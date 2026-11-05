// Copyright (C) 2009-2021 Apple Inc. All rights reserved.
// Copyright (C) 2010, 2013 Apple Inc. All rights reserved.
// Copyright (C) 2019 Google Inc. All rights reserved.
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

internal import WebCoreANGLE
internal import Synchronization

typealias GLContextCallbacks = WebCore.GLContextCallbacks

// The GL logic of a WebGL context over ANGLE, for every process and port: what GraphicsContextGLANGLE was. It is
// confined to the thread that made it. Its client and platform are reached through the context's identifier.
@_expose(Cxx)
public final class GLContext {
    // The identifier of the context whose EGL context is current on this thread, as far as the island knows.
    private static let currentContextID = Atomic<UInt64>(0)

    let contextID: UInt64
    private let platform: any GLContextPlatform
#if WTF_PLATFORM_COCOA
    // The platform again, for its Cocoa entry points.
    private let cocoaPlatform: CocoaGLPlatform?
#endif
    let display: ANGLEDisplay
    let eglContext: ANGLEContext
    let isForWebGL2: Bool
    let supportsWebGLDraftExtensions: Bool

    var state = GLState()
    var extensions = GLExtensions()

    // The state most entry points read or write is in Atomics rather than in state, since they need no exclusivity
    // check. The context is confined to one thread, so relaxed ordering is all they need.
    private let errorsStorage = Atomic<UInt8>(0)
    private let contextLostStorage = Atomic<Bool>(false)
    private let boundReadFBOStorage = Atomic<GLuint>(0)
    private let boundDrawFBOStorage = Atomic<GLuint>(0)
    private let maxInternalFramebufferWidth = Atomic<Int32>(0)
    private let maxInternalFramebufferHeight = Atomic<Int32>(0)

    var errors: GLErrorCodes {
        get { GLErrorCodes(rawValue: errorsStorage.load(ordering: .relaxed)) }
        set { errorsStorage.store(newValue.rawValue, ordering: .relaxed) }
    }

    var contextLost: Bool {
        get { contextLostStorage.load(ordering: .relaxed) }
        set { contextLostStorage.store(newValue, ordering: .relaxed) }
    }

    var boundReadFBO: GLuint {
        get { boundReadFBOStorage.load(ordering: .relaxed) }
        set { boundReadFBOStorage.store(newValue, ordering: .relaxed) }
    }

    var boundDrawFBO: GLuint {
        get { boundDrawFBOStorage.load(ordering: .relaxed) }
        set { boundDrawFBOStorage.store(newValue, ordering: .relaxed) }
    }

    var maxInternalFramebufferSize: GLSize {
        get { GLSize(width: maxInternalFramebufferWidth.load(ordering: .relaxed), height: maxInternalFramebufferHeight.load(ordering: .relaxed)) }
        set {
            maxInternalFramebufferWidth.store(newValue.width, ordering: .relaxed)
            maxInternalFramebufferHeight.store(newValue.height, ordering: .relaxed)
        }
    }
    private(set) var texture: GLuint = 0
    private(set) var fbo: GLuint = 0

    // A context whose platform is C++, which made its EGL context.
    @_expose(Cxx)
    public init(contextID: UInt64, display: ANGLEDisplay, context: ANGLEContext, isWebGL2: Bool, supportsWebGLDraftExtensions: Bool) {
        self.contextID = contextID
        self.platform = CxxGLContextPlatform(contextID: contextID, display: display, eglContext: context)
#if WTF_PLATFORM_COCOA
        self.cocoaPlatform = nil
#endif
        self.display = display
        self.eglContext = context
        self.isForWebGL2 = isWebGL2
        self.supportsWebGLDraftExtensions = supportsWebGLDraftExtensions
    }

#if WTF_PLATFORM_COCOA
    @_expose(Cxx)
    public init(contextID: UInt64, cocoaPlatform: borrowing CocoaGLPlatform, supportsWebGLDraftExtensions: Bool) {
        let platform = copy cocoaPlatform
        self.contextID = contextID
        self.platform = platform
        self.cocoaPlatform = platform
        self.display = platform.display
        self.eglContext = platform.eglContext
        self.isForWebGL2 = platform.attributes.isWebGL2
        self.supportsWebGLDraftExtensions = supportsWebGLDraftExtensions
    }
#endif

    // Context state.

    // Called by every entry point that calls ANGLE. Making a context current is expensive, so the island remembers
    // which one is.
    func makeContextCurrent() -> Bool {
        if Self.currentContextID.load(ordering: .relaxed) == contextID {
            return true
        }
        guard ANGLE.makeCurrent(display, eglContext) else {
            return false
        }
        Self.currentContextID.store(contextID, ordering: .relaxed)
        return true
    }

    @_expose(Cxx)
    public func makeCurrentForPlatform() -> Bool {
        makeContextCurrent()
    }

    // For the C++ that makes another EGL context current, or none.
    @_expose(Cxx)
    public static func forgetCurrentContext() {
        currentContextID.store(0, ordering: .relaxed)
    }

    @_expose(Cxx)
    public static func makeCurrent(_ display: ANGLEDisplay, _ context: ANGLEContext) -> Bool {
        forgetCurrentContext()
        return ANGLE.makeCurrent(display, context)
    }

    @_expose(Cxx)
    public static func releaseCurrentContext(_ display: ANGLEDisplay) -> Bool {
        forgetCurrentContext()
        return ANGLE.releaseCurrentContext(display)
    }

    @_expose(Cxx)
    public func isCurrent() -> Bool {
        Self.currentContextID.load(ordering: .relaxed) == contextID
    }

