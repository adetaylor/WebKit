// Copyright (C) 2009-2021 Apple Inc. All rights reserved.
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

#if ENABLE_WEBGL

internal import CoreGraphics
internal import IOSurface
internal import WebCoreWebGL
import WebCore_Private.Core.GraphicsContextGLCocoa
import WebCore_Private.Core.PixelBufferSwiftBridge

// The drawing buffer surfaces of a Cocoa shell's island platform, of the context's colour space, alpha and owner, and
// the IOSurfaceCores of its last display buffers, which the shell's C++ adopts as IOSurfaces. The cache is as long as,
// and filled on the same misses as, the C++ shell's cache of their IOSurfaces.
final class GraphicsContextGLCocoaSurfaces: CocoaGLSurfaceFactory {
    private struct Cache {
        private var surfaces: [IOSurfaceCore] = []
        private var next = 0

        mutating func surface(_ surface: IOSurfaceRef) -> IOSurfaceCore {
            if let cached = surfaces.first(where: { $0.surface === surface }) {
                return cached
            }
            let core = IOSurfaceCore(surface: surface, colorSpace: nil)
            if surfaces.count < CocoaGLPlatform.maxReusedDrawingBuffers {
                surfaces.append(core)
            } else {
                surfaces[next] = core
                next = (next + 1) % CocoaGLPlatform.maxReusedDrawingBuffers
            }
            return core
        }
    }

    var colorSpace: CGColorSpace
    private let alphaPremultiplication: WebCore.AlphaPremultiplication?
    // The shell's resource owner's, which the shell keeps for its whole life, or MACH_PORT_NULL.
    private let ownershipIdentity: mach_port_t
    private var displayBufferSurfaces = Cache()

    init(colorSpace: CGColorSpace, alpha: Bool, premultipliedAlpha: Bool, ownershipIdentity: mach_port_t) {
        self.colorSpace = colorSpace
        self.alphaPremultiplication = alpha ? (premultipliedAlpha ? .Premultiplied : .Unpremultiplied) : nil
        self.ownershipIdentity = ownershipIdentity
    }

    func createDrawingBufferSurface(width: Int32, height: Int32) -> IOSurfaceRef? {
        guard let surface = IOSurfaceCore.create(pool: nil, width: width, height: height, colorSpace: colorSpace, name: .GraphicsContextGL, format: .BGRA, useLosslessCompression: false, alphaPremultiplication: alphaPremultiplication) else {
            return nil
        }
        if ownershipIdentity != mach_port_t(MACH_PORT_NULL) {
            surface.setOwnershipIdentity(ownershipIdentity)
        }
        return surface.surface
    }

    func displayBufferSurface(_ surface: IOSurfaceRef) -> IOSurfaceCore {
        displayBufferSurfaces.surface(surface)
    }
}

extension WebCore.GraphicsContextGLCocoa {
    private var shell: GLShell {
        unsafe GLShell.fromReference(islandShell())
    }

    private var surfaces: GraphicsContextGLCocoaSurfaces? {
        shell.cocoaSurfaceFactory as? GraphicsContextGLCocoaSurfaces
    }

    @cxx
    @implementation
    func swiftCreateCocoaPlatform(_ contextID: UInt64, _ isWebGL2: Bool, _ alpha: Bool, _ premultipliedAlpha: Bool, _ powerPreference: UInt8, _ windowGPUID: UInt64, _ xrCompatible: Bool, _ ownershipIdentity: UInt32, _ maximumSurfaceWidth: Int32, _ maximumSurfaceHeight: Int32) -> Bool {
        let surfaces = GraphicsContextGLCocoaSurfaces(colorSpace: WebCore.platformColorSpace(m_drawingBufferColorSpace), alpha: alpha, premultipliedAlpha: premultipliedAlpha, ownershipIdentity: ownershipIdentity)
        return shell.createCocoaPlatform(contextID: contextID, isWebGL2: isWebGL2, alpha: alpha, powerPreference: powerPreference, windowGPUID: windowGPUID, xrCompatible: xrCompatible, ownershipIdentity: ownershipIdentity, maximumSurfaceWidth: maximumSurfaceWidth, maximumSurfaceHeight: maximumSurfaceHeight, surfaceFactory: surfaces)
    }

    @cxx
    @implementation
    func swiftDisplayBufferSurfaceState() -> UInt {
        guard let surfaces, let surface = shell.cocoaDisplayBufferSurface() else {
            return 0
        }
        return IOSurfaceCore.retained(surfaces.displayBufferSurface(surface))
    }

    @cxx
    @implementation
    func swiftCopySurfaceBufferState(_ bufferType: WebCore.GraphicsContextGLSurfaceBuffer) -> UInt {
        guard let surface = shell.context?.copySurfaceBuffer(bufferType == .DisplayBuffer ? 1 : 0) else {
            return 0
        }
        return IOSurfaceCore.retained(IOSurfaceCore(surface: surface, colorSpace: nil))
    }

    @cxx
    @implementation
    func swiftDrawingBufferColorSpaceDidChange() {
        surfaces?.colorSpace = WebCore.platformColorSpace(m_drawingBufferColorSpace)
        shell.context?.drawingBufferColorSpaceDidChange()
    }
}

#endif
