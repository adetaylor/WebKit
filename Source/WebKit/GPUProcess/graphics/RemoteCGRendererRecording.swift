// Copyright (C) 2021-2024 Apple Inc. All rights reserved.
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

// An identifier that the web process names a display list or a recorder by, as the key of a dictionary that messages look up,
// which hashes it as a C++ HashMap hashes an integer rather than with Hasher.
struct RemoteIdentifierKey: Hashable {
    let value: UInt64

    func hash(into hasher: inout Swift.Hasher) {
        hasher.combine(value)
    }

    func _rawHashValue(seed: Int) -> Int {
        var bits = value
        bits ^= bits >> 33
        bits &*= 0xff51_afd7_ed55_8ccd
        bits ^= UInt64(UInt(bitPattern: seed))
        bits ^= bits >> 33
        bits &*= 0xc4ce_b9fe_1a85_ec53
        bits ^= bits >> 33
        return Int(truncatingIfNeeded: bits)
    }
}

// The native images and image buffers that a recording's draws name, by identifier, as the recording found them.
final class RemoteCGRendererRecordedImages {
    fileprivate(set) var nativeImages: [RemoteIdentifierKey: RemoteCGRendererImage] = [:]
    fileprivate(set) var imageBuffers: [RemoteIdentifierKey: WebCore.ImageBuffer] = [:]

    fileprivate init() {
    }

    fileprivate init(copying other: RemoteCGRendererRecordedImages) {
        nativeImages = other.nativeImages
        imageBuffers = other.imageBuffers
    }
}

// A recording of RemoteCGRenderer's messages, which a display list or a snapshot's frame is: the messages, the resources they
// name, kept from when they were recorded, and the display lists they draw, by key (WebKit.displayListKey()). The native
// images and image buffers that its draws name are kept in Swift, the other resources in C++.
@_expose(Cxx)
final class RemoteCGRendererRecording {
    @_expose(!Cxx)
    let messages: [RemoteCGRenderer.RecordedMessage]
    @_expose(!Cxx)
    let resources: WebKit.RemoteCGRendererRecordedResources
    // Nil for a recording whose draws name none, which most don't.
    @_expose(!Cxx)
    let images: RemoteCGRendererRecordedImages?
    @_expose(!Cxx)
    let displayLists: [RemoteIdentifierKey: RemoteCGRendererRecording]
    // Whether a replay looks up the recording or the transform it started at: only SetCTM and DrawDisplayList do.
    @_expose(!Cxx)
    let replayNeedsContext: Bool
    // Whether a replay looks up any of the resources that C++ keeps: a run of glyphs keeps its font itself.
    @_expose(!Cxx)
    let replayNeedsResources: Bool

    @_expose(!Cxx)
    fileprivate init(
        messages: [RemoteCGRenderer.RecordedMessage],
        resources: WebKit.RemoteCGRendererRecordedResources,
        images: RemoteCGRendererRecordedImages?,
        displayLists: [RemoteIdentifierKey: RemoteCGRendererRecording],
        needsContext: Bool,
        namesResources: Bool
    ) {
        self.messages = messages
        self.resources = resources
        self.images = images
        self.displayLists = displayLists
        self.replayNeedsContext = needsContext
        self.replayNeedsResources = namesResources
    }

    // Draws the messages into a context's renderer, lent for the draw, with resources for a replay into the context, as
    // GraphicsContext::drawDisplayList() draws a WebCore display list.
    @used
    func draw(state: inout CGRendererCore, resources: WebKit.RemoteCGRendererResources) {
        RemoteCGRenderer.makeReplayer(resources: resources, snapshotFrames: nil).replay(self, state: &state)
    }

    // The messages as the stream sends them, for the print process: none if one draws what DisplayListData can't send there,
    // such as an image or an ARKit badge.
    @_expose(!Cxx)
    func encodedMessages() -> WebKit.RemoteCGRendererRecordedMessageEncoder? {
        if images != nil {
            return nil
        }
        #if USE_SYSTEM_PREVIEW
        for message in messages {
            if case .drawBadgeSystemImage = message {
                return nil
            }
        }
        #endif
        var encoder = WebKit.RemoteCGRendererRecordedMessageEncoder()
        RemoteCGRenderer.encode(messages, to: &encoder)
        return encoder
    }
}

