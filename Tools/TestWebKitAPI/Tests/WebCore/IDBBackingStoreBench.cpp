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

// Speed of IndexedDB's backing stores, one test per workload, through the IDBBackingStore interface and the
// factories in IDBBackingStoreFactories.h (no page, no script, no IPC). The tests name no store class.
//
// Each pass makes a fresh store (a fresh temporary directory for the file store), runs the workload's operations
// with deterministic inputs and feeds every result (errors, keys, values, counts, database info) to an FNV-1a
// digest. By default a test runs one pass and EXPECT_EQs the digest against the workload's expected checksum, so a
// mismatch means the store's results changed. With WEBKIT_RUN_BENCHMARKS set it then repeats the pass until its timed
// part has taken at least a second (at least three passes), checks every pass's digest, and prints
//     <Test>: <ms> ms <n> MB/s checksum=<digest>
// where <ms> is the timed total and <n> counts the key and value bytes the timed operations carried.
// Set-up and tear-down inside a pass (making the directory, filling a store a read workload reads, deleting the
// files) is measured and left out of the time.
//
// Stores run on a WTF::Thread: IDBBackingStore's constructor and destructor RELEASE_ASSERT(!isMainThread()).

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
#include <WebCore/IDBSerialization.h>
#include <WebCore/IDBTransactionDurability.h>
#include <WebCore/IDBTransactionInfo.h>
#include <WebCore/IDBTransactionMode.h>
#include <WebCore/IDBValue.h>
#include <WebCore/IndexKey.h>
#include <WebCore/IndexedDB.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/SQLiteDatabase.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/ThreadSafeDataBuffer.h>
#include <algorithm>
#include <atomic>
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <wtf/FileSystem.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Seconds.h>
#include <wtf/Threading.h>
#include <wtf/Vector.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI {

using namespace WebCore;
using namespace WebCore::IDBServer;

namespace IDBBackingStoreBenchmark {

using namespace IDBBenchmarkSupport;

// Each workload's expected checksum. A mismatch fails the test and prints the checksum
// ("<Test>: checksum=<digest> (recorded <value>)").
namespace Recorded {
constexpr uint64_t putSmallRecords = 0x498fe79ec2553545;
constexpr uint64_t putWithIndexes = 0x7316cdd94716adc5;
constexpr uint64_t putUniqueConflict = 0x6533760ecb605485;
constexpr uint64_t getByKey = 0xdefd4d6bfdd29e2c;
constexpr uint64_t cursorIterate = 0x3268bda7793e4605;
constexpr uint64_t cursorIterateReverseUnique = 0xd7c6b1fa84e5ee53;
constexpr uint64_t cursorIterateIndex = 0xaed84c5d2cac6fda;
constexpr uint64_t cursorMutateUnderCursor = 0x5285f3fdedc0569f;
constexpr uint64_t getAllRange = 0xb8b9119f85a2f488;
constexpr uint64_t deleteRange = 0x72a1336f89f6456c;
constexpr uint64_t createIndexOverRecords = 0xe37687d5583390d5;
constexpr uint64_t keyRoundTrip = 0xe8c8ddf759496e05;
constexpr uint64_t collationSort = 0x6e13bf5f7452e08f;
constexpr uint64_t openWithMigration = 0x87aad757e58c8707;
constexpr uint64_t memoryStorePutGetCursor = 0x094ded58f8195271;
constexpr uint64_t memoryStoreIndexCursor = 0x983ee1a46c949e42;
constexpr uint64_t memoryStoreAbortVersionChange = 0x01a7eb401c159ac5;
constexpr uint64_t sqliteMemoryPutGetCursor = 0x1aba28473d129abc;
constexpr uint64_t realisticMix = 0xfd2a8c680a486da8;
constexpr uint64_t memoryStoreRandomPutDelete = 0xb3a3978d73bb4b64;
constexpr uint64_t memoryStoreRandomPutDeleteIndex = 0x08d2a6bb9006806c;
constexpr uint64_t memoryStoreRandomPutIndex = 0x242e6b628a072e6a;
}

// Keys of every type, 8-bit and 16-bit strings (with unpaired surrogates), binaries and arrays nested to depth 3.
static IDBKeyData makeMixedKey(Random& random, unsigned depth = 0)
{
    switch (random.below(depth < 3 ? 9 : 7)) {
    case 0:
        return numberKey(static_cast<double>(random.below(100000)) / 8);
    case 1:
        return numberKey(static_cast<double>(random.below(1000)) - 500);
    case 2:
        return IDBKeyData { IDBKeyData::ValueVariant { IDBKeyData::Date { static_cast<double>(random.below(1000000)) * 1000 } } };
    case 3:
    case 4: {
        StringBuilder builder;
        unsigned length = random.below(25);
        bool wide = random.below(2);
        for (unsigned i = 0; i < length; ++i) {
            char16_t unit = 'a' + random.below(26);
            if (wide && i % 5 == 3)
                unit = random.below(8) ? static_cast<char16_t>(0x4E00 + random.below(64)) : static_cast<char16_t>(0xD800 + random.below(16));
            builder.append(unit);
        }
        return stringKey(builder.toString());
    }
    case 5: {
        Vector<uint8_t> bytes;
        unsigned length = random.below(33);
        for (unsigned i = 0; i < length; ++i)
            bytes.append(static_cast<uint8_t>(random.below(256)));
        return IDBKeyData { IDBKeyData::ValueVariant { ThreadSafeDataBuffer::create(WTF::move(bytes)) } };
    }
    case 6:
        return numberKey(static_cast<double>(random.below(1 << 20)));
    default: {
        Vector<IDBKeyData> elements;
        unsigned count = random.below(5);
        for (unsigned i = 0; i < count; ++i)
            elements.append(makeMixedKey(random, depth + 1));
        return IDBKeyData { IDBKeyData::ValueVariant { WTF::move(elements) } };
    }
    }
}

// The server-side environment a store needs: an IDBConnectionToClient to mint resource identifiers from, and
// a transaction, cursor and schema helper that follows what UniqueIDBDatabase and IDBCursor do.

enum class StoreKind { SQLiteFile, SQLiteMemory, Memory };

class Session {
public:
    Session(StoreKind kind, const String& directory = { })
        : m_connection(IDBConnectionToClient::create(*m_delegate))
        , m_identifier("IDBBackingStoreBench"_s, SecurityOriginData { "https"_s, "bench.example"_s, std::nullopt }, SecurityOriginData { "https"_s, "bench.example"_s, std::nullopt })
    {
        switch (kind) {
        case StoreKind::SQLiteFile:
            m_store = makeSQLiteIDBBackingStore(m_identifier, directory);
            break;
        case StoreKind::SQLiteMemory:
            m_store = makeSQLiteMemoryIDBBackingStore(m_identifier);
            break;
        case StoreKind::Memory:
            m_store = makeMemoryIDBBackingStore(m_identifier);
            break;
        }
    }

    ~Session()
    {
        close();
        m_connection->clearDelegate();
    }

    void close()
    {
        if (m_store)
            m_store->close();
        m_store = nullptr; // Destroyed on this (non-main) thread.
    }

