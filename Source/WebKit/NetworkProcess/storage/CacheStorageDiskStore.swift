// Copyright (C) 2022 Apple Inc. All rights reserved.
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

extension WebKit.CacheStorageDiskStore {
    private static let versionDirectoryPrefix: [UInt16] = Array("Version ".utf16)

    @cxx
    @implementation
    static func deleteOldVersionDirectories(_ path: WTF.String) {
        let names = WTF.FileSystemImpl.listDirectory(path)
        for name in names {
            let units = name.utf16Units
            guard units.starts(with: versionDirectoryPrefix) else {
                continue
            }
            if let version: UInt32 = units[versionDirectoryPrefix.count...].parseUnsignedInteger(),
                version < WebKit.cacheStorageCurrentVersion
            {
                _ = WTF.FileSystemImpl.deleteNonEmptyDirectory(WebKit.fileSystemPathByAppendingComponent(path, name))
            }
        }
    }
}

// MARK: Reading a record file

// std::span::subspan's checks; a count of UInt64.max, its dynamic_extent, takes the rest.
@_lifetime(copy bytes)
private func subspan(_ bytes: Span<UInt8>, _ offset: UInt64, _ count: UInt64) -> Span<UInt8> {
    precondition(offset <= UInt64(bytes.count))
    let start = Int(offset)
    if count == UInt64.max {
        return bytes.extracting(start..<bytes.count)
    }
    // Neither wraps: offset is at most bytes.count, and count at most the bytes after offset.
    precondition(count <= UInt64(bytes.count) &- offset)
    return bytes.extracting(start..<(start &+ Int(count)))
}

private func readRecordMetaData(_ bytes: Span<UInt8>) -> WebKit.CacheStorageRecordMetaData? {
    guard !bytes.isEmpty, let metaData = WebKit.decodeCacheStorageRecordMetaData(bytes).value else {
        return nil
    }
    guard metaData.cacheStorageVersion == WebKit.cacheStorageCurrentVersion,
        !(metaData.timeStamp.secondsSinceEpoch().value() > WTF.WallTime.now().secondsSinceEpoch().value())
    else {
        return nil
    }
    return metaData
}

/// Decodes a record's information from its file's bytes.
///
/// `fileData` is the record file's bytes, which the caller's SafeFileData owns and keeps, unchanged and at its
/// length, until this returns. Nothing this calls writes them. Any byte is a valid UInt8.
///
/// FIXME: Take a Span once a std::span can cross safely (rdar://186723514).
@_expose(Cxx)
func cacheStorageReadRecordInformation(
    _ salt: WTF.FileSystemImpl.Salt,
    _ fileData: WTF.SpanUInt8
) -> WebKit.OptionalCacheStorageStoredRecordInformation {
    let bytes = unsafe Span<UInt8>(_unsafeCxxSpan: fileData)
    guard let metaData = readRecordMetaData(bytes) else {
        return WebKit.OptionalCacheStorageStoredRecordInformation()
    }
    let headerData = subspan(bytes, metaData.headerOffset, metaData.headerSize)
    return WebKit.decodeCacheStorageStoredRecordInformation(consuming: metaData, headerData, salt)
}

/// Decodes a record from its file's bytes.
///
/// `fileData` is the record file's bytes, which the caller's SafeFileData owns and keeps, unchanged and at its
/// length, until this returns. Nothing this calls writes them. Any byte is a valid UInt8.
///
/// FIXME: Take a Span once a std::span can cross safely (rdar://186723514).
@_expose(Cxx)
func cacheStorageReadRecord(
    _ salt: WTF.FileSystemImpl.Salt,
    _ fileData: WTF.SpanUInt8,
    _ blob: WebCore.SharedBuffer?
) -> WebKit.OptionalCacheStorageRecord {
    let bytes = unsafe Span<UInt8>(_unsafeCxxSpan: fileData)
    guard let metaData = readRecordMetaData(bytes) else {
        return WebKit.OptionalCacheStorageRecord()
    }
    let headerData = subspan(bytes, metaData.headerOffset, metaData.headerSize)
    let isBodyInline = metaData.isBodyInline
    let bodyOffset = metaData.headerOffset &+ metaData.headerSize
    let bodySize = metaData.bodySize
    let information = WebKit.decodeCacheStorageStoredRecordInformation(consuming: metaData, headerData, salt)
    let inlineBody: Span<UInt8>
    if isBodyInline {
        guard bodyOffset &+ bodySize == UInt64(bytes.count) else {
            return WebKit.OptionalCacheStorageRecord()
        }
        inlineBody = subspan(bytes, bodyOffset, bodySize)
    } else {
        inlineBody = bytes.extracting(0..<0)
    }
    return WebKit.makeCacheStorageRecord(consuming: information, inlineBody, blob, salt)
}
