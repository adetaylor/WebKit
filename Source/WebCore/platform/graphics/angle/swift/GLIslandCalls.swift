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
#if WTF_PLATFORM_COCOA
internal import CoreVideo
internal import IOSurface
#endif

// What a C++ shell, GraphicsContextGLANGLE, keeps of the island: its context, and, for a Cocoa shell, the platform the
// context is made on. The shell owns one through the opaque reference GLIslandCalls.createShell() gives it.
public final class GLShell {
    public internal(set) var context: GLContext?
#if WTF_PLATFORM_COCOA
    var cocoaPlatform: CocoaGLPlatform?
#endif

    init() {
    }

    // The shell of a reference that GLIslandCalls.createShell() made and destroyShell() has not yet released. The C++
    // shell keeps its reference for its whole life, so its Swift and the GPU process's receiver, which it hands the
    // reference while it is alive, may use it.
    @unsafe
    public static func fromReference(_ reference: UInt) -> GLShell {
        unsafe Unmanaged<GLShell>.fromOpaque(UnsafeRawPointer(bitPattern: reference)!).takeUnretainedValue()
    }
}

extension WebCore.GLIslandCalls {
    private var islandShell: GLShell {
        unsafe GLShell.fromReference(shell)
    }

    private var context: GLContext {
        islandShell.context!
    }

#if WTF_PLATFORM_COCOA
    private var cocoaPlatform: CocoaGLPlatform {
        islandShell.cocoaPlatform!
    }
#endif

    @cxx
    @implementation
    public static func createShell() -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(GLShell()).toOpaque())
    }

    @cxx
    @implementation
    @unsafe
    public static func destroyShell(_ reference: UInt) {
        unsafe Unmanaged<GLShell>.fromOpaque(UnsafeRawPointer(bitPattern: reference)!).release()
    }

    @cxx
    @implementation
    public func createContext(_ contextID: UInt64, _ display: ANGLEDisplay, _ eglContext: ANGLEContext, _ isWebGL2: Bool, _ supportsWebGLDraftExtensions: Bool) {
        islandShell.context = GLContext(contextID: contextID, display: display, context: eglContext, isWebGL2: isWebGL2, supportsWebGLDraftExtensions: supportsWebGLDraftExtensions)
    }

    @cxx
    @implementation
    public func hasContext() -> Bool {
        islandShell.context != nil
    }

#if WTF_PLATFORM_COCOA
    @cxx
    @implementation
    public func createCocoaPlatform(_ contextID: UInt64, _ isWebGL2: Bool, _ alpha: Bool, _ powerPreference: UInt8, _ windowGPUID: UInt64, _ xrCompatible: Bool, _ ownershipIdentity: UInt32, _ maximumSurfaceWidth: Int32, _ maximumSurfaceHeight: Int32) -> Bool {
        let platform = CocoaGLPlatform(contextID: contextID, isWebGL2: isWebGL2, alpha: alpha, powerPreference: powerPreference, windowGPUID: windowGPUID, xrCompatible: xrCompatible, ownershipIdentity: ownershipIdentity, maximumSurfaceWidth: maximumSurfaceWidth, maximumSurfaceHeight: maximumSurfaceHeight)
        islandShell.cocoaPlatform = platform
        return platform.isValid()
    }

    @cxx
    @implementation
    public func createCocoaContext(_ contextID: UInt64, _ supportsWebGLDraftExtensions: Bool) {
        islandShell.context = GLContext(contextID: contextID, cocoaPlatform: cocoaPlatform, supportsWebGLDraftExtensions: supportsWebGLDraftExtensions)
    }

    @cxx
    @implementation
    public func hasPlatform() -> Bool {
        islandShell.cocoaPlatform != nil
    }