    void open(Digest& digest)
    {
        digest.addError(m_store->getOrEstablishDatabaseInfo(info));
        digest.addInteger(m_store->databaseVersion());
    }

    IDBBackingStore& store() { return *m_store; }

    IDBResourceIdentifier newIdentifier() { return IDBResourceIdentifier { m_connection.get() }; }

    IDBResourceIdentifier begin(Digest& digest, IDBTransactionMode mode, Vector<String>&& objectStores = { })
    {
        auto identifier = newIdentifier();
        std::unique_ptr<IDBDatabaseInfo> original;
        uint64_t newVersion = 0;
        if (mode == IDBTransactionMode::Versionchange) {
            original = makeUnique<IDBDatabaseInfo>(info);
            newVersion = info.version() + 1;
            info.setVersion(newVersion);
        }
        IDBTransactionInfo transactionInfo { identifier, mode, IDBTransactionDurability::Default, newVersion, WTF::move(objectStores), WTF::move(original) };
        digest.addError(m_store->beginTransaction(transactionInfo));
        return identifier;
    }

    void commit(Digest& digest, const IDBResourceIdentifier& transaction) { digest.addError(m_store->commitTransaction(transaction)); }
    void abort(Digest& digest, const IDBResourceIdentifier& transaction) { digest.addError(m_store->abortTransaction(transaction)); }

    // Schema changes, in a version-change transaction.
    IDBObjectStoreInfo createObjectStore(Digest& digest, const IDBResourceIdentifier& transaction, const String& name)
    {
        auto objectStoreInfo = info.createNewObjectStore(name, std::nullopt, false);
        digest.addError(m_store->createObjectStore(transaction, objectStoreInfo));
        return objectStoreInfo;
    }

    IDBIndexIdentifier createIndex(Digest& digest, const IDBResourceIdentifier& transaction, IDBObjectStoreIdentifier objectStore, const String& name, bool unique, bool multiEntry)
    {
        auto* objectStoreInfo = info.infoForExistingObjectStore(objectStore);
        RELEASE_ASSERT(objectStoreInfo);
        auto indexInfo = objectStoreInfo->createNewIndex(info.generateNextIndexID(), name, IDBKeyPath { String { "key"_s } }, unique, multiEntry);
        digest.addError(m_store->addIndex(transaction, indexInfo));
        return indexInfo.identifier();
    }

    // Records.
    void put(Digest& digest, const IDBResourceIdentifier& transaction, IDBObjectStoreIdentifier objectStore, const IDBKeyData& key, const IndexIDToIndexKeyMap& indexKeys, const IDBValue& value)
    {
        auto* objectStoreInfo = info.infoForExistingObjectStore(objectStore);
        RELEASE_ASSERT(objectStoreInfo);
        digest.addError(m_store->overwriteRecord(transaction, *objectStoreInfo, key, indexKeys, value));
    }

    void get(Digest& digest, const IDBResourceIdentifier& transaction, IDBObjectStoreIdentifier objectStore, const IDBKeyData& key)
    {
        IDBGetResult result;
        digest.addError(m_store->getRecord(transaction, objectStore, exactly(key), IDBGetRecordDataType::KeyAndValue, result));
        digest.addGetResult(result);
    }

    void getIndex(Digest& digest, const IDBResourceIdentifier& transaction, IDBObjectStoreIdentifier objectStore, IDBIndexIdentifier index, const IDBKeyData& key)
    {
        IDBGetResult result;
        digest.addError(m_store->getIndexRecord(transaction, objectStore, index, IndexedDB::IndexRecordType::Value, exactly(key), result));
        digest.addGetResult(result);
    }

    void getAll(Digest& digest, const IDBResourceIdentifier& transaction, IDBObjectStoreIdentifier objectStore, const IDBKeyRangeData& range)
    {
        IDBGetAllResult result;
        IDBGetAllRecordsData data { range, IndexedDB::GetAllType::Values, std::nullopt, IndexedDB::CursorDirection::Next, objectStore };
        digest.addError(m_store->getAllRecords(transaction, data, result));
        digest.addGetAllResult(result);
    }

    void count(Digest& digest, const IDBResourceIdentifier& transaction, IDBObjectStoreIdentifier objectStore, const IDBKeyRangeData& range)
    {
        uint64_t count = 0;
        digest.addError(m_store->getCount(transaction, objectStore, std::nullopt, range, count));
        digest.addInteger(count);
    }

    void deleteRange(Digest& digest, const IDBResourceIdentifier& transaction, IDBObjectStoreIdentifier objectStore, const IDBKeyRangeData& range)
    {
        digest.addError(m_store->deleteRange(transaction, objectStore, range));
    }

    // Walks a cursor the way IDBCursor::continue() does: the records the server prefetched are consumed
    // without calling the store (until a write by this transaction, which `onRecord` reports by returning
    // true, makes them stale); otherwise the next step is iterateCursor(count). Returns the records visited.
    template<typename OnRecord>
    size_t drainCursor(Digest& digest, const IDBResourceIdentifier& transaction, const IDBCursorInfo& cursor, OnRecord&& onRecord, size_t limit = SIZE_MAX, unsigned step = 1)
    {
        Vector<IDBCursorRecord> prefetched;
        size_t head = 0;
        auto absorb = [&](const IDBGetResult& result) {
            prefetched.clear();
            head = 0;
            for (auto& record : result.prefetchedRecords())
                prefetched.append(record);
        };
        auto reached = [](const IDBGetResult& result) { return result.isDefined() && !result.keyData().isNull(); };

        IDBGetResult current;
        digest.addError(m_store->openCursor(transaction, cursor, current));
        digest.addGetResult(current);
        absorb(current);

        size_t visited = 0;
        while (reached(current) && visited < limit) {
            ++visited;
            if (onRecord(current.keyData(), current.primaryKeyData(), current.value())) {
                prefetched.clear();
                head = 0;
            }
            if (visited >= limit)
                break;
            if (step <= prefetched.size() - head) {
                head += step - 1;
                auto& record = prefetched[head++];
                current = IDBGetResult { record.key, record.primaryKey, IDBValue { record.value }, std::nullopt };
                digest.addRecord(current.keyData(), current.primaryKeyData(), current.value());
                continue;
            }
            IDBGetResult next;
            IDBIterateCursorData data { { }, { }, step, IndexedDB::CursorIterateOption::Reply };
            digest.addError(m_store->iterateCursor(transaction, cursor.identifier(), data, next));
            digest.addGetResult(next);
            absorb(next);
            current = WTF::move(next);
        }
        digest.addInteger(visited);
        return visited;
    }

    IDBCursorInfo objectStoreCursor(const IDBResourceIdentifier& transaction, IDBObjectStoreIdentifier objectStore, const IDBKeyRangeData& range, IndexedDB::CursorDirection direction)
    {
        return IDBCursorInfo::forBackingStore(newIdentifier(), transaction, objectStore, std::nullopt, range, direction, IndexedDB::CursorType::KeyAndValue);
    }

