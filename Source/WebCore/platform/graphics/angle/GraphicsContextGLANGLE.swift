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

#if ENABLE_WEBGL

internal import WebCoreWebGL
import WebCore_Private.Core.GraphicsContextGLANGLE

// The members of GraphicsContextGLANGLE that only call the WebGL island's context. The others, which lend it memory
// or convert what it returns to WebCore types, are in GraphicsContextGLANGLE.cpp.
extension WebCore.GraphicsContextGLANGLE {
    // Only after initialize() made the context.
    private var island: GLContext {
        unsafe GLShell.fromReference(islandShell()).context!
    }

    @cxx
    @implementation
    func makeContextCurrent() -> Bool {
        unsafe GLShell.fromReference(islandShell()).context?.makeCurrentForPlatform() ?? false
    }

    @cxx
    @implementation
    func checkGPUStatus() {
        island.checkGPUStatusForPlatform()
    }

    @cxx
    @implementation
    func drawingBufferTexture() -> GCGLuint {
        island.drawingBufferTexture()
    }

    @cxx
    @implementation
    func boundReadFramebuffer() -> GCGLuint {
        island.boundReadFramebuffer()
    }

    @cxx
    @implementation
    func boundDrawFramebuffer() -> GCGLuint {
        island.boundDrawFramebuffer()
    }

    @cxx
    @implementation
    func takeFailNextDrawingBufferAllocation() -> Bool {
        island.takeFailNextDrawingBufferAllocation()
    }

    @cxx
    @implementation
    func failsNextDrawingBufferAllocation() -> Bool {
        island.failsNextDrawingBufferAllocation()
    }

    @cxx
    @implementation
    public override func activeTexture(_ texture: GCGLenum) {
        island.activeTexture(texture)
    }

    @cxx
    @implementation
    public override func attachShader(_ program: PlatformGLObject, _ shader: PlatformGLObject) {
        island.attachShader(program, shader)
    }

    @cxx
    @implementation
    public override func bindBuffer(_ target: GCGLenum, _ arg1: PlatformGLObject) {
        island.bindBuffer(target, arg1)
    }

    @cxx
    @implementation
    public override func bindFramebuffer(_ target: GCGLenum, _ arg1: PlatformGLObject) {
        island.bindFramebuffer(target, arg1)
    }

    @cxx
    @implementation
    public override func bindRenderbuffer(_ target: GCGLenum, _ arg1: PlatformGLObject) {
        island.bindRenderbuffer(target, arg1)
    }

    @cxx
    @implementation
    public override func bindTexture(_ target: GCGLenum, _ arg1: PlatformGLObject) {
        island.bindTexture(target, arg1)
    }

    @cxx
    @implementation
    public override func blendColor(_ red: GCGLclampf, _ green: GCGLclampf, _ blue: GCGLclampf, _ alpha: GCGLclampf) {
        island.blendColor(red, green, blue, alpha)
    }

    @cxx
    @implementation
    public override func blendEquation(_ mode: GCGLenum) {
        island.blendEquation(mode)
    }

    @cxx
    @implementation
    public override func blendEquationSeparate(_ modeRGB: GCGLenum, _ modeAlpha: GCGLenum) {
        island.blendEquationSeparate(modeRGB, modeAlpha)
    }

    @cxx
    @implementation
    public override func blendFunc(_ sfactor: GCGLenum, _ dfactor: GCGLenum) {
        island.blendFunc(sfactor, dfactor)
    }

    @cxx
    @implementation
    public override func blendFuncSeparate(_ srcRGB: GCGLenum, _ dstRGB: GCGLenum, _ srcAlpha: GCGLenum, _ dstAlpha: GCGLenum) {
        island.blendFuncSeparate(srcRGB, dstRGB, srcAlpha, dstAlpha)
    }

    @cxx
    @implementation
    public override func bufferData(_ target: GCGLenum, _ size: GCGLsizeiptr, _ usage: GCGLenum) {
        island.bufferDataUninitialized(target, size, usage)
    }

    @cxx
    @implementation
    public override func checkFramebufferStatus(_ target: GCGLenum) -> GCGLenum {
        island.checkFramebufferStatus(target)
    }

    @cxx
    @implementation
    public override func clear(_ mask: GCGLbitfield) {
        island.clear(mask)
    }

    @cxx
    @implementation
    public override func clearColor(_ red: GCGLclampf, _ green: GCGLclampf, _ blue: GCGLclampf, _ alpha: GCGLclampf) {
        island.clearColor(red, green, blue, alpha)
    }

    @cxx
    @implementation
    public override func clearDepth(_ depth: GCGLclampf) {
        island.clearDepth(depth)
    }

    @cxx
    @implementation
    public override func clearStencil(_ s: GCGLint) {
        island.clearStencil(s)
    }

    @cxx
    @implementation
    public override func colorMask(_ red: GCGLboolean, _ green: GCGLboolean, _ blue: GCGLboolean, _ alpha: GCGLboolean) {
        island.colorMask(red, green, blue, alpha)
    }

