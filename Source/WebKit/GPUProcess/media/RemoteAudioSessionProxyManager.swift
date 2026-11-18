// Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && USE_AUDIO_SESSION

import WebKit_Internal
import os

private let audioSessionLog = os.Logger(subsystem: "com.apple.WebKit", category: "WebRTC")

private typealias AudioSessionMessages = RemoteAudioSessionProxy.RemoteAudioSessionMessages

// What a proxy's request to make the audio session active or inactive does to the session.
enum AudioSessionActivation {
    case none
    case activate
    case deactivate
}

// What one web process asked of the audio session (RemoteAudioSessionProxy), and its connection, which hears the session's
// configuration and interruptions.
@MainActor
final class AudioSessionProxyState {
    let identifier: UInt64
    let processIdentifier: UInt64
    // The web process's connection, until it closes.
    private(set) var connection: WebKit.GPUConnectionToWebProcess?
    private var hasJoined = false
    var category: IPCTypes.AudioSessionCategory = .none
    var mode: IPCTypes.AudioSessionMode = .default
    var routeSharingPolicy: IPCTypes.RouteSharingPolicy = .default
    var soundStageSize: IPCTypes.AudioSessionSoundStageSize = .automatic
    var sceneIdentifier: String?
    var preferredBufferSize: UInt64 = 0
    var isActive = false
    var isInterrupted = false
    var isPlayingToBluetoothOverrideChanged = false
    #if WTF_PLATFORM_IOS_FAMILY
    private var speakerID = ""
    #endif

    init(identifier: UInt64, processIdentifier: UInt64, connection: WebKit.GPUConnectionToWebProcess) {
        self.identifier = identifier
        self.processIdentifier = processIdentifier
        self.connection = connection
    }

    // The proxy joins the arbitration, until its connection closes.
    func join() {
        guard !hasJoined, connection != nil else {
            return
        }
        hasJoined = true
        audioSessionArbiter.add(self)
        #if WTF_PLATFORM_IOS_FAMILY
        WebKit.RemoteAudioSessionIOS.setHostProcessAttribution()
        #endif
    }

    func leave() {
        connection = nil
        guard hasJoined else {
            return
        }
        hasJoined = false
        audioSessionArbiter.remove(identifier)
    }

    var configuration: IPCTypes.RemoteAudioSessionConfiguration {
        let session = WebCore.AudioSession.singleton()
        return IPCTypes.RemoteAudioSessionConfiguration(
            routingContextUID: IPCCoding.WTFString.swiftString(session.routingContextUID()),
            sampleRate: session.sampleRate(),
            bufferSize: UInt64(session.bufferSize()),
            numberOfOutputChannels: UInt64(session.numberOfOutputChannels()),
            maximumNumberOfOutputChannels: UInt64(session.maximumNumberOfOutputChannels()),
            preferredBufferSize: UInt64(session.preferredBufferSize()),
            outputLatency: UInt64(session.outputLatency()),
            isMuted: session.isMuted(),
            sceneIdentifier: sceneIdentifier,
            soundStageSize: soundStageSize,
            categoryOverride: IPCTypes.AudioSessionCategory(session.categoryOverride()),
            isActive: isActive
        )
    }

    private func send(_ body: (IPC.Connection) -> Void) {
        guard let connection else {
            return
        }
        body(connection.connection())
    }

    func configurationChanged() {
        let configuration = configuration
        send { AudioSessionMessages.configurationChanged(on: $0, to: 0, configuration: configuration) }
    }

    func beginInterruption() {
        send { AudioSessionMessages.beginInterruptionRemote(on: $0, to: 0) }
    }

    func endInterruption(mayResume: Bool) {
        send { AudioSessionMessages.endInterruptionRemote(on: $0, to: 0, flags: mayResume ? .yes : .no) }
    }

