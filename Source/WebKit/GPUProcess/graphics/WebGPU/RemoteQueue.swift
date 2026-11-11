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
// references of the objects they name, from the registry. The copies whose sources are image buffers or video frames,
// which WebCore's types carry, go to C++.
@_expose(Cxx)
final class RemoteQueue {
    private let queue: QueueReference
    private let link: WebGPURegistryLink
    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    private let videoFrames: WebKit.GPUVideoFrameSource?
    #endif

    @_expose(!Cxx)
    private init(_ queue: QueueReference, _ link: WebGPURegistryLink) {
        self.queue = queue
        self.link = link
        #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
        videoFrames = link.objects.flatMap { WebKit.createVideoFrameSource($0.host) }
        #endif
    }

    // Adds the queue, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ queue: QueueReference, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemoteQueue(queue, link)
        let registration = IPC.registerSwiftStreamReceiver(objects.host, receiver.getMessageReceiver(), .RemoteQueue, link.identifier)
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
            isValidWebGPUWriteWithCopySize(data.size())
        }
        withCopy(of: data) { bytes in
            queue.writeBuffer(buffer, bufferOffset, bytes)
        }
    }

    func writeBuffer(
        identifier: IPCTypes.WebGPUIdentifier,
        bufferOffset: UInt64,
        data: consuming IPCTypes.SharedMemoryHandle?,
        reply: consuming RemoteQueueWriteBufferReply
    ) {
        let buffer = link.objects?.object(identifier, as: BufferReference.self)
        assert(buffer != nil)
        guard let buffer else {
            reply.send(false)
            return
        }
        // A large write reads the mapping in place, and keeps it alive until the GPU has.
        guard let bytes = mapWebGPUWriteSharedMemory(data) else {
            reply.send(false)
            return
        }
        queue.writeBuffer(buffer, bufferOffset, gpuByteOwner(bytes))
        reply.send(true)
    }

    func writeTexture(
        destination: IPCTypes.ImageCopyTexture,
        dataHandle: consuming IPCTypes.SharedMemoryHandle?,
        imageDataLayout: IPCTypes.ImageDataLayout,
        size: IPCTypes.Extent3D,
        reply: consuming RemoteQueueWriteTextureReply
    ) {
        let bytes = mapWebGPUWriteSharedMemory(dataHandle)
        let texture = link.objects?.object(destination.texture, as: TextureReference.self)
        assert(texture != nil)
        guard let texture, let bytes else {
            reply.send(false)
            return
        }
        queue.writeTexture(
            texture,
            TextureCopyLocation(destination),
            gpuByteOwner(bytes),
            WebGPU.TexelCopyBufferLayout(imageDataLayout),
            WebGPU.Extent3D(size)
        )
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
            isValidWebGPUWriteWithCopySize(data.size())
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
        var surfaceDescription = WebKit.RemoteGPUImageBufferSurface()
        guard let surface = WebKit.copyImageBufferSurface(objects.host, imageBufferIdentifier.rawValue, &surfaceDescription),
            let sourceFormat = sourceTextureFormat(surfaceDescription.pixelFormat)
        else {
            return
        }
        var image = GPUCopyExternalImageSource()
        image.surface = surface
        image.sourceFormat = sourceFormat.format
        image.sourceSize = WebGPU.Extent2D(width: surfaceDescription.width, height: surfaceDescription.height)
        image.hasAlpha = sourceFormat.hasAlpha
        image.colorSpace = surfaceDescription.isDisplayP3 ? .DisplayP3 : .SRGB
        image.origin = source.origin.map { WebGPU.Origin2D($0) } ?? WebGPU.Origin2D(x: 0, y: 0)
        image.flipY = source.flipY
        // An ImageBitmap created with premultiplyAlpha: "none" was put into its buffer straight, so the caller has to say;
        // a buffer a 2D context composited is premultiplied.
        image.premultipliedAlpha = source.premultipliedAlpha
        queue.copyExternalImageToTexture(image, texture, GPUCopyExternalImageDestination(destination), WebGPU.Extent3D(copySize))
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

    // The frame is the shared one the message carries, or else the one the media player shows. A frame which could not be
    // resolved leaves the destination texture alone, exactly as a video with nothing decoded yet did on the readback path.
    func copyExternalImageFromVideoFrameToTexture(
        origin: IPCTypes.Origin2D?,
        flipY: Bool,
        mediaIdentifier: IPCTypes.MediaPlayerIdentifier?,
        sharedFrame: CxxDecodedArguments.RemoteQueue.CopyExternalImageFromVideoFrameToTextureSharedFrame,
        destination: IPCTypes.ImageCopyTextureTagged,
        copySize: IPCTypes.Extent3D
    ) {
        let texture = link.objects?.object(destination.texture, as: TextureReference.self)
        assert(texture != nil)
        guard let texture, let videoFrames else {
            return
        }
        var result = WebKit.GPUVideoFrameReadResult()
        var pixelBuffer = WebKit.readSharedVideoFrame(videoFrames, sharedFrame, &result)
        if result.isInvalid {
            return
        }
        if !result.hadFrame, let mediaIdentifier {
            pixelBuffer = WebKit.copyMediaPlayerFrame(videoFrames, mediaIdentifier.rawValue, &result)
        }
        guard let pixelBuffer else {
            return
        }
        // A decoded frame carries its extent, its crop and its primaries, and is opaque, so its alpha is replaced with 1 the
        // way an external texture's is. The display transform is the one thing about the frame its pixel buffer does not carry.
        var image = GPUCopyExternalImageSource()
        image.pixelBuffer = pixelBuffer
        image.pixelBufferRotation = videoFrameRotation(result.rotation)
        image.pixelBufferIsMirrored = result.isMirrored
        image.origin = origin.map { WebGPU.Origin2D($0) } ?? WebGPU.Origin2D(x: 0, y: 0)
        image.flipY = flipY
        image.hasAlpha = false
        image.premultipliedAlpha = true
        queue.copyExternalImageToTexture(image, texture, GPUCopyExternalImageDestination(destination), WebGPU.Extent3D(copySize))
    }
    #endif

    func setLabel(label: String?) {
        queue.setLabel(label)
    }
}

