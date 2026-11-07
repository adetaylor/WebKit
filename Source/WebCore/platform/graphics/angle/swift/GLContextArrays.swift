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

internal import CxxStdlib
internal import WebCoreANGLE
internal import WebCoreANGLE.BeforeOS26

// The entry points of GLContext for Swift callers, which pass arrays of their own: the receiver. On OS 26 and later the
// arrays reach ANGLE as Spans. Before, each else-branch is the old path, which copies the array into a std::vector for
// WebCoreANGLEBeforeOS26.h's shims. The old path goes when WebKit's deployment target reaches OS 26.
extension GLContext {
    @_expose(!Cxx)
    public func uniform1fv(_ location: GLint, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_Uniform1fv(location, values.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniform1fv(location, count, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func uniform1iv(_ location: GLint, _ values: [GLint]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_Uniform1iv(location, values.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniform1iv(location, count, ANGLEInts(values))
        }
    }

    @_expose(!Cxx)
    public func uniform1uiv(_ location: GLint, _ values: [GLuint]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_Uniform1uiv(location, values.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniform1uiv(location, count, ANGLEUnsignedInts(values))
        }
    }

    @_expose(!Cxx)
    public func uniform2fv(_ location: GLint, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 2)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_Uniform2fv(location, count, values.span.extracting(first: Int(count) * 2))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniform2fv(location, count, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func uniform2iv(_ location: GLint, _ values: [GLint]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 2)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_Uniform2iv(location, count, values.span.extracting(first: Int(count) * 2))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniform2iv(location, count, ANGLEInts(values))
        }
    }

    @_expose(!Cxx)
    public func uniform2uiv(_ location: GLint, _ values: [GLuint]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 2)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_Uniform2uiv(location, count, values.span.extracting(first: Int(count) * 2))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniform2uiv(location, count, ANGLEUnsignedInts(values))
        }
    }