    // Whether the session's activity changed as asked, then the proxy's.
    func tryToSetActive(_ active: Bool) async -> Bool {
        join()
        #if WTF_PLATFORM_IOS_FAMILY
        if active, let connection {
            WebKit.RemoteAudioSessionIOS.providePresentingApplicationPID(connection)
        }
        #endif
        let success: Bool
        switch audioSessionArbiter.activation(identifier, active: active) {
        case .none:
            success = true
        case .activate:
            success = await setSessionActive(true)
        case .deactivate:
            success = await setSessionActive(false)
        }
        let hasActiveChanged = success && isActive != active
        if success {
            isActive = active
            if active {
                isInterrupted = false
            }
        }
        #if ENABLE_MEDIA_STREAM && WTF_PLATFORM_IOS_FAMILY
        if success && active {
            WebKit.RemoteAudioSessionIOS.setPreferredSpeakerID(IPCCoding.WTFString.cxxString(speakerID))
        }
        #endif
        // After the reply.
        Task { @MainActor in
            if hasActiveChanged && self.connection != nil {
                self.configurationChanged()
            }
            audioSessionArbiter.updatePresentingProcesses()
            audioSessionArbiter.updateSpatialExperience()
        }
        return success
    }

    #if WTF_PLATFORM_IOS_FAMILY
    func setPreferredSpeakerID(_ speakerID: String) {
        if self.speakerID == speakerID {
            return
        }
        self.speakerID = speakerID
        if !isActive {
            return
        }
        #if ENABLE_MEDIA_STREAM
        WebKit.RemoteAudioSessionIOS.setPreferredSpeakerID(IPCCoding.WTFString.cxxString(speakerID))
        #endif
    }
    #endif
}

@MainActor
private func setSessionActive(_ active: Bool) async -> Bool {
    await withCheckedContinuation { continuation in
        WebCore.AudioSession.singleton().tryToSetActive(active, consuming: .init(continuation))
    }
}

extension IPCTypes.AudioSessionCategory {
    fileprivate var canMixWithOthers: Bool {
        self == .ambientSound
    }
}

// The GPU process's arbitration between what its web processes ask of its one audio session, which it applies to the
// session, and of the session's interruptions and configuration, which it tells the web processes about.
@MainActor
final class AudioSessionArbiter {
    private(set) var proxies: [AudioSessionProxyState] = []
    // A capture preview has no proxy, but needs a session that can record.
    private var isCapturePreviewActive = false
    private var capturePreviewActivationHandlers: [() -> Void] = []
    private var capturePreviewActivationCount: UInt = 0
    // While the arbiter interrupts the session for a web process, which needs no interruption back.
    private var isForwardingInterruption = false
    private var observer: WebCore.AudioSessionObserverCallbacks?

    fileprivate nonisolated init() {
    }

    // The arbiter observes the session from when it is first needed.
    private func observeIfNeeded() {
        if observer != nil {
            return
        }
        observer = WebCore.AudioSessionObserverCallbacks.create(
            consuming: WebCore.AudioSessionObserverCallbacks.Callback {
                MainActor.assumeIsolated {
                    audioSessionArbiter.beginAudioSessionInterruption()
                }
            },
            consuming: WebCore.AudioSessionObserverCallbacks.EndInterruptionCallback { mayResume in
                MainActor.assumeIsolated {
                    audioSessionArbiter.endAudioSessionInterruption(mayResume: mayResume)
                }
            },
            consuming: WebCore.AudioSessionObserverCallbacks.Callback {
                MainActor.assumeIsolated {
                    audioSessionArbiter.configurationDidChange()
                }
            }
        )
    }

    func proxy(_ identifier: UInt64) -> AudioSessionProxyState? {
        proxies.first { $0.identifier == identifier }
    }

    fileprivate func add(_ proxy: AudioSessionProxyState) {
        observeIfNeeded()
        assert(self.proxy(proxy.identifier) == nil)
        proxies.append(proxy)
        updateCategory()
    }

    fileprivate func remove(_ identifier: UInt64) {
        assert(proxy(identifier) != nil)
        proxies.removeAll { $0.identifier == identifier }
        updateCategory()
    }

