/*
 * Copyright (C) 2013-2023 Apple Inc. All rights reserved.
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

#pragma once

#include <wtf/Platform.h>
#if ENABLE(MEDIA_STREAM) && HAVE(AVCAPTUREDEVICE)

#include <CoreMedia/CMTime.h>
#include <CoreVideo/CVPixelBuffer.h>
#include <WebCore/MeteringMode.h>
#include <cstdint>
#include <wtf/SwiftBridging.h>

OBJC_CLASS AVCaptureSession;
OBJC_CLASS NSData;

// A camera, as CameraCaptureSource.swift implements it with AVFoundation: AVVideoCaptureSource holds one by identifier,
// calls it with plain values, and gets its frames, photos and events through the functions at the end of this file.

namespace WebCore {

enum class CameraCapturePosition : uint8_t {
    Unspecified,
    Front,
    Back,
};

// What the device and the source's state say about its settings and capabilities. Bit i of whiteBalanceModes is
// MeteringMode i.
struct CameraCaptureDeviceValues {
    double minimumFocusDistance { 0 };
    CameraCapturePosition position { CameraCapturePosition::Unspecified };
    uint8_t whiteBalanceModes { 0 };
    MeteringMode whiteBalanceMode { MeteringMode::None };
    bool hasMinimumFocusDistance { false };
    bool hasTorch { false };
    bool isTorchOn { false };
    bool isPortraitEffectActive { false };
    // Whether a torch or white balance change is pending, so that the settings report the requested value.
    bool isTorchChangePending { false };
    bool isWhiteBalanceModeChangePending { false };
};

struct CameraCapturePresetValues {
    double minZoom { 1 };
    double maxZoom { 1 };
    int32_t width { 0 };
    int32_t height { 0 };
    uint32_t frameRateRangeCount { 0 };
    bool hasMinZoom { false };
    bool hasMaxZoom { false };
    bool isEfficient { false };
};

struct CameraCaptureFrameRateRange {
    double minimum { 0 };
    double maximum { 0 };
};

struct CameraCapturePhotoRequest {
    double imageWidth { 0 };
    double imageHeight { 0 };
    // A FillLightMode.
    uint8_t fillLightMode { 0 };
    bool hasFillLightMode { false };
    bool hasImageSize { false };
    bool hasRedEyeReduction { false };
    bool redEyeReduction { false };
};

// The torch mode of the device, as a FillLightMode, if it has a torch.
struct CameraCaptureFillLightMode {
    uint8_t mode { 0 };
    bool hasTorch { false };
};

class SWIFT_PRIVATE_FILEID("WebCore/CameraCaptureSource.swift") CameraCaptureSourceHandle {
public:
    CameraCaptureSourceHandle() = default;
    // A source that cameraCaptureSourceCreate() made (WebCoreSwift-Generated.h), or none for 0.
    explicit CameraCaptureSourceHandle(uint64_t identifier)
        : m_identifier(identifier)
    {
    }

    static void setUseRotationCoordinatorAPI(bool);
    void destroy();
    bool isValid() const { return !!m_identifier; }
    uint64_t identifier() const { return m_identifier; }

    void startProducingData();
    void stopProducingData();
    void startApplyingConstraints();
    void endApplyingConstraints();
    // The source's torch and white balance mode, as RealtimeMediaSource holds them.
    void settingsDidChange(bool whiteBalanceModeChanged, bool torchChanged, bool torch, MeteringMode whiteBalanceMode);
    void setTorchAndWhiteBalanceMode(bool torch, MeteringMode whiteBalanceMode);
    // presetIndex is the preset's index in the presets, or -1 for none. Returns whether the preset changed, rather than
    // the zoom only or nothing.
    bool applyFrameRateAndZoomWithPreset(double frameRate, double zoom, int32_t presetIndex);
    void monitorOrientation(int32_t orientation);
    void orientationChanged(int32_t orientation);
    void rotationAngleForHorizonLevelDisplayChanged(uint16_t rotation);
    void takePhoto(CameraCapturePhotoRequest);

    uint16_t videoFrameRotation() const;
    bool isInterrupted() const;
    double facingModeFitnessScoreAdjustment() const;
    CameraCaptureDeviceValues deviceValues() const;
    CameraCaptureFillLightMode fillLightMode() const;
    uint32_t presetCount() const;
    CameraCapturePresetValues preset(uint32_t index) const;
    CameraCaptureFrameRateRange presetFrameRateRange(uint32_t presetIndex, uint32_t rangeIndex) const;

private:
    uint64_t m_identifier { 0 };
};

// What the source tells AVVideoCaptureSource, on the main thread.
enum class CameraCaptureSourceEvent : uint8_t {
    CaptureFailed,
    // value: whether the source is muted.
    MutedChanged,
    ConfigurationChanged,
    VideoFrameRotationChanged,
    SettingsChanged,
};

enum class CameraCapturePhotoError : uint8_t {
    InternalError,
    SetMaxPhotoDimensionsFailed,
    PipelineReadinessTimeout,
    SessionNotRunning,
    SessionCleared,
    TrackStopped,
    CapturePhotoFailed,
    PhotoOutputFailed,
};

void cameraCaptureSourceDidChange(uint64_t identifier, CameraCaptureSourceEvent, bool value);
bool cameraCaptureSourceIsMuted(uint64_t identifier);
// On the capture queue.
void cameraCaptureSourceDidCaptureFrame(uint64_t identifier, CVPixelBufferRef, CMTime presentationTime, uint16_t rotation, bool isMirrored);
// On any thread.
void cameraCaptureSourceDidCapturePhoto(uint64_t identifier, NSData * WTF_NONNULL);
void cameraCaptureSourceDidFailToCapturePhoto(uint64_t identifier, CameraCapturePhotoError);
#if PLATFORM(IOS) || PLATFORM(VISION)
void cameraCaptureSessionAuthorizeMultipleForegroundAppLayout(AVCaptureSession * WTF_NONNULL);
#endif

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && HAVE(AVCAPTUREDEVICE)
