// Copyright (C) 2009-2021 Apple Inc. All rights reserved.
// Copyright (C) 2023 Apple Inc. All rights reserved.
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

#if WTF_PLATFORM_COCOA && ENABLE_VIDEO

internal import CoreVideo
internal import IOSurface
internal import WebCoreANGLE
internal import WebCoreANGLE.Cocoa

// The values of GraphicsContextGLVideoUploadOutcome.
enum GLVideoUploadOutcome: UInt8 {
    case direct = 0
    case converted
    case cached
    case notTransferable
    case contextLost
    case noFrame
    case unsupported
    case conversionFailed
    case noIOSurface
    // The copy raised a GL error, e.g. the destination format is not supported.
    case copyFailed
    case pbufferFailed
}

private func yuvSampleRangeHint(_ pixelFormat: OSType) -> EGLint? {
    switch pixelFormat {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        return EGL_YUV_NARROW_RANGE_EXT
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        return EGL_YUV_FULL_RANGE_EXT
    default:
#if HAVE_COREVIDEO_COMPRESSED_PIXEL_FORMAT_TYPES
        if pixelFormat == ANGLECocoa.agx420YpCbCr8BiPlanarVideoRange() {
            return EGL_YUV_NARROW_RANGE_EXT
        }
        if pixelFormat == ANGLECocoa.agx420YpCbCr8BiPlanarFullRange() {
            return EGL_YUV_FULL_RANGE_EXT
        }
#endif
        return nil
    }
}

private func yuvColorSpaceHint(_ image: CVPixelBuffer) -> EGLint {
    if let matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil) {
        if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
            return EGL_ITU_REC709_EXT
        }
        if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
            return EGL_ITU_REC2020_EXT
        }
        if CFEqual(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995) {
            return EGL_SMPTE_240M_ANGLE
        }
    }
    // Assume unknown matrices are ITU R.601.
    return EGL_ITU_REC601_EXT
}

// The EGL_IOSURFACE_ORIENTATION_ANGLE bits that undo an ImageOrientation::Orientation, e.g. that move the origin to top
// left. The pbuffer texture image is the surface transformed by: invert y, invert x, swap x and y. InvertX switches
// between Left and Right. InvertY switches between Top and Bottom. SwapXY switches LeftTop to TopLeft. Even number of
// operations means a rotation, odd number of operations means a rotation and a flip.
private func iosurfaceOrientation(_ orientation: UInt8) -> EGLint {
    let invertX = EGL_IOSURFACE_ORIENTATION_INVERT_X_ANGLE
    let invertY = EGL_IOSURFACE_ORIENTATION_INVERT_Y_ANGLE
    let swapXY = EGL_IOSURFACE_ORIENTATION_SWAP_XY_ANGLE
    switch orientation {
    case 2:
        // OriginTopRight.
        return invertX
    case 3:
        // OriginBottomRight: rotated 180 degrees.
        return invertY | invertX
    case 4:
        // OriginBottomLeft: mirrored along the x-axis.
        return invertY
    case 5:
        // OriginLeftTop: mirrored along x-axis and rotated 270 degrees clock-wise.
        return swapXY
    case 6:
        // OriginRightTop: rotated 90 degrees clock-wise.
        return invertX | swapXY
    case 7:
        // OriginRightBottom: mirror along x-axis and rotated 90 degrees clockwise.
        return invertY | invertX | swapXY
    case 8:
        // OriginLeftBottom: rotated 270 degrees clock-wise.
        return invertY | swapXY
    default:
        // FromImage and OriginTopLeft.
        return 0
    }
}

// A video frame prepared to be bound as a GL_G8_B8R8_2PLANE_420_UNORM_ANGLE pbuffer.
private struct GLYUVVideoFrameSource {
    var surface: IOSurfaceRef
    var orientation: EGLint
    var colorSpaceHint: EGLint
    var sampleRangeHint: EGLint
    // The frame was converted to a pixel format the copy supports.
    var isConverted: Bool
}

