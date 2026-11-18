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

#pragma once

#if ENABLE(GPU_PROCESS)

#include "Connection.h"
#include "GPUConnectionToWebProcessMessages.h"
#include "MessageReceiverMap.h"
#include "RemoteAudioHardwareListenerIdentifier.h"
#include "RemoteRenderingBackendIdentifier.h"
#include "RemoteSnapshotIdentifier.h"
#include "ScopedActiveMessageReceiveQueue.h"
#include "SharedPreferencesForWebProcess.h"
#include "SwiftReceiverOwner.h"
#include "WebGPUIdentifier.h"
#include <WebCore/ImageBuffer.h>
#include <WebCore/ImageBufferTransferIdentifier.h>
#include <WebCore/MediaPlayerIdentifier.h>
#include <WebCore/NowPlayingManager.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/ProcessIdentity.h>
#include <pal/SessionID.h>
#include <wtf/Logger.h>
#include <wtf/MachSendRight.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/ThreadSafeWeakPtr.h>

#if ENABLE(WEB_AUDIO) && PLATFORM(IOS_FAMILY)
#include "RemoteAudioDestinationIdentifier.h"
#endif

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
#include "SampleBufferDisplayLayerIdentifier.h"
#include <wtf/MachSendRightAnnotated.h>
#endif

#if ENABLE(WEBGL)
#include "RemoteGraphicsContextGLIdentifier.h"
#include <WebCore/GraphicsContextGLAttributes.h>
#endif

#if USE(GRAPHICS_LAYER_WC)
#include "WCLayerTreeHostIdentifier.h"
#endif

#if ENABLE(IPC_TESTING_API)
#include "IPCTester.h"
#endif

#if ENABLE(LINEAR_MEDIA_PLAYER)
#include <wtf/LazyUniqueRef.h>
#endif

namespace WTF {
enum class Critical : bool;
enum class Synchronous : bool;
}

namespace WebCore {
class CDMInstance;
class MediaPlayer;
class SecurityOrigin;
class SecurityOriginData;
}