    @cxx
    @implementation
    public override func compileShader(_ arg0: PlatformGLObject) {
        island.compileShader(arg0)
    }

    @cxx
    @implementation
    public override func copyTexImage2D(_ target: GCGLenum, _ level: GCGLint, _ internalformat: GCGLenum, _ x: GCGLint, _ y: GCGLint, _ width: GCGLsizei, _ height: GCGLsizei, _ border: GCGLint) {
        island.copyTexImage2D(target, level, internalformat, x, y, width, height, border)
    }

    @cxx
    @implementation
    public override func copyTexSubImage2D(_ target: GCGLenum, _ level: GCGLint, _ xoffset: GCGLint, _ yoffset: GCGLint, _ x: GCGLint, _ y: GCGLint, _ width: GCGLsizei, _ height: GCGLsizei) {
        island.copyTexSubImage2D(target, level, xoffset, yoffset, x, y, width, height)
    }

    @cxx
    @implementation
    public override func cullFace(_ mode: GCGLenum) {
        island.cullFace(mode)
    }

    @cxx
    @implementation
    public override func depthFunc(_ function: GCGLenum) {
        island.depthFunc(function)
    }

    @cxx
    @implementation
    public override func depthMask(_ flag: GCGLboolean) {
        island.depthMask(flag)
    }

    @cxx
    @implementation
    public override func depthRange(_ zNear: GCGLclampf, _ zFar: GCGLclampf) {
        island.depthRange(zNear, zFar)
    }

    @cxx
    @implementation
    public override func detachShader(_ arg0: PlatformGLObject, _ arg1: PlatformGLObject) {
        island.detachShader(arg0, arg1)
    }

    @cxx
    @implementation
    public override func disable(_ cap: GCGLenum) {
        island.disable(cap)
    }

    @cxx
    @implementation
    public override func disableVertexAttribArray(_ index: GCGLuint) {
        island.disableVertexAttribArray(index)
    }

    @cxx
    @implementation
    public override func drawArrays(_ mode: GCGLenum, _ first: GCGLint, _ count: GCGLsizei) {
        island.drawArrays(mode, first, count)
    }

    @cxx
    @implementation
    public override func drawElements(_ mode: GCGLenum, _ count: GCGLsizei, _ type: GCGLenum, _ offset: GCGLintptr) {
        island.drawElements(mode, count, type, offset)
    }

    @cxx
    @implementation
    public override func enable(_ cap: GCGLenum) {
        island.enable(cap)
    }

    @cxx
    @implementation
    public override func enableVertexAttribArray(_ index: GCGLuint) {
        island.enableVertexAttribArray(index)
    }

    @cxx
    @implementation
    public override func finish() {
        island.finish()
    }

    @cxx
    @implementation
    public override func flush() {
        island.flush()
    }

    @cxx
    @implementation
    public override func framebufferRenderbuffer(_ target: GCGLenum, _ attachment: GCGLenum, _ renderbuffertarget: GCGLenum, _ arg3: PlatformGLObject) {
        island.framebufferRenderbuffer(target, attachment, renderbuffertarget, arg3)
    }

    @cxx
    @implementation
    public override func framebufferTexture2D(_ target: GCGLenum, _ attachment: GCGLenum, _ textarget: GCGLenum, _ arg3: PlatformGLObject, _ level: GCGLint) {
        island.framebufferTexture2D(target, attachment, textarget, arg3, level)
    }

    @cxx
    @implementation
    public override func frontFace(_ mode: GCGLenum) {
        island.frontFace(mode)
    }

    @cxx
    @implementation
    public override func generateMipmap(_ target: GCGLenum) {
        island.generateMipmap(target)
    }

    @cxx
    @implementation
    public override func getBufferParameteri(_ target: GCGLenum, _ pname: GCGLenum) -> GCGLint {
        island.getBufferParameteri(target, pname)
    }

    @cxx
    @implementation
    public override func getFramebufferAttachmentParameteri(_ target: GCGLenum, _ attachment: GCGLenum, _ pname: GCGLenum) -> GCGLint {
        island.getFramebufferAttachmentParameteri(target, attachment, pname)
    }

    @cxx
    @implementation
    public override func getInteger64(_ pname: GCGLenum) -> GCGLint64 {
        island.getInteger64(pname)
    }

    @cxx
    @implementation
    public override func getInteger64i(_ pname: GCGLenum, _ index: GCGLuint) -> GCGLint64 {
        island.getInteger64i(pname, index)
    }

    @cxx
    @implementation
    public override func getProgrami(_ program: PlatformGLObject, _ pname: GCGLenum) -> GCGLint {
        island.getProgrami(program, pname)
    }

    @cxx
    @implementation
    public override func getRenderbufferParameteri(_ target: GCGLenum, _ pname: GCGLenum) -> GCGLint {
        island.getRenderbufferParameteri(target, pname)
    }

    @cxx
    @implementation
    public override func getShaderi(_ arg0: PlatformGLObject, _ pname: GCGLenum) -> GCGLint {
        island.getShaderi(arg0, pname)
    }

