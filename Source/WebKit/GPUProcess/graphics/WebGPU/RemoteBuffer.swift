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
    private let link: WebGPURegistryLink
    private var isMapped: Bool
    // The number of the map request in flight, if any; every request gets the next number, so a completion can tell
    // whether it is for the request still pending.
    private var pendingMapRequest: UInt64?
    private var lastMapRequest: UInt64 = 0
    private var mapModeFlags: IPCTypes.MapMode

    @_expose(!Cxx)
    private init(_ buffer: BufferReference, mappedAtCreation: Bool, _ link: WebGPURegistryLink) {
        self.buffer = buffer
        self.link = link
        self.isMapped = mappedAtCreation
        self.mapModeFlags = mappedAtCreation ? .write : []
    }

    // Adds the buffer, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ buffer: BufferReference, mappedAtCreation: Bool, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemoteBuffer(buffer, mappedAtCreation: mappedAtCreation, link)
        let registration = IPC.registerSwiftStreamReceiver(objects.host, receiver.getMessageReceiver(), .RemoteBuffer, link.identifier)
        objects.add(link.identifier, buffer, receiver: receiver, registration: registration)
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteBufferMessageForwarder {
        WebKit.RemoteBufferMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
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
        if pendingMapRequest != nil {
            reply.send(false)
            return
        }
        lastMapRequest &+= 1
        let request = lastMapRequest
        pendingMapRequest = request

        let pendingReply = CopyableBox(value: reply)
        buffer.mapAsync(mapModeFlags.rawValue, offset, size) { success in
            // An unmap() since, or a later request after one, wins.
            if self.pendingMapRequest == request {
                self.pendingMapRequest = nil
                if success {
                    self.isMapped = true
                    self.mapModeFlags = mapModeFlags
                }
            }
            if let reply = pendingReply.take() {
                reply.send(success)
            }
        }
    }

    private var canWrite: Bool {
        pendingMapRequest == nil && isMapped && mapModeFlags.contains(.write)
    }

    func copy(
        data: consuming IPCTypes.SharedMemoryHandle?,
        offset: UInt64,
        reply: consuming RemoteBufferCopyReply
    ) {
        guard canWrite, let bytes = mapWebGPUWriteSharedMemory(data) else {
            reply.send(false)
            return
        }
        let written = bytes.withBytes { buffer.writeContents(Span<UInt8>(viewing: $0), at: offset) }
        reply.send(written)
    }

    func copyWithCopy(data: [UInt8], offset: UInt64) {
        guard canWrite else {
            return
        }
        _ = buffer.writeContents(data.span, at: offset)
    }

    func unmap() {
        if isMapped || pendingMapRequest != nil {
            buffer.unmap()
        }
        isMapped = false
        pendingMapRequest = nil
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
        link.remove()
    }

    func setLabel(label: String?) {
        buffer.setLabel(label)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