namespace WebKit {

#if !ENABLE(GPU_PROCESS_CORE_SWIFT)
// Whether the web process has a remote command listener, the commands it supports, as a mask of 1 << command type, and
// whether it supports seeking.
struct RemoteCommandListenerState {
    bool hasListener { false };
    uint32_t commands { 0 };
    bool supportsSeeking { false };
};
#endif

#if ENABLE(WEB_AUDIO) && PLATFORM(IOS_FAMILY)
// The output unit of an audio destination that iOS's spatial experience is set on, 0 if there's no such destination, and
// whether its web process preferred a spatial experience when it made it.
struct RemoteAudioDestinationSpatialTarget {
    uint64_t outputUnitIdentifier { 0 };
    bool prefersSpatialAudioExperience { false };
};
#endif

class GPUProcess;
class LayerHostingContext;
class LibWebRTCCodecsProxyMessageForwarder;
class RemoteAudioHardwareListenerProxy;
class RemoteLegacyCDMSessionClient;
#if ENABLE(GPU_PROCESS_CDM_SWIFT)
using RefPtrCDMInstance = RefPtr<WebCore::CDMInstance>;
#endif
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
using RefPtrRemoteLegacyCDMSessionClient = RefPtr<RemoteLegacyCDMSessionClient>;
#endif
class RemoteMediaEngineConfigurationFactoryProxy;
class RemoteMediaSessionHelperProxy;
class RemoteRenderingBackend;
class RemoteSampleBufferDisplayLayerManagerMessageForwarder;
class RemoteSampleBufferDisplayLayerMessageForwarder;
class RemoteSharedResourceCache;
class VideoReceiverEndpointManager;
struct GPUProcessConnectionParameters;
#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
using OptionalMachSendRightAnnotated = std::optional<WTF::MachSendRightAnnotated>;
#endif
struct MediaOverridesForTesting;

#if USE(GRAPHICS_LAYER_WC)
class RemoteWCLayerTreeHost;
#endif

#if ENABLE(VIDEO) && PLATFORM(COCOA)
class RemoteAudioVideoRendererProxyManager;
#endif
#if ENABLE(VIDEO)
class RemoteMediaPlayerManagerProxy;
class RemoteVideoFrameObjectHeap;
#endif

// m_swiftState holds the connection's Swift state (GPUConnectionToWebProcess.swift).
class SWIFT_PRIVATE_FILEID("WebKit/GPUConnectionToWebProcess.swift") GPUConnectionToWebProcess
    : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<GPUConnectionToWebProcess, WTF::DestructionThread::Main>
    , public WebCore::NowPlayingManagerClient
    , public IPC::Connection::Client {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(GPUConnectionToWebProcess);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(GPUConnectionToWebProcess);
public:
    static Ref<GPUConnectionToWebProcess> create(GPUProcess&, WebCore::ProcessIdentifier, PAL::SessionID, IPC::Connection::Handle&&, GPUProcessConnectionParameters&&);
    virtual ~GPUConnectionToWebProcess();

    // IPC::Connection::Client, WebCore::NowPlayingManagerClient.
    void ref() const final { ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::ref(); }
    void deref() const final { ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::deref(); }
    using ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::controlBlock;

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const { return m_sharedPreferencesForWebProcess; }
    const SharedPreferencesForWebProcess& sharedPreferencesForWebProcessValue() const LIFETIME_BOUND { return m_sharedPreferencesForWebProcess; }
    void updateSharedPreferencesForWebProcess(SharedPreferencesForWebProcess);

#if ENABLE(WEBXR)
    bool isWebXREnabled() const { return m_sharedPreferencesForWebProcess.webXREnabled; }
#else
    bool isWebXREnabled() const { return false; }
#endif

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    bool isDynamicContentScalingEnabled() const { return m_sharedPreferencesForWebProcess.useCGDisplayListsForDOMRendering; }
#endif

    USING_CAN_MAKE_WEAKPTR(WebCore::NowPlayingManagerClient);

    IPC::Connection& connection() { return m_connection.get(); }
#if PLATFORM(GTK) || PLATFORM(WPE)
    void close() { didClose(connection()); }
#endif
    IPC::MessageReceiverMap& messageReceiverMap() LIFETIME_BOUND { return m_messageReceiverMap; }
    GPUProcess& gpuProcess() { return m_gpuProcess.get(); }
    WebCore::ProcessIdentifier webProcessIdentifier() const { return m_webProcessIdentifier; }

    // The Now Playing candidate states of the connection's pages and the election are Swift's
    // (GPUConnectionToWebProcess.swift, GPUProcess.swift). For them: the Now Playing info of one page, or of all of them,
    // goes; the NowPlayingManager's client becomes this connection, for the page that owns Now Playing or for the remote
    // commands only, or stops being it.
    SWIFT_MAIN_ACTOR void clearNowPlayingInfo(bool forAllPages, uint64_t pageIdentifier);
    SWIFT_MAIN_ACTOR void becomeNowPlayingOwner(uint64_t pageIdentifier);
    SWIFT_MAIN_ACTOR void becomeRemoteCommandFallbackTarget();
    SWIFT_MAIN_ACTOR void resignNowPlayingManagerClient();

    // Implemented in Swift: the GPU process added this connection, or removed it.
    SWIFT_MAIN_ACTOR void swiftDidAddToGPUProcess();
    SWIFT_MAIN_ACTOR void swiftDidRemoveFromGPUProcess();
    // Implemented in Swift: whether the page owns Now Playing; the session that gets the remote commands, 0 for none;
    // this connection's process closed while its connection was the NowPlayingManager's client.
#if !ENABLE(GPU_PROCESS_CORE_SWIFT)
    SWIFT_MAIN_ACTOR bool swiftIsActiveNowPlayingPage(uint64_t pageIdentifier) const;
#endif
    SWIFT_MAIN_ACTOR uint64_t swiftRemoteCommandTargetSession() const;
#if !ENABLE(GPU_PROCESS_CORE_SWIFT)
    SWIFT_MAIN_ACTOR RemoteCommandListenerState swiftRemoteCommandListenerState() const;
#endif
    SWIFT_MAIN_ACTOR void swiftNowPlayingClientDidClose();

    // For IPC::registerSwiftReceiver(): routes the web process's messages for the receiver name and destination, 0 for
    // all of them, to the receiver until removeSwiftReceiver(). The connection's Swift state registers the receivers it owns.
    bool addSwiftReceiver(IPC::ReceiverName, uint64_t identifier, IPC::MessageReceiver&);
    void removeSwiftReceiver(IPC::ReceiverName, uint64_t identifier);

    // For the Swift receivers.
    SWIFT_MAIN_ACTOR void tryExitIfUnusedAndUnderMemoryPressure();
#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
    // Asks the web process to reset the track renderer unit, whose timeline jumped.
    void resetAudioMediaStreamTrackRendererInternalUnit(uint64_t identifier);
    static bool isAudioSessionInterrupted();
#endif
#if ENABLE(WEB_AUDIO) && PLATFORM(IOS_FAMILY)
    void audioDestinationWasDeleted(uint64_t destinationIdentifier);
#endif
#if PLATFORM(IOS_FAMILY)
    static void setMonitorsWirelessRoutes(bool);
#endif

    Ref<RemoteSharedResourceCache> sharedResourceCache();

#if ENABLE(VIDEO) && PLATFORM(COCOA)
    RemoteAudioVideoRendererProxyManager& remoteAudioVideoRendererProxyManager();
#endif
#if ENABLE(VIDEO)
    void canDecodeExtendedType(WebCore::PlatformMediaDecodingType, WebCore::ContentType, CompletionHandler<void(bool)>&&) const;
#endif

    PAL::SessionID sessionID() const { return m_sessionID; }

    bool isLockdownModeEnabled() const { return m_isLockdownModeEnabled; }
    bool isLockdownSafeFontParserEnabled() const { return sharedPreferencesForWebProcess() && sharedPreferencesForWebProcess()->lockdownFontParserEnabled; }
    bool isForceLockdownSafeFontParserEnabled() const { return sharedPreferencesForWebProcess() && sharedPreferencesForWebProcess()->forceLockdownFontParserEnabled; }

    Logger& logger();

    String mediaCacheDirectory() const;
#if ENABLE(LEGACY_ENCRYPTED_MEDIA) || ENABLE(ENCRYPTED_MEDIA)
    String mediaKeysStorageDirectory() const;
#endif

#if ENABLE(MEDIA_STREAM)
    void reapplyCaptureEnvironment(WebCore::PageIdentifier);
    void updateCaptureOrigin(const WebCore::SecurityOriginData&);
    NODELETE bool setCaptureAttributionString();
    // For the Swift capture access (GPUProcess.swift): a web process that will use echo cancellation can capture audio.
    static void prewarmEchoCancellingAudioCapture();
#endif
#if ENABLE(VIDEO)
    NODELETE RemoteVideoFrameObjectHeap& videoFrameObjectHeap() const;
#endif
#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
    SWIFT_MAIN_ACTOR void startCapturingAudio();
#if !ENABLE(GPU_PROCESS_CORE_SWIFT)
    void processIsStartingToCaptureAudio(GPUConnectionToWebProcess&);
#endif
#endif

    const WebCore::ProcessIdentity& webProcessIdentity() const LIFETIME_BOUND { return m_webProcessIdentity; }
#if ENABLE(GPU_PROCESS_CDM_SWIFT)
    String cdmMediaKeysStorageDirectory() const { return mediaKeysStorageDirectory(); }
    // Implemented in Swift: whether the identifier is a CDM instance's at all, since the Swift ClearKey instances have no
    // C++ instance.
    SWIFT_MAIN_ACTOR bool hasCDMInstance(uint64_t identifier) const;
    // Implemented in Swift: the C++ instance of a CDM instance, for the media players.
    SWIFT_MAIN_ACTOR RefPtrCDMInstance cdmInstance(uint64_t identifier) const;
#endif
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    // Implemented in Swift: a legacy CDM session, for the media players.
    SWIFT_MAIN_ACTOR RefPtrRemoteLegacyCDMSessionClient legacyCDMSession(uint64_t identifier) const;
#endif
#if !ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    RemoteMediaEngineConfigurationFactoryProxy& mediaEngineConfigurationFactoryProxy();
#endif
#if ENABLE(VIDEO)
    RemoteMediaPlayerManagerProxy& remoteMediaPlayerManagerProxy() { return m_remoteMediaPlayerManagerProxy.get(); }
#endif
#if ENABLE(LINEAR_MEDIA_PLAYER)
    VideoReceiverEndpointManager& videoReceiverEndpointManager();
#endif

    SWIFT_MAIN_ACTOR void updateSupportedRemoteCommands();

    SWIFT_MAIN_ACTOR bool allowsExitUnderMemoryPressure() const;
    SWIFT_MAIN_ACTOR void terminateWebProcess(IPC::MessageName);
    // For the owners of stream receivers: logs a message they find invalid and terminates the web process.
    Function<void(IPC::MessageName)> terminateWebProcessOnInvalidMessage();

    void lowMemoryHandler(WTF::Critical, WTF::Synchronous);

#if ENABLE(WEBGL)
    SWIFT_MAIN_ACTOR void releaseGraphicsContextGLForTesting(RemoteGraphicsContextGLIdentifier);
#endif

    static uint64_t objectCountForTesting() { return gObjectCountForTesting; }

    // Implemented in Swift: the number of rendering backends the connection's Swift state holds.
    SWIFT_MAIN_ACTOR size_t swiftRenderingBackendCount();

#if HAVE(AUDIT_TOKEN)
    const HashMap<WebCore::PageIdentifier, CoreIPCAuditToken>& presentingApplicationAuditTokens() const LIFETIME_BOUND { return m_presentingApplicationAuditTokens; }
    std::optional<audit_token_t> presentingApplicationAuditToken(WebCore::PageIdentifier) const;
    ProcessID presentingApplicationPID(WebCore::PageIdentifier) const;
    void setPresentingApplicationAuditToken(WebCore::PageIdentifier, std::optional<CoreIPCAuditToken>);
#endif
#if PLATFORM(COCOA)
    const String& applicationBundleIdentifier() const LIFETIME_BOUND { return m_applicationBundleIdentifier; }
#endif

#if ENABLE(VIDEO)
    void performWithMediaPlayerOnMainThread(WebCore::MediaPlayerIdentifier, Function<void(WebCore::MediaPlayer&)>&&);
#endif

#if ENABLE(EXTENSION_CAPABILITIES)
    SWIFT_MAIN_ACTOR String mediaPlaybackEnvironment(WebCore::PageIdentifier);
    SWIFT_MAIN_ACTOR void setMediaPlaybackEnvironment(WebCore::PageIdentifier, String);
    SWIFT_MAIN_ACTOR String displayCaptureEnvironment(WebCore::PageIdentifier);
    SWIFT_MAIN_ACTOR void setDisplayCaptureEnvironment(WebCore::PageIdentifier, String);
#endif

#if ENABLE(IPC_TESTING_API)
    void takeInvalidMessageStringForTesting(CompletionHandler<void(String&&)>&&);
#endif

    bool isAlwaysOnLoggingAllowed() const { return m_sessionID.isAlwaysOnLoggingAllowed() || m_sharedPreferencesForWebProcess.allowPrivacySensitiveOperationsInNonPersistentDataStores; }

#if USE(AUDIO_SESSION) && PLATFORM(IOS_FAMILY)
    // Implemented in Swift.
    SWIFT_MAIN_ACTOR void setAudioSessionPreferredSpeakerID(const String&);
#endif
#if ENABLE(ROUTING_ARBITRATION) && HAVE(AVAUDIO_ROUTING_ARBITER)
    // Implemented in Swift: the shared audio session's routing arbitration goes to this connection's web process, until
    // the process terminates.
    SWIFT_MAIN_ACTOR void swiftEnableRoutingArbitration();
    SWIFT_MAIN_ACTOR void swiftRoutingArbitrationProcessDidTerminate();
#endif

#if PLATFORM(IOS_FAMILY)
    void providePresentingApplicationPID(WebCore::PageIdentifier) const;
#endif

private:
    GPUConnectionToWebProcess(GPUProcess&, WebCore::ProcessIdentifier, PAL::SessionID, IPC::Connection::Handle&&, GPUProcessConnectionParameters&&);

    // Implemented in Swift.
    uintptr_t createSwiftState(uint64_t webProcessIdentifier, bool isLockdownModeEnabled);
    // Unsafe: the state must be the one createSwiftState() made, which only the destructor releases.
    SWIFT_UNSAFE static void destroySwiftState(uintptr_t);
    // m_swiftState, for Swift, which can only read it.
    uintptr_t swiftState() const { return m_swiftState; }

    // Implemented in Swift: the Swift state holds the rendering backends and the owners of the WebGL and WebGPU receivers until
    // they are released or the connection closes, and stops them then.
    SWIFT_MAIN_ACTOR bool swiftHasRenderingBackend(uint64_t identifier);
    // Before the backend starts listening for IPC.
#if PLATFORM(COCOA) && ENABLE(VIDEO)
    SWIFT_MAIN_ACTOR void swiftAddRenderingBackend(uint64_t identifier, RemoteRenderingBackend&, RemoteVideoFrameObjectHeap&, WebCore::ProcessIdentity webProcessIdentity, bool hasWebProcessIdentity);
#else
    SWIFT_MAIN_ACTOR void swiftAddRenderingBackend(uint64_t identifier, RemoteRenderingBackend&);
#endif
#if !ENABLE(GPU_PROCESS_CORE_SWIFT)
    // Whether the state had it.
    SWIFT_MAIN_ACTOR bool swiftReleaseRenderingBackend(uint64_t identifier);
#endif
#if ENABLE(WEBGL)
    SWIFT_MAIN_ACTOR void swiftAddGraphicsContextGL(uint64_t identifier, uint64_t renderingBackendIdentifier, IPC::SwiftReceiverOwner&, WebCore::GraphicsContextGLAttributes);
#if !ENABLE(GPU_PROCESS_CORE_SWIFT)
    SWIFT_MAIN_ACTOR bool swiftHasGraphicsContextGL(uint64_t identifier);
    // Whether none is left.
    SWIFT_MAIN_ACTOR bool swiftReleaseGraphicsContextGL(uint64_t identifier);
#endif
#if !PLATFORM(COCOA)
    void createGraphicsContextGLResources(WebCore::GraphicsContextGLAttributes, uint64_t identifier, RemoteRenderingBackend&, IPC::SwiftReceiverOwner&);
#endif
#endif
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
#if PLATFORM(COCOA) && ENABLE(VIDEO)
    SWIFT_MAIN_ACTOR void swiftAddGPU(uint64_t identifier, uint64_t renderingBackendIdentifier, IPC::SwiftReceiverOwner&, MachSendRight webProcessResourceOwner, RemoteVideoFrameObjectHeap&, WebCore::ProcessIdentity webProcessIdentity, bool hasWebProcessIdentity);
#else
    SWIFT_MAIN_ACTOR void swiftAddGPU(uint64_t identifier, uint64_t renderingBackendIdentifier, IPC::SwiftReceiverOwner&, MachSendRight webProcessResourceOwner);
#endif
#if !ENABLE(GPU_PROCESS_CORE_SWIFT)
    SWIFT_MAIN_ACTOR bool swiftHasGPU(uint64_t identifier);
    // Whether none is left.
    SWIFT_MAIN_ACTOR bool swiftReleaseGPU(uint64_t identifier);
#endif
#if ENABLE(GPU_PROCESS_MODEL)
    void createGPUModel(RemoteRenderingBackend&, IPC::SwiftReceiverOwner&, uint64_t identifier);
#endif
#endif
    SWIFT_MAIN_ACTOR void swiftCloseStreamReceivers();
#if ENABLE(GPU_PROCESS_CORE_SWIFT)
    RefPtr<IPC::StreamServerConnection> tryCreateStreamConnection(IPC::StreamServerConnection::Handle&&);
    // Implemented in Swift: whether to make the receiver, after the checks of the message, which mark it invalid if they
    // fail.
#if ENABLE(WEBGL)
    SWIFT_MAIN_ACTOR bool swiftShouldCreateGraphicsContextGL(uint64_t identifier, bool supportsDraftExtensions, uint64_t renderingBackendIdentifier);
#endif
#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    SWIFT_MAIN_ACTOR bool swiftShouldCreateGPU(uint64_t identifier, uint64_t renderingBackendIdentifier);
#endif
#endif

#if PLATFORM(COCOA) && USE(LIBWEBRTC)
    // Implemented in Swift: the Swift state makes and keeps the receiver of the video decoder and encoder messages, whose
    // forwarder this registers on the codecs queue, the dispatch queue that codecsQueue is.
    SWIFT_MAIN_ACTOR Ref<LibWebRTCCodecsProxyMessageForwarder> swiftCreateLibWebRTCCodecsProxy(RemoteVideoFrameObjectHeap&, WebCore::ProcessIdentity resourceOwner, bool hasResourceOwner, void* WTF_NONNULL codecsQueue);
    void stopLibWebRTCCodecsProxy();
#endif

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
    // Implemented in Swift (RemoteSampleBufferDisplayLayerManager.swift): the Swift state makes and keeps the receiver of
    // the sample buffer display layer messages, whose forwarders this registers on the layers' queue, the dispatch queue that
    // queue is, and updates a layer's bounds.
    SWIFT_MAIN_ACTOR Ref<RemoteSampleBufferDisplayLayerManagerMessageForwarder> swiftCreateSampleBufferDisplayLayerManager(RemoteVideoFrameObjectHeap&, WebCore::ProcessIdentity webProcessIdentity, bool hasWebProcessIdentity, void* WTF_NONNULL queue);
    SWIFT_MAIN_ACTOR Ref<RemoteSampleBufferDisplayLayerMessageForwarder> swiftSampleBufferDisplayLayerForwarder();
    SWIFT_MAIN_ACTOR void swiftUpdateSampleBufferDisplayLayerBoundsAndPosition(uint64_t identifier, CGRect bounds, OptionalMachSendRightAnnotated fence);
#endif

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
    // Implemented in Swift (UserMediaCaptureManagerProxy.swift): the capture receiver's sources stop, and reapply the
    // page's capture environment.
    SWIFT_MAIN_ACTOR void swiftCloseUserMediaCaptureManager();
    SWIFT_MAIN_ACTOR void swiftReapplyCaptureEnvironment(uint64_t pageIdentifier);

    // Implemented in Swift: for the track renderer units, whether this connection's process is the one that most recently
    // started capturing audio, and the audio session's interruptions.
#if !ENABLE(GPU_PROCESS_CORE_SWIFT)
    SWIFT_MAIN_ACTOR void swiftLastToCaptureAudioChanged(bool isLastToCaptureAudio);
#endif
#if !ENABLE(GPU_PROCESS_CORE_SWIFT)
    SWIFT_MAIN_ACTOR void swiftBeginAudioSessionInterruption();
    SWIFT_MAIN_ACTOR void swiftEndAudioSessionInterruption();
#endif

    void setLastAudioMediaStreamTrackRendererDeviceUsed(const String& deviceID);
#endif

#if ENABLE(WEB_AUDIO) && PLATFORM(IOS_FAMILY)
    // Implemented in Swift.
    SWIFT_MAIN_ACTOR RemoteAudioDestinationSpatialTarget swiftAudioDestinationSpatialTarget(uint64_t destinationIdentifier);

    void setAudioDestinationSceneIdentifier(RemoteAudioDestinationIdentifier, String&& sceneIdentifier);
#endif

    void createRenderingBackend(RemoteRenderingBackendIdentifier, IPC::StreamServerConnection::Handle&&);
    SWIFT_MAIN_ACTOR void releaseRenderingBackend(RemoteRenderingBackendIdentifier);

#if ENABLE(WEBGL)
    void createGraphicsContextGL(RemoteGraphicsContextGLIdentifier, WebCore::GraphicsContextGLAttributes, RemoteRenderingBackendIdentifier, IPC::StreamServerConnection::Handle&&);
    SWIFT_MAIN_ACTOR void releaseGraphicsContextGL(RemoteGraphicsContextGLIdentifier);
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
    void createGPU(WebGPUIdentifier, RemoteRenderingBackendIdentifier, IPC::StreamServerConnection::Handle&&);
    SWIFT_MAIN_ACTOR void releaseGPU(WebGPUIdentifier);
#endif

    void setNowPlayingInfoForPage(WebCore::NowPlayingInfo&&, std::optional<WebCore::PageIdentifier>);
    SWIFT_MAIN_ACTOR void abandonSnapshotFrame(RemoteSnapshotIdentifier, WebCore::FrameIdentifier);
    SWIFT_MAIN_ACTOR void failSnapshot(RemoteSnapshotIdentifier);
    SWIFT_MAIN_ACTOR void nowPlayingClientDidClose();
#if ENABLE(GPU_PROCESS_CORE_SWIFT)
    // Implemented in Swift, which keeps the pages' Now Playing info, and for it: the parts of the info that Swift can't
    // reach, and the NowPlayingManager's client and info.
    SWIFT_MAIN_ACTOR void swiftSetNowPlayingInfo(WebCore::NowPlayingInfo, uint64_t pageIdentifier);
    static void reuseNowPlayingArtworkImage(WebCore::NowPlayingInfo&, const WebCore::NowPlayingInfo& previousInfo);
    void setIsNowPlayingManagerClient(bool);
    void setNowPlayingManagerInfo(const WebCore::NowPlayingInfo&);
    // The commands are a mask of 1 << command type.
    void setNowPlayingManagerRemoteCommands(uint32_t commands, bool supportsSeeking);
#endif
    void postNowPlayingRemoteControlCommandForTesting(WebCore::PlatformMediaSessionRemoteControlCommandType, const WebCore::PlatformMediaSessionRemoteCommandArgument&);
#if PLATFORM(COCOA) && ENABLE(VIDEO)
    void hostedVideoLayerBoundsForTesting(WebCore::MediaPlayerClientIdentifier, CompletionHandler<void(std::optional<WebCore::FloatRect>)>&&);
#endif

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
    void updateSampleBufferDisplayLayerBoundsAndPosition(WebKit::SampleBufferDisplayLayerIdentifier, WebCore::FloatRect, std::optional<WTF::MachSendRightAnnotated>&&);
#endif

#if HAVE(VISIBILITY_PROPAGATION_VIEW)
    void createVisibilityPropagationContextForPage(WebPageProxyIdentifier, WebCore::PageIdentifier, bool canShowWhileLocked);
    void destroyVisibilityPropagationContextForPage(WebPageProxyIdentifier, WebCore::PageIdentifier);
#endif


#if PLATFORM(IOS_FAMILY)
    void ensureMediaSessionHelper();
#endif

    // Implemented in Swift with GPU_PROCESS_MEDIA_SWIFT.
    SWIFT_MAIN_ACTOR void createAudioHardwareListener(RemoteAudioHardwareListenerIdentifier);
    SWIFT_MAIN_ACTOR void releaseAudioHardwareListener(RemoteAudioHardwareListenerIdentifier);
    SWIFT_MAIN_ACTOR void releaseTransferredImageBuffer(WebCore::ImageBufferTransferIdentifier);
    void setMediaOverridesForTesting(MediaOverridesForTesting);
    SWIFT_MAIN_ACTOR void configureLoggingChannel(String, WTFLogChannelState, WTFLogLevel);

#if USE(GRAPHICS_LAYER_WC)
    void createWCLayerTreeHost(WebKit::WCLayerTreeHostIdentifier, uint64_t nativeWindow, bool usesOffscreenRendering);
    void releaseWCLayerTreeHost(WebKit::WCLayerTreeHostIdentifier);
#endif

    // IPC::Connection::Client
    void didClose(IPC::Connection&) final;
    void didReceiveInvalidMessage(IPC::Connection&, IPC::MessageName, const Vector<uint32_t>& indicesOfObjectsFailingDecoding) final;
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;

    bool dispatchMessage(IPC::Connection&, IPC::Decoder&);
    bool dispatchSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&);
#if ENABLE(GPU_PROCESS_CORE_SWIFT)
    // Implemented in Swift: whether the messages to the receiver name, which nothing is registered for in the receiver map,
    // are dropped rather than invalid.
    SWIFT_MAIN_ACTOR bool swiftRoutesUnregisteredReceiver(IPC::ReceiverName);
#endif

