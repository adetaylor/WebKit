// Copyright (C) 2020-2021 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_WEBGL

internal import WebCoreWebGL
import WebKit_Internal
#if WTF_PLATFORM_COCOA
import CoreVideo
import Dispatch
import Synchronization
#endif

// The GL names of the web process's names for a context's objects, as the HashMap with IntHash that kept them in C++:
// every value is a name, adding a name that is there changes nothing, and a name that isn't there has GL name 0.
struct RemoteGraphicsContextGLObjectNames {
    private enum Slot: UInt8 {
        case empty
        case full
        case deleted
    }

    // Open addressing with linear probing over a power-of-two number of slots, of which at most three quarters are full
    // or deleted, so that every probe ends at an empty slot.
    private var slots = [Slot](repeating: .empty, count: 64)
    private var names = [UInt32](repeating: 0, count: 64)
    private var objects = [UInt32](repeating: 0, count: 64)
    private var count = 0
    private var deletedCount = 0

    func get(_ name: UInt32) -> UInt32 {
        guard let index = index(of: name) else {
            return 0
        }
        return objects[index]
    }

    mutating func add(_ name: UInt32, _ object: UInt32) {
        if index(of: name) != nil {
            return
        }
        if (count + deletedCount + 1) * 4 > slots.count * 3 {
            resize()
        }
        let mask = slots.count - 1
        var index = Int(Self.hash(name)) & mask
        while slots[index] == .full {
            index = (index + 1) & mask
        }
        if slots[index] == .deleted {
            deletedCount -= 1
        }
        slots[index] = .full
        names[index] = name
        objects[index] = object
        count += 1
    }

    mutating func take(_ name: UInt32) -> UInt32 {
        guard let index = index(of: name) else {
            return 0
        }
        let object = objects[index]
        slots[index] = .deleted
        objects[index] = 0
        count -= 1
        deletedCount += 1
        return object
    }

    private func index(of name: UInt32) -> Int? {
        let mask = slots.count - 1
        var index = Int(Self.hash(name)) & mask
        for _ in 0..<slots.count {
            switch slots[index] {
            case .empty:
                return nil
            case .full where names[index] == name:
                return index
            case .full, .deleted:
                index = (index + 1) & mask
            }
        }
        return nil
    }

    // Twice as many slots as names, or more, without the deleted ones.
    private mutating func resize() {
        var capacity = 64
        while capacity < (count + 1) * 4 {
            capacity *= 2
        }
        let oldSlots = slots
        let oldNames = names
        let oldObjects = objects
        slots = [Slot](repeating: .empty, count: capacity)
        names = [UInt32](repeating: 0, count: capacity)
        objects = [UInt32](repeating: 0, count: capacity)
        count = 0
        deletedCount = 0
        for (index, slot) in oldSlots.enumerated() where slot == .full {
            add(oldNames[index], oldObjects[index])
        }
    }

    // WTF::intHash() of a 32-bit integer.
    private static func hash(_ value: UInt32) -> UInt32 {
        var key = value
        key = key &+ ~(key << 15)
        key ^= key >> 10
        key = key &+ (key << 3)
        key ^= key >> 6
        key = key &+ ~(key << 11)
        key ^= key >> 16
        return key
    }
}

// Receives a WebGL context's messages on the work queue of its owner, and makes the GL calls on the WebGL island's context.
// Like any stream receiver, it is confined to the connection's work queue. Its handlers are largely generated by
// Tools/Scripts/generate-gpup-webgl, in RemoteGraphicsContextGLFunctionsGenerated.swift. On Cocoa it makes the context and
// receives the messages that work with the context's C++ shell too; elsewhere its C++ companion,
// RemoteGraphicsContextGLResources, does.
@_expose(Cxx)
final class RemoteGraphicsContextGL {
    @_expose(!Cxx)
    let island: GLContext
    var names = RemoteGraphicsContextGLObjectNames()

    #if WTF_PLATFORM_COCOA
    private let owner: IPC.SwiftReceiverOwner
    private let identifier: UInt64
    private let sharedResourceCache: WebKit.RemoteSharedResourceCache
    #if ENABLE_VIDEO
    private let videoFrameHeap: WebKit.RemoteVideoFrameObjectHeap
    private let videoFrames: SharedVideoFrameSource
    #endif
    // From the start until the receiver stops receiving.
    private var client: WebKit.RemoteGraphicsContextGLClient?
    private var shell: WebCore.GraphicsContextGLCocoa?
    private var estimatedMemoryCost: UInt64?
    private var readbackBytes: [UInt8] = []
    private let idleSpareDrawingBufferReleaseTimer = IdleSpareDrawingBufferReleaseTimer()
    private var idleSpareDrawingBufferReleaseScheduled = false
    private var didDisplaySinceIdleSpareDrawingBufferReleaseScheduled = false

