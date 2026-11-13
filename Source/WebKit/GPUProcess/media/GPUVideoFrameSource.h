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

#pragma once

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA) && ENABLE(VIDEO)

#include <CoreVideo/CVBuffer.h>
#include <wtf/Compiler.h>

namespace WebKit {

class RemoteRenderingBackend;

// Whether there was a media player to read a frame from, and the display transform of the frame read, which the frame's
// pixel buffer doesn't carry: a horizontal mirror, then a clockwise rotation in degrees (WebCore::VideoFrameRotation).
struct GPUVideoFrameReadResult {
    bool hadFrame { false };
    uint16_t rotation { 0 };
    bool isMirrored { false };
    // The natural (displayed) size of the frame, in CSS pixels. Zero when not available (before metadata).
    uint32_t naturalWidth { 0 };
    uint32_t naturalHeight { 0 };
};

// The pixel buffer of the frame that the media player of the rendering backend's web process shows now, which the main
// thread reads. A free function, since Swift takes what a C++ method returns as unretained; CVBufferRef, which Swift takes
// as CoreVideo's type whatever typedef of CVPixelBufferRef a header has seen.
CVBufferRef WTF_NULLABLE copyMediaPlayerFrame(RemoteRenderingBackend&, uint64_t mediaPlayerIdentifier, GPUVideoFrameReadResult&) CF_RETURNS_RETAINED;

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && PLATFORM(COCOA) && ENABLE(VIDEO)
