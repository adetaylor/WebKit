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

#include <WebCore/IDBConnectionToClientDelegate.h>
#include <WebCore/IDBDatabaseInfo.h>
#include <WebCore/IDBDatabaseNameAndVersion.h>
#include <WebCore/IDBError.h>
#include <WebCore/IDBGetAllResult.h>
#include <WebCore/IDBGetResult.h>
#include <WebCore/IDBIndexInfo.h>
#include <WebCore/IDBKeyData.h>
#include <WebCore/IDBKeyPath.h>
#include <WebCore/IDBKeyRangeData.h>
#include <WebCore/IDBResourceIdentifier.h>
#include <WebCore/IDBResultData.h>
#include <WebCore/IDBValue.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/SQLiteDatabase.h>
#include <WebCore/ThreadSafeDataBuffer.h>
#include <algorithm>
#include <atomic>
#include <bit>
#include <wtf/FileSystem.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Seconds.h>
#include <wtf/Threading.h>

// What the backing store tests and benchmarks share: a connection delegate that ignores every call, number keys, and
// a way to run a store off the main thread.

namespace TestWebKitAPI {

class NullDelegate final : public WebCore::IDBServer::IDBConnectionToClientDelegate {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(NullDelegate);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(NullDelegate);

public:
    std::optional<WebCore::IDBConnectionIdentifier> identifier() const final { return m_identifier; }
    void didDeleteDatabase(const WebCore::IDBResultData&) final { }
    void didOpenDatabase(const WebCore::IDBResultData&) final { }
    void didAbortTransaction(const WebCore::IDBResourceIdentifier&, const WebCore::IDBError&) final { }
    void didCommitTransaction(const WebCore::IDBResourceIdentifier&, const WebCore::IDBError&) final { }
    void didCreateObjectStore(const WebCore::IDBResultData&) final { }
    void didDeleteObjectStore(const WebCore::IDBResultData&) final { }
    void didRenameObjectStore(const WebCore::IDBResultData&) final { }
    void didClearObjectStore(const WebCore::IDBResultData&) final { }
    void didCreateIndex(const WebCore::IDBResultData&) final { }
    void didDeleteIndex(const WebCore::IDBResultData&) final { }
    void didRenameIndex(const WebCore::IDBResultData&) final { }
    void didPutOrAdd(const WebCore::IDBResultData&) final { }
    void didGetRecord(const WebCore::IDBResultData&) final { }
    void didGetAllRecords(const WebCore::IDBResultData&) final { }
    void didGetCount(const WebCore::IDBResultData&) final { }
    void didDeleteRecord(const WebCore::IDBResultData&) final { }
    void didOpenCursor(const WebCore::IDBResultData&) final { }
    void didIterateCursor(const WebCore::IDBResultData&) final { }
    void fireVersionChangeEvent(WebCore::IDBDatabaseConnectionIdentifier, const WebCore::IDBResourceIdentifier&, uint64_t) final { }
    void generateIndexKeyForRecord(const WebCore::IDBResourceIdentifier&, const WebCore::IDBIndexInfo&, const std::optional<WebCore::IDBKeyPath>&, const WebCore::IDBKeyData&, const WebCore::IDBValue&, std::optional<int64_t>) final { }
    void didStartTransaction(const WebCore::IDBResourceIdentifier&, const WebCore::IDBError&) final { }
    void didCloseFromServer(WebCore::IDBDatabaseConnectionIdentifier, const WebCore::IDBError&) final { }
    void notifyOpenDBRequestBlocked(const WebCore::IDBResourceIdentifier&, uint64_t, uint64_t) final { }
    void didGetAllDatabaseNamesAndVersions(const WebCore::IDBResourceIdentifier&, Vector<WebCore::IDBDatabaseNameAndVersion>&&) final { }

private:
    // Process::generateIdentifier() asserts it runs on the UI thread in Debug; the store thread has its own counter.
    static WebCore::IDBConnectionIdentifier nextIdentifier()
    {
        static std::atomic<uint64_t> next { 1 };
        return WebCore::IDBConnectionIdentifier(next.fetch_add(1));
    }
    WebCore::IDBConnectionIdentifier m_identifier { nextIdentifier() };
};

inline WebCore::IDBKeyData numberKey(double number)
{
    return WebCore::IDBKeyData { WebCore::IDBKeyData::ValueVariant { number } };
}

// Stores run off the main thread: IDBBackingStore's constructor and destructor RELEASE_ASSERT(!isMainThread()).
template<typename Function>
void runOffMainThread(Function&& function)
{
    // SQLite's one-time initialization runs on the main thread and the main thread waits for it (callOnMainThreadAndWait),
    // which a store thread opening the first database would deadlock against while this thread waits for it. Do it
    // here, on the main thread.
    static bool sqliteInitialized = [] {
        // On the heap: a CheckedPtr-capable object destroyed on the stack asserts in Debug (m_didBeginDeletion).
        auto database = makeUnique<WebCore::SQLiteDatabase>();
        database->open(":memory:"_s);
        return true;
    }();
    UNUSED_VARIABLE(sqliteInitialized);
    Thread::create("IDBBackingStore"_s, [&function] {
        function();
    })->waitForCompletion();
}

// What the two benchmarks share: inputs, the digest of their results, the time excluded from a pass, a temporary
// directory and an index's shape.
namespace IDBBenchmarkSupport {

class Random {
public:
    explicit Random(uint64_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned bound)
    {
        m_state = m_state * 6364136223846793005ULL + 1442695040888963407ULL;
        return static_cast<unsigned>(m_state >> 33) % bound;
    }

private:
    uint64_t m_state;
};

class Digest {
public:
    void addByte(uint8_t byte)
    {
        m_value ^= byte;
        m_value *= 0x100000001b3ULL;
    }

