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
#include "RemoteSnapshot.h"
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

#if PLATFORM(COCOA)
#include "ArgumentCodersCocoa.h"
#include <WebCore/CoreAudioCaptureUnit.h>
#include <WebCore/UTIUtilities.h>
#include <WebCore/VP9UtilitiesCocoa.h>
#endif

#if HAVE(SCREEN_CAPTURE_KIT)
#include <WebCore/ScreenCaptureKitCaptureSource.h>
#endif

#if ENABLE(GPU_PROCESS_SWIFT)
// Pull in the Swift class WebKit::GPUProcess (defined in GPUProcess.swift,
// surfaced via WebKit-Swift-CPP.h) so the m_swiftReceiver member can be
// constructed in the ctor below. WebKit-Swift-CPP.h also redeclares the
// existing Phase 3 swiftGPUProcess<X> @_cdecl entry points (with
// SWIFT_NOEXCEPT) — the bare `extern "C" void swiftGPUProcess<X>(...);`
// forward declarations elsewhere in this file conflict on language linkage
// vs the SWIFT_EXTERN ... noexcept that this header provides, so they are
// removed below; the same names are available via this include.
#include "Shared/WebKit-Swift.h" // NOLINT
#endif

using namespace WebCore;

namespace WebKit {

// We wouldn't want the GPUProcess to repeatedly exit then relaunch when under memory pressure. In particular, we need to make sure the
// WebProcess has a change to schedule work after the GPUProcess get launched. For this reason, we make sure that the GPUProcess never
// idle-exits less than 5 seconds after getting launched. This amount of time should be sufficient for the WebProcess to schedule work
// work in the GPUProcess.
constexpr Seconds minimumLifetimeBeforeIdleExit { 5_s };

CxxGPUProcess::CxxGPUProcess()
    : m_idleExitTimer(*this, &CxxGPUProcess::tryExitIfUnused)
{
    RELEASE_LOG(Process, "%p - GPUProcess::GPUProcess:", this);
#if ASSERT_ENABLED && PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
    CoreAudioCaptureUnit::allowStarting();
#endif
#if ENABLE(GPU_PROCESS_SWIFT)
    // Construct the Swift IPC receiver class and register its forwarder so
    // GPUProcess messages reach the Swift handler chain. The forwarder is
    // owned by the Swift class via a Ref<>; the Swift class itself is owned
    // by m_swiftReceiver, so the forwarder's lifetime is bound to the
    // singleton's.
    m_swiftReceiver = WTF::makeUniqueWithoutFastMallocCheck<GPUProcess>(GPUProcess::init());
    addMessageReceiver(Messages::GPUProcess::messageReceiverName(), m_swiftReceiver->getMessageReceiver());
#endif
}

CxxGPUProcess::~CxxGPUProcess() = default;

CxxGPUProcess& CxxGPUProcess::singleton()
{
    static NeverDestroyed<Ref<CxxGPUProcess>> gpuProcess = adoptRef(*new CxxGPUProcess);
    return gpuProcess.get().get();
}

void CxxGPUProcess::createGPUConnectionToWebProcess(WebCore::ProcessIdentifier identifier, PAL::SessionID sessionID, IPC::Connection::Handle&& connectionHandle, GPUProcessConnectionParameters&& parameters, CompletionHandler<void()>&& completionHandler)
{
    RELEASE_LOG(Process, "%p - GPUProcess::createGPUConnectionToWebProcess: processIdentifier=%" PRIu64, this, identifier.toUInt64());

    auto reply = makeScopeExit(WTF::move(completionHandler));
    // If sender exited before we received the handle, the handle may not be valid.
    if (!connectionHandle)
        return;

    auto newConnection = GPUConnectionToWebProcess::create(*this, identifier, sessionID, WTF::move(connectionHandle), WTF::move(parameters));

#if ENABLE(MEDIA_STREAM)
    // FIXME: We should refactor code to go from WebProcess -> GPUProcess -> UIProcess when getUserMedia is called instead of going from WebProcess -> UIProcess directly.
    auto access = m_mediaCaptureAccessMap.take(identifier);
    newConnection->updateCaptureAccess(access.allowAudioCapture, access.allowVideoCapture, access.allowDisplayCapture);
    newConnection->setOrientationForMediaCapture(m_orientation);
#endif

#if ENABLE(IPC_TESTING_API)
    if (parameters.ignoreInvalidMessageForTesting)
        newConnection->connection().setIgnoreInvalidMessageForTesting();
#endif

    ASSERT(!m_webProcessConnections.contains(identifier));
    m_webProcessConnections.add(identifier, WTF::move(newConnection));
}

void CxxGPUProcess::sharedPreferencesForWebProcessDidChange(WebCore::ProcessIdentifier identifier, SharedPreferencesForWebProcess&& sharedPreferencesForWebProcess, CompletionHandler<void()>&& completionHandler)
{
    if (RefPtr connection = m_webProcessConnections.get(identifier))
        connection->updateSharedPreferencesForWebProcess(WTF::move(sharedPreferencesForWebProcess));
    completionHandler();
}

void CxxGPUProcess::removeGPUConnectionToWebProcess(GPUConnectionToWebProcess& connection)
{
    RELEASE_LOG(Process, "%p - GPUProcess::removeGPUConnectionToWebProcess: processIdentifier=%" PRIu64, this, connection.webProcessIdentifier().toUInt64());
    ASSERT(m_webProcessConnections.contains(connection.webProcessIdentifier()));
    m_webProcessConnections.remove(connection.webProcessIdentifier());
    tryExitIfUnusedAndUnderMemoryPressure();
}

void CxxGPUProcess::connectionToWebProcessClosed(IPC::Connection& connection)
{
}

bool CxxGPUProcess::shouldTerminate()
{
    return m_webProcessConnections.isEmpty();
}

bool CxxGPUProcess::canExitUnderMemoryPressure() const
{
    ASSERT(isMainRunLoop());
    for (auto& webProcessConnection : m_webProcessConnections.values()) {
        if (!webProcessConnection->allowsExitUnderMemoryPressure())
            return false;
    }
    return true;
}

void CxxGPUProcess::tryExitIfUnusedAndUnderMemoryPressure()
{
    ASSERT(isMainRunLoop());
    if (!MemoryPressureHandler::singleton().isUnderMemoryPressure())
        return;

    tryExitIfUnused();
}

void CxxGPUProcess::tryExitIfUnused()
{
    ASSERT(isMainRunLoop());
    if (!canExitUnderMemoryPressure()) {
        m_idleExitTimer.stop();
        return;
    }

    // To avoid exiting the GPUProcess too aggressively while under memory pressure and make sure the WebProcess gets a
    // change to schedule work, we don't exit if we've been running for less than |minimumLifetimeBeforeIdleExit|.
    // In case of simulated memory pressure, we ignore this rule to avoid flakiness in our benchmarks and tests.
    auto lifetime = MonotonicTime::now() - m_creationTime;
    if (lifetime < minimumLifetimeBeforeIdleExit && !MemoryPressureHandler::singleton().isSimulatingMemoryPressure()) {
        RELEASE_LOG(Process, "GPUProcess::tryExitIfUnused: GPUProcess is idle and under memory pressure but it is not exiting because it has just launched");
        // Check again after the process have lived long enough (minimumLifetimeBeforeIdleExit) to see if the GPUProcess
        // can idle-exit then.
        if (!m_idleExitTimer.isActive())
            m_idleExitTimer.startOneShot(minimumLifetimeBeforeIdleExit - lifetime);
        return;
    }
    m_idleExitTimer.stop();

    RELEASE_LOG(Process, "GPUProcess::tryExitIfUnused: GPUProcess is exiting because we are under memory pressure and the process is no longer useful.");
    protect(parentProcessConnection())->send(Messages::GPUProcessProxy::ProcessIsReadyToExit(), 0);
}

void CxxGPUProcess::lowMemoryHandler(Critical critical, Synchronous synchronous)
{
    RELEASE_LOG(Process, "GPUProcess::lowMemoryHandler: critical=%d, synchronous=%d", critical == Critical::Yes, synchronous == Synchronous::Yes);
    tryExitIfUnused();

    for (auto& connection : m_webProcessConnections.values())
        connection->lowMemoryHandler(critical, synchronous);

    WebCore::releaseGraphicsMemory(critical, synchronous);
}

void CxxGPUProcess::initializeGPUProcess(GPUProcessCreationParameters&& parameters, CompletionHandler<void()>&& completionHandler)
{
    CompletionHandlerCallingScope callCompletionHandler(WTF::move(completionHandler));

    applyProcessCreationParameters(WTF::move(parameters.auxiliaryProcessParameters));
    RELEASE_LOG(Process, "%p - GPUProcess::initializeGPUProcess:", this);
    WTF::Thread::setCurrentThreadIsUserInitiated();
    WebCore::initializeCommonAtomStrings();

    Ref memoryPressureHandler = MemoryPressureHandler::singleton();
    memoryPressureHandler->setLowMemoryHandler([weakThis = WeakPtr { *this }] (Critical critical, Synchronous synchronous) {
        if (RefPtr process = weakThis.get())
            process->lowMemoryHandler(critical, synchronous);
    });
    memoryPressureHandler->install();

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

#if USE(OS_STATE)
    registerWithStateDumper("GPUProcess state"_s);
#endif

    platformInitializeGPUProcess(parameters);
}

void CxxGPUProcess::updateGPUProcessPreferences(GPUProcessPreferences&& preferences)
{
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

bool CxxGPUProcess::updatePreference(std::optional<bool>& oldPreference, std::optional<bool>& newPreference)
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

#if ENABLE(GPU_PROCESS_SWIFT)
// Forward declaration of the Swift @_cdecl entry point for the Vector<String>-
// arg handler below (defined in SwiftGPUProcess.swift). The matching extern "C"
// bridge (WebKitGPUProcessOverrideUserPreferredLanguages) is defined further
// down in this file, next to the other Phase 3 bridges.
extern "C" void swiftGPUProcessUserPreferredLanguagesChanged(const char* const* languages, size_t count) noexcept;
#endif

void CxxGPUProcess::userPreferredLanguagesChanged(Vector<String>&& languages)
{
#if ENABLE(GPU_PROCESS_SWIFT)
    // Vector<String> at the IPC boundary becomes parallel arrays (const char**
    // + size_t count) on the C++/Swift boundary. utf8Storage owns the encoded
    // bytes and outlives the synchronous Swift call because it's a local in
    // this surrounding scope; ptrs holds borrowed views into those CStrings.
    Vector<CString> utf8Storage;
    utf8Storage.reserveInitialCapacity(languages.size());
    for (auto& lang : languages)
        utf8Storage.append(lang.utf8());
    Vector<const char*> ptrs;
    ptrs.reserveInitialCapacity(utf8Storage.size());
    for (auto& cstr : utf8Storage)
        ptrs.append(cstr.data());
    swiftGPUProcessUserPreferredLanguagesChanged(ptrs.span().data(), ptrs.size());
#else
    WTF::overrideUserPreferredLanguages(languages);
#endif
}

void CxxGPUProcess::prepareToSuspend(bool isSuspensionImminent, MonotonicTime, CompletionHandler<void()>&& completionHandler)
{
    RELEASE_LOG(ProcessSuspension, "%p - GPUProcess::prepareToSuspend(), isSuspensionImminent: %d", this, isSuspensionImminent);

    lowMemoryHandler(Critical::Yes, Synchronous::Yes);
    completionHandler();
}

void CxxGPUProcess::processDidResume()
{
    RELEASE_LOG(ProcessSuspension, "%p - GPUProcess::processDidResume()", this);
    resume();
}

void CxxGPUProcess::resume()
{
}

GPUConnectionToWebProcess* CxxGPUProcess::webProcessConnection(WebCore::ProcessIdentifier identifier) const
{
    return m_webProcessConnections.get(identifier);
}

void CxxGPUProcess::updateSandboxAccess(const Vector<SandboxExtension::Handle>& extensions)
{
    RELEASE_LOG(WebRTC, "GPUProcess::updateSandboxAccess: Adding %zu extensions", extensions.size());
    for (auto& extension : extensions)
        SandboxExtension::consumePermanently(extension);
}

Ref<RemoteSnapshot> CxxGPUProcess::getOrCreateSnapshot(RemoteSnapshotIdentifier snapshotIdentifier)
{
    Locker locker(m_globalResourceLocker);
    auto addResult = m_snapshots.ensure(snapshotIdentifier, [&] {
        return RemoteSnapshot::create();
    });
    return addResult.iterator->value;
}

#if PLATFORM(COCOA)

void CxxGPUProcess::sinkCompletedSnapshotToPDF(RemoteSnapshotIdentifier identifier, FloatSize size, FrameIdentifier rootFrameIdentifier, CompletionHandler<void(RefPtr<WebCore::SharedBuffer>&&)>&& completionHandler)
{
    RefPtr<RemoteSnapshot> snapshot;
    {
        Locker locker(m_globalResourceLocker);
        snapshot = m_snapshots.take(identifier);
    }
    if (!snapshot) {
        // Currently it's not possible to know if a snapshot exists, hence no ASSERT.
        completionHandler({ });
        return;
    }
    if (!snapshot->isComplete()) {
        // Currently the callbacks ensure the completeness.
        ASSERT_NOT_REACHED();
        return;
    }
    auto result = snapshot->drawToPDF(size, rootFrameIdentifier);
    if (!result) {
        ASSERT_NOT_REACHED();
        return;
    }
    completionHandler(WTF::move(*result));
}

#endif

void CxxGPUProcess::sinkCompletedSnapshotToBitmap(RemoteSnapshotIdentifier identifier, const FloatSize& size, FrameIdentifier rootFrameIdentifier, CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>&&)>&& completionHandler)
{
    RefPtr<RemoteSnapshot> snapshot;
    {
        Locker locker(m_globalResourceLocker);
        snapshot = m_snapshots.take(identifier);
    }
    if (!snapshot) {
        // Currently it's not possible to know if a snapshot exists, hence no ASSERT.
        completionHandler({ });
        return;
    }
    if (!snapshot->isComplete()) {
        // Currently the callbacks ensure the completeness.
        ASSERT_NOT_REACHED();
        return;
    }
    completionHandler(snapshot->drawToBitmap(size, rootFrameIdentifier));
}

void CxxGPUProcess::releaseSnapshot(RemoteSnapshotIdentifier identifier)
{
    // Currently it's not possible to know if a snapshot exists, hence no ASSERT.
    Locker locker(m_globalResourceLocker);
    m_snapshots.remove(identifier);
}

#if ENABLE(MEDIA_STREAM)
#if ENABLE(GPU_PROCESS_SWIFT)
// The Swift @_cdecl entry points used by the MEDIA_STREAM handlers below
// (swiftGPUProcessSetMockCaptureDevicesEnabled / ClearMockMediaDevices /
// ResetMockMediaDevices / SetMockCaptureDevicesInterrupted /
// TriggerMockCaptureConfigurationChange / RemoveMockMediaDevice /
// SetMockMediaDeviceIsEphemeral) are surfaced into C++ as global-scope
// SWIFT_INLINE_THUNK wrappers in WebKit-Swift-CPP.h (pulled in via
// "Shared/WebKit-Swift.h" near the top of this file), so we no longer need
// extern "C" forward declarations here. Those forward declarations would
// conflict with the inline thunks on language linkage (the thunks are C++,
// our extern "C" decls would not match).
//
// String-arg handlers (Phase 3 batch 2). The `const char*` boundary keeps
// the Swift signatures POD; both the C++ shim and the bridge convert via
// utf8()/String::fromUTF8 respectively. The CString returned by
// WTF::String::utf8() outlives the synchronous Swift call, so the raw
// pointer passed across the boundary stays valid for the call's duration.

// Typed C bridge so the Swift @_cdecl body can call the WebCore static
// MockRealtimeMediaSourceCenter::setMockRealtimeMediaSourceCenterEnabled
// without that class needing to import via Swift's C++ interop. Matches the
// WebKitGPUProcessConnectionToWebProcessObjectCount bridge pattern.
extern "C" void WebKitGPUProcessSetMockRealtimeMediaSourceCenterEnabled(bool isEnabled) noexcept
{
    WebCore::MockRealtimeMediaSourceCenter::setMockRealtimeMediaSourceCenterEnabled(isEnabled);
}

// Typed C bridges for the four batched handlers. Each preserves the exact
// WebCore::MockRealtimeMediaSourceCenter static call from the original C++
// body, on the C++ side where <WebCore/MockRealtimeMediaSourceCenter.h> is
// already included. The Swift @_cdecl bodies call these via @_silgen_name.
extern "C" void WebKitGPUProcessMockMediaCenterSetDevicesEmpty() noexcept
{
    WebCore::MockRealtimeMediaSourceCenter::setDevices({ });
}

extern "C" void WebKitGPUProcessMockMediaCenterResetDevices() noexcept
{
    WebCore::MockRealtimeMediaSourceCenter::resetDevices();
}

extern "C" void WebKitGPUProcessMockMediaCenterSetCaptureDevicesInterrupted(bool isCameraInterrupted, bool isMicrophoneInterrupted) noexcept
{
    WebCore::MockRealtimeMediaSourceCenter::setMockCaptureDevicesInterrupted(isCameraInterrupted, isMicrophoneInterrupted);
}

extern "C" void WebKitGPUProcessMockMediaCenterTriggerCaptureConfigurationChange(bool forCamera, bool forMicrophone, bool forDisplay) noexcept
{
    WebCore::MockRealtimeMediaSourceCenter::singleton().triggerMockCaptureConfigurationChange(forCamera, forMicrophone, forDisplay);
}

// String-arg bridges (Phase 3 batch 2). Convert the incoming UTF-8 C string
// back to WTF::String on the C++ side via String::fromUTF8, then call the
// WebCore static. Bridge name keeps the WebKitGPUProcessMockMediaCenter*
// family prefix.
extern "C" void WebKitGPUProcessMockMediaCenterRemoveDevice(const char* persistentId) noexcept
{
    WebCore::MockRealtimeMediaSourceCenter::removeDevice(String::fromUTF8(persistentId));
}

// Takes the [RefWrap]-wrapped MockMediaDevice from Swift's GPUProcess.swift
// addMockMediaDevice(device:) handler. The wrapped form is needed because
// MockMediaDevice is "address-only" in Swift's representation taxonomy
// (contains a std::variant of structs with non-trivial copy semantics) and
// pass-by-value triggers the swiftc IRGen crash documented at
// ~/swift-gpu-compiler-crash/. The bridge unwraps via Ref to keep the
// outer wrapper alive while we hand the inner MockMediaDevice& to WebCore.
extern "C" void WebKitGPUProcessMockMediaCenterAddDeviceFromWrap(WTF::RefCountable<WebCore::MockMediaDevice>* wrapped) noexcept
{
    Ref ref = *wrapped;
    WebCore::MockRealtimeMediaSourceCenter::addDevice(*ref.get());
}

extern "C" void WebKitGPUProcessMockMediaCenterSetDeviceIsEphemeral(const char* persistentId, bool isEphemeral) noexcept
{
    WebCore::MockRealtimeMediaSourceCenter::setDeviceIsEphemeral(String::fromUTF8(persistentId), isEphemeral);
}
#endif

void CxxGPUProcess::setMockCaptureDevicesEnabled(bool isEnabled)
{
#if ENABLE(GPU_PROCESS_SWIFT)
    // Body delegated to Swift via @_cdecl. The autogenerated IPC dispatcher
    // (DerivedSources/GPUProcessMessageReceiver.cpp) still calls this C++
    // method by name; the Swift function calls the
    // WebKitGPUProcessSetMockRealtimeMediaSourceCenterEnabled bridge above.
    swiftGPUProcessSetMockCaptureDevicesEnabled(isEnabled);
#else
    WebCore::MockRealtimeMediaSourceCenter::setMockRealtimeMediaSourceCenterEnabled(isEnabled);
#endif
}

void CxxGPUProcess::setOrientationForMediaCapture(WebCore::IntDegrees orientation)
{
    m_orientation = orientation;
    for (auto& connection : m_webProcessConnections.values())
        connection->setOrientationForMediaCapture(orientation);
}

void CxxGPUProcess::enableMicrophoneMuteStatusAPI()
{
#if PLATFORM(COCOA)
    CoreAudioCaptureUnit::defaultSingleton().setMuteStatusChangedCallback([weakProcess = WeakPtr { *this }] (bool isMuting) {
        if (RefPtr process = weakProcess.get())
            protect(process->parentProcessConnection())->send(Messages::GPUProcessProxy::MicrophoneMuteStatusChanged(isMuting), 0);
    });
#endif
}

void CxxGPUProcess::rotationAngleForCaptureDeviceChanged(const String& persistentId, WebCore::VideoFrameRotation rotation)
{
    for (auto& connection : m_webProcessConnections.values())
        connection->rotationAngleForCaptureDeviceChanged(persistentId, rotation);
}

void CxxGPUProcess::updateCaptureAccess(bool allowAudioCapture, bool allowVideoCapture, bool allowDisplayCapture, WebCore::ProcessIdentifier processID, CompletionHandler<void()>&& completionHandler)
{
    RELEASE_LOG(WebRTC, "GPUProcess::updateCaptureAccess: Entering (audio=%d, video=%d, display=%d)", allowAudioCapture, allowVideoCapture, allowDisplayCapture);

#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
    ensureAVCaptureServerConnection();
#endif

    if (RefPtr connection = webProcessConnection(processID)) {
        connection->updateCaptureAccess(allowAudioCapture, allowVideoCapture, allowDisplayCapture);
        return completionHandler();
    }

    auto& access = m_mediaCaptureAccessMap.add(processID, MediaCaptureAccess { allowAudioCapture, allowVideoCapture, allowDisplayCapture }).iterator->value;
    access.allowAudioCapture |= allowAudioCapture;
    access.allowVideoCapture |= allowVideoCapture;
    access.allowDisplayCapture |= allowDisplayCapture;

    completionHandler();
}

void CxxGPUProcess::updateCaptureOrigin(const WebCore::SecurityOriginData& originData, WebCore::ProcessIdentifier processID)
{
    if (RefPtr connection = webProcessConnection(processID))
        connection->updateCaptureOrigin(originData);
}

void CxxGPUProcess::addMockMediaDevice(const WebCore::MockMediaDevice& device)
{
    WebCore::MockRealtimeMediaSourceCenter::addDevice(device);
}

void CxxGPUProcess::clearMockMediaDevices()
{
#if ENABLE(GPU_PROCESS_SWIFT)
    // Body delegated to Swift via @_cdecl. The autogenerated IPC dispatcher
    // (DerivedSources/GPUProcessMessageReceiver.cpp) still calls this C++
    // method by name; the Swift function calls the
    // WebKitGPUProcessMockMediaCenterSetDevicesEmpty bridge above.
    swiftGPUProcessClearMockMediaDevices();
#else
    WebCore::MockRealtimeMediaSourceCenter::setDevices({ });
#endif
}

void CxxGPUProcess::removeMockMediaDevice(const String& persistentId)
{
#if ENABLE(GPU_PROCESS_SWIFT)
    // Body delegated to Swift via @_cdecl. The CString returned by
    // String::utf8() is a temporary that outlives the synchronous call, so
    // .data() is valid for the duration of swiftGPUProcessRemoveMockMediaDevice.
    swiftGPUProcessRemoveMockMediaDevice(persistentId.utf8().data());
#else
    WebCore::MockRealtimeMediaSourceCenter::removeDevice(persistentId);
#endif
}

void CxxGPUProcess::setMockMediaDeviceIsEphemeral(const String& persistentId, bool isEphemeral)
{
#if ENABLE(GPU_PROCESS_SWIFT)
    // Body delegated to Swift via @_cdecl. Same const-char-at-boundary
    // convention as removeMockMediaDevice above.
    swiftGPUProcessSetMockMediaDeviceIsEphemeral(persistentId.utf8().data(), isEphemeral);
#else
    WebCore::MockRealtimeMediaSourceCenter::setDeviceIsEphemeral(persistentId, isEphemeral);
#endif
}

void CxxGPUProcess::resetMockMediaDevices()
{
#if ENABLE(GPU_PROCESS_SWIFT)
    // Body delegated to Swift via @_cdecl. The autogenerated IPC dispatcher
    // (DerivedSources/GPUProcessMessageReceiver.cpp) still calls this C++
    // method by name; the Swift function calls the
    // WebKitGPUProcessMockMediaCenterResetDevices bridge above.
    swiftGPUProcessResetMockMediaDevices();
#else
    WebCore::MockRealtimeMediaSourceCenter::resetDevices();
#endif
}

void CxxGPUProcess::setMockCaptureDevicesInterrupted(bool isCameraInterrupted, bool isMicrophoneInterrupted)
{
#if ENABLE(GPU_PROCESS_SWIFT)
    // Body delegated to Swift via @_cdecl. The autogenerated IPC dispatcher
    // (DerivedSources/GPUProcessMessageReceiver.cpp) still calls this C++
    // method by name; the Swift function calls the
    // WebKitGPUProcessMockMediaCenterSetCaptureDevicesInterrupted bridge above.
    swiftGPUProcessSetMockCaptureDevicesInterrupted(isCameraInterrupted, isMicrophoneInterrupted);
#else
    WebCore::MockRealtimeMediaSourceCenter::setMockCaptureDevicesInterrupted(isCameraInterrupted, isMicrophoneInterrupted);
#endif
}

void CxxGPUProcess::triggerMockCaptureConfigurationChange(bool forCamera, bool forMicrophone, bool forDisplay)
{
#if ENABLE(GPU_PROCESS_SWIFT)
    // Body delegated to Swift via @_cdecl. The autogenerated IPC dispatcher
    // (DerivedSources/GPUProcessMessageReceiver.cpp) still calls this C++
    // method by name; the Swift function calls the
    // WebKitGPUProcessMockMediaCenterTriggerCaptureConfigurationChange bridge above.
    swiftGPUProcessTriggerMockCaptureConfigurationChange(forCamera, forMicrophone, forDisplay);
#else
    WebCore::MockRealtimeMediaSourceCenter::singleton().triggerMockCaptureConfigurationChange(forCamera, forMicrophone, forDisplay);
#endif
}

void CxxGPUProcess::setShouldListenToVoiceActivity(bool shouldListen)
{
#if PLATFORM(COCOA)
    if (!shouldListen) {
        RealtimeMediaSourceCenter::singleton().audioCaptureFactory().disableMutedSpeechActivityEventListener();
        return;
    }

    RealtimeMediaSourceCenter::singleton().audioCaptureFactory().enableMutedSpeechActivityEventListener([] {
        protect(CxxGPUProcess::singleton().parentProcessConnection())->send(Messages::GPUProcessProxy::VoiceActivityDetected { }, 0);
    });
#endif
}
#endif // ENABLE(MEDIA_STREAM)

#if HAVE(SCREEN_CAPTURE_KIT)
void CxxGPUProcess::promptForGetDisplayMedia(WebCore::DisplayCapturePromptType type, CompletionHandler<void(std::optional<WebCore::CaptureDevice>)>&& completionHandler)
{
    WebCore::ScreenCaptureKitSharingSessionManager::singleton().promptForGetDisplayMedia(type, WTF::move(completionHandler));
}

#if ENABLE(GPU_PROCESS_SWIFT)
// Forward declaration of the Swift @_cdecl entry point that owns the body of
// cancelGetDisplayMediaPrompt (defined in SwiftGPUProcess.swift). Same Phase 3
// pattern as the mock-media handlers above. Note: HAVE_SCREEN_CAPTURE_KIT lives
// in Source/WTF/wtf/PlatformHave.h and is not propagated to Swift as a
// conditional-compilation flag (it isn't in cmake's _WEBKIT_CONFIG_FILE_VARIABLES),
// so the Swift @_cdecl is defined unconditionally. The C++ gate here is what
// keeps the bridge symbol from being referenced when SCREEN_CAPTURE_KIT is off.

// Typed C bridge so the Swift @_cdecl body can call the WebCore static
// ScreenCaptureKitSharingSessionManager::cancelGetDisplayMediaPrompt without
// that class needing to import via Swift's C++ interop.
extern "C" void WebKitGPUProcessScreenCaptureKitSharingSessionManagerCancelGetDisplayMediaPrompt() noexcept
{
    WebCore::ScreenCaptureKitSharingSessionManager::singleton().cancelGetDisplayMediaPrompt();
}
#endif

void CxxGPUProcess::cancelGetDisplayMediaPrompt()
{
#if ENABLE(GPU_PROCESS_SWIFT)
    // Body delegated to Swift via @_cdecl. The autogenerated IPC dispatcher
    // (DerivedSources/GPUProcessMessageReceiver.cpp) still calls this C++
    // method by name; the Swift function calls the
    // WebKitGPUProcessScreenCaptureKitSharingSessionManagerCancelGetDisplayMediaPrompt
    // bridge above.
    swiftGPUProcessCancelGetDisplayMediaPrompt();
#else
    WebCore::ScreenCaptureKitSharingSessionManager::singleton().cancelGetDisplayMediaPrompt();
#endif
}

#endif // HAVE(SCREEN_CAPTURE_KIT)

void CxxGPUProcess::addSession(PAL::SessionID sessionID, GPUProcessSessionParameters&& parameters)
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

void CxxGPUProcess::removeSession(PAL::SessionID sessionID)
{
    auto findResult = m_sessions.find(sessionID);
    if (findResult == m_sessions.end()) {
        ASSERT_NOT_REACHED("Invalid SessionID");
        return;
    }
    m_sessions.remove(findResult);
}

const String& CxxGPUProcess::mediaCacheDirectory(PAL::SessionID sessionID) const
{
    auto findResult = m_sessions.find(sessionID);
    if (findResult == m_sessions.end()) {
        ASSERT_NOT_REACHED("Invalid SessionID");
        return nullString();
    }
    return findResult->value.mediaCacheDirectory;
}

#if ENABLE(LEGACY_ENCRYPTED_MEDIA) || ENABLE(ENCRYPTED_MEDIA)
const String& CxxGPUProcess::mediaKeysStorageDirectory(PAL::SessionID sessionID) const
{
    auto findResult = m_sessions.find(sessionID);
    if (findResult == m_sessions.end()) {
        ASSERT_NOT_REACHED("Invalid SessionID");
        return nullString();
    }
    return findResult->value.mediaKeysStorageDirectory;
}
#endif

WebCore::NowPlayingManager& CxxGPUProcess::nowPlayingManager()
{
    if (!m_nowPlayingManager)
        m_nowPlayingManager = makeUnique<WebCore::NowPlayingManager>();
    return *m_nowPlayingManager;
}

#if ENABLE(GPU_PROCESS) && USE(AUDIO_SESSION)
RemoteAudioSessionProxyManager& CxxGPUProcess::audioSessionManager() const
{
    if (!m_audioSessionManager)
        m_audioSessionManager = RemoteAudioSessionProxyManager::create(const_cast<CxxGPUProcess&>(*this));
    return *m_audioSessionManager;
}
#endif

#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
WorkQueue& CxxGPUProcess::videoMediaStreamTrackRendererQueue()
{
    if (!m_videoMediaStreamTrackRendererQueue)
        m_videoMediaStreamTrackRendererQueue = WorkQueue::create("RemoteVideoMediaStreamTrackRenderer"_s, WorkQueue::QOS::UserInitiated);
    return *m_videoMediaStreamTrackRendererQueue;
}
#endif

#if USE(LIBWEBRTC) && PLATFORM(COCOA)
WorkQueue& CxxGPUProcess::libWebRTCCodecsQueue()
{
    if (!m_libWebRTCCodecsQueue)
        m_libWebRTCCodecsQueue = WorkQueue::create("LibWebRTCCodecsQueue"_s, WorkQueue::QOS::UserInitiated);
    return *m_libWebRTCCodecsQueue;
}
#endif

#if ENABLE(GPU_PROCESS_SWIFT)
// Forward declaration of the Swift @_cdecl entry point that owns the body of
// webProcessConnectionCountForTesting (defined in SwiftGPUProcess.swift). At
// namespace scope so the C linkage spec is well-formed; inside the function
// body it would be ill-formed (extern "C" is a linkage specification, not a
// declaration form, so it can only appear at namespace scope).
#endif

void CxxGPUProcess::webProcessConnectionCountForTesting(CompletionHandler<void(uint64_t)>&& completionHandler)
{
#if ENABLE(GPU_PROCESS_SWIFT)
    // The autogenerated IPC dispatcher (DerivedSources/GPUProcessMessageReceiver.cpp)
    // calls GPUProcess::webProcessConnectionCountForTesting by name, so the C++
    // method declaration has to remain. The body forwards to a Swift @_cdecl
    // function (defined in SwiftGPUProcess.swift) whose body contains the
    // actual logic; this is the Phase 3 POC pattern for migrating IPC handlers
    // — keep the C++ method as a thin dispatch shim, put the logic in Swift.
    completionHandler(swiftGPUProcessWebProcessConnectionCountForTesting());
#else
    completionHandler(GPUConnectionToWebProcess::objectCountForTesting());
#endif
}

#if ENABLE(GPU_PROCESS_SWIFT)
// Typed C bridge so the Swift @_cdecl body in SwiftGPUProcess.swift can call
// GPUConnectionToWebProcess::objectCountForTesting() without that class
// needing to import via Swift's C++ interop. The class's base list
// (ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr,
// WebCore::NowPlayingManagerClient, IPC::Connection::Client) prevents Swift
// from synthesizing a usable type for it, so we expose the single
// inline-static counter accessor here as a plain extern "C" function instead.
// Matches the pattern of the existing extern "C" bridges in
// Source/WebKit/Shared/EntryPointUtilities/Cocoa/XPCService/GPUServiceEntryPoint.mm.
extern "C" uint64_t WebKitGPUProcessConnectionToWebProcessObjectCount() noexcept
{
    return GPUConnectionToWebProcess::objectCountForTesting();
}
#endif

#if ENABLE(GPU_PROCESS_SWIFT)
// Vector<String>-arg handler (Phase 3 batch). Boundary convention:
// parallel arrays of const char* + size_t count. The C++ shim builds the
// UTF-8 CStrings, the Swift @_cdecl plumbs the buffers straight through to
// the bridge below, and the bridge reconstructs a Vector<String> via
// String::fromUTF8 before calling the underlying WTF API. This establishes
// the pattern reused later for handlers taking Vector<SandboxExtension::Handle>
// (updateSandboxAccess / registerFonts). The matching swiftGPUProcess...
// forward declaration sits next to userPreferredLanguagesChanged above.
extern "C" void WebKitGPUProcessOverrideUserPreferredLanguages(const char* const* languages, size_t count) noexcept
{
    Vector<String> vec;
    vec.reserveInitialCapacity(count);
    for (size_t i = 0; i < count; ++i)
        vec.append(String::fromUTF8(languages[i]));
    WTF::overrideUserPreferredLanguages(vec);
}
#endif

void CxxGPUProcess::terminateWebProcess(WebCore::ProcessIdentifier identifier)
{
    protect(parentProcessConnection())->send(Messages::GPUProcessProxy::TerminateWebProcess(identifier), 0);
}

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
void CxxGPUProcess::processIsStartingToCaptureAudio(GPUConnectionToWebProcess& process)
{
    for (auto& connection : m_webProcessConnections.values())
        connection->processIsStartingToCaptureAudio(process);
}
#endif

#if ENABLE(WEBXR)
std::optional<WebCore::ProcessIdentity> CxxGPUProcess::immersiveModeProcessIdentity() const
{
    return m_processIdentity;
}

void CxxGPUProcess::webXRPromptAccepted(std::optional<WebCore::ProcessIdentity> processIdentity, CompletionHandler<void(bool)>&& completionHandler)
{
    m_processIdentity = processIdentity;
    completionHandler(true);
}
#endif

#if HAVE(AUDIT_TOKEN)
void CxxGPUProcess::setPresentingApplicationAuditToken(WebCore::ProcessIdentifier processIdentifier, WebCore::PageIdentifier pageIdentifier, std::optional<WebKit::CoreIPCAuditToken>&& auditToken)
{
    if (RefPtr connection = m_webProcessConnections.get(processIdentifier))
        connection->setPresentingApplicationAuditToken(pageIdentifier, WTF::move(auditToken));
}
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)
