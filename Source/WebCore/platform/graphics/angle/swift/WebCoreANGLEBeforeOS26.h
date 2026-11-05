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

// The old path of the WebGL island's entry points that take Swift arrays, for systems before OS 26, where Swift can't
// make a Span of an array: the arrays come as std::vectors. Delete it when WebKit's deployment target reaches OS 26.

#include "WebCoreANGLE.h"
#include <vector>

using ANGLEFloats = std::vector<GLfloat>;
using ANGLEInts = std::vector<GLint>;
using ANGLEUnsignedInts = std::vector<GLuint>;
using ANGLEBooleans = std::vector<GLboolean>;
using ANGLEBytes = std::vector<uint8_t>;

struct ANGLEBeforeOS26 final {
    ANGLEBeforeOS26() = delete;

    static void uniform1fv(GLint location, GLsizei count, const ANGLEFloats& value) { GL_Uniform1fv(location, count, elements(value, count, 1)); }
    static void uniform1iv(GLint location, GLsizei count, const ANGLEInts& value) { GL_Uniform1iv(location, count, elements(value, count, 1)); }
    static void uniform1uiv(GLint location, GLsizei count, const ANGLEUnsignedInts& value) { GL_Uniform1uiv(location, count, elements(value, count, 1)); }
    static void uniform2fv(GLint location, GLsizei count, const ANGLEFloats& value) { GL_Uniform2fv(location, count, elements(value, count, 2)); }
    static void uniform2iv(GLint location, GLsizei count, const ANGLEInts& value) { GL_Uniform2iv(location, count, elements(value, count, 2)); }
    static void uniform2uiv(GLint location, GLsizei count, const ANGLEUnsignedInts& value) { GL_Uniform2uiv(location, count, elements(value, count, 2)); }
    static void uniform3fv(GLint location, GLsizei count, const ANGLEFloats& value) { GL_Uniform3fv(location, count, elements(value, count, 3)); }
    static void uniform3iv(GLint location, GLsizei count, const ANGLEInts& value) { GL_Uniform3iv(location, count, elements(value, count, 3)); }
    static void uniform3uiv(GLint location, GLsizei count, const ANGLEUnsignedInts& value) { GL_Uniform3uiv(location, count, elements(value, count, 3)); }
    static void uniform4fv(GLint location, GLsizei count, const ANGLEFloats& value) { GL_Uniform4fv(location, count, elements(value, count, 4)); }
    static void uniform4iv(GLint location, GLsizei count, const ANGLEInts& value) { GL_Uniform4iv(location, count, elements(value, count, 4)); }
    static void uniform4uiv(GLint location, GLsizei count, const ANGLEUnsignedInts& value) { GL_Uniform4uiv(location, count, elements(value, count, 4)); }
    static void uniformMatrix2fv(GLint location, GLsizei count, GLboolean transpose, const ANGLEFloats& value) { GL_UniformMatrix2fv(location, count, transpose, elements(value, count, 4)); }
    static void uniformMatrix3fv(GLint location, GLsizei count, GLboolean transpose, const ANGLEFloats& value) { GL_UniformMatrix3fv(location, count, transpose, elements(value, count, 9)); }
    static void uniformMatrix4fv(GLint location, GLsizei count, GLboolean transpose, const ANGLEFloats& value) { GL_UniformMatrix4fv(location, count, transpose, elements(value, count, 16)); }
    static void uniformMatrix2x3fv(GLint location, GLsizei count, GLboolean transpose, const ANGLEFloats& value) { GL_UniformMatrix2x3fv(location, count, transpose, elements(value, count, 6)); }
    static void uniformMatrix3x2fv(GLint location, GLsizei count, GLboolean transpose, const ANGLEFloats& value) { GL_UniformMatrix3x2fv(location, count, transpose, elements(value, count, 6)); }
    static void uniformMatrix2x4fv(GLint location, GLsizei count, GLboolean transpose, const ANGLEFloats& value) { GL_UniformMatrix2x4fv(location, count, transpose, elements(value, count, 8)); }
    static void uniformMatrix4x2fv(GLint location, GLsizei count, GLboolean transpose, const ANGLEFloats& value) { GL_UniformMatrix4x2fv(location, count, transpose, elements(value, count, 8)); }
    static void uniformMatrix3x4fv(GLint location, GLsizei count, GLboolean transpose, const ANGLEFloats& value) { GL_UniformMatrix3x4fv(location, count, transpose, elements(value, count, 12)); }
    static void uniformMatrix4x3fv(GLint location, GLsizei count, GLboolean transpose, const ANGLEFloats& value) { GL_UniformMatrix4x3fv(location, count, transpose, elements(value, count, 12)); }
    static void drawBuffers(const ANGLEUnsignedInts& buffers) { GL_DrawBuffers(sizeFor(buffers), buffers.data()); }
    static void drawBuffersEXT(const ANGLEUnsignedInts& buffers) { GL_DrawBuffersEXT(sizeFor(buffers), buffers.data()); }
    static void invalidateFramebuffer(GLenum target, const ANGLEUnsignedInts& attachments) { GL_InvalidateFramebuffer(target, sizeFor(attachments), attachments.data()); }
    static void invalidateSubFramebuffer(GLenum target, const ANGLEUnsignedInts& attachments, GLint x, GLint y, GLsizei width, GLsizei height) { GL_InvalidateSubFramebuffer(target, sizeFor(attachments), attachments.data(), x, y, width, height); }
    static void framebufferDiscard(GLenum target, const ANGLEUnsignedInts& attachments) { GL_DiscardFramebufferEXT(target, sizeFor(attachments), attachments.data()); }
    static void multiDrawArraysANGLE(GLenum mode, const ANGLEInts& firsts, const ANGLEInts& counts) { RELEASE_ASSERT(firsts.size() == counts.size()); GL_MultiDrawArraysANGLE(mode, firsts.data(), counts.data(), sizeFor(firsts)); }
    static void multiDrawArraysInstancedANGLE(GLenum mode, const ANGLEInts& firsts, const ANGLEInts& counts, const ANGLEInts& instanceCounts) { RELEASE_ASSERT(firsts.size() == counts.size() && firsts.size() == instanceCounts.size()); GL_MultiDrawArraysInstancedANGLE(mode, firsts.data(), counts.data(), instanceCounts.data(), sizeFor(firsts)); }
    static void multiDrawArraysInstancedBaseInstanceANGLE(GLenum mode, const ANGLEInts& firsts, const ANGLEInts& counts, const ANGLEInts& instanceCounts, const ANGLEUnsignedInts& baseInstances) { RELEASE_ASSERT(firsts.size() == counts.size() && firsts.size() == instanceCounts.size() && firsts.size() == baseInstances.size()); GL_MultiDrawArraysInstancedBaseInstanceANGLE(mode, firsts.data(), counts.data(), instanceCounts.data(), baseInstances.data(), sizeFor(firsts)); }
    static void multiDrawElementsANGLE(GLenum mode, const ANGLEInts& counts, GLenum type, const ANGLEInts& offsets) { ANGLE::multiDrawElementsANGLE(mode, std::span { counts }, type, std::span { offsets }); }
    static void multiDrawElementsInstancedANGLE(GLenum mode, const ANGLEInts& counts, GLenum type, const ANGLEInts& offsets, const ANGLEInts& instanceCounts) { ANGLE::multiDrawElementsInstancedANGLE(mode, std::span { counts }, type, std::span { offsets }, std::span { instanceCounts }); }
    static void multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(GLenum mode, const ANGLEInts& counts, GLenum type, const ANGLEInts& offsets, const ANGLEInts& instanceCounts, const ANGLEInts& baseVertices, const ANGLEUnsignedInts& baseInstances) { ANGLE::multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(mode, std::span { counts }, type, std::span { offsets }, std::span { instanceCounts }, std::span { baseVertices }, std::span { baseInstances }); }