    // Initializes the context after the platform made its EGL context. Returns false if it should not be used.
    @_expose(Cxx)
    public func initialize() -> Bool {
        extensions.setSupported(ANGLE.getString(GLenum(GL_EXTENSIONS)), requestable: ANGLE.getString(GLenum(GL_REQUESTABLE_EXTENSIONS_ANGLE)))

        // Enable the extensions needed for antialias and preserveDrawingBuffer, to avoid IPC.
        _ = enableExtensions(["GL_ANGLE_framebuffer_multisample", "GL_ANGLE_framebuffer_blit", "GL_OES_rgb8_rgba8"])

        if isForWebGL2 && !enableExtensions(["GL_EXT_occlusion_query_boolean", "GL_ANGLE_framebuffer_multisample"]) {
            return false
        }

        if !platform.initializeExtensions(self) {
            return false
        }

        if isForWebGL2 {
            GL_Enable(GLenum(GL_PRIMITIVE_RESTART_FIXED_INDEX))
        }

        // Create the texture that will be used for the framebuffer.
        let textureTarget = GLenum(GL_TEXTURE_2D)
        texture = ANGLE.genTexture()
        GL_BindTexture(textureTarget, texture)
        GL_TexParameteri(textureTarget, GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        GL_TexParameteri(textureTarget, GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        GL_TexParameteri(textureTarget, GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        GL_TexParameteri(textureTarget, GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        GL_BindTexture(textureTarget, 0)

        fbo = ANGLE.genFramebuffer()
        GL_BindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        boundDrawFBO = fbo
        boundReadFBO = fbo

        GL_ClearColor(0, 0, 0, 0)

        // Compute initial platform-independent max internal framebuffer size.
        let maxTextureSize = ANGLE.getInteger(GLenum(GL_MAX_TEXTURE_SIZE))
        let maxRenderbufferSize = ANGLE.getInteger(GLenum(GL_MAX_RENDERBUFFER_SIZE))
        let maxViewportDims = ANGLE.getInteger2(GLenum(GL_MAX_VIEWPORT_DIMS))
        var maxInternalFramebufferSize = GLSize(width: maxViewportDims.x, height: maxViewportDims.y)
        maxInternalFramebufferSize.clampToMaximumSize(GLSize(width: maxTextureSize, height: maxTextureSize))
        maxInternalFramebufferSize.clampToMaximumSize(GLSize(width: maxRenderbufferSize, height: maxRenderbufferSize))
        self.maxInternalFramebufferSize = maxInternalFramebufferSize

        if !platform.initialize(self) {
            return false
        }

        let khrDebugIsSupported = enableExtensions(["GL_KHR_debug"])
        assert(khrDebugIsSupported)
        GL_Enable(GLenum(GL_DEBUG_OUTPUT_KHR))
        GL_Enable(GLenum(GL_DEBUG_OUTPUT_SYNCHRONOUS_KHR))
        ANGLE.debugMessageControl(GLenum(GL_DONT_CARE), GLenum(GL_DONT_CARE), GLenum(GL_DONT_CARE), GLboolean(GL_FALSE))
        ANGLE.debugMessageControl(GLenum(GL_DEBUG_SOURCE_API_KHR), GLenum(GL_DONT_CARE), GLenum(GL_DONT_CARE), GLboolean(GL_TRUE))
        ANGLE.setDebugMessageCallback(contextID)

        let packReverseRowOrderIsSupported = enableExtensions(["GL_ANGLE_pack_reverse_row_order"])
#if WTF_PLATFORM_COCOA
        assert(packReverseRowOrderIsSupported)
#else
        _ = packReverseRowOrderIsSupported
#endif

        assert(GL_GetError() == GLenum(GL_NO_ERROR))

        extensions.computeKnownActiveAndRequestable(supportsWebGLDraftExtensions: supportsWebGLDraftExtensions)
        return true
    }

    // Frees what the platform made for the context, with the context current. Called before the platform's C++
    // client is destroyed.
    @_expose(Cxx)
    public func willDestroyPlatform() {
        if makeContextCurrent() {
            platform.willDestroy(self)
        }
    }

    // Destroys the context's GL objects, then its platform's EGL objects.
    @_expose(Cxx)
    public func destroy() {
        let didReset = willDestroy()
        platform.destroy(self, didReset: didReset)
    }

#if WTF_PLATFORM_COCOA
    // The entry points of the Cocoa platform that need the context. Each does nothing for a context of a C++ platform.

    // Whether the current frame can be displayed. If it can, the caller inserts the frame's finished fence, then
    // calls didPrepareForDisplay().
    @_expose(Cxx)
    public func willPrepareForDisplay() -> Bool {
        cocoaPlatform?.willPrepareForDisplay(self) ?? false
    }

    @_expose(Cxx)
    public func didPrepareForDisplay() {
        cocoaPlatform?.didPrepareForDisplay(self)
    }

    // A copy of the drawing (0) or display (1) buffer, flipped to image orientation, or nil. The copy is retained.
    @_expose(Cxx)
    public func copySurfaceBuffer(_ bufferType: UInt8) -> IOSurfaceRef? {
        cocoaPlatform?.copySurfaceBuffer(self, bufferType)
    }

    @_expose(Cxx)
    public func readCompositedResults(_ pixels: WebCore.GLLentMutableBytes, _ width: Int32, _ height: Int32) -> Bool {
        cocoaPlatform?.readCompositedResults(self, pixels, width, height) ?? false
    }

    @_expose(Cxx)
    public func drawingBufferColorSpaceDidChange() {
        cocoaPlatform?.drawingBufferColorSpaceDidChange(self)
    }

#if ENABLE_WEBXR
    @_expose(Cxx)
    public func enableRequiredWebXRExtensions() -> Bool {
        guard let cocoaPlatform, makeContextCurrent() else {
            return false
        }
        return cocoaPlatform.enableRequiredWebXRExtensions(self)
    }
#endif
#endif

    // Deletes the context's own GL objects before the platform destroys its EGL context, and reports whether the
    // context had noticed a GPU reset.
    @_expose(Cxx)
    public func willDestroy() -> Bool {
        guard makeContextCurrent() else {
            return false
        }
        let didReset = GL_GetGraphicsResetStatusEXT() != GLenum(GL_NO_ERROR)
        GL_Disable(GLenum(GL_DEBUG_OUTPUT_KHR))
        if texture != 0 {
            ANGLE.deleteTexture(texture)
        }
        if fbo != 0 {
            ANGLE.deleteFramebuffer(fbo)
        }
        return didReset
    }

    // Debug messages from ANGLE, before they go to the client. The context loss is reported with
    // forceContextLost(), not as the errors of the calls after the loss.
    @_expose(Cxx)
    public static func reportsDebugMessage(_ type: GLenum, _ id: GLuint) -> Bool {
        !(type == GLenum(GL_DEBUG_TYPE_ERROR_KHR) && id == GLuint(GL_CONTEXT_LOST))
    }

    @_expose(Cxx)
    public func estimatedMemoryCost() -> Int64 {
        var usage: UInt64 = 0
        guard ANGLE.queryContextMemoryUsage(display, eglContext, &usage) else {
            return -1
        }
        return Int64(truncatingIfNeeded: usage)
    }

    // Client and platform.

    func addError(_ error: GLErrorCodes) {
        errors.formUnion(error)
    }

    func forceContextLost() {
        contextLost = true
        GLContextCallbacks.forceContextLost(contextID)
    }

    func didChangeMemoryCost() {
        GLContextCallbacks.didChangeMemoryCost(contextID)
    }

    func invalidateKnownTextureContent(_ texture: GLuint) {
#if WTF_PLATFORM_COCOA
        if let cocoaPlatform {
            cocoaPlatform.invalidateKnownTextureContent(texture)
            return
        }
#endif
        platform.invalidateKnownTextureContent(texture)
    }

    // Did the most recent drawing operation leave the GPU in an acceptable state?
    func checkGPUStatus() {
        if contextLost {
            return
        }
        if GL_GetGraphicsResetStatusEXT() == GLenum(GL_NO_ERROR) {
            return
        }
        platform.didLoseDisplay()
        forceContextLost()
        _ = Self.releaseCurrentContext(display)
    }

    @_expose(Cxx)
    public func checkGPUStatusForPlatform() {
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func isContextLost() -> Bool {
        contextLost
    }

    @_expose(Cxx)
    public func didForceContextLost() {
        contextLost = true
    }

    @_expose(Cxx)
    public func takeFailNextDrawingBufferAllocation() -> Bool {
        let fail = state.failNextDrawingBufferAllocation
        state.failNextDrawingBufferAllocation = false
        return fail
    }

    @_expose(Cxx)
    public func failsNextDrawingBufferAllocation() -> Bool {
        state.failNextDrawingBufferAllocation
    }

    @_expose(Cxx)
    public func clampMaxInternalFramebufferSize(_ width: Int32, _ height: Int32) {
        maxInternalFramebufferSize.clampToMaximumSize(GLSize(width: width, height: height))
    }

    @_expose(Cxx)
    public func drawingBufferTexture() -> GLuint {
        texture
    }

    @_expose(Cxx)
    public func boundReadFramebuffer() -> GLuint {
        boundReadFBO
    }

    @_expose(Cxx)
    public func boundDrawFramebuffer() -> GLuint {
        boundDrawFBO
    }

    @_expose(Cxx)
    public func knownActiveExtensions() -> UInt64 {
        extensions.knownActive
    }

    @_expose(Cxx)
    public func requestableExtensions() -> UInt64 {
        extensions.requestable
    }

    // Enables the extensions named by NUL-terminated strings, for the platform, only if all are supported. Returns
    // false, and enables nothing, otherwise.
    @_expose(Cxx)
    public func enableExtensionsForPlatform(_ names: WebCore.GLLentCStrings) -> Bool {
        var strings: [Swift.String] = []
        for index in 0..<names.size() {
            strings.append(Swift.String(ANGLE.copyString(names, index)))
        }
        return enableExtensions(strings)
    }

    // Enables extensions only if all are supported. Returns true if all are supported; changes nothing otherwise.
    @_expose(!Cxx)
    func enableExtensions(_ names: [Swift.String]) -> Bool {
        guard let requests = extensions.requestsToEnable(names) else {
            return false
        }
        for name in requests {
            ANGLE.requestExtension(std.string(name))
            extensions.didEnableRequestable(name)
        }
        return true
    }

    @_expose(Cxx)
    public func enableExtension(_ extension: UInt8) -> Bool {
        if extensions.knownActive & (1 << UInt64(`extension`)) != 0 {
            return true
        }
        if extensions.requestable & (1 << UInt64(`extension`)) == 0 {
            return false
        }
        guard let name = GLExtensions.name(of: `extension`) else {
            assertionFailure()
            return false
        }
        extensions.knownActive |= 1 << UInt64(`extension`)
        guard makeContextCurrent() else {
            return true
        }
        let success = enableExtensions([name])
        assert(success)
        return true
    }

    // Errors.

    @discardableResult
    func updateErrors() -> Bool {
        guard makeContextCurrent() else {
            return false
        }
        var movedAnError = false
        // Set an arbitrary limit of 100 here to avoid creating a hang if a problem driver has a bug that causes it to
        // never clear the error. Otherwise, we would just loop until we got NO_ERROR.
        for _ in 0..<100 {
            let error = GL_GetError()
            if error == GLenum(GL_NO_ERROR) {
                break
            }
            addError(GLErrorCodes(glError: error))
            movedAnError = true
        }
        return movedAnError
    }

    @_expose(Cxx)
    public func getErrors() -> UInt8 {
        guard makeContextCurrent() else {
            return GLErrorCodes.invalidOperation.rawValue
        }
        updateErrors()
        let errors = self.errors
        self.errors = []
        return errors.rawValue
    }

    @_expose(Cxx)
    public func addErrors(_ errors: UInt8) {
        addError(GLErrorCodes(rawValue: errors))
    }

    // Drawing buffer.

    @_expose(Cxx)
    public func reshape(_ width: Int32, _ height: Int32) {
        if width == state.currentWidth && height == state.currentHeight {
            return
        }

        assert(width >= 0 && height >= 0)
        if width < 0 || height < 0 {
            return
        }

        if width > maxInternalFramebufferSize.width || height > maxInternalFramebufferSize.height {
            return
        }

        guard makeContextCurrent() else {
            return
        }

        // FIXME: these may call makeContextCurrent again, we need to do this before changing the size.
        updateErrors()

        state.currentWidth = width
        state.currentHeight = height
        GLContextCallbacks.didChangeInternalFramebufferSize(contextID, width, height)

        let shouldBindFBO = boundDrawFBO != fbo || boundReadFBO != fbo
        if shouldBindFBO {
            GL_BindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        }

        if takeFailNextDrawingBufferAllocation() || !platform.reshapeDrawingBuffer(self) {
            GLLog.webGL("Fatal: Unable to allocate backing store of size \(width) x \(height)")
            forceContextLost()
            return
        }
        GL_FramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)

        if shouldBindFBO {
            GL_BindFramebuffer(GLenum(GL_FRAMEBUFFER), boundDrawFBO)
            if isForWebGL2 && boundDrawFBO != boundReadFBO {
                GL_BindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), boundReadFBO)
            }
        }

        let error = GL_GetError()
        if error != GLenum(GL_NO_ERROR) {
            GLLog.webGL("Fatal: OpenGL error during GraphicsContextGL buffer initialization (\(error)).")
            forceContextLost()
            return
        }
        didChangeMemoryCost()
    }

    // Reads the drawing buffer at its size, tightly packed RGBA, into pixels. Returns false if the read failed.
    @_expose(Cxx)
    public func readPixelsForPaintResults(_ pixels: WebCore.GLLentMutableBytes, _ width: Int32, _ height: Int32) -> Bool {
        withPixelPackBufferUnbound {
            setPackParameters(1, 0, GLboolean(GL_FALSE))
            updateErrors()
            _ = ANGLE.readPixels(0, 0, width, height, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), pixels)
            // The pixel buffer is uninitialized; never return it if the read was rejected for any reason.
            return !updateErrors()
        }
    }

    // As readPixelsForPaintResults, from the drawing buffer texture through a scratch framebuffer: when the context
    // is neither multisampled nor preserving the drawing buffer, fbo is the application visible default framebuffer,
    // and so its read buffer is application state which might be NONE.
    @_expose(Cxx)
    public func readRenderingResults(_ pixels: WebCore.GLLentMutableBytes, _ width: Int32, _ height: Int32) -> Bool {
        withScratchReadFramebuffer(attaching: texture) {
            readPixelsForPaintResults(pixels, width, height)
        }
    }

    var internalFramebufferSize: GLSize {
        GLSize(width: state.currentWidth, height: state.currentHeight)
    }

    @_expose(Cxx)
    public func maxDrawingBufferSize() -> ANGLEInt2 {
        let size = maxInternalFramebufferSize
        return ANGLEInt2(x: size.width, y: size.height)
    }

    // Limits.

    @_expose(Cxx)
    public func getInteger(_ pname: GLenum) -> GLint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getInteger(pname)
    }

    @_expose(Cxx)
    public func maxViewportDims() -> ANGLEInt2 {
        guard makeContextCurrent() else {
            return ANGLEInt2()
        }
        return ANGLE.getInteger2(GLenum(GL_MAX_VIEWPORT_DIMS))
    }

    // Textures.

    @_expose(Cxx)
    public func activeTexture(_ texture: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        state.activeTextureUnit = texture
        GL_ActiveTexture(texture)
    }

    @_expose(Cxx)
    public func bindTexture(_ target: GLenum, _ texture: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        state.bindTexture(texture, target: target)
        GL_BindTexture(target, texture)
    }

    @_expose(Cxx)
    public func createTexture() -> GLuint {
        guard makeContextCurrent() else {
            return 0
        }
        let name = ANGLE.genTexture()
        invalidateKnownTextureContent(name)
        return name
    }