// What a recorder's DrawSnapshotFrame messages reference: nothing, which makes them invalid messages, the frames of the snapshot
// it records a frame of, or, in the print process, which records a snapshot's recordings again, the frames that the snapshot
// had.
enum RemoteCGRendererSnapshotFrameReferences {
    case none
    case snapshot(RemoteSnapshot)
    case rerecording
}

// The lock of a recorder whose recording another thread draws (RemoteCGRendererRecordedDrawing), so that it draws whole
// messages.
final class RemoteCGRendererRecorderLock: Sendable {
    let mutex = Mutex<Void>(())
}

// Records the RemoteCGRenderer messages to a display list recorder, a snapshot recorder or the recorder of an image buffer whose
// drawing is recorded, on its stream connection's work queue, as RemoteGraphicsContext records them into a WebCore display list
// recorder: the resources that a message names are looked up and kept as it is recorded, and a missing one is an invalid
// message. The print process records a snapshot's recordings again with one. Exposed only for the generated C++ forwarder's
// weak reference.
@_expose(Cxx)
final class RemoteCGRendererRecorder {
    private let resources: WebKit.RemoteCGRendererResources
    private let displayLists: RemoteCGRendererDisplayLists
    private let snapshotFrames: RemoteCGRendererSnapshotFrameReferences
    // Which a message is recorded under, for a recorder whose recording another thread draws: its takeRecording() and
    // currentRecording() are then called under it.
    private let lock: RemoteCGRendererRecorderLock?
    private var messages: [RemoteCGRenderer.RecordedMessage] = []
    private var images: RemoteCGRendererRecordedImages?
    private var recordedDisplayLists: [RemoteIdentifierKey: RemoteCGRendererRecording] = [:]
    private var needsContext = false
    private var namesResources = false
    private var videoFrames: RemoteCGRendererVideoFrames
    // Whether its video frame reader has state, from SetSharedVideoFrameSemaphore, SetSharedVideoFrameMemory or
    // DrawVideoFrame.
    @_expose(!Cxx)
    private(set) var readVideoFrames = false

    @_expose(!Cxx)
    init(
        resources: WebKit.RemoteCGRendererResources,
        displayLists: RemoteCGRendererDisplayLists,
        videoFrameSources: GPUVideoFrameSources?,
        snapshotFrames: RemoteCGRendererSnapshotFrameReferences = .none,
        lock: RemoteCGRendererRecorderLock? = nil
    ) {
        self.resources = resources
        self.displayLists = displayLists
        self.videoFrames = RemoteCGRendererVideoFrames(videoFrameSources)
        self.snapshotFrames = snapshotFrames
        self.lock = lock
    }

    // The snapshot whose frame it records, if it records one.
    @_expose(!Cxx)
    var snapshot: RemoteSnapshot? {
        guard case .snapshot(let snapshot) = snapshotFrames else {
            return nil
        }
        return snapshot
    }

    // The forwarder of the recorder's messages, which keeps it, as the stream connection the forwarder is registered with keeps
    // the forwarder.
    @_expose(!Cxx)
    static func createMessageReceiver(recorder: RemoteCGRendererRecorder) -> RefRemoteCGRendererRecorderMessageForwarder {
        WebKit.RemoteCGRendererRecorderMessageForwarder.create(target: recorder)
    }

    // What it recorded, after which it records into a new recording.
    @_expose(!Cxx)
    func takeRecording() -> RemoteCGRendererRecording {
        let recording = RemoteCGRendererRecording(
            messages: messages,
            resources: WebKit.takeRecordedResources(resources),
            images: images,
            displayLists: recordedDisplayLists,
            needsContext: needsContext,
            namesResources: namesResources
        )
        messages = []
        images = nil
        if !recordedDisplayLists.isEmpty {
            recordedDisplayLists = [:]
        }
        needsContext = false
        namesResources = false
        return recording
    }

