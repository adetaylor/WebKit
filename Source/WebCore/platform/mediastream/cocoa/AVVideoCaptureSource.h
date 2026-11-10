/*
 * Copyright (C) 2013-2023 Apple Inc. All rights reserved.
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

#pragma once

#include <wtf/Platform.h>
#if ENABLE(MEDIA_STREAM) && HAVE(AVCAPTUREDEVICE)

#include <WebCore/CameraCaptureSourceHandle.h>
#include <WebCore/IntSize.h>
#include <WebCore/OrientationNotifier.h>
#include <WebCore/RealtimeVideoCaptureSource.h>
#include <wtf/Lock.h>

OBJC_CLASS NSArray;

namespace WebCore {

enum class VideoFrameRotation : uint16_t;

// A camera for callers in C++, over the Swift source that CameraCaptureSource.swift implements with AVFoundation.
class AVVideoCaptureSource : public RealtimeVideoCaptureSource {
public:
    static CaptureSourceOrError create(const CaptureDevice&, MediaDeviceHashSalts&&, const MediaConstraints*, std::optional<PageIdentifier>);
    static RetainPtr<NSArray> cameraCaptureDeviceTypes();

    WEBCORE_EXPORT static VideoCaptureFactory& factory();
    WEBCORE_EXPORT static void setUseAVCaptureDeviceRotationCoordinatorAPI(bool);

    static RefPtr<AVVideoCaptureSource> sourceWithIdentifier(uint64_t);

    void sourceDidChange(CameraCaptureSourceEvent, bool value);
    void didCaptureFrame(CVPixelBufferRef, const MediaTime& presentationTime, VideoFrameRotation, bool isMirrored);
    void resolvePendingPhotoRequest(Vector<uint8_t>&&, const String& mimeType);
    void rejectPendingPhotoRequest(const String&);

    void configurationChanged() final;

private:
    AVVideoCaptureSource(CameraCaptureSourceHandle, const CaptureDevice&, MediaDeviceHashSalts&&, std::optional<PageIdentifier>);
    virtual ~AVVideoCaptureSource();

    const RealtimeMediaSourceCapabilities& capabilities() final;
    const RealtimeMediaSourceSettings& settings() final;
    Ref<TakePhotoNativePromise> takePhotoInternal(PhotoSettings&&) final;
    Ref<PhotoCapabilitiesNativePromise> getPhotoCapabilities() final;
    Ref<PhotoSettingsNativePromise> getPhotoSettings() final;
    double facingModeFitnessScoreAdjustment() const final;
    void startProducingData() final;
    void stopProducingData() final;
    void settingsDidChange(OptionSet<RealtimeMediaSourceSettings::Flag>) final;
    void monitorOrientation(OrientationNotifier&) final;
    void startApplyingConstraints() final;
    void endApplyingConstraints() final;
    bool isCaptureSource() const final { return true; }
    CaptureDevice::DeviceType deviceType() const final { return CaptureDevice::DeviceType::Camera; }
    bool interrupted() const final;

    VideoFrameRotation videoFrameRotation() const final;
    void applyFrameRateAndZoomWithPreset(double, double, std::optional<VideoPreset>&&) final;
    void generatePresets() final;
    bool canResizeVideoFrames() const final { return true; }

    // OrientationNotifier::Observer API
    void orientationChanged(IntDegrees orientation) final;
    void rotationAngleForHorizonLevelDisplayChanged(const String&, VideoFrameRotation) final;

#if !RELEASE_LOG_DISABLED
    ASCIILiteral logClassName() const override { return "AVVideoCaptureSource"_s; }
#endif

    mutable CameraCaptureSourceHandle m_source;

    std::optional<RealtimeMediaSourceSettings> m_currentSettings WTF_GUARDED_BY_CAPABILITY(RunLoop::mainSingleton());
    std::optional<RealtimeMediaSourceCapabilities> m_capabilities WTF_GUARDED_BY_CAPABILITY(RunLoop::mainSingleton());
    std::optional<PhotoCapabilities> m_photoCapabilities WTF_GUARDED_BY_CAPABILITY(RunLoop::mainSingleton());
    std::unique_ptr<TakePhotoNativePromise::Producer> m_photoProducer WTF_GUARDED_BY_LOCK(m_photoLock);
    Lock m_photoLock;
    std::optional<VideoPreset> m_currentPreset WTF_GUARDED_BY_CAPABILITY(RunLoop::mainSingleton());
};

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && HAVE(AVCAPTUREDEVICE)