    // The strongest category, mode and route sharing policy that a proxy or the capture preview asks for.
    func updateCategory() {
        var categories = Set<IPCTypes.AudioSessionCategory>()
        var modes = Set<IPCTypes.AudioSessionMode>()
        var policies = Set<IPCTypes.RouteSharingPolicy>()

        // Without it the session stays in playback and on iOS BaseAudioCaptureUnit won't start.
        if isCapturePreviewActive {
            categories.insert(.playAndRecord)
            modes.insert(.videoChat)
        }

        for proxy in proxies {
            categories.insert(proxy.category)
            modes.insert(proxy.mode)
            policies.insert(proxy.routeSharingPolicy)
        }

        let categoryOrder: [IPCTypes.AudioSessionCategory] = [
            .playAndRecord, .recordAudio, .mediaPlayback, .soloAmbientSound, .ambientSound, .audioProcessing,
        ]
        let category = categoryOrder.first { categories.contains($0) } ?? .none
        let modeOrder: [IPCTypes.AudioSessionMode] = [.moviePlayback, .videoChat]
        let mode = modeOrder.first { modes.contains($0) } ?? .default

        var policy = IPCTypes.RouteSharingPolicy.default
        if policies.contains(.longFormVideo) {
            policy = .longFormVideo
        } else if policies.contains(.longFormAudio) {
            policy = .longFormAudio
        } else if policies.contains(.independent) {
            assertionFailure()
        }

#if !HAVE_AVSYSTEMROUTING_FRAMEWORK
        if isCapturePreviewActive {
            policy = .default
        }
#endif

        WebCore.AudioSession.singleton().setCategory(
            WebCore.AudioSessionCategory(category),
            WebCore.AudioSessionMode(mode),
            WebCore.RouteSharingPolicy(policy)
        )
    }

    // The smallest preferred buffer size a proxy asks for, if any asks for one.
    func updatePreferredBufferSize() {
        guard let preferredBufferSize = proxies.lazy.map(\.preferredBufferSize).filter({ $0 != 0 }).min() else {
            return
        }
        WebCore.AudioSession.singleton().setPreferredBufferSize(Int(clamping: preferredBufferSize))
    }

    // The scene identifier and sound stage size of the first active proxy with the largest sound stage size.
    func updateSpatialExperience() {
        var largest: AudioSessionProxyState?
        for proxy in proxies where proxy.isActive {
            if let current = largest, proxy.soundStageSize.rawValue <= current.soundStageSize.rawValue {
                continue
            }
            largest = proxy
        }
        let session = WebCore.AudioSession.singleton()
        session.setSceneIdentifier(IPCCoding.WTFString.cxxString(largest?.sceneIdentifier))
        session.setSoundStageSize(WebCore.AudioSessionSoundStageSize(largest?.soundStageSize ?? .automatic))
    }

    // On iOS, the presenting applications of the web processes whose proxies are active.
    func updatePresentingProcesses() {
        #if WTF_PLATFORM_IOS_FAMILY
        var presentingProcesses = WebKit.RemoteAudioSessionPresentingProcesses()
        for proxy in proxies {
            guard let connection = proxy.connection else {
                continue
            }
            presentingProcesses.add(connection, proxy.isActive)
        }
        presentingProcesses.commit()
        #endif
    }

    func hasActiveProxy() -> Bool {
        proxies.contains { $0.isActive }
    }

    private func hasOtherActiveProxy(than identifier: UInt64) -> Bool {
        proxies.contains { $0.isActive && $0.identifier != identifier }
    }

    private func hasActiveNotInterruptedProxy() -> Bool {
        proxies.contains { $0.isActive && !$0.isInterrupted }
    }

