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

internal import WebCoreANGLE

// The platform of a context: its EGL display and context, and what it does around the GL logic. It is given the
// context, which owns it, rather than keeping it.
protocol GLContextPlatform: AnyObject {
    var display: ANGLEDisplay { get }
    var eglContext: ANGLEContext { get }

    // Makes the platform's EGL context current, and returns whether it is.
    func makeCurrent() -> Bool
    // Enables the extensions the platform needs. Returns false if the context should not be used.
    func initializeExtensions(_ context: GLContext) -> Bool
    // Initializes the platform's state that depends on the context's. Returns false if the context should not be used.
    func initialize(_ context: GLContext) -> Bool
    func reshapeDrawingBuffer(_ context: GLContext) -> Bool
    func invalidateKnownTextureContent(_ texture: GLuint)
    #if WTF_PLATFORM_COCOA
    // The context noticed a GPU reset, and is about to be lost.
    func didLoseDisplay()
    #endif
    // With the context current, before it destroys its own GL objects.
    func willDestroy(_ context: GLContext)
    // Destroys the platform's EGL objects.
    func destroy(_ context: GLContext, didReset: Bool)
}

extension GLContextPlatform {
    // A surfaceless context.
    func makeCurrent() -> Bool {
        ANGLE.makeCurrent(display, eglContext)
    }
}

// An EGL platform whose C++ made the EGL context, reached through GLContextCallbacks by the context's identifier. It
// owns the EGL context, the surface (none if the display has surfaceless contexts) and the sharing context (none if
// there is none), and destroys them.
final class EGLGLContextPlatform: GLContextPlatform {
    let contextID: UInt64
    let display: ANGLEDisplay
    let eglContext: ANGLEContext
    private let surface: ANGLESurface
    private let sharingContext: ANGLEContext

    init(contextID: UInt64, display: ANGLEDisplay, eglContext: ANGLEContext, surface: ANGLESurface, sharingContext: ANGLEContext) {
        self.contextID = contextID
        self.display = display
        self.eglContext = eglContext
        self.surface = surface
        self.sharingContext = sharingContext
    }

    func makeCurrent() -> Bool {
        guard ANGLE.makeCurrent(display, surface, eglContext) else {
            return false
        }
        GLContextCallbacks.didMakeCurrent(contextID)
        return true
    }

    func initializeExtensions(_ context: GLContext) -> Bool {
        GLContextCallbacks.platformInitializeExtensions(contextID)
    }

    func initialize(_ context: GLContext) -> Bool {
        GLContextCallbacks.platformInitialize(contextID)
    }

    func reshapeDrawingBuffer(_ context: GLContext) -> Bool {
        GLContextCallbacks.reshapeDrawingBuffer(contextID)
    }

    func invalidateKnownTextureContent(_ texture: GLuint) {
        GLContextCallbacks.invalidateKnownTextureContent(contextID, texture)
    }

    #if WTF_PLATFORM_COCOA
    // Cocoa contexts lose their display through CocoaGLPlatform; an EGL platform's display has nothing to drop.
    func didLoseDisplay() {
    }
    #endif

    func willDestroy(_ context: GLContext) {
    }

    func destroy(_ context: GLContext, didReset: Bool) {
        context.destroyExternalImagesAndSyncs()
        #if os(Windows)
        _ = GLContext.releaseCurrentContext(display)
        #endif
        _ = ANGLE.destroyContext(display, eglContext)
        #if !os(Windows)
        if !sharingContext.isNull() {
            _ = ANGLE.destroyContext(display, sharingContext)
        }
        // Ideally this should go before the context's destruction, but there are platforms where it breaks the
        // destruction of the context.
        _ = GLContext.releaseCurrentContext(display)
        #endif
        if !surface.isNull() {
            _ = ANGLE.destroySurface(display, surface)
        }
    }
}