    IDBCursorInfo indexCursor(const IDBResourceIdentifier& transaction, IDBObjectStoreIdentifier objectStore, IDBIndexIdentifier index, const IDBKeyRangeData& range, IndexedDB::CursorDirection direction)
    {
        return IDBCursorInfo::forBackingStore(newIdentifier(), transaction, objectStore, index, range, direction, IndexedDB::CursorType::KeyAndValue);
    }

    IDBDatabaseInfo info;

private:
    // On the heap: a CheckedPtr-capable object destroyed on the stack asserts in Debug (m_didBeginDeletion).
    std::unique_ptr<NullDelegate> m_delegate { makeUnique<NullDelegate>() };
    Ref<IDBConnectionToClient> m_connection;
    IDBDatabaseIdentifier m_identifier;
    std::unique_ptr<IDBBackingStore> m_store;
};

// One object store ("bench") with the given indexes, in one version-change transaction.
static IDBObjectStoreIdentifier createSchema(Session& session, Digest& digest, std::initializer_list<bool> multiEntryFlags, Vector<IndexSpec>& indexes)
{
    auto versionChange = session.begin(digest, IDBTransactionMode::Versionchange);
    auto objectStore = session.createObjectStore(digest, versionChange, "bench"_s);
    unsigned number = 0;
    for (bool multiEntry : multiEntryFlags) {
        auto identifier = session.createIndex(digest, versionChange, objectStore.identifier(), makeString("index"_s, number++), false, multiEntry);
        indexes.append({ identifier, multiEntry });
    }
    session.commit(digest, versionChange);
    return objectStore.identifier();
}

static IndexKey indexKeyFor(const IndexSpec& spec, unsigned i)
{
    if (!spec.multiEntry)
        return IndexKey { IndexKey::Data { numberKey(i % 1009) } };
    Vector<IDBKeyData> keys;
    keys.append(numberKey(i % 97));
    keys.append(numberKey(1000 + i % 89));
    keys.append(numberKey(2000 + i % 83));
    return IndexKey { IndexKey::Data { WTF::move(keys) } };
}

// Puts `count` records, number keys first + 0..count-1, 64-byte values, in a read-write transaction of its own.
static size_t populate(Session& session, Digest& digest, IDBObjectStoreIdentifier objectStore, const Vector<IndexSpec>& indexes, unsigned count, unsigned first = 0, size_t valueBytes = 64)
{
    auto transaction = session.begin(digest, IDBTransactionMode::Readwrite, { "bench"_s });
    size_t bytes = 0;
    for (unsigned i = 0; i < count; ++i) {
        IndexIDToIndexKeyMap indexKeys;
        for (auto& spec : indexes)
            indexKeys.add(spec.identifier, indexKeyFor(spec, first + i));
        auto value = makeValue(first + i, valueBytes);
        session.put(digest, transaction, objectStore, numberKey(first + i), indexKeys, value);
        bytes += 8 + valueSize(value);
    }
    session.commit(digest, transaction);
    return bytes;
}

// Schema and records, outside the timed part.
static IDBObjectStoreIdentifier prepare(Session& session, Digest& digest, Excluded& excluded, std::initializer_list<bool> multiEntryFlags, Vector<IndexSpec>& indexes, unsigned count)
{
    std::optional<IDBObjectStoreIdentifier> objectStore;
    excluded.measure([&] {
        objectStore = createSchema(session, digest, multiEntryFlags, indexes);
        if (count)
            populate(session, digest, *objectStore, indexes, count);
    });
    return *objectStore;
}

// The harness.

// `pass(digest, excluded)` returns the bytes its timed operations carried.
template<typename Pass>
static void run(ASCIILiteral name, uint64_t recorded, const Pass& pass)
{
    Digest digest;
    Excluded excluded;
    runOffMainThread([&] {
        pass(digest, excluded);
    });
    auto checksum = digest.value();
    EXPECT_EQ(recorded, checksum);
    if (recorded != checksum)
        SAFE_PRINTF("%s: checksum=%016llx (recorded %016llx)\n", name, static_cast<unsigned long long>(checksum), static_cast<unsigned long long>(recorded));
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    Seconds timed;
    double totalBytes = 0;
    size_t passes = 0;
    size_t mismatches = 0;
    runOffMainThread([&] {
        do {
            Digest passDigest;
            Excluded passExcluded;
            auto start = MonotonicTime::now();
            size_t passBytes = pass(passDigest, passExcluded);
            timed += (MonotonicTime::now() - start) - passExcluded.total();
            totalBytes += passBytes;
            ++passes;
            mismatches += passDigest.value() != checksum;
        } while (passes < 3 || timed < 1_s);
    });
    EXPECT_EQ(0u, mismatches);
    SAFE_PRINTF("%s: %.1f ms %.3f MB/s checksum=%016llx\n", name, timed.milliseconds(),
        totalBytes / timed.microseconds(), static_cast<unsigned long long>(checksum));
}

// Workloads shared by several tests.

constexpr unsigned recordCount = 10000;

// Strides through 0..9999 in a fixed shuffled order (7919 is prime).
static unsigned shuffled(unsigned i) { return (i * 7919u) % recordCount; }

static size_t putGetCursor(StoreKind kind, Digest& digest, Excluded& excluded)
{
    size_t bytes = 0;
    Session session(kind);
    session.open(digest);
    Vector<IndexSpec> indexes;
    auto objectStore = createSchema(session, digest, { }, indexes);
    bytes += populate(session, digest, objectStore, indexes, recordCount);
    auto transaction = session.begin(digest, IDBTransactionMode::Readonly, { "bench"_s });
    for (unsigned i = 0; i < recordCount; ++i) {
        session.get(digest, transaction, objectStore, numberKey(shuffled(i)));
        bytes += 8 + 64;
    }
    auto cursor = session.objectStoreCursor(transaction, objectStore, IDBKeyRangeData::allKeys(), IndexedDB::CursorDirection::Next);
    session.drainCursor(digest, transaction, cursor, [&](const IDBKeyData&, const IDBKeyData&, const IDBValue& value) {
        bytes += 8 + valueSize(value);
        return false;
    });
    session.commit(digest, transaction);
    excluded.measure([&] {
        session.close();
    });
    return bytes;
}

static size_t indexCursorPass(StoreKind kind, IndexedDB::CursorDirection direction, Digest& digest, Excluded& excluded, std::optional<TemporaryDirectory>& directory)
{
    size_t bytes = 0;
    excluded.measure([&] {
        if (kind == StoreKind::SQLiteFile)
            directory.emplace();
    });
    Session session(kind, directory ? directory->path() : String { });
    session.open(digest);
    Vector<IndexSpec> indexes;
    // Set-up is part of the pass's digest but not of its time.
    auto objectStore = prepare(session, digest, excluded, { true }, indexes, 5000);
    auto transaction = session.begin(digest, IDBTransactionMode::Readonly, { "bench"_s });
    auto cursor = session.indexCursor(transaction, objectStore, indexes[0].identifier, IDBKeyRangeData::allKeys(), direction);
    session.drainCursor(digest, transaction, cursor, [&](const IDBKeyData&, const IDBKeyData&, const IDBValue& value) {
        bytes += 8 + 8 + valueSize(value);
        return false;
    });
    session.commit(digest, transaction);
    excluded.measure([&] {
        session.close();
        directory = std::nullopt;
    });
    return bytes;
}

// OpenWithMigration's input: a database the production store writes, rewritten to the v1 schemas by SQL
// (metadata version 1, v1 ObjectStoreInfo with maxIndexID, v1 Records and IndexRecords, TEXT database name).
// The tables of the version 1 schema: quoted names after RENAME are the alternate forms the store accepts. Keys of the two object stores are disjoint, since v1's key column is unique alone.

static void executeOrDie(SQLiteDatabase& database, StringView statement)
{
    bool ok = database.executeCommandSlow(statement);
    RELEASE_ASSERT(ok);
}

static void rewriteToV1(const String& databasePath)
{
    auto databaseOwner = makeUnique<SQLiteDatabase>();
    SQLiteDatabase& database = *databaseOwner;
    bool opened = database.open(databasePath, SQLiteDatabase::OpenMode::ReadWrite);
    RELEASE_ASSERT(opened);
    database.disableThreadingChecks();
    // Only needs to be a total order for the v1 UNIQUE constraint on Records.key while the rows are copied.
    database.setCollationFunction("IDBKEY"_s, [](int aLength, const void* a, int bLength, const void* b) {
        auto left = unsafeMakeSpan(static_cast<const uint8_t*>(a), aLength);
        auto right = unsafeMakeSpan(static_cast<const uint8_t*>(b), bLength);
        auto order = std::lexicographical_compare_three_way(left.begin(), left.end(), right.begin(), right.end());
        return order < 0 ? -1 : (order > 0 ? 1 : 0);
    });

    executeOrDie(database, "CREATE TABLE _V1_Records (objectStoreID INTEGER NOT NULL ON CONFLICT FAIL, key TEXT COLLATE IDBKEY NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT REPLACE, value NOT NULL ON CONFLICT FAIL)"_s);
    executeOrDie(database, "INSERT INTO _V1_Records SELECT objectStoreID, key, value FROM Records"_s);
    executeOrDie(database, "DROP TABLE Records"_s);
    executeOrDie(database, "ALTER TABLE _V1_Records RENAME TO Records"_s);

    executeOrDie(database, "CREATE TABLE _V1_IndexRecords (indexID INTEGER NOT NULL ON CONFLICT FAIL, objectStoreID INTEGER NOT NULL ON CONFLICT FAIL, key TEXT COLLATE IDBKEY NOT NULL ON CONFLICT FAIL, value NOT NULL ON CONFLICT FAIL)"_s);
    executeOrDie(database, "INSERT INTO _V1_IndexRecords SELECT indexID, objectStoreID, key, value FROM IndexRecords"_s);
    executeOrDie(database, "DROP TABLE IndexRecords"_s);
    executeOrDie(database, "ALTER TABLE _V1_IndexRecords RENAME TO IndexRecords"_s);

    executeOrDie(database, "CREATE TABLE _V1_ObjectStoreInfo (id INTEGER PRIMARY KEY NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT FAIL, name TEXT NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT FAIL, keyPath BLOB NOT NULL ON CONFLICT FAIL, autoInc INTEGER NOT NULL ON CONFLICT FAIL, maxIndexID INTEGER NOT NULL ON CONFLICT FAIL)"_s);
    executeOrDie(database, "INSERT INTO _V1_ObjectStoreInfo SELECT id, name, keyPath, autoInc, 0 FROM ObjectStoreInfo"_s);
    executeOrDie(database, "DROP TABLE ObjectStoreInfo"_s);
    executeOrDie(database, "ALTER TABLE _V1_ObjectStoreInfo RENAME TO ObjectStoreInfo"_s);

    executeOrDie(database, "UPDATE IDBDatabaseInfo SET value = '1' WHERE key = 'MetadataVersion'"_s);
    executeOrDie(database, "UPDATE IDBDatabaseInfo SET value = 'IDBBackingStoreBench' WHERE key = 'DatabaseName'"_s);
    database.close();
}

// Returns the v1 file's path; the production store wrote its rows.
static String buildV1Database(const String& directory)
{
    Digest scratch;
    {
        Session session(StoreKind::SQLiteFile, directory);
        session.open(scratch);
        auto versionChange = session.begin(scratch, IDBTransactionMode::Versionchange);
        auto first = session.createObjectStore(scratch, versionChange, "first"_s);
        auto second = session.createObjectStore(scratch, versionChange, "second"_s);
        Vector<IndexSpec> indexes;
        for (auto objectStore : { first.identifier(), second.identifier() }) {
            indexes.append({ session.createIndex(scratch, versionChange, objectStore, "unique"_s, false, false), false });
            indexes.append({ session.createIndex(scratch, versionChange, objectStore, "multi"_s, false, true), true });
        }
        session.commit(scratch, versionChange);

        auto transaction = session.begin(scratch, IDBTransactionMode::Readwrite, { "first"_s, "second"_s });
        for (unsigned i = 0; i < 2000; ++i) {
            for (unsigned s = 0; s < 2; ++s) {
                IndexIDToIndexKeyMap indexKeys;
                for (unsigned k = 0; k < 2; ++k)
                    indexKeys.add(indexes[s * 2 + k].identifier, indexKeyFor(indexes[s * 2 + k], i));
                unsigned key = s * 1000000 + i;
                session.put(scratch, transaction, s ? second.identifier() : first.identifier(), numberKey(key), indexKeys, makeValue(key, 96));
            }
        }
        session.commit(scratch, transaction);
        session.close();
    }
    String path = fullDatabasePathForDirectory(directory);
    rewriteToV1(path);
    return path;
}

} // namespace IDBBackingStoreBenchmark