    // What it recorded so far, while it records more.
    @_expose(!Cxx)
    func currentRecording() -> RemoteCGRendererRecording {
        RemoteCGRendererRecording(
            messages: messages,
            resources: WebKit.copyRecordedResources(resources),
            images: images.map { RemoteCGRendererRecordedImages(copying: $0) },
            displayLists: recordedDisplayLists,
            needsContext: needsContext,
            namesResources: namesResources
        )
    }

    @_expose(!Cxx)
    func record(_ message: consuming RemoteCGRenderer.RecordedMessage) throws(InvalidMessage) {
        guard let lock else {
            try recordUnlocked(consume message)
            return
        }
        let message = consume message
        try lock.mutex.withLock { _ throws(InvalidMessage) in
            try recordUnlocked(message)
        }
    }

    private func recordUnlocked(_ message: consuming RemoteCGRenderer.RecordedMessage) throws(InvalidMessage) {
        var namesResource = true
        var message = message
        switch copy message {
        case .fillCachedPath(let identifier), .clipCachedPath(let identifier, _), .clipTransformedCachedPath(_, let identifier, _):
            try messageCheck { resources.recordPath(identifier) }
        case .drawNativeImage(let identifier, _, _, _),
            .drawPatternNativeImage(let identifier, _, _, _, _, _, _),
            .setFillPatternNativeImage(let identifier, _),
            .setStrokePatternNativeImage(let identifier, _),
            .clipToNativeImage(let identifier, _):
            namesResource = false
            try recordNativeImage(identifier)
        case .drawImageBuffer(let identifier, _, _, _),
            .drawPatternImageBuffer(let identifier, _, _, _, _, _, _),
            .setFillPatternImageBuffer(let identifier, _),
            .setStrokePatternImageBuffer(let identifier, _):
            namesResource = false
            try recordImageBuffer(identifier)
        case .setFillCachedGradient(let identifier, _),
            .setStrokeCachedGradient(let identifier, _),
            .fillRectWithCachedGradient(_, let identifier),
            .fillRectWithCachedGradientAndSpaceTransform(_, let identifier, _, _):
            try messageCheck { resources.recordGradient(identifier) }
        case .drawGlyphs(let fontIdentifier, let glyphs, _, _):
            namesResource = false
            try messageCheck { resources.recordGlyphs(fontIdentifier, glyphs) }
        case .drawMeshGradient(let identifier, _):
            try messageCheck { resources.recordMeshGradient(identifier) }
        case .drawFilteredImageBuffer(let sourceImageIdentifier, let sourceImageRect, let filter):
            namesResource = false
            if let sourceImageIdentifier {
                try recordImageBuffer(key: sourceImageIdentifier.rawValue)
            }
            for key in filter.feImageIdentifiers {
                try recordNativeImageOrImageBuffer(key: key)
            }
            // The cached SVG filter that the filter names, with the filter's effects merged in, as a filter of the recording's
            // own, which a replay applies with results of its own.
            if case .svgFilterRenderer(let svgFilter) = filter, let identifier = svgFilter.renderingResourceIdentifierIfExists {
                let cachedFilter = displayLists.backendResources?.filter(key: identifier.rawValue)
                guard var merged = cachedFilter?.merge(svgFilter) else {
                    try messageCheck { false }
                    return
                }
                merged.renderingResourceIdentifierIfExists = nil
                message = .drawFilteredImageBuffer(
                    sourceImageIdentifier: sourceImageIdentifier,
                    sourceImageRect: sourceImageRect,
                    filter: .svgFilterRenderer(merged)
                )
            }
        #if USE_SYSTEM_PREVIEW
        case .drawBadgeSystemImage(let imageIdentifier, _):
            namesResource = false
            if let identifier = imageIdentifier.value {
                try recordNativeImage(identifier)
            }
        #endif
        case .setCTM:
            namesResource = false
            needsContext = true
        case .drawDisplayList(let identifier):
            namesResource = false
            needsContext = true
            let key = WebKit.displayListKey(identifier)
            guard let recording = displayLists.recording(key: key) else {
                try messageCheck { false }
                return
            }
            recordedDisplayLists[RemoteIdentifierKey(value: key)] = recording
        case .drawSnapshotFrame(let frameIdentifier):
            namesResource = false
            // A frame that the snapshot then waits for.
            switch snapshotFrames {
            case .none:
                try messageCheck { false }
            case .snapshot(let snapshot):
                snapshot.addFrameReference(frameIdentifier.toUInt64())
            case .rerecording:
                break
            }
        default:
            namesResource = false
        }
        namesResources = namesResources || namesResource
        messages.append(message)
    }

