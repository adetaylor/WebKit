// Copyright (C) 2021-2024 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT

import Synchronization
@_spi(WebKitGPU) internal import WebCore
import WebCore_Private
import WebKit_Internal

// The value that a dictionary's subscript with a default stores: the one it had, or the default, which it adds, looking the key
// up once.
func storedValue<Value>(_ value: inout Value) -> Value {
    value
}

// Whether two references are to the same image buffer. Safety: it compares the bits of the references, without using them,
// which is the only way Swift has to compare C++ reference types.
func isSameImageBuffer(_ imageBuffer: WebCore.ImageBuffer, _ other: WebCore.ImageBuffer?) -> Bool {
    guard let other else {
        return false
    }
    return unsafe unsafeBitCast(imageBuffer, to: UInt.self) == unsafeBitCast(other, to: UInt.self)
}

// A font that RemoteCGRenderer draws glyphs in, as a rendering backend caches it (CacheFont) or the print process makes it: the
// font, with its CTFont and facts worked out once, when it is made (CGRendererGlyphFontFactsOf()), which any thread may read.
// @unchecked Sendable: it is immutable, apart from the font's cache of its glyphs' colors, which it fills under its lock.
@_expose(Cxx)
final class RemoteCGRendererFont: @unchecked Sendable {
    @_expose(!Cxx)
    let sharedFont: WebKit.SharedFont
    @_expose(!Cxx)
    let ctFont: CTFont?
    private let facts: CGRendererGlyphFontFacts
    private let complexColorFormatGlyphsLock = Mutex<Void>(())

    @_expose(!Cxx)
    init(sharedFont: WebKit.SharedFont) {
        var facts = CGRendererGlyphFontFacts()
        self.ctFont = WebKit.glyphFontFactsOf(sharedFont, &facts)
        self.sharedFont = sharedFont
        self.facts = facts
    }

    // For the print process (RemoteSnapshotPrintData).
    @used
    static func create(sharedFont: WebKit.SharedFont) -> RemoteCGRendererFont {
        RemoteCGRendererFont(sharedFont: sharedFont)
    }

    // The facts of a run of the glyphs: the font's, except that the run draws nothing where a glyph has complex color
    // (FontBase::hasAnyComplexColorFormatGlyphs(), whose cache of the glyphs this fills one thread at a time).
    @_expose(!Cxx)
    func factsForGlyphs(_ glyphs: Span<CGGlyph>) -> CGRendererGlyphFontFacts {
        guard ctFont != nil else {
            return CGRendererGlyphFontFacts()
        }
        var facts = self.facts
        if facts.hasComplexColorFormatTables {
            let hasComplexColorGlyphs = complexColorFormatGlyphsLock.withLock { _ in
                WebKit.hasAnyComplexColorFormatGlyphs(sharedFont, glyphs)
            }
            if hasComplexColorGlyphs {
                assertionFailure("A font with complex color glyphs is drawn in the GPU process")
                facts.draws = false
            }
        }
        return facts
    }
}

// The resources that a recording's messages name (RemoteCGRendererRecording.swift), which it keeps from when it records them,
// as a WebCore display list keeps what it records. Read only once recorded, on whichever thread replays the recording.
@_expose(Cxx)
final class RemoteCGRendererRecordedResources {
    private var paths: [RemoteIdentifierKey: WebCore.PathImpl] = [:]
    private var gradients: [RemoteIdentifierKey: WebCore.Gradient] = [:]
    // The fonts, by identifier: the first that the recording kept, which is most often the only one, and the others.
    private var firstFont: (key: UInt64, font: RemoteCGRendererFont)?
    private var otherFonts: [RemoteIdentifierKey: RemoteCGRendererFont] = [:]
    private var meshGradients: [RemoteIdentifierKey: WebCore.MeshGradient] = [:]

    @_expose(!Cxx)
    init() {
    }

    @_expose(!Cxx)
    init(copying other: RemoteCGRendererRecordedResources) {
        paths = other.paths
        gradients = other.gradients
        firstFont = other.firstFont
        otherFonts = other.otherFonts
        meshGradients = other.meshGradients
    }

