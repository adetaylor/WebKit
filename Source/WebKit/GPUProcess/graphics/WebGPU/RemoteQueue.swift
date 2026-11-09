// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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


#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT

@_spi(WebKitGPU) import WebGPUSwift
internal import WebGPU_Private
import WebKit_Internal

// Receives the messages of a WebGPU queue, on its stream connection's work queue, and calls its QueueImpl, with the
// references of the objects they name, from the registry. The writes and copies whose sources are shared memory, image
// buffers or video frames, which WebCore's types carry, go to C++.
@_expose(Cxx)
final class RemoteQueue {
    private let queue: QueueReference
    private let link: WebGPURegistryLink
    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    private let videoFrames: WebKit.WebGPUSwiftVideoFrames?
    #endif

    @_expose(!Cxx)
    private init(_ queue: QueueReference, _ link: WebGPURegistryLink) {
        self.queue = queue
        self.link = link
        #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
        videoFrames = link.objects.flatMap { WebKit.WebGPUSwiftVideoFrames.create($0.host) }
        #endif
    }

    // Adds the queue, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ queue: QueueReference, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemoteQueue(queue, link)
        let registration = WebKit.registerWebGPUSwiftReceiver(objects.host, receiver.getMessageReceiver(), .RemoteQueue, link.identifier)
        objects.add(link.identifier, queue, receiver: receiver, registration: registration)
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteQueueMessageForwarder {
        WebKit.RemoteQueueMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
    }

    func destruct() {
        link.remove()
    }

    func submit(commandBuffers: [IPCTypes.WebGPUIdentifier]) {
        guard let objects = link.objects else {
            return
        }
        var references: [CommandBufferReference] = []
        references.reserveCapacity(commandBuffers.count)
        for identifier in commandBuffers {
            let commandBuffer = objects.object(identifier, as: CommandBufferReference.self)
            assert(commandBuffer != nil)
            guard let commandBuffer else {
                return
            }
            references.append(commandBuffer)
        }
        queue.submit(references)
    }

    func onSubmittedWorkDone(reply: consuming RemoteQueueOnSubmittedWorkDoneReply) {
        let pendingReply = CopyableBox(value: reply)
        queue.onSubmittedWorkDone { _ in
            if let reply = pendingReply.take() {
                reply.send()
            }
        }
    }

    // The data of a write with copy is lent from the message, whose buffer the web process can still write to, so
    // it is copied once, and WebGPU, which may read it more than once, sees only the copy. Writes of up to
    // reusedCopySize bytes are copied into the same storage each time.
    private static let reusedCopySize = 64 * 1024
    private var copiedData: [UInt8] = []

    private func withCopy(of data: IPC.LentBytes, _ body: (Span<UInt8>) -> Void) {
        guard data.size() <= Self.reusedCopySize else {
            let copy = data.copied()
            body(copy.span)
            return
        }
        data.copyBytes(into: &copiedData)
        // A local reference, as a span of a stored property would last only for the access to it.
        let copy = copiedData
        body(copy.span)
    }

    func writeBufferWithCopy(identifier: IPCTypes.WebGPUIdentifier, bufferOffset: UInt64, data: IPC.LentBytes) throws(InvalidMessage) {
        let buffer = link.objects?.object(identifier, as: BufferReference.self)
        assert(buffer != nil)
        guard let buffer else {
            return
        }
        try messageCheck {
            WebKit.isValidWebGPUWriteWithCopySize(data.size())
        }
        withCopy(of: data) { bytes in
            queue.writeBuffer(buffer, bufferOffset, bytes)
        }
    }

    func writeBuffer(
        identifier: IPCTypes.WebGPUIdentifier,
        bufferOffset: UInt64,
        data: CxxDecodedArguments.RemoteQueue.WriteBufferData,
        reply: consuming RemoteQueueWriteBufferReply
    ) {
        let buffer = link.objects?.object(identifier, as: BufferReference.self)
        assert(buffer != nil)
        guard let buffer else {
            reply.send(false)
            return
        }
        // A large write reads the mapping in place, and keeps it alive until the GPU has.
        guard let bytes = WebKit.mapSharedMemory(data).value else {
            reply.send(false)
            return
        }
        queue.writeBuffer(buffer, bufferOffset, bytes)
        reply.send(true)
    }

    func writeTexture(
        destination: IPCTypes.ImageCopyTexture,
        dataHandle: CxxDecodedArguments.RemoteQueue.WriteTextureDataHandle,
        imageDataLayout: IPCTypes.ImageDataLayout,
        size: IPCTypes.Extent3D,
        reply: consuming RemoteQueueWriteTextureReply
    ) {
        let bytes = WebKit.mapSharedMemory(dataHandle).value
        let texture = link.objects?.object(destination.texture, as: TextureReference.self)
        assert(texture != nil)
        guard let texture, let bytes else {
            reply.send(false)
            return
        }
        queue.writeTexture(texture, TextureCopyLocation(destination), bytes, WebGPU.TexelCopyBufferLayout(imageDataLayout), WebGPU.Extent3D(size))
        reply.send(true)
    }