    void addInteger(uint64_t value)
    {
        for (unsigned i = 0; i < 8; ++i)
            addByte(static_cast<uint8_t>(value >> (i * 8)));
    }

    void addBytes(std::span<const uint8_t> bytes)
    {
        addInteger(bytes.size());
        for (auto byte : bytes)
            addByte(byte);
    }

    // Code units, so an 8-bit and a 16-bit string with the same code units agree.
    void addString(const String& string)
    {
        addInteger(string.length());
        for (unsigned i = 0; i < string.length(); ++i)
            addInteger(string[i]);
    }

    void addError(const WebCore::IDBError& error)
    {
        addInteger(error.code() ? static_cast<uint64_t>(*error.code()) + 1 : 0);
        addString(error.messageForSerialization());
    }

    void addKey(const WebCore::IDBKeyData& key)
    {
        auto type = key.type();
        addInteger(static_cast<uint64_t>(static_cast<int64_t>(type)));
        switch (type) {
        case WebCore::IndexedDB::KeyType::Array:
            addInteger(key.array().size());
            for (auto& element : key.array())
                addKey(element);
            break;
        case WebCore::IndexedDB::KeyType::Binary:
            if (auto* data = key.binary().data())
                addBytes(data->span());
            else
                addInteger(0);
            break;
        case WebCore::IndexedDB::KeyType::String:
            addString(key.string());
            break;
        case WebCore::IndexedDB::KeyType::Date:
            addInteger(std::bit_cast<uint64_t>(key.date()));
            break;
        case WebCore::IndexedDB::KeyType::Number:
            addInteger(std::bit_cast<uint64_t>(key.number()));
            break;
        case WebCore::IndexedDB::KeyType::Max:
        case WebCore::IndexedDB::KeyType::Invalid:
        case WebCore::IndexedDB::KeyType::Min:
            break;
        }
    }

    void addValue(const WebCore::IDBValue& value)
    {
        if (auto* data = value.data().data())
            addBytes(data->span());
        else
            addInteger(0);
        addInteger(value.blobURLs().size());
    }

    void addRecord(const WebCore::IDBKeyData& key, const WebCore::IDBKeyData& primaryKey, const WebCore::IDBValue& value)
    {
        addKey(key);
        addKey(primaryKey);
        addValue(value);
    }

