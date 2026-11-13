/*
 * Copyright (C) 2017-2025 Apple Inc. All rights reserved.
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

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)

#include "Connection.h"
#include "MessageReceiver.h"
#include "SharedPreferencesForWebProcess.h"
#include <CoreAudio/CoreAudioTypes.h>
#include <WebCore/CaptureDevice.h>
#include <WebCore/CaptureSourceDecisions.h>
#include <WebCore/IntDegrees.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/ProcessIdentity.h>
#include <WebCore/VideoFrame.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/UniqueRef.h>

typedef struct __IOSurface *IOSurfaceRef;

namespace IPC {
class Semaphore;
template<typename> class CxxDecodedArgument;
}

namespace WebCore {
class CaptureConstraints;
struct MediaConstraints;
struct MediaDeviceHashSalts;
}

namespace WebKit {

class ProducerSharedCARingBuffer;
class RemoteVideoFrameObjectHeap;
struct ConsumerSharedCARingBufferHandle;

// A frame published to the web process: its reference in the frame heap, or, without a heap, nothing, since the frame's
// pixel buffer is sent instead (userMediaCaptureFrameSurface()); and RemoteVideoFrameProxy::properties().
struct UserMediaCapturePublishedFrame {
    uint64_t identifier { 0 };
    uint64_t version { 0 };
    int64_t timeValue { 0 };
    uint32_t timeScale { 0 };
    uint8_t timeFlags { 0 };
    uint16_t rotation { 0 };
    int32_t width { 0 };
    int32_t height { 0 };
    uint32_t pixelFormat { 0 };
    uint8_t primaries { 0 };
    uint8_t transfer { 0 };
    uint8_t matrix { 0 };
    uint8_t chromaLocation { 0 };
    bool hasReference { false };
    bool isMirrored { false };
    bool hasPrimaries { false };
    bool hasTransfer { false };
    bool hasMatrix { false };
    bool hasFullRange { false };
    bool fullRange { false };
    bool hasChromaLocation { false };
    bool shouldIgnoreAlpha { false };
};

// Publishes a source's frames, on the thread the source produces them on.
class UserMediaCaptureFramePublisher final : public ThreadSafeRefCounted<UserMediaCaptureFramePublisher> {
public:
    static Ref<UserMediaCaptureFramePublisher> create(RefPtr<RemoteVideoFrameObjectHeap>&&, WebCore::ProcessIdentity&&);
    ~UserMediaCaptureFramePublisher();

    // Tags the frame with the web process's identity, and adds it to the frame heap if there is one.
    UserMediaCapturePublishedFrame publish(WebCore::VideoFrame&);

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { ThreadSafeRefCounted<UserMediaCaptureFramePublisher>::ref(); }
    void deref() const { ThreadSafeRefCounted<UserMediaCaptureFramePublisher>::deref(); }
#endif

private:
    UserMediaCaptureFramePublisher(RefPtr<RemoteVideoFrameObjectHeap>&&, WebCore::ProcessIdentity&&);

    const RefPtr<RemoteVideoFrameObjectHeap> m_heap;
    const WebCore::ProcessIdentity m_resourceOwner;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// The IOSurface of a frame's pixel buffer, which the frame keeps alive, for a frame sent without a frame heap.
IOSurfaceRef WTF_NULLABLE userMediaCaptureFrameSurface(WebCore::VideoFrame&) CF_RETURNS_NOT_RETAINED;

// The ring and semaphore that a microphone's producer sink (Swift's CaptureSourceProxy) stores the microphone's quanta into
// for the web process, and the message that hands them over, as UserMediaCaptureManagerProxySourceProxy had them.
class UserMediaCaptureAudioStorage final : public ThreadSafeRefCounted<UserMediaCaptureAudioStorage> {
public:
    // A ring of 2 seconds of the format, or null.
    static UserMediaCaptureAudioStorage* WTF_NULLABLE create(IPC::Connection&, uint64_t sourceIdentifier, const AudioStreamBasicDescription&) SWIFT_RETURNS_RETAINED;
    ~UserMediaCaptureAudioStorage();

    // Unsafe: the sink stores into the ring and signals the semaphore until it is invalidated, which its owner must do
    // before letting this go; the identifier must be a capture sink's.
    SWIFT_UNSAFE void attachToSink(uint64_t sinkIdentifier);
    // Sends the ring to the web process, once, with the time of its first frame.
    void sendStorageChanged(int64_t startTimeValue, uint32_t startTimeScale);

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { ThreadSafeRefCounted<UserMediaCaptureAudioStorage>::ref(); }
    void deref() const { ThreadSafeRefCounted<UserMediaCaptureAudioStorage>::deref(); }
#endif

private:
    UserMediaCaptureAudioStorage(Ref<IPC::Connection>&&, uint64_t sourceIdentifier, const AudioStreamBasicDescription&, std::unique_ptr<ProducerSharedCARingBuffer>&&, ConsumerSharedCARingBufferHandle&&);

    const Ref<IPC::Connection> m_connection;
    const uint64_t m_sourceIdentifier;
    const AudioStreamBasicDescription m_format;
    const std::unique_ptr<ProducerSharedCARingBuffer> m_ringBuffer;
    const std::unique_ptr<IPC::Semaphore> m_semaphore;
    std::unique_ptr<ConsumerSharedCARingBufferHandle> m_handle;
    const uint64_t m_frameChunkSize;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// What applyCaptureEnvironment() found missing.
enum class UserMediaCaptureEnvironmentFailure : uint8_t {
    None,
    NoAttribution,
    NoMediaEnvironment,
};

// Receives one web process's capture messages. Its Swift state (UserMediaCaptureManagerProxy.swift), which m_swiftState
// holds, handles the messages and owns the sources; this does what the GPU process's C++ runtime does for them.
class SWIFT_PRIVATE_FILEID("WebKit/UserMediaCaptureManagerProxy.swift") UserMediaCaptureManagerProxy : public IPC::MessageReceiver, public RefCounted<UserMediaCaptureManagerProxy> {
    WTF_MAKE_TZONE_ALLOCATED(UserMediaCaptureManagerProxy);
public:
    class ConnectionProxy {
    public:
        virtual ~ConnectionProxy() = default;
        virtual void addMessageReceiver(IPC::ReceiverName, IPC::MessageReceiver&) = 0;
        virtual void removeMessageReceiver(IPC::ReceiverName) = 0;
        virtual IPC::Connection& connection() = 0;
        virtual bool willStartCapture(WebCore::CaptureDevice::DeviceType, WebCore::PageIdentifier) const = 0;
        virtual Logger& logger() = 0;
        virtual bool setCaptureAttributionString() { return true; }
        virtual WebCore::ProcessIdentity resourceOwner() const = 0;
#if ENABLE(APP_PRIVACY_REPORT)
        virtual void setTCCIdentity() { }
#endif
#if ENABLE(EXTENSION_CAPABILITIES)
        virtual bool setCurrentMediaEnvironment(WebCore::PageIdentifier) { return false; };
#endif
#if PLATFORM(IOS_FAMILY)
        virtual void providePresentingApplicationPID(WebCore::PageIdentifier) const = 0;
#endif
        virtual void startProducingData(WebCore::CaptureDevice::DeviceType, WebCore::PageIdentifier) { }
        virtual RemoteVideoFrameObjectHeap* remoteVideoFrameObjectHeap() { return nullptr; }

        virtual void startMonitoringCaptureDeviceRotation(WebCore::PageIdentifier, const String&) { }
        virtual void stopMonitoringCaptureDeviceRotation(WebCore::PageIdentifier, const String&) { }
        virtual std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const = 0;
    };
    static Ref<UserMediaCaptureManagerProxy> create(UniqueRef<ConnectionProxy>&&);
    ~UserMediaCaptureManagerProxy();

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    // Implemented in Swift.
    void close();
    void clear();
    void setOrientation(WebCore::IntDegrees);
    void swiftRotationAngleForCaptureDeviceChanged(String persistentID, uint16_t rotation);
    bool hasSourceProxies() const;
    void swiftReapplyCaptureEnvironment(uint64_t pageIdentifier);

    void rotationAngleForCaptureDeviceChanged(const String& persistentID, WebCore::VideoFrameRotation rotation) { swiftRotationAngleForCaptureDeviceChanged(persistentID, static_cast<uint16_t>(rotation)); }
    void reapplyCaptureEnvironment(WebCore::PageIdentifier pageIdentifier) { swiftReapplyCaptureEnvironment(pageIdentifier.toUInt64()); }

    void didReceiveMessageFromGPUProcess(IPC::Connection& connection, IPC::Decoder& decoder) { didReceiveMessage(connection, decoder); }
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

    // For the Swift state: what the GPU process's runtime does for capture.
    bool willStartCapture(WebCore::CaptureDevice::DeviceType, uint64_t pageIdentifier) const;
    UserMediaCaptureEnvironmentFailure applyCaptureEnvironment(WebCore::CaptureDevice::DeviceType, uint64_t pageIdentifier);
    void reapplyCaptureEnvironmentForSource(WebCore::CaptureDevice::DeviceType, uint64_t pageIdentifier);
    void startProducingData(WebCore::CaptureDevice::DeviceType, uint64_t pageIdentifier);
    void startMonitoringCaptureDeviceRotation(uint64_t pageIdentifier, const String& persistentID);
    void stopMonitoringCaptureDeviceRotation(uint64_t pageIdentifier, const String& persistentID);
    UserMediaCaptureFramePublisher* WTF_NONNULL framePublisher(bool usesFrameHeap) SWIFT_RETURNS_RETAINED;
    static WebCore::CaptureConstraints* WTF_NULLABLE takeConstraints(IPC::CxxDecodedArgument<WebCore::MediaConstraints>&) SWIFT_RETURNS_RETAINED;

    // For the Swift state: a microphone's unit is starting, which needs the audio session for capture.
    void microphoneUnitWillStart(uint64_t pageIdentifier);

private:
    explicit UserMediaCaptureManagerProxy(UniqueRef<ConnectionProxy>&&);

    // IPC::MessageReceiver
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

    // Implemented in Swift.
    SWIFT_MAIN_ACTOR uintptr_t createSwiftState();
    static void destroySwiftState(uintptr_t);

    const UniqueRef<ConnectionProxy> m_connectionProxy;
    // A retained reference to the Swift state, as an address, from the constructor to the destructor.
    uintptr_t m_swiftState { 0 };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

}

#endif
