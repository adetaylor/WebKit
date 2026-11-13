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

    // Enables the extensions the platform needs. Returns false if the context should not be used.
    func initializeExtensions(_ context: GLContext) -> Bool
    // Initializes the platform's state that depends on the context's. Returns false if the context should not be used.
    func initialize(_ context: GLContext) -> Bool
    func reshapeDrawingBuffer(_ context: GLContext) -> Bool
    func invalidateKnownTextureContent(_ texture: GLuint)
    // The context noticed a GPU reset, and is about to be lost.
    func didLoseDisplay()
    // With the context current, before it destroys its own GL objects.
    func willDestroy(_ context: GLContext)
    // Destroys the platform's EGL objects.
    func destroy(_ context: GLContext, didReset: Bool)
}

// A C++ platform, reached through GLContextCallbacks by the context's identifier. It destroys its own EGL objects.
final class CxxGLContextPlatform: GLContextPlatform {
    let contextID: UInt64
    let display: ANGLEDisplay
    let eglContext: ANGLEContext

    init(contextID: UInt64, display: ANGLEDisplay, eglContext: ANGLEContext) {
        self.contextID = contextID
        self.display = display
        self.eglContext = eglContext
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

    func didLoseDisplay() {
        GLContextCallbacks.didLoseDisplay(contextID)
    }

    func willDestroy(_ context: GLContext) {
    }

    func destroy(_ context: GLContext, didReset: Bool) {
    }
}
