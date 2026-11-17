// Copyright (C) 2024 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS

import Synchronization
import WebCore_Private
import WebKit_Internal

// Per GPU process limit of image buffers for canvas. These consume limited process-wide resources.
private let globalImageBufferForCanvasLimit: UInt = 200000

// Per Web Content process limit of accelerated image buffers for canvas. Prevents GPU resource exhaustion affecting other Web
// Content processes.
private let acceleratedImageBufferForCanvasLimit: UInt = 5000

// Per Web Content process limit of image buffers for canvas. Prevents IPC-related resource exhaustion affecting other Web Content
// processes.
private let imageBufferForCanvasLimit: UInt = 50000

private let globalAcceleratedImageBufferCount = Atomic<UInt>(0)
private let globalImageBufferForCanvasCount = Atomic<UInt>(0)

// A RemoteSharedResourceCache's counts of the image buffers of its web process, for any thread.
final class RemoteSharedResourceCacheState: Sendable {
    let acceleratedImageBufferForCanvasCount = Atomic<UInt>(0)
    let imageBufferForCanvasCount = Atomic<UInt>(0)
}

extension WebKit.RemoteSharedResourceCache {
    @cxx
    @implementation
    static func createSwiftState() -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(RemoteSharedResourceCacheState()).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        _ = unsafe Unmanaged<RemoteSharedResourceCacheState>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The shared resource cache has no Swift state")
        }
        return unsafe address
    }

    private var state: RemoteSharedResourceCacheState {
        // Safety: m_swiftState is a retained RemoteSharedResourceCacheState from the constructor to the destructor, and
        // nothing changes it.
        unsafe Unmanaged<RemoteSharedResourceCacheState>.fromOpaque(Self.stateAddress(m_swiftState)).takeUnretainedValue()
    }

    @cxx
    @implementation
    func didCreateImageBuffer(_ purpose: WebCore.RenderingPurpose, _ renderingMode: WebCore.RenderingMode) {
        let state = self.state
        if purpose == .Canvas {
            if renderingMode == .Accelerated {
                state.acceleratedImageBufferForCanvasCount.wrappingAdd(1, ordering: .sequentiallyConsistent)
            }
            globalImageBufferForCanvasCount.wrappingAdd(1, ordering: .sequentiallyConsistent)
            state.imageBufferForCanvasCount.wrappingAdd(1, ordering: .sequentiallyConsistent)
        }
        if renderingMode == .Accelerated {
            globalAcceleratedImageBufferCount.wrappingAdd(1, ordering: .sequentiallyConsistent)
        }
    }

    @cxx
    @implementation
    func didReleaseImageBuffer(_ purpose: WebCore.RenderingPurpose, _ renderingMode: WebCore.RenderingMode) {
        let state = self.state
        if purpose == .Canvas {
            if renderingMode == .Accelerated {
                state.acceleratedImageBufferForCanvasCount.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            }
            globalImageBufferForCanvasCount.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            state.imageBufferForCanvasCount.wrappingSubtract(1, ordering: .sequentiallyConsistent)
        }
        if renderingMode == .Accelerated {
            globalAcceleratedImageBufferCount.wrappingSubtract(1, ordering: .sequentiallyConsistent)
        }
    }

    @cxx
    @implementation
    func reachedAcceleratedImageBufferLimit(_ purpose: WebCore.RenderingPurpose, _ globalAcceleratedImageBufferLimit: Int) -> Bool {
        let reachedForCanvas = purpose == .Canvas
            && state.acceleratedImageBufferForCanvasCount.load(ordering: .sequentiallyConsistent) >= acceleratedImageBufferForCanvasLimit
        return reachedForCanvas
            || globalAcceleratedImageBufferCount.load(ordering: .sequentiallyConsistent) >= UInt(bitPattern: globalAcceleratedImageBufferLimit)
    }

    @cxx
    @implementation
    func reachedImageBufferForCanvasLimit() -> Bool {
        state.imageBufferForCanvasCount.load(ordering: .sequentiallyConsistent) >= imageBufferForCanvasLimit
            || globalImageBufferForCanvasCount.load(ordering: .sequentiallyConsistent) >= globalImageBufferForCanvasLimit
    }

    @cxx
    @implementation
    func getResourceLimitsForTesting(_ globalAcceleratedImageBufferLimit: Int) -> WebCore.ImageBufferResourceLimits {
        let state = self.state
        var limits = WebCore.ImageBufferResourceLimits()
        limits.acceleratedImageBufferForCanvasCount = UInt64(state.acceleratedImageBufferForCanvasCount.load(ordering: .sequentiallyConsistent))
        limits.acceleratedImageBufferForCanvasLimit = UInt64(acceleratedImageBufferForCanvasLimit)
        limits.globalAcceleratedImageBufferCount = UInt64(globalAcceleratedImageBufferCount.load(ordering: .sequentiallyConsistent))
        limits.globalAcceleratedImageBufferLimit = UInt64(UInt(bitPattern: globalAcceleratedImageBufferLimit))
        limits.globalImageBufferForCanvasCount = UInt64(globalImageBufferForCanvasCount.load(ordering: .sequentiallyConsistent))
        limits.globalImageBufferForCanvasLimit = UInt64(globalImageBufferForCanvasLimit)
        limits.imageBufferForCanvasCount = UInt64(state.imageBufferForCanvasCount.load(ordering: .sequentiallyConsistent))
        limits.imageBufferForCanvasLimit = UInt64(imageBufferForCanvasLimit)
        return limits
    }
}

#endif // ENABLE_GPU_PROCESS