    // The resources that the print process takes from a snapshot's print data (RemoteSnapshotPrintData), with the fonts it made
    // of the snapshot's.
    @used
    static func create() -> RemoteCGRendererRecordedResources {
        RemoteCGRendererRecordedResources()
    }

    @used
    func setFont(key: UInt64, font: RemoteCGRendererFont) {
        if firstFont == nil || firstFont?.key == key {
            firstFont = (key, font)
            return
        }
        otherFonts[RemoteIdentifierKey(value: key)] = font
    }

    @used
    func setGradient(key: UInt64, gradient: WebCore.Gradient) {
        gradients[RemoteIdentifierKey(value: key)] = gradient
    }

    @used
    func setPath(key: UInt64, path: WebCore.PathImpl) {
        paths[RemoteIdentifierKey(value: key)] = path
    }

    @_expose(!Cxx)
    func path(key: UInt64) -> WebCore.PathImpl? {
        paths[RemoteIdentifierKey(value: key)]
    }

    @_expose(!Cxx)
    func gradient(key: UInt64) -> WebCore.Gradient? {
        gradients[RemoteIdentifierKey(value: key)]
    }

    @_expose(!Cxx)
    func meshGradient(key: UInt64) -> WebCore.MeshGradient? {
        meshGradients[RemoteIdentifierKey(value: key)]
    }

    @_expose(!Cxx)
    func font(key: UInt64) -> RemoteCGRendererFont? {
        if let firstFont, firstFont.key == key {
            return firstFont.font
        }
        return otherFonts[RemoteIdentifierKey(value: key)]
    }

    @_expose(!Cxx)
    var hasMeshGradients: Bool {
        !meshGradients.isEmpty
    }

    // A recorder's: what the recording keeps under the identifier is the first it was given.
    fileprivate func addPath(_ path: WebCore.PathImpl, key: UInt64) {
        _ = storedValue(&paths[RemoteIdentifierKey(value: key), default: path])
    }

    fileprivate func addGradient(_ gradient: WebCore.Gradient, key: UInt64) {
        _ = storedValue(&gradients[RemoteIdentifierKey(value: key), default: gradient])
    }

    fileprivate func addMeshGradient(_ gradient: WebCore.MeshGradient, key: UInt64) {
        _ = storedValue(&meshGradients[RemoteIdentifierKey(value: key), default: gradient])
    }

    fileprivate func addFont(_ font: RemoteCGRendererFont, key: UInt64) -> RemoteCGRendererFont {
        guard let firstFont else {
            self.firstFont = (key, font)
            return font
        }
        if firstFont.key == key {
            return firstFont.font
        }
        return storedValue(&otherFonts[RemoteIdentifierKey(value: key), default: font])
    }

    // The resources, for the print process (RemoteSnapshotPrintData), whose recordings name no mesh gradients: the builder's last
    // recording's.
    @_expose(!Cxx)
    func export(to builder: WebKit.RemoteSnapshotPrintDataBuilder) {
        precondition(meshGradients.isEmpty)
        if let firstFont {
            builder.addFont(firstFont.key, firstFont.font.sharedFont)
        }
        for (key, font) in otherFonts {
            builder.addFont(key.value, font.sharedFont)
        }
        for (key, gradient) in gradients {
            builder.addGradient(key.value, gradient)
        }
        for (key, path) in paths {
            builder.addPath(key.value, path)
        }
    }
}

// What a RemoteCGRenderer looks up by identifier, as RemoteGraphicsContext's handlers do, and what it draws into:
// - an image buffer's receiver's: its rendering backend's resource cache and image buffers, and the buffer;
// - a recorder's: the backend's, which it copies into its recording's resources as it records each message;
// - a replay's into a context: only the resources of the recordings it replays;
// - the print process's recorder's, which records a snapshot's recordings again: those that the GPU process sent with each.
// While a recording is replayed (beginReplay()), its resources are the ones looked up.
final class RemoteCGRendererResources {
    // The backend whose resources are looked up, and whose shared resource cache allocates the images of the filters that the
    // receiver applies: none for a replay or the print process.
    let backend: WebKit.RemoteRenderingBackend?
    private let cache: RemoteResourceCache?
    // The image buffer that the receiver draws into, if it draws into one.
    let targetImageBuffer: WebCore.ImageBuffer?
    // What a recorder records, made when it records the first resource: receivers and replays record none.
    private var recordedResources: RemoteCGRendererRecordedResources?
    private var replayedResources: [RemoteCGRendererRecordedResources] = []
    // The copy of the target that the receiver draws an accelerated target into itself from (imageBufferImage()), which the
    // receiver lets go after the draw.
    private var selfCopy: WebCore.ImageBuffer?

