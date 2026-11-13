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

// Barcode, face and text detection with Vision, for the GPU process's receivers and, through ShapeDetectionFacade.swift,
// for WebCore's C++ detectors.
//
// WebCore soft-links Vision and CoreML, so this never names one of their classes or constants in a way that needs their
// symbols (a cast, a typed array, a constant, a class object): it reaches those through the generated accessors
// (VisionSoftLinkAccessors.swift and CoreMLSoftLinkAccessors.swift), and calls Vision's objects directly.
@_spi(WebKitGPU)
public enum ShapeDetectionVision {
    // In the image's pixels, with y increasing downwards, in Float as WebCore's FloatPoint and FloatRect.
    public struct Point: Sendable, Equatable {
        public var x: Float
        public var y: Float
    }

    public struct Rect: Sendable, Equatable {
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

        // The formats are values of WebCore::ShapeDetection::BarcodeFormat.
        public init(requestedFormats: [UInt8]) {
            var requestedFormatMask: UInt16 = 0
            for format in requestedFormats where format < UInt16.bitWidth {
                requestedFormatMask |= 1 << UInt16(format)
            }
            self.init(requestedFormatMask: requestedFormatMask)
        }

        public func detect(_ image: CGImage) -> [DetectedBarcode] {
            guard let request = createVisionBarcodesRequest() else {
                return []
            }
            request.symbologies = ShapeDetectionVision.symbologies(requestedFormatMask)
            guard performVisionRequest(image, request) else {
                return []
            }

            let imageSize = ImageSize(image)
            return visionResults(request) { result in
                guard let observation = VisionClass.cast(result, to: VisionClass.VNBarcodeObservation) else {
                    return nil
                }
                return DetectedBarcode(
                    boundingBox: rectFromVision(imageSize, observation.boundingBox),
                    rawValue: observation.payloadStringValue,
                    barcodeFormat: ShapeDetectionVision.format(observation.symbology),
                    cornerPoints: cornerPoints(imageSize, observation)
                )
            }
        }

        // The formats that Vision detects, as values of WebCore::ShapeDetection::BarcodeFormat, in increasing order.
        public static func supportedFormats() -> [UInt8] {
            let formatMask = supportedFormatMask()
            return (0..<UInt8(UInt16.bitWidth)).filter { formatMask & (1 << UInt16($0)) != 0 }
        }

