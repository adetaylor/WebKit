/*
 * Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

#include "config.h"
#include "SharedVideoFrameInfo.h"

#if ENABLE(VIDEO) && PLATFORM(COCOA)

#include "CVUtilities.h"
#include "Logging.h"
#include "PixelBufferSwiftBridge.h"

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

#if USE(LIBWEBRTC)

WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_BEGIN

#include <webrtc/api/video/video_frame.h>
#include <webrtc/webkit_sdk/WebKit/WebKitUtilities.h>

WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_END

#endif // USE(LIBWEBRTC)

#include "CoreVideoSoftLink.h"

namespace WebCore {

// The layout, encoding and plane copies are in SharedVideoFrameLayout.swift.

SharedVideoFrameInfo::SharedVideoFrameInfo(const SharedVideoFrameLayout& layout)
    : SharedVideoFrameInfo(layout.bufferType, layout.width, layout.height, layout.bytesPerRow, layout.widthPlaneB, layout.heightPlaneB, layout.bytesPerRowPlaneB, layout.bytesPerRowPlaneAlpha)
{
}

SharedVideoFrameLayout SharedVideoFrameInfo::layout() const
{
    return { m_bufferType, m_width, m_height, m_bytesPerRow, m_widthPlaneB, m_heightPlaneB, m_bytesPerRowPlaneB, m_bytesPerRowPlaneAlpha };
}

SharedVideoFrameInfo SharedVideoFrameInfo::fromCVPixelBuffer(CVPixelBufferRef pixelBuffer)
{
    return SharedVideoFrameInfo { sharedVideoFrameLayout(pixelBuffer) };
}

bool SharedVideoFrameInfo::isReadWriteSupported() const
{
    return sharedVideoFrameIsReadWriteSupported(layout());
}

size_t SharedVideoFrameInfo::storageSize() const
{
    if (!m_storageSize)
        const_cast<SharedVideoFrameInfo*>(this)->m_storageSize = sharedVideoFrameStorageSize(layout(), sizeof(SharedVideoFrameInfo));
    return m_storageSize;
}

void SharedVideoFrameInfo::encode(NOESCAPE std::span<uint8_t> destination)
{
    MutablePixelBytes bytes { destination };
    sharedVideoFrameEncode(layout(), bytes);
}

OptionalSharedVideoFrameInfo SharedVideoFrameInfo::decode(NOESCAPE std::span<const uint8_t> span)
{
    SharedVideoFrameLayout layout;
    if (!sharedVideoFrameDecode(PixelBytes { span }, sizeof(SharedVideoFrameInfo), layout))
        return std::nullopt;
    return SharedVideoFrameInfo { layout };
}

RetainPtr<CVPixelBufferRef> SharedVideoFrameInfo::createPixelBufferFromMemory(NOESCAPE std::span<const uint8_t> data, CVPixelBufferPoolRef bufferPool)
{
    ASSERT(isReadWriteSupported());
    return adoptCF(sharedVideoFrameCreatePixelBuffer(layout(), PixelBytes { data }, bufferPool));
}

bool SharedVideoFrameInfo::writePixelBuffer(CVPixelBufferRef pixelBuffer, NOESCAPE std::span<uint8_t> data)
{
    MutablePixelBytes bytes { data };
    switch (sharedVideoFrameWritePixelBuffer(layout(), pixelBuffer, sizeof(SharedVideoFrameInfo), bytes)) {
    case SharedVideoFrameWriteResult::Success:
        return true;
    case SharedVideoFrameWriteResult::LockFailed:
        RELEASE_LOG_ERROR(WebRTC, "SharedVideoFrameInfo::writePixelBuffer lock failed");
        return false;
    case SharedVideoFrameWriteResult::NotReadable:
        RELEASE_LOG_FAULT(WebRTC, "SharedVideoFrameInfo::writePixelBuffer pixel buffer is not readable");
        return false;
    case SharedVideoFrameWriteResult::PlaneANull:
        RELEASE_LOG_FAULT(WebRTC, "SharedVideoFrameInfo::writePixelBuffer plane A is null");
        return false;
    case SharedVideoFrameWriteResult::PlaneBNull:
        RELEASE_LOG_ERROR(WebRTC, "SharedVideoFrameInfo::writePixelBuffer plane B is null");
        return false;
    case SharedVideoFrameWriteResult::PlaneAlphaNull:
        RELEASE_LOG_ERROR(WebRTC, "SharedVideoFrameInfo::writePixelBuffer plane A is null");
        return false;
    case SharedVideoFrameWriteResult::StorageTooSmall:
        RELEASE_LOG_ERROR(WebRTC, "SharedVideoFrameInfo::writePixelBuffer storage is too small");
        return false;
    }
    ASSERT_NOT_REACHED();
    return false;
}

RetainPtr<CVPixelBufferPoolRef> SharedVideoFrameInfo::createCompatibleBufferPool() const
{
    auto result = createIOSurfaceCVPixelBufferPool(m_width, m_height, m_bufferType);
    if (!result)
        return { };
    return *result;
}

#if USE(LIBWEBRTC)
template<typename byteType>
uint32_t computeStrideY(const webrtc::VideoFrameBuffer& frame)
{
    auto width = static_cast<uint32_t>(frame.width());
    return sizeof(byteType) * width;
}

template<typename byteType>
uint32_t computeStrideUV(const webrtc::VideoFrameBuffer& frame)
{
    auto width = static_cast<uint32_t>(frame.width());
    return sizeof(byteType) * (width & 1 ? width + 1 : width);
}

static uint32_t computeWidthUV(const webrtc::VideoFrameBuffer& frame)
{
    auto width = static_cast<uint32_t>(frame.width());
    return (width + 1) / 2;
}

static uint32_t computeHeightUV(const webrtc::VideoFrameBuffer& frame)
{
    auto height = static_cast<uint32_t>(frame.height());
    return (height + 1) / 2;
}

SharedVideoFrameInfo SharedVideoFrameInfo::fromVideoFrameBuffer(const webrtc::VideoFrameBuffer& frame)
{
    if (frame.type() == webrtc::VideoFrameBuffer::Type::kNative)
        return SharedVideoFrameInfo { };

    auto type = frame.type();
    if (type == webrtc::VideoFrameBuffer::Type::kI420) {
        return {
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            static_cast<uint32_t>(frame.width()), static_cast<uint32_t>(frame.height()), computeStrideY<uint8_t>(frame),
            computeWidthUV(frame), computeHeightUV(frame), computeStrideUV<uint8_t>(frame)
        };
    }
    if (type == webrtc::VideoFrameBuffer::Type::kI010) {
        return {
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            static_cast<uint32_t>(frame.width()), static_cast<uint32_t>(frame.height()), computeStrideY<uint16_t>(frame),
            computeWidthUV(frame), computeHeightUV(frame), computeStrideUV<uint16_t>(frame)
        };
    }
    return { };
}

bool SharedVideoFrameInfo::writeVideoFrameBuffer(webrtc::VideoFrameBuffer& frameBuffer, std::span<uint8_t> data)
{
    ASSERT(m_bufferType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || m_bufferType == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange);
    encode(data);
    return webrtc::copyVideoFrameBuffer(frameBuffer, data.subspan(sizeof(SharedVideoFrameInfo)).data());
}
#endif

}

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