    // An image buffer's receiver's.
    init(backend: WebKit.RemoteRenderingBackend, target: WebCore.ImageBuffer) {
        self.backend = backend
        self.cache = backend.state.resources.cache
        self.targetImageBuffer = target
    }

    // A recorder's.
    init(recorderOf backend: WebKit.RemoteRenderingBackend) {
        self.backend = backend
        self.cache = backend.state.resources.cache
        self.targetImageBuffer = nil
    }

    // A replay's into the context that lends its renderer for it (GraphicsContextCG::lendSwiftRendererForReplay()), and the
    // print process's recorder's.
    private init() {
        self.backend = nil
        self.cache = nil
        self.targetImageBuffer = nil
    }

    static func forReplay() -> RemoteCGRendererResources {
        RemoteCGRendererResources()
    }

    deinit {
        assert(replayedResources.isEmpty)
    }

    // The backend's resources are its work queue's (assertIsCurrent(workQueue())).
    private func assertIsOnWorkQueue() {
        #if ASSERT_ENABLED
        if let backend {
            assert(backend.workQueue().isCurrent())
        }
        #endif
    }

    // Makes the recording's resources the ones looked up, until the matching endReplay(). Replays nest.
    func beginReplay(_ resources: RemoteCGRendererRecordedResources) {
        replayedResources.append(resources)
    }

    func endReplay() {
        replayedResources.removeLast()
    }

    // The resources, by identifier: the backend's, or, in a replay, those the recording kept.
    func cachedPath(_ identifier: WebKit.RemotePathImplIdentifier) -> WebCore.PathImpl? {
        let key = identifier.toUInt64()
        if let replayed = replayedResources.last {
            return replayed.path(key: key)
        }
        assertIsOnWorkQueue()
        return cache?.path(key: key)
    }

    func cachedGradient(_ identifier: WebKit.RemoteGradientIdentifier) -> WebCore.Gradient? {
        let key = identifier.toUInt64()
        if let replayed = replayedResources.last {
            return replayed.gradient(key: key)
        }
        assertIsOnWorkQueue()
        return cache?.gradient(key: key)
    }

    func cachedMeshGradient(_ identifier: WebKit.RemoteMeshGradientIdentifier) -> WebCore.MeshGradient? {
        let key = identifier.toUInt64()
        if let replayed = replayedResources.last {
            return replayed.meshGradient(key: key)
        }
        assertIsOnWorkQueue()
        return cache?.meshGradient(key: key)
    }

    func cachedFont(key: UInt64) -> RemoteCGRendererFont? {
        if let replayed = replayedResources.last {
            return replayed.font(key: key)
        }
        assertIsOnWorkQueue()
        return cache?.font(key: key)
    }

    // The resources that a recorder's message names, copied into its recording's as RemoteGraphicsContext looks them up for a
    // WebCore display list recorder: false where one is missing, which is an invalid message. The recording keeps the native
    // images and image buffers that its draws name, and its filters, itself (RemoteCGRendererRecording).
    func recordPath(_ identifier: WebKit.RemotePathImplIdentifier) -> Bool {
        guard let path = cachedPath(identifier) else {
            return false
        }
        recording().addPath(path, key: identifier.toUInt64())
        return true
    }

    func recordGradient(_ identifier: WebKit.RemoteGradientIdentifier) -> Bool {
        guard let gradient = cachedGradient(identifier) else {
            return false
        }
        recording().addGradient(gradient, key: identifier.toUInt64())
        return true
    }

