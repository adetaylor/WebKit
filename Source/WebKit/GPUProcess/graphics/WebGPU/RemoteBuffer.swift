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

// Receives the messages of a WebGPU buffer, on its stream connection's work queue, and calls its BufferImpl, keeping
// the state of the mapping that the web process asked for.
@_expose(Cxx)
final class RemoteBuffer {
    private let buffer: BufferReference
    // For the C++ that copies shared memory into the buffer.
    private let backing: WebKit.RemoteBufferBacking
    private let context: WebKit.WebGPUSwiftReceiverContext
    private var isMapped: Bool
    private var pendingMap = false
    private var mapModeFlags: IPCTypes.MapMode

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(backing: WebKit.RemoteBufferBacking, context: WebKit.WebGPUSwiftReceiverContext, mappedAtCreation: Bool) {
        self.buffer = WebGPUSwift.reference(of: backing.get())
        self.backing = backing
        self.context = context
        self.isMapped = mappedAtCreation
        self.mapModeFlags = mappedAtCreation ? .write : []
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @used
    func getMessageReceiver() -> RefRemoteBufferMessageForwarder {
        WebKit.RemoteBufferMessageForwarder.create(target: self)
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        context.sharedPreferencesForWebProcess()
    }

    func getMappedRange(offset: UInt64, size: UInt64?) throws(InvalidMessage) -> [UInt8]? {
        try messageCheck {
            isMapped
        }
        return buffer.getMappedRange(offset, size)
    }

    func mapAsync(
        mapModeFlags: IPCTypes.MapMode,
        offset: UInt64,
        size: UInt64?,
        reply: consuming RemoteBufferMapAsyncReply
    ) {
        if pendingMap {
            reply.send(false)
            return
        }
        pendingMap = true

        let pendingReply = CopyableBox(value: reply)
        buffer.mapAsync(mapModeFlags.rawValue, offset, size) { success in
            let mapWasPending = self.pendingMap
            self.pendingMap = false
            if success && mapWasPending {
                self.isMapped = true
                self.mapModeFlags = mapModeFlags
            }
            if let reply = pendingReply.take() {
                reply.send(success)
            }
        }
    }

    private var canWrite: Bool {
        !pendingMap && isMapped && mapModeFlags.contains(.write)
    }

    func copy(
        data: CxxDecodedArguments.RemoteBuffer.CopyData,
        offset: UInt64,
        reply: consuming RemoteBufferCopyReply
    ) {
        guard canWrite else {
            reply.send(false)
            return
        }
        reply.send(WebKit.copySharedMemoryToBuffer(backing.get(), data, offset))
    }

    func copyWithCopy(data: [UInt8], offset: UInt64) {
        guard canWrite else {
            return
        }
        _ = buffer.writeContents(data.span, at: offset)
    }

    func unmap() {
        if isMapped || pendingMap {
            buffer.unmap()
        }
        isMapped = false
        pendingMap = false
        mapModeFlags = []
    }

    func destroy() {
        unmap()
        buffer.destroy()
    }

    func generateAValidationError() {
        buffer.generateAValidationError()
    }

    func destruct() {
        context.removeFromObjectHeap()
    }

    func setLabel(label: String?) {
        buffer.setLabel(label)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
