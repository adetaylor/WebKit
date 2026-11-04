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

import WebKit_Internal

// Receives the messages of a WebGPU bind group, on its stream connection's work queue, and calls the bind group
// through the ::WebGPU C++ API.
@_expose(Cxx)
final class RemoteBindGroup {
    private let backing: WebGPU.BindGroup
    private let context: WebKit.WebGPUSwiftReceiverContext

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(backing: WebKit.RemoteBindGroupBacking, context: WebKit.WebGPUSwiftReceiverContext) {
        self.backing = backing.get()
        self.context = context
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @used
    func getMessageReceiver() -> RefRemoteBindGroupMessageForwarder {
        WebKit.RemoteBindGroupMessageForwarder.create(target: self)
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        context.sharedPreferencesForWebProcess()
    }

    func destruct() {
        context.removeFromObjectHeap()
    }

    func setLabel(label: String?) {
        backing.setLabel(consuming: IPCCoding.WTFString.cxxString(label))
    }

    func updateExternalTextures(
        externalTextureIdentifier: IPCTypes.WebGPUIdentifier
    ) -> Bool {
        guard let externalTexture = context.externalTexture(externalTextureIdentifier.rawValue) else {
            return false
        }
        return backing.updateExternalTextures(externalTexture)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
