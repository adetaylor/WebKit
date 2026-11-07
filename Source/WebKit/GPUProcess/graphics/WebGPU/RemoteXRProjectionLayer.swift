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

// Receives the messages of a WebXR projection layer, on its stream connection's work queue, and calls its
// XRProjectionLayerReference.
@_expose(Cxx)
final class RemoteXRProjectionLayer {
    private let layer: XRProjectionLayerReference
    private let link: WebGPURegistryLink

    @_expose(!Cxx)
    private init(_ layer: XRProjectionLayerReference, _ link: WebGPURegistryLink) {
        self.layer = layer
        self.link = link
    }

    // Adds the layer, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ layer: XRProjectionLayerReference, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemoteXRProjectionLayer(layer, link)
        let registration = WebKit.registerWebGPUSwiftReceiver(objects.host, receiver.getMessageReceiver(), .RemoteXRProjectionLayer, link.identifier)
        objects.add(link.identifier, layer, receiver: receiver, registration: registration)
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteXRProjectionLayerMessageForwarder {
        WebKit.RemoteXRProjectionLayerMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
    }

    func destruct() {
        link.remove()
    }

    #if ENABLE_WEBXR && WTF_PLATFORM_COCOA
    // C++ decodes the compositor's buffers and the rasterization rate map, and the frame owns them while the layer
    // starts with them.
    func startFrame(
        frameIndex: UInt64,
        colorBuffer: CxxDecodedArguments.RemoteXRProjectionLayer.StartFrameColorBuffer,
        depthBuffer: CxxDecodedArguments.RemoteXRProjectionLayer.StartFrameDepthBuffer,
        completionSyncEvent: CxxDecodedArguments.RemoteXRProjectionLayer.StartFrameCompletionSyncEvent,
        textureIndex: UInt64,
        rateMapDescription: CxxDecodedArguments.RemoteXRProjectionLayer.StartFrameRateMapDescription
    ) {
        let frame = WebKit.WebGPUXRFrame(colorBuffer, depthBuffer, completionSyncEvent, rateMapDescription)
        layer.startFrame(
            frameIndex,
            colorBuffer: frame.colorBuffer(),
            depthBuffer: frame.depthBuffer(),
            completionSyncEvent: frame.completionSyncEvent(),
            reusableTextureIndex: textureIndex,
            screenWidth: frame.screenWidth(),
            screenHeight: frame.screenHeight(),
            horizontalSamplesLeft: frame.horizontalSamplesLeft(),
            horizontalSamplesRight: frame.horizontalSamplesRight(),
            verticalSamples: frame.verticalSamples()
        )
    }
    #endif

    func endFrame() {
    }

    func destroy() {
        layer.destroy()
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
