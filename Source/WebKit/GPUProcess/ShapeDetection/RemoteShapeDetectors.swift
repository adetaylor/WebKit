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

#if ENABLE_GPU_PROCESS && HAVE_SHAPE_DETECTION_API_IMPLEMENTATION

internal import CoreGraphics
@_spi(WebKitGPU) internal import WebCore
import WebKit_Internal

// The Swift handlers of the shape detectors' C++ receivers (RemoteBarcodeDetector.h, RemoteFaceDetector.h and
// RemoteTextDetector.h), on the stream connection of the rendering backend that created them, so in its work queue. They
// detect with WebCore's ShapeDetectionVision, in native images the backend has cached.

extension WebKit.RemoteBarcodeDetector {
    func detect(
        renderingResourceIdentifier: IPCTypes.RenderingResourceIdentifier,
        reply: consuming RemoteBarcodeDetectorDetectReply
    ) throws(InvalidMessage) {
        var found = false
        let image = WebKit.copyShapeDetectionImage(self, renderingResourceIdentifier.rawValue, &found)
        try messageCheck { found }
        guard let image else {
            reply.send([])
            return
        }
        let detector: ShapeDetectionVision.BarcodeDetector = .init(requestedFormatMask: requestedFormatMask())
        reply.send(detector.detect(image).map(ipcDetectedBarcode))
    }
}

extension WebKit.RemoteFaceDetector {
    func detect(
        renderingResourceIdentifier: IPCTypes.RenderingResourceIdentifier,
        reply: consuming RemoteFaceDetectorDetectReply
    ) throws(InvalidMessage) {
        var found = false
        let image = WebKit.copyShapeDetectionImage(self, renderingResourceIdentifier.rawValue, &found)
        try messageCheck { found }
        guard let image else {
            reply.send([])
            return
        }
        let detector: ShapeDetectionVision.FaceDetector = .init(maxDetectedFaces: maxDetectedFaces())
        reply.send(detector.detect(image).map(ipcDetectedFace))
    }
}

extension WebKit.RemoteTextDetector {
    func detect(
        renderingResourceIdentifier: IPCTypes.RenderingResourceIdentifier,
        reply: consuming RemoteTextDetectorDetectReply
    ) throws(InvalidMessage) {
        var found = false
        let image = WebKit.copyShapeDetectionImage(self, renderingResourceIdentifier.rawValue, &found)
        try messageCheck { found }
        guard let image else {
            reply.send([])
            return
        }
        let detector: ShapeDetectionVision.TextDetector = .init()
        reply.send(detector.detect(image).map(ipcDetectedText))
    }
}

private func ipcRect(_ rect: ShapeDetectionVision.Rect) -> IPCTypes.FloatRect {
    .init(location: .init(x: rect.x, y: rect.y), size: .init(width: rect.width, height: rect.height))
}

private func ipcPoints(_ points: [ShapeDetectionVision.Point]) -> [IPCTypes.FloatPoint] {
    points.map { .init(x: $0.x, y: $0.y) }
}

// The formats' and landmark types' values are their C++ enums', which IPC's Swift forms have; a value without one would
// be the C++ structs' default.
private func ipcDetectedBarcode(_ barcode: ShapeDetectionVision.DetectedBarcode) -> IPCTypes.DetectedBarcode {
    .init(
        boundingBox: ipcRect(barcode.boundingBox),
        rawValue: barcode.rawValue,
        format: IPCTypes.BarcodeFormat(rawValue: barcode.format) ?? .unknown,
        cornerPoints: ipcPoints(barcode.cornerPoints)
    )
}

private func ipcDetectedFace(_ face: ShapeDetectionVision.DetectedFace) -> IPCTypes.DetectedFace {
    .init(
        boundingBox: ipcRect(face.boundingBox),
        landmarks: face.landmarks.map { .init(locations: ipcPoints($0.locations), type: IPCTypes.LandmarkType(rawValue: $0.type) ?? .eye) }
    )
}

private func ipcDetectedText(_ text: ShapeDetectionVision.DetectedText) -> IPCTypes.DetectedText {
    .init(boundingBox: ipcRect(text.boundingBox), rawValue: text.rawValue, cornerPoints: ipcPoints(text.cornerPoints))
}

#endif // ENABLE_GPU_PROCESS && HAVE_SHAPE_DETECTION_API_IMPLEMENTATION