    fileprivate init(island: GLContext, client: WebKit.RemoteGraphicsContextGLClient) {
        self.island = island
        self.owner = client.owner()
        self.identifier = client.identifier()
        self.sharedResourceCache = client.sharedResourceCache()
        #if ENABLE_VIDEO
        self.videoFrameHeap = client.videoFrameObjectHeap()
        let webProcessIdentity = client.webProcessIdentity()
        self.videoFrames = SharedVideoFrameSource(heap: videoFrameHeap.frames, resourceOwner: Bool(fromCxx: webProcessIdentity) ? webProcessIdentity : nil)
        #endif
        self.client = client
        let shell = client.context()
        self.shell = shell
        self.estimatedMemoryCost = Optional(fromCxx: shell.estimatedMemoryCost()).map { UInt64($0) }
    }
    #else
    fileprivate init(island: GLContext) {
        self.island = island
    }
    #endif

    // Only asked for if the forwarder has no shared preferences, which startReceiving(on:) gives it.
    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        WebKit.OptionalSharedPreferencesForWebProcess()
    }

    // The owner's hooks. On other ports nothing is scheduled on the owner, and the receiver's companion,
    // RemoteGraphicsContextGLResources, lets go of the context and of this when the stream connection stops.

    func runScheduledWork() {
        #if WTF_PLATFORM_COCOA
        if client?.takeMemoryCostChange() == true {
            updateMemoryCost()
        }
        if idleSpareDrawingBufferReleaseTimer.takeFired() {
            idleSpareDrawingBufferReleaseTimerFired()
        }
        #endif
    }

    func didStopReceiving() {
        #if WTF_PLATFORM_COCOA
        shell = nil
        client = nil
        readbackBytes = []
        #endif
    }

    func didStopWorkQueue() {
    }

    // Messages to be received, besides the generated ones.

    func ensureExtensionEnabled(glExtension: UInt8) throws(InvalidMessage) {
        let success = island.enableExtension(glExtension)
        try messageCheck {
            success
        }
    }

    func getErrors() -> UInt8 {
        island.getErrors()
    }

    func drawBuffers(bufs: [UInt32]) {
        island.drawBuffers(bufs)
    }

    func drawBuffersEXT(bufs: [UInt32]) {
        island.drawBuffersEXT(bufs)
    }

    func invalidateFramebuffer(glTarget: UInt32, attachments: [UInt32]) {
        island.invalidateFramebuffer(glTarget, attachments)
    }

    func invalidateSubFramebuffer(glTarget: UInt32, attachments: [UInt32], x: Int32, y: Int32, width: Int32, height: Int32) {
        island.invalidateSubFramebuffer(glTarget, attachments, x, y, width, height)
    }

    // Each draw's values, one array per kind, all of the same length.

    func multiDrawArraysANGLE(mode: UInt32, firsts: [Int32], counts: [Int32]) throws(InvalidMessage) {
        try messageCheck {
            firsts.count == counts.count
        }
        island.multiDrawArraysANGLE(mode, firsts, counts)
    }

    func multiDrawArraysInstancedANGLE(mode: UInt32, firsts: [Int32], counts: [Int32], instanceCounts: [Int32]) throws(InvalidMessage) {
        try messageCheck {
            firsts.count == counts.count && firsts.count == instanceCounts.count
        }
        island.multiDrawArraysInstancedANGLE(mode, firsts, counts, instanceCounts)
    }

    func multiDrawElementsANGLE(mode: UInt32, counts: [Int32], offsets: [Int32], type: UInt32) throws(InvalidMessage) {
        try messageCheck {
            counts.count == offsets.count
        }
        island.multiDrawElementsANGLE(mode, counts, offsets, type)
    }

    func multiDrawElementsInstancedANGLE(mode: UInt32, counts: [Int32], offsets: [Int32], instanceCounts: [Int32], type: UInt32) throws(InvalidMessage) {
        try messageCheck {
            counts.count == offsets.count && counts.count == instanceCounts.count
        }
        island.multiDrawElementsInstancedANGLE(mode, counts, offsets, instanceCounts, type)
    }

    func multiDrawArraysInstancedBaseInstanceANGLE(mode: UInt32, firsts: [Int32], counts: [Int32], instanceCounts: [Int32], baseInstances: [UInt32]) throws(InvalidMessage) {
        try messageCheck {
            firsts.count == counts.count && firsts.count == instanceCounts.count && firsts.count == baseInstances.count
        }
        island.multiDrawArraysInstancedBaseInstanceANGLE(mode, firsts, counts, instanceCounts, baseInstances)
    }

    func multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(mode: UInt32, counts: [Int32], offsets: [Int32], instanceCounts: [Int32], baseVertices: [Int32], baseInstances: [UInt32], type: UInt32) throws(InvalidMessage) {
        try messageCheck {
            counts.count == offsets.count && counts.count == instanceCounts.count && counts.count == baseVertices.count && counts.count == baseInstances.count
        }
        island.multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(mode, counts, offsets, instanceCounts, baseVertices, baseInstances, type)
    }

    // One matrix, of which the first columns x rows values are the matrix's, as UniformMatrix*fv of one sends it.
    func uniformMatrixOne(columns: UInt8, rows: UInt8, location: Int32, transpose: Bool, m0: Float, m1: Float, m2: Float, m3: Float, m4: Float, m5: Float, m6: Float, m7: Float, m8: Float, m9: Float, m10: Float, m11: Float, m12: Float, m13: Float, m14: Float, m15: Float) throws(InvalidMessage) {
        let known = island.uniformMatrix(columns: GLint(columns), rows: GLint(rows), location, transpose ? 1 : 0, ANGLEFloat16(values: (m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15)))
        try messageCheck {
            known
        }
    }
}

