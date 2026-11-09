// Copyright (c) 2023-2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import CoreVideo
import Metal
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Device
#if hasAttribute(diagnose)
@diagnose(UnusedImportAccess, as: ignored, reason: "Needed for exposed SPI")
#endif
public import WebGPU_Private.WebGPUCpp

@_spi(WebKitGPU)
public typealias ExternalTextureReference = ExternalTextureImpl

// https://gpuweb.github.io/gpuweb/#dictdef-gpuexternaltexturedescriptor, without its label, with the pixel buffer of the
// video source.
@_spi(WebKitGPU)
public struct GPUExternalTextureDescriptor {
    public var pixelBuffer: CVPixelBuffer?
    public var colorSpace = WebGPU.PredefinedColorSpace.SRGB
    // The size the source presents the frame at, which the pixel buffer does not carry. Zero when the source could not
    // say, and then the decoded size of the frame stands in for it.
    public var visibleSize = WebGPU.Extent2D()

    public init() {
    }
}

@_spi(WebKitGPU)
extension ExternalTextureImpl {

    // The descriptor's video frame, which the texture shows from now on: none if it has no pixel buffer. Only the pixel buffer is read.
    public func update(_ descriptor: GPUExternalTextureDescriptor) {
        if let pixelBuffer = descriptor.pixelBuffer {
            update(pixelBuffer)
        } else {
            updateWithoutPixelBuffer()
        }
    }
}

@_spi(WebKitGPU)
extension DeviceReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-importexternaltexture
    public func importExternalTexture(_ descriptor: GPUExternalTextureDescriptor) -> ExternalTextureReference {
        guard isValid() else {
            return makeInvalidExternalTextureImpl(self)
        }
        let size = descriptor.visibleSize
        let texture = makeExternalTextureImpl(descriptor.colorSpace, size.width, size.height, self)
        texture.update(descriptor)
        return texture
    }
}

// The state of a GPUExternalTexture, held by its Swift callers.
// Used only on its Instance's API thread, so not Sendable.
@_spi(WebKitGPU)
public final class ExternalTextureImpl: GPUObjectReference, LinkedImpl {
    private var linkSlot = ImplLinkSlot<ExternalTextureImpl>()
    // nil: no frame.
    private var backingPixelBuffer: CVPixelBuffer?
    private var destroyed = false

    // The planes imported from the current frame, set when a bind group imports it.
    private var backingTexture0: (any MTLTexture)?
    private var backingTexture1: (any MTLTexture)?

    private let colorSpace: WebGPU.PredefinedColorSpace
    // The size the source presents the frame at, which is not the size its planes were decoded into. Zero in either
    // component means the source could not say.
    private let backingVisibleWidth: UInt32
    private let backingVisibleHeight: UInt32

    /// The encoders that used the current frame: cleared by a new frame and by undestroy, never by the encoders.
    var tracking = EncoderTracking()
    /// The encoders that used the texture in any frame, until their clearTracking() at completion or discard.
    var pendingUsers = EncoderTracking()
    // Declared last, so that the device outlives the rest of the texture.
    let deviceImpl: DeviceImpl

    fileprivate init(
        colorSpace: WebGPU.PredefinedColorSpace,
        visibleWidth: UInt32,
        visibleHeight: UInt32,
        deviceImpl: DeviceImpl
    ) {
        self.colorSpace = colorSpace
        self.backingVisibleWidth = visibleWidth
        self.backingVisibleHeight = visibleHeight
        self.deviceImpl = deviceImpl
    }

    deinit {
        linkSlot.end()
    }

    var link: ImplLink<ExternalTextureImpl> {
        linkSlot.link(for: self)
    }

    public func isValid() -> Bool {
        backingPixelBuffer != nil || destroyed
    }

    @_spi(WebKitGPU)
    public func destroy() {
        backingPixelBuffer = nil
        destroyed = true
        for encoder in tracking.takeLive() {
            encoder.makeSubmitInvalid(nil)
        }
    }

    @_spi(WebKitGPU)
    public func undestroy() {
        guard destroyed else {
            return
        }
        for encoder in tracking.takeLive() {
            encoder.makeSubmitInvalid(nil)
        }
        destroyed = false
    }

    // The frame's IOSurface is first attributed to the web process.
    func update(_ pixelBuffer: CVPixelBuffer) {
        #if HAVE_IOSURFACE_SET_OWNERSHIP_IDENTITY && HAVE_TASK_IDENTITY_TOKEN
        if let surface = pixelBufferIOSurface(pixelBuffer) {
            setIOSurfaceOwnershipIdentity(surface, deviceImpl)
        }
        #endif
        backingPixelBuffer = pixelBuffer
        destroyed = false
        tracking.removeAll()
    }

    func updateWithoutPixelBuffer() {
        backingPixelBuffer = nil
        destroyed = false
        tracking.removeAll()
    }

    // The encoder retains the planes, not the texture.
    func setCommandEncoder(_ encoder: CommandEncoderImpl) {
        if !tracking.contains(encoder) {
            _ = tracking.add(encoder)
        }
        if !pendingUsers.contains(encoder) && pendingUsers.add(encoder) {
            encoder.trackExternalTexture(self)
        }
        encoder.addTexture(backingTexture0)
        encoder.addTexture(backingTexture1)
        encoder.retainExternalTexturePlanes(backingTexture0, backingTexture1)
        if destroyed {
            encoder.makeSubmitInvalid(nil)
        }
    }

    // The encoders that used the texture since its frame was last updated and are still alive.
    func openCommandEncoderCount() -> Int {
        tracking.liveCount()
    }

    func hasPendingUsers() -> Bool {
        pendingUsers.liveCount() != 0
    }

    func pixelBuffer() -> CVPixelBuffer? {
        backingPixelBuffer
    }

    func colorSpaceRawValue() -> UInt8 {
        colorSpace.rawValue
    }

    func visibleWidth() -> UInt32 {
        backingVisibleWidth
    }

    func visibleHeight() -> UInt32 {
        backingVisibleHeight
    }

    func updateExternalTextures(_ t0: (any MTLTexture)?, _ t1: (any MTLTexture)?) {
        backingTexture0 = t0
        backingTexture1 = t1
    }
}

func makeExternalTextureImpl(
    _ colorSpace: WebGPU.PredefinedColorSpace,
    _ visibleWidth: UInt32,
    _ visibleHeight: UInt32,
    _ deviceImpl: DeviceImpl
) -> ExternalTextureImpl {
    ExternalTextureImpl(
        colorSpace: colorSpace,
        visibleWidth: visibleWidth,
        visibleHeight: visibleHeight,
        deviceImpl: deviceImpl
    )
}

func makeInvalidExternalTextureImpl(_ deviceImpl: DeviceImpl) -> ExternalTextureImpl {
    ExternalTextureImpl(
        colorSpace: WebGPU.PredefinedColorSpace.SRGB,
        visibleWidth: 0,
        visibleHeight: 0,
        deviceImpl: deviceImpl
    )
}
