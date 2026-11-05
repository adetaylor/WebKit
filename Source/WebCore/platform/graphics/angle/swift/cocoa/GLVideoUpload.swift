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
    case framebufferIncomplete
    case pbufferFailed
}

private let yuvVertexShaderTexture2D = """
    attribute vec2 a_position;\
    uniform vec2 u_yTextureSize;\
    uniform vec2 u_uvTextureSize;\
    uniform int u_flipY;\
    uniform int u_flipX;\
    uniform int u_swapXY;\
    varying vec2 v_yTextureCoordinate;\
    varying vec2 v_uvTextureCoordinate;\
    void main()\
    {\
        gl_Position = vec4(a_position, 0, 1.0);\
        vec2 normalizedPosition = a_position * .5 + .5;\
        if (u_flipY == 1)\
            normalizedPosition.y = 1.0 - normalizedPosition.y;\
        if (u_flipX == 1)\
            normalizedPosition.x = 1.0 - normalizedPosition.x;\
        if (u_swapXY == 1)\
            normalizedPosition.xy = normalizedPosition.yx;\
        v_yTextureCoordinate = normalizedPosition;\
        v_uvTextureCoordinate = normalizedPosition;\
    }
    """

private let yuvFragmentShaderTexture2D = """
    precision mediump float;\
    uniform sampler2D u_yTexture;\
    uniform sampler2D u_uvTexture;\
    uniform mat4 u_colorMatrix;\
    varying vec2 v_yTextureCoordinate;\
    varying vec2 v_uvTextureCoordinate;\
    void main()\
    {\
        vec4 yuv;\
        yuv.r = texture2D(u_yTexture, v_yTextureCoordinate).r;\
        yuv.gb = texture2D(u_uvTexture, v_uvTextureCoordinate).rg;\
        yuv.a = 1.0;\
        gl_FragColor = yuv * u_colorMatrix;\
    }
    """

private enum PixelRange {
    case unknown
    case video
    case full
}

private enum TransferFunctionCV {
    case unknown
    case ituR709_2
    case ituR601_4
    case smpte240M1995
    case ituR2020
}

private func pixelRange(of pixelFormat: OSType) -> PixelRange {
    switch pixelFormat {
    case kCVPixelFormatType_4444AYpCbCr8, kCVPixelFormatType_4444AYpCbCr16, kCVPixelFormatType_422YpCbCr_4A_8BiPlanar,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
        return .video
    case kCVPixelFormatType_420YpCbCr8PlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr8FullRange, kCVPixelFormatType_ARGB2101010LEPacked,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        return .full
    default:
#if HAVE_COREVIDEO_COMPRESSED_PIXEL_FORMAT_TYPES
        if pixelFormat == ANGLECocoa.agx420YpCbCr8BiPlanarVideoRange() {
            return .video
        }
        if pixelFormat == ANGLECocoa.agx420YpCbCr8BiPlanarFullRange() {
            return .full
        }
#endif
        return .unknown
    }
}

// The transfer function of the frame's YCbCr matrix attachment, which is unknown unless it is one of CoreVideo's
// matrix strings. The DCI-P3 and P3-D65 ones, which CoreVideo no longer supports, are unknown too: both get r.601.
private func transferFunction(of image: CVPixelBuffer) -> TransferFunctionCV {
    guard let matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, nil) else {
        return .unknown
    }
    let transferFunctions: [(CFString, TransferFunctionCV)] = [
        (kCVImageBufferYCbCrMatrix_ITU_R_709_2, .ituR709_2),
        (kCVImageBufferYCbCrMatrix_ITU_R_601_4, .ituR601_4),
        (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995, .smpte240M1995),
        (kCVImageBufferYCbCrMatrix_ITU_R_2020, .ituR2020),
    ]
    return transferFunctions.first { CFEqual(matrix, $0.0) }?.1 ?? .unknown
}

