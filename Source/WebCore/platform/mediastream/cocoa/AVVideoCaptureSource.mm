/*
 * Copyright (C) 2013-2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "AVVideoCaptureSource.h"

#if ENABLE(MEDIA_STREAM) && HAVE(AVCAPTUREDEVICE)

#import "FillLightMode.h"
#import "Logging.h"
#import "MediaConstraints.h"
#import "RealtimeMediaSourceCenter.h"
#import "RealtimeMediaSourceSettings.h"
#import "VideoFrameCV.h"
#import "WebCore-Swift.h"
#import <pal/avfoundation/MediaTimeAVFoundation.h>
#import <wtf/HashMap.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/cocoa/VectorCocoa.h>

#if PLATFORM(IOS) || PLATFORM(VISION)
#import <pal/cocoa/AVFoundationSoftLink.h>
#endif

namespace WebCore {

static Lock sourcesLock;

static HashMap<uint64_t, ThreadSafeWeakPtr<AVVideoCaptureSource>>& sources() WTF_REQUIRES_LOCK(sourcesLock)
{
    static NeverDestroyed<HashMap<uint64_t, ThreadSafeWeakPtr<AVVideoCaptureSource>>> sources;
    return sources;
}

RefPtr<AVVideoCaptureSource> AVVideoCaptureSource::sourceWithIdentifier(uint64_t identifier)
{
    Locker locker { sourcesLock };
    return sources().get(identifier).get();
}

static ASCIILiteral photoErrorMessage(CameraCapturePhotoError error)
{
    switch (error) {
    case CameraCapturePhotoError::InternalError:
        return "Internal error"_s;
    case CameraCapturePhotoError::SetMaxPhotoDimensionsFailed:
        return "setMaxPhotoDimensions failed"_s;
    case CameraCapturePhotoError::PipelineReadinessTimeout:
        return "Photo capture timed out waiting for pipeline readiness"_s;
    case CameraCapturePhotoError::SessionNotRunning:
        return "Session not running"_s;
    case CameraCapturePhotoError::SessionCleared:
        return "Session cleared"_s;
    case CameraCapturePhotoError::TrackStopped:
        return "Track stopped"_s;
    case CameraCapturePhotoError::CapturePhotoFailed:
        return "capturePhotoWithSettings failed"_s;
    case CameraCapturePhotoError::PhotoOutputFailed:
        return "AVCapturePhotoOutput failed"_s;
    }
    ASSERT_NOT_REACHED();
    return "Internal error"_s;
}

void cameraCaptureSourceDidChange(uint64_t identifier, CameraCaptureSourceEvent event, bool value)
{
    if (RefPtr source = AVVideoCaptureSource::sourceWithIdentifier(identifier))
        source->sourceDidChange(event, value);
}

bool cameraCaptureSourceIsMuted(uint64_t identifier)
{
    RefPtr source = AVVideoCaptureSource::sourceWithIdentifier(identifier);
    return source && source->muted();
}

void cameraCaptureSourceDidCaptureFrame(uint64_t identifier, CVBufferRef pixelBuffer, CMTime presentationTime, uint16_t rotation, bool isMirrored)
{
    if (RefPtr source = AVVideoCaptureSource::sourceWithIdentifier(identifier))
        source->didCaptureFrame(pixelBuffer, PAL::toMediaTime(presentationTime), static_cast<VideoFrameRotation>(rotation), isMirrored);
}

void cameraCaptureSourceDidCapturePhoto(uint64_t identifier, NSData *data)
{
    if (RefPtr source = AVVideoCaptureSource::sourceWithIdentifier(identifier))
        source->resolvePendingPhotoRequest(makeVector(data), "image/jpeg"_s);
}

void cameraCaptureSourceDidFailToCapturePhoto(uint64_t identifier, CameraCapturePhotoError error)
{
    if (RefPtr source = AVVideoCaptureSource::sourceWithIdentifier(identifier))
        source->rejectPendingPhotoRequest(photoErrorMessage(error));
}

#if PLATFORM(IOS) || PLATFORM(VISION)
void cameraCaptureSessionAuthorizeMultipleForegroundAppLayout(AVCaptureSession *session)
{
    PAL::AVCaptureSessionSetAuthorizedToUseCameraInMultipleForegroundAppLayout(session);
}
#endif

void AVVideoCaptureSource::setUseAVCaptureDeviceRotationCoordinatorAPI(bool value)
{
#if PLATFORM(IOS_FAMILY)
    CameraCaptureSourceHandle::setUseRotationCoordinatorAPI(value);
#else
    UNUSED_PARAM(value);
#endif
}

CaptureSourceOrError AVVideoCaptureSource::create(const CaptureDevice& device, MediaDeviceHashSalts&& hashSalts, const MediaConstraints* constraints, std::optional<PageIdentifier> pageIdentifier)
{
    CameraCaptureSourceHandle handle { cameraCaptureSourceCreate(device.persistentId().createNSString().get()) };
    if (!handle.isValid())
        return CaptureSourceOrError({ "No AVVideoCaptureSource device"_s , MediaAccessDenialReason::PermissionDenied });

    Ref<RealtimeMediaSource> source = adoptRef(*new AVVideoCaptureSource(handle, device, WTF::move(hashSalts), pageIdentifier));

    if (!source->capabilities().width().max() || !source->capabilities().height().max() || !source->capabilities().frameRate().max())
        return CaptureSourceOrError({ "AVVideoCaptureSource device has invalid width, height or frameRate capabilities"_s , MediaAccessDenialReason::PermissionDenied });

    if (constraints) {
        if (auto result = source->applyConstraints(*constraints))
            return CaptureSourceOrError(CaptureSourceError { result->invalidConstraint });
    }

    return WTF::move(source);
}

AVVideoCaptureSource::AVVideoCaptureSource(CameraCaptureSourceHandle handle, const CaptureDevice& device, MediaDeviceHashSalts&& hashSalts, std::optional<PageIdentifier> pageIdentifier)
    : RealtimeVideoCaptureSource(device, WTF::move(hashSalts), pageIdentifier)
    , m_source(handle)
{
    Locker locker { sourcesLock };
    sources().add(m_source.identifier(), *this);
}

AVVideoCaptureSource::~AVVideoCaptureSource()
{
    assertIsCurrent(RunLoop::mainSingleton());
    ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER);

    {
        Locker locker { sourcesLock };
        sources().remove(m_source.identifier());
    }
    m_source.destroy();
}

RetainPtr<NSArray> AVVideoCaptureSource::cameraCaptureDeviceTypes()
{
    ASSERT(isMainThread());
    static NeverDestroyed<RetainPtr<NSMutableArray>> deviceTypes;
    if (!deviceTypes.get()) {
        deviceTypes.get() = adoptNS([[NSMutableArray alloc] initWithCapacity:8]);
        cameraCaptureSourceAddDeviceTypes(deviceTypes.get().get());
    }
    return deviceTypes.get();
}

void AVVideoCaptureSource::sourceDidChange(CameraCaptureSourceEvent event, bool value)
{
    assertIsCurrent(RunLoop::mainSingleton());
    switch (event) {
    case CameraCaptureSourceEvent::CaptureFailed:
        captureFailed();
        return;
    case CameraCaptureSourceEvent::MutedChanged:
        notifyMutedChange(value);
        return;
    case CameraCaptureSourceEvent::ConfigurationChanged:
        configurationChanged();
        return;
    case CameraCaptureSourceEvent::VideoFrameRotationChanged:
        ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER, "rotation is now ", videoFrameRotation());
        notifySettingsDidChangeObservers({ RealtimeMediaSourceSettings::Flag::Width, RealtimeMediaSourceSettings::Flag::Height });
        return;
    case CameraCaptureSourceEvent::SettingsChanged:
        m_currentSettings = std::nullopt;
        return;
    }
}

void AVVideoCaptureSource::didCaptureFrame(CVPixelBufferRef pixelBuffer, const MediaTime& presentationTime, VideoFrameRotation rotation, bool isMirrored)
{
    auto videoFrame = VideoFrameCV::create(presentationTime, isMirrored, rotation, pixelBuffer);
    setIntrinsicSize(expandedIntSize(videoFrame->presentationSize()));
    VideoFrameTimeMetadata metadata;
    metadata.captureTime = MonotonicTime::now().secondsSinceEpoch();
    dispatchVideoFrameToObservers(WTF::move(videoFrame), metadata);
}

void AVVideoCaptureSource::startProducingData()
{
    assertIsCurrent(RunLoop::mainSingleton());
    ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER);
#if ENABLE(EXTENSION_CAPABILITIES)
    auto& mediaEnvironment = RealtimeMediaSourceCenter::singleton().currentMediaEnvironment();
    WARNING_LOG_IF(loggerPtr() && mediaEnvironment.isEmpty(), "Media environment is empty");
    cameraCaptureSourceSetMediaEnvironment(m_source.identifier(), mediaEnvironment.createNSString().get());
#endif
#if ENABLE(APP_PRIVACY_REPORT)
    cameraCaptureSourceSetAssumedIdentity(m_source.identifier(), RealtimeMediaSourceCenter::singleton().identity().get());
#endif
    m_source.startProducingData();
}

void AVVideoCaptureSource::stopProducingData()
{
    assertIsCurrent(RunLoop::mainSingleton());
    ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER);
    m_source.stopProducingData();
}

void AVVideoCaptureSource::startApplyingConstraints()
{
    m_source.startApplyingConstraints();
}

void AVVideoCaptureSource::endApplyingConstraints()
{
    m_source.endApplyingConstraints();
}

void AVVideoCaptureSource::settingsDidChange(OptionSet<RealtimeMediaSourceSettings::Flag> settings)
{
    assertIsCurrent(RunLoop::mainSingleton());
    m_currentSettings = std::nullopt;
    m_source.settingsDidChange(settings.contains(RealtimeMediaSourceSettings::Flag::WhiteBalanceMode), settings.contains(RealtimeMediaSourceSettings::Flag::Torch), torch(), whiteBalanceMode());
}

void AVVideoCaptureSource::configurationChanged()
{
    assertIsCurrent(RunLoop::mainSingleton());
    m_currentSettings = { };
    m_capabilities = { };

    RealtimeMediaSource::configurationChanged();
}

static bool isZoomSupported(const Vector<VideoPreset>& presets)
{
    return std::ranges::any_of(presets, [](auto& preset) {
        return preset.isZoomSupported();
    });
}

static Vector<MeteringMode> whiteBalanceModes(const CameraCaptureDeviceValues& device)
{
    Vector<MeteringMode> modes(ReserveCapacityTag { }, 3);
    for (auto mode : { MeteringMode::Manual, MeteringMode::SingleShot, MeteringMode::Continuous }) {
        if (device.whiteBalanceModes & (1 << static_cast<uint8_t>(mode)))
            modes.append(mode);
    }
    return modes;
}

const RealtimeMediaSourceSettings& AVVideoCaptureSource::settings()
{
    assertIsCurrent(RunLoop::mainSingleton());
    if (m_currentSettings)
        return *m_currentSettings;

    auto device = m_source.deviceValues();

    RealtimeMediaSourceSettings settings;
    switch (device.position) {
    case CameraCapturePosition::Front:
        settings.setFacingMode(VideoFacingMode::User);
        break;
    case CameraCapturePosition::Back:
        settings.setFacingMode(VideoFacingMode::Environment);
        break;
    case CameraCapturePosition::Unspecified:
        settings.setFacingMode(VideoFacingMode::Unknown);
        break;
    }

    settings.setLabel(name());
    settings.setFrameRate(frameRate());

    auto size = this->size();
    if (is90DegreeRotation(videoFrameRotation()))
        size = size.transposedSize();

    settings.setWidth(size.width());
    settings.setHeight(size.height());
    settings.setDeviceId(hashedId());
    settings.setGroupId(hashedGroupId());
    settings.setBackgroundBlur(device.isPortraitEffectActive);

    RealtimeMediaSourceSupportedConstraints supportedConstraints;
    supportedConstraints.setSupportsDeviceId(true);
    supportedConstraints.setSupportsGroupId(true);
    supportedConstraints.setSupportsFacingMode(device.position != CameraCapturePosition::Unspecified);
    supportedConstraints.setSupportsWidth(true);
    supportedConstraints.setSupportsHeight(true);
    supportedConstraints.setSupportsAspectRatio(true);
    supportedConstraints.setSupportsFrameRate(true);
    supportedConstraints.setSupportsBackgroundBlur(true);

    if (isZoomSupported(presets())) {
        supportedConstraints.setSupportsZoom(true);
        settings.setZoom(zoom());
    }

    if (device.whiteBalanceModes) {
        supportedConstraints.setSupportsWhiteBalanceMode(true);
        settings.setWhiteBalanceMode(device.isWhiteBalanceModeChangePending ? whiteBalanceMode() : device.whiteBalanceMode);
    }

    if (device.hasTorch) {
        supportedConstraints.setSupportsTorch(true);
        settings.setTorch(device.isTorchChangePending ? torch() : device.isTorchOn);
    }

#if PLATFORM(IOS_FAMILY)
    supportedConstraints.setSupportsPowerEfficient(true);
    if (canBePowerEfficient())
        settings.setPowerEfficient(m_currentPreset ? m_currentPreset->isEfficient() : false);
#endif
    settings.setSupportedConstraints(supportedConstraints);

    m_currentSettings = WTF::move(settings);

    return *m_currentSettings;
}

const RealtimeMediaSourceCapabilities& AVVideoCaptureSource::capabilities()
{
    assertIsCurrent(RunLoop::mainSingleton());
    if (m_capabilities)
        return *m_capabilities;

    RealtimeMediaSourceCapabilities capabilities(settings().supportedConstraints());
    capabilities.setDeviceId(hashedId());
    capabilities.setGroupId(hashedGroupId());

    auto device = m_source.deviceValues();
    if (device.position == CameraCapturePosition::Front)
        capabilities.addFacingMode(VideoFacingMode::User);
    if (device.position == CameraCapturePosition::Back)
        capabilities.addFacingMode(VideoFacingMode::Environment);

    auto supportedConstraints = settings().supportedConstraints();

#if HAVE(AVCAPTUREDEVICE_MINFOCUSLENGTH)
    if (device.hasMinimumFocusDistance) {
        supportedConstraints.setSupportsFocusDistance(true);
        capabilities.setFocusDistance({ device.minimumFocusDistance / 1000, std::numeric_limits<double>::max() });
    }
#endif // HAVE(AVCAPTUREDEVICE_MINFOCUSLENGTH)

    auto modes = whiteBalanceModes(device);
    if (!modes.isEmpty()) {
        supportedConstraints.setSupportsWhiteBalanceMode(true);
        capabilities.setWhiteBalanceModes(WTF::move(modes));
    }

    if (device.hasTorch) {
        supportedConstraints.setSupportsTorch(true);
        capabilities.setTorch(true);
    }

    capabilities.setBackgroundBlur(device.isPortraitEffectActive ? RealtimeMediaSourceCapabilities::BackgroundBlur::On : RealtimeMediaSourceCapabilities::BackgroundBlur::Off);

#if PLATFORM(IOS_FAMILY)
    supportedConstraints.setSupportsPowerEfficient(true);
    capabilities.setPowerEfficient(canBePowerEfficient());
#endif

    capabilities.setSupportedConstraints(supportedConstraints);
    updateCapabilities(capabilities);

    m_capabilities = WTF::move(capabilities);

    return *m_capabilities;
}

void AVVideoCaptureSource::resolvePendingPhotoRequest(Vector<uint8_t>&& data, const String& mimeType)
{
    Locker lock { m_photoLock };

    if (!m_photoProducer) {
        ERROR_LOG_IF_POSSIBLE(LOGIDENTIFIER, "no photo producer");
        return;
    }

    m_photoProducer->resolve(std::make_pair(WTF::move(data), mimeType));
    m_photoProducer = nullptr;
}

void AVVideoCaptureSource::rejectPendingPhotoRequest(const String& error)
{
    Locker lock { m_photoLock };

    if (!m_photoProducer)
        return;

    ERROR_LOG_IF_POSSIBLE(LOGIDENTIFIER, error);
    m_photoProducer->reject(error);
    m_photoProducer = nullptr;
}

auto AVVideoCaptureSource::takePhotoInternal(PhotoSettings&& photoSettings) -> Ref<TakePhotoNativePromise>
{
    assertIsCurrent(RunLoop::mainSingleton());

    RefPtr<TakePhotoNativePromise> promise;
    {
        Locker lock { m_photoLock };
        if (m_photoProducer) {
            ERROR_LOG_IF_POSSIBLE(LOGIDENTIFIER, "m_photoProducer should be NULL!");
            return TakePhotoNativePromise::createAndReject("Internal error"_s);
        }

        m_photoProducer = makeUnique<TakePhotoNativePromise::Producer>();
        promise = static_cast<Ref<TakePhotoNativePromise>>(*m_photoProducer);
    }

    CameraCapturePhotoRequest request;
    if (photoSettings.fillLightMode) {
        request.hasFillLightMode = true;
        request.fillLightMode = static_cast<uint8_t>(*photoSettings.fillLightMode);
    }
    if (photoSettings.imageHeight && photoSettings.imageWidth) {
        request.hasImageSize = true;
        request.imageWidth = *photoSettings.imageWidth;
        request.imageHeight = *photoSettings.imageHeight;
    }
    if (photoSettings.redEyeReduction) {
        request.hasRedEyeReduction = true;
        request.redEyeReduction = *photoSettings.redEyeReduction;
    }
    m_source.takePhoto(request);

    return promise.releaseNonNull();
}

auto AVVideoCaptureSource::getPhotoCapabilities() -> Ref<PhotoCapabilitiesNativePromise>
{
    assertIsCurrent(RunLoop::mainSingleton());
    if (m_photoCapabilities)
        return PhotoCapabilitiesNativePromise::createAndResolve(*m_photoCapabilities);

    auto capabilities = this->capabilities();
    PhotoCapabilities photoCapabilities;

    auto height = capabilities.height();
    photoCapabilities.imageHeight = { height.max(), height.min(), 1 };

    auto width = capabilities.width();
    photoCapabilities.imageWidth = { width.max(), width.min(), 1 };

    m_photoCapabilities = WTF::move(photoCapabilities);

    return PhotoCapabilitiesNativePromise::createAndResolve(*m_photoCapabilities);
}

auto AVVideoCaptureSource::getPhotoSettings() -> Ref<PhotoSettingsNativePromise>
{
    ASSERT(isMainThread());

    PhotoSettings settings;

    std::optional<FillLightMode> fillLightMode;
    auto torchMode = m_source.fillLightMode();
    if (torchMode.hasTorch)
        fillLightMode = static_cast<FillLightMode>(torchMode.mode);

    auto trackSettings = this->settings();
    settings = { fillLightMode, trackSettings.height(), trackSettings.width(), { } };

    return PhotoSettingsNativePromise::createAndResolve(settings);
}

double AVVideoCaptureSource::facingModeFitnessScoreAdjustment() const
{
    ASSERT(isMainThread());

    auto fitnessScore = m_source.facingModeFitnessScoreAdjustment();
    ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER, captureDevice().label(), " has fitness adjustment ", fitnessScore);
    return fitnessScore;
}

void AVVideoCaptureSource::applyFrameRateAndZoomWithPreset(double requestedFrameRate, double requestedZoom, std::optional<VideoPreset>&& preset)
{
    assertIsCurrent(RunLoop::mainSingleton());
    int32_t presetIndex = preset && preset->formatIndex() ? static_cast<int32_t>(*preset->formatIndex()) : -1;
    if (!m_source.applyFrameRateAndZoomWithPreset(requestedFrameRate, requestedZoom, presetIndex))
        return;

    m_currentPreset = WTF::move(preset);
    if (m_currentPreset)
        setIntrinsicSize({ m_currentPreset->size().width(), m_currentPreset->size().height() });
}

void AVVideoCaptureSource::generatePresets()
{
    Vector<VideoPreset> presets;
    auto count = m_source.presetCount();
    for (uint32_t index = 0; index < count; ++index) {
        auto values = m_source.preset(index);
        Vector<FrameRateRange> frameRates;
        for (uint32_t rangeIndex = 0; rangeIndex < values.frameRateRangeCount; ++rangeIndex) {
            auto range = m_source.presetFrameRateRange(index, rangeIndex);
            frameRates.append({ range.minimum, range.maximum });
        }

        std::optional<double> minZoom;
        if (values.hasMinZoom)
            minZoom = values.minZoom;
        std::optional<double> maxZoom;
        if (values.hasMaxZoom)
            maxZoom = values.maxZoom;
        VideoPreset preset { { values.width, values.height }, WTF::move(frameRates), minZoom, maxZoom, values.isEfficient };
        preset.setFormatIndex(index);
        presets.append(WTF::move(preset));
    }

    setSupportedPresets(WTF::move(presets));
}

void AVVideoCaptureSource::monitorOrientation(OrientationNotifier& notifier)
{
    notifier.addObserver(*this);
    m_source.monitorOrientation(notifier.orientation());
}

void AVVideoCaptureSource::orientationChanged(IntDegrees orientation)
{
    ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER, "orientation = ", orientation);
    m_source.orientationChanged(orientation);
}

void AVVideoCaptureSource::rotationAngleForHorizonLevelDisplayChanged(const String& devicePersistentId, VideoFrameRotation videoFrameRotation)
{
    if (captureDevice().persistentId() != devicePersistentId)
        return;

    m_source.rotationAngleForHorizonLevelDisplayChanged(static_cast<uint16_t>(videoFrameRotation));
}

VideoFrameRotation AVVideoCaptureSource::videoFrameRotation() const
{
    return static_cast<VideoFrameRotation>(m_source.videoFrameRotation());
}

bool AVVideoCaptureSource::interrupted() const
{
    if (m_source.isInterrupted())
        return true;

    return RealtimeMediaSource::interrupted();
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && HAVE(AVCAPTUREDEVICE)
