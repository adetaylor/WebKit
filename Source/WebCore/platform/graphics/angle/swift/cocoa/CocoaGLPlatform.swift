// Copyright (C) 2009-2021 Apple Inc. All rights reserved.
// Copyright (C) 2021 Apple Inc. All rights reserved.
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

#if WTF_PLATFORM_COCOA

internal import CoreVideo
internal import IOSurface
internal import Metal
internal import Synchronization
internal import WebCoreANGLE
internal import WebCoreANGLE.Cocoa

// ANGLE shares one EGLDisplay between all the contexts that are created with the same display attributes. After a GPU
// reset, the display stays lost and contexts cannot be created on it. The reset increments the key, so that the
// contexts created after the reset use a new display. A display of an older key is terminated when its last context
// is destroyed.
private struct CocoaGLDisplays {
    var currentKey = 0
    var contextCounts: [UInt: Int] = [:]
}

private let cocoaGLDisplays = Mutex(CocoaGLDisplays())

// The attributes of a context that its Cocoa platform needs.
struct CocoaGLContextAttributes {
    var isWebGL2: Bool
    var alpha: Bool
    var powerPreference: UInt8
    var windowGPUID: UInt64
    var xrCompatible: Bool
    var ownershipIdentity: UInt32
    var maximumSurfaceWidth: Int32
    var maximumSurfaceHeight: Int32
}

// A drawing buffer: an IOSurface and the pbuffer of it ANGLE renders to.
struct CocoaGLPbuffer {
    var surface: IOSurfaceRef
    var pbuffer: ANGLESurface

    var isInUse: Bool {
        IOSurfaceIsInUse(surface)
    }

    var size: GLSize {
        GLSize(width: Int32(truncatingIfNeeded: IOSurfaceGetWidth(surface)), height: Int32(truncatingIfNeeded: IOSurfaceGetHeight(surface)))
    }
}

struct CocoaGLSpareBuffer {
    var surface: IOSurfaceRef
    var isAvailable = false
}

// The Cocoa platform of a WebGL context: ANGLE's Metal display and the context's EGL context, the IOSurface drawing
// buffers it renders to and displays.
@_expose(Cxx)
public final class CocoaGLPlatform: GLContextPlatform {
    @_expose(!Cxx)
    static let maxReusedDrawingBuffers = 3
    // On iOS CoreAnimation keeps a displayed buffer for about 4 frames; one more for headroom.
    @_expose(!Cxx)
    static let maxSpareDrawingBuffers = 5

    @_expose(!Cxx)
    let contextID: UInt64
    let attributes: CocoaGLContextAttributes
    @_expose(!Cxx)
    private(set) var display = ANGLEDisplay()
    @_expose(!Cxx)
    private(set) var displayKey = 0
    @_expose(!Cxx)
    private(set) var config = ANGLEConfig()
    @_expose(!Cxx)
    private(set) var eglContext = ANGLEContext()
    private var isInitialized = false

#if ENABLE_VIDEO
    private var videoUpload = GLVideoUpload()
#endif

    private var currentDrawingBufferIndex = 0
    private var drawingBuffers = [CocoaGLPbuffer?](repeating: nil, count: CocoaGLPlatform.maxReusedDrawingBuffers)
    private var spareDrawingBuffers: [CocoaGLSpareBuffer] = []

    // Makes the display and the context, and the context current. isValid() is false if it couldn't.
    @_expose(Cxx)
    public init(contextID: UInt64, isWebGL2: Bool, alpha: Bool, powerPreference: UInt8, windowGPUID: UInt64, xrCompatible: Bool, ownershipIdentity: UInt32, maximumSurfaceWidth: Int32, maximumSurfaceHeight: Int32) {
        self.contextID = contextID
        self.attributes = CocoaGLContextAttributes(isWebGL2: isWebGL2, alpha: alpha, powerPreference: powerPreference, windowGPUID: windowGPUID, xrCompatible: xrCompatible, ownershipIdentity: ownershipIdentity, maximumSurfaceWidth: maximumSurfaceWidth, maximumSurfaceHeight: maximumSurfaceHeight)
        initializeContext()
    }

