// Copyright (C) 2021-2023 Apple Inc. All rights reserved.
// Copyright (C) 2021-2025 Apple Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
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
internal import WebGPU_Private
import WebKit_Internal

// RemoteGPU's WebGPU messages (RemoteGPU.h), on its work queue, and the registry of its WebGPU objects, which
// m_swiftState holds retained, by address, from swiftInitialize() to swiftUninitialize().
extension WebKit.RemoteGPU {
    @cxx @implementation
    func swiftInitialize(_ instanceDescriptor: WebKit.WebGPUSwiftInstanceDescriptor) {
        precondition(m_swiftState == 0)
        m_swiftState = UInt(bitPattern: unsafe Unmanaged.passRetained(WebGPUImplTable(host: self, instanceDescriptor: instanceDescriptor)).toOpaque())
    }

    // Destroys the devices that are still alive, so that their pending callbacks are called, empties the registry, and
    // releases it, and with it the registry's reference to this.
    @cxx @implementation
    func swiftUninitialize() {
        guard hasRegistry else {
            return
        }
        // Safety: swiftInitialize() retained the registry at this address, and only this releases it.
        let table = unsafe Unmanaged<WebGPUImplTable>.fromOpaque(UnsafeMutableRawPointer(bitPattern: m_swiftState)!).takeRetainedValue()
        m_swiftState = 0
        table.destroyDevices()
        table.removeAll()
    }

    private var hasRegistry: Bool {
        m_swiftState != 0
    }

    // Only reached by messages, which come between swiftInitialize() and swiftUninitialize().
    private var table: WebGPUImplTable {
        precondition(hasRegistry, "RemoteGPU has no registry")
        // Safety: m_swiftState is a retained WebGPUImplTable until swiftUninitialize(), which runs on this work queue.
        return unsafe Unmanaged<WebGPUImplTable>.fromOpaque(UnsafeMutableRawPointer(bitPattern: m_swiftState)!).takeUnretainedValue()
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpu-requestadapter: nil if there's no adapter.
    func requestAdapter(
        options: IPCTypes.RequestAdapterOptions,
        identifier: IPCTypes.WebGPUIdentifier
    ) -> IPCTypes.RemoteGPURequestAdapterResponse? {
        var adapterOptions = WebGPU.RequestAdapterOptions()
        #if arch(x86_64)
        adapterOptions.powerPreference = .init(.HighPerformance)
        #else
        if let powerPreference = options.powerPreference {
            adapterOptions.powerPreference = .init(powerPreference == .highPerformance ? .HighPerformance : .LowPower)
        }
        #endif
        adapterOptions.forceFallbackAdapter = options.forceFallbackAdapter
        adapterOptions.xrCompatible = options.xrCompatible
        return table.requestAdapter(adapterOptions, identifier.rawValue)
    }

    func createPresentationContext(
        descriptor: IPCTypes.PresentationContextDescriptor,
        identifier: IPCTypes.WebGPUIdentifier
    ) throws(InvalidMessage) {
        let table = self.table
        try messageCheck {
            table.addPresentationContext(identifier.rawValue, descriptor.compositorIntegration.rawValue)
        }
    }

    func createCompositorIntegration(identifier: IPCTypes.WebGPUIdentifier) {
        table.addCompositorIntegration(identifier.rawValue)
    }

    func isValid(identifier: IPCTypes.WebGPUIdentifier) -> (Bool, Bool) {
        let state = table.objectState(identifier.rawValue)
        return (state.valid, state.exists)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