    // What the proxy's request to make the session active or inactive does to it. Making it active interrupts, on iOS, the
    // active proxies of other web processes that can't mix with the proxy.
    func activation(_ identifier: UInt64, active: Bool) -> AudioSessionActivation {
        guard let proxy = proxy(identifier) else {
            return .none
        }

        if !active {
            // Other proxies or a capture preview still need the session.
            if isCapturePreviewActive || hasOtherActiveProxy(than: identifier) {
                return .none
            }
            return .deactivate
        }

        if !hasActiveNotInterruptedProxy() {
            return .activate
        }

        // An ambient proxy mixes with the active proxies.
        if proxy.category.canMixWithOthers {
            return .none
        }

#if WTF_PLATFORM_IOS_FAMILY
        for otherProxy in proxies {
            if otherProxy.processIdentifier == proxy.processIdentifier || !otherProxy.isActive || otherProxy.category.canMixWithOthers {
                continue
            }
            otherProxy.isInterrupted = true
            otherProxy.beginInterruption()
        }
#endif
        return .none
    }

    // MARK: Interruptions

    // A web process interrupted its own session, which the GPU process's follows.
    func beginInterruptionRemote() {
        isForwardingInterruption = true
        WebCore.AudioSession.singleton().beginInterruption()
        isForwardingInterruption = false
    }

    func endInterruptionRemote(mayResume: Bool) {
        isForwardingInterruption = true
        WebCore.AudioSession.singleton().endInterruption(mayResume ? .Yes : .No)
        isForwardingInterruption = false
    }

    private func beginAudioSessionInterruption() {
        if isForwardingInterruption {
            return
        }
        for proxy in proxies where proxy.isActive {
            proxy.isInterrupted = true
            proxy.beginInterruption()
        }
    }

    private func endAudioSessionInterruption(mayResume: Bool) {
        if isForwardingInterruption {
            return
        }
        for proxy in proxies where proxy.isActive {
            proxy.isInterrupted = false
            proxy.endInterruption(mayResume: mayResume)
        }
    }

    private func configurationDidChange() {
        for proxy in proxies {
            proxy.configurationChanged()
        }
    }

    // MARK: Capture preview

    #if WTF_PLATFORM_IOS_FAMILY || ENABLE_ROUTING_ARBITRATION
    func beginCapturePreview(_ completion: @escaping () -> Void) {
        observeIfNeeded()
        if isCapturePreviewActive {
            if !capturePreviewActivationHandlers.isEmpty {
                capturePreviewActivationHandlers.append(completion)
                return
            }
            completion()
            return
        }

        isCapturePreviewActive = true
        updateCategory()

        capturePreviewActivationHandlers.append(completion)
        capturePreviewActivationCount += 1
        let activation = capturePreviewActivationCount
        // Now, so that an endCapturePreview() after this deactivates the session after this activates it.
        WebCore.AudioSession.singleton().tryToSetActive(true, consuming: .init { [self] succeeded in
            MainActor.assumeIsolated {
                if !succeeded {
                    audioSessionLog.error("RemoteAudioSessionProxyManager::beginCapturePreview unable to activate the audio session for a capture preview")
                }
                if activation != capturePreviewActivationCount {
                    return
                }
                let handlers = capturePreviewActivationHandlers
                capturePreviewActivationHandlers.removeAll()
                for handler in handlers {
                    handler()
                }
            }
        })
    }

    func endCapturePreview() {
        observeIfNeeded()
        if !isCapturePreviewActive {
            return
        }

        // An activation still in flight must not run these later, so run them now.
        capturePreviewActivationCount += 1
        let activationHandlers = capturePreviewActivationHandlers
        capturePreviewActivationHandlers.removeAll()

        isCapturePreviewActive = false
        updateCategory()

        if !hasActiveProxy() {
            WebCore.AudioSession.singleton().tryToSetActive(false, consuming: .init { _ in })
        }

        for handler in activationHandlers {
            handler()
        }
    }
    #endif
}

let audioSessionArbiter = AudioSessionArbiter()

