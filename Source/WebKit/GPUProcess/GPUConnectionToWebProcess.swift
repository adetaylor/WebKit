// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_GPU_PROCESS

#if USE_LIBWEBRTC && WTF_PLATFORM_COCOA
import Dispatch
#endif
import WebKit_Internal

// A receiver of a web process's messages that the connection's Swift state owns and routes the messages to while the
// connection is in the GPU process.
protocol GPUConnectionReceiver: AnyObject {
    // Whether the GPU process may exit under memory pressure as far as this receiver is concerned.
    @MainActor
    var allowsExitUnderMemoryPressure: Bool { get }
    // The connection has closed and its messages no longer reach this receiver.
    @MainActor
    func connectionDidClose()
}

// The Swift state of a web process's connection to the GPU process (GPUConnectionToWebProcess.h), which
// GPUConnectionToWebProcess::m_swiftState holds.
@MainActor
final class GPUConnectionState {
    let processIdentifier: UInt64
    let isLockdownModeEnabled: Bool
    // The Now Playing candidate states of the connection's pages, by page identifier, which the election reads.
    var nowPlayingCandidates: [UInt64: IPCTypes.NowPlayingCandidateState] = [:]
    // The web process's remote command listener, while it has one, which the NowPlayingManager's commands come from.
    private(set) var remoteCommandListener: RemoteCommandListener?
    #if WTF_PLATFORM_IOS_FAMILY
    // Whether the web process has MediaSessionHelper monitor wireless routes.
    private(set) var isMonitoringWirelessRoutes = false
    #endif
    #if ENABLE_MEDIA_STREAM
    // What the UI process allowed the web process to capture.
    private(set) var captureAccess = CaptureAccess()
    #if WTF_PLATFORM_COCOA
    // The state of the connection's capture receiver, while it has one.
    weak var captureManager: UserMediaCaptureManagerProxyState?
    #endif
    #endif

    // Declared before the receivers, so that their messages stop before the receivers go.
    private var registrations: [IPC.SwiftReceiverRegistration] = []
    // The receivers the state owns, from when the connection is added to the GPU process; their registrations route their
    // messages to them until the connection is removed from it.
    #if ENABLE_WEB_AUDIO && WTF_PLATFORM_COCOA
    private(set) var audioDestinationManager: RemoteAudioDestinationManager?
    #endif
    #if ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
    private(set) var audioMediaStreamTrackRendererInternalUnitManager: RemoteAudioMediaStreamTrackRendererInternalUnitManager?
    #endif
    #if ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
    private(set) var cdmFactory: RemoteCDMFactoryProxy?
    #endif
    #if USE_LIBWEBRTC && WTF_PLATFORM_COCOA
    // From before the connection opens: the C++ connection registers its forwarder on the codecs queue.
    fileprivate var libWebRTCCodecsProxy: LibWebRTCCodecsProxy?
    #endif

    // The receivers with stream connections of their own, by identifier, from when they are added until they are released
    // or the connection closes; the state stops their messages then.
    fileprivate var renderingBackends: [UInt64: WebKit.RemoteRenderingBackend] = [:]
    #if ENABLE_WEBGL
    fileprivate var graphicsContextGLOwners: [UInt64: IPC.SwiftReceiverOwner] = [:]
    #endif
    #if ENABLE_GPU_PROCESS_WEBGPU_SWIFT
    fileprivate var gpuOwners: [UInt64: IPC.SwiftReceiverOwner] = [:]
    #endif

    fileprivate nonisolated init(processIdentifier: UInt64, isLockdownModeEnabled: Bool) {
        self.processIdentifier = processIdentifier
        self.isLockdownModeEnabled = isLockdownModeEnabled
    }

    var receivers: [any GPUConnectionReceiver] {
        var receivers: [any GPUConnectionReceiver] = []
        #if ENABLE_WEB_AUDIO && WTF_PLATFORM_COCOA
        if let audioDestinationManager {
            receivers.append(audioDestinationManager)
        }
        #endif
        #if ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
        if let audioMediaStreamTrackRendererInternalUnitManager {
            receivers.append(audioMediaStreamTrackRendererInternalUnitManager)
        }
        #endif
        #if ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
        if let cdmFactory {
            receivers.append(cdmFactory)
        }
        #endif
        #if USE_LIBWEBRTC && WTF_PLATFORM_COCOA
        if let libWebRTCCodecsProxy {
            receivers.append(libWebRTCCodecsProxy)
        }
        #endif
        return receivers
    }

