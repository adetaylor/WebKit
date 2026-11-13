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

#include "config.h"
#include "UserMediaCaptureManagerProxy.h"

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)

#include "Connection.h"
#include "IPCSemaphore.h"
#include "Logging.h"
#include "RemoteCaptureSampleManagerMessages.h"
#include "RemoteVideoFrameObjectHeap.h"
#include "RemoteVideoFrameProxy.h"
#include "SharedCARingBuffer.h"
#include "SharedPreferencesForWebProcess.h"
#include "SwiftCoding.h"
#include "UserMediaCaptureManagerMessages.h"
#include "UserMediaCaptureManagerProxyMessages.h"
#include <WebCore/AudioOutputUnit.h>
#include <WebCore/AudioSession.h>
#include <WebCore/AudioUtilities.h>
#include <WebCore/CARingBuffer.h>
#include <WebCore/CaptureSourceDecisions.h>
#include <WebCore/MediaConstraints.h>
#include <WebCore/MediaConstraintsEvaluation.h>
#include <WebCore/PlatformMediaSessionManager.h>
#include <WebCore/RealtimeMediaSourceCenter.h>
#include <WebCore/WebAudioBufferList.h>
#include <wtf/Borrow.h>
#include <wtf/NativePromise.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/UniqueRef.h>
#include <wtf/WeakPtr.h>
#include <wtf/cocoa/Entitlements.h>

#include <WebCore/CoreVideoSoftLink.h>

#define MESSAGE_CHECK(assertion) MESSAGE_CHECK_BASE(assertion, m_connectionProxy->connection())
#define MESSAGE_CHECK_COMPLETION(assertion, completion) MESSAGE_CHECK_COMPLETION_BASE(assertion, m_connectionProxy->connection(), completion)