#if WTF_PLATFORM_COCOA
// Whether the idle spare drawing buffer release timer, which runs on the main thread, has fired since the work queue last
// looked.
private final class IdleSpareDrawingBufferReleaseTimer: Sendable {
    private let fired = Atomic<Bool>(false)

    static let delay: DispatchTimeInterval = .milliseconds(200)

    func fire() {
        fired.store(true, ordering: .releasing)
    }

    func takeFired() -> Bool {
        fired.exchange(false, ordering: .acquiring)
    }
}

// The signal that the display is done with a display buffer, which the context gives once its GPU work is done.
private final class FinishedSignal: Sendable {
    private let semaphore: IPCTypes.Semaphore

    init(_ semaphore: consuming IPCTypes.Semaphore) {
        self.semaphore = semaphore
    }

    func signal() {
        semaphore.signal()
    }
}

// The requests of the contexts for the GPU process's WebGL rendering resources, which it frees a second after the last
// request ends, on the WebGL work queue.
private struct WebGLRenderingResourcesRequests {
    var count = 0
    var freeScheduled = false
}

private let webGLRenderingResourcesRequests = Mutex(WebGLRenderingResourcesRequests())
private let webGLRenderingResourcesFreeDelay: DispatchTimeInterval = .seconds(1)

extension WebKit.RemoteGraphicsContextGLClient {
    @cxx
    @implementation
    static func acquireWebGLRenderingResources() {
        webGLRenderingResourcesRequests.withLock { requests in
            requests.count += 1
        }
    }

    @cxx
    @implementation
    static func releaseWebGLRenderingResources() {
        let schedulesFree = webGLRenderingResourcesRequests.withLock { requests in
            requests.count -= 1
            if requests.count != 0 || requests.freeScheduled {
                return false
            }
            requests.freeScheduled = true
            return true
        }
        if schedulesFree {
            DispatchQueue.main.asyncAfter(deadline: .now() + webGLRenderingResourcesFreeDelay) {
                freeWebGLRenderingResourcesIfUnrequested()
            }
        }
    }

    private static func freeWebGLRenderingResourcesIfUnrequested() {
        let unrequested = webGLRenderingResourcesRequests.withLock { requests in
            requests.freeScheduled = false
            return requests.count == 0
        }
        if unrequested {
            WebKit.releaseWebGLThreadResources()
        }
    }
}

// CoreVideo's CVPixelBuffer is CVBuffer itself in some builds and a class of its own in others.
private func pixelBufferAsCVBuffer<PixelBuffer: AnyObject>(_ pixelBuffer: PixelBuffer) -> CVBuffer {
    // Newer Swift compilers wrongly diagnose a cast to a named CoreVideo type as failing; this is the same cast.
    func cast<Target: AnyObject>(to _: Target.Type) -> Target { pixelBuffer as! Target }
    return cast(to: CVBuffer.self)
}

