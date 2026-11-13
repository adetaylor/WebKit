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

// What one web process asked of the audio session (RemoteAudioSessionProxy).
@MainActor
final class AudioSessionProxyState {
    let identifier: UInt64
    let processIdentifier: UInt64
    var category: IPCTypes.AudioSessionCategory = .none
    var mode: IPCTypes.AudioSessionMode = .default
    var routeSharingPolicy: IPCTypes.RouteSharingPolicy = .default
    var soundStageSize: IPCTypes.AudioSessionSoundStageSize = .automatic
    var preferredBufferSize: UInt64 = 0
    var isActive = false
    var isInterrupted = false
    var isPlayingToBluetoothOverrideChanged = false

    init(identifier: UInt64, processIdentifier: UInt64) {
        self.identifier = identifier
        self.processIdentifier = processIdentifier
    }
}

extension IPCTypes.AudioSessionCategory {
    fileprivate var canMixWithOthers: Bool {
        self == .ambientSound
    }
}

// The GPU process's arbitration between what its web processes ask of its one audio session
// (RemoteAudioSessionProxyManager), which it applies to the session through the manager.
@MainActor
final class AudioSessionArbiter {
    private(set) var proxies: [AudioSessionProxyState] = []
    // A capture preview has no proxy, but needs a session that can record.
    var isCapturePreviewActive = false

    fileprivate nonisolated init() {
    }

    func proxy(_ identifier: UInt64) -> AudioSessionProxyState? {
        proxies.first { $0.identifier == identifier }
    }

    fileprivate func add(_ proxy: AudioSessionProxyState) {
        assert(self.proxy(proxy.identifier) == nil)
        proxies.append(proxy)
        updateCategory()
    }

    fileprivate func remove(_ identifier: UInt64) {
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

        WebKit.RemoteAudioSessionProxyManager.setSessionCategory(
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
        WebKit.RemoteAudioSessionProxyManager.setSessionPreferredBufferSize(preferredBufferSize)
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
        WebKit.RemoteAudioSessionProxyManager.setSessionSpatialExperience(
            largest?.identifier ?? 0,
            WebCore.AudioSessionSoundStageSize(largest?.soundStageSize ?? .automatic)
        )
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
    fileprivate func activation(_ identifier: UInt64, active: Bool) -> WebKit.RemoteAudioSessionActivation {
        guard let proxy = proxy(identifier) else {
            return .None
        }

        if !active {
            // Other proxies or a capture preview still need the session.
            if isCapturePreviewActive || hasOtherActiveProxy(than: identifier) {
                return .None
            }
            return .Deactivate
        }

        if !hasActiveNotInterruptedProxy() {
            return .Activate
        }

        // An ambient proxy mixes with the active proxies.
        if proxy.category.canMixWithOthers {
            return .None
        }

#if WTF_PLATFORM_IOS_FAMILY
        for otherProxy in proxies {
            if otherProxy.processIdentifier == proxy.processIdentifier || !otherProxy.isActive || otherProxy.category.canMixWithOthers {
                continue
            }
            otherProxy.isInterrupted = true
            WebKit.RemoteAudioSessionProxyManager.beginProxyInterruption(otherProxy.identifier)
        }
#endif
        return .None
    }

    fileprivate func beginAudioSessionInterruption() {
        for proxy in proxies where proxy.isActive {
            proxy.isInterrupted = true
            WebKit.RemoteAudioSessionProxyManager.beginProxyInterruption(proxy.identifier)
        }
    }

    fileprivate func endAudioSessionInterruption(mayResume: Bool) {
        for proxy in proxies where proxy.isActive {
            proxy.isInterrupted = false
            WebKit.RemoteAudioSessionProxyManager.endProxyInterruption(proxy.identifier, mayResume)
        }
    }
}

let audioSessionArbiter = AudioSessionArbiter()

extension WebKit.RemoteAudioSessionProxyManager {
    @cxx
    @implementation
    func addSwiftProxy(_ identifier: UInt64, _ processIdentifier: UInt64) {
        MainActor.assumeIsolated {
            audioSessionArbiter.add(AudioSessionProxyState(identifier: identifier, processIdentifier: processIdentifier))
        }
    }

    @cxx
    @implementation
    func removeSwiftProxy(_ identifier: UInt64) {
        MainActor.assumeIsolated {
            audioSessionArbiter.remove(identifier)
        }
    }

    @cxx
    @implementation
    func updateSpatialExperience() {
        MainActor.assumeIsolated {
            audioSessionArbiter.updateSpatialExperience()
        }
    }

    @cxx
    @implementation
    func swiftActivation(_ identifier: UInt64, _ active: Bool) -> WebKit.RemoteAudioSessionActivation {
        MainActor.assumeIsolated {
            audioSessionArbiter.activation(identifier, active: active)
        }
    }

    @cxx
    @implementation
    func swiftBeginAudioSessionInterruption() {
        MainActor.assumeIsolated {
            audioSessionArbiter.beginAudioSessionInterruption()
        }
    }

    @cxx
    @implementation
    func swiftEndAudioSessionInterruption(_ mayResume: Bool) {
        MainActor.assumeIsolated {
            audioSessionArbiter.endAudioSessionInterruption(mayResume: mayResume)
        }
    }

#if WTF_PLATFORM_IOS_FAMILY || ENABLE_ROUTING_ARBITRATION
    @cxx
    @implementation
    func isCapturePreviewActive() -> Bool {
        MainActor.assumeIsolated {
            audioSessionArbiter.isCapturePreviewActive
        }
    }

    @cxx
    @implementation
    func setCapturePreviewActive(_ active: Bool) {
        MainActor.assumeIsolated {
            audioSessionArbiter.isCapturePreviewActive = active
            audioSessionArbiter.updateCategory()
        }
    }

    @cxx
    @implementation
    func hasActiveProxy() -> Bool {
        MainActor.assumeIsolated {
            audioSessionArbiter.hasActiveProxy()
        }
    }
#endif
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
    init(_ size: IPCTypes.AudioSessionSoundStageSize) {
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
