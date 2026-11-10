/*
 * Copyright (C) 2019-2025 Apple Inc. All rights reserved.
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
#include "GPUProcess.h"

#if ENABLE(GPU_PROCESS)

#include "ArgumentCoders.h"
#include "Attachment.h"
#include "AuxiliaryProcessMessages.h"
#include "GPUConnectionToWebProcess.h"
#include "GPUProcessConnectionParameters.h"
#include "GPUProcessCreationParameters.h"
#include "GPUProcessPreferences.h"
#include "GPUProcessProxyMessages.h"
#include "GPUProcessSessionParameters.h"
#include "LogInitialization.h"
#include "Logging.h"
#include "RemoteMediaPlayerManagerProxy.h"
#include "RemoteSnapshotPDFDrawingTask.h"
#include "RemoteSnapshotSink.h"
#include "SandboxExtension.h"
#include "WebPageProxyMessages.h"
#include "WebProcessPoolMessages.h"
#include <WebCore/CommonAtomStrings.h>
#include <WebCore/DeprecatedGlobalSettings.h>
#include <WebCore/FloatSize.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/LogInitialization.h>
#include <WebCore/MediaPlayer.h>
#include <WebCore/MemoryRelease.h>
#include <WebCore/NowPlayingManager.h>
#include <wtf/Borrow.h>
#include <wtf/CallbackAggregator.h>
#include <wtf/Language.h>
#include <wtf/LogInitialization.h>
#include <wtf/MemoryPressureHandler.h>
#include <wtf/OptionSet.h>
#include <wtf/ProcessPrivilege.h>
#include <wtf/RunLoop.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/Scope.h>
#include <wtf/UniqueRef.h>
#include <wtf/text/AtomString.h>

#if USE(AUDIO_SESSION)
#include "RemoteAudioSessionProxyManager.h"
#endif

#if ENABLE(MEDIA_STREAM)
#include <WebCore/MockRealtimeMediaSourceCenter.h>
#endif

#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
#include "CapturePreviewLayer.h"
#include "RotationMonitoringReason.h"
#include <WebCore/RealtimeMediaSourceCenter.h>
#include <wtf/cocoa/Entitlements.h>
#if PLATFORM(IOS_FAMILY)
#include <WebCore/MediaSessionHelperIOS.h>
#endif
#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
#include <WebCore/AVAudioSessionCaptureDeviceManager.h>
#endif
#endif

#if PLATFORM(COCOA)
#include "ArgumentCodersCocoa.h"
#include <WebCore/CoreAudioCaptureUnit.h>
#include <WebCore/IOSurface.h>
#include <WebCore/UTIUtilities.h>
#include <WebCore/VP9UtilitiesCocoa.h>
#endif

#if HAVE(SCREEN_CAPTURE_KIT)
#include <WebCore/ScreenCaptureKitCaptureSource.h>
#endif

#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "RemoteSnapshotRecorder.h"
#endif

namespace WebKit {

using namespace WebCore;

GPUProcess::GPUProcess()
{
    RELEASE_LOG(Process, "%p - GPUProcess::GPUProcess:", this);
#if ASSERT_ENABLED && PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
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

void GPUProcess::createGPUConnectionToWebProcess(WebCore::ProcessIdentifier identifier, PAL::SessionID sessionID, IPC::Connection::Handle&& connectionHandle, GPUProcessConnectionParameters&& parameters, CompletionHandler<void()>&& completionHandler)
{
    RELEASE_LOG(Process, "%p - GPUProcess::createGPUConnectionToWebProcess: processIdentifier=%" PRIu64, this, identifier.toUInt64());

    auto reply = makeScopeExit(WTF::move(completionHandler));
    // If sender exited before we received the handle, the handle may not be valid.
    if (!connectionHandle)
        return;

    auto newConnection = GPUConnectionToWebProcess::create(*this, identifier, sessionID, WTF::move(connectionHandle), WTF::move(parameters));

#if ENABLE(IPC_TESTING_API)
    if (parameters.ignoreInvalidMessageForTesting)
        newConnection->connection().setIgnoreInvalidMessageForTesting();
#endif

    ASSERT(!m_webProcessConnections.contains(identifier));
    Ref connection = newConnection.get();
    if (m_webProcessConnections.add(identifier, WTF::move(newConnection)).isNewEntry)
        connection->swiftDidAddToGPUProcess();
}

void GPUProcess::sharedPreferencesForWebProcessDidChange(WebCore::ProcessIdentifier identifier, SharedPreferencesForWebProcess&& sharedPreferencesForWebProcess, CompletionHandler<void()>&& completionHandler)
{
    if (RefPtr connection = m_webProcessConnections.get(identifier))
        connection->updateSharedPreferencesForWebProcess(WTF::move(sharedPreferencesForWebProcess));
    completionHandler();
}

void GPUProcess::securityFlagsDidChange(SecurityFlags::Storage&& securityFlags)
{
    SecurityFlags::Storage::update(WTF::move(securityFlags));
}

void GPUProcess::removeGPUConnectionToWebProcess(GPUConnectionToWebProcess& connection)
{
    RELEASE_LOG(Process, "%p - GPUProcess::removeGPUConnectionToWebProcess: processIdentifier=%" PRIu64, this, connection.webProcessIdentifier().toUInt64());
    ASSERT(m_webProcessConnections.get(connection.webProcessIdentifier()) == &connection);
    if (m_webProcessConnections.get(connection.webProcessIdentifier()) == &connection)
        m_webProcessConnections.remove(connection.webProcessIdentifier());

    removeTransferredImageBuffersForProcess(connection.webProcessIdentifier());
    swiftAbandonSnapshotFramesOwnedBy(connection.webProcessIdentifier());
    swiftRemoveSnapshotsForProcess(connection.webProcessIdentifier());

    connection.swiftDidRemoveFromGPUProcess();

    tryExitIfUnusedAndUnderMemoryPressure();
}

void GPUProcess::connectionToWebProcessClosed(IPC::Connection& connection)
{
}

bool GPUProcess::shouldTerminate()
{
    return m_webProcessConnections.isEmpty();
}

bool GPUProcess::isUnderMemoryPressure()
{
    return MemoryPressureHandler::singleton().isUnderMemoryPressure();
}

bool GPUProcess::isSimulatingMemoryPressure()
{
    return MemoryPressureHandler::singleton().isSimulatingMemoryPressure();
}

void GPUProcess::releaseMemory(Critical critical, Synchronous synchronous)
{
    WebCore::releaseGraphicsMemory(critical, synchronous);

#if PLATFORM(COCOA)
    if (critical == Critical::Yes)
        WebCore::IOSurface::releaseCGIOSurfaceContextResources();
#endif
}

void GPUProcess::sendProcessIsReadyToExit()
{
    protect(parentProcessConnection())->send(Messages::GPUProcessProxy::ProcessIsReadyToExit(), 0);
}

void GPUProcess::initializeGPUProcess(GPUProcessCreationParameters&& parameters, CompletionHandler<void()>&& completionHandler)
{
    CompletionHandlerCallingScope callCompletionHandler(WTF::move(completionHandler));

    applyProcessCreationParameters(WTF::move(parameters.auxiliaryProcessParameters));
    SecurityFlags::Storage::update(WTF::move(parameters.securityFlags));
    RELEASE_LOG(Process, "%p - GPUProcess::initializeGPUProcess:", this);
    WTF::Thread::setCurrentThreadIsUserInitiated();
    WebCore::initializeCommonAtomStrings();

    auto& memoryPressureHandler = MemoryPressureHandler::singleton();
    memoryPressureHandler.setLowMemoryHandler([weakThis = WeakPtr { *this }] (Critical critical, Synchronous synchronous) {
        if (RefPtr process = weakThis.get())
            process->lowMemoryHandler(critical, synchronous);
    });
    memoryPressureHandler.install();

#if PLATFORM(IOS_FAMILY) || ENABLE(ROUTING_ARBITRATION)
    DeprecatedGlobalSettings::setShouldManageAudioSessionCategory(true);
#endif

#if ENABLE(MEDIA_STREAM)
    setMockCaptureDevicesEnabled(parameters.useMockCaptureDevices);
#if PLATFORM(MAC)
    SandboxExtension::consumePermanently(parameters.microphoneSandboxExtensionHandle);
#endif
#if PLATFORM(IOS_FAMILY)
CoreAudioCaptureUnit::defaultSingleton().setStatusBarWasTappedCallback([weakProcess = WeakPtr { *this }] (auto completionHandler) {
        if (RefPtr process = weakProcess.get())
            process->parentProcessConnection()->sendWithAsyncReply(Messages::GPUProcessProxy::StatusBarWasTapped(), [] { }, 0);
        completionHandler();
    });
#endif
#endif // ENABLE(MEDIA_STREAM)

#if USE(SANDBOX_EXTENSIONS_FOR_CACHE_AND_TEMP_DIRECTORY_ACCESS)
    SandboxExtension::consumePermanently(parameters.containerCachesDirectoryExtensionHandle);
#if ENABLE(LLVM_PROFILE_GENERATION)
    WebKit::initializeLLVMProfiling();
    WebCore::initializeLLVMProfiling();
    JSC::initializeLLVMProfiling();
#endif // ENABLE(LLVM_PROFILE_GENERATION)
#endif

    populateMobileGestaltCache(WTF::move(parameters.mobileGestaltExtensionHandle));

#if PLATFORM(COCOA) && ENABLE(REMOTE_INSPECTOR)
    SandboxExtension::consumePermanently(parameters.gpuToolsExtensionHandles);
#endif

#if PLATFORM(COCOA)
    WebCore::setImageSourceAllowableTypes({ });
#endif

    m_applicationVisibleName = WTF::move(parameters.applicationVisibleName);

    // Match the QoS of the UIProcess since the GPU process is doing rendering on its behalf.
    WTF::Thread::setCurrentThreadIsUserInteractive(0);

    if (!parameters.overrideLanguages.isEmpty())
        overrideUserPreferredLanguages(parameters.overrideLanguages);

#if ENABLE(VIDEO) || ENABLE(WEB_AUDIO)
    if (auto& session = parameters.nowPlayingFallbackSession)
        swiftInitializeNowPlayingFallbackSession(session->object().toUInt64(), session->processIdentifier().toUInt64());
#endif

#if USE(OS_STATE)
    registerWithStateDumper("GPUProcess state"_s);
#endif

    platformInitializeGPUProcess(parameters);
}

void GPUProcess::updateGPUProcessPreferences(GPUProcessPreferences&& preferences)
{
#if PLATFORM(COCOA)
    if (preferences.mediaResourceLoadTimeoutForTesting != std::exchange(m_preferences.mediaResourceLoadTimeoutForTesting, preferences.mediaResourceLoadTimeoutForTesting))
        WebCore::DeprecatedGlobalSettings::setMediaResourceLoadTimeoutForTesting(m_preferences.mediaResourceLoadTimeoutForTesting.value_or(0));
#endif

#if ENABLE(VP9)
    if (updatePreference(m_preferences.vp9DecoderEnabled, preferences.vp9DecoderEnabled)) {
        VP9TestingOverrides::singleton().setShouldEnableVP9Decoder(*m_preferences.vp9DecoderEnabled);
#if PLATFORM(COCOA)
        if (!m_haveEnabledVP9Decoder && *m_preferences.vp9DecoderEnabled) {
            m_haveEnabledVP9Decoder = true;
            WebCore::registerSupplementalVP9Decoder();
        }
#endif
    }
#if PLATFORM(COCOA)
    if (preferences.swVPDecodersAlwaysEnabled != std::exchange(m_preferences.swVPDecodersAlwaysEnabled, preferences.swVPDecodersAlwaysEnabled))
        VP9TestingOverrides::singleton().setSWVPDecodersAlwaysEnabled(m_preferences.swVPDecodersAlwaysEnabled);

    if (!m_haveEnabledSWVP9Decoder && WebCore::shouldEnableSWVP9Decoder()) {
        WebCore::registerWebKitVP9Decoder();
        m_haveEnabledSWVP9Decoder = true;
    }
#endif
#endif
}

bool GPUProcess::updatePreference(std::optional<bool>& oldPreference, std::optional<bool>& newPreference)
{
    if (newPreference.has_value() && oldPreference != newPreference) {
        oldPreference = WTF::move(newPreference);
        return true;
    }
    
    if (!oldPreference.has_value()) {
        oldPreference = false;
        return true;
    }
    
    return false;
}

void GPUProcess::userPreferredLanguagesChanged(Vector<String>&& languages)
{
    overrideUserPreferredLanguages(languages);
}

void GPUProcess::prepareToSuspend(bool isSuspensionImminent, MonotonicTime, CompletionHandler<void()>&& completionHandler)
{
    RELEASE_LOG(ProcessSuspension, "%p - GPUProcess::prepareToSuspend(), isSuspensionImminent: %d", this, isSuspensionImminent);

    lowMemoryHandler(Critical::Yes, Synchronous::Yes);
    completionHandler();
}

void GPUProcess::processDidResume()
{
    RELEASE_LOG(ProcessSuspension, "%p - GPUProcess::processDidResume()", this);
    resume();
}

void GPUProcess::resume()
{
}

GPUConnectionToWebProcess* GPUProcess::webProcessConnection(WebCore::ProcessIdentifier identifier) const
{
    return m_webProcessConnections.get(identifier);
}

void GPUProcess::nowPlayingOwnerDidChange(bool hasOwner, uint64_t pageIdentifier, uint64_t processIdentifier)
{
#if ENABLE(VIDEO) || ENABLE(WEB_AUDIO)
    std::optional<QualifiedPageIdentifier> ownerPage;
    if (hasOwner)
        ownerPage = QualifiedPageIdentifier { PageIdentifier { pageIdentifier }, ProcessIdentifier { processIdentifier } };
    protect(singleton().parentProcessConnection())->send(Messages::GPUProcessProxy::NowPlayingOwnerDidChange(ownerPage), 0);
#else
    UNUSED_PARAM(hasOwner);
    UNUSED_PARAM(pageIdentifier);
    UNUSED_PARAM(processIdentifier);
#endif
}

void GPUProcess::updateSandboxAccess(const Vector<SandboxExtension::Handle>& extensions)
{
    RELEASE_LOG(WebRTC, "GPUProcess::updateSandboxAccess: Adding %zu extensions", extensions.size());
    for (auto& extension : borrow(extensions))
        SandboxExtension::consumePermanently(extension);
}

void GPUProcess::handOverTransferredImageBuffers(Vector<WebCore::ImageBufferTransferIdentifier>&& identifiers, WebCore::ProcessIdentifier destinationProcess)
{
    Locker locker(m_globalResourceLocker);
    // Not waited for, so the destination may already have claimed some of them.
    for (auto identifier : identifiers) {
        auto iterator = m_transferredImageBuffers.find(identifier);
        if (iterator != m_transferredImageBuffers.end())
            iterator->value.owner = destinationProcess;
    }
}

WebCore::ImageBufferTransferIdentifier GPUProcess::depositTransferredImageBuffer(WebCore::ProcessIdentifier owner, Ref<WebCore::ImageBuffer>&& imageBuffer)
{
    Locker locker(m_globalResourceLocker);
    auto identifier = WebCore::ImageBufferTransferIdentifier::createVersion4();
    auto result = m_transferredImageBuffers.add(identifier, TransferredImageBuffer { owner, WTF::move(imageBuffer) });
    RELEASE_ASSERT(result.isNewEntry);
    return identifier;
}

RefPtr<WebCore::ImageBuffer> GPUProcess::takeTransferredImageBuffer(WebCore::ImageBufferTransferIdentifier identifier)
{
    Locker locker(m_globalResourceLocker);
    return m_transferredImageBuffers.take(identifier).imageBuffer;
}

void GPUProcess::releaseTransferredImageBuffer(WebCore::ImageBufferTransferIdentifier identifier)
{
    Locker locker(m_globalResourceLocker);
    m_transferredImageBuffers.remove(identifier);
}

void GPUProcess::releaseTransferredImageBuffers(Vector<WebCore::ImageBufferTransferIdentifier>&& identifiers)
{
    Locker locker(m_globalResourceLocker);
    for (auto identifier : identifiers)
        m_transferredImageBuffers.remove(identifier);
}

void GPUProcess::removeTransferredImageBuffersForProcess(WebCore::ProcessIdentifier processIdentifier)
{
    Locker locker(m_globalResourceLocker);
    // Keyed on the owner: once ownership has moved on, the depositing process going away must not
    // take the buffer from the process it was handed to.
    m_transferredImageBuffers.removeIf([&](auto& entry) {
        return entry.value.owner == processIdentifier;
    });
}

void GPUProcess::createSnapshot(RemoteSnapshotIdentifier snapshotIdentifier, FrameIdentifier rootFrameIdentifier, const FloatSize& size, ProcessIdentifier rootProcessIdentifier)
{
    swiftCreateSnapshot(snapshotKey(snapshotIdentifier), rootFrameIdentifier, size, rootProcessIdentifier);
}

void GPUProcess::failSnapshot(RemoteSnapshotIdentifier snapshotIdentifier)
{
    swiftFailSnapshot(snapshotKey(snapshotIdentifier));
}

void GPUProcess::abandonSnapshotFrame(RemoteSnapshotIdentifier snapshotIdentifier, FrameIdentifier frameIdentifier)
{
    swiftAbandonSnapshotFrame(snapshotKey(snapshotIdentifier), frameIdentifier);
}

void GPUProcess::snapshotFrameWillBeDrawnByProcess(RemoteSnapshotIdentifier snapshotIdentifier, FrameIdentifier frameIdentifier, ProcessIdentifier processIdentifier)
{
    swiftSnapshotFrameWillBeDrawnByProcess(snapshotKey(snapshotIdentifier), frameIdentifier, processIdentifier);
}

void GPUProcess::abandonSnapshotFramesOwnedBy(ProcessIdentifier processIdentifier)
{
    swiftAbandonSnapshotFramesOwnedBy(processIdentifier);
}

void GPUProcess::releaseSnapshot(RemoteSnapshotIdentifier identifier)
{
    swiftReleaseSnapshot(snapshotKey(identifier));
}

#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

static RemoteSnapshotIdentifier snapshotIdentifier(RemoteSnapshotKey key)
{
    auto uuid = WTF::UUID::tryCreate(key.high, key.low);
    RELEASE_ASSERT(uuid);
    return { *uuid, ProcessIdentifier(key.process) };
}

Ref<RemoteSnapshotDisplayLists> GPUProcess::snapshotDisplayLists(const RemoteSnapshotIdentifier& identifier, std::optional<uint64_t> token)
{
    Ref gpuProcess = singleton();
    Locker locker(gpuProcess->m_globalResourceLocker);
    RefPtr displayLists = gpuProcess->m_snapshotDisplayLists.get(identifier);
    if (displayLists && (!token || displayLists->token() == *token))
        return displayLists.releaseNonNull();
    return RemoteSnapshotDisplayLists::create();
}

uint64_t GPUProcess::createSnapshotDisplayLists(RemoteSnapshotKey key)
{
    Ref gpuProcess = singleton();
    Ref displayLists = RemoteSnapshotDisplayLists::create();
    auto token = displayLists->token();
    Locker locker(gpuProcess->m_globalResourceLocker);
    gpuProcess->m_snapshotDisplayLists.set(snapshotIdentifier(key), WTF::move(displayLists));
    return token;
}

void GPUProcess::forgetSnapshotDisplayLists(RemoteSnapshotKey key)
{
    RefPtr<RemoteSnapshotDisplayLists> displayLists;
    {
        Ref gpuProcess = singleton();
        Locker locker(gpuProcess->m_globalResourceLocker);
        displayLists = gpuProcess->m_snapshotDisplayLists.take(snapshotIdentifier(key));
    }
}

void GPUProcess::abandonSnapshotDisplayList(RemoteSnapshotKey key, uint64_t frameKey)
{
    snapshotDisplayLists(snapshotIdentifier(key))->abandonFrame(FrameIdentifier(frameKey));
}

void GPUProcess::addSnapshotFrameReference(const RemoteSnapshotIdentifier& identifier, FrameIdentifier frameIdentifier, uint64_t displayListsToken)
{
    swiftAddSnapshotFrameReference(snapshotKey(identifier), frameIdentifier, displayListsToken);
}

void GPUProcess::snapshotFrameWasRecorded(const RemoteSnapshotIdentifier& identifier, FrameIdentifier frameIdentifier, uint64_t displayListsToken)
{
    swiftSnapshotFrameWasRecorded(snapshotKey(identifier), frameIdentifier, displayListsToken);
}

#endif

#if PLATFORM(COCOA)

void GPUProcess::sinkCompletedSnapshotToPDF(RemoteSnapshotIdentifier identifier, FrameIdentifier rootFrameIdentifier, std::optional<ProcessIdentifier> printProcessIdentifier, CompletionHandler<void(RefPtr<WebCore::SharedBuffer>&&)>&& completionHandler)
{
    RemoteSnapshotSink::create(identifier, rootFrameIdentifier, [printProcessIdentifier, completionHandler = WTF::move(completionHandler)](RemoteSnapshotSink* sink) mutable {
        if (!sink) {
            completionHandler({ });
            return;
        }
        RemoteSnapshotPDFDrawingTask::create(*sink, WTF::move(completionHandler))->start(printProcessIdentifier);
    })->swiftTakeSnapshotWhenComplete();
}

#endif

void GPUProcess::sinkCompletedSnapshotToBitmap(RemoteSnapshotIdentifier identifier, FrameIdentifier rootFrameIdentifier, CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>&&)>&& completionHandler)
{
    RemoteSnapshotSink::create(identifier, rootFrameIdentifier, [completionHandler = WTF::move(completionHandler)](RemoteSnapshotSink* sink) mutable {
        completionHandler(sink ? sink->drawToBitmap() : std::nullopt);
    })->swiftTakeSnapshotWhenComplete();
}

#if HAVE(IOSURFACE)

void GPUProcess::sinkCompletedSnapshotToIOSurface(RemoteSnapshotIdentifier identifier, float scale, const ColorSpace& colorSpace, FrameIdentifier rootFrameIdentifier, CompletionHandler<void(std::optional<ImageBufferBackendHandle>&&)>&& completionHandler)
{
    RemoteSnapshotSink::create(identifier, rootFrameIdentifier, [identifier, scale, colorSpace, completionHandler = WTF::move(completionHandler)](RemoteSnapshotSink* sink) mutable {
        if (!sink) {
            completionHandler({ });
            return;
        }
        // The surface outlives this call in the UI process, so charge it to the process that asked for it.
        RefPtr connection = GPUProcess::singleton().webProcessConnection(identifier.processIdentifier());
        if (!connection) {
            completionHandler({ });
            return;
        }
        bool useIOSurfaceWebKitBehavior = false;
#if USE(APPLE_INTERNAL_SDK)
        useIOSurfaceWebKitBehavior = connection->sharedPreferencesForWebProcessValue().useIOSurfaceWebKitBehavior;
#endif
        completionHandler(sink->drawToIOSurface(scale, colorSpace, connection->webProcessIdentity(), useIOSurfaceWebKitBehavior));
    })->swiftTakeSnapshotWhenComplete();
}

#endif

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
void GPUProcess::setMockCaptureDevicesEnabled(bool isEnabled)
{
    WebCore::MockRealtimeMediaSourceCenter::setMockRealtimeMediaSourceCenterEnabled(isEnabled);
}

void GPUProcess::enableMicrophoneMuteStatusAPI()
{
#if PLATFORM(COCOA)
    CoreAudioCaptureUnit::defaultSingleton().setMuteStatusChangedCallback([weakProcess = WeakPtr { *this }] (bool isMuting) {
        if (RefPtr process = weakProcess.get())
            protect(process->parentProcessConnection())->send(Messages::GPUProcessProxy::MicrophoneMuteStatusChanged(isMuting), 0);
    });
#endif
}

#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
void GPUProcess::startCapturePreview(std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice, WebCore::PageIdentifier pageIdentifier, WebCore::IntSize previewSize, WebCore::IntDegrees orientation, Vector<SandboxExtension::Handle>&& sandboxExtensions, String&& applicationBundleIdentifier, WebCore::SecurityOriginData&& origin, CompletionHandler<void(WebCore::HostingContext)>&& completionHandler)
{
    // FIXME: The manager is per process while requests are per page, so for now fail a second page's
    // prompt while another is up until we figure out a better solution.
    if (m_capturePreviewPage && *m_capturePreviewPage != pageIdentifier) {
        RELEASE_LOG_ERROR(WebRTC, "GPUProcess::startCapturePreview: a preview is already running for another page");
        return completionHandler({ });
    }

    m_capturePreviewPage = pageIdentifier;

    // Do not consumePermanently(): the preview's extensions are revoked when the prompt is dismissed. If the user
    // gives permission to capture the sandbox will be extended as necessary.
    for (auto& handle : borrow(sandboxExtensions)) {
        if (RefPtr extension = SandboxExtension::create(WTF::move(handle)); extension && extension->consume())
            m_capturePreviewSandboxExtensions.append(extension.releaseNonNull());
    }

    ensureAVCaptureServerConnection();

#if ENABLE(APP_PRIVACY_REPORT) && !PLATFORM(MACCATALYST)
    bool hasCaptureIdentity = setCaptureTCCIdentity(applicationBundleIdentifier) || WebCore::RealtimeMediaSourceCenter::singleton().hasIdentity();

    // Fail immediately if we don't have a capture identity as -[AVCaptureSession init] will throw.
    if (!hasCaptureIdentity && videoDevice) {
        RELEASE_LOG_ERROR(WebRTC, "GPUProcess::startCapturePreview: no capture identity, refusing to preview");
        stopCapturePreviewManager();
        return completionHandler({ });
    }
#else
    UNUSED_PARAM(applicationBundleIdentifier);
#endif

    if (!setUpCapturePreviewEnvironment(pageIdentifier, origin, !!videoDevice)) {
        stopCapturePreviewManager();
        return completionHandler({ });
    }

    // CapturePreviewStart (CapturePreviewManager.swift).
    constexpr uint8_t capturePreviewStarted = 1;
    constexpr uint8_t capturePreviewUnchanged = 2;

    RefPtr layer = videoDevice ? CapturePreviewLayer::create(previewSize) : nullptr;
    auto result = swiftStartCapturePreview(pageIdentifier.toUInt64(),
        videoDevice ? videoDevice->persistentId() : String { }, videoDevice ? videoDevice->label() : String { }, videoDevice && videoDevice->isDefault(),
        audioDevice ? audioDevice->persistentId() : String { }, audioDevice ? audioDevice->label() : String { }, audioDevice && audioDevice->isDefault(),
        previewSize.width(), previewSize.height(), orientation, layer.get());
    if (result == capturePreviewStarted)
        m_capturePreviewLayer = WTF::move(layer);
    else if (result != capturePreviewUnchanged)
        m_capturePreviewLayer = nullptr;
    if (!swiftHasCapturePreview())
        m_capturePreviewLayer = nullptr;
    if (result != capturePreviewUnchanged)
        setCapturePreviewVideoDevice(m_capturePreviewLayer ? videoDevice->persistentId() : String { }, pageIdentifier);

    completionHandler(m_capturePreviewLayer ? m_capturePreviewLayer->hostingContext() : WebCore::HostingContext { });
}

void GPUProcess::setCapturePreviewVideoDevice(const String& persistentID, std::optional<WebCore::PageIdentifier> pageIdentifier)
{
    RefPtr connection = parentProcessConnection();
    if (connection && !m_capturePreviewVideoDeviceID.isEmpty() && m_capturePreviewVideoPage)
        connection->send(Messages::GPUProcessProxy::StopMonitoringCaptureDeviceRotation(*m_capturePreviewVideoPage, m_capturePreviewVideoDeviceID, RotationMonitoringReason::CapturePreview), 0);
    m_capturePreviewVideoDeviceID = pageIdentifier ? persistentID : String { };
    m_capturePreviewVideoPage = pageIdentifier;
    if (connection && !m_capturePreviewVideoDeviceID.isEmpty() && m_capturePreviewVideoPage)
        connection->send(Messages::GPUProcessProxy::StartMonitoringCaptureDeviceRotation(*m_capturePreviewVideoPage, m_capturePreviewVideoDeviceID, RotationMonitoringReason::CapturePreview), 0);
}

bool GPUProcess::capturePreviewNeedsAudioSession()
{
#if (PLATFORM(IOS_FAMILY) || ENABLE(ROUTING_ARBITRATION)) && USE(AUDIO_SESSION)
    return true;
#else
    return false;
#endif
}

void GPUProcess::beginCapturePreviewAudioSession(uint64_t generation)
{
#if (PLATFORM(IOS_FAMILY) || ENABLE(ROUTING_ARBITRATION)) && USE(AUDIO_SESSION)
    Ref process = singleton();
#if PLATFORM(IOS_FAMILY)
    if (!process->m_savedPreferredMicrophoneID)
        process->m_savedPreferredMicrophoneID = WebCore::AVAudioSessionCaptureDeviceManager::singleton().preferredMicrophoneID();
#endif
    protect(process->audioSessionManager())->beginCapturePreview([generation] {
        singleton().capturePreviewAudioSessionIsReady(generation);
    });
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
    protect(process->audioSessionManager())->endCapturePreview();
#endif
}

void GPUProcess::capturePreviewAudioLevelChanged(uint64_t pageIdentifier, float level)
{
    if (RefPtr connection = singleton().parentProcessConnection())
        connection->send(Messages::GPUProcessProxy::CapturePreviewAudioLevelChanged(WebCore::PageIdentifier { pageIdentifier }, level), 0);
}

bool GPUProcess::setUpCapturePreviewEnvironment(WebCore::PageIdentifier pageIdentifier, const WebCore::SecurityOriginData& origin, bool hasCamera)
{
    if (!setCaptureAttributionString(origin)) {
        RELEASE_LOG_ERROR(WebRTC, "GPUProcess::startCapturePreview: unable to set capture attribution, refusing to preview");
        return false;
    }

#if PLATFORM(IOS_FAMILY) || ENABLE(EXTENSION_CAPABILITIES)
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
#endif

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

#if PLATFORM(IOS_FAMILY)
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
#endif

    return true;
}

void GPUProcess::stopCapturePreview(WebCore::PageIdentifier pageIdentifier, CompletionHandler<void()>&& completionHandler)
{
    if (m_capturePreviewPage && *m_capturePreviewPage != pageIdentifier)
        return completionHandler();

    m_capturePreviewPage = { };
    stopCapturePreviewManager();

    if (m_lastCaptureEnvironment) {
        auto [processIdentifier, capturePageIdentifier] = *m_lastCaptureEnvironment;
        if (RefPtr connection = m_webProcessConnections.get(processIdentifier))
            connection->reapplyCaptureEnvironment(capturePageIdentifier);
    }

    for (auto& extension : std::exchange(m_capturePreviewSandboxExtensions, { }))
        extension->revoke();

    completionHandler();
}

void GPUProcess::didApplyCaptureEnvironment(WebCore::ProcessIdentifier processIdentifier, WebCore::PageIdentifier pageIdentifier)
{
    m_lastCaptureEnvironment = { processIdentifier, pageIdentifier };
}

void GPUProcess::stopCapturePreviewManager()
{
    swiftStopCapturePreview();
    m_capturePreviewLayer = nullptr;
    setCapturePreviewVideoDevice({ }, std::nullopt);
}
#endif // ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

void GPUProcess::updateCaptureOrigin(const WebCore::SecurityOriginData& originData, WebCore::ProcessIdentifier processID)
{
    if (RefPtr connection = webProcessConnection(processID))
        connection->updateCaptureOrigin(originData);
}

void GPUProcess::addMockMediaDevice(const WebCore::MockMediaDevice& device)
{
    WebCore::MockRealtimeMediaSourceCenter::addDevice(device);
}

void GPUProcess::clearMockMediaDevices()
{
    WebCore::MockRealtimeMediaSourceCenter::setDevices({ });
}

void GPUProcess::removeMockMediaDevice(const String& persistentId)
{
    WebCore::MockRealtimeMediaSourceCenter::removeDevice(persistentId);
}

void GPUProcess::setMockMediaDeviceIsEphemeral(const String& persistentId, bool isEphemeral)
{
    WebCore::MockRealtimeMediaSourceCenter::setDeviceIsEphemeral(persistentId, isEphemeral);
}

void GPUProcess::resetMockMediaDevices()
{
    WebCore::MockRealtimeMediaSourceCenter::resetDevices();
}

void GPUProcess::setMockCaptureDevicesInterrupted(bool isCameraInterrupted, bool isMicrophoneInterrupted)
{
    WebCore::MockRealtimeMediaSourceCenter::setMockCaptureDevicesInterrupted(isCameraInterrupted, isMicrophoneInterrupted);
}

void GPUProcess::triggerMockCaptureConfigurationChange(bool forCamera, bool forMicrophone, bool forDisplay)
{
    WebCore::MockRealtimeMediaSourceCenter::singleton().triggerMockCaptureConfigurationChange(forCamera, forMicrophone, forDisplay);
}

void GPUProcess::setShouldListenToVoiceActivity(bool shouldListen)
{
#if PLATFORM(COCOA)
    if (!shouldListen) {
        RealtimeMediaSourceCenter::singleton().audioCaptureFactory().disableMutedSpeechActivityEventListener();
        return;
    }

    RealtimeMediaSourceCenter::singleton().audioCaptureFactory().enableMutedSpeechActivityEventListener([] {
        protect(GPUProcess::singleton().parentProcessConnection())->send(Messages::GPUProcessProxy::VoiceActivityDetected { }, 0);
    });
#endif
}
#endif // ENABLE(MEDIA_STREAM)

#if HAVE(SCREEN_CAPTURE_KIT)
void GPUProcess::promptForGetDisplayMedia(WebCore::DisplayCapturePromptType type, CompletionHandler<void(std::optional<WebCore::CaptureDevice>)>&& completionHandler)
{
    WebCore::ScreenCaptureKitSharingSessionManager::singleton().promptForGetDisplayMedia(type, WTF::move(completionHandler));
}

void GPUProcess::cancelGetDisplayMediaPrompt()
{
    WebCore::ScreenCaptureKitSharingSessionManager::singleton().cancelGetDisplayMediaPrompt();
}

#endif // HAVE(SCREEN_CAPTURE_KIT)

void GPUProcess::addSession(PAL::SessionID sessionID, GPUProcessSessionParameters&& parameters)
{
    ASSERT(!m_sessions.contains(sessionID));
    SandboxExtension::consumePermanently(parameters.mediaCacheDirectorySandboxExtensionHandle);
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    SandboxExtension::consumePermanently(parameters.mediaKeysStorageDirectorySandboxExtensionHandle);
#endif

    m_sessions.add(sessionID, GPUSession {
        WTF::move(parameters.mediaCacheDirectory)
#if ENABLE(LEGACY_ENCRYPTED_MEDIA) || ENABLE(ENCRYPTED_MEDIA)
        , WTF::move(parameters.mediaKeysStorageDirectory)
#endif
    });
}

void GPUProcess::removeSession(PAL::SessionID sessionID)
{
    auto findResult = m_sessions.find(sessionID);
    if (findResult == m_sessions.end()) {
        ASSERT_NOT_REACHED("Invalid SessionID");
        return;
    }
    m_sessions.remove(findResult);
}

const String& GPUProcess::mediaCacheDirectory(PAL::SessionID sessionID) const
{
    auto findResult = m_sessions.find(sessionID);
    if (findResult == m_sessions.end()) {
        ASSERT_NOT_REACHED("Invalid SessionID");
        return nullString();
    }
    return findResult->value.mediaCacheDirectory;
}

#if ENABLE(LEGACY_ENCRYPTED_MEDIA) || ENABLE(ENCRYPTED_MEDIA)
const String& GPUProcess::mediaKeysStorageDirectory(PAL::SessionID sessionID) const
{
    auto findResult = m_sessions.find(sessionID);
    if (findResult == m_sessions.end()) {
        ASSERT_NOT_REACHED("Invalid SessionID");
        return nullString();
    }
    return findResult->value.mediaKeysStorageDirectory;
}
#endif

WebCore::NowPlayingManager& GPUProcess::nowPlayingManager()
{
    if (!m_nowPlayingManager)
        lazyInitialize(m_nowPlayingManager, makeUnique<WebCore::NowPlayingManager>());
    return *m_nowPlayingManager;
}

#if ENABLE(GPU_PROCESS) && USE(AUDIO_SESSION)
RemoteAudioSessionProxyManager& GPUProcess::audioSessionManager()
{
    if (!m_audioSessionManager)
        m_audioSessionManager = RemoteAudioSessionProxyManager::create(*this);
    return *m_audioSessionManager;
}
#endif

#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
WorkQueue& GPUProcess::videoMediaStreamTrackRendererQueue()
{
    if (!m_videoMediaStreamTrackRendererQueue)
        lazyInitialize(m_videoMediaStreamTrackRendererQueue, WorkQueue::create("RemoteVideoMediaStreamTrackRenderer"_s, WorkQueue::QOS::UserInitiated));
    return *m_videoMediaStreamTrackRendererQueue;
}
#endif

#if USE(LIBWEBRTC) && PLATFORM(COCOA)
WorkQueue& GPUProcess::libWebRTCCodecsQueue()
{
    if (!m_libWebRTCCodecsQueue)
        lazyInitialize(m_libWebRTCCodecsQueue, WorkQueue::create("LibWebRTCCodecsQueue"_s, WorkQueue::QOS::UserInitiated));
    return *m_libWebRTCCodecsQueue;
}
#endif

void GPUProcess::webProcessConnectionCountForTesting(CompletionHandler<void(uint64_t)>&& completionHandler)
{
    completionHandler(GPUConnectionToWebProcess::objectCountForTesting());
}

#if PLATFORM(COCOA)
void GPUProcess::printProcessDrawingCountsForTesting(CompletionHandler<void(uint64_t, uint64_t)>&& completionHandler)
{
    completionHandler(RemoteSnapshotPDFDrawingTask::drawnInPrintProcessCountForTesting(), RemoteSnapshotPDFDrawingTask::drawnAfterPrintProcessFailedCountForTesting());
}
#endif

void GPUProcess::terminateWebProcess(WebCore::ProcessIdentifier identifier, IPC::MessageName invalidMessageName)
{
    protect(parentProcessConnection())->send(Messages::GPUProcessProxy::TerminateWebProcess(identifier, invalidMessageName), 0);
}

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
void GPUProcess::processIsStartingToCaptureAudio(GPUConnectionToWebProcess& process)
{
    for (auto& connection : m_webProcessConnections.values())
        connection->processIsStartingToCaptureAudio(process);
}
#endif

#if ENABLE(WEBXR)
std::optional<WebCore::ProcessIdentity> GPUProcess::immersiveModeProcessIdentity() const
{
    return m_processIdentity;
}

void GPUProcess::webXRPromptAccepted(std::optional<WebCore::ProcessIdentity> processIdentity, CompletionHandler<void(bool)>&& completionHandler)
{
    m_processIdentity = processIdentity;
    completionHandler(true);
}
#endif

#if HAVE(AUDIT_TOKEN)
void GPUProcess::setPresentingApplicationAuditToken(WebCore::ProcessIdentifier processIdentifier, WebCore::PageIdentifier pageIdentifier, std::optional<WebKit::CoreIPCAuditToken>&& auditToken)
{
    if (RefPtr connection = m_webProcessConnections.get(processIdentifier))
        connection->setPresentingApplicationAuditToken(pageIdentifier, WTF::move(auditToken));
}
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)
