// Copyright (C) 2026 Apple Inc. All rights reserved.
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

import CoreVideo
import Metal
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Device
import WebGPU_Private.WebGPUCpp

@_spi(WebKitGPU)
public typealias ExternalTextureReference = ExternalTextureImpl

@_spi(WebKitGPU)
extension ExternalTextureImpl {
    // What the callers used when it had a shell too.
    @_expose(!Cxx)
    public var impl: ExternalTextureImpl {
        self
    }

    // The descriptor's video frame, which the texture shows from now on, as the shell's update() takes it: none if it
    // has no pixel buffer. Only the pixel buffer is read.
    @_expose(!Cxx)
    public func update(_ descriptor: WebGPU.ExternalTextureDescriptor) {
        if let pixelBuffer = WebGPU.framePixelBuffer(descriptor) {
            update(pixelBuffer)
        } else {
            updateWithoutPixelBuffer()
        }
    }
}

@_spi(WebKitGPU)
extension DeviceReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-importexternaltexture, as the shell's importExternalTexture() does.
    public func importExternalTexture(_ descriptor: WebGPU.ExternalTextureDescriptor) -> ExternalTextureReference {
        guard impl.isValid() else {
            return makeInvalidExternalTextureImpl(impl)
        }
        let size = descriptor.visibleSize
        let texture = makeExternalTextureImpl(descriptor.colorSpace, size.width, size.height, impl)
        texture.update(descriptor)
        return texture
    }
}

// The state of a GPUExternalTexture, held by its Swift callers and by the C++ API's shell WebGPU::Metal::ExternalTexture.
// Used only on its Instance's API thread, so not Sendable.
@_expose(Cxx)
@_spi(WebKitGPU)
public final class ExternalTextureImpl: GPUObjectReference {
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
    @_expose(!Cxx)
    var tracking = EncoderTracking()
    /// The encoders that used the texture in any frame, until their clearTracking() at completion or discard.
    @_expose(!Cxx)
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

    @_expose(Cxx)
    public func isValid() -> Bool {
        backingPixelBuffer != nil || destroyed
    }

    @_expose(Cxx)
    @_spi(WebKitGPU)
    public func destroy() {
        backingPixelBuffer = nil
        destroyed = true
        for encoder in tracking.takeLive() {
            encoder.makeSubmitInvalid(nil)
        }
    }

    @_expose(!Cxx)
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
    @_expose(Cxx)
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
    @_expose(!Cxx)
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
    @_expose(!Cxx)
    func openCommandEncoderCount() -> Int {
        tracking.liveCount()
    }

    @_expose(!Cxx)
    func hasPendingUsers() -> Bool {
        pendingUsers.liveCount() != 0
    }

    @_expose(!Cxx)
    func pixelBuffer() -> CVPixelBuffer? {
        backingPixelBuffer
    }

    @_expose(!Cxx)
    func colorSpaceRawValue() -> UInt8 {
        colorSpace.rawValue
    }

    @_expose(!Cxx)
    func visibleWidth() -> UInt32 {
        backingVisibleWidth
    }

    @_expose(!Cxx)
    func visibleHeight() -> UInt32 {
        backingVisibleHeight
    }

    @_expose(!Cxx)
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
