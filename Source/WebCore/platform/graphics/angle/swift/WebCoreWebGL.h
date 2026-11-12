/*
 * Copyright (C) 2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

// The C++ that the WebGL island's Swift module, WebCoreWebGL, sees as its underlying module: the C++ types in its API,
// and the C++ it calls back for a context whose client and platform are C++.

#include "WebCoreANGLE.h"
#include <wtf/SwiftBridging.h>

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurfaceRef.h>
#endif

// Structs that Swift returns to C++ have a size that is a multiple of 8 for Swift interop, rdar://191583570.
struct alignas(8) ANGLEReadPixelsStatus {
    GLsizei width { 0 };
    GLsizei height { 0 };
    bool succeeded { false };
};

struct alignas(8) ANGLEActiveVariableInfo {
    GLenum type { 0 };
    GLint size { 0 };
    GLint nameLength { 0 };
};

struct alignas(8) ANGLEActiveVariableCount {
    GLint count { 0 };
    GLint maxLength { 0 };
};

struct alignas(8) ANGLEActiveAttribInfo {
    GLenum type { 0 };
    GLint location { -1 };
    GLint nameLength { 0 };
};

struct alignas(8) ANGLEActiveUniformInfo {
    GLenum type { 0 };
    GLint size { 0 };
    GLint blockIndex { -1 };
    GLint offset { -1 };
    GLint arrayStride { -1 };
    GLint matrixStride { -1 };
    GLint isRowMajor { 0 };
    GLint nameLength { 0 };
    GLint locationCount { 0 };
};

namespace WebCore {

// The C++ client and platform of a context, which GraphicsContextGLANGLE.cpp finds by the context's identifier. A
// context that is gone finds nothing.
struct GLContextCallbacks final {
    GLContextCallbacks() = delete;

    static void forceContextLost(uint64_t contextID);
    static void didChangeMemoryCost(uint64_t contextID);
    static void didChangeInternalFramebufferSize(uint64_t contextID, int32_t width, int32_t height);
    static bool platformInitializeExtensions(uint64_t contextID);
    static bool platformInitialize(uint64_t contextID);
    static bool reshapeDrawingBuffer(uint64_t contextID);
    static void invalidateKnownTextureContent(uint64_t contextID, GLuint texture);
    static void didLoseDisplay(uint64_t contextID);

#if defined(__APPLE__)
    // A drawing buffer's IOSurface, of the context's colour space and owner.
    static IOSurfaceRef createDrawingBufferSurface(uint64_t contextID, int32_t width, int32_t height) CF_RETURNS_RETAINED;
    // A frame converted to '420f', for the video uploads, or null if it couldn't be.
    static CVPixelBufferRef convertPixelBufferTo420f(CVPixelBufferRef) CF_RETURNS_RETAINED;
#endif

#if !defined(__swift__)
    static void addDebugMessage(uint64_t contextID, GLenum type, GLenum messageID, GLenum severity, std::span<const char8_t> message);
#endif
};

// A C++ shell's calls into its island context and the context's Cocoa platform: GraphicsContextGLANGLE's and
// GraphicsContextGLCocoa's, which the island's Swift implements (GLIslandCalls.swift). It holds the shell's reference to
// its GLShell, which the shell owns from createShell() until it passes it to destroyShell(). Only a live shell's own
// reference may make one, and only for the length of a call, so Swift needs unsafe to make one.
class GLIslandCalls {
public:
    SWIFT_UNSAFE explicit GLIslandCalls(uintptr_t shell)
        : shell(shell)
    {
    }

    static uintptr_t createShell();
    SWIFT_UNSAFE static void destroyShell(uintptr_t);

    // Makes the context of a C++ platform, which made the EGL context.
    void createContext(uint64_t contextID, ANGLEDisplay, ANGLEContext, bool isWebGL2, bool supportsWebGLDraftExtensions) const;
    bool hasContext() const;
#if defined(__APPLE__)
    // Makes the Cocoa platform, then the context on it. Returns false if the platform is not valid.
    bool createCocoaPlatform(uint64_t contextID, bool isWebGL2, bool alpha, uint8_t powerPreference, uint64_t windowGPUID, bool xrCompatible, uint32_t ownershipIdentity, int32_t maximumSurfaceWidth, int32_t maximumSurfaceHeight) const;
    void createCocoaContext(uint64_t contextID, bool supportsWebGLDraftExtensions) const;
    bool hasPlatform() const;
#endif

    ANGLEActiveAttribInfo activeAttrib(GLuint, GLuint, GLLentMutableBytes) const;
    ANGLEActiveVariableCount activeAttribCount(GLuint) const;
    ANGLEActiveUniformInfo activeUniform(GLuint, GLuint, GLLentMutableBytes) const;
    GLint activeUniformBlockNameLength(GLuint) const;
    GLint getInteger(GLenum) const;
    ANGLEActiveVariableCount activeUniformCount(GLuint) const;
    bool activeUniformLocations(GLuint, GLLentBytes, GLint, GLLentMutableInts) const;
    void addErrors(uint8_t) const;
    uint32_t addExternalImage(ANGLEImage) const;
    uint32_t addExternalSync(ANGLEEGLSync) const;
    void bindAttribLocation(GLuint, GLuint, GLLentBytes) const;
    void bindExternalImage(GLenum, uint32_t) const;
    void bufferData(GLenum, GLLentBytes, GLenum) const;
    void bufferSubData(GLenum, GLintptr, GLLentBytes) const;
    void clampMaxInternalFramebufferSize(int32_t, int32_t) const;
    void clearActiveVariables() const;
    void clearBufferfv(GLenum, GLint, GLLentFloats) const;
    void clearBufferiv(GLenum, GLint, GLLentInts) const;
    void clearBufferuiv(GLenum, GLint, GLLentUnsignedInts) const;
    GLenum clientWaitSync(uint64_t, GLbitfield, GLuint64) const;
    void compressedTexImage2D(GLenum, GLint, GLenum, GLsizei, GLsizei, GLint, GLLentBytes) const;
    void compressedTexImage3D(GLenum, GLint, GLenum, GLsizei, GLsizei, GLsizei, GLint, GLLentBytes) const;
    void compressedTexSubImage2D(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLLentBytes) const;
    void compressedTexSubImage3D(GLenum, GLint, GLint, GLint, GLint, GLsizei, GLsizei, GLsizei, GLenum, GLLentBytes) const;
    intptr_t copyLastVariableName(GLLentMutableBytes) const;
    intptr_t copyString(GLenum, GLLentMutableBytes) const;
    void deleteSync(uint64_t) const;
    void destroy() const;
    void didForceContextLost() const;
    void drawBuffers(GLLentUnsignedInts) const;
    void drawBuffersEXT(GLLentUnsignedInts) const;
    bool enableExtension(uint8_t) const;
    bool enableExtensionsForPlatform(GLLentCStrings) const;
    int64_t estimatedMemoryCost() const;
    uint64_t fenceSync(GLenum, GLbitfield) const;
    void framebufferDiscard(GLenum, GLLentUnsignedInts) const;
    GLsizei getActiveUniformBlockName(GLuint, GLuint, GLLentMutableBytes) const;
    void getActiveUniformBlockiv(GLuint, GLuint, GLenum, GLLentMutableInts) const;
    void getBooleanv(GLenum, GLLentMutableBytes) const;
    bool getBufferSubData(GLenum, GLintptr, GLLentMutableBytes) const;
    uint8_t getErrors() const;
    void getFloatv(GLenum, GLLentMutableFloats) const;
    GLint getFragDataLocation(GLuint, GLLentBytes) const;
    void getIntegeri_v(GLenum, GLuint, GLLentMutableInts) const;
    void getIntegerv(GLenum, GLLentMutableInts) const;
    void getInternalformativ(GLenum, GLenum, GLenum, GLLentMutableInts) const;
    GLsizei getProgramInfoLog(GLuint, GLLentMutableBytes) const;
    GLsizei getShaderInfoLog(GLuint, GLLentMutableBytes) const;
    ANGLEShaderPrecisionFormat getShaderPrecisionFormat(GLenum, GLenum) const;
    GLint getSynci(uint64_t, GLenum) const;
    ANGLEActiveVariableInfo getTransformFeedbackVarying(GLuint, GLuint) const;
    GLsizei getTranslatedShaderSourceANGLE(GLuint, GLLentMutableBytes) const;
    GLuint getUniformBlockIndex(GLuint, GLLentBytes) const;
    void getUniformfv(GLuint, GLint, GLLentMutableFloats) const;
    void getUniformiv(GLuint, GLint, GLLentMutableInts) const;
    void getUniformuiv(GLuint, GLint, GLLentMutableUnsignedInts) const;
    bool initialize() const;
    void invalidateFramebuffer(GLenum, GLLentUnsignedInts) const;
    void invalidateSubFramebuffer(GLenum, GLLentUnsignedInts, GLint, GLint, GLsizei, GLsizei) const;
    bool isCurrent() const;
    GLboolean isSync(uint64_t) const;
    uint64_t knownActiveExtensions() const;
    bool makeCurrentForPlatform() const;
    ANGLEInt2 maxDrawingBufferSize() const;
    ANGLEInt2 maxViewportDims() const;
    void multiDrawArraysANGLE(GLenum, GLLentInts, GLLentInts, GLsizei) const;
    void multiDrawArraysInstancedANGLE(GLenum, GLLentInts, GLLentInts, GLLentInts, GLsizei) const;
    void multiDrawArraysInstancedBaseInstanceANGLE(GLenum, GLLentInts, GLLentInts, GLLentInts, GLLentUnsignedInts, GLsizei) const;
    void multiDrawElementsANGLE(GLenum, GLLentInts, GLLentInts, GLenum, GLsizei) const;
    void multiDrawElementsInstancedANGLE(GLenum, GLLentInts, GLLentInts, GLLentInts, GLenum, GLsizei) const;
    void multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(GLenum, GLLentInts, GLLentInts, GLLentInts, GLLentInts, GLLentUnsignedInts, GLenum, GLsizei) const;
    GLint programInfoLogLength(GLuint) const;
    void readPixels(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, GLLentMutableBytes, GLint, GLint, GLboolean) const;
    void readPixelsBufferObject(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, GLintptr, GLint, GLint) const;
    bool readPixelsForPaintResults(GLLentMutableBytes, int32_t, int32_t) const;
    ANGLEReadPixelsStatus readPixelsWithStatus(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, GLboolean, GLLentMutableBytes) const;
    bool readRenderingResults(GLLentMutableBytes, int32_t, int32_t) const;
    uint64_t requestableExtensions() const;
    void reshape(int32_t, int32_t) const;
    GLint shaderInfoLogLength(GLuint) const;
    void shaderSource(GLuint, GLLentBytes) const;
    void simulateEventForTesting(uint8_t) const;
    void texImage2D(GLenum, GLint, GLenum, GLsizei, GLsizei, GLint, GLenum, GLenum, GLLentBytes) const;
    void texImage3D(GLenum, GLint, GLint, GLsizei, GLsizei, GLsizei, GLint, GLenum, GLenum, GLLentBytes) const;
    void texSubImage2D(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, GLLentBytes) const;
    void texSubImage3D(GLenum, GLint, GLint, GLint, GLint, GLsizei, GLsizei, GLsizei, GLenum, GLenum, GLLentBytes) const;
    void transformFeedbackVaryings(GLuint, GLLentCStrings, GLenum) const;
    GLint translatedShaderSourceLength(GLuint) const;
    void uniform1fv(GLint, GLLentFloats) const;
    void uniform1iv(GLint, GLLentInts) const;
    void uniform1uiv(GLint, GLLentUnsignedInts) const;
    void uniform2fv(GLint, GLLentFloats) const;
    void uniform2iv(GLint, GLLentInts) const;
    void uniform2uiv(GLint, GLLentUnsignedInts) const;
    void uniform3fv(GLint, GLLentFloats) const;
    void uniform3iv(GLint, GLLentInts) const;
    void uniform3uiv(GLint, GLLentUnsignedInts) const;
    void uniform4fv(GLint, GLLentFloats) const;
    void uniform4iv(GLint, GLLentInts) const;
    void uniform4uiv(GLint, GLLentUnsignedInts) const;
    void uniformMatrix2fv(GLint, GLboolean, GLLentFloats) const;
    void uniformMatrix2x3fv(GLint, GLboolean, GLLentFloats) const;
    void uniformMatrix2x4fv(GLint, GLboolean, GLLentFloats) const;
    void uniformMatrix3fv(GLint, GLboolean, GLLentFloats) const;
    void uniformMatrix3x2fv(GLint, GLboolean, GLLentFloats) const;
    void uniformMatrix3x4fv(GLint, GLboolean, GLLentFloats) const;
    void uniformMatrix4fv(GLint, GLboolean, GLLentFloats) const;
    void uniformMatrix4x2fv(GLint, GLboolean, GLLentFloats) const;
    void uniformMatrix4x3fv(GLint, GLboolean, GLLentFloats) const;
    void vertexAttrib1fv(GLuint, GLfloat) const;
    void vertexAttrib2fv(GLuint, GLfloat, GLfloat) const;
    void vertexAttrib3fv(GLuint, GLfloat, GLfloat, GLfloat) const;
    void vertexAttrib4fv(GLuint, GLfloat, GLfloat, GLfloat, GLfloat) const;
    void vertexAttribI4iv(GLuint, GLint, GLint, GLint, GLint) const;
    void vertexAttribI4uiv(GLuint, GLuint, GLuint, GLuint, GLuint) const;
    void waitSync(uint64_t, GLbitfield, GLint64) const;
    void willDestroyPlatform() const;
    static void forgetCurrentContext();
    static bool makeCurrent(ANGLEDisplay, ANGLEContext);
    static bool reportsDebugMessage(GLenum, GLuint);
#if defined(__APPLE__)
    void destroyPlatformWithoutContext() const;
    // Retained, or null. Not CF_RETURNS_RETAINED: Swift implements it, and returns the reference retained itself.
    IOSurfaceRef displayBufferSurface() const;
    bool hasSpareDrawingBuffersInUse() const;
    bool isPlatformValid() const;
    ANGLEConfig platformConfig() const;
    ANGLEContext platformContext() const;
    ANGLEDisplay platformDisplay() const;
    void releaseIdleSpareDrawingBuffers() const;
    intptr_t spareDrawingBufferCountForTesting() const;
    intptr_t volatileSpareDrawingBufferCountForTesting() const;
    void waitUntilWorkScheduled() const;
    // Retained, or null, as displayBufferSurface().
    IOSurfaceRef copySurfaceBuffer(uint8_t) const;
    void didPrepareForDisplay() const;
    void drawingBufferColorSpaceDidChange() const;
    bool readCompositedResults(GLLentMutableBytes, int32_t, int32_t) const;
    bool willPrepareForDisplay() const;
    static bool isDisplayInitializedForTesting(ANGLEDisplay);
#endif

#if defined(__APPLE__) && ENABLE(VIDEO)
    uint8_t copyVideoFrameToTexture(CVPixelBufferRef, uint8_t, GLuint, GLenum, GLint, GLenum, GLenum, bool, bool) const;
#endif
#if defined(__APPLE__) && ENABLE(WEBXR)
    bool enableRequiredWebXRExtensions() const;
#endif

    const uintptr_t shell;
};

}