    // The backend's native image or image buffer that a message names, which the recording keeps: a missing one is an invalid
    // message.
    private func recordNativeImage(_ identifier: WebCore.RenderingResourceIdentifier) throws(InvalidMessage) {
        try recordNativeImage(key: identifier.toUInt64())
    }

    private func recordNativeImage(key: UInt64) throws(InvalidMessage) {
        let image = displayLists.backendResources?.nativeImage(key: key)
        try messageCheck { image != nil }
        // As the C++ keeps a recording's other resources, the first one an identifier names.
        let images = recordedImages()
        if let image, images.nativeImages.index(forKey: RemoteIdentifierKey(value: key)) == nil {
            images.nativeImages[RemoteIdentifierKey(value: key)] = image
        }
    }

    private func recordImageBuffer(_ identifier: WebCore.RenderingResourceIdentifier) throws(InvalidMessage) {
        try recordImageBuffer(key: identifier.toUInt64())
    }

    private func recordImageBuffer(key: UInt64) throws(InvalidMessage) {
        let imageBuffer = displayLists.backendResources?.imageBuffer(key: key)
        try messageCheck { imageBuffer != nil }
        let images = recordedImages()
        if let imageBuffer, images.imageBuffers.index(forKey: RemoteIdentifierKey(value: key)) == nil {
            images.imageBuffers[RemoteIdentifierKey(value: key)] = imageBuffer
        }
    }

    // The native image, or else the image buffer, that an FEImage names (FEImage's SourceImage).
    private func recordNativeImageOrImageBuffer(key: UInt64) throws(InvalidMessage) {
        if displayLists.backendResources?.nativeImage(key: key) != nil {
            try recordNativeImage(key: key)
        } else {
            try recordImageBuffer(key: key)
        }
    }

    // The recording's images, made when it first names one. A recording that currentRecording() made has its own copy.
    private func recordedImages() -> RemoteCGRendererRecordedImages {
        if let images {
            return images
        }
        let images = RemoteCGRendererRecordedImages()
        self.images = images
        return images
    }

    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    // RemoteGraphicsContext reads the frame, which a WebCore display list recorder then doesn't record, so that the reader
    // keeps in step with the sender.
    @_expose(!Cxx)
    func drawVideoFrame(
        frame: WebKit.SharedVideoFrame,
        rect: WebCore.FloatRect,
        shouldDiscardAlpha: WebCore.ShouldDiscardAlpha,
        options: WebCore.RasterDrawingOptions
    ) {
        readVideoFrames = true
        _ = videoFrames.source()?.readBuffer(frame.bufferTag())
    }

    @_expose(!Cxx)
    func setSharedVideoFrameSemaphore(semaphore: consuming IPCTypes.Semaphore) {
        readVideoFrames = true
        videoFrames.setSemaphore(semaphore)
    }

    @_expose(!Cxx)
    func setSharedVideoFrameMemory(storageHandle: consuming IPCTypes.SharedMemoryHandle) {
        readVideoFrames = true
        videoFrames.setSharedMemory(storageHandle)
    }
    #endif
}

