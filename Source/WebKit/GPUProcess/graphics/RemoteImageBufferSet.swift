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

#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT && !ENABLE_RE_DYNAMIC_CONTENT_SCALING

import os
@_spi(WebKitGPU) internal import WebCore
import WebCore_Private
import WebCore_Private.Core.GraphicsContextSwiftBridge
import WebKit_Internal

// RemoteImageBufferSet::swiftSomeBuffersStayedNonVolatile.
private let someBuffersStayedNonVolatile: UInt16 = 1 << 8

private let remoteLayerBuffersLog = os.Logger(subsystem: "com.apple.WebKit", category: "RemoteLayerBuffers")

// The state of a RemoteImageBufferSet, on the rendering backend's work queue.
private final class RemoteImageBufferSetState {
    let contextIdentifier: WebKit.RemoteGraphicsContextIdentifier
    let backend: WebKit.RemoteRenderingBackend
    var frontBuffer: WebCore.ImageBuffer?
    var backBuffer: WebCore.ImageBuffer?
    var secondaryBackBuffer: WebCore.ImageBuffer?
    var previouslyPaintedRect: WebCore.IntRect?
    var frontBufferIsCleared = false
    var configuration = WebKit.RemoteImageBufferSetConfiguration()
    // The receiver of the front buffer's drawing, while the set prepares it for display.
    var context: WebKit.RemoteImageBufferGraphicsContext?