#endif

    @cxx
    @implementation
    public func activeAttrib(_ program: GLuint, _ index: GLuint, _ name: WebCore.GLLentMutableBytes) -> ANGLEActiveAttribInfo {
        context.activeAttrib(program, index, name)
    }

    @cxx
    @implementation
    public func activeAttribCount(_ program: GLuint) -> ANGLEActiveVariableCount {
        context.activeAttribCount(program)
    }

    @cxx
    @implementation
    public func activeUniform(_ program: GLuint, _ index: GLuint, _ name: WebCore.GLLentMutableBytes) -> ANGLEActiveUniformInfo {
        context.activeUniform(program, index, name)
    }

    @cxx
    @implementation
    public func activeUniformBlockNameLength(_ program: GLuint) -> GLint {
        context.activeUniformBlockNameLength(program)
    }

    @cxx
    @implementation
    public func getInteger(_ pname: GLenum) -> GLint {
        context.getInteger(pname)
    }

    @cxx
    @implementation
    public func activeUniformCount(_ program: GLuint) -> ANGLEActiveVariableCount {
        context.activeUniformCount(program)
    }

    @cxx
    @implementation
    public func activeUniformLocations(_ program: GLuint, _ name: WebCore.GLLentBytes, _ nameLength: GLint, _ locations: WebCore.GLLentMutableInts) -> Bool {
        context.activeUniformLocations(program, name, nameLength, locations)
    }

    @cxx
    @implementation
    public func addErrors(_ errors: UInt8) {
        context.addErrors(errors)
    }

    @cxx
    @implementation
    public func addExternalImage(_ image: ANGLEImage) -> UInt32 {
        context.addExternalImage(image)
    }

    @cxx
    @implementation
    public func addExternalSync(_ sync: ANGLEEGLSync) -> UInt32 {
        context.addExternalSync(sync)
    }

    @cxx
    @implementation
    public func bindAttribLocation(_ program: GLuint, _ index: GLuint, _ name: WebCore.GLLentBytes) {
        context.bindAttribLocation(program, index, name)
    }

    @cxx
    @implementation
    public func bindExternalImage(_ target: GLenum, _ image: UInt32) {
        context.bindExternalImage(target, image)
    }

    @cxx
    @implementation
    public func bufferData(_ target: GLenum, _ data: WebCore.GLLentBytes, _ usage: GLenum) {
        context.bufferData(target, data, usage)
    }

    @cxx
    @implementation
    public func bufferSubData(_ target: GLenum, _ offset: GLintptr, _ data: WebCore.GLLentBytes) {
        context.bufferSubData(target, offset, data)
    }

    @cxx
    @implementation
    public func clampMaxInternalFramebufferSize(_ width: Int32, _ height: Int32) {
        context.clampMaxInternalFramebufferSize(width, height)
    }

    @cxx
    @implementation
    public func clearActiveVariables() {
        context.clearActiveVariables()
    }

    @cxx
    @implementation
    public func clearBufferfv(_ buffer: GLenum, _ drawbuffer: GLint, _ values: WebCore.GLLentFloats) {
        context.clearBufferfv(buffer, drawbuffer, values)
    }

    @cxx
    @implementation
    public func clearBufferiv(_ buffer: GLenum, _ drawbuffer: GLint, _ values: WebCore.GLLentInts) {
        context.clearBufferiv(buffer, drawbuffer, values)
    }

    @cxx
    @implementation
    public func clearBufferuiv(_ buffer: GLenum, _ drawbuffer: GLint, _ values: WebCore.GLLentUnsignedInts) {
        context.clearBufferuiv(buffer, drawbuffer, values)
    }

    @cxx
    @implementation
    public func clientWaitSync(_ sync: UInt64, _ flags: GLbitfield, _ timeout: GLuint64) -> GLenum {
        context.clientWaitSync(sync, flags, timeout)
    }

    @cxx
    @implementation
    public func compressedTexImage2D(_ target: GLenum, _ level: GLint, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei, _ border: GLint, _ data: WebCore.GLLentBytes) {
        context.compressedTexImage2D(target, level, internalformat, width, height, border, data)
    }

    @cxx
    @implementation
    public func compressedTexImage3D(_ target: GLenum, _ level: GLint, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei, _ border: GLint, _ data: WebCore.GLLentBytes) {
        context.compressedTexImage3D(target, level, internalformat, width, height, depth, border, data)
    }

    @cxx
    @implementation
    public func compressedTexSubImage2D(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ data: WebCore.GLLentBytes) {
        context.compressedTexSubImage2D(target, level, xoffset, yoffset, width, height, format, data)
    }

    @cxx
    @implementation
    public func compressedTexSubImage3D(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ zoffset: GLint, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei, _ format: GLenum, _ data: WebCore.GLLentBytes) {
        context.compressedTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, data)
    }

    @cxx
    @implementation
    public func copyLastVariableName(_ name: WebCore.GLLentMutableBytes) -> Int {
        context.copyLastVariableName(name)
    }

    @cxx
    @implementation
    public func copyString(_ name: GLenum, _ destination: WebCore.GLLentMutableBytes) -> Int {
        context.copyString(name, destination)
    }

    @cxx
    @implementation
    public func deleteSync(_ sync: UInt64) {
        context.deleteSync(sync)
    }

    @cxx
    @implementation
    public func destroy() {
        context.destroy()
    }

    @cxx
    @implementation
    public func didForceContextLost() {
        context.didForceContextLost()
    }

    @cxx
    @implementation
    public func drawBuffers(_ buffers: WebCore.GLLentUnsignedInts) {
        context.drawBuffers(buffers)
    }

    @cxx
    @implementation
    public func drawBuffersEXT(_ buffers: WebCore.GLLentUnsignedInts) {
        context.drawBuffersEXT(buffers)
    }

    @cxx
    @implementation
    public func enableExtension(_ extension: UInt8) -> Bool {
        context.enableExtension(`extension`)
    }

    @cxx
    @implementation
    public func enableExtensionsForPlatform(_ names: WebCore.GLLentCStrings) -> Bool {
        context.enableExtensionsForPlatform(names)
    }

    @cxx
    @implementation
    public func estimatedMemoryCost() -> Int64 {
        context.estimatedMemoryCost()
    }

    @cxx
    @implementation
    public func fenceSync(_ condition: GLenum, _ flags: GLbitfield) -> UInt64 {
        context.fenceSync(condition, flags)
    }

    @cxx
    @implementation
    public func framebufferDiscard(_ target: GLenum, _ attachments: WebCore.GLLentUnsignedInts) {
        context.framebufferDiscard(target, attachments)
    }

    @cxx
    @implementation
    public func getActiveUniformBlockName(_ program: GLuint, _ uniformBlockIndex: GLuint, _ name: WebCore.GLLentMutableBytes) -> GLsizei {
        context.getActiveUniformBlockName(program, uniformBlockIndex, name)
    }

    @cxx
    @implementation
    public func getActiveUniformBlockiv(_ program: GLuint, _ uniformBlockIndex: GLuint, _ pname: GLenum, _ params: WebCore.GLLentMutableInts) {
        context.getActiveUniformBlockiv(program, uniformBlockIndex, pname, params)
    }

    @cxx
    @implementation
    public func getBooleanv(_ pname: GLenum, _ value: WebCore.GLLentMutableBytes) {
        context.getBooleanv(pname, value)
    }

    @cxx
    @implementation
    public func getBufferSubData(_ target: GLenum, _ offset: GLintptr, _ data: WebCore.GLLentMutableBytes) -> Bool {
        context.getBufferSubData(target, offset, data)
    }

    @cxx
    @implementation
    public func getErrors() -> UInt8 {
        context.getErrors()
    }

    @cxx
    @implementation
    public func getFloatv(_ pname: GLenum, _ value: WebCore.GLLentMutableFloats) {
        context.getFloatv(pname, value)
    }

    @cxx
    @implementation
    public func getFragDataLocation(_ program: GLuint, _ name: WebCore.GLLentBytes) -> GLint {
        context.getFragDataLocation(program, name)
    }

    @cxx
    @implementation
    public func getIntegeri_v(_ pname: GLenum, _ index: GLuint, _ value: WebCore.GLLentMutableInts) {
        context.getIntegeri_v(pname, index, value)
    }

    @cxx
    @implementation
    public func getIntegerv(_ pname: GLenum, _ value: WebCore.GLLentMutableInts) {
        context.getIntegerv(pname, value)
    }

    @cxx
    @implementation
    public func getInternalformativ(_ target: GLenum, _ internalformat: GLenum, _ pname: GLenum, _ data: WebCore.GLLentMutableInts) {
        context.getInternalformativ(target, internalformat, pname, data)
    }

    @cxx
    @implementation
    public func getProgramInfoLog(_ program: GLuint, _ log: WebCore.GLLentMutableBytes) -> GLsizei {
        context.getProgramInfoLog(program, log)
    }

    @cxx
    @implementation
    public func getShaderInfoLog(_ shader: GLuint, _ log: WebCore.GLLentMutableBytes) -> GLsizei {
        context.getShaderInfoLog(shader, log)
    }

    @cxx
    @implementation
    public func getShaderPrecisionFormat(_ shaderType: GLenum, _ precisionType: GLenum) -> ANGLEShaderPrecisionFormat {
        context.getShaderPrecisionFormat(shaderType, precisionType)
    }

    @cxx
    @implementation
    public func getSynci(_ sync: UInt64, _ pname: GLenum) -> GLint {
        context.getSynci(sync, pname)
    }

    @cxx
    @implementation
    public func getTransformFeedbackVarying(_ program: GLuint, _ index: GLuint) -> ANGLEActiveVariableInfo {
        context.getTransformFeedbackVarying(program, index)
    }

    @cxx
    @implementation
    public func getTranslatedShaderSourceANGLE(_ shader: GLuint, _ source: WebCore.GLLentMutableBytes) -> GLsizei {
        context.getTranslatedShaderSourceANGLE(shader, source)
    }

    @cxx
    @implementation
    public func getUniformBlockIndex(_ program: GLuint, _ uniformBlockName: WebCore.GLLentBytes) -> GLuint {
        context.getUniformBlockIndex(program, uniformBlockName)
    }

    @cxx
    @implementation
    public func getUniformfv(_ program: GLuint, _ location: GLint, _ value: WebCore.GLLentMutableFloats) {
        context.getUniformfv(program, location, value)
    }

    @cxx
    @implementation
    public func getUniformiv(_ program: GLuint, _ location: GLint, _ value: WebCore.GLLentMutableInts) {
        context.getUniformiv(program, location, value)
    }

    @cxx
    @implementation
    public func getUniformuiv(_ program: GLuint, _ location: GLint, _ value: WebCore.GLLentMutableUnsignedInts) {
        context.getUniformuiv(program, location, value)
    }

    @cxx
    @implementation
    public func initialize() -> Bool {
        context.initialize()
    }

    @cxx
    @implementation
    public func invalidateFramebuffer(_ target: GLenum, _ attachments: WebCore.GLLentUnsignedInts) {
        context.invalidateFramebuffer(target, attachments)
    }

    @cxx
    @implementation
    public func invalidateSubFramebuffer(_ target: GLenum, _ attachments: WebCore.GLLentUnsignedInts, _ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei) {
        context.invalidateSubFramebuffer(target, attachments, x, y, width, height)
    }

    @cxx
    @implementation
    public func isCurrent() -> Bool {
        context.isCurrent()
    }

    @cxx
    @implementation
    public func isSync(_ sync: UInt64) -> GLboolean {
        context.isSync(sync)
    }

    @cxx
    @implementation
    public func knownActiveExtensions() -> UInt64 {
        context.knownActiveExtensions()
    }

    @cxx
    @implementation
    public func makeCurrentForPlatform() -> Bool {
        context.makeCurrentForPlatform()
    }

    @cxx
    @implementation
    public func maxDrawingBufferSize() -> ANGLEInt2 {
        context.maxDrawingBufferSize()
    }

    @cxx
    @implementation
    public func maxViewportDims() -> ANGLEInt2 {
        context.maxViewportDims()
    }

    @cxx
    @implementation
    public func multiDrawArraysANGLE(_ mode: GLenum, _ firsts: WebCore.GLLentInts, _ counts: WebCore.GLLentInts, _ drawCount: GLsizei) {
        context.multiDrawArraysANGLE(mode, firsts, counts, drawCount)
    }

    @cxx
    @implementation
    public func multiDrawArraysInstancedANGLE(_ mode: GLenum, _ firsts: WebCore.GLLentInts, _ counts: WebCore.GLLentInts, _ instanceCounts: WebCore.GLLentInts, _ drawCount: GLsizei) {
        context.multiDrawArraysInstancedANGLE(mode, firsts, counts, instanceCounts, drawCount)
    }

    @cxx
    @implementation
    public func multiDrawArraysInstancedBaseInstanceANGLE(_ mode: GLenum, _ firsts: WebCore.GLLentInts, _ counts: WebCore.GLLentInts, _ instanceCounts: WebCore.GLLentInts, _ baseInstances: WebCore.GLLentUnsignedInts, _ drawCount: GLsizei) {
        context.multiDrawArraysInstancedBaseInstanceANGLE(mode, firsts, counts, instanceCounts, baseInstances, drawCount)
    }

    @cxx
    @implementation
    public func multiDrawElementsANGLE(_ mode: GLenum, _ counts: WebCore.GLLentInts, _ offsets: WebCore.GLLentInts, _ type: GLenum, _ drawCount: GLsizei) {
        context.multiDrawElementsANGLE(mode, counts, offsets, type, drawCount)
    }

    @cxx
    @implementation
    public func multiDrawElementsInstancedANGLE(_ mode: GLenum, _ counts: WebCore.GLLentInts, _ offsets: WebCore.GLLentInts, _ instanceCounts: WebCore.GLLentInts, _ type: GLenum, _ drawCount: GLsizei) {
        context.multiDrawElementsInstancedANGLE(mode, counts, offsets, instanceCounts, type, drawCount)
    }

    @cxx
    @implementation
    public func multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(_ mode: GLenum, _ counts: WebCore.GLLentInts, _ offsets: WebCore.GLLentInts, _ instanceCounts: WebCore.GLLentInts, _ baseVertices: WebCore.GLLentInts, _ baseInstances: WebCore.GLLentUnsignedInts, _ type: GLenum, _ drawCount: GLsizei) {
        context.multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(mode, counts, offsets, instanceCounts, baseVertices, baseInstances, type, drawCount)
    }

    @cxx
    @implementation
    public func programInfoLogLength(_ program: GLuint) -> GLint {
        context.programInfoLogLength(program)
    }

    @cxx
    @implementation
    public func readPixels(_ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ type: GLenum, _ data: WebCore.GLLentMutableBytes, _ alignment: GLint, _ rowLength: GLint, _ reverseRowOrder: GLboolean) {
        context.readPixels(x, y, width, height, format, type, data, alignment, rowLength, reverseRowOrder)
    }

    @cxx
    @implementation
    public func readPixelsBufferObject(_ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ type: GLenum, _ offset: GLintptr, _ alignment: GLint, _ rowLength: GLint) {
        context.readPixelsBufferObject(x, y, width, height, format, type, offset, alignment, rowLength)
    }

    @cxx
    @implementation
    public func readPixelsForPaintResults(_ pixels: WebCore.GLLentMutableBytes, _ width: Int32, _ height: Int32) -> Bool {
        context.readPixelsForPaintResults(pixels, width, height)
    }

    @cxx
    @implementation
    public func readPixelsWithStatus(_ x: GLint, _ y: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ type: GLenum, _ reverseRowOrder: GLboolean, _ data: WebCore.GLLentMutableBytes) -> ANGLEReadPixelsStatus {
        context.readPixelsWithStatus(x, y, width, height, format, type, reverseRowOrder, data)
    }

    @cxx
    @implementation
    public func readRenderingResults(_ pixels: WebCore.GLLentMutableBytes, _ width: Int32, _ height: Int32) -> Bool {
        context.readRenderingResults(pixels, width, height)
    }

    @cxx
    @implementation
    public func requestableExtensions() -> UInt64 {
        context.requestableExtensions()
    }

    @cxx
    @implementation
    public func reshape(_ width: Int32, _ height: Int32) {
        context.reshape(width, height)
    }

    @cxx
    @implementation
    public func shaderInfoLogLength(_ shader: GLuint) -> GLint {
        context.shaderInfoLogLength(shader)
    }

    @cxx
    @implementation
    public func shaderSource(_ shader: GLuint, _ source: WebCore.GLLentBytes) {
        context.shaderSource(shader, source)
    }

    @cxx
    @implementation
    public func simulateEventForTesting(_ event: UInt8) {
        context.simulateEventForTesting(event)
    }

    @cxx
    @implementation
    public func texImage2D(_ target: GLenum, _ level: GLint, _ internalformat: GLenum, _ width: GLsizei, _ height: GLsizei, _ border: GLint, _ format: GLenum, _ type: GLenum, _ pixels: WebCore.GLLentBytes) {
        context.texImage2D(target, level, internalformat, width, height, border, format, type, pixels)
    }

    @cxx
    @implementation
    public func texImage3D(_ target: GLenum, _ level: GLint, _ internalformat: GLint, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei, _ border: GLint, _ format: GLenum, _ type: GLenum, _ pixels: WebCore.GLLentBytes) {
        context.texImage3D(target, level, internalformat, width, height, depth, border, format, type, pixels)
    }

    @cxx
    @implementation
    public func texSubImage2D(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ width: GLsizei, _ height: GLsizei, _ format: GLenum, _ type: GLenum, _ pixels: WebCore.GLLentBytes) {
        context.texSubImage2D(target, level, xoffset, yoffset, width, height, format, type, pixels)
    }

    @cxx
    @implementation
    public func texSubImage3D(_ target: GLenum, _ level: GLint, _ xoffset: GLint, _ yoffset: GLint, _ zoffset: GLint, _ width: GLsizei, _ height: GLsizei, _ depth: GLsizei, _ format: GLenum, _ type: GLenum, _ pixels: WebCore.GLLentBytes) {
        context.texSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels)
    }

    @cxx
    @implementation
    public func transformFeedbackVaryings(_ program: GLuint, _ varyings: WebCore.GLLentCStrings, _ bufferMode: GLenum) {
        context.transformFeedbackVaryings(program, varyings, bufferMode)
    }

    @cxx
    @implementation
    public func translatedShaderSourceLength(_ shader: GLuint) -> GLint {
        context.translatedShaderSourceLength(shader)
    }

    @cxx
    @implementation
    public func uniform1fv(_ location: GLint, _ values: WebCore.GLLentFloats) {
        context.uniform1fv(location, values)
    }

    @cxx
    @implementation
    public func uniform1iv(_ location: GLint, _ values: WebCore.GLLentInts) {
        context.uniform1iv(location, values)
    }

    @cxx
    @implementation
    public func uniform1uiv(_ location: GLint, _ values: WebCore.GLLentUnsignedInts) {
        context.uniform1uiv(location, values)
    }

    @cxx
    @implementation
    public func uniform2fv(_ location: GLint, _ values: WebCore.GLLentFloats) {
        context.uniform2fv(location, values)
    }

    @cxx
    @implementation
    public func uniform2iv(_ location: GLint, _ values: WebCore.GLLentInts) {
        context.uniform2iv(location, values)
    }

    @cxx
    @implementation
    public func uniform2uiv(_ location: GLint, _ values: WebCore.GLLentUnsignedInts) {
        context.uniform2uiv(location, values)
    }

    @cxx
    @implementation
    public func uniform3fv(_ location: GLint, _ values: WebCore.GLLentFloats) {
        context.uniform3fv(location, values)
    }

    @cxx
    @implementation
    public func uniform3iv(_ location: GLint, _ values: WebCore.GLLentInts) {
        context.uniform3iv(location, values)
    }

    @cxx
    @implementation
    public func uniform3uiv(_ location: GLint, _ values: WebCore.GLLentUnsignedInts) {
        context.uniform3uiv(location, values)
    }

    @cxx
    @implementation
    public func uniform4fv(_ location: GLint, _ values: WebCore.GLLentFloats) {
        context.uniform4fv(location, values)
    }

    @cxx
    @implementation
    public func uniform4iv(_ location: GLint, _ values: WebCore.GLLentInts) {
        context.uniform4iv(location, values)
    }

    @cxx
    @implementation
    public func uniform4uiv(_ location: GLint, _ values: WebCore.GLLentUnsignedInts) {
        context.uniform4uiv(location, values)
    }

    @cxx
    @implementation
    public func uniformMatrix2fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        context.uniformMatrix2fv(location, transpose, values)
    }

    @cxx
    @implementation
    public func uniformMatrix2x3fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        context.uniformMatrix2x3fv(location, transpose, values)
    }

    @cxx
    @implementation
    public func uniformMatrix2x4fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        context.uniformMatrix2x4fv(location, transpose, values)
    }

    @cxx
    @implementation
    public func uniformMatrix3fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        context.uniformMatrix3fv(location, transpose, values)
    }

    @cxx
    @implementation
    public func uniformMatrix3x2fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        context.uniformMatrix3x2fv(location, transpose, values)
    }

    @cxx
    @implementation
    public func uniformMatrix3x4fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        context.uniformMatrix3x4fv(location, transpose, values)
    }

    @cxx
    @implementation
    public func uniformMatrix4fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        context.uniformMatrix4fv(location, transpose, values)
    }

    @cxx
    @implementation
    public func uniformMatrix4x2fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        context.uniformMatrix4x2fv(location, transpose, values)
    }

    @cxx
    @implementation
    public func uniformMatrix4x3fv(_ location: GLint, _ transpose: GLboolean, _ values: WebCore.GLLentFloats) {
        context.uniformMatrix4x3fv(location, transpose, values)
    }

    @cxx
    @implementation
    public func vertexAttrib1fv(_ index: GLuint, _ x: GLfloat) {
        context.vertexAttrib1fv(index, x)
    }

    @cxx
    @implementation
    public func vertexAttrib2fv(_ index: GLuint, _ x: GLfloat, _ y: GLfloat) {
        context.vertexAttrib2fv(index, x, y)
    }

    @cxx
    @implementation
    public func vertexAttrib3fv(_ index: GLuint, _ x: GLfloat, _ y: GLfloat, _ z: GLfloat) {
        context.vertexAttrib3fv(index, x, y, z)
    }

    @cxx
    @implementation
    public func vertexAttrib4fv(_ index: GLuint, _ x: GLfloat, _ y: GLfloat, _ z: GLfloat, _ w: GLfloat) {
        context.vertexAttrib4fv(index, x, y, z, w)
    }

    @cxx
    @implementation
    public func vertexAttribI4iv(_ index: GLuint, _ x: GLint, _ y: GLint, _ z: GLint, _ w: GLint) {
        context.vertexAttribI4iv(index, x, y, z, w)
    }

    @cxx
    @implementation
    public func vertexAttribI4uiv(_ index: GLuint, _ x: GLuint, _ y: GLuint, _ z: GLuint, _ w: GLuint) {
        context.vertexAttribI4uiv(index, x, y, z, w)
    }

    @cxx
    @implementation
    public func waitSync(_ sync: UInt64, _ flags: GLbitfield, _ timeout: GLint64) {
        context.waitSync(sync, flags, timeout)
    }

    @cxx
    @implementation
    public func willDestroyPlatform() {
        context.willDestroyPlatform()
    }

    @cxx
    @implementation
    public static func forgetCurrentContext() {
        GLContext.forgetCurrentContext()
    }

    @cxx
    @implementation
    public static func makeCurrent(_ display: ANGLEDisplay, _ context: ANGLEContext) -> Bool {
        GLContext.makeCurrent(display, context)
    }

    @cxx
    @implementation
    public static func reportsDebugMessage(_ type: GLenum, _ id: GLuint) -> Bool {
        GLContext.reportsDebugMessage(type, id)
    }

