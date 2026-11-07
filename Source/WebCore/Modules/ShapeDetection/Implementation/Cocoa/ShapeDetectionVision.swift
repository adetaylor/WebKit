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

public import CoreGraphics
import Foundation
import Vision
import WebCore_Private.Core.BarcodeFormatInterface
import WebCore_Private.Core.LandmarkTypeInterface
import WebCore_Private.Core.ShapeDetectionVisionSupport

// Barcode, face and text detection with Vision, for the GPU process's receivers and for WebCore's C++ detectors.
//
// WebCore soft-links Vision, so this never names a Vision class or constant in a way that needs Vision's symbols (a
// cast, a typed array, a constant): ShapeDetectionVisionSupport.h does those. It calls Vision's objects directly.
@_spi(WebKitGPU)
public enum ShapeDetectionVision {
    // In the image's pixels, with y increasing downwards, in Float as WebCore's FloatPoint and FloatRect.
    public struct Point: Sendable {
        public var x: Float
        public var y: Float
    }

    public struct Rect: Sendable {
        public var x: Float
        public var y: Float
        public var width: Float
        public var height: Float
    }

    public struct DetectedBarcode: Sendable {
        public var boundingBox: Rect
        public var rawValue: Swift.String?
        let barcodeFormat: WebCore.ShapeDetection.BarcodeFormat
        public var cornerPoints: [Point]

        // The value of its WebCore::ShapeDetection::BarcodeFormat.
        public var format: UInt8 { barcodeFormat.rawValue }
    }

    public struct Landmark: Sendable {
        public var locations: [Point]
        let landmarkType: WebCore.ShapeDetection.LandmarkType

        // The value of its WebCore::ShapeDetection::LandmarkType.
        public var type: UInt8 { landmarkType.rawValue }
    }

    public struct DetectedFace: Sendable {
        public var boundingBox: Rect
        public var landmarks: [Landmark]
    }

    public struct DetectedText: Sendable {
        public var boundingBox: Rect
        public var rawValue: Swift.String?
        public var cornerPoints: [Point]
    }

    public struct BarcodeDetector: Sendable {
        // Bit n is the BarcodeFormat whose value is n.
        private let requestedFormatMask: UInt16

        public init(requestedFormatMask: UInt16) {
            self.requestedFormatMask = requestedFormatMask
        }

        public func detect(_ image: CGImage) -> [DetectedBarcode] {
            let request = WebCore.ShapeDetection.createVisionBarcodesRequest()
            request.symbologies = ShapeDetectionVision.symbologies(requestedFormatMask)
            guard WebCore.ShapeDetection.performVisionRequest(image, request) else {
                return []
            }

            let imageSize = ImageSize(image)
            let count = WebCore.ShapeDetection.visionResultCount(request)
            var results: [DetectedBarcode] = []
            results.reserveCapacity(count)
            for index in 0..<count {
                let observation = WebCore.ShapeDetection.visionBarcodeObservation(request, index)
                results.append(
                    DetectedBarcode(
                        boundingBox: rectFromVision(imageSize, observation.boundingBox),
                        rawValue: observation.payloadStringValue,
                        barcodeFormat: ShapeDetectionVision.format(observation.symbology),
                        cornerPoints: cornerPoints(imageSize, observation)
                    )
                )
            }
            return results
        }

        // The formats that Vision detects, as a mask like requestedFormatMask.
        public static func supportedFormatMask() -> UInt16 {
            let request = WebCore.ShapeDetection.createVisionBarcodesRequest()
            guard let symbologies = try? request.supportedSymbologies() else {
                return 0
            }
            var result: UInt16 = 0
            for symbology in symbologies {
                result |= 1 << ShapeDetectionVision.format(symbology).rawValue
            }
            return result
        }
    }

    public struct FaceDetector: Sendable {
        private let maxDetectedFaces: UInt16

        public init(maxDetectedFaces: UInt16) {
            self.maxDetectedFaces = maxDetectedFaces
        }