    @cxx
    @implementation
    public override func getTexParameterf(_ target: GCGLenum, _ pname: GCGLenum) -> GCGLfloat {
        island.getTexParameterf(target, pname)
    }

    @cxx
    @implementation
    public override func getTexParameteri(_ target: GCGLenum, _ pname: GCGLenum) -> GCGLint {
        island.getTexParameteri(target, pname)
    }

    @cxx
    @implementation
    public override func getVertexAttribOffset(_ index: GCGLuint, _ pname: GCGLenum) -> GCGLsizeiptr {
        island.getVertexAttribOffset(index, pname)
    }

    @cxx
    @implementation
    public override func hint(_ target: GCGLenum, _ mode: GCGLenum) {
        island.hint(target, mode)
    }

    @cxx
    @implementation
    public override func isBuffer(_ arg0: PlatformGLObject) -> GCGLboolean {
        island.isBuffer(arg0)
    }

    @cxx
    @implementation
    public override func isEnabled(_ cap: GCGLenum) -> GCGLboolean {
        island.isEnabled(cap)
    }

    @cxx
    @implementation
    public override func isFramebuffer(_ arg0: PlatformGLObject) -> GCGLboolean {
        island.isFramebuffer(arg0)
    }

    @cxx
    @implementation
    public override func isProgram(_ arg0: PlatformGLObject) -> GCGLboolean {
        island.isProgram(arg0)
    }

    @cxx
    @implementation
    public override func isRenderbuffer(_ arg0: PlatformGLObject) -> GCGLboolean {
        island.isRenderbuffer(arg0)
    }

    @cxx
    @implementation
    public override func isShader(_ arg0: PlatformGLObject) -> GCGLboolean {
        island.isShader(arg0)
    }

    @cxx
    @implementation
    public override func isTexture(_ arg0: PlatformGLObject) -> GCGLboolean {
        island.isTexture(arg0)
    }

    @cxx
    @implementation
    public override func lineWidth(_ arg0: GCGLfloat) {
        island.lineWidth(arg0)
    }

    @cxx
    @implementation
    public override func linkProgram(_ arg0: PlatformGLObject) {
        island.linkProgram(arg0)
    }

    @cxx
    @implementation
    public override func pixelStorei(_ pname: GCGLenum, _ param: GCGLint) {
        island.pixelStorei(pname, param)
    }

    @cxx
    @implementation
    public override func polygonOffset(_ factor: GCGLfloat, _ units: GCGLfloat) {
        island.polygonOffset(factor, units)
    }

    @cxx
    @implementation
    public override func renderbufferStorage(_ target: GCGLenum, _ internalformat: GCGLenum, _ width: GCGLsizei, _ height: GCGLsizei) {
        island.renderbufferStorage(target, internalformat, width, height)
    }

    @cxx
    @implementation
    public override func sampleCoverage(_ value: GCGLclampf, _ invert: GCGLboolean) {
        island.sampleCoverage(value, invert)
    }

    @cxx
    @implementation
    public override func scissor(_ x: GCGLint, _ y: GCGLint, _ width: GCGLsizei, _ height: GCGLsizei) {
        island.scissor(x, y, width, height)
    }

    @cxx
    @implementation
    public override func stencilFunc(_ function: GCGLenum, _ ref: GCGLint, _ mask: GCGLuint) {
        island.stencilFunc(function, ref, mask)
    }

    @cxx
    @implementation
    public override func stencilFuncSeparate(_ face: GCGLenum, _ function: GCGLenum, _ ref: GCGLint, _ mask: GCGLuint) {
        island.stencilFuncSeparate(face, function, ref, mask)
    }

    @cxx
    @implementation
    public override func stencilMask(_ mask: GCGLuint) {
        island.stencilMask(mask)
    }

    @cxx
    @implementation
    public override func stencilMaskSeparate(_ face: GCGLenum, _ mask: GCGLuint) {
        island.stencilMaskSeparate(face, mask)
    }

    @cxx
    @implementation
    public override func stencilOp(_ fail: GCGLenum, _ zfail: GCGLenum, _ zpass: GCGLenum) {
        island.stencilOp(fail, zfail, zpass)
    }

    @cxx
    @implementation
    public override func stencilOpSeparate(_ face: GCGLenum, _ fail: GCGLenum, _ zfail: GCGLenum, _ zpass: GCGLenum) {
        island.stencilOpSeparate(face, fail, zfail, zpass)
    }

    @cxx
    @implementation
    public override func texImage2D(_ target: GCGLenum, _ level: GCGLint, _ internalformat: GCGLenum, _ width: GCGLsizei, _ height: GCGLsizei, _ border: GCGLint, _ format: GCGLenum, _ type: GCGLenum, _ offset: GCGLintptr) {
        island.texImage2DFromUnpackBuffer(target, level, internalformat, width, height, border, format, type, offset)
    }

