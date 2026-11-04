// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

import CoreGraphics
import IOSurface
@_spi(WebKitGPU) import WebGPUSwift
import WebKit_Internal

// Receives the messages of a WebGPU canvas context, on its stream connection's work queue, and calls its
// PresentationContextIOSurfaceImpl. The current textures it gives go in the registry, with their receivers.
@_expose(Cxx)
final class RemotePresentationContext {
    private let presentationContext: PresentationContextReference
    private let link: WebGPURegistryLink

    @_expose(!Cxx)
    private init(_ presentationContext: PresentationContextReference, _ link: WebGPURegistryLink) {
        self.presentationContext = presentationContext
        self.link = link
    }

    // Adds the canvas context, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ presentationContext: PresentationContextReference, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemotePresentationContext(presentationContext, link)
        let registration = WebKit.registerWebGPUSwiftReceiver(objects.host, receiver.getMessageReceiver(), .RemotePresentationContext, link.identifier)
        objects.add(link.identifier, presentationContext, receiver: receiver, registration: registration)
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemotePresentationContextMessageForwarder {
        WebKit.RemotePresentationContextMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
    }

    // Does nothing if the configuration's device doesn't exist, as converting the configuration did.
    func configure(configuration: IPCTypes.CanvasConfiguration) {
        guard let device = link.objects?.object(configuration.device, as: DeviceReference.self) else {
            return
        }
        var canvasConfiguration = GPUCanvasConfiguration(device: device)
        canvasConfiguration.format = sameNumbering(configuration.format)
        canvasConfiguration.usage = configuration.usage.rawValue
        canvasConfiguration.viewFormats = configuration.viewFormats.map { sameNumbering($0) }
        canvasConfiguration.colorSpace = sameNumbering(configuration.colorSpace)
        canvasConfiguration.toneMappingMode = sameNumbering(configuration.toneMappingMode)
        canvasConfiguration.compositingAlphaMode = sameNumbering(configuration.compositingAlphaMode)
        canvasConfiguration.reportValidationErrors = configuration.reportValidationErrors
        canvasConfiguration.width = configuration.width
        canvasConfiguration.height = configuration.height
        presentationContext.configure(canvasConfiguration)
    }

    func unconfigure() {
        presentationContext.unconfigure()
    }

    // The web process names the texture rather than waiting for a reply, so each current texture gets a receiver of its
    // own under the identifier it names, even when it is one that an earlier message got.
    func getCurrentTexture(identifier: IPCTypes.WebGPUIdentifier, frameIndex: UInt32) {
        guard let texture = presentationContext.getCurrentTexture(frameIndex), let textureLink = link.child(identifier) else {
            return
        }
        RemoteTexture.add(texture, textureLink)
    }

    func present(frameIndex: UInt32) {
        presentationContext.present(frameIndex)
    }
}

// A canvas context as the compositor integration that shows it holds it, to give it the render buffers and to present
// and read back its frames. Used on the RemoteGPU's work queue.
@_expose(Cxx)
final class WebGPUCompositorCanvas {
    private let presentationContext: PresentationContextReference

    @_expose(!Cxx)
    init(_ presentationContext: PresentationContextReference) {
        self.presentationContext = presentationContext
    }

    func unconfigure() {
        presentationContext.unconfigure()
    }

    func renderBuffersWereRecreated() {
        presentationContext.renderBuffersWereRecreated()
    }

    func addRenderBuffer(_ surface: IOSurfaceRef) {
        presentationContext.addRenderBuffer(surface as IOSurface)
    }

    func present(_ frameIndex: UInt32) {
        presentationContext.present(frameIndex)
    }

    // Calls the completion once the configured device's queue has scheduled the work submitted so far.
    func onSubmittedWorkScheduled(_ completion: WebKit.WebGPUSwiftCompletion) {
        presentationContext.onSubmittedWorkScheduled {
            completion.call()
        }
    }

    func lastFrameGPUCost() -> Double {
        presentationContext.lastFrameGPUCost
    }

    func lastFramePresentStall() -> Double {
        presentationContext.lastFramePresentStall
    }

    // CF_RETURNS_RETAINED; the compositor integration adopts it. nil, with isIOSurfaceSupportedFormat set, when the
    // compositor can read the render buffer's IOSurface instead.
    func textureAsNativeImage(_ bufferIndex: UInt32, _ isIOSurfaceSupportedFormat: inout Bool) -> CGImage? {
        presentationContext.textureAsNativeImage(bufferIndex, &isIOSurfaceSupportedFormat)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