using namespace IDBBackingStoreBenchmark;

// Runs no workload: alone in a process, its time is the start-up every other test's process also pays.
TEST(IDBBackingStoreBench, StartUp)
{
}

TEST(IDBBackingStoreBench, PutSmallRecords)
{
    run("PutSmallRecords"_s, Recorded::putSmallRecords, [](Digest& digest, Excluded& excluded) {
        size_t bytes = 0;
        TemporaryDirectory* directory = nullptr;
        excluded.measure([&] {
            directory = new TemporaryDirectory;
        });
        Session session(StoreKind::SQLiteFile, directory->path());
        session.open(digest);
        Vector<IndexSpec> indexes;
        auto objectStore = prepare(session, digest, excluded, { }, indexes, 0);
        bytes += populate(session, digest, objectStore, indexes, recordCount);
        excluded.measure([&] {
            session.close();
            delete directory;
        });
        return bytes;
    });
}

TEST(IDBBackingStoreBench, PutWithIndexes)
{
    run("PutWithIndexes"_s, Recorded::putWithIndexes, [](Digest& digest, Excluded& excluded) {
        size_t bytes = 0;
        TemporaryDirectory* directory = nullptr;
        excluded.measure([&] {
            directory = new TemporaryDirectory;
        });
        Session session(StoreKind::SQLiteFile, directory->path());
        session.open(digest);
        Vector<IndexSpec> indexes;
        auto objectStore = prepare(session, digest, excluded, { false, true }, indexes, 0);
        // The first index is declared non-unique by createSchema, so a repeat of its key is not an error here;
        // PutUniqueConflict is the workload that makes the unique index fail.
        bytes += populate(session, digest, objectStore, indexes, 5000);
        excluded.measure([&] {
            session.close();
            delete directory;
        });
        return bytes;
    });
}

