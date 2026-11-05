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

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
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
#endif

#if !defined(__swift__)
    static void addDebugMessage(uint64_t contextID, GLenum type, GLenum messageID, GLenum severity, std::span<const char8_t> message);
#endif
};

}
