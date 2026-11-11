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

// A microphone's end of a web process's track, until the microphone's unit is Swift.
class UserMediaCaptureManagerProxySourceProxy final
    : public RefCounted<UserMediaCaptureManagerProxySourceProxy>
    , public RealtimeMediaSourceObserver
    , private RealtimeMediaSource::AudioSampleObserver
    , public CanMakeCheckedPtr<UserMediaCaptureManagerProxySourceProxy> {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(UserMediaCaptureManagerProxySourceProxy);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(UserMediaCaptureManagerProxySourceProxy);
public:
    static Ref<UserMediaCaptureManagerProxySourceProxy> create(RealtimeMediaSourceIdentifier id, Ref<IPC::Connection>&& connection, Ref<RealtimeMediaSource>&& source) { return adoptRef(*new UserMediaCaptureManagerProxySourceProxy(id, WTF::move(connection), WTF::move(source))); }
    ~UserMediaCaptureManagerProxySourceProxy()
    {
        unobserveMedia();
        m_source->removeObserver(*this);
    }

    void unobserveMedia()
    {
        if (!m_isObservingMedia)
            return;
        m_isObservingMedia = false;

        if (m_usesAudioSink)
            removeAudioSink();
        else
            m_source->removeAudioSampleObserver(*this);
    }

    void observeMedia()
    {
        if (m_isObservingMedia)
            return;
        m_isObservingMedia = true;

        if (m_usesAudioSink) {
            if (!m_audioSink)
                prepareAudioSink(m_source->audioStreamDescription());
            else
                m_source->addAudioCaptureSink(*m_audioSink);
        } else
            m_source->addAudioSampleObserver(*this);
    }

    NODELETE bool isObservingMedia() const { return m_isObservingMedia; }

    NODELETE bool isUsingSource(const RealtimeMediaSource& source) const { return m_source.ptr() == &source; }
    NODELETE RealtimeMediaSource& source() { return m_source; }

    void audioUnitWillStart() final
    {
#if PLATFORM(IOS_FAMILY)
        m_providePresentingApplicationPIDFunction();
#endif
        // FIXME: We should ensure that WebProcess sets up the AudioSession properly before starting to capture microphone.
        Ref session = AudioSession::singleton();
        RELEASE_LOG_ERROR_IF(!session->isActive() || session->category() != AudioSession::CategoryType::PlayAndRecord, WebRTC, "Audio session should be active (%d) and category should be play and record (%d)", session->isActive(), session->category() != AudioSession::CategoryType::PlayAndRecord);

        session->setCategory(AudioSession::CategoryType::PlayAndRecord, AudioSession::Mode::VideoChat, RouteSharingPolicy::Default);
        session->tryToSetActive(true)->whenSettled(RunLoop::mainSingleton(), [](auto&&) { });
    }

    void start()
    {
        // A compromised WebContent process may send StartProducingData repeatedly. Once we are
        // observing, prepareAudioDescription() would race the capture thread's audioSamplesAvailable().
        if (m_isObservingMedia)
            return;

        m_shouldReset = true;
        m_isStopped = false;
        m_source->start();

        if (m_usesAudioSink)
            prepareAudioSink(m_source->audioStreamDescription());
        else if (auto* description = m_source->audioStreamDescription())
            prepareAudioDescription(*description);

        observeMedia();
    }

    void stop()
    {
        m_isStopped = true;
        m_source->stop();

        unobserveMedia();
    }

    void end()
    {
        m_isStopped = true;
        m_isEnded = true;
        m_source->requestToEnd(*this);
    }

    void setIsInBackground(bool value) { m_source->setIsInBackground(value); }

    void queueAndProcessSerialAction(Function<Ref<GenericPromise>()>&& action)
    {
        ASSERT(isMainRunLoop());

        Ref pendingAction = WTF::move(m_pendingAction);
        m_pendingAction = pendingAction->isResolved() ? action() : pendingAction->whenSettled(RunLoop::mainSingleton(), WTF::move(action));
    }

    void applyConstraints(WebCore::MediaConstraints&& constraints, CompletionHandler<void(std::optional<RealtimeMediaSource::ApplyConstraintsError>&&)> callback)
    {
        queueAndProcessSerialAction([weakThis = WeakPtr { *this }, constraints = WTF::move(constraints), callback = WTF::move(callback)]() mutable {
            RefPtr protectedThis = weakThis.get();
            if (!protectedThis) {
                callback(RealtimeMediaSource::ApplyConstraintsError { { }, { } });
                return GenericPromise::createAndResolve();
            }

            protect(protectedThis->m_source)->applyConstraints(constraints, WTF::move(callback));
            return GenericPromise::createAndResolve();
        });
    }

    const WebCore::RealtimeMediaSourceSettings& settings() { return m_source->settings(); }

#if PLATFORM(IOS_FAMILY)
    void setProvidePresentingApplicationPIDFunction(Function<void()>&& providePresentingApplicationPIDFunction)
    {
        m_providePresentingApplicationPIDFunction = WTF::move(providePresentingApplicationPIDFunction);
    }
#endif

private:
    UserMediaCaptureManagerProxySourceProxy(RealtimeMediaSourceIdentifier id, Ref<IPC::Connection>&& connection, Ref<RealtimeMediaSource>&& source)
        : m_id(id)
        , m_connection(WTF::move(connection))
        , m_source(WTF::move(source))
    {
        m_source->addObserver(*this);
        m_usesAudioSink = m_source->canHaveAudioCaptureSinks();
    }

    // CheckedPtr interface
    uint32_t checkedPtrCount() const final { return CanMakeCheckedPtr::checkedPtrCount(); }
    uint32_t checkedPtrCountWithoutThreadCheck() const final { return CanMakeCheckedPtr::checkedPtrCountWithoutThreadCheck(); }
    void incrementCheckedPtrCount() const final { CanMakeCheckedPtr::incrementCheckedPtrCount(); }
    void decrementCheckedPtrCount() const final { CanMakeCheckedPtr::decrementCheckedPtrCount(); }
    void setDidBeginCheckedPtrDeletion() final { CanMakeCheckedPtr::setDidBeginCheckedPtrDeletion(); }

    void sourceStopped() final
    {
        m_connection->send(Messages::UserMediaCaptureManager::SourceStopped(m_id, m_source->captureDidFail()), 0);
    }

    void sourceMutedChanged() final
    {
        m_connection->send(Messages::UserMediaCaptureManager::SourceMutedChanged(m_id, m_source->muted(), m_source->interrupted()), 0);
    }

    void sourceSettingsChanged() final
    {
        m_connection->send(Messages::UserMediaCaptureManager::SourceSettingsChanged(m_id, settings()), 0);
    }

    void sourceConfigurationChanged() final
    {
        Ref source = m_source;
        m_connection->send(Messages::UserMediaCaptureManager::SourceConfigurationChanged(m_id, source->persistentID(), settings(), source->capabilities()), 0);
    }

    void prepareAudioDescription(const AudioStreamDescription& description)
    {
        m_captureSemaphore = makeUnique<IPC::Semaphore>();
        ASSERT(description.platformDescription().type == PlatformDescription::CAAudioStreamBasicType);
        m_description = *std::get<const AudioStreamBasicDescription*>(description.platformDescription().description);

        // Allocate a ring buffer large enough to contain 2 seconds of audio.
        auto result = ProducerSharedCARingBuffer::allocate(*m_description, m_description->sampleRate() * 2);
        RELEASE_ASSERT(result); // FIXME(https://bugs.webkit.org/show_bug.cgi?id=262690): Handle allocation failure.
        auto [ringBuffer, audioHandle] = WTF::move(*result);
        m_ringBuffer = WTF::move(ringBuffer);
        m_audioHandle = WTF::move(audioHandle);
    }

    // The sink the capture unit stores into the ring with on its IO thread, instead of audioSamplesAvailable() (DEV-CAP-1:
    // the ring and the semaphore are made here, on the main thread). Without a format yet, the sink waits for the unit's.
    // The old sink goes first, as its removal waits for the IO thread to finish with the old ring and semaphore.
    void prepareAudioSink(const AudioStreamDescription* description)
    {
        ASSERT(isMainRunLoop());
        removeAudioSink();
        std::optional<AudioStreamBasicDescription> format;
        if (description) {
            prepareAudioDescription(*description);
            m_frameChunkSize = std::max(WebCore::AudioUtilities::renderQuantumSize, AudioSession::singleton().preferredBufferSize());
            format = m_description->streamDescription();
        }
        m_audioSink = makeUnique<WebCore::AudioCaptureSink>(WebCore::AudioCaptureSink::Kind::Producer, format.value_or(AudioStreamBasicDescription { }));
        if (format)
            m_audioSink->attachRing(*m_ringBuffer, m_captureSemaphore->machSemaphore(), m_frameChunkSize);
        m_audioSink->setStartedHandler([weakThis = WeakPtr { *this }](int64_t value, uint32_t scale) {
            if (RefPtr protectedThis = weakThis.get())
                protectedThis->audioSinkStarted(MediaTime { value, scale });
        });
        m_audioSink->setFormatChangedHandler([weakThis = WeakPtr { *this }] {
            if (RefPtr protectedThis = weakThis.get(); protectedThis && protectedThis->m_audioSink)
                protectedThis->prepareAudioSink(protectedThis->m_source->audioStreamDescription());
        });
        if (m_isObservingMedia)
            m_source->addAudioCaptureSink(*m_audioSink);
    }

    void removeAudioSink()
    {
        if (!m_audioSink)
            return;
        m_source->removeAudioCaptureSink(*m_audioSink);
        m_audioSink = nullptr;
    }

    // The first quantum the sink stored: the ring's start time, as audioSamplesAvailable() reset the storage.
    void audioSinkStarted(const MediaTime& time)
    {
        if (!m_audioHandle)
            return;
        m_startTime = time;
        m_connection->send(Messages::RemoteCaptureSampleManager::AudioStorageChanged(m_id, WTF::move(*m_audioHandle), *m_description, *m_captureSemaphore, m_startTime, m_frameChunkSize), 0);
        m_audioHandle = { };
    }

    // May get called on a background thread.
    void audioSamplesAvailable(const MediaTime& time, const PlatformAudioData& audioData, const AudioStreamDescription& description, size_t numberOfFrames) final
    {
        bool descriptionChanged = m_description != description;
        if (descriptionChanged || m_shouldReset) {
            m_shouldReset = false;
            m_writeOffset = 0;
            m_remainingFrameCount = 0;
            m_startTime = time;
            m_frameChunkSize = std::max(WebCore::AudioUtilities::renderQuantumSize, AudioSession::singleton().preferredBufferSize());

            ASSERT(descriptionChanged || m_audioHandle);

            DisableMallocRestrictionsForCurrentThreadScope scope;
            if (descriptionChanged)
                prepareAudioDescription(description);

            m_connection->send(Messages::RemoteCaptureSampleManager::AudioStorageChanged(m_id, WTF::move(*m_audioHandle), *m_description, *m_captureSemaphore, m_startTime, m_frameChunkSize), 0);
            m_audioHandle = { };
        }

        m_ringBuffer->store(downcast<WebAudioBufferList>(audioData).list(), numberOfFrames, m_writeOffset);
        m_writeOffset += numberOfFrames;

        size_t framesToSend = numberOfFrames + m_remainingFrameCount;
        size_t signalCount = framesToSend / m_frameChunkSize;
        m_remainingFrameCount = framesToSend - (signalCount * m_frameChunkSize);
        for (unsigned i = 0; i < signalCount; ++i)
            m_captureSemaphore->signal();
    }

    bool preventSourceFromEnding()
    {
        // Do not allow the source to end if we are still using it.
        return !m_isEnded;
    }

    bool m_isObservingMedia { false };
    bool m_isStopped { false };
    bool m_isEnded { false };
    std::atomic<bool> m_shouldReset { false };
    // A microphone of the GPU process stores into the ring on its IO thread (WebCore::AudioCaptureSink).
    bool m_usesAudioSink { false };
    std::unique_ptr<WebCore::AudioCaptureSink> m_audioSink;

    RealtimeMediaSourceIdentifier m_id;
    const Ref<IPC::Connection> m_connection;
    const Ref<RealtimeMediaSource> m_source;
    std::unique_ptr<ProducerSharedCARingBuffer> m_ringBuffer;
    std::optional<CAAudioStreamDescription> m_description;
    std::unique_ptr<IPC::Semaphore> m_captureSemaphore;
    std::optional<ConsumerSharedCARingBufferHandle> m_audioHandle;
    int64_t m_writeOffset { 0 };
    int64_t m_remainingFrameCount { 0 };
    size_t m_frameChunkSize { 0 };
    MediaTime m_startTime;
#if PLATFORM(IOS_FAMILY)
    Function<void()> m_providePresentingApplicationPIDFunction;
#endif

    Ref<GenericPromise> m_pendingAction { GenericPromise::createAndResolve() };
};

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