private enum GLYUVVideoFrameSourceResult {
    case source(GLYUVVideoFrameSource)
    case failure(GLVideoUploadOutcome)
}

private func yuvVideoFrameSource(_ frame: CVPixelBuffer, orientation: UInt8) -> GLYUVVideoFrameSourceResult {
    var pixelBuffer = frame
    var isConverted = false
    var sampleRangeHint = yuvSampleRangeHint(CVPixelBufferGetPixelFormatType(pixelBuffer))
    if sampleRangeHint == nil {
        // FIXME: Support more pixel formats without conversion.
        guard let converted = GLContextCallbacks.convertPixelBufferTo420f(frame) else {
            GLLog.debug("GLVideoUpload - failed converting an image with pixel format (\(CVPixelBufferGetPixelFormatType(frame))).")
            return .failure(.conversionFailed)
        }
        pixelBuffer = converted
        assert(CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        sampleRangeHint = EGL_YUV_FULL_RANGE_EXT
        isConverted = true
    }
    guard let surface = ANGLECocoa.ioSurface(pixelBuffer) else {
        return .failure(.noIOSurface)
    }
    return .source(GLYUVVideoFrameSource(
        surface: surface,
        orientation: iosurfaceOrientation(orientation),
        colorSpaceHint: yuvColorSpaceHint(pixelBuffer),
        sampleRangeHint: sampleRangeHint ?? EGL_YUV_FULL_RANGE_EXT,
        isConverted: isConverted))
}

// Binds source as an oriented YUV pbuffer to a temporary TEXTURE_2D texture and calls copy with the texture. The GL
// errors of the copy are not WebGL errors, rather they make the function return copyFailed. The caller must have moved
// the pending errors aside. Returns nil if the copy succeeded.
private func copyFromYUVVideoFrameSource(_ display: ANGLEDisplay, _ config: ANGLEConfig, _ source: GLYUVVideoFrameSource, _ copy: (GLuint) -> Void) -> GLVideoUploadOutcome? {
    let sourceTexture = ANGLE.genTexture()
    defer {
        ANGLE.deleteTexture(sourceTexture)
    }
    return withRestoredTextureBinding(GLenum(GL_TEXTURE_BINDING_2D), GLenum(GL_TEXTURE_2D)) { () -> GLVideoUploadOutcome? in
        GL_BindTexture(GLenum(GL_TEXTURE_2D), sourceTexture)
        let pbuffer = ANGLECocoa.createYUVIOSurfacePbuffer(display, config, source.surface, source.orientation, source.colorSpaceHint, source.sampleRangeHint)
        if pbuffer.isNull() {
            return .pbufferFailed
        }
        defer {
            _ = ANGLECocoa.destroySurface(display, pbuffer)
        }
        if !ANGLECocoa.bindTexImage(display, pbuffer) {
            return .pbufferFailed
        }

        copy(sourceTexture)

        _ = ANGLECocoa.releaseTexImage(display, pbuffer)
        if GL_GetError() != GLenum(GL_NO_ERROR) {
            // Drain the rest of the errors, with an arbitrary limit in case of a driver bug.
            for _ in 0..<100 {
                if GL_GetError() == GLenum(GL_NO_ERROR) {
                    break
                }
            }
            return .copyFailed
        }
        return nil
    }
}

private struct GLVideoTextureContent: Equatable {
    var surfaceID: IOSurfaceID
    var surfaceSeed: UInt32
    var target: GLenum
    var level: GLint
    var internalFormat: GLenum
    var type: GLenum
    var orientation: EGLint
    var unpackFlipY: Bool
    var unpackPremultiplyAlpha: Bool
}

// The copies of video frames to the textures of a WebGL context, which glCopyTextureCHROMIUM makes in the context.
struct GLVideoUpload {
    // The source of the latest copy per texture, so that repeated uploads of an unchanged frame can be skipped. The
    // surfaces are kept, so that their IDs aren't reused while the content is known.
    private var knownContent: [GLuint: (content: GLVideoTextureContent, surface: IOSurfaceRef)] = [:]

    mutating func invalidateKnownTextureContent(_ texture: GLuint) {
        if !knownContent.isEmpty {
            knownContent[texture] = nil
        }
    }

    // Invalidates the known content of the texture bound to the binding point of target in the active texture unit.
    // With the context current.
    mutating func invalidateKnownTextureContent(forTarget target: GLenum) {
        if knownContent.isEmpty {
            return
        }
        let binding: GLenum
        switch target {
        case GLenum(GL_TEXTURE_2D):
            binding = GLenum(GL_TEXTURE_BINDING_2D)
        case GLenum(GL_TEXTURE_CUBE_MAP), GLenum(GL_TEXTURE_CUBE_MAP_POSITIVE_X), GLenum(GL_TEXTURE_CUBE_MAP_NEGATIVE_X),
            GLenum(GL_TEXTURE_CUBE_MAP_POSITIVE_Y), GLenum(GL_TEXTURE_CUBE_MAP_NEGATIVE_Y), GLenum(GL_TEXTURE_CUBE_MAP_POSITIVE_Z),
            GLenum(GL_TEXTURE_CUBE_MAP_NEGATIVE_Z):
            binding = GLenum(GL_TEXTURE_BINDING_CUBE_MAP)
        case GLenum(GL_TEXTURE_3D):
            binding = GLenum(GL_TEXTURE_BINDING_3D)
        case GLenum(GL_TEXTURE_2D_ARRAY):
            binding = GLenum(GL_TEXTURE_BINDING_2D_ARRAY)
        default:
            // Unknown binding point, forget everything.
            knownContent.removeAll()
            return
        }
        knownContent[GLuint(bitPattern: ANGLE.getInteger(binding))] = nil
    }

    // Like glCopyTextureCHROMIUM with the frame, whose orientation is an ImageOrientation::Orientation, as the source
    // texture. Returns how the copy was done, or why it was not.
    mutating func copyVideoFrameToTexture(_ context: GLContext, _ display: ANGLEDisplay, _ config: ANGLEConfig, _ frame: CVPixelBuffer, orientation: UInt8, texture: GLuint, target: GLenum, level: GLint, internalFormat: GLenum, type: GLenum, unpackFlipY: Bool, unpackPremultiplyAlpha: Bool) -> GLVideoUploadOutcome {
        let source: GLYUVVideoFrameSource
        switch yuvVideoFrameSource(frame, orientation: orientation) {
        case .source(let frameSource):
            source = frameSource
        case .failure(let outcome):
            return outcome
        }

        let content = GLVideoTextureContent(surfaceID: IOSurfaceGetID(source.surface), surfaceSeed: IOSurfaceGetSeed(source.surface), target: target, level: level, internalFormat: internalFormat, type: type, orientation: source.orientation, unpackFlipY: unpackFlipY, unpackPremultiplyAlpha: unpackPremultiplyAlpha)
        if let known = knownContent[texture], known.content == content, known.surface === source.surface {
            // If the texture hasn't been modified since the last time we copied to it, and the image hasn't been
            // modified since the last time it was copied, this is a no-op.
            return .cached
        }
        // A failed copy may have modified the texture.
        knownContent[texture] = nil

        guard context.makeContextCurrent() else {
            return .contextLost
        }
        guard context.extensions.isEnabled("GL_CHROMIUM_copy_texture") else {
            return .unsupported
        }
        // Move the pending errors aside so that the copy errors can be identified.
        context.updateErrors()
        let failure = copyFromYUVVideoFrameSource(display, config, source) { sourceTexture in
            GL_CopyTextureCHROMIUM(sourceTexture, 0, target, texture, level, GLint(bitPattern: internalFormat), type, GLboolean(unpackFlipY ? GL_TRUE : GL_FALSE), GLboolean(unpackPremultiplyAlpha ? GL_TRUE : GL_FALSE), GLboolean(GL_FALSE))
        }
        if let failure {
            return failure
        }
        knownContent[texture] = (content, source.surface)
        return source.isConverted ? .converted : .direct
    }
}

#endif