        public func detect(_ image: CGImage) -> [DetectedFace] {
            let request = WebCore.ShapeDetection.createVisionFaceLandmarksRequest()
            guard WebCore.ShapeDetection.performVisionRequest(image, request) else {
                return []
            }

            let imageSize = ImageSize(image)
            let count = WebCore.ShapeDetection.visionResultCount(request)
            var results: [DetectedFace] = []
            results.reserveCapacity(min(Int(maxDetectedFaces), count))
            for index in 0..<count {
                let observation = WebCore.ShapeDetection.visionFaceObservation(request, index)
                results.append(
                    DetectedFace(
                        boundingBox: rectFromVision(imageSize, observation.boundingBox),
                        landmarks: landmarks(observation.landmarks, imageSize)
                    )
                )
                if results.count >= Int(maxDetectedFaces) {
                    break
                }
            }
            return results
        }
    }

    public struct TextDetector: Sendable {
        public init() {
        }

        public func detect(_ image: CGImage) -> [DetectedText] {
            let request = WebCore.ShapeDetection.createVisionTextRequest()
            guard WebCore.ShapeDetection.performVisionRequest(image, request) else {
                return []
            }

            let imageSize = ImageSize(image)
            let count = WebCore.ShapeDetection.visionResultCount(request)
            var results: [DetectedText] = []
            results.reserveCapacity(count)
            for index in 0..<count {
                let observation = WebCore.ShapeDetection.visionTextObservation(request, index)
                results.append(
                    DetectedText(
                        boundingBox: rectFromVision(imageSize, observation.boundingBox),
                        rawValue: WebCore.ShapeDetection.visionTopCandidateString(observation),
                        cornerPoints: cornerPoints(imageSize, observation)
                    )
                )
            }
            return results
        }
    }
}

// Vision uses normalized coordinates (0 .. 1 across the image), and
// also uses an increasing-y-goes-up coordinate system.
// The web expects the results are in unnormalized coordinates (0 .. size across the image), and
// an increasing-y-goes-down coordinate system.
// These functions perform the necessary conversions, in Float with WebCore's FloatRect and FloatPoint arithmetic.

private struct ImageSize {
    let width: Float
    let height: Float

    init(_ image: CGImage) {
        width = Float(image.width)
        height = Float(image.height)
    }

    var cgSize: CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}

private func rectFromVision(_ imageSize: ImageSize, _ rect: CGRect) -> ShapeDetectionVision.Rect {
    let rectX = Float(rect.origin.x)
    let rectY = Float(rect.origin.y)
    let x = rectX * imageSize.width
    let y = rectY * imageSize.height
    let maxX = (rectX + Float(rect.size.width)) * imageSize.width
    let maxY = (rectY + Float(rect.size.height)) * imageSize.height
    return .init(x: x, y: imageSize.height - maxY, width: maxX - x, height: maxY - y)
}

// height - y * height is rounded once, as clang's contraction of the C++ expression it replaces was.
private func pointFromVision(_ imageSize: ImageSize, _ point: CGPoint) -> ShapeDetectionVision.Point {
    .init(x: Float(point.x) * imageSize.width, y: imageSize.height.addingProduct(-Float(point.y), imageSize.height))
}

private func pointFromUnnormalizedVision(_ imageSize: ImageSize, _ point: CGPoint) -> ShapeDetectionVision.Point {
    .init(x: Float(point.x), y: imageSize.height - Float(point.y))
}

private func cornerPoints(_ imageSize: ImageSize, _ observation: VNRectangleObservation) -> [ShapeDetectionVision.Point] {
    let bottomLeft = pointFromVision(imageSize, observation.bottomLeft)
    let bottomRight = pointFromVision(imageSize, observation.bottomRight)
    let topLeft = pointFromVision(imageSize, observation.topLeft)
    let topRight = pointFromVision(imageSize, observation.topRight)

    // The spec says "in clockwise direction and starting with top-left"
    return [topLeft, topRight, bottomRight, bottomLeft]
}

private func landmarks(_ landmarks: VNFaceLandmarks2D?, _ imageSize: ImageSize) -> [ShapeDetectionVision.Landmark] {
    [
        .init(locations: locations(landmarks?.leftEye, imageSize), landmarkType: .Eye),
        .init(locations: locations(landmarks?.rightEye, imageSize), landmarkType: .Eye),
        .init(locations: locations(landmarks?.nose, imageSize), landmarkType: .Nose),
    ]
}

