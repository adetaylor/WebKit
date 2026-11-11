// Copyright (C) 2012 Google Inc. All rights reserved.
// Copyright (C) 2013-2023 Apple Inc. All rights reserved.
// Copyright (C) 2013 Nokia Corporation and/or its subsidiary(-ies).
// Copyright (C) 2015 Ericsson AB. All rights reserved.
// Copyright (C) 2013-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer
//    in the documentation and/or other materials provided with the
//    distribution.
// 3. Neither the name of Google Inc. nor the names of its contributors
//    may be used to endorse or promote products derived from this
//    software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Copyright (C) 2018-2024 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM

// The decisions that the C++ RealtimeMediaSource and RealtimeVideoCaptureSource and the GPU process's Swift capture
// sources (cocoa/CaptureSource.swift) both make.

import WebCore_Private.Core.CaptureSourceDecisions

// A size or a length as Int32: values out of its range clamp to it, and NaN is 0.
func captureDimension(_ value: Double) -> Int32 {
    guard !value.isNaN else {
        return 0
    }
    return Int32(min(max(value, Double(Int32.min)), Double(Int32.max)))
}

// The decisions that the C++ RealtimeMediaSource and RealtimeVideoCaptureSource make, for both them and the Swift sources.
extension WebCore.CaptureSourceDecisions {
    // RealtimeMediaSource::size(): a size whose width or height is 0 takes the intrinsic size's aspect ratio.
    @cxx
    @implementation
    static func resolvedSize(_ size: WebCore.CaptureSourceSize, _ intrinsicSize: WebCore.CaptureSourceSize) -> WebCore.CaptureSourceSize {
        var size = size
        if (size.width <= 0 || size.height <= 0) && intrinsicSize.width > 0 && intrinsicSize.height > 0 {
            if size.width == 0 && size.height == 0 {
                size = intrinsicSize
            } else if size.width != 0 {
                size.height = captureDimension(Double(size.width) * (Double(intrinsicSize.height) / Double(intrinsicSize.width)))
            } else if size.height != 0 {
                size.width = captureDimension(Double(size.height) * (Double(intrinsicSize.width) / Double(intrinsicSize.height)))
            }
        }
        return size
    }

    // RealtimeMediaSource::computeResizedVideoFrameSize(): a width or height alone keeps the aspect ratio.
    @cxx
    @implementation
    static func resizedVideoFrameSize(_ desired: WebCore.CaptureSourceSize, _ actual: WebCore.CaptureSourceSize) -> WebCore.CaptureSourceSize {
        if desired.width != 0 && desired.height == 0 && actual.width > 0 {
            return WebCore.CaptureSourceSize(width: desired.width, height: desired.width &* actual.height / actual.width)
        }
        if desired.height != 0 && desired.width == 0 && actual.height > 0 {
            return WebCore.CaptureSourceSize(width: desired.height &* actual.width / actual.height, height: desired.height)
        }
        return desired
    }

    // The frame decimation of an observer that wants frameRate frames a second, of a source that produces
    // observedFrameRate.
    @cxx
    @implementation
    static func frameDecimation(_ observedFrameRate: Double, _ frameRate: Double) -> UInt64 {
        guard frameRate != 0 else {
            return 1
        }
        let decimation = observedFrameRate / frameRate
        guard decimation.isFinite, decimation >= 1 else {
            return 1
        }
        return decimation < Double(UInt64.max) ? UInt64(decimation) : .max
    }

    // RealtimeVideoCaptureSource::takePhoto(): a photo width or height alone takes the intrinsic size's aspect ratio.
    @cxx
    @implementation
    static func photoSize(_ width: Double, _ height: Double, _ intrinsicSize: WebCore.CaptureSourceSize) -> WebCore.CaptureSourceSize {
        var sanitized = WebCore.CaptureSourceSize(width: captureDimension(width), height: captureDimension(height))
        guard intrinsicSize.width > 0, intrinsicSize.height > 0 else {
            return sanitized
        }
        if sanitized.height == 0 {
            sanitized.height = captureDimension(Double(sanitized.width) * (Double(intrinsicSize.height) / Double(intrinsicSize.width)))
        } else if sanitized.width == 0 {
            sanitized.width = captureDimension(Double(sanitized.height) * (Double(intrinsicSize.width) / Double(intrinsicSize.height)))
        }
        return sanitized
    }
}

extension WebCore.CaptureVideoCapabilityRanges {
    @cxx
    @implementation
    mutating func addPreset(_ width: Int32, _ height: Int32, _ minZoom: Double, _ maxZoom: Double, _ maxFrameRate: Double) {
        minimumWidth = min(minimumWidth, width)
        maximumWidth = max(maximumWidth, width)
        minimumHeight = min(minimumHeight, height)
        maximumHeight = max(maximumHeight, height)
        let aspectRatio = Double(width) / Double(height)
        minimumAspectRatio = min(minimumAspectRatio, aspectRatio)
        maximumAspectRatio = max(maximumAspectRatio, aspectRatio)
        minimumZoom = min(minimumZoom, minZoom)
        maximumZoom = max(maximumZoom, maxZoom)
        maximumFrameRate = max(maximumFrameRate, maxFrameRate)
    }

    @cxx
    @implementation
    func ranges(_ canResizeVideoFrames: Bool) -> WebCore.CaptureCapabilityValues {
        var capabilities = WebCore.CaptureCapabilityValues()
        guard maximumWidth != 0, maximumHeight != 0, maximumFrameRate != 0 else {
            return capabilities
        }
        capabilities.widthMin = canResizeVideoFrames ? 1 : minimumWidth
        capabilities.widthMax = maximumWidth
        capabilities.heightMin = canResizeVideoFrames ? 1 : minimumHeight
        capabilities.heightMax = maximumHeight
        capabilities.aspectRatioMin = canResizeVideoFrames ? 1 / Double(maximumHeight) : minimumAspectRatio
        capabilities.aspectRatioMax = canResizeVideoFrames ? Double(maximumWidth) : maximumAspectRatio
        capabilities.frameRateMin = 1
        capabilities.frameRateMax = maximumFrameRate
        capabilities.zoomMin = minimumZoom
        capabilities.zoomMax = maximumZoom
        return capabilities
    }
}

#endif
