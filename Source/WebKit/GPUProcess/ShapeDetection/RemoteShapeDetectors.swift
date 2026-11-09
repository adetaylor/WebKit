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

// The GPU process's shape detection. The rendering backend's handlers create and release the detectors' receivers, on its
// stream connection, so in its work queue, and say which barcode formats Vision detects. The receivers detect with
// WebCore's ShapeDetectionVision, in native images the backend has cached.

extension WebKit.RemoteRenderingBackend {
    func createBarcodeDetector(
        identifier: IPCTypes.ShapeDetectionIdentifier,
        barcodeDetectorOptions: IPCTypes.BarcodeDetectorOptions
    ) throws(InvalidMessage) {
        let detector = ShapeDetectionVision.BarcodeDetector(requestedFormats: barcodeDetectorOptions.formats.map(\.rawValue))
        let forwarder = RemoteBarcodeDetector(detector, self).messageForwarder()
        try messageCheck("a detector has the identifier") {
            IPC.tryStartReceivingSwiftMessages(streamConnection(), forwarder, .RemoteBarcodeDetector, identifier.rawValue)
        }
    }

    func releaseBarcodeDetector(identifier: IPCTypes.ShapeDetectionIdentifier) throws(InvalidMessage) {
        try messageCheck("no detector has the identifier") {
            streamConnection().tryStopReceivingMessages(.RemoteBarcodeDetector, identifier.rawValue)
        }
    }

    func supportedBarcodeDetectorBarcodeFormats(reply: consuming RemoteRenderingBackendSupportedBarcodeDetectorBarcodeFormatsReply) {
        reply.send(ShapeDetectionVision.BarcodeDetector.supportedFormats().compactMap { IPCTypes.BarcodeFormat(rawValue: $0) })
    }

    func createFaceDetector(
        identifier: IPCTypes.ShapeDetectionIdentifier,
        faceDetectorOptions: IPCTypes.FaceDetectorOptions
    ) throws(InvalidMessage) {
        let detector = ShapeDetectionVision.FaceDetector(maxDetectedFaces: faceDetectorOptions.maxDetectedFaces)
        let forwarder = RemoteFaceDetector(detector, self).messageForwarder()
        try messageCheck("a detector has the identifier") {
            IPC.tryStartReceivingSwiftMessages(streamConnection(), forwarder, .RemoteFaceDetector, identifier.rawValue)
        }
    }

    func releaseFaceDetector(identifier: IPCTypes.ShapeDetectionIdentifier) throws(InvalidMessage) {
        try messageCheck("no detector has the identifier") {
            streamConnection().tryStopReceivingMessages(.RemoteFaceDetector, identifier.rawValue)
        }
    }

    func createTextDetector(identifier: IPCTypes.ShapeDetectionIdentifier) throws(InvalidMessage) {
        let forwarder = RemoteTextDetector(.init(), self).messageForwarder()
        try messageCheck("a detector has the identifier") {
            IPC.tryStartReceivingSwiftMessages(streamConnection(), forwarder, .RemoteTextDetector, identifier.rawValue)
        }
    }

    func releaseTextDetector(identifier: IPCTypes.ShapeDetectionIdentifier) throws(InvalidMessage) {
        try messageCheck("no detector has the identifier") {
            streamConnection().tryStopReceivingMessages(.RemoteTextDetector, identifier.rawValue)
        }
    }
}

// Each receiver's forwarder keeps it while the stream connection keeps the forwarder, until the backend releases the
// detector or the connection is invalidated. The receiver keeps the backend.

@_expose(Cxx)
final class RemoteBarcodeDetector {
    private let detector: ShapeDetectionVision.BarcodeDetector
    private let backend: WebKit.RemoteRenderingBackend

    @_expose(!Cxx)
    fileprivate init(_ detector: ShapeDetectionVision.BarcodeDetector, _ backend: WebKit.RemoteRenderingBackend) {
        self.detector = detector
        self.backend = backend
    }

    @_expose(!Cxx)
    fileprivate func messageForwarder() -> RefRemoteBarcodeDetectorMessageForwarder {
        WebKit.RemoteBarcodeDetectorMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        backend.sharedPreferencesForWebProcess()
    }

    func detect(
        renderingResourceIdentifier: IPCTypes.RenderingResourceIdentifier,
        reply: consuming RemoteBarcodeDetectorDetectReply
    ) throws(InvalidMessage) {
        guard let image = try cachedImage(backend, renderingResourceIdentifier) else {
            reply.send([])
            return
        }
        reply.send(detector.detect(image).map(ipcDetectedBarcode))
    }
}

@_expose(Cxx)
final class RemoteFaceDetector {
    private let detector: ShapeDetectionVision.FaceDetector
    private let backend: WebKit.RemoteRenderingBackend

    @_expose(!Cxx)
    fileprivate init(_ detector: ShapeDetectionVision.FaceDetector, _ backend: WebKit.RemoteRenderingBackend) {
        self.detector = detector
        self.backend = backend
    }

    @_expose(!Cxx)
    fileprivate func messageForwarder() -> RefRemoteFaceDetectorMessageForwarder {
        WebKit.RemoteFaceDetectorMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        backend.sharedPreferencesForWebProcess()
    }

    func detect(
        renderingResourceIdentifier: IPCTypes.RenderingResourceIdentifier,
        reply: consuming RemoteFaceDetectorDetectReply
    ) throws(InvalidMessage) {
        guard let image = try cachedImage(backend, renderingResourceIdentifier) else {
            reply.send([])
            return
        }
        reply.send(detector.detect(image).map(ipcDetectedFace))
    }
}

@_expose(Cxx)
final class RemoteTextDetector {
    private let detector: ShapeDetectionVision.TextDetector
    private let backend: WebKit.RemoteRenderingBackend

    @_expose(!Cxx)
    fileprivate init(_ detector: ShapeDetectionVision.TextDetector, _ backend: WebKit.RemoteRenderingBackend) {
        self.detector = detector
        self.backend = backend
    }

    @_expose(!Cxx)
    fileprivate func messageForwarder() -> RefRemoteTextDetectorMessageForwarder {
        WebKit.RemoteTextDetectorMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        backend.sharedPreferencesForWebProcess()
    }

    func detect(
        renderingResourceIdentifier: IPCTypes.RenderingResourceIdentifier,
        reply: consuming RemoteTextDetectorDetectReply
    ) throws(InvalidMessage) {
        guard let image = try cachedImage(backend, renderingResourceIdentifier) else {
            reply.send([])
            return
        }
        reply.send(detector.detect(image).map(ipcDetectedText))
    }
}

// The image of the native image the backend has cached under the identifier: an identifier it has none for is an invalid
// message; a native image with no platform image gives nil.
private func cachedImage(
    _ backend: WebKit.RemoteRenderingBackend,
    _ identifier: IPCTypes.RenderingResourceIdentifier
) throws(InvalidMessage) -> CGImage? {
    var found = false
    let image = WebKit.copyCachedNativeImage(backend, identifier.rawValue, &found)
    try messageCheck("no native image has the identifier") { found }
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