private func locations(_ region: VNFaceLandmarkRegion2D?, _ imageSize: ImageSize) -> [ShapeDetectionVision.Point] {
    guard let region else {
        return []
    }
    let size = imageSize.cgSize
    let count = region.pointCount
    var result: [ShapeDetectionVision.Point] = []
    result.reserveCapacity(count)
    for index in 0..<count {
        result.append(pointFromUnnormalizedVision(imageSize, WebCore.ShapeDetection.visionLandmarkPointInImage(region, size, index)))
    }
    return result
}

// Barcode formats and Vision's symbologies.

extension ShapeDetectionVision {
    fileprivate typealias BarcodeFormat = WebCore.ShapeDetection.BarcodeFormat
    fileprivate typealias Symbology = WebCore.ShapeDetection.VisionBarcodeSymbology

    private static let allSymbologies: [Symbology] = [
        .Aztec, .Codabar, .Code39, .Code39Checksum, .Code39FullASCII, .Code39FullASCIIChecksum, .Code93, .Code93i, .Code128,
        .DataMatrix, .Ean8, .Ean13, .GS1DataBar, .GS1DataBarExpanded, .GS1DataBarLimited, .I2of5, .I2of5Checksum, .Itf14,
        .MicroPDF417, .MicroQR, .Pdf417, .Qr, .Upce,
    ]

    // The first symbology with a name gives its format.
    private static let formatsByName: [Swift.String: BarcodeFormat] = Dictionary(
        allSymbologies.map {
            (WebCore.ShapeDetection.visionBarcodeSymbologyName($0), format($0))
        },
        uniquingKeysWith: { first, _ in first }
    )

    private static func format(_ symbology: Symbology) -> BarcodeFormat {
        switch symbology {
        case .Aztec:
            .Aztec
        case .Codabar:
            .Codabar
        case .Code39, .Code39Checksum, .Code39FullASCII, .Code39FullASCIIChecksum:
            .Code_39
        case .Code93, .Code93i:
            .Code_93
        case .Code128:
            .Code_128
        case .DataMatrix:
            .Data_matrix
        case .Ean8:
            .Ean_8
        case .Ean13:
            .Ean_13
        case .GS1DataBar, .GS1DataBarExpanded, .GS1DataBarLimited:
            .Unknown
        case .I2of5, .I2of5Checksum, .Itf14:
            .Itf
        case .MicroPDF417, .Pdf417:
            .Pdf417
        case .MicroQR, .Qr:
            .Qr_code
        case .Upce:
            .Upc_e
        @unknown default:
            .Unknown
        }
    }

    fileprivate static func format(_ symbology: VNBarcodeSymbology) -> BarcodeFormat {
        formatsByName[symbology.rawValue] ?? .Unknown
    }

    private static func symbologies(_ format: BarcodeFormat) -> [Symbology] {
        switch format {
        case .Aztec:
            [.Aztec]
        case .Code_128:
            [.Code128]
        case .Code_39:
            [.Code39, .Code39Checksum, .Code39FullASCII, .Code39FullASCIIChecksum]
        case .Code_93:
            [.Code93, .Code93i]
        case .Codabar:
            [.Codabar]
        case .Data_matrix:
            [.DataMatrix]
        case .Ean_13:
            [.Ean13]
        case .Ean_8:
            [.Ean8]
        case .Itf:
            [.I2of5, .I2of5Checksum, .Itf14]
        case .Pdf417:
            [.MicroPDF417, .Pdf417]
        case .Qr_code:
            [.MicroQR, .Qr]
        case .Unknown:
            [.GS1DataBar, .GS1DataBarExpanded, .GS1DataBarLimited]
        case .Upc_a:
            []
        case .Upc_e:
            [.Upce]
        @unknown default:
            []
        }
    }

    // The symbologies of the formats in the mask.
    fileprivate static func symbologies(_ formatMask: UInt16) -> [VNBarcodeSymbology] {
        var result: [VNBarcodeSymbology] = []
        for value in 0..<UInt8(UInt16.bitWidth) where formatMask & (1 << value) != 0 {
            guard let format = BarcodeFormat(rawValue: value) else {
                continue
            }
            for symbology in symbologies(format) {
                result.append(VNBarcodeSymbology(rawValue: WebCore.ShapeDetection.visionBarcodeSymbologyName(symbology)))
            }
        }
        return result
    }
}

// What WebCore's C++ detectors (BarcodeDetectorImpl and the others) call.

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