    // Query outputs, as vectors of count values.
    static ANGLEBooleans getBooleanv(GLenum pname, size_t count) { ANGLEBooleans values(count); ANGLE::getBooleanv(pname, std::span { values }); return values; }
    static ANGLEFloats getFloatv(GLenum pname, size_t count) { ANGLEFloats values(count); ANGLE::getFloatv(pname, std::span { values }); return values; }
    static ANGLEInts getIntegerv(GLenum pname, size_t count) { ANGLEInts values(count); ANGLE::getIntegerv(pname, std::span { values }); return values; }
    static ANGLEInts getInternalformativ(GLenum target, GLenum internalFormat, GLenum pname, size_t count) { ANGLEInts values(count); ANGLE::getInternalformativ(target, internalFormat, pname, std::span { values }); return values; }
    static ANGLEInts getActiveUniformBlockiv(GLuint program, GLuint uniformBlockIndex, GLenum pname, size_t count) { ANGLEInts values(count); ANGLE::getActiveUniformBlockiv(program, uniformBlockIndex, pname, std::span { values }); return values; }
    static ANGLEFloats getUniformfv(GLuint program, GLint location, size_t count) { ANGLEFloats values(count); ANGLE::getUniformfv(program, location, std::span { values }); return values; }
    static ANGLEInts getUniformiv(GLuint program, GLint location, size_t count) { ANGLEInts values(count); ANGLE::getUniformiv(program, location, std::span { values }); return values; }
    static ANGLEUnsignedInts getUniformuiv(GLuint program, GLint location, size_t count) { ANGLEUnsignedInts values(count); ANGLE::getUniformuiv(program, location, std::span { values }); return values; }