#if !WTF_PLATFORM_COCOA
extension EGLGLContextPlatform {
    // A WebGL context's EGL objects on an EGL port's display. sharingContext is Windows' display's, and may be none
    // there. Returns nil, having destroyed what it made, if one fails.
    static func createObjects(
        display: ANGLEDisplay,
        sharingContext: ANGLEContext,
        isSurfacelessDisplay: Bool,
        isWebGL2: Bool
    ) -> (config: ANGLEConfig, surface: ANGLESurface, context: ANGLEContext)? {
        #if !os(Windows)
        guard !sharingContext.isNull() else {
            GLLog.debug("ANGLE sharing EGLContext Initialization failed.")
            return nil
        }
        #endif
        let extensions = Swift.String(ANGLE.queryString(display, EGL_EXTENSIONS))
        GLLog.debug("Extensions: \(extensions)")
        let extensionNames = extensions.split(separator: " ")
        let isSurfacelessContextSupported = extensionNames.contains("EGL_KHR_surfaceless_context")

        var configAttributes: [EGLint] = [EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT]
        #if USE_COORDINATED_GRAPHICS
        configAttributes += [
            EGL_SURFACE_TYPE, !isSurfacelessContextSupported || isSurfacelessDisplay ? EGL_PBUFFER_BIT : EGL_WINDOW_BIT,
        ]
        #endif
        configAttributes += [
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 0, EGL_STENCIL_SIZE, 0, EGL_NONE,
        ]
        let config = ANGLE.chooseConfig(display, configAttributes.span)
        guard !config.isNull() else {
            GLLog.debug("EGLConfig Initialization failed.")
            return nil
        }

        let pbufferAttributes: [EGLint] = [EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE]
        let surface = isSurfacelessContextSupported ? ANGLESurface() : ANGLE.createPbufferSurface(display, config, pbufferAttributes.span)
        guard isSurfacelessContextSupported || !surface.isNull() else {
            GLLog.debug("Surfaceless context is not supported and we failed to create a pbuffer surface")
            return nil
        }
        func destroySurface() {
            if !surface.isNull() {
                _ = ANGLE.destroySurface(display, surface)
            }
        }

        _ = ANGLE.bindOpenGLESAPI()
        guard ANGLE.error() == EGL_SUCCESS else {
            GLLog.debug("Unable to bind to OPENGL_ES_API")
            destroySurface()
            return nil
        }

        var contextAttributes: [EGLint]
        if isWebGL2 {
            contextAttributes = [EGL_CONTEXT_CLIENT_VERSION, 3]
        } else {
            // ANGLE will upgrade the context to ES3 automatically unless this is specified.
            contextAttributes = [EGL_CONTEXT_CLIENT_VERSION, 2, EGL_CONTEXT_OPENGL_BACKWARDS_COMPATIBLE_ANGLE, EGL_FALSE]
        }
        contextAttributes += [
            EGL_CONTEXT_WEBGL_COMPATIBILITY_ANGLE, EGL_TRUE,
            // WebGL requires that all resources are cleared at creation.
            EGL_ROBUST_RESOURCE_INITIALIZATION_ANGLE, EGL_TRUE,
            // WebGL doesn't allow client arrays.
            EGL_CONTEXT_CLIENT_ARRAYS_ENABLED_ANGLE, EGL_FALSE,
            // WebGL doesn't allow implicit creation of objects on bind.
            EGL_CONTEXT_BIND_GENERATES_RESOURCE_CHROMIUM, EGL_FALSE,
        ]
        #if USE_COORDINATED_GRAPHICS
        contextAttributes += [EGL_CONTEXT_VIRTUALIZATION_GROUP_ANGLE, 0]
        #endif
        if extensionNames.contains("EGL_ANGLE_power_preference") {
            // EGL_LOW_POWER_ANGLE is the default. Change to EGL_HIGH_POWER_ANGLE if desired.
            contextAttributes += [EGL_POWER_PREFERENCE_ANGLE, EGL_LOW_POWER_ANGLE]
        }
        contextAttributes.append(EGL_NONE)

        let context = ANGLE.createContext(display, config, sharingContext, contextAttributes.span)
        guard !context.isNull() else {
            GLLog.debug("EGLContext Initialization failed.")
            destroySurface()
            return nil
        }
        return (config, surface, context)
    }
}
#endif
