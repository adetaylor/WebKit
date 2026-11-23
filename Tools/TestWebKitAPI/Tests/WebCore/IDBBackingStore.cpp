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

#include "config.h"

#include "IDBBackingStoreTestSupport.h"
#include <WebCore/IDBBackingStore.h>
#include <WebCore/IDBBackingStoreFactories.h>
#include <WebCore/IDBConnectionToClient.h>
#include <WebCore/IDBConnectionToClientDelegate.h>
#include <WebCore/IDBCursorInfo.h>
#include <WebCore/IDBDatabaseIdentifier.h>
#include <WebCore/IDBDatabaseInfo.h>
#include <WebCore/IDBDatabaseNameAndVersion.h>
#include <WebCore/IDBError.h>
#include <WebCore/IDBGetAllRecordsData.h>
#include <WebCore/IDBGetAllResult.h>
#include <WebCore/IDBGetRecordData.h>
#include <WebCore/IDBGetResult.h>
#include <WebCore/IDBIndexInfo.h>
#include <WebCore/IDBIterateCursorData.h>
#include <WebCore/IDBKeyData.h>
#include <WebCore/IDBKeyPath.h>
#include <WebCore/IDBKeyRangeData.h>
#include <WebCore/IDBObjectStoreInfo.h>
#include <WebCore/IDBResourceIdentifier.h>
#include <WebCore/IDBResultData.h>
#include <WebCore/IDBTransactionDurability.h>
#include <WebCore/IDBTransactionInfo.h>
#include <WebCore/IDBTransactionMode.h>
#include <WebCore/IDBValue.h>
#include <WebCore/IndexKey.h>
#include <WebCore/IndexedDB.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/SQLiteDatabase.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/ThreadSafeDataBuffer.h>
#include <atomic>
#include <cmath>
#include <wtf/Threading.h>

namespace TestWebKitAPI {

using namespace WebCore;
using namespace WebCore::IDBServer;

namespace {

enum class StoreKind { SQLiteMemory, Memory };

IDBKeyRangeData numberRange(double lower, double upper)
{
    return IDBKeyRangeData { numberKey(lower), numberKey(upper), false, false };
}

// A store with the one object store "store", made and closed on the store thread (runOffMainThread).
class TestStore {
public:
    explicit TestStore(StoreKind kind)
        : m_connection(IDBConnectionToClient::create(*m_delegate))
    {
        IDBDatabaseIdentifier identifier { "IDBBackingStoreTest"_s, SecurityOriginData { "https"_s, "test.example"_s, std::nullopt }, SecurityOriginData { "https"_s, "test.example"_s, std::nullopt } };
        m_store = kind == StoreKind::Memory ? makeMemoryIDBBackingStore(identifier) : makeSQLiteMemoryIDBBackingStore(identifier);
        EXPECT_TRUE(m_store->getOrEstablishDatabaseInfo(m_info).isNull());

        auto versionChange = begin(IDBTransactionMode::Versionchange);
        m_objectStoreInfo = m_info.createNewObjectStore("store"_s, std::nullopt, false);
        EXPECT_TRUE(m_store->createObjectStore(versionChange, *m_objectStoreInfo).isNull());
        EXPECT_TRUE(m_store->commitTransaction(versionChange).isNull());
    }

    ~TestStore()
    {
        m_store->close();
        m_store = nullptr;
        m_connection->clearDelegate();
    }

    IDBBackingStore& store() { return *m_store; }
    IDBObjectStoreIdentifier objectStore() const { return m_objectStoreInfo->identifier(); }
    IDBConnectionToClient& connection() { return m_connection; }