    void addGetResult(const WebCore::IDBGetResult& result)
    {
        addInteger(result.isDefined());
        addRecord(result.keyData(), result.primaryKeyData(), result.value());
        addInteger(result.prefetchedRecords().size());
        for (auto& record : result.prefetchedRecords())
            addRecord(record.key, record.primaryKey, record.value);
    }

    void addGetAllResult(const WebCore::IDBGetAllResult& result)
    {
        addInteger(static_cast<uint64_t>(result.type()));
        addInteger(result.keys().size());
        for (auto& key : result.keys())
            addKey(key);
        addInteger(result.primaryKeys().size());
        for (auto& key : result.primaryKeys())
            addKey(key);
        addInteger(result.values().size());
        for (auto& value : result.values())
            addValue(value);
    }

    // The names and shape of a database, in a fixed order (the identifiers differ from one run to the next).
    void addDatabaseInfo(const WebCore::IDBDatabaseInfo& info)
    {
        addString(info.name());
        addInteger(info.version());
        auto names = info.objectStoreNames();
        std::sort(names.begin(), names.end(), [](const String& a, const String& b) {
            return codePointCompareLessThan(a, b);
        });
        addInteger(names.size());
        for (auto& name : names) {
            addString(name);
            auto* objectStoreInfo = const_cast<WebCore::IDBDatabaseInfo&>(info).infoForExistingObjectStore(name); // the const overload is not exported
            if (!objectStoreInfo)
                continue;
            addInteger(objectStoreInfo->autoIncrement());
            auto indexNames = objectStoreInfo->indexNames();
            std::sort(indexNames.begin(), indexNames.end(), [](const String& a, const String& b) {
                return codePointCompareLessThan(a, b);
            });
            addInteger(indexNames.size());
            for (auto& indexName : indexNames)
                addString(indexName);
        }
    }

    uint64_t value() const { return m_value; }

private:
    uint64_t m_value { 0xcbf29ce484222325ULL };
};

inline WebCore::IDBKeyData stringKey(const String& string)
{
    return WebCore::IDBKeyData { WebCore::IDBKeyData::ValueVariant { string } };
}

inline WebCore::IDBKeyRangeData rangeOf(const WebCore::IDBKeyData& lower, const WebCore::IDBKeyData& upper, bool lowerOpen = false, bool upperOpen = false)
{
    return WebCore::IDBKeyRangeData { WebCore::IDBKeyData(lower), WebCore::IDBKeyData(upper), lowerOpen, upperOpen };
}

inline WebCore::IDBKeyRangeData exactly(const WebCore::IDBKeyData& key)
{
    return rangeOf(key, key);
}

// WebCore::IDBValue::size() is not exported.
inline size_t valueSize(const WebCore::IDBValue& value)
{
    auto* data = value.data().data();
    return data ? data->size() : 0;
}

inline WebCore::IDBValue makeValue(uint64_t seed, size_t size)
{
    Vector<uint8_t> bytes;
    bytes.reserveInitialCapacity(size);
    for (size_t j = 0; j < size; ++j)
        bytes.append(static_cast<uint8_t>(seed * 31 + j * 7 + (j >> 3)));
    return WebCore::IDBValue { WebCore::ThreadSafeDataBuffer::create(WTF::move(bytes)) };
}

// Time a pass spends outside what it measures.
class Excluded {
public:
    template<typename Function>
    void measure(Function&& function)
    {
        auto start = MonotonicTime::now();
        function();
        m_total += MonotonicTime::now() - start;
    }

    Seconds total() const { return m_total; }

private:
    Seconds m_total;
};

class TemporaryDirectory {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(TemporaryDirectory);

public:
    TemporaryDirectory()
    {
        String path = FileSystem::createTemporaryFile("IDBBenchmark"_s);
        FileSystem::deleteFile(path);
        FileSystem::makeAllDirectories(path);
        m_path = path;
    }

    ~TemporaryDirectory() { FileSystem::deleteNonEmptyDirectory(m_path); }

    const String& path() const { return m_path; }

private:
    String m_path;
};

struct IndexSpec {
    WebCore::IDBIndexIdentifier identifier;
    bool multiEntry { false };
};

} // namespace IDBBenchmarkSupport

} // namespace TestWebKitAPI