#if WTF_PLATFORM_COCOA
    @cxx
    @implementation
    public func destroyPlatformWithoutContext() {
        cocoaPlatform.destroyWithoutContext()
    }

    @cxx
    @implementation
    public func displayBufferSurface() -> Unmanaged<IOSurfaceRef>? {
        unsafe cocoaPlatform.displayBufferSurface().map { unsafe Unmanaged.passRetained($0) }
    }

    @cxx
    @implementation
    public func hasSpareDrawingBuffersInUse() -> Bool {
        cocoaPlatform.hasSpareDrawingBuffersInUse()
    }

    @cxx
    @implementation
    public func isPlatformValid() -> Bool {
        cocoaPlatform.isValid()
    }

    @cxx
    @implementation
    public func platformConfig() -> ANGLEConfig {
        cocoaPlatform.platformConfig()
    }

    @cxx
    @implementation
    public func platformContext() -> ANGLEContext {
        cocoaPlatform.platformContext()
    }

    @cxx
    @implementation
    public func platformDisplay() -> ANGLEDisplay {
        cocoaPlatform.platformDisplay()
    }

    @cxx
    @implementation
    public func releaseIdleSpareDrawingBuffers() {
        cocoaPlatform.releaseIdleSpareDrawingBuffers()
    }

    @cxx
    @implementation
    public func spareDrawingBufferCountForTesting() -> Int {
        cocoaPlatform.spareDrawingBufferCountForTesting()
    }

    @cxx
    @implementation
    public func volatileSpareDrawingBufferCountForTesting() -> Int {
        cocoaPlatform.volatileSpareDrawingBufferCountForTesting()
    }

    @cxx
    @implementation
    public func waitUntilWorkScheduled() {
        cocoaPlatform.waitUntilWorkScheduled()
    }

    @cxx
    @implementation
    public func copySurfaceBuffer(_ bufferType: UInt8) -> Unmanaged<IOSurfaceRef>? {
        unsafe context.copySurfaceBuffer(bufferType).map { unsafe Unmanaged.passRetained($0) }
    }

    @cxx
    @implementation
    public func didPrepareForDisplay() {
        context.didPrepareForDisplay()
    }

    @cxx
    @implementation
    public func drawingBufferColorSpaceDidChange() {
        context.drawingBufferColorSpaceDidChange()
    }

    @cxx
    @implementation
    public func readCompositedResults(_ pixels: WebCore.GLLentMutableBytes, _ width: Int32, _ height: Int32) -> Bool {
        context.readCompositedResults(pixels, width, height)
    }

    @cxx
    @implementation
    public func willPrepareForDisplay() -> Bool {
        context.willPrepareForDisplay()
    }

    @cxx
    @implementation
    public static func isDisplayInitializedForTesting(_ display: ANGLEDisplay) -> Bool {
        CocoaGLPlatform.isDisplayInitializedForTesting(display)
    }

#endif
#if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    @cxx
    @implementation
    public func copyVideoFrameToTexture(_ frame: CVPixelBuffer?, _ orientation: UInt8, _ texture: GLuint, _ target: GLenum, _ level: GLint, _ internalFormat: GLenum, _ type: GLenum, _ unpackFlipY: Bool, _ unpackPremultiplyAlpha: Bool) -> UInt8 {
        guard let frame else {
            return GLVideoUploadOutcome.unsupported.rawValue
        }
        return context.copyVideoFrameToTexture(frame, orientation, texture, target, level, internalFormat, type, unpackFlipY, unpackPremultiplyAlpha)
    }

#endif
#if WTF_PLATFORM_COCOA && ENABLE_WEBXR
    @cxx
    @implementation
    public func enableRequiredWebXRExtensions() -> Bool {
        context.enableRequiredWebXRExtensions()
    }

#endif
}
