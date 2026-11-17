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

import Synchronization
@_spi(WebKitGPU) internal import WebCore
import WebCore_Private
import WebKit_Internal

// A native image as RemoteCGRenderer draws it: the image, for the C++ that draws its pattern or reads it, and its platform
// image, which is nil for an image this process can't read, its size and its headroom, read once when it is cached. A
// recording keeps it as it was when the recording named it. A class, so that a lookup retains one object.
final class RemoteCGRendererImage {
    let nativeImage: WebCore.NativeImage
    let image: CGImage?
    let width: Float
    let height: Float
    let headroom: Float

    init(nativeImage: WebCore.NativeImage, image: CGImage?, width: Float, height: Float, headroom: Float) {
        self.nativeImage = nativeImage
        self.image = image
        self.width = width
        self.height = height
        self.headroom = headroom
    }
}

// The rendering backend's resources that its image buffers' receivers and its recorders look up, on its work queue: the
// receivers of its image buffers' messages, by identifier, its cached native images, and the filters that RemoteResourceCache
// caches for its C++ contexts, which its Swift draws keep their own state of (RemoteCGRendererCachedFilter).
final class RemoteRenderingBackendResources {
    private(set) var imageBuffers: [UInt64: RemoteImageBuffer] = [:]
    // The image buffer that the last lookup found, which the draws of one image buffer after another find without the
    // dictionary. Only while the receiver is in imageBuffers, so that it keeps the buffer no longer than the receiver does.
    private var lastFoundImageBuffer: (key: UInt64, imageBuffer: WebCore.ImageBuffer)?
    private var nativeImages: [RemoteIdentifierKey: RemoteCGRendererImage] = [:]
    private var filters: [RemoteIdentifierKey: RemoteCGRendererCachedFilter] = [:]

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

    // False if an image already has the key, or, where it replaces one, if none has. What it replaces or releases is
    // released after the change, so that no access to the dictionary can overlap another.
    func cacheNativeImage(_ image: RemoteCGRendererImage, key: UInt64, replaces: Bool) -> Bool {
        let key = RemoteIdentifierKey(value: key)
        guard (nativeImages.index(forKey: key) != nil) == replaces else {
            return false
        }
        let replaced = nativeImages.updateValue(image, forKey: key)
        withExtendedLifetime(replaced) {}
        return true
    }

    func releaseNativeImage(key: UInt64) -> Bool {
        let released = nativeImages.removeValue(forKey: RemoteIdentifierKey(value: key))
        return released != nil
    }

    func nativeImage(key: UInt64) -> RemoteCGRendererImage? {
        nativeImages[RemoteIdentifierKey(value: key)]
    }

    func removeAllNativeImages() {
        var removed: [RemoteIdentifierKey: RemoteCGRendererImage] = [:]
        swap(&nativeImages, &removed)
    }

    // RemoteResourceCache cached a filter under the key, which an SVG filter that a draw names is if it is one.
    func cacheFilter(key: UInt64, isSVGFilter: Bool) {
        filters[RemoteIdentifierKey(value: key)] = RemoteCGRendererCachedFilter(identifier: key, isSVGFilter: isSVGFilter)
    }

    func releaseFilter(key: UInt64) {
        filters.removeValue(forKey: RemoteIdentifierKey(value: key))
    }

    func filter(key: UInt64) -> RemoteCGRendererCachedFilter? {
        filters[RemoteIdentifierKey(value: key)]
    }

    func removeAllFilters() {
        var removed: [RemoteIdentifierKey: RemoteCGRendererCachedFilter] = [:]
        swap(&filters, &removed)
    }
}

// A recording that another thread let go of, for the work queue to release. @unchecked Sendable: only the work queue uses it
// after this.
private struct PendingRecordingRelease: @unchecked Sendable {
    let recording: RemoteCGRendererRecording
}