namespace WebKit {
using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(UserMediaCaptureManagerProxy);

// MARK: Frames

Ref<UserMediaCaptureFramePublisher> UserMediaCaptureFramePublisher::create(RefPtr<RemoteVideoFrameObjectHeap>&& heap, ProcessIdentity&& resourceOwner)
{
    return adoptRef(*new UserMediaCaptureFramePublisher(WTF::move(heap), WTF::move(resourceOwner)));
}

UserMediaCaptureFramePublisher::UserMediaCaptureFramePublisher(RefPtr<RemoteVideoFrameObjectHeap>&& heap, ProcessIdentity&& resourceOwner)
    : m_heap(WTF::move(heap))
    , m_resourceOwner(WTF::move(resourceOwner))
{
}

UserMediaCaptureFramePublisher::~UserMediaCaptureFramePublisher() = default;

IOSurfaceRef userMediaCaptureFrameSurface(VideoFrame& frame)
{
    RetainPtr pixelBuffer = frame.pixelBuffer();
    return pixelBuffer ? CVPixelBufferGetIOSurface(pixelBuffer.get()) : nullptr;
}

UserMediaCapturePublishedFrame UserMediaCaptureFramePublisher::publish(VideoFrame& frame)
{
    if (m_resourceOwner)
        frame.setOwnershipIdentity(m_resourceOwner);

    UserMediaCapturePublishedFrame published;
    auto properties = RemoteVideoFrameProxy::properties(frame);
    published.timeValue = properties.presentationTime.timeValue();
    published.timeScale = properties.presentationTime.timeScale();
    published.timeFlags = properties.presentationTime.timeFlags();
    published.isMirrored = properties.isMirrored;
    published.rotation = static_cast<uint16_t>(properties.rotation);
    published.width = properties.size.width();
    published.height = properties.size.height();
    published.pixelFormat = properties.pixelFormat;
    if (auto primaries = properties.colorSpace.primaries) {
        published.hasPrimaries = true;
        published.primaries = static_cast<uint8_t>(*primaries);
    }
    if (auto transfer = properties.colorSpace.transfer) {
        published.hasTransfer = true;
        published.transfer = static_cast<uint8_t>(*transfer);
    }
    if (auto matrix = properties.colorSpace.matrix) {
        published.hasMatrix = true;
        published.matrix = static_cast<uint8_t>(*matrix);
    }
    if (auto fullRange = properties.colorSpace.fullRange) {
        published.hasFullRange = true;
        published.fullRange = *fullRange;
    }
    if (auto chromaLocation = properties.colorSpace.chromaLocation) {
        published.hasChromaLocation = true;
        published.chromaLocation = static_cast<uint8_t>(*chromaLocation);
    }
    published.shouldIgnoreAlpha = properties.shouldIgnoreAlpha;

    if (!m_heap)
        return published;

    auto reference = m_heap->add(frame);
    published.hasReference = true;
    published.identifier = reference.identifier().toUInt64();
    published.version = reference.version();
    return published;
}

// MARK: Microphones

UserMediaCaptureAudioStorage* UserMediaCaptureAudioStorage::create(IPC::Connection& connection, uint64_t sourceIdentifier, const AudioStreamBasicDescription& format)
{
    // Allocate a ring buffer large enough to contain 2 seconds of audio.
    auto result = ProducerSharedCARingBuffer::allocate(format, format.mSampleRate * 2);
    if (!result) {
        RELEASE_LOG_ERROR(WebRTC, "UserMediaCaptureAudioStorage: unable to allocate the ring");
        return nullptr;
    }
    auto [ringBuffer, handle] = WTF::move(*result);
    return &adoptRef(*new UserMediaCaptureAudioStorage(connection, sourceIdentifier, format, WTF::move(ringBuffer), WTF::move(handle))).leakRef();
}

UserMediaCaptureAudioStorage::UserMediaCaptureAudioStorage(Ref<IPC::Connection>&& connection, uint64_t sourceIdentifier, const AudioStreamBasicDescription& format, std::unique_ptr<ProducerSharedCARingBuffer>&& ringBuffer, ConsumerSharedCARingBufferHandle&& handle)
    : m_connection(WTF::move(connection))
    , m_sourceIdentifier(sourceIdentifier)
    , m_format(format)
    , m_ringBuffer(WTF::move(ringBuffer))
    , m_semaphore(makeUnique<IPC::Semaphore>())
    , m_handle(makeUniqueWithoutFastMallocCheck<ConsumerSharedCARingBufferHandle>(WTF::move(handle)))
    , m_frameChunkSize(std::max(WebCore::AudioUtilities::renderQuantumSize, AudioSession::singleton().preferredBufferSize()))
{
}

UserMediaCaptureAudioStorage::~UserMediaCaptureAudioStorage() = default;

void UserMediaCaptureAudioStorage::attachToSink(uint64_t sinkIdentifier)
{
    AudioCaptureSink::attachRing(sinkIdentifier, *m_ringBuffer, m_semaphore->machSemaphore(), m_frameChunkSize);
}

void UserMediaCaptureAudioStorage::sendStorageChanged(int64_t startTimeValue, uint32_t startTimeScale)
{
    if (!m_handle)
        return;
    auto handle = std::exchange(m_handle, nullptr);
    m_connection->send(Messages::RemoteCaptureSampleManager::AudioStorageChanged(RealtimeMediaSourceIdentifier { m_sourceIdentifier }, WTF::move(*handle), m_format, *m_semaphore, MediaTime { startTimeValue, startTimeScale }, m_frameChunkSize), 0);
}

// MARK: Receiver

Ref<UserMediaCaptureManagerProxy> UserMediaCaptureManagerProxy::create(UniqueRef<ConnectionProxy>&& connectionProxy)
{
    Ref proxy = adoptRef(*new UserMediaCaptureManagerProxy(WTF::move(connectionProxy)));
    proxy->m_swiftState = proxy->createSwiftState();
    return proxy;
}

UserMediaCaptureManagerProxy::UserMediaCaptureManagerProxy(UniqueRef<ConnectionProxy>&& connectionProxy)
    : m_connectionProxy(WTF::move(connectionProxy))
{
    m_connectionProxy->addMessageReceiver(Messages::UserMediaCaptureManagerProxy::messageReceiverName(), *this);
}

UserMediaCaptureManagerProxy::~UserMediaCaptureManagerProxy()
{
    m_connectionProxy->removeMessageReceiver(Messages::UserMediaCaptureManagerProxy::messageReceiverName());
    destroySwiftState(m_swiftState);
}

bool UserMediaCaptureManagerProxy::willStartCapture(CaptureDevice::DeviceType type, uint64_t pageIdentifier) const
{
    return m_connectionProxy->willStartCapture(type, PageIdentifier { pageIdentifier });
}

UserMediaCaptureEnvironmentFailure UserMediaCaptureManagerProxy::applyCaptureEnvironment(CaptureDevice::DeviceType deviceType, uint64_t pageIdentifierValue)
{
    if (!m_connectionProxy->setCaptureAttributionString()) {
        RELEASE_LOG_ERROR(WebRTC, "Unable to set capture attribution, failing capture.");
        return UserMediaCaptureEnvironmentFailure::NoAttribution;
    }

#if ENABLE(APP_PRIVACY_REPORT)
    m_connectionProxy->setTCCIdentity();
#endif
#if ENABLE(EXTENSION_CAPABILITIES) && !PLATFORM(IOS_FAMILY_SIMULATOR)
    PageIdentifier pageIdentifier { pageIdentifierValue };
    bool hasValidMediaEnvironmentOrIdentity = m_connectionProxy->setCurrentMediaEnvironment(pageIdentifier) || RealtimeMediaSourceCenter::singleton().hasIdentity();
    if (!hasValidMediaEnvironmentOrIdentity && deviceType == CaptureDevice::DeviceType::Camera
        && WTF::processHasEntitlement("com.apple.developer.web-browser-engine.rendering"_s)) {
        RELEASE_LOG_ERROR(WebRTC, "Unable to set media environment, failing capture.");
        return UserMediaCaptureEnvironmentFailure::NoMediaEnvironment;
    }
#else
    UNUSED_PARAM(deviceType);
    UNUSED_PARAM(pageIdentifierValue);
#endif
    return UserMediaCaptureEnvironmentFailure::None;
}

void UserMediaCaptureManagerProxy::reapplyCaptureEnvironmentForSource(CaptureDevice::DeviceType deviceType, uint64_t pageIdentifier)
{
    if (applyCaptureEnvironment(deviceType, pageIdentifier) != UserMediaCaptureEnvironmentFailure::None)
        RELEASE_LOG_ERROR(WebRTC, "UserMediaCaptureManagerProxy::reapplyCaptureEnvironment failed for a running capture");
#if PLATFORM(IOS_FAMILY)
    m_connectionProxy->providePresentingApplicationPID(PageIdentifier { pageIdentifier });
#endif
}

void UserMediaCaptureManagerProxy::startProducingData(CaptureDevice::DeviceType deviceType, uint64_t pageIdentifier)
{
    m_connectionProxy->startProducingData(deviceType, PageIdentifier { pageIdentifier });
}

void UserMediaCaptureManagerProxy::startMonitoringCaptureDeviceRotation(uint64_t pageIdentifier, const String& persistentID)
{
    m_connectionProxy->startMonitoringCaptureDeviceRotation(PageIdentifier { pageIdentifier }, persistentID);
}

void UserMediaCaptureManagerProxy::stopMonitoringCaptureDeviceRotation(uint64_t pageIdentifier, const String& persistentID)
{
    m_connectionProxy->stopMonitoringCaptureDeviceRotation(PageIdentifier { pageIdentifier }, persistentID);
}

UserMediaCaptureFramePublisher* UserMediaCaptureManagerProxy::framePublisher(bool usesFrameHeap)
{
    RefPtr heap = usesFrameHeap ? m_connectionProxy->remoteVideoFrameObjectHeap() : nullptr;
    return &UserMediaCaptureFramePublisher::create(WTF::move(heap), m_connectionProxy->resourceOwner()).leakRef();
}

CaptureConstraints* UserMediaCaptureManagerProxy::takeConstraints(IPC::CxxDecodedArgument<MediaConstraints>& constraints)
{
    auto value = constraints.take();
    if (!value)
        return nullptr;
    return CaptureConstraints::create(WTF::move(*value));
}

void UserMediaCaptureManagerProxy::microphoneUnitWillStart(uint64_t pageIdentifier)
{
#if PLATFORM(IOS_FAMILY)
    m_connectionProxy->providePresentingApplicationPID(PageIdentifier { pageIdentifier });
#else
    UNUSED_PARAM(pageIdentifier);
#endif
    // FIXME: We should ensure that WebProcess sets up the AudioSession properly before starting to capture microphone.
    Ref session = AudioSession::singleton();
    RELEASE_LOG_ERROR_IF(!session->isActive() || session->category() != AudioSession::CategoryType::PlayAndRecord, WebRTC, "Audio session should be active (%d) and category should be play and record (%d)", session->isActive(), session->category() != AudioSession::CategoryType::PlayAndRecord);

    session->setCategory(AudioSession::CategoryType::PlayAndRecord, AudioSession::Mode::VideoChat, RouteSharingPolicy::Default);
    session->tryToSetActive(true)->whenSettled(RunLoop::mainSingleton(), [](auto&&) { });
}

std::optional<SharedPreferencesForWebProcess> UserMediaCaptureManagerProxy::sharedPreferencesForWebProcess() const
{
    return m_connectionProxy->sharedPreferencesForWebProcess();
}

}

#undef MESSAGE_CHECK_COMPLETION
#undef MESSAGE_CHECK

#endif