// The drawing of an image buffer whose drawing is recorded (RenderingMode::DisplayList), whose context can't lend a renderer:
// recorded while the buffer receives drawing (RemoteImageBuffer.swift), and drawn where the WebCore display list that the
// buffer's context records is drawn, by the one placeholder that display list has, which keeps it, on any thread. Once the
// buffer no longer receives drawing, it keeps the recording and lets the recorder, which keeps the rendering backend, go.
// @unchecked Sendable: its recorder and recording are only used under the recorder's lock.
@_expose(Cxx)
final class RemoteCGRendererRecordedDrawing: @unchecked Sendable {
    // A recording that leaves the lock. @unchecked Sendable: a recording is immutable, and is replayed on other threads.
    private struct LockedRecording: @unchecked Sendable {
        let recording: RemoteCGRendererRecording?
    }

    private let lock: RemoteCGRendererRecorderLock
    private var recorder: RemoteCGRendererRecorder?
    private var recording: RemoteCGRendererRecording?

    @_expose(!Cxx)
    private init(recorder: RemoteCGRendererRecorder, lock: RemoteCGRendererRecorderLock) {
        self.recorder = recorder
        self.lock = lock
    }

    // The drawing, and the receiver of the buffer's drawing, which records it until stopRecording().
    @_expose(!Cxx)
    static func create(
        resources: WebKit.RemoteCGRendererResources,
        displayLists: RemoteCGRendererDisplayLists,
        videoFrameSources: GPUVideoFrameSources
    ) -> (RemoteCGRendererRecordedDrawing, RefRemoteCGRendererRecorderMessageForwarder) {
        let lock = RemoteCGRendererRecorderLock()
        let recorder = RemoteCGRendererRecorder(
            resources: resources,
            displayLists: displayLists,
            videoFrameSources: videoFrameSources,
            lock: lock
        )
        let forwarder = RemoteCGRendererRecorder.createMessageReceiver(recorder: recorder)
        return (RemoteCGRendererRecordedDrawing(recorder: recorder, lock: lock), forwarder)
    }

    @_expose(!Cxx)
    func stopRecording() {
        lock.mutex.withLock { _ in
            guard let recorder else {
                return
            }
            recording = recorder.takeRecording()
            self.recorder = nil
        }
    }

    private func currentRecording() -> RemoteCGRendererRecording? {
        let locked = lock.mutex.withLock { _ in
            LockedRecording(recording: recorder?.currentRecording() ?? recording)
        }
        return locked.recording
    }

    // Draws what the buffer's drawing recorded so far into a context's renderer, lent for the draw, with resources for a replay
    // into the context, for the placeholder that keeps the drawing (RemoteImageBufferGraphicsContext::installRecordedDrawing()).
    @used
    static func draw(_ drawing: UInt, state: inout CGRendererCore, resources: WebKit.RemoteCGRendererResources) {
        // Safety: the placeholder keeps the drawing retained from installRecordedDrawing() until it lets go of it (releaseDrawing()).
        let drawing = unsafe Unmanaged<RemoteCGRendererRecordedDrawing>.fromOpaque(address(drawing)).takeUnretainedValue()
        drawing.currentRecording()?.draw(state: &state, resources: resources)
    }

    @used
    static func releaseDrawing(_ drawing: UInt) {
        // Safety: installRecordedDrawing() was given the drawing retained, which only the placeholder releases, once.
        unsafe Unmanaged<RemoteCGRendererRecordedDrawing>.fromOpaque(address(drawing)).release()
    }

    private static func address(_ drawing: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: drawing) else {
            preconditionFailure("A placeholder has no recorded drawing")
        }
        return unsafe address
    }
}

// The display lists of a rendering backend, which its contexts' DrawDisplayList messages name, on its work queue, by key
// (WebKit.displayListKey()).
@_expose(Cxx)
final class RemoteCGRendererDisplayLists {
    // Changed only by changes that release what they replace or remove after they end, so that no access to it can overlap
    // another, and the lookups need no dynamic exclusivity check.
    private var recordings: [RemoteIdentifierKey: RemoteCGRendererRecording] = [:]
    // The backend's resources, which the recorders that record into these display lists look up: none for the print
    // process's, whose recordings name no native images or image buffers.
    @_expose(!Cxx)
    let backendResources: RemoteRenderingBackendResources?

    @_expose(!Cxx)
    init(backendResources: RemoteRenderingBackendResources?) {
        self.backendResources = backendResources
    }