// The rendering backend's state in Swift, on its work queue: its resources, its display list recorders and snapshot recorders,
// by identifier, and the display lists that its contexts' DrawDisplayList messages name.
final class RemoteRenderingBackendState {
    let resources = RemoteRenderingBackendResources()
    var displayListRecorders: [RemoteIdentifierKey: DisplayListRecorder] = [:]
    var snapshotRecorders: [RemoteIdentifierKey: DisplayListRecorder] = [:]
    // The recordings of snapshot frames that other threads let go of (RemoteSnapshotFrameRecording), which any thread adds to.
    fileprivate let pendingReleases = Mutex<[PendingRecordingRelease]>([])
    // Recorders whose recordings became display lists, for the next recorders to reuse: a page makes many short display
    // lists, such as one for each run of text it caches, in each rendering update.
    var idleDisplayListRecorders: [DisplayListRecorder] = []
    // False once the backend is uninitialized, after which an idle recorder would keep the backend that its resources keep.
    var reusesDisplayListRecorders = true
    let displayLists: RemoteCGRendererDisplayLists
    // What its receivers and recorders read the web process's video frames with.
    let videoFrameSources: GPUVideoFrameSources

    init(videoFrameSources: GPUVideoFrameSources) {
        displayLists = RemoteCGRendererDisplayLists(backendResources: resources)
        self.videoFrameSources = videoFrameSources
    }

    var imageBuffers: [UInt64: RemoteImageBuffer] {
        resources.imageBuffers
    }

    func addImageBuffer(_ receiver: RemoteImageBuffer, key: UInt64) -> Bool {
        resources.addImageBuffer(receiver, key: key)
    }

    func removeImageBuffer(key: UInt64) -> RemoteImageBuffer? {
        resources.removeImageBuffer(key: key)
    }

    func removeAllImageBuffers() -> [UInt64: RemoteImageBuffer] {
        resources.removeAllImageBuffers()
    }

    func imageBuffer(key: UInt64) -> WebCore.ImageBuffer? {
        resources.imageBuffer(key: key)
    }
}

// A display list recorder and the forwarder of its messages, which the stream connection keeps while it receives them.
struct DisplayListRecorder {
    let recorder: RemoteCGRendererRecorder
    let forwarder: RefRemoteCGRendererRecorderMessageForwarder
}

private let maximumIdleDisplayListRecorders = 16

extension WebKit.RemoteRenderingBackend {
    // For GPUConnectionToWebProcess.swift, which adds the backend before it receives messages.
    func initializeSwiftState(videoFrameSources: GPUVideoFrameSources) {
        precondition(swiftState() == 0)
        let state = RemoteRenderingBackendState(videoFrameSources: videoFrameSources)
        // Safety: the state is new, and retained once, which only destroySwiftState() releases.
        unsafe setSwiftState(UInt(bitPattern: unsafe Unmanaged.passRetained(state).toOpaque()))
    }