    @_expose(Cxx)
    public func isValid() -> Bool {
        isInitialized
    }

    @_expose(Cxx)
    public func platformDisplay() -> ANGLEDisplay {
        display
    }

    @_expose(Cxx)
    public func platformConfig() -> ANGLEConfig {
        config
    }

    @_expose(Cxx)
    public func platformContext() -> ANGLEContext {
        eglContext
    }

    // Display and context.

    private static func platformSupportsMetal() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return false
        }
#if os(macOS) || targetEnvironment(macCatalyst)
        // Old Macs, such as MacBookPro11,4 cannot use WebGL via Metal.
        // This check can be removed once they are no longer supported.
        if !supportsMac2Family(device) {
            return false
        }
#endif
        return true
    }

#if os(macOS) || targetEnvironment(macCatalyst)
#if hasAttribute(diagnose)
    @diagnose(DeprecatedDeclaration, as: ignored, reason: "MTLGPUFamilyMac2 is the family of the old Macs that can't run WebGL")
#endif
    private static func supportsMac2Family(_ device: any MTLDevice) -> Bool {
        device.supportsFamily(.mac2)
    }
#endif

    private static func initializeEGLDisplay(_ attributes: CocoaGLContextAttributes, displayKey: Int) -> ANGLEDisplay {
        if !ANGLECocoa.isAvailable() {
            GLLog.webGL("Failed to load ANGLE shared library.")
            return ANGLEDisplay()
        }
#if os(macOS)
        let gpuID = attributes.windowGPUID
#else
        let gpuID: UInt64 = 0
#endif
        let display = ANGLECocoa.getMetalDisplay(attributes.powerPreference, gpuID, displayKey)
        if display.isNull() || !ANGLECocoa.initialize(display) {
            return ANGLEDisplay()
        }
        assert(Swift.String(ANGLECocoa.queryString(display, EGL_EXTENSIONS)).contains("EGL_ANGLE_metal_shared_event_sync"))
        return display
    }

    // Returns the EGL error of the context creation.
    private func createDisplayAndContext() -> EGLint {
        let attributes = self.attributes
        let (key, newDisplay) = cocoaGLDisplays.withLock { displays in
            // The display is initialized and counted under the lock, so that it is not terminated in between.
            let key = displays.currentKey
            let display = Self.initializeEGLDisplay(attributes, displayKey: key)
            if !display.isNull() {
                displays.contextCounts[display.identity(), default: 0] += 1
            }
            return (key, display)
        }
        displayKey = key
        display = newDisplay
        if display.isNull() {
            return EGL_NOT_INITIALIZED
        }

        config = ANGLECocoa.chooseConfig(display)
        if config.isNull() {
            return EGL_BAD_CONFIG
        }

        _ = ANGLECocoa.bindOpenGLESAPI()
        let error = ANGLECocoa.error()
        if error != EGL_SUCCESS {
            return error
        }

        eglContext = ANGLECocoa.createWebGLContext(display, config, attributes.isWebGL2, attributes.ownershipIdentity)
        return eglContext.isNull() ? ANGLECocoa.error() : EGL_SUCCESS
    }

    private func initializeContext() {
        if !Self.platformSupportsMetal() {
            return
        }
        var error = createDisplayAndContext()
        if error == EGL_CONTEXT_LOST || error == EGL_BAD_DISPLAY {
            // The display was lost in a GPU reset that no context noticed. Create the context on a new display.
            Self.didLoseDisplay(displayKey)
            Self.releaseDisplay(display, displayKey)
            display = ANGLEDisplay()
            // The config belongs to the released display.
            config = ANGLEConfig()
            error = createDisplayAndContext()
        }
        if error != EGL_SUCCESS || !GLContext.makeCurrent(display, eglContext) {
            return
        }
        isInitialized = true
    }

    // The other contexts of the display may notice the reset later, so the key is incremented only once.
    @_expose(!Cxx)
    static func didLoseDisplay(_ displayKey: Int) {
        cocoaGLDisplays.withLock { displays in
            if displayKey == displays.currentKey {
                displays.currentKey += 1
            }
        }
    }

    @_expose(!Cxx)
    static func releaseDisplay(_ display: ANGLEDisplay, _ displayKey: Int) {
        let identity = display.identity()
        let terminates = cocoaGLDisplays.withLock { displays -> Bool in
            guard let count = displays.contextCounts[identity] else {
                fatalError("A display was released more often than it was counted")
            }
            if count > 1 {
                displays.contextCounts[identity] = count - 1
                return false
            }
            displays.contextCounts[identity] = nil
            return displayKey < displays.currentKey
        }
        // A display of an older key is not handed out again, so it is terminated without the lock.
        if terminates {
            _ = ANGLE.terminate(display)
        }
    }

    @_expose(Cxx)
    public static func isDisplayInitializedForTesting(_ display: ANGLEDisplay) -> Bool {
        !ANGLECocoa.queryString(display, EGL_VENDOR).empty()
    }

    // GLContextPlatform.

    @_expose(!Cxx)
    func initializeExtensions(_ context: GLContext) -> Bool {
#if os(macOS)
        // For creating the EGL surface from an IOSurface.
        if !context.enableExtensions(["GL_EXT_texture_format_BGRA8888"]) {
            return false
        }
#endif
        // For flip blit.
        if !attributes.isWebGL2 && !context.enableExtensions(["GL_NV_framebuffer_blit"]) {
            return false
        }
#if ENABLE_WEBXR
        if attributes.xrCompatible && !enableRequiredWebXRExtensions(context) {
            return false
        }
#endif
        return true
    }

    @_expose(!Cxx)
    func initialize(_ context: GLContext) -> Bool {
        // Compute platform-specific max internal framebuffer size.
        context.clampMaxInternalFramebufferSize(attributes.maximumSurfaceWidth, attributes.maximumSurfaceHeight)
        return true
    }

    @_expose(!Cxx)
    func reshapeDrawingBuffer(_ context: GLContext) -> Bool {
        assert(!context.internalFramebufferSize.isEmpty)
        freeDrawingBuffers()
        return bindNextDrawingBuffer(context)
    }

    func invalidateKnownTextureContent(_ texture: GLuint) {
#if ENABLE_VIDEO
        videoUpload.invalidateKnownTextureContent(texture)
#endif
    }

    // With the context current.
    @_expose(!Cxx)
    func invalidateKnownTextureContent(forTarget target: GLenum) {
#if ENABLE_VIDEO
        videoUpload.invalidateKnownTextureContent(forTarget: target)
#endif
    }

    @_expose(!Cxx)
    func didLoseDisplay() {
        GLLog.webGL("GPU has reset (context \(contextID)). Lose the context.")
        Self.didLoseDisplay(displayKey)
    }

    // With the context current.
    @_expose(!Cxx)
    func willDestroy(_ context: GLContext) {
        freeDrawingBuffers()
    }

    @_expose(!Cxx)
    func destroy(_ context: GLContext, didReset: Bool) {
        // A context that is destroyed before it noticed a GPU reset must not leave the lost display to the new contexts.
        if didReset {
            Self.didLoseDisplay(displayKey)
        }
        if !eglContext.isNull() {
            context.destroyExternalImagesAndSyncs()
        }
        destroyContextAndReleaseDisplay()
    }

    // For a platform that no GLContext was made with.
    @_expose(Cxx)
    public func destroyWithoutContext() {
        destroyContextAndReleaseDisplay()
    }

    private func destroyContextAndReleaseDisplay() {
        if !eglContext.isNull() {
            _ = GLContext.releaseCurrentContext(display)
            _ = ANGLECocoa.destroyContext(display, eglContext)
            eglContext = ANGLEContext()
        }
        if !display.isNull() {
            Self.releaseDisplay(display, displayKey)
            display = ANGLEDisplay()
        }
    }