    // The display lists of a rendering backend (RemoteRenderingBackend.swift), for its C++ that records into them or draws
    // them.
    @used
    static func forBackend(_ backend: WebKit.RemoteRenderingBackend) -> RemoteCGRendererDisplayLists {
        backend.state.displayLists
    }

    // False for a key that already names a display list, which is an invalid message.
    @_expose(!Cxx)
    func add(_ recording: RemoteCGRendererRecording, key: UInt64) -> Bool {
        let key = RemoteIdentifierKey(value: key)
        guard recordings[key] == nil else {
            return false
        }
        _ = recordings.updateValue(recording, forKey: key)
        return true
    }

    @_expose(!Cxx)
    func remove(key: UInt64) -> Bool {
        recordings.removeValue(forKey: RemoteIdentifierKey(value: key)) != nil
    }

    @_expose(!Cxx)
    func removeAll() {
        var removed: [RemoteIdentifierKey: RemoteCGRendererRecording] = [:]
        swap(&recordings, &removed)
    }

    func recording(key: UInt64) -> RemoteCGRendererRecording? {
        recordings[RemoteIdentifierKey(value: key)]
    }
}

// A recording of a snapshot's frame, which is let go of on the work queue of the rendering backend that recorded it: a frame's
// recording keeps resources that the backend's work queue references too, such as fonts, which another thread can replay but
// can't release. None for a recording that the print process records again, which it lets go of where it draws it.
// @unchecked Sendable: it is immutable, and is replayed on other threads as the C++ snapshot replayed its recordings.
final class RemoteSnapshotFrameRecording: @unchecked Sendable {
    let recording: RemoteCGRendererRecording
    private let backend: WebKit.RemoteRenderingBackend?

    init(recording: RemoteCGRendererRecording, backend: WebKit.RemoteRenderingBackend?) {
        self.recording = recording
        self.backend = backend
    }

    deinit {
        backend?.releaseOnWorkQueue(recording)
    }
}

// The frames of a snapshot whose root a replay draws (RemoteSnapshot.swift): each frame's recording, or none for a frame that
// was abandoned, which draws nothing. The GPU process's sinks draw the frames that the snapshot had when it completed
// (forSink()), on the main thread; the print process makes them from the snapshot's print data, recording each recording
// again (beginRerecording()), and draws them where it makes them.
@_expose(Cxx)
final class RemoteCGRendererSnapshotFrames {
    private var recordings: [UInt64: RemoteSnapshotFrameRecording] = [:]
    private var abandonedFrames: Set<UInt64> = []
    private var framesBeingDrawn: Set<UInt64> = []
    // The print process's recordings, in the order of the snapshot's print data, the display lists that the next one draws,
    // and its recorder while it records it.
    private var rerecordings: [RemoteCGRendererRecording] = []
    private var nextDisplayLists: [(key: UInt64, recording: RemoteCGRendererRecording)] = []
    private var rerecorder: RemoteCGRendererRecorder?

    @_expose(!Cxx)
    private init() {
    }

    // The frames of a snapshot when it completed, by key (WebKit.frameKey()).
    @_expose(!Cxx)
    init(recordings: [UInt64: RemoteSnapshotFrameRecording], abandonedFrames: Set<UInt64>) {
        self.recordings = recordings
        self.abandonedFrames = abandonedFrames
    }

    @used
    static func create() -> RemoteCGRendererSnapshotFrames {
        RemoteCGRendererSnapshotFrames()
    }

    // The frames of the snapshot that a sink waited for, which it draws once the snapshot completed with its root.
    @used
    static func forSink(_ sink: WebKit.RemoteSnapshotSink) -> RemoteCGRendererSnapshotFrames {
        guard let frames = sink.frames else {
            preconditionFailure("A sink draws only a snapshot that completed with its root")
        }
        return frames
    }