TEST(IDBBackingStoreBench, PutUniqueConflict)
{
    run("PutUniqueConflict"_s, Recorded::putUniqueConflict, [](Digest& digest, Excluded& excluded) {
        size_t bytes = 0;
        TemporaryDirectory* directory = nullptr;
        excluded.measure([&] {
            directory = new TemporaryDirectory;
        });
        Session session(StoreKind::SQLiteFile, directory->path());
        session.open(digest);
        std::optional<IDBObjectStoreIdentifier> preparedStore;
        std::optional<IDBIndexIdentifier> preparedIndex;
        excluded.measure([&] {
            auto versionChange = session.begin(digest, IDBTransactionMode::Versionchange);
            preparedStore = session.createObjectStore(digest, versionChange, "bench"_s).identifier();
            preparedIndex = session.createIndex(digest, versionChange, *preparedStore, "unique"_s, true, false);
            session.commit(digest, versionChange);
        });
        auto objectStore = *preparedStore;
        auto uniqueIndex = *preparedIndex;
        auto transaction = session.begin(digest, IDBTransactionMode::Readwrite, { "bench"_s });
        for (unsigned i = 0; i < 2000; ++i) {
            // Even puts are new; each odd put reuses the previous put's index key under a new primary key.
            IndexIDToIndexKeyMap indexKeys;
            indexKeys.add(uniqueIndex, IndexKey { IndexKey::Data { numberKey(i & ~1u) } });
            auto value = makeValue(i, 64);
            session.put(digest, transaction, objectStore, numberKey(i), indexKeys, value);
            bytes += 8 + valueSize(value);
        }
        session.commit(digest, transaction);
        excluded.measure([&] {
            session.close();
            delete directory;
        });
        return bytes;
    });
}

TEST(IDBBackingStoreBench, GetByKey)
{
    run("GetByKey"_s, Recorded::getByKey, [](Digest& digest, Excluded& excluded) {
        size_t bytes = 0;
        TemporaryDirectory* directory = nullptr;
        excluded.measure([&] {
            directory = new TemporaryDirectory;
        });
        Session session(StoreKind::SQLiteFile, directory->path());
        session.open(digest);
        Vector<IndexSpec> indexes;
        auto objectStore = prepare(session, digest, excluded, { }, indexes, recordCount);
        auto transaction = session.begin(digest, IDBTransactionMode::Readonly, { "bench"_s });
        for (unsigned i = 0; i < recordCount; ++i) {
            session.get(digest, transaction, objectStore, numberKey(shuffled(i)));
            bytes += 8 + 64;
        }
        session.commit(digest, transaction);
        excluded.measure([&] {
            session.close();
            delete directory;
        });
        return bytes;
    });
}

TEST(IDBBackingStoreBench, CursorIterate)
{
    run("CursorIterate"_s, Recorded::cursorIterate, [](Digest& digest, Excluded& excluded) {
        size_t bytes = 0;
        TemporaryDirectory* directory = nullptr;
        excluded.measure([&] {
            directory = new TemporaryDirectory;
        });
        Session session(StoreKind::SQLiteFile, directory->path());
        session.open(digest);
        Vector<IndexSpec> indexes;
        auto objectStore = prepare(session, digest, excluded, { }, indexes, recordCount);
        auto transaction = session.begin(digest, IDBTransactionMode::Readonly, { "bench"_s });
        auto cursor = session.objectStoreCursor(transaction, objectStore, IDBKeyRangeData::allKeys(), IndexedDB::CursorDirection::Next);
        session.drainCursor(digest, transaction, cursor, [&](const IDBKeyData&, const IDBKeyData&, const IDBValue& value) {
            bytes += 8 + valueSize(value);
            return false;
        });
        session.commit(digest, transaction);
        excluded.measure([&] {
            session.close();
            delete directory;
        });
        return bytes;
    });
}

TEST(IDBBackingStoreBench, CursorIterateReverseUnique)
{
    std::optional<TemporaryDirectory> directory;
    run("CursorIterateReverseUnique"_s, Recorded::cursorIterateReverseUnique, [&](Digest& digest, Excluded& excluded) {
        return indexCursorPass(StoreKind::SQLiteFile, IndexedDB::CursorDirection::Prevunique, digest, excluded, directory);
    });
}

TEST(IDBBackingStoreBench, CursorIterateIndex)
{
    std::optional<TemporaryDirectory> directory;
    run("CursorIterateIndex"_s, Recorded::cursorIterateIndex, [&](Digest& digest, Excluded& excluded) {
        return indexCursorPass(StoreKind::SQLiteFile, IndexedDB::CursorDirection::Next, digest, excluded, directory);
    });
}

TEST(IDBBackingStoreBench, CursorMutateUnderCursor)
{
    run("CursorMutateUnderCursor"_s, Recorded::cursorMutateUnderCursor, [](Digest& digest, Excluded& excluded) {
        size_t bytes = 0;
        TemporaryDirectory* directory = nullptr;
        excluded.measure([&] {
            directory = new TemporaryDirectory;
        });
        Session session(StoreKind::SQLiteFile, directory->path());
        session.open(digest);
        Vector<IndexSpec> indexes;
        auto objectStore = prepare(session, digest, excluded, { false }, indexes, 5000);
        auto transaction = session.begin(digest, IDBTransactionMode::Readwrite, { "bench"_s });
        auto cursor = session.objectStoreCursor(transaction, objectStore, IDBKeyRangeData::allKeys(), IndexedDB::CursorDirection::Next);
        unsigned step = 0;
        session.drainCursor(digest, transaction, cursor, [&](const IDBKeyData& key, const IDBKeyData&, const IDBValue& value) {
            bytes += 8 + valueSize(value);
            if (++step % 10)
                return false;
            // Delete the record under the cursor; the client's prefetched records are stale after a write.
            session.deleteRange(digest, transaction, objectStore, exactly(key));
            return true;
        });
        session.commit(digest, transaction);
        excluded.measure([&] {
            session.close();
            delete directory;
        });
        return bytes;
    });
}

TEST(IDBBackingStoreBench, GetAllRange)
{
    run("GetAllRange"_s, Recorded::getAllRange, [](Digest& digest, Excluded& excluded) {
        size_t bytes = 0;
        TemporaryDirectory* directory = nullptr;
        excluded.measure([&] {
            directory = new TemporaryDirectory;
        });
        Session session(StoreKind::SQLiteFile, directory->path());
        session.open(digest);
        Vector<IndexSpec> indexes;
        auto objectStore = prepare(session, digest, excluded, { }, indexes, recordCount);
        auto transaction = session.begin(digest, IDBTransactionMode::Readonly, { "bench"_s });
        for (unsigned range = 0; range < 10; ++range) {
            session.getAll(digest, transaction, objectStore, rangeOf(numberKey(range * 900), numberKey(range * 900 + 999)));
            bytes += 1000 * (8 + 64);
        }
        session.commit(digest, transaction);
        excluded.measure([&] {
            session.close();
            delete directory;
        });
        return bytes;
    });
}