    @cxx
    @implementation
    public override func texSubImage2D(_ target: GCGLenum, _ level: GCGLint, _ xoffset: GCGLint, _ yoffset: GCGLint, _ width: GCGLsizei, _ height: GCGLsizei, _ format: GCGLenum, _ type: GCGLenum, _ offset: GCGLintptr) {
        island.texSubImage2DFromUnpackBuffer(target, level, xoffset, yoffset, width, height, format, type, offset)
    }

    @cxx
    @implementation
    public override func compressedTexImage2D(_ target: GCGLenum, _ level: GCGLint, _ internalformat: GCGLenum, _ width: GCGLsizei, _ height: GCGLsizei, _ border: GCGLint, _ imageSize: GCGLsizei, _ offset: GCGLintptr) {
        island.compressedTexImage2DFromUnpackBuffer(target, level, internalformat, width, height, border, imageSize, offset)
    }

    @cxx
    @implementation
    public override func compressedTexSubImage2D(_ target: GCGLenum, _ level: GCGLint, _ xoffset: GCGLint, _ yoffset: GCGLint, _ width: GCGLsizei, _ height: GCGLsizei, _ format: GCGLenum, _ imageSize: GCGLsizei, _ offset: GCGLintptr) {
        island.compressedTexSubImage2DFromUnpackBuffer(target, level, xoffset, yoffset, width, height, format, imageSize, offset)
    }

    @cxx
    @implementation
    public override func texParameterf(_ target: GCGLenum, _ pname: GCGLenum, _ param: GCGLfloat) {
        island.texParameterf(target, pname, param)
    }

    @cxx
    @implementation
    public override func texParameteri(_ target: GCGLenum, _ pname: GCGLenum, _ param: GCGLint) {
        island.texParameteri(target, pname, param)
    }

    @cxx
    @implementation
    public override func uniform1f(_ location: GCGLint, _ x: GCGLfloat) {
        island.uniform1f(location, x)
    }

    @cxx
    @implementation
    public override func uniform1i(_ location: GCGLint, _ x: GCGLint) {
        island.uniform1i(location, x)
    }

    @cxx
    @implementation
    public override func uniform2f(_ location: GCGLint, _ x: GCGLfloat, _ y: GCGLfloat) {
        island.uniform2f(location, x, y)
    }

    @cxx
    @implementation
    public override func uniform2i(_ location: GCGLint, _ x: GCGLint, _ y: GCGLint) {
        island.uniform2i(location, x, y)
    }

    @cxx
    @implementation
    public override func uniform3f(_ location: GCGLint, _ x: GCGLfloat, _ y: GCGLfloat, _ z: GCGLfloat) {
        island.uniform3f(location, x, y, z)
    }

    @cxx
    @implementation
    public override func uniform3i(_ location: GCGLint, _ x: GCGLint, _ y: GCGLint, _ z: GCGLint) {
        island.uniform3i(location, x, y, z)
    }

    @cxx
    @implementation
    public override func uniform4f(_ location: GCGLint, _ x: GCGLfloat, _ y: GCGLfloat, _ z: GCGLfloat, _ w: GCGLfloat) {
        island.uniform4f(location, x, y, z, w)
    }

    @cxx
    @implementation
    public override func uniform4i(_ location: GCGLint, _ x: GCGLint, _ y: GCGLint, _ z: GCGLint, _ w: GCGLint) {
        island.uniform4i(location, x, y, z, w)
    }

    @cxx
    @implementation
    public override func useProgram(_ arg0: PlatformGLObject) {
        island.useProgram(arg0)
    }

    @cxx
    @implementation
    public override func validateProgram(_ arg0: PlatformGLObject) {
        island.validateProgram(arg0)
    }

    @cxx
    @implementation
    public override func vertexAttrib1f(_ index: GCGLuint, _ x: GCGLfloat) {
        island.vertexAttrib1f(index, x)
    }

    @cxx
    @implementation
    public override func vertexAttrib2f(_ index: GCGLuint, _ x: GCGLfloat, _ y: GCGLfloat) {
        island.vertexAttrib2f(index, x, y)
    }

    @cxx
    @implementation
    public override func vertexAttrib3f(_ index: GCGLuint, _ x: GCGLfloat, _ y: GCGLfloat, _ z: GCGLfloat) {
        island.vertexAttrib3f(index, x, y, z)
    }

    @cxx
    @implementation
    public override func vertexAttrib4f(_ index: GCGLuint, _ x: GCGLfloat, _ y: GCGLfloat, _ z: GCGLfloat, _ w: GCGLfloat) {
        island.vertexAttrib4f(index, x, y, z, w)
    }

    @cxx
    @implementation
    public override func vertexAttribPointer(_ index: GCGLuint, _ size: GCGLint, _ type: GCGLenum, _ normalized: GCGLboolean, _ stride: GCGLsizei, _ offset: GCGLintptr) {
        island.vertexAttribPointer(index, size, type, normalized, stride, offset)
    }

    @cxx
    @implementation
    public override func viewport(_ x: GCGLint, _ y: GCGLint, _ width: GCGLsizei, _ height: GCGLsizei) {
        island.viewport(x, y, width, height)
    }

