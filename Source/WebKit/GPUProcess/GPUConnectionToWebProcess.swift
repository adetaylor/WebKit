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

import WebKit_Internal

// The Swift state of a web process's connection to the GPU process (GPUConnectionToWebProcess.h), which
// GPUConnectionToWebProcess::m_swiftState holds.
@MainActor
final class GPUConnectionState {
    let processIdentifier: UInt64
    // The Now Playing candidate states of the connection's pages, by page identifier, which the election reads.
    var nowPlayingCandidates: [UInt64: IPCTypes.NowPlayingCandidateState] = [:]

    fileprivate nonisolated init(processIdentifier: UInt64) {
        self.processIdentifier = processIdentifier
    }
}

extension WebKit.GPUConnectionToWebProcess {
    @cxx
    @implementation
    func createSwiftState(_ webProcessIdentifier: UInt64) -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(GPUConnectionState(processIdentifier: webProcessIdentifier)).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        unsafe Unmanaged<GPUConnectionState>.fromOpaque(stateAddress(swiftState)).release()
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
}

extension WebKit.GPUConnectionToWebProcess {
    @cxx
    @implementation
    @MainActor
    func swiftDidAddToGPUProcess() {
        webProcessConnections.add(self, process: state.processIdentifier)
    }

    @cxx
    @implementation
    @MainActor
    func swiftDidRemoveFromGPUProcess() {
        webProcessConnections.remove(process: state.processIdentifier)
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
    func swiftNowPlayingClientDidClose() {
        state.nowPlayingCandidates.removeAll()
        nowPlayingArbiter.clientDidClose(process: state.processIdentifier)
    }

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

    // Unlike the remote command target session, safe to ask from any process: it compares rather than assuming the
    // caller owns the target.
    @MainActor
    func isRemoteCommandTargetSessionForTesting(connection: IPC.Connection, identifier: IPCTypes.MediaSessionIdentifier) -> Bool {
        nowPlayingArbiter.isRemoteCommandTarget(process: state.processIdentifier, session: identifier.rawValue)
    }
}

#endif // ENABLE_GPU_PROCESS