    @_expose(!Cxx)
    public func uniform3fv(_ location: GLint, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 3)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_Uniform3fv(location, count, values.span.extracting(first: Int(count) * 3))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniform3fv(location, count, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func uniform3iv(_ location: GLint, _ values: [GLint]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 3)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_Uniform3iv(location, count, values.span.extracting(first: Int(count) * 3))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniform3iv(location, count, ANGLEInts(values))
        }
    }

    @_expose(!Cxx)
    public func uniform3uiv(_ location: GLint, _ values: [GLuint]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 3)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_Uniform3uiv(location, count, values.span.extracting(first: Int(count) * 3))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniform3uiv(location, count, ANGLEUnsignedInts(values))
        }
    }

    @_expose(!Cxx)
    public func uniform4fv(_ location: GLint, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 4)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_Uniform4fv(location, count, values.span.extracting(first: Int(count) * 4))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniform4fv(location, count, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func uniform4iv(_ location: GLint, _ values: [GLint]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 4)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_Uniform4iv(location, count, values.span.extracting(first: Int(count) * 4))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniform4iv(location, count, ANGLEInts(values))
        }
    }

    @_expose(!Cxx)
    public func uniform4uiv(_ location: GLint, _ values: [GLuint]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 4)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_Uniform4uiv(location, count, values.span.extracting(first: Int(count) * 4))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniform4uiv(location, count, ANGLEUnsignedInts(values))
        }
    }

    @_expose(!Cxx)
    public func uniformMatrix2fv(_ location: GLint, _ transpose: GLboolean, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 4)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_UniformMatrix2fv(location, count, transpose, values.span.extracting(first: Int(count) * 4))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniformMatrix2fv(location, count, transpose, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func uniformMatrix3fv(_ location: GLint, _ transpose: GLboolean, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 9)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_UniformMatrix3fv(location, count, transpose, values.span.extracting(first: Int(count) * 9))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniformMatrix3fv(location, count, transpose, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func uniformMatrix4fv(_ location: GLint, _ transpose: GLboolean, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 16)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_UniformMatrix4fv(location, count, transpose, values.span.extracting(first: Int(count) * 16))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniformMatrix4fv(location, count, transpose, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func uniformMatrix2x3fv(_ location: GLint, _ transpose: GLboolean, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 6)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_UniformMatrix2x3fv(location, count, transpose, values.span.extracting(first: Int(count) * 6))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniformMatrix2x3fv(location, count, transpose, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func uniformMatrix3x2fv(_ location: GLint, _ transpose: GLboolean, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 6)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_UniformMatrix3x2fv(location, count, transpose, values.span.extracting(first: Int(count) * 6))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniformMatrix3x2fv(location, count, transpose, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func uniformMatrix2x4fv(_ location: GLint, _ transpose: GLboolean, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 8)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_UniformMatrix2x4fv(location, count, transpose, values.span.extracting(first: Int(count) * 8))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniformMatrix2x4fv(location, count, transpose, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func uniformMatrix4x2fv(_ location: GLint, _ transpose: GLboolean, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 8)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_UniformMatrix4x2fv(location, count, transpose, values.span.extracting(first: Int(count) * 8))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniformMatrix4x2fv(location, count, transpose, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func uniformMatrix3x4fv(_ location: GLint, _ transpose: GLboolean, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 12)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_UniformMatrix3x4fv(location, count, transpose, values.span.extracting(first: Int(count) * 12))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniformMatrix3x4fv(location, count, transpose, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func uniformMatrix4x3fv(_ location: GLint, _ transpose: GLboolean, _ values: [GLfloat]) {
        guard makeContextCurrent() else {
            return
        }
        let count = GLsizei(truncatingIfNeeded: values.count / 12)
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_UniformMatrix4x3fv(location, count, transpose, values.span.extracting(first: Int(count) * 12))
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.uniformMatrix4x3fv(location, count, transpose, ANGLEFloats(values))
        }
    }

    @_expose(!Cxx)
    public func drawBuffers(_ buffers: [GLenum]) {
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_DrawBuffers(buffers.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.drawBuffers(ANGLEUnsignedInts(buffers))
        }
    }

    @_expose(!Cxx)
    public func drawBuffersEXT(_ buffers: [GLenum]) {
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_DrawBuffersEXT(buffers.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.drawBuffersEXT(ANGLEUnsignedInts(buffers))
        }
    }

    @_expose(!Cxx)
    public func invalidateFramebuffer(_ target: GLenum, _ attachments: [GLenum]) {
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_InvalidateFramebuffer(target, attachments.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.invalidateFramebuffer(target, ANGLEUnsignedInts(attachments))
        }
    }

    @_expose(!Cxx)
    public func invalidateSubFramebuffer(_ target: GLenum, _ attachments: [GLenum], _ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei) {
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_InvalidateSubFramebuffer(target, attachments.span, x, y, width, height)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.invalidateSubFramebuffer(target, ANGLEUnsignedInts(attachments), x, y, width, height)
        }
    }

    @_expose(!Cxx)
    public func framebufferDiscard(_ target: GLenum, _ attachments: [GLenum]) {
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_DiscardFramebufferEXT(target, attachments.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.framebufferDiscard(target, ANGLEUnsignedInts(attachments))
        }
    }

    @_expose(!Cxx)
    public func multiDrawArraysANGLE(_ mode: GLenum, _ firsts: [GLint], _ counts: [GLsizei]) {
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_MultiDrawArraysANGLE(mode, firsts.span, counts.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.multiDrawArraysANGLE(mode, ANGLEInts(firsts), ANGLEInts(counts))
        }
        checkGPUStatus()
    }

    @_expose(!Cxx)
    public func multiDrawArraysInstancedANGLE(_ mode: GLenum, _ firsts: [GLint], _ counts: [GLsizei], _ instanceCounts: [GLsizei]) {
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_MultiDrawArraysInstancedANGLE(mode, firsts.span, counts.span, instanceCounts.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.multiDrawArraysInstancedANGLE(mode, ANGLEInts(firsts), ANGLEInts(counts), ANGLEInts(instanceCounts))
        }
        checkGPUStatus()
    }

    @_expose(!Cxx)
    public func multiDrawArraysInstancedBaseInstanceANGLE(_ mode: GLenum, _ firsts: [GLint], _ counts: [GLsizei], _ instanceCounts: [GLsizei], _ baseInstances: [GLuint]) {
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            GL_MultiDrawArraysInstancedBaseInstanceANGLE(mode, firsts.span, counts.span, instanceCounts.span, baseInstances.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.multiDrawArraysInstancedBaseInstanceANGLE(mode, ANGLEInts(firsts), ANGLEInts(counts), ANGLEInts(instanceCounts), ANGLEUnsignedInts(baseInstances))
        }
        checkGPUStatus()
    }

    @_expose(!Cxx)
    public func multiDrawElementsANGLE(_ mode: GLenum, _ counts: [GLsizei], _ offsets: [GLint], _ type: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            ANGLE.multiDrawElementsANGLE(mode, counts.span, type, offsets.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.multiDrawElementsANGLE(mode, ANGLEInts(counts), type, ANGLEInts(offsets))
        }
        checkGPUStatus()
    }

    @_expose(!Cxx)
    public func multiDrawElementsInstancedANGLE(_ mode: GLenum, _ counts: [GLsizei], _ offsets: [GLint], _ instanceCounts: [GLsizei], _ type: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            ANGLE.multiDrawElementsInstancedANGLE(mode, counts.span, type, offsets.span, instanceCounts.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.multiDrawElementsInstancedANGLE(mode, ANGLEInts(counts), type, ANGLEInts(offsets), ANGLEInts(instanceCounts))
        }
        checkGPUStatus()
    }

    @_expose(!Cxx)
    public func multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(_ mode: GLenum, _ counts: [GLsizei], _ offsets: [GLint], _ instanceCounts: [GLsizei], _ baseVertices: [GLint], _ baseInstances: [GLuint], _ type: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            ANGLE.multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(mode, counts.span, type, offsets.span, instanceCounts.span, baseVertices.span, baseInstances.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(mode, ANGLEInts(counts), type, ANGLEInts(offsets), ANGLEInts(instanceCounts), ANGLEInts(baseVertices), ANGLEUnsignedInts(baseInstances))
        }
        checkGPUStatus()
    }

    // count values, zero if the context can't be made current.
    @_expose(!Cxx)
    public func getBooleanv(_ pname: GLenum, count: Int) -> [GLboolean] {
        var values = [GLboolean](repeating: 0, count: count)
        guard makeContextCurrent() else {
            return values
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            var span = values.mutableSpan
            ANGLE.getBooleanv(pname, &span)
        } else {
            // Before OS 26.
            values = Array(ANGLEBeforeOS26.getBooleanv(pname, count))
        }
        return values
    }

    // count values, zero if the context can't be made current.
    @_expose(!Cxx)
    public func getFloatv(_ pname: GLenum, count: Int) -> [GLfloat] {
        var values = [GLfloat](repeating: 0, count: count)
        guard makeContextCurrent() else {
            return values
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            var span = values.mutableSpan
            ANGLE.getFloatv(pname, &span)
        } else {
            // Before OS 26.
            values = Array(ANGLEBeforeOS26.getFloatv(pname, count))
        }
        return values
    }

    // Zero if the context can't be made current.
    @_expose(!Cxx)
    public func getIntegeri_v(_ pname: GLenum, _ index: GLuint) -> ANGLEInt4 {
        guard makeContextCurrent() else {
            return ANGLEInt4()
        }
        return ANGLE.getIntegeri_v(pname, index)
    }

    // count values, zero if the context can't be made current.
    @_expose(!Cxx)
    public func getIntegerv(_ pname: GLenum, count: Int) -> [GLint] {
        var values = [GLint](repeating: 0, count: count)
        guard makeContextCurrent() else {
            return values
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            var span = values.mutableSpan
            ANGLE.getIntegerv(pname, &span)
        } else {
            // Before OS 26.
            values = Array(ANGLEBeforeOS26.getIntegerv(pname, count))
        }
        return values
    }

    // count values, zero if the context can't be made current.
    @_expose(!Cxx)
    public func getInternalformativ(_ target: GLenum, _ internalformat: GLenum, _ pname: GLenum, count: Int) -> [GLint] {
        var values = [GLint](repeating: 0, count: count)
        guard makeContextCurrent() else {
            return values
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            var span = values.mutableSpan
            ANGLE.getInternalformativ(target, internalformat, pname, &span)
        } else {
            // Before OS 26.
            values = Array(ANGLEBeforeOS26.getInternalformativ(target, internalformat, pname, count))
        }
        return values
    }

    // count values, zero if the context can't be made current.
    @_expose(!Cxx)
    public func getActiveUniformBlockiv(_ program: GLuint, _ uniformBlockIndex: GLuint, _ pname: GLenum, count: Int) -> [GLint] {
        var values = [GLint](repeating: 0, count: count)
        guard makeContextCurrent() else {
            return values
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            var span = values.mutableSpan
            ANGLE.getActiveUniformBlockiv(program, uniformBlockIndex, pname, &span)
        } else {
            // Before OS 26.
            values = Array(ANGLEBeforeOS26.getActiveUniformBlockiv(program, uniformBlockIndex, pname, count))
        }
        return values
    }

    // count values, zero if the context can't be made current.
    @_expose(!Cxx)
    public func getUniformfv(_ program: GLuint, _ location: GLint, count: Int) -> [GLfloat] {
        var values = [GLfloat](repeating: 0, count: count)
        guard makeContextCurrent() else {
            return values
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            var span = values.mutableSpan
            ANGLE.getUniformfv(program, location, &span)
        } else {
            // Before OS 26.
            values = Array(ANGLEBeforeOS26.getUniformfv(program, location, count))
        }
        return values
    }

    // count values, zero if the context can't be made current.
    @_expose(!Cxx)
    public func getUniformiv(_ program: GLuint, _ location: GLint, count: Int) -> [GLint] {
        var values = [GLint](repeating: 0, count: count)
        guard makeContextCurrent() else {
            return values
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            var span = values.mutableSpan
            ANGLE.getUniformiv(program, location, &span)
        } else {
            // Before OS 26.
            values = Array(ANGLEBeforeOS26.getUniformiv(program, location, count))
        }
        return values
    }

    // count values, zero if the context can't be made current.
    @_expose(!Cxx)
    public func getUniformuiv(_ program: GLuint, _ location: GLint, count: Int) -> [GLuint] {
        var values = [GLuint](repeating: 0, count: count)
        guard makeContextCurrent() else {
            return values
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            var span = values.mutableSpan
            ANGLE.getUniformuiv(program, location, &span)
        } else {
            // Before OS 26.
            values = Array(ANGLEBeforeOS26.getUniformuiv(program, location, count))
        }
        return values
    }

    // Strings in: the bytes of a UTF8CString, without a terminator.

    @_expose(!Cxx)
    public func shaderSource(_ shader: GLuint, _ source: [UInt8]) {
        assert(shader != 0)
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            ANGLE.shaderSource(shader, source.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.shaderSource(shader, ANGLEBytes(source))
        }
    }

    @_expose(!Cxx)
    public func bindAttribLocation(_ program: GLuint, _ index: GLuint, _ name: [UInt8]) {
        assert(program != 0)
        guard makeContextCurrent() else {
            return
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            ANGLE.bindAttribLocation(program, index, name.span)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.bindAttribLocation(program, index, ANGLEBytes(name))
        }
    }

    @_expose(!Cxx)
    public func getFragDataLocation(_ program: GLuint, _ name: [UInt8]) -> GLint {
        guard makeContextCurrent() else {
            return -1
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            return ANGLE.getFragDataLocation(program, name.span)
        } else {
            // Before OS 26.
            return ANGLEBeforeOS26.getFragDataLocation(program, ANGLEBytes(name))
        }
    }

    @_expose(!Cxx)
    public func getUniformBlockIndex(_ program: GLuint, _ uniformBlockName: [UInt8]) -> GLuint {
        assert(program != 0)
        guard makeContextCurrent() else {
            return GLuint(GL_INVALID_INDEX)
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            return ANGLE.getUniformBlockIndex(program, uniformBlockName.span)
        } else {
            // Before OS 26.
            return ANGLEBeforeOS26.getUniformBlockIndex(program, ANGLEBytes(uniformBlockName))
        }
    }

    @_expose(!Cxx)
    public func transformFeedbackVaryings(_ program: GLuint, _ varyings: [[UInt8]], _ bufferMode: GLenum) {
        guard makeContextCurrent() else {
            return
        }
        var names: [UInt8] = []
        for varying in varyings {
            names += varying
            names.append(0)
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            ANGLE.transformFeedbackVaryings(program, names.span, bufferMode)
        } else {
            // Before OS 26.
            ANGLEBeforeOS26.transformFeedbackVaryings(program, ANGLEBytes(names), bufferMode)
        }
    }

    // Strings out: the bytes, without a terminator, or nil where the C++ API returns a null string (the context isn't
    // current).

    @_expose(!Cxx)
    public func getProgramInfoLog(_ program: GLuint) -> [UInt8]? {
        let maxLength = programInfoLogLength(program)
        return readString(maxLength) { span in ANGLE.getProgramInfoLog(program, &span) } beforeOS26: { ANGLEBeforeOS26.getProgramInfoLog(program, Int(maxLength)) }
    }

    @_expose(!Cxx)
    public func getShaderInfoLog(_ shader: GLuint) -> [UInt8]? {
        let maxLength = shaderInfoLogLength(shader)
        return readString(maxLength) { span in ANGLE.getShaderInfoLog(shader, &span) } beforeOS26: { ANGLEBeforeOS26.getShaderInfoLog(shader, Int(maxLength)) }
    }

    @_expose(!Cxx)
    public func getTranslatedShaderSourceANGLE(_ shader: GLuint) -> [UInt8]? {
        let maxLength = translatedShaderSourceLength(shader)
        return readString(maxLength) { span in ANGLE.getTranslatedShaderSource(shader, &span) } beforeOS26: { ANGLEBeforeOS26.getTranslatedShaderSource(shader, Int(maxLength)) }
    }

    @_expose(!Cxx)
    public func getActiveUniformBlockName(_ program: GLuint, _ uniformBlockIndex: GLuint) -> [UInt8]? {
        let maxLength = activeUniformBlockNameLength(program)
        // ANGLE is asked even for an empty name, so that it checks the index.
        return readString(maxLength, readsEmpty: true) { span in ANGLE.getActiveUniformBlockName(program, uniformBlockIndex, &span) } beforeOS26: { ANGLEBeforeOS26.getActiveUniformBlockName(program, uniformBlockIndex, Int(maxLength)) }
    }

    @_expose(!Cxx)
    public func getString(_ name: GLenum) -> [UInt8]? {
        if stringLength(name) < 0 {
            return nil
        }
        return bytes(of: ANGLE.getString(name))
    }

    // Active variables, with their names as bytes, after activeAttribCount() and activeUniformCount(). nil if the index
    // isn't one, as for the C++ callers.

    @_expose(!Cxx)
    public func activeAttrib(_ program: GLuint, _ index: GLuint, maxLength: GLint) -> (info: ANGLEActiveAttribInfo, name: [UInt8])? {
        guard makeContextCurrent() else {
            return nil
        }
        let variable = ANGLE.getActiveAttrib(program, index, maxLength)
        if variable.name.empty() || variable.size != 1 {
            assertionFailure()
            return nil
        }
        let info = ANGLEActiveAttribInfo(type: variable.type, location: ANGLE.getAttribLocation(program, variable.name), nameLength: GLint(variable.name.size()))
        return (info, bytes(of: variable.name))
    }

    @_expose(!Cxx)
    public func activeUniform(_ program: GLuint, _ index: GLuint, maxLength: GLint) -> (info: ANGLEActiveUniformInfo, name: [UInt8], locations: [GLint])? {
        guard makeContextCurrent() else {
            return nil
        }
        let variable = ANGLE.getActiveUniform(program, index, maxLength)
        if variable.name.empty() || variable.size < 1 {
            assertionFailure()
            return nil
        }
        let info = activeUniformInfo(program, index, variable.type, variable.size, GLint(variable.name.size()))
        var locations = [GLint](repeating: 0, count: Int(info.locationCount))
        let found: Bool
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            var span = locations.mutableSpan
            found = ANGLE.getUniformLocations(program, variable.name, &span)
        } else {
            // Before OS 26.
            locations = Array(ANGLEBeforeOS26.getUniformLocations(program, variable.name, locations.count))
            found = locations.count == Int(info.locationCount)
        }
        if !found {
            assertionFailure()
            return nil
        }
        return (info, bytes(of: variable.name), locations)
    }

    @_expose(!Cxx)
    public func lastTransformFeedbackVaryingName() -> [UInt8] {
        bytes(of: lastVariableName)
    }

    // Clear values: 4 for a color buffer, 1 for depth or stencil, as the C++ API checks.

    @_expose(!Cxx)
    public func clearBufferiv(_ buffer: GLenum, _ drawbuffer: GLint, _ values: [GLint]) {
        guard makeContextCurrent(), validateClearBufferv(buffer, values.count) else {
            return
        }
        ANGLE.clearBufferiv(buffer, drawbuffer, ANGLEInt4(values: Self.four(values, 0)))
        checkGPUStatus()
    }

    @_expose(!Cxx)
    public func clearBufferuiv(_ buffer: GLenum, _ drawbuffer: GLint, _ values: [GLuint]) {
        guard makeContextCurrent(), validateClearBufferv(buffer, values.count) else {
            return
        }
        ANGLE.clearBufferuiv(buffer, drawbuffer, ANGLEUnsignedInt4(values: Self.four(values, 0)))
        checkGPUStatus()
    }

    @_expose(!Cxx)
    public func clearBufferfv(_ buffer: GLenum, _ drawbuffer: GLint, _ values: [GLfloat]) {
        guard makeContextCurrent(), validateClearBufferv(buffer, values.count) else {
            return
        }
        ANGLE.clearBufferfv(buffer, drawbuffer, ANGLEFloat4(values: Self.four(values, 0)))
        checkGPUStatus()
    }

    // The first four values, or the one value and padding.
    private static func four<T>(_ values: [T], _ padding: T) -> (T, T, T, T) {
        values.count >= 4 ? (values[0], values[1], values[2], values[3]) : (values[0], padding, padding, padding)
    }

    // A string of up to maxLength bytes with its terminator, which read writes into a span (OS 26 and later) or
    // beforeOS26 returns. nil when maxLength is negative, which means the context isn't current.
    private func readString(_ maxLength: GLint, readsEmpty: Bool = false, read: (inout MutableSpan<UInt8>) -> GLsizei, beforeOS26: () -> ANGLEBytes) -> [UInt8]? {
        if maxLength < 0 {
            return nil
        }
        if maxLength == 0 && !readsEmpty {
            return []
        }
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            var string = [UInt8](repeating: 0, count: Int(maxLength))
            let length: GLsizei
            do {
                var span = string.mutableSpan
                length = read(&span)
            }
            return Array(string.prefix(Int(min(max(length, 0), maxLength))))
        } else {
            // Before OS 26.
            return Array(beforeOS26())
        }
    }

    private func bytes(of string: std.string) -> [UInt8] {
        string.map { UInt8(bitPattern: $0) }
    }
}