    // Static, so that the destructor never retains the backend it destroys.
    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        // Safety: initializeSwiftState() retained the state at this address, and only the destructor releases it.
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
            _ = tryStopReceivingMessages(.RemoteCGRenderer, identifier.value)
        }
        let snapshotRecorders = state.snapshotRecorders
        state.snapshotRecorders = [:]
        for identifier in snapshotRecorders.keys {
            _ = tryStopReceivingMessages(.RemoteCGRenderer, identifier.value)
        }
        state.displayLists.removeAll()
        state.resources.removeAllNativeImages()
        // The filters' results are the work queue's, as RemoteResourceCache's filters are.
        state.resources.removeAllFilters()
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
        // Safety: m_swiftState is a retained RemoteRenderingBackendState from initializeSwiftState() to the destructor, which
        // doesn't run during the call.
        return unsafe Unmanaged<RemoteRenderingBackendState>
            .fromOpaque(UnsafeRawPointer(bitPattern: swiftState) ?? noSwiftState())
            ._withUnsafeGuaranteedRef { state in WebKit.RefPtrImageBuffer(state.imageBuffer(key: key)) }
    }

    @cxx
    @implementation
    func cachedNativeImage(_ identifier: WebCore.RenderingResourceIdentifier) -> WebKit.RefPtrNativeImage {
        WebKit.RefPtrNativeImage(state.resources.nativeImage(key: identifier.toUInt64())?.nativeImage)
    }

    @cxx
    @implementation
    func swiftCacheNativeImage(
        _ nativeImage: WebCore.NativeImage,
        _ image: CGImage?,
        _ width: Float,
        _ height: Float,
        _ headroom: Float,
        _ identifier: WebCore.RenderingResourceIdentifier,
        _ replaces: Bool
    ) -> Bool {
        let cached = RemoteCGRendererImage(nativeImage: nativeImage, image: image, width: width, height: height, headroom: headroom)
        return state.resources.cacheNativeImage(cached, key: identifier.toUInt64(), replaces: replaces)
    }

    @cxx
    @implementation
    func swiftReleaseNativeImage(_ identifier: WebCore.RenderingResourceIdentifier) -> Bool {
        state.resources.releaseNativeImage(key: identifier.toUInt64())
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
        let started = WebKit.tryStartReceivingSwiftMessages(
            self,
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

    private func makeDisplayListRecorder(
        _ state: RemoteRenderingBackendState,
        snapshotFrames: RemoteCGRendererSnapshotFrameReferences = .none
    ) -> DisplayListRecorder {
        let recorder = RemoteCGRendererRecorder(
            resources: WebKit.createDisplayListRecorderResources(self),
            displayLists: state.displayLists,
            videoFrameSources: state.videoFrameSources,
            snapshotFrames: snapshotFrames
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
        let stopped = tryStopReceivingMessages(.RemoteCGRenderer, key)
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
    func swiftCreateSnapshotRecorder(
        _ identifier: WebKit.RemoteSnapshotRecorderIdentifier,
        _ snapshot: WebKit.RemoteSnapshotKey
    ) -> Bool {
        let state = self.state
        let key = identifier.toUInt64()
        guard state.snapshotRecorders[RemoteIdentifierKey(value: key)] == nil else {
            return false
        }
        let snapshotRecorder = makeDisplayListRecorder(
            state,
            snapshotFrames: .snapshot(remoteSnapshots.snapshotForRecorder(RemoteSnapshotRegistryKey(snapshot)))
        )
        guard WebKit.tryStartReceivingSwiftMessages(self, snapshotRecorder.forwarder, .RemoteCGRenderer, key) else {
            return false
        }
        state.snapshotRecorders[RemoteIdentifierKey(value: key)] = snapshotRecorder
        return true
    }

    @cxx
    @implementation
    func swiftSinkSnapshotRecorderIntoSnapshotFrame(
        _ identifier: WebKit.RemoteSnapshotRecorderIdentifier,
        _ frameIdentifier: WebCore.FrameIdentifier
    ) -> Bool {
        let key = identifier.toUInt64()
        guard let snapshotRecorder = state.snapshotRecorders.removeValue(forKey: RemoteIdentifierKey(value: key)) else {
            return false
        }
        _ = tryStopReceivingMessages(.RemoteCGRenderer, key)
        let recorder = snapshotRecorder.recorder
        let recording = RemoteSnapshotFrameRecording(recording: recorder.takeRecording(), backend: self)
        recorder.snapshot?.setFrame(frameIdentifier.toUInt64(), recording)
        return true
    }

    // Lets go of a recording of a snapshot frame on the work queue, from any thread.
    func releaseOnWorkQueue(_ recording: RemoteCGRendererRecording) {
        let release = PendingRecordingRelease(recording: recording)
        state.pendingReleases.withLock { $0.append(release) }
        scheduleSwiftReleases()
    }

    @cxx
    @implementation
    func swiftReleasePendingRecordings() {
        let released = state.pendingReleases.withLock { pendingReleases in
            var released: [PendingRecordingRelease] = []
            swap(&released, &pendingReleases)
            return released
        }
        withExtendedLifetime(released) {}
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

    @cxx
    @implementation
    func swiftCacheFilter(_ identifier: WebCore.RenderingResourceIdentifier, _ isSVGFilter: Bool) {
        state.resources.cacheFilter(key: identifier.toUInt64(), isSVGFilter: isSVGFilter)
    }

    @cxx
    @implementation
    func swiftReleaseFilter(_ identifier: WebCore.RenderingResourceIdentifier) {
        state.resources.releaseFilter(key: identifier.toUInt64())
    }

    @cxx
    @implementation
    func swiftReleaseFilters() {
        state.resources.removeAllFilters()
    }

    var state: RemoteRenderingBackendState {
        let swiftState = swiftState()
        precondition(swiftState != 0, "RemoteRenderingBackend has no Swift state")
        // Safety: m_swiftState is a retained RemoteRenderingBackendState from initializeSwiftState() to the destructor.
        return unsafe Unmanaged<RemoteRenderingBackendState>
            .fromOpaque(UnsafeRawPointer(bitPattern: swiftState) ?? noSwiftState())
            .takeUnretainedValue()
    }
}

private func noSwiftState<T>() -> T {
    preconditionFailure("RemoteRenderingBackend has no Swift state")
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
