/*
 * Copyright (C) 2020-2025 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "LibWebRTCCodecsProxy.h"

#if USE(LIBWEBRTC) && PLATFORM(COCOA) && ENABLE(GPU_PROCESS)

#import "Connection.h"
#import "GPUConnectionToWebProcess.h"
#import "GPUProcess.h"
#import "LibWebRTCCodecsMessages.h"
#import "LibWebRTCCodecsProxyMessages.h"
#import "Logging.h"
#import "RemoteVideoFrameIdentifier.h"
#import "RemoteVideoFrameObjectHeap.h"
#import "SharedVideoFrame.h"
#import <WebCore/CMUtilities.h>
#import <WebCore/CVUtilities.h>
#import <WebCore/GPUVideoEncoder.h>
#import <WebCore/HEVCUtilitiesCocoa.h>
#import <WebCore/LibWebRTCProvider.h>
#import <WebCore/PixelBufferConformerCV.h>
#import <wtf/BlockPtr.h>
#import <wtf/TZoneMallocInlines.h>

#import <pal/cf/CoreMediaSoftLink.h>
#import <WebCore/CoreVideoSoftLink.h>

namespace WebKit {
using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(LibWebRTCCodecsProxy);

// Hands a decoder's or an encoder's results to LibWebRTCCodecsProxy.swift on the codecs queue. The platform callbacks
// that report them keep it, so it doesn't keep the decoder or the encoder.
class LibWebRTCCodecsProxyResultCallback final : public ThreadSafeRefCounted<LibWebRTCCodecsProxyResultCallback> {
public:
    static Ref<LibWebRTCCodecsProxyResultCallback> create(Ref<WorkQueue>&& queue, void (^callback)(bool))
    {
        return adoptRef(*new LibWebRTCCodecsProxyResultCallback(WTF::move(queue), callback));
    }

    void notify(bool result)
    {
        m_queue->dispatch([protectedThis = Ref { *this }, result] {
            assertIsCurrent(protectedThis->m_queue);
            protectedThis->m_callback(result);
        });
    }

private:
    LibWebRTCCodecsProxyResultCallback(Ref<WorkQueue>&& queue, void (^callback)(bool))
        : m_queue(WTF::move(queue))
        , m_callback(makeBlockPtr(callback))
    {
    }

    const Ref<WorkQueue> m_queue;
    const BlockPtr<void(bool)> m_callback;
};

Ref<LibWebRTCCodecsProxy> LibWebRTCCodecsProxy::create(GPUConnectionToWebProcess& webProcessConnection, SharedPreferencesForWebProcess& sharedPreferencesForWebProcess)
{
    Ref proxy = adoptRef(*new LibWebRTCCodecsProxy(webProcessConnection.connection(), webProcessConnection.gpuProcess().libWebRTCCodecsQueue(), webProcessConnection.videoFrameObjectHeap(), webProcessConnection.webProcessIdentity(), sharedPreferencesForWebProcess));
    proxy->m_connection->addWorkQueueMessageReceiver(Messages::LibWebRTCCodecsProxy::messageReceiverName(), proxy->m_queue.get(), proxy.get());
    return proxy;
}

LibWebRTCCodecsProxy::LibWebRTCCodecsProxy(Ref<IPC::Connection>&& connection, Ref<WorkQueue>&& queue, Ref<RemoteVideoFrameObjectHeap>&& videoFrameObjectHeap, const ProcessIdentity& resourceOwner, const SharedPreferencesForWebProcess& sharedPreferencesForWebProcess)
    : m_connection(WTF::move(connection))
    , m_queue(WTF::move(queue))
    , m_videoFrameObjectHeap(WTF::move(videoFrameObjectHeap))
    , m_resourceOwner(resourceOwner)
    , m_sharedPreferencesForWebProcess(sharedPreferencesForWebProcess)
    , m_swiftState(createSwiftState(m_videoFrameObjectHeap.get(), m_resourceOwner, !!m_resourceOwner, (__bridge void*)m_queue->dispatchQueue()))
{
    m_queue->dispatch([this, protectedThis = Ref { *this }, sharedPreferencesForWebProcess] {
        m_sharedPreferencesForWebProcess = sharedPreferencesForWebProcess;
    });
}

LibWebRTCCodecsProxy::~LibWebRTCCodecsProxy()
{
    destroySwiftState(m_swiftState);
}

void LibWebRTCCodecsProxy::stopListeningForIPC(Ref<LibWebRTCCodecsProxy>&& refFromConnection)
{
    m_connection->removeWorkQueueMessageReceiver(Messages::LibWebRTCCodecsProxy::messageReceiverName());
    m_queue->dispatch([protectedThis = WTF::move(refFromConnection)] {
        protectedThis->failPendingReplies();
    });
}

std::optional<SharedPreferencesForWebProcess> LibWebRTCCodecsProxy::sharedPreferencesForWebProcess() const
{
    return m_sharedPreferencesForWebProcess;
}

void LibWebRTCCodecsProxy::updateSharedPreferencesForWebProcess(SharedPreferencesForWebProcess sharedPreferencesForWebProcess)
{
    m_queue->dispatch([this, protectedThis = Ref { *this }, sharedPreferencesForWebProcess = WTF::move(sharedPreferencesForWebProcess)] {
        m_sharedPreferencesForWebProcess = sharedPreferencesForWebProcess;
    });
}

void LibWebRTCCodecsProxy::releaseVideoFrame(SharedVideoFrameArgument& argument)
{
    auto sharedVideoFrame = argument.take();
    if (!sharedVideoFrame)
        return;
    // Make sure to read RemoteVideoFrameReadReference to prevent memory leaks.
    if (std::holds_alternative<RemoteVideoFrameReadReference>(sharedVideoFrame->buffer))
        m_videoFrameObjectHeap->get(WTF::move(std::get<RemoteVideoFrameReadReference>(sharedVideoFrame->buffer)));
}

PixelBufferConformerCV& LibWebRTCCodecsProxy::pixelBufferConformer()
{
    assertIsCurrent(m_queue);
    if (!m_pixelBufferConformer)
        m_pixelBufferConformer = makeUnique<WebCore::PixelBufferConformerCV>((__bridge CFDictionaryRef)@{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) });
    return *m_pixelBufferConformer;
}

void LibWebRTCCodecsProxy::setRTCLoggingLevel(uint8_t level)
{
    WebCore::LibWebRTCProvider::setRTCLogging(static_cast<WTFLogLevel>(level));
}

bool isValidDecoderCodecString(VideoCodecType codecType, CodecStringArgument& codecStringArgument)
{
    auto codecString = codecStringArgument.take();
    if (!codecString)
        return false;
    return codecString->isNull() || isValidWebRTCDecoderCodecString(codecType, *codecString);
}

static PlatformVideoColorSpace platformColorSpace(LibWebRTCCodecsColorSpace colorSpace)
{
    PlatformVideoColorSpace result;
    if (colorSpace.hasPrimaries)
        result.primaries = colorSpace.primaries;
    if (colorSpace.hasTransfer)
        result.transfer = colorSpace.transfer;
    if (colorSpace.hasMatrix)
        result.matrix = colorSpace.matrix;
    if (colorSpace.hasFullRange)
        result.fullRange = colorSpace.fullRange;
    if (colorSpace.hasChromaLocation)
        result.chromaLocation = colorSpace.chromaLocation;
    return result;
}

static LibWebRTCCodecsColorSpace codecsColorSpace(const PlatformVideoColorSpace& colorSpace)
{
    LibWebRTCCodecsColorSpace result;
    if (colorSpace.primaries) {
        result.hasPrimaries = true;
        result.primaries = *colorSpace.primaries;
    }
    if (colorSpace.transfer) {
        result.hasTransfer = true;
        result.transfer = *colorSpace.transfer;
    }
    if (colorSpace.matrix) {
        result.hasMatrix = true;
        result.matrix = *colorSpace.matrix;
    }
    if (colorSpace.fullRange) {
        result.hasFullRange = true;
        result.fullRange = *colorSpace.fullRange;
    }
    if (colorSpace.chromaLocation) {
        result.hasChromaLocation = true;
        result.chromaLocation = *colorSpace.chromaLocation;
    }
    return result;
}

CMFormatDescriptionRef createDecoderFormatDescription(const VideoInfo& videoInfo, LibWebRTCCodecsColorSpace colorSpaceOverride)
{
    auto colorSpace = platformColorSpace(colorSpaceOverride);
    if (!colorSpace.isValid())
        return createFormatDescriptionFromTrackInfo(videoInfo).leakRef();

    auto data = videoInfo.toVideoInfoData();
    overrideVideoColorSpaceAsNeeded(data.second.colorSpace, colorSpace);
    Ref updatedVideoInfo = VideoInfo::create(WTF::move(data));
    return createFormatDescriptionFromTrackInfo(updatedVideoInfo).leakRef();
}

LibWebRTCCodecsColorSpace colorSpaceOfPixelBuffer(CVPixelBufferRef pixelBuffer)
{
    return codecsColorSpace(computeVideoFrameColorSpace(pixelBuffer));
}

RefPtr<LibWebRTCCodecsProxyEncoder> LibWebRTCCodecsProxyEncoder::create(LibWebRTCCodecsProxy& proxy, uint64_t rawIdentifier, VideoCodecType codecType, CodecStringArgument& codecStringArgument, EncoderParametersArgument& parametersArgument, bool useLowLatency, bool useAnnexB, VideoEncoderScalabilityMode scalabilityMode, void (^resultCallback)(bool))
{
    assertIsCurrent(proxy.workQueue());

    auto codecString = codecStringArgument.take();
    auto parameters = parametersArgument.take();
    if (!codecString || !parameters)
        return nullptr;

    if (!isValidWebRTCEncoderConfiguration(codecType, *codecString, useLowLatency, scalabilityMode))
        return nullptr;

    VideoEncoderIdentifier identifier { rawIdentifier };
    Ref callback = LibWebRTCCodecsProxyResultCallback::create(proxy.workQueue(), resultCallback);
    auto errorBlock = [callback](bool result) {
        callback->notify(result);
    };
    auto newFrameBlock = [callback, connection = Ref { proxy.connection() }, identifier](std::span<const uint8_t> buffer, const WebCore::GPUVideoEncoderFrameInfo& frameInfo) {
        connection->send(Messages::LibWebRTCCodecs::CompletedEncoding { identifier, buffer, frameInfo }, 0);
        callback->notify(true);
    };
    auto newConfigurationBlock = [connection = Ref { proxy.connection() }, identifier](std::span<const uint8_t> buffer, const PlatformVideoColorSpace& encoderColorSpace) {
        connection->send(Messages::LibWebRTCCodecs::SetEncodingConfiguration { identifier, buffer, encoderColorSpace }, 0);
    };

    RefPtr encoder = WebCore::GPUVideoEncoder::create({
        .codecType = codecType,
        .useAnnexB = useAnnexB,
        .scalabilityMode = scalabilityMode,
        .isLowLatencyEnabled = useLowLatency,
        .queue = proxy.workQueue()
    }, *parameters, WTF::move(newFrameBlock), WTF::move(newConfigurationBlock), WTF::move(errorBlock));
    if (!encoder)
        return nullptr;

    return adoptRef(*new LibWebRTCCodecsProxyEncoder(proxy, encoder.releaseNonNull()));
}

LibWebRTCCodecsProxyEncoder::LibWebRTCCodecsProxyEncoder(LibWebRTCCodecsProxy& proxy, Ref<GPUVideoEncoder>&& encoder)
    : m_proxy(proxy)
    , m_encoder(WTF::move(encoder))
    , m_frameReader(makeUniqueRef<SharedVideoFrameReader>(Ref { proxy.videoFrameObjectHeap() }, proxy.resourceOwner()))
{
}

LibWebRTCCodecsProxyEncoder::~LibWebRTCCodecsProxyEncoder() = default;

void LibWebRTCCodecsProxyEncoder::initialize(uint16_t width, uint16_t height, unsigned startBitrate, unsigned maxBitrate, unsigned minBitrate, uint32_t maxFramerate)
{
    m_encoder->initialize(width, height, startBitrate, maxBitrate, minBitrate, maxFramerate);
}

bool LibWebRTCCodecsProxyEncoder::encodeFrame(SharedVideoFrameArgument& argument, int64_t timeStamp, bool hasDuration, uint64_t durationValue, bool shouldEncodeAsKeyFrame)
{
    auto duration = hasDuration ? std::optional { durationValue } : std::nullopt;
    auto sharedVideoFrame = argument.take();
    if (!sharedVideoFrame)
        return false;

    auto pixelBuffer = m_frameReader->readBuffer(WTF::move(sharedVideoFrame->buffer));
    if (!pixelBuffer)
        return false;

    if (CVPixelBufferGetPixelFormatType(pixelBuffer.get()) == kCVPixelFormatType_32BGRA) {
        sharedVideoFrame->colorSpace = srgbColorSpace();
        RefPtr proxy = m_proxy;
        if (!proxy)
            return false;
        pixelBuffer = proxy->pixelBufferConformer().convert(pixelBuffer.get());
        if (!pixelBuffer)
            return false;
    }

#if !PLATFORM(MACCATALYST)
    attachColorSpaceToPixelBuffer(sharedVideoFrame->colorSpace, pixelBuffer);
    m_encoder->encodeFrame(pixelBuffer.get(), Seconds(sharedVideoFrame->time.toDouble()).nanoseconds(), timeStamp, duration, sharedVideoFrame->rotation, sharedVideoFrame->mirrored, shouldEncodeAsKeyFrame);
    return true;
#else
    UNUSED_PARAM(timeStamp);
    UNUSED_PARAM(duration);
    UNUSED_PARAM(shouldEncodeAsKeyFrame);
    return false;
#endif
}

void LibWebRTCCodecsProxyEncoder::flush()
{
    m_encoder->flush();
}

void LibWebRTCCodecsProxyEncoder::setRates(uint32_t bitRate, uint32_t frameRate)
{
    m_encoder->setRates(bitRate, frameRate);
}

void LibWebRTCCodecsProxyEncoder::setSharedVideoFrameSemaphore(mach_port_t semaphore)
{
    m_frameReader->setSemaphore(IPC::Semaphore { MachSendRight::create(semaphore) });
}

void LibWebRTCCodecsProxyEncoder::setSharedVideoFrameMemory(mach_port_t memory, uint64_t size)
{
    m_frameReader->setSharedMemory({ MachSendRight::create(memory), size });
}

}

#endif
