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

// The canvas context's SPI that returns a CGImage, kept in a file whose only public import declaring IOSurfaceRef is
// CoreGraphics: with IOSurface's as well, a public declaration flips from build to build between the two.
@_spi(WebKitGPU)
extension PresentationContextIOSurfaceImpl {
    // The render buffer's contents as an image, for formats the compositor can't read from the IOSurface. nil, with
    // isIOSurfaceSupportedFormat set, when it can.
    @_expose(!Cxx)
    public func textureAsNativeImage(_ bufferIndex: UInt32, _ isIOSurfaceSupportedFormat: inout Bool) -> CGImage? {
        renderBufferAsNativeImage(bufferIndex, &isIOSurfaceSupportedFormat)
    }
}