extension WebKit.RemoteGraphicsContextGLClient {
    @cxx
    @implementation
    func startReceiver() {
        let shell = context()
        let attributes = shell.contextAttributes()
        let knownActiveExtensions = shell.knownActiveExtensions()
        var initializationState = WebKit.RemoteGraphicsContextGLInitializationState()
        initializationState.attributes = attributes
        initializationState.knownActiveExtensions = UInt64(knownActiveExtensions.toRaw())
        initializationState.requestableExtensions = UInt64(shell.requestableExtensions().toRaw())
        initializationState.maxCombinedTextureImageUnits = shell.maxCombinedTextureImageUnits()
        initializationState.maxVertexAttribs = shell.maxVertexAttribs()
        initializationState.maxTextureSize = shell.maxTextureSize()
        initializationState.maxCubeMapTextureSize = shell.maxCubeMapTextureSize()
        initializationState.maxRenderbufferSize = shell.maxRenderbufferSize()
        initializationState.maxViewportDims = shell.maxViewportDims()
        initializationState.maxDrawingBufferSize = shell.maxDrawingBufferSize()
        // MAX_SAMPLES is core in ES3 and otherwise comes from GL_ANGLE_framebuffer_multisample.
        // Querying it without either would just add INVALID_ENUM to the error queue.
        if attributes.isWebGL2 || knownActiveExtensions.contains(.ANGLE_framebuffer_multisample) {
            initializationState.maxSamples = shell.maxSamples()
        }
        if attributes.isWebGL2 {
            initializationState.maxTransformFeedbackSeparateAttribs = shell.maxTransformFeedbackSeparateAttribs()
            initializationState.maxUniformBufferBindings = shell.maxUniformBufferBindings()
            initializationState.uniformBufferOffsetAlignment = shell.uniformBufferOffsetAlignment()
            initializationState.max3DTextureSize = shell.max3DTextureSize()
            initializationState.maxArrayTextureLayers = shell.maxArrayTextureLayers()
        }
        sendWasCreated(&initializationState)
        // Safety: the receiver keeps this, and so the context whose islandShell() this is, and its shell, until it stops
        // receiving messages, and uses the island only for them.
        let island = unsafe GLShell.fromReference(shell.islandShell()).context!
        RemoteGraphicsContextGL(island: island, client: self).startReceiving(on: owner())
    }
}

extension RemoteGraphicsContextGL {
    // Only reached by messages, which come between the start and the stop.
    private var context: WebCore.GraphicsContextGLCocoa {
        guard let shell else {
            preconditionFailure("RemoteGraphicsContextGL has no context")
        }
        return shell
    }

    private var contextClient: WebKit.RemoteGraphicsContextGLClient {
        guard let client else {
            preconditionFailure("RemoteGraphicsContextGL has no context")
        }
        return client
    }

    private func updateMemoryCost() {
        guard let shell else {
            return
        }
        let memoryCost = Optional(fromCxx: shell.estimatedMemoryCost()).map { UInt64($0) }
        if memoryCost == estimatedMemoryCost {
            return
        }
        estimatedMemoryCost = memoryCost
        RemoteGraphicsContextGLProxyMessages.memoryCostChanged(on: owner, to: identifier, memoryCost: memoryCost)
    }

