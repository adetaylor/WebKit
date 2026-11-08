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
#import "LibWebRTCCodecsProxyPlatform.h"

#if USE(LIBWEBRTC) && PLATFORM(COCOA) && ENABLE(GPU_PROCESS)

#import "Connection.h"
#import "LibWebRTCCodecsMessages.h"
#import "LibWebRTCCodecsProxyMessages.h"
#import "Logging.h"
#import "RemoteVideoFrameIdentifier.h"
#import "RemoteVideoFrameObjectHeapHandle.h"
#import "SharedVideoFrame.h"
#import <WebCore/CMUtilities.h>
#import <WebCore/CVUtilities.h>
#import <WebCore/FrameRateMonitor.h>
#import <WebCore/GPUVideoDecoder.h>
#import <WebCore/GPUVideoEncoder.h>
#import <WebCore/HEVCUtilitiesCocoa.h>
#import <WebCore/LibWebRTCProvider.h>
#import <WebCore/PixelBufferConformerCV.h>
#import <WebCore/VideoFrameCV.h>
#import <wtf/BlockPtr.h>
#import <wtf/MediaTime.h>
#import <wtf/Scope.h>

WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_BEGIN

#include <webrtc/webkit_sdk/WebKit/WebKitDecoder.h>

WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_END

#import <pal/cf/CoreMediaSoftLink.h>
#import <WebCore/CoreVideoSoftLink.h>

namespace WebKit {
using namespace WebCore;

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

Ref<LibWebRTCCodecsProxyPlatform> LibWebRTCCodecsProxyPlatform::create(Ref<IPC::Connection>&& connection, Ref<WorkQueue>&& queue, Ref<RemoteVideoFrameObjectHeapHandle>&& videoFrameObjectHeap, const ProcessIdentity& resourceOwner, const SharedPreferencesForWebProcess& sharedPreferencesForWebProcess)
{
    return adoptRef(*new LibWebRTCCodecsProxyPlatform(WTF::move(connection), WTF::move(queue), WTF::move(videoFrameObjectHeap), resourceOwner, sharedPreferencesForWebProcess));
}

LibWebRTCCodecsProxyPlatform::LibWebRTCCodecsProxyPlatform(Ref<IPC::Connection>&& connection, Ref<WorkQueue>&& queue, Ref<RemoteVideoFrameObjectHeapHandle>&& videoFrameObjectHeap, const ProcessIdentity& resourceOwner, const SharedPreferencesForWebProcess& sharedPreferencesForWebProcess)
    : m_connection(WTF::move(connection))
    , m_queue(WTF::move(queue))
    , m_videoFrameObjectHeap(WTF::move(videoFrameObjectHeap))
    , m_resourceOwner(resourceOwner)
    , m_sharedPreferencesForWebProcess(sharedPreferencesForWebProcess)
{
    m_queue->dispatch([this, protectedThis = Ref { *this }, sharedPreferencesForWebProcess] {
        m_sharedPreferencesForWebProcess = sharedPreferencesForWebProcess;
    });
}

LibWebRTCCodecsProxyPlatform::~LibWebRTCCodecsProxyPlatform() = default;

void LibWebRTCCodecsProxyPlatform::stopReceivingMessages()
{
    m_connection->removeWorkQueueMessageReceiver(Messages::LibWebRTCCodecsProxy::messageReceiverName());
}

void LibWebRTCCodecsProxyPlatform::dispatch(void (^task)())
{
    m_queue->dispatch([task = makeBlockPtr(task)] {
        task();
    });
}

std::optional<SharedPreferencesForWebProcess> LibWebRTCCodecsProxyPlatform::sharedPreferencesForWebProcess() const
{
    return m_sharedPreferencesForWebProcess;
}

void LibWebRTCCodecsProxyPlatform::updateSharedPreferencesForWebProcess(SharedPreferencesForWebProcess sharedPreferencesForWebProcess)
{
    m_queue->dispatch([this, protectedThis = Ref { *this }, sharedPreferencesForWebProcess = WTF::move(sharedPreferencesForWebProcess)] {
        m_sharedPreferencesForWebProcess = sharedPreferencesForWebProcess;
    });
}

void LibWebRTCCodecsProxyPlatform::releaseVideoFrame(SharedVideoFrameArgument& argument)
{
    auto sharedVideoFrame = argument.take();
    if (!sharedVideoFrame)
        return;
    // Make sure to read RemoteVideoFrameReadReference to prevent memory leaks.
    if (std::holds_alternative<RemoteVideoFrameReadReference>(sharedVideoFrame->buffer))
        m_videoFrameObjectHeap->get(WTF::move(std::get<RemoteVideoFrameReadReference>(sharedVideoFrame->buffer)));
}

PixelBufferConformerCV& LibWebRTCCodecsProxyPlatform::pixelBufferConformer()
{
    assertIsCurrent(m_queue);
    if (!m_pixelBufferConformer)
        m_pixelBufferConformer = makeUnique<WebCore::PixelBufferConformerCV>((__bridge CFDictionaryRef)@{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) });
    return *m_pixelBufferConformer;
}