    // NowPlayingManagerClient
    void didReceiveRemoteControlCommand(WebCore::PlatformMediaSession::RemoteControlCommandType, const WebCore::PlatformMediaSession::RemoteCommandArgument&) final;

    void enableMediaPlaybackIfNecessary();

    static uint64_t gObjectCountForTesting;

    const RefPtr<Logger> m_logger;

    const Ref<IPC::Connection> m_connection;
    IPC::MessageReceiverMap m_messageReceiverMap;
    const Ref<GPUProcess> m_gpuProcess;
    const WebCore::ProcessIdentifier m_webProcessIdentifier;
    const WebCore::ProcessIdentity m_webProcessIdentity;
#if ENABLE(WEB_AUDIO) && PLATFORM(IOS_FAMILY)
    HashMap<uint64_t, String> m_audioDestinationSceneIdentifiers;
#endif
    const RefPtr<RemoteSharedResourceCache> m_sharedResourceCache;
#if ENABLE(VIDEO) && PLATFORM(COCOA)
    const RefPtr<RemoteAudioVideoRendererProxyManager> m_remoteAudioVideoRendererProxyManager;
#endif
#if ENABLE(VIDEO)
    const Ref<RemoteMediaPlayerManagerProxy> m_remoteMediaPlayerManagerProxy;
#endif
#if ENABLE(LINEAR_MEDIA_PLAYER)
    const LazyUniqueRef<GPUConnectionToWebProcess, VideoReceiverEndpointManager> m_videoReceiverEndpointManager;
#endif
    PAL::SessionID m_sessionID;
#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)
#if !ENABLE(GPU_PROCESS_CORE_SWIFT)
    class AudioSessionInterruptionForwarder;
    const RefPtr<AudioSessionInterruptionForwarder> m_audioSessionInterruptionForwarder;
#endif

