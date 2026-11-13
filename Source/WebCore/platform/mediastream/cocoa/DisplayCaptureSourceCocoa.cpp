/*
 * Copyright (C) 2017-2024 Apple Inc. All rights reserved.
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

#include "config.h"
#include "DisplayCaptureSourceCocoa.h"

#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

#include "ImageTransferSessionVT.h"
#include "MediaDeviceHashSalts.h"
#include "RealtimeVideoUtilities.h"
#include "VideoFrame.h"
#include <wtf/HashMap.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>

#if HAVE(SCREEN_CAPTURE_KIT)
#include "ScreenCaptureKitCaptureSource.h"
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(DisplayCaptureSourceCocoa);

static HashMap<uint64_t, ThreadSafeWeakPtr<DisplayCaptureSourceCocoa>>& sources()
{
    ASSERT(isMainThread());
    static NeverDestroyed<HashMap<uint64_t, ThreadSafeWeakPtr<DisplayCaptureSourceCocoa>>> sources;
    return sources.get();
}

RefPtr<DisplayCaptureSourceCocoa> DisplayCaptureSourceCocoa::sourceWithIdentifier(uint64_t identifier)
{
    return sources().get(identifier).get();
}

void displayCaptureSourceDidChange(uint64_t identifier, DisplayCaptureSourceEvent event)
{
    if (RefPtr source = DisplayCaptureSourceCocoa::sourceWithIdentifier(identifier))
        source->sourceDidChange(event);
}

bool displayCaptureSourceIsMuted(uint64_t identifier)
{
    RefPtr source = DisplayCaptureSourceCocoa::sourceWithIdentifier(identifier);
    return !source || source->muted();
}

void displayCaptureSourceDidEmitFrame(uint64_t identifier, CMSampleBufferRef sampleBuffer, CGImageRef image, double sampleTime, DisplayCaptureSize size)
{
    if (RefPtr source = DisplayCaptureSourceCocoa::sourceWithIdentifier(identifier))
        source->didEmitFrame(sampleBuffer, image, sampleTime, { size.width, size.height });
}

CMSampleBufferRef displayCaptureSourceCopyCroppedFrame(uint64_t identifier, CMSampleBufferRef frame, DisplayCaptureFloatRect rect, DisplayCaptureFloatSize frameSize)
{
    RefPtr source = DisplayCaptureSourceCocoa::sourceWithIdentifier(identifier);
    if (!source)
        return nullptr;
    return source->croppedFrame(frame, { rect.x, rect.y, rect.width, rect.height }, { frameSize.width, frameSize.height }).leakRef();
}

CaptureSourceOrError DisplayCaptureSourceCocoa::create(const CaptureDevice& device, MediaDeviceHashSalts&& hashSalts, const MediaConstraints* constraints, std::optional<PageIdentifier> pageIdentifier)
{
    switch (device.type()) {
    case CaptureDevice::DeviceType::Screen:
    case CaptureDevice::DeviceType::Window: {
#if HAVE(SCREEN_CAPTURE_KIT)
        if (!ScreenCaptureKitCaptureSource::isAvailable()) {
            ASSERT_NOT_REACHED();
            return { };
        }
        auto deviceID = ScreenCaptureKitCaptureSource::computeDeviceID(device);
        if (!deviceID)
            return CaptureSourceOrError { WTF::move(deviceID).error() };
        return create(DisplayCaptureSourceHandle::create(device.type() == CaptureDevice::DeviceType::Window, deviceID.value()), device, WTF::move(hashSalts), constraints, pageIdentifier);
#else
        UNUSED_PARAM(hashSalts);
        UNUSED_PARAM(constraints);
        UNUSED_PARAM(pageIdentifier);
        ASSERT(device.type() == CaptureDevice::DeviceType::Window);
        return { };
#endif
    }
    case CaptureDevice::DeviceType::SystemAudio:
    case CaptureDevice::DeviceType::Microphone:
    case CaptureDevice::DeviceType::Speaker:
    case CaptureDevice::DeviceType::Camera:
    case CaptureDevice::DeviceType::Canvas:
    case CaptureDevice::DeviceType::Unknown:
        ASSERT_NOT_REACHED();
        break;
    }

    return { };
}

CaptureSourceOrError DisplayCaptureSourceCocoa::createMock(const MockDisplayDescription& display, const CaptureDevice& device, MediaDeviceHashSalts&& hashSalts, const MediaConstraints* constraints, std::optional<PageIdentifier> pageIdentifier)
{
    return create(DisplayCaptureSourceHandle::createMock(display), device, WTF::move(hashSalts), constraints, pageIdentifier);
}

CaptureSourceOrError DisplayCaptureSourceCocoa::create(DisplayCaptureSourceHandle handle, const CaptureDevice& device, MediaDeviceHashSalts&& hashSalts, const MediaConstraints* constraints, std::optional<PageIdentifier> pageIdentifier)
{
    auto source = adoptRef(*new DisplayCaptureSourceCocoa(handle, device, WTF::move(hashSalts), pageIdentifier));
    if (constraints) {
        if (auto result = source->applyConstraints(*constraints))
            return CaptureSourceOrError(CaptureSourceError { result->invalidConstraint });
    }

    return CaptureSourceOrError(WTF::move(source));
}

DisplayCaptureSourceCocoa::DisplayCaptureSourceCocoa(DisplayCaptureSourceHandle handle, const CaptureDevice& device, MediaDeviceHashSalts&& hashSalts, std::optional<PageIdentifier> pageIdentifier)
    : RealtimeMediaSource(device, WTF::move(hashSalts), pageIdentifier)
    , m_source(handle)
    , m_userActivity("App nap disabled for screen capture"_s)
{
    sources().add(m_source.identifier(), *this);
}

DisplayCaptureSourceCocoa::~DisplayCaptureSourceCocoa()
{
    sources().remove(m_source.identifier());
    m_source.destroy();

    if (auto callback = std::exchange(m_whenReadyCallback, { })) {
        callOnMainRunLoop([callback = WTF::move(callback)]() mutable {
            callback({ "Source no longer needed"_s, MediaAccessDenialReason::InvalidAccess });
        });
    }
}

const RealtimeMediaSourceCapabilities& DisplayCaptureSourceCocoa::capabilities()
{
    if (!m_capabilities)
        m_capabilities = captureCapabilities(m_source.capabilities(captureSupportedConstraintBits(settings().supportedConstraints())), hashedId(), { });
    return m_capabilities.value();
}

const RealtimeMediaSourceSettings& DisplayCaptureSourceCocoa::settings()
{
    if (!m_currentSettings) {
        auto size = this->size();
        m_currentSettings = captureSettings(m_source.settings(frameRate(), size.width(), size.height()), name(), hashedId(), { });
    }
    return m_currentSettings.value();
}

void DisplayCaptureSourceCocoa::settingsDidChange(OptionSet<RealtimeMediaSourceSettings::Flag> settings)
{
    if (settings.contains(RealtimeMediaSourceSettings::Flag::FrameRate))
        m_source.setFrameRate(frameRate());

    m_currentSettings = { };
}

void DisplayCaptureSourceCocoa::commitConfiguration()
{
    auto& settings = this->settings();
    m_source.commitConfiguration(settings.width(), settings.height(), settings.frameRate());
}

void DisplayCaptureSourceCocoa::startProducingData()
{
    m_userActivity.start();
    auto& settings = this->settings();
    m_source.startProducingData(frameRate(), settings.width(), settings.height(), settings.frameRate());
}

void DisplayCaptureSourceCocoa::stopProducingData()
{
    m_userActivity.stop();
    m_source.stopProducingData();
}

void DisplayCaptureSourceCocoa::endProducingData()
{
    m_source.endProducingData();
}

void DisplayCaptureSourceCocoa::whenReady(CompletionHandler<void(CaptureSourceError&&)>&& callback)
{
    m_whenReadyCallback = WTF::move(callback);
    m_source.whenReady();
}

IntSize DisplayCaptureSourceCocoa::computeResizedVideoFrameSize(IntSize desiredSize, IntSize intrinsicSize)
{
    auto size = DisplayCaptureSourceHandle::resizedVideoFrameSize({ desiredSize.width(), desiredSize.height() }, { intrinsicSize.width(), intrinsicSize.height() });
    return { size.width, size.height };
}

void DisplayCaptureSourceCocoa::setSizeFrameRateAndZoom(const VideoPresetConstraints& constraints)
{
    // We do not need to handle width, height or zoom here since we capture at full size and let each video frame observer resize as needed.
    // FIXME: We should set frameRate according all video frame observers.
    if (constraints.frameRate && *constraints.frameRate > this->frameRate())
        setFrameRate(*constraints.frameRate);
}

void DisplayCaptureSourceCocoa::sourceDidChange(DisplayCaptureSourceEvent event)
{
    switch (event) {
    case DisplayCaptureSourceEvent::CaptureFailed:
        captureFailed();
        return;
    case DisplayCaptureSourceEvent::ConfigurationChanged:
        capturerConfigurationChanged();
        return;
    case DisplayCaptureSourceEvent::Ready:
        if (auto callback = std::exchange(m_whenReadyCallback, { }))
            callback({ });
        return;
    }
}

void DisplayCaptureSourceCocoa::didEmitFrame(CMSampleBufferRef sampleBuffer, CGImageRef image, double sampleTime, IntSize imageSize)
{
    if (intrinsicSize() != imageSize || size() != imageSize) {
        setIntrinsicSize(imageSize);
        setSize(imageSize);
    }

    if (!m_imageTransferSession)
        lazyInitialize(m_imageTransferSession, ImageTransferSessionVT::create(preferedPixelBufferFormat()));

    auto time = MediaTime::createWithDouble(sampleTime);
    RefPtr videoFrame = sampleBuffer ? m_imageTransferSession->createVideoFrame(sampleBuffer, time, size()) : m_imageTransferSession->createVideoFrame(image, time, size());
    if (!videoFrame) {
        ASSERT_NOT_REACHED();
        return;
    }

    VideoFrameTimeMetadata metadata;
    metadata.captureTime = MonotonicTime::now().secondsSinceEpoch();
    videoFrameAvailable(*videoFrame, metadata);
}

RetainPtr<CMSampleBufferRef> DisplayCaptureSourceCocoa::croppedFrame(CMSampleBufferRef frame, const FloatRect& contentRect, const FloatSize& frameSize)
{
    if (!m_cropSession)
        lazyInitialize(m_cropSession, ImageTransferSessionVT::create(preferedPixelBufferFormat()));

    m_cropSession->setCroppingRectangle(contentRect, frameSize);
    return m_cropSession->convertCMSampleBuffer(frame, IntSize { contentRect.size() });
}

double DisplayCaptureSourceCocoa::observedFrameRate() const
{
    return frameRate();
}

void DisplayCaptureSourceCocoa::capturerConfigurationChanged()
{
    m_currentSettings = { };
    m_capabilities = { };
    auto capturerIntrinsicSize = m_source.intrinsicSize();
    IntSize intrinsicSize { capturerIntrinsicSize.width, capturerIntrinsicSize.height };
    if (this->intrinsicSize() != intrinsicSize)
        setIntrinsicSize(intrinsicSize);
    forEachObserver([](auto& observer) {
        observer.sourceConfigurationChanged();
    });
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