void LibWebRTCCodecsProxyPlatform::setRTCLoggingLevel(uint8_t level)
{
    WebCore::LibWebRTCProvider::setRTCLogging(static_cast<WTFLogLevel>(level));
}

static std::unique_ptr<FrameRateMonitor> createGeneratedFrameRateMonitor(VideoDecoderIdentifier identifier)
{
    return makeUnique<FrameRateMonitor>([identifier](auto info) {
        callOnMainRunLoop([identifier, info] {
            auto frameTime = info.frameTime.secondsSinceEpoch().value();
            auto lastFrameTime = info.lastFrameTime.secondsSinceEpoch().value();
            RELEASE_LOG(WebRTC, "LibWebRTCCodecsProxy decoder %" PRIu64 " generated a video frame at %f, previous frame was at %f, observed frame rate is %f, delay since last frame is %f ms, frame count is %lu", identifier.toUInt64(), frameTime, lastFrameTime, info.observedFrameRate, (frameTime - lastFrameTime) * 1000, info.frameCount);
        });
    });
}

static std::unique_ptr<FrameRateMonitor> createReceivedFrameRateMonitor(VideoDecoderIdentifier identifier)
{
    return makeUnique<FrameRateMonitor>([identifier](auto info) {
        callOnMainRunLoop([identifier, info] {
            auto frameTime = info.frameTime.secondsSinceEpoch().value();
            auto lastFrameTime = info.lastFrameTime.secondsSinceEpoch().value();
            RELEASE_LOG(WebRTC, "LibWebRTCCodecsProxy decoder %" PRIu64 " received a compressed frame at %f, previous frame was at %f, observed frame rate is %f, delay since last frame is %f ms, frame count is %lu", identifier.toUInt64(), frameTime, lastFrameTime, info.observedFrameRate, (frameTime - lastFrameTime) * 1000, info.frameCount);
        });
    });
}

