/*
 * Copyright (C) 2012 Google Inc. All rights reserved.
 * Copyright (C) 2013-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2013 Nokia Corporation and/or its subsidiary(-ies).
 * Copyright (C) 2015 Ericsson AB. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer
 *    in the documentation and/or other materials provided with the
 *    distribution.
 * 3. Neither the name of Google Inc. nor the names of its contributors
 *    may be used to endorse or promote products derived from this
 *    software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"

#if ENABLE(MEDIA_STREAM)
#include "RealtimeMediaSource.h"

#include "CaptureSourceDecisions.h"
#include "JSMeteringMode.h"
#include "Logging.h"
#include "MediaConstraints.h"
#include "MediaConstraintsEvaluation.h"
#include "NotImplemented.h"
#include "RealtimeMediaSourceCapabilities.h"
#include "RealtimeMediaSourceCenter.h"
#include <wtf/CompletionHandler.h>
#include <wtf/MainThread.h>
#include <wtf/MediaTime.h>
#include <wtf/NativePromise.h>
#include <wtf/UUID.h>
#include <wtf/text/StringHash.h>

#if PLATFORM(COCOA)
#include "ImageRotationSessionVT.h"
#include "ImageTransferSessionVT.h"
#include "VideoFrameCV.h"
#endif

#if USE(GSTREAMER)
#include "VideoFrameGStreamer.h"
#endif

namespace WebCore {

struct VideoFrameAdaptor {
    WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(VideoFrameAdaptor);

    VideoFrameAdaptor(IntSize size, double frameRate)
        : size(size)
        , frameRate(frameRate)
    {
    }

    IntSize size;
    double frameRate;

    size_t frameDecimation { 1 };
    size_t frameDecimationCounter { 0 };
#if PLATFORM(COCOA)
    std::unique_ptr<ImageTransferSessionVT> imageTransferSession;
#endif
};

NODELETE static RealtimeMediaSource::Type toSourceType(CaptureDevice::DeviceType type)
{
    switch (type) {
    case CaptureDevice::DeviceType::Microphone:
    case CaptureDevice::DeviceType::SystemAudio:
        return RealtimeMediaSource::Type::Audio;
    case CaptureDevice::DeviceType::Camera:
    case CaptureDevice::DeviceType::Canvas:
    case CaptureDevice::DeviceType::Screen:
    case CaptureDevice::DeviceType::Window:
        return RealtimeMediaSource::Type::Video;
    case CaptureDevice::DeviceType::Unknown:
    case CaptureDevice::DeviceType::Speaker:
        ASSERT_NOT_REACHED();
        return RealtimeMediaSource::Type::Audio;
    }
    ASSERT_NOT_REACHED();
    return RealtimeMediaSource::Type::Audio;
}

RealtimeMediaSourceObserver::RealtimeMediaSourceObserver() = default;

RealtimeMediaSourceObserver::~RealtimeMediaSourceObserver() = default;

RealtimeMediaSource::RealtimeMediaSource(const CaptureDevice& device, MediaDeviceHashSalts&& hashSalts, std::optional<PageIdentifier> pageIdentifier)
    : m_pageIdentifier(pageIdentifier)
    , m_idHashSalts(WTF::move(hashSalts))
    , m_type(toSourceType(device.type()))
    , m_name({ device.label() })
    , m_device(device)
{
    initializeIds();
}

RealtimeMediaSource::~RealtimeMediaSource() = default;

void RealtimeMediaSource::setPersistentId(const String& persistentID)
{
    m_device.setPersistentId(persistentID);
    initializeIds();
}

void RealtimeMediaSource::initializeIds()
{
    if (m_device.persistentId().isEmpty())
        m_device.setPersistentId(createVersion4UUIDString());

    m_hashedID = RealtimeMediaSourceCenter::hashStringWithSalt(m_device.persistentId(), m_idHashSalts.persistentDeviceSalt);
    m_ephemeralHashedID = RealtimeMediaSourceCenter::hashStringWithSalt(m_device.persistentId(), m_idHashSalts.ephemeralDeviceSalt);

    m_hashedGroupId = RealtimeMediaSourceCenter::hashStringWithSalt(m_device.groupId(), m_idHashSalts.ephemeralDeviceSalt);
}

void RealtimeMediaSource::addAudioSampleObserver(AudioSampleObserver& observer)
{
    ASSERT(isMainThread());
    {
        Locker locker { m_audioSampleObserversLock };
        m_audioSampleObservers.add(&observer);
    }
    audioSampleObserversChanged();
}

void RealtimeMediaSource::removeAudioSampleObserver(AudioSampleObserver& observer)
{
    ASSERT(isMainThread());
    {
        Locker locker { m_audioSampleObserversLock };
        m_audioSampleObservers.remove(&observer);
    }
    audioSampleObserversChanged();
}

bool RealtimeMediaSource::hasAudioSampleObservers() const
{
    Locker locker { m_audioSampleObserversLock };
    return !m_audioSampleObservers.isEmpty();
}

void RealtimeMediaSource::addVideoFrameObserver(VideoFrameObserver& observer)
{
    ASSERT(isMainThread());
    Locker locker { m_videoFrameObserversLock };
    m_videoFrameObservers.add(&observer, nullptr);
}

void RealtimeMediaSource::addVideoFrameObserver(VideoFrameObserver& observer, IntSize size, double frameRate)
{
    ASSERT(isMainThread());
    Locker locker { m_videoFrameObserversLock };
    ASSERT(!m_videoFrameObservers.contains(&observer));
    m_videoFrameObservers.add(&observer, makeUnique<VideoFrameAdaptor>(size, frameRate));
    ++m_videoFrameObserversWithAdaptors;
}

void RealtimeMediaSource::removeVideoFrameObserver(VideoFrameObserver& observer)
{
    ASSERT(isMainThread());
    Locker locker { m_videoFrameObserversLock };
    if (auto result = m_videoFrameObservers.take(&observer)) {
        ASSERT(m_videoFrameObserversWithAdaptors);
        --m_videoFrameObserversWithAdaptors;
    }
}

void RealtimeMediaSource::addObserver(RealtimeMediaSourceObserver& observer)
{
    ASSERT(isMainThread());
    m_observers.add(observer);
}

void RealtimeMediaSource::removeObserver(RealtimeMediaSourceObserver& observer)
{
    ASSERT(isMainThread());
    m_observers.remove(observer);
    if (m_observers.isEmptyIgnoringNullReferences())
        stopBeingObserved();
}

void RealtimeMediaSource::setMuted(bool muted)
{
    // Changed m_muted before calling start/stop so muted() will reflect the correct state.
    bool changed = m_muted != muted;

    ALWAYS_LOG_IF(m_logger && changed, LOGIDENTIFIER, muted);
    if (changed && !muted && m_isProducingData) {
        // Let's uninterrupt by doing a stop/start cycle.
        stop();
    }

    m_muted = muted;
    if (muted)
        stop();
    else
        start();

    if (changed)
        notifyMutedObservers();
}

void RealtimeMediaSource::notifyMutedChange(bool muted)
{
    if (m_muted == muted)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, muted);
    m_muted = muted;

    notifyMutedObservers();
}

void RealtimeMediaSource::setInterruptedForTesting(bool interrupted)
{
    notifyMutedChange(interrupted);
}

void RealtimeMediaSource::forEachObserver(NOESCAPE const Function<void(RealtimeMediaSourceObserver&)>& apply)
{
    ASSERT(isMainThread());
    Ref protectedThis { *this };
    m_observers.forEach(apply);
}

void RealtimeMediaSource::forEachVideoFrameObserver(NOESCAPE const Function<void(VideoFrameObserver&)>& apply)
{
    Locker locker { m_videoFrameObserversLock };
    for (auto* observer : m_videoFrameObservers.keys())
        apply(*observer);
}

void RealtimeMediaSource::notifyMutedObservers()
{
    forEachObserver([](auto& observer) {
        observer.sourceMutedChanged();
    });
}

void RealtimeMediaSource::notifySettingsDidChangeObservers(OptionSet<RealtimeMediaSourceSettings::Flag> flags)
{
    ASSERT(isMainThread());

    ++m_settingsCapabilitiesUpdateCount;
    settingsDidChange(flags);

    if (m_pendingSettingsDidChangeNotification)
        return;
    m_pendingSettingsDidChangeNotification = true;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, flags);

    scheduleDeferredTask([this, protectedThis = Ref { *this }] {
        m_pendingSettingsDidChangeNotification = false;
        forEachObserver([](auto& observer) {
            observer.sourceSettingsChanged();
        });
    });
}

void RealtimeMediaSource::updateHasStartedProducingData()
{
    if (m_hasStartedProducingData)
        return;

    // Heap allocations are forbidden on the audio thread for performance reasons so we need to
    // explicitly allow the following allocation(s).
    DisableMallocRestrictionsForCurrentThreadScope disableMallocRestrictions;
    callOnMainThread([protectedThis = Ref { *this }] {
        if (protectedThis->m_hasStartedProducingData)
            return;
        protectedThis->m_hasStartedProducingData = true;
        protectedThis->forEachObserver([&](auto& observer) {
            observer.hasStartedProducingData();
        });
    });
}

VideoFrameRotation RealtimeMediaSource::videoFrameRotation() const
{
    return VideoFrameRotation::None;
}

static RefPtr<VideoFrame> adaptVideoFrame(VideoFrameAdaptor& adaptor, VideoFrame& videoFrame, IntSize desiredSize)
{
#if PLATFORM(COCOA)
    if (!adaptor.imageTransferSession || adaptor.imageTransferSession->pixelFormat() != videoFrame.pixelFormat())
        adaptor.imageTransferSession = ImageTransferSessionVT::create(videoFrame.pixelFormat(), true);

    ASSERT(adaptor.imageTransferSession);
    if (!adaptor.imageTransferSession)
        return nullptr;

    return adaptor.imageTransferSession->convertVideoFrame(videoFrame, desiredSize);
#elif USE(GSTREAMER)
    UNUSED_PARAM(adaptor);
    return reinterpret_cast<VideoFrameGStreamer&>(videoFrame).resizeTo(desiredSize);
#else
    UNUSED_PARAM(adaptor);
    UNUSED_PARAM(videoFrame);
    UNUSED_PARAM(desiredSize);
    notImplemented();
    return nullptr;
#endif
}

IntSize RealtimeMediaSource::computeResizedVideoFrameSize(IntSize desiredSize, IntSize actualSize)
{
    ASSERT(!actualSize.isZero());
    auto size = CaptureSourceDecisions::resizedVideoFrameSize({ desiredSize.width(), desiredSize.height() }, { actualSize.width(), actualSize.height() });
    return { size.width, size.height };
}

void RealtimeMediaSource::videoFrameAvailable(VideoFrame& videoFrame, VideoFrameTimeMetadata metadata)
{
#if !RELEASE_LOG_DISABLED
    ++m_frameCount;

    auto timestamp = MonotonicTime::now();
    auto delta = timestamp - m_lastFrameLogTime;
    if (!m_lastFrameLogTime || delta >= 1_s) {
        if (m_lastFrameLogTime) {
            INFO_LOG_IF(loggerPtr(), LOGIDENTIFIER, m_frameCount, " frames sent in ", delta.value(), " seconds");
            m_frameCount = 0;
        }
        m_lastFrameLogTime = timestamp;
    }
#endif

    updateHasStartedProducingData();

    Locker locker { m_videoFrameObserversLock };

    bool shouldSwapAdaptorSize = false;
    Ref currentVideoFrame = [&] -> Ref<VideoFrame> {
#if PLATFORM(COCOA)
        if (!m_isApplyingRotation || videoFrame.hasNoTransformation())
            return videoFrame;

        if (!m_rotationSession)
            lazyInitialize(m_rotationSession, makeUnique<ImageRotationSessionVT>(m_canUseIOSurface ? ImageRotationSessionVT::ShouldUseIOSurface::Yes : ImageRotationSessionVT::ShouldUseIOSurface::No));

        RefPtr rotatedVideoFrame = m_rotationSession->applyRotation(videoFrame);
        if (!rotatedVideoFrame)
            return videoFrame;

        shouldSwapAdaptorSize = videoFrame.has90DegreeRotation();
        return rotatedVideoFrame.releaseNonNull();
#else
        return videoFrame;
#endif
    }();

    // videoFrameObservers needs to be passed as parameter because if m_videoFrameObservers
    // is used, that confuses the thread safety static analysis, which can't deduce that
    // the lock has been taken by the outer scope of the videoFrameAvailable() method.
    auto deliverFrame = [&] (Ref<VideoFrame>&& frame, VideoFrameTimeMetadata&& frameMetadata,
        HashMap<VideoFrameObserver*, std::unique_ptr<VideoFrameAdaptor>>& videoFrameObservers) {
        for (auto& [key, value] : videoFrameObservers) {
            if (auto* adaptor = value.get()) {
                if (adaptor->frameDecimation > 1 && ++adaptor->frameDecimationCounter % adaptor->frameDecimation)
                    continue;

                adaptor->frameDecimation = CaptureSourceDecisions::frameDecimation(observedFrameRate(), adaptor->frameRate);

                if (!adaptor->size.isZero()) {
                    auto actualSize = expandedIntSize(frame->presentationSize());
                    auto adaptorSize = adaptor->size;
                    if (shouldSwapAdaptorSize)
                        adaptorSize = adaptorSize.transposedSize();
                    auto desiredSize = computeResizedVideoFrameSize(adaptorSize, actualSize);

                    if (desiredSize != actualSize) {
                        if (auto newVideoFrame = adaptVideoFrame(*adaptor, frame, desiredSize)) {
                            key->videoFrameAvailable(*newVideoFrame, frameMetadata);
                            continue;
                        }
                    }
                }
            }
            key->videoFrameAvailable(frame, frameMetadata);
        }
    };

    // Store encoded (H.264, vp9, etc.) video frames to avoid missing the headers when the first observer starts listening.
    if (m_videoFrameObservers.isEmpty() && currentVideoFrame->isEncoded()) {
        // If the encoded format has changed, empty the pending frames, because there's no point on delivering them anymore.
        if (!m_pendingVideoFrames.isEmpty() && !(protect(m_pendingVideoFrames.last().frame)->hasSameEncodedFormat(currentVideoFrame)))
            m_pendingVideoFrames.clear();

        if (m_pendingVideoFrames.size() < maxPendingVideoFramesBeforeAddTrack)
            m_pendingVideoFrames.append(PendingVideoFrame { WTF::move(currentVideoFrame), WTF::move(metadata) });
        else
            ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, "RealtimeMediaSource: Dropping video frame (queue is full) ", m_pendingVideoFrames.size(), " frames");
        return;
    }

    if (!m_pendingVideoFrames.isEmpty()) {
        ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, "RealtimeMediaSource: Delivering ", m_pendingVideoFrames.size(), " queued frame(s) (observer ready)");
        for (auto& pending : m_pendingVideoFrames)
            deliverFrame(WTF::move(pending.frame), WTF::move(pending.metadata), m_videoFrameObservers);
        m_pendingVideoFrames.clear();
    }

    deliverFrame(WTF::move(currentVideoFrame), WTF::move(metadata), m_videoFrameObservers);
}

void RealtimeMediaSource::audioSamplesAvailable(const MediaTime& time, const PlatformAudioData& audioData, const AudioStreamDescription& description, size_t numberOfFrames)
{
    updateHasStartedProducingData();

    Locker locker { m_audioSampleObserversLock };
    for (auto& observer : m_audioSampleObservers)
        observer->audioSamplesAvailable(time, audioData, description, numberOfFrames);
}

void RealtimeMediaSource::start()
{
    if (m_isProducingData || m_isEnded)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER);

    m_isProducingData = true;
    startProducingData();

    if (m_registerOwnerCallback)
        m_registerOwnerCallback(*this, false);

    if (!m_isProducingData)
        return;

    forEachObserver([](auto& observer) {
        observer.sourceStarted();
    });
}

void RealtimeMediaSource::stop()
{
    if (!m_isProducingData || m_isEnded)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER);

    m_isProducingData = false;

    {
        Locker locker { m_videoFrameObserversLock };
        m_pendingVideoFrames.clear();
    }

    stopProducingData();
}

void RealtimeMediaSource::requestToEnd(RealtimeMediaSourceObserver& callingObserver)
{
    bool hasObserverPreventingEnding = false;
    forEachObserver([&](auto& observer) {
        if (observer.preventSourceFromEnding())
            hasObserverPreventingEnding = true;
    });
    if (hasObserverPreventingEnding)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER);
    end(&callingObserver);
}

void RealtimeMediaSource::end(RealtimeMediaSourceObserver* callingObserver)
{
    ASSERT(isMainThread());

    if (m_isEnded)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER);

    Ref protectedThis { *this };

    endProducingData();
    m_isEnded = true;
    didEnd();

    if (m_registerOwnerCallback)
        m_registerOwnerCallback(*this, false);

    forEachObserver([&callingObserver](auto& observer) {
        if (&observer != callingObserver)
            observer.sourceStopped();
    });
}

void RealtimeMediaSource::registerOwnerCallback(OwnerCallback&& callback)
{
    ASSERT(isMainThread());
    ASSERT(!m_registerOwnerCallback);
    m_registerOwnerCallback = WTF::move(callback);
}

void RealtimeMediaSource::captureFailed()
{
    ERROR_LOG_IF(m_logger, LOGIDENTIFIER);

    m_captureDidFailed = true;
    end();
}

std::optional<MediaVideoPresetTable> RealtimeMediaSource::videoPresetTable()
{
    return std::nullopt;
}

void RealtimeMediaSource::setSizeFrameRateAndZoom(const VideoPresetConstraints& constraints)
{
    IntSize size;
    if (constraints.width)
        size.setWidth(*constraints.width);
    if (constraints.height)
        size.setHeight(*constraints.height);
    setSize(size);
    if (constraints.frameRate)
        setFrameRate(*constraints.frameRate);
    if (constraints.zoom)
        setZoom(*constraints.zoom);
}

static RealtimeMediaSource::VideoPresetConstraints videoPresetConstraints(const MediaVideoPresetConstraints& values)
{
    RealtimeMediaSource::VideoPresetConstraints constraints;
    if (values.hasWidth)
        constraints.width = values.width;
    if (values.hasHeight)
        constraints.height = values.height;
    if (values.hasFrameRate)
        constraints.frameRate = values.frameRate;
    if (values.hasZoom)
        constraints.zoom = values.zoom;
    constraints.shouldPreferPowerEfficiency = values.shouldPreferPowerEfficiency;
    return constraints;
}

MediaConstraintsEvaluation RealtimeMediaSource::evaluateConstraints(const MediaConstraints& constraints, MediaConstraintsEvaluationPurpose purpose)
{
    // Constraints with nothing the engine reads leave the source alone: its capabilities and settings aren't read.
    auto needs = mediaConstraintsSourceNeeds(constraints);
    if (!needs.evaluates)
        return { };

    return evaluateMediaConstraints(constraints, {
        mediaConstraintsCapabilities(capabilities()),
        isEphemeral() ? m_ephemeralHashedID : m_hashedID,
        needs.groupId ? settings().groupId() : emptyString(),
        size(),
        frameRate(),
        zoom(),
        volume(),
        sampleRate(),
        sampleSize(),
        discreteSampleRates(),
        discreteSampleSizes(),
        needs.facingMode ? facingModeFitnessScoreAdjustment() : 0,
        deviceType() == CaptureDevice::DeviceType::Camera,
        needs.presets ? videoPresetTable() : std::nullopt,
    }, purpose);
}

std::optional<MediaConstraintType> RealtimeMediaSource::hasAnyInvalidConstraint(const MediaConstraints& constraints)
{
    ASSERT(constraints.isValid);

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER);

    auto evaluation = evaluateConstraints(constraints, MediaConstraintsEvaluationPurpose::FitnessScore);
    if (evaluation.hasInvalidConstraint) {
        ERROR_LOG_IF(m_logger, LOGIDENTIFIER, "failed constraint ", evaluation.invalidConstraint);
        return evaluation.invalidConstraint;
    }

    m_fitnessScore = evaluation.fitnessScore;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, "fitness distance : ", m_fitnessScore);

    return { };
}

RealtimeMediaSource::VideoPresetConstraints RealtimeMediaSource::extractVideoPresetConstraints(const MediaConstraints& constraints)
{
    auto evaluation = evaluateConstraints(constraints, MediaConstraintsEvaluationPurpose::VideoPresetConstraints);
    if (evaluation.hasInvalidConstraint)
        return { };
    return videoPresetConstraints(evaluation.videoPresetConstraints);
}

void RealtimeMediaSource::applyEvaluatedConstraints(const MediaConstraintsEvaluation& evaluation)
{
    if (!evaluation.hasConstraintsToApply)
        return;

    startApplyingConstraints();

    auto presetConstraints = videoPresetConstraints(evaluation.videoPresetConstraints);
    if (presetConstraints.hasConstraints())
        setSizeFrameRateAndZoom(presetConstraints);

    if (evaluation.setsSampleRate)
        setSampleRate(evaluation.sampleRate);
    if (evaluation.setsSampleSize)
        setSampleSize(evaluation.sampleSize);
    if (evaluation.setsVolume)
        setVolume(evaluation.volume);
    if (evaluation.setsEchoCancellation)
        setEchoCancellation(evaluation.echoCancellation);
    if (evaluation.setsFacingMode)
        setFacingMode(static_cast<VideoFacingMode>(evaluation.facingMode));
    if (evaluation.setsWhiteBalanceMode)
        setWhiteBalanceMode(static_cast<MeteringMode>(evaluation.whiteBalanceMode));
    if (evaluation.setsTorch)
        setTorch(evaluation.torch);

    endApplyingConstraints();
}

std::optional<RealtimeMediaSource::ApplyConstraintsError> RealtimeMediaSource::applyConstraints(const MediaConstraints& constraints)
{
    ASSERT(constraints.isValid);

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER);

    auto evaluation = evaluateConstraints(constraints, MediaConstraintsEvaluationPurpose::Application);
    if (evaluation.hasInvalidConstraint) {
        ERROR_LOG_IF(m_logger, LOGIDENTIFIER, "failed constraint ", evaluation.invalidConstraint);
        return ApplyConstraintsError { evaluation.invalidConstraint, "Invalid constraint"_s };
    }

    applyEvaluatedConstraints(evaluation);
    return { };
}

void RealtimeMediaSource::applyConstraints(const MediaConstraints& constraints, ApplyConstraintsHandler&& completionHandler)
{
    completionHandler(applyConstraints(constraints));
}

void RealtimeMediaSource::setSize(const IntSize& size)
{
    if (size == m_size)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, size);
    
    m_size = size;
    notifySettingsDidChangeObservers({ RealtimeMediaSourceSettings::Flag::Width, RealtimeMediaSourceSettings::Flag::Height });
}

const IntSize RealtimeMediaSource::size() const
{
    auto size = CaptureSourceDecisions::resolvedSize({ m_size.width(), m_size.height() }, { m_intrinsicSize.width(), m_intrinsicSize.height() });
    return { size.width, size.height };
}

void RealtimeMediaSource::setIntrinsicSize(const IntSize& intrinsicSize, bool notifyObservers)
{
    if (m_intrinsicSize == intrinsicSize)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, intrinsicSize);

    m_intrinsicSize = intrinsicSize;
    if (notifyObservers) {
        scheduleDeferredTask([this, protectedThis = Ref { *this }] {
            notifySettingsDidChangeObservers({ RealtimeMediaSourceSettings::Flag::Width, RealtimeMediaSourceSettings::Flag::Height });
        });
    }
}

IntSize RealtimeMediaSource::intrinsicSize() const
{
    return m_intrinsicSize;
}

void RealtimeMediaSource::setFrameRate(double rate)
{
    if (m_frameRate == rate)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, rate);
    
    m_frameRate = rate;
    notifySettingsDidChangeObservers(RealtimeMediaSourceSettings::Flag::FrameRate);
}

void RealtimeMediaSource::setZoom(double zoom)
{
    if (m_zoom == zoom)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, zoom);

    m_zoom = zoom;
    notifySettingsDidChangeObservers(RealtimeMediaSourceSettings::Flag::Zoom);
}

void RealtimeMediaSource::setTorch(bool torch)
{
    if (m_torch == torch)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, torch);
    m_torch = torch;
    notifySettingsDidChangeObservers(RealtimeMediaSourceSettings::Flag::Torch);
}


void RealtimeMediaSource::setFacingMode(VideoFacingMode mode)
{
    if (m_facingMode == mode)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, mode);

    m_facingMode = mode;
    notifySettingsDidChangeObservers(RealtimeMediaSourceSettings::Flag::FacingMode);
}

void RealtimeMediaSource::setWhiteBalanceMode(MeteringMode mode)
{
    if (m_whiteBalanceMode == mode)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, mode);

    m_whiteBalanceMode = mode;
    notifySettingsDidChangeObservers(RealtimeMediaSourceSettings::Flag::WhiteBalanceMode);
}

void RealtimeMediaSource::setVolume(double volume)
{
    if (m_volume == volume)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, volume);

    m_volume = volume;
    notifySettingsDidChangeObservers(RealtimeMediaSourceSettings::Flag::Volume);
}

void RealtimeMediaSource::setSampleRate(int rate)
{
    if (m_sampleRate == rate)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, rate);

    m_sampleRate = rate;
    notifySettingsDidChangeObservers(RealtimeMediaSourceSettings::Flag::SampleRate);
}

std::optional<Vector<int>> RealtimeMediaSource::discreteSampleRates() const
{
    return std::nullopt;
}

void RealtimeMediaSource::setSampleSize(int size)
{
    if (m_sampleSize == size)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, size);

    m_sampleSize = size;
    notifySettingsDidChangeObservers(RealtimeMediaSourceSettings::Flag::SampleSize);
}

std::optional<Vector<int>> RealtimeMediaSource::discreteSampleSizes() const
{
    return std::nullopt;
}

void RealtimeMediaSource::setEchoCancellation(bool echoCancellation)
{
    if (m_echoCancellation == echoCancellation)
        return;

    ALWAYS_LOG_IF(m_logger, LOGIDENTIFIER, echoCancellation);
    m_echoCancellation = echoCancellation;
    notifySettingsDidChangeObservers(RealtimeMediaSourceSettings::Flag::EchoCancellation);
}

void RealtimeMediaSource::scheduleDeferredTask(Function<void()>&& function)
{
    ASSERT(function);
    callOnMainThread([protectedThis = Ref { *this }, function = WTF::move(function)] {
        function();
    });
}

const String& RealtimeMediaSource::hashedId() const
{
    ASSERT(!m_hashedID.isEmpty());
    ASSERT(!m_ephemeralHashedID.isEmpty());

    if (isEphemeral())
        return m_ephemeralHashedID;

    return m_hashedID;
}

const MediaDeviceHashSalts& RealtimeMediaSource::deviceIDHashSalts() const
{
    return m_idHashSalts;
}

void RealtimeMediaSource::setType(Type type)
{
    if (type == m_type)
        return;

    m_type = type;

    scheduleDeferredTask([this, protectedThis = Ref { *this }] {
        forEachObserver([](auto& observer) {
            observer.sourceSettingsChanged();
        });
    });
}

auto RealtimeMediaSource::takePhoto(PhotoSettings&&) -> Ref<TakePhotoNativePromise>
{
    return TakePhotoNativePromise::createAndReject("Not supported"_s);
}

auto RealtimeMediaSource::getPhotoCapabilities() -> Ref<PhotoCapabilitiesNativePromise>
{
    return PhotoCapabilitiesNativePromise::createAndReject("Not supported"_s);
}

auto RealtimeMediaSource::getPhotoSettings() -> Ref<PhotoSettingsNativePromise>
{
    return PhotoSettingsNativePromise::createAndReject("Not supported"_s);
}

#if USE(GSTREAMER)
std::pair<GstClockTime, GstClockTime> RealtimeMediaSource::queryCaptureLatency() const
{
    return { GST_CLOCK_TIME_NONE, GST_CLOCK_TIME_NONE };
}
#endif

void RealtimeMediaSource::configurationChanged()
{
    forEachObserver([](auto& observer) {
        observer.sourceConfigurationChanged();
    });
}

void RealtimeMediaSource::setShouldApplyRotation()
{
    ASSERT(isMainThread());

#if PLATFORM(COCOA)
    m_isApplyingRotation = true;
#endif
}

bool RealtimeMediaSource::isApplyingRotation() const
{
    return m_isApplyingRotation;
}

#if !RELEASE_LOG_DISABLED
void RealtimeMediaSource::setLogger(const Logger& newLogger, uint64_t newLogIdentifier)
{
    m_logger = newLogger;
    m_logIdentifier = newLogIdentifier;
    ALWAYS_LOG(LOGIDENTIFIER, m_type, ", ", name(), ", ", m_hashedID, ", ", m_ephemeralHashedID);
}

WTFLogChannel& RealtimeMediaSource::logChannel() const
{
    return LogWebRTC;
}
#endif

String convertEnumerationToString(RealtimeMediaSource::Type enumerationValue)
{
    static const std::array<NeverDestroyed<String>, 2> values {
        MAKE_STATIC_STRING_IMPL("Audio"),
        MAKE_STATIC_STRING_IMPL("Video")
    };
    static_assert(static_cast<size_t>(RealtimeMediaSource::Type::Audio) == 0, "RealtimeMediaSource::Type::Audio is not 0 as expected");
    static_assert(static_cast<size_t>(RealtimeMediaSource::Type::Video) == 1, "RealtimeMediaSource::Type::Video is not 1 as expected");
    ASSERT(static_cast<size_t>(enumerationValue) < std::size(values));
    return values[static_cast<size_t>(enumerationValue)];
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
