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

#pragma once

#if USE(LIBWEBRTC) && PLATFORM(COCOA) && ENABLE(GPU_PROCESS)

#include "SharedPreferencesForWebProcess.h"
#include "SharedVideoFrame.h"
#include "SwiftCoding.h"
#include "VideoDecoderIdentifier.h"
#include "VideoEncoderIdentifier.h"
#include "WorkQueueMessageReceiver.h"
#include <CoreMedia/CMFormatDescription.h>
#include <WebCore/PlatformVideoColorSpace.h>
#include <WebCore/ProcessIdentity.h>
#include <WebCore/SharedMemory.h>
#include <WebCore/VideoCodecType.h>
#include <WebCore/VideoEncoderScalabilityMode.h>
#include <optional>
#include <span>
#include <wtf/Function.h>
#include <wtf/Ref.h>
#include <wtf/RefPtr.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/UniqueRef.h>
#include <wtf/Vector.h>
#include <wtf/WorkQueue.h>
#include <wtf/text/WTFString.h>

namespace IPC {
class Connection;
class Semaphore;
}

namespace WebCore {
class GPUVideoEncoder;
class PixelBufferConformerCV;
class VideoInfo;
}

namespace WebKit {

class GPUConnectionToWebProcess;
class RemoteVideoFrameObjectHeap;

// Swift doesn't give a function that takes a class template's reference type the overloads that take a Span, unless
// the type is spelled through an alias.
using CodecStringArgument = IPC::CxxDecodedArgument<String>;
using EncoderParametersArgument = IPC::CxxDecodedArgument<Vector<std::pair<String, String>>>;
using SharedVideoFrameArgument = IPC::CxxDecodedArgument<SharedVideoFrame>;

// A WebCore::PlatformVideoColorSpace that Swift can make and read: each value counts only if the flag before it is set.
struct LibWebRTCCodecsColorSpace {
    bool hasPrimaries { false };
    WebCore::PlatformVideoColorPrimaries primaries { };
    bool hasTransfer { false };
    WebCore::PlatformVideoTransferCharacteristics transfer { };
    bool hasMatrix { false };
    WebCore::PlatformVideoMatrixCoefficients matrix { };
    bool hasFullRange { false };
    bool fullRange { false };
    bool hasChromaLocation { false };
    WebCore::PlatformVideoChromaLocation chromaLocation { };
};

// What LibWebRTCCodecsProxy.swift's decoders leave to WebCore: the check of a codec string, which a null String passes;
// the format description of a video info, with the values that the override sets replacing the video info's, returned
// +1; and the colour space of a decoded frame, as WebCore::VideoFrameCV computes it.
bool isValidDecoderCodecString(WebCore::VideoCodecType, CodecStringArgument&);
CMFormatDescriptionRef WTF_NULLABLE createDecoderFormatDescription(const WebCore::VideoInfo&, LibWebRTCCodecsColorSpace colorSpaceOverride) CF_RETURNS_RETAINED;
LibWebRTCCodecsColorSpace colorSpaceOfPixelBuffer(CVPixelBufferRef WTF_NONNULL);

// The receiver of the web process's video decoder and encoder messages, which run on the codecs queue. Swift handles
// them (LibWebRTCCodecsProxy.swift), keeping the decoders and encoders in the Swift state that m_swiftState holds; this
// keeps the connection and codecs queue, the shared preferences the messages are enabled by, and the frames read from
// the video frame heap.
class SWIFT_PRIVATE_FILEID("WebKit/LibWebRTCCodecsProxy.swift") LibWebRTCCodecsProxy final : public IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any> {
    WTF_MAKE_TZONE_ALLOCATED(LibWebRTCCodecsProxy);
public:
    static Ref<LibWebRTCCodecsProxy> create(GPUConnectionToWebProcess&, SharedPreferencesForWebProcess&);
    ~LibWebRTCCodecsProxy();

    void ref() const final { IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::ref(); }
    void deref() const final { IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::deref(); }

    // Fails what is pending once the messages already queued have been handled.
    void stopListeningForIPC(Ref<LibWebRTCCodecsProxy>&& refFromConnection);
    // Implemented in Swift; called on the main thread.
    bool allowsExitUnderMemoryPressure() const;