// The YCbCr to RGB matrices, in single precision, for video and full range, from the components Kb and Kr of
// ITU R.601 rev 4 (0.114, 0.299), ITU R.709 rev 2 (0.0722, 0.2126), ITU-R BT.2020-2 (0.0593, 0.2627) and
// SMPTE 240M-1999 (0.087, 0.212).
//
// The conversion from YCbCr -> RGB generally takes the form:
// Y = Kr * R + Kg * G + Kb * B
// Cb = (B - Y) / (2 * (1 - Kb))
// Cr = (R - Y) / (2 * (1 - Kr))
// Where the values of Kb and Kr are defined in a specification and Kg is derived from: Kr + Kg + Kb = 1
//
// Solving the above equations for R, B, and G derives the following:
// R = Y + (2 * (1 - Kr)) * Cr
// B = Y + (2 * (1 - Kb)) * Cb
// G = Y - (2 * (1 - Kb)) * (Kb / Kg) * Cb - ((1 - Kr) * 2) * (Kr / Kg) * Cr
//
// When the color values are Video range, Y has a range of [16, 235] with a width of 219, and Cb & Cr have
// a range of [16, 240] with a width of 224. When the color values are Full range, Y, Cb, and Cr all have
// a range of [0, 255] with a width of 256. The final column converts Cb and Cr to [-128, 128] and, in the case of
// video range, Y to [16, 240].
private enum YCbCrMatrices {
    static let r601Video = ANGLEFloat16(values: (
        0x1.2a150ap+0, 0x0p+0, 0x1.989534p+0, -0x1.bf976ep-1,
        0x1.2a150ap+0, -0x1.912a2p-2, -0x1.a03d4ap-1, 0x1.1036cp-1,
        0x1.2a150ap+0, 0x1.0234a8p+1, 0x0p+0, -0x1.15ebe4p+0,
        0x0p+0, 0x0p+0, 0x0p+0, 0x1p+0))
    static let r601Full = ANGLEFloat16(values: (
        0x1p+0, 0x0p+0, 0x1.66e978p+0, -0x1.6851cap-1,
        0x1p+0, -0x1.606542p-2, -0x1.6da344p-1, 0x1.0ffaecp-1,
        0x1p+0, 0x1.c5a1cap+0, 0x0p+0, -0x1.c76934p-1,
        0x0p+0, 0x0p+0, 0x0p+0, 0x1p+0))
    static let r709Video = ANGLEFloat16(values: (
        0x1.2a150ap+0, 0x0p+0, 0x1.caf114p+0, -0x1.f225dcp-1,
        0x1.2a150ap+0, -0x1.b4bbbp-3, -0x1.10d97ep-1, 0x1.34b7ep-2,
        0x1.2a150ap+0, 0x1.0e632ep+1, 0x0p+0, -0x1.2226a4p+0,
        0x0p+0, 0x0p+0, 0x0p+0, 0x1p+0))
    static let r709Full = ANGLEFloat16(values: (
        0x1p+0, 0x0p+0, 0x1.932618p+0, -0x1.94bad2p-1,
        0x1p+0, -0x1.7fa3dep-3, -0x1.df5bf8p-2, 0x1.50e7dcp-2,
        0x1p+0, 0x1.db089ap+0, 0x0p+0, -0x1.dce58p-1,
        0x0p+0, 0x0p+0, 0x0p+0, 0x1p+0))
    static let bt2020Video = ANGLEFloat16(values: (
        0x1.2a150ap+0, 0x0p+0, 0x1.adbd96p+0, -0x1.d4d50ep-1,
        0x1.2a150ap+0, -0x1.7fa4d6p-3, -0x1.4d046ap-1, 0x1.63cc2ap-2,
        0x1.2a150ap+0, 0x1.122598p+1, 0x0p+0, -0x1.25ecd4p+0,
        0x0p+0, 0x0p+0, 0x0p+0, 0x1p+0))
    static let bt2020Full = ANGLEFloat16(values: (
        0x1p+0, 0x0p+0, 0x1.797f64p+0, -0x1.7afa5ep-1,
        0x1p+0, -0x1.51013cp-3, -0x1.248866p-1, 0x1.7a42f6p-2,
        0x1p+0, 0x1.e1a36ep+0, 0x0p+0, -0x1.e386f4p-1,
        0x0p+0, 0x0p+0, 0x0p+0, 0x1p+0))
    static let smpte240MVideo = ANGLEFloat16(values: (
        0x1.2a150ap+0, 0x0p+0, 0x1.cb4a9ap+0, -0x1.f27fbcp-1,
        0x1.2a150ap+0, -0x1.082d2cp-2, -0x1.15cd72p-1, 0x1.50af76p-2,
        0x1.2a150ap+0, 0x1.0a1304p+1, 0x0p+0, -0x1.1dd226p+0,
        0x0p+0, 0x0p+0, 0x0p+0, 0x1p+0))
    static let smpte240MFull = ANGLEFloat16(values: (
        0x1p+0, 0x0p+0, 0x1.9374bcp+0, -0x1.9509c6p-1,
        0x1p+0, -0x1.d01f2ep-3, -0x1.e80f98p-2, 0x1.697912p-2,
        0x1p+0, 0x1.d374bcp+0, 0x0p+0, -0x1.d54a06p-1,
        0x0p+0, 0x0p+0, 0x0p+0, 0x1p+0))

