/*
 * Copyright (C) 2010-2025 Apple Inc. All rights reserved.
 * Copyright (C) 2012 Intel Corporation. All rights reserved.
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
#include "WebPageProxyMessageHandler.h"

#include "APIAttachment.h"
#include "APIContextMenuClient.h"
#include "APIDiagnosticLoggingClient.h"
#include "APIFindClient.h"
#include "APIFindMatchesClient.h"
#include "APIFormClient.h"
#include "APIFrameInfo.h"
#include "APIFullscreenClient.h"
#include "APIHistoryClient.h"
#include "APILegacyContextHistoryClient.h"
#include "APILoaderClient.h"
#include "APINavigation.h"
#include "APINavigationClient.h"
#include "APIPageConfiguration.h"
#include "APIPolicyClient.h"
#include "APITargetedElementInfo.h"
#include "APITargetedElementRequest.h"
#include "APIUIClient.h"
#include "AuthenticationChallengeProxy.h"
#include "AuthenticationManager.h"
#include "BrowsingContextGroup.h"
#include "CallbackID.h"
#include "ColorControlSupportsAlpha.h"
#include "Connection.h"
#include "DownloadManager.h"
#include "DownloadProxy.h"
#include "DrawingAreaMessages.h"
#include "DrawingAreaProxy.h"
#include "FindStringCallbackAggregator.h"
#include "FrameInfoData.h"
#include "FrameProcess.h"
#include "GeolocationPermissionRequestManagerProxy.h"
#include "LoadParameters.h"
#include "LogInitialization.h"
#include "MediaKeySystemPermissionRequestManagerProxy.h"
#include "ModelElementController.h"
#include "NavigationActionData.h"
#include "NetworkProcessMessages.h"
#include "NetworkProcessProxy.h"
#include "NotificationManagerMessageHandlerMessages.h"
#include "PageClient.h"
#include "PlatformPopupMenuData.h"
#include "PolicyDecision.h"
#include "ProcessAssertion.h"
#include "ProcessThrottler.h"
#include "ProvisionalFrameProxy.h"
#include "ProvisionalPageProxy.h"
#include "RemotePageProxy.h"
#include "SpeechRecognitionPermissionManager.h"
#include "SpeechRecognitionRemoteRealtimeMediaSourceManager.h"
#include "SuspendedPageProxy.h"
#include "TextChecker.h"
#include "TextCheckerState.h"
#include "URLSchemeTaskParameters.h"
#include "UndoOrRedo.h"
#include "UserMediaPermissionRequestProxy.h"
#include "UserMediaProcessManager.h"
#include "ViewGestureController.h"
#include "WebAutomationSession.h"
#include "WebAutomationSessionProxyMessages.h"
#include "WebBackForwardCache.h"
#include "WebBackForwardList.h"
#include "WebBackForwardListCounts.h"
#include "WebBackForwardListFrameItem.h"
#include "WebBackForwardListItem.h"
#include "WebContextMenuProxy.h"
#include "WebDateTimePicker.h"
#include "WebEditCommandProxy.h"
#include "WebErrors.h"
#include "WebEventType.h"
#include "WebFrame.h"
#include "WebFrameProxy.h"
#include "WebFullScreenManagerProxy.h"
#include "WebFullScreenManagerProxyMessages.h"
#include "WebImage.h"
#include "WebInspectorUIProxy.h"
#include "WebInspectorUtilities.h"
#include "WebNavigationDataStore.h"
#include "WebNavigationState.h"
#include "WebNotificationManagerProxy.h"
#include "WebOpenPanelResultListenerProxy.h"
#include "WebPage.h"
#include "WebPageCreationParameters.h"
#include "WebPageDebuggable.h"
#include "WebPageGroup.h"
#include "WebPageInjectedBundleClient.h"
#include "WebPageInspectorController.h"
#include "WebPageMessages.h"
#include "WebPageProxyMessageHandler.h"
#include "WebPageProxyInternals.h"
#include "WebPageProxyMessageHandlerMessages.h"
#include "WebPageProxyTesting.h"
#include "WebPasteboardProxy.h"
#include "WebPopupItem.h"
#include "WebPreferences.h"
#include "WebProcess.h"
#include "WebProcessActivityState.h"
#include "WebProcessMessages.h"
#include "WebProcessPool.h"
#include "WebProcessProxy.h"
#include "WebResourceLoadStatisticsStore.h"
#include "WebScreenOrientationManagerProxy.h"
#include "WebURLSchemeHandler.h"
#include "WebUserContentControllerProxy.h"
#include "WebsiteDataStore.h"
#include <JavaScriptCore/ConsoleTypes.h>
#include <WebCore/AlternativeTextClient.h>
#include <WebCore/AppHighlight.h>
#include <WebCore/ArchiveError.h>
#include <WebCore/BitmapImage.h>
#include <WebCore/CaptureDeviceManager.h>
#include <WebCore/CompositionHighlight.h>
#include <WebCore/CrossSiteNavigationDataTransfer.h>
#include <WebCore/CryptoKey.h>
#include <WebCore/DOMPasteAccess.h>
#include <WebCore/DeprecatedGlobalSettings.h>
#include <WebCore/DiagnosticLoggingClient.h>
#include <WebCore/DiagnosticLoggingKeys.h>
#include <WebCore/DigitalCredentialRequest.h>
#include <WebCore/DigitalCredentialRequestOptions.h>
#include <WebCore/DigitalCredentialsRequestData.h>
#include <WebCore/DigitalCredentialsResponseData.h>
#include <WebCore/DragController.h>
#include <WebCore/DragData.h>
#include <WebCore/ElementContext.h>
#include <WebCore/EventNames.h>
#include <WebCore/ExceptionCode.h>
#include <WebCore/ExceptionData.h>
#include <WebCore/ExceptionDetails.h>
#include <WebCore/FloatRect.h>
#include <WebCore/FocusDirection.h>
#include <WebCore/FontAttributeChanges.h>
#include <WebCore/FrameLoader.h>
#include <WebCore/FrameLoaderClient.h>
#include <WebCore/GlobalFrameIdentifier.h>
#include <WebCore/GlobalWindowIdentifier.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/LegacySchemeRegistry.h>
#include <WebCore/LengthBox.h>
#include <WebCore/LinkDecorationFilteringData.h>
#include <WebCore/MIMETypeRegistry.h>
#include <WebCore/MediaDeviceHashSalts.h>
#include <WebCore/MediaStreamRequest.h>
#include <WebCore/ModalContainerTypes.h>
#include <WebCore/NotImplemented.h>
#include <WebCore/OrganizationStorageAccessPromptQuirk.h>
#include <WebCore/PerformanceLoggingClient.h>
#include <WebCore/PermissionDescriptor.h>
#include <WebCore/PermissionState.h>
#include <WebCore/PlatformEvent.h>
#include <WebCore/PublicSuffixStore.h>
#include <WebCore/Quirks.h>
#include <WebCore/RealtimeMediaSourceCenter.h>
#include <WebCore/RemoteUserInputEventData.h>
#include <WebCore/RenderEmbeddedObject.h>
#include <WebCore/ResourceLoadStatistics.h>
#include <WebCore/RunJavaScriptParameters.h>
#include <WebCore/SerializedCryptoKeyWrap.h>
#include <WebCore/SerializedScriptValue.h>
#include <WebCore/ShareData.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/ShouldTreatAsContinuingLoad.h>
#include <WebCore/Site.h>
#include <WebCore/SleepDisabler.h>
#include <WebCore/StoredCredentialsPolicy.h>
#include <WebCore/TextCheckerClient.h>
#include <WebCore/TextExtractionTypes.h>
#include <WebCore/TextIndicator.h>
#include <WebCore/ValidationBubble.h>
#include <WebCore/WindowFeatures.h>
#include <WebCore/WrappedCryptoKey.h>
#include <WebCore/WritingDirection.h>
#include <optional>
#include <stdio.h>
#include <wtf/CallbackAggregator.h>
#include <wtf/CoroutineUtilities.h>
#include <wtf/EnumTraits.h>
#include <wtf/FileSystem.h>
#include <wtf/ListHashSet.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/NumberOfCores.h>
#include <wtf/Scope.h>
#include <wtf/SystemTracing.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/URL.h>
#include <wtf/URLParser.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringView.h>
#include <wtf/text/TextStream.h>

// #if ENABLE(APPLICATION_MANIFEST)
// #include "APIApplicationManifest.h"
// #endif

#if ENABLE(ASYNC_SCROLLING) && PLATFORM(COCOA)
#include "RemoteScrollingCoordinatorMessages.h"
#include "RemoteScrollingCoordinatorProxy.h"
#endif

#ifndef NDEBUG
#include <wtf/RefCountedLeakCounter.h>
#endif

#if PLATFORM(COCOA)
// #include "InsertTextOptions.h"
// #include "NetworkIssueReporter.h"
// #include "PlaybackSessionInterfaceLMK.h"
// #include "RemoteLayerTreeDrawingAreaProxy.h"
// #include "RemoteLayerTreeScrollingPerformanceData.h"
#include "UserMediaCaptureManagerProxy.h"
#include "VideoPresentationManagerProxy.h"
#include "VideoPresentationManagerProxyMessages.h"
#include "WKTextExtractionUtilities.h"
// #include "WebPrivacyHelpers.h"
#include <WebCore/AttributedString.h>
#include <WebCore/CoreAudioCaptureDeviceManager.h>
#include <WebCore/LegacyWebArchive.h>
#include <WebCore/NullPlaybackSessionInterface.h>
#include <WebCore/PlaybackSessionInterfaceAVKitLegacy.h>
#include <WebCore/PlaybackSessionInterfaceMac.h>
#include <WebCore/PlaybackSessionInterfaceTVOS.h>
#include <WebCore/RunLoopObserver.h>
#include <WebCore/SystemBattery.h>
#include <objc/runtime.h>
#include <wtf/MachSendRight.h>
#include <wtf/cocoa/Entitlements.h>
#include <wtf/cocoa/RuntimeApplicationChecksCocoa.h>
#endif

#if PLATFORM(MAC)
// #include "DisplayLink.h"
#include <WebCore/ImageUtilities.h>
#include <WebCore/UTIUtilities.h>
#endif

#if PLATFORM(COCOA) || PLATFORM(GTK)
#include "ViewSnapshotStore.h"
#endif

#if PLATFORM(GTK)
#if USE(GBM)
#include "AcceleratedBackingStoreDMABuf.h"
#endif
#include <WebCore/SelectionData.h>
#endif

#if USE(CAIRO)
#include <WebCore/CairoUtilities.h>
#endif

#if ENABLE(WIRELESS_PLAYBACK_TARGET) && !PLATFORM(IOS_FAMILY)
// #include "MediaPlaybackTargetContextSerialized.h"
#include <WebCore/WebMediaSessionManager.h>
#endif

#if PLATFORM(IOS_FAMILY) || (PLATFORM(MAC) && ENABLE(VIDEO_PRESENTATION_MODE))
#include "PlaybackSessionManagerProxy.h"
#endif

#if ENABLE(WEB_AUTHN)
#include "WebAuthenticatorCoordinatorProxy.h"
#endif

#if ENABLE(REMOTE_INSPECTOR)
#include <JavaScriptCore/JSRemoteInspector.h>
#include <JavaScriptCore/RemoteInspector.h>
#endif

// #if HAVE(SEC_KEY_PROXY)
// #include "SecKeyProxyStore.h"
// #endif

#if HAVE(APP_SSO)
#include "SOAuthorizationCoordinator.h"
#endif

#if ENABLE(DEVICE_ORIENTATION) && PLATFORM(IOS_FAMILY)
#include "WebDeviceOrientationUpdateProviderProxy.h"
#endif

// #if ENABLE(DATA_DETECTION)
// #include "DataDetectionResult.h"
// #endif

// #if ENABLE(MEDIA_USAGE)
// #include "MediaUsageManager.h"
// #endif

// #if PLATFORM(COCOA)
// #include "DefaultWebBrowserChecks.h"
// #endif

#if ENABLE(MEDIA_SESSION_COORDINATOR)
#include "MediaSessionCoordinatorProxyPrivate.h"
#include "RemoteMediaSessionCoordinatorProxy.h"
#endif

#if HAVE(GROUP_ACTIVITIES)
#include "GroupActivitiesSessionNotifier.h"
#endif

#if ENABLE(APP_HIGHLIGHTS)
#include <WebCore/HighlightVisibility.h>
#endif

// #if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
// #import "DisplayCaptureSessionManager.h"
// #endif

#if HAVE(SCREEN_CAPTURE_KIT)
#import <WebCore/ScreenCaptureKitSharingSessionManager.h>
#endif

#if USE(QUICK_LOOK)
#include <WebCore/PreviewConverter.h>
#endif

#if USE(SYSTEM_PREVIEW)
#include "SystemPreviewController.h"
#endif

#if USE(COORDINATED_GRAPHICS)
#include "DrawingAreaProxyCoordinatedGraphics.h"
#endif

#if ENABLE(WK_WEB_EXTENSIONS) && PLATFORM(COCOA)
#include "WebExtensionController.h"
#endif

#if PLATFORM(COCOA)
#include <wtf/spi/darwin/SandboxSPI.h>
#endif

#if PLATFORM(IOS_FAMILY)
#import <pal/system/ios/Device.h>
#endif

#if USE(GLIB_EVENT_LOOP)
#include <wtf/glib/RunLoopSourcePriority.h>
#endif

#if PLATFORM(IOS_FAMILY) && ENABLE(MODEL_PROCESS)
#include "ModelPresentationManagerProxy.h"
#endif

#define MESSAGE_CHECK(process, assertion) MESSAGE_CHECK_BASE(assertion, process->connection())
#define MESSAGE_CHECK_URL(process, url) MESSAGE_CHECK_BASE(checkURLReceivedFromCurrentOrPreviousWebProcess(process, url), process->connection())
#define MESSAGE_CHECK_URL_COROUTINE(process, url) MESSAGE_CHECK_BASE_COROUTINE(checkURLReceivedFromCurrentOrPreviousWebProcess(process, url), process->connection())
#define MESSAGE_CHECK_COMPLETION(process, assertion, completion) MESSAGE_CHECK_COMPLETION_BASE(assertion, process->connection(), completion)
#define MESSAGE_CHECK_URL_COMPLETION(process, url, completion) MESSAGE_CHECK_COMPLETION_BASE(checkURLReceivedFromCurrentOrPreviousWebProcess(process, url), process->connection(), completion)

namespace WebKit {

using namespace WebCore;

WebPageProxyMessageHandler* WebPageProxyMessageHandler::create(WebPageProxy* proxy)
{
    return new WebPageProxyMessageHandler(proxy);
}

WebPageProxyMessageHandler::WebPageProxyMessageHandler(WebPageProxy* proxy) : m_proxy(proxy) {

}

void WebPageProxyMessageHandler::handleMessage(IPC::Connection& connection, const String& messageName, const WebKit::UserData& messageBody)
{
    ASSERT(&protectedLegacyMainFrameProcess()->connection() == &connection || preferences().siteIsolationEnabled());
    m_proxy->handleMessageShared(protectedLegacyMainFrameProcess(), messageName, messageBody);
}

void WebPageProxyMessageHandler::handleMessageWithAsyncReply(const String& messageName, const UserData& messageBody, CompletionHandler<void(UserData&&)>&& completionHandler)
{
    m_proxy->handleMessageWithAsyncReply(messageName, messageBody, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::handleSynchronousMessage(IPC::Connection& connection, const String& messageName, const UserData& messageBody, CompletionHandler<void(UserData&&)>&& completionHandler)
{
    m_proxy->handleSynchronousMessage(connection, messageName, messageBody, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::shouldGoToBackForwardListItem(BackForwardItemIdentifier itemID, bool inBackForwardCache, CompletionHandler<void(WebCore::ShouldGoToHistoryItem)>&& completionHandler)
{
    m_proxy->shouldGoToBackForwardListItem(itemID, inBackForwardCache, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::shouldGoToBackForwardListItemSync(BackForwardItemIdentifier itemID, CompletionHandler<void(WebCore::ShouldGoToHistoryItem)>&& completionHandler)
{
    m_proxy->shouldGoToBackForwardListItem(itemID, false, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::createInspectorTarget(IPC::Connection& connection, const String& targetId, Inspector::InspectorTargetType type)
{
    MESSAGE_CHECK_BASE(!targetId.isEmpty(), connection);
    inspectorController().createInspectorTarget(targetId, type);
}

void WebPageProxyMessageHandler::destroyInspectorTarget(IPC::Connection& connection, const String& targetId)
{
    MESSAGE_CHECK_BASE(!targetId.isEmpty(), connection);
    inspectorController().destroyInspectorTarget(targetId);
}

void WebPageProxyMessageHandler::sendMessageToInspectorFrontend(const String& targetId, const String& message)
{
    inspectorController().sendMessageToInspectorFrontend(targetId, message);
}

void WebPageProxyMessageHandler::didUpdateRenderingAfterCommittingLoad()
{
    m_proxy->didUpdateRenderingAfterCommittingLoad();
}

#if PLATFORM(GTK)
void WebPageProxyMessageHandler::startDrag(SelectionData&& selectionData, OptionSet<WebCore::DragOperation> dragOperationMask, std::optional<ShareableBitmap::Handle>&& dragImageHandle, IntPoint&& dragImageHotspot)
{
    m_proxy->startDrag(WTFMove(selectionData), dragOperationMask, WTFMove(dragimageHandle), dragImageHotspot);
}
#endif

void WebPageProxyMessageHandler::enableAccessibilityForAllProcesses()
{
    forEachWebContentProcess([&](auto& webProcess, auto pageID) {
        webProcess.send(Messages::WebPage::EnableAccessibility(), pageID);
    });
}

void WebPageProxyMessageHandler::fixedLayoutSizeDidChange(IntSize size)
{
    m_proxy->fixedLayoutSizeDidChange(size);
}

static bool scaleFactorIsValidForMessage(double scaleFactor)
{
    return scaleFactor > 0 && scaleFactor <= 100;
}

void WebPageProxyMessageHandler::pageScaleFactorDidChange(IPC::Connection& connection, double scaleFactor)
{
    m_proxy->pageScaleFactorDidChange(connection, scaleFactor);
}

void WebPageProxyMessageHandler::viewScaleFactorDidChange(IPC::Connection& connection, double scaleFactor)
{
    MESSAGE_CHECK_BASE(scaleFactorIsValidForMessage(scaleFactor), connection);
    if (!protectedLegacyMainFrameProcess()->hasConnection(connection))
        return;

    forEachWebContentProcess([&] (auto& process, auto pageID) {
        if (&process == &protectedLegacyMainFrameProcess().get())
            return;
        process.send(Messages::WebPage::DidScaleView(scaleFactor), pageID);
    });
}

void WebPageProxyMessageHandler::pluginScaleFactorDidChange(IPC::Connection& connection, double pluginScaleFactor)
{
    m_proxy->pluginScaleFactorDidChange(connection, pluginScaleFactor);
}

void WebPageProxyMessageHandler::pluginZoomFactorDidChange(IPC::Connection& connection, double pluginZoomFactor)
{
    m_proxy->pluginZoomFactorDidChange(connection, pluginZoomFactor);
}

void WebPageProxyMessageHandler::didCreateSubframe(FrameIdentifier parentID, FrameIdentifier newFrameID, const String& frameName, SandboxFlags sandboxFlags, ScrollbarMode scrollingMode)
{
    RefPtr parent = WebFrameProxy::webFrame(parentID);
    if (!parent)
        return;
    parent->didCreateSubframe(newFrameID, frameName, sandboxFlags, scrollingMode);
}

void WebPageProxyMessageHandler::didDestroyFrame(IPC::Connection& connection, FrameIdentifier frameID)
{
    m_proxy->didDestroyFrame(connection, frameID);
}

void WebPageProxyMessageHandler::didStartProgress()
{
    m_proxy->didStartProgress();
}

void WebPageProxyMessageHandler::didChangeProgress(double value)
{
    m_proxy->didChangeProgress(value);
}

void WebPageProxyMessageHandler::didFinishProgress()
{
    m_proxy->didFinishProgress();
}

void WebPageProxyMessageHandler::setNetworkRequestsInProgress(bool networkRequestsInProgress)
{
    m_proxy->setNetworkRequestsInProgress(networkRequestsInProgress);
}

void WebPageProxyMessageHandler::startNetworkRequestsForPageLoadTiming(WebCore::FrameIdentifier frameID)
{
    m_proxy->startNetworkRequestsForPageLoadTiming(frameID);
}

void WebPageProxyMessageHandler::endNetworkRequestsForPageLoadTiming(WebCore::FrameIdentifier frameID, WallTime timestamp)
{
    m_proxy->endNetworkRequestsForPageLoadTiming(frameID, timestamp);
}

void WebPageProxyMessageHandler::updateScrollingMode(IPC::Connection& connection, WebCore::FrameIdentifier frameID, WebCore::ScrollbarMode scrollingMode)
{
    if (RefPtr frame = WebFrameProxy::webFrame(frameID)) {
        RefPtr process = dynamicDowncast<WebProcessProxy>(AuxiliaryProcessProxy::fromConnection(connection));
        RefPtr parentFrame = frame->parentFrame();
        MESSAGE_CHECK(process, parentFrame && &parentFrame->process() == process.get());
        frame->updateScrollingMode(scrollingMode);
    }
}

void WebPageProxyMessageHandler::updateRemoteFrameSize(WebCore::FrameIdentifier frameID, WebCore::IntSize size)
{
    m_proxy->updateRemoteFrameSize(frameID, size);
}

void WebPageProxyMessageHandler::resolveAccessibilityHitTestForTesting(WebCore::FrameIdentifier frameID, WebCore::IntPoint point, CompletionHandler<void(String)>&& callback)
{
    m_proxy->sendWithAsyncReplyToProcessContainingFrame(frameID, Messages::WebPage::ResolveAccessibilityHitTestForTesting(frameID, point), WTFMove(callback));
}

void WebPageProxyMessageHandler::updateSandboxFlags(IPC::Connection& connection, WebCore::FrameIdentifier frameID, WebCore::SandboxFlags sandboxFlags)
{
    if (RefPtr frame = WebFrameProxy::webFrame(frameID)) {
        RefPtr process = dynamicDowncast<WebProcessProxy>(AuxiliaryProcessProxy::fromConnection(connection));
        RefPtr parentFrame = frame->parentFrame();
        MESSAGE_CHECK(process, parentFrame && &parentFrame->process() == process.get());
        frame->updateSandboxFlags(sandboxFlags);
    }
}

void WebPageProxyMessageHandler::updateOpener(IPC::Connection& connection, WebCore::FrameIdentifier frameID, WebCore::FrameIdentifier newOpener)
{
    if (RefPtr frame = WebFrameProxy::webFrame(frameID))
        frame->updateOpener(newOpener);
    forEachWebContentProcess([&](auto& webProcess, auto pageID) {
        if (webProcess.hasConnection(connection))
            return;
        webProcess.send(Messages::WebPage::UpdateOpener(frameID, newOpener), pageID);
    });
}

void WebPageProxyMessageHandler::didDestroyNavigation(WebCore::NavigationIdentifier navigationID)
{
    m_proxy->didDestroyNavigation(navigationID);
}

void WebPageProxyMessageHandler::didStartProvisionalLoadForFrame(FrameIdentifier frameID, FrameInfoData&& frameInfo, ResourceRequest&& request, std::optional<WebCore::NavigationIdentifier> navigationID, URL&& url, URL&& unreachableURL, const UserData& userData, WallTime timestamp)
{
    didStartProvisionalLoadForFrameShared(protectedLegacyMainFrameProcess(), frameID, WTFMove(frameInfo), WTFMove(request), navigationID, WTFMove(url), WTFMove(unreachableURL), userData, timestamp);
}

void WebPageProxyMessageHandler::didExplicitOpenForFrame(IPC::Connection& connection, FrameIdentifier frameID, URL&& url, String&& mimeType)
{
    m_proxy->didExplicitOpenForFrame(connection, frameID, WTFMove(url), WTFMove(mimeType));
}

void WebPageProxyMessageHandler::didReceiveServerRedirectForProvisionalLoadForFrame(FrameIdentifier frameID, std::optional<WebCore::NavigationIdentifier> navigationID, ResourceRequest&& request, const UserData& userData)
{
    didReceiveServerRedirectForProvisionalLoadForFrameShared(protectedLegacyMainFrameProcess(), frameID, navigationID, WTFMove(request), userData);
}

void WebPageProxyMessageHandler::willPerformClientRedirectForFrame(IPC::Connection& connection, FrameIdentifier frameID, const String& url, double delay, LockBackForwardList lockBackForwardList)
{
    m_proxy->willPerformClientRedirectForFrame(connection, frameID, url, delay, lockBackForwardList);
}

void WebPageProxyMessageHandler::didCancelClientRedirectForFrame(IPC::Connection& connection, FrameIdentifier frameID)
{
    m_proxy->didCancelClientRedirectForFrame(connection, frameID);
}

void WebPageProxyMessageHandler::didChangeProvisionalURLForFrame(FrameIdentifier frameID, std::optional<WebCore::NavigationIdentifier> navigationID, URL&& url)
{
    m_proxy->didChangeProvisionalURLForFrame(frameID, navigationID, WTFMove(url));
}

void WebPageProxyMessageHandler::didFailProvisionalLoadForFrame(IPC::Connection& connection, FrameInfoData&& frameInfo, ResourceRequest&& request, std::optional<WebCore::NavigationIdentifier> navigationID, const String& provisionalURL, const ResourceError& error, WillContinueLoading willContinueLoading, const UserData& userData, WillInternallyHandleFailure willInternallyHandleFailure)
{
    m_proxy->didFailProvisionalLoadForFrame(connection, WTFMove(frameInfo), WTFMove(request), navigationID, provisionalURL, error, willContinueLoading, userData, willInternallyHandleFailure);
}

void WebPageProxyMessageHandler::didFinishServiceWorkerPageRegistration(bool success)
{
    m_proxy->didFinishServiceWorkerPageRegistration(success);
}

void WebPageProxyMessageHandler::didCommitLoadForFrame(IPC::Connection& connection, FrameIdentifier frameID, FrameInfoData&& frameInfo, ResourceRequest&& request, std::optional<WebCore::NavigationIdentifier> navigationID, const String& mimeType, bool frameHasCustomContentProvider, FrameLoadType frameLoadType, const CertificateInfo& certificateInfo, bool usedLegacyTLS, bool wasPrivateRelayed, const String& proxyName, const WebCore::ResourceResponseSource source, bool containsPluginDocument, HasInsecureContent hasInsecureContent, MouseEventPolicy mouseEventPolicy, const UserData& userData)
{
    m_proxy->didCommitLoadForFrame(connection, frameID, WTFMove(frameInfo), WTFMove(request), navigationID, mimeType, frameHasCustomContentProvider, frameLoadType, certificateInfo, usedLegacyTLS, wasPrivateRelayed, proxyName, source, containsPluginDocument, hasInsecureContent, mouseEventPolicy, userData);
}

void WebPageProxyMessageHandler::didFinishDocumentLoadForFrame(IPC::Connection& connection, FrameIdentifier frameID, std::optional<WebCore::NavigationIdentifier> navigationID, const UserData& userData, WallTime timestamp)
{
    m_proxy->didFinishDocumentLoadForFrame(connection, frameID, navigationID, userData, timestamp);
}

void WebPageProxyMessageHandler::broadcastProcessSyncData(IPC::Connection& connection, const WebCore::ProcessSyncData& data)
{
    forEachWebContentProcess([&](auto& webProcess, auto pageID) {
        if (!webProcess.hasConnection() || &webProcess.connection() == &connection)
            return;
        webProcess.send(Messages::WebPage::ProcessSyncDataChangedInAnotherProcess(data), pageID);
    });
}

void WebPageProxyMessageHandler::broadcastTopDocumentSyncData(IPC::Connection& connection, Ref<WebCore::DocumentSyncData>&& data)
{
    forEachWebContentProcess([&](auto& webProcess, auto pageID) {
        if (!webProcess.hasConnection() || &webProcess.connection() == &connection)
            return;
        webProcess.send(Messages::WebPage::TopDocumentSyncDataChangedInAnotherProcess(data), pageID);
    });
}

void WebPageProxyMessageHandler::didFinishLoadForFrame(IPC::Connection& connection, FrameIdentifier frameID, FrameInfoData&& frameInfo, ResourceRequest&& request, std::optional<WebCore::NavigationIdentifier> navigationID, const UserData& userData)
{
    m_proxy->didFinishLoadForFrame(connection, frameID, WTFMove(frameInfo), WTFMove(request), navigationID, userData);
}

void WebPageProxyMessageHandler::didFailLoadForFrame(IPC::Connection& connection, FrameIdentifier frameID, FrameInfoData&& frameInfo, ResourceRequest&& request, std::optional<WebCore::NavigationIdentifier> navigationID, const ResourceError& error, const UserData& userData)
{
    m_proxy->didFailLoadForFrame(connection, frameID, WTFMove(frameInfo), WTFMove(request), navigationID, error, userData);
}

void WebPageProxyMessageHandler::didSameDocumentNavigationForFrame(IPC::Connection& connection, FrameIdentifier frameID, std::optional<WebCore::NavigationIdentifier> navigationID, SameDocumentNavigationType navigationType, URL&& url, const UserData& userData)
{
    m_proxy->didSameDocumentNavigationForFrame(connection, frameID, navigationID, navigationType, WTFMove(url), userData);
}

void WebPageProxyMessageHandler::didSameDocumentNavigationForFrameViaJS(IPC::Connection& connection, SameDocumentNavigationType navigationType, URL url, NavigationActionData&& navigationActionData, const UserData& userData)
{
    m_proxy->didSameDocumentNavigationForFrameViaJS(connection, navigationType, WTFMove(url), WTFMove(navigationActionData), userData);
}

void WebPageProxyMessageHandler::didChangeMainDocument(FrameIdentifier frameID, std::optional<NavigationIdentifier> navigationID)
{
    m_proxy->didChangeMainDocument(frameID, navigationID);
}

void WebPageProxyMessageHandler::didReceiveTitleForFrame(IPC::Connection& connection, FrameIdentifier frameID, const String& title, const UserData& userData)
{
    m_proxy->didReceiveTitleForFrame(connection, frameID, title, userData);
}

void WebPageProxyMessageHandler::didFirstLayoutForFrame(FrameIdentifier, const UserData& userData)
{
}

void WebPageProxyMessageHandler::didFirstVisuallyNonEmptyLayoutForFrame(IPC::Connection& connection, FrameIdentifier frameID, const UserData& userData, WallTime timestamp)
{
    m_proxy->didFirstVisuallyNonEmptyLayoutForFrame(connection, frameID, userData, timestamp);
}

void WebPageProxyMessageHandler::didReachLayoutMilestone(OptionSet<WebCore::LayoutMilestone> layoutMilestones, WallTime timestamp)
{
    m_proxy->didReachLayoutMilestone(layoutMilestones, timestamp);
}

void WebPageProxyMessageHandler::didDisplayInsecureContentForFrame(IPC::Connection& connection, FrameIdentifier frameID, const UserData& userData)
{
    m_proxy->didDisplayInsecureContentForFrame(connection, frameID, userData);
}

void WebPageProxyMessageHandler::didRunInsecureContentForFrame(IPC::Connection& connection, FrameIdentifier frameID, const UserData& userData)
{
    m_proxy->didRunInsecureContentForFrame(connection, frameID, userData);
}

void WebPageProxyMessageHandler::mainFramePluginHandlesPageScaleGestureDidChange(bool mainFramePluginHandlesPageScaleGesture, double minScale, double maxScale)
{
    m_proxy->mainFramePluginHandlesPageScaleGestureDidChange(mainFramePluginHandlesPageScaleGesture, minScale, maxScale);
}

#if !PLATFORM(COCOA)
void WebPageProxyMessageHandler::beginSafeBrowsingCheck(const URL&, bool, WebFramePolicyListenerProxy& listener)
{
    listener.didReceiveSafeBrowsingResults({ });
}
#endif

void WebPageProxyMessageHandler::decidePolicyForNavigationActionAsync(NavigationActionData&& data, CompletionHandler<void(PolicyDecision&&)>&& completionHandler)
{
    m_proxy->decidePolicyForNavigationActionAsync(WTFMove(data), WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::decidePolicyForNavigationActionSync(IPC::Connection& connection, NavigationActionData&& data, CompletionHandler<void(PolicyDecision&&)>&& reply)
{
    m_proxy->decidePolicyForNavigationActionSync(connection, WTFMove(data), WTFMove(reply));
}

void WebPageProxyMessageHandler::decidePolicyForNewWindowAction(IPC::Connection& connection, NavigationActionData&& navigationActionData, const String& frameName, CompletionHandler<void(PolicyDecision&&)>&& completionHandler)
{
    m_proxy->decidePolicyForNewWindowAction(connection, WTFMove(navigationActionData), frameName, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::decidePolicyForResponse(IPC::Connection& connection, FrameInfoData&& frameInfo, std::optional<WebCore::NavigationIdentifier> navigationID, const ResourceResponse& response, const ResourceRequest& request, bool canShowMIMEType, const String& downloadAttribute, bool isShowingInitialAboutBlank, WebCore::CrossOriginOpenerPolicyValue activeDocumentCOOPValue, CompletionHandler<void(PolicyDecision&&)>&& completionHandler)
{
    m_proxy->decidePolicyForResponse(connection, WTFMove(frameInfo), navigationID, response, request, canShowMIMEType, downloadAttribute, isShowingInitialAboutBlank, activeDocumentCOOPValue, WTFMove(completionHandler));
}

// FormClient

void WebPageProxyMessageHandler::willSubmitForm(IPC::Connection& connection, FrameIdentifier frameID, FrameIdentifier sourceFrameID, const Vector<std::pair<String, String>>& textFieldValues, const UserData& userData, CompletionHandler<void()>&& completionHandler)
{
    m_proxy->willSubmitForm(connection, frameID, sourceFrameID, textFieldValues, userData, WTFMove(completionHandler));
}

#if ENABLE(CONTENT_EXTENSIONS)
void WebPageProxyMessageHandler::contentRuleListNotification(URL&& url, ContentRuleListResults&& results)
{
    m_proxy->contentRuleListNotification(WTFMove(url), WTFMove(results));
}
#endif

void WebPageProxyMessageHandler::didNavigateWithNavigationData(const WebNavigationDataStore& store, FrameIdentifier frameID)
{
    m_proxy->didNavigateWithNavigationData(store, frameID);
}

void WebPageProxyMessageHandler::didPerformClientRedirect(const String& sourceURLString, const String& destinationURLString, FrameIdentifier frameID)
{
    m_proxy->didPerformClientRedirect(sourceURLString, destinationURLString, frameID);
}

void WebPageProxyMessageHandler::didPerformServerRedirect(const String& sourceURLString, const String& destinationURLString, FrameIdentifier frameID)
{
    m_proxy->didPerformServerRedirect(sourceURLString, destinationURLString, frameID);
}

void WebPageProxyMessageHandler::didUpdateHistoryTitle(IPC::Connection& connection, const String& title, const String& url, FrameIdentifier frameID)
{
    m_proxy->didUpdateHistoryTitle(connection, title, url, frameID);
}

// UIClient

void WebPageProxyMessageHandler::createNewPage(IPC::Connection& connection, WindowFeatures&& windowFeatures, NavigationActionData&& navigationActionData, CompletionHandler<void(std::optional<WebCore::PageIdentifier>, std::optional<WebKit::WebPageCreationParameters>)>&& reply)
{
    m_proxy->createNewPage(connection, WTFMove(windowFeatures), WTFMove(navigationActionData), WTFMove(reply));
}

void WebPageProxyMessageHandler::showPage()
{
    m_proxy->showPage();
}

void WebPageProxyMessageHandler::closePage()
{
    m_proxy->closePage();
}

void WebPageProxyMessageHandler::runJavaScriptAlert(IPC::Connection& connection, FrameIdentifier frameID, FrameInfoData&& frameInfo, const String& message, CompletionHandler<void()>&& reply)
{
    m_proxy->runJavaScriptAlert(connection, frameID, WTFMove(frameInfo), message, WTFMove(reply));
}

void WebPageProxyMessageHandler::runJavaScriptConfirm(IPC::Connection& connection, FrameIdentifier frameID, FrameInfoData&& frameInfo, const String& message, CompletionHandler<void(bool)>&& reply)
{
    m_proxy->runJavaScriptConfirm(connection, frameID, WTFMove(frameInfo), message, WTFMove(reply));
}

void WebPageProxyMessageHandler::runJavaScriptPrompt(IPC::Connection& connection, FrameIdentifier frameID, FrameInfoData&& frameInfo, const String& message, const String& defaultValue, CompletionHandler<void(const String&)>&& reply)
{
    m_proxy->runJavaScriptPrompt(connection, frameID, WTFMove(frameInfo), message, defaultValue, WTFMove(reply));
}

void WebPageProxyMessageHandler::mouseDidMoveOverElement(WebHitTestResultData&& hitTestResultData, OptionSet<WebEventModifier> modifiers, UserData&& userData)
{
    m_proxy->mouseDidMoveOverElement(WTFMove(hitTestResultData), modifiers, WTFMove(userData));
}

void WebPageProxyMessageHandler::setToolbarsAreVisible(bool toolbarsAreVisible)
{
    uiClient()->setToolbarsAreVisible(*m_proxy, toolbarsAreVisible);
}

void WebPageProxyMessageHandler::getToolbarsAreVisible(CompletionHandler<void(bool)>&& reply)
{
    uiClient()->toolbarsAreVisible(*m_proxy, WTFMove(reply));
}

void WebPageProxyMessageHandler::setMenuBarIsVisible(bool menuBarIsVisible)
{
    uiClient()->setMenuBarIsVisible(*m_proxy, menuBarIsVisible);
}

void WebPageProxyMessageHandler::getMenuBarIsVisible(CompletionHandler<void(bool)>&& reply)
{
    uiClient()->menuBarIsVisible(*m_proxy, WTFMove(reply));
}

void WebPageProxyMessageHandler::setStatusBarIsVisible(bool statusBarIsVisible)
{
    uiClient()->setStatusBarIsVisible(*m_proxy, statusBarIsVisible);
}

void WebPageProxyMessageHandler::getStatusBarIsVisible(CompletionHandler<void(bool)>&& reply)
{
    uiClient()->statusBarIsVisible(*m_proxy, WTFMove(reply));
}

void WebPageProxyMessageHandler::setIsResizable(bool isResizable)
{
    uiClient()->setIsResizable(*m_proxy, isResizable);
}

void WebPageProxyMessageHandler::setWindowFrame(const FloatRect& newWindowFrame)
{
    m_proxy->setWindowFrame(newWindowFrame);
}

void WebPageProxyMessageHandler::getWindowFrame(CompletionHandler<void(const FloatRect&)>&& reply)
{
    WebPageProxy* proxy = &*m_proxy;
    uiClient()->windowFrame(*proxy, [proxy, protectedProxy = Ref { *proxy }, reply = WTFMove(reply)] (FloatRect frame) mutable {
        RefPtr pageClient = proxy->pageClient();
        reply(pageClient ? pageClient->convertToUserSpace(frame) : FloatRect { });
    });
}

void WebPageProxyMessageHandler::getWindowFrameWithCallback(Function<void(FloatRect)>&& completionHandler)
{
    m_proxy->getWindowFrameWithCallback(WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::screenToRootView(const IntPoint& screenPoint, CompletionHandler<void(const IntPoint&)>&& reply)
{
    RefPtr pageClient = this->pageClient();
    reply(pageClient ? pageClient->screenToRootView(screenPoint) : IntPoint { });
}

void WebPageProxyMessageHandler::rootViewPointToScreen(const IntPoint& viewPoint, CompletionHandler<void(const IntPoint&)>&& reply)
{
    RefPtr pageClient = this->pageClient();
    reply(pageClient ? pageClient->rootViewToScreen(viewPoint) : IntPoint { });
}

void WebPageProxyMessageHandler::rootViewRectToScreen(const IntRect& viewRect, CompletionHandler<void(const IntRect&)>&& reply)
{
    RefPtr pageClient = this->pageClient();
    reply(pageClient ? pageClient->rootViewToScreen(viewRect) : IntRect { });
}

void WebPageProxyMessageHandler::accessibilityScreenToRootView(const IntPoint& screenPoint, CompletionHandler<void(IntPoint)>&& completionHandler)
{
    RefPtr pageClient = this->pageClient();
    if (!pageClient)
        return completionHandler({ });
    completionHandler(pageClient->accessibilityScreenToRootView(screenPoint));
}

void WebPageProxyMessageHandler::rootViewToAccessibilityScreen(const IntRect& viewRect, CompletionHandler<void(IntRect)>&& completionHandler)
{
    RefPtr pageClient = this->pageClient();
    if (!pageClient)
        return completionHandler({ });
    completionHandler(pageClient->rootViewToAccessibilityScreen(viewRect));
}

void WebPageProxyMessageHandler::runBeforeUnloadConfirmPanel(IPC::Connection& connection, FrameIdentifier frameID, FrameInfoData&& frameInfo, const String& message, CompletionHandler<void(bool)>&& reply)
{
    m_proxy->runBeforeUnloadConfirmPanel(connection, frameID, WTFMove(frameInfo), message, WTFMove(reply));
}

void WebPageProxyMessageHandler::pageDidScroll(const WebCore::IntPoint& scrollPosition)
{
    m_proxy->pageDidScroll(scrollPosition);
}

void WebPageProxyMessageHandler::setHasActiveAnimatedScrolls(bool isRunning)
{
    m_proxy->setHasActiveAnimatedScrolls(isRunning);
}

void WebPageProxyMessageHandler::runOpenPanel(IPC::Connection& connection, FrameIdentifier frameID, FrameInfoData&& frameInfo, const FileChooserSettings& settings)
{
    m_proxy->runOpenPanel(connection, frameID, WTFMove(frameInfo), settings);
}

void WebPageProxyMessageHandler::showShareSheet(IPC::Connection& connection, const ShareDataWithParsedURL& shareData, CompletionHandler<void(bool)>&& completionHandler)
{
    MESSAGE_CHECK_BASE(!shareData.url || shareData.url->protocolIsInHTTPFamily() || shareData.url->protocolIsData(), connection);
    MESSAGE_CHECK_BASE(shareData.files.isEmpty() || protectedPreferences()->webShareFileAPIEnabled(), connection);
    MESSAGE_CHECK_BASE(shareData.originator == ShareDataOriginator::Web, connection);
    if (RefPtr pageClient = this->pageClient())
        pageClient->showShareSheet(shareData, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::showContactPicker(IPC::Connection& connection, const ContactsRequestData& requestData, CompletionHandler<void(std::optional<Vector<ContactInfo>>&&)>&& completionHandler)
{
    MESSAGE_CHECK_BASE(protectedPreferences()->contactPickerAPIEnabled(), connection);
    if (RefPtr pageClient = this->pageClient())
        pageClient->showContactPicker(requestData, WTFMove(completionHandler));
}

#if ENABLE(WEB_AUTHN)
void WebPageProxyMessageHandler::showDigitalCredentialsPicker(IPC::Connection& connection, const WebCore::DigitalCredentialsRequestData& requestData, WTF::CompletionHandler<void(Expected<WebCore::DigitalCredentialsResponseData, WebCore::ExceptionData>&&)>&& completionHandler)
{
    MESSAGE_CHECK_COMPLETION_BASE(
        protectedPreferences()->digitalCredentialsEnabled(),
        connection,
        completionHandler(makeUnexpected(WebCore::ExceptionData { WebCore::ExceptionCode::SecurityError, "Digital credentials feature is disabled by preference."_s }))
    );

#if HAVE(DIGITAL_CREDENTIALS_UI)
    MESSAGE_CHECK_COMPLETION_BASE(
        requestData.topOrigin.securityOrigin()->isSameOriginDomain(SecurityOrigin::create(protectedMainFrame()->url())),
        connection,
        completionHandler(makeUnexpected(WebCore::ExceptionData { WebCore::ExceptionCode::SecurityError, "Digital credentials request is not same-origin with main frame."_s }))
    );

    protectedPageClient()->showDigitalCredentialsPicker(requestData, WTFMove(completionHandler));
#else
    completionHandler(makeUnexpected(WebCore::ExceptionData { WebCore::ExceptionCode::NotSupportedError, "Digital credentials UI is not supported."_s }));
#endif
}

void WebPageProxyMessageHandler::dismissDigitalCredentialsPicker(IPC::Connection& connection, WTF::CompletionHandler<void(bool)>&& completionHandler)
{
    MESSAGE_CHECK_COMPLETION_BASE(
        protectedPreferences()->digitalCredentialsEnabled(),
        connection,
        completionHandler(false)
    );
#if HAVE(DIGITAL_CREDENTIALS_UI)
    protectedPageClient()->dismissDigitalCredentialsPicker(WTFMove(completionHandler));
#else
    completionHandler(false);
#endif
}
#endif // ENABLE(WEB_AUTHN)

void WebPageProxyMessageHandler::printFrame(IPC::Connection& connection, FrameIdentifier frameID, const String& title, const FloatSize& pdfFirstPageSize, CompletionHandler<void()>&& completionHandler)
{
    m_proxy->printFrame(connection, frameID, title, pdfFirstPageSize, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::didChangeContentSize(const IntSize& size)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->didChangeContentSize(size);
}

void WebPageProxyMessageHandler::didChangeIntrinsicContentSize(const IntSize& intrinsicContentSize)
{
    m_proxy->didChangeIntrinsicContentSize(intrinsicContentSize);
}

void WebPageProxyMessageHandler::showColorPicker(const WebCore::Color& initialColor, const IntRect& elementRect, ColorControlSupportsAlpha supportsAlpha, Vector<WebCore::Color>&& suggestions)
{
    m_proxy->showColorPicker(initialColor, elementRect, supportsAlpha, WTFMove(suggestions));
}

void WebPageProxyMessageHandler::setColorPickerColor(const WebCore::Color& color)
{
    m_proxy->setColorPickerColor(color);
}

void WebPageProxyMessageHandler::endColorPicker()
{
    m_proxy->endColorPicker();
}

void WebPageProxyMessageHandler::showDataListSuggestions(WebCore::DataListSuggestionInformation&& info)
{
    m_proxy->showDataListSuggestions(WTFMove(info));
}

void WebPageProxyMessageHandler::handleKeydownInDataList(const String& key)
{
    m_proxy->handleKeydownInDataList(key);
}

void WebPageProxyMessageHandler::endDataListSuggestions()
{
    m_proxy->endDataListSuggestions();
}

void WebPageProxyMessageHandler::showDateTimePicker(WebCore::DateTimeChooserParameters&& params)
{
    m_proxy->showDateTimePicker(WTFMove(params));
}

void WebPageProxyMessageHandler::endDateTimePicker()
{
    m_proxy->endDateTimePicker();
}

#if ENABLE(VIDEO_PRESENTATION_MODE)

void WebPageProxyMessageHandler::setMockVideoPresentationModeEnabled(bool enabled)
{
    m_proxy->setMockVideoPresentationModeEnabled(enabled);
}

#endif

void WebPageProxyMessageHandler::setHasFocusedElementWithUserInteraction(bool value)
{
    m_proxy->setHasFocusedElementWithUserInteraction(value);
}

#if HAVE(TOUCH_BAR)

void WebPageProxyMessageHandler::setIsTouchBarUpdateSuppressedForHiddenContentEditable(bool ignoreTouchBarUpdate)
{
    m_proxy->setIsTouchBarUpdateSuppressedForHiddenContentEditable(ignoreTouchBarUpdate);
}

void WebPageProxyMessageHandler::setIsNeverRichlyEditableForTouchBar(bool isNeverRichlyEditable)
{
    m_proxy->setIsNeverRichlyEditableForTouchBar(isNeverRichlyEditable);
}

#endif

void WebPageProxyMessageHandler::requestDOMPasteAccess(DOMPasteAccessCategory pasteAccessCategory, FrameIdentifier frameID, const IntRect& elementRect, const String& originIdentifier, CompletionHandler<void(DOMPasteAccessResponse)>&& completionHandler)
{
    m_proxy->requestDOMPasteAccess(pasteAccessCategory, frameID, elementRect, originIdentifier, WTFMove(completionHandler));
}

// BackForwardList

void WebPageProxyMessageHandler::backForwardAddItem(IPC::Connection& connection, Ref<FrameState>&& navigatedFrameState)
{
    m_proxy->backForwardAddItem(connection, WTFMove(navigatedFrameState));
}

void WebPageProxyMessageHandler::backForwardSetChildItem(BackForwardFrameItemIdentifier frameItemID, Ref<FrameState>&& frameState)
{
    m_proxy->backForwardSetChildItem(frameItemID, WTFMove(frameState));
}

void WebPageProxyMessageHandler::backForwardClearChildren(BackForwardItemIdentifier itemID, BackForwardFrameItemIdentifier frameItemID)
{
    if (RefPtr frameItem = WebBackForwardListFrameItem::itemForID(itemID, frameItemID))
        frameItem->clearChildren();
}

void WebPageProxyMessageHandler::backForwardUpdateItem(IPC::Connection& connection, Ref<FrameState>&& frameState)
{
    m_proxy->backForwardUpdateItem(connection, WTFMove(frameState));
}

void WebPageProxyMessageHandler::backForwardGoToItem(BackForwardItemIdentifier itemID, CompletionHandler<void(const WebBackForwardListCounts&)>&& completionHandler)
{
    m_proxy->backForwardGoToItem(itemID, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::backForwardListContainsItem(WebCore::BackForwardItemIdentifier itemID, CompletionHandler<void(bool)>&& completionHandler)
{
    m_proxy->backForwardListContainsItem(itemID, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::backForwardItemAtIndex(int32_t index, FrameIdentifier frameID, CompletionHandler<void(RefPtr<FrameState>&&)>&& completionHandler)
{
    m_proxy->backForwardItemAtIndex(index, frameID, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::backForwardListCounts(CompletionHandler<void(WebBackForwardListCounts&&)>&& completionHandler)
{
    m_proxy->backForwardListCounts(WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::compositionWasCanceled()
{
#if PLATFORM(COCOA)
    if (RefPtr pageClient = this->pageClient())
        pageClient->notifyInputContextAboutDiscardedComposition();
#endif
}

// Undo management

void WebPageProxyMessageHandler::registerEditCommandForUndo(IPC::Connection& connection, WebUndoStepID commandID, const String& label)
{
    m_proxy->registerEditCommandForUndo(connection, commandID, label);
}

void WebPageProxyMessageHandler::registerInsertionUndoGrouping()
{
#if USE(INSERTION_UNDO_GROUPING)
    if (RefPtr pageClient = this->pageClient())
        pageClient->registerInsertionUndoGrouping();
#endif
}

void WebPageProxyMessageHandler::canUndoRedo(UndoOrRedo action, CompletionHandler<void(bool)>&& completionHandler)
{
    RefPtr pageClient = this->pageClient();
    completionHandler(pageClient && pageClient->canUndoRedo(action));
}

void WebPageProxyMessageHandler::executeUndoRedo(UndoOrRedo action, CompletionHandler<void()>&& completionHandler)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->executeUndoRedo(action);
    completionHandler();
}

void WebPageProxyMessageHandler::clearAllEditCommands()
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->clearAllEditCommands();
}

void WebPageProxyMessageHandler::didGetImageForFindMatch(ImageBufferParameters&& parameters, ShareableBitmap::Handle&& contentImageHandle, uint32_t matchIndex)
{
    m_proxy->didGetImageForFindMatch(WTFMove(parameters), WTFMove(contentImageHandle), matchIndex);
}

void WebPageProxyMessageHandler::setTextIndicatorFromFrame(FrameIdentifier frameID, WebCore::TextIndicatorData&& indicatorData, uint64_t lifetime)
{
    m_proxy->setTextIndicatorFromFrame(frameID, WTFMove(indicatorData), lifetime);
}

void WebPageProxyMessageHandler::clearTextIndicator()
{
    m_proxy->clearTextIndicator();
}

void WebPageProxyMessageHandler::showPopupMenuFromFrame(IPC::Connection& connection, FrameIdentifier frameID, const IntRect& rect, uint64_t textDirection, Vector<WebPopupItem>&& items, int32_t selectedIndex, const PlatformPopupMenuData& data)
{
    m_proxy->showPopupMenuFromFrame(connection, frameID, rect, textDirection, WTFMove(items), selectedIndex, data);
}

void WebPageProxyMessageHandler::hidePopupMenu()
{
    m_proxy->hidePopupMenu();
}

void WebPageProxyMessageHandler::showContextMenuFromFrame(FrameInfoData&& frameInfo, ContextMenuContextData&& contextMenuContextData, UserData&& userData)
{
    m_proxy->showContextMenuFromFrame(WTFMove(frameInfo), WTFMove(contextMenuContextData), WTFMove(userData));
}

#if USE(UNIFIED_TEXT_CHECKING)
void WebPageProxyMessageHandler::checkTextOfParagraph(const String& text, OptionSet<TextCheckingType> checkingTypes, int32_t insertionPoint, CompletionHandler<void(Vector<WebCore::TextCheckingResult>&&)>&& completionHandler)
{
    completionHandler(TextChecker::checkTextOfParagraph(spellDocumentTag(), text, insertionPoint, checkingTypes, m_proxy->m_initialCapitalizationEnabled));
}
#endif

void WebPageProxyMessageHandler::checkSpellingOfString(const String& text, CompletionHandler<void(int32_t misspellingLocation, int32_t misspellingLength)>&& completionHandler)
{
    int32_t misspellingLocation = 0;
    int32_t misspellingLength = 0;
    TextChecker::checkSpellingOfString(spellDocumentTag(), text, misspellingLocation, misspellingLength);
    completionHandler(misspellingLocation, misspellingLength);
}

void WebPageProxyMessageHandler::checkGrammarOfString(const String& text, CompletionHandler<void(Vector<WebCore::GrammarDetail>&&, int32_t badGrammarLocation, int32_t badGrammarLength)>&& completionHandler)
{
    Vector<GrammarDetail> grammarDetails;
    int32_t badGrammarLocation = 0;
    int32_t badGrammarLength = 0;
    TextChecker::checkGrammarOfString(spellDocumentTag(), text, grammarDetails, badGrammarLocation, badGrammarLength);
    completionHandler(WTFMove(grammarDetails), badGrammarLocation, badGrammarLength);
}

void WebPageProxyMessageHandler::spellingUIIsShowing(CompletionHandler<void(bool)>&& completionHandler)
{
    completionHandler(TextChecker::spellingUIIsShowing());
}

void WebPageProxyMessageHandler::updateSpellingUIWithMisspelledWord(const String& misspelledWord)
{
    TextChecker::updateSpellingUIWithMisspelledWord(spellDocumentTag(), misspelledWord);
}

void WebPageProxyMessageHandler::updateSpellingUIWithGrammarString(const String& badGrammarPhrase, const GrammarDetail& grammarDetail)
{
    TextChecker::updateSpellingUIWithGrammarString(spellDocumentTag(), badGrammarPhrase, grammarDetail);
}

void WebPageProxyMessageHandler::getGuessesForWord(const String& word, const String& context, int32_t insertionPoint, CompletionHandler<void(Vector<String>&&)>&& completionHandler)
{
    Vector<String> guesses;
    TextChecker::getGuessesForWord(spellDocumentTag(), word, context, insertionPoint, guesses, m_proxy->m_initialCapitalizationEnabled);
    completionHandler(WTFMove(guesses));
}

void WebPageProxyMessageHandler::learnWord(IPC::Connection& connection, const String& word)
{
    m_proxy->learnWord(connection, word);
}

void WebPageProxyMessageHandler::ignoreWord(IPC::Connection& connection, const String& word)
{
    m_proxy->ignoreWord(connection, word);
}

void WebPageProxyMessageHandler::requestCheckingOfString(TextCheckerRequestID requestID, const TextCheckingRequestData& request, int32_t insertionPoint)
{
    TextChecker::requestCheckingOfString(TextCheckerCompletion::create(requestID, request, *m_proxy), insertionPoint);
}

void WebPageProxyMessageHandler::focusFromServiceWorker(CompletionHandler<void()>&& callback)
{
    m_proxy->focusFromServiceWorker(WTFMove(callback));
}

// Other

void WebPageProxyMessageHandler::setFocus(bool focused)
{
    m_proxy->setFocus(focused);
    if (focused)
        uiClient()->focus(&*m_proxy);
    else
        uiClient()->unfocus(&*m_proxy);
}

void WebPageProxyMessageHandler::takeFocus(WebCore::FocusDirection direction)
{
    if (uiClient()->takeFocus(&*m_proxy, (direction == WebCore::FocusDirection::Forward) ? kWKFocusDirectionForward : kWKFocusDirectionBackward))
        return;

    if (RefPtr pageClient = this->pageClient())
        pageClient->takeFocus(direction);
}

void WebPageProxyMessageHandler::setCursor(const WebCore::Cursor& cursor)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->setCursor(cursor);
}

void WebPageProxyMessageHandler::setCursorHiddenUntilMouseMoves(bool hiddenUntilMouseMoves)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->setCursorHiddenUntilMouseMoves(hiddenUntilMouseMoves);
}

void WebPageProxyMessageHandler::didReceiveEvent(WebEventType eventType, bool handled, std::optional<RemoteUserInputEventData> remoteUserInputEventData)
{
    m_proxy->didReceiveEvent(eventType, handled, remoteUserInputEventData);
}

void WebPageProxyMessageHandler::editorStateChanged(EditorState&& editorState)
{
    m_proxy->editorStateChanged(WTFMove(editorState));
}

void WebPageProxyMessageHandler::logDiagnosticMessageFromWebProcess(IPC::Connection& connection, const String& message, const String& description, WebCore::ShouldSample shouldSample)
{
    MESSAGE_CHECK_BASE(message.containsOnlyASCII(), connection);

    m_proxy->logDiagnosticMessage(message, description, shouldSample);
}

void WebPageProxyMessageHandler::logDiagnosticMessageWithResultFromWebProcess(IPC::Connection& connection, const String& message, const String& description, uint32_t result, WebCore::ShouldSample shouldSample)
{
    MESSAGE_CHECK_BASE(message.containsOnlyASCII(), connection);

    m_proxy->logDiagnosticMessageWithResult(message, description, result, shouldSample);
}

void WebPageProxyMessageHandler::logDiagnosticMessageWithValueFromWebProcess(IPC::Connection& connection, const String& message, const String& description, double value, unsigned significantFigures, ShouldSample shouldSample)
{
    MESSAGE_CHECK_BASE(message.containsOnlyASCII(), connection);

    m_proxy->logDiagnosticMessageWithValue(message, description, value, significantFigures, shouldSample);
}

void WebPageProxyMessageHandler::logDiagnosticMessageWithEnhancedPrivacyFromWebProcess(IPC::Connection& connection, const String& message, const String& description, WebCore::ShouldSample shouldSample)
{
    MESSAGE_CHECK_BASE(message.containsOnlyASCII(), connection);

    m_proxy->logDiagnosticMessageWithEnhancedPrivacy(message, description, shouldSample);
}

void WebPageProxyMessageHandler::logDiagnosticMessageWithValueDictionaryFromWebProcess(IPC::Connection& connection, const String& message, const String& description, const WebCore::DiagnosticLoggingClient::ValueDictionary& valueDictionary, WebCore::ShouldSample shouldSample)
{
    MESSAGE_CHECK_BASE(message.containsOnlyASCII(), connection);

    m_proxy->logDiagnosticMessageWithValueDictionary(message, description, valueDictionary, shouldSample);
}

void WebPageProxyMessageHandler::logDiagnosticMessageWithDomainFromWebProcess(IPC::Connection& connection, const String& message, WebCore::DiagnosticLoggingDomain domain)
{
    MESSAGE_CHECK_BASE(message.containsOnlyASCII(), connection);

    m_proxy->logDiagnosticMessageWithDomain(message, domain);
}

void WebPageProxyMessageHandler::logScrollingEvent(uint32_t eventType, MonotonicTime timestamp, uint64_t data)
{
    m_proxy->logScrollingEvent(eventType, timestamp, data);
}

void WebPageProxyMessageHandler::focusedFrameChanged(IPC::Connection& connection, const std::optional<FrameIdentifier>& frameID)
{
    m_proxy->focusedFrameChanged(connection, frameID);
}

void WebPageProxyMessageHandler::gamepadsRecentlyAccessed()
{
    m_proxy->gamepadsRecentlyAccessed();
}

void WebPageProxyMessageHandler::didApplyLinkDecorationFiltering(const URL& originalURL, const URL& adjustedURL)
{
    m_proxy->didApplyLinkDecorationFiltering(originalURL, adjustedURL);
}

void WebPageProxyMessageHandler::exceededDatabaseQuota(FrameIdentifier frameID, const String& originIdentifier, const String& databaseName, const String& displayName, uint64_t currentQuota, uint64_t currentOriginUsage, uint64_t currentDatabaseUsage, uint64_t expectedUsage, CompletionHandler<void(uint64_t)>&& reply)
{
    m_proxy->requestStorageSpace(frameID, originIdentifier, databaseName, displayName, currentQuota, currentOriginUsage, currentDatabaseUsage, expectedUsage, [reply = WTFMove(reply)](auto quota) mutable {
        reply(quota);
    });
}

void WebPageProxyMessageHandler::requestGeolocationPermissionForFrame(IPC::Connection& connection, GeolocationIdentifier geolocationID, FrameInfoData&& frameInfo)
{
    RefPtr frame = WebFrameProxy::webFrame(frameInfo.frameID);
    if (!frame)
        return;

    auto request = protectedGeolocationPermissionRequestManager()->createRequest(geolocationID, frame->protectedProcess());
    Function<void(bool)> completionHandler = [request = WTFMove(request)](bool allowed) {
        if (allowed)
            request->allow();
        else
            request->deny();
    };

    // FIXME: Once iOS migrates to the new WKUIDelegate SPI, clean this up
    // and make it one UIClient call that calls the completionHandler with false
    // if there is no delegate instead of returning the completionHandler
    // for other code paths to try.
    uiClient()->decidePolicyForGeolocationPermissionRequest(*m_proxy, *frame, frameInfo, completionHandler);
#if PLATFORM(IOS_FAMILY)
    if (RefPtr pageClient = this->pageClient(); completionHandler && pageClient)
        pageClient->decidePolicyForGeolocationPermissionRequest(*frame, frameInfo, completionHandler);
#endif
    if (completionHandler)
        completionHandler(false);
}

void WebPageProxyMessageHandler::revokeGeolocationAuthorizationToken(const String& authorizationToken)
{
    protectedGeolocationPermissionRequestManager()->revokeAuthorizationToken(authorizationToken);
}

void WebPageProxyMessageHandler::requestUserMediaPermissionForFrame(IPC::Connection& connection, UserMediaRequestIdentifier userMediaID, FrameInfoData&& frameInfo, const SecurityOriginData& userMediaDocumentOriginData, const SecurityOriginData& topLevelDocumentOriginData, MediaStreamRequest&& request)
{
    MESSAGE_CHECK_BASE(WebFrameProxy::webFrame(frameInfo.frameID), connection);
#if PLATFORM(MAC)
    CoreAudioCaptureDeviceManager::singleton().setFilterTapEnabledDevices(!protectedPreferences()->captureAudioInGPUProcessEnabled());
#endif
    protectedUserMediaPermissionRequestManager()->requestUserMediaPermissionForFrame(userMediaID, WTFMove(frameInfo), userMediaDocumentOriginData.securityOrigin(), topLevelDocumentOriginData.securityOrigin(), WTFMove(request));
}

void WebPageProxyMessageHandler::enumerateMediaDevicesForFrame(IPC::Connection& connection, FrameIdentifier frameID, const SecurityOriginData& userMediaDocumentOriginData, const SecurityOriginData& topLevelDocumentOriginData, CompletionHandler<void(const Vector<CaptureDeviceWithCapabilities>&, MediaDeviceHashSalts&&)>&& completionHandler)
{
    RefPtr frame = WebFrameProxy::webFrame(frameID);
    if (!frame)
        return;

    protectedUserMediaPermissionRequestManager()->enumerateMediaDevicesForFrame(frameID, userMediaDocumentOriginData.securityOrigin(), topLevelDocumentOriginData.securityOrigin(), WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::beginMonitoringCaptureDevices()
{
    protectedUserMediaPermissionRequestManager()->syncWithWebCorePrefs();
    UserMediaProcessManager::singleton().beginMonitoringCaptureDevices();
}

void WebPageProxyMessageHandler::validateCaptureStateUpdate(WebCore::UserMediaRequestIdentifier requestIdentifier, WebCore::ClientOrigin&& clientOrigin, FrameInfoData&& frameInfo, bool isActive, WebCore::MediaProducerMediaCaptureKind kind, CompletionHandler<void(std::optional<WebCore::Exception>&&)>&& completionHandler)
{
    m_proxy->validateCaptureStateUpdate(requestIdentifier, WTFMove(clientOrigin), WTFMove(frameInfo), isActive, kind, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::setShouldListenToVoiceActivity(bool value)
{
    m_proxy->setShouldListenToVoiceActivity(value);
}

void WebPageProxyMessageHandler::requestMediaKeySystemPermissionForFrame(IPC::Connection& connection, MediaKeySystemRequestIdentifier mediaKeySystemID, FrameIdentifier frameID, WebCore::ClientOrigin&& clientOrigin, const String& keySystem)
{
    m_proxy->requestMediaKeySystemPermissionForFrame(connection, mediaKeySystemID, frameID, WTFMove(clientOrigin), keySystem);
}

#if ENABLE(DEVICE_ORIENTATION)

void WebPageProxyMessageHandler::shouldAllowDeviceOrientationAndMotionAccess(IPC::Connection& connection, FrameIdentifier frameID, FrameInfoData&& frameInfo, bool mayPrompt, CompletionHandler<void(DeviceOrientationOrMotionPermissionState)>&& completionHandler)
{
    m_proxy->shouldAllowDeviceOrientationAndMotionAccess(connection, frameID, WTFMove(frameInfo), mayPrompt, WTFMove(completionHandler));
}

#endif

#if ENABLE(IMAGE_ANALYSIS)

void WebPageProxyMessageHandler::requestTextRecognition(const URL& imageURL, ShareableBitmap::Handle&& imageData, const String& sourceLanguageIdentifier, const String& targetLanguageIdentifier, CompletionHandler<void(TextRecognitionResult&&)>&& completionHandler)
{
    protectedPageClient()->requestTextRecognition(imageURL, WTFMove(imageData), sourceLanguageIdentifier, targetLanguageIdentifier, WTFMove(completionHandler));
}

#endif // ENABLE(IMAGE_ANALYSIS)

#if ENABLE(MEDIA_CONTROLS_CONTEXT_MENUS) && USE(UICONTEXTMENU)

void WebPageProxyMessageHandler::showMediaControlsContextMenu(FloatRect&& targetFrame, Vector<MediaControlsContextMenuItem>&& items, CompletionHandler<void(MediaControlsContextMenuItem::ID)>&& completionHandler)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->showMediaControlsContextMenu(WTFMove(targetFrame), WTFMove(items), WTFMove(completionHandler));
}

#endif // ENABLE(MEDIA_CONTROLS_CONTEXT_MENUS) && USE(UICONTEXTMENU)

void WebPageProxyMessageHandler::requestNotificationPermission(const String& originString, CompletionHandler<void(bool allowed)>&& completionHandler)
{
    m_proxy->requestNotificationPermission(originString, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::runModal()
{
    m_proxy->runModal();
}

void WebPageProxyMessageHandler::notifyScrollerThumbIsVisibleInRect(const IntRect& scrollerThumb)
{
    m_proxy->notifyScrollerThumbIsVisibleInRect(scrollerThumb);
}

void WebPageProxyMessageHandler::recommendedScrollbarStyleDidChange(int32_t newStyle)
{
#if USE(APPKIT)
    if (RefPtr pageClient = this->pageClient())
        pageClient->recommendedScrollbarStyleDidChange(static_cast<WebCore::ScrollbarStyle>(newStyle));
#else
    UNUSED_PARAM(newStyle);
#endif
}

void WebPageProxyMessageHandler::didChangeScrollbarsForMainFrame(bool hasHorizontalScrollbar, bool hasVerticalScrollbar)
{
    m_proxy->didChangeScrollbarsForMainFrame(hasHorizontalScrollbar, hasVerticalScrollbar);
}

void WebPageProxyMessageHandler::didChangeScrollOffsetPinningForMainFrame(RectEdges<bool> pinnedState)
{
    m_proxy->didChangeScrollOffsetPinningForMainFrame(pinnedState);
}

void WebPageProxyMessageHandler::didChangePageCount(unsigned pageCount)
{
    m_proxy->didChangePageCount(pageCount);
}

void WebPageProxyMessageHandler::themeColorChanged(const Color& themeColor)
{
    m_proxy->themeColorChanged(themeColor);
}

void WebPageProxyMessageHandler::pageExtendedBackgroundColorDidChange(const Color& newPageExtendedBackgroundColor)
{
    m_proxy->pageExtendedBackgroundColorDidChange(newPageExtendedBackgroundColor);
}

void WebPageProxyMessageHandler::sampledPageTopColorChanged(const Color& sampledPageTopColor)
{
    m_proxy->sampledPageTopColorChanged(sampledPageTopColor);
}

#if ENABLE(WEB_PAGE_SPATIAL_BACKDROP)
void WebPageProxyMessageHandler::spatialBackdropSourceChanged(std::optional<WebCore::SpatialBackdropSource>&& spatialBackdropSource)
{
    m_proxy->spatialBackdropSourceChanged(WTFMove(spatialBackdropSource));
}
#endif

void WebPageProxyMessageHandler::didFinishLoadingDataForCustomContentProvider(const String& suggestedFilename, std::span<const uint8_t> dataReference)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->didFinishLoadingDataForCustomContentProvider(ResourceResponseBase::sanitizeSuggestedFilename(suggestedFilename), dataReference);
}

#if USE(AUTOMATIC_TEXT_REPLACEMENT)

void WebPageProxyMessageHandler::toggleSmartInsertDelete()
{
    if (TextChecker::isTestingMode())
        TextChecker::setSmartInsertDeleteEnabled(!TextChecker::isSmartInsertDeleteEnabled());
}

void WebPageProxyMessageHandler::toggleAutomaticQuoteSubstitution()
{
    if (TextChecker::isTestingMode())
        TextChecker::setAutomaticQuoteSubstitutionEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled));
}

void WebPageProxyMessageHandler::toggleAutomaticLinkDetection()
{
    if (TextChecker::isTestingMode())
        TextChecker::setAutomaticLinkDetectionEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticLinkDetectionEnabled));
}

void WebPageProxyMessageHandler::toggleAutomaticDashSubstitution()
{
    if (TextChecker::isTestingMode())
        TextChecker::setAutomaticDashSubstitutionEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled));
}

void WebPageProxyMessageHandler::toggleAutomaticTextReplacement()
{
    if (TextChecker::isTestingMode())
        TextChecker::setAutomaticTextReplacementEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticTextReplacementEnabled));
}

#endif

#if USE(DICTATION_ALTERNATIVES)

void WebPageProxyMessageHandler::showDictationAlternativeUI(const WebCore::FloatRect& boundingBoxOfDictatedText, WebCore::DictationContext dictationContext)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->showDictationAlternativeUI(boundingBoxOfDictatedText, dictationContext);
}

void WebPageProxyMessageHandler::removeDictationAlternatives(WebCore::DictationContext dictationContext)
{
    m_proxy->removeDictationAlternatives(dictationContext);
}

void WebPageProxyMessageHandler::dictationAlternatives(WebCore::DictationContext dictationContext, CompletionHandler<void(Vector<String>&&)>&& completionHandler)
{
    RefPtr pageClient = this->pageClient();
    if (!pageClient)
        return completionHandler({ });
    completionHandler(protectedPageClient()->dictationAlternatives(dictationContext));
}

#endif

#if PLATFORM(MAC)

void WebPageProxyMessageHandler::substitutionsPanelIsShowing(CompletionHandler<void(bool)>&& completionHandler)
{
    completionHandler(TextChecker::substitutionsPanelIsShowing());
}

void WebPageProxyMessageHandler::showCorrectionPanel(AlternativeTextType panelType, const FloatRect& boundingBoxOfReplacedString, const String& replacedString, const String& replacementString, const Vector<String>& alternativeReplacementStrings)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->showCorrectionPanel(panelType, boundingBoxOfReplacedString, replacedString, replacementString, alternativeReplacementStrings);
}

void WebPageProxyMessageHandler::dismissCorrectionPanel(ReasonForDismissingAlternativeText reason)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->dismissCorrectionPanel(reason);
}

void WebPageProxyMessageHandler::dismissCorrectionPanelSoon(ReasonForDismissingAlternativeText reason, CompletionHandler<void(String)>&& completionHandler)
{
    RefPtr pageClient = this->pageClient();
    if (!pageClient)
        return completionHandler({ });
    completionHandler(protectedPageClient()->dismissCorrectionPanelSoon(reason));
}

void WebPageProxyMessageHandler::recordAutocorrectionResponse(AutocorrectionResponse response, const String& replacedString, const String& replacementString)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->recordAutocorrectionResponse(response, replacedString, replacementString);
}

void WebPageProxyMessageHandler::setEditableElementIsFocused(bool editableElementIsFocused)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->setEditableElementIsFocused(editableElementIsFocused);
}

#endif // PLATFORM(MAC)

void WebPageProxyMessageHandler::serializeAndWrapCryptoKey(IPC::Connection& connection, WebCore::CryptoKeyData&& keyData, CompletionHandler<void(std::optional<Vector<uint8_t>>&&)>&& completionHandler)
{
    m_proxy->serializeAndWrapCryptoKey(connection, WTFMove(keyData), WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::unwrapCryptoKey(WrappedCryptoKey&& wrappedKey, CompletionHandler<void(std::optional<Vector<uint8_t>>&&)>&& completionHandler)
{
    m_proxy->unwrapCryptoKey(WTFMove(wrappedKey), WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::isPlayingMediaDidChange(MediaProducerMediaStateFlags newState)
{
    m_proxy->isPlayingMediaDidChange(newState);
}

void WebPageProxyMessageHandler::handleAutoplayEvent(WebCore::AutoplayEvent event, OptionSet<AutoplayEventFlags> flags)
{
    uiClient()->handleAutoplayEvent(*m_proxy, event, flags);
}

void WebPageProxyMessageHandler::didPerformImmediateActionHitTest(WebHitTestResultData&& result, bool contentPreventsDefault, const UserData& userData)
{
    m_proxy->didPerformImmediateActionHitTest(WTFMove(result), contentPreventsDefault, userData);
}

void WebPageProxyMessageHandler::imageOrMediaDocumentSizeChanged(const WebCore::IntSize& newSize)
{
    uiClient()->imageOrMediaDocumentSizeChanged(newSize);
}

void WebPageProxyMessageHandler::handleAutoFillButtonClick(const UserData& userData)
{
    uiClient()->didClickAutoFillButton(*m_proxy, protectedLegacyMainFrameProcess()->transformHandlesToObjects(userData.protectedObject().get()).get());
}

void WebPageProxyMessageHandler::didResignInputElementStrongPasswordAppearance(const UserData& userData)
{
    uiClient()->didResignInputElementStrongPasswordAppearance(*m_proxy, protectedLegacyMainFrameProcess()->transformHandlesToObjects(userData.protectedObject().get()).get());
}

void WebPageProxyMessageHandler::performSwitchHapticFeedback()
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->performSwitchHapticFeedback();
}

#if ENABLE(WIRELESS_PLAYBACK_TARGET) && !PLATFORM(IOS_FAMILY)

void WebPageProxyMessageHandler::addPlaybackTargetPickerClient(PlaybackTargetClientContextIdentifier contextId)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->mediaSessionManager().addPlaybackTargetPickerClient(webMediaSessionManagerClient(), contextId);
}

void WebPageProxyMessageHandler::removePlaybackTargetPickerClient(PlaybackTargetClientContextIdentifier contextId)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->mediaSessionManager().removePlaybackTargetPickerClient(webMediaSessionManagerClient(), contextId);
}

void WebPageProxyMessageHandler::showPlaybackTargetPicker(PlaybackTargetClientContextIdentifier contextId, const WebCore::FloatRect& rect, bool hasVideo)
{
    if (RefPtr pageClient = this->pageClient()) {
        pageClient->mediaSessionManager().showPlaybackTargetPicker(webMediaSessionManagerClient(), contextId, protectedPageClient()->rootViewToScreen(IntRect(rect)), hasVideo, pageClient->effectiveAppearanceIsDark());
    }
}

void WebPageProxyMessageHandler::playbackTargetPickerClientStateDidChange(PlaybackTargetClientContextIdentifier contextId, WebCore::MediaProducerMediaStateFlags state)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->mediaSessionManager().clientStateDidChange(webMediaSessionManagerClient(), contextId, state);
}

void WebPageProxyMessageHandler::setMockMediaPlaybackTargetPickerEnabled(bool enabled)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->mediaSessionManager().setMockMediaPlaybackTargetPickerEnabled(enabled);
}

void WebPageProxyMessageHandler::setMockMediaPlaybackTargetPickerState(const String& name, WebCore::MediaPlaybackTargetContextMockState state)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->mediaSessionManager().setMockMediaPlaybackTargetPickerState(name, state);
}

void WebPageProxyMessageHandler::mockMediaPlaybackTargetPickerDismissPopup()
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->mediaSessionManager().mockMediaPlaybackTargetPickerDismissPopup();
}

#endif

void WebPageProxyMessageHandler::didRestoreScrollPosition()
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->didRestoreScrollPosition();
}

void WebPageProxyMessageHandler::getLoadDecisionForIcon(const WebCore::LinkIcon& icon, CallbackID loadIdentifier)
{
    m_proxy->getLoadDecisionForIcon(icon, loadIdentifier);
}

void WebPageProxyMessageHandler::hideValidationMessage()
{
    m_proxy->hideValidationMessage();
}

#if ENABLE(POINTER_LOCK)
void WebPageProxyMessageHandler::requestPointerLock()
{
    m_proxy->requestPointerLock();
}

void WebPageProxyMessageHandler::requestPointerUnlock()
{
    m_proxy->requestPointerUnlock();
}
#endif // ENABLE(POINTER_LOCK)

void WebPageProxyMessageHandler::startURLSchemeTask(IPC::Connection& connection, URLSchemeTaskParameters&& parameters)
{
    m_proxy->startURLSchemeTask(connection, WTFMove(parameters));
}

void WebPageProxyMessageHandler::stopURLSchemeTask(IPC::Connection& connection, WebURLSchemeHandlerIdentifier handlerIdentifier, WebCore::ResourceLoaderIdentifier taskIdentifier)
{
    m_proxy->stopURLSchemeTask(connection, handlerIdentifier, taskIdentifier);
}

void WebPageProxyMessageHandler::loadSynchronousURLSchemeTask(IPC::Connection& connection, URLSchemeTaskParameters&& parameters, CompletionHandler<void(const WebCore::ResourceResponse&, const WebCore::ResourceError&, Vector<uint8_t>&&)>&& reply)
{
    m_proxy->loadSynchronousURLSchemeTask(connection, WTFMove(parameters), WTFMove(reply));
}

#if ENABLE(ATTACHMENT_ELEMENT)

#if PLATFORM(IOS_FAMILY)
void WebPageProxyMessageHandler::writePromisedAttachmentToPasteboard(IPC::Connection& connection, PromisedAttachmentInfo&& info, const String& authorizationToken)
{
    MESSAGE_CHECK_BASE(isValidPerformActionOnElementAuthorizationToken(authorizationToken), connection);

    if (RefPtr pageClient = this->pageClient())
        pageClient->writePromisedAttachmentToPasteboard(WTFMove(info));
}
#endif

void WebPageProxyMessageHandler::requestAttachmentIcon(IPC::Connection& connection, const String& identifier, const String& contentType, const String& fileName, const String& title, const FloatSize& requestedSize)
{
    m_proxy->requestAttachmentIcon(connection, identifier, contentType, fileName, title, requestedSize);
}

void WebPageProxyMessageHandler::registerAttachmentIdentifierFromData(IPC::Connection& connection, const String& identifier, const String& contentType, const String& preferredFileName, const IPC::SharedBufferReference& data)
{
    m_proxy->registerAttachmentIdentifierFromData(connection, identifier, contentType, preferredFileName, data);
}

void WebPageProxyMessageHandler::registerAttachmentIdentifierFromFilePath(IPC::Connection& connection, const String& identifier, const String& contentType, const String& filePath)
{
    m_proxy->registerAttachmentIdentifierFromFilePath(connection, identifier, contentType, filePath);
}

void WebPageProxyMessageHandler::registerAttachmentIdentifier(IPC::Connection& connection, const String& identifier)
{
    m_proxy->registerAttachmentIdentifier(connection, identifier);
}

void WebPageProxyMessageHandler::registerAttachmentsFromSerializedData(IPC::Connection& connection, Vector<SerializedAttachmentData>&& data)
{
    m_proxy->registerAttachmentsFromSerializedData(connection, WTFMove(data));
}

void WebPageProxyMessageHandler::cloneAttachmentData(IPC::Connection& connection, const String& fromIdentifier, const String& toIdentifier)
{
    m_proxy->cloneAttachmentData(connection, fromIdentifier, toIdentifier);
}

void WebPageProxyMessageHandler::serializedAttachmentDataForIdentifiers(const Vector<String>& identifiers, CompletionHandler<void(Vector<WebCore::SerializedAttachmentData>&&)>&& completionHandler)
{
    m_proxy->serializedAttachmentDataForIdentifiers(identifiers, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::didInsertAttachmentWithIdentifier(IPC::Connection& connection, const String& identifier, const String& source, WebCore::AttachmentAssociatedElementType associatedElementType)
{
    m_proxy->didInsertAttachmentWithIdentifier(connection, identifier, source, associatedElementType);
}

void WebPageProxyMessageHandler::didRemoveAttachmentWithIdentifier(IPC::Connection& connection, const String& identifier)
{
    m_proxy->didRemoveAttachmentWithIdentifier(connection, identifier);
}

#endif // ENABLE(ATTACHMENT_ELEMENT)

#if ENABLE(SPEECH_SYNTHESIS)

void WebPageProxyMessageHandler::speechSynthesisVoiceList(CompletionHandler<void(Vector<WebSpeechSynthesisVoice>&&)>&& completionHandler)
{
    auto result = speechSynthesisData().protectedSynthesizer()->voiceList().map([](auto& voice) {
        return WebSpeechSynthesisVoice { voice->voiceURI(), voice->name(), voice->lang(), voice->localService(), voice->isDefault() };
    });
    completionHandler(WTFMove(result));
}

void WebPageProxyMessageHandler::speechSynthesisSetFinishedCallback(CompletionHandler<void()>&& completionHandler)
{
    speechSynthesisData().speakingFinishedCompletionHandler = WTFMove(completionHandler);
}

void WebPageProxyMessageHandler::speechSynthesisSpeak(const String& text, const String& lang, float volume, float rate, float pitch, MonotonicTime, const String& voiceURI, const String& voiceName, const String& voiceLang, bool localService, bool defaultVoice, CompletionHandler<void()>&& completionHandler)
{
    auto voice = WebCore::PlatformSpeechSynthesisVoice::create(voiceURI, voiceName, voiceLang, localService, defaultVoice);
    auto utterance = WebCore::PlatformSpeechSynthesisUtterance::create(m_proxy->internals());
    utterance->setText(text);
    utterance->setLang(lang);
    utterance->setVolume(volume);
    utterance->setRate(rate);
    utterance->setPitch(pitch);
    utterance->setVoice(&voice.get());

    speechSynthesisData().speakingStartedCompletionHandler = WTFMove(completionHandler);
    speechSynthesisData().utterance = WTFMove(utterance);
    speechSynthesisData().protectedSynthesizer()->speak(speechSynthesisData().utterance.get());
}

void WebPageProxyMessageHandler::speechSynthesisCancel()
{
    speechSynthesisData().protectedSynthesizer()->cancel();
}

void WebPageProxyMessageHandler::speechSynthesisResetState()
{
    speechSynthesisData().protectedSynthesizer()->resetState();
}

void WebPageProxyMessageHandler::speechSynthesisPause(CompletionHandler<void()>&& completionHandler)
{
    speechSynthesisData().speakingPausedCompletionHandler = WTFMove(completionHandler);
    speechSynthesisData().protectedSynthesizer()->pause();
}

void WebPageProxyMessageHandler::speechSynthesisResume(CompletionHandler<void()>&& completionHandler)
{
    speechSynthesisData().speakingResumedCompletionHandler = WTFMove(completionHandler);
    speechSynthesisData().protectedSynthesizer()->resume();
}

#endif // ENABLE(SPEECH_SYNTHESIS)

void WebPageProxyMessageHandler::configureLoggingChannel(const String& channelName, WTFLogChannelState state, WTFLogLevel level)
{
#if !RELEASE_LOG_DISABLED
    auto* channel = getLogChannel(channelName);
    if  (!channel)
        return;

    channel->state = state;
    channel->level = level;
#else
    UNUSED_PARAM(channelName);
    UNUSED_PARAM(state);
    UNUSED_PARAM(level);
#endif
}

#if ENABLE(WEB_AUTHN)
void WebPageProxyMessageHandler::setMockWebAuthenticationConfiguration(MockWebAuthenticationConfiguration&& configuration)
{
    m_proxy->setMockWebAuthenticationConfiguration(WTFMove(configuration));
}
#endif

void WebPageProxyMessageHandler::didFindTextManipulationItems(const Vector<WebCore::TextManipulationItem>& items)
{
    m_proxy->didFindTextManipulationItems(items);
}

// #endif

#if ENABLE(ARKIT_INLINE_PREVIEW)
void WebPageProxyMessageHandler::modelElementGetCamera(ModelIdentifier modelIdentifier, CompletionHandler<void(Expected<WebCore::HTMLModelElementCamera, ResourceError>)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->getCameraForModelElement(modelIdentifier, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementSetCamera(ModelIdentifier modelIdentifier, WebCore::HTMLModelElementCamera camera, CompletionHandler<void(bool)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->setCameraForModelElement(modelIdentifier, camera, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementIsPlayingAnimation(ModelIdentifier modelIdentifier, CompletionHandler<void(Expected<bool, ResourceError>)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->isPlayingAnimationForModelElement(modelIdentifier, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementSetAnimationIsPlaying(ModelIdentifier modelIdentifier, bool isPlaying, CompletionHandler<void(bool)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->setAnimationIsPlayingForModelElement(modelIdentifier, isPlaying, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementIsLoopingAnimation(ModelIdentifier modelIdentifier, CompletionHandler<void(Expected<bool, ResourceError>)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->isLoopingAnimationForModelElement(modelIdentifier, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementSetIsLoopingAnimation(ModelIdentifier modelIdentifier, bool isLooping, CompletionHandler<void(bool)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->setIsLoopingAnimationForModelElement(modelIdentifier, isLooping, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementAnimationDuration(ModelIdentifier modelIdentifier, CompletionHandler<void(Expected<Seconds, WebCore::ResourceError>)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->animationDurationForModelElement(modelIdentifier, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementAnimationCurrentTime(ModelIdentifier modelIdentifier, CompletionHandler<void(Expected<Seconds, WebCore::ResourceError>)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->animationCurrentTimeForModelElement(modelIdentifier, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementSetAnimationCurrentTime(ModelIdentifier modelIdentifier, Seconds currentTime, CompletionHandler<void(bool)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->setAnimationCurrentTimeForModelElement(modelIdentifier, currentTime, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementHasAudio(ModelIdentifier modelIdentifier, CompletionHandler<void(Expected<bool, ResourceError>)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->hasAudioForModelElement(modelIdentifier, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementIsMuted(ModelIdentifier modelIdentifier, CompletionHandler<void(Expected<bool, ResourceError>)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->isMutedForModelElement(modelIdentifier, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementSetIsMuted(ModelIdentifier modelIdentifier, bool isMuted, CompletionHandler<void(bool)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->setIsMutedForModelElement(modelIdentifier, isMuted, WTFMove(completionHandler));
}
#endif

#if ENABLE(ARKIT_INLINE_PREVIEW_IOS)
void WebPageProxyMessageHandler::takeModelElementFullscreen(ModelIdentifier modelIdentifier)
{
    if (RefPtr controller = modelElementController())
        controller->takeModelElementFullscreen(modelIdentifier, URL { currentURL() });
}

void WebPageProxyMessageHandler::modelElementSetInteractionEnabled(ModelIdentifier modelIdentifier, bool isInteractionEnabled)
{
    if (RefPtr controller = modelElementController())
        controller->setInteractionEnabledForModelElement(modelIdentifier, isInteractionEnabled);
}

#endif

#if ENABLE(ARKIT_INLINE_PREVIEW_MAC)
void WebPageProxyMessageHandler::modelElementCreateRemotePreview(const String& uuid, const FloatSize& size, CompletionHandler<void(Expected<std::pair<String, uint32_t>, ResourceError>)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->modelElementCreateRemotePreview(uuid, size, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementLoadRemotePreview(const String& uuid, const URL& url, CompletionHandler<void(std::optional<WebCore::ResourceError>&&)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->modelElementLoadRemotePreview(uuid, url, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::modelElementDestroyRemotePreview(const String& uuid)
{
    if (RefPtr controller = modelElementController())
        controller->modelElementDestroyRemotePreview(uuid);
}

void WebPageProxyMessageHandler::modelElementSizeDidChange(const String& uuid, WebCore::FloatSize size, CompletionHandler<void(Expected<MachSendRight, WebCore::ResourceError>)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->modelElementSizeDidChange(uuid, size, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::handleMouseDownForModelElement(const String& uuid, const WebCore::LayoutPoint& flippedLocationInElement, MonotonicTime timestamp)
{
    if (RefPtr controller = modelElementController())
        controller->handleMouseDownForModelElement(uuid, flippedLocationInElement, timestamp);
}

void WebPageProxyMessageHandler::handleMouseMoveForModelElement(const String& uuid, const WebCore::LayoutPoint& flippedLocationInElement, MonotonicTime timestamp)
{
    if (RefPtr controller = modelElementController())
        controller->handleMouseMoveForModelElement(uuid, flippedLocationInElement, timestamp);
}

void WebPageProxyMessageHandler::handleMouseUpForModelElement(const String& uuid, const WebCore::LayoutPoint& flippedLocationInElement, MonotonicTime timestamp)
{
    if (RefPtr controller = modelElementController())
        controller->handleMouseUpForModelElement(uuid, flippedLocationInElement, timestamp);
}

void WebPageProxyMessageHandler::modelInlinePreviewUUIDs(CompletionHandler<void(Vector<String>&&)>&& completionHandler)
{
    if (RefPtr controller = modelElementController())
        controller->inlinePreviewUUIDs(WTFMove(completionHandler));
}
#endif

void WebPageProxyMessageHandler::requestScrollToRect(const FloatRect& targetRect, const FloatPoint& origin)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->requestScrollToRect(targetRect, origin);
}

void WebPageProxyMessageHandler::requestCookieConsent(CompletionHandler<void(CookieConsentDecisionResult)>&& completion)
{
    uiClient()->requestCookieConsent(WTFMove(completion));
}

#if ENABLE(IMAGE_ANALYSIS) && ENABLE(VIDEO)
void WebPageProxyMessageHandler::beginTextRecognitionForVideoInElementFullScreen(MediaPlayerIdentifier identifier, FloatRect bounds)
{
    m_proxy->beginTextRecognitionForVideoInElementFullScreen(identifier, bounds);
}

void WebPageProxyMessageHandler::cancelTextRecognitionForVideoInElementFullScreen()
{
    m_proxy->cancelTextRecognitionForVideoInElementFullScreen();
}
#endif // #if ENABLE(IMAGE_ANALYSIS) && ENABLE(VIDEO)

void WebPageProxyMessageHandler::didCreateSleepDisabler(IPC::Connection& connection, SleepDisablerIdentifier identifier, const String& reason, bool display)
{
    m_proxy->didCreateSleepDisabler(connection, identifier, reason, display);
}

void WebPageProxyMessageHandler::didDestroySleepDisabler(SleepDisablerIdentifier identifier)
{
    m_proxy->didDestroySleepDisabler(identifier);
}

#if USE(SYSTEM_PREVIEW)
void WebPageProxyMessageHandler::beginSystemPreview(const URL& url, const SecurityOriginData& topOrigin, const SystemPreviewInfo& systemPreviewInfo, CompletionHandler<void()>&& completionHandler)
{
    RefPtr systemPreviewController = m_systemPreviewController;
    if (!systemPreviewController)
        return completionHandler();
    systemPreviewController->begin(url, topOrigin, systemPreviewInfo, WTFMove(completionHandler));
}

#endif

#if ENABLE(WINDOW_PROXY_PROPERTY_ACCESS_NOTIFICATION)

void WebPageProxyMessageHandler::didAccessWindowProxyPropertyViaOpenerForFrame(IPC::Connection& connection, FrameIdentifier frameID, const SecurityOriginData& parentOrigin, WindowProxyProperty property)
{
    m_proxy->didAccessWindowProxyPropertyViaOpenerForFrame(connection, frameID, parentOrigin, property);
}

#endif

void WebPageProxyMessageHandler::dispatchLoadEventToFrameOwnerElement(WebCore::FrameIdentifier frameID)
{
    m_proxy->dispatchLoadEventToFrameOwnerElement(frameID);
}

void WebPageProxyMessageHandler::focusRemoteFrame(IPC::Connection& connection, WebCore::FrameIdentifier frameID)
{
    m_proxy->focusRemoteFrame(connection, frameID);
}

void WebPageProxyMessageHandler::postMessageToRemote(WebCore::FrameIdentifier source, const String& sourceOrigin, WebCore::FrameIdentifier target, std::optional<WebCore::SecurityOriginData> targetOrigin, const WebCore::MessageWithMessagePorts& message)
{
    m_proxy->sendToProcessContainingFrame(target, Messages::WebPage::RemotePostMessage(source, sourceOrigin, target, targetOrigin, message));
}

void WebPageProxyMessageHandler::renderTreeAsTextForTesting(WebCore::FrameIdentifier frameID, size_t baseIndent, OptionSet<WebCore::RenderAsTextFlag> behavior, CompletionHandler<void(String&&)>&& completionHandler)
{
    auto sendResult = m_proxy->sendSyncToProcessContainingFrame(frameID, Messages::WebPage::RenderTreeAsTextForTesting(frameID, baseIndent, behavior));
    if (!sendResult.succeeded())
        return completionHandler("Test Error - sending WebPage::RenderTreeAsTextForTesting failed"_s);

    auto [result] = sendResult.takeReply();
    completionHandler(WTFMove(result));
}

void WebPageProxyMessageHandler::layerTreeAsTextForTesting(FrameIdentifier frameID, size_t baseIndent, OptionSet<LayerTreeAsTextOptions> options, CompletionHandler<void(String&&)>&& completionHandler)
{
    auto sendResult = m_proxy->sendSyncToProcessContainingFrame(frameID, Messages::WebPage::LayerTreeAsTextForTesting(frameID, baseIndent, options));
    if (!sendResult.succeeded())
        return completionHandler("Test Error - sending WebPage::RenderTreeAsTextForTesting failed"_s);

    auto [result] = sendResult.takeReply();
    completionHandler(WTFMove(result));
}

void WebPageProxyMessageHandler::addMessageToConsoleForTesting(String&& message)
{
    uiClient()->addMessageToConsoleForTesting(*m_proxy, WTFMove(message));
}

void WebPageProxyMessageHandler::frameTextForTesting(WebCore::FrameIdentifier frameID, CompletionHandler<void(String&&)>&& completionHandler)
{
    auto sendResult = m_proxy->sendSyncToProcessContainingFrame(frameID, Messages::WebPage::FrameTextForTesting(frameID));
    if (!sendResult.succeeded())
        return completionHandler("Test Error - sending WebPage::FrameTextForTesting failed"_s);

    auto [result] = sendResult.takeReply();
    completionHandler(WTFMove(result));
}

void WebPageProxyMessageHandler::bindRemoteAccessibilityFrames(int processIdentifier, WebCore::FrameIdentifier frameID, Vector<uint8_t>&& dataToken, CompletionHandler<void(Vector<uint8_t>, int)>&& completionHandler)
{
    m_proxy->bindRemoteAccessibilityFrames(processIdentifier, frameID, WTFMove(dataToken), WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::updateRemoteFrameAccessibilityOffset(WebCore::FrameIdentifier frameID, WebCore::IntPoint offset)
{
    m_proxy->updateRemoteFrameAccessibilityOffset(frameID, offset);
}

void WebPageProxyMessageHandler::documentURLForConsoleLog(WebCore::FrameIdentifier frameID, CompletionHandler<void(const URL&)>&& completionHandler)
{
    // FIXME: <rdar://125885582> Respond with an empty string if there's no inspector and no test runner.
    if (RefPtr frame = WebFrameProxy::webFrame(frameID))
        return completionHandler(frame->url());
    completionHandler({ });
}

void WebPageProxyMessageHandler::nowPlayingMetadataChanged(const WebCore::NowPlayingMetadata& metadata)
{
    m_proxy->nowPlayingMetadataChanged(metadata);
}

void WebPageProxyMessageHandler::didAdjustVisibilityWithSelectors(Vector<String>&& selectors)
{
    uiClient()->didAdjustVisibilityWithSelectors(*m_proxy, WTFMove(selectors));
}

void WebPageProxyMessageHandler::frameNameChanged(IPC::Connection& connection, WebCore::FrameIdentifier frameID, const String& frameName)
{
    m_proxy->frameNameChanged(connection, frameID, frameName);
}

void WebPageProxyMessageHandler::hasActiveNowPlayingSessionChanged(bool hasActiveNowPlayingSession)
{
    if (RefPtr pageClient = this->pageClient())
        pageClient->hasActiveNowPlayingSessionChanged(hasActiveNowPlayingSession);
}

void WebPageProxyMessageHandler::setAllowsLayoutViewportHeightExpansion(bool value)
{
    m_proxy->setAllowsLayoutViewportHeightExpansion(value);
}

// Forwarding through to obj-C

void WebPageProxyMessageHandler::abortApplePayAMSUISession()
{
    m_proxy->abortApplePayAMSUISession();
}

void WebPageProxyMessageHandler::createPDFHUD(PDFPluginIdentifier id, const WebCore::IntRect& rect)
{
    m_proxy->createPDFHUD(id, rect);
}

void WebPageProxyMessageHandler::removePDFHUD(PDFPluginIdentifier id)
{
    m_proxy->removePDFHUD(id);
}

void WebPageProxyMessageHandler::searchTheWeb(WTF::String const& query)
{
    m_proxy->searchTheWeb(query);
}

void WebPageProxyMessageHandler::getIsSpeaking(WTF::CompletionHandler<void (bool)>&& completionHandler)
{
    m_proxy->getIsSpeaking(WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::setRenderTreeSize(uint64_t treeSize)
{
    m_proxy->setRenderTreeSize(treeSize);
}

void WebPageProxyMessageHandler::loadRecentSearches(IPC::Connection& connection, const String& name, CompletionHandler<void(Vector<WebCore::RecentSearch>&&)>&& completionHandler)
{
    m_proxy->loadRecentSearches(connection, name, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::makeFirstResponder()
{
    m_proxy->makeFirstResponder();
}

void WebPageProxyMessageHandler::saveRecentSearches(IPC::Connection& connection, const String& name, const Vector<WebCore::RecentSearch>& recentSearches)
{
    m_proxy->saveRecentSearches(connection, name, recentSearches);
}

void WebPageProxyMessageHandler::showPDFContextMenu(const PDFContextMenu& menu, PDFPluginIdentifier pluginID, CompletionHandler<void(std::optional<int32_t>&&)>&& completionHandler)
{
    m_proxy->showPDFContextMenu(menu, pluginID, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::updatePDFHUDLocation(PDFPluginIdentifier pluginID, const WebCore::IntRect& rect)
{
    m_proxy->updatePDFHUDLocation(pluginID, rect);
}

void WebPageProxyMessageHandler::showValidationMessage(WebCore::IntRect const& rect, WTF::String const& msg)
{
    m_proxy->showValidationMessage(rect, msg);
}

void WebPageProxyMessageHandler::didUpdateActivityState()
{
    m_proxy->didUpdateActivityState();
}

void WebPageProxyMessageHandler::setDataDetectionResult(WebKit::DataDetectionResult const& result)
{
    m_proxy->setDataDetectionResult(result);
}

void WebPageProxyMessageHandler::handleAcceptsFirstMouse(bool value)
{
    m_proxy->handleAcceptsFirstMouse(value);
}

void WebPageProxyMessageHandler::setPromisedDataForImage(IPC::Connection& connection, const String& pasteboardName, WebCore::SharedMemoryHandle&& imageHandle, const String& filename, const String& extension,
    const String& title, const String& url, const String& visibleURL, WebCore::SharedMemoryHandle&& archiveHandle, const String& originIdentifier)
{
    m_proxy->setPromisedDataForImage(connection, pasteboardName, WTFMove(imageHandle), filename, extension, title, url, visibleURL, WTFMove(archiveHandle), originIdentifier);
}

void WebPageProxyMessageHandler::showTelephoneNumberMenu(const String& telephoneNumber, const WebCore::IntPoint& pt, const WebCore::IntRect& rect)
{
    m_proxy->showTelephoneNumberMenu(telephoneNumber, pt, rect);
}

void WebPageProxyMessageHandler::useFixedLayoutDidChange(bool value)
{
    m_proxy->useFixedLayoutDidChange(value);
}

void WebPageProxyMessageHandler::startApplePayAMSUISession(URL&& url, WebCore::ApplePayAMSUIRequest&& request, CompletionHandler<void(std::optional<bool>&&)>&& completionHandler)
{
    m_proxy->startApplePayAMSUISession(WTFMove(url), WTFMove(request), WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::didPerformDictionaryLookup(WebCore::DictionaryPopupInfo const& info)
{
    m_proxy->didPerformDictionaryLookup(info);
}

void WebPageProxyMessageHandler::addMediaUsageManagerSession(WebCore::MediaSessionIdentifier id, const String& label, const URL& url)
{
    m_proxy->addMediaUsageManagerSession(id, label, url);
}

void WebPageProxyMessageHandler::handleContextMenuTranslation(WebCore::TranslationContextMenuInfo const& info)
{
    m_proxy->handleContextMenuTranslation(info);
}

void WebPageProxyMessageHandler::executeSavedCommandBySelector(IPC::Connection& connection, const String& selector, CompletionHandler<void(bool)>&& completionHandler)
{
    m_proxy->executeSavedCommandBySelector(connection, selector, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::addTextAnimationForAnimationID(IPC::Connection& connection, const WTF::UUID& uuid, const WebCore::TextAnimationData& animData, const WebCore::TextIndicatorData& indicatorData)
{
    m_proxy->addTextAnimationForAnimationID(connection, uuid, animData, indicatorData);
}

void WebPageProxyMessageHandler::changeUniversalAccessZoomFocus(WebCore::IntRect const& a, WebCore::IntRect const& b)
{
    m_proxy->changeUniversalAccessZoomFocus(a, b);
}

void WebPageProxyMessageHandler::removeMediaUsageManagerSession(WebCore::MediaSessionIdentifier id)
{
    m_proxy->removeMediaUsageManagerSession(id);
}

void WebPageProxyMessageHandler::didChangeInspectorFrontendCount(uint32_t count)
{
    m_proxy->didChangeInspectorFrontendCount(count);
}

void WebPageProxyMessageHandler::contentFilterDidBlockLoadForFrame(IPC::Connection& connection, const WebCore::ContentFilterUnblockHandler& handler, WebCore::FrameIdentifier frameID)
{
    m_proxy->contentFilterDidBlockLoadForFrame(connection, handler, frameID);
}

void WebPageProxyMessageHandler::handleClickForDataDetectionResult(WebCore::DataDetectorElementInfo const& info, WebCore::IntPoint const& point)
{
    m_proxy->handleClickForDataDetectionResult(info, point);
}

void WebPageProxyMessageHandler::removeTextAnimationForAnimationID(IPC::Connection& connection, WTF::UUID const& uuid)
{
    m_proxy->removeTextAnimationForAnimationID(connection, uuid);
}

void WebPageProxyMessageHandler::updateMediaUsageManagerSessionState(WebCore::MediaSessionIdentifier id, const WebCore::MediaUsageInfo& info)
{
    m_proxy->updateMediaUsageManagerSessionState(id, info);
}

void WebPageProxyMessageHandler::isAnyAnimationAllowedToPlayDidChange(bool value)
{
    m_proxy->isAnyAnimationAllowedToPlayDidChange(value);
}

void WebPageProxyMessageHandler::registerWebProcessAccessibilityToken(std::span<const uint8_t> token)
{
    m_proxy->registerWebProcessAccessibilityToken(token);
}

void WebPageProxyMessageHandler::assistiveTechnologyMakeFirstResponder()
{
    m_proxy->assistiveTechnologyMakeFirstResponder();
}

void WebPageProxyMessageHandler::didStartProvisionalLoadForFrameShared(Ref<WebProcessProxy>&& process, WebCore::FrameIdentifier frameID, FrameInfoData&& frameInfo, WebCore::ResourceRequest&& request, std::optional<WebCore::NavigationIdentifier> navigationID, URL&& url, URL&& unreachableURL, const UserData& data, WallTime time)
{
    m_proxy->didStartProvisionalLoadForFrameShared(WTFMove(process), frameID, WTFMove(frameInfo), WTFMove(request), navigationID, WTFMove(url), WTFMove(unreachableURL), data, time);
}

void WebPageProxyMessageHandler::didEndPartialIntelligenceTextAnimation(IPC::Connection& connection)
{
    m_proxy->didEndPartialIntelligenceTextAnimation(connection);
}

void WebPageProxyMessageHandler::setCanShortCircuitHorizontalWheelEvents(bool value)
{
    m_proxy->setCanShortCircuitHorizontalWheelEvents(value);
}

void WebPageProxyMessageHandler::setHasExecutedAppBoundBehaviorBeforeNavigation()
{
    m_proxy->setHasExecutedAppBoundBehaviorBeforeNavigation();
}

void WebPageProxyMessageHandler::proofreadingSessionUpdateStateForSuggestionWithID(IPC::Connection& connection, WebCore::WritingTools::TextSuggestionState state, WTF::UUID const& uuid)
{
    m_proxy->proofreadingSessionUpdateStateForSuggestionWithID(connection, state, uuid);
}

void WebPageProxyMessageHandler::addTextAnimationForAnimationIDWithCompletionHandler(IPC::Connection& connection, const WTF::UUID& uuid, const WebCore::TextAnimationData& animData, const WebCore::TextIndicatorData& indicatorData, WTF::CompletionHandler<void(WebCore::TextAnimationRunMode)>&& completionHandler)
{
    m_proxy->addTextAnimationForAnimationIDWithCompletionHandler(connection, uuid, animData, indicatorData, WTFMove(completionHandler));
}

void WebPageProxyMessageHandler::didReceiveServerRedirectForProvisionalLoadForFrameShared(Ref<WebProcessProxy>&& process, WebCore::FrameIdentifier frameID, std::optional<WebCore::NavigationIdentifier> navigationID, WebCore::ResourceRequest&& request, const UserData& data)
{
    m_proxy->didReceiveServerRedirectForProvisionalLoadForFrameShared(WTFMove(process), frameID, navigationID, WTFMove(request), data);
}

void WebPageProxyMessageHandler::proofreadingSessionShowDetailsForSuggestionWithIDRelativeToRect(IPC::Connection& connection, WTF::UUID const& uuid, WebCore::IntRect rect)
{
    m_proxy->proofreadingSessionShowDetailsForSuggestionWithIDRelativeToRect(connection, uuid, rect);
}

void WebPageProxyMessageHandler::startDrag(WebCore::DragItem const& dragItem, WebCore::ShareableBitmapHandle&& bitmap)
{
    m_proxy->startDrag(dragItem, WTFMove(bitmap));
}

// Accessors etc.

PageClient* WebPageProxyMessageHandler::pageClient() const
{
    return m_proxy->pageClient();
}

API::UIClient* WebPageProxyMessageHandler::uiClient() const
{
    return m_proxy->m_uiClient.get();
}

API::NavigationClient& WebPageProxyMessageHandler::navigationClient()
{
    return m_proxy->m_navigationClient.get();
}

UserMediaPermissionRequestManagerProxy& WebPageProxyMessageHandler::userMediaPermissionRequestManager()
{
    return m_proxy->userMediaPermissionRequestManager();
}

Ref<UserMediaPermissionRequestManagerProxy> WebPageProxyMessageHandler::protectedUserMediaPermissionRequestManager()
{
    return userMediaPermissionRequestManager();
}

#if USE(SYSTEM_PREVIEW)
Ref<SystemPreviewController> WebPageProxyMessageHandler::protectedSystemPreviewController() {
    return m_proxy->m_systemPreviewController;
}
#endif

void WebPageProxyMessageHandler::forEachWebContentProcess(NOESCAPE Function<void(WebProcessProxy&, PageIdentifier)>&& function)
{
    m_proxy->forEachWebContentProcess(WTFMove(function));
}

SpellDocumentTag WebPageProxyMessageHandler::spellDocumentTag() {
    return m_proxy->spellDocumentTag();
}

RefPtr<PageClient> WebPageProxyMessageHandler::protectedPageClient()
{
    return pageClient();
}


RefPtr<ModelElementController> WebPageProxyMessageHandler::modelElementController()
{
    return m_proxy->m_modelElementController;
}

Ref<GeolocationPermissionRequestManagerProxy> WebPageProxyMessageHandler::protectedGeolocationPermissionRequestManager()
{
    return m_proxy->protectedGeolocationPermissionRequestManager();
}

SpeechSynthesisData& WebPageProxyMessageHandler::speechSynthesisData()
{
    return m_proxy->internals().speechSynthesisData();
}

WebCore::WebMediaSessionManagerClient& WebPageProxyMessageHandler::webMediaSessionManagerClient()
{
    return m_proxy->internals();
}

const WebPreferences& WebPageProxyMessageHandler::preferences() const
{
    return m_proxy->preferences();
}

WebPreferences& WebPageProxyMessageHandler::preferences()
{
    return m_proxy->preferences();
}

Ref<WebPreferences> WebPageProxyMessageHandler::protectedPreferences() const
{
    return m_proxy->protectedPreferences();
}

Ref<WebProcessProxy> WebPageProxyMessageHandler::protectedLegacyMainFrameProcess()
{
    return m_proxy->protectedLegacyMainFrameProcess();
}

WebPageInspectorController& WebPageProxyMessageHandler::inspectorController() const {
    return m_proxy->inspectorController();
}

std::optional<SharedPreferencesForWebProcess> WebPageProxyMessageHandler::sharedPreferencesForWebProcess(IPC::Connection& connection) const
{
    return m_proxy->sharedPreferencesForWebProcess(connection);
}

void WebPageProxyMessageHandler::ref() const
{
    m_proxy->ref();
}

void WebPageProxyMessageHandler::deref() const
{
    m_proxy->deref();
}

} // namespace WebKit

#undef MESSAGE_CHECK_URL_COMPLETION
#undef MESSAGE_CHECK_COMPLETION
#undef MESSAGE_CHECK_URL
#undef MESSAGE_CHECK