    fileprivate func createReceivers(for connection: WebKit.GPUConnectionToWebProcess) {
        #if ENABLE_WEB_AUDIO && WTF_PLATFORM_COCOA
        let audioDestinationManager = RemoteAudioDestinationManager(connection: connection, isLockdownModeEnabled: isLockdownModeEnabled)
        self.audioDestinationManager = audioDestinationManager
        register(IPC.registerSwiftReceiver(connection, audioDestinationManager.getMessageReceiver(), .RemoteAudioDestinationManager, 0))
        #endif
        #if ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
        let audioMediaStreamTrackRendererInternalUnitManager = RemoteAudioMediaStreamTrackRendererInternalUnitManager(
            connection: connection
        )
        self.audioMediaStreamTrackRendererInternalUnitManager = audioMediaStreamTrackRendererInternalUnitManager
        register(
            IPC.registerSwiftReceiver(
                connection,
                audioMediaStreamTrackRendererInternalUnitManager.getMessageReceiver(),
                .RemoteAudioMediaStreamTrackRendererInternalUnitManager,
                0
            )
        )
        #endif
        #if ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
        let cdmFactory = RemoteCDMFactoryProxy(connection: connection)
        self.cdmFactory = cdmFactory
        register(IPC.registerSwiftReceiver(connection, cdmFactory.getMessageReceiver(), .RemoteCDMFactoryProxy, 0))
        #endif
    }

    private func register(_ registration: IPC.SwiftReceiverRegistration?) {
        guard let registration else {
            preconditionFailure("The connection that adds its receivers has gone")
        }
        registrations.append(registration)
    }

    // The receivers' messages stop before they hear the connection has closed.
    fileprivate func connectionDidClose() {
        registrations.removeAll()
        for receiver in receivers {
            receiver.connectionDidClose()
        }
    }

    var allowsExitUnderMemoryPressure: Bool {
        receivers.allSatisfy { $0.allowsExitUnderMemoryPressure }
    }

    func createRemoteCommandListener(_ identifier: IPCTypes.RemoteRemoteCommandListenerIdentifier) {
        remoteCommandListener = RemoteCommandListener(identifier: identifier)
    }

    func releaseRemoteCommandListener(_ identifier: IPCTypes.RemoteRemoteCommandListenerIdentifier) {
        if remoteCommandListener?.identifier == identifier {
            remoteCommandListener = nil
        }
    }

    // Whether the connection has a listener, whose commands these become.
    func setSupportedRemoteCommands(_ commands: [IPCTypes.PlatformMediaSessionRemoteControlCommandType], supportsSeeking: Bool) -> Bool {
        guard remoteCommandListener != nil else {
            return false
        }
        remoteCommandListener?.commands = Set(commands)
        remoteCommandListener?.supportsSeeking = supportsSeeking
        return true
    }

    #if WTF_PLATFORM_IOS_FAMILY
    func setMonitorsWirelessRoutes(_ monitors: Bool) {
        guard monitors != isMonitoringWirelessRoutes else {
            return
        }
        isMonitoringWirelessRoutes = monitors
        WebKit.GPUConnectionToWebProcess.setMonitorsWirelessRoutes(monitors)
    }
    #endif

    #if ENABLE_MEDIA_STREAM
    func allowCapture(_ access: CaptureAccess, willUseEchoCancellation: Bool) {
        if willUseEchoCancellation {
            assert(access.audio)
            WebKit.GPUConnectionToWebProcess.prewarmEchoCancellingAudioCapture()
        }
        captureAccess.formUnion(access)
    }
    #endif

    fileprivate func releaseRenderingBackend(_ identifier: UInt64) -> Bool {
        guard let renderingBackend = renderingBackends.removeValue(forKey: identifier) else {
            return false
        }
        renderingBackend.stopListeningForIPC()
        return true
    }

    // The WebGPU receivers keep rendering backends, so they go first. The rendering backends keep the connection, so this also
    // breaks that cycle.
    fileprivate func closeStreamReceivers() {
        #if ENABLE_GPU_PROCESS_WEBGPU_SWIFT
        let gpuOwners = self.gpuOwners
        self.gpuOwners.removeAll()
        for owner in gpuOwners.values {
            owner.stopListeningForIPC()
        }
        #endif
        let renderingBackends = self.renderingBackends
        self.renderingBackends.removeAll()
        for renderingBackend in renderingBackends.values {
            renderingBackend.stopListeningForIPC()
        }
        #if ENABLE_WEBGL
        let graphicsContextGLOwners = self.graphicsContextGLOwners
        self.graphicsContextGLOwners.removeAll()
        for owner in graphicsContextGLOwners.values {
            owner.stopListeningForIPC()
        }
        #endif
    }