    static func matrix(for range: PixelRange, _ transferFunction: TransferFunctionCV) -> ANGLEFloat16 {
        // We should never be asked to handle a Pixel Format whose range value is unknown.
        assert(range != .unknown)
        let isVideo = range == .video
        switch transferFunction {
        case .ituR709_2:
            return isVideo ? r709Video : r709Full
        case .ituR2020:
            return isVideo ? bt2020Video : bt2020Full
        case .smpte240M1995:
            return isVideo ? smpte240MVideo : smpte240MFull
        case .ituR601_4, .unknown:
            // Assume unknown transfer functions are r.601.
            return isVideo ? r601Video : r601Full
        }
    }
}

private struct TextureContent: Equatable {
    var surfaceID: IOSurfaceID
    var surfaceSeed: UInt32
    var level: GLint
    var internalFormat: GLenum
    var format: GLenum
    var type: GLenum
    var unpackFlipY: Bool
    var orientation: UInt8
}

// Copies the frames of videos to textures, on a context that shares the WebGL context's objects.
final class GLVideoUpload {
    private let display: ANGLEDisplay
    private let config: ANGLEConfig
    private var context = ANGLEContext()

    private var framebuffer: GLuint = 0
    private var yuvVertexBuffer: GLuint = 0
    private var yTextureUniformLocation: GLint = -1
    private var uvTextureUniformLocation: GLint = -1
    private var yuvFlipYUniformLocation: GLint = -1
    private var yuvFlipXUniformLocation: GLint = -1
    private var yuvSwapXYUniformLocation: GLint = -1
    private var colorMatrixUniformLocation: GLint = -1
    private var yuvPositionAttributeLocation: GLint = -1
    private var yTextureSizeUniformLocation: GLint = -1
    private var uvTextureSizeUniformLocation: GLint = -1

    // The surfaces are kept, so that their IDs aren't reused while the content is known.
    private var knownContent: [GLuint: (content: TextureContent, surface: IOSurfaceRef)] = [:]

    var isValid: Bool {
        !context.isNull()
    }

