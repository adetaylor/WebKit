// Copyright (C) 2021-2023 Apple Inc. All rights reserved.
// Copyright (C) 2024-2026 Apple Inc. All rights reserved.
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

// Receives the messages of a WebXR sub-image, on its stream connection's work queue, and calls its XRSubImageReference.
// The textures it gives go in the registry, with their receivers.
@_expose(Cxx)
final class RemoteXRSubImage {
    private let subImage: XRSubImageReference
    private let link: WebGPURegistryLink

    @_expose(!Cxx)
    private init(_ subImage: XRSubImageReference, _ link: WebGPURegistryLink) {
        self.subImage = subImage
        self.link = link
    }

    // Adds the sub-image, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ subImage: XRSubImageReference, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemoteXRSubImage(subImage, link)
        let registration = WebKit.registerWebGPUSwiftReceiver(objects.host, receiver.getMessageReceiver(), .RemoteXRSubImage, link.identifier)
        objects.add(link.identifier, subImage, receiver: receiver, registration: registration)
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteXRSubImageMessageForwarder {
        WebKit.RemoteXRSubImageMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
    }

    func destruct() {
        link.remove()
    }

    func getColorTexture(identifier: IPCTypes.WebGPUIdentifier) {
        addTexture(subImage.colorTexture, identifier)
    }

    func getDepthTexture(identifier: IPCTypes.WebGPUIdentifier) {
        addTexture(subImage.depthStencilTexture, identifier)
    }

    private func addTexture(_ texture: TextureReference?, _ identifier: IPCTypes.WebGPUIdentifier) {
        guard let textureLink = link.child(identifier) else {
            return
        }
        assert(texture != nil)
        guard let texture else {
            return
        }
        RemoteTexture.add(texture, textureLink)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