    @cxx
    @implementation
    public override func drawArraysInstanced(_ mode: GCGLenum, _ first: GCGLint, _ count: GCGLsizei, _ primcount: GCGLsizei) {
        island.drawArraysInstanced(mode, first, count, primcount)
    }

    @cxx
    @implementation
    public override func drawElementsInstanced(_ mode: GCGLenum, _ count: GCGLsizei, _ type: GCGLenum, _ offset: GCGLintptr, _ primcount: GCGLsizei) {
        island.drawElementsInstanced(mode, count, type, offset, primcount)
    }

    @cxx
    @implementation
    public override func vertexAttribDivisor(_ index: GCGLuint, _ divisor: GCGLuint) {
        island.vertexAttribDivisor(index, divisor)
    }

    @cxx
    @implementation
    public override func createVertexArray() -> PlatformGLObject {
        island.createVertexArray()
    }

    @cxx
    @implementation
    public override func deleteVertexArray(_ arg0: PlatformGLObject) {
        island.deleteVertexArray(arg0)
    }

    @cxx
    @implementation
    public override func isVertexArray(_ arg0: PlatformGLObject) -> GCGLboolean {
        island.isVertexArray(arg0)
    }

    @cxx
    @implementation
    public override func bindVertexArray(_ arg0: PlatformGLObject) {
        island.bindVertexArray(arg0)
    }

    @cxx
    @implementation
    public override func copyBufferSubData(_ readTarget: GCGLenum, _ writeTarget: GCGLenum, _ readOffset: GCGLintptr, _ writeOffset: GCGLintptr, _ arg4: GCGLsizeiptr) {
        island.copyBufferSubData(readTarget, writeTarget, readOffset, writeOffset, arg4)
    }