        // The formats that Vision detects, as a mask like requestedFormatMask.
        public static func supportedFormatMask() -> UInt16 {
            guard let request = createVisionBarcodesRequest(), let symbologies = try? request.supportedSymbologies() else {
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
            guard let request = createVisionFaceLandmarksRequest(), performVisionRequest(image, request) else {
                return []
            }

            guard let observations = VisionMember.results(of: request)?.results else {
                return []
            }

            let imageSize = ImageSize(image)
            var results: [DetectedFace] = []
            results.reserveCapacity(min(Int(maxDetectedFaces), observations.count))
            for result in observations {
                guard let observation = VisionClass.cast(result as AnyObject, to: VisionClass.VNFaceObservation) else {
                    continue
                }
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
            guard let request = createVisionTextRequest(), performVisionRequest(image, request) else {
                return []
            }

            let imageSize = ImageSize(image)
            return visionResults(request) { result in
                guard let observation = VisionClass.cast(result, to: VisionClass.VNRecognizedTextObservation) else {
                    return nil
                }
                return DetectedText(
                    boundingBox: rectFromVision(imageSize, observation.boundingBox),
                    rawValue: topCandidateString(observation),
                    cornerPoints: cornerPoints(imageSize, observation)
                )
            }
        }
    }
}

// Vision's requests, and its results, through the generated accessors.

private func configureRequestToUseCPUOrGPU(_ request: VNRequest) {
    guard let supportedComputeStageDevices = try? VisionMember.supportedComputeStageDevices(of: request)?.supportedComputeStageDevices()
    else {
        return
    }

    for (computeStage, devices) in supportedComputeStageDevices {
        guard let computeStage = computeStage as? NSString, let devices = devices as? NSArray else {
            continue
        }
        var set = false
        // The devices are Vision's own compute devices for the stage, which the re-declaration's AnyObject parameter erases.
        for device in devices where isGPUComputeDevice(device) {
            unsafe VisionMember.setComputeDevice(of: request)?.setComputeDevice(device as AnyObject, forComputeStage: computeStage)
            set = true
            break
        }
        if !set {
            for device in devices where isGPUComputeDevice(device) {
                unsafe VisionMember.setComputeDevice(of: request)?.setComputeDevice(device as AnyObject, forComputeStage: computeStage)
                break
            }
        }
    }
}

private func isGPUComputeDevice(_ device: Any) -> Bool {
    guard let gpuComputeDeviceClass = CoreMLClass.MLGPUComputeDevice, let device = device as? NSObject else {
        return false
    }
    return device.isKind(of: gpuComputeDeviceClass)
}

// New requests, configured to run on the GPU when Vision can, or nil if Vision has no such request.
private func createVisionBarcodesRequest() -> VNDetectBarcodesRequest? {
    // It's important that both getSupportedFormats() and detect() use a VNDetectBarcodesRequest that is
    // configured the same way. This function is intended to make sure both VNDetectBarcodesRequests are
    // configured accordingly.
    guard let request = VisionClass.VNDetectBarcodesRequest?.init() else {
        return nil
    }
    configureRequestToUseCPUOrGPU(request)
    return request
}

private func createVisionFaceLandmarksRequest() -> VNDetectFaceLandmarksRequest? {
    guard let request = VisionClass.VNDetectFaceLandmarksRequest?.init() else {
        return nil
    }
    configureRequestToUseCPUOrGPU(request)
    return request
}

private func createVisionTextRequest() -> VNRecognizeTextRequest? {
    guard let request = VisionClass.VNRecognizeTextRequest?.init() else {
        return nil
    }
    configureRequestToUseCPUOrGPU(request)
    return request
}

// Whether Vision performed the request on the image without an error.
private func performVisionRequest(_ image: CGImage, _ request: VNRequest) -> Bool {
    guard let imageRequestHandler = VisionClass.VNImageRequestHandler?.init(cgImage: image, options: [:]),
        let performer = VisionMember.performRequests(of: imageRequestHandler)
    else {
        return false
    }
    do {
        // An array of one VNRequest, which the re-declaration's NSArray parameter erases.
        try unsafe performer.performRequests(NSArray(object: request as AnyObject))
    } catch {
        return false
    }
    return true
}

// What transform makes of each of the request's results, skipping those it makes nothing of. Nothing here holds a typed
// Vision value in a generic or an existential, which would need its class.
private func visionResults<Result>(_ request: VNRequest, _ transform: (AnyObject) -> Result?) -> [Result] {
    guard let results = VisionMember.results(of: request)?.results else {
        return []
    }
    var transformed: [Result] = []
    transformed.reserveCapacity(results.count)
    for result in results {
        if let value = transform(result as AnyObject) {
            transformed.append(value)
        }
    }
    return transformed
}

// The string of the observation's top candidate.
private func topCandidateString(_ observation: VNRecognizedTextObservation) -> Swift.String? {
    guard let candidates = VisionMember.topCandidates(of: observation)?.topCandidates(1), candidates.count > 0,
        let candidate = VisionClass.cast(candidates.object(at: 0) as AnyObject, to: VisionClass.VNRecognizedText)
    else {
        return nil
    }
    return candidate.string
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

// The region's points in the coordinates of an image of that size, from -[VNFaceLandmarkRegion2D pointsInImageOfSize:].
private func locations(_ region: VNFaceLandmarkRegion2D?, _ imageSize: ImageSize) -> [ShapeDetectionVision.Point] {
    guard let region, let points = VisionMember.pointsInImage(of: region, imageSize: imageSize.cgSize) else {
        return []
    }
    return points.map { pointFromUnnormalizedVision(imageSize, $0) }
}

// Barcode formats and Vision's symbologies.

// The Vision barcode symbologies that shape detection maps to and from barcode formats.
private enum VisionBarcodeSymbology: CaseIterable {
    case aztec
    case codabar
    case code39
    case code39Checksum
    case code39FullASCII
    case code39FullASCIIChecksum
    case code93
    case code93i
    case code128
    case dataMatrix
    case ean8
    case ean13
    case gs1DataBar
    case gs1DataBarExpanded
    case gs1DataBarLimited
    case i2of5
    case i2of5Checksum
    case itf14
    case microPDF417
    case microQR
    case pdf417
    case qr
    case upce

    var value: VNBarcodeSymbology {
        switch self {
        case .aztec:
            VisionSoftLink.VNBarcodeSymbologyAztec
        case .codabar:
            VisionSoftLink.VNBarcodeSymbologyCodabar
        case .code39:
            VisionSoftLink.VNBarcodeSymbologyCode39
        case .code39Checksum:
            VisionSoftLink.VNBarcodeSymbologyCode39Checksum
        case .code39FullASCII:
            VisionSoftLink.VNBarcodeSymbologyCode39FullASCII
        case .code39FullASCIIChecksum:
            VisionSoftLink.VNBarcodeSymbologyCode39FullASCIIChecksum
        case .code93:
            VisionSoftLink.VNBarcodeSymbologyCode93
        case .code93i:
            VisionSoftLink.VNBarcodeSymbologyCode93i
        case .code128:
            VisionSoftLink.VNBarcodeSymbologyCode128
        case .dataMatrix:
            VisionSoftLink.VNBarcodeSymbologyDataMatrix
        case .ean8:
            VisionSoftLink.VNBarcodeSymbologyEAN8
        case .ean13:
            VisionSoftLink.VNBarcodeSymbologyEAN13
        case .gs1DataBar:
            VisionSoftLink.VNBarcodeSymbologyGS1DataBar
        case .gs1DataBarExpanded:
            VisionSoftLink.VNBarcodeSymbologyGS1DataBarExpanded
        case .gs1DataBarLimited:
            VisionSoftLink.VNBarcodeSymbologyGS1DataBarLimited
        case .i2of5:
            VisionSoftLink.VNBarcodeSymbologyI2of5
        case .i2of5Checksum:
            VisionSoftLink.VNBarcodeSymbologyI2of5Checksum
        case .itf14:
            VisionSoftLink.VNBarcodeSymbologyITF14
        case .microPDF417:
            VisionSoftLink.VNBarcodeSymbologyMicroPDF417
        case .microQR:
            VisionSoftLink.VNBarcodeSymbologyMicroQR
        case .pdf417:
            VisionSoftLink.VNBarcodeSymbologyPDF417
        case .qr:
            VisionSoftLink.VNBarcodeSymbologyQR
        case .upce:
            VisionSoftLink.VNBarcodeSymbologyUPCE
        }
    }
}

extension ShapeDetectionVision {
    fileprivate typealias BarcodeFormat = WebCore.ShapeDetection.BarcodeFormat
    fileprivate typealias Symbology = VisionBarcodeSymbology

    // The first symbology with a name gives its format.
    private static let formatsByName: [Swift.String: BarcodeFormat] = Dictionary(
        Symbology.allCases.map {
            ($0.value.rawValue, format($0))
        },
        uniquingKeysWith: { first, _ in first }
    )

    private static func format(_ symbology: Symbology) -> BarcodeFormat {
        switch symbology {
        case .aztec:
            .Aztec
        case .codabar:
            .Codabar
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum:
            .Code_39
        case .code93, .code93i:
            .Code_93
        case .code128:
            .Code_128
        case .dataMatrix:
            .Data_matrix
        case .ean8:
            .Ean_8
        case .ean13:
            .Ean_13
        case .gs1DataBar, .gs1DataBarExpanded, .gs1DataBarLimited:
            .Unknown
        case .i2of5, .i2of5Checksum, .itf14:
            .Itf
        case .microPDF417, .pdf417:
            .Pdf417
        case .microQR, .qr:
            .Qr_code
        case .upce:
            .Upc_e
        }
    }

    fileprivate static func format(_ symbology: VNBarcodeSymbology) -> BarcodeFormat {
        formatsByName[symbology.rawValue] ?? .Unknown
    }

    private static func symbologies(_ format: BarcodeFormat) -> [Symbology] {
        switch format {
        case .Aztec:
            [.aztec]
        case .Code_128:
            [.code128]
        case .Code_39:
            [.code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum]
        case .Code_93:
            [.code93, .code93i]
        case .Codabar:
            [.codabar]
        case .Data_matrix:
            [.dataMatrix]
        case .Ean_13:
            [.ean13]
        case .Ean_8:
            [.ean8]
        case .Itf:
            [.i2of5, .i2of5Checksum, .itf14]
        case .Pdf417:
            [.microPDF417, .pdf417]
        case .Qr_code:
            [.microQR, .qr]
        case .Unknown:
            [.gs1DataBar, .gs1DataBarExpanded, .gs1DataBarLimited]
        case .Upc_a:
            []
        case .Upc_e:
            [.upce]
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
                result.append(symbology.value)
            }
        }
        return result
    }
}

#endif // ENABLE_WEBCORE_SWIFT && HAVE_SHAPE_DETECTION_API_IMPLEMENTATION && HAVE_VISION
