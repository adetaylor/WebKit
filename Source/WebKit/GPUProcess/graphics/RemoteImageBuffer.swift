// Copyright (C) 2020-2022 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT

@_spi(WebKitGPU) internal import WebCore
import WebCore_Private
import WebKit_Internal

// The receiver of an image buffer's messages, from the buffer's creation until the rendering backend releases it, on the
// backend's work queue. The buffer is a WebCore::ImageBuffer, with the backend it was made with; its context, which
// receives its drawing, does what takes the WebCore types that Swift has no form of.
@_expose(Cxx)
final class RemoteImageBuffer {
    @_expose(!Cxx)
    let imageBuffer: WebCore.ImageBuffer
    private let identifier: UInt64
    private let backend: WebKit.RemoteRenderingBackend
    private let context: WebKit.RemoteImageBufferGraphicsContext
    // The drawing of a buffer whose drawing is recorded (RenderingMode::DisplayList), which its context can't draw.
    private let recordedDrawing: RemoteCGRendererRecordedDrawing?
    // The signal that FlushContext signals once the buffer's drawing is flushed.
    private var flushSignal: FlushSignal?

    @_expose(!Cxx)
    private init(
        imageBuffer: WebCore.ImageBuffer,
        identifier: UInt64,
        backend: WebKit.RemoteRenderingBackend,
        context: WebKit.RemoteImageBufferGraphicsContext,
        recordedDrawing: RemoteCGRendererRecordedDrawing?
    ) {
        self.imageBuffer = imageBuffer
        self.identifier = identifier
        self.backend = backend
        self.context = context
        self.recordedDrawing = recordedDrawing
    }

    // A receiver of the buffer's messages, which the backend's stream connection keeps until stopReceivingMessages(): nil
    // if another receiver has the identifier.
    @_expose(!Cxx)
    static func create(
        _ imageBuffer: WebCore.ImageBuffer,
        identifier: UInt64,
        contextIdentifier: WebKit.RemoteGraphicsContextIdentifier,
        backend: WebKit.RemoteRenderingBackend
    ) -> RemoteImageBuffer? {
        let context = WebKit.RemoteImageBufferGraphicsContext.createForImageBufferReceiver(imageBuffer, contextIdentifier, backend)
        var recordedDrawing: RemoteCGRendererRecordedDrawing?
        if imageBuffer.renderingMode() == .DisplayList {
            // Another receiver of drawing has the context's identifier: the message is invalid.
            guard let drawing = startRecordedDrawing(context, contextIdentifier, backend) else {
                context.releaseImageBuffer()
                return nil
            }
            recordedDrawing = drawing
        }
        let receiver = RemoteImageBuffer(
            imageBuffer: imageBuffer,
            identifier: identifier,
            backend: backend,
            context: context,
            recordedDrawing: recordedDrawing
        )
        let forwarder = WebKit.RemoteImageBufferMessageForwarder.create(target: receiver)
        guard WebKit.tryStartReceivingSwiftMessages(backend, forwarder, .RemoteImageBuffer, identifier) else {
            context.stopListeningForIPC()
            recordedDrawing?.stopRecording()
            context.releaseImageBuffer()
            return nil
        }
        return receiver
    }

    // Records the drawing of a buffer whose drawing is recorded, which its context's recording draws where the buffer is drawn,
    // until the buffer no longer receives drawing.
    private static func startRecordedDrawing(
        _ context: WebKit.RemoteImageBufferGraphicsContext,
        _ contextIdentifier: WebKit.RemoteGraphicsContextIdentifier,
        _ backend: WebKit.RemoteRenderingBackend
    ) -> RemoteCGRendererRecordedDrawing? {
        let backendState = backend.state
        let (recordedDrawing, forwarder) = RemoteCGRendererRecordedDrawing.create(
            resources: WebKit.createDisplayListRecorderResources(backend),
            displayLists: backendState.displayLists,
            videoFrameSources: backendState.videoFrameSources
        )
        guard WebKit.tryStartReceivingSwiftMessages(backend, forwarder, .RemoteCGRenderer, contextIdentifier.toUInt64())
        else {
            return nil
        }
        // Safety: the drawing is retained once, which only the placeholder that the context gives it releases.
        unsafe context.installRecordedDrawing(UInt(bitPattern: unsafe Unmanaged.passRetained(recordedDrawing).toOpaque()))
        return recordedDrawing
    }

    // The buffer's messages, and its context's, stop coming; the buffer stops being counted.
    @_expose(!Cxx)
    func stopReceivingMessages() {
        context.stopListeningForIPC()
        recordedDrawing?.stopRecording()
        _ = backend.tryStopReceivingMessages(.RemoteImageBuffer, identifier)
        context.releaseImageBuffer()
    }

    // The pixels of a buffer that holds them, which isn't a layer's: other messages are invalid.
    private func checkPixelsCanBeRead() throws(InvalidMessage) {
        try messageCheck("Backend does not hold pixels") {
            let renderingMode = imageBuffer.renderingMode()
            return renderingMode != .PDFDocument && renderingMode != .DisplayList
        }
        try messageCheck("We should not interact with the pixelBuffer for LayerBacking") {
            imageBuffer.renderingPurpose() != .LayerBacking
        }
    }