// The texture format of the IOSurface that an accelerated ImageBuffer of this pixel format is backed by, plus whether its
// alpha channel holds meaningful data. nil for the formats GPUQueue::copyExternalImageToTexture keeps on the CPU readback
// path.
private func sourceTextureFormat(_ pixelFormat: WebCore.PixelFormat) -> (format: WebGPU.TextureFormat, hasAlpha: Bool)? {
    switch pixelFormat {
    case .RGBA8:
        return (.Rgba8unorm, true)
    case .BGRA8:
        return (.Bgra8unorm, true)
    case .BGRX8:
        // IOSurface::Format::BGRX uses the same IOSurface pixel format as BGRA, but CoreGraphics renders into it with
        // kCGImageAlphaNoneSkipFirst, so the alpha byte is undefined.
        return (.Bgra8unorm, false)
    case .RGBX8:
        return (.Rgba8unorm, false)
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    case .RGBA16F:
        return (.Rgba16float, true)
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16
    case .RGBA16:
        return (.Rgba16unorm, true)
    #endif
    default:
        // Packed 10-bit surfaces have no single-plane MTLPixelFormat equivalent.
        return nil
    }
}

#if WTF_PLATFORM_COCOA && ENABLE_VIDEO
// WebCore::VideoFrameRotation's degrees.
private func videoFrameRotation(_ degrees: UInt16) -> WebGPU.VideoFrameRotation {
    switch degrees {
    case 90:
        return .Right
    case 180:
        return .UpsideDown
    case 270:
        return .Left
    default:
        return .None
    }
}
#endif

extension GPUCopyExternalImageDestination {
    // ConvertFromBackingContext's conversion of the destination, apart from the texture.
    fileprivate init(_ destination: IPCTypes.ImageCopyTextureTagged) {
        self.init()
        mipLevel = destination.mipLevel
        origin = destination.origin.map { WebGPU.Origin3D($0) } ?? WebGPU.Origin3D(x: 0, y: 0, z: 0)
        aspect = sameNumbering(destination.aspect)
        colorSpace = sameNumbering(destination.colorSpace)
        premultipliedAlpha = destination.premultipliedAlpha
    }
}

extension WebGPU.Origin2D {
    fileprivate init(_ origin: IPCTypes.Origin2D) {
        self.init(
            x: origin.x,
            y: origin.y
        )
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