class UserMediaCaptureMicrophones {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(UserMediaCaptureMicrophones);
public:
    explicit UserMediaCaptureMicrophones(UserMediaCaptureManagerProxy::ConnectionProxy& connectionProxy)
        : m_connectionProxy(connectionProxy)
    {
    }

    UserMediaCaptureMicrophoneResult create(RealtimeMediaSourceIdentifier, const CaptureDevice&, MediaDeviceHashSalts&&, const MediaConstraints*, PageIdentifier);
    RefPtr<UserMediaCaptureManagerProxySourceProxy> get(uint64_t identifier) const { return m_proxies.get(identifier); }
    void remove(uint64_t identifier);
    void clone(uint64_t identifier, uint64_t cloneIdentifier, PageIdentifier);
    void clear() { m_proxies.clear(); }
    void forEach(NOESCAPE const Function<void(UserMediaCaptureManagerProxySourceProxy&)>& function)
    {
        for (Ref proxy : m_proxies.values())
            function(proxy);
    }

private:
    UserMediaCaptureManagerProxy::ConnectionProxy& m_connectionProxy;
    HashMap<uint64_t, Ref<UserMediaCaptureManagerProxySourceProxy>> m_proxies;
#if PLATFORM(IOS_FAMILY)
    HashMap<PageIdentifier, ThreadSafeWeakPtr<RealtimeMediaSource>> m_pageMicrophones;
#endif
};