    IDBResourceIdentifier begin(IDBTransactionMode mode)
    {
        IDBResourceIdentifier transaction { m_connection.get() };
        std::unique_ptr<IDBDatabaseInfo> original;
        uint64_t newVersion = 0;
        if (mode == IDBTransactionMode::Versionchange) {
            original = makeUnique<IDBDatabaseInfo>(m_info);
            newVersion = m_info.version() + 1;
            m_info.setVersion(newVersion);
        }
        Vector<String> objectStores;
        if (mode != IDBTransactionMode::Versionchange)
            objectStores.append("store"_s);
        IDBTransactionInfo transactionInfo { transaction, mode, IDBTransactionDurability::Default, newVersion, WTF::move(objectStores), WTF::move(original) };
        EXPECT_TRUE(m_store->beginTransaction(transactionInfo).isNull());
        return transaction;
    }

    void put(const IDBResourceIdentifier& transaction, double key, const IndexIDToIndexKeyMap& indexKeys = { })
    {
        EXPECT_TRUE(m_store->overwriteRecord(transaction, *m_objectStoreInfo, numberKey(key), indexKeys, IDBValue { ThreadSafeDataBuffer::create(Vector<uint8_t> { 1, 2, 3 }) }).isNull());
    }

    IDBIndexIdentifier addIndex(const IDBResourceIdentifier& transaction, const String& name)
    {
        auto indexInfo = m_objectStoreInfo->createNewIndex(m_info.generateNextIndexID(), name, IDBKeyPath { String { "key"_s } }, false, false);
        EXPECT_TRUE(m_store->addIndex(transaction, indexInfo).isNull());
        return indexInfo.identifier();
    }

private:
    std::unique_ptr<NullDelegate> m_delegate { makeUnique<NullDelegate>() };
    Ref<IDBConnectionToClient> m_connection;
    std::unique_ptr<IDBBackingStore> m_store;
    IDBDatabaseInfo m_info;
    std::optional<IDBObjectStoreInfo> m_objectStoreInfo;
};

// A record of key +0 is deleted by key -0 (equal keys), then the delete is aborted. Returns whether the record reads
// back as -0. The read goes through a range that is not one key: for exactly one key, getRecord answers with the key
// the range names.
bool keyAfterAbortedDeleteOfNegativeZeroIsNegative(StoreKind kind)
{
    bool negative = false;
    runOffMainThread([&] {
        TestStore test { kind };
        auto& store = test.store();

        auto put = test.begin(IDBTransactionMode::Readwrite);
        test.put(put, 0.0);
        EXPECT_TRUE(store.commitTransaction(put).isNull());

        auto remove = test.begin(IDBTransactionMode::Readwrite);
        EXPECT_TRUE(store.deleteRange(remove, test.objectStore(), numberRange(-0.0, -0.0)).isNull());
        EXPECT_TRUE(store.abortTransaction(remove).isNull());

        auto read = test.begin(IDBTransactionMode::Readonly);
        IDBGetResult result;
        EXPECT_TRUE(store.getRecord(read, test.objectStore(), numberRange(-1, 1), IDBGetRecordDataType::KeyAndValue, result).isNull());
        EXPECT_EQ(IndexedDB::KeyType::Number, result.keyData().type());
        negative = result.keyData().type() == IndexedDB::KeyType::Number && std::signbit(result.keyData().number());
        EXPECT_TRUE(store.commitTransaction(read).isNull());
    });
    return negative;
}

// In one version change, an index is renamed away from "a", an index is added under "a" and renamed away too, then the
// version change is aborted. Returns the first index's name after the abort and the count of records through it.
std::pair<String, uint64_t> indexAfterAbortedRenameOverAddedIndex(StoreKind kind)
{
    std::pair<String, uint64_t> result;
    runOffMainThread([&] {
        TestStore test { kind };
        auto& store = test.store();

        auto create = test.begin(IDBTransactionMode::Versionchange);
        auto index = test.addIndex(create, "a"_s);
        EXPECT_TRUE(store.commitTransaction(create).isNull());

        auto put = test.begin(IDBTransactionMode::Readwrite);
        for (unsigned i = 0; i < 3; ++i) {
            IndexIDToIndexKeyMap indexKeys;
            indexKeys.add(index, IndexKey { IndexKey::Data { numberKey(10 + i) } });
            test.put(put, i, indexKeys);
        }
        EXPECT_TRUE(store.commitTransaction(put).isNull());

        auto renames = test.begin(IDBTransactionMode::Versionchange);
        EXPECT_TRUE(store.renameIndex(renames, test.objectStore(), index, "t"_s).isNull());
        auto addedIndex = test.addIndex(renames, "a"_s);
        EXPECT_TRUE(store.renameIndex(renames, test.objectStore(), addedIndex, "z"_s).isNull());
        EXPECT_TRUE(store.abortTransaction(renames).isNull());

        auto& indexes = store.infoForObjectStore(test.objectStore())->indexMap();
        if (auto indexInfo = indexes.find(index); indexInfo != indexes.end())
            result.first = indexInfo->value.name();
        auto read = test.begin(IDBTransactionMode::Readonly);
        EXPECT_TRUE(store.getCount(read, test.objectStore(), index, IDBKeyRangeData::allKeys(), result.second).isNull());
        EXPECT_TRUE(store.commitTransaction(read).isNull());
    });
    return result;
}

// Puts and deletes in random order with no ordered read between them, short of and past the point where the in-memory
// store stops keeping its record keys sorted, and a long run of them under an open cursor, which keeps them sorted.
// Returns the keys every read gives, in the order given.
Vector<double> keysReadAroundRandomOrderWrites(StoreKind kind)
{
    Vector<double> keys;
    runOffMainThread([&] {
        TestStore test { kind };
        auto& store = test.store();
        auto readAll = [&](const IDBResourceIdentifier& transaction) {
            IDBGetAllResult result;
            IDBGetAllRecordsData data { IDBKeyRangeData::allKeys(), IndexedDB::GetAllType::Keys, std::nullopt, IndexedDB::CursorDirection::Next, test.objectStore() };
            EXPECT_TRUE(store.getAllRecords(transaction, data, result).isNull());
            for (auto& key : result.keys())
                keys.append(key.number());
            uint64_t count = 0;
            EXPECT_TRUE(store.getCount(transaction, test.objectStore(), std::nullopt, IDBKeyRangeData::allKeys(), count).isNull());
            keys.append(static_cast<double>(count));
        };
        auto readCursor = [&](const IDBResourceIdentifier& transaction, const IDBResourceIdentifier& cursor, unsigned count) {
            IDBGetResult result;
            IDBIterateCursorData data { { }, { }, count, IndexedDB::CursorIterateOption::Reply };
            EXPECT_TRUE(store.iterateCursor(transaction, cursor, data, result).isNull());
            keys.append(result.keyData().number());
        };
        // A permutation of 0..count-1.
        auto shuffled = [](unsigned count, uint32_t seed) {
            Vector<double> order;
            for (unsigned i = 0; i < count; ++i)
                order.append(i);
            for (unsigned i = count - 1; i > 0; --i) {
                seed = seed * 1664525 + 1013904223;
                std::swap(order[i], order[seed % (i + 1)]);
            }
            return order;
        };

        auto ascending = test.begin(IDBTransactionMode::Readwrite);
        for (unsigned i = 0; i < 100; ++i)
            test.put(ascending, 1000 + i);
        EXPECT_TRUE(store.commitTransaction(ascending).isNull());

        // Below the point: 100 records, 20 out-of-order puts.
        auto below = test.begin(IDBTransactionMode::Readwrite);
        for (double key : shuffled(20, 1))
            test.put(below, key);
        readAll(below);
        EXPECT_TRUE(store.commitTransaction(below).isNull());

        // Under a cursor: 600 out-of-order puts, then one more after the cursor's transaction.
        auto underCursor = test.begin(IDBTransactionMode::Readwrite);
        auto cursor = IDBCursorInfo::forBackingStore(IDBResourceIdentifier { test.connection() }, underCursor, test.objectStore(), std::nullopt, IDBKeyRangeData::allKeys(), IndexedDB::CursorDirection::Next, IndexedDB::CursorType::KeyOnly);
        IDBGetResult first;
        EXPECT_TRUE(store.openCursor(underCursor, cursor, first).isNull());
        keys.append(first.keyData().number());
        for (double key : shuffled(600, 2))
            test.put(underCursor, 100 + key);
        readCursor(underCursor, cursor.identifier(), 30);
        EXPECT_TRUE(store.commitTransaction(underCursor).isNull());
        auto oneMore = test.begin(IDBTransactionMode::Readwrite);
        test.put(oneMore, 50.5);
        readAll(oneMore);
        EXPECT_TRUE(store.commitTransaction(oneMore).isNull());

        // Past the point: 2000 out-of-order puts and 500 deletes, then reads.
        auto past = test.begin(IDBTransactionMode::Readwrite);
        for (double key : shuffled(2000, 3))
            test.put(past, 2000 + key);
        for (double key : shuffled(500, 4))
            EXPECT_TRUE(store.deleteRange(past, test.objectStore(), numberRange(2000 + 4 * key, 2000 + 4 * key)).isNull());
        readAll(past);
        EXPECT_TRUE(store.commitTransaction(past).isNull());
    });
    return keys;
}

// The same through an index whose keys arrive in random order, several records to a key: short of and past the point
// where the in-memory store stops keeping the index's entries sorted, under an open index cursor, and with deletes and
// an aborted transaction. Returns the (index key, primary key) pairs every read gives, in the order given.
Vector<double> indexRecordsReadAroundRandomOrderWrites(StoreKind kind)
{
    Vector<double> records;
    runOffMainThread([&] {
        TestStore test { kind };
        auto& store = test.store();
        auto create = test.begin(IDBTransactionMode::Versionchange);
        auto index = test.addIndex(create, "index"_s);
        EXPECT_TRUE(store.commitTransaction(create).isNull());

        // Index keys in a scrambled order, three records to a key.
        auto put = [&](const IDBResourceIdentifier& transaction, unsigned key) {
            IndexIDToIndexKeyMap indexKeys;
            indexKeys.add(index, IndexKey { IndexKey::Data { numberKey(((key / 3) * 7919) % 100003) } });
            test.put(transaction, key, indexKeys);
        };
        auto readAll = [&](const IDBResourceIdentifier& transaction) {
            IDBGetAllResult result;
            IDBGetAllRecordsData data { IDBKeyRangeData::allKeys(), IndexedDB::GetAllType::Keys, std::nullopt, IndexedDB::CursorDirection::Next, test.objectStore(), index };
            EXPECT_TRUE(store.getAllRecords(transaction, data, result).isNull());
            for (auto& key : result.keys())
                records.append(key.number());
            uint64_t count = 0;
            EXPECT_TRUE(store.getCount(transaction, test.objectStore(), index, numberRange(10000, 90000), count).isNull());
            records.append(static_cast<double>(count));
        };
        auto readCursor = [&](const IDBResourceIdentifier& transaction, const IDBResourceIdentifier& cursor, unsigned count) {
            IDBGetResult result;
            IDBIterateCursorData data { { }, { }, count, IndexedDB::CursorIterateOption::Reply };
            EXPECT_TRUE(store.iterateCursor(transaction, cursor, data, result).isNull());
            records.append(result.keyData().number());
            records.append(result.primaryKeyData().number());
        };
        auto shuffled = [](unsigned count, uint32_t seed) {
            Vector<unsigned> order;
            for (unsigned i = 0; i < count; ++i)
                order.append(i);
            for (unsigned i = count - 1; i > 0; --i) {
                seed = seed * 1664525 + 1013904223;
                std::swap(order[i], order[seed % (i + 1)]);
            }
            return order;
        };

        // Below the point: 30 out-of-order puts.
        auto below = test.begin(IDBTransactionMode::Readwrite);
        for (unsigned key : shuffled(30, 1))
            put(below, key);
        readAll(below);
        EXPECT_TRUE(store.commitTransaction(below).isNull());

        // Under an index cursor: 600 out-of-order puts, then one more after the cursor's transaction.
        auto underCursor = test.begin(IDBTransactionMode::Readwrite);
        auto cursor = IDBCursorInfo::forBackingStore(IDBResourceIdentifier { test.connection() }, underCursor, test.objectStore(), index, IDBKeyRangeData::allKeys(), IndexedDB::CursorDirection::Next, IndexedDB::CursorType::KeyOnly);
        IDBGetResult first;
        EXPECT_TRUE(store.openCursor(underCursor, cursor, first).isNull());
        records.append(first.keyData().number());
        for (unsigned key : shuffled(600, 2))
            put(underCursor, 100 + key);
        readCursor(underCursor, cursor.identifier(), 30);
        EXPECT_TRUE(store.commitTransaction(underCursor).isNull());
        auto oneMore = test.begin(IDBTransactionMode::Readwrite);
        put(oneMore, 50);
        readAll(oneMore);
        EXPECT_TRUE(store.commitTransaction(oneMore).isNull());

        // Past the point: 2000 out-of-order puts and 500 deletes, then reads.
        auto past = test.begin(IDBTransactionMode::Readwrite);
        for (unsigned key : shuffled(2000, 3))
            put(past, 2000 + key);
        for (unsigned key : shuffled(500, 4))
            EXPECT_TRUE(store.deleteRange(past, test.objectStore(), numberRange(2000 + 4 * key, 2000 + 4 * key)).isNull());
        readAll(past);
        EXPECT_TRUE(store.commitTransaction(past).isNull());

        // Past the point again, aborted: the index reads as before.
        auto aborted = test.begin(IDBTransactionMode::Readwrite);
        for (unsigned key : shuffled(2000, 5))
            put(aborted, 5000 + key);
        EXPECT_TRUE(store.deleteRange(aborted, test.objectStore(), numberRange(2100, 2600)).isNull());
        EXPECT_TRUE(store.abortTransaction(aborted).isNull());
        auto afterAbort = test.begin(IDBTransactionMode::Readonly);
        readAll(afterAbort);
        EXPECT_TRUE(store.commitTransaction(afterAbort).isNull());
    });
    return records;
}

} // namespace

// The in-memory store puts an aborted delete's record back under the key the delete named; the SQLite store rolls
// the deletion back, so the record keeps the key it was stored with.
TEST(IndexedDB, MemoryStoreAbortedDeleteRestoresTheNamedKey)
{
    EXPECT_TRUE(keyAfterAbortedDeleteOfNegativeZeroIsNegative(StoreKind::Memory));
    EXPECT_FALSE(keyAfterAbortedDeleteOfNegativeZeroIsNegative(StoreKind::SQLiteMemory));
}

// The abort deletes the added index that holds the name the renamed one goes back to.
TEST(IndexedDB, AbortedRenameOverAddedIndex)
{
    for (auto kind : { StoreKind::Memory, StoreKind::SQLiteMemory }) {
        auto [name, count] = indexAfterAbortedRenameOverAddedIndex(kind);
        EXPECT_EQ("a"_s, name);
        EXPECT_EQ(3u, count);
    }
}

TEST(IndexedDB, MemoryStoreKeepsKeyOrderAcrossRandomOrderWrites)
{
    auto keys = keysReadAroundRandomOrderWrites(StoreKind::Memory);
    // The keys all the reads return together: 3067 for the fixed seed, and the SQLite store returns the same ones in the
    // same order.
    EXPECT_EQ(3067u, keys.size());
    EXPECT_EQ(keysReadAroundRandomOrderWrites(StoreKind::SQLiteMemory), keys);
}

TEST(IndexedDB, MemoryStoreKeepsIndexOrderAcrossRandomOrderWrites)
{
    auto records = indexRecordsReadAroundRandomOrderWrites(StoreKind::Memory);
    // The index records all the reads return together: 4930 for the fixed seed, and the SQLite store returns the same
    // ones in the same order.
    EXPECT_EQ(4930u, records.size());
    EXPECT_EQ(indexRecordsReadAroundRandomOrderWrites(StoreKind::SQLiteMemory), records);
}

} // namespace TestWebKitAPI