    fileprivate func invalidateReceivers() {
        #if ENABLE_WEB_AUDIO && WTF_PLATFORM_COCOA
        audioDestinationManager?.invalidate()
        #endif
        #if ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
        audioMediaStreamTrackRendererInternalUnitManager?.invalidate()
        #endif
        #if WTF_PLATFORM_IOS_FAMILY
        setMonitorsWirelessRoutes(false)
        #endif
    }
}

// A web process's remote command listener: the commands it supports.
struct RemoteCommandListener {
    let identifier: IPCTypes.RemoteRemoteCommandListenerIdentifier
    var commands: Set<IPCTypes.PlatformMediaSessionRemoteControlCommandType> = []
    var supportsSeeking = false
}

extension WebKit.GPUConnectionToWebProcess {
    @cxx
    @implementation
    func createSwiftState(_ webProcessIdentifier: UInt64, _ isLockdownModeEnabled: Bool) -> UInt {
        let state = GPUConnectionState(processIdentifier: webProcessIdentifier, isLockdownModeEnabled: isLockdownModeEnabled)
        return UInt(bitPattern: unsafe Unmanaged.passRetained(state).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        let state = unsafe Unmanaged<GPUConnectionState>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
        MainActor.assumeIsolated {
            // The receivers stop rendering here, on the main thread.
            state.invalidateReceivers()
            state.closeStreamReceivers()
        }
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The connection has no Swift state")
        }
        return unsafe address
    }

    var state: GPUConnectionState {
        // Safety: m_swiftState is a retained GPUConnectionState from the constructor to the destructor, and nothing else
        // changes it.
        unsafe Unmanaged<GPUConnectionState>.fromOpaque(Self.stateAddress(swiftState())).takeUnretainedValue()
    }

    #if USE_LIBWEBRTC && WTF_PLATFORM_COCOA
    @cxx
    @implementation
    @MainActor
    func swiftCreateLibWebRTCCodecsProxy(
        _ videoFrameObjectHeap: WebKit.RemoteVideoFrameObjectHeap,
        _ resourceOwner: WebCore.ProcessIdentity,
        _ hasResourceOwner: Bool,
        _ codecsQueue: UnsafeMutableRawPointer
    ) -> RefLibWebRTCCodecsProxyMessageForwarder {
        // Safety: the connection passes the dispatch queue of the GPU process's codecs WorkQueue, which keeps it for the
        // process's life, and this retains it.
        let queue = unsafe Unmanaged<DispatchQueue>.fromOpaque(codecsQueue).takeUnretainedValue()
        guard let codecsQueue = queue as? DispatchSerialQueue else {
            preconditionFailure("The codecs queue is not serial")
        }
        precondition(state.libWebRTCCodecsProxy == nil, "The connection has a codecs receiver")
        // Safety: the heap is used on any thread, which its own lock and its WorkQueue confine its state to.
        nonisolated(unsafe) let videoFrameObjectHeap = videoFrameObjectHeap
        let proxy = unsafe LibWebRTCCodecsProxy(
            videoFrameObjectHeap: videoFrameObjectHeap,
            resourceOwner: hasResourceOwner ? resourceOwner : nil,
            codecsQueue: codecsQueue
        )
        state.libWebRTCCodecsProxy = proxy
        return proxy.getMessageReceiver()
    }
    #endif
}

extension WebKit.GPUConnectionToWebProcess {
    @cxx
    @implementation
    @MainActor
    func swiftDidAddToGPUProcess() {
        webProcessConnections.add(self, process: state.processIdentifier)
        state.createReceivers(for: self)
        #if ENABLE_MEDIA_STREAM
        // FIXME: We should refactor code to go from WebProcess -> GPUProcess -> UIProcess when getUserMedia is called instead of going from WebProcess -> UIProcess directly.
        let pending = captureEnvironment.takePendingAccess(process: state.processIdentifier)
        state.allowCapture(pending.access, willUseEchoCancellation: pending.willUseEchoCancellation)
        #endif
    }

