// Copyright (C) 2020-2024 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT

@_spi(WebKitGPU) internal import WebCore
import WebCore_Private
import WebKit_Internal

// The rendering backend's state in Swift, on its work queue: the receivers of its image buffers' messages and its display
// list recorders, by identifier, and the display lists that its contexts' DrawDisplayList messages name.
final class RemoteRenderingBackendState {
    private(set) var imageBuffers: [UInt64: RemoteImageBuffer] = [:]
    // The image buffer that the last lookup found, which the draws of one image buffer after another find without the
    // dictionary. Only while the receiver is in imageBuffers, so that it keeps the buffer no longer than the receiver does.
    private var lastFoundImageBuffer: (key: UInt64, imageBuffer: WebCore.ImageBuffer)?
    var displayListRecorders: [RemoteIdentifierKey: DisplayListRecorder] = [:]
    // Recorders whose recordings became display lists, for the next recorders to reuse: a page makes many short display
    // lists, such as one for each run of text it caches, in each rendering update.
    var idleDisplayListRecorders: [DisplayListRecorder] = []
    // False once the backend is uninitialized, after which an idle recorder would keep the backend that its resources keep.
    var reusesDisplayListRecorders = true
    let displayLists = RemoteCGRendererDisplayLists.create()

    // False if a receiver already has the key.
    func addImageBuffer(_ receiver: RemoteImageBuffer, key: UInt64) -> Bool {
        guard imageBuffers[key] == nil else {
            return false
        }
        imageBuffers[key] = receiver
        return true
    }

    func removeImageBuffer(key: UInt64) -> RemoteImageBuffer? {
        lastFoundImageBuffer = nil
        return imageBuffers.removeValue(forKey: key)
    }

    func removeAllImageBuffers() -> [UInt64: RemoteImageBuffer] {
        lastFoundImageBuffer = nil
        let removed = imageBuffers
        imageBuffers = [:]
        return removed
    }

    func imageBuffer(key: UInt64) -> WebCore.ImageBuffer? {
        if let lastFoundImageBuffer, lastFoundImageBuffer.key == key {
            return lastFoundImageBuffer.imageBuffer
        }
        guard let imageBuffer = imageBuffers[key]?.imageBuffer else {
            return nil
        }
        lastFoundImageBuffer = (key, imageBuffer)
        return imageBuffer
    }
}

// A display list recorder and the forwarder of its messages, which the stream connection keeps while it receives them.
struct DisplayListRecorder {
    let recorder: RemoteCGRendererRecorder
    let forwarder: RefRemoteCGRendererRecorderMessageForwarder
}

private let maximumIdleDisplayListRecorders = 16

extension WebKit.RemoteRenderingBackend {
    @cxx
    @implementation
    func swiftInitialize() {
        precondition(swiftState() == 0)
        // Safety: the state is new, and retained once, which only destroySwiftState() releases.
        unsafe setSwiftState(UInt(bitPattern: unsafe Unmanaged.passRetained(RemoteRenderingBackendState()).toOpaque()))
    }

