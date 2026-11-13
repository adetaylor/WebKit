// Copyright (C) 2023 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT && HAVE_SHAPE_DETECTION_API_IMPLEMENTATION && HAVE_VISION

import CoreGraphics
import Foundation
import WebCore_Private.Core.BarcodeFormatInterface
import WebCore_Private.Core.DetectedShapes
import WebCore_Private.Core.LandmarkTypeInterface

// WebKitLegacy's way to ShapeDetectionVision: BarcodeDetectorImpl, FaceDetectorImpl and TextDetectorImpl call these, and
// get what they find in a DetectedShapes. The GPU process's receivers call ShapeDetectionVision directly, so the GPU
// process never runs these, nor the C++ detectors.

@_expose(Cxx)
func shapeDetectionSupportedBarcodeFormats() -> UInt16 {
    ShapeDetectionVision.BarcodeDetector.supportedFormatMask()
}

@_expose(Cxx)
func shapeDetectionDetectBarcodes(_ requestedFormatMask: UInt16, _ image: CGImage, _ shapes: WebCore.ShapeDetection.DetectedShapes) {
    for barcode in ShapeDetectionVision.BarcodeDetector(requestedFormatMask: requestedFormatMask).detect(image) {
        let corners = barcode.cornerPoints.map(cgPoint)
        shapes.appendBarcode(
            cgRect(barcode.boundingBox),
            barcode.rawValue,
            barcode.barcodeFormat,
            corners[0],
            corners[1],
            corners[2],
            corners[3]
        )
    }
}

@_expose(Cxx)
func shapeDetectionDetectFaces(_ maxDetectedFaces: UInt16, _ image: CGImage, _ shapes: WebCore.ShapeDetection.DetectedShapes) {
    for face in ShapeDetectionVision.FaceDetector(maxDetectedFaces: maxDetectedFaces).detect(image) {
        shapes.appendFace(cgRect(face.boundingBox))
        for landmark in face.landmarks {
            shapes.appendFaceLandmark(landmark.landmarkType)
            for location in landmark.locations {
                shapes.appendFaceLandmarkLocation(cgPoint(location))
            }
        }
    }
}

@_expose(Cxx)
func shapeDetectionDetectTexts(_ image: CGImage, _ shapes: WebCore.ShapeDetection.DetectedShapes) {
    for text in ShapeDetectionVision.TextDetector().detect(image) {
        let corners = text.cornerPoints.map(cgPoint)
        shapes.appendText(cgRect(text.boundingBox), text.rawValue, corners[0], corners[1], corners[2], corners[3])
    }
}

private func cgRect(_ rect: ShapeDetectionVision.Rect) -> CGRect {
    CGRect(x: CGFloat(rect.x), y: CGFloat(rect.y), width: CGFloat(rect.width), height: CGFloat(rect.height))
}

private func cgPoint(_ point: ShapeDetectionVision.Point) -> CGPoint {
    CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
}

#endif // ENABLE_WEBCORE_SWIFT && HAVE_SHAPE_DETECTION_API_IMPLEMENTATION && HAVE_VISION
