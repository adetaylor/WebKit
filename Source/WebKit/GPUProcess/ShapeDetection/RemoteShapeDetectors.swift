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

// The receivers of a shape detector's messages, on the stream connection of the rendering backend that created it, so
// in its work queue. They detect with WebCore's ShapeDetectionVision, in native images the backend has cached.

@_expose(Cxx)
final class RemoteBarcodeDetector {
    private let detector: ShapeDetectionVision.BarcodeDetector
    private let resources: WebKit.RemoteShapeDetectionResources

    @_expose(!Cxx)
    private init(_ detector: ShapeDetectionVision.BarcodeDetector, _ resources: WebKit.RemoteShapeDetectionResources) {
        self.detector = detector
        self.resources = resources
    }

    // A new receiver, and the forwarder of its messages, which keeps it. Only C++ calls it, so @used keeps it under
    // -O -wmo (rdar://179098545).
    @used
    static func createMessageReceiver(
        _ resources: WebKit.RemoteShapeDetectionResources,
        _ requestedFormatMask: UInt16
    ) -> RefRemoteBarcodeDetectorMessageForwarder {
        WebKit.RemoteBarcodeDetectorMessageForwarder.create(
            target: RemoteBarcodeDetector(.init(requestedFormatMask: requestedFormatMask), resources)
        )
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        resources.sharedPreferencesForWebProcess()
    }

    func detect(
        renderingResourceIdentifier: IPCTypes.RenderingResourceIdentifier,
        reply: consuming RemoteBarcodeDetectorDetectReply
    ) throws(InvalidMessage) {
        guard let image = try sourceImage(resources, renderingResourceIdentifier) else {
            reply.send([])
            return
        }
        reply.send(detector.detect(image).map(ipcDetectedBarcode))
    }
}

@_expose(Cxx)
final class RemoteFaceDetector {
    private let detector: ShapeDetectionVision.FaceDetector
    private let resources: WebKit.RemoteShapeDetectionResources

    @_expose(!Cxx)
    private init(_ detector: ShapeDetectionVision.FaceDetector, _ resources: WebKit.RemoteShapeDetectionResources) {
        self.detector = detector
        self.resources = resources
    }

    // A new receiver, and the forwarder of its messages, which keeps it. Only C++ calls it, so @used keeps it under
    // -O -wmo (rdar://179098545).
    @used
    static func createMessageReceiver(
        _ resources: WebKit.RemoteShapeDetectionResources,
        _ maxDetectedFaces: UInt16
    ) -> RefRemoteFaceDetectorMessageForwarder {
        WebKit.RemoteFaceDetectorMessageForwarder.create(target: RemoteFaceDetector(.init(maxDetectedFaces: maxDetectedFaces), resources))
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        resources.sharedPreferencesForWebProcess()
    }

    func detect(
        renderingResourceIdentifier: IPCTypes.RenderingResourceIdentifier,
        reply: consuming RemoteFaceDetectorDetectReply
    ) throws(InvalidMessage) {
        guard let image = try sourceImage(resources, renderingResourceIdentifier) else {
            reply.send([])
            return
        }
        reply.send(detector.detect(image).map(ipcDetectedFace))
    }
}

@_expose(Cxx)
final class RemoteTextDetector {
    private let detector: ShapeDetectionVision.TextDetector
    private let resources: WebKit.RemoteShapeDetectionResources

    @_expose(!Cxx)
    private init(_ detector: ShapeDetectionVision.TextDetector, _ resources: WebKit.RemoteShapeDetectionResources) {
        self.detector = detector
        self.resources = resources
    }

    // A new receiver, and the forwarder of its messages, which keeps it. Only C++ calls it, so @used keeps it under
    // -O -wmo (rdar://179098545).
    @used
    static func createMessageReceiver(_ resources: WebKit.RemoteShapeDetectionResources) -> RefRemoteTextDetectorMessageForwarder {
        WebKit.RemoteTextDetectorMessageForwarder.create(target: RemoteTextDetector(.init(), resources))
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        resources.sharedPreferencesForWebProcess()
    }

    func detect(
        renderingResourceIdentifier: IPCTypes.RenderingResourceIdentifier,
        reply: consuming RemoteTextDetectorDetectReply
    ) throws(InvalidMessage) {
        guard let image = try sourceImage(resources, renderingResourceIdentifier) else {
            reply.send([])
            return
        }
        reply.send(detector.detect(image).map(ipcDetectedText))
    }
}

// The image of the native image the backend has cached under the identifier, which is nil if it has none. An identifier
// the backend has no native image for is an invalid message.
private func sourceImage(
    _ resources: WebKit.RemoteShapeDetectionResources,
    _ identifier: IPCTypes.RenderingResourceIdentifier
) throws(InvalidMessage) -> CGImage? {
    var found = false
    let image = WebKit.copyShapeDetectionImage(resources, identifier.rawValue, &found)
    try messageCheck { found }
    return image
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