    private func scheduleIdleSpareDrawingBufferRelease() {
        if idleSpareDrawingBufferReleaseScheduled {
            return
        }
        idleSpareDrawingBufferReleaseScheduled = true
        didDisplaySinceIdleSpareDrawingBufferReleaseScheduled = false
        let owner = self.owner
        let timer = idleSpareDrawingBufferReleaseTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + IdleSpareDrawingBufferReleaseTimer.delay) {
            timer.fire()
            owner.scheduleWork()
        }
    }

    private func idleSpareDrawingBufferReleaseTimerFired() {
        idleSpareDrawingBufferReleaseScheduled = false
        guard let shell else {
            return
        }
        if didDisplaySinceIdleSpareDrawingBufferReleaseScheduled {
            if shell.hasSpareDrawingBuffersInUse() {
                scheduleIdleSpareDrawingBufferRelease()
            }
            return
        }
        shell.releaseIdleSpareDrawingBuffers()
    }

    // The messages that work with the context's shell.

    func reshape(width: Int32, height: Int32) {
        if width != 0 && height != 0 {
            context.reshape(width, height)
        } else {
            RemoteGraphicsContextGLProxyMessages.wasLost(on: owner, to: identifier)
        }
    }

    // The finished fence is signalled once the context's GPU work for the display buffer is done.
    func prepareForDisplay(finishedFence: consuming IPCTypes.Semaphore, reply: consuming RemoteGraphicsContextGLPrepareForDisplayReply) {
        let context = self.context
        let finishedSignal = FinishedSignal(finishedFence)
        context.prepareForDisplayWithFinishedSignal(WebKit.RemoteGraphicsContextGLTask {
            finishedSignal.signal()
        })
        reply.send { encoder in
            WebKit.encodeDisplayBuffer(context, encoder)
        }
        didDisplaySinceIdleSpareDrawingBufferReleaseScheduled = true
        if context.hasSpareDrawingBuffersInUse() {
            scheduleIdleSpareDrawingBufferRelease()
        }
    }

    func copyNativeImage(connection: IPC.StreamServerConnection, buffer: WebCore.GraphicsContextGLSurfaceBuffer, nativeImageReference: WebKit.RemoteNativeImageReference) throws(InvalidMessage) {
        let copied = WebKit.copyNativeImage(context, sharedResourceCache, buffer, nativeImageReference)
        try messageCheck {
            copied
        }
    }

    #if ENABLE_MEDIA_STREAM || ENABLE_WEB_CODECS
    func surfaceBufferToVideoFrame(connection: IPC.StreamServerConnection, buffer: WebCore.GraphicsContextGLSurfaceBuffer, reference: WebKit.RemoteVideoFrameReference) -> WebKit.OptionalRemoteVideoFrameProxyProperties {
        WebKit.surfaceBufferToVideoFrame(context, videoFrameHeap, buffer, reference)
    }
    #endif

    #if ENABLE_VIDEO
    func copyTextureFromVideoFrame(frame: consuming IPCTypes.SharedVideoFrame, texture: UInt32, glTarget: UInt32, level: Int32, internalFormat: UInt32, type: UInt32, unpackFlipY: Bool, unpackPremultiplyAlpha: Bool) -> Bool {
        let context = self.context
        guard let read = videoFrames.read(frame) else {
            context.recordVideoUploadForTesting(.NoFrame, 0)
            return false
        }
        return WebKit.copyTextureFromVideoFrame(context, pixelBufferAsCVBuffer(read.pixelBuffer), read.rotation, read.isMirrored, names.get(texture), glTarget, level, internalFormat, type, unpackFlipY, unpackPremultiplyAlpha)
    }

    func setSharedVideoFrameSemaphore(semaphore: consuming IPCTypes.Semaphore) {
        videoFrames.setSemaphore(semaphore)
    }

    func setSharedVideoFrameMemory(storageHandle: consuming IPCTypes.SharedMemoryHandle) {
        videoFrames.setSharedMemory(storageHandle)
    }

    func getLastVideoUploadForTesting(connection: IPC.StreamServerConnection) -> WebCore.GraphicsContextGLVideoUploadRecord {
        Optional(fromCxx: context.lastVideoUploadForTesting()) ?? WebCore.GraphicsContextGLVideoUploadRecord()
    }
    #endif

    func simulateEventForTesting(connection: IPC.StreamServerConnection, event: WebCore.GraphicsContextGLSimulatedEventForTesting) {
        // FIXME: only run this in testing mode. https://bugs.webkit.org/show_bug.cgi?id=222544
        if event == .Timeout {
            // Simulate the timeout by just discarding the context. The subsequent messages act like unauthorized or old
            // messages from the web process: they are skipped.
            contextClient.releaseForTesting()
            return
        }
        context.simulateEventForTesting(event)
    }

    func getBufferSubDataInline(glTarget: UInt32, offset: UInt64, dataSize: UInt64) -> [UInt8] {
        // NOTE: when changing, change the value in RemoteGraphicsContextGLProxy too.
        let getBufferSubDataInlineSizeLimit: UInt64 = 64 * 1024
        let context = self.context
        guard dataSize != 0, dataSize <= getBufferSubDataInlineSizeLimit else {
            context.addError(.InvalidOperation)
            return []
        }
        var data = takeZeroedReadbackBytes(count: Int(dataSize))
        let succeeded = data.withUnsafeMutableBufferPointer { buffer in
            // Safety: the context writes at most the span's bytes, which the buffer holds during the call.
            unsafe context.getBufferSubDataWithStatus(glTarget, Int(truncatingIfNeeded: offset), WTF.MutableSpanUInt8(buffer))
        }
        readbackBytes = data
        return succeeded ? data : []
    }

    func getBufferSubDataSharedMemory(glTarget: UInt32, offset: UInt64, dataSize: UInt64, handle: CxxDecodedArguments.RemoteGraphicsContextGL.GetBufferSubDataSharedMemoryHandle) -> Bool {
        // NOTE: when changing, change the value in RemoteGraphicsContextGLProxy too.
        let readPixelsSharedMemorySizeLimit: UInt64 = 100 * 1024 * 1024
        if dataSize > readPixelsSharedMemorySizeLimit {
            return false
        }
        return contextClient.getBufferSubData(glTarget, offset, dataSize, handle)
    }

    func readPixelsInline(rect: IPCTypes.IntRect, format: UInt32, type: UInt32, packReverseRowOrder: Bool) -> (IPCTypes.IntSize?, [UInt8]) {
        // NOTE: when changing, change the value in RemoteGraphicsContextGLProxy too.
        let readPixelsInlineSizeLimit: UInt32 = 64 * 1024
        let bytesPerGroup = WebCore.GraphicsContextGL.computeBytesPerGroup(format, type)
        let area = (Int64(rect.size.width) * Int64(rect.size.height)).magnitude
        guard bytesPerGroup != 0, area <= UInt64(UInt32.max) else {
            return (nil, [])
        }
        let (replyImageBytes, overflowed) = UInt32(area).multipliedReportingOverflow(by: bytesPerGroup)
        guard !overflowed else {
            return (nil, [])
        }
        let context = self.context
        var pixels: [UInt8] = []
        var readArea: WebCore.IntSize?
        if replyImageBytes <= readPixelsInlineSizeLimit {
            pixels = takeZeroedReadbackBytes(count: Int(replyImageBytes))
            readArea = pixels.withUnsafeMutableBufferPointer { buffer in
                // Safety: the context writes at most the span's bytes, which the buffer holds during the call.
                Optional(fromCxx: unsafe context.readPixelsWithStatus(WebCore.IntRect(rect.location.x, rect.location.y, rect.size.width, rect.size.height), format, type, packReverseRowOrder ? 1 : 0, WTF.MutableSpanUInt8(buffer)))
            }
            readbackBytes = pixels
        } else {
            context.addError(.OutOfMemory)
        }
        guard let readArea else {
            return (nil, [])
        }
        return (IPCTypes.IntSize(width: readArea.width(), height: readArea.height()), pixels)
    }

    // The storage of the last inline readback's reply, which the next one reuses once the reply has gone, so that
    // readbacks don't allocate and free their bytes each time.
    private func takeZeroedReadbackBytes(count: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        swap(&bytes, &readbackBytes)
        bytes.removeAll(keepingCapacity: true)
        bytes.append(contentsOf: repeatElement(0, count: count))
        return bytes
    }

    func readPixelsSharedMemory(rect: IPCTypes.IntRect, format: UInt32, type: UInt32, packReverseRowOrder: Bool, handle: CxxDecodedArguments.RemoteGraphicsContextGL.ReadPixelsSharedMemoryHandle) -> IPCTypes.IntSize? {
        var readArea = WebCore.IntSize()
        guard contextClient.readPixels(rect.location.x, rect.location.y, rect.size.width, rect.size.height, format, type, packReverseRowOrder, handle, &readArea) else {
            return nil
        }
        return IPCTypes.IntSize(width: readArea.width(), height: readArea.height())
    }

    func setDrawingBufferColorSpace(connection: IPC.StreamServerConnection, colorSpace: WebCore.ColorSpace) {
        context.setDrawingBufferColorSpace(colorSpace)
    }

    func activeAttribs(connection: IPC.StreamServerConnection, program: UInt32) -> WebCore.VectorGCGLAttribActiveInfo {
        context.activeAttribs(program != 0 ? names.get(program) : 0)
    }

    func activeUniforms(connection: IPC.StreamServerConnection, program: UInt32) -> WebCore.VectorGCGLUniformActiveInfo {
        context.activeUniforms(program != 0 ? names.get(program) : 0)
    }

    func getTransformFeedbackVarying(connection: IPC.StreamServerConnection, program: UInt32, index: UInt32) -> WebCore.OptionalGCGLTransformFeedbackActiveInfo {
        context.getTransformFeedbackVarying(program != 0 ? names.get(program) : 0, index)
    }

    // The payloads, which the message lends for the call.

    func bufferData1(glTarget: UInt32, data: IPC.LentBytes, usage: UInt32) {
        WebKit.lendBufferData(context, glTarget, data, usage)
    }

    func bufferSubData(glTarget: UInt32, offset: UInt64, data: IPC.LentBytes) {
        WebKit.lendBufferSubData(context, glTarget, offset, data)
    }

    func texImage2D0(glTarget: UInt32, level: Int32, internalformat: UInt32, width: Int32, height: Int32, border: Int32, format: UInt32, type: UInt32, pixels: IPC.LentBytes) {
        WebKit.lendTexImage2D(context, glTarget, level, internalformat, width, height, border, format, type, pixels)
    }

    func texSubImage2D0(glTarget: UInt32, level: Int32, xoffset: Int32, yoffset: Int32, width: Int32, height: Int32, format: UInt32, type: UInt32, pixels: IPC.LentBytes) {
        WebKit.lendTexSubImage2D(context, glTarget, level, xoffset, yoffset, width, height, format, type, pixels)
    }

    func compressedTexImage2D0(glTarget: UInt32, level: Int32, internalformat: UInt32, width: Int32, height: Int32, border: Int32, data: IPC.LentBytes) {
        WebKit.lendCompressedTexImage2D(context, glTarget, level, internalformat, width, height, border, data)
    }

    func compressedTexSubImage2D0(glTarget: UInt32, level: Int32, xoffset: Int32, yoffset: Int32, width: Int32, height: Int32, format: UInt32, data: IPC.LentBytes) {
        WebKit.lendCompressedTexSubImage2D(context, glTarget, level, xoffset, yoffset, width, height, format, data)
    }

    func texImage3D0(glTarget: UInt32, level: Int32, internalformat: Int32, width: Int32, height: Int32, depth: Int32, border: Int32, format: UInt32, type: UInt32, pixels: IPC.LentBytes) {
        WebKit.lendTexImage3D(context, glTarget, level, internalformat, width, height, depth, border, format, type, pixels)
    }

    func texSubImage3D0(glTarget: UInt32, level: Int32, xoffset: Int32, yoffset: Int32, zoffset: Int32, width: Int32, height: Int32, depth: Int32, format: UInt32, type: UInt32, pixels: IPC.LentBytes) {
        WebKit.lendTexSubImage3D(context, glTarget, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels)
    }

    func compressedTexImage3D0(glTarget: UInt32, level: Int32, internalformat: UInt32, width: Int32, height: Int32, depth: Int32, border: Int32, data: IPC.LentBytes) {
        WebKit.lendCompressedTexImage3D(context, glTarget, level, internalformat, width, height, depth, border, data)
    }

    func compressedTexSubImage3D0(glTarget: UInt32, level: Int32, xoffset: Int32, yoffset: Int32, zoffset: Int32, width: Int32, height: Int32, depth: Int32, format: UInt32, data: IPC.LentBytes) {
        WebKit.lendCompressedTexSubImage3D(context, glTarget, level, xoffset, yoffset, zoffset, width, height, depth, format, data)
    }

    #if ENABLE_WEBXR
    private func checkWebXRPromptAccepted() throws(InvalidMessage) {
        let accepted = contextClient.webXRPromptAccepted()
        try messageCheck {
            accepted
        }
    }

    func framebufferDiscard(glTarget: UInt32, attachments: [UInt32]) throws(InvalidMessage) {
        try checkWebXRPromptAccepted()
        let context = self.context
        attachments.withUnsafeBufferPointer { attachments in
            // Safety: the buffer holds its count of attachments during the call, which only reads them.
            unsafe WebKit.framebufferDiscard(context, glTarget, attachments.baseAddress, attachments.count)
        }
    }

    func createExternalImage(connection: IPC.StreamServerConnection, externalImage: UInt32, arg0: WebCore.GraphicsContextGL.ExternalImageSource, internalFormat: UInt32, layer: Int32) throws(InvalidMessage) {
        try checkWebXRPromptAccepted()
        let result = WebKit.createExternalImage(context, arg0, internalFormat, layer)
        if result != 0 {
            names.add(externalImage, result)
        }
    }

    func deleteExternalImage(handle: UInt32) throws(InvalidMessage) {
        try checkWebXRPromptAccepted()
        if handle == 0 {
            return
        }
        context.deleteExternalImage(names.take(handle))
    }

    func bindExternalImage(glTarget: UInt32, arg1: UInt32) throws(InvalidMessage) {
        try checkWebXRPromptAccepted()
        context.bindExternalImage(glTarget, arg1 != 0 ? names.get(arg1) : 0)
    }

    func createExternalSync(connection: IPC.StreamServerConnection, externalSync: UInt32, arg0: WebCore.GraphicsContextGL.ExternalSyncSource) throws(InvalidMessage) {
        try checkWebXRPromptAccepted()
        let result = WebKit.createExternalSync(context, arg0)
        if result != 0 {
            names.add(externalSync, result)
        }
    }

    func deleteExternalSync(arg0: UInt32) throws(InvalidMessage) {
        try checkWebXRPromptAccepted()
        if arg0 == 0 {
            return
        }
        context.deleteExternalSync(names.take(arg0))
    }

    func enableRequiredWebXRExtensions() throws(InvalidMessage) -> Bool {
        let enabled = contextClient.webXREnabled()
        try messageCheck {
            enabled
        }
        return context.enableRequiredWebXRExtensions()
    }

    func addFoveation(physicalSizeLeft: IPCTypes.IntSize, physicalSizeRight: IPCTypes.IntSize, screenSize: IPCTypes.IntSize, horizontalSamplesLeft: [Float], verticalSamples: [Float], horizontalSamplesRight: [Float]) throws(InvalidMessage) -> Bool {
        try checkWebXRPromptAccepted()
        let context = self.context
        return horizontalSamplesLeft.withUnsafeBufferPointer { left in
            verticalSamples.withUnsafeBufferPointer { vertical in
                horizontalSamplesRight.withUnsafeBufferPointer { right in
                    // Safety: each buffer holds its count of samples during the call, which only reads them.
                    unsafe WebKit.addFoveation(context, physicalSizeLeft.width, physicalSizeLeft.height, physicalSizeRight.width, physicalSizeRight.height, screenSize.width, screenSize.height, left.baseAddress, left.count, vertical.baseAddress, vertical.count, right.baseAddress, right.count)
                }
            }
        }
    }

    func enableFoveation(arg0: UInt32) throws(InvalidMessage) {
        try checkWebXRPromptAccepted()
        context.enableFoveation(arg0 != 0 ? names.get(arg0) : 0)
    }

    func disableFoveation() throws(InvalidMessage) {
        try checkWebXRPromptAccepted()
        context.disableFoveation()
    }

    func framebufferResolveRenderbuffer(glTarget: UInt32, attachment: UInt32, renderbuffertarget: UInt32, arg3: UInt32) throws(InvalidMessage) {
        try checkWebXRPromptAccepted()
        context.framebufferResolveRenderbuffer(glTarget, attachment, renderbuffertarget, arg3 != 0 ? names.get(arg3) : 0)
    }
    #endif
}
#endif