static auto createDecoderCallback(LibWebRTCCodecsProxyPlatform& platform, VideoDecoderIdentifier identifier, bool useRemoteFrames, bool enableAdditionalLogging, VideoFrameRotation rotation, bool isMirrored, Ref<LibWebRTCCodecsProxyResultCallback>&& resultCallback)
{
    RefPtr<RemoteVideoFrameObjectHeapHandle> videoFrameObjectHeap;
    if (useRemoteFrames)
        videoFrameObjectHeap = &platform.videoFrameObjectHeap();
    std::unique_ptr<FrameRateMonitor> frameRateMonitor;
    if (enableAdditionalLogging)
        frameRateMonitor = createGeneratedFrameRateMonitor(identifier);
    return [resultCallback = WTF::move(resultCallback), identifier, rotation, isMirrored, connection = Ref { platform.connection() }, resourceOwner = platform.resourceOwner(), videoFrameObjectHeap = WTF::move(videoFrameObjectHeap), frameRateMonitor = WTF::move(frameRateMonitor)](CVPixelBufferRef pixelBuffer, int64_t timeStamp, int64_t timeStampNs, bool isReordered) mutable {
        auto scope = makeScopeExit([&, pixelBuffer = retainPtr(pixelBuffer)] {
            bool isGettingReorderedFrame = pixelBuffer && isReordered;
            if (!isGettingReorderedFrame)
                resultCallback->notify(pixelBuffer || isReordered);
        });

        if (!pixelBuffer) {
            if (!isReordered)
                connection->send(Messages::LibWebRTCCodecs::FailedDecoding { identifier }, 0);
            return;
        }

        if (frameRateMonitor)
            frameRateMonitor->update();

        auto videoFrame = WebCore::VideoFrameCV::create(MediaTime(timeStampNs, 1), isMirrored, rotation, pixelBuffer);
        if (resourceOwner)
            videoFrame->setOwnershipIdentity(resourceOwner);
        if (!videoFrameObjectHeap) {
            connection->send(Messages::LibWebRTCCodecs::CompletedDecodingCV { identifier, timeStamp, timeStampNs, pixelBuffer }, 0);
            return;
        }

        auto properties = RemoteVideoFrameProxy::properties(videoFrame);
        auto reference = videoFrameObjectHeap->add(WTF::move(videoFrame));
        connection->send(Messages::LibWebRTCCodecs::CompletedDecoding { identifier, timeStamp, timeStampNs, reference, WTF::move(properties) }, 0);
    };
}

RefPtr<LibWebRTCCodecsProxyDecoder> LibWebRTCCodecsProxyDecoder::create(LibWebRTCCodecsProxyPlatform& platform, uint64_t rawIdentifier, VideoCodecType codecType, CodecStringArgument& codecStringArgument, bool useRemoteFrames, bool enableAdditionalLogging, ColorSpaceOverrideArgument& colorSpaceOverrideArgument, VideoFrameRotationArgument& rotationArgument, bool isMirrored, void (^resultCallback)(bool))
{
    assertIsCurrent(platform.workQueue());

    auto codecString = codecStringArgument.take();
    auto colorSpaceOverride = colorSpaceOverrideArgument.take();
    auto rotation = rotationArgument.take();
    if (!codecString || !colorSpaceOverride || !rotation)
        return nullptr;

    if (!codecString->isNull() && !isValidWebRTCDecoderCodecString(codecType, *codecString))
        return nullptr;

    VideoDecoderIdentifier identifier { rawIdentifier };
    Ref callback = LibWebRTCCodecsProxyResultCallback::create(platform.workQueue(), resultCallback);
    auto decoder = GPUVideoDecoder::create(makeBlockPtr(createDecoderCallback(platform, identifier, useRemoteFrames, enableAdditionalLogging, *rotation, isMirrored, WTF::move(callback))).get(), Ref { platform.workQueue() }, WTF::move(*colorSpaceOverride));
    if (!decoder)
        return nullptr;

    std::unique_ptr<FrameRateMonitor> frameRateMonitor;
    if (enableAdditionalLogging)
        frameRateMonitor = createReceivedFrameRateMonitor(identifier);

    return adoptRef(*new LibWebRTCCodecsProxyDecoder(platform.connection(), identifier, WTF::move(decoder), WTF::move(frameRateMonitor)));
}

LibWebRTCCodecsProxyDecoder::LibWebRTCCodecsProxyDecoder(Ref<IPC::Connection>&& connection, VideoDecoderIdentifier identifier, std::unique_ptr<GPUVideoDecoder>&& decoder, std::unique_ptr<FrameRateMonitor>&& frameRateMonitor)
    : m_connection(WTF::move(connection))
    , m_identifier(identifier)
    , m_decoder(WTF::move(decoder))
    , m_frameRateMonitor(WTF::move(frameRateMonitor))
{
}

LibWebRTCCodecsProxyDecoder::~LibWebRTCCodecsProxyDecoder() = default;

void LibWebRTCCodecsProxyDecoder::flush()
{
    m_decoder->flush();
}