    @cxx
    @implementation
    @MainActor
    func swiftDidRemoveFromGPUProcess() {
        state.connectionDidClose()
        webProcessConnections.remove(self, process: state.processIdentifier)
        nowPlayingArbiter.recompute()
    }

    @cxx
    @implementation
    @MainActor
    func swiftIsActiveNowPlayingPage(_ pageIdentifier: UInt64) -> Bool {
        nowPlayingArbiter.isActive(process: state.processIdentifier, page: pageIdentifier)
    }

    @cxx
    @implementation
    @MainActor
    func swiftRemoteCommandTargetSession() -> UInt64 {
        nowPlayingArbiter.remoteCommandTargetSession(in: state.processIdentifier) ?? 0
    }

    @cxx
    @implementation
    @MainActor
    func swiftRemoteCommandListenerState() -> WebKit.RemoteCommandListenerState {
        var listenerState = WebKit.RemoteCommandListenerState()
        if let listener = state.remoteCommandListener {
            listenerState.hasListener = true
            listenerState.commands = listener.commands.reduce(0) { $0 | UInt32(1) << $1.rawValue }
            listenerState.supportsSeeking = listener.supportsSeeking
        }
        return listenerState
    }

    #if ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
    @cxx
    @implementation
    @MainActor
    func hasCDMInstance(_ identifier: UInt64) -> Bool {
        MainActor.preconditionIsolated()
        return state.cdmFactory?.hasInstance(identifier) ?? false
    }
    #endif

    @cxx
    @implementation
    @MainActor
    func swiftNowPlayingClientDidClose() {
        state.nowPlayingCandidates.removeAll()
        nowPlayingArbiter.clientDidClose(process: state.processIdentifier)
    }

    #if ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
    @cxx
    @implementation
    @MainActor
    func swiftLastToCaptureAudioChanged(_ isLastToCaptureAudio: Bool) {
        MainActor.preconditionIsolated()
        state.audioMediaStreamTrackRendererInternalUnitManager?.setIsLastToCaptureAudio(isLastToCaptureAudio)
    }

    @cxx
    @implementation
    @MainActor
    func swiftBeginAudioSessionInterruption() {
        MainActor.preconditionIsolated()
        state.audioMediaStreamTrackRendererInternalUnitManager?.beginAudioSessionInterruption()
    }

    @cxx
    @implementation
    @MainActor
    func swiftEndAudioSessionInterruption() {
        MainActor.preconditionIsolated()
        state.audioMediaStreamTrackRendererInternalUnitManager?.endAudioSessionInterruption()
    }
    #endif

    #if ENABLE_WEB_AUDIO && WTF_PLATFORM_IOS_FAMILY
    @cxx
    @implementation
    @MainActor
    func swiftAudioDestinationSpatialTarget(_ destinationIdentifier: UInt64) -> WebKit.RemoteAudioDestinationSpatialTarget {
        MainActor.preconditionIsolated()
        var target = WebKit.RemoteAudioDestinationSpatialTarget()
        if let destination = state.audioDestinationManager?.spatialTarget(destinationIdentifier) {
            target.outputUnitIdentifier = destination.outputUnitIdentifier
            target.prefersSpatialAudioExperience = destination.prefersSpatialAudioExperience
        }
        return target
    }
    #endif

    // The candidate state and the Now Playing info of the page, or of all of the connection's pages, go.
    @MainActor
    func clearNowPlayingCandidates(page: UInt64?) {
        if let page {
            state.nowPlayingCandidates[page] = nil
        } else {
            state.nowPlayingCandidates.removeAll()
        }
        clearNowPlayingInfo(page == nil, page ?? 0)
        nowPlayingArbiter.recompute()
    }

    @MainActor
    func clearNowPlayingInfoForPage(connection: IPC.Connection, pageIdentifier: IPCTypes.PageIdentifier?) {
        clearNowPlayingCandidates(page: pageIdentifier?.rawValue)
    }

    @MainActor
    func setNowPlayingCandidateState(connection: IPC.Connection, candidate: IPCTypes.NowPlayingCandidateState) {
        guard let page = candidate.pageIdentifier else {
            return
        }
        state.nowPlayingCandidates[page.rawValue] = candidate
        nowPlayingArbiter.recompute()
    }

    @MainActor
    func isActiveNowPlayingSessionForTesting(connection: IPC.Connection, identifier: IPCTypes.MediaSessionIdentifier) -> Bool {
        nowPlayingArbiter.isActive(process: state.processIdentifier, session: identifier.rawValue)
    }

