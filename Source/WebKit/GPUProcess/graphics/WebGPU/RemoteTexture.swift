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

// Receives the messages of a WebGPU texture, on its stream connection's work queue, and calls its TextureImpl. The
// views it makes go in the registry, with their receivers.
@_expose(Cxx)
final class RemoteTexture {
    private let texture: TextureReference
    private let link: WebGPURegistryLink

    @_expose(!Cxx)
    private init(_ texture: TextureReference, _ link: WebGPURegistryLink) {
        self.texture = texture
        self.link = link
    }

    // Adds the texture, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ texture: TextureReference, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemoteTexture(texture, link)
        let registration = IPC.registerSwiftStreamReceiver(objects.host, receiver.getMessageReceiver(), .RemoteTexture, link.identifier)
        objects.add(link.identifier, texture, receiver: receiver, registration: registration)
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteTextureMessageForwarder {
        WebKit.RemoteTextureMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
    }

    func createView(descriptor: IPCTypes.TextureViewDescriptor?, identifier: IPCTypes.WebGPUIdentifier) {
        guard let viewLink = link.child(identifier) else {
            return
        }
        RemoteTextureView.add(texture.createView(descriptor.map { GPUTextureViewDescriptor($0) }, label: descriptor?.label), viewLink)
    }

    func destroy() {
        texture.destroy()
    }

    func undestroy() {
        texture.undestroy()
    }

    func destruct() {
        link.remove()
    }

    func setLabel(label: String?) {
        texture.setLabel(label)
    }
}

extension GPUTextureViewDescriptor {
    fileprivate init(_ descriptor: IPCTypes.TextureViewDescriptor) {
        self.init()
        format = descriptor.format.map { sameNumbering($0) }
        dimension = descriptor.dimension.map { sameNumbering($0) }
        baseMipLevel = descriptor.baseMipLevel
        mipLevelCount = descriptor.mipLevelCount
        baseArrayLayer = descriptor.baseArrayLayer
        arrayLayerCount = descriptor.arrayLayerCount
        aspect = sameNumbering(descriptor.aspect)
        usage = descriptor.usage.rawValue
        swizzle = WebGPU.TextureComponentSwizzle(descriptor.swizzle)
    }
}

extension WebGPU.TextureComponentSwizzle {
    fileprivate init(_ swizzle: IPCTypes.TextureComponentSwizzle) {
        self.init()
        r = sameNumbering(swizzle.r)
        g = sameNumbering(swizzle.g)
        b = sameNumbering(swizzle.b)
        a = sameNumbering(swizzle.a)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