TEST(IDBBackingStoreBench, DeleteRange)
{
    run("DeleteRange"_s, Recorded::deleteRange, [](Digest& digest, Excluded& excluded) {
        size_t bytes = 0;
        TemporaryDirectory* directory = nullptr;
        excluded.measure([&] {
            directory = new TemporaryDirectory;
        });
        Session session(StoreKind::SQLiteFile, directory->path());
        session.open(digest);
        Vector<IndexSpec> indexes;
        auto objectStore = prepare(session, digest, excluded, { true }, indexes, recordCount);
        auto transaction = session.begin(digest, IDBTransactionMode::Readwrite, { "bench"_s });
        for (unsigned range = 0; range < 10; ++range) {
            session.deleteRange(digest, transaction, objectStore, rangeOf(numberKey(range * 1000), numberKey(range * 1000 + 499)));
            bytes += 500 * (8 + 64);
        }
        session.count(digest, transaction, objectStore, IDBKeyRangeData::allKeys());
        session.commit(digest, transaction);
        excluded.measure([&] {
            session.close();
            delete directory;
        });
        return bytes;
    });
}

TEST(IDBBackingStoreBench, CreateIndexOverRecords)
{
    run("CreateIndexOverRecords"_s, Recorded::createIndexOverRecords, [](Digest& digest, Excluded& excluded) {
        size_t bytes = 0;
        TemporaryDirectory* directory = nullptr;
        excluded.measure([&] {
            directory = new TemporaryDirectory;
        });
        Session session(StoreKind::SQLiteFile, directory->path());
        session.open(digest);
        Vector<IndexSpec> indexes;
        auto objectStore = prepare(session, digest, excluded, { }, indexes, 5000);
        // As UniqueIDBDatabase does: add the index, read every record, then give each its index key.
        auto versionChange = session.begin(digest, IDBTransactionMode::Versionchange);
        auto* objectStoreInfo = session.info.infoForExistingObjectStore(objectStore);
        RELEASE_ASSERT(objectStoreInfo);
        auto indexInfo = objectStoreInfo->createNewIndex(session.info.generateNextIndexID(), "late"_s, IDBKeyPath { String { "key"_s } }, false, true);
        digest.addError(session.store().addIndex(versionChange, indexInfo));
        struct Record {
            IDBKeyData key;
            std::optional<int64_t> recordID;
        };
        Vector<Record> records;
        session.store().forEachObjectStoreRecord(versionChange, objectStore, [&](IDBBackingStore::RecordOrError&& record) {
            if (!record) {
                digest.addError(record.error());
                return;
            }
            digest.addRecord(record->key, record->key, record->value);
            bytes += 8 + valueSize(record->value);
            records.append({ record->key, record->recordID });
        });
        for (auto& record : records) {
            IndexSpec spec { indexInfo.identifier(), true };
            digest.addError(session.store().updateIndexRecordsWithIndexKey(versionChange, indexInfo, record.key, indexKeyFor(spec, static_cast<unsigned>(record.key.number())), record.recordID));
        }
        session.commit(digest, versionChange);
        excluded.measure([&] {
            session.close();
            delete directory;
        });
        return bytes;
    });
}

TEST(IDBBackingStoreBench, KeyRoundTrip)
{
    // 100,000 mixed keys, made once.
    Vector<IDBKeyData> keys;
    Random random(5);
    for (unsigned i = 0; i < 100000; ++i)
        keys.append(makeMixedKey(random));
    run("KeyRoundTrip"_s, Recorded::keyRoundTrip, [&keys](Digest& digest, Excluded&) {
        size_t bytes = 0;
        for (auto& key : keys) {
            auto buffer = serializeIDBKeyData(key);
            digest.addInteger(!!buffer);
            if (!buffer)
                continue;
            auto serialized = buffer->span();
            digest.addBytes(serialized);
            IDBKeyData decoded;
            bool decodedOK = deserializeIDBKeyData(serialized, decoded);
            digest.addInteger(decodedOK);
            digest.addKey(decoded);
            digest.addInteger(decoded == key);
            bytes += serialized.size();
        }
        return bytes;
    });
}

TEST(IDBBackingStoreBench, CollationSort)
{
    run("CollationSort"_s, Recorded::collationSort, [](Digest& digest, Excluded& excluded) {
        size_t bytes = 0;
        Session session(StoreKind::SQLiteMemory);
        session.open(digest);
        Vector<IndexSpec> indexes;
        auto objectStore = prepare(session, digest, excluded, { false }, indexes, 0);
        // An index of 20,000 mixed keys: every insert and the scan compare keys through the collation.
        Random random(9);
        auto transaction = session.begin(digest, IDBTransactionMode::Readwrite, { "bench"_s });
        for (unsigned i = 0; i < 20000; ++i) {
            IndexIDToIndexKeyMap indexKeys;
            auto indexKey = makeMixedKey(random);
            bytes += 16;
            indexKeys.add(indexes[0].identifier, IndexKey { IndexKey::Data { WTF::move(indexKey) } });
            session.put(digest, transaction, objectStore, numberKey(i), indexKeys, makeValue(i, 16));
        }
        auto cursor = session.indexCursor(transaction, objectStore, indexes[0].identifier, IDBKeyRangeData::allKeys(), IndexedDB::CursorDirection::Next);
        session.drainCursor(digest, transaction, cursor, [&](const IDBKeyData& key, const IDBKeyData&, const IDBValue&) {
            bytes += 16;
            return false;
        });
        session.commit(digest, transaction);
        excluded.measure([&] {
            session.close();
        });
        return bytes;
    });
}

