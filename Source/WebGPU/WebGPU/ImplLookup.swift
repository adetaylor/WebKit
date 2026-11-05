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

public import CoreGraphics
@_implementationOnly import WebGPU_Internal.BindGroup
@_implementationOnly import WebGPU_Internal.Buffer
@_implementationOnly import WebGPU_Internal.CommandEncoder
@_implementationOnly import WebGPU_Internal.ComputePassEncoder
@_implementationOnly import WebGPU_Internal.ComputePipeline
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.Instance
@_implementationOnly import WebGPU_Internal.PresentationContext
@_implementationOnly import WebGPU_Internal.Queue
@_implementationOnly import WebGPU_Internal.RenderPassEncoder
@_implementationOnly import WebGPU_Internal.RenderPipeline
@_implementationOnly import WebGPU_Internal.RenderBundleEncoder
@_implementationOnly import WebGPU_Internal.ShaderModule
@_implementationOnly import WebGPU_Internal.Texture
import WebGPU_Private.WebGPUCpp

// The names Swift callers have for the Impls, and the operations of theirs that the Impls' own files don't define.

@_spi(WebKitGPU)
public typealias BindGroupReference = BindGroupImpl

@_spi(WebKitGPU)
extension BindGroupImpl {
    // What the callers used when it had a shell too.
    @_expose(!Cxx)
    public var impl: BindGroupImpl {
        self
    }
}

@_spi(WebKitGPU)
public typealias ComputePipelineReference = ComputePipelineImpl

@_spi(WebKitGPU)
extension ComputePipelineImpl {
    // What the callers used when it had a shell too.
    @_expose(!Cxx)
    public var impl: ComputePipelineImpl {
        self
    }
}

@_spi(WebKitGPU)
extension PresentationContextReference {
    // The render buffer's contents as an image, for formats the compositor can't read from the IOSurface. nil, with
    // isIOSurfaceSupportedFormat set, when it can.
    @_expose(!Cxx)
    public func textureAsNativeImage(_ bufferIndex: UInt32, _ isIOSurfaceSupportedFormat: inout Bool) -> CGImage? {
        renderBufferAsNativeImage(bufferIndex, &isIOSurfaceSupportedFormat)
    }
}

@_spi(WebKitGPU)
extension BufferImpl {
    // What the callers used when it had a shell too.
    @_expose(!Cxx)
    public var impl: BufferImpl {
        self
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-mapasync, as Buffer's shell calls it. `mode` is the bits of
    // OptionSet<WebGPU::MapMode>; nil size: the rest of the buffer after the offset.
    @_expose(!Cxx)
    public func mapAsync(_ mode: UInt8, _ offset: UInt64, _ size: UInt64?, _ completion: @escaping (Bool) -> Void) {
        let rangeSize = size ?? (initialSize() > offset ? initialSize() - offset : 0)
        let rangeFits = UInt(exactly: offset) != nil && UInt(exactly: rangeSize) != nil
        mapAsync(mode, rangeFits, rangeFits ? offset : 0, rangeFits ? rangeSize : 0, completion)
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-getmappedrange, as Buffer::getMappedRange() reserves the range, but
    // giving a copy of its bytes. No bytes if the range can't be given.
    @_expose(!Cxx)
    public func getMappedRange(_ offset: UInt64, _ size: UInt64?) -> [UInt8] {
        let rangeSize = size ?? (initialSize() > offset ? initialSize() - offset : 0)
        guard UInt(exactly: offset) != nil, UInt(exactly: rangeSize) != nil, reserveMappedRange(offset, rangeSize) else {
            return []
        }
        // The reserved range lies within the mapping, so within the contents.
        guard let byteCount = Int(exactly: rangeSize), byteCount > 0 else {
            return []
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var destination = bytes.mutableSpan
        WebGPU.Metal.readBufferContents(buffer(), offset, &destination)
        return bytes
    }

    // Writes data into the buffer's contents at that offset, as a mapped range of them is written. Returns false,
    // writing nothing, if the contents don't hold it there.
    @_expose(!Cxx)
    public func writeContents(_ data: Span<UInt8>, at offset: UInt64) -> Bool {
        WebGPU.Metal.writeBufferContentsIfInBounds(buffer(), offset, data)
    }

    @_expose(!Cxx)
    public func setLabel(_ label: Swift.String?) {
        setLabel(WTF.String(label ?? ""))
    }

    // Buffer::generateAValidationError.
    @_expose(!Cxx)
    public func generateAValidationError() {
        deviceImpl.generateAValidationError("Buffer state was not unmapped")
    }
}

@_spi(WebKitGPU)
extension ComputePipelineReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpupipelinebase-getbindgrouplayout
    public func getBindGroupLayout(_ groupIndex: UInt32) -> BindGroupLayoutReference {
        impl.bindGroupLayout(groupIndex)
    }
}

@_spi(WebKitGPU)
extension RenderPipelineReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpupipelinebase-getbindgrouplayout
    public func getBindGroupLayout(_ groupIndex: UInt32) -> BindGroupLayoutReference {
        impl.bindGroupLayout(groupIndex)
    }
}

@_spi(WebKitGPU)
public typealias BufferReference = BufferImpl

@_spi(WebKitGPU)
public typealias RenderBundleReference = RenderBundleImpl

@_spi(WebKitGPU)
extension RenderBundleImpl {
    // What the callers used when it had a shell too.
    @_expose(!Cxx)
    public var impl: RenderBundleImpl {
        self
    }
}

@_spi(WebKitGPU)
public typealias RenderPipelineReference = RenderPipelineImpl

@_spi(WebKitGPU)
extension RenderPipelineImpl {
    // What the callers used when it had a shell too.
    @_expose(!Cxx)
    public var impl: RenderPipelineImpl {
        self
    }
}

@_spi(WebKitGPU)
public typealias ComputePassEncoderReference = ComputePassEncoderImpl

@_spi(WebKitGPU)
extension ComputePassEncoderImpl {
    // What the callers used when it had a shell too.
    @_expose(!Cxx)
    public var impl: ComputePassEncoderImpl {
        self
    }
}

@_spi(WebKitGPU)
public typealias RenderPassEncoderReference = RenderPassEncoderImpl

@_spi(WebKitGPU)
extension RenderPassEncoderImpl {
    // What the callers used when it had a shell too.
    @_expose(!Cxx)
    public var impl: RenderPassEncoderImpl {
        self
    }
}

// A WebGPU object that Swift holds, as the GPU process's registry of them keeps it: whether it's valid.
@_spi(WebKitGPU)
public protocol GPUObjectReference: AnyObject {
    func isValid() -> Bool
}

@_spi(WebKitGPU)
extension GPUObjectReference {
    public var isValid: Bool {
        isValid()
    }
}