    // A display list, by key, that the recording that the print process records next draws: the recording at the index, which
    // it recorded before. False for an index past those, or a key that another of its display lists has.
    @used
    func addDisplayListToNextRecording(key: UInt64, index: UInt64) -> Bool {
        guard index < rerecordings.count, !nextDisplayLists.contains(where: { $0.key == key }) else {
            return false
        }
        nextDisplayLists.append((key, rerecordings[Int(index)]))
        return true
    }

    // The receiver of the messages of the recording that the print process records next, until endRerecording().
    @used
    func beginRerecording(resources: WebKit.RemoteCGRendererResources) -> RefRemoteCGRendererRecorderMessageForwarder {
        let displayLists = RemoteCGRendererDisplayLists(backendResources: nil)
        for displayList in nextDisplayLists {
            _ = displayLists.add(displayList.recording, key: displayList.key)
        }
        nextDisplayLists = []
        let recorder = RemoteCGRendererRecorder(
            resources: resources,
            displayLists: displayLists,
            videoFrameSources: nil,
            snapshotFrames: .rerecording
        )
        rerecorder = recorder
        return RemoteCGRendererRecorder.createMessageReceiver(recorder: recorder)
    }

    @used
    func endRerecording() {
        guard let rerecorder else {
            preconditionFailure("The print process ends a recording it didn't begin")
        }
        rerecordings.append(rerecorder.takeRecording())
        self.rerecorder = nil
    }

    // A frame, by key, and the recording at the index that the print process recorded: false for an index past those.
    @used
    func addFrame(key: UInt64, index: UInt64) -> Bool {
        guard index < rerecordings.count else {
            return false
        }
        recordings[key] = RemoteSnapshotFrameRecording(recording: rerecordings[Int(index)], backend: nil)
        return true
    }

    @used
    func addAbandoned(key: UInt64) {
        abandonedFrames.insert(key)
    }

    // Draws the root frame, and the frames it draws in turn, into a context's renderer, lent for the draw, with resources for
    // a replay into the context: false if the root has no recording and wasn't abandoned.
    @used
    func draw(rootKey: UInt64, state: inout CGRendererCore, resources: WebKit.RemoteCGRendererResources) -> Bool {
        draw(rootKey, to: RemoteCGRenderer.makeReplayer(resources: resources, snapshotFrames: self), state: &state)
    }

    // The recordings of the frames, and of the display lists they draw, for the print process (RemoteSnapshotPrintData): false
    // if it can't have one of them.
    @used
    func encode(to builder: WebKit.RemoteSnapshotPrintDataBuilder) -> Bool {
        var indices: [ObjectIdentifier: UInt64] = [:]
        var count: UInt64 = 0
        func add(_ recording: RemoteCGRendererRecording) -> UInt64? {
            if let index = indices[ObjectIdentifier(recording)] {
                return index
            }
            var displayLists: [(key: UInt64, index: UInt64)] = []
            for (key, displayList) in recording.displayLists {
                guard let index = add(displayList) else {
                    return nil
                }
                displayLists.append((key.value, index))
            }
            guard var encoder = recording.encodedMessages(), builder.addRecording(&encoder, recording.resources) else {
                return nil
            }
            for displayList in displayLists {
                builder.addDisplayList(displayList.key, displayList.index)
            }
            let index = count
            count += 1
            indices[ObjectIdentifier(recording)] = index
            return index
        }
        for (key, frame) in recordings {
            guard let index = add(frame.recording) else {
                return false
            }
            builder.addFrame(key, index)
        }
        for key in abandonedFrames {
            builder.addAbandonedFrame(key)
        }
        return true
    }

    // A frame that the replay draws, the root or one a DrawSnapshotFrame draws. A frame that is being drawn, which only a frame
    // that draws itself reaches, isn't drawn again.
    @_expose(!Cxx)
    func draw(_ key: UInt64, to renderer: RemoteCGRenderer, state: inout CGRendererCore) -> Bool {
        if abandonedFrames.contains(key) {
            return true
        }
        guard let recording = recordings[key]?.recording else {
            return false
        }
        guard framesBeingDrawn.insert(key).inserted else {
            return true
        }
        renderer.replay(recording, state: &state)
        framesBeingDrawn.remove(key)
        return true
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