UserMediaCaptureMicrophoneResult UserMediaCaptureMicrophones::create(RealtimeMediaSourceIdentifier identifier, const CaptureDevice& device, MediaDeviceHashSalts&& hashSalts, const MediaConstraints* constraints, PageIdentifier pageIdentifier)
{
    UserMediaCaptureMicrophoneResult result;
    auto sourceOrError = RealtimeMediaSourceCenter::singleton().audioCaptureFactory().createAudioCaptureSource(device, WTF::move(hashSalts), constraints, pageIdentifier);
    if (!sourceOrError) {
        result.errorMessage = WTF::move(sourceOrError.error.errorMessage);
        result.denialReason = static_cast<uint8_t>(sourceOrError.error.denialReason);
        result.invalidConstraint = static_cast<uint8_t>(sourceOrError.error.invalidConstraint);
        return result;
    }

    Ref source = sourceOrError.source();
#if PLATFORM(IOS_FAMILY)
    // FIXME: Support multiple microphones simultaneously.
    if (RefPtr microphoneSource = m_pageMicrophones.get(pageIdentifier).get()) {
        if (microphoneSource->persistentID() != device.persistentId() && !microphoneSource->isEnded()) {
            RELEASE_LOG_ERROR(WebRTC, "Ending microphone source as new source is using a different device.");
            microphoneSource->endImmediatly();
        }
    }
    m_pageMicrophones.set(pageIdentifier, ThreadSafeWeakPtr { source.get() });
#endif

#if !RELEASE_LOG_DISABLED
    source->setLogger(protect(m_connectionProxy.logger()), LoggerHelper::uniqueLogIdentifier());
#endif

    auto proxy = UserMediaCaptureManagerProxySourceProxy::create(identifier, protect(m_connectionProxy.connection()), source.copyRef());
#if PLATFORM(IOS_FAMILY)
    proxy->setProvidePresentingApplicationPIDFunction([&connectionProxy = m_connectionProxy, pageIdentifier] {
        connectionProxy.providePresentingApplicationPID(pageIdentifier);
    });
#endif

    // A microphone is ready once it exists (RealtimeMediaSource::whenReady()).
    auto& settings = proxy->settings();
    auto& capabilities = source->capabilities();
    result.label = settings.label();
    result.deviceId = settings.deviceId();
    result.groupId = settings.groupId();
    result.settings = captureSettingsValues(settings);
    result.capabilityDeviceId = capabilities.deviceId();
    result.capabilityGroupId = capabilities.groupId();
    result.capabilities = captureCapabilityValues(capabilities);
    m_proxies.add(identifier.toUInt64(), WTF::move(proxy));
    return result;
}

