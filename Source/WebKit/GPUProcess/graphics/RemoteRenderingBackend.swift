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

import Dispatch
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
// receivers of its image buffers' messages, by identifier, its cached native images, and its other cached resources.
final class RemoteRenderingBackendResources {
    let cache = RemoteResourceCache()
    private(set) var imageBuffers: [UInt64: RemoteImageBuffer] = [:]
    // The image buffer that the last lookup found, which the draws of one image buffer after another find without the
    // dictionary. Only while the receiver is in imageBuffers, so that it keeps the buffer no longer than the receiver does.
    private var lastFoundImageBuffer: (key: UInt64, imageBuffer: WebCore.ImageBuffer)?
    private var nativeImages: [RemoteIdentifierKey: RemoteCGRendererImage] = [:]

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
    // The receivers of the backend's image buffer sets' messages, which stop receiving them when they leave.
    #if ENABLE_GPU_PROCESS_IMAGE_BUFFER_SET_SWIFT
    var imageBufferSets: [RemoteIdentifierKey: RemoteImageBufferSet] = [:]
    #else
    var imageBufferSets: [RemoteIdentifierKey: WebKit.RemoteImageBufferSet] = [:]
    #endif
    // Which buffer sets of the last PrepareImageBufferSetsForDisplaySync need display, kept for the next, so that each rendering
    // update reuses its storage.
    var setsNeedingDisplay: [Bool] = []
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

    // Ends every receiver, which releases the references that they and the recorders' resources hold to this, empties the
    // display lists and the caches, which the work queue fills, and stops the stream connection.
    @cxx
    @implementation
    func workQueueUninitialize() {
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
        let imageBufferSets = state.imageBufferSets
        state.imageBufferSets = [:]
        for imageBufferSet in imageBufferSets.values {
            imageBufferSet.stopListeningForIPC()
        }
        state.resources.releaseAllCachedResources()
        let connection = streamConnection()
        connection.stopReceivingMessages(.RemoteRenderingBackend, identifier().toUInt64())
        connection.invalidate()
    }