    RefPtr<RemoteSampleBufferDisplayLayerManagerMessageForwarder> m_sampleBufferDisplayLayerManager;
    RefPtr<RemoteSampleBufferDisplayLayerMessageForwarder> m_sampleBufferDisplayLayers;
#endif

#if ENABLE(MEDIA_STREAM)
    Ref<WebCore::SecurityOrigin> m_captureOrigin;
#endif
#if ENABLE(VIDEO)
    IPC::ScopedActiveMessageReceiveQueue<RemoteVideoFrameObjectHeap> m_videoFrameObjectHeap;
#endif
#if PLATFORM(COCOA) && USE(LIBWEBRTC)
    RefPtr<LibWebRTCCodecsProxyMessageForwarder> m_libWebRTCCodecsProxy;
#endif
#if HAVE(AUDIT_TOKEN)
    HashMap<WebCore::PageIdentifier, CoreIPCAuditToken> m_presentingApplicationAuditTokens;
#endif
#if PLATFORM(COCOA)
    const String m_applicationBundleIdentifier;
#endif

#if PLATFORM(IOS_FAMILY)
    const RefPtr<RemoteMediaSessionHelperProxy> m_mediaSessionHelperProxy;
#endif
#if !ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    const std::unique_ptr<RemoteMediaEngineConfigurationFactoryProxy> m_mediaEngineConfigurationFactoryProxy;
#endif

#if HAVE(VISIBILITY_PROPAGATION_VIEW)
    HashMap<std::pair<WebPageProxyIdentifier, WebCore::PageIdentifier>, std::unique_ptr<LayerHostingContext>> m_visibilityPropagationContexts;
#endif

#if !ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    using RemoteAudioHardwareListenerMap = HashMap<RemoteAudioHardwareListenerIdentifier, Ref<RemoteAudioHardwareListenerProxy>>;
    RemoteAudioHardwareListenerMap m_remoteAudioHardwareListenerMap;
#endif

#if USE(GRAPHICS_LAYER_WC)
    using RemoteWCLayerTreeHostMap = HashMap<WCLayerTreeHostIdentifier, Ref<RemoteWCLayerTreeHost>>;
    RemoteWCLayerTreeHostMap m_remoteWCLayerTreeHostMap;
#endif

#if !ENABLE(GPU_PROCESS_CORE_SWIFT)
    HashMap<WebCore::PageIdentifier, WebCore::NowPlayingInfo> m_nowPlayingInfos;
#endif
    bool m_isNowPlayingManagerClient { false };
    const bool m_isLockdownModeEnabled { false };

#if ENABLE(EXTENSION_CAPABILITIES) && !ENABLE(GPU_PROCESS_CORE_SWIFT)
    HashMap<WebCore::PageIdentifier, String> m_mediaPlaybackEnvironments;
    HashMap<WebCore::PageIdentifier, String> m_displayCaptureEnvironments;
#endif

#if ENABLE(IPC_TESTING_API)
    const Ref<IPCTester> m_ipcTester;
#endif
    SharedPreferencesForWebProcess m_sharedPreferencesForWebProcess;
    // A retained reference to the Swift state, as an address, from the constructor to the destructor.
    uintptr_t m_swiftState __attribute__((availability(swift, unavailable))) { 0 };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)