void UserMediaCaptureMicrophones::remove(uint64_t identifier)
{
    RefPtr proxy = m_proxies.take(identifier);
#if PLATFORM(IOS_FAMILY)
    if (!proxy)
        return;
    Ref source = proxy->source();
    for (auto& other : m_proxies.values()) {
        if (other->isUsingSource(source))
            return;
    }
    if (auto pageIdentifier = source->pageIdentifier()) {
        if (source.ptr() == m_pageMicrophones.get(*pageIdentifier).get().get())
            m_pageMicrophones.remove(*pageIdentifier);
    }
#else
    UNUSED_VARIABLE(proxy);
#endif
}

void UserMediaCaptureMicrophones::clone(uint64_t identifier, uint64_t cloneIdentifier, PageIdentifier pageIdentifier)
{
    RefPtr proxy = m_proxies.get(identifier);
    if (!proxy)
        return;
    auto cloneProxy = UserMediaCaptureManagerProxySourceProxy::create(RealtimeMediaSourceIdentifier { cloneIdentifier }, protect(m_connectionProxy.connection()), proxy->source().clone());
#if PLATFORM(IOS_FAMILY)
    cloneProxy->setProvidePresentingApplicationPIDFunction([&connectionProxy = m_connectionProxy, pageIdentifier] {
        connectionProxy.providePresentingApplicationPID(pageIdentifier);
    });
#else
    UNUSED_PARAM(pageIdentifier);
#endif
    if (proxy->isObservingMedia())
        cloneProxy->observeMedia();
    m_proxies.add(cloneIdentifier, WTF::move(cloneProxy));
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
    , m_microphones(makeUnique<UserMediaCaptureMicrophones>(m_connectionProxy.get()))
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

UserMediaCaptureMicrophoneResult UserMediaCaptureManagerProxy::createMicrophone(uint64_t identifier, const String& persistentID, CaptureDevice::DeviceType type, const String& label, const String& groupId, bool isDefault, bool isEphemeral, const String& persistentDeviceSalt, const String& ephemeralDeviceSalt, IPC::CxxDecodedArgument<MediaConstraints>& constraintsArgument, uint64_t pageIdentifier)
{
    CaptureDevice device { persistentID, type, label, groupId };
    device.setIsDefault(isDefault);
    device.setIsEphemeral(isEphemeral);
    auto constraints = constraintsArgument.take();
    const MediaConstraints* validConstraints = constraints && constraints->isValid ? &*constraints : nullptr;
    return m_microphones->create(RealtimeMediaSourceIdentifier { identifier }, device, { persistentDeviceSalt, ephemeralDeviceSalt }, validConstraints, PageIdentifier { pageIdentifier });
}

void UserMediaCaptureManagerProxy::microphoneStart(uint64_t identifier, uint64_t pageIdentifier)
{
    RefPtr proxy = m_microphones->get(identifier);
    if (!proxy)
        return;

    Ref source = proxy->source();
    if (auto failure = applyCaptureEnvironment(source->deviceType(), pageIdentifier); failure != UserMediaCaptureEnvironmentFailure::None) {
        if (failure == UserMediaCaptureEnvironmentFailure::NoMediaEnvironment)
            source->captureFailed();
        return;
    }

    startProducingData(source->deviceType(), pageIdentifier);
    proxy->start();
}

void UserMediaCaptureManagerProxy::microphoneStop(uint64_t identifier)
{
    if (RefPtr proxy = m_microphones->get(identifier))
        proxy->stop();
}

void UserMediaCaptureManagerProxy::microphoneEnd(uint64_t identifier)
{
    if (RefPtr proxy = m_microphones->get(identifier))
        proxy->end();
}

void UserMediaCaptureManagerProxy::microphoneRemove(uint64_t identifier)
{
    m_microphones->remove(identifier);
}

void UserMediaCaptureManagerProxy::microphoneClone(uint64_t identifier, uint64_t cloneIdentifier, uint64_t pageIdentifier)
{
    m_microphones->clone(identifier, cloneIdentifier, PageIdentifier { pageIdentifier });
}

void UserMediaCaptureManagerProxy::microphoneApplyConstraints(uint64_t identifier, IPC::CxxDecodedArgument<MediaConstraints>& constraintsArgument)
{
    auto sourceIdentifier = RealtimeMediaSourceIdentifier { identifier };
    RefPtr proxy = m_microphones->get(identifier);
    auto constraints = constraintsArgument.take();
    if (!proxy || !constraints) {
        protect(m_connectionProxy->connection())->send(Messages::UserMediaCaptureManager::ApplyConstraintsFailed(sourceIdentifier, { }, "Unknown source"_s), 0);
        return;
    }

    MESSAGE_CHECK(areCaptureConstraintsWellFormed(*constraints));

    proxy->applyConstraints(WTF::move(*constraints), [sourceIdentifier, proxy, connection = protect(m_connectionProxy->connection())](auto&& result) {
        if (result) {
            connection->send(Messages::UserMediaCaptureManager::ApplyConstraintsFailed(sourceIdentifier, result->invalidConstraint, result->message), 0);
            return;
        }

        connection->send(Messages::UserMediaCaptureManager::ApplyConstraintsSucceeded(sourceIdentifier, proxy->settings()), 0);
    });
}

void UserMediaCaptureManagerProxy::microphoneSetIsInBackground(uint64_t identifier, bool isInBackground)
{
    if (RefPtr proxy = m_microphones->get(identifier))
        proxy->setIsInBackground(isInBackground);
}

void UserMediaCaptureManagerProxy::microphoneReapplyCaptureEnvironment(uint64_t pageIdentifier)
{
    bool reapplied = false;
    m_microphones->forEach([&](auto& proxy) {
        if (reapplied)
            return;
        Ref source = proxy.source();
        auto sourcePageIdentifier = source->pageIdentifier();
        if (!sourcePageIdentifier || sourcePageIdentifier->toUInt64() != pageIdentifier || !source->isProducingData())
            return;
        reapplyCaptureEnvironmentForSource(source->deviceType(), pageIdentifier);
        reapplied = true;
    });
}

void UserMediaCaptureManagerProxy::microphoneClear()
{
    m_microphones->clear();
}

std::optional<SharedPreferencesForWebProcess> UserMediaCaptureManagerProxy::sharedPreferencesForWebProcess() const
{
    return m_connectionProxy->sharedPreferencesForWebProcess();
}

}

#undef MESSAGE_CHECK_COMPLETION
#undef MESSAGE_CHECK

#endif