    func addImageBuffer(
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
    func takeImageBuffer(_ identifier: WebCore.RenderingResourceIdentifier) -> WebKit.RefPtrImageBuffer {
        guard let receiver = state.removeImageBuffer(key: identifier.toUInt64()) else {
            return WebKit.RefPtrImageBuffer(nil)
        }
        receiver.stopReceivingMessages()
        return WebKit.RefPtrImageBuffer(receiver.imageBuffer)
    }

    private func removeImageBuffer(_ identifier: WebCore.RenderingResourceIdentifier) -> Bool {
        guard let receiver = state.removeImageBuffer(key: identifier.toUInt64()) else {
            return false
        }
        receiver.stopReceivingMessages()
        return true
    }

    @cxx
    @implementation
    func imageBuffer(_ identifier: WebCore.RenderingResourceIdentifier) -> WebKit.RefPtrImageBuffer {
        assertIsOnWorkQueue()
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
        assertIsOnWorkQueue()
        return WebKit.RefPtrNativeImage(state.resources.nativeImage(key: identifier.toUInt64())?.nativeImage)
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

    private func removeNativeImage(_ identifier: WebCore.RenderingResourceIdentifier) -> Bool {
        state.resources.releaseNativeImage(key: identifier.toUInt64())
    }

    // A recorder of the RemoteCGRenderer messages to it, as RemoteGraphicsContext records them into a WebCore display list
    // recorder: false if one already has the identifier.
    private func addDisplayListRecorder(_ identifier: WebKit.RemoteDisplayListRecorderIdentifier) -> Bool {
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
            resources: RemoteCGRendererResources(recorderOf: self),
            displayLists: state.displayLists,
            videoFrameSources: state.videoFrameSources,
            snapshotFrames: snapshotFrames
        )
        return DisplayListRecorder(recorder: recorder, forwarder: RemoteCGRendererRecorder.createMessageReceiver(recorder: recorder))
    }

    // Makes what the recorder recorded the display list that the identifier names: false if there is no such recorder, or
    // if the identifier already names a display list.
    private func sinkDisplayListRecorder(
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
        let added = state.displayLists.add(recorder.takeRecording(), key: displayListIdentifier.toUInt64())
        // A recorder that read video frames keeps the reader's state, which a new recorder doesn't have.
        if stopped, state.reusesDisplayListRecorders, !recorder.readVideoFrames,
            state.idleDisplayListRecorders.count < maximumIdleDisplayListRecorders
        {
            state.idleDisplayListRecorders.append(displayListRecorder)
        }
        return added
    }

    private func addSnapshotRecorder(
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

    private func sinkSnapshotRecorder(
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

    private func removeDisplayList(_ identifier: WebKit.RemoteDisplayListIdentifier) -> Bool {
        state.displayLists.remove(key: identifier.toUInt64())
    }

    @cxx
    @implementation
    func paintNativeImageToImageBuffer(_ nativeImage: WebCore.NativeImage, _ imageBufferIdentifier: WebCore.RenderingResourceIdentifier) {
        performOnWorkQueueAndWait {
            guard let imageBuffer = self.imageBuffer(imageBufferIdentifier).get() else {
                return
            }
            let canvasRect = WebCore.FloatRect(WebCore.FloatPoint(), WebCore.FloatSize(imageBuffer.backendSize()))
            let imageRect = WebCore.FloatRect(WebCore.FloatPoint(), WebCore.FloatSize(nativeImage.size()))
            let drawing = WebCore.ImageBufferDrawing(imageBuffer)
            let context = drawing.context()
            context.save()
            context.setImageInterpolationQuality(.DoNotInterpolate)
            context.drawNativeImage(nativeImage, canvasRect, imageRect, .Copy)
            context.restore()
            imageBuffer.flushDrawingContext()
        }
    }

    // The backend's registries and caches are its work queue's (assertIsCurrent(workQueue())).
    func assertIsOnWorkQueue() {
        #if ASSERT_ENABLED
        assert(workQueue().isCurrent())
        #endif
    }

    // Runs the work on the work queue, from another thread, which waits for it.
    func performOnWorkQueueAndWait(_ work: @escaping () -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        dispatchBlock {
            work()
            semaphore.signal()
        }
        semaphore.wait()
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

// The backend's messages, on its work queue. A failed message check marks the message invalid, as the C++ handlers' did.
extension WebKit.RemoteRenderingBackend {
    private func handleMessage(_ body: () throws(InvalidMessage) -> Void) {
        do {
            try body()
        } catch {
            markMessageInvalid(error, on: streamConnection())
        }
    }

    @cxx
    @implementation
    func createImageBuffer(
        _ logicalSize: WebCore.FloatSize,
        _ renderingMode: WebCore.RenderingMode,
        _ purpose: WebCore.RenderingPurpose,
        _ resolutionScale: Float,
        _ colorSpace: WebCore.ColorSpace,
        _ bufferFormat: WebCore.ImageBufferFormat,
        _ identifier: WebCore.RenderingResourceIdentifier,
        _ contextIdentifier: WebKit.RemoteGraphicsContextIdentifier
    ) {
        let imageBuffer = allocateImageBuffer(
            logicalSize,
            renderingMode,
            purpose,
            resolutionScale,
            colorSpace,
            bufferFormat,
            WebCore.ImageBufferCreationContext()
        )
        addAllocatedImageBuffer(imageBuffer, identifier, contextIdentifier)
    }

    @cxx
    @implementation
    func swiftCreateMappableImageBuffer(
        _ logicalSize: WebCore.FloatSize,
        _ renderingMode: WebCore.RenderingMode,
        _ purpose: WebCore.RenderingPurpose,
        _ resolutionScale: Float,
        _ colorSpace: WebCore.ColorSpace,
        _ bufferFormat: WebCore.ImageBufferFormat,
        _ bitmap: WebKit.ShareableBitmapHandleBox?,
        _ identifier: WebCore.RenderingResourceIdentifier,
        _ contextIdentifier: WebKit.RemoteGraphicsContextIdentifier
    ) {
        var imageBuffer = WebKit.RefPtrImageBuffer(nil)
        // Backing store the web process allocated is adopted as-is. Its geometry is attacker-controlled, so the backend validates
        // it against what was requested and fails the allocation rather than drawing into a surface of the wrong shape. The
        // rendering mode is not adjusted here: the backing store must be used as given, or none at all. Only an unaccelerated
        // buffer has a backing store that the web process can hand over.
        if checkImageBufferRenderingMode(renderingMode), !reachedCanvasLimit(purpose), renderingMode == .Unaccelerated, let bitmap {
            imageBuffer = WebKit.RemoteRenderingBackend.createImageBufferAdoptingBitmap(
                logicalSize,
                resolutionScale,
                colorSpace,
                bufferFormat,
                purpose,
                imageBufferCreationContext(),
                bitmap
            )
        }
        addAllocatedImageBuffer(imageBuffer, identifier, contextIdentifier)
    }

    // On failure to create a remote image buffer a null one still receives the drawing that the web process may already have
    // sent it.
    private func addAllocatedImageBuffer(
        _ allocated: WebKit.RefPtrImageBuffer,
        _ identifier: WebCore.RenderingResourceIdentifier,
        _ contextIdentifier: WebKit.RemoteGraphicsContextIdentifier
    ) {
        var imageBuffer = allocated.get()
        if imageBuffer == nil {
            WebKit.LogChannel.RemoteLayerBuffers().releaseLog.log(
                "[renderingBackend=\(self.identifier().toUInt64())] RemoteRenderingBackend::createImageBuffer - failed to allocate image buffer \(identifier.toUInt64())"
            )
            imageBuffer = makeNullImageBuffer()
            sendDidFailToCreateBackend(identifier)
        }
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Duplicate ImageBuffers") {
                imageBuffer.map { addImageBuffer($0, identifier, contextIdentifier) } ?? false
            }
        }
    }

    private func makeNullImageBuffer() -> WebCore.ImageBuffer {
        guard let imageBuffer = WebCore.createNullImageBuffer().get() else {
            preconditionFailure("A null image buffer could not be created")
        }
        return imageBuffer
    }

    // PDF documents and display lists are drawn through contexts that are not ImageBuffers. This also covers the configurations
    // of image buffer sets. Marks the message invalid otherwise.
    private func checkImageBufferRenderingMode(_ renderingMode: WebCore.RenderingMode) -> Bool {
        do {
            try messageCheck("renderingMode != RenderingMode::PDFDocument && renderingMode != RenderingMode::DisplayList") {
                renderingMode != .PDFDocument && renderingMode != .DisplayList
            }
        } catch {
            markMessageInvalid(error, on: streamConnection())
            return false
        }
        return true
    }

    private func reachedCanvasLimit(_ purpose: WebCore.RenderingPurpose) -> Bool {
        purpose == .Canvas && sharedResourceCache().reachedImageBufferForCanvasLimit()
    }

    private func imageBufferCreationContext(_ base: WebCore.ImageBufferCreationContext = WebCore.ImageBufferCreationContext())
        -> WebCore.ImageBufferCreationContext
    {
        var creationContext = base
        WebKit.RemoteRenderingBackend.adjustImageBufferCreationContext(sharedResourceCache(), &creationContext)
        return creationContext
    }

    @cxx
    @implementation
    func allocateImageBuffer(
        _ logicalSize: WebCore.FloatSize,
        _ requestedRenderingMode: WebCore.RenderingMode,
        _ purpose: WebCore.RenderingPurpose,
        _ resolutionScale: Float,
        _ colorSpace: WebCore.ColorSpace,
        _ bufferFormat: WebCore.ImageBufferFormat,
        _ creationContext: WebCore.ImageBufferCreationContext
    ) -> WebKit.RefPtrImageBuffer {
        assertIsOnWorkQueue()
        guard checkImageBufferRenderingMode(requestedRenderingMode), !reachedCanvasLimit(purpose) else {
            return WebKit.RefPtrImageBuffer(nil)
        }
        var renderingMode = requestedRenderingMode
        if renderingMode == .Accelerated,
            sharedResourceCache().reachedAcceleratedImageBufferLimit(purpose, acceleratedImageBufferLimit())
        {
            renderingMode = .Unaccelerated
        }
        return makeImageBuffer(
            logicalSize,
            renderingMode,
            purpose,
            resolutionScale,
            colorSpace,
            bufferFormat,
            imageBufferCreationContext(creationContext)
        )
    }

    @cxx
    @implementation
    func releaseImageBuffer(_ identifier: WebCore.RenderingResourceIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Missing ImageBuffer") { removeImageBuffer(identifier) }
        }
    }

    // The buffer, which nothing else may have, leaves its receiver.
    private func takeUnsharedImageBuffer(_ identifier: WebCore.RenderingResourceIdentifier) throws(InvalidMessage) -> WebKit.RefPtrImageBuffer {
        let imageBuffer = takeImageBuffer(identifier)
        try messageCheck("Missing ImageBuffer") { imageBuffer.get() != nil }
        try messageCheck("ImageBuffer in use") { WebKit.RemoteRenderingBackend.hasOnlyReference(imageBuffer) }
        return imageBuffer
    }

    @cxx
    @implementation
    func sinkImageBufferIntoNativeImage(
        _ identifier: WebCore.RenderingResourceIdentifier,
        _ imageIdentifier: WebCore.RenderingResourceIdentifier
    ) {
        handleMessage { () throws(InvalidMessage) in
            // Like releaseImageBuffer(), the buffer is gone after this. The web process does not release it again.
            var imageBuffer = try takeUnsharedImageBuffer(identifier)
            // The buffer may have failed to allocate.
            let image = WebKit.RemoteRenderingBackend.sinkIntoNativeImage(&imageBuffer).get()
                ?? WebKit.RemoteRenderingBackend.createPlaceholderNativeImage().get()
            try messageCheck("NativeImage could not be created") { image != nil }
            try messageCheck("NativeImage already exists") {
                image.map { putNativeImageInCache($0, imageIdentifier, false) } ?? false
            }
        }
    }

    @cxx
    @implementation
    static func createPlaceholderNativeImage() -> WebKit.RefPtrNativeImage {
        var imageBuffer = WebCore.ImageBuffer.create(WebCore.FloatSize(1, 1), .Unaccelerated, .Unspecified, 1, WebCore.GraphicsContextSwiftBridge.sRGBColorSpace(), .BGRA8)
        return WebKit.RemoteRenderingBackend.sinkIntoNativeImage(&imageBuffer)
    }

    @cxx
    @implementation
    func moveToSerializedBuffer(
        _ identifier: WebCore.RenderingResourceIdentifier,
        _ serializedIdentifier: WebKit.RemoteSerializedImageBufferIdentifier
    ) {
        handleMessage { () throws(InvalidMessage) in
            // This transfers ownership of the RemoteImageBuffer contents to the transfer heap.
            var imageBuffer = try takeUnsharedImageBuffer(identifier)
            try messageCheck("Duplicate SerializedImageBuffer") {
                // Avoid leaking cross-RemoteRenderingBackend state through context by releasing the context.
                WebKit.RemoteRenderingBackend.addSerializedImageBuffer(sharedResourceCache(), serializedIdentifier, &imageBuffer)
            }
        }
    }

    @cxx
    @implementation
    func moveToImageBuffer(
        _ identifier: WebKit.RemoteSerializedImageBufferIdentifier,
        _ imageBufferIdentifier: WebCore.RenderingResourceIdentifier,
        _ contextIdentifier: WebKit.RemoteGraphicsContextIdentifier
    ) {
        handleMessage { () throws(InvalidMessage) in
            let imageBuffer = sharedResourceCache().takeSerializedImageBuffer(identifier).get()
            try messageCheck("Missing SerializedImageBuffer") { imageBuffer != nil }
            guard let imageBuffer else {
                return
            }
            imageBuffer.transferToNewContext(imageBufferCreationContext())
            try messageCheck("Duplicate ImageBuffer") { addImageBuffer(imageBuffer, imageBufferIdentifier, contextIdentifier) }
        }
    }

    @cxx
    @implementation
    func moveSerializedBufferToTransferHeap(
        _ serializedIdentifier: WebKit.RemoteSerializedImageBufferIdentifier,
        _ completionHandler: WebKit.MoveSerializedBufferToTransferHeapCompletionHandler?
    ) {
        var result = WebKit.OptionalImageBufferTransferIdentifier()
        handleMessage { () throws(InvalidMessage) in
            var imageBuffer = sharedResourceCache().takeSerializedImageBuffer(serializedIdentifier)
            try messageCheck("Missing SerializedImageBuffer") { imageBuffer.get() != nil }
            result = WebKit.RemoteRenderingBackend.depositTransferredImageBuffer(
                gpuConnectionToWebProcess().webProcessIdentifier(),
                &imageBuffer
            )
        }
        // The identifier exists only once the buffer has been deposited, so a claim made with it can never arrive too early.
        if let completionHandler {
            completionHandler.pointee(result)
        }
    }

    @cxx
    @implementation
    func takeTransferredBuffer(
        _ handle: WebCore.ImageBufferTransferHandle,
        _ imageBufferIdentifier: WebCore.RenderingResourceIdentifier,
        _ contextIdentifier: WebKit.RemoteGraphicsContextIdentifier
    ) {
        guard let imageBuffer = WebKit.RemoteRenderingBackend.takeTransferredImageBuffer(handle).get() else {
            // Discarded along with the process that owned it, claimed already by a process that was given the same identifier,
            // or misdescribed by the sender.
            WebKit.LogChannel.RemoteLayerBuffers().releaseLog.log(
                "[renderingBackend=\(self.identifier().toUInt64())] RemoteRenderingBackend::takeTransferredBuffer - no buffer to take for image buffer \(imageBufferIdentifier.toUInt64())"
            )
            let nullImageBuffer = makeNullImageBuffer()
            sendDidFailToCreateBackend(imageBufferIdentifier)
            handleMessage { () throws(InvalidMessage) in
                try messageCheck("Duplicate ImageBuffer") { addImageBuffer(nullImageBuffer, imageBufferIdentifier, contextIdentifier) }
            }
            return
        }
        var creationContext = imageBufferCreationContext()
        // The sender may have kept a send right to the surface, and could then alias it in a buffer of its own with
        // CreateMappableImageBuffer.
        WebKit.RemoteRenderingBackend.clearSurfacePool(&creationContext)
        imageBuffer.transferToNewContext(creationContext)
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Duplicate ImageBuffer") { addImageBuffer(imageBuffer, imageBufferIdentifier, contextIdentifier) }
        }
    }

    @cxx
    @implementation
    func createDisplayListRecorder(_ identifier: WebKit.RemoteDisplayListRecorderIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Recorder already created") { addDisplayListRecorder(identifier) }
        }
    }