    @MainActor
    func createRemoteCommandListener(connection: IPC.Connection, identifier: IPCTypes.RemoteRemoteCommandListenerIdentifier) {
        state.createRemoteCommandListener(identifier)
    }

    @MainActor
    func releaseRemoteCommandListener(connection: IPC.Connection, identifier: IPCTypes.RemoteRemoteCommandListenerIdentifier) {
        state.releaseRemoteCommandListener(identifier)
    }

    @MainActor
    func setSupportedRemoteCommands(
        connection: IPC.Connection,
        commands: [IPCTypes.PlatformMediaSessionRemoteControlCommandType],
        supportsSeeking: Bool
    ) {
        if state.setSupportedRemoteCommands(commands, supportsSeeking: supportsSeeking) {
            updateSupportedRemoteCommands()
        }
    }

    #if WTF_PLATFORM_IOS_FAMILY
    @MainActor
    func startMonitoringWirelessRoutes(connection: IPC.Connection) {
        state.setMonitorsWirelessRoutes(true)
    }

    @MainActor
    func stopMonitoringWirelessRoutes(connection: IPC.Connection) {
        state.setMonitorsWirelessRoutes(false)
    }
    #endif

    // Unlike the remote command target session, safe to ask from any process: it compares rather than assuming the
    // caller owns the target.
    @MainActor
    func isRemoteCommandTargetSessionForTesting(connection: IPC.Connection, identifier: IPCTypes.MediaSessionIdentifier) -> Bool {
        nowPlayingArbiter.isRemoteCommandTarget(process: state.processIdentifier, session: identifier.rawValue)
    }
}

extension WebKit.GPUConnectionToWebProcess {
    @cxx
    @implementation
    @MainActor
    func swiftHasRenderingBackend(_ identifier: UInt64) -> Bool {
        state.renderingBackends[identifier] != nil
    }

    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    // Before the backend receives messages, which its renderers' video frames are read from the heap for.
    @cxx
    @implementation
    @MainActor
    func swiftAddRenderingBackend(
        _ identifier: UInt64,
        _ renderingBackend: WebKit.RemoteRenderingBackend,
        _ videoFrameHeap: WebKit.RemoteVideoFrameObjectHeap,
        _ webProcessIdentity: WebCore.ProcessIdentity,
        _ hasWebProcessIdentity: Bool
    ) {
        precondition(state.renderingBackends[identifier] == nil, "The rendering backend has been added")
        #if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
        let videoFrameSources = GPUVideoFrameSources(
            heap: videoFrameHeap,
            webProcessIdentity: hasWebProcessIdentity ? webProcessIdentity : nil
        )
        renderingBackend.initializeSwiftState(videoFrameSources: videoFrameSources)
        #endif
        state.renderingBackends[identifier] = renderingBackend
    }
    #else
    // Before the backend receives messages.
    @cxx
    @implementation
    @MainActor
    func swiftAddRenderingBackend(_ identifier: UInt64, _ renderingBackend: WebKit.RemoteRenderingBackend) {
        precondition(state.renderingBackends[identifier] == nil, "The rendering backend has been added")
        #if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
        renderingBackend.initializeSwiftState(videoFrameSources: GPUVideoFrameSources())
        #endif
        state.renderingBackends[identifier] = renderingBackend
    }
    #endif

    @cxx
    @implementation
    @MainActor
    func swiftReleaseRenderingBackend(_ identifier: UInt64) -> Bool {
        state.releaseRenderingBackend(identifier)
    }

    @cxx
    @implementation
    @MainActor
    func swiftRenderingBackendCount() -> Int {
        state.renderingBackends.count
    }

    @cxx
    @implementation
    @MainActor
    func swiftCloseStreamReceivers() {
        state.closeStreamReceivers()
    }

    #if ENABLE_WEBGL
    @cxx
    @implementation
    @MainActor
    func swiftHasGraphicsContextGL(_ identifier: UInt64) -> Bool {
        state.graphicsContextGLOwners[identifier] != nil
    }

