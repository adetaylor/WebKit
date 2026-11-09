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

#if HAVE(SHAPE_DETECTION_API_IMPLEMENTATION) && HAVE(VISION)

#include <CoreGraphics/CoreGraphics.h>
#include <WebCore/BarcodeFormatInterface.h>
#include <WebCore/DetectedBarcodeInterface.h>
#include <WebCore/DetectedFaceInterface.h>
#include <WebCore/DetectedTextInterface.h>
#include <WebCore/LandmarkTypeInterface.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Vector.h>

OBJC_CLASS NSString;

namespace WebCore::ShapeDetection {

// What the Swift detectors find, for the C++ detectors (BarcodeDetectorImpl and the others), which WebKitLegacy uses.
class DetectedShapes final : public RefCounted<DetectedShapes> {
public:
    static Ref<DetectedShapes> create() { return adoptRef(*new DetectedShapes); }

    void appendBarcode(CGRect boundingBox, NSString * WTF_NULLABLE rawValue, BarcodeFormat, CGPoint topLeft, CGPoint topRight, CGPoint bottomRight, CGPoint bottomLeft);
    // A face, with its landmarks appended after it.
    void appendFace(CGRect boundingBox);
    void appendFaceLandmark(LandmarkType);
    void appendFaceLandmarkLocation(CGPoint);
    void appendText(CGRect boundingBox, NSString * WTF_NULLABLE rawValue, CGPoint topLeft, CGPoint topRight, CGPoint bottomRight, CGPoint bottomLeft);

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { RefCounted<DetectedShapes>::ref(); }
    void deref() const { RefCounted<DetectedShapes>::deref(); }
#else
    Vector<DetectedBarcode> takeBarcodes() { return std::exchange(m_barcodes, { }); }
    Vector<DetectedFace> takeFaces() { return std::exchange(m_faces, { }); }
    Vector<DetectedText> takeTexts() { return std::exchange(m_texts, { }); }
#endif

private:
    DetectedShapes() = default;

    Vector<DetectedBarcode> m_barcodes;
    Vector<DetectedFace> m_faces;
    Vector<DetectedText> m_texts;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebCore::ShapeDetection

#endif // HAVE(SHAPE_DETECTION_API_IMPLEMENTATION) && HAVE(VISION)