    @cxx
    @implementation
    public override func blitFramebuffer(_ srcX0: GCGLint, _ srcY0: GCGLint, _ srcX1: GCGLint, _ srcY1: GCGLint, _ dstX0: GCGLint, _ dstY0: GCGLint, _ dstX1: GCGLint, _ dstY1: GCGLint, _ mask: GCGLbitfield, _ filter: GCGLenum) {
        island.blitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter)
    }

    @cxx
    @implementation
    public override func framebufferTextureLayer(_ target: GCGLenum, _ attachment: GCGLenum, _ texture: PlatformGLObject, _ level: GCGLint, _ layer: GCGLint) {
        island.framebufferTextureLayer(target, attachment, texture, level, layer)
    }

    @cxx
    @implementation
    public override func readBuffer(_ src: GCGLenum) {
        island.readBuffer(src)
    }

    @cxx
    @implementation
    public override func renderbufferStorageMultisample(_ target: GCGLenum, _ samples: GCGLsizei, _ internalformat: GCGLenum, _ width: GCGLsizei, _ height: GCGLsizei) {
        island.renderbufferStorageMultisample(target, samples, internalformat, width, height)
    }

    @cxx
    @implementation
    public override func texStorage2D(_ target: GCGLenum, _ levels: GCGLsizei, _ internalformat: GCGLenum, _ width: GCGLsizei, _ height: GCGLsizei) {
        island.texStorage2D(target, levels, internalformat, width, height)
    }

    @cxx
    @implementation
    public override func texStorage3D(_ target: GCGLenum, _ levels: GCGLsizei, _ internalformat: GCGLenum, _ width: GCGLsizei, _ height: GCGLsizei, _ depth: GCGLsizei) {
        island.texStorage3D(target, levels, internalformat, width, height, depth)
    }

    @cxx
    @implementation
    public override func texImage3D(_ target: GCGLenum, _ level: GCGLint, _ internalformat: GCGLint, _ width: GCGLsizei, _ height: GCGLsizei, _ depth: GCGLsizei, _ border: GCGLint, _ format: GCGLenum, _ type: GCGLenum, _ offset: GCGLintptr) {
        island.texImage3DFromUnpackBuffer(target, level, internalformat, width, height, depth, border, format, type, offset)
    }

    @cxx
    @implementation
    public override func texSubImage3D(_ target: GCGLenum, _ level: GCGLint, _ xoffset: GCGLint, _ yoffset: GCGLint, _ zoffset: GCGLint, _ width: GCGLsizei, _ height: GCGLsizei, _ depth: GCGLsizei, _ format: GCGLenum, _ type: GCGLenum, _ offset: GCGLintptr) {
        island.texSubImage3DFromUnpackBuffer(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, offset)
    }

    @cxx
    @implementation
    public override func copyTexSubImage3D(_ target: GCGLenum, _ level: GCGLint, _ xoffset: GCGLint, _ yoffset: GCGLint, _ zoffset: GCGLint, _ x: GCGLint, _ y: GCGLint, _ width: GCGLsizei, _ height: GCGLsizei) {
        island.copyTexSubImage3D(target, level, xoffset, yoffset, zoffset, x, y, width, height)
    }

    @cxx
    @implementation
    public override func compressedTexImage3D(_ target: GCGLenum, _ level: GCGLint, _ internalformat: GCGLenum, _ width: GCGLsizei, _ height: GCGLsizei, _ depth: GCGLsizei, _ border: GCGLint, _ imageSize: GCGLsizei, _ offset: GCGLintptr) {
        island.compressedTexImage3DFromUnpackBuffer(target, level, internalformat, width, height, depth, border, imageSize, offset)
    }

    @cxx
    @implementation
    public override func compressedTexSubImage3D(_ target: GCGLenum, _ level: GCGLint, _ xoffset: GCGLint, _ yoffset: GCGLint, _ zoffset: GCGLint, _ width: GCGLsizei, _ height: GCGLsizei, _ depth: GCGLsizei, _ format: GCGLenum, _ imageSize: GCGLsizei, _ offset: GCGLintptr) {
        island.compressedTexSubImage3DFromUnpackBuffer(target, level, xoffset, yoffset, zoffset, width, height, depth, format, imageSize, offset)
    }

    @cxx
    @implementation
    public override func uniform1ui(_ location: GCGLint, _ v0: GCGLuint) {
        island.uniform1ui(location, v0)
    }

    @cxx
    @implementation
    public override func uniform2ui(_ location: GCGLint, _ v0: GCGLuint, _ v1: GCGLuint) {
        island.uniform2ui(location, v0, v1)
    }

    @cxx
    @implementation
    public override func uniform3ui(_ location: GCGLint, _ v0: GCGLuint, _ v1: GCGLuint, _ v2: GCGLuint) {
        island.uniform3ui(location, v0, v1, v2)
    }

    @cxx
    @implementation
    public override func uniform4ui(_ location: GCGLint, _ v0: GCGLuint, _ v1: GCGLuint, _ v2: GCGLuint, _ v3: GCGLuint) {
        island.uniform4ui(location, v0, v1, v2, v3)
    }

    @cxx
    @implementation
    public override func vertexAttribI4i(_ index: GCGLuint, _ x: GCGLint, _ y: GCGLint, _ z: GCGLint, _ w: GCGLint) {
        island.vertexAttribI4i(index, x, y, z, w)
    }

    @cxx
    @implementation
    public override func vertexAttribI4ui(_ index: GCGLuint, _ x: GCGLuint, _ y: GCGLuint, _ z: GCGLuint, _ w: GCGLuint) {
        island.vertexAttribI4ui(index, x, y, z, w)
    }

    @cxx
    @implementation
    public override func vertexAttribIPointer(_ index: GCGLuint, _ size: GCGLint, _ type: GCGLenum, _ stride: GCGLsizei, _ offset: GCGLintptr) {
        island.vertexAttribIPointer(index, size, type, stride, offset)
    }

    @cxx
    @implementation
    public override func drawRangeElements(_ mode: GCGLenum, _ start: GCGLuint, _ end: GCGLuint, _ count: GCGLsizei, _ type: GCGLenum, _ offset: GCGLintptr) {
        island.drawRangeElements(mode, start, end, count, type, offset)
    }

    @cxx
    @implementation
    public override func clearBufferfi(_ buffer: GCGLenum, _ drawbuffer: GCGLint, _ depth: GCGLfloat, _ stencil: GCGLint) {
        island.clearBufferfi(buffer, drawbuffer, depth, stencil)
    }

    @cxx
    @implementation
    public override func createQuery() -> PlatformGLObject {
        island.createQuery()
    }

    @cxx
    @implementation
    public override func deleteQuery(_ query: PlatformGLObject) {
        island.deleteQuery(query)
    }

    @cxx
    @implementation
    public override func isQuery(_ query: PlatformGLObject) -> GCGLboolean {
        island.isQuery(query)
    }

    @cxx
    @implementation
    public override func beginQuery(_ target: GCGLenum, _ query: PlatformGLObject) {
        island.beginQuery(target, query)
    }

    @cxx
    @implementation
    public override func endQuery(_ target: GCGLenum) {
        island.endQuery(target)
    }

    @cxx
    @implementation
    public override func getQuery(_ target: GCGLenum, _ pname: GCGLenum) -> GCGLint {
        island.getQuery(target, pname)
    }

    @cxx
    @implementation
    public override func getQueryObjectui(_ query: PlatformGLObject, _ pname: GCGLenum) -> GCGLuint {
        island.getQueryObjectui(query, pname)
    }

    @cxx
    @implementation
    public override func createSampler() -> PlatformGLObject {
        island.createSampler()
    }

    @cxx
    @implementation
    public override func deleteSampler(_ sampler: PlatformGLObject) {
        island.deleteSampler(sampler)
    }

    @cxx
    @implementation
    public override func isSampler(_ sampler: PlatformGLObject) -> GCGLboolean {
        island.isSampler(sampler)
    }

    @cxx
    @implementation
    public override func bindSampler(_ unit: GCGLuint, _ sampler: PlatformGLObject) {
        island.bindSampler(unit, sampler)
    }

    @cxx
    @implementation
    public override func samplerParameteri(_ sampler: PlatformGLObject, _ pname: GCGLenum, _ param: GCGLint) {
        island.samplerParameteri(sampler, pname, param)
    }

    @cxx
    @implementation
    public override func samplerParameterf(_ sampler: PlatformGLObject, _ pname: GCGLenum, _ param: GCGLfloat) {
        island.samplerParameterf(sampler, pname, param)
    }

    @cxx
    @implementation
    public override func getSamplerParameterf(_ sampler: PlatformGLObject, _ pname: GCGLenum) -> GCGLfloat {
        island.getSamplerParameterf(sampler, pname)
    }

    @cxx
    @implementation
    public override func getSamplerParameteri(_ sampler: PlatformGLObject, _ pname: GCGLenum) -> GCGLint {
        island.getSamplerParameteri(sampler, pname)
    }

    @cxx
    @implementation
    public override func createTransformFeedback() -> PlatformGLObject {
        island.createTransformFeedback()
    }

    @cxx
    @implementation
    public override func deleteTransformFeedback(_ id: PlatformGLObject) {
        island.deleteTransformFeedback(id)
    }

    @cxx
    @implementation
    public override func isTransformFeedback(_ id: PlatformGLObject) -> GCGLboolean {
        island.isTransformFeedback(id)
    }

    @cxx
    @implementation
    public override func bindTransformFeedback(_ target: GCGLenum, _ id: PlatformGLObject) {
        island.bindTransformFeedback(target, id)
    }

    @cxx
    @implementation
    public override func beginTransformFeedback(_ primitiveMode: GCGLenum) {
        island.beginTransformFeedback(primitiveMode)
    }

    @cxx
    @implementation
    public override func endTransformFeedback() {
        island.endTransformFeedback()
    }

    @cxx
    @implementation
    public override func pauseTransformFeedback() {
        island.pauseTransformFeedback()
    }

    @cxx
    @implementation
    public override func resumeTransformFeedback() {
        island.resumeTransformFeedback()
    }

    @cxx
    @implementation
    public override func bindBufferBase(_ target: GCGLenum, _ index: GCGLuint, _ buffer: PlatformGLObject) {
        island.bindBufferBase(target, index, buffer)
    }

    @cxx
    @implementation
    public override func bindBufferRange(_ target: GCGLenum, _ index: GCGLuint, _ buffer: PlatformGLObject, _ offset: GCGLintptr, _ arg4: GCGLsizeiptr) {
        island.bindBufferRange(target, index, buffer, offset, arg4)
    }

    @cxx
    @implementation
    public override func uniformBlockBinding(_ program: PlatformGLObject, _ uniformBlockIndex: GCGLuint, _ uniformBlockBinding: GCGLuint) {
        island.uniformBlockBinding(program, uniformBlockIndex, uniformBlockBinding)
    }

    @cxx
    @implementation
    public override func deleteExternalImage(_ image: GCGLExternalImage) {
        island.deleteExternalImage(image)
    }

    @cxx
    @implementation
    public override func deleteExternalSync(_ sync: GCGLExternalSync) {
        island.deleteExternalSync(sync)
    }

    @cxx
    @implementation
    public override func createQueryEXT() -> PlatformGLObject {
        island.createQueryEXT()
    }

    @cxx
    @implementation
    public override func deleteQueryEXT(_ query: PlatformGLObject) {
        island.deleteQueryEXT(query)
    }

    @cxx
    @implementation
    public override func isQueryEXT(_ query: PlatformGLObject) -> GCGLboolean {
        island.isQueryEXT(query)
    }

    @cxx
    @implementation
    public override func beginQueryEXT(_ target: GCGLenum, _ query: PlatformGLObject) {
        island.beginQueryEXT(target, query)
    }

    @cxx
    @implementation
    public override func endQueryEXT(_ target: GCGLenum) {
        island.endQueryEXT(target)
    }

    @cxx
    @implementation
    public override func queryCounterEXT(_ query: PlatformGLObject, _ target: GCGLenum) {
        island.queryCounterEXT(query, target)
    }

    @cxx
    @implementation
    public override func getQueryiEXT(_ target: GCGLenum, _ pname: GCGLenum) -> GCGLint {
        island.getQueryiEXT(target, pname)
    }

    @cxx
    @implementation
    public override func getQueryObjectiEXT(_ query: PlatformGLObject, _ pname: GCGLenum) -> GCGLint {
        island.getQueryObjectiEXT(query, pname)
    }

    @cxx
    @implementation
    public override func getQueryObjectui64EXT(_ query: PlatformGLObject, _ pname: GCGLenum) -> GCGLuint64 {
        island.getQueryObjectui64EXT(query, pname)
    }

    @cxx
    @implementation
    public override func getInteger64EXT(_ pname: GCGLenum) -> GCGLint64 {
        island.getInteger64EXT(pname)
    }

    @cxx
    @implementation
    public override func enableiOES(_ target: GCGLenum, _ index: GCGLuint) {
        island.enableiOES(target, index)
    }

    @cxx
    @implementation
    public override func disableiOES(_ target: GCGLenum, _ index: GCGLuint) {
        island.disableiOES(target, index)
    }

    @cxx
    @implementation
    public override func blendEquationiOES(_ buf: GCGLuint, _ mode: GCGLenum) {
        island.blendEquationiOES(buf, mode)
    }

    @cxx
    @implementation
    public override func blendEquationSeparateiOES(_ buf: GCGLuint, _ modeRGB: GCGLenum, _ modeAlpha: GCGLenum) {
        island.blendEquationSeparateiOES(buf, modeRGB, modeAlpha)
    }

    @cxx
    @implementation
    public override func blendFunciOES(_ buf: GCGLuint, _ src: GCGLenum, _ dst: GCGLenum) {
        island.blendFunciOES(buf, src, dst)
    }

    @cxx
    @implementation
    public override func blendFuncSeparateiOES(_ buf: GCGLuint, _ srcRGB: GCGLenum, _ dstRGB: GCGLenum, _ srcAlpha: GCGLenum, _ dstAlpha: GCGLenum) {
        island.blendFuncSeparateiOES(buf, srcRGB, dstRGB, srcAlpha, dstAlpha)
    }

    @cxx
    @implementation
    public override func colorMaskiOES(_ buf: GCGLuint, _ red: GCGLboolean, _ green: GCGLboolean, _ blue: GCGLboolean, _ alpha: GCGLboolean) {
        island.colorMaskiOES(buf, red, green, blue, alpha)
    }

    @cxx
    @implementation
    public override func drawArraysInstancedBaseInstanceANGLE(_ mode: GCGLenum, _ first: GCGLint, _ count: GCGLsizei, _ instanceCount: GCGLsizei, _ baseInstance: GCGLuint) {
        island.drawArraysInstancedBaseInstanceANGLE(mode, first, count, instanceCount, baseInstance)
    }

    @cxx
    @implementation
    public override func drawElementsInstancedBaseVertexBaseInstanceANGLE(_ mode: GCGLenum, _ count: GCGLsizei, _ type: GCGLenum, _ offset: GCGLintptr, _ instanceCount: GCGLsizei, _ baseVertex: GCGLint, _ baseInstance: GCGLuint) {
        island.drawElementsInstancedBaseVertexBaseInstanceANGLE(mode, count, type, offset, instanceCount, baseVertex, baseInstance)
    }

    @cxx
    @implementation
    public override func clipControlEXT(_ origin: GCGLenum, _ depth: GCGLenum) {
        island.clipControlEXT(origin, depth)
    }

    @cxx
    @implementation
    public override func provokingVertexANGLE(_ provokeMode: GCGLenum) {
        island.provokingVertexANGLE(provokeMode)
    }

    @cxx
    @implementation
    public override func polygonModeANGLE(_ face: GCGLenum, _ mode: GCGLenum) {
        island.polygonModeANGLE(face, mode)
    }

    @cxx
    @implementation
    public override func polygonOffsetClampEXT(_ factor: GCGLfloat, _ units: GCGLfloat, _ clamp: GCGLfloat) {
        island.polygonOffsetClampEXT(factor, units, clamp)
    }

    @cxx
    @implementation
    public override func renderbufferStorageMultisampleANGLE(_ target: GCGLenum, _ samples: GCGLsizei, _ internalformat: GCGLenum, _ width: GCGLsizei, _ height: GCGLsizei) {
        island.renderbufferStorageMultisampleANGLE(target, samples, internalformat, width, height)
    }

    @cxx
    @implementation
    public override func createBuffer() -> PlatformGLObject {
        island.createBuffer()
    }

    @cxx
    @implementation
    public override func createFramebuffer() -> PlatformGLObject {
        island.createFramebuffer()
    }

    @cxx
    @implementation
    public override func createProgram() -> PlatformGLObject {
        island.createProgram()
    }

    @cxx
    @implementation
    public override func createRenderbuffer() -> PlatformGLObject {
        island.createRenderbuffer()
    }

    @cxx
    @implementation
    public override func createShader(_ arg0: GCGLenum) -> PlatformGLObject {
        island.createShader(arg0)
    }

    @cxx
    @implementation
    public override func createTexture() -> PlatformGLObject {
        island.createTexture()
    }

    @cxx
    @implementation
    public override func deleteBuffer(_ arg0: PlatformGLObject) {
        island.deleteBuffer(arg0)
    }

    @cxx
    @implementation
    public override func deleteFramebuffer(_ arg0: PlatformGLObject) {
        island.deleteFramebuffer(arg0)
    }

    @cxx
    @implementation
    public override func deleteProgram(_ arg0: PlatformGLObject) {
        island.deleteProgram(arg0)
    }

    @cxx
    @implementation
    public override func deleteRenderbuffer(_ arg0: PlatformGLObject) {
        island.deleteRenderbuffer(arg0)
    }

    @cxx
    @implementation
    public override func deleteShader(_ arg0: PlatformGLObject) {
        island.deleteShader(arg0)
    }

    @cxx
    @implementation
    public override func deleteTexture(_ arg0: PlatformGLObject) {
        island.deleteTexture(arg0)
    }
}

#endif
