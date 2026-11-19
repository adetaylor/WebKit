/*
 * Copyright (C) 2019-2025 Apple Inc. All rights reserved.
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2019-2023 Apple Inc. All rights reserved.
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

#import "config.h"
#import "GPUProcess.h"

#if ENABLE(GPU_PROCESS_CORE_SWIFT)

#import "GPUConnectionToWebProcess.h"
#import "GPUProcessCreationParameters.h"
#import "GPUProcessProxyMessages.h"
#import "Logging.h"
#import "RemoteSnapshotPDFDrawingTask.h"
#import "RemoteSnapshotSink.h"
#import "SandboxInitializationParameters.h"
#import <WebCore/NowPlayingManager.h>
#import <WebCore/UTIUtilities.h>
#import <wtf/Borrow.h>
#import <wtf/MemoryPressureHandler.h>

#if ENABLE(MEDIA_STREAM)
#import "SampleBufferDisplayLayerHost.h"
#import <WebCore/CoreAudioCaptureUnit.h>
#import <WebCore/MockRealtimeMediaSourceCenter.h>
#import <WebCore/RealtimeMediaSourceCenter.h>
#import <pal/cocoa/AVFoundationSoftLink.h>
#import <pal/spi/cocoa/AVFoundationSPI.h>
#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
#import <WebCore/AVAudioSessionCaptureDeviceManager.h>
#endif
#endif

#if HAVE(SCREEN_CAPTURE_KIT)
#import <WebCore/ScreenCaptureKitSharingSessionManager.h>
#endif

#if PLATFORM(MAC)
#import <WebCore/LocalizedStrings.h>
#import <pal/spi/cocoa/CoreServicesSPI.h>
#import <pal/spi/cocoa/LaunchServicesSPI.h>
#import <wtf/BlockPtr.h>
#import <wtf/darwin/DispatchExtras.h>
#endif

#if PLATFORM(IOS_FAMILY)
#import "MediaPermissionUtilities.h"
#import "TCCSoftLink.h"
#import <WebCore/LocalizedStrings.h>
#import <WebCore/MediaSessionHelperIOS.h>
#import <pal/spi/cocoa/LaunchServicesSPI.h>
#import <pal/spi/cocoa/MetalSPI.h>
#import <wtf/OSObjectPtr.h>
#import <wtf/cocoa/Entitlements.h>
#import <wtf/cocoa/SpanCocoa.h>
#if HAVE(SYSTEM_STATUS)
#import "SystemStatusSPI.h"
#import <pal/ios/SystemStatusSoftLink.h>
#endif
#if USE(EXTENSIONKIT)
#import "WKProcessExtension.h"
#endif
#endif

#if PLATFORM(VISION) && ENABLE(MODEL_PROCESS) && HAVE(CORE_RE)
#import "CoreIPCAuditToken.h"
#import "SharedFileHandle.h"
#import "WKSharedSimulationConnectionHelper.h"
#endif

namespace WebKit {
using namespace WebCore;

GPUProcess::GPUProcess()
{
#if ASSERT_ENABLED && ENABLE(MEDIA_STREAM)
    CoreAudioCaptureUnit::allowStarting();
#endif
    m_swiftState = createSwiftState();
}

GPUProcess::~GPUProcess()
{
    destroySwiftState(std::exchange(m_swiftState, 0));
}

GPUProcess& GPUProcess::singleton()
{
    static NeverDestroyed<Ref<GPUProcess>> gpuProcess = adoptRef(*new GPUProcess);
    return gpuProcess.get().get();
}

// The C++ part of start-up: what moves the parameters, or reaches AuxiliaryProcess and Launch Services.
void GPUProcess::initializeGPUProcess(GPUProcessCreationParameters&& parameters, CompletionHandler<void()>&& completionHandler)
{
    applyProcessCreationParameters(WTF::move(parameters.auxiliaryProcessParameters));
    SecurityFlags::Storage::update(WTF::move(parameters.securityFlags));
    auto& memoryPressureHandler = MemoryPressureHandler::singleton();
    memoryPressureHandler.setLowMemoryHandler([weakThis = WeakPtr { *this }](Critical critical, Synchronous synchronous) {
        if (RefPtr process = weakThis.get())
            process->lowMemoryHandler(critical, synchronous);
    });
    memoryPressureHandler.install();
#if ENABLE(MEDIA_STREAM) && PLATFORM(MAC)
    SandboxExtension::consumePermanently(parameters.microphoneSandboxExtensionHandle);
#endif
#if PLATFORM(IOS_FAMILY) && ENABLE(MEDIA_STREAM)
    CoreAudioCaptureUnit::defaultSingleton().setStatusBarWasTappedCallback([weakProcess = WeakPtr { *this }] (auto completionHandler) {
        if (RefPtr process = weakProcess.get())
            process->parentProcessConnection()->sendWithAsyncReply(Messages::GPUProcessProxy::StatusBarWasTapped(), [] { }, 0);
        completionHandler();
    });
#endif
#if PLATFORM(IOS_FAMILY) && USE(SANDBOX_EXTENSIONS_FOR_CACHE_AND_TEMP_DIRECTORY_ACCESS)
    SandboxExtension::consumePermanently(parameters.containerCachesDirectoryExtensionHandle);
#if ENABLE(LLVM_PROFILE_GENERATION)
    WebKit::initializeLLVMProfiling();
    WebCore::initializeLLVMProfiling();
    JSC::initializeLLVMProfiling();
#endif
#endif
    populateMobileGestaltCache(WTF::move(parameters.mobileGestaltExtensionHandle));
#if ENABLE(REMOTE_INSPECTOR)
    SandboxExtension::consumePermanently(parameters.gpuToolsExtensionHandles);
#endif
    m_applicationVisibleName = WTF::move(parameters.applicationVisibleName);
    WebCore::setImageSourceAllowableTypes({ });
#if ENABLE(VIDEO) || ENABLE(WEB_AUDIO)
    if (auto& session = parameters.nowPlayingFallbackSession)
        swiftInitializeNowPlayingFallbackSession(session->object().toUInt64(), session->processIdentifier().toUInt64());
#endif
    registerWithStateDumper("GPUProcess state"_s);
    swiftInitializeGPUProcess(parameters);
#if PLATFORM(MAC)
    RefPtr launchServicesExtension = SandboxExtension::create(WTF::move(parameters.launchServicesExtensionHandle));
    if (launchServicesExtension) {
        bool ok = launchServicesExtension->consume();
        ASSERT_UNUSED(ok, ok);
    }
    // Check in with Launch Services before setting the process name, which needs its extension.
    launchServicesCheckIn();
    updateProcessName();
    _LSSetApplicationLaunchServicesServerConnectionStatus(kLSServerConnectionStatusDoNotConnectToServerMask | kLSServerConnectionStatusReleaseNotificationsMask, nullptr);
    if (launchServicesExtension)
        launchServicesExtension->revoke();
#endif
#if PLATFORM(IOS_FAMILY) && USE(SANDBOX_EXTENSIONS_FOR_CACHE_AND_TEMP_DIRECTORY_ACCESS) && USE(EXTENSIONKIT)
    MTLSetShaderCachePath(parameters.containerCachesDirectory.createNSString().get());
#endif
#if PLATFORM(IOS_FAMILY) && USE(EXTENSIONKIT)
    // Last, once everything that needs the sandbox's extensions has them.
    if (WKProcessExtension.sharedInstance)
        [WKProcessExtension.sharedInstance lockdownSandbox:@"2.0"];
#endif
    increaseFileDescriptorLimit();
    completionHandler();
}

bool GPUProcess::addWebProcessConnection(GPUConnectionToWebProcess& connection, bool ignoreInvalidMessageForTesting)
{
#if ENABLE(IPC_TESTING_API)
    if (ignoreInvalidMessageForTesting)
        connection.connection().setIgnoreInvalidMessageForTesting();
#else
    UNUSED_PARAM(ignoreInvalidMessageForTesting);
#endif
    ASSERT(!m_webProcessConnections.contains(connection.webProcessIdentifier()));
    return m_webProcessConnections.add(connection.webProcessIdentifier(), connection).isNewEntry;
}

GPUConnectionToWebProcess* GPUProcess::webProcessConnection(WebCore::ProcessIdentifier identifier) const
{
    return m_webProcessConnections.get(identifier);
}

void GPUProcess::removeGPUConnectionToWebProcess(GPUConnectionToWebProcess& connection)
{
    Ref protectedConnection { connection };
    ASSERT(m_webProcessConnections.get(connection.webProcessIdentifier()) == &connection);
    if (m_webProcessConnections.get(connection.webProcessIdentifier()) == &connection)
        m_webProcessConnections.remove(connection.webProcessIdentifier());
    didRemoveWebProcessConnection(connection);
}

WebCore::NowPlayingManager& GPUProcess::nowPlayingManager()
{
    if (!m_nowPlayingManager)
        lazyInitialize(m_nowPlayingManager, makeUnique<WebCore::NowPlayingManager>());
    return *m_nowPlayingManager;
}

void GPUProcess::terminateWebProcess(WebCore::ProcessIdentifier identifier, IPC::MessageName invalidMessageName)
{
    protect(parentProcessConnection())->send(Messages::GPUProcessProxy::TerminateWebProcess(identifier, invalidMessageName), 0);
}

void GPUProcess::updateSandboxAccess(const Vector<SandboxExtension::Handle>& extensions)
{
    RELEASE_LOG(WebRTC, "GPUProcess::updateSandboxAccess: Adding %zu extensions", extensions.size());
    SandboxExtension::consumePermanently(extensions);
}

RetainPtr<NSDictionary> GPUProcess::additionalStateForDiagnosticReport() const
{
    RetainPtr backendStates = adoptNS([[NSMutableDictionary alloc] init]);
    for (auto& [webProcessIdentifier, connection] : m_webProcessConnections) {
        if (connection->swiftRenderingBackendCount())
            [backendStates setObject:adoptNS([[NSMutableDictionary alloc] init]).get() forKey:webProcessIdentifier.loggingString().createNSString().get()];
    }
    if (![backendStates count])
        return adoptNS([[NSDictionary alloc] init]);
    return @{ @"RemoteRenderingBackend states": backendStates.get() };
}

void GPUProcess::sinkCompletedSnapshotToPDF(RemoteSnapshotIdentifier identifier, FrameIdentifier rootFrameIdentifier, std::optional<ProcessIdentifier> printProcessIdentifier, CompletionHandler<void(RefPtr<WebCore::SharedBuffer>&&)>&& completionHandler)
{
    RemoteSnapshotSink::create(identifier, rootFrameIdentifier, [printProcessIdentifier, completionHandler = WTF::move(completionHandler)](RemoteSnapshotSink* sink) mutable {
        if (!sink)
            return completionHandler({ });
        RemoteSnapshotPDFDrawingTask::create(*sink, WTF::move(completionHandler))->start(printProcessIdentifier);
    })->swiftTakeSnapshotWhenComplete();
}

void GPUProcess::sinkCompletedSnapshotToBitmap(RemoteSnapshotIdentifier identifier, FrameIdentifier rootFrameIdentifier, CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>&&)>&& completionHandler)
{
    RemoteSnapshotSink::create(identifier, rootFrameIdentifier, [completionHandler = WTF::move(completionHandler)](RemoteSnapshotSink* sink) mutable {
        completionHandler(sink ? sink->drawToBitmap() : std::nullopt);
    })->swiftTakeSnapshotWhenComplete();
}

void GPUProcess::sinkCompletedSnapshotToIOSurface(RemoteSnapshotIdentifier identifier, float scale, const ColorSpace& colorSpace, FrameIdentifier rootFrameIdentifier, CompletionHandler<void(std::optional<ImageBufferBackendHandle>&&)>&& completionHandler)
{
    RemoteSnapshotSink::create(identifier, rootFrameIdentifier, [identifier, scale, colorSpace, completionHandler = WTF::move(completionHandler)](RemoteSnapshotSink* sink) mutable {
        // The surface outlives this call in the UI process, so charge it to the process that asked for it.
        RefPtr connection = sink ? GPUProcess::singleton().webProcessConnection(identifier.processIdentifier()) : nullptr;
        if (!connection)
            return completionHandler({ });
        bool useIOSurfaceWebKitBehavior = false;
#if USE(APPLE_INTERNAL_SDK)
        useIOSurfaceWebKitBehavior = connection->sharedPreferencesForWebProcessValue().useIOSurfaceWebKitBehavior;
#endif
        completionHandler(sink->drawToIOSurface(scale, colorSpace, connection->webProcessIdentity(), useIOSurfaceWebKitBehavior));
    })->swiftTakeSnapshotWhenComplete();
}

void GPUProcess::waitForSnapshot(RemoteSnapshotIdentifier identifier, CompletionHandler<void()>&& completionHandler)
{
    Ref wait = RemoteSnapshotSink::create(identifier, std::nullopt, [completionHandler = WTF::move(completionHandler)](RemoteSnapshotSink*) mutable {
        completionHandler();
    });
    // Sent after the sink, keeping its order, so a snapshot that is not here has already been drawn.
    if (!wait->swiftWaitForSnapshot())
        wait->completeWithoutSnapshot();
}

#if ENABLE(MEDIA_STREAM)
void GPUProcess::ensureAVCaptureServerConnection()
{
    RELEASE_LOG(WebRTC, "GPUProcess::ensureAVCaptureServerConnection: Entering.");
    RetainPtr deviceClass = PAL::getAVCaptureDeviceClassSingleton();
    if ([deviceClass respondsToSelector:@selector(ensureServerConnection)]) {
        RELEASE_LOG(WebRTC, "GPUProcess::ensureAVCaptureServerConnection: Calling [AVCaptureDevice ensureServerConnection]");
        [deviceClass ensureServerConnection];
    }
}

void GPUProcess::startCapturePreview(std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice, WebCore::PageIdentifier pageIdentifier, WebCore::IntSize previewSize, WebCore::IntDegrees orientation, Vector<SandboxExtension::Handle>&& sandboxExtensions, String&& applicationBundleIdentifier, WebCore::SecurityOriginData&& origin, CompletionHandler<void(WebCore::HostingContext)>&& completionHandler)
{
    if (!swiftCanStartCapturePreview(pageIdentifier))
        return completionHandler({ });
    // Do not consumePermanently(): the preview's extensions are revoked when the prompt is dismissed. If the user
    // gives permission to capture the sandbox will be extended as necessary.
    for (auto& handle : borrow(sandboxExtensions)) {
        if (RefPtr extension = SandboxExtension::create(WTF::move(handle)); extension && extension->consume())
            m_capturePreviewSandboxExtensions.append(extension.releaseNonNull());
    }
    if (!swiftPrepareCapturePreview(pageIdentifier, !!videoDevice, WTF::move(applicationBundleIdentifier), WTF::move(origin)))
        return completionHandler({ });
    RefPtr layer = videoDevice ? SampleBufferDisplayLayerHost::createForCapturePreview(previewSize) : nullptr;
    completionHandler(swiftStartCapturePreviewForPage(pageIdentifier, layer.get(), videoDevice ? videoDevice->persistentId() : String { }, videoDevice ? videoDevice->label() : String { }, videoDevice && videoDevice->isDefault(),
        audioDevice ? audioDevice->persistentId() : String { }, audioDevice ? audioDevice->label() : String { }, audioDevice && audioDevice->isDefault(), previewSize, orientation));
}

void GPUProcess::enableMicrophoneMuteStatusAPI()
{
    CoreAudioCaptureUnit::defaultSingleton().setMuteStatusChangedCallback([weakProcess = WeakPtr { *this }] (bool isMuting) {
        if (RefPtr process = weakProcess.get())
            protect(process->parentProcessConnection())->send(Messages::GPUProcessProxy::MicrophoneMuteStatusChanged(isMuting), 0);
    });
}

void GPUProcess::clearMockMediaDevices()
{
    WebCore::MockRealtimeMediaSourceCenter::setDevices({ });
}

void GPUProcess::triggerMockCaptureConfigurationChange(bool forCamera, bool forMicrophone, bool forDisplay)
{
    WebCore::MockRealtimeMediaSourceCenter::singleton().triggerMockCaptureConfigurationChange(forCamera, forMicrophone, forDisplay);
}

void GPUProcess::setShouldListenToVoiceActivity(bool shouldListen)
{
    if (!shouldListen)
        return RealtimeMediaSourceCenter::singleton().audioCaptureFactory().disableMutedSpeechActivityEventListener();
    RealtimeMediaSourceCenter::singleton().audioCaptureFactory().enableMutedSpeechActivityEventListener([] {
        protect(GPUProcess::singleton().parentProcessConnection())->send(Messages::GPUProcessProxy::VoiceActivityDetected { }, 0);
    });
}

void GPUProcess::revokeCapturePreviewSandboxExtensions()
{
    for (auto& extension : std::exchange(m_capturePreviewSandboxExtensions, { }))
        extension->revoke();
}

void GPUProcess::beginCapturePreviewAudioSession(uint64_t generation)
{
#if (PLATFORM(IOS_FAMILY) || ENABLE(ROUTING_ARBITRATION)) && USE(AUDIO_SESSION)
    Ref process = singleton();
#if PLATFORM(IOS_FAMILY)
    if (!process->m_savedPreferredMicrophoneID)
        process->m_savedPreferredMicrophoneID = WebCore::AVAudioSessionCaptureDeviceManager::singleton().preferredMicrophoneID();
#endif
    process->swiftBeginCapturePreviewAudioSession(generation);
#else
    UNUSED_PARAM(generation);
#endif
}

void GPUProcess::endCapturePreviewAudioSession()
{
#if (PLATFORM(IOS_FAMILY) || ENABLE(ROUTING_ARBITRATION)) && USE(AUDIO_SESSION)
    Ref process = singleton();
#if PLATFORM(IOS_FAMILY)
    auto savedPreferredMicrophoneID = std::exchange(process->m_savedPreferredMicrophoneID, std::nullopt);
    if (!savedPreferredMicrophoneID)
        return;

    WebCore::AVAudioSessionCaptureDeviceManager::singleton().setPreferredMicrophoneID(*savedPreferredMicrophoneID);
#endif
    process->swiftEndCapturePreviewAudioSession();
#endif
}
#endif // ENABLE(MEDIA_STREAM)

#if HAVE(SCREEN_CAPTURE_KIT)
void GPUProcess::promptForGetDisplayMedia(WebCore::DisplayCapturePromptType type, CompletionHandler<void(std::optional<WebCore::CaptureDevice>)>&& completionHandler)
{
    WebCore::ScreenCaptureKitSharingSessionManager::singleton().promptForGetDisplayMedia(type, WTF::move(completionHandler));
}

void GPUProcess::selectWindowForCapture(uint32_t windowID, CompletionHandler<void(std::optional<WebCore::CaptureDevice>)>&& completionHandler)
{
    WebCore::ScreenCaptureKitSharingSessionManager::singleton().selectWindowForCapture(windowID, WTF::move(completionHandler));
}

void GPUProcess::cancelGetDisplayMediaPrompt()
{
    WebCore::ScreenCaptureKitSharingSessionManager::singleton().cancelGetDisplayMediaPrompt();
}
#endif

#if ENABLE(WEBXR)
void GPUProcess::webXRPromptAccepted(std::optional<WebCore::ProcessIdentity> processIdentity, CompletionHandler<void(bool)>&& completionHandler)
{
    m_processIdentity = processIdentity;
    completionHandler(true);
}
#endif

#if PLATFORM(MAC) || PLATFORM(MACCATALYST)
void GPUProcess::initializeProcess(const AuxiliaryProcessInitializationParameters&)
{
    setApplicationIsDaemon();
#if HAVE(CSCHECKFIXDISABLE)
    _CSCheckFixDisable();
#endif
}

void GPUProcess::initializeProcessName(const AuxiliaryProcessInitializationParameters& parameters)
{
#if PLATFORM(MAC)
    m_uiProcessName = parameters.uiProcessName;
#endif
}

void GPUProcess::initializeSandbox(const AuxiliaryProcessInitializationParameters& parameters, SandboxInitializationParameters& sandboxParameters)
{
    // The service has a different bundle identifier, so the profile has to be given.
    RetainPtr webKit2Bundle = [NSBundle bundleForClass:NSClassFromString(@"WKWebView")];
    sandboxParameters.setOverrideSandboxProfilePath([webKit2Bundle pathForResource:@"com.apple.WebKit.GPUProcess" ofType:@"sb"]);
    AuxiliaryProcess::initializeSandbox(parameters, sandboxParameters);
}
#endif

#if PLATFORM(MAC)
void GPUProcess::updateProcessName()
{
#if !PLATFORM(MACCATALYST)
ALLOW_NONLITERAL_FORMAT_BEGIN
    RetainPtr applicationName = adoptNS([[NSString alloc] initWithFormat:WEB_UI_STRING("%@ Graphics and Media", "visible name of the GPU process. The argument is the application name.").createNSString().get(), m_uiProcessName.createNSString().get()]);
ALLOW_NONLITERAL_FORMAT_END
    RetainPtr asn = _LSGetCurrentApplicationASN();
    auto result = _LSSetApplicationInformationItem(kLSDefaultSessionID, asn.get(), _kLSDisplayNameKey, (CFStringRef)applicationName.get(), nullptr);
    ASSERT_UNUSED(result, result == noErr);
#endif
}

void GPUProcess::openDirectoryCacheInvalidated(SandboxExtension::Handle&& handle)
{
    dispatch_async(globalDispatchQueueSingleton(QOS_CLASS_UTILITY, 0), makeBlockPtr([handle = WTF::move(handle)]() mutable {
        AuxiliaryProcess::openDirectoryCacheInvalidated(WTF::move(handle));
    }).get());
}
#endif // PLATFORM(MAC)

#if PLATFORM(VISION) && ENABLE(MODEL_PROCESS)
#if HAVE(CORE_RE)
void GPUProcess::requestSharedSimulationConnection(CoreIPCAuditToken&& modelProcessAuditToken, CompletionHandler<void(std::optional<IPC::SharedFileHandle>)>&& completionHandler)
{
    Ref<WKSharedSimulationConnectionHelper> sharedSimulationConnectionHelper = adoptRef(*new WKSharedSimulationConnectionHelper);
    sharedSimulationConnectionHelper->requestSharedSimulationConnectionForAuditToken(modelProcessAuditToken.auditToken(), [sharedSimulationConnectionHelper, completionHandler = WTF::move(completionHandler)] (RetainPtr<NSFileHandle> sharedSimulationConnection, RetainPtr<id> appService) mutable {
        if (!sharedSimulationConnection) {
            RELEASE_LOG_ERROR(ModelElement, "GPUProcess: Shared simulation join request failed");
            completionHandler(std::nullopt);
            return;
        }

        RELEASE_LOG(ModelElement, "GPUProcess: Shared simulation join request succeeded");
        completionHandler(IPC::SharedFileHandle::create(FileSystem::FileHandle::adopt([sharedSimulationConnection fileDescriptor])));
    });
}
#endif

#if HAVE(TASK_IDENTITY_TOKEN)
void GPUProcess::createMemoryAttributionIDForTask(WebCore::ProcessIdentity processIdentity, CompletionHandler<void(const std::optional<String>&)>&& completionHandler)
{
#if HAVE(CORE_RE)
    Ref<WKSharedSimulationConnectionHelper> sharedSimulationConnectionHelper = adoptRef(*new WKSharedSimulationConnectionHelper);
    sharedSimulationConnectionHelper->createMemoryAttributionIDForTask(processIdentity.taskIdToken(), [sharedSimulationConnectionHelper, completionHandler = WTF::move(completionHandler)] (RetainPtr<NSString> attributionTaskID, RetainPtr<id> appService) mutable {
        if (!attributionTaskID) {
            RELEASE_LOG_ERROR(ModelElement, "GPUProcess: Memory attribution ID request failed");
            completionHandler(std::nullopt);
            return;
        }

        RELEASE_LOG(ModelElement, "GPUProcess: Memory attribution ID request succeeded");
        completionHandler(String(attributionTaskID.get()));
    });
#else
    UNUSED_PARAM(processIdentity);
    completionHandler(std::nullopt);
#endif
}

void GPUProcess::unregisterMemoryAttributionID(const String& attributionID, CompletionHandler<void()>&& completionHandler)
{
#if HAVE(CORE_RE)
    Ref<WKSharedSimulationConnectionHelper> sharedSimulationConnectionHelper = adoptRef(*new WKSharedSimulationConnectionHelper);
    sharedSimulationConnectionHelper->unregisterMemoryAttributionID(attributionID.createNSString().get(), [sharedSimulationConnectionHelper, completionHandler = WTF::move(completionHandler)] (RetainPtr<id> appService) mutable {
        if (appService)
            RELEASE_LOG(ModelElement, "GPUProcess: Memory attribution ID unregistration succeeded");
        else
            RELEASE_LOG(ModelElement, "GPUProcess: Memory attribution ID unregistration failed");
        completionHandler();
    });
#else
    UNUSED_PARAM(attributionID);
    completionHandler();
#endif
}
#endif
#endif

#if PLATFORM(IOS_FAMILY) && ENABLE(MEDIA_STREAM) && HAVE(SYSTEM_STATUS)
bool GPUProcess::setCaptureAttributionString(WebCore::SecurityOriginData captureOrigin)
{
    if (![PAL::getSTDynamicActivityAttributionPublisherClassSingleton() respondsToSelector:@selector(setCurrentAttributionStringWithFormat:auditToken:)]
        && ![PAL::getSTDynamicActivityAttributionPublisherClassSingleton() respondsToSelector:@selector(setCurrentAttributionWebsiteString:auditToken:)]) {
        return true;
    }

    auto auditToken = protect(parentProcessConnection())->getAuditToken();
    if (!auditToken)
        return false;

    RetainPtr visibleName = applicationVisibleNameFromOrigin(captureOrigin);
    if (!visibleName)
        visibleName = m_applicationVisibleName.createNSString();

    if ([PAL::getSTDynamicActivityAttributionPublisherClassSingleton() respondsToSelector:@selector(setCurrentAttributionWebsiteString:auditToken:)])
        [PAL::getSTDynamicActivityAttributionPublisherClassSingleton() setCurrentAttributionWebsiteString:visibleName.get() auditToken:auditToken.value()];
    else {
        SUPPRESS_UNRETAINED_ARG RetainPtr formatString = adoptNS([[NSString alloc] initWithFormat:WEB_UI_NSSTRING(@"%@ in %%@", "The domain and application using the camera and/or microphone. The first argument is domain, the second is the application name (iOS only)."), visibleName.get()]);
        [PAL::getSTDynamicActivityAttributionPublisherClassSingleton() setCurrentAttributionStringWithFormat:formatString.get() auditToken:auditToken.value()];
    }
    return true;
}
#endif

#if PLATFORM(IOS_FAMILY) && ENABLE(MEDIA_STREAM) && ENABLE(APP_PRIVACY_REPORT) && !PLATFORM(MACCATALYST)
bool GPUProcess::setCaptureTCCIdentity(const String& fallbackBundleIdentifier)
{
    auto auditToken = protect(parentProcessConnection())->getAuditToken();
    if (!auditToken) {
        RELEASE_LOG_ERROR(WebRTC, "setCaptureTCCIdentity: getAuditToken returned null");
        return false;
    }

    NSError *error = nil;
    RetainPtr bundleProxy = [LSBundleProxy bundleProxyWithAuditToken:*auditToken error:&error];
    RELEASE_LOG_ERROR_IF(error, WebRTC, "setCaptureTCCIdentity: -[LSBundleProxy bundleProxyWithAuditToken:error:] failed with error %s", [[error localizedDescription] UTF8String]);

    String bundleIdentifier = [bundleProxy bundleIdentifier];
    if (bundleIdentifier.isNull())
        bundleIdentifier = fallbackBundleIdentifier;

    if (bundleIdentifier.isNull()) {
        RELEASE_LOG_ERROR(WebRTC, "setCaptureTCCIdentity: unable to get the bundle identifier");
        return false;
    }

    // FIXME: Adopting is needed here but static analysis is not able to tell.
    SUPPRESS_RETAINPTR_CTOR_ADOPT OSObjectPtr identity = adoptOSObject(tcc_identity_create(TCC_IDENTITY_CODE_BUNDLE_ID, bundleIdentifier.utf8().legacyCStringPointer()));
    if (!identity) {
        RELEASE_LOG_ERROR(WebRTC, "setCaptureTCCIdentity: tcc_identity_create returned null");
        return false;
    }

    WebCore::RealtimeMediaSourceCenter::singleton().setIdentity(WTF::move(identity));
    return true;
}

bool GPUProcess::hasCaptureIdentity(const String& applicationBundleIdentifier)
{
    return setCaptureTCCIdentity(applicationBundleIdentifier) || WebCore::RealtimeMediaSourceCenter::singleton().hasIdentity();
}
#endif

#if PLATFORM(IOS_FAMILY) && ENABLE(MEDIA_STREAM)
bool GPUProcess::platformSetUpCapturePreviewEnvironment(WebCore::PageIdentifier pageIdentifier, bool hasCamera)
{
    auto isConnectionForPage = [&](GPUConnectionToWebProcess& connection) {
#if HAVE(AUDIT_TOKEN)
        if (connection.presentingApplicationAuditTokens().contains(pageIdentifier))
            return true;
#endif
#if ENABLE(EXTENSION_CAPABILITIES)
        if (!connection.mediaPlaybackEnvironment(pageIdentifier).isEmpty())
            return true;
#endif
        UNUSED_PARAM(connection);
        return false;
    };
    RefPtr<GPUConnectionToWebProcess> pageConnection;
    for (Ref connection : m_webProcessConnections.values()) {
        if (isConnectionForPage(connection)) {
            pageConnection = connection.ptr();
            break;
        }
    }

#if ENABLE(EXTENSION_CAPABILITIES) && !PLATFORM(IOS_FAMILY_SIMULATOR)
    String mediaEnvironment = pageConnection ? pageConnection->mediaPlaybackEnvironment(pageIdentifier) : String { };
    bool hasMediaEnvironment = !mediaEnvironment.isEmpty();
    WebCore::RealtimeMediaSourceCenter::singleton().setCurrentMediaEnvironment(WTF::move(mediaEnvironment));
    if (!hasMediaEnvironment && !WebCore::RealtimeMediaSourceCenter::singleton().hasIdentity() && hasCamera
        && WTF::processHasEntitlement("com.apple.developer.web-browser-engine.rendering"_s)) {
        RELEASE_LOG_ERROR(WebRTC, "GPUProcess::startCapturePreview: no media environment, refusing to preview");
        return false;
    }
#else
    UNUSED_PARAM(hasCamera);
#endif

#if HAVE(AUDIT_TOKEN)
    bool hasPresentingApplication = pageConnection && pageConnection->presentingApplicationAuditTokens().contains(pageIdentifier);
#else
    bool hasPresentingApplication = false;
#endif
    if (hasPresentingApplication)
        pageConnection->providePresentingApplicationPID(pageIdentifier);
    else {
#if ENABLE(EXTENSION_CAPABILITIES)
        bool usesMediaCapabilityGrants = pageConnection && pageConnection->sharedPreferencesForWebProcessValue().mediaCapabilityGrantsEnabled;
#else
        bool usesMediaCapabilityGrants = false;
#endif
        if (!usesMediaCapabilityGrants) {
            if (RefPtr connection = parentProcessConnection())
                protect(MediaSessionHelper::sharedHelper())->providePresentingApplicationPID(connection->remoteProcessID());
        }
    }
    return true;
}
#endif

#if PLATFORM(IOS_FAMILY) && USE(EXTENSIONKIT)
void GPUProcess::resolveBookmarkDataForCacheDirectory(std::span<const uint8_t> bookmarkData)
{
    RetainPtr bookmark = toNSData(bookmarkData);
    BOOL bookmarkIsStale = NO;
    NSError* error = nil;
    [NSURL URLByResolvingBookmarkData:bookmark.get() options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:&bookmarkIsStale error:&error];
}
#endif

} // namespace WebKit

#endif