    init(display: ANGLEDisplay, config: ANGLEConfig, sharing owner: ANGLEContext, isWebGL2: Bool) {
        self.display = display
        self.config = config
        // Create compatible context that shares state with owner, but one that does not have robustness or WebGL
        // compatibility. The reset notification strategy must match the owner's.
        let context = ANGLECocoa.createSharedContext(display, config, owner, isWebGL2)
        if context.isNull() {
            return
        }
        _ = GLContext.makeCurrent(display, context)
        var keepsContext = false
        defer {
            if !keepsContext {
                _ = GLContext.releaseCurrentContext(display)
                _ = ANGLECocoa.destroyContext(display, context)
            }
        }

        let vertexShader = GL_CreateShader(GLenum(GL_VERTEX_SHADER))
        let fragmentShader = GL_CreateShader(GLenum(GL_FRAGMENT_SHADER))
        let yuvProgram = GL_CreateProgram()
        defer {
            GL_DeleteShader(vertexShader)
            GL_DeleteShader(fragmentShader)
            GL_DeleteProgram(yuvProgram)
        }
        ANGLE.shaderSource(vertexShader, std.string(yuvVertexShaderTexture2D))
        ANGLE.shaderSource(fragmentShader, std.string(yuvFragmentShaderTexture2D))
        GL_CompileShader(vertexShader)
        GL_CompileShader(fragmentShader)
        GL_AttachShader(yuvProgram, vertexShader)
        GL_AttachShader(yuvProgram, fragmentShader)
        GL_LinkProgram(yuvProgram)
        // Link status is checked afterwards for theoretical parallel compilation benefit.

        let yuvVertexBuffer = ANGLE.genBuffer()
        var keepsVertexBuffer = false
        defer {
            if !keepsVertexBuffer {
                ANGLE.deleteBuffer(yuvVertexBuffer)
            }
        }
        GL_BindBuffer(GLenum(GL_ARRAY_BUFFER), yuvVertexBuffer)
        ANGLE.bufferData(GLenum(GL_ARRAY_BUFFER), ANGLEFloat12(values: (-1, -1, 1, -1, 1, 1, 1, 1, -1, 1, -1, -1)), GLenum(GL_STATIC_DRAW))

        let framebuffer = ANGLE.genFramebuffer()
        var keepsFramebuffer = false
        defer {
            if !keepsFramebuffer {
                ANGLE.deleteFramebuffer(framebuffer)
            }
        }

        let status = ANGLE.getProgrami(yuvProgram, GLenum(GL_LINK_STATUS))
        if status == 0 {
            let vertexShaderStatus = ANGLE.getShaderi(vertexShader, GLenum(GL_COMPILE_STATUS))
            let fragmentShaderStatus = ANGLE.getShaderi(fragmentShader, GLenum(GL_COMPILE_STATUS))
            GLLog.debug("GLVideoUpload - YUV program failed to link: \(status), \(vertexShaderStatus), \(fragmentShaderStatus).")
            return
        }
        keepsContext = true
        keepsVertexBuffer = true
        keepsFramebuffer = true
        self.context = context
        self.yuvVertexBuffer = yuvVertexBuffer
        self.framebuffer = framebuffer
        yTextureUniformLocation = ANGLE.getUniformLocation(yuvProgram, std.string("u_yTexture"))
        uvTextureUniformLocation = ANGLE.getUniformLocation(yuvProgram, std.string("u_uvTexture"))
        colorMatrixUniformLocation = ANGLE.getUniformLocation(yuvProgram, std.string("u_colorMatrix"))
        yuvFlipYUniformLocation = ANGLE.getUniformLocation(yuvProgram, std.string("u_flipY"))
        yuvFlipXUniformLocation = ANGLE.getUniformLocation(yuvProgram, std.string("u_flipX"))
        yuvSwapXYUniformLocation = ANGLE.getUniformLocation(yuvProgram, std.string("u_swapXY"))
        yTextureSizeUniformLocation = ANGLE.getUniformLocation(yuvProgram, std.string("u_yTextureSize"))
        uvTextureSizeUniformLocation = ANGLE.getUniformLocation(yuvProgram, std.string("u_uvTextureSize"))
        yuvPositionAttributeLocation = ANGLE.getAttribLocation(yuvProgram, std.string("a_position"))
        // Program is deleted by the cleanup while the program binary stays in use.
        GL_UseProgram(yuvProgram)
        GL_EnableVertexAttribArray(GLuint(bitPattern: yuvPositionAttributeLocation))
        ANGLE.vertexAttribPointer(GLuint(bitPattern: yuvPositionAttributeLocation), 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), 0, 0)
        GL_ClearColor(0, 0, 0, 0)
        GL_BindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
    }

    // With the EGL context of its owner current, if the owner's is.
    func destroy() {
        if context.isNull() || !GLContext.makeCurrent(display, context) {
            return
        }
        ANGLE.deleteBuffer(yuvVertexBuffer)
        ANGLE.deleteFramebuffer(framebuffer)
        _ = ANGLECocoa.destroyContext(display, context)
        context = ANGLEContext()
    }

    func invalidateKnownTextureContent(_ texture: GLuint) {
        if !knownContent.isEmpty {
            knownContent[texture] = nil
        }
    }

    // Copies a frame to a TEXTURE_2D texture of the frame's size. Returns how the copy was done, or why it was not.
    func copyVideoSampleToTexture(_ frame: CVPixelBuffer, orientation: UInt8, outputTexture: GLuint, level: GLint, internalFormat: GLenum, format: GLenum, type: GLenum, unpackFlipY: Bool, hardwareOnlyForTesting: Bool) -> GLVideoUploadOutcome {
        var image = frame
        var isConverted = false
        var pixelFormat = CVPixelBufferGetPixelFormatType(image)
        if !Self.isDirectlySupported(pixelFormat) {
            guard let convertedImage = GLContextCallbacks.convertPixelBufferTo420f(frame) else {
                GLLog.debug("GLVideoUpload - failed converting an image with pixel format (\(pixelFormat)).")
                return .conversionFailed
            }
            image = convertedImage
            isConverted = true
            pixelFormat = CVPixelBufferGetPixelFormatType(image)
            assert(pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        }
        guard let surface = ANGLECocoa.ioSurface(image) else {
            return .noIOSurface
        }

        let content = TextureContent(surfaceID: IOSurfaceGetID(surface), surfaceSeed: IOSurfaceGetSeed(surface), level: level, internalFormat: internalFormat, format: format, type: type, unpackFlipY: unpackFlipY, orientation: orientation)
        if let known = knownContent[outputTexture], known.content == content, known.surface === surface {
            // If the texture hasn't been modified since the last time we copied to it, and the image hasn't been
            // modified since the last time it was copied, this is a no-op.
            return .cached
        }
        if context.isNull() || !GLContext.makeCurrent(display, context) {
            return .contextLost
        }
        // When the caller does not fall back, a failure must not redefine the texture (see clearsTextureOnError).
        if hardwareOnlyForTesting && !isRenderableForTesting(internalFormat, format, type) {
            return .framebufferIncomplete
        }

        // Compute transform that undoes the orientation, e.g. moves the origin to top left. Even number of operations
        // (flipX, flipY, swapXY) means a rotation. Odd number of operations means a rotation and a flip. flipX switches
        // between Left and Right. flipY switches between Top and Bottom. swapXY switches LeftTop to TopLeft. Goal is to
        // get to OriginTopLeft.
        var flipY = false
        var flipX = false
        var swapXY = false
        switch orientation {
        case 2:
            flipX = true
        case 3:
            // Rotated 180 degrees.
            flipY = true
            flipX = true
        case 4:
            // Mirrored along the x-axis.
            flipY = true
        case 5:
            // Mirrored along x-axis and rotated 270 degrees clock-wise.
            swapXY = true
        case 6:
            // Rotated 90 degrees clock-wise.
            flipX = true
            swapXY = true
        case 7:
            // Mirror along x-axis and rotated 90 degrees clockwise.
            flipY = true
            flipX = true
            swapXY = true
        case 8:
            // Rotated 270 degrees clock-wise.
            flipY = true
            swapXY = true
        default:
            break
        }
        if unpackFlipY {
            flipY = !flipY
        }

        let sourceWidth = CVPixelBufferGetWidth(image)
        let sourceHeight = CVPixelBufferGetHeight(image)
        let width = swapXY ? sourceHeight : sourceWidth
        let height = swapXY ? sourceWidth : sourceHeight

        GL_Viewport(0, 0, GLsizei(truncatingIfNeeded: width), GLsizei(truncatingIfNeeded: height))

        // The outputTexture might contain uninitialized content on early-outs. Clear it in cases clearsTextureOnError
        // is not reset.
        var clearsTextureOnError = true
        defer {
            if clearsTextureOnError {
                GL_BindTexture(GLenum(GL_TEXTURE_2D), outputTexture)
                ANGLE.texImage2DUninitialized(GLenum(GL_TEXTURE_2D), level, GLint(bitPattern: internalFormat), 0, 0, 0, format, type)
                GL_BindTexture(GLenum(GL_TEXTURE_2D), 0)
            }
        }
        // Allocate memory for the output texture.
        GL_BindTexture(GLenum(GL_TEXTURE_2D), outputTexture)
        ANGLE.texImage2DUninitialized(GLenum(GL_TEXTURE_2D), level, GLint(bitPattern: internalFormat), GLsizei(truncatingIfNeeded: width), GLsizei(truncatingIfNeeded: height), 0, format, type)

        GL_FramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), outputTexture, level)
        if GL_CheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) != GLenum(GL_FRAMEBUFFER_COMPLETE) {
            GLLog.debug("GLVideoUpload - Unable to create framebuffer for outputTexture.")
            return .framebufferIncomplete
        }
        GL_BindTexture(GLenum(GL_TEXTURE_2D), 0)

        // Bind and set up the textures for the video source.
        let yPlaneWidth = IOSurfaceGetWidthOfPlane(surface, 0)
        let yPlaneHeight = IOSurfaceGetHeightOfPlane(surface, 0)
        let uvPlaneWidth = IOSurfaceGetWidthOfPlane(surface, 1)
        let uvPlaneHeight = IOSurfaceGetHeightOfPlane(surface, 1)

        let uvTexture = ANGLE.genTexture()
        defer {
            ANGLE.deleteTexture(uvTexture)
        }
        GL_ActiveTexture(GLenum(GL_TEXTURE1))
        GL_BindTexture(GLenum(GL_TEXTURE_2D), uvTexture)
        Self.setSamplingParameters()
        let uvHandle = ANGLECocoa.createIOSurfacePbuffer(display, config, surface, GLsizei(truncatingIfNeeded: uvPlaneWidth), GLsizei(truncatingIfNeeded: uvPlaneHeight), 1, GLenum(GL_TEXTURE_2D), GLenum(GL_RG), GLenum(GL_UNSIGNED_BYTE), EGL_IOSURFACE_READ_HINT_ANGLE)
        if uvHandle.isNull() || !ANGLECocoa.bindTexImage(display, uvHandle) {
            if !uvHandle.isNull() {
                _ = ANGLECocoa.destroySurface(display, uvHandle)
            }
            return .pbufferFailed
        }
        defer {
            _ = ANGLECocoa.releaseTexImage(display, uvHandle)
            _ = ANGLECocoa.destroySurface(display, uvHandle)
        }

        let yTexture = ANGLE.genTexture()
        defer {
            ANGLE.deleteTexture(yTexture)
        }
        GL_ActiveTexture(GLenum(GL_TEXTURE0))
        GL_BindTexture(GLenum(GL_TEXTURE_2D), yTexture)
        Self.setSamplingParameters()
        let yHandle = ANGLECocoa.createIOSurfacePbuffer(display, config, surface, GLsizei(truncatingIfNeeded: yPlaneWidth), GLsizei(truncatingIfNeeded: yPlaneHeight), 0, GLenum(GL_TEXTURE_2D), GLenum(GL_RED), GLenum(GL_UNSIGNED_BYTE), EGL_IOSURFACE_READ_HINT_ANGLE)
        if yHandle.isNull() || !ANGLECocoa.bindTexImage(display, yHandle) {
            if !yHandle.isNull() {
                _ = ANGLECocoa.destroySurface(display, yHandle)
            }
            return .pbufferFailed
        }
        defer {
            _ = ANGLECocoa.releaseTexImage(display, yHandle)
            _ = ANGLECocoa.destroySurface(display, yHandle)
        }

        // Configure the drawing parameters.
        GL_Uniform1i(yTextureUniformLocation, 0)
        GL_Uniform1i(uvTextureUniformLocation, 1)
        GL_Uniform1i(yuvFlipYUniformLocation, flipY ? 1 : 0)
        GL_Uniform1i(yuvFlipXUniformLocation, flipX ? 1 : 0)
        GL_Uniform1i(yuvSwapXYUniformLocation, swapXY ? 1 : 0)
        GL_Uniform2f(yTextureSizeUniformLocation, GLfloat(yPlaneWidth), GLfloat(yPlaneHeight))
        GL_Uniform2f(uvTextureSizeUniformLocation, GLfloat(uvPlaneWidth), GLfloat(uvPlaneHeight))

        let colorMatrix = YCbCrMatrices.matrix(for: pixelRange(of: pixelFormat), transferFunction(of: image))
        ANGLE.uniformMatrix4fv(colorMatrixUniformLocation, GLboolean(GL_FALSE), colorMatrix)

        // Do the actual drawing.
        GL_DrawArrays(GLenum(GL_TRIANGLES), 0, 6)

        knownContent[outputTexture] = (content, surface)
        clearsTextureOnError = false
        return isConverted ? .converted : .direct
    }

    static func isDirectlySupported(_ pixelFormat: OSType) -> Bool {
        // FIXME: This currently only supports '420v' and '420f' pixel formats. Investigate supporting more pixel formats.
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            return true
        }
