/*
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
#import "ScreenCaptureKitCaptureSource.h"

#if HAVE(SCREEN_CAPTURE_KIT)

#import "DisplayCaptureManager.h"
#import "ImageTransferSessionVT.h"
#import "Logging.h"
#import "PlatformMediaSessionManager.h"
#import "PlatformScreen.h"
#import "RealtimeMediaSourceCenter.h"
#import "RealtimeVideoUtilities.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <pal/spi/cg/CoreGraphicsSPI.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/BlockPtr.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/cf/TypeCastsCF.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/darwin/DispatchExtras.h>
#import <wtf/text/StringToIntegerConversion.h>

#import <pal/cf/CoreMediaSoftLink.h>
#import <pal/mac/ScreenCaptureKitSoftLink.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

using namespace WebCore;
@interface WebCoreScreenCaptureKitHelper : NSObject<SCStreamDelegate, SCStreamOutput> {
    WeakPtr<ScreenCaptureKitCaptureSource> _callback;
}

- (instancetype)initWithCallback:(WeakPtr<ScreenCaptureKitCaptureSource>&&)callback;
- (void)disconnect;
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error;
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type;
- (void)outputVideoEffectDidStartForStream:(SCStream *)stream;
- (void)outputVideoEffectDidStopForStream:(SCStream *)stream;
@end

@implementation WebCoreScreenCaptureKitHelper
- (instancetype)initWithCallback:(WeakPtr<ScreenCaptureKitCaptureSource>&&)callback
{
    self = [super init];
    if (!self)
        return self;

    _callback = WTF::move(callback);
    return self;
}

- (void)disconnect
{
    _callback = nullptr;
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error
{
    callOnMainRunLoop([strongSelf = RetainPtr { self }, error = RetainPtr { error }]() mutable {
        if (RefPtr callback = strongSelf->_callback.get())
            callback->sessionFailedWithError(WTF::move(error), "-[SCStreamDelegate stream:didStopWithError:] called"_s);
    });
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type
{
    ASSERT(type == SCStreamOutputTypeScreen);

    if (!sampleBuffer) {
        RELEASE_LOG_ERROR(WebRTC, "stream:didOutputSampleBuffer:ofType: - NULL sample buffer!");
        return;
    }

    callOnMainRunLoop([strongSelf = RetainPtr { self }, sampleBuffer = RetainPtr { sampleBuffer }]() mutable {
        if (RefPtr callback = strongSelf->_callback.get())
            callback->streamDidOutputVideoSampleBuffer(WTF::move(sampleBuffer));
    });
}

- (void)outputVideoEffectDidStartForStream:(SCStream *)stream
{
    callOnMainRunLoop([strongSelf = RetainPtr { self }]() mutable {
        if (RefPtr callback = strongSelf->_callback.get())
            callback->outputVideoEffectDidStartForStream();
    });
}

- (void)outputVideoEffectDidStopForStream:(SCStream *)stream
{
    callOnMainRunLoop([strongSelf = RetainPtr { self }]() mutable {
        if (RefPtr callback = strongSelf->_callback.get())
            callback->outputVideoEffectDidStopForStream();
    });
}

@end

#pragma clang diagnostic pop

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScreenCaptureKitCaptureSource);

ALLOW_NEW_API_WITHOUT_GUARDS_BEGIN

static_assert(static_cast<int64_t>(SCFrameStatusComplete) == static_cast<int64_t>(DisplayCaptureFrameStatus::Complete));
static_assert(static_cast<int64_t>(SCFrameStatusIdle) == static_cast<int64_t>(DisplayCaptureFrameStatus::Idle));
static_assert(static_cast<int64_t>(SCFrameStatusBlank) == static_cast<int64_t>(DisplayCaptureFrameStatus::Blank));
static_assert(static_cast<int64_t>(SCFrameStatusSuspended) == static_cast<int64_t>(DisplayCaptureFrameStatus::Suspended));
static_assert(static_cast<int64_t>(SCFrameStatusStarted) == static_cast<int64_t>(DisplayCaptureFrameStatus::Started));
static_assert(static_cast<int64_t>(SCFrameStatusStopped) == static_cast<int64_t>(DisplayCaptureFrameStatus::Stopped));

bool ScreenCaptureKitCaptureSource::isAvailable()
{
    return PAL::isScreenCaptureKitFrameworkAvailable();
}

std::expected<uint32_t, CaptureSourceError> ScreenCaptureKitCaptureSource::computeDeviceID(const CaptureDevice& device)
{
    ASSERT(device.type() == CaptureDevice::DeviceType::Screen || device.type() == CaptureDevice::DeviceType::Window);

    auto deviceID = parseInteger<uint32_t>(device.persistentId());
    if (!deviceID)
        return makeUnexpected(CaptureSourceError { "Invalid display device ID"_s, MediaAccessDenialReason::PermissionDenied });

    return *deviceID;
}

ScreenCaptureKitCaptureSource::ScreenCaptureKitCaptureSource(CapturerObserver& observer, const CaptureDevice& device, uint32_t deviceID)
    : DisplayCaptureSourceCocoa::Capturer(observer)
    , m_captureDevice(device)
    , m_deviceID(deviceID)
{
}

ScreenCaptureKitCaptureSource::~ScreenCaptureKitCaptureSource()
{
    if (!m_sessionSource)
        ScreenCaptureKitSharingSessionManager::singleton().cancelPendingSessionForDevice(m_captureDevice);

    if (auto callback = std::exchange(m_whenReadyCallback, { })) {
        callOnMainRunLoop([callback = WTF::move(callback)]() mutable {
            callback({ "Source no longer needed"_s , MediaAccessDenialReason::InvalidAccess });
        });
    }
}

void ScreenCaptureKitCaptureSource::whenReady(CompletionHandler<void(CaptureSourceError&&)>&& callback)
{
    switch (m_core.whenReady()) {
    case ScreenCaptureKitCaptureCore::WhenReadyAction::CallNow:
        callback({ });
        return;
    case ScreenCaptureKitCaptureCore::WhenReadyAction::Wait:
        m_whenReadyCallback = WTF::move(callback);
        return;
    case ScreenCaptureKitCaptureCore::WhenReadyAction::StartPrewarming:
        m_whenReadyCallback = WTF::move(callback);
        // We start to get the first frame. The frame size allows to finalize initialization of the source settings.
        startInternal(IsPrewarming::Yes);
        return;
    }
}

bool ScreenCaptureKitCaptureSource::start()
{
    startInternal(IsPrewarming::No);
    return m_core.isRunning();
}

void ScreenCaptureKitCaptureSource::startInternal(IsPrewarming isPrewarming)
{
    ASSERT(isAvailable());
    ASSERT(!m_whenReadyCallback || !m_core.isRunning());

    ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER);

    if (m_core.startInternal(isPrewarming == IsPrewarming::Yes))
        startContentStream();
}

void ScreenCaptureKitCaptureSource::stop()
{
    ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER);

    m_core.stop();
    if (!contentStream())
        return;

    auto stopHandler = makeBlockPtr([weakThis = WeakPtr { *this }] (NSError *error) mutable {
        callOnMainRunLoop([weakThis = WTF::move(weakThis), error = RetainPtr { error }]() mutable {
            if (!error)
                return;

            if (RefPtr protectedThis = weakThis.get())
                protectedThis->sessionFailedWithError(WTF::move(error), "-[SCStream stopCaptureWithCompletionHandler:] failed"_s);
        });
    });
    [protect(contentStream()) stopCaptureWithCompletionHandler:stopHandler.get()];

    // We do not nullify m_sessionSource to keep the picker active since it is helping capture for some fullscreen cases.
    if (m_sessionSource)
        m_contentFilter = m_sessionSource->contentFilter();
}

void ScreenCaptureKitCaptureSource::end()
{
    stop();
}

void ScreenCaptureKitCaptureSource::sessionFailedWithError(RetainPtr<NSError>&& error, const String& message)
{
    ASSERT(isMainThread());

    if (!m_core.isRunning())
        return;

    ERROR_LOG_IF(loggerPtr() && error, LOGIDENTIFIER, message, " with error '", error.get(), "'");
    ERROR_LOG_IF(loggerPtr() && !error, LOGIDENTIFIER, message);

    captureFailed();
    m_sessionSource = nullptr;
}

void ScreenCaptureKitCaptureSource::sessionFilterDidChange(SCContentFilter* contentFilter)
{
    ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER);

#if HAVE(WINDOW_CAPTURE)
    ASSERT(isMainThread());

    std::optional<CaptureDevice> device;
    switch ([contentFilter style]) {
    case SCShareableContentStyleWindow: {
        RetainPtr windows = retainPtr(contentFilter.includedWindows);
        ASSERT([windows count] == 1);
        if (![windows count])
            return;

        RetainPtr window = retainPtr(windows.get()[0]);
        device = CaptureDevice(String::number([window windowID]), CaptureDevice::DeviceType::Window, [window title], emptyString(), true);
        m_content = window;
        break;
    }
    case SCShareableContentStyleDisplay: {
        RetainPtr displays = retainPtr(contentFilter.includedDisplays);
        ASSERT([displays count] == 1);
        if (![displays count])
            return;

        RetainPtr display = retainPtr(displays.get()[0]);
        device = CaptureDevice(String::number([display displayID]), CaptureDevice::DeviceType::Screen, "Screen"_str, emptyString(), true);
        m_content = display;
        break;
    }
    case SCShareableContentStyleNone:
    case SCShareableContentStyleApplication:
    default:
        ASSERT_NOT_REACHED();
        return;
    }
    if (!device) {
        sessionFailedWithError(nil, "Unknown CaptureDevice after content changed"_s);
        return;
    }

    m_captureDevice = device.value();
    m_core.resetIntrinsicSize();
    if (contentStream()) {
        auto completionHandler = makeBlockPtr([weakThis = WeakPtr { *this }] (NSError *error) mutable {
            if (!error)
                return;

            callOnMainRunLoop([weakThis = WTF::move(weakThis), error = RetainPtr { error }]() mutable {
                if (RefPtr protectedThis = weakThis.get())
                    protectedThis->sessionFailedWithError(WTF::move(error), "-[SCStream updateContentFilter:completionHandler:] failed"_s);
            });
        });

        [protect(contentStream()) updateContentFilter:contentFilter completionHandler:completionHandler.get()];
    }

    configurationChanged();
#else
    UNUSED_PARAM(contentFilter);
#endif
}

void ScreenCaptureKitCaptureSource::sessionStreamDidEnd(SCStream* stream)
{
    ASSERT_UNUSED(stream, stream == contentStream());
    sessionFailedWithError(nil, "sessionDidEnd"_s);
}

DisplayCaptureSourceCocoa::DisplayFrameType ScreenCaptureKitCaptureSource::generateFrame()
{
    return m_currentFrame;
}

RetainPtr<SCStreamConfiguration> ScreenCaptureKitCaptureSource::streamConfiguration()
{
    if (m_streamConfiguration)
        return m_streamConfiguration;

    m_streamConfiguration = adoptNS([PAL::allocSCStreamConfigurationInstance() init]);
    [m_streamConfiguration setPixelFormat:preferedPixelBufferFormat()];
    [m_streamConfiguration setShowsCursor:YES];

#if HAVE(WINDOW_CAPTURE)
    [m_streamConfiguration setQueueDepth:6];
    [m_streamConfiguration setColorSpaceName:kCGColorSpaceSRGB];
    [m_streamConfiguration setColorMatrix:kCGDisplayStreamYCbCrMatrix_SMPTE_240M_1995];
    [m_streamConfiguration setPresenterOverlayPrivacyAlertSetting:SCPresenterOverlayAlertSettingNever];
#endif

    auto configuration = m_core.streamConfiguration();
    if (configuration.hasMinimumFrameInterval)
        [m_streamConfiguration setMinimumFrameInterval:PAL::CMTimeMakeWithSeconds(configuration.minimumFrameInterval, 1000)];

    if (configuration.hasSize) {
        [m_streamConfiguration setWidth:configuration.width];
        [m_streamConfiguration setHeight:configuration.height];
    }

    return m_streamConfiguration;
}

void ScreenCaptureKitCaptureSource::startContentStream()
{
    ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER);

    if (!m_captureHelper)
        lazyInitialize(m_captureHelper, adoptNS([[WebCoreScreenCaptureKitHelper alloc] initWithCallback:this]));

    if (!m_contentFilter) {
        m_contentFilter = ScreenCaptureKitSharingSessionManager::singleton().contentFilter(m_captureDevice);
        auto contentRect = [m_contentFilter contentRect];
        m_core.setContentSize(contentRect.size.width, contentRect.size.height, [m_contentFilter pointPixelScale]);

        ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER, "contentFilter.contentRect = ", contentSize(), ", contentFilter.pointPixelScale = ", [m_contentFilter pointPixelScale]);
    }

    if (!m_contentFilter) {
        sessionFailedWithError(nil, "Unknown display device - no content filter"_s);
        return;
    }

    m_sessionSource = ScreenCaptureKitSharingSessionManager::singleton().createSessionSourceForDevice(*this, m_contentFilter.get(), streamConfiguration().get(), (SCStreamDelegate*)m_captureHelper.get());
    if (!m_sessionSource) {
        sessionFailedWithError(nil, "Failed to allocate stream"_s);
        return;
    }

#if HAVE(WINDOW_CAPTURE)
    RetainPtr contentFilter = this->contentFilter();
    switch ([contentFilter style]) {
    case SCShareableContentStyleWindow: {
        RetainPtr windows = [contentFilter includedWindows];
        ASSERT([windows count] == 1);
        if (![windows count])
            return;

        m_content = retainPtr(windows.get()[0]);
        break;
    }
    case SCShareableContentStyleDisplay: {
        RetainPtr displays = [contentFilter includedDisplays];
        ASSERT([displays count] == 1);
        if (![displays count])
            return;

        m_content = retainPtr(displays.get()[0]);
        break;
    }
    case SCShareableContentStyleNone:
    case SCShareableContentStyleApplication:
    default:
        ASSERT_NOT_REACHED();
        return;
        break;
    }
#endif

    RetainPtr contentStream = this->contentStream();
    NSError *error = nil;
    if (![contentStream addStreamOutput:m_captureHelper.get() type:SCStreamOutputTypeScreen sampleHandlerQueue:protect(captureQueue()) error:&error]) {
        sessionFailedWithError(WTF::move(error), "-[SCStream addStreamOutput:type:sampleHandlerQueue:error:] failed"_s);
        return;
    }

    auto completionHandler = makeBlockPtr([weakThis = WeakPtr { *this }, identifier = LOGIDENTIFIER] (NSError *error) mutable {
        callOnMainRunLoop([weakThis = WTF::move(weakThis), error = RetainPtr { error }, identifier]() mutable {
            RefPtr protectedThis = weakThis.get();
            if (!protectedThis)
                return;

            if (error) {
                protectedThis->sessionFailedWithError(WTF::move(error), "-[SCStream startCaptureWithCompletionHandler:] failed"_s);
                return;
            }

            protectedThis->m_core.resetIntrinsicSize();
            protectedThis->configurationChanged();
            ALWAYS_LOG_WITH_THIS_IF_POSSIBLE(protectedThis, identifier, "stream started");
        });
    });

    [contentStream startCaptureWithCompletionHandler:completionHandler.get()];

    m_core.didStartContentStream();
}

IntSize ScreenCaptureKitCaptureSource::intrinsicSize() const
{
    std::optional<CGRect> frame;
#if HAVE(WINDOW_CAPTURE)
    constexpr bool isEmptyContentFrameDefault = false;
    if (m_content) {
        frame = switchOn(m_content.value(),
            [](const RetainPtr<SCDisplay> display) -> CGRect {
                return [display frame];
            },
            [](const RetainPtr<SCWindow> window) -> CGRect {
                return [window frame];
            }
        );
    }
#else
    constexpr bool isEmptyContentFrameDefault = true;
    if (m_contentFilter)
        frame = [m_contentFilter contentRect];
#endif

    auto size = m_core.intrinsicSize(!!frame, frame ? frame->size.width : 0, frame ? frame->size.height : 0, isEmptyContentFrameDefault);
    return { size.width, size.height };
}

FloatSize ScreenCaptureKitCaptureSource::contentSize() const
{
    auto size = m_core.contentSize();
    return { size.width, size.height };
}

void ScreenCaptureKitCaptureSource::updateStreamConfiguration()
{
    ASSERT(contentStream());

    ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER);

    auto completionHandler = makeBlockPtr([weakThis = WeakPtr { *this }] (NSError *error) mutable {
        if (!error)
            return;

        callOnMainRunLoop([weakThis = WTF::move(weakThis), error = RetainPtr { error }]() mutable {
            if (RefPtr protectedThis = weakThis.get())
                protectedThis->sessionFailedWithError(WTF::move(error), "-[SCStream updateConfiguration:completionHandler:] failed"_s);
        });
    });

    [protect(contentStream()) updateConfiguration:streamConfiguration().get() completionHandler:completionHandler.get()];
}

void ScreenCaptureKitCaptureSource::commitConfiguration(const RealtimeMediaSourceSettings& settings)
{
    if (!m_core.commitConfiguration(settings.width(), settings.height(), settings.frameRate()))
        return;

    ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER, IntSize(settings.width(), settings.height()), ", ", settings.frameRate());

    if (!contentStream())
        return;

    m_streamConfiguration = nullptr;
    updateStreamConfiguration();
}

static DisplayCaptureFloatSize presentationSize(CMSampleBufferRef sampleBuffer)
{
    FloatSize size { PAL::CMVideoFormatDescriptionGetPresentationDimensions(protect(PAL::CMSampleBufferGetFormatDescription(sampleBuffer)), true, true) };
    return { size.width(), size.height() };
}

void ScreenCaptureKitCaptureSource::streamDidOutputVideoSampleBuffer(RetainPtr<CMSampleBufferRef> sampleBuffer)
{
    ASSERT(isMainThread());
    ASSERT(sampleBuffer);

    RetainPtr attachments = (__bridge NSArray *)PAL::CMSampleBufferGetSampleAttachmentsArray(sampleBuffer.get(), false);
    DisplayCaptureFrameAttachments frameAttachments;
    [attachments.get() enumerateObjectsUsingBlock:makeBlockPtr([weakThis = WeakPtr { *this }, &frameAttachments](NSDictionary *attachment, NSUInteger, BOOL*) {

        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return;

        if (RetainPtr scaleFactorNumber = dynamic_objc_cast<NSNumber>(attachment[SCStreamFrameInfoScaleFactor]))
            frameAttachments.scaleFactor = [scaleFactorNumber floatValue];

        if (RetainPtr contentScaleNumber = dynamic_objc_cast<NSNumber>(attachment[SCStreamFrameInfoContentScale]))
            frameAttachments.contentScale = [contentScaleNumber floatValue];

        if (RetainPtr contentRectDictionary = dynamic_cf_cast<CFDictionaryRef>(attachment[SCStreamFrameInfoContentRect])) {
            CGRect cgRect;
            if (CGRectMakeWithDictionaryRepresentation(contentRectDictionary.get(), &cgRect)) {
                FloatRect contentRect { cgRect };
                frameAttachments.contentRect = { contentRect.x(), contentRect.y(), contentRect.width(), contentRect.height() };
            }
        }

#if HAVE(WINDOW_CAPTURE)
        if (protectedThis->m_isVideoEffectEnabled) {
            if (RetainPtr overlayRectDictionary = dynamic_cf_cast<CFDictionaryRef>(attachment[SCStreamFrameInfoPresenterOverlayContentRect])) {
                CGRect overlayRect;
                if (CGRectMakeWithDictionaryRepresentation(overlayRectDictionary.get(), &overlayRect))
                    frameAttachments.shouldDisallowReconfiguration = overlayRect.origin.x && overlayRect.origin.y;
            }
        }

        if (!frameAttachments.hasStatus) {
            RetainPtr statusNumber = dynamic_objc_cast<NSNumber>(attachment[SCStreamFrameInfoStatus]);
            if (!statusNumber)
                return;

            frameAttachments.hasStatus = true;
            frameAttachments.status = [statusNumber integerValue];
        }
#endif
    }).get()];

    auto decision = m_core.frameDidArrive(frameAttachments);
    if (decision.isPrewarmingFrame) {
        ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER, "pre-warming, ignoring frame");
        return;
    }
    if (!decision.shouldUseFrame)
        return;

    m_currentFrame = WTF::move(sampleBuffer);

    // FIXME: for now we will rely on cropping to handle large presenter overlay.
    // We might further want to reduce calling updateStreamConfiguration once we crop when user is resizing.
    if (decision.shouldUpdateStreamConfiguration) {
        ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER, "resetting m_contentSize to ", contentSize());
        m_streamConfiguration = nullptr;
        updateStreamConfiguration();
    }

    auto frameSize = presentationSize(m_currentFrame.get());
    if (ScreenCaptureKitCaptureCore::shouldCropFrame(decision.contentRect, frameSize)) {
        if (!m_transferSession)
            lazyInitialize(m_transferSession, ImageTransferSessionVT::create(preferedPixelBufferFormat()));

        FloatRect contentRect { decision.contentRect.x, decision.contentRect.y, decision.contentRect.width, decision.contentRect.height };
        m_transferSession->setCroppingRectangle(contentRect, FloatSize { frameSize.width, frameSize.height });
        if (auto newFrame = m_transferSession->convertCMSampleBuffer(m_currentFrame.get(), IntSize { contentRect.size() })) {
            m_currentFrame = WTF::move(newFrame);
            frameSize = presentationSize(m_currentFrame.get());
        }
    }

    if (m_core.intrinsicSizeDidChange(frameSize)) {
        ALWAYS_LOG_IF_POSSIBLE(LOGIDENTIFIER, "resetting m_intrinsicSize to ", intrinsicSize());
        configurationChanged();
    }

    if (m_core.firstFrameDidArrive() && m_whenReadyCallback)
        m_whenReadyCallback({ });
}

dispatch_queue_t ScreenCaptureKitCaptureSource::captureQueue()
{
    if (!m_captureQueue)
        m_captureQueue = adoptOSObject(dispatch_queue_create("CGDisplayStreamCaptureSource Capture Queue", serialQueueWithAutoreleasePoolAttrSingleton()));

    return m_captureQueue.get();
}

CaptureDevice::DeviceType ScreenCaptureKitCaptureSource::deviceType() const
{
    return m_captureDevice.type();
}

DisplaySurfaceType ScreenCaptureKitCaptureSource::surfaceType() const
{
    return m_captureDevice.type() == CaptureDevice::DeviceType::Screen ? DisplaySurfaceType::Monitor : DisplaySurfaceType::Window;
}

std::optional<CaptureDevice> ScreenCaptureKitCaptureSource::screenCaptureDeviceWithPersistentID(const String& displayIDString)
{
    if (!isAvailable()) {
        RELEASE_LOG_ERROR(WebRTC, "ScreenCaptureKitCaptureSource::screenCaptureDeviceWithPersistentID: screen capture unavailable");
        return std::nullopt;
    }

    auto displayID = parseInteger<uint32_t>(displayIDString);
    if (!displayID) {
        RELEASE_LOG_ERROR(WebRTC, "ScreenCaptureKitCaptureSource::screenCaptureDeviceWithPersistentID: invalid display ID");
        return std::nullopt;
    }

    return CaptureDevice(String::number(displayID.value()), CaptureDevice::DeviceType::Screen, "ScreenCaptureDevice"_s, emptyString(), true);
}

std::optional<CaptureDevice> ScreenCaptureKitCaptureSource::windowCaptureDeviceWithPersistentID(const String& windowIDString)
{
    auto windowID = parseInteger<uint32_t>(windowIDString);
    if (!windowID) {
        RELEASE_LOG_ERROR(WebRTC, "ScreenCaptureKitCaptureSource::windowCaptureDeviceWithPersistentID: invalid window ID");
        return std::nullopt;
    }

    return CaptureDevice(String::number(windowID.value()), CaptureDevice::DeviceType::Window, emptyString(), emptyString(), true);
}

ALLOW_NEW_API_WITHOUT_GUARDS_END

} // namespace WebCore

#endif // HAVE(SCREEN_CAPTURE_KIT)
