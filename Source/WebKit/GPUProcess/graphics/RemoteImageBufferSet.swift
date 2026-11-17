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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_IMAGE_BUFFER_SET_SWIFT

import os
@_spi(WebKitGPU) internal import WebCore
import WebCore_Private
import WebCore_Private.Core.GraphicsContextSwiftBridge
import WebKit_Internal

private let remoteLayerBuffersLog = os.Logger(subsystem: "com.apple.WebKit", category: "RemoteLayerBuffers")

// The image buffers of a layer, and the receiver of their messages, on the rendering backend's work queue: the front buffer
// that a rendering update draws into, and the back buffers that the display may still show. The backend's state keeps it
// until the backend releases it, which stops its messages (stopListeningForIPC()). Exposed to C++ only as the type its
// generated message forwarder keeps.
@_expose(Cxx)
final class RemoteImageBufferSet {
    private let identifier: UInt64
    private let contextIdentifier: WebKit.RemoteGraphicsContextIdentifier
    private let backend: WebKit.RemoteRenderingBackend
    private var frontBuffer: WebCore.ImageBuffer?
    private var backBuffer: WebCore.ImageBuffer?
    private var secondaryBackBuffer: WebCore.ImageBuffer?
    private var previouslyPaintedRect: WebCore.IntRect?
    private var frontBufferIsCleared = false
    private var configuration = WebKit.RemoteImageBufferSetConfiguration()
    // The receiver of the front buffer's drawing, while the set prepares it for display.
    private var context: WebKit.RemoteImageBufferGraphicsContext?

    private init(identifier: UInt64, contextIdentifier: WebKit.RemoteGraphicsContextIdentifier, backend: WebKit.RemoteRenderingBackend) {
        self.identifier = identifier
        self.contextIdentifier = contextIdentifier
        self.backend = backend
    }

    deinit {
        // Unwind the context's state stack before destruction, since calls to restore may not have been flushed yet, or the
        // web process may have terminated. Volatile image buffers do not have contexts.
        if let frontBuffer, frontBuffer.volatilityState() != .Volatile, frontBuffer.hasBackend() {
            let drawing = WebCore.ImageBufferDrawing(frontBuffer)
            drawing.context().unwindStateStack()
        }
        context?.stopListeningForIPC()
    }

    // A set that receives the messages to the identifier on the backend's stream connection: nil if another receiver has it.
    @_expose(!Cxx)
    static func create(
        identifier: WebKit.ImageBufferSetIdentifier,
        contextIdentifier: WebKit.RemoteGraphicsContextIdentifier,
        backend: WebKit.RemoteRenderingBackend
    ) -> RemoteImageBufferSet? {
        let set = RemoteImageBufferSet(identifier: identifier.toUInt64(), contextIdentifier: contextIdentifier, backend: backend)
        let forwarder = WebKit.RemoteImageBufferSetMessageForwarder.create(target: set)
        guard WebKit.tryStartReceivingSwiftMessages(backend, forwarder, .RemoteImageBufferSet, set.identifier) else {
            return nil
        }
        return set
    }

    @_expose(!Cxx)
    func stopListeningForIPC() {
        _ = backend.tryStopReceivingMessages(.RemoteImageBufferSet, identifier)
    }

    @_expose(!Cxx)
    func isPreparingForDisplay() -> Bool {
        context != nil
    }

    // Tries to swap one of the existing back buffers to the new front buffer, if any are not currently in use.
    private func swapBuffersForDisplay(hasEmptyDirtyRegion: Bool, supportsPartialRepaint: Bool) -> WebKit.SwapBuffersDisplayRequirement {
        var displayRequirement = WebKit.SwapBuffersDisplayRequirement.NeedsNoDisplay

        // Make the previous front buffer non-volatile early, so that we can dirty the whole layer if it comes back empty.
        if frontBuffer.map({ $0.setNonVolatile() == .Empty }) ?? true {
            displayRequirement = .NeedsFullDisplay
        } else if !hasEmptyDirtyRegion {
            displayRequirement = .NeedsNormalDisplay
        }

        if displayRequirement == .NeedsNoDisplay {
            return displayRequirement
        }

        if !supportsPartialRepaint {
            displayRequirement = .NeedsFullDisplay
        }

        if backBuffer.map({ $0.isInUse() }) ?? true {
            previouslyPaintedRect = nil
            (backBuffer, secondaryBackBuffer) = (secondaryBackBuffer, backBuffer)

            // When pulling the secondary back buffer out of hibernation (to become the new front buffer), if it is somehow
            // still in use (e.g. we got three swaps ahead of the render server), just give up and discard it.
            if let backBuffer, backBuffer.isInUse() {
                self.backBuffer = nil
            }
        }

        (frontBuffer, backBuffer) = (backBuffer, frontBuffer)

        if let frontBuffer, frontBuffer.setNonVolatile() == .Empty {
            previouslyPaintedRect = nil
        }

        return displayRequirement
    }

