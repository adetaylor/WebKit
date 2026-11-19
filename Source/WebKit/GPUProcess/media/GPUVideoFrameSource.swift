// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT && WTF_PLATFORM_COCOA && ENABLE_VIDEO

import CoreVideo
@_spi(WebKitGPU) internal import WebCore
import WebKit_Internal
import wtf

// The frame that the media player of a rendering backend's web process shows now, with the display transform that the
// frame's pixel buffer doesn't carry: a horizontal mirror, then a clockwise rotation in degrees (WebCore::VideoFrameRotation).
struct MediaPlayerFrame {
    // Nil if there's no player or no frame.
    var pixelBuffer: CVBuffer?
    var rotation: UInt16 = 0
    var isMirrored = false
    // The natural (displayed) size of the frame, in CSS pixels. Zero when not available (before metadata).
    var naturalWidth: UInt32 = 0
    var naturalHeight: UInt32 = 0
}

// Reads the frame on the main thread, which the media players are on, and waits for it.
func copyMediaPlayerFrame(_ renderingBackend: WebKit.RemoteRenderingBackend, _ mediaPlayerIdentifier: UInt64) -> MediaPlayerFrame {
    final class Reader: @unchecked Sendable {
        // Written on the main thread while the caller waits for it, and read once it has.
        var frame = MediaPlayerFrame()
    }
    let reader = Reader()
    renderingBackend.gpuConnectionToWebProcess().performWithMediaPlayerOnMainThread(
        WebCore.MediaPlayerIdentifier(mediaPlayerIdentifier),
        consuming: WebKit.MediaPlayerCallback { (player: WebCore.MediaPlayer) in
            let naturalSize = player.naturalSize()
            reader.frame.naturalWidth = cssPixels(naturalSize.width())
            reader.frame.naturalHeight = cssPixels(naturalSize.height())
            guard let videoFrame = player.videoFrameForCurrentTime().get() else {
                return
            }
            reader.frame.rotation = videoFrame.rotation().rawValue
            reader.frame.isMirrored = videoFrame.isMirrored()
            reader.frame.pixelBuffer = WebKit.videoFramePixelBuffer(videoFrame)
        }
    )
    return reader.frame
}

// 0 for a size that is negative or not a number; clamped to Int32.max, as the size travels as an IntSize.
private func cssPixels(_ size: Float) -> UInt32 {
    guard size > 0 else {
        return 0
    }
    return size < Float(Int32.max) ? UInt32(size) : UInt32(Int32.max)
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT && WTF_PLATFORM_COCOA && ENABLE_VIDEO
