/*
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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

#include "config.h"
#include "GPUProcessIOSurfaces.h"

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA)

#include <WebCore/ColorSpace.h>
#include <WebCore/IOSurface.h>

namespace WebKit {

static WebCore::IOSurface::Format webCoreFormat(GPUProcessIOSurfaceFormat format)
{
    switch (format) {
    case GPUProcessIOSurfaceFormat::Bgra:
        return WebCore::IOSurface::Format::BGRA;
    case GPUProcessIOSurfaceFormat::Bgrx:
        return WebCore::IOSurface::Format::BGRX;
    case GPUProcessIOSurfaceFormat::Rgba:
        return WebCore::IOSurface::Format::RGBA;
    case GPUProcessIOSurfaceFormat::Rgbx:
        return WebCore::IOSurface::Format::RGBX;
    case GPUProcessIOSurfaceFormat::Rgba16F:
#if ENABLE(PIXEL_FORMAT_RGBA16F)
        return WebCore::IOSurface::Format::RGBA16F;
#else
        return WebCore::IOSurface::Format::BGRA;
#endif
    }
    ASSERT_NOT_REACHED();
    return WebCore::IOSurface::Format::BGRA;
}

static WebCore::IOSurface::Name webCoreName(GPUProcessIOSurfaceName name)
{
    switch (name) {
    case GPUProcessIOSurfaceName::WebGPU:
        return WebCore::IOSurface::Name::WebGPU;
    }
    ASSERT_NOT_REACHED();
    return WebCore::IOSurface::Name::Default;
}

void createGPUProcessIOSurfaces(IPC::CxxDecodedArgument<WebCore::ColorSpace>& colorSpaceArgument, int32_t width, int32_t height, GPUProcessIOSurfaceFormat format, GPUProcessIOSurfaceName name, uint32_t count, NOESCAPE void (^addSurface)(IOSurfaceRef))
{
    auto colorSpace = colorSpaceArgument.take();
    RELEASE_ASSERT(colorSpace);
    for (uint32_t index = 0; index < count; ++index) {
        if (auto surface = WebCore::IOSurface::create(nullptr, WebCore::IntSize(width, height), *colorSpace, webCoreName(name), webCoreFormat(format)))
            addSurface(surface->surface());
    }
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && PLATFORM(COCOA)