    func writeTextureWithCopy(
        destination: IPCTypes.ImageCopyTexture,
        data: IPC.LentBytes,
        imageDataLayout: IPCTypes.ImageDataLayout,
        size: IPCTypes.Extent3D
    ) throws(InvalidMessage) {
        let texture = link.objects?.object(destination.texture, as: TextureReference.self)
        assert(texture != nil)
        guard let texture else {
            return
        }
        try messageCheck {
            WebKit.isValidWebGPUWriteWithCopySize(data.size())
        }
        withCopy(of: data) { bytes in
            queue.writeTexture(texture, TextureCopyLocation(destination), bytes, WebGPU.TexelCopyBufferLayout(imageDataLayout), WebGPU.Extent3D(size))
        }
    }

    // Synchronous, so that the source image buffer can't be released before C++ resolves it, and so that drawing
    // recorded against the source after this call can't be applied before the copy is encoded.
    func copyExternalImageToTexture(
        source: IPCTypes.ImageCopyExternalImage,
        destination: IPCTypes.ImageCopyTextureTagged,
        copySize: IPCTypes.Extent3D
    ) {
        let texture = link.objects?.object(destination.texture, as: TextureReference.self)
        assert(texture != nil)
        guard let objects = link.objects, let texture, let imageBufferIdentifier = source.imageBufferIdentifier else {
            return
        }
        let origin = source.origin.map { WebGPU.Origin2D($0) } ?? WebGPU.Origin2D()
        guard let image = WebKit.webGPUExternalImage(objects.host, imageBufferIdentifier.rawValue, origin, source.flipY, source.premultipliedAlpha).value else {
            return
        }
        queue.copyExternalImageToTexture(GPUCopyExternalImageSource(image), texture, GPUCopyExternalImageDestination(destination), WebGPU.Extent3D(copySize))
    }

    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    func setSharedVideoFrameSemaphore(
        semaphore: borrowing IPCTypes.Semaphore
    ) {
        videoFrames?.setSemaphore(semaphore.port)
    }

    func setSharedVideoFrameMemory(
        storageHandle: borrowing IPCTypes.SharedMemoryHandle
    ) {
        videoFrames?.setSharedMemory(storageHandle.port, storageHandle.size)
    }

    func copyExternalImageFromVideoFrameToTexture(
        source: CxxDecodedArguments.RemoteQueue.CopyExternalImageFromVideoFrameToTextureSource,
        destination: IPCTypes.ImageCopyTextureTagged,
        copySize: IPCTypes.Extent3D
    ) {
        let texture = link.objects?.object(destination.texture, as: TextureReference.self)
        assert(texture != nil)
        guard let texture, let image = videoFrames?.externalImage(source).value else {
            return
        }
        queue.copyExternalImageToTexture(GPUCopyExternalImageSource(image), texture, GPUCopyExternalImageDestination(destination), WebGPU.Extent3D(copySize))
    }
    #endif

    func setLabel(label: String?) {
        queue.setLabel(label)
    }
}

extension GPUCopyExternalImageSource {
    // The WebGPU implementation's form of the source that webGPUExternalImage() or WebGPUSwiftVideoFrames resolves.
    fileprivate init(_ source: borrowing WebGPU.ImageCopyExternalImage) {
        self.init()
        surface = WebGPU.sourceSurface(source)
        sourceFormat = Optional(fromCxx: source.sourceFormat)
        sourceSize = source.sourceSize
        pixelBuffer = WebGPU.sourcePixelBuffer(source)
        pixelBufferRotation = source.pixelBufferRotation
        pixelBufferIsMirrored = source.pixelBufferIsMirrored
        origin = source.origin
        flipY = source.flipY
        hasAlpha = source.hasAlpha
        premultipliedAlpha = source.premultipliedAlpha
        colorSpace = source.colorSpace
    }
}

extension GPUCopyExternalImageDestination {
    // ConvertFromBackingContext's conversion of the destination, apart from the texture.
    fileprivate init(_ destination: IPCTypes.ImageCopyTextureTagged) {
        self.init()
        mipLevel = destination.mipLevel
        origin = destination.origin.map { WebGPU.Origin3D($0) } ?? WebGPU.Origin3D()
        aspect = sameNumbering(destination.aspect)
        colorSpace = sameNumbering(destination.colorSpace)
        premultipliedAlpha = destination.premultipliedAlpha
    }
}

extension WebGPU.Origin2D {
    fileprivate init(_ origin: IPCTypes.Origin2D) {
        self.init()
        x = origin.x
        y = origin.y
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