    @_expose(Cxx)
    public func deleteTexture(_ texture: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        state.textureBindings.removeBindings(of: texture)
        ANGLE.deleteTexture(texture)
        invalidateKnownTextureContent(texture)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func texStorage2D(_ target: GLenum, _ levels: GLsizei, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        GL_TexStorage2D(target, levels, internalformat, width, height)
        invalidateKnownTextureContent(state.currentBoundTexture)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func texStorage3D(_ target: GLenum, _ levels: GLsizei, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        GL_TexStorage3D(target, levels, internalformat, width, height, depth)
        invalidateKnownTextureContent(state.currentBoundTexture)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func texImage2D(_ target: GLenum, _ level: GLint, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei, _ border: GLint, _ format: GLenum, _ type: GLenum, _ pixels: WebCore.GLLentBytes) {
        let internalformat = isForWebGL2 ? internalformat : adjustWebGL1TextureInternalFormat(internalformat, format, type)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.texImage2D(target, level, GLint(bitPattern: internalformat), width, height, border, format, type, pixels)
        invalidateKnownTextureContent(state.currentBoundTexture)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func texImage2DFromUnpackBuffer(_ target: GLenum, _ level: GLint, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei, _ border: GLint, _ format: GLenum, _ type: GLenum, _ offset: GLintptr) {
        let internalformat = isForWebGL2 ? internalformat : adjustWebGL1TextureInternalFormat(internalformat, format, type)
        guard makeContextCurrent() else {
            return
        }
        guard ANGLE.texImage2DFromUnpackBuffer(target, level, GLint(bitPattern: internalformat), width, height, border, format, type, offset) else {
            addError(.invalidOperation)
            return
        }
        invalidateKnownTextureContent(state.currentBoundTexture)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func texSubImage2D(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ type: GLenum, _ pixels: WebCore.GLLentBytes) {
        guard makeContextCurrent() else {
            return
        }
        // FIXME: we will need to deal with PixelStore params when dealing with image buffers that differ from the subimage size.
        ANGLE.texSubImage2D(target, level, xoffset, yoffset, width, height, format, type, pixels)
        invalidateKnownTextureContent(state.currentBoundTexture)
    }

    @_expose(Cxx)
    public func texSubImage2DFromUnpackBuffer(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ type: GLenum, _ offset: GLintptr) {
        guard makeContextCurrent() else {
            return
        }
        // FIXME: we will need to deal with PixelStore params when dealing with image buffers that differ from the subimage size.
        guard ANGLE.texSubImage2DFromUnpackBuffer(target, level, xoffset, yoffset, width, height, format, type, offset) else {
            addError(.invalidOperation)
            return
        }
        invalidateKnownTextureContent(state.currentBoundTexture)
    }

    @_expose(Cxx)
    public func compressedTexImage2D(_ target: GLenum, _ level: GLint, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei, _ border: GLint, _ data: WebCore.GLLentBytes) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.compressedTexImage2D(target, level, internalformat, width, height, border, data)
        invalidateKnownTextureContent(state.currentBoundTexture)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func compressedTexImage2DFromUnpackBuffer(_ target: GLenum, _ level: GLint, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei, _ border: GLint, _ imageSize: GLsizei, _ offset: GLintptr) {
        guard makeContextCurrent() else {
            return
        }
        guard ANGLE.compressedTexImage2DFromUnpackBuffer(target, level, internalformat, width, height, border, imageSize, offset) else {
            addError(.invalidOperation)
            return
        }
        invalidateKnownTextureContent(state.currentBoundTexture)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func compressedTexSubImage2D(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ data: WebCore.GLLentBytes) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.compressedTexSubImage2D(target, level, xoffset, yoffset, width, height, format, data)
        invalidateKnownTextureContent(state.currentBoundTexture)
    }

    @_expose(Cxx)
    public func compressedTexSubImage2DFromUnpackBuffer(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ imageSize: GLsizei, _ offset: GLintptr) {
        guard makeContextCurrent() else {
            return
        }
        guard ANGLE.compressedTexSubImage2DFromUnpackBuffer(target, level, xoffset, yoffset, width, height, format, imageSize, offset) else {
            addError(.invalidOperation)
            return
        }
        invalidateKnownTextureContent(state.currentBoundTexture)
    }

    @_expose(Cxx)
    public func texImage3D(_ target: GLenum, _ level: GLint, _ internalformat: GLint, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei, _ border: GLint, _ format: GLenum, _ type: GLenum, _ pixels: WebCore.GLLentBytes) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.texImage3D(target, level, internalformat, width, height, depth, border, format, type, pixels)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func texImage3DFromUnpackBuffer(_ target: GLenum, _ level: GLint, _ internalformat: GLint, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei, _ border: GLint, _ format: GLenum, _ type: GLenum, _ offset: GLintptr) {
        guard makeContextCurrent() else {
            return
        }
        guard ANGLE.texImage3DFromUnpackBuffer(target, level, internalformat, width, height, depth, border, format, type, offset) else {
            addError(.invalidOperation)
            return
        }
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func texSubImage3D(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ zoffset: GLint, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei, _ format: GLenum, _ type: GLenum, _ pixels: WebCore.GLLentBytes) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.texSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels)
    }

    @_expose(Cxx)
    public func texSubImage3DFromUnpackBuffer(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ zoffset: GLint, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei, _ format: GLenum, _ type: GLenum, _ offset: GLintptr) {
        guard makeContextCurrent() else {
            return
        }
        guard ANGLE.texSubImage3DFromUnpackBuffer(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, offset) else {
            addError(.invalidOperation)
            return
        }
    }

    @_expose(Cxx)
    public func compressedTexImage3D(_ target: GLenum, _ level: GLint, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei, _ border: GLint, _ data: WebCore.GLLentBytes) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.compressedTexImage3D(target, level, internalformat, width, height, depth, border, data)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func compressedTexImage3DFromUnpackBuffer(_ target: GLenum, _ level: GLint, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei, _ border: GLint, _ imageSize: GLsizei, _ offset: GLintptr) {
        guard makeContextCurrent() else {
            return
        }
        guard ANGLE.compressedTexImage3DFromUnpackBuffer(target, level, internalformat, width, height, depth, border, imageSize, offset) else {
            addError(.invalidOperation)
            return
        }
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func compressedTexSubImage3D(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ zoffset: GLint, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei, _ format: GLenum, _ data: WebCore.GLLentBytes) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.compressedTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, data)
    }

    @_expose(Cxx)
    public func compressedTexSubImage3DFromUnpackBuffer(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ zoffset: GLint, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei, _ format: GLenum, _ imageSize: GLsizei, _ offset: GLintptr) {
        guard makeContextCurrent() else {
            return
        }
        guard ANGLE.compressedTexSubImage3DFromUnpackBuffer(target, level, xoffset, yoffset, zoffset, width, height, depth, format, imageSize, offset) else {
            addError(.invalidOperation)
            return
        }
    }

    @_expose(Cxx)
    public func framebufferTexture2D(_ target: GLenum, _ attachment: GLenum, _ textarget: GLenum, _ texture: GLuint, _ level: GLint) {
        guard makeContextCurrent() else {
            return
        }
        GL_FramebufferTexture2D(target, attachment, textarget, texture, level)
        invalidateKnownTextureContent(state.currentBoundTexture)
    }

    // Read pixels.

    @_expose(Cxx)
    public func readPixels(_ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ type: GLenum, _ data: WebCore.GLLentMutableBytes, _ alignment: GLint, _ rowLength: GLint, _ reverseRowOrder: GLboolean) {
        guard makeContextCurrent() else {
            return
        }
        withPixelPackBufferUnbound {
            setPackParameters(alignment, rowLength, reverseRowOrder)
            _ = readPixelsImpl(x, y, width, height, format, type, data)
        }
    }

    // Reads pixels from positive pixel coordinates with tight packing.
    @_expose(Cxx)
    public func readPixelsWithStatus(_ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ type: GLenum, _ reverseRowOrder: GLboolean, _ data: WebCore.GLLentMutableBytes) -> ANGLEReadPixelsStatus {
        guard makeContextCurrent() else {
            return ANGLEReadPixelsStatus()
        }
        return withPixelPackBufferUnbound {
            // Used for tight packing read only.
            setPackParameters(1, 0, reverseRowOrder)
            return readPixelsImpl(x, y, width, height, format, type, data)
        }
    }

    @_expose(Cxx)
    public func readPixelsBufferObject(_ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ type: GLenum, _ offset: GLintptr, _ alignment: GLint, _ rowLength: GLint) {
        guard makeContextCurrent() else {
            return
        }
        if !isForWebGL2 {
            addError(.invalidOperation)
            return
        }
        guard ANGLE.getInteger(GLenum(GL_PIXEL_PACK_BUFFER_BINDING)) != 0 else {
            addError(.invalidOperation)
            return
        }
        setPackParameters(alignment, rowLength, GLboolean(GL_FALSE))
        // ANGLE validates the read size against the PBO size.
        _ = ANGLE.readPixelsIntoPackBuffer(x, y, width, height, format, type, offset)
    }

    private func readPixelsImpl(_ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ type: GLenum, _ data: WebCore.GLLentMutableBytes) -> ANGLEReadPixelsStatus {
        // FIXME: remove the two glFlush calls when the driver bug is fixed, i.e.,
        // all previous rendering calls should be done before reading pixels.
        GL_Flush()
        updateErrors()
        let result = ANGLE.readPixels(x, y, width, height, format, type, data)
        if updateErrors() {
            return ANGLEReadPixelsStatus()
        }
        return ANGLEReadPixelsStatus(width: result.columns, height: result.rows, succeeded: true)
    }

    func setPackParameters(_ alignment: GLint, _ rowLength: GLint, _ reverseRowOrder: GLboolean) {
        if state.packAlignment != alignment {
            GL_PixelStorei(GLenum(GL_PACK_ALIGNMENT), alignment)
            state.packAlignment = alignment
        }
        if state.packRowLength != rowLength {
            GL_PixelStorei(GLenum(GL_PACK_ROW_LENGTH), rowLength)
            state.packRowLength = rowLength
        }
        if state.packReverseRowOrder != reverseRowOrder {
            GL_PixelStorei(GLenum(GL_PACK_REVERSE_ROW_ORDER_ANGLE), GLint(reverseRowOrder))
            state.packReverseRowOrder = reverseRowOrder
        }
    }

    // Buffers.

    @_expose(Cxx)
    public func bufferDataUninitialized(_ target: GLenum, _ size: GLsizeiptr, _ usage: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.bufferDataUninitialized(target, size, usage)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func bufferData(_ target: GLenum, _ data: WebCore.GLLentBytes, _ usage: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.bufferData(target, data, usage)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func bufferSubData(_ target: GLenum, _ offset: GLintptr, _ data: WebCore.GLLentBytes) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.bufferSubData(target, offset, data)
    }

    // Returns whether the data was read.
    @_expose(Cxx)
    public func getBufferSubData(_ target: GLenum, _ offset: GLintptr, _ data: WebCore.GLLentMutableBytes) -> Bool {
        guard makeContextCurrent() else {
            return false
        }
        switch ANGLE.getBufferSubData(target, offset, data) {
        case .MapFailed:
            return false
        case .Read:
            return true
        case .ReadButUnmapFailed:
            addError(.invalidOperation)
            return true
        @unknown default:
            return false
        }
    }

    @_expose(Cxx)
    public func createBuffer() -> GLuint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.genBuffer()
    }

    @_expose(Cxx)
    public func deleteBuffer(_ buffer: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.deleteBuffer(buffer)
        didChangeMemoryCost()
    }

    // Framebuffers and renderbuffers.

    @_expose(Cxx)
    public func bindFramebuffer(_ target: GLenum, _ buffer: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        let framebuffer = buffer != 0 ? buffer : fbo
        GL_BindFramebuffer(target, framebuffer)
        if target == GLenum(GL_FRAMEBUFFER) {
            boundReadFBO = framebuffer
            boundDrawFBO = framebuffer
        } else if target == GLenum(GL_READ_FRAMEBUFFER) {
            boundReadFBO = framebuffer
        } else if target == GLenum(GL_DRAW_FRAMEBUFFER) {
            boundDrawFBO = framebuffer
        }
    }

    @_expose(Cxx)
    public func createFramebuffer() -> GLuint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.genFramebuffer()
    }

    @_expose(Cxx)
    public func deleteFramebuffer(_ framebuffer: GLuint) {
        if framebuffer == 0 {
            // FBO 0 represents the default framebuffer (fbo via the bindFramebuffer(0) substitution); deleting it
            // would tear down the result framebuffer.
            addError(.invalidOperation)
            return
        }
        guard makeContextCurrent() else {
            return
        }
        // Make sure the framebuffer is not going to be used for drawing operations after it gets deleted.
        if isForWebGL2 {
            if framebuffer == boundDrawFBO {
                bindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), 0)
            }
            if framebuffer == boundReadFBO {
                bindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), 0)
            }
        } else if framebuffer == boundDrawFBO {
            bindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        }
        ANGLE.deleteFramebuffer(framebuffer)
    }

    @_expose(Cxx)
    public func createRenderbuffer() -> GLuint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.genRenderbuffer()
    }

    @_expose(Cxx)
    public func deleteRenderbuffer(_ renderbuffer: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.deleteRenderbuffer(renderbuffer)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func renderbufferStorage(_ target: GLenum, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        if takeFailNextRenderbufferAllocation() {
            addError(.outOfMemory)
            return
        }
        GL_RenderbufferStorage(target, internalformat, width, height)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func renderbufferStorageMultisample(_ target: GLenum, _ samples: GLsizei, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        if takeFailNextRenderbufferAllocation() {
            addError(.outOfMemory)
            return
        }
        GL_RenderbufferStorageMultisample(target, samples, internalformat, width, height)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func renderbufferStorageMultisampleANGLE(_ target: GLenum, _ samples: GLsizei, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        if takeFailNextRenderbufferAllocation() {
            addError(.outOfMemory)
            return
        }
        GL_RenderbufferStorageMultisampleANGLE(target, samples, internalformat, width, height)
        didChangeMemoryCost()
    }

    private func takeFailNextRenderbufferAllocation() -> Bool {
        let fail = state.failNextRenderbufferAllocation
        state.failNextRenderbufferAllocation = false
        return fail
    }

    @_expose(Cxx)
    public func blitFramebuffer(_ srcX0: GLint, _ srcY0: GLint, _ srcX1: GLint, _ srcY1: GLint, _ dstX0: GLint, _ dstY0: GLint, _ dstX1: GLint, _ dstY1: GLint, _ mask: GLbitfield, _ filter: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        if isForWebGL2 {
            GL_BlitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter)
        } else if extensions.isNVFramebufferBlitEnabled {
            GL_BlitFramebufferNV(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter)
        } else {
            GL_BlitFramebufferANGLE(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter)
        }
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func invalidateFramebuffer(_ target: GLenum, _ attachments: WebCore.GLLentUnsignedInts) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.invalidateFramebuffer(target, attachments)
    }

    @_expose(Cxx)
    public func invalidateSubFramebuffer(_ target: GLenum, _ attachments: WebCore.GLLentUnsignedInts, _ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.invalidateSubFramebuffer(target, attachments, x, y, width, height)
    }

    @_expose(Cxx)
    public func framebufferDiscard(_ target: GLenum, _ attachments: WebCore.GLLentUnsignedInts) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.discardFramebufferEXT(target, attachments)
    }

    @_expose(Cxx)
    public func drawBuffers(_ buffers: WebCore.GLLentUnsignedInts) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.drawBuffers(buffers)
    }

    @_expose(Cxx)
    public func drawBuffersEXT(_ buffers: WebCore.GLLentUnsignedInts) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.drawBuffersEXT(buffers)
    }

    // Clears and draws.

    @_expose(Cxx)
    public func clearBufferiv(_ buffer: GLenum, _ drawbuffer: GLint, _ values: WebCore.GLLentInts) {
        guard makeContextCurrent() else {
            return
        }
        guard validateClearBufferv(buffer, values.size()) else {
            return
        }
        ANGLE.clearBufferiv(buffer, drawbuffer, values)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func clearBufferuiv(_ buffer: GLenum, _ drawbuffer: GLint, _ values: WebCore.GLLentUnsignedInts) {
        guard makeContextCurrent() else {
            return
        }
        guard validateClearBufferv(buffer, values.size()) else {
            return
        }
        ANGLE.clearBufferuiv(buffer, drawbuffer, values)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func clearBufferfv(_ buffer: GLenum, _ drawbuffer: GLint, _ values: WebCore.GLLentFloats) {
        guard makeContextCurrent() else {
            return
        }
        guard validateClearBufferv(buffer, values.size()) else {
            return
        }
        ANGLE.clearBufferfv(buffer, drawbuffer, values)
        checkGPUStatus()
    }

    // ClearBuffer*v are missing ANGLE Robust* entry points. Make the call act similar way as other calls that validate
    // buffer sizes by validating it here.
    func validateClearBufferv(_ buffer: GLenum, _ valuesSize: Int) -> Bool {
        switch buffer {
        case GLenum(GL_COLOR):
            if valuesSize == 4 {
                return true
            }
        case GLenum(GL_DEPTH), GLenum(GL_STENCIL):
            if valuesSize == 1 {
                return true
            }
        default:
            break
        }
        addError(.invalidOperation)
        return false
    }

    @_expose(Cxx)
    public func drawElements(_ mode: GLenum, _ count: GLsizei, _ type: GLenum, _ offset: GLintptr) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.drawElements(mode, count, type, offset)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func drawArraysInstanced(_ mode: GLenum, _ first: GLint, _ count: GLsizei, _ primcount: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        if isForWebGL2 {
            GL_DrawArraysInstanced(mode, first, count, primcount)
        } else {
            GL_DrawArraysInstancedANGLE(mode, first, count, primcount)
        }
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func drawElementsInstanced(_ mode: GLenum, _ count: GLsizei, _ type: GLenum, _ offset: GLintptr, _ primcount: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        if isForWebGL2 {
            ANGLE.drawElementsInstanced(mode, count, type, offset, primcount)
        } else {
            ANGLE.drawElementsInstancedANGLE(mode, count, type, offset, primcount)
        }
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func drawRangeElements(_ mode: GLenum, _ start: GLuint, _ end: GLuint, _ count: GLsizei, _ type: GLenum, _ offset: GLintptr) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.drawRangeElements(mode, start, end, count, type, offset)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func drawElementsInstancedBaseVertexBaseInstanceANGLE(_ mode: GLenum, _ count: GLsizei, _ type: GLenum, _ offset: GLintptr, _ instanceCount: GLsizei, _ baseVertex: GLint, _ baseInstance: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.drawElementsInstancedBaseVertexBaseInstanceANGLE(mode, count, type, offset, instanceCount, baseVertex, baseInstance)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func multiDrawArraysANGLE(_ mode: GLenum, _ firsts: WebCore.GLLentInts, _ counts: WebCore.GLLentInts, _ drawCount: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.multiDrawArraysANGLE(mode, firsts, counts, drawCount)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func multiDrawArraysInstancedANGLE(_ mode: GLenum, _ firsts: WebCore.GLLentInts, _ counts: WebCore.GLLentInts, _ instanceCounts: WebCore.GLLentInts, _ drawCount: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.multiDrawArraysInstancedANGLE(mode, firsts, counts, instanceCounts, drawCount)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func multiDrawElementsANGLE(_ mode: GLenum, _ counts: WebCore.GLLentInts, _ offsets: WebCore.GLLentInts, _ type: GLenum, _ drawCount: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.multiDrawElementsANGLE(mode, counts, type, offsets, drawCount)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func multiDrawElementsInstancedANGLE(_ mode: GLenum, _ counts: WebCore.GLLentInts, _ offsets: WebCore.GLLentInts, _ instanceCounts: WebCore.GLLentInts, _ type: GLenum, _ drawCount: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.multiDrawElementsInstancedANGLE(mode, counts, type, offsets, instanceCounts, drawCount)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func multiDrawArraysInstancedBaseInstanceANGLE(_ mode: GLenum, _ firsts: WebCore.GLLentInts, _ counts: WebCore.GLLentInts, _ instanceCounts: WebCore.GLLentInts, _ baseInstances: WebCore.GLLentUnsignedInts, _ drawCount: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.multiDrawArraysInstancedBaseInstanceANGLE(mode, firsts, counts, instanceCounts, baseInstances, drawCount)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(_ mode: GLenum, _ counts: WebCore.GLLentInts, _ offsets: WebCore.GLLentInts, _ instanceCounts: WebCore.GLLentInts, _ baseVertices: WebCore.GLLentInts, _ baseInstances: WebCore.GLLentUnsignedInts, _ type: GLenum, _ drawCount: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(mode, counts, type, offsets, instanceCounts, baseVertices, baseInstances, drawCount)
        checkGPUStatus()
    }

    // Capabilities and pixel storage.

    @_expose(Cxx)
    public func enable(_ cap: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        if cap == GLenum(GL_PRIMITIVE_RESTART_FIXED_INDEX) {
            if !isForWebGL2 {
                addError(.invalidOperation)
            }
            return
        }
        GL_Enable(cap)
    }

    @_expose(Cxx)
    public func disable(_ cap: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        if cap == GLenum(GL_PRIMITIVE_RESTART_FIXED_INDEX) {
            if isForWebGL2 {
                addError(.invalidOperation)
            }
            return
        }
        GL_Disable(cap)
    }

    @_expose(Cxx)
    public func pixelStorei(_ pname: GLenum, _ param: GLint) {
        guard makeContextCurrent() else {
            return
        }
        switch pname {
        case GLenum(GL_UNPACK_ALIGNMENT), GLenum(GL_UNPACK_ROW_LENGTH), GLenum(GL_UNPACK_IMAGE_HEIGHT), GLenum(GL_UNPACK_SKIP_PIXELS), GLenum(GL_UNPACK_SKIP_ROWS), GLenum(GL_UNPACK_SKIP_IMAGES):
            break
        default:
            // Should be never set, rather passed to the commands that need these.
            addError(.invalidOperation)
            return
        }
        GL_PixelStorei(pname, param)
    }

    // Shaders and programs.

    @_expose(Cxx)
    public func compileShader(_ shader: GLuint) {
        assert(shader != 0)
        guard makeContextCurrent() else {
            return
        }
#if !os(Windows)
        // We need the ANGLE_texture_rectangle extension to support IOSurface backbuffers, but we don't want it exposed
        // to WebGL user shaders. Temporarily disable it during shader compilation.
        GL_Disable(GLenum(GL_TEXTURE_RECTANGLE_ANGLE))
#endif
        GL_CompileShader(shader)
#if !os(Windows)
        GL_Enable(GLenum(GL_TEXTURE_RECTANGLE_ANGLE))
#endif
    }

    @_expose(Cxx)
    public func createShader(_ type: GLenum) -> GLuint {
        guard makeContextCurrent() else {
            return 0
        }
        return GL_CreateShader(type == GLenum(GL_FRAGMENT_SHADER) ? GLenum(GL_FRAGMENT_SHADER) : GLenum(GL_VERTEX_SHADER))
    }

    // The source, with its NUL terminator.
    @_expose(Cxx)
    public func shaderSource(_ shader: GLuint, _ source: WebCore.GLLentBytes) {
        assert(shader != 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.shaderSource(shader, source)
    }

    @_expose(Cxx)
    public func bindAttribLocation(_ program: GLuint, _ index: GLuint, _ name: WebCore.GLLentBytes) {
        assert(program != 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.bindAttribLocation(program, index, name)
    }

    @_expose(Cxx)
    public func getFragDataLocation(_ program: GLuint, _ name: WebCore.GLLentBytes) -> GLint {
        guard makeContextCurrent() else {
            return -1
        }
        return ANGLE.getFragDataLocation(program, name)
    }

    @_expose(Cxx)
    public func getUniformBlockIndex(_ program: GLuint, _ uniformBlockName: WebCore.GLLentBytes) -> GLuint {
        assert(program != 0)
        guard makeContextCurrent() else {
            return GLuint(GL_INVALID_INDEX)
        }
        return ANGLE.getUniformBlockIndex(program, uniformBlockName)
    }

    @_expose(Cxx)
    public func transformFeedbackVaryings(_ program: GLuint, _ varyings: WebCore.GLLentCStrings, _ bufferMode: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.transformFeedbackVaryings(program, varyings, bufferMode)
    }

    @_expose(Cxx)
    public func getProgrami(_ program: GLuint, _ pname: GLenum) -> GLint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getProgrami(program, pname)
    }

    @_expose(Cxx)
    public func getShaderi(_ shader: GLuint, _ pname: GLenum) -> GLint {
        assert(shader != 0)
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getShaderi(shader, pname)
    }

    // The length a program's info log needs, including its NUL terminator, or -1 if the context isn't current.
    @_expose(Cxx)
    public func programInfoLogLength(_ program: GLuint) -> GLint {
        guard makeContextCurrent() else {
            return -1
        }
        return ANGLE.getProgrami(program, GLenum(GL_INFO_LOG_LENGTH))
    }

    @_expose(Cxx)
    public func getProgramInfoLog(_ program: GLuint, _ log: WebCore.GLLentMutableBytes) -> GLsizei {
        let length = ANGLE.getProgramInfoLog(program, log)
        assert(length == GLsizei(log.size()) - 1)
        return length
    }

    @_expose(Cxx)
    public func shaderInfoLogLength(_ shader: GLuint) -> GLint {
        guard makeContextCurrent() else {
            return -1
        }
        return ANGLE.getShaderi(shader, GLenum(GL_INFO_LOG_LENGTH))
    }

    @_expose(Cxx)
    public func getShaderInfoLog(_ shader: GLuint, _ log: WebCore.GLLentMutableBytes) -> GLsizei {
        let length = ANGLE.getShaderInfoLog(shader, log)
        assert(length == GLsizei(log.size()) - 1)
        return length
    }

    @_expose(Cxx)
    public func translatedShaderSourceLength(_ shader: GLuint) -> GLint {
        guard makeContextCurrent() else {
            return -1
        }
        return ANGLE.getShaderi(shader, GLenum(GL_TRANSLATED_SHADER_SOURCE_LENGTH_ANGLE))
    }

    @_expose(Cxx)
    public func getTranslatedShaderSourceANGLE(_ shader: GLuint, _ source: WebCore.GLLentMutableBytes) -> GLsizei {
        let length = ANGLE.getTranslatedShaderSource(shader, source)
        assert(length == GLsizei(source.size()) - 1)
        return length
    }

    @_expose(Cxx)
    public func activeUniformBlockNameLength(_ program: GLuint) -> GLint {
        assert(program != 0)
        guard makeContextCurrent() else {
            return -1
        }
        // A maximum length of 0 is ok: asking for the name of the block then sets the consistent error.
        return ANGLE.getProgrami(program, GLenum(GL_ACTIVE_UNIFORM_BLOCK_MAX_NAME_LENGTH))
    }

    @_expose(Cxx)
    public func getActiveUniformBlockName(_ program: GLuint, _ uniformBlockIndex: GLuint, _ name: WebCore.GLLentMutableBytes) -> GLsizei {
        ANGLE.getActiveUniformBlockName(program, uniformBlockIndex, name)
    }

    @_expose(Cxx)
    public func getActiveUniformBlockiv(_ program: GLuint, _ uniformBlockIndex: GLuint, _ pname: GLenum, _ params: WebCore.GLLentMutableInts) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.getActiveUniformBlockiv(program, uniformBlockIndex, pname, params)
    }

    // The transform feedback varying's type and size, and its name into the lent bytes, as the length of the name.
    // nameLength is 0 if there is no such varying.
    @_expose(Cxx)
    public func getTransformFeedbackVarying(_ program: GLuint, _ index: GLuint) -> ANGLEActiveVariableInfo {
        guard makeContextCurrent() else {
            return ANGLEActiveVariableInfo()
        }
        // A maximum length of 0 is ok: asking for the varying then sets the consistent error.
        let maxLength = ANGLE.getProgrami(program, GLenum(GL_TRANSFORM_FEEDBACK_VARYING_MAX_LENGTH))
        let varying = ANGLE.getTransformFeedbackVarying(program, index, maxLength)
        if varying.name.empty() {
            return ANGLEActiveVariableInfo()
        }
        lastVariableName = varying.name
        return ANGLEActiveVariableInfo(type: varying.type, size: varying.size, nameLength: GLint(varying.name.size()))
    }

    // The name of the variable that getTransformFeedbackVarying() last returned.
    private(set) var lastVariableName = std.string()

    @_expose(Cxx)
    public func copyLastVariableName(_ name: WebCore.GLLentMutableBytes) -> Int {
        ANGLE.copyString(lastVariableName, name)
    }

    // Active attributes and uniforms, one at a time: the count first, then each variable, whose name goes into the
    // lent bytes, which hold the maximum name length the count gave.

    // The number of active attributes and the length their names need, with the terminator; 0 and 0 if there are none
    // or the context isn't current.
    @_expose(Cxx)
    public func activeAttribCount(_ program: GLuint) -> ANGLEActiveVariableCount {
        activeVariableCount(program, GLenum(GL_ACTIVE_ATTRIBUTE_MAX_LENGTH), GLenum(GL_ACTIVE_ATTRIBUTES))
    }

    // An active attribute's type and location, and its name into the lent bytes. nameLength is 0 if it isn't one.
    @_expose(Cxx)
    public func activeAttrib(_ program: GLuint, _ index: GLuint, _ name: WebCore.GLLentMutableBytes) -> ANGLEActiveAttribInfo {
        guard makeContextCurrent() else {
            return ANGLEActiveAttribInfo()
        }
        let variable = ANGLE.getActiveAttrib(program, index, name)
        if variable.length < 1 || variable.size != 1 {
            assertionFailure()
            return ANGLEActiveAttribInfo()
        }
        return ANGLEActiveAttribInfo(type: variable.type, location: ANGLE.getAttribLocation(program, name), nameLength: variable.length)
    }

    @_expose(Cxx)
    public func activeUniformCount(_ program: GLuint) -> ANGLEActiveVariableCount {
        activeVariableCount(program, GLenum(GL_ACTIVE_UNIFORM_MAX_LENGTH), GLenum(GL_ACTIVE_UNIFORMS))
    }

    // An active uniform's type, size, block layout and how many locations it has, which activeUniformLocations() then
    // finds, and its name into the lent bytes. nameLength is 0 if it isn't one.
    @_expose(Cxx)
    public func activeUniform(_ program: GLuint, _ index: GLuint, _ name: WebCore.GLLentMutableBytes) -> ANGLEActiveUniformInfo {
        guard makeContextCurrent() else {
            return ANGLEActiveUniformInfo()
        }
        let variable = ANGLE.getActiveUniform(program, index, name)
        if variable.length < 1 || variable.size < 1 {
            assertionFailure()
            return ANGLEActiveUniformInfo()
        }
        return activeUniformInfo(program, index, variable.type, variable.size, variable.length)
    }

    // The locations of the uniform activeUniform() returned, whose name of nameLength the lent bytes hold, into the lent
    // ints, which hold its locationCount. False if they couldn't be found.
    @_expose(Cxx)
    public func activeUniformLocations(_ program: GLuint, _ name: WebCore.GLLentBytes, _ nameLength: GLint, _ locations: WebCore.GLLentMutableInts) -> Bool {
        guard makeContextCurrent() else {
            return false
        }
        let found = ANGLE.getUniformLocations(program, name, nameLength, locations)
        assert(found)
        return found
    }

    // An active uniform's block layout, and its location count: one per element if it isn't in a block.
    func activeUniformInfo(_ program: GLuint, _ index: GLuint, _ type: GLenum, _ size: GLint, _ nameLength: GLint) -> ANGLEActiveUniformInfo {
        var info = ANGLEActiveUniformInfo(type: type, size: size, blockIndex: -1, offset: -1, arrayStride: -1, matrixStride: -1, isRowMajor: -1, nameLength: nameLength, locationCount: 0)
        if isForWebGL2 {
            info.blockIndex = ANGLE.getActiveUniformi(program, index, GLenum(GL_UNIFORM_BLOCK_INDEX))
            info.offset = ANGLE.getActiveUniformi(program, index, GLenum(GL_UNIFORM_OFFSET))
            info.arrayStride = ANGLE.getActiveUniformi(program, index, GLenum(GL_UNIFORM_ARRAY_STRIDE))
            info.matrixStride = ANGLE.getActiveUniformi(program, index, GLenum(GL_UNIFORM_MATRIX_STRIDE))
            info.isRowMajor = ANGLE.getActiveUniformi(program, index, GLenum(GL_UNIFORM_IS_ROW_MAJOR))
        }
        if info.blockIndex == -1 {
            info.locationCount = size
        }
        return info
    }

    @_expose(Cxx)
    public func clearActiveVariables() {
        lastVariableName = std.string()
    }

    private func activeVariableCount(_ program: GLuint, _ maxLengthName: GLenum, _ countName: GLenum) -> ANGLEActiveVariableCount {
        guard makeContextCurrent() else {
            return ANGLEActiveVariableCount()
        }
        let maxLength = ANGLE.getProgrami(program, maxLengthName)
        if maxLength <= 0 {
            return ANGLEActiveVariableCount()
        }
        return ANGLEActiveVariableCount(count: max(ANGLE.getProgrami(program, countName), 0), maxLength: maxLength)
    }

    // Strings.

    // The length of a GL string, or -1 if it is null or the context isn't current.
    @_expose(Cxx)
    public func stringLength(_ name: GLenum) -> Int {
        guard makeContextCurrent() else {
            return -1
        }
        return ANGLE.stringLength(name)
    }

    // Copies as much of a GL string as fits into destination. Returns its whole length, or -1 if it is null or the
    // context isn't current.
    @_expose(Cxx)
    public func copyString(_ name: GLenum, _ destination: WebCore.GLLentMutableBytes) -> Int {
        guard makeContextCurrent() else {
            return -1
        }
        return ANGLE.copyString(name, destination)
    }

    // Uniforms.

    @_expose(Cxx)
    public func uniform1fv(_ location: GLint, _ values: WebCore.GLLentFloats) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniform1fv(location, GLsizei(truncatingIfNeeded: values.size()), values)
    }

    @_expose(Cxx)
    public func uniform2fv(_ location: GLint, _ values: WebCore.GLLentFloats) {
        assert(values.size() % 2 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniform2fv(location, GLsizei(truncatingIfNeeded: values.size() / 2), values)
    }

    @_expose(Cxx)
    public func uniform3fv(_ location: GLint, _ values: WebCore.GLLentFloats) {
        assert(values.size() % 3 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniform3fv(location, GLsizei(truncatingIfNeeded: values.size() / 3), values)
    }

    @_expose(Cxx)
    public func uniform4fv(_ location: GLint, _ values: WebCore.GLLentFloats) {
        assert(values.size() % 4 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniform4fv(location, GLsizei(truncatingIfNeeded: values.size() / 4), values)
    }

    @_expose(Cxx)
    public func uniform1iv(_ location: GLint, _ values: WebCore.GLLentInts) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniform1iv(location, GLsizei(truncatingIfNeeded: values.size()), values)
    }

    @_expose(Cxx)
    public func uniform2iv(_ location: GLint, _ values: WebCore.GLLentInts) {
        assert(values.size() % 2 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniform2iv(location, GLsizei(truncatingIfNeeded: values.size() / 2), values)
    }

    @_expose(Cxx)
    public func uniform3iv(_ location: GLint, _ values: WebCore.GLLentInts) {
        assert(values.size() % 3 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniform3iv(location, GLsizei(truncatingIfNeeded: values.size() / 3), values)
    }

    @_expose(Cxx)
    public func uniform4iv(_ location: GLint, _ values: WebCore.GLLentInts) {
        assert(values.size() % 4 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniform4iv(location, GLsizei(truncatingIfNeeded: values.size() / 4), values)
    }

    @_expose(Cxx)
    public func uniform1uiv(_ location: GLint, _ values: WebCore.GLLentUnsignedInts) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniform1uiv(location, GLsizei(truncatingIfNeeded: values.size()), values)
    }

    @_expose(Cxx)
    public func uniform2uiv(_ location: GLint, _ values: WebCore.GLLentUnsignedInts) {
        assert(values.size() % 2 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniform2uiv(location, GLsizei(truncatingIfNeeded: values.size() / 2), values)
    }

    @_expose(Cxx)
    public func uniform3uiv(_ location: GLint, _ values: WebCore.GLLentUnsignedInts) {
        assert(values.size() % 3 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniform3uiv(location, GLsizei(truncatingIfNeeded: values.size() / 3), values)
    }

    @_expose(Cxx)
    public func uniform4uiv(_ location: GLint, _ values: WebCore.GLLentUnsignedInts) {
        assert(values.size() % 4 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniform4uiv(location, GLsizei(truncatingIfNeeded: values.size() / 4), values)
    }

    @_expose(Cxx)
    public func uniformMatrix2fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniformMatrix2fv(location, GLsizei(truncatingIfNeeded: values.size() / 4), transpose, values)
    }

    @_expose(Cxx)
    public func uniformMatrix3fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        assert(values.size() % 9 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniformMatrix3fv(location, GLsizei(truncatingIfNeeded: values.size() / 9), transpose, values)
    }

    @_expose(Cxx)
    public func uniformMatrix4fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        assert(values.size() % 16 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniformMatrix4fv(location, GLsizei(truncatingIfNeeded: values.size() / 16), transpose, values)
    }

    @_expose(Cxx)
    public func uniformMatrix2x3fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        assert(values.size() % 6 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniformMatrix2x3fv(location, GLsizei(truncatingIfNeeded: values.size() / 6), transpose, values)
    }

    @_expose(Cxx)
    public func uniformMatrix3x2fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        assert(values.size() % 6 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniformMatrix3x2fv(location, GLsizei(truncatingIfNeeded: values.size() / 6), transpose, values)
    }

    @_expose(Cxx)
    public func uniformMatrix2x4fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        assert(values.size() % 8 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniformMatrix2x4fv(location, GLsizei(truncatingIfNeeded: values.size() / 8), transpose, values)
    }

    @_expose(Cxx)
    public func uniformMatrix4x2fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        assert(values.size() % 8 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniformMatrix4x2fv(location, GLsizei(truncatingIfNeeded: values.size() / 8), transpose, values)
    }

    @_expose(Cxx)
    public func uniformMatrix3x4fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        assert(values.size() % 12 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniformMatrix3x4fv(location, GLsizei(truncatingIfNeeded: values.size() / 12), transpose, values)
    }

    @_expose(Cxx)
    public func uniformMatrix4x3fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        assert(values.size() % 12 == 0)
        guard makeContextCurrent() else {
            return
        }
        ANGLE.uniformMatrix4x3fv(location, GLsizei(truncatingIfNeeded: values.size() / 12), transpose, values)
    }

    @_expose(Cxx)
    public func getUniformfv(_ program: GLuint, _ location: GLint, _ value: WebCore.GLLentMutableFloats) {
        guard makeContextCurrent() else {
            return
        }
        // FIXME: Bug in ANGLE bufSize validation for uniforms. See https://bugs.webkit.org/show_bug.cgi?id=219069.
        ANGLE.getUniformfv(program, location, value)
    }

    @_expose(Cxx)
    public func getUniformiv(_ program: GLuint, _ location: GLint, _ value: WebCore.GLLentMutableInts) {
        guard makeContextCurrent() else {
            return
        }
        // FIXME: Bug in ANGLE bufSize validation for uniforms. See https://bugs.webkit.org/show_bug.cgi?id=219069.
        ANGLE.getUniformiv(program, location, value)
    }

    @_expose(Cxx)
    public func getUniformuiv(_ program: GLuint, _ location: GLint, _ value: WebCore.GLLentMutableUnsignedInts) {
        guard makeContextCurrent() else {
            return
        }
        // FIXME: Bug in ANGLE bufSize validation for uniforms. See https://bugs.webkit.org/show_bug.cgi?id=219069.
        ANGLE.getUniformuiv(program, location, value)
    }

    // Vertex attributes.

    @_expose(Cxx)
    public func vertexAttrib1fv(_ index: GLuint, _ x: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.vertexAttrib1fv(index, ANGLEFloat4(values: (x, 0, 0, 0)))
    }

    @_expose(Cxx)
    public func vertexAttrib2fv(_ index: GLuint, _ x: GLfloat, _ y: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.vertexAttrib2fv(index, ANGLEFloat4(values: (x, y, 0, 0)))
    }

    @_expose(Cxx)
    public func vertexAttrib3fv(_ index: GLuint, _ x: GLfloat, _ y: GLfloat, _ z: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.vertexAttrib3fv(index, ANGLEFloat4(values: (x, y, z, 0)))
    }

    @_expose(Cxx)
    public func vertexAttrib4fv(_ index: GLuint, _ x: GLfloat, _ y: GLfloat, _ z: GLfloat, _ w: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.vertexAttrib4fv(index, ANGLEFloat4(values: (x, y, z, w)))
    }

    @_expose(Cxx)
    public func vertexAttribI4iv(_ index: GLuint, _ x: GLint, _ y: GLint, _ z: GLint, _ w: GLint) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.vertexAttribI4iv(index, ANGLEInt4(values: (x, y, z, w)))
    }

    @_expose(Cxx)
    public func vertexAttribI4uiv(_ index: GLuint, _ x: GLuint, _ y: GLuint, _ z: GLuint, _ w: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.vertexAttribI4uiv(index, ANGLEUnsignedInt4(values: (x, y, z, w)))
    }

    @_expose(Cxx)
    public func vertexAttribPointer(_ index: GLuint, _ size: GLint, _ type: GLenum, _ normalized: GLboolean, _ stride: GLsizei, _ offset: GLintptr) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.vertexAttribPointer(index, size, type, normalized, stride, offset)
    }

    @_expose(Cxx)
    public func vertexAttribIPointer(_ index: GLuint, _ size: GLint, _ type: GLenum, _ stride: GLsizei, _ offset: GLintptr) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.vertexAttribIPointer(index, size, type, stride, offset)
    }

    @_expose(Cxx)
    public func vertexAttribDivisor(_ index: GLuint, _ divisor: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        if isForWebGL2 {
            GL_VertexAttribDivisor(index, divisor)
        } else {
            GL_VertexAttribDivisorANGLE(index, divisor)
        }
    }

    @_expose(Cxx)
    public func getVertexAttribOffset(_ index: GLuint, _ pname: GLenum) -> GLsizeiptr {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getVertexAttribOffset(index, pname)
    }

    // Vertex arrays.

    @_expose(Cxx)
    public func createVertexArray() -> GLuint {
        guard makeContextCurrent() else {
            return 0
        }
        return isForWebGL2 ? ANGLE.genVertexArray() : ANGLE.genVertexArrayOES()
    }

    @_expose(Cxx)
    public func deleteVertexArray(_ array: GLuint) {
        if array == 0 {
            return
        }
        guard makeContextCurrent() else {
            return
        }
        if isForWebGL2 {
            ANGLE.deleteVertexArray(array)
        } else {
            ANGLE.deleteVertexArrayOES(array)
        }
    }

    @_expose(Cxx)
    public func isVertexArray(_ array: GLuint) -> GLboolean {
        if array == 0 {
            return GLboolean(GL_FALSE)
        }
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return isForWebGL2 ? GL_IsVertexArray(array) : GL_IsVertexArrayOES(array)
    }

    @_expose(Cxx)
    public func bindVertexArray(_ array: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        if isForWebGL2 {
            GL_BindVertexArray(array)
        } else {
            GL_BindVertexArrayOES(array)
        }
    }

    // State queries.

    @_expose(Cxx)
    public func getBooleanv(_ pname: GLenum, _ value: WebCore.GLLentMutableBytes) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.getBooleanv(pname, value)
    }

    @_expose(Cxx)
    public func getFloatv(_ pname: GLenum, _ value: WebCore.GLLentMutableFloats) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.getFloatv(pname, value)
    }

    @_expose(Cxx)
    public func getIntegerv(_ pname: GLenum, _ value: WebCore.GLLentMutableInts) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.getIntegerv(pname, value)
    }

    @_expose(Cxx)
    public func getIntegeri_v(_ pname: GLenum, _ index: GLuint, _ value: WebCore.GLLentMutableInts) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.getIntegeri_v(pname, index, value)
    }

    @_expose(Cxx)
    public func getInteger64(_ pname: GLenum) -> GLint64 {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getInteger64(pname)
    }

    @_expose(Cxx)
    public func getInteger64i(_ pname: GLenum, _ index: GLuint) -> GLint64 {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getInteger64i(pname, index)
    }

    @_expose(Cxx)
    public func getInteger64EXT(_ pname: GLenum) -> GLint64 {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getInteger64(pname)
    }

    @_expose(Cxx)
    public func getInternalformativ(_ target: GLenum, _ internalformat: GLenum, _ pname: GLenum, _ data: WebCore.GLLentMutableInts) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.getInternalformativ(target, internalformat, pname, data)
    }

    @_expose(Cxx)
    public func getBufferParameteri(_ target: GLenum, _ pname: GLenum) -> GLint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getBufferParameteri(target, pname)
    }

    @_expose(Cxx)
    public func getFramebufferAttachmentParameteri(_ target: GLenum, _ attachment: GLenum, _ pname: GLenum) -> GLint {
        guard makeContextCurrent() else {
            return 0
        }
        // Or STENCIL_ATTACHMENT, either works.
        let attachment = attachment == GLenum(GL_DEPTH_STENCIL_ATTACHMENT) ? GLenum(GL_DEPTH_ATTACHMENT) : attachment
        return ANGLE.getFramebufferAttachmentParameteri(target, attachment, pname)
    }

    @_expose(Cxx)
    public func getRenderbufferParameteri(_ target: GLenum, _ pname: GLenum) -> GLint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getRenderbufferParameteri(target, pname)
    }

    @_expose(Cxx)
    public func getTexParameterf(_ target: GLenum, _ pname: GLenum) -> GLfloat {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getTexParameterf(target, pname)
    }

    @_expose(Cxx)
    public func getTexParameteri(_ target: GLenum, _ pname: GLenum) -> GLint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getTexParameteri(target, pname)
    }

    @_expose(Cxx)
    public func getShaderPrecisionFormat(_ shaderType: GLenum, _ precisionType: GLenum) -> ANGLEShaderPrecisionFormat {
        guard makeContextCurrent() else {
            return ANGLEShaderPrecisionFormat()
        }
        return ANGLE.getShaderPrecisionFormat(shaderType, precisionType)
    }

    // Queries.

    @_expose(Cxx)
    public func createQuery() -> GLuint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.genQuery()
    }

    @_expose(Cxx)
    public func deleteQuery(_ query: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.deleteQuery(query)
    }

    @_expose(Cxx)
    public func getQuery(_ target: GLenum, _ pname: GLenum) -> GLint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getQueryi(target, pname)
    }

    @_expose(Cxx)
    public func getQueryObjectui(_ query: GLuint, _ pname: GLenum) -> GLuint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getQueryObjectui(query, pname)
    }

    @_expose(Cxx)
    public func createQueryEXT() -> GLuint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.genQueryEXT()
    }

    @_expose(Cxx)
    public func deleteQueryEXT(_ query: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.deleteQueryEXT(query)
    }

    @_expose(Cxx)
    public func getQueryiEXT(_ target: GLenum, _ pname: GLenum) -> GLint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getQueryi(target, pname)
    }

    @_expose(Cxx)
    public func getQueryObjectiEXT(_ query: GLuint, _ pname: GLenum) -> GLint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getQueryObjecti(query, pname)
    }

    @_expose(Cxx)
    public func getQueryObjectui64EXT(_ query: GLuint, _ pname: GLenum) -> GLuint64 {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getQueryObjectui64(query, pname)
    }

    // Samplers.

    @_expose(Cxx)
    public func createSampler() -> GLuint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.genSampler()
    }

    @_expose(Cxx)
    public func deleteSampler(_ sampler: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.deleteSampler(sampler)
    }

    @_expose(Cxx)
    public func getSamplerParameterf(_ sampler: GLuint, _ pname: GLenum) -> GLfloat {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getSamplerParameterf(sampler, pname)
    }

    @_expose(Cxx)
    public func getSamplerParameteri(_ sampler: GLuint, _ pname: GLenum) -> GLint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getSamplerParameteri(sampler, pname)
    }

    // Syncs.

    @_expose(Cxx)
    public func fenceSync(_ condition: GLenum, _ flags: GLbitfield) -> UInt64 {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.fenceSync(condition, flags)
    }

    @_expose(Cxx)
    public func isSync(_ sync: UInt64) -> GLboolean {
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return ANGLE.isSync(sync)
    }

    @_expose(Cxx)
    public func deleteSync(_ sync: UInt64) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.deleteSync(sync)
    }

    @_expose(Cxx)
    public func clientWaitSync(_ sync: UInt64, _ flags: GLbitfield, _ timeout: GLuint64) -> GLenum {
        guard makeContextCurrent() else {
            return GLenum(GL_WAIT_FAILED)
        }
        return ANGLE.clientWaitSync(sync, flags, timeout)
    }

    @_expose(Cxx)
    public func waitSync(_ sync: UInt64, _ flags: GLbitfield, _ timeout: GLint64) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.waitSync(sync, flags, GLuint64(bitPattern: timeout))
    }

    @_expose(Cxx)
    public func getSynci(_ sync: UInt64, _ pname: GLenum) -> GLint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.getSynci(sync, pname)
    }

    // Transform feedback.

    @_expose(Cxx)
    public func createTransformFeedback() -> GLuint {
        guard makeContextCurrent() else {
            return 0
        }
        return ANGLE.genTransformFeedback()
    }

    @_expose(Cxx)
    public func deleteTransformFeedback(_ transformFeedback: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        ANGLE.deleteTransformFeedback(transformFeedback)
    }

    // External images and syncs.

    private var externalImages: [UInt32: ANGLEImage] = [:]
    private var externalSyncs: [UInt32: ANGLEEGLSync] = [:]
    private var nextExternalImageName: UInt32 = 0
    private var nextExternalSyncName: UInt32 = 0

    @_expose(Cxx)
    public func addExternalImage(_ image: ANGLEImage) -> UInt32 {
        nextExternalImageName &+= 1
        externalImages[nextExternalImageName] = image
        return nextExternalImageName
    }

    @_expose(Cxx)
    public func addExternalSync(_ sync: ANGLEEGLSync) -> UInt32 {
        nextExternalSyncName &+= 1
        externalSyncs[nextExternalSyncName] = sync
        return nextExternalSyncName
    }

    @_expose(Cxx)
    public func deleteExternalImage(_ image: UInt32) {
        if image == 0 {
            return
        }
        guard let eglImage = externalImages.removeValue(forKey: image) else {
            addError(.invalidOperation)
            return
        }
        let result = ANGLE.destroyImage(display, eglImage)
        assert(result)
        if !result {
            addError(.invalidOperation)
        }
    }

    @_expose(Cxx)
    public func deleteExternalSync(_ sync: UInt32) {
        if sync == 0 {
            return
        }
        guard let eglSync = externalSyncs.removeValue(forKey: sync) else {
            addError(.invalidOperation)
            return
        }
        let result = ANGLE.destroySync(display, eglSync)
        assert(result)
        if !result {
            addError(.invalidOperation)
        }
    }

    @_expose(Cxx)
    public func bindExternalImage(_ target: GLenum, _ image: UInt32) {
        guard makeContextCurrent() else {
            return
        }
        var eglImage = ANGLEImage()
        if image != 0 {
            guard let found = externalImages[image] else {
                addError(.invalidOperation)
                return
            }
            eglImage = found
        }
        if target == GLenum(GL_RENDERBUFFER) {
            ANGLE.imageTargetRenderbufferStorage(GLenum(GL_RENDERBUFFER), eglImage)
        } else {
            ANGLE.imageTargetTexture2D(target, eglImage)
        }
    }

    // Destroys the external images and syncs left, before the platform destroys the EGL context.
    @_expose(Cxx)
    public func destroyExternalImagesAndSyncs() {
        for image in externalImages.values {
            let result = ANGLE.destroyImage(display, image)
            assert(result)
        }
        for sync in externalSyncs.values {
            let result = ANGLE.destroySync(display, sync)
            assert(result)
        }
        externalImages = [:]
        externalSyncs = [:]
    }

    // Testing.

    @_expose(Cxx)
    public func simulateEventForTesting(_ event: UInt8) {
        switch event {
        case GLContextSimulatedEvent.gpuStatusFailure:
#if WTF_PLATFORM_COCOA
            // Lose the ANGLE context now, so that the context notices the failure like a real GPU reset.
            if makeContextCurrent() && enableExtensions(["GL_CHROMIUM_lose_context"]) {
                GL_LoseContextCHROMIUM(GLenum(GL_GUILTY_CONTEXT_RESET), GLenum(GL_INNOCENT_CONTEXT_RESET))
            }
#else
            state.failNextStatusCheck = true
#endif
        case GLContextSimulatedEvent.displayBufferAllocationFailure:
            state.failNextDrawingBufferAllocation = true
        case GLContextSimulatedEvent.renderbufferAllocationFailure:
            state.failNextRenderbufferAllocation = true
        default:
            break
        }
    }

    // Helpers.

    // Only for non-WebGL 2.0 contexts.
    private func adjustWebGL1TextureInternalFormat(_ internalformat: GLenum, _ format: GLenum, _ type: GLenum) -> GLenum {
        // The implementation of WEBGL_color_buffer_float for WebGL 1.0 / ES 2.0 requires a sized internal format.
        // Adjust it if necessary at this lowest level.
        if type == GLenum(GL_FLOAT) {
            if extensions.isKnownActive(.chromiumColorBufferFloatRGBA) && format == GLenum(GL_RGBA) && internalformat == GLenum(GL_RGBA) {
                return GLenum(GL_RGBA32F)
            }
            if extensions.isKnownActive(.chromiumColorBufferFloatRGB) && format == GLenum(GL_RGB) && internalformat == GLenum(GL_RGB) {
                return GLenum(GL_RGB32F)
            }
        }
        return internalformat
    }

    func withPixelPackBufferUnbound<Result>(_ body: () -> Result) -> Result {
        withBufferBinding(GLenum(GL_PIXEL_PACK_BUFFER), 0, condition: isForWebGL2, body)
    }

    func withScratchReadFramebuffer<Result>(attaching texture: GLuint, _ body: () -> Result) -> Result {
        withScratchReadFramebufferBinding(isForWebGL2: isForWebGL2, restoring: boundReadFBO, attaching: texture, body)
    }

    // Pass-throughs.

    @_expose(Cxx)
    public func depthRange(_ zNear: GLfloat, _ zFar: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_DepthRangef(zNear, zFar)
    }

    @_expose(Cxx)
    public func clearDepth(_ depth: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_ClearDepthf(depth)
    }

    @_expose(Cxx)
    public func attachShader(_ program: GLuint, _ shader: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_AttachShader(program, shader)
    }

    @_expose(Cxx)
    public func bindBuffer(_ target: GLenum, _ buffer: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_BindBuffer(target, buffer)
    }

    @_expose(Cxx)
    public func bindRenderbuffer(_ target: GLenum, _ renderbuffer: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_BindRenderbuffer(target, renderbuffer)
    }

    @_expose(Cxx)
    public func blendColor(_ red: GLfloat, _ green: GLfloat, _ blue: GLfloat, _ alpha: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_BlendColor(red, green, blue, alpha)
    }

    @_expose(Cxx)
    public func blendEquation(_ mode: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_BlendEquation(mode)
    }

    @_expose(Cxx)
    public func blendEquationSeparate(_ modeRGB: GLenum, _ modeAlpha: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_BlendEquationSeparate(modeRGB, modeAlpha)
    }

    @_expose(Cxx)
    public func blendFunc(_ sfactor: GLenum, _ dfactor: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_BlendFunc(sfactor, dfactor)
    }

    @_expose(Cxx)
    public func blendFuncSeparate(_ srcRGB: GLenum, _ dstRGB: GLenum, _ srcAlpha: GLenum, _ dstAlpha: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_BlendFuncSeparate(srcRGB, dstRGB, srcAlpha, dstAlpha)
    }

    @_expose(Cxx)
    public func copyBufferSubData(_ readTarget: GLenum, _ writeTarget: GLenum, _ readOffset: GLintptr, _ writeOffset: GLintptr, _ size: GLsizeiptr) {
        guard makeContextCurrent() else {
            return
        }
        GL_CopyBufferSubData(readTarget, writeTarget, readOffset, writeOffset, size)
    }

    @_expose(Cxx)
    public func checkFramebufferStatus(_ target: GLenum) -> GLenum {
        guard makeContextCurrent() else {
            return GLenum(GL_INVALID_OPERATION)
        }
        return GL_CheckFramebufferStatus(target)
    }

    @_expose(Cxx)
    public func clearColor(_ r: GLfloat, _ g: GLfloat, _ b: GLfloat, _ a: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_ClearColor(r, g, b, a)
    }

    @_expose(Cxx)
    public func clear(_ mask: GLbitfield) {
        guard makeContextCurrent() else {
            return
        }
        GL_Clear(mask)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func clearStencil(_ s: GLint) {
        guard makeContextCurrent() else {
            return
        }
        GL_ClearStencil(s)
    }

    @_expose(Cxx)
    public func colorMask(_ red: GLboolean, _ green: GLboolean, _ blue: GLboolean, _ alpha: GLboolean) {
        guard makeContextCurrent() else {
            return
        }
        GL_ColorMask(red, green, blue, alpha)
    }

    @_expose(Cxx)
    public func copyTexImage2D(_ target: GLenum, _ level: GLint, _ internalformat: GLenum, _ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei, _ border: GLint) {
        guard makeContextCurrent() else {
            return
        }
        GL_CopyTexImage2D(target, level, internalformat, x, y, width, height, border)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func copyTexSubImage2D(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        GL_CopyTexSubImage2D(target, level, xoffset, yoffset, x, y, width, height)
    }

    @_expose(Cxx)
    public func cullFace(_ mode: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_CullFace(mode)
    }

    @_expose(Cxx)
    public func depthFunc(_ function: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_DepthFunc(function)
    }

    @_expose(Cxx)
    public func depthMask(_ flag: GLboolean) {
        guard makeContextCurrent() else {
            return
        }
        GL_DepthMask(flag)
    }

    @_expose(Cxx)
    public func detachShader(_ program: GLuint, _ shader: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_DetachShader(program, shader)
    }

    @_expose(Cxx)
    public func disableVertexAttribArray(_ index: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_DisableVertexAttribArray(index)
    }

    @_expose(Cxx)
    public func drawArrays(_ mode: GLenum, _ first: GLint, _ count: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        GL_DrawArrays(mode, first, count)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func enableVertexAttribArray(_ index: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_EnableVertexAttribArray(index)
    }

    @_expose(Cxx)
    public func finish() {
        guard makeContextCurrent() else {
            return
        }
        GL_Finish()
    }

    @_expose(Cxx)
    public func flush() {
        guard makeContextCurrent() else {
            return
        }
        GL_Flush()
    }

    @_expose(Cxx)
    public func framebufferRenderbuffer(_ target: GLenum, _ attachment: GLenum, _ renderbuffertarget: GLenum, _ buffer: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_FramebufferRenderbuffer(target, attachment, renderbuffertarget, buffer)
    }

    @_expose(Cxx)
    public func frontFace(_ mode: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_FrontFace(mode)
    }

    @_expose(Cxx)
    public func generateMipmap(_ target: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_GenerateMipmap(target)
        didChangeMemoryCost()
    }

    @_expose(Cxx)
    public func hint(_ target: GLenum, _ mode: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_Hint(target, mode)
    }

    @_expose(Cxx)
    public func isBuffer(_ buffer: GLuint) -> GLboolean {
        if buffer == 0 {
            return GLboolean(GL_FALSE)
        }
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return GL_IsBuffer(buffer)
    }

    @_expose(Cxx)
    public func isEnabled(_ cap: GLenum) -> GLboolean {
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return GL_IsEnabled(cap)
    }

    @_expose(Cxx)
    public func isFramebuffer(_ framebuffer: GLuint) -> GLboolean {
        if framebuffer == 0 {
            return GLboolean(GL_FALSE)
        }
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return GL_IsFramebuffer(framebuffer)
    }

    @_expose(Cxx)
    public func isProgram(_ program: GLuint) -> GLboolean {
        if program == 0 {
            return GLboolean(GL_FALSE)
        }
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return GL_IsProgram(program)
    }

    @_expose(Cxx)
    public func isRenderbuffer(_ renderbuffer: GLuint) -> GLboolean {
        if renderbuffer == 0 {
            return GLboolean(GL_FALSE)
        }
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return GL_IsRenderbuffer(renderbuffer)
    }

    @_expose(Cxx)
    public func isShader(_ shader: GLuint) -> GLboolean {
        if shader == 0 {
            return GLboolean(GL_FALSE)
        }
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return GL_IsShader(shader)
    }

    @_expose(Cxx)
    public func isTexture(_ texture: GLuint) -> GLboolean {
        if texture == 0 {
            return GLboolean(GL_FALSE)
        }
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return GL_IsTexture(texture)
    }

    @_expose(Cxx)
    public func lineWidth(_ width: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_LineWidth(width)
    }

    @_expose(Cxx)
    public func linkProgram(_ program: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_LinkProgram(program)
    }

    @_expose(Cxx)
    public func polygonOffset(_ factor: GLfloat, _ units: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_PolygonOffset(factor, units)
    }

    @_expose(Cxx)
    public func sampleCoverage(_ value: GLfloat, _ invert: GLboolean) {
        guard makeContextCurrent() else {
            return
        }
        GL_SampleCoverage(value, invert)
    }

    @_expose(Cxx)
    public func scissor(_ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        GL_Scissor(x, y, width, height)
    }

    @_expose(Cxx)
    public func stencilFunc(_ function: GLenum, _ ref: GLint, _ mask: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_StencilFunc(function, ref, mask)
    }

    @_expose(Cxx)
    public func stencilFuncSeparate(_ face: GLenum, _ function: GLenum, _ ref: GLint, _ mask: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_StencilFuncSeparate(face, function, ref, mask)
    }

    @_expose(Cxx)
    public func stencilMask(_ mask: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_StencilMask(mask)
    }

    @_expose(Cxx)
    public func stencilMaskSeparate(_ face: GLenum, _ mask: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_StencilMaskSeparate(face, mask)
    }

    @_expose(Cxx)
    public func stencilOp(_ fail: GLenum, _ zfail: GLenum, _ zpass: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_StencilOp(fail, zfail, zpass)
    }

    @_expose(Cxx)
    public func stencilOpSeparate(_ face: GLenum, _ fail: GLenum, _ zfail: GLenum, _ zpass: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_StencilOpSeparate(face, fail, zfail, zpass)
    }

    @_expose(Cxx)
    public func texParameterf(_ target: GLenum, _ pname: GLenum, _ value: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_TexParameterf(target, pname, value)
    }

    @_expose(Cxx)
    public func texParameteri(_ target: GLenum, _ pname: GLenum, _ value: GLint) {
        guard makeContextCurrent() else {
            return
        }
        GL_TexParameteri(target, pname, value)
    }

    @_expose(Cxx)
    public func uniform1f(_ location: GLint, _ v0: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_Uniform1f(location, v0)
    }

    @_expose(Cxx)
    public func uniform2f(_ location: GLint, _ v0: GLfloat, _ v1: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_Uniform2f(location, v0, v1)
    }

    @_expose(Cxx)
    public func uniform3f(_ location: GLint, _ v0: GLfloat, _ v1: GLfloat, _ v2: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_Uniform3f(location, v0, v1, v2)
    }

    @_expose(Cxx)
    public func uniform4f(_ location: GLint, _ v0: GLfloat, _ v1: GLfloat, _ v2: GLfloat, _ v3: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_Uniform4f(location, v0, v1, v2, v3)
    }

    @_expose(Cxx)
    public func uniform1i(_ location: GLint, _ v0: GLint) {
        guard makeContextCurrent() else {
            return
        }
        GL_Uniform1i(location, v0)
    }

    @_expose(Cxx)
    public func uniform2i(_ location: GLint, _ v0: GLint, _ v1: GLint) {
        guard makeContextCurrent() else {
            return
        }
        GL_Uniform2i(location, v0, v1)
    }

    @_expose(Cxx)
    public func uniform3i(_ location: GLint, _ v0: GLint, _ v1: GLint, _ v2: GLint) {
        guard makeContextCurrent() else {
            return
        }
        GL_Uniform3i(location, v0, v1, v2)
    }

    @_expose(Cxx)
    public func uniform4i(_ location: GLint, _ v0: GLint, _ v1: GLint, _ v2: GLint, _ v3: GLint) {
        guard makeContextCurrent() else {
            return
        }
        GL_Uniform4i(location, v0, v1, v2, v3)
    }

    @_expose(Cxx)
    public func useProgram(_ program: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_UseProgram(program)
    }

    @_expose(Cxx)
    public func validateProgram(_ program: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_ValidateProgram(program)
    }

    @_expose(Cxx)
    public func vertexAttrib1f(_ index: GLuint, _ v0: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_VertexAttrib1f(index, v0)
    }

    @_expose(Cxx)
    public func vertexAttrib2f(_ index: GLuint, _ v0: GLfloat, _ v1: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_VertexAttrib2f(index, v0, v1)
    }

    @_expose(Cxx)
    public func vertexAttrib3f(_ index: GLuint, _ v0: GLfloat, _ v1: GLfloat, _ v2: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_VertexAttrib3f(index, v0, v1, v2)
    }

    @_expose(Cxx)
    public func vertexAttrib4f(_ index: GLuint, _ v0: GLfloat, _ v1: GLfloat, _ v2: GLfloat, _ v3: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_VertexAttrib4f(index, v0, v1, v2, v3)
    }

    @_expose(Cxx)
    public func viewport(_ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        GL_Viewport(x, y, width, height)
    }

    @_expose(Cxx)
    public func createProgram() -> GLuint {
        guard makeContextCurrent() else {
            return 0
        }
        return GL_CreateProgram()
    }

    @_expose(Cxx)
    public func deleteProgram(_ program: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_DeleteProgram(program)
    }

    @_expose(Cxx)
    public func deleteShader(_ shader: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_DeleteShader(shader)
    }

    @_expose(Cxx)
    public func uniformBlockBinding(_ program: GLuint, _ uniformBlockIndex: GLuint, _ uniformBlockBinding: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_UniformBlockBinding(program, uniformBlockIndex, uniformBlockBinding)
    }

    @_expose(Cxx)
    public func beginQuery(_ target: GLenum, _ query: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_BeginQuery(target, query)
    }

    @_expose(Cxx)
    public func endQuery(_ target: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_EndQuery(target)
    }

    @_expose(Cxx)
    public func isTransformFeedback(_ transformFeedback: GLuint) -> GLboolean {
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return GL_IsTransformFeedback(transformFeedback)
    }

    @_expose(Cxx)
    public func bindTransformFeedback(_ target: GLenum, _ transformFeedback: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_BindTransformFeedback(target, transformFeedback)
    }

    @_expose(Cxx)
    public func beginTransformFeedback(_ primitiveMode: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_BeginTransformFeedback(primitiveMode)
    }

    @_expose(Cxx)
    public func endTransformFeedback() {
        guard makeContextCurrent() else {
            return
        }
        GL_EndTransformFeedback()
    }

    @_expose(Cxx)
    public func bindBufferBase(_ target: GLenum, _ index: GLuint, _ buffer: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_BindBufferBase(target, index, buffer)
    }

    @_expose(Cxx)
    public func framebufferTextureLayer(_ target: GLenum, _ attachment: GLenum, _ texture: GLuint, _ level: GLint, _ layer: GLint) {
        guard makeContextCurrent() else {
            return
        }
        GL_FramebufferTextureLayer(target, attachment, texture, level, layer)
    }

    @_expose(Cxx)
    public func readBuffer(_ src: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_ReadBuffer(src)
    }

    @_expose(Cxx)
    public func copyTexSubImage3D(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ zoffset: GLint, _ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        GL_CopyTexSubImage3D(target, level, xoffset, yoffset, zoffset, x, y, width, height)
    }

    @_expose(Cxx)
    public func uniform1ui(_ location: GLint, _ v0: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_Uniform1ui(location, v0)
    }

    @_expose(Cxx)
    public func uniform2ui(_ location: GLint, _ v0: GLuint, _ v1: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_Uniform2ui(location, v0, v1)
    }

    @_expose(Cxx)
    public func uniform3ui(_ location: GLint, _ v0: GLuint, _ v1: GLuint, _ v2: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_Uniform3ui(location, v0, v1, v2)
    }

    @_expose(Cxx)
    public func uniform4ui(_ location: GLint, _ v0: GLuint, _ v1: GLuint, _ v2: GLuint, _ v3: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_Uniform4ui(location, v0, v1, v2, v3)
    }

    @_expose(Cxx)
    public func vertexAttribI4i(_ index: GLuint, _ x: GLint, _ y: GLint, _ z: GLint, _ w: GLint) {
        guard makeContextCurrent() else {
            return
        }
        GL_VertexAttribI4i(index, x, y, z, w)
    }

    @_expose(Cxx)
    public func vertexAttribI4ui(_ index: GLuint, _ x: GLuint, _ y: GLuint, _ z: GLuint, _ w: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_VertexAttribI4ui(index, x, y, z, w)
    }

    @_expose(Cxx)
    public func clearBufferfi(_ buffer: GLenum, _ drawbuffer: GLint, _ depth: GLfloat, _ stencil: GLint) {
        guard makeContextCurrent() else {
            return
        }
        GL_ClearBufferfi(buffer, drawbuffer, depth, stencil)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func isQuery(_ query: GLuint) -> GLboolean {
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return GL_IsQuery(query)
    }

    @_expose(Cxx)
    public func isSampler(_ sampler: GLuint) -> GLboolean {
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return GL_IsSampler(sampler)
    }

    @_expose(Cxx)
    public func bindSampler(_ unit: GLuint, _ sampler: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_BindSampler(unit, sampler)
    }

    @_expose(Cxx)
    public func samplerParameteri(_ sampler: GLuint, _ pname: GLenum, _ param: GLint) {
        guard makeContextCurrent() else {
            return
        }
        GL_SamplerParameteri(sampler, pname, param)
    }

    @_expose(Cxx)
    public func samplerParameterf(_ sampler: GLuint, _ pname: GLenum, _ param: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_SamplerParameterf(sampler, pname, param)
    }

    @_expose(Cxx)
    public func pauseTransformFeedback() {
        guard makeContextCurrent() else {
            return
        }
        GL_PauseTransformFeedback()
    }

    @_expose(Cxx)
    public func resumeTransformFeedback() {
        guard makeContextCurrent() else {
            return
        }
        GL_ResumeTransformFeedback()
    }

    @_expose(Cxx)
    public func bindBufferRange(_ target: GLenum, _ index: GLuint, _ buffer: GLuint, _ offset: GLintptr, _ size: GLsizeiptr) {
        guard makeContextCurrent() else {
            return
        }
        GL_BindBufferRange(target, index, buffer, offset, size)
    }

    @_expose(Cxx)
    public func isQueryEXT(_ query: GLuint) -> GLboolean {
        guard makeContextCurrent() else {
            return GLboolean(GL_FALSE)
        }
        return GL_IsQueryEXT(query)
    }

    @_expose(Cxx)
    public func beginQueryEXT(_ target: GLenum, _ query: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_BeginQueryEXT(target, query)
    }

    @_expose(Cxx)
    public func endQueryEXT(_ target: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_EndQueryEXT(target)
    }

    @_expose(Cxx)
    public func queryCounterEXT(_ query: GLuint, _ target: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_QueryCounterEXT(query, target)
    }

    @_expose(Cxx)
    public func enableiOES(_ target: GLenum, _ index: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_EnableiOES(target, index)
    }

    @_expose(Cxx)
    public func disableiOES(_ target: GLenum, _ index: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_DisableiOES(target, index)
    }

    @_expose(Cxx)
    public func blendEquationiOES(_ buf: GLuint, _ mode: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_BlendEquationiOES(buf, mode)
    }

    @_expose(Cxx)
    public func blendEquationSeparateiOES(_ buf: GLuint, _ modeRGB: GLenum, _ modeAlpha: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_BlendEquationSeparateiOES(buf, modeRGB, modeAlpha)
    }

    @_expose(Cxx)
    public func blendFunciOES(_ buf: GLuint, _ src: GLenum, _ dst: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_BlendFunciOES(buf, src, dst)
    }

    @_expose(Cxx)
    public func blendFuncSeparateiOES(_ buf: GLuint, _ srcRGB: GLenum, _ dstRGB: GLenum, _ srcAlpha: GLenum, _ dstAlpha: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_BlendFuncSeparateiOES(buf, srcRGB, dstRGB, srcAlpha, dstAlpha)
    }

    @_expose(Cxx)
    public func colorMaskiOES(_ buf: GLuint, _ red: GLboolean, _ green: GLboolean, _ blue: GLboolean, _ alpha: GLboolean) {
        guard makeContextCurrent() else {
            return
        }
        GL_ColorMaskiOES(buf, red, green, blue, alpha)
    }

    @_expose(Cxx)
    public func drawArraysInstancedBaseInstanceANGLE(_ mode: GLenum, _ first: GLint, _ count: GLsizei, _ instanceCount: GLsizei, _ baseInstance: GLuint) {
        guard makeContextCurrent() else {
            return
        }
        GL_DrawArraysInstancedBaseInstanceANGLE(mode, first, count, instanceCount, baseInstance)
        checkGPUStatus()
    }

    @_expose(Cxx)
    public func clipControlEXT(_ origin: GLenum, _ depth: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_ClipControlEXT(origin, depth)
    }

    @_expose(Cxx)
    public func provokingVertexANGLE(_ provokeMode: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_ProvokingVertexANGLE(provokeMode)
    }

    @_expose(Cxx)
    public func polygonModeANGLE(_ face: GLenum, _ mode: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        GL_PolygonModeANGLE(face, mode)
    }

    @_expose(Cxx)
    public func polygonOffsetClampEXT(_ factor: GLfloat, _ units: GLfloat, _ clamp: GLfloat) {
        guard makeContextCurrent() else {
            return
        }
        GL_PolygonOffsetClampEXT(factor, units, clamp)
    }
}

// The values of GraphicsContextGLSimulatedEventForTesting.
enum GLContextSimulatedEvent {
    static let gpuStatusFailure: UInt8 = 0
    static let timeout: UInt8 = 1
    static let displayBufferAllocationFailure: UInt8 = 2
    static let renderbufferAllocationFailure: UInt8 = 3
}

