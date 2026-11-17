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
@_spi(WebKitGPU) internal import WebCore
import WebKit_Internal

// Receives the compositor messages of a WebGPU canvas, on the RemoteGPU's work queue: the render buffers that the compositor
// shows the canvas from, and the canvas context that draws into them. PrepareForDisplay returns the displayed surface's send
// right so the web process can share it with the compositor without the GPU process holding its own send right.
@_expose(Cxx)
final class RemoteCompositorIntegration {
    private let link: WebGPURegistryLink
    private var renderBuffers: [IOSurfaceRef] = []
    // Spare render buffers kept for when the next-frame surface is still in use by the compositor.
    private var spareRenderBuffers: [SpareRenderBuffer] = []
    // Dimensions, format and color space of the render buffers, for creating spare buffers with the same parameters.
    private var renderBufferWidth: Int32 = 0
    private var renderBufferHeight: Int32 = 0
    private var renderBufferTextureFormat = IPCTypes.TextureFormat.bgra8unorm
    private var renderBufferColorSpace: CGColorSpace?
    private static let maxSpareRenderBuffers = 5
    // The EDR headroom last set on the render buffers.
    private var contentHeadroom: Float?
    private var canvas: WebGPUCompositorCanvas?
    private var alphaMode = IPCTypes.AlphaPremultiplication.premultiplied
    // Whether the render buffers have been made for a device.
    private var hasDevice = false

    private struct SpareRenderBuffer {
        var surface: IOSurfaceRef
    }

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
            objects.owner,
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
        destinationColorSpace: IPCTypes.ColorSpace,
        alphaMode: IPCTypes.AlphaPremultiplication,
        textureFormat: IPCTypes.TextureFormat,
        deviceIdentifier: IPCTypes.WebGPUIdentifier,
        reply: consuming RemoteCompositorIntegrationRecreateRenderBuffersReply
    ) throws(InvalidMessage) {
        try messageCheck {
            link.objects?.hasDevice(deviceIdentifier.rawValue) ?? false
        }

        spareRenderBuffers = []
        renderBuffers = []
        contentHeadroom = nil
        hasDevice = true
        self.alphaMode = alphaMode

        canvas?.unconfigure()

        // Up to three buffers, at most the largest 2D texture in size.
        let max2DTextureSize: Int32 = 16384
        let colorSpace = destinationColorSpace.cgColorSpace
        let format = renderBufferFormat(textureFormat, premultiplied: alphaMode == .premultiplied)
        renderBufferWidth = max(1, min(max2DTextureSize, width))
        renderBufferHeight = max(1, min(max2DTextureSize, height))
        renderBufferTextureFormat = textureFormat
        renderBufferColorSpace = colorSpace
        var surfaces: [IOSurfaceRef] = []
        for _ in 0..<3 {
            let surface = IOSurfaceCore.create(
                pool: nil,
                width: renderBufferWidth,
                height: renderBufferHeight,
                colorSpace: colorSpace,
                name: .WebGPU,
                format: format
            )
            if let surface {
                surfaces.append(surface.surface)
            }
        }
        renderBuffers = surfaces

        canvas?.renderBuffersWereRecreated()
        for surface in renderBuffers {
            canvas?.addRenderBuffer(surface)
        }
        reply.send(UInt32(renderBuffers.count))
    }
    #endif

    // Replies once the configured device's queue has scheduled the work submitted so far, with the
    // display buffer's send right and optionally which render buffer index was replaced with a spare.
    func prepareForDisplay(frameIndex: UInt32, reply: consuming RemoteCompositorIntegrationPrepareForDisplayReply) {
        guard let canvas else {
            reply.send(IPCTypes.PrepareForDisplayReply(gpuFrameCost: 0, presentStall: 0, displayBuffer: .init(), replacedRenderBufferIndex: nil))
            return
        }
        canvas.present(frameIndex)

        var displayBuffer = IPCTypes.MachSendRight()
        var replacedRenderBufferIndex: UInt32? = nil
        if Int(frameIndex) < renderBuffers.count {
            displayBuffer = IPCTypes.MachSendRight(surface: renderBuffers[Int(frameIndex)])
            let count = renderBuffers.count
            let nextFrameIndex = (Int(frameIndex) + 1) % count
            if nextFrameIndex != Int(frameIndex) && replaceRenderBufferIfInUse(nextFrameIndex) {
                replacedRenderBufferIndex = UInt32(nextFrameIndex)
            }
        }

        let pendingReply = CopyableBox(value: reply)
        let pendingBuffer = CopyableBox(value: displayBuffer)
        canvas.onSubmittedWorkScheduled {
            if let reply = pendingReply.take(), let buffer = pendingBuffer.take() {
                reply.send(IPCTypes.PrepareForDisplayReply(
                    gpuFrameCost: canvas.lastFrameGPUCost(),
                    presentStall: canvas.lastFramePresentStall(),
                    displayBuffer: consume buffer,
                    replacedRenderBufferIndex: replacedRenderBufferIndex
                ))
            }
        }
    }

    // Checks if renderBuffers[index] is in use; if so, swaps in a spare surface and notifies the canvas.
    // Returns true if the buffer was replaced.
    private func replaceRenderBufferIfInUse(_ index: Int) -> Bool {
        guard !renderBuffers.isEmpty, IOSurfaceIsInUse(renderBuffers[index]) else {
            return false
        }

        var replacement: IOSurfaceRef?
        // Prefer a spare that is no longer in use.
        if let spareIndex = spareRenderBuffers.firstIndex(where: { !IOSurfaceIsInUse($0.surface) }) {
            replacement = spareRenderBuffers.remove(at: spareIndex).surface
        }
        // Fall back to creating a fresh surface with the same dimensions and color space.
        if replacement == nil, let colorSpace = renderBufferColorSpace {
            replacement = IOSurfaceCore.create(
                pool: nil,
                width: renderBufferWidth,
                height: renderBufferHeight,
                colorSpace: colorSpace,
                name: .WebGPU,
                format: renderBufferFormat(renderBufferTextureFormat, premultiplied: alphaMode == .premultiplied)
            )?.surface
        }
        guard let replacement else {
            return false
        }

        #if HAVE_SUPPORT_HDR_DISPLAY
        if let headroom = contentHeadroom {
            IOSurfaceSetValue(replacement, kIOSurfaceContentHeadroom, NSNumber(value: headroom))
        }
        #endif

        let old = renderBuffers[index]
        renderBuffers[index] = replacement
        spareRenderBuffers.append(SpareRenderBuffer(surface: old))
        if spareRenderBuffers.count > Self.maxSpareRenderBuffers {
            spareRenderBuffers.removeFirst()
        }
        canvas?.replaceRenderBuffer(at: UInt32(index), with: replacement)
        return true
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
        objects.renderingBackend.paintToImageBuffer(
            textureImage,
            renderBuffers[Int(bufferIndex)],
            forceOpaque: alphaMode != .premultiplied,
            imageBufferIdentifier: imageBuffer.rawValue
        )
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
private func renderBufferFormat(_ textureFormat: IPCTypes.TextureFormat, premultiplied: Bool) -> IOSurfaceFormat {
    switch textureFormat {
    case .rgba8unorm, .rgba8unormSRGB:
        return premultiplied ? .RGBA : .RGBX
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    case .rgba16float:
        return .RGBA16F
    #endif
    default:
        return premultiplied ? .BGRA : .BGRX
    }
}
#endif

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
