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

#if ENABLE_GPU_PROCESS && HAVE_AVASSETREADER

@_spi(WebKitGPU) internal import WebCore
import WebKit_Internal
import wtf

// Receives the messages of one web process's connection to the GPU process for the web process's AVFoundation image
// decoders, which the connection's Swift state owns (GPUConnectionState), and owns the decoders.
@_expose(Cxx)
final class RemoteImageDecoderAVFProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteImageDecoderAVFProxyMessageForwarder?
    // The connection, until it closes: the connection's Swift state, which the connection holds, holds this.
    @_expose(!Cxx)
    private(set) var connection: WebKit.GPUConnectionToWebProcess?
    private var decoders: [UInt64: WebCore.ImageDecoderAVFObjC] = [:]

    @_expose(!Cxx)
    init(connection: WebKit.GPUConnectionToWebProcess) {
        self.connection = connection
        self.messageForwarder = WebKit.RemoteImageDecoderAVFProxyMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteImageDecoderAVFProxyMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        // The connection dispatches the receiver's messages on the main thread, which alone changes `connection`.
        MainActor.preconditionIsolated()
        guard let connection else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }
        return connection.sharedPreferencesForWebProcess()
    }

    @MainActor
    private func encodedDataStatusChanged(_ identifier: UInt64) {
        guard let connection, let decoder = decoders[identifier], let decoderIdentifier = IPCTypes.ImageDecoderIdentifier(rawValue: identifier) else {
            return
        }
        let size = decoder.size()
        RemoteImageDecoderAVFProxy.RemoteImageDecoderAVFManagerMessages.encodedDataStatusChanged(
            on: connection.connection(),
            to: 0,
            identifier: decoderIdentifier,
            frameCount: UInt64(decoder.frameCount()),
            size: IPCTypes.IntSize(width: size.width(), height: size.height()),
            hasTrack: decoder.hasTrack()
        )
    }

    // MARK: Messages

    @MainActor
    func createDecoder(
        connection: IPC.Connection,
        data: CxxDecodedArguments.RemoteImageDecoderAVFProxy.CreateDecoderData,
        mimeType: String?
    ) throws(InvalidMessage) -> IPCTypes.ImageDecoderIdentifier? {
        let cxxMimeType = IPCCoding.WTFString.cxxString(mimeType)
        try messageCheck("createDecoder() should not be called with unsupported mime-type.") {
            WebCore.ImageDecoderAVFObjC.canDecodeType(cxxMimeType)
        }
        guard let gpuConnection = self.connection,
            let decoder = WebKit.createImageDecoderAVF(data, cxxMimeType, gpuConnection)
        else {
            return nil
        }
        let identifier = WTF.ObjectIdentifierMainThreadAccessTraits.generateIdentifierInternal()
        // ImageDecoderAVFObjC reports its status on the main thread.
        decoder.setEncodedDataStatusChangeCallback(
            consuming: WebKit.ImageDecoderAVFStatusCallback { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.encodedDataStatusChanged(identifier)
                }
            }
        )
        decoders[identifier] = decoder
        return IPCTypes.ImageDecoderIdentifier(rawValue: identifier)
    }

    @MainActor
    func deleteDecoder(connection: IPC.Connection, identifier: IPCTypes.ImageDecoderIdentifier) {
        assert(decoders[identifier.rawValue] != nil)
        guard decoders.removeValue(forKey: identifier.rawValue) != nil, let gpuConnection = self.connection else {
            return
        }
        if allowsExitUnderMemoryPressure {
            gpuConnection.tryExitIfUnusedAndUnderMemoryPressure()
        }
    }

    @MainActor
    func setExpectedContentSize(connection: IPC.Connection, identifier: IPCTypes.ImageDecoderIdentifier, expectedContentSize: Int64) {
        assert(decoders[identifier.rawValue] != nil)
        decoders[identifier.rawValue]?.setExpectedContentSize(expectedContentSize)
    }

    @MainActor
    func setData(
        connection: IPC.Connection,
        identifier: WebCore.ImageDecoderIdentifier,
        data: IPC.SharedBufferReference,
        allDataReceived: Bool
    ) -> (frameCount: UInt64, size: WebCore.IntSize, hasTrack: Bool, frameInfos: WebCore.OptionalVectorImageDecoderFrameInfo) {
        guard let decoder = decoders[identifier.toUInt64()] else {
            assertionFailure("No decoder for the identifier")
            return (0, WebCore.IntSize(), false, WebCore.OptionalVectorImageDecoderFrameInfo())
        }
        WebKit.setImageDecoderAVFData(decoder, data, allDataReceived)
        return (UInt64(decoder.frameCount()), decoder.size(), decoder.hasTrack(), WebKit.imageDecoderAVFFrameInfos(decoder))
    }

    @MainActor
    func createFrameImageAtIndex(
        connection: IPC.Connection,
        identifier: WebCore.ImageDecoderIdentifier,
        index: UInt64
    ) -> WebCore.OptionalShareableBitmapHandle {
        assert(decoders[identifier.toUInt64()] != nil)
        guard let decoder = decoders[identifier.toUInt64()] else {
            return WebCore.OptionalShareableBitmapHandle()
        }
        return WebKit.createImageDecoderAVFFrameBitmap(decoder, index)
    }

    @MainActor
    func clearFrameBufferCache(connection: IPC.Connection, identifier: IPCTypes.ImageDecoderIdentifier, index: UInt64) {
        assert(decoders[identifier.rawValue] != nil)
        guard let decoder = decoders[identifier.rawValue] else {
            return
        }
        // As C++'s std::min<uint64_t>(index, frameCount() - 1) did, with no frames too.
        decoder.clearFrameBufferCache(Int(truncatingIfNeeded: min(index, UInt64(decoder.frameCount()) &- 1)))
    }
}

extension RemoteImageDecoderAVFProxy: GPUConnectionReceiver {
    @_expose(!Cxx)
    @MainActor
    var allowsExitUnderMemoryPressure: Bool {
        decoders.isEmpty
    }

    @_expose(!Cxx)
    @MainActor
    func connectionDidClose() {
        decoders.removeAll()
        connection = nil
    }
}

#endif // ENABLE_GPU_PROCESS && HAVE_AVASSETREADER