    // This is using location and size as opposed to rect because invalid rect object gets restricted by IPC rect object
    // decoder and triggers timeout in WebContent process.
    func getPixelBuffer(
        outputFormat: CxxDecodedArguments.RemoteImageBuffer.GetPixelBufferOutputFormat,
        srcPoint: IPCTypes.IntPoint,
        srcSize: IPCTypes.IntSize
    ) throws(InvalidMessage) {
        try checkPixelsCanBeRead()
        let result = context.getPixelBuffer(outputFormat, srcPoint.x, srcPoint.y, srcSize.width, srcSize.height)
        try messageCheck("No shared memory for getPixelBufferForImageBuffer") {
            result != .NoSharedMemory
        }
        try messageCheck("Pixel format not supported") {
            result != .UnsupportedFormat
        }
        try messageCheck("Shmem for return of getPixelBuffer is too small") {
            result != .SharedMemoryTooSmall
        }
    }

    func getPixelBufferWithNewMemory(
        handle: CxxDecodedArguments.RemoteImageBuffer.GetPixelBufferWithNewMemoryHandle,
        outputFormat: CxxDecodedArguments.RemoteImageBuffer.GetPixelBufferWithNewMemoryOutputFormat,
        srcPoint: IPCTypes.IntPoint,
        srcSize: IPCTypes.IntSize
    ) throws(InvalidMessage) {
        try messageCheck("Shared memory could not be mapped.") {
            context.setPixelBufferSharedMemory(handle)
        }
        try getPixelBuffer(outputFormat: outputFormat, srcPoint: srcPoint, srcSize: srcSize)
    }

    func putPixelBuffer(
        connection: IPC.StreamServerConnection,
        pixelBuffer: borrowing WebCore.PixelBufferSourceView,
        srcPoint: WebCore.IntPoint,
        srcSize: WebCore.IntSize,
        destPoint: WebCore.IntPoint,
        destFormat: WebCore.AlphaPremultiplication
    ) throws(InvalidMessage) {
        try messageCheck("putPixelBuffer() should not be called if (resolutionScale() != 1)") {
            imageBuffer.resolutionScale() == 1
        }
        try checkPixelsCanBeRead()
        context.putPixelBuffer(pixelBuffer, srcPoint, srcSize, destPoint, destFormat)
    }

    func copyNativeImage(image: IPCTypes.RenderingResourceIdentifier) throws(InvalidMessage) {
        try messageCheck("NativeImage could not be created, or already exists") {
            context.copyNativeImage(image.rawValue)
        }
    }

    func convertToLuminanceMask() {
        imageBuffer.convertToLuminanceMask()
    }

    func transformToColorSpace(connection: IPC.StreamServerConnection, colorSpace: WebCore.ColorSpace) {
        imageBuffer.transformToColorSpace(colorSpace)
    }

    func setFlushSignal(signal: consuming IPCTypes.Signal) {
        flushSignal = FlushSignal(signal)
    }

    func flushContext() throws(InvalidMessage) {
        try messageCheck("Cannot flush context without a valid flush signal. Use FlushContextSync for synchronous flushing.") {
            flushSignal != nil
        }
        imageBuffer.flushDrawingContext()
        flushSignal?.signal.signal()
    }

    func flushContextSync() {
        imageBuffer.flushDrawingContext()
    }

    func getEffectiveRenderingModeForTesting(connection: IPC.StreamServerConnection) -> WebCore.OptionalRenderingMode {
        imageBuffer.getEffectiveRenderingModeForTesting()
    }

    func getBackendHandle(reply: consuming RemoteImageBufferGetBackendHandleReply) {
        let context = context
        reply.send { encoder in
            context.encodeBackendHandle(encoder)
        }
    }

    #if WTF_PLATFORM_COCOA
    // The finished signal is signalled once the display is done with the buffer, or once it gives up waiting.
    func prepareForDisplay(finishedSignal: consuming IPCTypes.Semaphore, reply: consuming RemoteImageBufferPrepareForDisplayReply) {
        let context = context
        reply.send { encoder in
            context.encodeDisplayBuffer(encoder)
        }
        context.waitForDisplayBuffer()
        finishedSignal.signal()
    }
    #endif

    #if ENABLE_RE_DYNAMIC_CONTENT_SCALING
    func dynamicContentScalingDisplayList(reply: consuming RemoteImageBufferDynamicContentScalingDisplayListReply) {
        let context = context
        reply.send { encoder in
            context.encodeDynamicContentScalingDisplayList(encoder)
        }
    }
    #endif
}

// A flush signal, which the receiver keeps in a class since IPCTypes.Signal is ~Copyable.
private final class FlushSignal {
    let signal: IPCTypes.Signal

    init(_ signal: consuming IPCTypes.Signal) {
        self.signal = signal
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