#if HAVE_COREVIDEO_COMPRESSED_PIXEL_FORMAT_TYPES
        if pixelFormat == ANGLECocoa.agx420YpCbCr8BiPlanarVideoRange() || pixelFormat == ANGLECocoa.agx420YpCbCr8BiPlanarFullRange() {
            return true
        }
#endif
        return false
    }

    private static func setSamplingParameters() {
        GL_TexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        GL_TexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        GL_TexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        GL_TexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
    }

    // Whether a level of the format can be rendered to, checked on a 1x1 texture so that the destination texture stays
    // unchanged. Only used when the caller does not fall back on failure.
    private func isRenderableForTesting(_ internalFormat: GLenum, _ format: GLenum, _ type: GLenum) -> Bool {
        let texture = ANGLE.genTexture()
        GL_BindTexture(GLenum(GL_TEXTURE_2D), texture)
        ANGLE.texImage2DUninitialized(GLenum(GL_TEXTURE_2D), 0, GLint(bitPattern: internalFormat), 1, 1, 0, format, type)
        GL_FramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
        let isComplete = GL_CheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE)
        GL_FramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), 0, 0)
        GL_BindTexture(GLenum(GL_TEXTURE_2D), 0)
        ANGLE.deleteTexture(texture)
        return isComplete
    }
}

#endif