    init(contextIdentifier: WebKit.RemoteGraphicsContextIdentifier, backend: WebKit.RemoteRenderingBackend) {
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

    // Tries to swap one of the existing back buffers to the new front buffer, if any are not currently in use.
    func swapBuffersForDisplay(hasEmptyDirtyRegion: Bool, supportsPartialRepaint: Bool) -> WebKit.SwapBuffersDisplayRequirement {
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
    func logFailedAllocation(identifier: UInt64) {
        let size = configuration.logicalSize
        let format = configuration.bufferFormat
        remoteLayerBuffersLog.error(
            """
            RemoteImageBufferSet \(identifier) failed to allocate front buffer: size \(size.width())x\(size.height()) \
            scale \(self.configuration.resolutionScale) pixelFormat \(format.pixelFormat.rawValue) \
            lossless \(format.useLosslessCompression == .Yes) renderingMode \(self.configuration.renderingMode.rawValue) \
            renderingPurpose \(self.configuration.renderingPurpose.rawValue)
            """
        )
    }
}

extension WebKit.RemoteImageBufferSet {
    private var state: RemoteImageBufferSetState {
        // Safety: m_swiftState is a retained RemoteImageBufferSetState from createSwiftState() to the destructor.
        unsafe Unmanaged<RemoteImageBufferSetState>.fromOpaque(Self.address(swiftState())).takeUnretainedValue()
    }

    private static func address(_ swiftState: UInt) -> UnsafeRawPointer {
        guard let address = unsafe UnsafeRawPointer(bitPattern: swiftState) else {
            preconditionFailure("RemoteImageBufferSet has no Swift state")
        }
        return unsafe address
    }

    @cxx
    @implementation
    static func createSwiftState(
        _ contextIdentifier: WebKit.RemoteGraphicsContextIdentifier,
        _ backend: WebKit.RemoteRenderingBackend
    ) -> UInt {
        let state = RemoteImageBufferSetState(contextIdentifier: contextIdentifier, backend: backend)
        // Safety: the state is new, and retained once, which only destroySwiftState() releases.
        return UInt(bitPattern: unsafe Unmanaged.passRetained(state).toOpaque())
    }

    // Static, so that the destructor never retains the set it destroys.
    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        // Safety: createSwiftState() retained the state at this address, and only the destructor releases it.
        _ = unsafe Unmanaged<RemoteImageBufferSetState>.fromOpaque(address(swiftState)).takeRetainedValue()
    }

    @cxx
    @implementation
    func isPreparingForDisplay() -> Bool {
        state.context != nil
    }

    @cxx
    @implementation
    func updateConfiguration(_ configuration: WebKit.RemoteImageBufferSetConfiguration) {
        let state = self.state
        state.configuration = configuration
        state.frontBuffer = nil
        state.backBuffer = nil
        state.secondaryBackBuffer = nil
    }

    @cxx
    @implementation
    func submitDrawingCommands() {
        state.frontBuffer?.submitDrawingCommands()
    }

    @cxx
    @implementation
    func swiftEndPrepareForDisplay() -> WebKit.RemoteImageBufferSetBuffers {
        let state = self.state
        state.context?.stopListeningForIPC()
        state.context = nil
        state.frontBuffer?.flushDrawingContext()
        return WebKit.RemoteImageBufferSetBuffers.make(
            WebKit.RefPtrImageBuffer(state.frontBuffer),
            WebKit.RefPtrImageBuffer(state.backBuffer),
            WebKit.RefPtrImageBuffer(state.secondaryBackBuffer)
        )
    }

    // This is the GPU Process version of RemoteLayerBackingStore::prepareBuffers(). Unsafe, as C++ passes the input by
    // reference: it is the caller's, which outlives the call, and only this reads and writes it during the call.
    @cxx
    @implementation
    @unsafe
    func ensureBufferForDisplay(
        _ inputData: inout WebKit.ImageBufferSetPrepareBufferForDisplayInputData,
        _ isSync: Bool
    ) -> WebKit.SwapBuffersDisplayRequirement {
        let state = self.state
        let displayRequirement = state.swapBuffersForDisplay(
            hasEmptyDirtyRegion: inputData.hasEmptyDirtyRegion,
            supportsPartialRepaint: inputData.supportsPartialRepaint && !WebKit.isSmallLayerBacking(state.configuration.imageBufferParameters())
        )
        if displayRequirement == .NeedsFullDisplay {
            let layerBounds = WebCore.Region(WebCore.IntRect(WebCore.IntPoint(), WebCore.expandedIntSize(state.configuration.logicalSize)))
            do throws(InvalidMessage) {
                try messageCheck("Can't asynchronously require full display for a buffer set") {
                    isSync || inputData.dirtyRegion.contains(layerBounds)
                }
            } catch {
                markMessageInvalid(error, on: state.backend.streamConnection())
                return displayRequirement
            }
            inputData.dirtyRegion = layerBounds
        }

        if state.frontBuffer == nil {
            state.frontBuffer = state.backend.allocateImageBuffer(
                state.configuration.logicalSize,
                state.configuration.renderingMode,
                state.configuration.renderingPurpose,
                state.configuration.resolutionScale,
                state.configuration.colorSpace,
                state.configuration.bufferFormat
            ).get()
            if state.frontBuffer == nil {
                state.logFailedAllocation(identifier: identifier().toUInt64())
            }
            state.frontBufferIsCleared = true
        }

        if displayRequirement != .NeedsNoDisplay {
            guard let imageBuffer = state.frontBuffer ?? WebCore.createNullImageBuffer().get() else {
                preconditionFailure("No empty image buffer")
            }
            // The previous receiver stops before the new one, which takes its identifier, starts.
            state.context?.stopListeningForIPC()
            state.context = WebKit.RemoteImageBufferGraphicsContext.createForSwift(imageBuffer, state.contextIdentifier, state.backend)
        }
        return displayRequirement
    }

    @cxx
    @implementation
    func prepareBufferForDisplay(_ dirtyRegion: WebCore.Region, _ requiresClearedPixels: Bool) {
        let state = self.state
        guard let frontBuffer = state.frontBuffer else {
            state.previouslyPaintedRect = nil
            return
        }

        let paintingRects = WebKit.PaintingRects(dirtyRegion, state.configuration.resolutionScale)
        let rects: Span<WebCore.FloatRect> = paintingRects.span()
        let layerBounds = WebCore.FloatRect(WebCore.FloatPoint(), state.configuration.logicalSize)

        let drawing = WebCore.ImageBufferDrawing(frontBuffer)
        let context = drawing.context()
        context.resetClip()

        var copyRect = WebCore.FloatRect()
        if let backBuffer = state.backBuffer {
            let enclosingCopyRect = state.previouslyPaintedRect ?? WebCore.enclosingIntRect(layerBounds)
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
                state.frontBufferIsCleared = false
            }
        } else {
            // If the copy-forward touched pixels that are about to be painted, then they won't be 'clear' any more.
            for index in rects.indices where copyRect.intersects(rects[index]) {
                state.frontBufferIsCleared = false
            }
            context.clipToRects(rects)
        }

        if requiresClearedPixels && !state.frontBufferIsCleared {
            context.clearRect(layerBounds)
        }

        state.previouslyPaintedRect = dirtyRegion.bounds()
        state.frontBufferIsCleared = false
    }

    @cxx
    @implementation
    func swiftMakeBuffersVolatile(_ requestedBuffers: UInt8, _ forcePurge: Bool) -> UInt16 {
        let state = self.state
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
        makeBufferTypeVolatile(.Front, state.frontBuffer)
        makeBufferTypeVolatile(.Back, state.backBuffer)
        makeBufferTypeVolatile(.SecondaryBack, state.secondaryBackBuffer)
        return UInt16(volatileBuffers) | (allSucceeded ? 0 : someBuffersStayedNonVolatile)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT && !ENABLE_RE_DYNAMIC_CONTENT_SCALING
