/**
 * Copyright (C) 2010-2025 Apple Inc. All rights reserved.
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

#include "APIObject.h"
#include "MessageReceiver.h"
#include "UIProcess/API/APIUIClient.h"
#include "UIProcess/ModelElementController.h"
#include "UIProcess/UserMediaPermissionRequestProxy.h"
#include "UIProcess/WebPageProxyInternals.h"
#include "UIProcess/WebPreferences.h"
#include "WebProcess/Geolocation/GeolocationPermissionRequestManager.h"
#include "wtf/AbstractRefCounted.h"
#include "wtf/RefCounted.h"
#include <WebCore/BoxExtents.h>
#include <WebCore/CryptoKeyData.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/LayerTreeAsTextOptions.h>
#include <WebCore/NavigationIdentifier.h>
#include <WebCore/NowPlayingMetadataObserver.h>
#include <WebCore/ProcessSyncData.h>
#include <WebCore/SnapshotIdentifier.h>
#include <WebCore/SpatialBackdropSource.h>
#include <WebCore/WebMediaSessionManagerClient.h>
#include <pal/HysteresisActivity.h>
#include <wtf/ApproximateTime.h>
#include <wtf/CheckedRef.h>
#include <wtf/CompletionHandler.h>
#include <wtf/OptionSet.h>
#include <wtf/ProcessID.h>
#include <wtf/UniqueRef.h>
#include <wtf/WeakHashSet.h>

#if USE(DICTATION_ALTERNATIVES)
#include <WebCore/PlatformTextAlternatives.h>
#endif

#if PLATFORM(IOS_FAMILY)
#include "HardwareKeyboardState.h"
#endif

namespace Inspector {
enum class InspectorTargetType : uint8_t;
}

namespace IPC {
class Decoder;
class SharedBufferReference;
}

namespace API {
class NavigationClient;
}

namespace WebCore {

class CertificateInfo;
class Color;
class ContentFilterUnblockHandler;
class Cursor;
class DataSegment;
class DocumentSyncData;
class FloatPoint;
class FloatQuad;
class FloatRect;
class FloatSize;
class IntPoint;
class IntRect;
class IntSize;
class LayoutPoint;
class ResourceError;
class ResourceLoader;
class ResourceRequest;
class ResourceResponse;
class SecurityOriginData;
class SelectionData;
class SharedMemoryHandle;
class TextCheckingRequestData;
class WebMediaSessionManagerClient;

enum class LayoutMilestone : uint16_t;

enum class ActivityState : uint16_t;
enum class AlternativeTextType : uint8_t;
enum class AutocorrectionResponse : uint8_t;
enum class AutoplayEvent : uint8_t;
enum class AutoplayEventFlags : uint8_t;
enum class CookieConsentDecisionResult : uint8_t;
enum class CrossOriginOpenerPolicyValue : uint8_t;
enum class DOMPasteAccessCategory : uint8_t;
enum class DOMPasteAccessResponse : uint8_t;
enum class DeviceOrientationOrMotionPermissionState : uint8_t;
enum class DiagnosticLoggingDomain : uint8_t;
enum class DragOperation : uint8_t;
enum class FocusDirection : uint8_t;
enum class FrameLoadType : uint8_t;
enum class HasInsecureContent : bool;
enum class InputMode : uint8_t;
enum class LockBackForwardList : bool;
enum class MediaPlaybackTargetContextMockState : uint8_t;
enum class MediaProducerMediaCaptureKind : uint8_t;
enum class MediaProducerMediaState : uint32_t;
enum class MouseEventPolicy : uint8_t;
enum class PermissionState : uint8_t;
enum class ReasonForDismissingAlternativeText : uint8_t;
enum class RenderAsTextFlag : uint16_t;
enum class ResourceResponseSource : uint8_t;
enum class RouteSharingPolicy : uint8_t;
enum class SandboxFlag : uint16_t;
enum class ScrollbarMode : uint8_t;
enum class ShouldGoToHistoryItem : uint8_t;
enum class ShouldSample : bool;
enum class TextAnimationRunMode : uint8_t;
enum class TextCheckingType : uint8_t;
enum class WheelEventProcessingSteps : uint8_t;
enum class WillContinueLoading : bool;
enum class WillInternallyHandleFailure : bool;
enum class WindowProxyProperty : uint8_t;

#if ENABLE(ATTACHMENT_ELEMENT)
enum class AttachmentAssociatedElementType : uint8_t;
#endif

struct ApplePayAMSUIRequest;
struct BackForwardItemIdentifierType;
struct BackForwardFrameItemIdentifierType;
struct CaptureDeviceWithCapabilities;
struct ClientOrigin;
struct ContactInfo;
struct ContactsRequestData;
struct ContentRuleListResults;
struct DataDetectorElementInfo;
struct DataListSuggestionInformation;
struct DateTimeChooserParameters;
struct DiagnosticLoggingDictionary;
struct DictationContextType;
struct DictionaryPopupInfo;
struct DragItem;
struct ElementContext;
struct FileChooserSettings;
struct GrammarDetail;
struct HTMLModelElementCamera;
struct ImageBufferParameters;
struct InspectorOverlayHighlight;
struct LinkIcon;
struct MediaControlsContextMenuItem;
struct MediaDeviceHashSalts;
struct MediaKeySystemRequestIdentifierType;
struct MediaPlayerIdentifierType;
struct MediaSessionIdentifierType;
struct MediaStreamRequest;
struct MediaUsageInfo;
struct MessageWithMessagePorts;
struct MockWebAuthenticationConfiguration;
struct PageIdentifierType;
struct PlaybackTargetClientContextIdentifierType;
struct PromisedAttachmentInfo;
struct RecentSearch;
struct RemoteUserInputEventData;
struct ScrollingNodeIDType;
struct SerializedAttachmentData;
struct ShareDataWithParsedURL;
struct SleepDisablerIdentifierType;
struct TextCheckingResult;
struct TextIndicatorData;
struct TextManipulationItem;
struct TextRecognitionResult;
struct TranslationContextMenuInfo;
struct UserMediaRequestIdentifierType;
struct WindowFeatures;
struct WrappedCryptoKey;
struct DigitalCredentialsRequestData;
struct DigitalCredentialsResponseData;
struct ExceptionData;

#if ENABLE(WRITING_TOOLS)
namespace WritingTools {
enum class Action : uint8_t;
enum class TextSuggestionState : uint8_t;

struct Session;

using TextSuggestionID = WTF::UUID;
}
#endif

template<typename> class ProcessQualified;
template<typename> class RectEdges;

using BackForwardItemIdentifier = ProcessQualified<ObjectIdentifier<BackForwardItemIdentifierType>>;
using BackForwardFrameItemIdentifier = ProcessQualified<ObjectIdentifier<BackForwardFrameItemIdentifierType>>;
using DictationContext = ObjectIdentifier<DictationContextType>;
using IntDegrees = int32_t;
using MediaControlsContextMenuItemID = uint64_t;
using MediaKeySystemRequestIdentifier = ObjectIdentifier<MediaKeySystemRequestIdentifierType>;
using MediaPlayerIdentifier = ObjectIdentifier<MediaPlayerIdentifierType>;
using MediaProducerMediaStateFlags = OptionSet<MediaProducerMediaState>;
using MediaSessionIdentifier = ObjectIdentifier<MediaSessionIdentifierType>;
using PageIdentifier = ObjectIdentifier<PageIdentifierType>;
using PlaybackTargetClientContextIdentifier = ProcessQualified<ObjectIdentifier<PlaybackTargetClientContextIdentifierType>>;
using ResourceLoaderIdentifier = AtomicObjectIdentifier<ResourceLoader>;
using SandboxFlags = OptionSet<SandboxFlag>;
using ScrollingNodeID = ProcessQualified<ObjectIdentifier<ScrollingNodeIDType>>;
using ScrollPosition = IntPoint;
using SleepDisablerIdentifier = ObjectIdentifier<SleepDisablerIdentifierType>;
using UserMediaRequestIdentifier = ObjectIdentifier<UserMediaRequestIdentifierType>;

} // namespace WebCore

namespace WebCore {
class ShareableBitmapHandle;
class ShareableResourceHandle;
struct TextAnimationData;
enum class ElementIdentifierType;

using ElementIdentifier = ObjectIdentifier<ElementIdentifierType>;
}

namespace WebKit {

class CallbackID;
class ContextMenuContextData;
class FrameState;
class GeolocationPermissionRequestManagerProxy;
class ModelElementController;
class NativeWebMouseEvent;
class PageClient;
class UserData;
class UserMediaPermissionRequestProxy;
class WebFrameProxy;
class WebMouseEvent;
class WebPageInspectorController;
class WebPageLoadTiming;
class WebPageProxy;
class WebPopupMenuProxy;
class WebPreferences;
class WebProcessProxy;
class WebURLSchemeHandler;

struct DataDetectionResult;
struct EditorState;
struct FocusedElementInformation;
struct FrameInfoData;
struct GeolocationIdentifierType;
struct InputMethodState;
struct InteractionInformationAtPosition;
struct KeyEventInterpretationContext;
struct ModelIdentifier;
struct NavigationActionData;
struct PDFContextMenu;
struct PDFPluginIdentifierType;
struct PlatformPopupMenuData;
struct PolicyDecision;
struct SessionState;
struct SharedPreferencesForWebProcess;
struct SpeechSynthesisData;
struct TapIdentifierType;
struct TextCheckerRequestType;
struct URLSchemeTaskParameters;
struct UserMessage;
struct ViewWindowCoordinates;
struct WebAutocorrectionContext;
struct WebBackForwardListCounts;
struct WebHitTestResultData;
struct WebNavigationDataStore;
struct WebPageCreationParameters;
struct WebPopupItem;
struct WebSpeechSynthesisVoice;

enum class ColorControlSupportsAlpha : bool;
enum class LoadedWebArchive : bool;
enum class SameDocumentNavigationType : uint8_t;
enum class UndoOrRedo : bool;
enum class WebEventModifier : uint8_t;
enum class WebEventType : uint8_t;

using ActivityStateChangeID = uint64_t;
using GeolocationIdentifier = ObjectIdentifier<GeolocationIdentifierType>;
using LayerHostingContextID = uint32_t;
using PDFPluginIdentifier = ObjectIdentifier<PDFPluginIdentifierType>;
using SpellDocumentTag = int64_t;
using TapIdentifier = ObjectIdentifier<TapIdentifierType>;
using TextCheckerRequestID = ObjectIdentifier<TextCheckerRequestType>;
using WebURLSchemeHandlerIdentifier = ObjectIdentifier<WebURLSchemeHandler>;
using WebUndoStepID = uint64_t;

class WebPageProxyMessageHandler final : public IPC::MessageReceiver {
public:
    static WebPageProxyMessageHandler* create(WebPageProxy* proxy);
    virtual ~WebPageProxyMessageHandler() = default;

    void ref() const final;
    void deref() const final;

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess(IPC::Connection&) const;

    void didChangeInspectorFrontendCount(uint32_t count);

    void createInspectorTarget(IPC::Connection&, const String& targetId, Inspector::InspectorTargetType);
    void destroyInspectorTarget(IPC::Connection&, const String& targetId);
    void sendMessageToInspectorFrontend(const String& targetId, const String& message);

#if ENABLE(VIDEO_PRESENTATION_MODE)
    void setMockVideoPresentationModeEnabled(bool);
#endif

#if ENABLE(ARKIT_INLINE_PREVIEW)
    void modelElementGetCamera(ModelIdentifier, CompletionHandler<void(Expected<WebCore::HTMLModelElementCamera, WebCore::ResourceError>)>&&);
    void modelElementSetCamera(ModelIdentifier, WebCore::HTMLModelElementCamera, CompletionHandler<void(bool)>&&);
    void modelElementIsPlayingAnimation(ModelIdentifier, CompletionHandler<void(Expected<bool, WebCore::ResourceError>)>&&);
    void modelElementSetAnimationIsPlaying(ModelIdentifier, bool, CompletionHandler<void(bool)>&&);
    void modelElementIsLoopingAnimation(ModelIdentifier, CompletionHandler<void(Expected<bool, WebCore::ResourceError>)>&&);
    void modelElementSetIsLoopingAnimation(ModelIdentifier, bool, CompletionHandler<void(bool)>&&);
    void modelElementAnimationDuration(ModelIdentifier, CompletionHandler<void(Expected<Seconds, WebCore::ResourceError>)>&&);
    void modelElementAnimationCurrentTime(ModelIdentifier, CompletionHandler<void(Expected<Seconds, WebCore::ResourceError>)>&&);
    void modelElementSetAnimationCurrentTime(ModelIdentifier, Seconds, CompletionHandler<void(bool)>&&);
    void modelElementHasAudio(ModelIdentifier, CompletionHandler<void(Expected<bool, WebCore::ResourceError>)>&&);
    void modelElementIsMuted(ModelIdentifier, CompletionHandler<void(Expected<bool, WebCore::ResourceError>)>&&);
    void modelElementSetIsMuted(ModelIdentifier, bool, CompletionHandler<void(bool)>&&);
#endif
#if ENABLE(ARKIT_INLINE_PREVIEW_IOS)
    void takeModelElementFullscreen(ModelIdentifier);
    void modelElementSetInteractionEnabled(ModelIdentifier, bool);
#endif
#if ENABLE(ARKIT_INLINE_PREVIEW_MAC)
    void modelElementCreateRemotePreview(const String&, const WebCore::FloatSize&, CompletionHandler<void(Expected<std::pair<String, uint32_t>, WebCore::ResourceError>)>&&);
    void modelElementLoadRemotePreview(const String&, const URL&, CompletionHandler<void(std::optional<WebCore::ResourceError>&&)>&&);
    void modelElementDestroyRemotePreview(const String&);
    void modelElementSizeDidChange(const String&, WebCore::FloatSize, CompletionHandler<void(Expected<MachSendRight, WebCore::ResourceError>)>&&);
    void handleMouseDownForModelElement(const String&, const WebCore::LayoutPoint&, MonotonicTime);
    void handleMouseMoveForModelElement(const String&, const WebCore::LayoutPoint&, MonotonicTime);
    void handleMouseUpForModelElement(const String&, const WebCore::LayoutPoint&, MonotonicTime);
    void modelInlinePreviewUUIDs(CompletionHandler<void(Vector<String>&&)>&&);
#endif

#if ENABLE(APPLE_PAY_AMS_UI)
    void startApplePayAMSUISession(URL&&, WebCore::ApplePayAMSUIRequest&&, CompletionHandler<void(std::optional<bool>&&)>&&);
    void abortApplePayAMSUISession();
#endif

    void closePage();

    void shouldGoToBackForwardListItem(WebCore::BackForwardItemIdentifier, bool inBackForwardCache, CompletionHandler<void(WebCore::ShouldGoToHistoryItem)>&&);
    void shouldGoToBackForwardListItemSync(WebCore::BackForwardItemIdentifier, CompletionHandler<void(WebCore::ShouldGoToHistoryItem)>&&);

    void setHasActiveAnimatedScrolls(bool isRunning);

    void didUpdateActivityState();

#if PLATFORM(IOS_FAMILY)
    void scrollingNodeScrollWillStartScroll(std::optional<WebCore::ScrollingNodeID>);
    void scrollingNodeScrollDidEndScroll(std::optional<WebCore::ScrollingNodeID>);

    void handleAutocorrectionContext(const WebAutocorrectionContext&);
    void didReceivePositionInformation(const InteractionInformationAtPosition&);
    void saveImageToLibrary(WebCore::SharedMemoryHandle&& imageHandle, const String& authorizationToken);
    void setFocusedElementValue(const WebCore::ElementContext&, const String&);
    void setFocusedElementSelectedIndex(const WebCore::ElementContext&, uint32_t index, bool allowMultipleSelection = false);
    void commitPotentialTapFailed();
    void didNotHandleTapAsClick(const WebCore::IntPoint&);
    void didHandleTapAsHover();
    void didCompleteSyntheticClick();
    void disableDoubleTapGesturesDuringTapIfNecessary(TapIdentifier);
    void handleSmartMagnificationInformationForPotentialTap(TapIdentifier, const WebCore::FloatRect& renderRect, bool fitEntireRect, double viewportMinimumScale, double viewportMaximumScale, bool nodeIsRootLevel, bool nodeIsPluginElement);
    void showDataDetectorsUIForPositionInformation(const InteractionInformationAtPosition&);

#if ENABLE(DRAG_SUPPORT)
    void didHandleDragStartRequest(bool started);
    void didHandleAdditionalDragItemsRequest(bool added);
    void willReceiveEditDragSnapshot();
    void didReceiveEditDragSnapshot(std::optional<WebCore::TextIndicatorData>);
#endif
#endif // PLATFORM(IOS_FAMILY)

#if ENABLE(MODEL_PROCESS)
    void didReceiveInteractiveModelElement(std::optional<WebCore::ElementIdentifier>);
#endif

#if ENABLE(DATA_DETECTION)
    void setDataDetectionResult(const DataDetectionResult&);
    void handleClickForDataDetectionResult(const WebCore::DataDetectorElementInfo&, const WebCore::IntPoint&);
#endif

#if PLATFORM(GTK) || PLATFORM(WPE)
    void setInputMethodState(std::optional<InputMethodState>&&);
#endif
        
    void requestScrollToRect(const WebCore::FloatRect& targetRect, const WebCore::FloatPoint& origin);

    void dictationAlternativesAtSelection(CompletionHandler<void(Vector<WebCore::DictationContext>&&)>&&);
    void clearDictationAlternatives(Vector<WebCore::DictationContext>&&);

#if USE(DICTATION_ALTERNATIVES)
    PlatformTextAlternatives *platformDictationAlternatives(WebCore::DictationContext);
#endif

    void dispatchMouseDidMoveOverElementAsynchronously(const NativeWebMouseEvent&);

    void enableAccessibilityForAllProcesses();

#if PLATFORM(COCOA)
    // Called by the web process through a message.
    void registerWebProcessAccessibilityToken(std::span<const uint8_t>);
    void makeFirstResponder();
    void assistiveTechnologyMakeFirstResponder();

#endif

    void pageScaleFactorDidChange(IPC::Connection&, double);
    void viewScaleFactorDidChange(IPC::Connection&, double);
    void pluginScaleFactorDidChange(IPC::Connection&, double);
    void pluginZoomFactorDidChange(IPC::Connection&, double);

    // Find.
    void didGetImageForFindMatch(WebCore::ImageBufferParameters&&, WebCore::ShareableBitmapHandle&& contentImageHandle, uint32_t matchIndex);
    void clearTextIndicator();

#if ENABLE(DRAG_SUPPORT)    
    // Drag and drop support.
#if PLATFORM(COCOA)
    void startDrag(const WebCore::DragItem&, WebCore::ShareableBitmapHandle&& dragImageHandle);
    void setPromisedDataForImage(IPC::Connection&, const String& pasteboardName, WebCore::SharedMemoryHandle&& imageHandle, const String& filename, const String& extension,
        const String& title, const String& url, const String& visibleURL, WebCore::SharedMemoryHandle&& archiveHandle, const String& originIdentifier);
#endif
#if PLATFORM(GTK)
    void startDrag(WebCore::SelectionData&&, OptionSet<WebCore::DragOperation>, std::optional<WebCore::ShareableBitmapHandle>&& dragImage, WebCore::IntPoint&& dragImageHotspot);
#endif
#endif

#if HAVE(VISIBILITY_PROPAGATION_VIEW)
    void didCreateContextInWebProcessForVisibilityPropagation(LayerHostingContextID);
#endif

#if ENABLE(PDF_PLUGIN) && PLATFORM(MAC)
    void showPDFContextMenu(const PDFContextMenu&, PDFPluginIdentifier, CompletionHandler<void(std::optional<int32_t>&&)>&&);
#endif

#if ENABLE(POINTER_LOCK)
    void requestPointerUnlock();
#endif

    void setColorPickerColor(const WebCore::Color&);
    void endColorPicker();

    void didApplyLinkDecorationFiltering(const URL&, const URL&);

    void serializeAndWrapCryptoKey(IPC::Connection&, WebCore::CryptoKeyData&&, CompletionHandler<void(std::optional<Vector<uint8_t>>&&)>&&);
    void unwrapCryptoKey(WebCore::WrappedCryptoKey&&, CompletionHandler<void(std::optional<Vector<uint8_t>>&&)>&&);

    void isPlayingMediaDidChange(WebCore::MediaProducerMediaStateFlags);

    void handleAutoplayEvent(WebCore::AutoplayEvent, OptionSet<WebCore::AutoplayEventFlags>);

#if USE(UNIFIED_TEXT_CHECKING)
    void checkTextOfParagraph(const String& text, OptionSet<WebCore::TextCheckingType> checkingTypes, int32_t insertionPoint, CompletionHandler<void(Vector<WebCore::TextCheckingResult>&&)>&&);
#endif
    void getGuessesForWord(const String& word, const String& context, int32_t insertionPoint, CompletionHandler<void(Vector<String>&&)>&&);

    void logDiagnosticMessageFromWebProcess(IPC::Connection&, const String& message, const String& description, WebCore::ShouldSample);
    void logDiagnosticMessageWithResultFromWebProcess(IPC::Connection&, const String& message, const String& description, uint32_t result, WebCore::ShouldSample);
    void logDiagnosticMessageWithValueFromWebProcess(IPC::Connection&, const String& message, const String& description, double value, unsigned significantFigures, WebCore::ShouldSample);
    void logDiagnosticMessageWithEnhancedPrivacyFromWebProcess(IPC::Connection&, const String& message, const String& description, WebCore::ShouldSample);
    void logDiagnosticMessageWithValueDictionaryFromWebProcess(IPC::Connection&, const String& message, const String& description, const WebCore::DiagnosticLoggingDictionary&, WebCore::ShouldSample);
    void logDiagnosticMessageWithDomainFromWebProcess(IPC::Connection&, const String& message, WebCore::DiagnosticLoggingDomain);

    // Performance logging.
    void logScrollingEvent(uint32_t eventType, MonotonicTime, uint64_t);

    // Form validation messages.
    void showValidationMessage(const WebCore::IntRect& anchorClientRect, const String& message);
    void hideValidationMessage();

#if ENABLE(WIRELESS_PLAYBACK_TARGET) && !PLATFORM(IOS_FAMILY)
    void addPlaybackTargetPickerClient(WebCore::PlaybackTargetClientContextIdentifier);
    void removePlaybackTargetPickerClient(WebCore::PlaybackTargetClientContextIdentifier);
    void showPlaybackTargetPicker(WebCore::PlaybackTargetClientContextIdentifier, const WebCore::FloatRect&, bool hasVideo);
    void playbackTargetPickerClientStateDidChange(WebCore::PlaybackTargetClientContextIdentifier, WebCore::MediaProducerMediaStateFlags);
    void setMockMediaPlaybackTargetPickerEnabled(bool);
    void setMockMediaPlaybackTargetPickerState(const String&, WebCore::MediaPlaybackTargetContextMockState);
    void mockMediaPlaybackTargetPickerDismissPopup();
#endif

    void didReachLayoutMilestone(OptionSet<WebCore::LayoutMilestone>, WallTime timestamp);

    void didRestoreScrollPosition();

    void getLoadDecisionForIcon(const WebCore::LinkIcon&, CallbackID);

    void focusFromServiceWorker(CompletionHandler<void()>&&);
    void setFocus(bool focused);
    void setWindowFrame(const WebCore::FloatRect&);
    void getWindowFrame(CompletionHandler<void(const WebCore::FloatRect&)>&&);
    void getWindowFrameWithCallback(Function<void(WebCore::FloatRect)>&&);

#if ENABLE(GAMEPAD)
    static constexpr Seconds gamepadsRecentlyAccessedThreshold { 1500_ms };

    void gamepadsRecentlyAccessed();
#endif

    void editorStateChanged(EditorState&&);

#if ENABLE(DEVICE_ORIENTATION)
    void shouldAllowDeviceOrientationAndMotionAccess(IPC::Connection&, WebCore::FrameIdentifier, FrameInfoData&&, bool mayPrompt, CompletionHandler<void(WebCore::DeviceOrientationOrMotionPermissionState)>&&);
#endif

#if ENABLE(IMAGE_ANALYSIS)
    void requestTextRecognition(const URL& imageURL, WebCore::ShareableBitmapHandle&& imageData, const String& sourceLanguageIdentifier, const String& targetLanguageIdentifier, CompletionHandler<void(WebCore::TextRecognitionResult&&)>&&);
#endif

#if ENABLE(MEDIA_CONTROLS_CONTEXT_MENUS) && USE(UICONTEXTMENU)
    void showMediaControlsContextMenu(WebCore::FloatRect&&, Vector<WebCore::MediaControlsContextMenuItem>&&, CompletionHandler<void(WebCore::MediaControlsContextMenuItemID)>&&);
#endif

#if ENABLE(ATTACHMENT_ELEMENT)
    void serializedAttachmentDataForIdentifiers(const Vector<String>&, CompletionHandler<void(Vector<WebCore::SerializedAttachmentData>&&)>&&);

    void registerAttachmentIdentifier(IPC::Connection&, const String&);
#endif

    // Logic shared between the WebPageProxy and the ProvisionalPageProxy.
    void didStartProvisionalLoadForFrameShared(Ref<WebProcessProxy>&&, WebCore::FrameIdentifier, FrameInfoData&&, WebCore::ResourceRequest&&, std::optional<WebCore::NavigationIdentifier>, URL&&, URL&& unreachableURL, const UserData&, WallTime);
    void didFailProvisionalLoadForFrameShared(Ref<WebProcessProxy>&&, WebFrameProxy&, FrameInfoData&&, WebCore::ResourceRequest&&, std::optional<WebCore::NavigationIdentifier>, const String& provisionalURL, const WebCore::ResourceError&, WebCore::WillContinueLoading, const UserData&, WebCore::WillInternallyHandleFailure);
    void didReceiveServerRedirectForProvisionalLoadForFrameShared(Ref<WebProcessProxy>&&, WebCore::FrameIdentifier, std::optional<WebCore::NavigationIdentifier>, WebCore::ResourceRequest&&, const UserData&);
    void didPerformServerRedirectShared(Ref<WebProcessProxy>&&, const String& sourceURLString, const String& destinationURLString, WebCore::FrameIdentifier);
    void didPerformClientRedirectShared(Ref<WebProcessProxy>&&, const String& sourceURLString, const String& destinationURLString, WebCore::FrameIdentifier);
    void didNavigateWithNavigationDataShared(Ref<WebProcessProxy>&&, const WebNavigationDataStore&, WebCore::FrameIdentifier);
    void didChangeProvisionalURLForFrameShared(Ref<WebProcessProxy>&&, WebCore::FrameIdentifier, std::optional<WebCore::NavigationIdentifier>, URL&&);
    // void decidePolicyForNavigationActionAsyncShared(Ref<WebProcessProxy>&&, NavigationActionData&&, CompletionHandler<void(PolicyDecision&&)>&&);
    void decidePolicyForResponseShared(Ref<WebProcessProxy>&&, WebCore::PageIdentifier, FrameInfoData&&, std::optional<WebCore::NavigationIdentifier>, const WebCore::ResourceResponse&, const WebCore::ResourceRequest&, bool canShowMIMEType, const String& downloadAttribute, bool isShowingInitialAboutBlank, WebCore::CrossOriginOpenerPolicyValue activeDocumentCOOPValue, CompletionHandler<void(PolicyDecision&&)>&&);

    void backForwardAddItemShared(IPC::Connection&, Ref<FrameState>&&, LoadedWebArchive);
    void backForwardGoToItemShared(WebCore::BackForwardItemIdentifier, CompletionHandler<void(const WebBackForwardListCounts&)>&&);
    void decidePolicyForNavigationActionSyncShared(Ref<WebProcessProxy>&&, NavigationActionData&&, CompletionHandler<void(PolicyDecision&&)>&&);
    void didDestroyNavigationShared(Ref<WebProcessProxy>&&, WebCore::NavigationIdentifier);
#if USE(QUICK_LOOK)
    void requestPasswordForQuickLookDocumentInMainFrameShared(const String& fileName, CompletionHandler<void(const String&)>&&);
#endif
#if ENABLE(CONTENT_FILTERING)
    void contentFilterDidBlockLoadForFrameShared(Ref<WebProcessProxy>&&, const WebCore::ContentFilterUnblockHandler&, WebCore::FrameIdentifier);
#endif
    void handleMessageShared(const Ref<WebProcessProxy>&, const String& messageName, const WebKit::UserData&);

#if ENABLE(SPEECH_SYNTHESIS)
    void speechSynthesisVoiceList(CompletionHandler<void(Vector<WebSpeechSynthesisVoice>&&)>&&);
    void speechSynthesisSpeak(const String&, const String&, float volume, float rate, float pitch, MonotonicTime startTime, const String& voiceURI, const String& voiceName, const String& voiceLang, bool localService, bool defaultVoice, CompletionHandler<void()>&&);
    void speechSynthesisSetFinishedCallback(CompletionHandler<void()>&&);
    void speechSynthesisCancel();
    void speechSynthesisPause(CompletionHandler<void()>&&);
    void speechSynthesisResume(CompletionHandler<void()>&&);
    void speechSynthesisResetState();
#endif

    void configureLoggingChannel(const String&, WTFLogChannelState, WTFLogLevel);

    // IPC::MessageReceiver
    // Implemented in generated WebPageProxyMessageHandlerMessageReceiver.cpp
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    bool didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;

#if ENABLE(WEB_AUTHN)
    void setMockWebAuthenticationConfiguration(WebCore::MockWebAuthenticationConfiguration&&);
#endif

    void didFindTextManipulationItems(const Vector<WebCore::TextManipulationItem>&);

#if ENABLE(MEDIA_USAGE)
    void addMediaUsageManagerSession(WebCore::MediaSessionIdentifier, const String&, const URL&);
    void updateMediaUsageManagerSessionState(WebCore::MediaSessionIdentifier, const WebCore::MediaUsageInfo&);
    void removeMediaUsageManagerSession(WebCore::MediaSessionIdentifier);
#endif

    void setHasExecutedAppBoundBehaviorBeforeNavigation();

#if ENABLE(PDF_HUD)
    void createPDFHUD(PDFPluginIdentifier, const WebCore::IntRect&);
    void updatePDFHUDLocation(PDFPluginIdentifier, const WebCore::IntRect&);
    void removePDFHUD(PDFPluginIdentifier);
#endif

#if ENABLE(PDF_PAGE_NUMBER_INDICATOR)
    void createPDFPageNumberIndicator(PDFPluginIdentifier, const WebCore::IntRect&, size_t pageCount);
    void updatePDFPageNumberIndicatorLocation(PDFPluginIdentifier, const WebCore::IntRect&);
    void updatePDFPageNumberIndicatorCurrentPage(PDFPluginIdentifier, size_t pageIndex);
    void removePDFPageNumberIndicator(PDFPluginIdentifier);
#endif

#if PLATFORM(MAC)
    void changeUniversalAccessZoomFocus(const WebCore::IntRect&, const WebCore::IntRect&);
#endif

#if HAVE(TRANSLATION_UI_SERVICES) && ENABLE(CONTEXT_MENUS)
    bool canHandleContextMenuTranslation() const;
    void handleContextMenuTranslation(const WebCore::TranslationContextMenuInfo&);
#endif

    void broadcastProcessSyncData(IPC::Connection&, const WebCore::ProcessSyncData&);
    void broadcastTopDocumentSyncData(IPC::Connection&, Ref<WebCore::DocumentSyncData>&&);

#if USE(SYSTEM_PREVIEW)
    void beginSystemPreview(const URL&, const WebCore::SecurityOriginData& topOrigin, const WebCore::SystemPreviewInfo&, CompletionHandler<void()>&&);
#endif

    void requestCookieConsent(CompletionHandler<void(WebCore::CookieConsentDecisionResult)>&&);

#if ENABLE(IMAGE_ANALYSIS) && ENABLE(VIDEO)
    void beginTextRecognitionForVideoInElementFullScreen(WebCore::MediaPlayerIdentifier, WebCore::FloatRect videoBounds);
    void cancelTextRecognitionForVideoInElementFullScreen();
#endif

    void didDestroyFrame(IPC::Connection&, WebCore::FrameIdentifier);

    void didCommitLoadForFrame(IPC::Connection&, WebCore::FrameIdentifier, FrameInfoData&&, WebCore::ResourceRequest&&, std::optional<WebCore::NavigationIdentifier>, const String& mimeType, bool frameHasCustomContentProvider, WebCore::FrameLoadType, const WebCore::CertificateInfo&, bool usedLegacyTLS, bool wasPrivateRelayed, const String& proxyName, const WebCore::ResourceResponseSource, bool containsPluginDocument, WebCore::HasInsecureContent, WebCore::MouseEventPolicy, const UserData&);

    void didCreateSleepDisabler(IPC::Connection&, WebCore::SleepDisablerIdentifier, const String& reason, bool display);
    void didDestroySleepDisabler(WebCore::SleepDisablerIdentifier);

#if ENABLE(ACCESSIBILITY_ANIMATION_CONTROL)
    void isAnyAnimationAllowedToPlayDidChange(bool anyAnimationCanPlay);
#endif
    void proofreadingSessionShowDetailsForSuggestionWithIDRelativeToRect(IPC::Connection&, const WebCore::WritingTools::TextSuggestionID&, WebCore::IntRect selectionBoundsInRootView);
    void proofreadingSessionUpdateStateForSuggestionWithID(IPC::Connection&, WebCore::WritingTools::TextSuggestionState, const WebCore::WritingTools::TextSuggestionID&);

    void addTextAnimationForAnimationID(IPC::Connection&, const WTF::UUID&, const WebCore::TextAnimationData&, const WebCore::TextIndicatorData&);
    void addTextAnimationForAnimationIDWithCompletionHandler(IPC::Connection&, const WTF::UUID&, const WebCore::TextAnimationData&, const WebCore::TextIndicatorData&, WTF::CompletionHandler<void(WebCore::TextAnimationRunMode)>&&);
    void removeTextAnimationForAnimationID(IPC::Connection&, const WTF::UUID&);

    void didEndPartialIntelligenceTextAnimation(IPC::Connection&);
    void didEndPartialIntelligenceTextAnimationImpl();
    void nowPlayingMetadataChanged(const WebCore::NowPlayingMetadata&);

    void didAdjustVisibilityWithSelectors(Vector<String>&&);

    void hasActiveNowPlayingSessionChanged(bool);

    void startNetworkRequestsForPageLoadTiming(WebCore::FrameIdentifier);
    void endNetworkRequestsForPageLoadTiming(WebCore::FrameIdentifier, WallTime);

#if PLATFORM(IOS_FAMILY)
    void isPotentialTapInProgress(CompletionHandler<void(bool)>&&);
#endif

private:
    WebPageProxyMessageHandler(WebPageProxy*);

#if ENABLE(POINTER_LOCK)
    void requestPointerLock();
#endif

    void didCreateSubframe(WebCore::FrameIdentifier parent, WebCore::FrameIdentifier newFrameID, const String& frameName, WebCore::SandboxFlags, WebCore::ScrollbarMode);

    void didStartProvisionalLoadForFrame(WebCore::FrameIdentifier, FrameInfoData&&, WebCore::ResourceRequest&&, std::optional<WebCore::NavigationIdentifier>, URL&&, URL&& unreachableURL, const UserData&, WallTime);
    void didReceiveServerRedirectForProvisionalLoadForFrame(WebCore::FrameIdentifier, std::optional<WebCore::NavigationIdentifier>, WebCore::ResourceRequest&&, const UserData&);
    void willPerformClientRedirectForFrame(IPC::Connection&, WebCore::FrameIdentifier, const String& url, double delay, WebCore::LockBackForwardList);
    void didCancelClientRedirectForFrame(IPC::Connection&, WebCore::FrameIdentifier);
    void didChangeProvisionalURLForFrame(WebCore::FrameIdentifier, std::optional<WebCore::NavigationIdentifier>, URL&&);
    void didFailProvisionalLoadForFrame(IPC::Connection&, FrameInfoData&&, WebCore::ResourceRequest&&, std::optional<WebCore::NavigationIdentifier>, const String& provisionalURL, const WebCore::ResourceError&, WebCore::WillContinueLoading, const UserData&, WebCore::WillInternallyHandleFailure);
    void didFinishDocumentLoadForFrame(IPC::Connection&, WebCore::FrameIdentifier, std::optional<WebCore::NavigationIdentifier>, const UserData&, WallTime);
    void didFinishLoadForFrame(IPC::Connection&, WebCore::FrameIdentifier, FrameInfoData&&, WebCore::ResourceRequest&&, std::optional<WebCore::NavigationIdentifier>, const UserData&);
    void didFailLoadForFrame(IPC::Connection&, WebCore::FrameIdentifier, FrameInfoData&&, WebCore::ResourceRequest&&, std::optional<WebCore::NavigationIdentifier>, const WebCore::ResourceError&, const UserData&);
    void didSameDocumentNavigationForFrame(IPC::Connection&, WebCore::FrameIdentifier, std::optional<WebCore::NavigationIdentifier>, SameDocumentNavigationType, URL&&, const UserData&);
    void didSameDocumentNavigationForFrameViaJS(IPC::Connection&, SameDocumentNavigationType, URL, NavigationActionData&&, const UserData&);
    void didChangeMainDocument(WebCore::FrameIdentifier, std::optional<WebCore::NavigationIdentifier>);
    void didExplicitOpenForFrame(IPC::Connection&, WebCore::FrameIdentifier, URL&&, String&& mimeType);

    void didReceiveTitleForFrame(IPC::Connection&, WebCore::FrameIdentifier, const String&, const UserData&);
    void didFirstLayoutForFrame(WebCore::FrameIdentifier, const UserData&);
    void didFirstVisuallyNonEmptyLayoutForFrame(IPC::Connection&, WebCore::FrameIdentifier, const UserData&, WallTime);
    void didDisplayInsecureContentForFrame(IPC::Connection&, WebCore::FrameIdentifier, const UserData&);
    void didRunInsecureContentForFrame(IPC::Connection&, WebCore::FrameIdentifier, const UserData&);
    void mainFramePluginHandlesPageScaleGestureDidChange(bool, double minScale, double maxScale);
    void didStartProgress();
    void didChangeProgress(double);
    void didFinishProgress();
    void setNetworkRequestsInProgress(bool);

    void updateRemoteFrameSize(WebCore::FrameIdentifier, WebCore::IntSize);
    void resolveAccessibilityHitTestForTesting(WebCore::FrameIdentifier, WebCore::IntPoint, CompletionHandler<void(String)>&&);
    void updateSandboxFlags(IPC::Connection&, WebCore::FrameIdentifier, WebCore::SandboxFlags);
    void updateOpener(IPC::Connection&, WebCore::FrameIdentifier, WebCore::FrameIdentifier);
    void updateScrollingMode(IPC::Connection&, WebCore::FrameIdentifier, WebCore::ScrollbarMode);

    void didDestroyNavigation(WebCore::NavigationIdentifier);

    void decidePolicyForNavigationActionAsync(NavigationActionData&&, CompletionHandler<void(PolicyDecision&&)>&&);
    void decidePolicyForNavigationActionSync(IPC::Connection&, NavigationActionData&&, CompletionHandler<void(PolicyDecision&&)>&&);
    void decidePolicyForNewWindowAction(IPC::Connection&, NavigationActionData&&, const String& frameName, CompletionHandler<void(PolicyDecision&&)>&&);
    void decidePolicyForResponse(IPC::Connection&, FrameInfoData&&, std::optional<WebCore::NavigationIdentifier>, const WebCore::ResourceResponse&, const WebCore::ResourceRequest&, bool canShowMIMEType, const String& downloadAttribute, bool isShowingInitialAboutBlank, WebCore::CrossOriginOpenerPolicyValue activeDocumentCOOPValue, CompletionHandler<void(PolicyDecision&&)>&&);

    void willSubmitForm(IPC::Connection&, WebCore::FrameIdentifier, WebCore::FrameIdentifier sourceFrameID, const Vector<std::pair<String, String>>& textFieldValues, const UserData&, CompletionHandler<void()>&&);

#if ENABLE(CONTENT_EXTENSIONS)
    void contentRuleListNotification(URL&&, WebCore::ContentRuleListResults&&);
#endif

    // History client
    void didNavigateWithNavigationData(const WebNavigationDataStore&, WebCore::FrameIdentifier);
    void didPerformClientRedirect(const String& sourceURLString, const String& destinationURLString, WebCore::FrameIdentifier);
    void didPerformServerRedirect(const String& sourceURLString, const String& destinationURLString, WebCore::FrameIdentifier);
    void didUpdateHistoryTitle(IPC::Connection&, const String& title, const String& url, WebCore::FrameIdentifier);

    // UI client
    void createNewPage(IPC::Connection&, WebCore::WindowFeatures&&, NavigationActionData&&, CompletionHandler<void(std::optional<WebCore::PageIdentifier>, std::optional<WebPageCreationParameters>)>&&);
    void showPage();
    void runJavaScriptAlert(IPC::Connection&, WebCore::FrameIdentifier, FrameInfoData&&, const String&, CompletionHandler<void()>&&);
    void runJavaScriptConfirm(IPC::Connection&, WebCore::FrameIdentifier, FrameInfoData&&, const String&, CompletionHandler<void(bool)>&&);
    void runJavaScriptPrompt(IPC::Connection&, WebCore::FrameIdentifier, FrameInfoData&&, const String&, const String&, CompletionHandler<void(const String&)>&&);
    void mouseDidMoveOverElement(WebHitTestResultData&&, OptionSet<WebEventModifier>, UserData&&);

    void setToolbarsAreVisible(bool toolbarsAreVisible);
    void getToolbarsAreVisible(CompletionHandler<void(bool)>&&);
    void setMenuBarIsVisible(bool menuBarIsVisible);
    void getMenuBarIsVisible(CompletionHandler<void(bool)>&&);
    void setStatusBarIsVisible(bool statusBarIsVisible);
    void getStatusBarIsVisible(CompletionHandler<void(bool)>&&);
    void setIsResizable(bool isResizable);
    void screenToRootView(const WebCore::IntPoint& screenPoint, CompletionHandler<void(const WebCore::IntPoint&)>&&);
    void rootViewPointToScreen(const WebCore::IntPoint& viewPoint, CompletionHandler<void(const WebCore::IntPoint&)>&&);
    void rootViewRectToScreen(const WebCore::IntRect& viewRect, CompletionHandler<void(const WebCore::IntRect&)>&&);
    void accessibilityScreenToRootView(const WebCore::IntPoint& screenPoint, CompletionHandler<void(WebCore::IntPoint)>&&);
    void rootViewToAccessibilityScreen(const WebCore::IntRect& viewRect, CompletionHandler<void(WebCore::IntRect)>&&);
#if PLATFORM(IOS_FAMILY)
    void relayAccessibilityNotification(const String&, std::span<const uint8_t>);
#endif
    void runBeforeUnloadConfirmPanel(IPC::Connection&, WebCore::FrameIdentifier, FrameInfoData&&, const String& message, CompletionHandler<void(bool)>&&);
    void pageDidScroll(const WebCore::IntPoint&);
    void runOpenPanel(IPC::Connection&, WebCore::FrameIdentifier, FrameInfoData&&, const WebCore::FileChooserSettings&);
    void showShareSheet(IPC::Connection&, const WebCore::ShareDataWithParsedURL&, CompletionHandler<void(bool)>&&);
    void showContactPicker(IPC::Connection&, const WebCore::ContactsRequestData&, CompletionHandler<void(std::optional<Vector<WebCore::ContactInfo>>&&)>&&);
#if ENABLE(WEB_AUTHN)
    void showDigitalCredentialsPicker(IPC::Connection&, const WebCore::DigitalCredentialsRequestData&, WTF::CompletionHandler<void(Expected<WebCore::DigitalCredentialsResponseData, WebCore::ExceptionData>&&)>&&);
    void dismissDigitalCredentialsPicker(IPC::Connection&, WTF::CompletionHandler<void(bool)>&&);
#endif
    void printFrame(IPC::Connection&, WebCore::FrameIdentifier, const String&, const WebCore::FloatSize&,  CompletionHandler<void()>&&);
    void exceededDatabaseQuota(WebCore::FrameIdentifier, const String& originIdentifier, const String& databaseName, const String& displayName, uint64_t currentQuota, uint64_t currentOriginUsage, uint64_t currentDatabaseUsage, uint64_t expectedUsage, CompletionHandler<void(uint64_t)>&&);

    void requestGeolocationPermissionForFrame(IPC::Connection&, GeolocationIdentifier, FrameInfoData&&);
    void revokeGeolocationAuthorizationToken(const String& authorizationToken);

#if PLATFORM(GTK) || PLATFORM(WPE)
    void sendMessageToWebView(UserMessage&&);
    void sendMessageToWebViewWithReply(UserMessage&&, CompletionHandler<void(UserMessage&&)>&&);

    void didInitiateLoadForResource(WebCore::ResourceLoaderIdentifier, WebCore::FrameIdentifier, WebCore::ResourceRequest&&);
    void didSendRequestForResource(WebCore::ResourceLoaderIdentifier, WebCore::FrameIdentifier, WebCore::ResourceRequest&&, WebCore::ResourceResponse&&);
    void didReceiveResponseForResource(WebCore::ResourceLoaderIdentifier, WebCore::FrameIdentifier, WebCore::ResourceResponse&&);
    void didFinishLoadForResource(WebCore::ResourceLoaderIdentifier, WebCore::FrameIdentifier, WebCore::ResourceError&&);
#endif

#if ENABLE(MEDIA_STREAM)
    void requestUserMediaPermissionForFrame(IPC::Connection&, WebCore::UserMediaRequestIdentifier, FrameInfoData&&, const WebCore::SecurityOriginData& userMediaDocumentOriginIdentifier, const WebCore::SecurityOriginData& topLevelDocumentOriginIdentifier, WebCore::MediaStreamRequest&&);
    void enumerateMediaDevicesForFrame(IPC::Connection&, WebCore::FrameIdentifier, const WebCore::SecurityOriginData& userMediaDocumentOriginData, const WebCore::SecurityOriginData& topLevelDocumentOriginData, CompletionHandler<void(const Vector<WebCore::CaptureDeviceWithCapabilities>&, WebCore::MediaDeviceHashSalts&&)>&&);
    void beginMonitoringCaptureDevices();
    void validateCaptureStateUpdate(WebCore::UserMediaRequestIdentifier, WebCore::ClientOrigin&&, FrameInfoData&&, bool isActive, WebCore::MediaProducerMediaCaptureKind, CompletionHandler<void(std::optional<WebCore::Exception>&&)>&&);
    void setShouldListenToVoiceActivity(bool);
#endif

    void requestMediaKeySystemPermissionForFrame(IPC::Connection&, WebCore::MediaKeySystemRequestIdentifier, WebCore::FrameIdentifier, WebCore::ClientOrigin&&, const String&);

    void runModal();
    void notifyScrollerThumbIsVisibleInRect(const WebCore::IntRect&);
    void recommendedScrollbarStyleDidChange(int32_t newStyle);
    void didChangeScrollbarsForMainFrame(bool hasHorizontalScrollbar, bool hasVerticalScrollbar);
    void didChangeScrollOffsetPinningForMainFrame(WebCore::RectEdges<bool>);
    void didChangePageCount(unsigned);
    void themeColorChanged(const WebCore::Color&);
    void pageExtendedBackgroundColorDidChange(const WebCore::Color&);
    void sampledPageTopColorChanged(const WebCore::Color&);
#if ENABLE(WEB_PAGE_SPATIAL_BACKDROP)
    void spatialBackdropSourceChanged(std::optional<WebCore::SpatialBackdropSource>&&);
#endif
    void setCanShortCircuitHorizontalWheelEvents(bool canShortCircuitHorizontalWheelEvents);

    void requestNotificationPermission(const String& originString, CompletionHandler<void(bool allowed)>&&);

    void didChangeContentSize(const WebCore::IntSize&);
    void didChangeIntrinsicContentSize(const WebCore::IntSize&);

    void showColorPicker(const WebCore::Color& initialColor, const WebCore::IntRect&, ColorControlSupportsAlpha, Vector<WebCore::Color>&&);

    void showDataListSuggestions(WebCore::DataListSuggestionInformation&&);
    void handleKeydownInDataList(const String&);
    void endDataListSuggestions();

    void showDateTimePicker(WebCore::DateTimeChooserParameters&&);
    void endDateTimePicker();

    void compositionWasCanceled();
    void setHasFocusedElementWithUserInteraction(bool);

#if HAVE(TOUCH_BAR)
    void setIsTouchBarUpdateSuppressedForHiddenContentEditable(bool);
    void setIsNeverRichlyEditableForTouchBar(bool);
#endif

    void requestDOMPasteAccess(WebCore::DOMPasteAccessCategory, WebCore::FrameIdentifier, const WebCore::IntRect&, const String&, CompletionHandler<void(WebCore::DOMPasteAccessResponse)>&&);

    // Back/Forward list management
    void backForwardAddItem(IPC::Connection&, Ref<FrameState>&&);
    void backForwardSetChildItem(WebCore::BackForwardFrameItemIdentifier, Ref<FrameState>&&);
    void backForwardClearChildren(WebCore::BackForwardItemIdentifier, WebCore::BackForwardFrameItemIdentifier);
    void backForwardGoToItem(WebCore::BackForwardItemIdentifier, CompletionHandler<void(const WebBackForwardListCounts&)>&&);
    void backForwardListContainsItem(WebCore::BackForwardItemIdentifier, CompletionHandler<void(bool)>&&);
    void backForwardItemAtIndex(int32_t index, WebCore::FrameIdentifier, CompletionHandler<void(RefPtr<FrameState>&&)>&&);
    void backForwardListCounts(CompletionHandler<void(WebBackForwardListCounts&&)>&&);
    void backForwardUpdateItem(IPC::Connection&, Ref<FrameState>&&);

    // Undo management
    void registerEditCommandForUndo(IPC::Connection&, WebUndoStepID commandID, const String& label);
    void registerInsertionUndoGrouping();
    void clearAllEditCommands();
    void canUndoRedo(UndoOrRedo, CompletionHandler<void(bool)>&&);
    void executeUndoRedo(UndoOrRedo, CompletionHandler<void()>&&);

    // Keyboard handling
#if PLATFORM(COCOA)
    void executeSavedCommandBySelector(IPC::Connection&, const String& selector, CompletionHandler<void(bool)>&&);
#endif

#if PLATFORM(GTK) || PLATFORM(WPE)
    void bindAccessibilityTree(const String&);
#endif

#if PLATFORM(GTK)
    void showEmojiPicker(const WebCore::IntRect&, CompletionHandler<void(String)>&&);
#endif

    // Popup Menu.
    void showPopupMenuFromFrame(IPC::Connection&, WebCore::FrameIdentifier, const WebCore::IntRect&, uint64_t textDirection, Vector<WebPopupItem>&& items, int32_t selectedIndex, const PlatformPopupMenuData&);
    void hidePopupMenu();

#if ENABLE(CONTEXT_MENUS)
    void showContextMenuFromFrame(FrameInfoData&&, ContextMenuContextData&&, UserData&&);
#endif


#if ENABLE(TELEPHONE_NUMBER_DETECTION) && PLATFORM(MAC)
    void showTelephoneNumberMenu(const String& telephoneNumber, const WebCore::IntPoint&, const WebCore::IntRect&);
#endif

    // Search popup results
    void saveRecentSearches(IPC::Connection&, const String&, const Vector<WebCore::RecentSearch>&);
    void loadRecentSearches(IPC::Connection&, const String&, CompletionHandler<void(Vector<WebCore::RecentSearch>&&)>&&);

#if PLATFORM(COCOA)
    // Speech.
    void getIsSpeaking(CompletionHandler<void(bool)>&&);

    void searchTheWeb(const String&);

    // Dictionary.
    void didPerformDictionaryLookup(const WebCore::DictionaryPopupInfo&);
#endif

    // Spelling and grammar.
    void checkSpellingOfString(const String& text, CompletionHandler<void(int32_t misspellingLocation, int32_t misspellingLength)>&&);
    void checkGrammarOfString(const String& text, CompletionHandler<void(Vector<WebCore::GrammarDetail>&&, int32_t badGrammarLocation, int32_t badGrammarLength)>&&);
    void spellingUIIsShowing(CompletionHandler<void(bool)>&&);
    void updateSpellingUIWithMisspelledWord(const String& misspelledWord);
    void updateSpellingUIWithGrammarString(const String& badGrammarPhrase, const WebCore::GrammarDetail&);
    void learnWord(IPC::Connection&, const String& word);
    void ignoreWord(IPC::Connection&, const String& word);
    void requestCheckingOfString(TextCheckerRequestID, const WebCore::TextCheckingRequestData&, int32_t insertionPoint);

    void takeFocus(WebCore::FocusDirection);
    void setCursor(const WebCore::Cursor&);
    void setCursorHiddenUntilMouseMoves(bool);

    void didReceiveEvent(WebEventType, bool handled, std::optional<WebCore::RemoteUserInputEventData>);
    void didUpdateRenderingAfterCommittingLoad();
#if PLATFORM(IOS_FAMILY)
    void interpretKeyEvent(EditorState&&, KeyEventInterpretationContext&&, CompletionHandler<void(bool)>&&);
    void showPlaybackTargetPicker(bool hasVideo, const WebCore::IntRect& elementRect, WebCore::RouteSharingPolicy, const String&);

    void updateStringForFind(const String&);
#endif

    void focusedFrameChanged(IPC::Connection&, const std::optional<WebCore::FrameIdentifier>&);

    void didFinishLoadingDataForCustomContentProvider(const String& suggestedFilename, std::span<const uint8_t>);

#if USE(AUTOMATIC_TEXT_REPLACEMENT)
    void toggleSmartInsertDelete();
    void toggleAutomaticQuoteSubstitution();
    void toggleAutomaticLinkDetection();
    void toggleAutomaticDashSubstitution();
    void toggleAutomaticTextReplacement();
#endif

#if USE(DICTATION_ALTERNATIVES)
    void showDictationAlternativeUI(const WebCore::FloatRect& boundingBoxOfDictatedText, WebCore::DictationContext);
    void removeDictationAlternatives(WebCore::DictationContext);
    void dictationAlternatives(WebCore::DictationContext, CompletionHandler<void(Vector<String>&&)>&&);
#endif

#if PLATFORM(MAC)
    void substitutionsPanelIsShowing(CompletionHandler<void(bool)>&&);
    void showCorrectionPanel(WebCore::AlternativeTextType panelType, const WebCore::FloatRect& boundingBoxOfReplacedString, const String& replacedString, const String& replacementString, const Vector<String>& alternativeReplacementStrings);
    void dismissCorrectionPanel(WebCore::ReasonForDismissingAlternativeText);
    void dismissCorrectionPanelSoon(WebCore::ReasonForDismissingAlternativeText, CompletionHandler<void(String)>&&);
    void recordAutocorrectionResponse(WebCore::AutocorrectionResponse, const String& replacedString, const String& replacementString);

    void setEditableElementIsFocused(bool);

    void handleAcceptsFirstMouse(bool);
#endif // PLATFORM(MAC)

#if PLATFORM(IOS_FAMILY)
    void couldNotRestorePageState();
    void restorePageState(std::optional<WebCore::FloatPoint> scrollPosition, const WebCore::FloatPoint& scrollOrigin, const WebCore::FloatBoxExtent& obscuredInsetsOnSave, double scale);
    void restorePageCenterAndScale(std::optional<WebCore::FloatPoint>, double scale);

    void didGetTapHighlightGeometries(TapIdentifier requestID, const WebCore::Color&, const Vector<WebCore::FloatQuad>& geometries, const WebCore::IntSize& topLeftRadius, const WebCore::IntSize& topRightRadius, const WebCore::IntSize& bottomLeftRadius, const WebCore::IntSize& bottomRightRadius, bool nodeHasBuiltInClickHandling);

    void elementDidFocus(const FocusedElementInformation&, bool userIsInteracting, bool blurPreviousNode, OptionSet<WebCore::ActivityState> activityStateChanges, const UserData&);
    void elementDidBlur();
    void updateInputContextAfterBlurringAndRefocusingElement();
    void didProgrammaticallyClearFocusedElement(WebCore::ElementContext&&);
    void updateFocusedElementInformation(const FocusedElementInformation&);
    void focusedElementDidChangeInputMode(WebCore::InputMode);

    void showInspectorHighlight(const WebCore::InspectorOverlayHighlight&);
    void hideInspectorHighlight();

    void enableInspectorNodeSearch();
    void disableInspectorNodeSearch();
#endif // PLATFORM(IOS_FAMILY)

    void setRenderTreeSize(uint64_t treeSize);

#if USE(QUICK_LOOK)
    void didStartLoadForQuickLookDocumentInMainFrame(const String& fileName, const String& uti);
    void didFinishLoadForQuickLookDocumentInMainFrame(WebCore::ShareableResourceHandle&&);
    void requestPasswordForQuickLookDocumentInMainFrame(const String& fileName, CompletionHandler<void(const String&)>&&);
#endif

#if ENABLE(CONTENT_FILTERING)
    void contentFilterDidBlockLoadForFrame(IPC::Connection&, const WebCore::ContentFilterUnblockHandler&, WebCore::FrameIdentifier);
#endif

#if PLATFORM(MAC)
    void didPerformImmediateActionHitTest(WebHitTestResultData&&, bool contentPreventsDefault, const UserData&);
#endif

    void useFixedLayoutDidChange(bool useFixedLayout);
    void fixedLayoutSizeDidChange(WebCore::IntSize);

    void imageOrMediaDocumentSizeChanged(const WebCore::IntSize&);

    void startURLSchemeTask(IPC::Connection&, URLSchemeTaskParameters&&);
    void stopURLSchemeTask(IPC::Connection&, WebURLSchemeHandlerIdentifier, WebCore::ResourceLoaderIdentifier);
    void loadSynchronousURLSchemeTask(IPC::Connection&, URLSchemeTaskParameters&&, CompletionHandler<void(const WebCore::ResourceResponse&, const WebCore::ResourceError&, Vector<uint8_t>&&)>&&);

    void handleAutoFillButtonClick(const UserData&);

    void didResignInputElementStrongPasswordAppearance(const UserData&);

    void performSwitchHapticFeedback();

    void handleMessage(IPC::Connection&, const String& messageName, const UserData& messageBody);
    void handleMessageWithAsyncReply(const String& messageName, const UserData& messageBody, CompletionHandler<void(UserData&&)>&&);
    void handleSynchronousMessage(IPC::Connection&, const String& messageName, const UserData& messageBody, CompletionHandler<void(UserData&&)>&&);

#if ENABLE(ATTACHMENT_ELEMENT)
    void registerAttachmentIdentifierFromData(IPC::Connection&, const String&, const String& contentType, const String& preferredFileName, const IPC::SharedBufferReference&);
    void registerAttachmentIdentifierFromFilePath(IPC::Connection&, const String&, const String& contentType, const String& filePath);
    void registerAttachmentsFromSerializedData(IPC::Connection&, Vector<WebCore::SerializedAttachmentData>&&);
    void cloneAttachmentData(IPC::Connection&, const String& fromIdentifier, const String& toIdentifier);

    void didInsertAttachmentWithIdentifier(IPC::Connection&, const String& identifier, const String& source, WebCore::AttachmentAssociatedElementType);
    void didRemoveAttachmentWithIdentifier(IPC::Connection&, const String& identifier);

#if PLATFORM(IOS_FAMILY)
    void writePromisedAttachmentToPasteboard(IPC::Connection&, WebCore::PromisedAttachmentInfo&&, const String& authorizationToken);
#endif

    void requestAttachmentIcon(IPC::Connection&, const String& identifier, const String& type, const String& path, const String& title, const WebCore::FloatSize&);

#endif

#if ENABLE(WINDOW_PROXY_PROPERTY_ACCESS_NOTIFICATION)
    void didAccessWindowProxyPropertyViaOpenerForFrame(IPC::Connection&, WebCore::FrameIdentifier, const WebCore::SecurityOriginData&, WebCore::WindowProxyProperty);
#endif

    void didFinishServiceWorkerPageRegistration(bool success);

    void runModalJavaScriptDialog(RefPtr<WebFrameProxy>&&, FrameInfoData&&, const String& message, CompletionHandler<void(WebPageProxyMessageHandler&, WebFrameProxy*, FrameInfoData&&, const String&, CompletionHandler<void()>&&)>&&);

    void dispatchLoadEventToFrameOwnerElement(WebCore::FrameIdentifier);

    void focusRemoteFrame(IPC::Connection&, WebCore::FrameIdentifier);
    void postMessageToRemote(WebCore::FrameIdentifier source, const String& sourceOrigin, WebCore::FrameIdentifier target, std::optional<WebCore::SecurityOriginData> targetOrigin, const WebCore::MessageWithMessagePorts&);
    void renderTreeAsTextForTesting(WebCore::FrameIdentifier, size_t baseIndent, OptionSet<WebCore::RenderAsTextFlag>, CompletionHandler<void(String&&)>&&);
    void layerTreeAsTextForTesting(WebCore::FrameIdentifier, size_t baseIndent, OptionSet<WebCore::LayerTreeAsTextOptions>, CompletionHandler<void(String&&)>&&);
    void addMessageToConsoleForTesting(String&&);
    void frameTextForTesting(WebCore::FrameIdentifier, CompletionHandler<void(String&&)>&&);
    void bindRemoteAccessibilityFrames(int processIdentifier, WebCore::FrameIdentifier, Vector<uint8_t>&& dataToken, CompletionHandler<void(Vector<uint8_t>, int)>&&);
    void updateRemoteFrameAccessibilityOffset(WebCore::FrameIdentifier, WebCore::IntPoint);
    void documentURLForConsoleLog(WebCore::FrameIdentifier, CompletionHandler<void(const URL&)>&&);

    void setTextIndicatorFromFrame(WebCore::FrameIdentifier, WebCore::TextIndicatorData&&, uint64_t);

    void frameNameChanged(IPC::Connection&, WebCore::FrameIdentifier, const String& frameName);

    void setAllowsLayoutViewportHeightExpansion(bool);

    PageClient* pageClient() const;
    API::UIClient* uiClient() const;
#if ENABLE(MEDIA_STREAM)
    UserMediaPermissionRequestManagerProxy& userMediaPermissionRequestManager();
    Ref<UserMediaPermissionRequestManagerProxy> protectedUserMediaPermissionRequestManager();
#endif

#if USE(SYSTEM_PREVIEW)
    Ref<SystemPreviewController> protectedSystemPreviewController();
#endif
    void forEachWebContentProcess(NOESCAPE Function<void(WebProcessProxy&, WebCore::PageIdentifier)>&&);
    SpellDocumentTag spellDocumentTag();
    WebPageInspectorController& inspectorController() const;
    API::NavigationClient& navigationClient();
    Ref<WebProcessProxy> protectedLegacyMainFrameProcess();
    const WebPreferences& preferences() const;
    WebPreferences& preferences();
    Ref<WebPreferences> protectedPreferences() const;
    RefPtr<PageClient> protectedPageClient();
    RefPtr<ModelElementController> modelElementController();
    Ref<GeolocationPermissionRequestManagerProxy> protectedGeolocationPermissionRequestManager();
    SpeechSynthesisData& speechSynthesisData();
    WebCore::WebMediaSessionManagerClient& webMediaSessionManagerClient();

    WebPageProxy* m_proxy;
};

} // namespace WebKit
