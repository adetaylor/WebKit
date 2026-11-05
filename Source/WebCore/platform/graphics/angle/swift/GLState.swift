// Copyright (C) 2009, 2014-2019 Apple Inc. All rights reserved.
// Copyright (C) 2010, 2013 Apple Inc. All rights reserved.
// Copyright (C) 2019 Apple Inc. All rights reserved.
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

// The island's strings are Swift's, not the String of wtf, which its C++ modules bring in.
typealias String = Swift.String

// The errors a context has recorded and not yet returned from getErrors(), as GCGLErrorCodeSet's raw value.
struct GLErrorCodes: OptionSet {
    let rawValue: UInt8

    static let contextLost = GLErrorCodes(rawValue: 1)
    static let invalidFramebufferOperation = GLErrorCodes(rawValue: 1 << 1)
    static let outOfMemory = GLErrorCodes(rawValue: 1 << 2)
    static let invalidOperation = GLErrorCodes(rawValue: 1 << 3)
    static let invalidValue = GLErrorCodes(rawValue: 1 << 4)
    static let invalidEnum = GLErrorCodes(rawValue: 1 << 5)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(glError: GLenum) {
        switch glError {
        case GLenum(GL_INVALID_ENUM):
            self = .invalidEnum
        case GLenum(GL_INVALID_VALUE):
            self = .invalidValue
        case GLenum(GL_INVALID_OPERATION):
            self = .invalidOperation
        case GLenum(GL_OUT_OF_MEMORY):
            self = .outOfMemory
        case GLenum(GL_INVALID_FRAMEBUFFER_OPERATION):
            self = .invalidFramebufferOperation
        case GLenum(GL_CONTEXT_LOST), GLContextConstants.contextLostWebGL:
            self = .contextLost
        default:
            assertionFailure()
            self = .invalidOperation
        }
    }
}

enum GLContextConstants {
    static let contextLostWebGL: GLenum = 0x9242
}

// The texture each texture unit has bound, with its target. Units past the dense ones are kept too, since the unit is
// recorded before ANGLE validates it.
struct GLTextureBindings {
    private static let denseUnitCount = 32

    private var dense = [GLTextureBinding](repeating: GLTextureBinding(), count: denseUnitCount)
    private var sparse: [GLenum: GLTextureBinding] = [:]

    func texture(unit: GLenum) -> GLuint {
        if let index = Self.denseIndex(unit) {
            return dense[index].texture
        }
        return sparse[unit]?.texture ?? 0
    }

    mutating func set(unit: GLenum, texture: GLuint, target: GLenum) {
        if let index = Self.denseIndex(unit) {
            dense[index] = GLTextureBinding(texture: texture, target: target)
        } else {
            sparse[unit] = GLTextureBinding(texture: texture, target: target)
        }
    }

    mutating func removeBindings(of texture: GLuint) {
        for index in dense.indices where dense[index].texture == texture {
            dense[index] = GLTextureBinding()
        }
        if !sparse.isEmpty {
            sparse = sparse.filter { $0.value.texture != texture }
        }
    }

    private static func denseIndex(_ unit: GLenum) -> Int? {
        let base = GLenum(GL_TEXTURE0)
        guard unit >= base, unit - base < GLenum(denseUnitCount) else {
            return nil
        }
        return Int(unit - base)
    }
}

struct GLTextureBinding {
    var texture: GLuint = 0
    var target: GLenum = 0
}

struct GLState {
    var activeTextureUnit = GLenum(GL_TEXTURE0)
    var textureBindings = GLTextureBindings()

    var packAlignment: GLint = 4
    var packRowLength: GLint = 0
    var packReverseRowOrder: GLboolean = 0

    var currentWidth: Int32 = 0
    var currentHeight: Int32 = 0

    var failNextStatusCheck = false
    var failNextDrawingBufferAllocation = false
    var failNextRenderbufferAllocation = false

    var currentBoundTexture: GLuint {
        textureBindings.texture(unit: activeTextureUnit)
    }

    mutating func bindTexture(_ texture: GLuint, target: GLenum) {
        textureBindings.set(unit: activeTextureUnit, texture: texture, target: target)
    }
}

struct GLSize: Equatable {
    var width: Int32 = 0
    var height: Int32 = 0

    var isEmpty: Bool {
        width <= 0 || height <= 0
    }

    mutating func clampToMaximumSize(_ maximum: GLSize) {
        width = min(width, maximum.width)
        height = min(height, maximum.height)
    }
}