    // Strings in, as bytes without a terminator; out, as the bytes written.
    static void shaderSource(GLuint shader, const ANGLEBytes& source) { ANGLE::shaderSource(shader, std::span { source }); }
    static void bindAttribLocation(GLuint program, GLuint index, const ANGLEBytes& name) { ANGLE::bindAttribLocation(program, index, std::span { name }); }
    static GLint getFragDataLocation(GLuint program, const ANGLEBytes& name) { return ANGLE::getFragDataLocation(program, std::span { name }); }
    static GLuint getUniformBlockIndex(GLuint program, const ANGLEBytes& name) { return ANGLE::getUniformBlockIndex(program, std::span { name }); }
    static void transformFeedbackVaryings(GLuint program, const ANGLEBytes& names, GLenum bufferMode) { ANGLE::transformFeedbackVaryings(program, std::span { names }, bufferMode); }
    static ANGLEBytes getProgramInfoLog(GLuint program, size_t maxLength) { return written(maxLength, [&](std::span<uint8_t> log) { return ANGLE::getProgramInfoLog(program, log); }); }
    static ANGLEBytes getShaderInfoLog(GLuint shader, size_t maxLength) { return written(maxLength, [&](std::span<uint8_t> log) { return ANGLE::getShaderInfoLog(shader, log); }); }
    static ANGLEBytes getTranslatedShaderSource(GLuint shader, size_t maxLength) { return written(maxLength, [&](std::span<uint8_t> source) { return ANGLE::getTranslatedShaderSource(shader, source); }); }
    static ANGLEBytes getActiveUniformBlockName(GLuint program, GLuint uniformBlockIndex, size_t maxLength) { return written(maxLength, [&](std::span<uint8_t> name) { return ANGLE::getActiveUniformBlockName(program, uniformBlockIndex, name); }); }
    // count locations, or none if they couldn't be found.
    static ANGLEInts getUniformLocations(GLuint program, const std::string& name, size_t count)
    {
        ANGLEInts locations(count);
        if (!ANGLE::getUniformLocations(program, name, std::span { locations }))
            return { };
        return locations;
    }

private:
    // The elements of count values of n elements each.
    template<typename T> static const T* elements(const std::vector<T>& vector, GLsizei count, size_t n)
    {
        RELEASE_ASSERT(count >= 0 && static_cast<size_t>(count) <= vector.size() / n);
        return vector.data();
    }
    template<typename T> static GLsizei sizeFor(const std::vector<T>& vector) { return static_cast<GLsizei>(vector.size()); }

    // The bytes a getter writes into maxLength bytes, as many as it says it wrote.
    template<typename Get> static ANGLEBytes written(size_t maxLength, const Get& get)
    {
        ANGLEBytes bytes(maxLength);
        GLsizei length = get(std::span { bytes });
        bytes.resize(std::min(static_cast<size_t>(std::max<GLsizei>(length, 0)), bytes.size()));
        return bytes;
    }
};
