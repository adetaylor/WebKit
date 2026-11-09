// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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

// Receives the messages of a WebGPU shader module, on its stream connection's work queue, and calls its
// ShaderModuleImpl.
@_expose(Cxx)
final class RemoteShaderModule {
    private let shaderModule: ShaderModuleReference
    private let link: WebGPURegistryLink

    @_expose(!Cxx)
    private init(_ shaderModule: ShaderModuleReference, _ link: WebGPURegistryLink) {
        self.shaderModule = shaderModule
        self.link = link
    }

    // Adds the shader module, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ shaderModule: ShaderModuleReference, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemoteShaderModule(shaderModule, link)
        let registration = IPC.registerSwiftStreamReceiver(
            objects.host,
            receiver.getMessageReceiver(),
            .RemoteShaderModule,
            link.identifier
        )
        objects.add(link.identifier, shaderModule, receiver: receiver, registration: registration)
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteShaderModuleMessageForwarder {
        WebKit.RemoteShaderModuleMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
    }

    func compilationInfo(reply: consuming RemoteShaderModuleCompilationInfoReply) {
        reply.send(shaderModule.compilationInfo().map { IPCTypes.CompilationMessage($0) })
    }

    // Nothing to label: the module has no Metal object of its own.
    func setLabel(label: String?) {
    }

    func destruct() {
        link.remove()
    }
}

extension IPCTypes.CompilationMessage {
    fileprivate init(_ message: GPUShaderCompilationMessage) {
        self.init(
            message: message.message,
            type: message.isError ? .error : .warning,
            lineNum: message.lineNumber,
            linePos: message.linePosition,
            offset: message.offset,
            length: message.length
        )
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
