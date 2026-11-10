/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
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

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include <CoreGraphics/CGImage.h>
#include <IOSurface/IOSurfaceRef.h>
#include <WebCore/PixelFormat.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <wtf/SwiftBridging.h>

namespace WebCore {
class NativeImage;
}

namespace WebKit {

class RemoteRenderingBackend;

// What copyImageBufferSurface() says of the image buffer whose IOSurface it gives.
struct RemoteGPUImageBufferSurface {
    WebCore::PixelFormat pixelFormat { WebCore::PixelFormat::BGRA8 };
    uint32_t width { 0 };
    uint32_t height { 0 };
    bool isDisplayP3 { false };
};

// The rendering backend's image buffers, for the WebGPU receivers, from their work queue.
void paintNativeImageToImageBuffer(RemoteRenderingBackend&, WebCore::NativeImage&, WebCore::RenderingResourceIdentifier);
// Paints the image, or else the IOSurface's image, into the rendering backend's image buffer with that identifier.
void paintToImageBuffer(RemoteRenderingBackend&, CGImageRef WTF_NULLABLE, IOSurfaceRef WTF_NULLABLE, bool forceOpaque, uint64_t imageBufferIdentifier);

// The IOSurface of the rendering backend's image buffer with that identifier, read for a copy: null unless the image buffer
// is accelerated and not empty. A function, since Swift takes what a C++ method returns as unretained.
IOSurfaceRef WTF_NULLABLE copyImageBufferSurface(RemoteRenderingBackend&, uint64_t imageBufferIdentifier, RemoteGPUImageBufferSurface&) CF_RETURNS_RETAINED;


} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