#if !WTF_PLATFORM_COCOA
// The members of RemoteGraphicsContextGLResources (RemoteGraphicsContextGLResources.h) that make and reach its Swift state,
// the receiver of the GL calls, on its work queue.
extension WebKit.RemoteGraphicsContextGLResources {
    @cxx
    @implementation
    @unsafe
    func createSwiftState(_ islandShell: UInt) -> UInt {
        // Safety: the caller keeps alive the context whose islandShell() this is, and so its shell.
        let receiver = RemoteGraphicsContextGL(island: unsafe GLShell.fromReference(islandShell).context!)
        receiver.startReceiving(on: swiftReceiverOwner())
        return UInt(bitPattern: unsafe Unmanaged.passRetained(receiver).toOpaque())
    }

    @cxx
    @implementation
    @unsafe
    static func destroySwiftState(_ swiftState: UInt) {
        // Safety: createSwiftState() retained the receiver at this address, and only this releases it.
        _ = unsafe Unmanaged<RemoteGraphicsContextGL>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("RemoteGraphicsContextGLResources has no Swift state")
        }
        return unsafe address
    }

    // Only reached while the receivers receive messages, between createSwiftState() and destroySwiftState().
    private var receiver: RemoteGraphicsContextGL {
        // Safety: m_swiftState is 0 or a retained RemoteGraphicsContextGL that only destroySwiftState() releases, once the
        // receivers no longer receive messages.
        unsafe Unmanaged<RemoteGraphicsContextGL>.fromOpaque(Self.stateAddress(swiftState())).takeUnretainedValue()
    }

    // The names, for the messages that C++ handles.

    @cxx
    @implementation
    func objectName(_ name: UInt32) -> UInt32 {
        receiver.names.get(name)
    }

    @cxx
    @implementation
    func takeObjectName(_ name: UInt32) -> UInt32 {
        receiver.names.take(name)
    }

    @cxx
    @implementation
    func addObjectName(_ name: UInt32, _ object: UInt32) {
        receiver.names.add(name, object)
    }
}
#endif

#endif
