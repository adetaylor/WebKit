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

// Records the RemoteCGRenderer messages to a display list recorder or a snapshot recorder, on its stream connection's work
// queue, as RemoteGraphicsContext records them into a WebCore display list recorder: the resources that a message names are
// looked up and kept as it is recorded, and a missing one is an invalid message.
@_expose(Cxx)
final class RemoteCGRendererRecorder {
    private let resources: WebKit.RemoteCGRendererResources
    private let displayLists: RemoteCGRendererDisplayLists
    private var messages: [RemoteCGRenderer.RecordedMessage] = []
    private var images: RemoteCGRendererRecordedImages?
    private var recordedDisplayLists: [RemoteIdentifierKey: RemoteCGRendererRecording] = [:]
    private var needsContext = false
    private var namesResources = false
    // Whether its resources' video frame reader has state, from SetSharedVideoFrameSemaphore, SetSharedVideoFrameMemory or
    // DrawVideoFrame.
    @_expose(!Cxx)
    private(set) var readVideoFrames = false

    @_expose(!Cxx)
    private init(resources: WebKit.RemoteCGRendererResources, displayLists: RemoteCGRendererDisplayLists) {
        self.resources = resources
        self.displayLists = displayLists
    }

    @used
    static func create(resources: WebKit.RemoteCGRendererResources, displayLists: RemoteCGRendererDisplayLists) -> RemoteCGRendererRecorder {
        RemoteCGRendererRecorder(resources: resources, displayLists: displayLists)
    }

    // The forwarder of the recorder's messages, which keeps it, as the stream connection the C++ registers the forwarder with
    // keeps the forwarder. Only C++ calls it, so @used keeps it under -O -wmo (rdar://179098545).
    @used
    static func createMessageReceiver(recorder: RemoteCGRendererRecorder) -> RefRemoteCGRendererRecorderMessageForwarder {
        WebKit.RemoteCGRendererRecorderMessageForwarder.create(target: recorder)
    }

    // What it recorded, after which it records into a new recording.
    @used
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
    @used
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
        var namesResource = true
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
        case .drawFilteredImageBuffer(let sourceImageIdentifier, _, let filter):
            try messageCheck { resources.recordFilter(sourceImageIdentifier, filter) }
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
            try messageCheck { resources.addSnapshotFrameReference(frameIdentifier) }
        default:
            namesResource = false
        }
        namesResources = namesResources || namesResource
        messages.append(message)
    }

    // The backend's native image or image buffer that a message names, which the recording keeps: a missing one is an invalid
    // message.
    private func recordNativeImage(_ identifier: WebCore.RenderingResourceIdentifier) throws(InvalidMessage) {
        let key = identifier.toUInt64()
        let image = displayLists.backendResources?.nativeImage(key: key)
        try messageCheck { image != nil }
        // As the C++ keeps a recording's other resources, the first one an identifier names.
        let images = recordedImages()
        if let image, images.nativeImages.index(forKey: RemoteIdentifierKey(value: key)) == nil {
            images.nativeImages[RemoteIdentifierKey(value: key)] = image
        }
    }

    private func recordImageBuffer(_ identifier: WebCore.RenderingResourceIdentifier) throws(InvalidMessage) {
        let key = identifier.toUInt64()
        let imageBuffer = displayLists.backendResources?.imageBuffer(key: key)
        try messageCheck { imageBuffer != nil }
        let images = recordedImages()
        if let imageBuffer, images.imageBuffers.index(forKey: RemoteIdentifierKey(value: key)) == nil {
            images.imageBuffers[RemoteIdentifierKey(value: key)] = imageBuffer
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
    // RemoteGraphicsContext reads the frame, which a WebCore display list recorder then doesn't record.
    @_expose(!Cxx)
    func drawVideoFrame(
        frame: WebKit.SharedVideoFrame,
        rect: WebCore.FloatRect,
        shouldDiscardAlpha: WebCore.ShouldDiscardAlpha,
        options: WebCore.RasterDrawingOptions
    ) {
        readVideoFrames = true
        resources.readVideoFrame(frame)
    }

    @_expose(!Cxx)
    func setSharedVideoFrameSemaphore(semaphore: borrowing IPC.Semaphore) {
        readVideoFrames = true
        WebKit.setSharedVideoFrameSemaphore(resources, semaphore)
    }

    @_expose(!Cxx)
    func setSharedVideoFrameMemory(storageHandle: borrowing WebCore.SharedMemory.Handle) {
        readVideoFrames = true
        WebKit.setSharedVideoFrameMemory(resources, storageHandle)
    }
    #endif
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

    @used
    static func create() -> RemoteCGRendererDisplayLists {
        RemoteCGRendererDisplayLists(backendResources: nil)
    }

    // The display lists of a rendering backend (RemoteRenderingBackend.swift), for its C++ that records into them or draws
    // them.
    @used
    static func forBackend(_ backend: WebKit.RemoteRenderingBackend) -> RemoteCGRendererDisplayLists {
        backend.state.displayLists
    }

    // False for a key that already names a display list, which is an invalid message.
    @used
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

// The frames of a snapshot whose root a replay draws (RemoteSnapshot), made for the replay on the thread that replays it:
// each frame's recording, or none for a frame that was abandoned, which draws nothing.
@_expose(Cxx)
final class RemoteCGRendererSnapshotFrames {
    private var recordings: [UInt64: RemoteCGRendererRecording] = [:]
    private var abandonedFrames: Set<UInt64> = []
    private var framesBeingDrawn: Set<UInt64> = []

    @_expose(!Cxx)
    private init() {
    }

    @used
    static func create() -> RemoteCGRendererSnapshotFrames {
        RemoteCGRendererSnapshotFrames()
    }

    // A frame, by key (WebKit.frameKey()), and its recording.
    @used
    func add(_ recording: RemoteCGRendererRecording, key: UInt64) {
        recordings[key] = recording
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
        for (key, recording) in recordings {
            guard let index = add(recording) else {
                return false
            }
            builder.addFrame(key, index)
        }
        for key in abandonedFrames {
            builder.addAbandonedFrame(key)
        }
        return true
    }

    // RemoteSnapshot::applyFrame(). A frame that is being drawn, which only a frame that draws itself reaches, isn't drawn
    // again.
    @_expose(!Cxx)
    func draw(_ key: UInt64, to renderer: RemoteCGRenderer, state: inout CGRendererCore) -> Bool {
        if abandonedFrames.contains(key) {
            return true
        }
        guard let recording = recordings[key] else {
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
