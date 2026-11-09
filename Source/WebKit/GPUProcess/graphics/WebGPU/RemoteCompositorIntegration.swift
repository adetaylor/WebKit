// Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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
import Foundation
import IOSurface
import WebKit_Internal

// Receives the compositor messages of a WebGPU canvas, on the RemoteGPU's work queue: the render buffers that the compositor
// shows the canvas from, IOSurfaces whose send rights the RecreateRenderBuffers reply carries, and the canvas context that
// draws into them.
@_expose(Cxx)
final class RemoteCompositorIntegration {
    private let link: WebGPURegistryLink
    private var renderBuffers: [IOSurfaceRef] = []
    // The EDR headroom last set on the render buffers.
    private var contentHeadroom: Float?
    private var canvas: WebGPUCompositorCanvas?
    private var alphaMode = IPCTypes.AlphaPremultiplication.premultiplied
    // Whether the render buffers have been made for a device.
    private var hasDevice = false

    @_expose(!Cxx)
    private init(_ link: WebGPURegistryLink) {
        self.link = link
    }

    // Adds the compositor integration, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemoteCompositorIntegration(link)
        let registration = IPC.registerSwiftStreamReceiver(
            objects.host,
            receiver.getMessageReceiver(),
            .RemoteCompositorIntegration,
            link.identifier
        )
        objects.add(link.identifier, receiver, registration: registration)
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteCompositorIntegrationMessageForwarder {
        WebKit.RemoteCompositorIntegrationMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
    }

    // The canvas context that draws into the render buffers, which the registry makes for them once.
    @_expose(!Cxx)
    func setCanvas(_ canvas: WebGPUCompositorCanvas) {
        assert(self.canvas == nil)
        self.canvas = canvas
    }

    #if WTF_PLATFORM_COCOA
    func recreateRenderBuffers(
        width: Int32,
        height: Int32,
        destinationColorSpace: CxxDecodedArguments.RemoteCompositorIntegration.RecreateRenderBuffersDestinationColorSpace,
        alphaMode: IPCTypes.AlphaPremultiplication,
        textureFormat: IPCTypes.TextureFormat,
        bufferCount: UInt32,
        deviceIdentifier: IPCTypes.WebGPUIdentifier,
        reply: consuming RemoteCompositorIntegrationRecreateRenderBuffersReply
    ) throws(InvalidMessage) {
        try messageCheck {
            link.objects?.hasDevice(deviceIdentifier.rawValue) ?? false
        }

        renderBuffers = []
        contentHeadroom = nil
        hasDevice = true
        self.alphaMode = alphaMode

        canvas?.unconfigure()

        // Up to three buffers, at most the largest 2D texture in size.
        let max2DTextureSize: Int32 = 16384
        var surfaces: [IOSurfaceRef] = []
        WebKit.createGPUProcessIOSurfaces(
            destinationColorSpace,
            max(1, min(max2DTextureSize, width)),
            max(1, min(max2DTextureSize, height)),
            renderBufferFormat(textureFormat, premultiplied: alphaMode == .premultiplied),
            .WebGPU,
            min(3, bufferCount)
        ) { surface in
            surfaces.append(surface)
        }
        renderBuffers = surfaces

        canvas?.renderBuffersWereRecreated()
        var sendRights = IPCTypes.MachSendRightVector()
        for surface in renderBuffers {
            canvas?.addRenderBuffer(surface)
            sendRights.append(IPCTypes.MachSendRight(surface: surface))
        }
        reply.send(sendRights)
    }
    #endif

    // Replies once the configured device's queue has scheduled the work submitted so far.
    func prepareForDisplay(frameIndex: UInt32, reply: consuming RemoteCompositorIntegrationPrepareForDisplayReply) {
        guard let canvas else {
            reply.send((gpuFrameCost: 0, presentStall: 0))
            return
        }
        canvas.present(frameIndex)
        let pendingReply = CopyableBox(value: reply)
        canvas.onSubmittedWorkScheduled {
            if let reply = pendingReply.take() {
                reply.send((gpuFrameCost: canvas.lastFrameGPUCost(), presentStall: canvas.lastFramePresentStall()))
            }
        }
    }

    func paintCompositedResultsToCanvas(imageBuffer: IPCTypes.RenderingResourceIdentifier, bufferIndex: UInt32) {
        guard Int(bufferIndex) < renderBuffers.count, hasDevice, let objects = link.objects else {
            return
        }
        var isIOSurfaceSupportedFormat = false
        let textureImage = canvas?.textureAsNativeImage(bufferIndex, &isIOSurfaceSupportedFormat)
        guard textureImage != nil || isIOSurfaceSupportedFormat else {
            return
        }
        // A premultiplied canvas must keep its alpha channel so transparent pixels composite over the page; an opaque
        // canvas forces the alpha to be ignored. This matters for RGBA16F, whose IOSurface format cannot itself encode
        // opacity.
        objects.host.paintToImageBuffer(textureImage, renderBuffers[Int(bufferIndex)], alphaMode != .premultiplied, imageBuffer.rawValue)
    }

    func destruct() {
        link.remove()
    }

    func updateContentsHeadroom(headroom: Float) {
        #if HAVE_SUPPORT_HDR_DISPLAY
        guard contentHeadroom != headroom else {
            return
        }
        contentHeadroom = headroom
        for surface in renderBuffers {
            IOSurfaceSetValue(surface, kIOSurfaceContentHeadroom, NSNumber(value: headroom))
        }
        #endif
    }
}

#if WTF_PLATFORM_COCOA
// The IOSurface format of a render buffer for the texture format and the alpha mode.
private func renderBufferFormat(_ textureFormat: IPCTypes.TextureFormat, premultiplied: Bool) -> WebKit.GPUProcessIOSurfaceFormat {
    switch textureFormat {
    case .rgba8unorm, .rgba8unormSRGB:
        return premultiplied ? .Rgba : .Rgbx
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    case .rgba16float:
        return .Rgba16F
    #endif
    default:
        return premultiplied ? .Bgra : .Bgrx
    }
}
#endif

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
