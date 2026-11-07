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

#import "config.h"
#import "BarcodeDetectorImplementation.h"

#if HAVE(SHAPE_DETECTION_API_IMPLEMENTATION) && HAVE(VISION)

#import "BarcodeDetectorOptionsInterface.h"
#import "BarcodeFormatInterface.h"
#import "DetectedBarcodeInterface.h"
#import "NativeImage.h"
#import "ShapeDetectionVisionSupport.h"
#import "WebCore-Swift.h"
#import <wtf/TZoneMallocInlines.h>

namespace WebCore::ShapeDetection {

static constexpr auto lastBarcodeFormat = BarcodeFormat::Upc_e;
static_assert(std::to_underlying(lastBarcodeFormat) < 16);

uint16_t BarcodeDetectorImpl::formatMask(const Vector<BarcodeFormat>& formats)
{
    uint16_t result = 0;
    for (auto format : formats)
        result |= 1 << std::to_underlying(format);
    return result;
}

Vector<BarcodeFormat> BarcodeDetectorImpl::formats(uint16_t formatMask)
{
    Vector<BarcodeFormat> result;
    for (uint8_t value = 0; value <= std::to_underlying(lastBarcodeFormat); ++value) {
        if (formatMask & (1 << value))
            result.append(static_cast<BarcodeFormat>(value));
    }
    return result;
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(BarcodeDetectorImpl);

BarcodeDetectorImpl::BarcodeDetectorImpl(const BarcodeDetectorOptions& barcodeDetectorOptions)
    : m_requestedFormatMask(formatMask(barcodeDetectorOptions.formats))
{
}

BarcodeDetectorImpl::~BarcodeDetectorImpl() = default;

void BarcodeDetectorImpl::getSupportedFormats(CompletionHandler<void(Vector<BarcodeFormat>&&)>&& completionHandler)
{
    completionHandler(formats(WebCore::shapeDetectionSupportedBarcodeFormats()));
}

void BarcodeDetectorImpl::detect(const NativeImage& image, CompletionHandler<void(Vector<DetectedBarcode>&&)>&& completionHandler)
{
    auto platformImage = image.platformImage();
    if (!platformImage) {
        completionHandler({ });
        return;
    }

    Ref shapes = DetectedShapes::create();
    WebCore::shapeDetectionDetectBarcodes(m_requestedFormatMask, platformImage.get(), shapes.ptr());
    completionHandler(shapes->takeBarcodes());
}

} // namespace WebCore::ShapeDetection

#endif // HAVE(SHAPE_DETECTION_API_IMPLEMENTATION) && HAVE(VISION)
