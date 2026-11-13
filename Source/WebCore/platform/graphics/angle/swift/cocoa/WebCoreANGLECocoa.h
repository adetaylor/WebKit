/*
 * Copyright (C) 2009-2021 Apple Inc. All rights reserved.
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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

// The shims of ANGLE's Metal backend's EGL for the Cocoa platform of the WebGL island: displays, contexts, IOSurface
// pbuffers. The attributes that make a context a WebGL context are fixed here.

#include "../WebCoreANGLE.h"
#include <CoreVideo/CoreVideo.h>
#include <IOKit/IOReturn.h>
#include <IOSurface/IOSurfaceRef.h>

struct ANGLECocoa final {
    ANGLECocoa() = delete;

    // Whether ANGLE's library was loaded, which is weak linked.
    static bool isAvailable();

    static std::string queryString(ANGLEDisplay display, EGLint name)
    {
        auto* string = EGL_QueryString(display.get(), name);
        return string ? std::string { string } : std::string { };
    }
    static std::string queryClientString(EGLint name)
    {
        auto* string = EGL_QueryString(EGL_NO_DISPLAY, name);
        return string ? std::string { string } : std::string { };
    }

    // The Metal display for a power preference (0 default, 1 low power, 2 high performance) or, by default, for the GPU
    // of the given registry ID when gpuID isn't 0, with WebKit's Metal feature overrides, keyed by displayKey.
    static ANGLEDisplay getMetalDisplay(uint8_t powerPreference, uint64_t gpuID, EGLAttrib displayKey);
    static bool initialize(ANGLEDisplay display) { EGLint major = 0, minor = 0; return EGL_Initialize(display.get(), &major, &minor); }

    // An RGBA8 config without depth or stencil.
    static ANGLEConfig chooseConfig(ANGLEDisplay display)
    {
        const EGLint attributes[] = {
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_RED_SIZE, 8,
            EGL_GREEN_SIZE, 8,
            EGL_BLUE_SIZE, 8,
            EGL_ALPHA_SIZE, 8,
            EGL_DEPTH_SIZE, 0,
            EGL_STENCIL_SIZE, 0,
            EGL_NONE
        };
        EGLConfig config = nullptr;
        EGLint count = 0;
        EGL_ChooseConfig(display.get(), attributes, &config, 1, &count);
        return count == 1 ? ANGLEConfig { config } : ANGLEConfig { };
    }

    static bool bindOpenGLESAPI() { return EGL_BindAPI(EGL_OPENGL_ES_API); }
    static EGLint error() { return EGL_GetError(); }

    // A context for WebGL: no client arrays, so that every offset the offset shims pass is an offset into a bound
    // buffer, resources cleared at creation, and context loss on GPU reset. ownershipIdentity is a task identity token,
    // or 0 for none.
    static ANGLEContext createWebGLContext(ANGLEDisplay display, ANGLEConfig config, bool isWebGL2, uint32_t ownershipIdentity);
    static bool destroyContext(ANGLEDisplay display, ANGLEContext context) { return EGL_DestroyContext(display.get(), context.get()); }

    // A pbuffer for an IOSurface plane, which ANGLE renders to and samples from. textureTarget is GL_TEXTURE_2D or
    // GL_TEXTURE_RECTANGLE_ANGLE; usageHint EGL_IOSURFACE_READ_HINT_ANGLE and/or EGL_IOSURFACE_WRITE_HINT_ANGLE.
    static ANGLESurface createIOSurfacePbuffer(ANGLEDisplay display, ANGLEConfig config, IOSurfaceRef surface, GLsizei width, GLsizei height, GLuint plane, GLenum textureTarget, GLenum internalFormat, GLenum type, EGLint usageHint)
    {
        const EGLint attributes[] = {
            EGL_WIDTH, width,
            EGL_HEIGHT, height,
            EGL_IOSURFACE_PLANE_ANGLE, static_cast<EGLint>(plane),
            EGL_TEXTURE_TARGET, textureTarget == GL_TEXTURE_RECTANGLE_ANGLE ? EGL_TEXTURE_RECTANGLE_ANGLE : EGL_TEXTURE_2D,
            EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, static_cast<EGLint>(internalFormat),
            EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
            EGL_TEXTURE_TYPE_ANGLE, static_cast<EGLint>(type),
            // Only has an effect on the iOS Simulator.
            EGL_IOSURFACE_USAGE_HINT_ANGLE, usageHint,
            EGL_NONE, EGL_NONE
        };
        return ANGLESurface { EGL_CreatePbufferFromClientBuffer(display.get(), EGL_IOSURFACE_ANGLE, surface, config.get(), attributes) };
    }
    // A pbuffer of an NV12 IOSurface, which glCopyTextureCHROMIUM converts to RGB when it is bound to a TEXTURE_2D
    // texture. orientation holds EGL_IOSURFACE_ORIENTATION_*_ANGLE bits, which say how the surface maps to the texture
    // image, which has the size of the oriented surface; colorSpaceHint and sampleRangeHint are values of
    // EGL_YUV_COLOR_SPACE_HINT_EXT and EGL_SAMPLE_RANGE_HINT_EXT.
    static ANGLESurface createYUVIOSurfacePbuffer(ANGLEDisplay display, ANGLEConfig config, IOSurfaceRef surface, EGLint orientation, EGLint colorSpaceHint, EGLint sampleRangeHint)
    {
        auto surfaceWidth = static_cast<EGLint>(IOSurfaceGetWidth(surface));
        auto surfaceHeight = static_cast<EGLint>(IOSurfaceGetHeight(surface));
        bool swapsXY = orientation & EGL_IOSURFACE_ORIENTATION_SWAP_XY_ANGLE;
        auto width = swapsXY ? surfaceHeight : surfaceWidth;
        auto height = swapsXY ? surfaceWidth : surfaceHeight;
        const EGLint attributes[] = {
            EGL_WIDTH, width,
            EGL_HEIGHT, height,
            EGL_IOSURFACE_PLANE_ANGLE, 0,
            EGL_TEXTURE_TARGET, EGL_TEXTURE_2D,
            EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_G8_B8R8_2PLANE_420_UNORM_ANGLE,
            EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
            EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
            EGL_YUV_COLOR_SPACE_HINT_EXT, colorSpaceHint,
            EGL_SAMPLE_RANGE_HINT_EXT, sampleRangeHint,
            EGL_IOSURFACE_ORIENTATION_ANGLE, orientation,
            // Only has an effect on the iOS Simulator.
            EGL_IOSURFACE_USAGE_HINT_ANGLE, EGL_IOSURFACE_READ_HINT_ANGLE,
            EGL_NONE, EGL_NONE
        };
        return ANGLESurface { EGL_CreatePbufferFromClientBuffer(display.get(), EGL_IOSURFACE_ANGLE, surface, config.get(), attributes) };
    }
    static bool destroySurface(ANGLEDisplay display, ANGLESurface surface) { return EGL_DestroySurface(display.get(), surface.get()); }
    static bool bindTexImage(ANGLEDisplay display, ANGLESurface surface) { return EGL_BindTexImage(display.get(), surface.get(), EGL_BACK_BUFFER); }
    static bool releaseTexImage(ANGLEDisplay display, ANGLESurface surface) { return EGL_ReleaseTexImage(display.get(), surface.get(), EGL_BACK_BUFFER); }

    static void waitUntilWorkScheduled(ANGLEDisplay display) { EGL_WaitUntilWorkScheduledANGLE(display.get()); }

    // Whether the kernel has the surface as volatile, or purged.
    static bool isVolatile(IOSurfaceRef surface)
    {
        uint32_t state = 0;
        return IOSurfaceSetPurgeable(surface, kIOSurfacePurgeableKeepCurrent, &state) == kIOReturnSuccess && (state == kIOSurfacePurgeableVolatile || state == kIOSurfacePurgeableEmpty);
    }

    // Makes the surface volatile, so that the kernel may purge it, or not. Returns false if it couldn't.
    static bool setVolatile(IOSurfaceRef surface, bool isVolatile)
    {
        uint32_t previousState = 0;
        return IOSurfaceSetPurgeable(surface, isVolatile ? kIOSurfacePurgeableVolatile : kIOSurfacePurgeableNonVolatile, &previousState) == kIOReturnSuccess;
    }

    // The IOSurface of a pixel buffer, or null if it has none.
    static IOSurfaceRef ioSurface(CVPixelBufferRef pixelBuffer) CF_RETURNS_NOT_RETAINED { return CVPixelBufferGetIOSurface(pixelBuffer); }
    // The compressed '420v' and '420f' formats, where CoreVideo has them.
    static OSType agx420YpCbCr8BiPlanarVideoRange();
    static OSType agx420YpCbCr8BiPlanarFullRange();
};