    // Static, so that the destructor never retains the backend it destroys.
    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        // Safety: swiftInitialize() retained the state at this address, and only the destructor releases it.
        _ = unsafe Unmanaged<RemoteRenderingBackendState>
            .fromOpaque(UnsafeRawPointer(bitPattern: swiftState) ?? noSwiftState())
            .takeRetainedValue()
    }

    // Ends every receiver, which releases the references that they and the recorders' resources hold to this, and empties
    // the display lists.
    @cxx
    @implementation
    func swiftUninitialize() {
        let state = self.state
        for receiver in state.removeAllImageBuffers().values {
            receiver.stopReceivingMessages()
        }
        let recorders = state.displayListRecorders
        state.displayListRecorders = [:]
        state.reusesDisplayListRecorders = false
        state.idleDisplayListRecorders = []
        for identifier in recorders.keys {
            _ = streamConnection().tryStopReceivingMessages(.RemoteCGRenderer, identifier.value)
        }
        state.displayLists.removeAll()
    }

    @cxx
    @implementation
    func swiftAddImageBuffer(
        _ imageBuffer: WebCore.ImageBuffer,
        _ identifier: WebCore.RenderingResourceIdentifier,
        _ contextIdentifier: WebKit.RemoteGraphicsContextIdentifier
    ) -> Bool {
        let state = self.state
        let key = identifier.toUInt64()
        guard state.imageBuffers[key] == nil,
            let receiver = RemoteImageBuffer.create(imageBuffer, identifier: key, contextIdentifier: contextIdentifier, backend: self)
        else {
            return false
        }
        return state.addImageBuffer(receiver, key: key)
    }

    // The receiver goes before this returns, and with it its references to the buffer, so that the caller can check that
    // nothing else has the buffer.
    @cxx
    @implementation
    func swiftTakeImageBuffer(_ identifier: WebCore.RenderingResourceIdentifier) -> WebKit.RefPtrImageBuffer {
        guard let receiver = state.removeImageBuffer(key: identifier.toUInt64()) else {
            return WebKit.RefPtrImageBuffer(nil)
        }
        receiver.stopReceivingMessages()
        return WebKit.RefPtrImageBuffer(receiver.imageBuffer)
    }

    @cxx
    @implementation
    func swiftReleaseImageBuffer(_ identifier: WebCore.RenderingResourceIdentifier) -> Bool {
        guard let receiver = state.removeImageBuffer(key: identifier.toUInt64()) else {
            return false
        }
        receiver.stopReceivingMessages()
        return true
    }

    @cxx
    @implementation
    func imageBuffer(_ identifier: WebCore.RenderingResourceIdentifier) -> WebKit.RefPtrImageBuffer {
        let key = identifier.toUInt64()
        let swiftState = swiftState()
        precondition(swiftState != 0, "RemoteRenderingBackend has no Swift state")
        // Each draw of an image buffer looks it up, so the state is borrowed for the lookup rather than retained.
        // Safety: m_swiftState is a retained RemoteRenderingBackendState from swiftInitialize() to the destructor, which
        // doesn't run during the call.
        return unsafe Unmanaged<RemoteRenderingBackendState>
            .fromOpaque(UnsafeRawPointer(bitPattern: swiftState) ?? noSwiftState())
            ._withUnsafeGuaranteedRef { state in WebKit.RefPtrImageBuffer(state.imageBuffer(key: key)) }
    }

    // A recorder of the RemoteCGRenderer messages to it, as RemoteGraphicsContext records them into a WebCore display list
    // recorder: false if one already has the identifier.
    @cxx
    @implementation
    func swiftCreateDisplayListRecorder(_ identifier: WebKit.RemoteDisplayListRecorderIdentifier) -> Bool {
        let state = self.state
        let key = identifier.toUInt64()
        guard state.displayListRecorders[RemoteIdentifierKey(value: key)] == nil else {
            return false
        }
        // The recorder starts receiving from the end of the idle ones, from where it moves without a copy of the forwarder.
        if state.idleDisplayListRecorders.isEmpty {
            state.idleDisplayListRecorders.append(makeDisplayListRecorder(state))
        }
        let started = IPC.tryStartReceivingSwiftMessages(
            streamConnection(),
            state.idleDisplayListRecorders[state.idleDisplayListRecorders.count - 1].forwarder,
            .RemoteCGRenderer,
            key
        )
        guard started else {
            return false
        }
        state.displayListRecorders[RemoteIdentifierKey(value: key)] = state.idleDisplayListRecorders.removeLast()
        return true
    }

    private func makeDisplayListRecorder(_ state: RemoteRenderingBackendState) -> DisplayListRecorder {
        let recorder = RemoteCGRendererRecorder.create(
            resources: WebKit.createDisplayListRecorderResources(self),
            displayLists: state.displayLists
        )
        return DisplayListRecorder(recorder: recorder, forwarder: RemoteCGRendererRecorder.createMessageReceiver(recorder: recorder))
    }

    // Makes what the recorder recorded the display list that the identifier names: false if there is no such recorder, or
    // if the identifier already names a display list.
    @cxx
    @implementation
    func swiftSinkDisplayListRecorderIntoDisplayList(
        _ identifier: WebKit.RemoteDisplayListRecorderIdentifier,
        _ displayListIdentifier: WebKit.RemoteDisplayListIdentifier
    ) -> Bool {
        let state = self.state
        let key = identifier.toUInt64()
        guard let displayListRecorder = state.displayListRecorders.removeValue(forKey: RemoteIdentifierKey(value: key)) else {
            return false
        }
        let stopped = streamConnection().tryStopReceivingMessages(.RemoteCGRenderer, key)
        let recorder = displayListRecorder.recorder
        let added = state.displayLists.add(recorder.takeRecording(), key: WebKit.displayListKey(displayListIdentifier))
        // A recorder that read video frames keeps the reader's state, which a new recorder doesn't have.
        if stopped, state.reusesDisplayListRecorders, !recorder.readVideoFrames,
            state.idleDisplayListRecorders.count < maximumIdleDisplayListRecorders
        {
            state.idleDisplayListRecorders.append(displayListRecorder)
        }
        return added
    }

    @cxx
    @implementation
    func swiftReleaseDisplayList(_ identifier: WebKit.RemoteDisplayListIdentifier) -> Bool {
        state.displayLists.remove(key: WebKit.displayListKey(identifier))
    }

    @cxx
    @implementation
    func swiftReleaseDisplayLists() {
        state.displayLists.removeAll()
    }

    var state: RemoteRenderingBackendState {
        let swiftState = swiftState()
        precondition(swiftState != 0, "RemoteRenderingBackend has no Swift state")
        // Safety: m_swiftState is a retained RemoteRenderingBackendState from swiftInitialize() to the destructor.
        return unsafe Unmanaged<RemoteRenderingBackendState>
            .fromOpaque(UnsafeRawPointer(bitPattern: swiftState) ?? noSwiftState())
            .takeUnretainedValue()
    }
}

private func noSwiftState<T>() -> T {
    preconditionFailure("RemoteRenderingBackend has no Swift state")
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