#if ENABLE_WEBXR
    @_expose(!Cxx)
    func enableRequiredWebXRExtensions(_ context: GLContext) -> Bool {
        if !attributes.isWebGL2 && !context.enableExtensions(["GL_EXT_sRGB"]) {
            return false
        }
        var names = [
            "GL_ANGLE_framebuffer_multisample",
            "GL_ANGLE_framebuffer_blit",
            "GL_EXT_discard_framebuffer",
            "GL_OES_EGL_image",
            "GL_OES_rgb8_rgba8",
        ]
#if !targetEnvironment(simulator)
        names.append("GL_ANGLE_variable_rasterization_rate_metal")
#endif
#if os(visionOS) || os(macOS)
        names.append("GL_WEBKIT_explicit_resolve_target")
#endif
        names.append("GL_NV_framebuffer_blit")
        return context.enableExtensions(names)
    }
#endif

    // Drawing buffers.

    private var drawingBufferIndex: Int {
        currentDrawingBufferIndex % Self.maxReusedDrawingBuffers
    }

    private var displayBufferIndex: Int {
        (currentDrawingBufferIndex + Self.maxReusedDrawingBuffers - 1) % Self.maxReusedDrawingBuffers
    }

    private var copyBufferIndex: Int {
        (currentDrawingBufferIndex + 1) % Self.maxReusedDrawingBuffers
    }

    private func surfaceBufferIndex(_ buffer: UInt8) -> Int {
        buffer == CocoaGLSurfaceBuffer.displayBuffer ? displayBufferIndex : drawingBufferIndex
    }

    // The display buffer's surface, retained, or nil.
    @_expose(Cxx)
    public func displayBufferSurface() -> IOSurfaceRef? {
        drawingBuffers[displayBufferIndex]?.surface
    }

    private func createDrawingBuffer(_ context: GLContext) -> CocoaGLPbuffer? {
        if let spare = takeSpareDrawingBuffer(context) {
            return createPbuffer(spare, context)
        }
        let size = context.internalFramebufferSize
        guard let surface = GLContextCallbacks.createDrawingBufferSurface(contextID, size.width, size.height) else {
            return nil
        }
        return createPbuffer(surface, context)
    }

    private func createPbuffer(_ surface: IOSurfaceRef, _ context: GLContext) -> CocoaGLPbuffer? {
        let size = context.internalFramebufferSize
        let internalFormat = attributes.alpha ? GLenum(GL_BGRA_EXT) : GLenum(GL_RGB)
        let pbuffer = ANGLECocoa.createIOSurfacePbuffer(display, config, surface, size.width, size.height, 0, GLenum(GL_TEXTURE_2D), internalFormat, GLenum(GL_UNSIGNED_BYTE), EGL_IOSURFACE_WRITE_HINT_ANGLE)
        if pbuffer.isNull() {
            return nil
        }
        return CocoaGLPbuffer(surface: surface, pbuffer: pbuffer)
    }

    private func bindNextDrawingBuffer(_ context: GLContext) -> Bool {
        assert(!context.internalFramebufferSize.isEmpty)
        updateSpareDrawingBuffers()
        if let buffer = drawingBuffers[drawingBufferIndex] {
            _ = ANGLECocoa.releaseTexImage(display, buffer.pbuffer)
        }

        currentDrawingBufferIndex += 1
        let index = drawingBufferIndex

        if let buffer = drawingBuffers[index] {
            if buffer.isInUse {
                retireDrawingBuffer(index)
            } else if context.failsNextDrawingBufferAllocation() {
                _ = ANGLECocoa.destroySurface(display, buffer.pbuffer)
                drawingBuffers[index] = nil
            }
        }
        if context.takeFailNextDrawingBufferAllocation() {
            return false
        }
        if drawingBuffers[index] == nil {
            guard let buffer = createDrawingBuffer(context) else {
                return false
            }
            drawingBuffers[index] = buffer
        }

        guard let buffer = drawingBuffers[index] else {
            return false
        }
        return withRestoredTextureBinding(GLenum(GL_TEXTURE_BINDING_2D), GLenum(GL_TEXTURE_2D)) {
            GL_BindTexture(GLenum(GL_TEXTURE_2D), context.drawingBufferTexture())
            if !ANGLECocoa.bindTexImage(display, buffer.pbuffer) {
                _ = ANGLECocoa.destroySurface(display, buffer.pbuffer)
                drawingBuffers[index] = nil
                return false
            }
            return true
        }
    }

    private func freeDrawingBuffers() {
        // Note: due to a ANGLE bug in ReleaseTexImage, the current context should be the context owning the pbuffer and
        // the texture.
        if let buffer = drawingBuffers[drawingBufferIndex] {
            _ = ANGLECocoa.releaseTexImage(display, buffer.pbuffer)
        }
        for index in drawingBuffers.indices {
            if let buffer = drawingBuffers[index] {
                _ = ANGLECocoa.destroySurface(display, buffer.pbuffer)
                drawingBuffers[index] = nil
            }
        }
        spareDrawingBuffers.removeAll()
    }

    private func retireDrawingBuffer(_ index: Int) {
        guard let buffer = drawingBuffers[index] else {
            return
        }
        _ = ANGLECocoa.destroySurface(display, buffer.pbuffer)
        drawingBuffers[index] = nil
        spareDrawingBuffers.append(CocoaGLSpareBuffer(surface: buffer.surface))
        if spareDrawingBuffers.count > Self.maxSpareDrawingBuffers {
            spareDrawingBuffers.removeFirst()
        }
    }

    private func takeSpareDrawingBuffer(_ context: GLContext) -> IOSurfaceRef? {
        guard let index = spareDrawingBuffers.firstIndex(where: { $0.isAvailable }) else {
            return nil
        }
        let surface = spareDrawingBuffers.remove(at: index).surface
        assert(Int32(truncatingIfNeeded: IOSurfaceGetWidth(surface)) == context.internalFramebufferSize.width && Int32(truncatingIfNeeded: IOSurfaceGetHeight(surface)) == context.internalFramebufferSize.height)
        // The contents do not matter, so neither does whether they were purged.
        _ = ANGLECocoa.setVolatile(surface, false)
        return surface
    }

    private func updateSpareDrawingBuffers() {
        for index in spareDrawingBuffers.indices {
            if spareDrawingBuffers[index].isAvailable || IOSurfaceIsInUse(spareDrawingBuffers[index].surface) {
                continue
            }
            spareDrawingBuffers[index].isAvailable = true
            _ = ANGLECocoa.setVolatile(spareDrawingBuffers[index].surface, true)
        }
    }

    @_expose(Cxx)
    public func hasSpareDrawingBuffersInUse() -> Bool {
        spareDrawingBuffers.contains { !$0.isAvailable }
    }

    @_expose(Cxx)
    public func releaseIdleSpareDrawingBuffers() {
        updateSpareDrawingBuffers()
        spareDrawingBuffers.removeAll { !$0.isAvailable }
    }

    @_expose(Cxx)
    public func spareDrawingBufferCountForTesting() -> Int {
        spareDrawingBuffers.count
    }

    // As the kernel has it.
    @_expose(Cxx)
    public func volatileSpareDrawingBufferCountForTesting() -> Int {
        spareDrawingBuffers.count(where: { ANGLECocoa.isVolatile($0.surface) })
    }

    // Display.

    // Whether the current frame can be displayed. If it can, the caller inserts the frame's finished fence, then
    // calls didPrepareForDisplay().
    @_expose(!Cxx)
    func willPrepareForDisplay(_ context: GLContext) -> Bool {
        guard context.makeContextCurrent() else {
            return false
        }
        // The next drawing buffer cannot be created on a display lost in a GPU reset.
        context.checkGPUStatus()
        return !context.isContextLost() && drawingBuffers[drawingBufferIndex] != nil
    }

    @_expose(!Cxx)
    func didPrepareForDisplay(_ context: GLContext) {
        let success = bindNextDrawingBuffer(context)
        waitUntilWorkScheduled()
        if !success {
            context.forceContextLost()
        }
    }

    @_expose(Cxx)
    public func waitUntilWorkScheduled() {
        ANGLECocoa.waitUntilWorkScheduled(display)
    }

    // A copy of the drawing or display buffer, flipped to image orientation, or nil. The copy is retained.
    @_expose(!Cxx)
    func copySurfaceBuffer(_ context: GLContext, _ bufferType: UInt8) -> IOSurfaceRef? {
        let size = context.internalFramebufferSize
        guard let source = drawingBuffers[surfaceBufferIndex(bufferType)], source.size == size else {
            return nil
        }

        let copyIndex = copyBufferIndex
        updateSpareDrawingBuffers()
        if drawingBuffers[copyIndex]?.isInUse ?? false {
            retireDrawingBuffer(copyIndex)
        }
        if drawingBuffers[copyIndex] == nil {
            guard let buffer = createDrawingBuffer(context) else {
                return nil
            }
            drawingBuffers[copyIndex] = buffer
        }
        guard let destination = drawingBuffers[copyIndex] else {
            return nil
        }

        let succeeded = withRestoredTextureBinding(GLenum(GL_TEXTURE_BINDING_2D), GLenum(GL_TEXTURE_2D)) { () -> Bool in
            let destinationTexture = ANGLE.genTexture()
            defer {
                ANGLE.deleteTexture(destinationTexture)
            }
            GL_BindTexture(GLenum(GL_TEXTURE_2D), destinationTexture)

            if !ANGLECocoa.bindTexImage(display, destination.pbuffer) {
                return false
            }
            defer {
                _ = ANGLECocoa.releaseTexImage(display, destination.pbuffer)
            }
            // Restores the bindings after the scratch framebuffers below are deleted, as deleting a bound framebuffer
            // resets the binding to 0.
            defer {
                if attributes.isWebGL2 {
                    GL_BindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), context.boundDrawFramebuffer())
                    GL_BindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), context.boundReadFramebuffer())
                } else {
                    GL_BindFramebuffer(GLenum(GL_FRAMEBUFFER), context.boundDrawFramebuffer())
                }
            }
            let flipFBO = ANGLE.genFramebuffer()
            defer {
                ANGLE.deleteFramebuffer(flipFBO)
            }
            GL_BindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER_ANGLE), flipFBO)
            GL_FramebufferTexture2D(GLenum(GL_DRAW_FRAMEBUFFER_ANGLE), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), destinationTexture, 0)

            // A framebuffer of its own, since the client might have modified the default framebuffer's state.
            var sourceTexture: GLuint?
            defer {
                if let sourceTexture {
                    ANGLE.deleteTexture(sourceTexture)
                }
            }
            let sourceFBO = ANGLE.genFramebuffer()
            defer {
                ANGLE.deleteFramebuffer(sourceFBO)
            }
            defer {
                if sourceTexture != nil {
                    _ = ANGLECocoa.releaseTexImage(display, source.pbuffer)
                }
            }
            var sourceTextureName = context.drawingBufferTexture()
            if bufferType == CocoaGLSurfaceBuffer.displayBuffer {
                let texture = ANGLE.genTexture()
                sourceTexture = texture
                GL_BindTexture(GLenum(GL_TEXTURE_2D), texture)
                if !ANGLECocoa.bindTexImage(display, source.pbuffer) {
                    ANGLE.deleteTexture(texture)
                    sourceTexture = nil
                    return false
                }
                sourceTextureName = texture
            }

            GL_BindFramebuffer(GLenum(GL_READ_FRAMEBUFFER_ANGLE), sourceFBO)
            GL_FramebufferTexture2D(GLenum(GL_READ_FRAMEBUFFER_ANGLE), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), sourceTextureName, 0)

            assert(GL_CheckFramebufferStatus(GLenum(GL_DRAW_FRAMEBUFFER_ANGLE)) == GLenum(GL_FRAMEBUFFER_COMPLETE))
            assert(GL_CheckFramebufferStatus(GLenum(GL_READ_FRAMEBUFFER_ANGLE)) == GLenum(GL_FRAMEBUFFER_COMPLETE))
            withCapability(GLenum(GL_SCISSOR_TEST), enabled: false) {
                withCapability(GLenum(GL_DITHER), enabled: false) {
                    // The destination rows run the other way, which is the flip.
                    context.blitFramebuffer(0, 0, size.width, size.height, 0, size.height, size.width, 0, GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST))
                }
            }
            return true
        }
        return succeeded ? destination.surface : nil
    }

    // Reads the display buffer, through GL, into pixels, at the context's size. Returns false if it couldn't.
    // At the time of writing, there are no convenient functions to convert the IOSurface pixel data to ImageData. The
    // image data ends up being drawn to an ImageBuffer, but at the time there's no functions to construct a NativeImage
    // out of an IOSurface in such a way that drawing the NativeImage would be guaranteed leave the IOSurface be
    // unreferenced after the draw call finishes.
    @_expose(!Cxx)
    func readCompositedResults(_ context: GLContext, _ pixels: WebCore.GLLentMutableBytes, _ width: Int32, _ height: Int32) -> Bool {
        guard let buffer = drawingBuffers[displayBufferIndex], buffer.size == context.internalFramebufferSize else {
            return false
        }
        let texture = ANGLE.genTexture()
        defer {
            ANGLE.deleteTexture(texture)
        }
        return withRestoredTextureBinding(GLenum(GL_TEXTURE_BINDING_2D), GLenum(GL_TEXTURE_2D)) {
            GL_BindTexture(GLenum(GL_TEXTURE_2D), texture)
            if !ANGLECocoa.bindTexImage(display, buffer.pbuffer) {
                return false
            }
            GL_TexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
            let fbo = ANGLE.genFramebuffer()
            defer {
                ANGLE.deleteFramebuffer(fbo)
            }
            return withReadFramebufferBinding(isForWebGL2: attributes.isWebGL2, restoring: context.boundReadFramebuffer()) { binding in
                binding.bind(fbo)
                GL_FramebufferTexture2D(binding.target, GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
                assert(GL_CheckFramebufferStatus(binding.target) == GLenum(GL_FRAMEBUFFER_COMPLETE))
                let succeeded = context.readPixelsForPaintResults(pixels, width, height)
                let releaseOk = ANGLECocoa.releaseTexImage(display, buffer.pbuffer)
                assert(releaseOk)
                return succeeded
            }
        }
    }

#if ENABLE_VIDEO
    // Video uploads, in the context's EGL context.

    // Like glCopyTextureCHROMIUM with the frame, whose orientation is an ImageOrientation::Orientation, as the source
    // texture. A failed copy leaves the texture unchanged.
    @_expose(!Cxx)
    func copyVideoFrameToTexture(_ context: GLContext, _ frame: CVPixelBuffer, orientation: UInt8, texture: GLuint, target: GLenum, level: GLint, internalFormat: GLenum, type: GLenum, unpackFlipY: Bool, unpackPremultiplyAlpha: Bool) -> GLVideoUploadOutcome {
        videoUpload.copyVideoFrameToTexture(context, display, config, frame, orientation: orientation, texture: texture, target: target, level: level, internalFormat: internalFormat, type: type, unpackFlipY: unpackFlipY, unpackPremultiplyAlpha: unpackPremultiplyAlpha)
    }
#endif

    // The colour space of the drawing buffers changed: reallocates them, or loses the context if it can't.
    @_expose(!Cxx)
    func drawingBufferColorSpaceDidChange(_ context: GLContext) {
        if context.internalFramebufferSize.isEmpty {
            return
        }
        if !reshapeDrawingBuffer(context) {
            context.forceContextLost()
        }
    }
}

// The values of GraphicsContextGLSurfaceBuffer.
enum CocoaGLSurfaceBuffer {
    static let drawingBuffer: UInt8 = 0
    static let displayBuffer: UInt8 = 1
}

#endif
