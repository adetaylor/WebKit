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
    @used
    func getMessageReceiver() -> RefRemoteQueueMessageForwarder {
        WebKit.RemoteQueueMessageForwarder.create(target: self)
    }

    @used
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
            let commandBuffer = objects.commandBuffer(identifier)
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

    func writeBufferWithCopy(identifier: IPCTypes.WebGPUIdentifier, bufferOffset: UInt64, data: [UInt8]) {
        let buffer = link.objects?.object(identifier, as: BufferReference.self)
        assert(buffer != nil)
        guard let buffer else {
            return
        }
        queue.writeBuffer(buffer, bufferOffset, data.span)
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
        reply.send(WebKit.writeSharedMemoryToBuffer(queue.apiObject, buffer.apiObject, data, bufferOffset))
    }

    func writeTexture(
        destination: CxxDecodedArguments.RemoteQueue.WriteTextureDestination,
        dataHandle: CxxDecodedArguments.RemoteQueue.WriteTextureDataHandle,
        imageDataLayout: CxxDecodedArguments.RemoteQueue.WriteTextureImageDataLayout,
        size: CxxDecodedArguments.RemoteQueue.WriteTextureSize,
        reply: consuming RemoteQueueWriteTextureReply
    ) {
        guard let objects = link.objects else {
            reply.send(false)
            return
        }
        reply.send(objects.host.writeSharedMemoryToTexture(queue.apiObject, destination, dataHandle, imageDataLayout, size))
    }

    func writeTextureWithCopy(
        destination: IPCTypes.ImageCopyTexture,
        data: [UInt8],
        imageDataLayout: IPCTypes.ImageDataLayout,
        size: IPCTypes.Extent3D
    ) {
        let texture = link.objects?.texture(destination.texture)
        assert(texture != nil)
        guard let texture else {
            return
        }
        queue.writeTexture(texture, TextureCopyLocation(destination), data.span, WebGPU.TexelCopyBufferLayout(imageDataLayout), WebGPU.Extent3D(size))
    }

    // Synchronous, so that the source image buffer can't be released before C++ resolves it, and so that drawing
    // recorded against the source after this call can't be applied before the copy is encoded.
    func copyExternalImageToTexture(
        source: CxxDecodedArguments.RemoteQueue.CopyExternalImageToTextureSource,
        destination: CxxDecodedArguments.RemoteQueue.CopyExternalImageToTextureDestination,
        copySize: CxxDecodedArguments.RemoteQueue.CopyExternalImageToTextureCopySize
    ) {
        link.objects?.host.copyExternalImageToTexture(queue.apiObject, source, destination, copySize)
    }

    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    func setSharedVideoFrameSemaphore(
        semaphore: CxxDecodedArguments.RemoteQueue.SetSharedVideoFrameSemaphoreSemaphore
    ) {
        videoFrames?.setSemaphore(semaphore)
    }

    func setSharedVideoFrameMemory(
        storageHandle: CxxDecodedArguments.RemoteQueue.SetSharedVideoFrameMemoryStorageHandle
    ) {
        videoFrames?.setSharedMemory(storageHandle)
    }

    func copyExternalImageFromVideoFrameToTexture(
        source: CxxDecodedArguments.RemoteQueue.CopyExternalImageFromVideoFrameToTextureSource,
        destination: CxxDecodedArguments.RemoteQueue.CopyExternalImageFromVideoFrameToTextureDestination,
        copySize: CxxDecodedArguments.RemoteQueue.CopyExternalImageFromVideoFrameToTextureCopySize
    ) {
        videoFrames?.copyExternalImageFromVideoFrameToTexture(queue.apiObject, source, destination, copySize)
    }
    #endif

    func setLabel(label: String?) {
        queue.setLabel(label)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