    IPC::Connection& connection() const LIFETIME_BOUND { return m_connection; }
    WorkQueue& workQueue() const LIFETIME_BOUND { return m_queue; }
    RemoteVideoFrameObjectHeap& videoFrameObjectHeap() const LIFETIME_BOUND { return m_videoFrameObjectHeap; }
    const WebCore::ProcessIdentity& resourceOwner() const LIFETIME_BOUND { return m_resourceOwner; }

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;
    void updateSharedPreferencesForWebProcess(SharedPreferencesForWebProcess);

    // Reads the heap frame that a SharedVideoFrame refers to, if it refers to one, so that the heap releases it.
    void releaseVideoFrame(SharedVideoFrameArgument&);
    // The pixel buffer conformer that encoders share, on the codecs queue.
    WebCore::PixelBufferConformerCV& pixelBufferConformer();

    static void setRTCLoggingLevel(uint8_t);

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

private:
    LibWebRTCCodecsProxy(Ref<IPC::Connection>&&, Ref<WorkQueue>&&, Ref<RemoteVideoFrameObjectHeap>&&, const WebCore::ProcessIdentity&, const SharedPreferencesForWebProcess&);

    // Implemented in Swift, in LibWebRTCCodecsProxy.swift, on the state that m_swiftState holds.
    static uintptr_t createSwiftState(RemoteVideoFrameObjectHeap&, WebCore::ProcessIdentity resourceOwner, bool hasResourceOwner, void* WTF_NONNULL codecsQueue);
    static void destroySwiftState(uintptr_t);
    void failPendingReplies();

    const Ref<IPC::Connection> m_connection;
    const Ref<WorkQueue> m_queue;
    const Ref<RemoteVideoFrameObjectHeap> m_videoFrameObjectHeap;
    const WebCore::ProcessIdentity m_resourceOwner;
    SharedPreferencesForWebProcess m_sharedPreferencesForWebProcess;
    std::unique_ptr<WebCore::PixelBufferConformerCV> m_pixelBufferConformer;
    // A retained reference to the Swift state, as an address, from the constructor to the destructor.
    const uintptr_t m_swiftState;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// An encoder of LibWebRTCCodecsProxy.swift. What it encodes goes to the web process, and each result goes to the callback
// on the codecs queue.
class LibWebRTCCodecsProxyEncoder final : public ThreadSafeRefCounted<LibWebRTCCodecsProxyEncoder> {
public:
    // Null if the configuration isn't valid, or there is no encoder for it.
    static RefPtr<LibWebRTCCodecsProxyEncoder> create(LibWebRTCCodecsProxy&, uint64_t identifier, WebCore::VideoCodecType, CodecStringArgument&, EncoderParametersArgument&, bool useLowLatency, bool useAnnexB, WebCore::VideoEncoderScalabilityMode, void (^WTF_NONNULL resultCallback)(bool));
    ~LibWebRTCCodecsProxyEncoder();

    void initialize(uint16_t width, uint16_t height, unsigned startBitrate, unsigned maxBitrate, unsigned minBitrate, uint32_t maxFramerate);
    // Returns false if the frame can't be encoded. Otherwise its result goes to the callback.
    [[nodiscard]] bool encodeFrame(SharedVideoFrameArgument&, int64_t timeStamp, bool hasDuration, uint64_t duration, bool shouldEncodeAsKeyFrame);
    void flush();
    void setRates(uint32_t bitRate, uint32_t frameRate);
    // Each takes a right of its own to the port that the encoder's IPCTypes.Semaphore or SharedMemoryHandle owns.
    void setSharedVideoFrameSemaphore(mach_port_t);
    void setSharedVideoFrameMemory(mach_port_t, uint64_t size);

private:
    LibWebRTCCodecsProxyEncoder(LibWebRTCCodecsProxy&, Ref<WebCore::GPUVideoEncoder>&&);

    // Weak, since the proxy's Swift state keeps the encoder.
    const ThreadSafeWeakPtr<LibWebRTCCodecsProxy> m_proxy;
    const Ref<WebCore::GPUVideoEncoder> m_encoder;
    const UniqueRef<SharedVideoFrameReader> m_frameReader;
};

}

#endif
