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
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. AND ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_GPU_PROCESS_SWIFT

@_silgen_name("WebKitGPUServiceInitializerImpl")
private func webKitGPUServiceInitializerImpl(_ connection: OpaquePointer, _ initializerMessage: OpaquePointer?)

// SwiftGPUProcess is the Swift-side orchestrator for the GPU process. It owns
// the call hierarchy entered via the XPC GPUServiceInitializer symbol (see
// GPUServiceEntryPoint.swift). At present it wraps the existing C++
// XPCServiceInitializer<WebKit::GPUProcess, WebKit::GPUServiceInitializerDelegate>
// flow through a single C entry, WebKitGPUServiceInitializerImpl; subsequent
// phases will lift the individual initialization steps (delegate setup, JSC
// configuration, SDK-aligned behaviors, InitializeWebKit2, etc.) into Swift
// while leaving the existing C++ WebKit::GPUProcess singleton in place as the
// IPC message receiver.
public final class SwiftGPUProcess {
    public static let shared = SwiftGPUProcess()

    private init() {
    }

    public func initialize(connection: OpaquePointer, initializerMessage: OpaquePointer?) {
        webKitGPUServiceInitializerImpl(connection, initializerMessage)
    }
}

#endif // ENABLE_GPU_PROCESS_SWIFT
