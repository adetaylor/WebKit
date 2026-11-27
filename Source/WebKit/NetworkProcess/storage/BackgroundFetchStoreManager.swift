// Copyright (C) 2023 Apple Inc. All rights reserved.
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

import WebKit_Internal

extension WebKit.BackgroundFetchStoreManager {
    private static let fetchSuffix: [UInt16] = Array("-backgroundfetch".utf16)

    private static func shouldUseFileMapping(_ fileSize: UInt64) -> Bool {
        fileSize >= UInt64(WTF.pageSize())
    }

    private static func fileContents(
        _ filePath: WTF.String,
        _ fileSize: UInt64
    ) -> WebKit.SharedBufferRefPtr {
        WebCore.SharedBuffer.createWithContentsOfFile(
            filePath,
            .Private,
            shouldUseFileMapping(fileSize) ? .Yes : .No
        )
    }

    @cxx
    @implementation
    static func createNewStorageIdentifier() -> WTF.String {
        WTF.String(utf16Units: WTF.createVersion4UUIDString().utf16Units + fetchSuffix)
    }

    @cxx
    @implementation
    static func createFetchResponseBodyFile(_ identifier: WTF.String, _ index: Int) -> WTF.String {
        WTF.String(utf16Units: identifier.utf16Units + Array("-".utf16) + Array(Swift.String(UInt(bitPattern: index)).utf16))
    }

    @cxx
    @implementation
    static func removeFilesWithPrefix(_ directoryPath: WTF.String, _ identifier: WTF.String) {
        let prefix = identifier.utf16Units
        let fileNames = WTF.FileSystemImpl.listDirectory(directoryPath)
        for fileName in fileNames where fileName.hasPrefix(utf16Units: prefix) {
            _ = WTF.FileSystemImpl.deleteFile(WebKit.fileSystemPathByAppendingComponent(directoryPath, fileName))
        }
    }

    @cxx
    @implementation
    static func removeFetchAndResponseBodies(_ filePath: WTF.String) {
        _ = WTF.FileSystemImpl.deleteFile(filePath)
        var index = 0
        while WTF.FileSystemImpl.deleteFile(createFetchResponseBodyFile(filePath, index)) {
            index &+= 1
        }
    }

    @cxx
    @implementation
    static func readStoredFetches(_ directoryPath: WTF.String) -> WebKit.BackgroundFetchStoreManager.StoredFetches {
        var fetches = WebKit.BackgroundFetchStoreManager.StoredFetches()
        let fileNames = WTF.FileSystemImpl.listDirectory(directoryPath)
        for fileName in fileNames where fileName.hasSuffix(utf16Units: fetchSuffix) {
            let fetchPath = WebKit.fileSystemPathByAppendingComponent(directoryPath, fileName)
            guard let fileSize = WTF.FileSystemImpl.fileSize(fetchPath).value else {
                continue
            }
            fetches.append(consuming: .init(first: fileContents(fetchPath, fileSize), second: fileName))
        }
        return fetches
    }

    @cxx
    @implementation
    static func readResponseBody(_ filePath: WTF.String) -> WebKit.SharedBufferRefPtr {
        guard let fileSize = WTF.FileSystemImpl.fileSize(filePath).value else {
            return WebKit.SharedBufferRefPtr()
        }
        return fileContents(filePath, fileSize)
    }

    @cxx
    @implementation
    static func writeFetch(
        _ filePath: WTF.String,
        _ responseBodyIndexToClear: WebKit.OptionalSize,
        _ data: WebKit.UInt8Vector
    ) -> WebCore.BackgroundFetchStore.StoreResult {
        let size = UInt64(data.size())
        let writtenSize = WebKit.fileSystemOverwriteEntireFile(filePath, data)
        guard writtenSize.value == size else {
            return .InternalError
        }
        if let index = responseBodyIndexToClear.value {
            _ = WTF.FileSystemImpl.deleteFile(createFetchResponseBodyFile(filePath, Int(bitPattern: index)))
        }
        return .OK
    }

    @cxx
    @implementation
    static func writeResponseBodyChunk(
        _ filePath: WTF.String,
        _ borrowedData: borrowing WebCore.SharedBuffer
    ) -> WebCore.BackgroundFetchStore.StoreResult {
        let data = copy borrowedData
        var handle = WTF.FileSystemImpl.openFile(filePath, .ReadWrite)
        guard handle.isValid() else {
            return .InternalError
        }
        return WebKit.fileHandleWrite(&handle, data).value == UInt64(data.size()) ? .OK : .InternalError
    }
}
