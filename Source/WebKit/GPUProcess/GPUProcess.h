/*
 * Copyright (C) 2019-2024 Apple Inc. All rights reserved.
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

#if ENABLE(GPU_PROCESS)

#if ENABLE(GPU_PROCESS_CORE_SWIFT)

#include "AuxiliaryProcess.h"
#include "GPUProcessConnectionParameters.h"
#include "GPUProcessCreationParameters.h"
#include "GPUProcessPreferences.h"
#include "GPUProcessSessionParameters.h"
#include "ImageBufferBackendHandle.h"
#include "RemoteSnapshotIdentifier.h"
#include "RemoteSnapshotSink.h"
#include "SandboxExtension.h"
#include "SecurityFlags.h"
#include "SharedPreferencesForWebProcess.h"
#include <WebCore/ColorSpace.h>
#include <WebCore/FloatSize.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/HostingContext.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/ImageBufferTransferIdentifier.h>
#include <WebCore/IntDegrees.h>
#include <WebCore/MediaSessionIdentifier.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/ProcessIdentity.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/ShareableBitmap.h>
#include <pal/SessionID.h>
#include <wtf/Language.h>
#include <wtf/MemoryPressureHandler.h>
#include <wtf/MonotonicTime.h>
#include <wtf/RefCountable.h>
#include <wtf/SwiftBridging.h>

#if ENABLE(MEDIA_STREAM)
#include <WebCore/CaptureDevice.h>
#include <WebCore/MockMediaDevice.h>
#endif

#if HAVE(AUDIT_TOKEN)
#include "CoreIPCAuditToken.h"
#endif

#if HAVE(SCREEN_CAPTURE_KIT)
#include <WebCore/DisplayCapturePromptType.h>
#endif

#if PLATFORM(VISION) && ENABLE(MODEL_PROCESS) && HAVE(CORE_RE)
#include "SharedFileHandle.h"
#endif

namespace WebCore {
class NowPlayingManager;
struct ScreenProperties;
}

namespace WebKit {

class SampleBufferDisplayLayerHost;
class GPUConnectionToWebProcess;

using GPUProcessConnectionParametersArgument = WTF::MoveOnlyArgument<GPUProcessConnectionParameters>;
using GPUProcessSessionParametersArgument = WTF::MoveOnlyArgument<GPUProcessSessionParameters>;

using RefPtrTransferredImageBuffer = RefPtr<WebCore::ImageBuffer>;
#if HAVE(AUDIT_TOKEN)
using OptionalCoreIPCAuditToken = std::optional<CoreIPCAuditToken>;
#endif
// The replies of messages that Swift handles, as IPC makes their completion handlers reference-counted for it.
using GPUProcessVoidReply = WTF::RefCountable<CompletionHandler<void()>>;
using GPUProcessCountReply = WTF::RefCountable<CompletionHandler<void(uint64_t)>>;
using GPUProcessDrawingCountsReply = WTF::RefCountable<CompletionHandler<void(uint64_t, uint64_t)>>;

// Swift (GPUProcess.swift) implements most of the process, and holds its state in m_swiftState. C++ keeps what Swift can't
// take: messages with sandbox extension or connection handles, replies that move C++ values, and accessors that return
// references.
class SWIFT_PRIVATE_FILEID("WebKit/GPUProcess.swift") GPUProcess final : public AuxiliaryProcess, public ThreadSafeRefCounted<GPUProcess> {
    WTF_MAKE_NONCOPYABLE(GPUProcess);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(GPUProcess);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(GPUProcess);
public:
    ~GPUProcess();

    static GPUProcess& singleton();
    static constexpr WTF::AuxiliaryProcessType processType = WTF::AuxiliaryProcessType::GPU;

    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }

    void removeGPUConnectionToWebProcess(GPUConnectionToWebProcess&);
    void connectionToWebProcessClosed(IPC::Connection&) { }
    GPUConnectionToWebProcess* webProcessConnection(WebCore::ProcessIdentifier) const;
    IPC::Connection* WTF_NULLABLE uiProcessConnection() const { return parentProcessConnection(); }

    SWIFT_MAIN_ACTOR String mediaCacheDirectory(PAL::SessionID) const;
#if ENABLE(LEGACY_ENCRYPTED_MEDIA) || ENABLE(ENCRYPTED_MEDIA)
    SWIFT_MAIN_ACTOR String mediaKeysStorageDirectory(PAL::SessionID) const;
#endif

    WebCore::NowPlayingManager& nowPlayingManager() LIFETIME_BOUND;

#if ENABLE(MEDIA_STREAM)
    WorkQueue& videoMediaStreamTrackRendererQueue() { return m_videoMediaStreamTrackRendererQueue; }
    void ensureAVCaptureServerConnection();
    SWIFT_MAIN_ACTOR void didApplyCaptureEnvironment(WebCore::ProcessIdentifier, WebCore::PageIdentifier);
    bool setCaptureAttributionString(WebCore::SecurityOriginData);
#if PLATFORM(IOS_FAMILY) && ENABLE(APP_PRIVACY_REPORT) && !PLATFORM(MACCATALYST)
    bool setCaptureTCCIdentity(const String& fallbackBundleIdentifier);
    bool hasCaptureIdentity(const String& applicationBundleIdentifier);
#endif
#endif

#if USE(LIBWEBRTC)
    WorkQueue& libWebRTCCodecsQueue() { return m_libWebRTCCodecsQueue; }
#endif

    SWIFT_MAIN_ACTOR void tryExitIfUnusedAndUnderMemoryPressure();

#if ENABLE(WEBXR)
    std::optional<WebCore::ProcessIdentity> immersiveModeProcessIdentity() const { return m_processIdentity; }
#endif

    // The snapshots are Swift's (RemoteSnapshot.swift), which these hand the messages about them to.
    // Created by the process painting its root, or by whoever asks to draw it if that comes first.
    // Neither can come after it is released. A frame recording into one that does not exist records
    // into nothing, so none can bring back a snapshot that was released.
    void createSnapshot(RemoteSnapshotIdentifier, WebCore::FrameIdentifier rootFrameIdentifier, WebCore::FloatSize, WebCore::ProcessIdentifier rootProcessIdentifier);
    // For a root that could not be recorded.
    void failSnapshot(RemoteSnapshotIdentifier);
    void abandonSnapshotFrame(RemoteSnapshotIdentifier, WebCore::FrameIdentifier);

    // Hands an ImageBuffer from one web process's rendering backend to another's. Unlike
    // a snapshot's, the identifier is minted here and unguessable, so only a process it was given
    // can claim the buffer. The depositing process owns an unclaimed buffer until the process
    // brokering delivery hands it on, which only decides whose exit discards it. On any thread.
    WebCore::ImageBufferTransferIdentifier depositTransferredImageBuffer(WebCore::ProcessIdentifier owner, WebCore::ImageBuffer&);
    RefPtrTransferredImageBuffer takeTransferredImageBuffer(WebCore::ImageBufferTransferIdentifier);
    void releaseTransferredImageBuffer(WebCore::ImageBufferTransferIdentifier);

    void terminateWebProcess(WebCore::ProcessIdentifier, IPC::MessageName);

#if ENABLE(MEDIA_STREAM)
    // For the capture preview (CapturePreviewManager.swift).
    SWIFT_MAIN_ACTOR uint8_t swiftStartCapturePreview(uint64_t pageIdentifier, String videoDeviceID, String videoDeviceLabel, bool videoDeviceIsDefault, String audioDeviceID, String audioDeviceLabel, bool audioDeviceIsDefault, int32_t previewWidth, int32_t previewHeight, int32_t orientation, SampleBufferDisplayLayerHost* WTF_NULLABLE);
    SWIFT_MAIN_ACTOR void swiftStopCapturePreview();
    SWIFT_MAIN_ACTOR bool swiftHasCapturePreview() const;
    SWIFT_MAIN_ACTOR void capturePreviewAudioSessionIsReady(uint64_t generation);
#if (PLATFORM(IOS_FAMILY) || ENABLE(ROUTING_ARBITRATION)) && USE(AUDIO_SESSION)
    // Implemented in Swift (RemoteAudioSessionProxyManager.swift): the audio session arbitration has the preview's session
    // record, then tells capturePreviewAudioSessionIsReady(), or stops.
    SWIFT_MAIN_ACTOR void swiftBeginCapturePreviewAudioSession(uint64_t generation);
    SWIFT_MAIN_ACTOR void swiftEndCapturePreviewAudioSession();
#endif
    static bool capturePreviewNeedsAudioSession();
    SWIFT_MAIN_ACTOR static void beginCapturePreviewAudioSession(uint64_t generation);
    SWIFT_MAIN_ACTOR static void endCapturePreviewAudioSession();
    SWIFT_MAIN_ACTOR static void capturePreviewAudioLevelChanged(uint64_t pageIdentifier, float level);
#endif

private:
    GPUProcess();

    uintptr_t createSwiftState();
    // Unsafe: the state must be the one createSwiftState() made, which only the destructor releases.
    SWIFT_UNSAFE static void destroySwiftState(uintptr_t);
    uintptr_t swiftState() const { return m_swiftState; }

    SWIFT_MAIN_ACTOR void lowMemoryHandler(Critical, Synchronous);
    SWIFT_MAIN_ACTOR void tryExitIfUnused();
    SWIFT_MAIN_ACTOR bool canExitUnderMemoryPressure() const;
    SWIFT_MAIN_ACTOR void didRemoveWebProcessConnection(GPUConnectionToWebProcess&);

    // AuxiliaryProcess
    void initializeProcess(const AuxiliaryProcessInitializationParameters&) override;
    void initializeProcessName(const AuxiliaryProcessInitializationParameters&) override;
    void initializeSandbox(const AuxiliaryProcessInitializationParameters&, SandboxInitializationParameters&) override;
    Thread::QOS connectionReceiveQueueQOS() const override { return Thread::QOS::UserInteractive; }
    bool shouldTerminate() override { return m_webProcessConnections.isEmpty(); }
    RetainPtr<NSDictionary> additionalStateForDiagnosticReport() const final;
    void dispatchSimulatedNotificationsForPreferenceChange(const String&) final { }

    // IPC::Connection::Client
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) override;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) override;

    // Message handlers. Those that Swift implements take their arguments by value.
    void initializeGPUProcess(GPUProcessCreationParameters&&, CompletionHandler<void()>&&);
    SWIFT_MAIN_ACTOR void swiftInitializeNowPlayingFallbackSession(uint64_t sessionIdentifier, uint64_t processIdentifier);
    // Unsafe: Swift borrows the parameters for the call, and only reads their values.
    SWIFT_UNSAFE SWIFT_MAIN_ACTOR void swiftInitializeGPUProcess(const GPUProcessCreationParameters&);
    SWIFT_MAIN_ACTOR void createGPUConnectionToWebProcess(WebCore::ProcessIdentifier, PAL::SessionID, IPC::ConnectionHandleArgument, GPUProcessConnectionParametersArgument, GPUProcessVoidReply* WTF_NONNULL);
    // Whether the connection is new, which this then keeps.
    bool addWebProcessConnection(GPUConnectionToWebProcess&, bool ignoreInvalidMessageForTesting);
    SWIFT_MAIN_ACTOR void sharedPreferencesForWebProcessDidChange(WebCore::ProcessIdentifier, SharedPreferencesForWebProcess, GPUProcessVoidReply* WTF_NONNULL);
    void securityFlagsDidChange(SecurityFlags::Storage&& securityFlags) { SecurityFlags::Storage::update(WTF::move(securityFlags)); }
    SWIFT_MAIN_ACTOR void updateGPUProcessPreferences(GPUProcessPreferences);
    void updateSandboxAccess(const Vector<SandboxExtension::Handle>&);
    SWIFT_MAIN_ACTOR void prepareToSuspend(bool isSuspensionImminent, MonotonicTime estimatedSuspendTime, GPUProcessVoidReply* WTF_NONNULL);
    SWIFT_MAIN_ACTOR void processDidResume();
    SWIFT_MAIN_ACTOR void addSession(PAL::SessionID, GPUProcessSessionParametersArgument);
    SWIFT_MAIN_ACTOR void removeSession(PAL::SessionID);
    void userPreferredLanguagesChanged(Vector<String>&& languages) { overrideUserPreferredLanguages(languages); }

#if ENABLE(MEDIA_STREAM)
    SWIFT_MAIN_ACTOR void setMockCaptureDevicesEnabled(bool);
    void enableMicrophoneMuteStatusAPI();
    SWIFT_MAIN_ACTOR void updateCaptureOrigin(WebCore::SecurityOriginData, WebCore::ProcessIdentifier);
    void startCapturePreview(std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice, WebCore::PageIdentifier, WebCore::IntSize previewSize, WebCore::IntDegrees orientation, Vector<SandboxExtension::Handle>&&, String&& applicationBundleIdentifier, WebCore::SecurityOriginData&&, CompletionHandler<void(WebCore::HostingContext)>&&);
    SWIFT_MAIN_ACTOR bool swiftCanStartCapturePreview(WebCore::PageIdentifier);
    SWIFT_MAIN_ACTOR bool swiftPrepareCapturePreview(WebCore::PageIdentifier, bool hasCamera, String applicationBundleIdentifier, WebCore::SecurityOriginData);
    SWIFT_MAIN_ACTOR WebCore::HostingContext swiftStartCapturePreviewForPage(WebCore::PageIdentifier, SampleBufferDisplayLayerHost* WTF_NULLABLE, String videoDeviceID, String videoDeviceLabel, bool videoDeviceIsDefault, String audioDeviceID, String audioDeviceLabel, bool audioDeviceIsDefault, WebCore::IntSize previewSize, WebCore::IntDegrees orientation);
    SWIFT_MAIN_ACTOR void stopCapturePreview(WebCore::PageIdentifier, GPUProcessVoidReply* WTF_NONNULL);
    void revokeCapturePreviewSandboxExtensions();
#if PLATFORM(IOS_FAMILY)
    bool platformSetUpCapturePreviewEnvironment(WebCore::PageIdentifier, bool hasCamera);
#endif
    SWIFT_MAIN_ACTOR void addMockMediaDevice(WebCore::MockMediaDevice);
    void clearMockMediaDevices();
    SWIFT_MAIN_ACTOR void removeMockMediaDevice(String);
    SWIFT_MAIN_ACTOR void setMockMediaDeviceIsEphemeral(String, bool);
    SWIFT_MAIN_ACTOR void resetMockMediaDevices();
    SWIFT_MAIN_ACTOR void setMockCaptureDevicesInterrupted(bool isCameraInterrupted, bool isMicrophoneInterrupted);
    void triggerMockCaptureConfigurationChange(bool forCamera, bool forMicrophone, bool forDisplay);
    void setShouldListenToVoiceActivity(bool);
#endif
#if HAVE(SCREEN_CAPTURE_KIT)
    void promptForGetDisplayMedia(WebCore::DisplayCapturePromptType, CompletionHandler<void(std::optional<WebCore::CaptureDevice>)>&&);
    void cancelGetDisplayMediaPrompt();
#endif
#if PLATFORM(MAC)
    // HAVE(AVPLAYER_VIDEORANGEOVERRIDE): AVFoundation overrides HDR support itself.
    void setScreenProperties(const WebCore::ScreenProperties&) { }
    void updateProcessName();
    void openDirectoryCacheInvalidated(SandboxExtension::Handle&&);
#endif
    void sinkCompletedSnapshotToPDF(RemoteSnapshotIdentifier, WebCore::FrameIdentifier, std::optional<WebCore::ProcessIdentifier> printProcessIdentifier, CompletionHandler<void(RefPtr<WebCore::SharedBuffer>&&)>&&);
    void sinkCompletedSnapshotToBitmap(RemoteSnapshotIdentifier, WebCore::FrameIdentifier, CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>&&)>&&);
    void sinkCompletedSnapshotToIOSurface(RemoteSnapshotIdentifier, float scale, const WebCore::ColorSpace&, WebCore::FrameIdentifier, CompletionHandler<void(std::optional<ImageBufferBackendHandle>&&)>&&);
    void waitForSnapshot(RemoteSnapshotIdentifier, CompletionHandler<void()>&&);
    SWIFT_MAIN_ACTOR void releaseSnapshot(RemoteSnapshotIdentifier);
    SWIFT_MAIN_ACTOR void snapshotFrameWillBeDrawnByProcess(RemoteSnapshotIdentifier, WebCore::FrameIdentifier, WebCore::ProcessIdentifier);
    SWIFT_MAIN_ACTOR void abandonSnapshotFramesOwnedBy(WebCore::ProcessIdentifier);
    // Implemented in Swift (RemoteSnapshot.swift), on its registry of snapshots, which the rendering backends' work queues
    // reach too.
    static void swiftCreateSnapshot(RemoteSnapshotKey, WebCore::FrameIdentifier rootFrameIdentifier, WebCore::FloatSize, WebCore::ProcessIdentifier rootProcessIdentifier);
    static void swiftFailSnapshot(RemoteSnapshotKey);
    static void swiftAbandonSnapshotFrame(RemoteSnapshotKey, WebCore::FrameIdentifier);
    static void swiftReleaseSnapshot(RemoteSnapshotKey);
    static void swiftSnapshotFrameWillBeDrawnByProcess(RemoteSnapshotKey, WebCore::FrameIdentifier, WebCore::ProcessIdentifier);
    static void swiftAbandonSnapshotFramesOwnedBy(WebCore::ProcessIdentifier);
    static void swiftRemoveSnapshotsForProcess(WebCore::ProcessIdentifier);
#if HAVE(POWERLOG_TASK_MODE_QUERY)
    void enablePowerLogging(SandboxExtension::Handle&& handle) { SandboxExtension::consumePermanently(WTF::move(handle)); }
#endif
    SWIFT_MAIN_ACTOR void webProcessConnectionCountForTesting(GPUProcessCountReply* WTF_NONNULL);
    SWIFT_MAIN_ACTOR void printProcessDrawingCountsForTesting(GPUProcessDrawingCountsReply* WTF_NONNULL);
#if PLATFORM(IOS_FAMILY) && USE(EXTENSIONKIT)
    void resolveBookmarkDataForCacheDirectory(std::span<const uint8_t> bookmarkData);
#endif
#if ENABLE(WEBXR)
    void webXRPromptAccepted(std::optional<WebCore::ProcessIdentity>, CompletionHandler<void(bool)>&&);
#endif
#if HAVE(AUDIT_TOKEN)
    SWIFT_MAIN_ACTOR void setPresentingApplicationAuditToken(WebCore::ProcessIdentifier, WebCore::PageIdentifier, OptionalCoreIPCAuditToken);
#endif
#if PLATFORM(VISION) && ENABLE(MODEL_PROCESS)
#if HAVE(CORE_RE)
    void requestSharedSimulationConnection(CoreIPCAuditToken&&, CompletionHandler<void(std::optional<IPC::SharedFileHandle>)>&&);
#endif
#if HAVE(TASK_IDENTITY_TOKEN)
    void createMemoryAttributionIDForTask(WebCore::ProcessIdentity, CompletionHandler<void(const std::optional<String>&)>&&);
    void unregisterMemoryAttributionID(const String&, CompletionHandler<void()>&&);
#endif
#endif
    SWIFT_MAIN_ACTOR void postWillTakeSnapshotNotification(GPUProcessVoidReply* WTF_NONNULL);
    void registerFonts(Vector<SandboxExtension::Handle>&& sandboxExtensions) { SandboxExtension::consumePermanently(sandboxExtensions); }
    void handOverTransferredImageBuffers(Vector<WebCore::ImageBufferTransferIdentifier>&& identifiers, WebCore::ProcessIdentifier destinationProcess)
    {
        // Not waited for, so the destination may already have claimed some of them.
        for (auto identifier : identifiers)
            handOverTransferredImageBuffer(identifier, destinationProcess);
    }
    void handOverTransferredImageBuffer(WebCore::ImageBufferTransferIdentifier, WebCore::ProcessIdentifier destinationProcess);
    void releaseTransferredImageBuffers(Vector<WebCore::ImageBufferTransferIdentifier>&& identifiers)
    {
        for (auto identifier : identifiers)
            releaseTransferredImageBuffer(identifier);
    }

    HashMap<WebCore::ProcessIdentifier, Ref<GPUConnectionToWebProcess>> m_webProcessConnections;
    String m_applicationVisibleName;
#if PLATFORM(MAC)
    String m_uiProcessName;
#endif
#if ENABLE(MEDIA_STREAM)
    Vector<Ref<SandboxExtension>> m_capturePreviewSandboxExtensions;
#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
    std::optional<String> m_savedPreferredMicrophoneID;
#endif
    const Ref<WorkQueue> m_videoMediaStreamTrackRendererQueue { WorkQueue::create("RemoteVideoMediaStreamTrackRenderer"_s, WorkQueue::QOS::UserInitiated) };
#endif
#if USE(LIBWEBRTC)
    const Ref<WorkQueue> m_libWebRTCCodecsQueue { WorkQueue::create("LibWebRTCCodecsQueue"_s, WorkQueue::QOS::UserInitiated) };
#endif
    const std::unique_ptr<WebCore::NowPlayingManager> m_nowPlayingManager;
#if ENABLE(WEBXR)
    std::optional<WebCore::ProcessIdentity> m_processIdentity;
#endif
    // A retained reference to the Swift state, as an address, from the constructor to the destructor.
    uintptr_t m_swiftState __attribute__((availability(swift, unavailable))) { 0 };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebKit

#else // ENABLE(GPU_PROCESS_CORE_SWIFT)

#include "AuxiliaryProcess.h"
#include "GPUProcessPreferences.h"
#include "ImageBufferBackendHandle.h"
#include "RemoteSerializedImageBufferIdentifier.h"
#include <WebCore/ColorSpace.h>
#include <WebCore/ImageBufferTransferIdentifier.h>
#include "RemoteSnapshotIdentifier.h"
#include "RemoteSnapshotSink.h"
#include "SandboxExtension.h"
#include "SecurityFlags.h"
#include "WebPageProxyIdentifier.h"
#include <WebCore/FrameIdentifier.h>
#include <WebCore/HostingContext.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/IntDegrees.h>
#include <WebCore/MediaPlayerIdentifier.h>
#include <WebCore/MediaSessionIdentifier.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/ProcessIdentity.h>
#include <WebCore/ShareableBitmap.h>
#include <WebCore/Timer.h>
#include <pal/SessionID.h>
#include <wtf/Function.h>
#include <wtf/Lock.h>
#include <wtf/Markable.h>
#include <wtf/MemoryPressureHandler.h>
#include <wtf/MonotonicTime.h>
#include <wtf/NativePromise.h>
#include <wtf/SwiftBridging.h>
#include <wtf/WeakPtr.h>

#if PLATFORM(MAC)
#include <CoreGraphics/CGDisplayConfiguration.h>
#endif

#if USE(GRAPHICS_LAYER_WC)
#include "WCSharedSceneContextHolder.h"
#endif

#if HAVE(SCREEN_CAPTURE_KIT)
#include <WebCore/DisplayCapturePromptType.h>
#endif

#if PLATFORM(VISION) && ENABLE(MODEL_PROCESS) && HAVE(CORE_RE)
#include "SharedFileHandle.h"
#endif

namespace WebCore {
class CaptureDevice;
class NowPlayingManager;
class SecurityOriginData;

struct MockMediaDevice;
struct ScreenProperties;

namespace DisplayList {
class DisplayList;
}

enum class VideoFrameRotation : uint16_t;
}

namespace WebKit {

class SampleBufferDisplayLayerHost;
class GPUConnectionToWebProcess;
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
class RemoteSnapshotDisplayLists;
#endif
struct CoreIPCAuditToken;
struct GPUProcessConnectionParameters;
struct GPUProcessCreationParameters;
struct GPUProcessSessionParameters;
struct SharedPreferencesForWebProcess;

// m_swiftState holds the process's Swift state (GPUProcess.swift).
class SWIFT_PRIVATE_FILEID("WebKit/GPUProcess.swift") GPUProcess final : public AuxiliaryProcess, public ThreadSafeRefCounted<GPUProcess> {
    WTF_MAKE_NONCOPYABLE(GPUProcess);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(GPUProcess);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(GPUProcess);
public:
    ~GPUProcess();

    static GPUProcess& singleton();
    static constexpr WTF::AuxiliaryProcessType processType = WTF::AuxiliaryProcessType::GPU;

    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }

    void removeGPUConnectionToWebProcess(GPUConnectionToWebProcess&);

    void prepareToSuspend(bool isSuspensionImminent, MonotonicTime estimatedSuspendTime, CompletionHandler<void()>&&);
    void processDidResume();
    NODELETE void resume();

    NODELETE void connectionToWebProcessClosed(IPC::Connection&);

    GPUConnectionToWebProcess* webProcessConnection(WebCore::ProcessIdentifier) const;

    NODELETE const String& mediaCacheDirectory(PAL::SessionID) const LIFETIME_BOUND;
#if ENABLE(LEGACY_ENCRYPTED_MEDIA) || ENABLE(ENCRYPTED_MEDIA)
    NODELETE const String& mediaKeysStorageDirectory(PAL::SessionID) const LIFETIME_BOUND;
#endif

    WebCore::NowPlayingManager& nowPlayingManager() LIFETIME_BOUND;

    // The Now Playing election is Swift's (GPUProcess.swift). For it: tells the UI process which page owns Now Playing,
    // if any.
    static void nowPlayingOwnerDidChange(bool hasOwner, uint64_t pageIdentifier, uint64_t processIdentifier);
    // Implemented in Swift: the UI process's session that gets the remote commands while no page owns Now Playing.
    SWIFT_MAIN_ACTOR void swiftInitializeNowPlayingFallbackSession(uint64_t sessionIdentifier, uint64_t processIdentifier);

#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
    WorkQueue& videoMediaStreamTrackRendererQueue();
    void ensureAVCaptureServerConnection();
    void didApplyCaptureEnvironment(WebCore::ProcessIdentifier, WebCore::PageIdentifier);
    bool setCaptureAttributionString(const WebCore::SecurityOriginData&);
#if ENABLE(APP_PRIVACY_REPORT) && !PLATFORM(MACCATALYST)
    bool setCaptureTCCIdentity(const String& fallbackBundleIdentifier);
#endif
#endif

#if USE(LIBWEBRTC) && PLATFORM(COCOA)
    WorkQueue& libWebRTCCodecsQueue();
#endif

#if USE(GRAPHICS_LAYER_WC)
    WCSharedSceneContextHolder& sharedSceneContext() LIFETIME_BOUND { return m_sharedSceneContext; }
#endif

    // Implemented in Swift (GPUProcess.swift), as the idle exit and the low memory handling are.
    SWIFT_MAIN_ACTOR void tryExitIfUnusedAndUnderMemoryPressure();

    // For the idle exit and the low memory handling in Swift.
    static bool isUnderMemoryPressure();
    static bool isSimulatingMemoryPressure();
    static void releaseMemory(Critical, Synchronous);
    void sendProcessIsReadyToExit();

    const String& applicationVisibleName() const LIFETIME_BOUND { return m_applicationVisibleName; }

    void webProcessConnectionCountForTesting(CompletionHandler<void(uint64_t)>&&);
#if PLATFORM(COCOA)
    void printProcessDrawingCountsForTesting(CompletionHandler<void(uint64_t drawnInPrintProcess, uint64_t drawnAfterPrintProcessFailed)>&&);
#endif

#if USE(EXTENSIONKIT)
    void resolveBookmarkDataForCacheDirectory(std::span<const uint8_t> bookmarkData);
#endif

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
    void processIsStartingToCaptureAudio(GPUConnectionToWebProcess&);
#endif

#if ENABLE(WEBXR)
    std::optional<WebCore::ProcessIdentity> immersiveModeProcessIdentity() const;
#endif

#if HAVE(AUDIT_TOKEN)
    void setPresentingApplicationAuditToken(WebCore::ProcessIdentifier, WebCore::PageIdentifier, std::optional<CoreIPCAuditToken>&&);
#endif

    // The snapshots are Swift's (RemoteSnapshot.swift), which these hand the messages about them to.
    // Created by the process painting its root, or by whoever asks to draw it if that comes first.
    // Neither can come after it is released. A frame recording into one that does not exist records
    // into nothing, so none can bring back a snapshot that was released.
    void createSnapshot(RemoteSnapshotIdentifier, WebCore::FrameIdentifier rootFrameIdentifier, const WebCore::FloatSize&, WebCore::ProcessIdentifier rootProcessIdentifier);
    // For a root that could not be recorded.
    void failSnapshot(RemoteSnapshotIdentifier);
    void abandonSnapshotFrame(RemoteSnapshotIdentifier, WebCore::FrameIdentifier);
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    // For the ports that record snapshot frames as WebCore display lists (RemoteSnapshotRecorder.h): a snapshot's display
    // lists, or, for one that doesn't exist or whose display lists don't have the token, ones that are dropped with whoever
    // takes them. The recorders' frames reach the snapshot only if it has the display lists they record into.
#ifndef __swift__
    static Ref<RemoteSnapshotDisplayLists> snapshotDisplayLists(const RemoteSnapshotIdentifier&, std::optional<uint64_t> token = std::nullopt);
#endif
    static void addSnapshotFrameReference(const RemoteSnapshotIdentifier&, WebCore::FrameIdentifier, uint64_t displayListsToken);
    static void snapshotFrameWasRecorded(const RemoteSnapshotIdentifier&, WebCore::FrameIdentifier, uint64_t displayListsToken);
    // For Swift, which keeps a snapshot's display lists as long as it keeps the snapshot: their token.
    static uint64_t createSnapshotDisplayLists(RemoteSnapshotKey);
    static void forgetSnapshotDisplayLists(RemoteSnapshotKey);
    static void abandonSnapshotDisplayList(RemoteSnapshotKey, uint64_t frameKey);
#endif

    // Hands an ImageBuffer from one web process's rendering backend to another's. Unlike
    // a snapshot's, the identifier is minted here and unguessable, so only a process it was given
    // can claim the buffer. The depositing process owns an unclaimed buffer until the process
    // brokering delivery hands it on, which only decides whose exit discards it.
    WebCore::ImageBufferTransferIdentifier depositTransferredImageBuffer(WebCore::ProcessIdentifier owner, Ref<WebCore::ImageBuffer>&&);
    RefPtr<WebCore::ImageBuffer> takeTransferredImageBuffer(WebCore::ImageBufferTransferIdentifier);
    void releaseTransferredImageBuffer(WebCore::ImageBufferTransferIdentifier);
    void removeTransferredImageBuffersForProcess(WebCore::ProcessIdentifier);

#if PLATFORM(VISION) && ENABLE(MODEL_PROCESS)
#if HAVE(CORE_RE)
    void requestSharedSimulationConnection(CoreIPCAuditToken&&, CompletionHandler<void(std::optional<IPC::SharedFileHandle>)>&&);
#endif
#if HAVE(TASK_IDENTITY_TOKEN)
    void createMemoryAttributionIDForTask(WebCore::ProcessIdentity, CompletionHandler<void(const std::optional<String>&)>&&);
    void unregisterMemoryAttributionID(const String&, CompletionHandler<void()>&&);
#endif
#endif

#if PLATFORM(COCOA)
    void postWillTakeSnapshotNotification(CompletionHandler<void()>&&);
    void registerFonts(Vector<SandboxExtension::Handle>&&);
#endif

    void terminateWebProcess(WebCore::ProcessIdentifier, IPC::MessageName);

    void handOverTransferredImageBuffers(Vector<WebCore::ImageBufferTransferIdentifier>&&, WebCore::ProcessIdentifier destinationProcess);
    // For buffers the UI process was relaying and will not deliver.
    void releaseTransferredImageBuffers(Vector<WebCore::ImageBufferTransferIdentifier>&&);

#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
    // Implemented in Swift (CapturePreviewManager.swift): the capture preview of a getUserMedia prompt. The layer is the
    // one this made for the camera, if there is one; the result is a CapturePreviewStart.
    SWIFT_MAIN_ACTOR uint8_t swiftStartCapturePreview(uint64_t pageIdentifier, String videoDeviceID, String videoDeviceLabel, bool videoDeviceIsDefault, String audioDeviceID, String audioDeviceLabel, bool audioDeviceIsDefault, int32_t previewWidth, int32_t previewHeight, int32_t orientation, SampleBufferDisplayLayerHost* WTF_NULLABLE);
    SWIFT_MAIN_ACTOR void swiftStopCapturePreview();
    SWIFT_MAIN_ACTOR bool swiftHasCapturePreview() const;
    SWIFT_MAIN_ACTOR void capturePreviewAudioSessionIsReady(uint64_t generation);
#if (PLATFORM(IOS_FAMILY) || ENABLE(ROUTING_ARBITRATION)) && USE(AUDIO_SESSION)
    // Implemented in Swift (RemoteAudioSessionProxyManager.swift): the audio session arbitration has the preview's session
    // record, then tells capturePreviewAudioSessionIsReady(), or stops.
    SWIFT_MAIN_ACTOR void swiftBeginCapturePreviewAudioSession(uint64_t generation);
    SWIFT_MAIN_ACTOR void swiftEndCapturePreviewAudioSession();
#endif

    // For the capture preview (CapturePreviewManager.swift).
    static bool capturePreviewNeedsAudioSession();
    SWIFT_MAIN_ACTOR static void beginCapturePreviewAudioSession(uint64_t generation);
    SWIFT_MAIN_ACTOR static void endCapturePreviewAudioSession();
    SWIFT_MAIN_ACTOR static void capturePreviewAudioLevelChanged(uint64_t pageIdentifier, float level);
#endif

private:
#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
    bool setUpCapturePreviewEnvironment(WebCore::PageIdentifier, const WebCore::SecurityOriginData&, bool hasCamera);
    void stopCapturePreviewManager();
    void setCapturePreviewVideoDevice(const String& persistentID, std::optional<WebCore::PageIdentifier>);
#endif

    GPUProcess();

    // Implemented in Swift.
    uintptr_t createSwiftState();
    // Unsafe: the state must be the one createSwiftState() made, which only the destructor releases.
    SWIFT_UNSAFE static void destroySwiftState(uintptr_t);
    // m_swiftState, for Swift, which can only read it.
    uintptr_t swiftState() const { return m_swiftState; }

    SWIFT_MAIN_ACTOR void lowMemoryHandler(Critical, Synchronous);

    // AuxiliaryProcess
    void initializeProcess(const AuxiliaryProcessInitializationParameters&) override;
    void initializeProcessName(const AuxiliaryProcessInitializationParameters&) override;
    void initializeSandbox(const AuxiliaryProcessInitializationParameters&, SandboxInitializationParameters&) override;
    Thread::QOS connectionReceiveQueueQOS() const override { return Thread::QOS::UserInteractive; }
    bool shouldTerminate() override;
#if PLATFORM(GTK) || PLATFORM(WPE)
    void stopRunLoop() override;
#endif

    SWIFT_MAIN_ACTOR void tryExitIfUnused();
    SWIFT_MAIN_ACTOR bool canExitUnderMemoryPressure() const;

    // IPC::Connection::Client
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) override;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) override;

    // Message Handlers
    void initializeGPUProcess(GPUProcessCreationParameters&&, CompletionHandler<void()>&&);
    void platformInitializeGPUProcess(GPUProcessCreationParameters&);
    void updateGPUProcessPreferences(GPUProcessPreferences&&);
    void createGPUConnectionToWebProcess(WebCore::ProcessIdentifier, PAL::SessionID, IPC::Connection::Handle&&, GPUProcessConnectionParameters&&, CompletionHandler<void()>&&);
    void sharedPreferencesForWebProcessDidChange(WebCore::ProcessIdentifier, SharedPreferencesForWebProcess&&, CompletionHandler<void()>&&);
    void securityFlagsDidChange(SecurityFlags::Storage&&);
    void addSession(PAL::SessionID, GPUProcessSessionParameters&&);
    void removeSession(PAL::SessionID);
    void updateSandboxAccess(const Vector<SandboxExtension::Handle>&);

    NODELETE bool updatePreference(std::optional<bool>& oldPreference, std::optional<bool>& newPreference);
    void userPreferredLanguagesChanged(Vector<String>&&);

#if ENABLE(MEDIA_STREAM)
    void setMockCaptureDevicesEnabled(bool);
    void enableMicrophoneMuteStatusAPI();
    void updateCaptureOrigin(const WebCore::SecurityOriginData&, WebCore::ProcessIdentifier);
#if PLATFORM(COCOA)
    void startCapturePreview(std::optional<WebCore::CaptureDevice>&& videoDevice, std::optional<WebCore::CaptureDevice>&& audioDevice, WebCore::PageIdentifier, WebCore::IntSize previewSize, WebCore::IntDegrees orientation, Vector<SandboxExtension::Handle>&&, String&& applicationBundleIdentifier, WebCore::SecurityOriginData&&, CompletionHandler<void(WebCore::HostingContext)>&&);
    void stopCapturePreview(WebCore::PageIdentifier, CompletionHandler<void()>&&);
#endif
    void addMockMediaDevice(const WebCore::MockMediaDevice&);
    void clearMockMediaDevices();
    void removeMockMediaDevice(const String&);
    void setMockMediaDeviceIsEphemeral(const String&, bool);
    void resetMockMediaDevices();
    void setMockCaptureDevicesInterrupted(bool isCameraInterrupted, bool isMicrophoneInterrupted);
    void triggerMockCaptureConfigurationChange(bool forCamera, bool forMicrophone, bool forDisplay);
    void setShouldListenToVoiceActivity(bool);
#endif
#if HAVE(SCREEN_CAPTURE_KIT)
    void promptForGetDisplayMedia(WebCore::DisplayCapturePromptType, CompletionHandler<void(std::optional<WebCore::CaptureDevice>)>&&);
    void selectWindowForCapture(uint32_t windowID, CompletionHandler<void(std::optional<WebCore::CaptureDevice>)>&&);
    void cancelGetDisplayMediaPrompt();
#endif
#if PLATFORM(MAC)
    NODELETE void setScreenProperties(const WebCore::ScreenProperties&);
    void updateProcessName();
#endif
#if PLATFORM(COCOA)
    void sinkCompletedSnapshotToPDF(RemoteSnapshotIdentifier, WebCore::FrameIdentifier, std::optional<WebCore::ProcessIdentifier> printProcessIdentifier, CompletionHandler<void(RefPtr<WebCore::SharedBuffer>&&)>&&);
#endif
    void sinkCompletedSnapshotToBitmap(RemoteSnapshotIdentifier, WebCore::FrameIdentifier, CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>&&)>&&);
#if HAVE(IOSURFACE)
    void sinkCompletedSnapshotToIOSurface(RemoteSnapshotIdentifier, float scale, const WebCore::ColorSpace&, WebCore::FrameIdentifier, CompletionHandler<void(std::optional<ImageBufferBackendHandle>&&)>&&);
#endif
    void releaseSnapshot(RemoteSnapshotIdentifier);
    void snapshotFrameWillBeDrawnByProcess(RemoteSnapshotIdentifier, WebCore::FrameIdentifier, WebCore::ProcessIdentifier);
    void waitForSnapshot(RemoteSnapshotIdentifier, CompletionHandler<void()>&&);
    void abandonSnapshotFramesOwnedBy(WebCore::ProcessIdentifier);

    // Implemented in Swift (RemoteSnapshot.swift), on its registry of snapshots, which the rendering backends' work queues
    // reach too.
    static void swiftCreateSnapshot(RemoteSnapshotKey, WebCore::FrameIdentifier rootFrameIdentifier, WebCore::FloatSize, WebCore::ProcessIdentifier rootProcessIdentifier);
    static void swiftFailSnapshot(RemoteSnapshotKey);
    static void swiftAbandonSnapshotFrame(RemoteSnapshotKey, WebCore::FrameIdentifier);
    static void swiftReleaseSnapshot(RemoteSnapshotKey);
    static void swiftSnapshotFrameWillBeDrawnByProcess(RemoteSnapshotKey, WebCore::FrameIdentifier, WebCore::ProcessIdentifier);
    static void swiftAbandonSnapshotFramesOwnedBy(WebCore::ProcessIdentifier);
    static void swiftRemoveSnapshotsForProcess(WebCore::ProcessIdentifier);
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    static void swiftAddSnapshotFrameReference(RemoteSnapshotKey, WebCore::FrameIdentifier, uint64_t displayListsToken);
    static void swiftSnapshotFrameWasRecorded(RemoteSnapshotKey, WebCore::FrameIdentifier, uint64_t displayListsToken);
#endif

#if USE(OS_STATE)
    RetainPtr<NSDictionary> additionalStateForDiagnosticReport() const final;
#endif

#if ENABLE(CFPREFS_DIRECT_MODE)
    void dispatchSimulatedNotificationsForPreferenceChange(const String& key) final;
#endif

#if PLATFORM(MAC)
    void openDirectoryCacheInvalidated(SandboxExtension::Handle&&);
#endif

#if HAVE(POWERLOG_TASK_MODE_QUERY)
    void enablePowerLogging(SandboxExtension::Handle&&);
#endif
#if ENABLE(WEBXR)
    void webXRPromptAccepted(std::optional<WebCore::ProcessIdentity>, CompletionHandler<void(bool)>&&);
#endif

    // Connections to WebProcesses.
    HashMap<WebCore::ProcessIdentifier, Ref<GPUConnectionToWebProcess>> m_webProcessConnections;

    GPUProcessPreferences m_preferences;

#if ENABLE(MEDIA_STREAM)
#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
    // The layer the capture preview shows its camera in, while it does.
    RefPtr<SampleBufferDisplayLayerHost> m_capturePreviewLayer;
    // The camera whose rotation the UI process monitors for the preview, and its page.
    String m_capturePreviewVideoDeviceID;
    Markable<WebCore::PageIdentifier> m_capturePreviewVideoPage;
#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
    std::optional<String> m_savedPreferredMicrophoneID;
#endif
    Markable<WebCore::PageIdentifier> m_capturePreviewPage;
    std::optional<std::pair<WebCore::ProcessIdentifier, WebCore::PageIdentifier>> m_lastCaptureEnvironment;
    Vector<Ref<SandboxExtension>> m_capturePreviewSandboxExtensions;
    const RefPtr<WorkQueue> m_videoMediaStreamTrackRendererQueue;
#endif
#endif
#if USE(LIBWEBRTC) && PLATFORM(COCOA)
    const RefPtr<WorkQueue> m_libWebRTCCodecsQueue;
#endif

#if USE(GRAPHICS_LAYER_WC)
    WCSharedSceneContextHolder m_sharedSceneContext;
#endif

    // FIXME: This is a sign that we lack local id exchange protocol. The outcome is that
    // the protocols are insecure and prone to id guessing and content stuffing.
    // Do not add more globally shared resources.
    Lock m_globalResourceLocker;
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    HashMap<RemoteSnapshotIdentifier, Ref<RemoteSnapshotDisplayLists>> m_snapshotDisplayLists WTF_GUARDED_BY_LOCK(m_globalResourceLocker);
#endif

    struct TransferredImageBuffer {
        Markable<WebCore::ProcessIdentifier> owner;
        RefPtr<WebCore::ImageBuffer> imageBuffer;
    };
    HashMap<WebCore::ImageBufferTransferIdentifier, TransferredImageBuffer> m_transferredImageBuffers WTF_GUARDED_BY_LOCK(m_globalResourceLocker);

    struct GPUSession {
        String mediaCacheDirectory;
#if ENABLE(LEGACY_ENCRYPTED_MEDIA) || ENABLE(ENCRYPTED_MEDIA)
        String mediaKeysStorageDirectory;
#endif
    };
    HashMap<PAL::SessionID, GPUSession> m_sessions;
    const std::unique_ptr<WebCore::NowPlayingManager> m_nowPlayingManager;
    String m_applicationVisibleName;
#if PLATFORM(MAC)
    String m_uiProcessName;
#endif
#if ENABLE(WEBXR)
    std::optional<WebCore::ProcessIdentity> m_processIdentity;
#endif
#if ENABLE(VP9) && PLATFORM(COCOA)
    bool m_haveEnabledVP9Decoder { false };
    bool m_haveEnabledSWVP9Decoder { false };
#endif
    // A retained reference to the Swift state, as an address, from the constructor to the destructor.
    uintptr_t m_swiftState __attribute__((availability(swift, unavailable))) { 0 };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CORE_SWIFT)

#endif // ENABLE(GPU_PROCESS)