    @cxx
    @implementation
    @MainActor
    func swiftAddGraphicsContextGL(
        _ identifier: UInt64,
        _ renderingBackendIdentifier: UInt64,
        _ owner: IPC.SwiftReceiverOwner,
        _ attributes: WebCore.GraphicsContextGLAttributes
    ) {
        guard let renderingBackend = state.renderingBackends[renderingBackendIdentifier],
            state.graphicsContextGLOwners[identifier] == nil
        else {
            assertionFailure("The context has been added, or its rendering backend has not")
            owner.stopListeningForIPC()
            return
        }
        #if WTF_PLATFORM_COCOA
        WebKit.RemoteGraphicsContextGLClient.create(owner, self, renderingBackend, identifier, attributes)
        #else
        createGraphicsContextGLResources(attributes, identifier, renderingBackend, owner)
        #endif
        state.graphicsContextGLOwners[identifier] = owner
    }

    @cxx
    @implementation
    @MainActor
    func swiftReleaseGraphicsContextGL(_ identifier: UInt64) -> Bool {
        let owner: IPC.SwiftReceiverOwner? = state.graphicsContextGLOwners.removeValue(forKey: identifier)
        owner?.stopListeningForIPC()
        return state.graphicsContextGLOwners.isEmpty
    }
    #endif

    #if ENABLE_GPU_PROCESS_WEBGPU_SWIFT
    @cxx
    @implementation
    @MainActor
    func swiftHasGPU(_ identifier: UInt64) -> Bool {
        state.gpuOwners[identifier] != nil
    }

    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    @cxx
    @implementation
    @MainActor
    func swiftAddGPU(
        _ identifier: UInt64,
        _ renderingBackendIdentifier: UInt64,
        _ owner: IPC.SwiftReceiverOwner,
        _ webProcessResourceOwner: WTF.MachSendRight,
        _ videoFrameHeap: WebKit.RemoteVideoFrameObjectHeap,
        _ webProcessIdentity: WebCore.ProcessIdentity,
        _ hasWebProcessIdentity: Bool
    ) {
        guard let renderingBackend = renderingBackendForGPU(identifier, renderingBackendIdentifier, owner) else {
            return
        }
        RemoteGPU.create(
            owner,
            renderingBackend,
            identifier,
            webProcessResourceOwner,
            videoFrameHeap,
            hasWebProcessIdentity ? webProcessIdentity : nil
        )
        state.gpuOwners[identifier] = owner
    }
    #else
    @cxx
    @implementation
    @MainActor
    func swiftAddGPU(
        _ identifier: UInt64,
        _ renderingBackendIdentifier: UInt64,
        _ owner: IPC.SwiftReceiverOwner,
        _ webProcessResourceOwner: WTF.MachSendRight
    ) {
        guard let renderingBackend = renderingBackendForGPU(identifier, renderingBackendIdentifier, owner) else {
            return
        }
        RemoteGPU.create(owner, renderingBackend, identifier, webProcessResourceOwner)
        state.gpuOwners[identifier] = owner
    }
    #endif

    // The rendering backend of a new WebGPU receiver, after its companions are made, or nil, with the owner stopped.
    @MainActor
    private func renderingBackendForGPU(
        _ identifier: UInt64,
        _ renderingBackendIdentifier: UInt64,
        _ owner: IPC.SwiftReceiverOwner
    ) -> WebKit.RemoteRenderingBackend? {
        guard let renderingBackend = state.renderingBackends[renderingBackendIdentifier], state.gpuOwners[identifier] == nil else {
            assertionFailure("The GPU has been added, or its rendering backend has not")
            owner.stopListeningForIPC()
            return nil
        }
        #if ENABLE_GPU_PROCESS_MODEL
        createGPUModel(renderingBackend, owner, identifier)
        #endif
        return renderingBackend
    }

    @cxx
    @implementation
    @MainActor
    func swiftReleaseGPU(_ identifier: UInt64) -> Bool {
        let owner = state.gpuOwners.removeValue(forKey: identifier)
        assert(owner != nil, "The GPU has not been added")
        owner?.stopListeningForIPC()
        return state.gpuOwners.isEmpty
    }
    #endif
}

// What the connection's receivers make the readers of the video frames its web process shares with: the connection's video
// frame heap, and the web process's identity, if it has one, which the buffers read out of shared memory are attributed to.
struct GPUVideoFrameSources {
    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    let heap: WebKit.RemoteVideoFrameObjectHeap
    let webProcessIdentity: WebCore.ProcessIdentity?

    func make() -> SharedVideoFrameSource {
        SharedVideoFrameSource(heap: heap, resourceOwner: webProcessIdentity)
    }
    #endif
}

#endif // ENABLE_GPU_PROCESS
