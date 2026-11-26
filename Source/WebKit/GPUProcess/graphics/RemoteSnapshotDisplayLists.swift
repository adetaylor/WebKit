// Copyright (C) 2025 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && !ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT

import WebCore_Private
import WebKit_Internal

// A snapshot's display lists, held by the snapshot (RemoteSnapshot.swift) for as long as it exists: its recorders record
// frames into them, and the sinks that take it draw its frames from them.
//
// @unchecked Sendable: the C++ object is thread-safe reference counted, its token never changes, and its lock (m_lock)
// guards its frames in each of its members. The threads that reach it: the rendering backends' work queues (setFrame,
// applyFrame, abandonFrame), the main thread (a sink's applyFrame, abandonFrame), and any thread that reads the token.
final class RemoteSnapshotDisplayListsReference: @unchecked Sendable {
    private let displayLists: WebKit.RemoteSnapshotDisplayLists

    init() {
        displayLists = WebKit.RemoteSnapshotDisplayLists.create().get()
    }

    // Unique to these display lists, so that a recorder's frames reach only the snapshot that holds them.
    var token: UInt64 {
        displayLists.token()
    }

    // A frame that draws nothing, even if its display list comes in later.
    func abandonFrame(_ frame: UInt64) {
        displayLists.abandonFrame(WebCore.FrameIdentifier(frame))
    }

    // A C++ reference to these display lists.
    var cxxReference: WebKit.RefRemoteSnapshotDisplayLists {
        WebKit.RefRemoteSnapshotDisplayLists(displayLists)
    }

    // Completes a sink of the snapshot, which draws its frames from these display lists if it succeeded.
    func complete(_ sink: WebKit.RemoteSnapshotSink, _ success: Bool, _ size: WebCore.FloatSize) {
        sink.complete(success, size, displayLists)
    }
}

extension RemoteSnapshotDisplayListsReference: CustomReflectable {
    // Nothing to reflect: the display lists' frames are reached only under their lock, in C++.
    var customMirror: Mirror {
        Mirror(self, children: [])
    }
}

#endif // ENABLE_GPU_PROCESS && !ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
