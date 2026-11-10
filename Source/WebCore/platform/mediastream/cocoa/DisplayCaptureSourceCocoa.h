/*
 * Copyright (C) 2017-2022 Apple Inc. All rights reserved.
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
#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

#include <WebCore/CaptureDevice.h>
#include <WebCore/DisplayCaptureSourceHandle.h>
#include <WebCore/RealtimeMediaSource.h>
#include <WebCore/RealtimeMediaSourceSettings.h>
#include <WebCore/UserActivity.h>
#include <wtf/CompletionHandler.h>
#include <wtf/RetainPtr.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class FloatRect;
class FloatSize;
class ImageTransferSessionVT;

// A screen or window capture for callers in C++: DisplayCaptureSource.swift captures, and this keeps the
// RealtimeMediaSource state, settings and capabilities, and makes the video frames.
class DisplayCaptureSourceCocoa final
    : public RealtimeMediaSource
    , public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<DisplayCaptureSourceCocoa, WTF::DestructionThread::MainRunLoop> {
    WTF_MAKE_TZONE_ALLOCATED(DisplayCaptureSourceCocoa);
public:
    static CaptureSourceOrError create(const CaptureDevice&, MediaDeviceHashSalts&&, const MediaConstraints*, std::optional<PageIdentifier>);
    // A source for the mock display drawing with this identifier (DisplayCaptureSourceHandle.h).
    static CaptureSourceOrError createMock(uint64_t drawingIdentifier, const CaptureDevice&, MediaDeviceHashSalts&&, const MediaConstraints*, std::optional<PageIdentifier>);
    // The mock display drawing with this identifier changed device.
    static void mockDrawingConfigurationChanged(uint64_t drawingIdentifier);

    WTF_ABSTRACT_THREAD_SAFE_REF_COUNTED_AND_CAN_MAKE_WEAK_PTR_IMPL;
    virtual ~DisplayCaptureSourceCocoa();

    static RefPtr<DisplayCaptureSourceCocoa> sourceWithIdentifier(uint64_t);
    void sourceDidChange(DisplayCaptureSourceEvent);
    void didEmitFrame(CMSampleBufferRef, CGImageRef, double sampleTime, IntSize);
    RetainPtr<CMSampleBufferRef> croppedFrame(CMSampleBufferRef, const FloatRect&, const FloatSize&);

private:
    static CaptureSourceOrError create(DisplayCaptureSourceHandle, uint64_t mockDrawingIdentifier, const CaptureDevice&, MediaDeviceHashSalts&&, const MediaConstraints*, std::optional<PageIdentifier>);
    DisplayCaptureSourceCocoa(DisplayCaptureSourceHandle, uint64_t mockDrawingIdentifier, const CaptureDevice&, MediaDeviceHashSalts&&, std::optional<PageIdentifier>);

    // RealtimeMediaSource
    void startProducingData() final;
    void stopProducingData() final;
    void endProducingData() final;
    void settingsDidChange(OptionSet<RealtimeMediaSourceSettings::Flag>) final;
    bool isCaptureSource() const final { return true; }
    const RealtimeMediaSourceCapabilities& capabilities() final;
    const RealtimeMediaSourceSettings& settings() final;
    CaptureDevice::DeviceType deviceType() const final { return m_source.isWindow() ? CaptureDevice::DeviceType::Window : CaptureDevice::DeviceType::Screen; }
    void endApplyingConstraints() final { commitConfiguration(); }
    IntSize computeResizedVideoFrameSize(IntSize desiredSize, IntSize actualSize) final;
    void setSizeFrameRateAndZoom(const VideoPresetConstraints&) final;
    double observedFrameRate() const final;
    void whenReady(CompletionHandler<void(CaptureSourceError&&)>&&) final;

    ASCIILiteral logClassName() const final { return "DisplayCaptureSourceCocoa"_s; }

    void capturerConfigurationChanged();
    void commitConfiguration();

    DisplayCaptureSourceHandle m_source;
    uint64_t m_mockDrawingIdentifier { 0 };
    std::optional<RealtimeMediaSourceCapabilities> m_capabilities;
    std::optional<RealtimeMediaSourceSettings> m_currentSettings;
    UserActivity m_userActivity;
    CompletionHandler<void(CaptureSourceError&&)> m_whenReadyCallback;

    const std::unique_ptr<ImageTransferSessionVT> m_imageTransferSession;
    const std::unique_ptr<ImageTransferSessionVT> m_cropSession;
};

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