TEST(IDBBackingStoreBench, OpenWithMigration)
{
    TemporaryDirectory templateDirectory;
    String templatePath;
    runOffMainThread([&] {
        templatePath = buildV1Database(templateDirectory.path());
    });
    auto templateSize = FileSystem::fileSize(templatePath);
    size_t fileBytes = templateSize ? static_cast<size_t>(*templateSize) : 0;

    run("OpenWithMigration"_s, Recorded::openWithMigration, [&](Digest& digest, Excluded& excluded) {
        TemporaryDirectory* directory = nullptr;
        String path;
        excluded.measure([&] {
            directory = new TemporaryDirectory;
            path = fullDatabasePathForDirectory(directory->path());
            bool copied = FileSystem::copyFile(path, templatePath);
            RELEASE_ASSERT(copied);
        });
        // The static helper reads the v1 file's name and version without migrating it.
        auto nameAndVersion = databaseNameAndVersionFromFile(path);
        digest.addInteger(!!nameAndVersion);
        if (nameAndVersion) {
            digest.addString(nameAndVersion->name);
            digest.addInteger(nameAndVersion->version);
        }
        digest.addInteger(databasesSizeForDirectory(directory->path()) > 0);

        Session session(StoreKind::SQLiteFile, directory->path());
        session.open(digest); // Migrates Records, IndexRecords, ObjectStoreInfo, the metadata and the index ids.
        auto names = session.info.objectStoreNames();
        std::sort(names.begin(), names.end(), [](const String& a, const String& b) {
            return codePointCompareLessThan(a, b);
        });
        digest.addInteger(session.info.version());
        for (auto& name : names) {
            digest.addString(name);
            auto* objectStoreInfo = session.info.infoForExistingObjectStore(name);
            if (!objectStoreInfo)
                continue;
            auto indexNames = objectStoreInfo->indexNames();
            std::sort(indexNames.begin(), indexNames.end(), [](const String& a, const String& b) {
                return codePointCompareLessThan(a, b);
            });
            for (auto& indexName : indexNames)
                digest.addString(indexName);
        }
        // Read the migrated rows back.
        auto* first = session.info.infoForExistingObjectStore("first"_s);
        auto* second = session.info.infoForExistingObjectStore("second"_s);
        if (first && second) {
            auto transaction = session.begin(digest, IDBTransactionMode::Readonly, { "first"_s, "second"_s });
            for (unsigned i = 0; i < 200; ++i) {
                session.get(digest, transaction, first->identifier(), numberKey(shuffled(i) % 2000));
                session.get(digest, transaction, second->identifier(), numberKey(1000000 + shuffled(i) % 2000));
            }
            session.count(digest, transaction, first->identifier(), IDBKeyRangeData::allKeys());
            session.commit(digest, transaction);
        }
        excluded.measure([&] {
            session.close();
            delete directory;
        });
        return fileBytes;
    });
}

TEST(IDBBackingStoreBench, MemoryStorePutGetCursor)
{
    run("MemoryStorePutGetCursor"_s, Recorded::memoryStorePutGetCursor, [](Digest& digest, Excluded& excluded) {
        return putGetCursor(StoreKind::Memory, digest, excluded);
    });
}

TEST(IDBBackingStoreBench, MemoryStoreIndexCursor)
{
    run("MemoryStoreIndexCursor"_s, Recorded::memoryStoreIndexCursor, [](Digest& digest, Excluded& excluded) {
        std::optional<TemporaryDirectory> none;
        size_t bytes = indexCursorPass(StoreKind::Memory, IndexedDB::CursorDirection::Next, digest, excluded, none);
        bytes += indexCursorPass(StoreKind::Memory, IndexedDB::CursorDirection::Prevunique, digest, excluded, none);
        return bytes;
    });
}

// 0..count-1 in an order fixed by `seed` (Fisher-Yates).
static Vector<unsigned> shuffledOrder(unsigned count, uint64_t seed)
{
    Vector<unsigned> order;
    order.reserveInitialCapacity(count);
    for (unsigned i = 0; i < count; ++i)
        order.append(i);
    Random random(seed);
    for (unsigned i = count; i > 1; --i)
        std::swap(order[i - 1], order[random.below(i)]);
    return order;
}

// `count` puts with keys in random order into one store, then (with `deletes`) deletes of half of them in another
// random order, in one read-write transaction: every insert and remove lands in the middle of the ordered keys. With
// `indexed`, one index whose keys are a second random order, so that its entries are inserted and removed out of order too.
static size_t randomPutDelete(unsigned count, bool indexed, bool deletes, Digest& digest, Excluded& excluded)
{
    size_t bytes = 0;
    Session session(StoreKind::Memory);
    Vector<IndexSpec> indexes;
    std::optional<IDBObjectStoreIdentifier> objectStore;
    Vector<unsigned> keys, indexKeys, deletions;
    excluded.measure([&] {
        keys = shuffledOrder(count, 1);
        indexKeys = shuffledOrder(count, 2);
        deletions = shuffledOrder(count, 3);
        session.open(digest);
        if (indexed)
            objectStore = createSchema(session, digest, { false }, indexes);
        else
            objectStore = createSchema(session, digest, { }, indexes);
    });
    auto transaction = session.begin(digest, IDBTransactionMode::Readwrite, { "bench"_s });
    for (unsigned i = 0; i < count; ++i) {
        IndexIDToIndexKeyMap indexKeyMap;
        if (indexed)
            indexKeyMap.add(indexes[0].identifier, IndexKey { IndexKey::Data { numberKey(indexKeys[i]) } });
        auto value = makeValue(i, 16);
        session.put(digest, transaction, *objectStore, numberKey(keys[i]), indexKeyMap, value);
        bytes += 8 + valueSize(value);
    }
    for (unsigned i = 0; deletes && i < count; ++i) {
        unsigned key = deletions[i];
        if (key % 2)
            continue;
        session.deleteRange(digest, transaction, *objectStore, exactly(numberKey(key)));
        bytes += 8;
    }
    session.count(digest, transaction, *objectStore, IDBKeyRangeData::allKeys());
    session.commit(digest, transaction);
    excluded.measure([&] {
        session.close();
    });
    return bytes;
}

TEST(IDBBackingStoreBench, MemoryStoreRandomPutDelete)
{
    run("MemoryStoreRandomPutDelete"_s, Recorded::memoryStoreRandomPutDelete, [](Digest& digest, Excluded& excluded) {
        return randomPutDelete(100000, false, true, digest, excluded);
    });
}

TEST(IDBBackingStoreBench, MemoryStoreRandomPutDeleteIndex)
{
    run("MemoryStoreRandomPutDeleteIndex"_s, Recorded::memoryStoreRandomPutDeleteIndex, [](Digest& digest, Excluded& excluded) {
        // 10,000 records, not 100,000: deleting a record scans every entry of the index, so this workload is quadratic
        // in its record count.
        return randomPutDelete(10000, true, true, digest, excluded);
    });
}

TEST(IDBBackingStoreBench, MemoryStoreRandomPutIndex)
{
    run("MemoryStoreRandomPutIndex"_s, Recorded::memoryStoreRandomPutIndex, [](Digest& digest, Excluded& excluded) {
        return randomPutDelete(100000, true, false, digest, excluded);
    });
}