    // Logs the configuration of a front buffer that failed to allocate.
    private func logFailedAllocation() {
        let size = configuration.logicalSize
        let format = configuration.bufferFormat
        remoteLayerBuffersLog.error(
            """
            RemoteImageBufferSet \(self.identifier) failed to allocate front buffer: size \(size.width())x\(size.height()) \
            scale \(self.configuration.resolutionScale) pixelFormat \(format.pixelFormat.rawValue) \
            lossless \(format.useLosslessCompression == .Yes) renderingMode \(self.configuration.renderingMode.rawValue) \
            renderingPurpose \(self.configuration.renderingPurpose.rawValue)
            """
        )
    }

    // This is the GPU Process version of RemoteLayerBackingStore::prepareBuffers(). Makes the front buffer valid, by swapping
    // in a back buffer or allocating one, and, unless it needs no display, starts receiving its drawing. For a full display,
    // the dirty region becomes the layer's bounds.
    @_expose(!Cxx)
    func ensureBufferForDisplay(
        _ inputData: inout WebKit.ImageBufferSetPrepareBufferForDisplayInputData,
        isSync: Bool
    ) -> WebKit.SwapBuffersDisplayRequirement {
        let displayRequirement = swapBuffersForDisplay(
            hasEmptyDirtyRegion: inputData.hasEmptyDirtyRegion,
            supportsPartialRepaint: inputData.supportsPartialRepaint && !WebKit.isSmallLayerBacking(configuration.imageBufferParameters())
        )
        if displayRequirement == .NeedsFullDisplay {
            let layerBounds = WebCore.Region(WebCore.IntRect(WebCore.IntPoint(), WebCore.expandedIntSize(configuration.logicalSize)))
            do throws(InvalidMessage) {
                try messageCheck("Can't asynchronously require full display for a buffer set") {
                    isSync || inputData.dirtyRegion.contains(layerBounds)
                }
            } catch {
                markMessageInvalid(error, on: backend.streamConnection())
                return displayRequirement
            }
            inputData.dirtyRegion = layerBounds
        }

        if frontBuffer == nil {
            frontBuffer = backend.allocateImageBuffer(
                configuration.logicalSize,
                configuration.renderingMode,
                configuration.renderingPurpose,
                configuration.resolutionScale,
                configuration.colorSpace,
                configuration.bufferFormat
            ).get()
            if frontBuffer == nil {
                logFailedAllocation()
            }
            frontBufferIsCleared = true
        }

        if displayRequirement != .NeedsNoDisplay {
            guard let imageBuffer = frontBuffer ?? WebCore.createNullImageBuffer().get() else {
                preconditionFailure("No empty image buffer")
            }
            // The previous receiver stops before the new one, which takes its identifier, starts.
            context?.stopListeningForIPC()
            context = WebKit.RemoteImageBufferGraphicsContext.createForSwift(imageBuffer, contextIdentifier, backend)
        }
        return displayRequirement
    }