    @cxx
    @implementation
    func sinkDisplayListRecorderIntoDisplayList(
        _ identifier: WebKit.RemoteDisplayListRecorderIdentifier,
        _ displayListIdentifier: WebKit.RemoteDisplayListIdentifier
    ) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Recorder sunk into display list before being cached, or display list already created") {
                sinkDisplayListRecorder(identifier, displayListIdentifier)
            }
        }
    }

    @cxx
    @implementation
    func releaseDisplayList(_ identifier: WebKit.RemoteDisplayListIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Display list released before being cached") { removeDisplayList(identifier) }
        }
    }

    @cxx
    @implementation
    func nativeImageBitmap(
        _ imageIdentifier: WebCore.RenderingResourceIdentifier,
        _ completionHandler: WebKit.NativeImageBitmapCompletionHandler?
    ) {
        var handle = WebKit.OptionalShareableBitmapHandle()
        if let image = state.resources.nativeImage(key: imageIdentifier.toUInt64())?.nativeImage {
            handle = createBitmapHandleReplacingPlatformImage(image)
            // Swift draws the image that replaced the native image's platform image from now on.
            if WebKit.RemoteRenderingBackend.hasHandle(handle) {
                let replaced = putNativeImageInCache(image, imageIdentifier, true)
                assert(replaced)
            }
        } else {
            handleMessage { () throws(InvalidMessage) in
                try messageCheck("NativeImage not cached.") { false }
            }
        }
        assert(WebKit.RemoteRenderingBackend.hasHandle(handle))
        if let completionHandler {
            WebKit.complete(completionHandler, consuming: handle)
        }
    }

    @cxx
    @implementation
    func swiftCacheNativeImageFromBitmap(_ bitmap: WebCore.ShareableBitmap?, _ imageIdentifier: WebCore.RenderingResourceIdentifier) {
        guard let bitmap, let image = WebKit.RemoteRenderingBackend.createNativeImage(bitmap).get() else {
            return
        }
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("NativeImage already cached.") { putNativeImageInCache(image, imageIdentifier, false) }
        }
    }

    @cxx
    @implementation
    func swiftCacheSharedNativeImage(_ identifier: WebCore.RenderingResourceIdentifier, _ found: Bool, _ image: WebCore.NativeImage?) {
        // Another stream connection publishes the image, possibly on this work queue. Wait without blocking the queue.
        guard found else {
            streamConnection().markCurrentlyDispatchedMessageAsDeferred()
            return
        }
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Shared NativeImage not found.") { image != nil }
            try messageCheck("NativeImage already cached.") {
                image.map { putNativeImageInCache($0, identifier, false) } ?? false
            }
        }
    }

    @cxx
    @implementation
    func releaseNativeImage(_ identifier: WebCore.RenderingResourceIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("NativeImage released before being cached.") { removeNativeImage(identifier) }
        }
    }

    @cxx
    @implementation
    func cachePathImpl(_ path: WebKit.RefPathImpl, _ identifier: WebKit.RemotePathImplIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Path already cached.") { state.resources.cachePathImpl(path.get(), key: identifier.toUInt64()) }
        }
    }

    @cxx
    @implementation
    func releasePathImpl(_ identifier: WebKit.RemotePathImplIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Path released before being cached.") { state.resources.releasePathImpl(key: identifier.toUInt64()) }
        }
    }

    @cxx
    @implementation
    func cacheGradient(_ gradient: WebKit.RefGradient, _ identifier: WebKit.RemoteGradientIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Gradient already cached.") { state.resources.cacheGradient(gradient.get(), key: identifier.toUInt64()) }
        }
    }

    @cxx
    @implementation
    func releaseGradient(_ identifier: WebKit.RemoteGradientIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Gradient released before being cached.") { state.resources.releaseGradient(key: identifier.toUInt64()) }
        }
    }

    @cxx
    @implementation
    func cacheMeshGradient(_ gradient: WebKit.RefMeshGradient, _ identifier: WebKit.RemoteMeshGradientIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Mesh gradient already cached.") {
                state.resources.cacheMeshGradient(gradient.get(), key: identifier.toUInt64())
            }
        }
    }

    @cxx
    @implementation
    func releaseMeshGradient(_ identifier: WebKit.RemoteMeshGradientIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Mesh gradient released before being cached.") {
                state.resources.releaseMeshGradient(key: identifier.toUInt64())
            }
        }
    }

    @cxx
    @implementation
    func cacheFilter(_ filter: WebKit.RefFilter) {
        handleMessage { () throws(InvalidMessage) in
            let filter = filter.get()
            try messageCheck("Received a Filter without a valid resource identifier.") { filter.hasValidRenderingResourceIdentifier() }
            try messageCheck("Filter already cached.") {
                state.resources.cacheFilter(filter, key: filter.renderingResourceIdentifier().toUInt64())
            }
        }
    }

    @cxx
    @implementation
    func releaseFilter(_ identifier: WebCore.RenderingResourceIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Filter released before being cached.") { state.resources.releaseFilter(key: identifier.toUInt64()) }
        }
    }

    @cxx
    @implementation
    func cacheFont(
        _ fontAttributes: WebCore.FontInternalAttributes,
        _ platformData: WebCore.FontPlatformDataAttributes,
        _ fontCustomPlatformDataIdentifier: WebKit.OptionalRenderingResourceIdentifier
    ) {
        handleMessage { () throws(InvalidMessage) in
            var customPlatformData: WebCore.FontCustomPlatformData?
            if let customIdentifier = fontCustomPlatformDataIdentifier.value {
                customPlatformData = state.resources.cachedFontCustomPlatformData(key: customIdentifier.toUInt64())
                try messageCheck("CacheFont without caching custom data") { customPlatformData != nil }
            }
            var key: UInt64 = 0
            let font = WebKit.RemoteRenderingBackend.createFont(fontAttributes, platformData, customPlatformData, &key)
            try messageCheck("Font already cached.") { state.resources.cacheFont(RemoteCGRendererFont(sharedFont: font.get()), key: key) }
        }
    }

    @cxx
    @implementation
    func releaseFont(_ identifier: WebCore.RenderingResourceIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Font released before being cached.") { state.resources.releaseFont(key: identifier.toUInt64()) }
        }
    }

    @cxx
    @implementation
    func swiftCacheFontCustomPlatformData(_ customPlatformData: WebCore.FontCustomPlatformData?, _ key: UInt64) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("cacheFontCustomPlatformData couldn't deserialize FontCustomPlatformData") { customPlatformData != nil }
            guard let customPlatformData else {
                return
            }
            try messageCheck("FontCustomPlatformData already cached.") {
                state.resources.cacheFontCustomPlatformData(customPlatformData, key: key)
            }
        }
    }

    @cxx
    @implementation
    func releaseFontCustomPlatformData(_ identifier: WebCore.RenderingResourceIdentifier) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("FontCustomPlatformData released before being cached.") {
                state.resources.releaseFontCustomPlatformData(key: identifier.toUInt64())
            }
        }
    }

    @cxx
    @implementation
    func releaseMemory() {
        state.resources.releaseMemoryCaches()
        state.displayLists.removeAll()
    }

    @cxx
    @implementation
    func createImageBufferSet(_ identifier: WebKit.ImageBufferSetIdentifier, _ contextIdentifier: WebKit.RemoteGraphicsContextIdentifier) {
        let state = self.state
        let key = RemoteIdentifierKey(value: identifier.toUInt64())
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Duplicate ImageBufferSet") { state.imageBufferSets[key] == nil }
            #if ENABLE_GPU_PROCESS_IMAGE_BUFFER_SET_SWIFT
            let imageBufferSet = RemoteImageBufferSet.create(identifier: identifier, contextIdentifier: contextIdentifier, backend: self)
            try messageCheck("Another receiver has the ImageBufferSet's identifier") { imageBufferSet != nil }
            state.imageBufferSets[key] = imageBufferSet
            #else
            state.imageBufferSets[key] = WebKit.RemoteImageBufferSet.create(identifier, contextIdentifier, self).get()
            #endif
        }
    }

    @cxx
    @implementation
    func releaseImageBufferSet(_ identifier: WebKit.ImageBufferSetIdentifier) {
        let imageBufferSet = state.imageBufferSets.removeValue(forKey: RemoteIdentifierKey(value: identifier.toUInt64()))
        imageBufferSet?.stopListeningForIPC()
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Missing ImageBufferSet") { imageBufferSet != nil }
        }
    }

    #if ENABLE_GPU_PROCESS_IMAGE_BUFFER_SET_SWIFT
    private typealias ImageBufferSet = RemoteImageBufferSet
    #else
    private typealias ImageBufferSet = WebKit.RemoteImageBufferSet
    #endif

    private func imageBufferSet(_ identifier: WebKit.ImageBufferSetIdentifier, _ reason: StaticString) throws(InvalidMessage)
        -> ImageBufferSet
    {
        let imageBufferSet = state.imageBufferSets[RemoteIdentifierKey(value: identifier.toUInt64())]
        try messageCheck(reason) { imageBufferSet != nil }
        guard let imageBufferSet else {
            preconditionFailure("The message check failed")
        }
        return imageBufferSet
    }

    @cxx
    @implementation
    @unsafe
    func swiftPrepareImageBufferSetsForDisplay(_ inputs: inout WebKit.ImageBufferSetPrepareBufferForDisplayInputs) {
        handleMessage { () throws(InvalidMessage) in
            for index in 0..<inputs.size() {
                let imageBufferSet = try imageBufferSet(inputs[index].remoteBufferSet, "BufferSet is being updated before being created")
                #if ENABLE_GPU_PROCESS_IMAGE_BUFFER_SET_SWIFT
                let displayRequirement = imageBufferSet.ensureBufferForDisplay(&inputs[index], isSync: false)
                if displayRequirement != .NeedsNoDisplay {
                    imageBufferSet.prepareBufferForDisplay(dirtyRegion: inputs[index].dirtyRegion, requiresClearedPixels: inputs[index].requiresClearedPixels)
                }
                #else
                let displayRequirement = imageBufferSet.ensureBufferForDisplay(&inputs[index], false)
                if displayRequirement != .NeedsNoDisplay {
                    imageBufferSet.prepareBufferForDisplay(inputs[index].dirtyRegion, inputs[index].requiresClearedPixels)
                }
                #endif
            }
        }
    }

    @cxx
    @implementation
    @unsafe
    func swiftEnsureBuffersForDisplay(
        _ inputs: inout WebKit.ImageBufferSetPrepareBufferForDisplayInputs,
        _ requirements: inout WebKit.SwapBuffersDisplayRequirements
    ) -> Bool {
        let state = self.state
        state.setsNeedingDisplay.removeAll(keepingCapacity: true)
        var isValid = false
        handleMessage { () throws(InvalidMessage) in
            for index in 0..<inputs.size() {
                let imageBufferSet = try imageBufferSet(inputs[index].remoteBufferSet, "BufferSet is being updated before being created")
                #if ENABLE_GPU_PROCESS_IMAGE_BUFFER_SET_SWIFT
                let requirement = imageBufferSet.ensureBufferForDisplay(&inputs[index], isSync: true)
                #else
                let requirement = imageBufferSet.ensureBufferForDisplay(&inputs[index], true)
                #endif
                requirements[index] = requirement
                state.setsNeedingDisplay.append(requirement != .NeedsNoDisplay)
            }
            isValid = true
        }
        return isValid
    }

    @cxx
    @implementation
    @unsafe
    func swiftPrepareBuffersForDisplay(_ inputs: inout WebKit.ImageBufferSetPrepareBufferForDisplayInputs) {
        let state = self.state
        handleMessage { () throws(InvalidMessage) in
            for index in 0..<inputs.size() where state.setsNeedingDisplay[index] {
                let imageBufferSet = try imageBufferSet(inputs[index].remoteBufferSet, "BufferSet is being updated before being created")
                #if ENABLE_GPU_PROCESS_IMAGE_BUFFER_SET_SWIFT
                imageBufferSet.prepareBufferForDisplay(dirtyRegion: inputs[index].dirtyRegion, requiresClearedPixels: inputs[index].requiresClearedPixels)
                #else
                imageBufferSet.prepareBufferForDisplay(inputs[index].dirtyRegion, inputs[index].requiresClearedPixels)
                #endif
            }
        }
    }

    @cxx
    @implementation
    func markSurfacesVolatile(
        _ requestIdentifier: WebKit.MarkSurfacesAsVolatileRequestIdentifier,
        _ identifiers: WebKit.ImageBufferSetVolatileBuffers,
        _ forcePurge: Bool
    ) {
        let count = identifiers.size()
        var markedBufferSets = WebKit.ImageBufferSetVolatileBuffers()
        var allSucceeded = true
        var isValid = false
        handleMessage { () throws(InvalidMessage) in
            for index in 0..<count {
                let setIdentifier = identifiers[index].first
                let requestedBuffers = identifiers[index].second
                let imageBufferSet = try imageBufferSet(setIdentifier, "BufferSet is being marked volatile before being created")
                try messageCheck("BufferSet is being marked volatile while preparing for display") {
                    !imageBufferSet.isPreparingForDisplay()
                }
                #if ENABLE_GPU_PROCESS_IMAGE_BUFFER_SET_SWIFT
                let (volatileBuffers, succeeded) = imageBufferSet.makeBuffersVolatile(requestedBuffers.toRaw(), forcePurge: forcePurge)
                if !succeeded {
                    allSucceeded = false
                }
                if volatileBuffers != 0 {
                    WebKit.RemoteRenderingBackend.appendRawVolatileBuffers(&markedBufferSets, setIdentifier, volatileBuffers)
                }
                #else
                var volatileBuffers = WebKit.OptionSetBufferInSetType()
                if !imageBufferSet.makeBuffersVolatile(requestedBuffers, &volatileBuffers, forcePurge) {
                    allSucceeded = false
                }
                if !volatileBuffers.isEmpty() {
                    WebKit.RemoteRenderingBackend.appendVolatileBuffers(&markedBufferSets, setIdentifier, volatileBuffers)
                }
                #endif
            }
            isValid = true
        }
        guard isValid else {
            return
        }
        sendDidMarkLayersAsVolatile(requestIdentifier, consuming: consume markedBufferSets, allSucceeded)
    }

    @cxx
    @implementation
    func createSnapshot(
        _ snapshotIdentifier: WebKit.RemoteSnapshotIdentifier,
        _ rootFrameIdentifier: WebCore.FrameIdentifier,
        _ size: WebCore.FloatSize,
        _ completionHandler: WebKit.CreateSnapshotCompletionHandler?
    ) {
        WebKit.GPUProcess.singleton().createSnapshot(
            snapshotIdentifier,
            rootFrameIdentifier,
            size,
            gpuConnectionToWebProcess().webProcessIdentifier()
        )
        if let completionHandler {
            completionHandler.pointee()
        }
    }

    @cxx
    @implementation
    func createSnapshotRecorder(
        _ identifier: WebKit.RemoteSnapshotRecorderIdentifier,
        _ snapshotIdentifier: WebKit.RemoteSnapshotIdentifier
    ) {
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Recorder already created") { addSnapshotRecorder(identifier, WebKit.snapshotKey(snapshotIdentifier)) }
        }
    }

    @cxx
    @implementation
    func sinkSnapshotRecorderIntoSnapshotFrame(
        _ identifier: WebKit.RemoteSnapshotRecorderIdentifier,
        _ frameIdentifier: WebCore.FrameIdentifier,
        _ completionHandler: WebKit.SinkSnapshotRecorderIntoSnapshotFrameCompletionHandler?
    ) {
        // FIXME: using global identifiers (frameIdentifier) is not secure. Do not follow this pattern.
        handleMessage { () throws(InvalidMessage) in
            try messageCheck("Recorder sunk into snapshot before being cached") { sinkSnapshotRecorder(identifier, frameIdentifier) }
            if let completionHandler {
                completionHandler.pointee(true)
            }
        }
    }

    @cxx
    @implementation
    func getImageBufferResourceLimitsForTesting(_ completionHandler: WebKit.GetImageBufferResourceLimitsForTestingCompletionHandler?) {
        let limits = sharedResourceCache().getResourceLimitsForTesting(acceleratedImageBufferLimit())
        if let completionHandler {
            completionHandler.pointee(limits)
        }
    }
}

private func noSwiftState<T>() -> T {
    preconditionFailure("RemoteRenderingBackend has no Swift state")
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
