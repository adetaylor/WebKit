/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "CacheStorageCache.h"
#include "CacheStorageManager.h"
#include "CacheStorageRecord.h"
#include "FileSystemStorageError.h"
#include "FileSystemStorageHandle.h"
#include "FileSystemStorageManager.h"
#include "NetworkCacheKey.h"
#include "SwiftCoding.h"
#include <WebCore/CacheQueryOptions.h>
#include <WebCore/ClientOrigin.h>
#include <WebCore/DOMCacheEngine.h>
#include <WebCore/FetchHeadersGuard.h>
#include <WebCore/FetchOptions.h>
#include <WebCore/FileSystemHandleRecord.h>
#include <WebCore/FileSystemSyncAccessHandleIdentifier.h>
#include <WebCore/FileSystemWritableFileStreamIdentifier.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/FileHandle.h>
#include <wtf/FileSystem.h>
#include <wtf/SHA1.h>
#include <wtf/WallTime.h>

namespace WebKit {

// The instantiations the storage classes' Swift members return or take.
using OptionalClientOrigin = std::optional<WebCore::ClientOrigin>;
using FileSystemHandleRecordVector = Vector<WebCore::FileSystemHandleRecord>;
using OptionalFileSystemHandleRecordVector = std::optional<Vector<WebCore::FileSystemHandleRecord>>;
using FileSystemHandleGlobalIdentifierVector = Vector<WebCore::FileSystemHandleGlobalIdentifier>;
using OptionalFileSystemStorageError = std::optional<FileSystemStorageError>;
using OptionalUInt64 = std::optional<uint64_t>;
using OptionalSize = std::optional<size_t>;
using UInt8Vector = Vector<uint8_t>;
using SharedBufferRefPtr = RefPtr<WebCore::SharedBuffer>;
using WeakPtrCacheStorageCache = WeakPtr<CacheStorageCache>;
using WeakPtrCacheStorageManager = WeakPtr<CacheStorageManager>;
using WeakPtrFileSystemStorageHandle = WeakPtr<FileSystemStorageHandle>;

// Reading a std::optional or a CrossThreadRecord in Swift copies it, so the Cache Storage handlers take their request and records, and check the records' sizes, here.
WebCore::ResourceRequest cacheStorageTakeRequest(IPC::CxxDecodedArgument<WebCore::ResourceRequest>&);
CacheStorageRecordVector cacheStorageTakeRecords(IPC::CxxDecodedArgument<Vector<WebCore::DOMCacheEngine::CrossThreadRecord>>&, CacheStorageCache&, bool& sizesAreValid);

struct CacheStorageRecordMetaData {
    unsigned cacheStorageVersion { 0 };
    NetworkCache::Key key;
    WallTime timeStamp;
    SHA1::Digest headerHash;
    uint64_t headerSize { 0 };
    SHA1::Digest bodyHash;
    uint64_t bodySize { 0 };
    bool isBodyInline { false };
    uint64_t headerOffset { 0 };
};

struct CacheStorageRecordHeader {
    double insertionTime { 0 };
    uint64_t size { 0 };
    WebCore::FetchHeaders::Guard requestHeadersGuard { WebCore::FetchHeaders::Guard::None };
    WebCore::ResourceRequest request;
    WebCore::FetchOptions options;
    String referrer;
    WebCore::FetchHeaders::Guard responseHeadersGuard { WebCore::FetchHeaders::Guard::None };
    WebCore::ResourceResponse::CrossThreadData responseData;
    uint64_t responseBodySize { 0 };
};

struct CacheStorageStoredRecordInformation {
    CacheStorageRecordInformation info;
    CacheStorageRecordMetaData metaData;
    CacheStorageRecordHeader header;
};

constexpr unsigned cacheStorageCurrentVersion = 19;

using OptionalCacheStorageRecordMetaData = std::optional<CacheStorageRecordMetaData>;
using OptionalCacheStorageStoredRecordInformation = std::optional<CacheStorageStoredRecordInformation>;
using OptionalCacheStorageRecord = std::optional<CacheStorageRecord>;

// Swift cannot call WTF::Persistence's templated coders.
OptionalCacheStorageRecordMetaData decodeCacheStorageRecordMetaData(std::span<const uint8_t> fileData NOESCAPE);
OptionalCacheStorageStoredRecordInformation decodeCacheStorageStoredRecordInformation(CacheStorageRecordMetaData&&, std::span<const uint8_t> headerData NOESCAPE, const FileSystem::Salt&);
// Swift does not import value() for a std::optional of a noncopyable type, so it cannot move the information out.
OptionalCacheStorageRecord makeCacheStorageRecord(OptionalCacheStorageStoredRecordInformation&&, std::span<const uint8_t> inlineBody NOESCAPE, WebCore::SharedBuffer* blob, const FileSystem::Salt&);


// FileSystem's functions that take a StringView, for Swift, which cannot make a StringView of a String safely.
inline String fileSystemPathByAppendingComponent(const String& path, const String& component)
{
    return FileSystem::pathByAppendingComponent(path, component);
}

inline String fileSystemCreateTemporaryFile(const String& prefix)
{
    return FileSystem::createTemporaryFile(prefix);
}

// Swift reaches the Vector's and SharedBuffer's bytes only through an unsafe std::span, and FileHandle::write does not import as a Span overload.
inline OptionalUInt64 fileSystemOverwriteEntireFile(const String& path, std::span<const uint8_t> data NOESCAPE)
{
    return FileSystem::overwriteEntireFile(path, data);
}

inline OptionalUInt64 fileSystemOverwriteEntireFile(const String& path, const Vector<uint8_t>& data)
{
    return FileSystem::overwriteEntireFile(path, data.span());
}

inline OptionalUInt64 fileHandleWrite(FileSystem::FileHandle& handle, std::span<const uint8_t> data NOESCAPE)
{
    return handle.write(data);
}

inline OptionalUInt64 fileHandleWrite(FileSystem::FileHandle& handle, const WebCore::SharedBuffer& data)
{
    return handle.write(data.span());
}

} // namespace WebKit