TEST(IDBBackingStoreBench, MemoryStoreAbortVersionChange)
{
    run("MemoryStoreAbortVersionChange"_s, Recorded::memoryStoreAbortVersionChange, [](Digest& digest, Excluded& excluded) {
        size_t bytes = 0;
        Session session(StoreKind::Memory);
        session.open(digest);
        // A committed baseline: five object stores with an index and 200 records each.
        Vector<IDBObjectStoreIdentifier> baseline;
        Vector<IDBIndexIdentifier> baselineIndexes;
        excluded.measure([&] {
            auto versionChange = session.begin(digest, IDBTransactionMode::Versionchange);
            for (unsigned i = 0; i < 5; ++i) {
                auto objectStore = session.createObjectStore(digest, versionChange, makeString("base"_s, i)).identifier();
                baseline.append(objectStore);
                baselineIndexes.append(session.createIndex(digest, versionChange, objectStore, "index"_s, false, false));
            }
            session.commit(digest, versionChange);
            auto transaction = session.begin(digest, IDBTransactionMode::Readwrite, { "base0"_s, "base1"_s, "base2"_s, "base3"_s, "base4"_s });
            for (unsigned s = 0; s < 5; ++s) {
                for (unsigned i = 0; i < 200; ++i) {
                    IndexIDToIndexKeyMap indexKeys;
                    indexKeys.add(baselineIndexes[s], IndexKey { IndexKey::Data { numberKey(i % 17) } });
                    session.put(digest, transaction, baseline[s], numberKey(i), indexKeys, makeValue(i, 32));
                }
            }
            session.commit(digest, transaction);
        });
        // Twenty version-change transactions that create, rename, clear and delete, then abort.
        for (unsigned round = 0; round < 20; ++round) {
            auto saved = session.info;
            auto versionChange = session.begin(digest, IDBTransactionMode::Versionchange);
            Vector<IDBObjectStoreIdentifier> created;
            Vector<IDBIndexIdentifier> createdIndexes;
            for (unsigned i = 0; i < 10; ++i) {
                auto objectStore = session.createObjectStore(digest, versionChange, makeString("new"_s, round, '-', i)).identifier();
                created.append(objectStore);
                createdIndexes.append(session.createIndex(digest, versionChange, objectStore, "a"_s, false, false));
                session.createIndex(digest, versionChange, objectStore, "b"_s, false, true);
            }
            for (unsigned i = 0; i < 20; ++i) {
                IndexIDToIndexKeyMap indexKeys;
                indexKeys.add(createdIndexes[i % 2], IndexKey { IndexKey::Data { numberKey(i) } });
                session.put(digest, versionChange, created[i % 2], numberKey(i), indexKeys, makeValue(i, 32));
                bytes += 8 + 32;
            }
            digest.addError(session.store().renameObjectStore(versionChange, created[2], "renamed"_s));
            digest.addError(session.store().renameObjectStore(versionChange, baseline[1], "renamed-base"_s));
            digest.addError(session.store().renameIndex(versionChange, baseline[2], baselineIndexes[2], "renamed-index"_s));
            digest.addError(session.store().deleteIndex(versionChange, baseline[3], baselineIndexes[3]));
            digest.addError(session.store().clearObjectStore(versionChange, baseline[4]));
            digest.addError(session.store().deleteObjectStore(versionChange, baseline[0]));
            digest.addError(session.store().deleteObjectStore(versionChange, created[3]));
            session.abort(digest, versionChange);
            session.info = WTF::move(saved);
            for (auto objectStore : baseline)
                digest.addInteger(!!session.store().infoForObjectStore(objectStore));
            for (auto objectStore : created)
                digest.addInteger(!!session.store().infoForObjectStore(objectStore));
        }
        excluded.measure([&] {
            session.close();
        });
        return bytes;
    });
}

TEST(IDBBackingStoreBench, SQLiteMemoryPutGetCursor)
{
    run("SQLiteMemoryPutGetCursor"_s, Recorded::sqliteMemoryPutGetCursor, [](Digest& digest, Excluded& excluded) {
        return putGetCursor(StoreKind::SQLiteMemory, digest, excluded);
    });
}

// A scripted sequence shaped like PerformanceTests/IndexedDB/basic (objectstore-add, -get, -cursor with
// continue, advance, delete and update, index-get, index-multientry, -count, -clear).
TEST(IDBBackingStoreBench, RealisticMix)
{
    run("RealisticMix"_s, Recorded::realisticMix, [](Digest& digest, Excluded& excluded) {
        size_t bytes = 0;
        TemporaryDirectory* directory = nullptr;
        excluded.measure([&] {
            directory = new TemporaryDirectory;
        });
        Session session(StoreKind::SQLiteFile, directory->path());
        session.open(digest);
        Vector<IndexSpec> indexes;
        auto objectStore = prepare(session, digest, excluded, { false, true }, indexes, 0);
        Random random(21);
        unsigned nextKey = 0;
        for (unsigned round = 0; round < 12; ++round) {
            // One read-write transaction per round, as a page's transaction would be.
            auto transaction = session.begin(digest, IDBTransactionMode::Readwrite, { "bench"_s });
            // objectstore-add
            for (unsigned i = 0; i < 100; ++i, ++nextKey) {
                IndexIDToIndexKeyMap indexKeys;
                for (auto& spec : indexes)
                    indexKeys.add(spec.identifier, indexKeyFor(spec, nextKey));
                auto value = makeValue(nextKey, 48 + random.below(200));
                session.put(digest, transaction, objectStore, numberKey(nextKey), indexKeys, value);
                bytes += 8 + valueSize(value);
            }
            // objectstore-get
            for (unsigned i = 0; i < 60; ++i) {
                session.get(digest, transaction, objectStore, numberKey(random.below(nextKey)));
                bytes += 8 + 100;
            }
            // index-get
            for (unsigned i = 0; i < 20; ++i) {
                session.getIndex(digest, transaction, objectStore, indexes[0].identifier, numberKey(random.below(1009)));
                bytes += 8 + 100;
            }
            session.count(digest, transaction, objectStore, IDBKeyRangeData::allKeys()); // objectstore-count
            unsigned from = random.below(nextKey);
            auto cursor = session.objectStoreCursor(transaction, objectStore, rangeOf(numberKey(from), numberKey(nextKey)), IndexedDB::CursorDirection::Next);
            unsigned seen = 0;
            session.drainCursor(digest, transaction, cursor, [&](const IDBKeyData& key, const IDBKeyData&, const IDBValue& value) { // cursor-continue, -update, -delete
                bytes += 8 + valueSize(value);
                ++seen;
                if (!(seen % 7)) {
                    IndexIDToIndexKeyMap indexKeys;
                    for (auto& spec : indexes)
                        indexKeys.add(spec.identifier, indexKeyFor(spec, static_cast<unsigned>(key.number())));
                    session.put(digest, transaction, objectStore, key, indexKeys, makeValue(seen, 64));
                    return true;
                }
                if (!(seen % 11)) {
                    session.deleteRange(digest, transaction, objectStore, exactly(key));
                    return true;
                }
                return false;
            }, 150, seen % 3 + 1); // cursor-advance steps
            auto indexCursor = session.indexCursor(transaction, objectStore, indexes[1].identifier, rangeOf(numberKey(0), numberKey(50)), IndexedDB::CursorDirection::Next); // index-multientry
            session.drainCursor(digest, transaction, indexCursor, [&](const IDBKeyData&, const IDBKeyData&, const IDBValue& value) {
                bytes += 16 + valueSize(value);
                return false;
            }, 100);
            if (round % 5 == 4) // objectstore-clear
                digest.addError(session.store().clearObjectStore(transaction, objectStore));
            session.commit(digest, transaction);
        }
        excluded.measure([&] {
            session.close();
            delete directory;
        });
        return bytes;
    });
}

} // namespace TestWebKitAPI
