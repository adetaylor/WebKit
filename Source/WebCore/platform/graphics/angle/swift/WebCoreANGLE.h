/*
 * Copyright (C) 2019 Google Inc. All rights reserved.
 * Copyright (C) 2020 Sony Interactive Entertainment Inc.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE AND ITS CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * Copyright (C) 2009-2021 Apple Inc. All rights reserved.
 * Copyright (C) 2010, 2013 Apple Inc. All rights reserved.
 * Copyright (C) 2019 Google Inc. All rights reserved.
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

#pragma once

// ANGLE's GL and EGL entry points, as the clang module WebCoreANGLE, for the WebGL island's Swift. ANGLE is treated as
// a system API. struct ANGLE holds the shims for the entry points that Swift can't call safely as they are: integers
// that ANGLE takes as pointers, pointers with implied sizes, single values returned through pointers, EGL's pointer
// handles, strings, and memory that C++ lends Swift (GLLentMemory.h). Each shim's only obligation is that ANGLE reads
// or writes no more than the memory it is given.

// Included before ANGLE's headers, which include it inside extern "C", where importing <stdint.h>'s module warns.
#include <ANGLE/khrplatform.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <string>
#include <vector>
#include <string_view>
#include <wtf/Assertions.h>
#include <wtf/StdLibExtras.h>

#ifndef EGL_EGLEXT_PROTOTYPES
#define EGL_EGLEXT_PROTOTYPES 0
#endif
#ifndef EGL_EGL_PROTOTYPES
#define EGL_EGL_PROTOTYPES 0
#endif
#ifndef GL_GLES_PROTOTYPES
#define GL_GLES_PROTOTYPES 0
#endif
#ifndef GL_GLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES 0
#endif
#define EGL_NO_PLATFORM_SPECIFIC_TYPES

#include <ANGLE/entry_points_egl_autogen.h>
#include <ANGLE/entry_points_egl_ext_autogen.h>
#include <ANGLE/entry_points_gles_2_0_autogen.h>
#include <ANGLE/entry_points_gles_3_0_autogen.h>
#include <ANGLE/entry_points_gles_ext_autogen.h>

#include "GLLentMemory.h"

// An EGL handle as a value Swift can hold. Swift sees EGL's handles as unsafe pointers; only C++ makes these, and EGL
// validates every handle it is given.
template<typename Tag>
class ANGLEHandle {
public:
    ANGLEHandle() = default;
    bool isNull() const { return !m_bits; }
    bool operator==(const ANGLEHandle&) const = default;

private:
    friend struct ANGLE;
    friend class ANGLEHandles;

    explicit ANGLEHandle(void* handle)
        : m_bits(reinterpret_cast<uintptr_t>(handle))
    {
    }
    void* get() const { return reinterpret_cast<void*>(m_bits); }

    uintptr_t m_bits { 0 };
};

struct ANGLEDisplayTag;
struct ANGLEConfigTag;
struct ANGLEContextTag;
struct ANGLEImageTag;
struct ANGLESyncTag;
using ANGLEDisplay = ANGLEHandle<ANGLEDisplayTag>;
using ANGLEConfig = ANGLEHandle<ANGLEConfigTag>;
using ANGLEContext = ANGLEHandle<ANGLEContextTag>;
using ANGLEImage = ANGLEHandle<ANGLEImageTag>;
using ANGLEEGLSync = ANGLEHandle<ANGLESyncTag>;

#if !defined(__swift__)
// For the C++ that makes and uses the handles it gives the island.
class ANGLEHandles {
public:
    template<typename Tag> static ANGLEHandle<Tag> wrap(void* handle) { return ANGLEHandle<Tag> { handle }; }
    template<typename Tag> static void* unwrap(ANGLEHandle<Tag> handle) { return handle.get(); }
};
#endif

struct ANGLEInt2 {
    GLint x { 0 };
    GLint y { 0 };
};

struct ANGLEFloat4 {
    GLfloat values[4] { };
};

struct ANGLEInt4 {
    GLint values[4] { };
};

struct ANGLEUnsignedInt4 {
    GLuint values[4] { };
};

// Structs that Swift returns to C++ have a size that is a multiple of 8 for Swift interop, rdar://191583570.
struct alignas(8) ANGLEShaderPrecisionFormat {
    GLint rangeMin { 0 };
    GLint rangeMax { 0 };
    GLint precision { 0 };
    // False when the context couldn't be made current, and nothing was queried.
    bool queried { false };
};

struct ANGLEReadPixelsResult {
    GLsizei columns { 0 };
    GLsizei rows { 0 };
};

struct ANGLEActiveVariable {
    std::string name;
    GLint size { 0 };
    GLenum type { 0 };
};

// The size and type of an active variable, and the length of its name, which went into lent bytes. length is 0 if
// there was none, or it didn't fit.
struct ANGLEActiveName {
    GLint size { 0 };
    GLenum type { 0 };
    GLsizei length { 0 };
};

enum class ANGLEBufferReadResult : uint8_t {
    MapFailed,
    Read,
    ReadButUnmapFailed,
};

// Values the rest of WebCore's C++ uses for the EGL handles of a context.
struct ANGLEContextHandles {
    ANGLEDisplay display;
    ANGLEConfig config;
    ANGLEContext context;
};

struct ANGLE final {
    ANGLE() = delete;

    // Creation and deletion, one name at a time.
    static GLuint genBuffer() { GLuint name = 0; GL_GenBuffers(1, &name); return name; }
    static GLuint genFramebuffer() { GLuint name = 0; GL_GenFramebuffers(1, &name); return name; }
    static GLuint genRenderbuffer() { GLuint name = 0; GL_GenRenderbuffers(1, &name); return name; }
    static GLuint genTexture() { GLuint name = 0; GL_GenTextures(1, &name); return name; }
    static GLuint genVertexArray() { GLuint name = 0; GL_GenVertexArrays(1, &name); return name; }
    static GLuint genVertexArrayOES() { GLuint name = 0; GL_GenVertexArraysOES(1, &name); return name; }
    static GLuint genQuery() { GLuint name = 0; GL_GenQueries(1, &name); return name; }
    static GLuint genQueryEXT() { GLuint name = 0; GL_GenQueriesEXT(1, &name); return name; }
    static GLuint genSampler() { GLuint name = 0; GL_GenSamplers(1, &name); return name; }
    static GLuint genTransformFeedback() { GLuint name = 0; GL_GenTransformFeedbacks(1, &name); return name; }
    static void deleteBuffer(GLuint name) { GL_DeleteBuffers(1, &name); }
    static void deleteFramebuffer(GLuint name) { GL_DeleteFramebuffers(1, &name); }
    static void deleteRenderbuffer(GLuint name) { GL_DeleteRenderbuffers(1, &name); }
    static void deleteTexture(GLuint name) { GL_DeleteTextures(1, &name); }
    static void deleteVertexArray(GLuint name) { GL_DeleteVertexArrays(1, &name); }
    static void deleteVertexArrayOES(GLuint name) { GL_DeleteVertexArraysOES(1, &name); }
    static void deleteQuery(GLuint name) { GL_DeleteQueries(1, &name); }
    static void deleteQueryEXT(GLuint name) { GL_DeleteQueriesEXT(1, &name); }
    static void deleteSampler(GLuint name) { GL_DeleteSamplers(1, &name); }
    static void deleteTransformFeedback(GLuint name) { GL_DeleteTransformFeedbacks(1, &name); }

    // Single-value queries, through the Robust entry points.
    static GLint getInteger(GLenum pname) { GLint value = 0; GL_GetIntegervRobustANGLE(pname, 1, nullptr, &value); return value; }
    static ANGLEInt2 getInteger2(GLenum pname) { GLint values[2] { }; GL_GetIntegervRobustANGLE(pname, 2, nullptr, values); return { values[0], values[1] }; }
    static GLint64 getInteger64(GLenum pname) { GLint64 value = 0; GL_GetInteger64vRobustANGLE(pname, 1, nullptr, &value); return value; }
    static GLint64 getInteger64i(GLenum pname, GLuint index) { GLint64 value = 0; GL_GetInteger64i_vRobustANGLE(pname, index, 1, nullptr, &value); return value; }
    static GLint getBufferParameteri(GLenum target, GLenum pname) { GLint value = 0; GL_GetBufferParameterivRobustANGLE(target, pname, 1, nullptr, &value); return value; }
    static GLint getFramebufferAttachmentParameteri(GLenum target, GLenum attachment, GLenum pname) { GLint value = 0; GL_GetFramebufferAttachmentParameterivRobustANGLE(target, attachment, pname, 1, nullptr, &value); return value; }
    static GLint getProgrami(GLuint program, GLenum pname) { GLint value = 0; GL_GetProgramivRobustANGLE(program, pname, 1, nullptr, &value); return value; }
    static GLint getRenderbufferParameteri(GLenum target, GLenum pname) { GLint value = 0; GL_GetRenderbufferParameterivRobustANGLE(target, pname, 1, nullptr, &value); return value; }
    static GLint getShaderi(GLuint shader, GLenum pname) { GLint value = 0; GL_GetShaderivRobustANGLE(shader, pname, 1, nullptr, &value); return value; }
    static GLfloat getTexParameterf(GLenum target, GLenum pname) { GLfloat value = 0; GL_GetTexParameterfvRobustANGLE(target, pname, 1, nullptr, &value); return value; }
    static GLint getTexParameteri(GLenum target, GLenum pname) { GLint value = 0; GL_GetTexParameterivRobustANGLE(target, pname, 1, nullptr, &value); return value; }
    static GLint getQueryi(GLenum target, GLenum pname) { GLint value = 0; GL_GetQueryivRobustANGLE(target, pname, 1, nullptr, &value); return value; }
    static GLuint getQueryObjectui(GLuint query, GLenum pname) { GLuint value = 0; GL_GetQueryObjectuivRobustANGLE(query, pname, 1, nullptr, &value); return value; }
    static GLint getQueryObjecti(GLuint query, GLenum pname) { GLint value = 0; GL_GetQueryObjectivRobustANGLE(query, pname, 1, nullptr, &value); return value; }
    static GLuint64 getQueryObjectui64(GLuint query, GLenum pname) { GLuint64 value = 0; GL_GetQueryObjectui64vRobustANGLE(query, pname, 1, nullptr, &value); return value; }
    static GLfloat getSamplerParameterf(GLuint sampler, GLenum pname) { GLfloat value = 0; GL_GetSamplerParameterfvRobustANGLE(sampler, pname, 1, nullptr, &value); return value; }
    static GLint getSamplerParameteri(GLuint sampler, GLenum pname) { GLint value = 0; GL_GetSamplerParameterivRobustANGLE(sampler, pname, 1, nullptr, &value); return value; }
    static GLint getActiveUniformi(GLuint program, GLuint index, GLenum pname) { GLint value = -1; GL_GetActiveUniformsiv(program, 1, &index, pname, &value); return value; }
    static GLintptr getVertexAttribOffset(GLuint index, GLenum pname)
    {
        void* pointer = nullptr;
        GL_GetVertexAttribPointervRobustANGLE(index, pname, 1, nullptr, &pointer);
        return reinterpret_cast<GLintptr>(pointer);
    }
    static ANGLEShaderPrecisionFormat getShaderPrecisionFormat(GLenum shaderType, GLenum precisionType)
    {
        GLint range[2] { };
        GLint precision = 0;
        GL_GetShaderPrecisionFormat(shaderType, precisionType, range, &precision);
        return { range[0], range[1], precision, true };
    }

    // Queries into lent memory. bufSize is in elements, except for GetUniform*, where ANGLE takes bytes.
    static void getBooleanv(GLenum pname, WebCore::GLLentMutableBytes values) { auto span = values.span(); GL_GetBooleanvRobustANGLE(pname, sizeFor(span), nullptr, span.data()); }
    static void getFloatv(GLenum pname, WebCore::GLLentMutableFloats values) { auto span = values.span(); GL_GetFloatvRobustANGLE(pname, sizeFor(span), nullptr, span.data()); }
    static void getIntegerv(GLenum pname, WebCore::GLLentMutableInts values) { auto span = values.span(); GL_GetIntegervRobustANGLE(pname, sizeFor(span), nullptr, span.data()); }
    static void getIntegeri_v(GLenum pname, GLuint index, WebCore::GLLentMutableInts values) { auto span = values.span(); GL_GetIntegeri_vRobustANGLE(pname, index, sizeFor(span), nullptr, span.data()); }
    static void getInternalformativ(GLenum target, GLenum internalFormat, GLenum pname, WebCore::GLLentMutableInts values) { auto span = values.span(); GL_GetInternalformativRobustANGLE(target, internalFormat, pname, sizeFor(span), nullptr, span.data()); }
    static void getActiveUniformBlockiv(GLuint program, GLuint uniformBlockIndex, GLenum pname, WebCore::GLLentMutableInts values) { auto span = values.span(); GL_GetActiveUniformBlockivRobustANGLE(program, uniformBlockIndex, pname, sizeFor(span), nullptr, span.data()); }
    static void getUniformfv(GLuint program, GLint location, WebCore::GLLentMutableFloats values) { auto span = values.span(); GL_GetUniformfvRobustANGLE(program, location, bytesFor(span), nullptr, span.data()); }
    static void getUniformiv(GLuint program, GLint location, WebCore::GLLentMutableInts values) { auto span = values.span(); GL_GetUniformivRobustANGLE(program, location, bytesFor(span), nullptr, span.data()); }
    static void getUniformuiv(GLuint program, GLint location, WebCore::GLLentMutableUnsignedInts values) { auto span = values.span(); GL_GetUniformuivRobustANGLE(program, location, bytesFor(span), nullptr, span.data()); }

    static ANGLEReadPixelsResult readPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, WebCore::GLLentMutableBytes pixels)
    {
        auto span = pixels.span();
        ANGLEReadPixelsResult result;
        GL_ReadPixelsRobustANGLE(x, y, width, height, format, type, sizeFor(span), nullptr, &result.columns, &result.rows, span.data());
        return result;
    }

    // Reads the mapped range of the buffer bound to target into data, through MapBufferRange, which maps no more than
    // the length asked for.
    static ANGLEBufferReadResult getBufferSubData(GLenum target, GLintptr offset, WebCore::GLLentMutableBytes data)
    {
        auto span = data.span();
        void* mapped = GL_MapBufferRange(target, offset, static_cast<GLsizeiptr>(span.size()), GL_MAP_READ_BIT);
        if (!mapped)
            return ANGLEBufferReadResult::MapFailed;
        memcpySpan(span, unsafeMakeSpan(static_cast<const uint8_t*>(mapped), span.size()));
        return GL_UnmapBuffer(target) ? ANGLEBufferReadResult::Read : ANGLEBufferReadResult::ReadButUnmapFailed;
    }

    // Data from lent memory. The sizes ANGLE sees are the spans' sizes.
    static void bufferData(GLenum target, WebCore::GLLentBytes data, GLenum usage) { auto span = data.span(); GL_BufferData(target, static_cast<GLsizeiptr>(span.size()), span.data(), usage); }
    static void bufferDataUninitialized(GLenum target, GLsizeiptr size, GLenum usage) { GL_BufferData(target, size, nullptr, usage); }
    static void bufferSubData(GLenum target, GLintptr offset, WebCore::GLLentBytes data) { auto span = data.span(); GL_BufferSubData(target, offset, static_cast<GLsizeiptr>(span.size()), span.data()); }
    static void texImage2D(GLenum target, GLint level, GLint internalFormat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, WebCore::GLLentBytes pixels) { auto span = pixels.span(); GL_TexImage2DRobustANGLE(target, level, internalFormat, width, height, border, format, type, sizeFor(span), span.data()); }
    static void texSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, WebCore::GLLentBytes pixels) { auto span = pixels.span(); GL_TexSubImage2DRobustANGLE(target, level, xoffset, yoffset, width, height, format, type, sizeFor(span), span.data()); }
    static void texImage3D(GLenum target, GLint level, GLint internalFormat, GLsizei width, GLsizei height, GLsizei depth, GLint border, GLenum format, GLenum type, WebCore::GLLentBytes pixels) { auto span = pixels.span(); GL_TexImage3DRobustANGLE(target, level, internalFormat, width, height, depth, border, format, type, sizeFor(span), span.data()); }
    static void texSubImage3D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, WebCore::GLLentBytes pixels) { auto span = pixels.span(); GL_TexSubImage3DRobustANGLE(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, sizeFor(span), span.data()); }
    static void compressedTexImage2D(GLenum target, GLint level, GLenum internalFormat, GLsizei width, GLsizei height, GLint border, WebCore::GLLentBytes data) { auto span = data.span(); GL_CompressedTexImage2D(target, level, internalFormat, width, height, border, sizeFor(span), span.data()); }
    static void compressedTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, WebCore::GLLentBytes data) { auto span = data.span(); GL_CompressedTexSubImage2D(target, level, xoffset, yoffset, width, height, format, sizeFor(span), span.data()); }
    static void compressedTexImage3D(GLenum target, GLint level, GLenum internalFormat, GLsizei width, GLsizei height, GLsizei depth, GLint border, WebCore::GLLentBytes data) { auto span = data.span(); GL_CompressedTexImage3D(target, level, internalFormat, width, height, depth, border, sizeFor(span), span.data()); }
    static void compressedTexSubImage3D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, WebCore::GLLentBytes data) { auto span = data.span(); GL_CompressedTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, sizeFor(span), span.data()); }

    // Uploads from the bound pixel unpack buffer at an offset. Each returns false, and uploads nothing, when no buffer
    // is bound, because ANGLE would then read the offset as an address.
    static bool texImage2DFromUnpackBuffer(GLenum target, GLint level, GLint internalFormat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, GLintptr offset)
    {
        if (!hasBoundBuffer(GL_PIXEL_UNPACK_BUFFER_BINDING))
            return false;
        GL_TexImage2DRobustANGLE(target, level, internalFormat, width, height, border, format, type, 0, reinterpret_cast<const void*>(offset));
        return true;
    }
    static bool texSubImage2DFromUnpackBuffer(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, GLintptr offset)
    {
        if (!hasBoundBuffer(GL_PIXEL_UNPACK_BUFFER_BINDING))
            return false;
        GL_TexSubImage2DRobustANGLE(target, level, xoffset, yoffset, width, height, format, type, 0, reinterpret_cast<const void*>(offset));
        return true;
    }
    static bool texImage3DFromUnpackBuffer(GLenum target, GLint level, GLint internalFormat, GLsizei width, GLsizei height, GLsizei depth, GLint border, GLenum format, GLenum type, GLintptr offset)
    {
        if (!hasBoundBuffer(GL_PIXEL_UNPACK_BUFFER_BINDING))
            return false;
        GL_TexImage3DRobustANGLE(target, level, internalFormat, width, height, depth, border, format, type, 0, reinterpret_cast<const void*>(offset));
        return true;
    }
    static bool texSubImage3DFromUnpackBuffer(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, GLintptr offset)
    {
        if (!hasBoundBuffer(GL_PIXEL_UNPACK_BUFFER_BINDING))
            return false;
        GL_TexSubImage3DRobustANGLE(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, 0, reinterpret_cast<const void*>(offset));
        return true;
    }
    static bool compressedTexImage2DFromUnpackBuffer(GLenum target, GLint level, GLenum internalFormat, GLsizei width, GLsizei height, GLint border, GLsizei imageSize, GLintptr offset)
    {
        if (!hasBoundBuffer(GL_PIXEL_UNPACK_BUFFER_BINDING))
            return false;
        GL_CompressedTexImage2D(target, level, internalFormat, width, height, border, imageSize, reinterpret_cast<const void*>(offset));
        return true;
    }
    static bool compressedTexSubImage2DFromUnpackBuffer(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLsizei imageSize, GLintptr offset)
    {
        if (!hasBoundBuffer(GL_PIXEL_UNPACK_BUFFER_BINDING))
            return false;
        GL_CompressedTexSubImage2D(target, level, xoffset, yoffset, width, height, format, imageSize, reinterpret_cast<const void*>(offset));
        return true;
    }
    static bool compressedTexImage3DFromUnpackBuffer(GLenum target, GLint level, GLenum internalFormat, GLsizei width, GLsizei height, GLsizei depth, GLint border, GLsizei imageSize, GLintptr offset)
    {
        if (!hasBoundBuffer(GL_PIXEL_UNPACK_BUFFER_BINDING))
            return false;
        GL_CompressedTexImage3D(target, level, internalFormat, width, height, depth, border, imageSize, reinterpret_cast<const void*>(offset));
        return true;
    }
    static bool compressedTexSubImage3DFromUnpackBuffer(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLsizei imageSize, GLintptr offset)
    {
        if (!hasBoundBuffer(GL_PIXEL_UNPACK_BUFFER_BINDING))
            return false;
        GL_CompressedTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, imageSize, reinterpret_cast<const void*>(offset));
        return true;
    }
    // Reads into the bound pixel pack buffer at an offset. ANGLE checks the read against the buffer's size.
    static bool readPixelsIntoPackBuffer(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, GLintptr offset)
    {
        if (!hasBoundBuffer(GL_PIXEL_PACK_BUFFER_BINDING))
            return false;
        GL_ReadPixelsRobustANGLE(x, y, width, height, format, type, std::numeric_limits<GLsizei>::max(), nullptr, nullptr, nullptr, reinterpret_cast<void*>(offset));
        return true;
    }

    // Uniform arrays: count elements of n values each, which the span must hold.
    static void uniform1fv(GLint location, GLsizei count, WebCore::GLLentFloats v) { GL_Uniform1fv(location, count, elements(v, count, 1)); }
    static void uniform2fv(GLint location, GLsizei count, WebCore::GLLentFloats v) { GL_Uniform2fv(location, count, elements(v, count, 2)); }
    static void uniform3fv(GLint location, GLsizei count, WebCore::GLLentFloats v) { GL_Uniform3fv(location, count, elements(v, count, 3)); }
    static void uniform4fv(GLint location, GLsizei count, WebCore::GLLentFloats v) { GL_Uniform4fv(location, count, elements(v, count, 4)); }
    static void uniform1iv(GLint location, GLsizei count, WebCore::GLLentInts v) { GL_Uniform1iv(location, count, elements(v, count, 1)); }
    static void uniform2iv(GLint location, GLsizei count, WebCore::GLLentInts v) { GL_Uniform2iv(location, count, elements(v, count, 2)); }
    static void uniform3iv(GLint location, GLsizei count, WebCore::GLLentInts v) { GL_Uniform3iv(location, count, elements(v, count, 3)); }
    static void uniform4iv(GLint location, GLsizei count, WebCore::GLLentInts v) { GL_Uniform4iv(location, count, elements(v, count, 4)); }
    static void uniform1uiv(GLint location, GLsizei count, WebCore::GLLentUnsignedInts v) { GL_Uniform1uiv(location, count, elements(v, count, 1)); }
    static void uniform2uiv(GLint location, GLsizei count, WebCore::GLLentUnsignedInts v) { GL_Uniform2uiv(location, count, elements(v, count, 2)); }
    static void uniform3uiv(GLint location, GLsizei count, WebCore::GLLentUnsignedInts v) { GL_Uniform3uiv(location, count, elements(v, count, 3)); }
    static void uniform4uiv(GLint location, GLsizei count, WebCore::GLLentUnsignedInts v) { GL_Uniform4uiv(location, count, elements(v, count, 4)); }
    static void uniformMatrix2fv(GLint location, GLsizei count, GLboolean transpose, WebCore::GLLentFloats v) { GL_UniformMatrix2fv(location, count, transpose, elements(v, count, 4)); }
    static void uniformMatrix3fv(GLint location, GLsizei count, GLboolean transpose, WebCore::GLLentFloats v) { GL_UniformMatrix3fv(location, count, transpose, elements(v, count, 9)); }
    static void uniformMatrix4fv(GLint location, GLsizei count, GLboolean transpose, WebCore::GLLentFloats v) { GL_UniformMatrix4fv(location, count, transpose, elements(v, count, 16)); }
    static void uniformMatrix2x3fv(GLint location, GLsizei count, GLboolean transpose, WebCore::GLLentFloats v) { GL_UniformMatrix2x3fv(location, count, transpose, elements(v, count, 6)); }
    static void uniformMatrix3x2fv(GLint location, GLsizei count, GLboolean transpose, WebCore::GLLentFloats v) { GL_UniformMatrix3x2fv(location, count, transpose, elements(v, count, 6)); }
    static void uniformMatrix2x4fv(GLint location, GLsizei count, GLboolean transpose, WebCore::GLLentFloats v) { GL_UniformMatrix2x4fv(location, count, transpose, elements(v, count, 8)); }
    static void uniformMatrix4x2fv(GLint location, GLsizei count, GLboolean transpose, WebCore::GLLentFloats v) { GL_UniformMatrix4x2fv(location, count, transpose, elements(v, count, 8)); }
    static void uniformMatrix3x4fv(GLint location, GLsizei count, GLboolean transpose, WebCore::GLLentFloats v) { GL_UniformMatrix3x4fv(location, count, transpose, elements(v, count, 12)); }
    static void uniformMatrix4x3fv(GLint location, GLsizei count, GLboolean transpose, WebCore::GLLentFloats v) { GL_UniformMatrix4x3fv(location, count, transpose, elements(v, count, 12)); }

    // Fixed-size values, by value.
    static void vertexAttrib1fv(GLuint index, ANGLEFloat4 v) { GL_VertexAttrib1fv(index, v.values); }
    static void vertexAttrib2fv(GLuint index, ANGLEFloat4 v) { GL_VertexAttrib2fv(index, v.values); }
    static void vertexAttrib3fv(GLuint index, ANGLEFloat4 v) { GL_VertexAttrib3fv(index, v.values); }
    static void vertexAttrib4fv(GLuint index, ANGLEFloat4 v) { GL_VertexAttrib4fv(index, v.values); }
    static void vertexAttribI4iv(GLuint index, ANGLEInt4 v) { GL_VertexAttribI4iv(index, v.values); }
    static void vertexAttribI4uiv(GLuint index, ANGLEUnsignedInt4 v) { GL_VertexAttribI4uiv(index, v.values); }

    // ClearBuffer reads four values of a colour buffer and one of depth or stencil, and has no size argument.
    static void clearBufferiv(GLenum buffer, GLint drawbuffer, WebCore::GLLentInts values) { GL_ClearBufferiv(buffer, drawbuffer, elements(values, 1, clearBufferValueCount(buffer))); }
    static void clearBufferuiv(GLenum buffer, GLint drawbuffer, WebCore::GLLentUnsignedInts values) { GL_ClearBufferuiv(buffer, drawbuffer, elements(values, 1, clearBufferValueCount(buffer))); }
    static void clearBufferfv(GLenum buffer, GLint drawbuffer, WebCore::GLLentFloats values) { GL_ClearBufferfv(buffer, drawbuffer, elements(values, 1, clearBufferValueCount(buffer))); }

    // Enum lists.
    static void drawBuffers(WebCore::GLLentUnsignedInts buffers) { auto span = buffers.span(); GL_DrawBuffers(sizeFor(span), span.data()); }
    static void drawBuffersEXT(WebCore::GLLentUnsignedInts buffers) { auto span = buffers.span(); GL_DrawBuffersEXT(sizeFor(span), span.data()); }
    static void invalidateFramebuffer(GLenum target, WebCore::GLLentUnsignedInts attachments) { auto span = attachments.span(); GL_InvalidateFramebuffer(target, sizeFor(span), span.data()); }
    static void invalidateSubFramebuffer(GLenum target, WebCore::GLLentUnsignedInts attachments, GLint x, GLint y, GLsizei width, GLsizei height) { auto span = attachments.span(); GL_InvalidateSubFramebuffer(target, sizeFor(span), span.data(), x, y, width, height); }
    static void discardFramebufferEXT(GLenum target, WebCore::GLLentUnsignedInts attachments) { auto span = attachments.span(); GL_DiscardFramebufferEXT(target, sizeFor(span), span.data()); }

    // Integers that ANGLE takes as pointers. The context is created for WebGL, without client arrays, so ANGLE reads
    // them as offsets into the bound buffers, never as addresses.
    static void drawElements(GLenum mode, GLsizei count, GLenum type, GLintptr offset) { GL_DrawElements(mode, count, type, reinterpret_cast<const void*>(offset)); }
    static void drawElementsInstanced(GLenum mode, GLsizei count, GLenum type, GLintptr offset, GLsizei instanceCount) { GL_DrawElementsInstanced(mode, count, type, reinterpret_cast<const void*>(offset), instanceCount); }
    static void drawElementsInstancedANGLE(GLenum mode, GLsizei count, GLenum type, GLintptr offset, GLsizei instanceCount) { GL_DrawElementsInstancedANGLE(mode, count, type, reinterpret_cast<const void*>(offset), instanceCount); }
    static void drawElementsInstancedBaseVertexBaseInstanceANGLE(GLenum mode, GLsizei count, GLenum type, GLintptr offset, GLsizei instanceCount, GLint baseVertex, GLuint baseInstance) { GL_DrawElementsInstancedBaseVertexBaseInstanceANGLE(mode, count, type, reinterpret_cast<const void*>(offset), instanceCount, baseVertex, baseInstance); }
    static void drawRangeElements(GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type, GLintptr offset) { GL_DrawRangeElements(mode, start, end, count, type, reinterpret_cast<const void*>(offset)); }
    static void vertexAttribPointer(GLuint index, GLint size, GLenum type, GLboolean normalized, GLsizei stride, GLintptr offset) { GL_VertexAttribPointer(index, size, type, normalized, stride, reinterpret_cast<const void*>(offset)); }
    static void vertexAttribIPointer(GLuint index, GLint size, GLenum type, GLsizei stride, GLintptr offset) { GL_VertexAttribIPointer(index, size, type, stride, reinterpret_cast<const void*>(offset)); }

    // Multi-draws: drawCount elements of each array, which every span must hold.
    static void multiDrawArraysANGLE(GLenum mode, WebCore::GLLentInts firsts, WebCore::GLLentInts counts, GLsizei drawCount)
    {
        GL_MultiDrawArraysANGLE(mode, elements(firsts, drawCount, 1), elements(counts, drawCount, 1), drawCount);
    }
    static void multiDrawArraysInstancedANGLE(GLenum mode, WebCore::GLLentInts firsts, WebCore::GLLentInts counts, WebCore::GLLentInts instanceCounts, GLsizei drawCount)
    {
        GL_MultiDrawArraysInstancedANGLE(mode, elements(firsts, drawCount, 1), elements(counts, drawCount, 1), elements(instanceCounts, drawCount, 1), drawCount);
    }
    static void multiDrawArraysInstancedBaseInstanceANGLE(GLenum mode, WebCore::GLLentInts firsts, WebCore::GLLentInts counts, WebCore::GLLentInts instanceCounts, WebCore::GLLentUnsignedInts baseInstances, GLsizei drawCount)
    {
        GL_MultiDrawArraysInstancedBaseInstanceANGLE(mode, elements(firsts, drawCount, 1), elements(counts, drawCount, 1), elements(instanceCounts, drawCount, 1), elements(baseInstances, drawCount, 1), drawCount);
    }
    static void multiDrawElementsANGLE(GLenum mode, WebCore::GLLentInts counts, GLenum type, WebCore::GLLentInts offsets, GLsizei drawCount)
    {
        auto offsetPointers = asOffsets(offsets, drawCount);
        GL_MultiDrawElementsANGLE(mode, elements(counts, drawCount, 1), type, offsetPointers.data(), drawCount);
    }
    static void multiDrawElementsInstancedANGLE(GLenum mode, WebCore::GLLentInts counts, GLenum type, WebCore::GLLentInts offsets, WebCore::GLLentInts instanceCounts, GLsizei drawCount)
    {
        auto offsetPointers = asOffsets(offsets, drawCount);
        GL_MultiDrawElementsInstancedANGLE(mode, elements(counts, drawCount, 1), type, offsetPointers.data(), elements(instanceCounts, drawCount, 1), drawCount);
    }
    static void multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(GLenum mode, WebCore::GLLentInts counts, GLenum type, WebCore::GLLentInts offsets, WebCore::GLLentInts instanceCounts, WebCore::GLLentInts baseVertices, WebCore::GLLentUnsignedInts baseInstances, GLsizei drawCount)
    {
        auto offsetPointers = asOffsets(offsets, drawCount);
        GL_MultiDrawElementsInstancedBaseVertexBaseInstanceANGLE(mode, elements(counts, drawCount, 1), type, offsetPointers.data(), elements(instanceCounts, drawCount, 1), elements(baseVertices, drawCount, 1), elements(baseInstances, drawCount, 1), drawCount);
    }

    // Strings in. Lent strings include their NUL terminator; an empty one is a null string.
    static void shaderSource(GLuint shader, WebCore::GLLentBytes source)
    {
        auto string = cString(source);
        GLint length = string ? static_cast<GLint>(source.size() - 1) : 0;
        GL_ShaderSource(shader, 1, &string, &length);
    }
    static void bindAttribLocation(GLuint program, GLuint index, WebCore::GLLentBytes name) { GL_BindAttribLocation(program, index, cString(name)); }
    static GLint getUniformLocation(GLuint program, WebCore::GLLentBytes name) { return GL_GetUniformLocation(program, cString(name)); }
    static GLint getFragDataLocation(GLuint program, WebCore::GLLentBytes name) { return GL_GetFragDataLocation(program, cString(name)); }
    static GLuint getUniformBlockIndex(GLuint program, WebCore::GLLentBytes name) { return GL_GetUniformBlockIndex(program, cString(name)); }
    static void transformFeedbackVaryings(GLuint program, WebCore::GLLentCStrings varyings, GLenum bufferMode)
    {
        auto span = varyings.span();
        GL_TransformFeedbackVaryings(program, sizeFor(span), span.data(), bufferMode);
    }
    static GLint getUniformLocation(GLuint program, const std::string& name) { return GL_GetUniformLocation(program, name.c_str()); }
    static GLint getAttribLocation(GLuint program, const std::string& name) { return GL_GetAttribLocation(program, name.c_str()); }
    static void requestExtension(const std::string& name) { GL_RequestExtensionANGLE(name.c_str()); }

    // Strings out.
    static std::string getString(GLenum name)
    {
        auto* string = reinterpret_cast<const char*>(GL_GetString(name));
        return string ? std::string { string } : std::string { };
    }
    static std::string copyString(WebCore::GLLentBytes string)
    {
        auto* characters = cString(string);
        return characters ? std::string { characters } : std::string { };
    }
    static std::string copyString(WebCore::GLLentCStrings strings, size_t index)
    {
        auto span = strings.span();
        RELEASE_ASSERT(index < span.size());
        return span[index] ? std::string { span[index] } : std::string { };
    }
    static size_t copyString(const std::string& string, WebCore::GLLentMutableBytes destination)
    {
        auto span = destination.span();
        size_t length = std::min(string.size(), span.size());
        memcpySpan(span.first(length), asBytes(std::span<const char> { string }).first(length));
        return length;
    }
    static ptrdiff_t stringLength(GLenum name)
    {
        auto* string = reinterpret_cast<const char*>(GL_GetString(name));
        return string ? static_cast<ptrdiff_t>(std::string_view { string }.size()) : -1;
    }
    // Copies as much of a GL string as fits. Returns its whole length, or -1 if it is null.
    static ptrdiff_t copyString(GLenum name, WebCore::GLLentMutableBytes destination)
    {
        auto* string = reinterpret_cast<const char*>(GL_GetString(name));
        if (!string)
            return -1;
        std::string_view view { string };
        auto span = destination.span();
        size_t length = std::min(view.size(), span.size());
        memcpySpan(span.first(length), asBytes(std::span<const char> { view }).first(length));
        return static_cast<ptrdiff_t>(view.size());
    }
    // Info logs and names into lent memory, returning the length ANGLE wrote, without the NUL.
    static GLsizei getProgramInfoLog(GLuint program, WebCore::GLLentMutableBytes log) { auto span = log.span(); GLsizei length = 0; GL_GetProgramInfoLog(program, sizeFor(span), &length, reinterpret_cast<GLchar*>(span.data())); return length; }
    static GLsizei getShaderInfoLog(GLuint shader, WebCore::GLLentMutableBytes log) { auto span = log.span(); GLsizei length = 0; GL_GetShaderInfoLog(shader, sizeFor(span), &length, reinterpret_cast<GLchar*>(span.data())); return length; }
    static GLsizei getTranslatedShaderSource(GLuint shader, WebCore::GLLentMutableBytes source) { auto span = source.span(); GLsizei length = 0; GL_GetTranslatedShaderSourceANGLE(shader, sizeFor(span), &length, reinterpret_cast<GLchar*>(span.data())); return length; }
    static GLsizei getActiveUniformBlockName(GLuint program, GLuint index, WebCore::GLLentMutableBytes name) { auto span = name.span(); GLsizei length = 0; GL_GetActiveUniformBlockName(program, index, sizeFor(span), &length, reinterpret_cast<GLchar*>(span.data())); return length; }
    // name is written only when length is nonzero.
    static ANGLEActiveVariable getTransformFeedbackVarying(GLuint program, GLuint index, GLsizei maxLength) { return activeVariable(GL_GetTransformFeedbackVarying, program, index, maxLength); }
    static ANGLEActiveVariable getActiveAttrib(GLuint program, GLuint index, GLsizei maxLength) { return activeVariable(GL_GetActiveAttrib, program, index, maxLength); }
    static ANGLEActiveName getActiveAttrib(GLuint program, GLuint index, WebCore::GLLentMutableBytes name) { return activeName(GL_GetActiveAttrib, program, index, name); }
    // The location of an attribute whose NUL-terminated name the lent bytes hold.
    static GLint getAttribLocation(GLuint program, WebCore::GLLentMutableBytes name)
    {
        auto span = name.span();
        RELEASE_ASSERT(std::ranges::find(span, 0) != span.end());
        return GL_GetAttribLocation(program, reinterpret_cast<const char*>(span.data()));
    }
    static ANGLEActiveVariable getActiveUniform(GLuint program, GLuint index, GLsizei maxLength) { return activeVariable(GL_GetActiveUniform, program, index, maxLength); }
    static ANGLEActiveName getActiveUniform(GLuint program, GLuint index, WebCore::GLLentMutableBytes name) { return activeName(GL_GetActiveUniform, program, index, name); }
    // The locations of a uniform that isn't in a block, whose name of nameLength the lent bytes hold, into the lent
    // ints: one per element of an array, whose name ends in "[0]". False if it doesn't.
    static bool getUniformLocations(GLuint program, WebCore::GLLentBytes name, GLint nameLength, WebCore::GLLentMutableInts locations)
    {
        auto span = name.span();
        RELEASE_ASSERT(nameLength >= 0 && static_cast<size_t>(nameLength) <= span.size());
        return uniformLocations(program, std::string_view { reinterpret_cast<const char*>(span.data()), static_cast<size_t>(nameLength) }, locations.span());
    }

    // GLsync values, which go to the web process and back as integers. ANGLE validates them.
    static uint64_t fenceSync(GLenum condition, GLbitfield flags) { return reinterpret_cast<uintptr_t>(GL_FenceSync(condition, flags)); }
    static GLboolean isSync(uint64_t sync) { return GL_IsSync(asSync(sync)); }
    static void deleteSync(uint64_t sync) { GL_DeleteSync(asSync(sync)); }
    static GLenum clientWaitSync(uint64_t sync, GLbitfield flags, GLuint64 timeout) { return GL_ClientWaitSync(asSync(sync), flags, timeout); }
    static void waitSync(uint64_t sync, GLbitfield flags, GLuint64 timeout) { GL_WaitSync(asSync(sync), flags, timeout); }
    static GLint getSynci(uint64_t sync, GLenum pname) { GLint value = 0; GL_GetSynciv(asSync(sync), pname, 1, nullptr, &value); return value; }

    // The debug messages of the current context go to the trampoline with contextID, which names the context without
    // pointing to it, so a message for a context that is gone finds nothing.
    static void setDebugMessageCallback(uint64_t contextID) { GL_DebugMessageCallbackKHR(debugMessageTrampoline, reinterpret_cast<const void*>(static_cast<uintptr_t>(contextID))); }
    static void debugMessageControl(GLenum source, GLenum type, GLenum severity, GLboolean enabled) { GL_DebugMessageControlKHR(source, type, severity, 0, nullptr, enabled); }

    // EGL.
    static bool makeCurrent(ANGLEDisplay display, ANGLEContext context) { return EGL_MakeCurrent(display.get(), EGL_NO_SURFACE, EGL_NO_SURFACE, context.get()); }
    static bool releaseCurrentContext(ANGLEDisplay display) { return EGL_MakeCurrent(display.get(), EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT); }
    static ANGLEDisplay currentDisplay() { return ANGLEDisplay { EGL_GetCurrentDisplay() }; }
    static bool terminate(ANGLEDisplay display) { return EGL_Terminate(display.get()); }
    static bool releaseThread() { return EGL_ReleaseThread(); }
    // ANGLE's estimate of the context's memory use, low word first.
    static bool queryContextMemoryUsage(ANGLEDisplay display, ANGLEContext context, uint64_t& usage)
    {
        EGLint words[2] { };
        if (!EGL_QueryContext(display.get(), context.get(), EGL_CONTEXT_MEMORY_USAGE_ANGLE, words))
            return false;
        usage = static_cast<uint32_t>(words[0]) | static_cast<uint64_t>(static_cast<uint32_t>(words[1])) << 32;
        return true;
    }
    static bool destroyImage(ANGLEDisplay display, ANGLEImage image) { return EGL_DestroyImageKHR(display.get(), image.get()); }
    static bool destroySync(ANGLEDisplay display, ANGLEEGLSync sync) { return EGL_DestroySync(display.get(), sync.get()); }
    static void imageTargetRenderbufferStorage(GLenum target, ANGLEImage image) { GL_EGLImageTargetRenderbufferStorageOES(target, image.get()); }
    static void imageTargetTexture2D(GLenum target, ANGLEImage image) { GL_EGLImageTargetTexture2DOES(target, image.get()); }

private:
    // Sizes past what a GLsizei holds wrap, as they always have: to a smaller size, or a negative one that ANGLE rejects.
    template<typename T> static GLsizei sizeFor(std::span<T> span) { return static_cast<GLsizei>(span.size()); }
    template<typename T> static GLsizei bytesFor(std::span<T> span) { return static_cast<GLsizei>(span.size_bytes()); }

    // The first count * n elements of a lent span, which must hold them.
    template<typename T>
    static T* elements(const WebCore::GLLent<T>& lent, GLsizei count, size_t n)
    {
        return elementSpan(lent, count, n).data();
    }

    // ANGLE reads nothing for a negative count, which it rejects.
    template<typename T>
    static std::span<T> elementSpan(const WebCore::GLLent<T>& lent, GLsizei count, size_t n)
    {
        auto span = lent.span();
        if (count < 0)
            return span.first(0);
        auto needed = static_cast<uint64_t>(count) * n;
        RELEASE_ASSERT(needed <= span.size());
        return span.first(static_cast<size_t>(needed));
    }

    // Whether a buffer is bound to a binding point, which C++ names here: a query of one value, so the plain entry point.
    static bool hasBoundBuffer(GLenum binding)
    {
        GLint buffer = 0;
        GL_GetIntegerv(binding, &buffer);
        return buffer;
    }

    static size_t clearBufferValueCount(GLenum buffer) { return buffer == GL_DEPTH || buffer == GL_STENCIL ? 1 : 4; }

    // Offsets as the pointers ANGLE takes them as: on the stack for up to 32 draws.
    class OffsetPointers {
    public:
        explicit OffsetPointers(std::span<const GLint> offsets)
        {
            if (offsets.size() > m_inline.size())
                m_heap.resize(offsets.size());
            auto pointers = m_heap.empty() ? std::span { m_inline }.first(offsets.size()) : std::span { m_heap };
            std::ranges::transform(offsets, pointers.begin(), [](GLint offset) {
                return reinterpret_cast<const void*>(static_cast<intptr_t>(offset));
            });
        }
        const void* const* data() const { return m_heap.empty() ? m_inline.data() : m_heap.data(); }

    private:
        std::array<const void*, 32> m_inline;
        std::vector<const void*> m_heap;
    };

    static OffsetPointers asOffsets(WebCore::GLLentInts offsets, GLsizei drawCount) { return OffsetPointers { elementSpan(offsets, drawCount, 1) }; }

    static const GLchar* cString(WebCore::GLLentBytes string)
    {
        auto span = string.span();
        if (span.empty())
            return nullptr;
        RELEASE_ASSERT(!span.back());
        return reinterpret_cast<const GLchar*>(span.data());
    }

    template<typename Function>
    static ANGLEActiveName activeName(Function function, GLuint program, GLuint index, WebCore::GLLentMutableBytes name)
    {
        auto span = name.span();
        ANGLEActiveName result;
        function(program, index, sizeFor(span), &result.length, &result.size, &result.type, reinterpret_cast<GLchar*>(span.data()));
        if (result.length < 0 || static_cast<size_t>(result.length) >= span.size())
            result.length = 0;
        return result;
    }

    static bool uniformLocations(GLuint program, std::string_view name, std::span<GLint> locations)
    {
        if (locations.empty())
            return true;
        std::string elementName { name };
        locations[0] = GL_GetUniformLocation(program, elementName.c_str());
        if (locations.size() == 1)
            return true;
        if (!name.ends_with("[0]"))
            return false;
        size_t baseLength = name.size() - 3;
        for (size_t index = 1; index < locations.size(); ++index) {
            elementName.resize(baseLength);
            elementName += '[';
            elementName += std::to_string(index);
            elementName += ']';
            locations[index] = GL_GetUniformLocation(program, elementName.c_str());
        }
        return true;
    }

    template<typename Function>
    static ANGLEActiveVariable activeVariable(Function function, GLuint program, GLuint index, GLsizei maxLength)
    {
        ANGLEActiveVariable result;
        if (maxLength < 0)
            maxLength = 0;
        std::string name(static_cast<size_t>(maxLength), '\0');
        GLsizei length = 0;
        function(program, index, maxLength, &length, &result.size, &result.type, name.data());
        name.resize(length > 0 ? static_cast<size_t>(std::min(length, maxLength)) : 0);
        result.name = std::move(name);
        return result;
    }

    static GLsync asSync(uint64_t sync) { return reinterpret_cast<GLsync>(static_cast<uintptr_t>(sync)); }

    static void GL_APIENTRY debugMessageTrampoline(GLenum source, GLenum type, GLuint messageID, GLenum severity, GLsizei length, const GLchar* message, const void* contextID);
};