    // Copies what the dirty region leaves of the previous frame into the new front buffer, clips to the region, and clears
    // the pixels to be drawn, unless drawing will be opaque.
    @_expose(!Cxx)
    func prepareBufferForDisplay(dirtyRegion: borrowing WebCore.Region, requiresClearedPixels: Bool) {
        guard let frontBuffer = frontBuffer else {
            previouslyPaintedRect = nil
            return
        }

        let paintingRects = WebKit.PaintingRects(dirtyRegion, configuration.resolutionScale)
        let rects: Span<WebCore.FloatRect> = paintingRects.span()
        let layerBounds = WebCore.FloatRect(WebCore.FloatPoint(), configuration.logicalSize)

        let drawing = WebCore.ImageBufferDrawing(frontBuffer)
        let context = drawing.context()
        context.resetClip()

        var copyRect = WebCore.FloatRect()
        if let backBuffer = backBuffer {
            let enclosingCopyRect = previouslyPaintedRect ?? WebCore.enclosingIntRect(layerBounds)
            if !dirtyRegion.contains(WebCore.Region(enclosingCopyRect)) {
                var copyRegion = WebCore.Region(enclosingCopyRect)
                copyRegion.subtract(dirtyRegion)
                copyRect = WebCore.intersection(WebCore.FloatRect(copyRegion.bounds()), layerBounds)
                if !copyRect.isEmpty() {
                    context.drawImageBuffer(backBuffer, copyRect, copyRect, .Copy, .Normal)
                }
            }
        }

        if rects.count == 1 {
            context.clip(rects[0])
            if copyRect.intersects(rects[0]) {
                frontBufferIsCleared = false
            }
        } else {
            // If the copy-forward touched pixels that are about to be painted, then they won't be 'clear' any more.
            for index in rects.indices where copyRect.intersects(rects[index]) {
                frontBufferIsCleared = false
            }
            context.clipToRects(rects)
        }

        if requiresClearedPixels && !frontBufferIsCleared {
            context.clearRect(layerBounds)
        }

        previouslyPaintedRect = dirtyRegion.bounds()
        frontBufferIsCleared = false
    }

    // The BufferInSetType raw values of the buffers that it made volatile, of those requested, and whether it made all of them
    // volatile.
    @_expose(!Cxx)
    func makeBuffersVolatile(_ requestedBuffers: UInt8, forcePurge: Bool) -> (volatileBuffers: UInt8, allSucceeded: Bool) {
        var volatileBuffers: UInt8 = 0
        var allSucceeded = true
        func makeBufferTypeVolatile(_ type: WebKit.BufferInSetType, _ imageBuffer: WebCore.ImageBuffer?) {
            guard requestedBuffers & type.rawValue != 0, let imageBuffer else {
                return
            }
            let madeVolatile: Bool
            // Safety: the set is not preparing for display (RemoteRenderingBackend checks it), so no receiver draws into
            // the buffer or holds its context.
            if forcePurge {
                unsafe imageBuffer.setVolatileAndPurgeForTesting()
                madeVolatile = true
            } else {
                unsafe imageBuffer.releaseGraphicsContext()
                madeVolatile = imageBuffer.setVolatile()
            }
            if madeVolatile {
                volatileBuffers |= type.rawValue
            } else {
                allSucceeded = false
            }
        }
        makeBufferTypeVolatile(.Front, frontBuffer)
        makeBufferTypeVolatile(.Back, backBuffer)
        makeBufferTypeVolatile(.SecondaryBack, secondaryBackBuffer)
        return (volatileBuffers, allSucceeded)
    }

    // Messages

    @_expose(!Cxx)
    func updateConfiguration(connection: IPC.StreamServerConnection, configuration: WebKit.RemoteImageBufferSetConfiguration) {
        self.configuration = configuration
        frontBuffer = nil
        backBuffer = nil
        secondaryBackBuffer = nil
    }

    @_expose(!Cxx)
    func endPrepareForDisplay(
        renderingUpdateID: CxxDecodedArguments.RemoteImageBufferSet.EndPrepareForDisplayRenderingUpdateID,
        reply: consuming RemoteImageBufferSetEndPrepareForDisplayReply
    ) {
        context?.stopListeningForIPC()
        context = nil
        frontBuffer?.flushDrawingContext()
        let frontBuffer = frontBuffer
        let backBuffer = backBuffer
        let secondaryBackBuffer = secondaryBackBuffer
        reply.send { encoder in
            WebKit.encodeImageBufferSetEndPrepareForDisplayReply(encoder, renderingUpdateID, frontBuffer, backBuffer, secondaryBackBuffer)
        }
    }

    @_expose(!Cxx)
    func submitDrawingCommands() {
        frontBuffer?.submitDrawingCommands()
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_IMAGE_BUFFER_SET_SWIFT
