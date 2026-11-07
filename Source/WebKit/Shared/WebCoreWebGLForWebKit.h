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

// What WebKit's Swift-generated C++ header needs of the WebGL island's, WebCoreWebGL's, which it includes this in place of
// (-clang-header-expose-module in PlatformCocoa.cmake): WebKit's Swift exposes to C++ a function that takes the island's
// GLContextHandoff inout, and its thunk passes it on as a pointer to its storage. The island's generated header would
// bring ANGLE's headers into every file that includes WebKit's. The storage of a GLContextHandoff is the struct itself,
// which GraphicsContextGLANGLE::islandHandoff() checks against the island's generated header.

namespace WebCoreWebGL {

class GLContextHandoff;

namespace _impl {

class _impl_GLContextHandoff {
public:
    static char* getOpaquePointer(GLContextHandoff& object) { return reinterpret_cast<char*>(&object); }
};

} // namespace _impl

} // namespace WebCoreWebGL