void LibWebRTCCodecsProxyDecoder::setFormat(std::span<const uint8_t> description NOESCAPE, VideoInfoArgument& videoInfo, uint16_t width, uint16_t height)
{
    if (auto info = videoInfo.take())
        m_decoder->setFormat(description, width, height, WTF::move(*info));
}

void LibWebRTCCodecsProxyDecoder::setColorSpaceOverride(ColorSpaceOverrideArgument& colorSpaceOverride)
{
    if (auto value = colorSpaceOverride.take())
        m_decoder->setColorSpaceOverride(WTF::move(*value));
}

bool LibWebRTCCodecsProxyDecoder::decodeFrame(int64_t timeStamp, std::span<const uint8_t> data NOESCAPE, VideoInfoArgument& videoInfo)
{
    if (m_frameRateMonitor)
        m_frameRateMonitor->update();
    auto info = videoInfo.take();
    if (!info || m_decoder->decodeFrame(timeStamp, data, WTF::move(*info))) {
        m_connection->send(Messages::LibWebRTCCodecs::FailedDecoding { m_identifier }, 0);
        return false;
    }
    return true;
}

void LibWebRTCCodecsProxyDecoder::setFrameSize(uint16_t width, uint16_t height)
{
    m_decoder->setFrameSize(width, height);
}

RefPtr<LibWebRTCCodecsProxyEncoder> LibWebRTCCodecsProxyEncoder::create(LibWebRTCCodecsProxyPlatform& platform, uint64_t rawIdentifier, VideoCodecType codecType, CodecStringArgument& codecStringArgument, EncoderParametersArgument& parametersArgument, bool useLowLatency, bool useAnnexB, VideoEncoderScalabilityMode scalabilityMode, void (^resultCallback)(bool))
{
    assertIsCurrent(platform.workQueue());

    auto codecString = codecStringArgument.take();
    auto parameters = parametersArgument.take();
    if (!codecString || !parameters)
        return nullptr;

    if (!isValidWebRTCEncoderConfiguration(codecType, *codecString, useLowLatency, scalabilityMode))
        return nullptr;

    VideoEncoderIdentifier identifier { rawIdentifier };
    Ref callback = LibWebRTCCodecsProxyResultCallback::create(platform.workQueue(), resultCallback);
    auto errorBlock = [callback](bool result) {
        callback->notify(result);
    };
    auto newFrameBlock = [callback, connection = Ref { platform.connection() }, identifier](std::span<const uint8_t> buffer, const WebCore::GPUVideoEncoderFrameInfo& frameInfo) {
        connection->send(Messages::LibWebRTCCodecs::CompletedEncoding { identifier, buffer, frameInfo }, 0);
        callback->notify(true);
    };
    auto newConfigurationBlock = [connection = Ref { platform.connection() }, identifier](std::span<const uint8_t> buffer, const PlatformVideoColorSpace& encoderColorSpace) {
        connection->send(Messages::LibWebRTCCodecs::SetEncodingConfiguration { identifier, buffer, encoderColorSpace }, 0);
    };

    RefPtr encoder = WebCore::GPUVideoEncoder::create({
        .codecType = codecType,
        .useAnnexB = useAnnexB,
        .scalabilityMode = scalabilityMode,
        .isLowLatencyEnabled = useLowLatency,
        .queue = platform.workQueue()
    }, *parameters, WTF::move(newFrameBlock), WTF::move(newConfigurationBlock), WTF::move(errorBlock));
    if (!encoder)
        return nullptr;

    return adoptRef(*new LibWebRTCCodecsProxyEncoder(platform, encoder.releaseNonNull()));
}

LibWebRTCCodecsProxyEncoder::LibWebRTCCodecsProxyEncoder(LibWebRTCCodecsProxyPlatform& platform, Ref<GPUVideoEncoder>&& encoder)
    : m_platform(platform)
    , m_encoder(WTF::move(encoder))
    , m_frameReader(makeUniqueRef<SharedVideoFrameReader>(Ref { platform.videoFrameObjectHeap() }, platform.resourceOwner()))
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
        pixelBuffer = m_platform->pixelBufferConformer().convert(pixelBuffer.get());
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
