// Copyright (C) 2024-2026 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT

@_spi(WebKitGPU) import WebGPUSwift
import WebKit_Internal

// The Swift state of a WebXR projection layer's receiver, which the C++ RemoteXRProjectionLayer holds retained, by
// address, from add() to its destructor: the layer, and the link to the registry that owns it.
final class RemoteXRProjectionLayerState {
    let layer: XRProjectionLayerReference
    let link: WebGPURegistryLink

    init(_ layer: XRProjectionLayerReference, _ link: WebGPURegistryLink) {
        self.layer = layer
        self.link = link
    }
}

// The messages of a WebXR projection layer, on its stream connection's work queue, that Swift handles: all but
// StartFrame, which C++ handles and passes on to startSwiftFrame().
extension WebKit.RemoteXRProjectionLayer {
    // Adds the layer, with the receiver of its messages, to the registry that the link names.
    static func add(_ layer: XRProjectionLayerReference, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let state = RemoteXRProjectionLayerState(layer, link)
        let address = UInt(bitPattern: unsafe Unmanaged.passRetained(state).toOpaque())
        let registration = WebKit.registerWebGPUSwiftReceiver(objects.host, .RemoteXRProjectionLayer, address, link.identifier)
        objects.add(link.identifier, layer, receiver: state, registration: registration)
    }

    @cxx @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        _ = unsafe Unmanaged<RemoteXRProjectionLayerState>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("A projection layer receiver without its state")
        }
        return unsafe address
    }

    private var state: RemoteXRProjectionLayerState {
        // Safety: m_swiftState is a retained RemoteXRProjectionLayerState until the destructor, and nothing changes it.
        unsafe Unmanaged<RemoteXRProjectionLayerState>.fromOpaque(Self.stateAddress(m_swiftState)).takeUnretainedValue()
    }

    func destruct() {
        state.link.remove()
    }

    #if ENABLE_WEBXR && WTF_PLATFORM_COCOA
    @cxx @implementation
    func startSwiftFrame(
        _ frameIndex: UInt64,
        _ colorBuffer: UInt32,
        _ depthBuffer: UInt32,
        _ completionSyncEvent: UInt32,
        _ textureIndex: UInt64,
        _ screenWidth: UInt32,
        _ screenHeight: UInt32,
        _ horizontalSamplesLeft: WebGPU.XRRasterizationSamples,
        _ horizontalSamplesRight: WebGPU.XRRasterizationSamples,
        _ verticalSamples: WebGPU.XRRasterizationSamples
    ) {
        state.layer.startFrame(
            frameIndex,
            colorBuffer: colorBuffer,
            depthBuffer: depthBuffer,
            completionSyncEvent: completionSyncEvent,
            reusableTextureIndex: textureIndex,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            horizontalSamplesLeft: horizontalSamplesLeft,
            horizontalSamplesRight: horizontalSamplesRight,
            verticalSamples: verticalSamples
        )
    }
    #endif

    func endFrame() {
    }

    func destroy() {
        state.layer.destroy()
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