    // A DrawGlyphs's font, which the recorded run keeps, with its facts for the run. A recording draws every run of an
    // identifier in the font it first recorded for it, as the print process does.
    func recordGlyphs(_ fontIdentifier: IPCTypes.RenderingResourceIdentifier, _ glyphs: IPCTypes.GlyphRun) -> Bool {
        guard let font = cachedFont(key: fontIdentifier.rawValue) else {
            return false
        }
        let recordedFont = recording().addFont(font, key: fontIdentifier.rawValue)
        let glyphStorage = glyphs.storage.glyphs
        let facts = recordedFont.factsForGlyphs(glyphStorage.span.extracting(0..<glyphs.count))
        glyphs.storage.setRecordedFont(recordedFont.ctFont, facts: facts)
        return true
    }

    func recordMeshGradient(_ identifier: WebKit.RemoteMeshGradientIdentifier) -> Bool {
        guard let gradient = cachedMeshGradient(identifier) else {
            return false
        }
        recording().addMeshGradient(gradient, key: identifier.toUInt64())
        return true
    }

    // The recorder's recording's resources, for its recording, after which it records into new ones, and a copy of them, for a
    // recording of what it recorded so far.
    func takeRecordedResources() -> RemoteCGRendererRecordedResources {
        let taken = recordedResources ?? RemoteCGRendererRecordedResources()
        recordedResources = nil
        return taken
    }

    func copyRecordedResources() -> RemoteCGRendererRecordedResources {
        guard let recordedResources else {
            return RemoteCGRendererRecordedResources()
        }
        return RemoteCGRendererRecordedResources(copying: recordedResources)
    }

    private func recording() -> RemoteCGRendererRecordedResources {
        if let recordedResources {
            return recordedResources
        }
        let recording = RemoteCGRendererRecordedResources()
        recordedResources = recording
        return recording
    }

    // The image of an image buffer that the receiver looks up, as GraphicsContext draws one (nativeImageForDrawing()), with the
    // color matrix that inverts it where the options do; a nil image buffer isn't found. An accelerated target drawn into
    // itself is drawn from a flushed copy of itself (clonesAcceleratedTarget), which the facts say, and which the receiver lets
    // go after the draw (releaseSelfCopy()).
    func imageBufferImage(
        _ found: WebCore.ImageBuffer?,
        _ sourceRect: WebCore.FloatRect,
        _ options: WebCore.RasterDrawingOptions,
        clonesAcceleratedTarget: Bool,
        _ facts: inout CGRendererImageFacts
    ) -> CGImage? {
        facts = CGRendererImageFacts()
        facts.resolutionScale = 1
        guard var imageBuffer = found else {
            return nil
        }
        facts.found = true
        if clonesAcceleratedTarget, isSameImageBuffer(imageBuffer, targetImageBuffer), imageBuffer.renderingMode() == .Accelerated {
            guard let clone = imageBuffer.clone().get() else {
                return nil
            }
            clone.flushDrawingContext()
            facts.isSelfCopy = true
            selfCopy = clone
            imageBuffer = clone
        }
        facts.resolutionScale = imageBuffer.resolutionScale()
        var scaledSourceRect = sourceRect
        scaledSourceRect.scale(facts.resolutionScale)
        guard
            let image = CGRendererCopyImageBufferImageForDrawing(
                targetImageBuffer,
                imageBuffer,
                scaledSourceRect,
                options,
                &facts
            )
        else {
            releaseSelfCopy()
            facts.isSelfCopy = false
            return nil
        }
        return image
    }

    func releaseSelfCopy() {
        selfCopy = nil
    }

    // The brush of a SetFillPatternImageBuffer or a SetStrokePatternImageBuffer: nil for the image buffer the receiver draws
    // into, which is an invalid message.
    func imageBufferPatternBrush(_ tileImageBuffer: WebCore.ImageBuffer, _ pattern: WebCore.PatternParameters) -> CGRendererBrushSource? {
        if isSameImageBuffer(tileImageBuffer, targetImageBuffer) {
            return nil
        }
        return CGRendererImageBufferPatternBrushSource(tileImageBuffer, pattern)
    }

    // The allocator of the images of the filters that a RemoteCGRenderer applies (RemoteCGRendererFilters.swift): the
    // backend's shared resource cache's, as RemoteGraphicsContext's, or for a replay or a renderer without a backend, the
    // default one.
    func filterImageAllocator(forReplay: Bool) -> WebCore.FilterImageAllocator {
        WebKit.createFilterImageAllocator(forReplay ? nil : backend)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