#if ENABLE_ROUTING_ARBITRATION && HAVE_AVAUDIO_ROUTING_ARBITER
extension WebKit.GPUConnectionToWebProcess {
    @cxx
    @implementation
    @MainActor
    func swiftEnableRoutingArbitration() {
        precondition(state.routingArbitration == nil, "The connection does the routing arbitration")
        let ipcConnection = connection()
        // The functions reference the connection until its process terminates.
        let routingArbitration = WebCore.AudioSessionRoutingArbitrationCallbacks.create(
            consuming: WebCore.AudioSessionRoutingArbitrationCallbacks.BeginCallback { [self] category, callback in
                guard let callback else {
                    return
                }
                if isAlwaysOnLoggingAllowed() {
                    audioSessionLog.log("LocalAudioSessionRoutingArbitrator::beginRoutingArbitrationWithCategory \(category.rawValue)")
                }
                WebKit.sendBeginRoutingArbitration(ipcConnection, category, callback)
            },
            consuming: WebCore.AudioSessionRoutingArbitrationCallbacks.LeaveCallback {
                WebKit.sendEndRoutingArbitration(ipcConnection)
            },
            consuming: WebCore.AudioSessionRoutingArbitrationCallbacks.CanLogCallback { [self] in
                isAlwaysOnLoggingAllowed()
            }
        )
        state.routingArbitration = routingArbitration
        routingArbitration.becomeSharedSessionClient()
    }

    @cxx
    @implementation
    @MainActor
    func swiftRoutingArbitrationProcessDidTerminate() {
        guard state.routingArbitration != nil else {
            return
        }
        WebKit.sendEndRoutingArbitration(connection())
        state.routingArbitration = nil
    }
}
#endif

#if ENABLE_MEDIA_STREAM && (WTF_PLATFORM_IOS_FAMILY || ENABLE_ROUTING_ARBITRATION)
extension WebKit.GPUProcess {
    @cxx
    @implementation
    @MainActor
    func swiftBeginCapturePreviewAudioSession(_ generation: UInt64) {
        audioSessionArbiter.beginCapturePreview { [self] in
            capturePreviewAudioSessionIsReady(generation)
        }
    }

    @cxx
    @implementation
    @MainActor
    func swiftEndCapturePreviewAudioSession() {
        audioSessionArbiter.endCapturePreview()
    }
}
#endif

extension IPCTypes.AudioSessionCategory {
    // The two list the same values in the same order (WebCoreArgumentCodersMedia.serialization.in).
    init(_ category: WebCore.AudioSessionCategory) {
        self = IPCTypes.AudioSessionCategory(rawValue: category.rawValue) ?? .none
    }
}

extension WebCore.AudioSessionCategory {
    fileprivate init(_ category: IPCTypes.AudioSessionCategory) {
        switch category {
        case .none:
            self = .None
        case .ambientSound:
            self = .AmbientSound
        case .soloAmbientSound:
            self = .SoloAmbientSound
        case .mediaPlayback:
            self = .MediaPlayback
        case .recordAudio:
            self = .RecordAudio
        case .playAndRecord:
            self = .PlayAndRecord
        case .audioProcessing:
            self = .AudioProcessing
        }
    }
}

extension WebCore.AudioSessionMode {
    fileprivate init(_ mode: IPCTypes.AudioSessionMode) {
        switch mode {
        case .default:
            self = .Default
        case .videoChat:
            self = .VideoChat
        case .moviePlayback:
            self = .MoviePlayback
        }
    }
}

extension WebCore.RouteSharingPolicy {
    fileprivate init(_ policy: IPCTypes.RouteSharingPolicy) {
        switch policy {
        case .default:
            self = .Default
        case .longFormAudio:
            self = .LongFormAudio
        case .independent:
            self = .Independent
        case .longFormVideo:
            self = .LongFormVideo
        }
    }
}

extension WebCore.AudioSessionSoundStageSize {
    fileprivate init(_ size: IPCTypes.AudioSessionSoundStageSize) {
        switch size {
        case .automatic:
            self = .Automatic
        case .small:
            self = .Small
        case .medium:
            self = .Medium
        case .large:
            self = .Large
        }
    }
}

#endif // ENABLE_GPU_PROCESS && USE_AUDIO_SESSION
