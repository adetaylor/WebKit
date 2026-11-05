// Copyright (C) 2020 Apple Inc. All rights reserved.
// Copyright (C) 2021 Apple Inc. All rights reserved.
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

// GL state changed for the length of a closure, and restored after it.

// Binds bindingValue to a pixel pack or unpack buffer binding point while body runs, if condition holds.
func withBufferBinding<Result>(_ bindingPoint: GLenum, _ bindingValue: GLuint, condition: Bool = true, _ body: () -> Result) -> Result {
    guard condition else {
        return body()
    }
    let query = bindingPoint == GLenum(GL_PIXEL_PACK_BUFFER) ? GLenum(GL_PIXEL_PACK_BUFFER_BINDING) : GLenum(GL_PIXEL_UNPACK_BUFFER_BINDING)
    assert(bindingPoint == GLenum(GL_PIXEL_PACK_BUFFER) || bindingPoint == GLenum(GL_PIXEL_UNPACK_BUFFER))
    let previous = GLuint(bitPattern: ANGLE.getInteger(query))
    if previous == bindingValue {
        return body()
    }
    GL_BindBuffer(bindingPoint, bindingValue)
    defer {
        GL_BindBuffer(bindingPoint, previous)
    }
    return body()
}

// Binds a scratch framebuffer with texture attached as COLOR_ATTACHMENT0, as the read framebuffer, while body runs,
// so that a read is unaffected by application visible default framebuffer state such as READ_BUFFER. Restores the
// read framebuffer binding to restoreValue, then deletes the scratch framebuffer.
func withScratchReadFramebufferBinding<Result>(isForWebGL2: Bool, restoring restoreValue: GLuint, attaching texture: GLuint, _ body: () -> Result) -> Result {
    let framebuffer = ANGLE.genFramebuffer()
    defer {
        ANGLE.deleteFramebuffer(framebuffer)
    }
    return withReadFramebufferBinding(isForWebGL2: isForWebGL2, restoring: restoreValue) { binding in
        binding.bind(framebuffer)
        GL_FramebufferTexture2D(binding.target, GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
        return body()
    }
}

// The read framebuffer binding, which binding.bind() changes for the length of body, and which is restored to
// restoreValue after it if it changed.
func withReadFramebufferBinding<Result>(isForWebGL2: Bool, restoring restoreValue: GLuint, _ body: (inout GLReadFramebufferBinding) -> Result) -> Result {
    var binding = GLReadFramebufferBinding(target: isForWebGL2 ? GLenum(GL_READ_FRAMEBUFFER) : GLenum(GL_FRAMEBUFFER), restoreValue: restoreValue)
    defer {
        if binding.changed {
            GL_BindFramebuffer(binding.target, restoreValue)
        }
    }
    return body(&binding)
}

struct GLReadFramebufferBinding {
    let target: GLenum
    let restoreValue: GLuint
    private(set) var changed = false

    init(target: GLenum, restoreValue: GLuint) {
        self.target = target
        self.restoreValue = restoreValue
    }

    mutating func bind(_ framebuffer: GLuint) {
        if !changed && restoreValue == framebuffer {
            return
        }
        GL_BindFramebuffer(target, framebuffer)
        changed = restoreValue != framebuffer
    }

    mutating func markChanged() {
        changed = true
    }
}
