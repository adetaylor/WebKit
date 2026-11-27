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

// Speed of IndexedDB's server, one test per workload, through IDBServer's entry points (the ones WebKitLegacy's
// InProcessIDBServer and the network process's storage manager call) with a client that plays the web process:
// no page, no script, no IPC. The tests name no server class beyond IDBServer and the delegate interface.
//
// Each pass makes a fresh server (a fresh temporary directory for the file store), runs the workload with
// deterministic inputs, and feeds every callback the server makes (the results, errors, events and quota requests,
// in order) to an FNV-1a digest. A pass runs on both stores the server can make: the SQLite store on disk and the
// in-memory store (a transient database). By default a test runs one pass and EXPECT_EQs the digest against the
// workload's expected checksum, so a mismatch means the server's behaviour changed. With WEBKIT_RUN_BENCHMARKS set
// it then repeats the pass until its timed part has taken at least a second (at least three passes), checks every
// pass's digest, and prints
//     <Test>: <ms> ms <n> MB/s checksum=<digest>
// where <ms> is the timed total and <n> counts the key and value bytes the timed operations carried.
// Set-up and tear-down inside a pass (making the directory, filling a store a read workload reads, deleting the
// files) is measured and left out of the time.
//
// The server and its stores run on a WTF::Thread: IDBServer's constructor and destructor assert they are not on the
// main thread. The server completes every quota check synchronously (its space requester returns a bool), so the
// tests deny a request at the points they choose and grant the next one.

#include "config.h"

#include "IDBBackingStoreTestSupport.h"
#include <WebCore/ClientOrigin.h>
#include <WebCore/IDBConnectionToClientDelegate.h>
#include <WebCore/IDBCursorInfo.h>
#include <WebCore/IDBDatabaseConnectionIdentifier.h>
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
#include <WebCore/IDBOpenRequestData.h>
#include <WebCore/IDBRequestData.h>
#include <WebCore/IDBResourceIdentifier.h>
#include <WebCore/IDBResultData.h>
#include <WebCore/IDBServer.h>
#include <WebCore/IDBTransactionDurability.h>
#include <WebCore/IDBTransactionInfo.h>
#include <WebCore/IDBTransactionMode.h>
#include <WebCore/IDBValue.h>
#include <WebCore/IndexKey.h>
#include <WebCore/IndexedDB.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/ThreadSafeDataBuffer.h>
#include <algorithm>
#include <atomic>
#include <bit>
#include <cstdio>
#include <cstdlib>
#if OS(DARWIN)
#include <libproc.h>
#include <unistd.h>
#endif
#include <wtf/FileSystem.h>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Seconds.h>
#include <wtf/Threading.h>
#include <wtf/Vector.h>
#include <wtf/WallTime.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

// A web process's requests are built by the IPC decoders, which are friends of the request classes and the only
// callers of their private constructors. The tests have no web process, so they stand in for the decoders.
namespace IPC {

template<> struct ArgumentCoder<WebCore::IDBRequestData> {
    static WebCore::IDBRequestData make(WebCore::IDBConnectionIdentifier connection, WebCore::IDBResourceIdentifier request, WebCore::IDBResourceIdentifier transaction, std::optional<WebCore::IDBResourceIdentifier>&& cursor, std::optional<WebCore::IDBObjectStoreIdentifier> objectStore, std::optional<WebCore::IDBIndexIdentifier> index, WebCore::IndexedDB::IndexRecordType indexRecordType)
    {
        return WebCore::IDBRequestData { connection, request, transaction, WTF::move(cursor), objectStore, index, indexRecordType, 0, WebCore::IndexedDB::RequestType::Other };
    }
};

template<> struct ArgumentCoder<WebCore::IDBOpenRequestData> {
    static WebCore::IDBOpenRequestData make(WebCore::IDBConnectionIdentifier connection, WebCore::IDBResourceIdentifier request, WebCore::IDBDatabaseIdentifier&& database, uint64_t version, WebCore::IndexedDB::RequestType type)
    {
        return WebCore::IDBOpenRequestData { connection, request, WTF::move(database), version, type };
    }
};

// IDBResultData::databaseInfo and transactionInfo are not exported from WebCore; the coder is the class's friend.
template<> struct ArgumentCoder<WebCore::IDBResultData> {
    static const WebCore::IDBDatabaseInfo& databaseInfo(const WebCore::IDBResultData& result) { return *result.m_databaseInfo; }
    static const WebCore::IDBTransactionInfo& transactionInfo(const WebCore::IDBResultData& result) { return *result.m_transactionInfo; }
    static bool hasGetResult(const WebCore::IDBResultData& result) { return !!result.m_getResult; }
};

} // namespace IPC

namespace TestWebKitAPI {

using namespace WebCore;
using namespace WebCore::IDBServer;
using Server = WebCore::IDBServer::IDBServer;

namespace IDBServerBenchmark {

using namespace IDBBenchmarkSupport;

// Each workload's expected checksum. A mismatch fails the test and prints
// "<Test>: checksum=<digest> (recorded <value>)".
namespace Recorded {
constexpr uint64_t openUpgradeClose = 0xdbda49cee062f1f8ull;
constexpr uint64_t putSmallRecordsOneTransaction = 0xddac745ff3515b24ull;
constexpr uint64_t manySmallTransactions = 0xee4a049b78367720ull;
constexpr uint64_t getByKey = 0xd04148e59b4e03e8ull;
constexpr uint64_t cursorIterate = 0xb99a7895a81bf7ddull;
constexpr uint64_t cursorVariants = 0x09969040d11268f4ull;
constexpr uint64_t concurrentReadOnly = 0x25ecf8894bd5a1f8ull;
constexpr uint64_t versionChangeWithOpenConnections = 0x7173442b0c508e24ull;
constexpr uint64_t realisticMix = 0x66a4dd9fef74a093ull;
constexpr uint64_t recordOperations = 0xc5594e93ccfc38c5ull;
constexpr uint64_t schemaChanges = 0x060d6bdec232a46cull;
constexpr uint64_t errorPaths = 0xd282136b111dc879ull;
constexpr uint64_t quotaDeniedThenGranted = 0xeb4bc1dd0a56c0fbull;
constexpr uint64_t abortPaths = 0x9d84dd46fb823b19ull;
constexpr uint64_t deleteDatabase = 0x690a8921172f67a6ull;
constexpr uint64_t closeWithPending = 0xfe57a2319f3ccec1ull;
constexpr uint64_t clientSuspension = 0x1aecd0effd23dad4ull;
constexpr uint64_t originOperations = 0xca84304050683dd2ull;
}

// The two stores the server makes: the SQLite store in the directory it is given, and the in-memory store, which
// it makes for a transient database.
enum class StoreKind { SQLiteFile, Memory };

class Client;

// One server and the clients of it. Every callback a client receives, and every quota request, goes into the digest.
class World {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(World);

public:
    World(StoreKind, Digest&, const String& directory);
    ~World();

    Client& addClient(bool registered = true);
    void removeClient(Client&);

    Server& server() { return *m_server; }
    Digest& digest() { return m_digest; }
    StoreKind kind() const { return m_kind; }
    const String& directory() const { return m_directory; }

    IDBDatabaseIdentifier databaseIdentifier(const String& name, const String& host = "bench.example"_s) const
    {
        return { name, SecurityOriginData { "https"_s, host, std::nullopt }, SecurityOriginData { "https"_s, host, std::nullopt }, m_kind == StoreKind::Memory };
    }

    // The next `count` quota requests are denied; the ones after them are granted.
    void denyNext(unsigned count) { m_denials = count; }

    uint64_t ordinal(const IDBResourceIdentifier& identifier)
    {
        auto result = m_resourceOrdinals.add(identifier, m_resourceOrdinals.size() + 1);
        return result.iterator->value;
    }

    uint64_t ordinal(IDBDatabaseConnectionIdentifier identifier)
    {
        auto result = m_connectionOrdinals.add(identifier.toUInt64(), m_connectionOrdinals.size() + 1);
        return result.iterator->value;
    }

private:
    bool requestSpace(uint64_t size)
    {
        bool granted = true;
        if (m_denials) {
            --m_denials;
            granted = false;
        }
        m_digest.addInteger(size);
        m_digest.addInteger(granted);
        return granted;
    }

    StoreKind m_kind;
    Digest& m_digest;
    String m_directory;
    unsigned m_denials { 0 };
    HashMap<IDBResourceIdentifier, uint64_t> m_resourceOrdinals;
    HashMap<uint64_t, uint64_t> m_connectionOrdinals;
    std::unique_ptr<Server> m_server;
    Vector<std::unique_ptr<Client>> m_clients;
};

// The client's view of a database connection the server opened for it, and of one of its transactions.
struct Db {
    IDBDatabaseConnectionIdentifier connection;
    IDBDatabaseInfo info;
};

struct Transaction {
    IDBResourceIdentifier identifier;
    unsigned handled { 0 }; // The results of its requests that the client has received.
};

struct Cursor {
    IDBResourceIdentifier identifier;
    IDBObjectStoreIdentifier objectStore;
    std::optional<IDBIndexIdentifier> index;
};

// The web process of the in-process server: a delegate that counts and digests what the server sends it, remembers
// what a script needs to answer, and the requests a web process makes.
class Client final : public IDBConnectionToClientDelegate {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(Client);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(Client);

public:
    enum class Event : uint8_t {
        DeleteDatabase,
        OpenDatabase,
        AbortTransaction,
        CommitTransaction,
        CreateObjectStore,
        DeleteObjectStore,
        RenameObjectStore,
        ClearObjectStore,
        CreateIndex,
        DeleteIndex,
        RenameIndex,
        PutOrAdd,
        GetRecord,
        GetAllRecords,
        GetCount,
        DeleteRecord,
        OpenCursor,
        IterateCursor,
        VersionChange,
        GenerateIndexKey,
        StartTransaction,
        CloseFromServer,
        Blocked,
        DatabaseNames,
    };

    struct Opened {
        IDBResultType type;
        std::optional<IDBDatabaseConnectionIdentifier> connection;
        std::optional<IDBResourceIdentifier> transaction;
        std::optional<IDBDatabaseInfo> info;
        std::optional<ExceptionCode> error;
    };

    struct VersionChange {
        IDBDatabaseConnectionIdentifier connection;
        IDBResourceIdentifier request;
        uint64_t version { 0 };
    };

    struct IndexKeyRequest {
        IDBResourceIdentifier request;
        IDBIndexInfo index;
        IDBKeyData key;
        std::optional<int64_t> recordID;
    };

    Client(World& world)
        : m_world(world)
    {
    }

    unsigned callbackCount() const { return m_callbackCount; }

    // What the server sent, for the script to answer.
    std::optional<Opened> takeOpened()
    {
        auto result = WTF::move(m_opened);
        m_opened = std::nullopt;
        return result;
    }
    unsigned takeDeleted() { return std::exchange(m_deleted, 0); }
    Vector<VersionChange> takeVersionChanges() { return std::exchange(m_versionChanges, { }); }
    Vector<IDBDatabaseConnectionIdentifier> takeClosedByServer() { return std::exchange(m_closedByServer, { }); }
    unsigned takeBlocked() { return std::exchange(m_blocked, 0); }
    std::optional<IDBResultType> lastType() const { return m_lastType; }
    std::optional<IDBGetResult> takeGetResult()
    {
        auto result = WTF::move(m_lastGet);
        m_lastGet = std::nullopt;
        return result;
    }
    bool started(const Transaction& transaction) const { return m_started.contains(transaction.identifier); }

    // The requests of a web process.

    IDBResourceIdentifier open(const IDBDatabaseIdentifier& database, uint64_t version)
    {
        auto request = newResource();
        m_world.server().openDatabase(openData(database, version, request, IndexedDB::RequestType::Open));
        return request;
    }

    IDBResourceIdentifier deleteDatabase(const IDBDatabaseIdentifier& database)
    {
        auto request = newResource();
        m_world.server().deleteDatabase(openData(database, 0, request, IndexedDB::RequestType::Delete));
        return request;
    }

    void cancelOpen(const IDBDatabaseIdentifier& database, uint64_t version, const IDBResourceIdentifier& request)
    {
        m_world.server().openDBRequestCancelled(openData(database, version, request, IndexedDB::RequestType::Open));
    }

    void answerVersionChange(const VersionChange& change, IndexedDB::ConnectionClosedOnBehalfOfServer closed)
    {
        m_world.server().didFireVersionChangeEvent(change.connection, change.request, closed);
    }

    void pendingClose(const Db& db) { m_world.server().databaseConnectionPendingClose(db.connection); }
    void close(const Db& db) { m_world.server().databaseConnectionClosed(db.connection); }
    void abortOpenAndUpgradeNeeded(const Db& db, const Transaction& transaction) { m_world.server().abortOpenAndUpgradeNeeded(db.connection, transaction.identifier); }
    void abortOpenAndUpgradeNeeded(const Db& db) { m_world.server().abortOpenAndUpgradeNeeded(db.connection, std::nullopt); }

    Transaction begin(const Db& db, IDBTransactionMode mode, Vector<String>&& objectStores)
    {
        auto identifier = newResource();
        IDBTransactionInfo info { identifier, mode, IDBTransactionDurability::Default, 0, WTF::move(objectStores), nullptr };
        m_world.server().establishTransaction(db.connection, info);
        return { identifier, 0 };
    }

    // Commits with `unhandled` of its results not yet seen by the page; the server aborts a transaction with one that failed.
    void commit(const Transaction& transaction, unsigned unhandled = 0) { m_world.server().commitTransaction(transaction.identifier, transaction.handled - unhandled); }
    void abort(const Transaction& transaction) { m_world.server().abortTransaction(transaction.identifier); }
    void finishVersionChange(const Db& db, const Transaction& transaction) { m_world.server().didFinishHandlingVersionChangeTransaction(db.connection, transaction.identifier); }

    // Schema changes, in a version-change transaction.
    IDBObjectStoreInfo createObjectStore(Db& db, const Transaction& transaction, const String& name, std::optional<IDBKeyPath>&& keyPath = std::nullopt, bool autoIncrement = false)
    {
        auto info = db.info.createNewObjectStore(name, WTF::move(keyPath), autoIncrement);
        m_world.server().createObjectStore(request(transaction), info);
        return info;
    }

    void deleteObjectStore(const Transaction& transaction, const String& name) { m_world.server().deleteObjectStore(request(transaction), name); }
    void renameObjectStore(const Transaction& transaction, IDBObjectStoreIdentifier objectStore, const String& name) { m_world.server().renameObjectStore(request(transaction, objectStore), objectStore, name); }
    void clearObjectStore(const Transaction& transaction, IDBObjectStoreIdentifier objectStore) { m_world.server().clearObjectStore(request(transaction, objectStore), objectStore); }

    // Answers the server's requests for index keys of the records the index covers, as the web process would.
    IDBIndexIdentifier createIndex(Db& db, const Transaction& transaction, IDBObjectStoreIdentifier objectStore, const String& name, bool unique, bool multiEntry)
    {
        auto* objectStoreInfo = db.info.infoForExistingObjectStore(objectStore);
        RELEASE_ASSERT(objectStoreInfo);
        auto indexInfo = objectStoreInfo->createNewIndex(db.info.generateNextIndexID(), name, IDBKeyPath { String { "key"_s } }, unique, multiEntry);
        m_world.server().createIndex(request(transaction, objectStore), indexInfo);
        answerIndexKeys(transaction, multiEntry);
        return indexInfo.identifier();
    }

    void deleteIndex(const Transaction& transaction, IDBObjectStoreIdentifier objectStore, const String& name) { m_world.server().deleteIndex(request(transaction, objectStore), objectStore, name); }
    void renameIndex(const Transaction& transaction, IDBObjectStoreIdentifier objectStore, IDBIndexIdentifier index, const String& name) { m_world.server().renameIndex(request(transaction, objectStore), objectStore, index, name); }

    // Records.
    void put(Transaction& transaction, IDBObjectStoreIdentifier objectStore, const IDBKeyData& key, const IndexIDToIndexKeyMap& indexKeys, const IDBValue& value, IndexedDB::ObjectStoreOverwriteMode mode = IndexedDB::ObjectStoreOverwriteMode::Overwrite)
    {
        counted(transaction, [&] {
            m_world.server().putOrAdd(request(transaction, objectStore), key, value, indexKeys, mode);
        });
    }

    void get(Transaction& transaction, IDBObjectStoreIdentifier objectStore, const IDBKeyRangeData& range, IDBGetRecordDataType type = IDBGetRecordDataType::KeyAndValue)
    {
        counted(transaction, [&] {
            m_world.server().getRecord(request(transaction, objectStore), IDBGetRecordData { range, type });
        });
    }

    void getIndex(Transaction& transaction, IDBObjectStoreIdentifier objectStore, IDBIndexIdentifier index, const IDBKeyRangeData& range, IndexedDB::IndexRecordType recordType)
    {
        counted(transaction, [&] {
            m_world.server().getRecord(request(transaction, objectStore, index, std::nullopt, recordType), IDBGetRecordData { range, IDBGetRecordDataType::KeyAndValue });
        });
    }

    void getAll(Transaction& transaction, IDBObjectStoreIdentifier objectStore, std::optional<IDBIndexIdentifier> index, const IDBKeyRangeData& range, IndexedDB::GetAllType type, std::optional<uint32_t> count = std::nullopt, IndexedDB::CursorDirection direction = IndexedDB::CursorDirection::Next)
    {
        counted(transaction, [&] {
            m_world.server().getAllRecords(request(transaction, objectStore, index), IDBGetAllRecordsData { range, type, count, direction, objectStore, index });
        });
    }

    void count(Transaction& transaction, IDBObjectStoreIdentifier objectStore, std::optional<IDBIndexIdentifier> index, const IDBKeyRangeData& range)
    {
        counted(transaction, [&] {
            m_world.server().getCount(request(transaction, objectStore, index), range);
        });
    }

    void deleteRecord(Transaction& transaction, IDBObjectStoreIdentifier objectStore, const IDBKeyRangeData& range)
    {
        counted(transaction, [&] {
            m_world.server().deleteRecord(request(transaction, objectStore), range);
        });
    }

    Cursor openCursor(Transaction& transaction, IDBObjectStoreIdentifier objectStore, std::optional<IDBIndexIdentifier> index, const IDBKeyRangeData& range, IndexedDB::CursorDirection direction)
    {
        Cursor cursor { newResource(), objectStore, index };
        auto info = IDBCursorInfo::forBackingStore(cursor.identifier, transaction.identifier, objectStore, index, range, direction, IndexedDB::CursorType::KeyAndValue);
        m_lastGet = std::nullopt;
        counted(transaction, [&] {
            m_world.server().openCursor(request(transaction, objectStore, index, cursor.identifier), info);
        });
        return cursor;
    }

    void iterateCursor(Transaction& transaction, const Cursor& cursor, const IDBKeyData& key, const IDBKeyData& primaryKey, unsigned count, IndexedDB::CursorIterateOption option = IndexedDB::CursorIterateOption::Reply)
    {
        m_lastGet = std::nullopt;
        counted(transaction, [&] {
            m_world.server().iterateCursor(request(transaction, cursor.objectStore, cursor.index, cursor.identifier), IDBIterateCursorData { key, primaryKey, count, option });
        });
    }

    // Walks a cursor the way IDBCursor::continue() does: the records the server prefetched are consumed without
    // calling it (until a write by this transaction, which `onRecord` reports by returning true, makes them stale);
    // otherwise the next step is iterateCursor(count). Returns the records visited.
    template<typename OnRecord>
    size_t drainCursor(Transaction& transaction, const Cursor& cursor, const IDBKeyRangeData& range, IndexedDB::CursorDirection direction, OnRecord&& onRecord, size_t limit = SIZE_MAX, unsigned step = 1)
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
        UNUSED_PARAM(range);
        UNUSED_PARAM(direction);

        auto first = takeGetResult();
        if (!first)
            return 0;
        IDBGetResult current = WTF::move(*first);
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
                continue;
            }
            iterateCursor(transaction, cursor, { }, { }, step);
            auto next = takeGetResult();
            if (!next)
                break;
            absorb(*next);
            current = WTF::move(*next);
        }
        m_world.digest().addInteger(visited);
        return visited;
    }

    void setSuspended(bool suspended) { m_world.server().setClientSuspended(*m_identifier, suspended); }

    // IDBConnectionToClientDelegate.

    std::optional<IDBConnectionIdentifier> identifier() const final { return m_identifier; }

    void didDeleteDatabase(const IDBResultData& result) final
    {
        note(Event::DeleteDatabase, result);
        ++m_deleted;
    }

    void didOpenDatabase(const IDBResultData& result) final
    {
        note(Event::OpenDatabase, result);
        Opened opened { result.type(), std::nullopt, std::nullopt, std::nullopt, std::nullopt };
        switch (result.type()) {
        case IDBResultType::OpenDatabaseSuccess:
        case IDBResultType::OpenDatabaseUpgradeNeeded:
            opened.connection = result.databaseConnectionIdentifier();
            opened.info.emplace(IPC::ArgumentCoder<IDBResultData>::databaseInfo(result));
            if (result.type() == IDBResultType::OpenDatabaseUpgradeNeeded)
                opened.transaction = IPC::ArgumentCoder<IDBResultData>::transactionInfo(result).identifier();
            break;
        case IDBResultType::Error:
            opened.error = result.error().code();
            break;
        default:
            break;
        }
        m_opened = WTF::move(opened);
    }

    void didAbortTransaction(const IDBResourceIdentifier& transaction, const IDBError& error) final { noteTransaction(Event::AbortTransaction, transaction, error); }
    void didCommitTransaction(const IDBResourceIdentifier& transaction, const IDBError& error) final { noteTransaction(Event::CommitTransaction, transaction, error); }
    void didStartTransaction(const IDBResourceIdentifier& transaction, const IDBError& error) final
    {
        noteTransaction(Event::StartTransaction, transaction, error);
        m_started.add(transaction);
    }
    void didCreateObjectStore(const IDBResultData& result) final { note(Event::CreateObjectStore, result); }
    void didDeleteObjectStore(const IDBResultData& result) final { note(Event::DeleteObjectStore, result); }
    void didRenameObjectStore(const IDBResultData& result) final { note(Event::RenameObjectStore, result); }
    void didClearObjectStore(const IDBResultData& result) final { note(Event::ClearObjectStore, result); }
    void didCreateIndex(const IDBResultData& result) final { note(Event::CreateIndex, result); }
    void didDeleteIndex(const IDBResultData& result) final { note(Event::DeleteIndex, result); }
    void didRenameIndex(const IDBResultData& result) final { note(Event::RenameIndex, result); }
    void didPutOrAdd(const IDBResultData& result) final { noteData(Event::PutOrAdd, result); }
    void didGetRecord(const IDBResultData& result) final { noteData(Event::GetRecord, result); }
    void didGetAllRecords(const IDBResultData& result) final { noteData(Event::GetAllRecords, result); }
    void didGetCount(const IDBResultData& result) final { noteData(Event::GetCount, result); }
    void didDeleteRecord(const IDBResultData& result) final { noteData(Event::DeleteRecord, result); }
    void didOpenCursor(const IDBResultData& result) final { noteData(Event::OpenCursor, result); }
    void didIterateCursor(const IDBResultData& result) final { noteData(Event::IterateCursor, result); }

    void fireVersionChangeEvent(IDBDatabaseConnectionIdentifier connection, const IDBResourceIdentifier& request, uint64_t version) final
    {
        ++m_callbackCount;
        auto& digest = m_world.digest();
        digest.addInteger(static_cast<uint64_t>(Event::VersionChange));
        digest.addInteger(m_world.ordinal(connection));
        digest.addInteger(m_world.ordinal(request));
        digest.addInteger(version);
        m_versionChanges.append({ connection, request, version });
    }

    void generateIndexKeyForRecord(const IDBResourceIdentifier& request, const IDBIndexInfo& index, const std::optional<IDBKeyPath>&, const IDBKeyData& key, const IDBValue& value, std::optional<int64_t> recordID) final
    {
        ++m_callbackCount;
        auto& digest = m_world.digest();
        digest.addInteger(static_cast<uint64_t>(Event::GenerateIndexKey));
        digest.addInteger(m_world.ordinal(request));
        digest.addString(index.name());
        digest.addRecord(key, key, value);
        digest.addInteger(recordID ? static_cast<uint64_t>(*recordID) + 1 : 0);
        m_indexKeyRequests.append({ request, index, key, recordID });
    }

    void didCloseFromServer(IDBDatabaseConnectionIdentifier connection, const IDBError& error) final
    {
        ++m_callbackCount;
        auto& digest = m_world.digest();
        digest.addInteger(static_cast<uint64_t>(Event::CloseFromServer));
        digest.addInteger(m_world.ordinal(connection));
        digest.addError(error);
        m_closedByServer.append(connection);
    }

    void notifyOpenDBRequestBlocked(const IDBResourceIdentifier& request, uint64_t oldVersion, uint64_t newVersion) final
    {
        ++m_callbackCount;
        ++m_blocked;
        auto& digest = m_world.digest();
        digest.addInteger(static_cast<uint64_t>(Event::Blocked));
        digest.addInteger(m_world.ordinal(request));
        digest.addInteger(oldVersion);
        digest.addInteger(newVersion);
    }

    void didGetAllDatabaseNamesAndVersions(const IDBResourceIdentifier& request, Vector<IDBDatabaseNameAndVersion>&& databases) final
    {
        ++m_callbackCount;
        auto& digest = m_world.digest();
        digest.addInteger(static_cast<uint64_t>(Event::DatabaseNames));
        digest.addInteger(m_world.ordinal(request));
        std::sort(databases.begin(), databases.end(), [](auto& a, auto& b) {
            return codePointCompareLessThan(a.name, b.name);
        });
        digest.addInteger(databases.size());
        for (auto& database : databases) {
            digest.addString(database.name);
            digest.addInteger(database.version);
        }
    }

    IDBResourceIdentifier newResource() { return IDBResourceIdentifier { *m_identifier }; }

private:
    IDBOpenRequestData openData(const IDBDatabaseIdentifier& database, uint64_t version, const IDBResourceIdentifier& request, IndexedDB::RequestType type)
    {
        IDBDatabaseIdentifier copy = database;
        return IPC::ArgumentCoder<IDBOpenRequestData>::make(*m_identifier, request, WTF::move(copy), version, type);
    }

    IDBRequestData request(const Transaction& transaction, std::optional<IDBObjectStoreIdentifier> objectStore = std::nullopt, std::optional<IDBIndexIdentifier> index = std::nullopt, std::optional<IDBResourceIdentifier> cursor = std::nullopt, IndexedDB::IndexRecordType recordType = IndexedDB::IndexRecordType::Key)
    {
        return IPC::ArgumentCoder<IDBRequestData>::make(*m_identifier, newResource(), transaction.identifier, WTF::move(cursor), objectStore, index, recordType);
    }

    // Runs a request of `transaction` that gets a result, and counts the result as one the page has handled.
    template<typename Function>
    void counted(Transaction& transaction, Function&& function)
    {
        unsigned before = m_dataResults;
        function();
        if (m_dataResults != before)
            ++transaction.handled;
    }

    void answerIndexKeys(const Transaction& transaction, bool multiEntry)
    {
        while (!m_indexKeyRequests.isEmpty()) {
            auto requests = std::exchange(m_indexKeyRequests, { });
            for (auto& pending : requests) {
                unsigned i = static_cast<unsigned>(pending.key.number());
                IndexSpec spec { pending.index.identifier(), multiEntry };
                m_world.server().didGenerateIndexKeyForRecord(transaction.identifier, pending.request, pending.index, pending.key, indexKeyFor(spec, i), pending.recordID);
            }
        }
    }

    void note(Event event, const IDBResultData& result)
    {
        ++m_callbackCount;
        auto& digest = m_world.digest();
        digest.addInteger(static_cast<uint64_t>(event));
        digest.addInteger(m_world.ordinal(result.requestIdentifier()));
        digest.addInteger(static_cast<uint64_t>(result.type()));
        m_lastType = result.type();
        switch (result.type()) {
        case IDBResultType::Error:
            digest.addError(result.error());
            break;
        case IDBResultType::OpenDatabaseUpgradeNeeded:
            digest.addInteger(m_world.ordinal(IPC::ArgumentCoder<IDBResultData>::transactionInfo(result).identifier()));
            digest.addInteger(static_cast<uint64_t>(IPC::ArgumentCoder<IDBResultData>::transactionInfo(result).mode()));
            digest.addInteger(IPC::ArgumentCoder<IDBResultData>::transactionInfo(result).newVersion());
            [[fallthrough]];
        case IDBResultType::OpenDatabaseSuccess:
            digest.addInteger(m_world.ordinal(result.databaseConnectionIdentifier()));
            digest.addDatabaseInfo(IPC::ArgumentCoder<IDBResultData>::databaseInfo(result));
            break;
        case IDBResultType::DeleteDatabaseSuccess:
            digest.addDatabaseInfo(IPC::ArgumentCoder<IDBResultData>::databaseInfo(result));
            break;
        case IDBResultType::PutOrAddSuccess:
            if (auto* key = result.resultKey())
                digest.addKey(*key);
            break;
        case IDBResultType::GetRecordSuccess:
        case IDBResultType::OpenCursorSuccess:
        case IDBResultType::IterateCursorSuccess:
            // The server answers a count as a GetRecordSuccess with no record, only an integer.
            if (!IPC::ArgumentCoder<IDBResultData>::hasGetResult(result)) {
                digest.addInteger(result.resultInteger());
                break;
            }
            digest.addGetResult(result.getResult());
            m_lastGet = result.getResult();
            break;
        case IDBResultType::GetAllRecordsSuccess:
            digest.addGetAllResult(result.getAllResult());
            break;
        case IDBResultType::GetCountSuccess:
            digest.addInteger(result.resultInteger());
            break;
        default:
            break;
        }
    }

    void noteData(Event event, const IDBResultData& result)
    {
        ++m_dataResults;
        note(event, result);
    }

    void noteTransaction(Event event, const IDBResourceIdentifier& transaction, const IDBError& error)
    {
        ++m_callbackCount;
        auto& digest = m_world.digest();
        digest.addInteger(static_cast<uint64_t>(event));
        digest.addInteger(m_world.ordinal(transaction));
        digest.addError(error);
    }

public:
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

private:
    // Process::generateIdentifier() asserts it runs on the UI thread in Debug; the server thread has its own counter.
    static IDBConnectionIdentifier nextIdentifier()
    {
        static std::atomic<uint64_t> next { 1000 };
        return IDBConnectionIdentifier(next.fetch_add(1));
    }

    World& m_world;
    std::optional<IDBConnectionIdentifier> m_identifier { nextIdentifier() };
    unsigned m_callbackCount { 0 };
    unsigned m_dataResults { 0 };
    unsigned m_deleted { 0 };
    unsigned m_blocked { 0 };
    std::optional<Opened> m_opened;
    std::optional<IDBResultType> m_lastType;
    std::optional<IDBGetResult> m_lastGet;
    Vector<VersionChange> m_versionChanges;
    Vector<IndexKeyRequest> m_indexKeyRequests;
    Vector<IDBDatabaseConnectionIdentifier> m_closedByServer;
    HashSet<IDBResourceIdentifier> m_started;
    bool m_registered { true };

    friend class World;
};

World::World(StoreKind kind, Digest& digest, const String& directory)
    : m_kind(kind)
    , m_digest(digest)
    , m_directory(directory)
{
    m_server = makeUnique<Server>(directory.isolatedCopy(), [this](const ClientOrigin&, uint64_t size) {
        return requestSpace(size);
    });
}

World::~World()
{
    for (auto& client : m_clients) {
        if (client->m_registered)
            m_server->unregisterConnection(*client->identifier());
    }
    m_server = nullptr;
}

Client& World::addClient(bool registered)
{
    m_clients.append(makeUnique<Client>(*this));
    auto& client = *m_clients.last();
    client.m_registered = registered;
    if (registered)
        m_server->registerConnection(client);
    return client;
}

// The web process goes away: the server closes its connections and drops its transactions and requests.
void World::removeClient(Client& client)
{
    RELEASE_ASSERT(client.m_registered);
    client.m_registered = false;
    m_server->unregisterConnection(*client.identifier());
}

// Scripts.

// Runs `body` with a fresh server on each of the two stores, in a fresh directory, and adds up its bytes.
template<typename Body>
static size_t onBothStores(Digest& digest, Excluded& excluded, Body&& body)
{
    size_t bytes = 0;
    for (auto kind : { StoreKind::SQLiteFile, StoreKind::Memory }) {
        std::unique_ptr<TemporaryDirectory> directory;
        excluded.measure([&] {
            directory = makeUnique<TemporaryDirectory>();
        });
        digest.addInteger(static_cast<uint64_t>(kind));
        auto world = makeUnique<World>(kind, digest, directory->path());
        bytes += body(*world, excluded);
        excluded.measure([&] {
            world = nullptr;
            directory = nullptr;
        });
    }
    return bytes;
}

struct Upgrade {
    Db db;
    Transaction transaction;
};

// Opens the database at a version that needs an upgrade; the version-change transaction is the upgrade's.
static std::optional<Upgrade> openForUpgrade(Client& client, World& world, const String& name, uint64_t version, const String& host = "bench.example"_s)
{
    client.open(world.databaseIdentifier(name, host), version);
    auto opened = client.takeOpened();
    if (!opened || opened->type != IDBResultType::OpenDatabaseUpgradeNeeded)
        return std::nullopt;
    return Upgrade { Db { *opened->connection, WTF::move(*opened->info) }, Transaction { *opened->transaction, 0 } };
}

static std::optional<Db> openConnection(Client& client, World& world, const String& name, uint64_t version, const String& host = "bench.example"_s)
{
    client.open(world.databaseIdentifier(name, host), version);
    auto opened = client.takeOpened();
    if (!opened || opened->type != IDBResultType::OpenDatabaseSuccess)
        return std::nullopt;
    return Db { *opened->connection, WTF::move(*opened->info) };
}

static void commitUpgrade(Client& client, Upgrade& upgrade)
{
    client.commit(upgrade.transaction);
    client.finishVersionChange(upgrade.db, upgrade.transaction);
}

struct Schema {
    IDBObjectStoreIdentifier objectStore;
    Vector<IndexSpec> indexes;
};

// One object store with the given indexes, in the upgrade's transaction.
static Schema createSchema(Client& client, Upgrade& upgrade, const String& name, std::initializer_list<bool> multiEntryFlags, bool autoIncrement = false)
{
    auto objectStore = client.createObjectStore(upgrade.db, upgrade.transaction, name, std::nullopt, autoIncrement);
    Schema schema { objectStore.identifier(), { } };
    unsigned number = 0;
    for (bool multiEntry : multiEntryFlags) {
        auto index = client.createIndex(upgrade.db, upgrade.transaction, schema.objectStore, makeString("index"_s, number++), false, multiEntry);
        schema.indexes.append({ index, multiEntry });
    }
    return schema;
}

static IndexIDToIndexKeyMap indexKeysFor(const Schema& schema, unsigned i)
{
    IndexIDToIndexKeyMap indexKeys;
    for (auto& spec : schema.indexes)
        indexKeys.add(spec.identifier, Client::indexKeyFor(spec, i));
    return indexKeys;
}

// Puts `count` records, number keys first + 0..count-1, in a read-write transaction of its own.
static size_t populate(Client& client, const Db& db, const Schema& schema, unsigned count, unsigned first = 0, size_t valueBytes = 64)
{
    auto transaction = client.begin(db, IDBTransactionMode::Readwrite, { "bench"_s });
    if (!client.started(transaction))
        return 0;
    size_t bytes = 0;
    for (unsigned i = 0; i < count; ++i) {
        auto value = makeValue(first + i, valueBytes);
        client.put(transaction, schema.objectStore, numberKey(first + i), indexKeysFor(schema, first + i), value);
        bytes += 8 + valueSize(value);
    }
    client.commit(transaction);
    return bytes;
}

// A database with one object store "bench" and its records, and a connection open to it.
struct Fixture {
    Db db;
    Schema schema;
};

static std::optional<Fixture> makeFixture(Client& client, World& world, Excluded& excluded, const String& name, std::initializer_list<bool> multiEntryFlags, unsigned records)
{
    std::optional<Fixture> fixture;
    excluded.measure([&] {
        auto upgrade = openForUpgrade(client, world, name, 1);
        if (!upgrade)
            return;
        auto schema = createSchema(client, *upgrade, "bench"_s, multiEntryFlags);
        commitUpgrade(client, *upgrade);
        if (records)
            populate(client, upgrade->db, schema, records);
        fixture = Fixture { WTF::move(upgrade->db), WTF::move(schema) };
    });
    return fixture;
}

// The harness.

// The process's physical footprint, and its lifetime peak, in bytes (zero where not measured).
struct Footprint {
    uint64_t current { 0 };
    uint64_t peak { 0 };
};

static Footprint footprint()
{
    Footprint result;
#if OS(DARWIN)
    rusage_info_current usage { };
    if (!proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, reinterpret_cast<rusage_info_t*>(&usage))) {
        result.current = usage.ri_phys_footprint;
        result.peak = usage.ri_lifetime_max_phys_footprint;
    }
#endif
    return result;
}

// `pass(digest, excluded)` returns the bytes its timed operations carried.
template<typename Pass>
static void run(ASCIILiteral name, uint64_t recorded, const Pass& pass)
{
    Digest digest;
    Excluded excluded;
    auto before = footprint();
    runOffMainThread([&] {
        pass(digest, excluded);
    });
    auto checksum = digest.value();
    // Memory (the baseline is the footprint before the first pass; a run of one shape per process): what the pass
    // added at its peak, what it kept after it, and what a second pass keeps beyond the first.
    auto afterFirst = footprint();
    {
        Digest secondDigest;
        Excluded secondExcluded;
        runOffMainThread([&] {
            pass(secondDigest, secondExcluded);
        });
    }
    auto afterSecond = footprint();
    SAFE_PRINTF("%s: memory peak-added=%lld KB retained=%lld KB second-pass-retained=%lld KB\n", name,
        static_cast<long long>((afterSecond.peak - before.current) / 1024), static_cast<long long>((static_cast<int64_t>(afterFirst.current) - static_cast<int64_t>(before.current)) / 1024),
        static_cast<long long>((static_cast<int64_t>(afterSecond.current) - static_cast<int64_t>(afterFirst.current)) / 1024));
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

constexpr unsigned recordCount = 10000;

// Strides through 0..9999 in a fixed shuffled order (7919 is prime).
static unsigned shuffled(unsigned i) { return (i * 7919u) % recordCount; }

// Workloads.

static size_t openUpgradeClose(World& world, Excluded&)
{
    size_t bytes = 0;
    auto& client = world.addClient();
    for (unsigned n = 0; n < 40; ++n) {
        String name = makeString("db"_s, n);
        // Creates the database: version 1 with an object store and an index.
        auto upgrade = openForUpgrade(client, world, name, 1);
        if (!upgrade)
            return bytes;
        auto schema = createSchema(client, *upgrade, "store"_s, { false });
        commitUpgrade(client, *upgrade);
        client.close(upgrade->db);
        // Opens it again at its version, at the version it has by default (0), and at a newer one, which upgrades it.
        auto same = openConnection(client, world, name, 1);
        if (!same)
            return bytes;
        client.close(*same);
        auto defaulted = openConnection(client, world, name, 0);
        if (!defaulted)
            return bytes;
        client.close(*defaulted);
        auto second = openForUpgrade(client, world, name, 2);
        if (!second)
            return bytes;
        client.createIndex(second->db, second->transaction, schema.objectStore, "second"_s, false, true);
        commitUpgrade(client, *second);
        client.close(second->db);
        bytes += 16;
    }
    world.digest().addInteger(client.callbackCount());
    return bytes;
}

static size_t putSmallRecordsOneTransaction(World& world, Excluded& excluded)
{
    auto& client = world.addClient();
    auto fixture = makeFixture(client, world, excluded, "puts"_s, { }, 0);
    if (!fixture)
        return 0;
    size_t bytes = populate(client, fixture->db, fixture->schema, recordCount);
    client.close(fixture->db);
    world.digest().addInteger(client.callbackCount());
    return bytes;
}

static size_t manySmallTransactions(World& world, Excluded& excluded)
{
    size_t bytes = 0;
    auto& client = world.addClient();
    auto fixture = makeFixture(client, world, excluded, "small"_s, { false }, 0);
    if (!fixture)
        return 0;
    for (unsigned i = 0; i < 1000; ++i) {
        auto transaction = client.begin(fixture->db, IDBTransactionMode::Readwrite, { "bench"_s });
        if (!client.started(transaction))
            return bytes;
        auto value = makeValue(i, 64);
        client.put(transaction, fixture->schema.objectStore, numberKey(i), indexKeysFor(fixture->schema, i), value);
        bytes += 8 + valueSize(value);
        client.commit(transaction);
    }
    client.close(fixture->db);
    world.digest().addInteger(client.callbackCount());
    return bytes;
}

static size_t getByKey(World& world, Excluded& excluded)
{
    size_t bytes = 0;
    auto& client = world.addClient();
    auto fixture = makeFixture(client, world, excluded, "gets"_s, { }, recordCount);
    if (!fixture)
        return 0;
    auto transaction = client.begin(fixture->db, IDBTransactionMode::Readonly, { "bench"_s });
    if (!client.started(transaction))
        return 0;
    for (unsigned i = 0; i < recordCount; ++i) {
        client.get(transaction, fixture->schema.objectStore, exactly(numberKey(shuffled(i))));
        bytes += 8 + 64;
    }
    client.commit(transaction);
    client.close(fixture->db);
    world.digest().addInteger(client.callbackCount());
    return bytes;
}

static size_t cursorIterate(World& world, Excluded& excluded)
{
    size_t bytes = 0;
    auto& client = world.addClient();
    auto fixture = makeFixture(client, world, excluded, "cursor"_s, { }, recordCount);
    if (!fixture)
        return 0;
    auto transaction = client.begin(fixture->db, IDBTransactionMode::Readonly, { "bench"_s });
    if (!client.started(transaction))
        return 0;
    auto range = IDBKeyRangeData::allKeys();
    auto cursor = client.openCursor(transaction, fixture->schema.objectStore, std::nullopt, range, IndexedDB::CursorDirection::Next);
    client.drainCursor(transaction, cursor, range, IndexedDB::CursorDirection::Next, [&](const IDBKeyData&, const IDBKeyData&, const IDBValue& value) {
        bytes += 8 + valueSize(value);
        return false;
    });
    client.commit(transaction);
    client.close(fixture->db);
    world.digest().addInteger(client.callbackCount());
    return bytes;
}

// Cursors the way pages use them: backwards, over an index, skipping with advance, deleting and updating under it,
// over a key range, and over the keys only; and getAll of each type.
static size_t cursorVariants(World& world, Excluded& excluded)
{
    size_t bytes = 0;
    auto& client = world.addClient();
    auto fixture = makeFixture(client, world, excluded, "variants"_s, { false, true }, 3000);
    if (!fixture)
        return 0;
    auto& schema = fixture->schema;
    auto transaction = client.begin(fixture->db, IDBTransactionMode::Readwrite, { "bench"_s });
    if (!client.started(transaction))
        return 0;
    auto all = IDBKeyRangeData::allKeys();
    struct Walk {
        std::optional<unsigned> index;
        IDBKeyRangeData range;
        IndexedDB::CursorDirection direction;
        size_t limit;
        unsigned step;
    };
    Vector<Walk> walks;
    walks.append({ std::nullopt, all, IndexedDB::CursorDirection::Prev, 400, 1 });
    walks.append({ std::nullopt, rangeOf(numberKey(100), numberKey(900), true, true), IndexedDB::CursorDirection::Next, SIZE_MAX, 3 });
    walks.append({ 0, all, IndexedDB::CursorDirection::Nextunique, 500, 1 });
    walks.append({ 0, rangeOf(numberKey(10), numberKey(200)), IndexedDB::CursorDirection::Prevunique, SIZE_MAX, 2 });
    walks.append({ 1, rangeOf(numberKey(0), numberKey(50)), IndexedDB::CursorDirection::Next, 300, 1 });
    walks.append({ 1, all, IndexedDB::CursorDirection::Prev, 300, 5 });
    for (auto& walk : walks) {
        std::optional<IDBIndexIdentifier> index;
        if (walk.index)
            index = schema.indexes[*walk.index].identifier;
        auto cursor = client.openCursor(transaction, schema.objectStore, index, walk.range, walk.direction);
        client.drainCursor(transaction, cursor, walk.range, walk.direction, [&](const IDBKeyData&, const IDBKeyData&, const IDBValue& value) {
            bytes += 8 + valueSize(value);
            return false;
        }, walk.limit, walk.step);
    }
    // Updates and deletes under the cursor: the server's prefetched records are stale after each.
    auto cursor = client.openCursor(transaction, schema.objectStore, std::nullopt, all, IndexedDB::CursorDirection::Next);
    unsigned seen = 0;
    client.drainCursor(transaction, cursor, all, IndexedDB::CursorDirection::Next, [&](const IDBKeyData& key, const IDBKeyData&, const IDBValue& value) {
        bytes += 8 + valueSize(value);
        ++seen;
        if (!(seen % 9)) {
            client.put(transaction, schema.objectStore, key, indexKeysFor(schema, static_cast<unsigned>(key.number())), makeValue(seen, 48), IndexedDB::ObjectStoreOverwriteMode::OverwriteForCursor);
            return true;
        }
        if (!(seen % 13)) {
            client.deleteRecord(transaction, schema.objectStore, exactly(key));
            return true;
        }
        return false;
    }, 600);
    // Continue to a key, and to a key and primary key, as continue(key) and continuePrimaryKey() do on an index.
    auto indexCursor = client.openCursor(transaction, schema.objectStore, schema.indexes[0].identifier, all, IndexedDB::CursorDirection::Next);
    auto start = client.takeGetResult();
    if (start && start->isDefined()) {
        client.iterateCursor(transaction, indexCursor, numberKey(500), { }, 0);
        if (auto moved = client.takeGetResult())
            client.iterateCursor(transaction, indexCursor, moved->keyData(), moved->primaryKeyData(), 1, IndexedDB::CursorIterateOption::DoNotReply);
        client.iterateCursor(transaction, indexCursor, numberKey(900), numberKey(900), 0);
        client.takeGetResult();
    }
    // getAll of keys, values and records, over the object store and an index, with and without a count.
    client.getAll(transaction, schema.objectStore, std::nullopt, rangeOf(numberKey(0), numberKey(300)), IndexedDB::GetAllType::Values);
    client.getAll(transaction, schema.objectStore, std::nullopt, all, IndexedDB::GetAllType::Keys, 200);
    client.getAll(transaction, schema.objectStore, std::nullopt, all, IndexedDB::GetAllType::Records, 100, IndexedDB::CursorDirection::Prev);
    client.getAll(transaction, schema.objectStore, schema.indexes[0].identifier, rangeOf(numberKey(5), numberKey(20)), IndexedDB::GetAllType::Records);
    client.getAll(transaction, schema.objectStore, schema.indexes[1].identifier, all, IndexedDB::GetAllType::Keys, 150);
    client.count(transaction, schema.objectStore, std::nullopt, all);
    client.count(transaction, schema.objectStore, schema.indexes[1].identifier, rangeOf(numberKey(0), numberKey(60)));
    client.commit(transaction);
    client.close(fixture->db);
    world.digest().addInteger(client.callbackCount());
    return bytes;
}

// Four connections to one database read it at once, with scopes that overlap; a write waits for the readers of
// its store and starts when they finish.
static size_t concurrentReadOnly(World& world, Excluded& excluded)
{
    size_t bytes = 0;
    auto& first = world.addClient();
    std::optional<Upgrade> upgrade;
    Vector<Schema> schemas;
    excluded.measure([&] {
        upgrade = openForUpgrade(first, world, "readers"_s, 1);
        if (!upgrade)
            return;
        for (auto name : { "a"_s, "b"_s, "c"_s })
            schemas.append(createSchema(first, *upgrade, name, { false }));
        commitUpgrade(first, *upgrade);
        for (auto& schema : schemas) {
            auto transaction = first.begin(upgrade->db, IDBTransactionMode::Readwrite, { "a"_s, "b"_s, "c"_s });
            if (!first.started(transaction))
                return;
            for (unsigned i = 0; i < 2000; ++i)
                first.put(transaction, schema.objectStore, numberKey(i), indexKeysFor(schema, i), makeValue(i, 64));
            first.commit(transaction);
        }
    });
    if (!upgrade || schemas.size() != 3)
        return 0;

    struct Reader {
        Client* client;
        Db db;
        Transaction transaction;
        unsigned store;
    };
    Vector<Reader> readers;
    Vector<Vector<String>> scopes;
    scopes.append({ "a"_s, "b"_s });
    scopes.append({ "b"_s, "c"_s });
    scopes.append({ "a"_s, "c"_s });
    scopes.append({ "a"_s, "b"_s, "c"_s });
    for (unsigned i = 0; i < 4; ++i) {
        auto& client = i ? world.addClient() : first;
        std::optional<Db> db;
        if (!i)
            db = Db { upgrade->db.connection, upgrade->db.info };
        else
            db = openConnection(client, world, "readers"_s, 1);
        if (!db)
            return bytes;
        auto transaction = client.begin(*db, IDBTransactionMode::Readonly, WTF::move(scopes[i]));
        if (!client.started(transaction))
            return bytes;
        readers.append({ &client, WTF::move(*db), WTF::move(transaction), i % 3 });
    }
    // A writer of "a" on the first connection waits for the readers of "a".
    auto writer = first.begin(readers[0].db, IDBTransactionMode::Readwrite, { "a"_s });
    world.digest().addInteger(first.started(writer));

    for (unsigned round = 0; round < 2500; ++round) {
        for (auto& reader : readers) {
            auto& schema = schemas[reader.store];
            reader.client->get(reader.transaction, schema.objectStore, exactly(numberKey((round * 7 + reader.store) % 2000)));
            bytes += 8 + 64;
        }
    }
    for (auto& reader : readers)
        reader.client->commit(reader.transaction);
    world.digest().addInteger(first.started(writer));
    if (first.started(writer)) {
        first.put(writer, schemas[0].objectStore, numberKey(5000), indexKeysFor(schemas[0], 5000), makeValue(5000, 64));
        first.commit(writer);
    }
    for (auto& reader : readers)
        reader.client->close(reader.db);
    world.digest().addInteger(first.callbackCount());
    return bytes;
}

// A connection asks for a new version while two others have the database open: they get versionchange events, one
// closes at once, one answers and closes later (the request is blocked meanwhile), and the upgrade runs.
static size_t versionChangeWithOpenConnections(World& world, Excluded&)
{
    size_t bytes = 0;
    auto& a = world.addClient();
    auto& b = world.addClient();
    auto& c = world.addClient();
    auto upgrade = openForUpgrade(a, world, "versions"_s, 1);
    if (!upgrade)
        return 0;
    auto schema = createSchema(a, *upgrade, "bench"_s, { false });
    commitUpgrade(a, *upgrade);
    auto dbA = Db { upgrade->db.connection, upgrade->db.info };
    auto dbB = openConnection(b, world, "versions"_s, 1);
    if (!dbB)
        return 0;
    for (unsigned version = 2; version < 40; ++version) {
        // C asks for the next version.
        c.open(world.databaseIdentifier("versions"_s), version);
        auto aEvents = a.takeVersionChanges();
        auto bEvents = b.takeVersionChanges();
        if (aEvents.size() != 1 || bEvents.size() != 1)
            return bytes;
        // B closes in its event handler: it tells the server it did, on its behalf.
        b.answerVersionChange(bEvents[0], IndexedDB::ConnectionClosedOnBehalfOfServer::Yes);
        // A has seen the event but keeps its connection: the request is blocked, A is told.
        a.answerVersionChange(aEvents[0], IndexedDB::ConnectionClosedOnBehalfOfServer::No);
        world.digest().addInteger(c.takeBlocked());
        a.pendingClose(dbA);
        a.close(dbA);
        auto opened = c.takeOpened();
        if (!opened || opened->type != IDBResultType::OpenDatabaseUpgradeNeeded)
            return bytes;
        Db dbC { *opened->connection, WTF::move(*opened->info) };
        Transaction transaction { *opened->transaction, 0 };
        c.createObjectStore(dbC, transaction, makeString("store"_s, version));
        c.commit(transaction);
        c.finishVersionChange(dbC, transaction);
        // A and B open the new version again, and C closes.
        auto reopenedA = openConnection(a, world, "versions"_s, version);
        auto reopenedB = openConnection(b, world, "versions"_s, version);
        if (!reopenedA || !reopenedB)
            return bytes;
        dbA = WTF::move(*reopenedA);
        dbB = WTF::move(reopenedB);
        c.close(dbC);
        bytes += 16;
    }
    a.close(dbA);
    b.close(*dbB);
    world.digest().addInteger(a.callbackCount() + b.callbackCount() + c.callbackCount());
    return bytes;
}

// A scripted sequence shaped like PerformanceTests/IndexedDB/basic (objectstore-add, -get, -cursor with continue,
// advance, delete and update, index-get, index-multientry, -count, -clear).
static size_t realisticMix(World& world, Excluded& excluded)
{
    size_t bytes = 0;
    auto& client = world.addClient();
    auto fixture = makeFixture(client, world, excluded, "mix"_s, { false, true }, 0);
    if (!fixture)
        return 0;
    auto& schema = fixture->schema;
    Random random(21);
    unsigned nextKey = 0;
    for (unsigned round = 0; round < 12; ++round) {
        // One read-write transaction per round, as a page's transaction would be.
        auto transaction = client.begin(fixture->db, IDBTransactionMode::Readwrite, { "bench"_s });
        if (!client.started(transaction))
            return bytes;
        // objectstore-add
        for (unsigned i = 0; i < 100; ++i, ++nextKey) {
            auto value = makeValue(nextKey, 48 + random.below(200));
            client.put(transaction, schema.objectStore, numberKey(nextKey), indexKeysFor(schema, nextKey), value, IndexedDB::ObjectStoreOverwriteMode::NoOverwrite);
            bytes += 8 + valueSize(value);
        }
        // objectstore-get
        for (unsigned i = 0; i < 60; ++i) {
            client.get(transaction, schema.objectStore, exactly(numberKey(random.below(nextKey))));
            bytes += 8 + 100;
        }
        // index-get
        for (unsigned i = 0; i < 20; ++i) {
            client.getIndex(transaction, schema.objectStore, schema.indexes[0].identifier, exactly(numberKey(random.below(1009))), IndexedDB::IndexRecordType::Value);
            bytes += 8 + 100;
        }
        client.count(transaction, schema.objectStore, std::nullopt, IDBKeyRangeData::allKeys()); // objectstore-count
        unsigned from = random.below(nextKey);
        auto range = rangeOf(numberKey(from), numberKey(nextKey));
        auto cursor = client.openCursor(transaction, schema.objectStore, std::nullopt, range, IndexedDB::CursorDirection::Next);
        unsigned seen = 0;
        client.drainCursor(transaction, cursor, range, IndexedDB::CursorDirection::Next, [&](const IDBKeyData& key, const IDBKeyData&, const IDBValue& value) { // cursor-continue, -update, -delete
            bytes += 8 + valueSize(value);
            ++seen;
            if (!(seen % 7)) {
                client.put(transaction, schema.objectStore, key, indexKeysFor(schema, static_cast<unsigned>(key.number())), makeValue(seen, 64), IndexedDB::ObjectStoreOverwriteMode::OverwriteForCursor);
                return true;
            }
            if (!(seen % 11)) {
                client.deleteRecord(transaction, schema.objectStore, exactly(key));
                return true;
            }
            return false;
        }, 150, seen % 3 + 1); // cursor-advance steps
        auto indexRange = rangeOf(numberKey(0), numberKey(50));
        auto indexCursor = client.openCursor(transaction, schema.objectStore, schema.indexes[1].identifier, indexRange, IndexedDB::CursorDirection::Next); // index-multientry
        client.drainCursor(transaction, indexCursor, indexRange, IndexedDB::CursorDirection::Next, [&](const IDBKeyData&, const IDBKeyData&, const IDBValue& value) {
            bytes += 16 + valueSize(value);
            return false;
        }, 100);
        // objectstore-clear: cleared in an upgrade below, as the page cannot clear in a read-write transaction.
        client.commit(transaction);
    }
    // objectstore-clear is a version-change request.
    client.close(fixture->db);
    auto upgrade = openForUpgrade(client, world, "mix"_s, 2);
    if (upgrade) {
        client.clearObjectStore(upgrade->transaction, schema.objectStore);
        commitUpgrade(client, *upgrade);
        client.close(upgrade->db);
    }
    world.digest().addInteger(client.callbackCount());
    return bytes;
}

// Every record operation with its variants: add and put, generated keys (with the key an index key is built on),
// keys that are arrays, strings and dates, deletes of ranges, and reads of what is missing.
static size_t recordOperations(World& world, Excluded& excluded)
{
    size_t bytes = 0;
    auto& client = world.addClient();
    std::optional<Upgrade> upgrade;
    Schema plain { IDBObjectStoreIdentifier::generate(), { } };
    Schema generated { IDBObjectStoreIdentifier::generate(), { } };
    excluded.measure([&] {
        upgrade = openForUpgrade(client, world, "records"_s, 1);
        if (!upgrade)
            return;
        plain = createSchema(client, *upgrade, "plain"_s, { false, true });
        generated = createSchema(client, *upgrade, "generated"_s, { false }, true);
        commitUpgrade(client, *upgrade);
    });
    if (!upgrade)
        return 0;
    auto transaction = client.begin(upgrade->db, IDBTransactionMode::Readwrite, { "plain"_s, "generated"_s });
    if (!client.started(transaction))
        return 0;
    Random random(3);
    for (unsigned i = 0; i < 300; ++i) {
        // Keys of every type, added once and then added again (a constraint error) and overwritten.
        auto key = [&](unsigned n) {
            switch (n % 4) {
            case 0:
                return numberKey(n);
            case 1:
                return stringKey(makeString("key-"_s, n));
            case 2:
                return IDBKeyData { IDBKeyData::ValueVariant { IDBKeyData::Date { static_cast<double>(n) * 1000 } } };
            default: {
                Vector<IDBKeyData> elements;
                elements.append(numberKey(n % 7));
                elements.append(stringKey(makeString("e"_s, n)));
                return IDBKeyData { IDBKeyData::ValueVariant { WTF::move(elements) } };
            }
            }
        }(i);
        auto value = makeValue(i, 32 + random.below(64));
        bytes += 8 + valueSize(value);
        IndexIDToIndexKeyMap indexKeys;
        indexKeys.add(plain.indexes[0].identifier, Client::indexKeyFor(plain.indexes[0], i));
        indexKeys.add(plain.indexes[1].identifier, Client::indexKeyFor(plain.indexes[1], i));
        client.put(transaction, plain.objectStore, key, indexKeys, value, IndexedDB::ObjectStoreOverwriteMode::NoOverwrite);
        if (!(i % 5))
            client.put(transaction, plain.objectStore, key, indexKeys, value, IndexedDB::ObjectStoreOverwriteMode::NoOverwrite); // ConstraintError, handled
        if (!(i % 3))
            client.put(transaction, plain.objectStore, key, indexKeys, makeValue(i + 1, 40));
        // Generated keys: none given, and one given that moves the generator.
        IndexIDToIndexKeyMap generatedKeys;
        generatedKeys.add(generated.indexes[0].identifier, IndexKey { IndexKey::Data { IDBKeyData::placeholder() } });
        client.put(transaction, generated.objectStore, IDBKeyData { }, generatedKeys, makeValue(i, 24), IndexedDB::ObjectStoreOverwriteMode::NoOverwrite);
        if (i % 50 == 49)
            client.put(transaction, generated.objectStore, numberKey(1000 + i), generatedKeys, makeValue(i, 24), IndexedDB::ObjectStoreOverwriteMode::NoOverwrite);
    }
    // Reads, of what is there and what is not.
    for (unsigned i = 0; i < 100; ++i) {
        client.get(transaction, plain.objectStore, exactly(numberKey(i * 4)));
        client.get(transaction, plain.objectStore, exactly(stringKey(makeString("key-"_s, i * 4 + 1))), IDBGetRecordDataType::KeyOnly);
        client.get(transaction, plain.objectStore, exactly(numberKey(100000 + i)));
        client.getIndex(transaction, plain.objectStore, plain.indexes[0].identifier, exactly(numberKey(i)), IndexedDB::IndexRecordType::Key);
        client.getIndex(transaction, plain.objectStore, plain.indexes[1].identifier, exactly(numberKey(1000 + i % 89)), IndexedDB::IndexRecordType::Value);
        client.get(transaction, generated.objectStore, exactly(numberKey(i + 1)));
    }
    client.count(transaction, plain.objectStore, std::nullopt, IDBKeyRangeData::allKeys());
    client.count(transaction, generated.objectStore, std::nullopt, rangeOf(numberKey(10), numberKey(40)));
    // Deletes: one record, a range, a range that holds nothing, then everything of a type.
    client.deleteRecord(transaction, plain.objectStore, exactly(numberKey(0)));
    client.deleteRecord(transaction, plain.objectStore, rangeOf(numberKey(4), numberKey(200), false, true));
    client.deleteRecord(transaction, plain.objectStore, rangeOf(numberKey(900000), numberKey(900100)));
    client.deleteRecord(transaction, generated.objectStore, rangeOf(numberKey(1), numberKey(100)));
    client.count(transaction, plain.objectStore, std::nullopt, IDBKeyRangeData::allKeys());
    client.getAll(transaction, generated.objectStore, std::nullopt, IDBKeyRangeData::allKeys(), IndexedDB::GetAllType::Records, 40);
    client.commit(transaction);
    client.close(upgrade->db);
    world.digest().addInteger(client.callbackCount());
    return bytes;
}

// Schema changes: create, rename, clear and delete object stores and indexes, an index over records that exist (the
// server asks the web process for each record's index key), a second upgrade that changes what the first made.
static size_t schemaChanges(World& world, Excluded&)
{
    size_t bytes = 0;
    auto& client = world.addClient();
    auto upgrade = openForUpgrade(client, world, "schema"_s, 1);
    if (!upgrade)
        return 0;
    auto people = client.createObjectStore(upgrade->db, upgrade->transaction, "people"_s);
    auto logs = createSchema(client, *upgrade, "logs"_s, { false, true }, true);
    auto scratch = client.createObjectStore(upgrade->db, upgrade->transaction, "scratch"_s);
    commitUpgrade(client, *upgrade);
    // Records exist: later upgrades index them.
    Schema peopleSchema { people.identifier(), { } };
    auto transaction = client.begin(upgrade->db, IDBTransactionMode::Readwrite, { "people"_s, "logs"_s, "scratch"_s });
    if (!client.started(transaction))
        return 0;
    for (unsigned i = 0; i < 400; ++i) {
        client.put(transaction, people.identifier(), numberKey(i), { }, makeValue(i, 40));
        client.put(transaction, logs.objectStore, numberKey(i), indexKeysFor(logs, i), makeValue(i, 40));
        client.put(transaction, scratch.identifier(), numberKey(i), { }, makeValue(i, 40));
        bytes += 3 * (8 + 40);
    }
    client.commit(transaction);
    client.close(upgrade->db);

    auto second = openForUpgrade(client, world, "schema"_s, 2);
    if (!second)
        return bytes;
    // An index over 400 records, and a multi-entry one. (Only sequences the web process sends: names are never taken
    // or missing, which the web process checks before it asks.)
    auto byName = client.createIndex(second->db, second->transaction, people.identifier(), "byName"_s, false, false);
    auto byTags = client.createIndex(second->db, second->transaction, people.identifier(), "byTags"_s, false, true);
    client.renameIndex(second->transaction, people.identifier(), byName, "byFullName"_s);
    client.renameIndex(second->transaction, people.identifier(), byTags, "byLabels"_s);
    client.deleteIndex(second->transaction, logs.objectStore, "index0"_s);
    client.renameObjectStore(second->transaction, scratch.identifier(), "temp"_s);
    client.clearObjectStore(second->transaction, logs.objectStore);
    client.createObjectStore(second->db, second->transaction, "extra"_s, std::nullopt, true);
    client.deleteObjectStore(second->transaction, "temp"_s);
    commitUpgrade(client, *second);
    client.close(second->db);

    // The upgrade's result is there: read and write through it.
    auto db = openConnection(client, world, "schema"_s, 2);
    if (!db)
        return bytes;
    auto reading = client.begin(*db, IDBTransactionMode::Readonly, { "people"_s, "logs"_s });
    if (client.started(reading)) {
        client.getIndex(reading, people.identifier(), byName, exactly(numberKey(7)), IndexedDB::IndexRecordType::Key);
        client.count(reading, people.identifier(), byTags, IDBKeyRangeData::allKeys());
        client.count(reading, logs.objectStore, std::nullopt, IDBKeyRangeData::allKeys());
        client.commit(reading);
    }
    client.close(*db);
    world.digest().addInteger(client.callbackCount());
    return bytes;
}

// What the server answers when the page's request is wrong or it has gone: requests for transactions, connections
// and stores that are not there, a version below the database's, constraint errors, a transaction that commits
// with a failed request it never handled, and requests from a connection the server does not know.
static size_t errorPaths(World& world, Excluded&)
{
    size_t bytes = 0;
    auto& client = world.addClient();
    auto& stranger = world.addClient(false);
    auto upgrade = openForUpgrade(client, world, "errors"_s, 3);
    if (!upgrade)
        return 0;
    auto schema = createSchema(client, *upgrade, "bench"_s, { false });
    auto unique = client.createIndex(upgrade->db, upgrade->transaction, schema.objectStore, "unique"_s, true, false);
    commitUpgrade(client, *upgrade);

    // A version below the database's; a connection the server does not know; an open cancelled that is not open.
    client.open(world.databaseIdentifier("errors"_s), 2);
    auto lower = client.takeOpened();
    world.digest().addInteger(lower ? static_cast<uint64_t>(lower->type) + 1 : 0);
    stranger.open(world.databaseIdentifier("errors"_s), 3);
    stranger.deleteDatabase(world.databaseIdentifier("errors"_s));
    client.cancelOpen(world.databaseIdentifier("nothing"_s), 1, client.newResource());
    world.digest().addInteger(stranger.callbackCount());

    // Requests for what the server does not have: ignored, with nothing sent back.
    Transaction ghost { client.newResource(), 0 };
    Db ghostDb { IDBDatabaseConnectionIdentifier::generate(), IDBDatabaseInfo { "ghost"_s, 1, 0 } };
    client.commit(ghost);
    client.abort(ghost);
    client.get(ghost, schema.objectStore, exactly(numberKey(1)));
    client.put(ghost, schema.objectStore, numberKey(1), { }, makeValue(1, 8));
    client.deleteRecord(ghost, schema.objectStore, exactly(numberKey(1)));
    client.count(ghost, schema.objectStore, std::nullopt, IDBKeyRangeData::allKeys());
    client.getAll(ghost, schema.objectStore, std::nullopt, IDBKeyRangeData::allKeys(), IndexedDB::GetAllType::Keys);
    client.openCursor(ghost, schema.objectStore, std::nullopt, IDBKeyRangeData::allKeys(), IndexedDB::CursorDirection::Next);
    client.iterateCursor(ghost, Cursor { client.newResource(), schema.objectStore, std::nullopt }, { }, { }, 1);
    client.clearObjectStore(ghost, schema.objectStore);
    client.deleteIndex(ghost, schema.objectStore, "unique"_s);
    client.renameIndex(ghost, schema.objectStore, unique, "x"_s);
    client.deleteObjectStore(ghost, "bench"_s);
    client.renameObjectStore(ghost, schema.objectStore, "x"_s);
    client.begin(ghostDb, IDBTransactionMode::Readonly, { "bench"_s });
    client.pendingClose(ghostDb);
    client.close(ghostDb);
    client.finishVersionChange(ghostDb, ghost);
    client.abortOpenAndUpgradeNeeded(ghostDb, ghost);
    client.answerVersionChange({ ghostDb.connection, client.newResource(), 4 }, IndexedDB::ConnectionClosedOnBehalfOfServer::No);
    world.digest().addInteger(client.callbackCount());

    // Requests against stores that are not there, in a transaction that is.
    auto db = openConnection(client, world, "errors"_s, 3);
    if (!db)
        return bytes;
    auto reading = client.begin(*db, IDBTransactionMode::Readonly, { "bench"_s });
    if (client.started(reading)) {
        auto missing = IDBObjectStoreIdentifier::generate();
        client.get(reading, missing, exactly(numberKey(1)));
        client.getAll(reading, missing, std::nullopt, IDBKeyRangeData::allKeys(), IndexedDB::GetAllType::Values);
        client.count(reading, missing, std::nullopt, IDBKeyRangeData::allKeys());
        client.openCursor(reading, missing, std::nullopt, IDBKeyRangeData::allKeys(), IndexedDB::CursorDirection::Next);
        client.get(reading, schema.objectStore, exactly(numberKey(1))); // Nothing there: a result without a record.
        // The page handled every result: the commit goes through, though some failed.
        client.commit(reading);
    }
    auto writing = client.begin(*db, IDBTransactionMode::Readwrite, { "bench"_s });
    if (client.started(writing)) {
        auto missing = IDBObjectStoreIdentifier::generate();
        client.put(writing, missing, numberKey(1), { }, makeValue(1, 8));
        client.deleteRecord(writing, missing, exactly(numberKey(1)));
        // A key that exists, added again; a record whose unique index key another record has.
        for (unsigned i = 0; i < 20; ++i) {
            IndexIDToIndexKeyMap indexKeys;
            indexKeys.add(unique, IndexKey { IndexKey::Data { numberKey(i / 2) } });
            client.put(writing, schema.objectStore, numberKey(i), indexKeys, makeValue(i, 16), IndexedDB::ObjectStoreOverwriteMode::NoOverwrite);
            bytes += 8 + 16;
        }
        client.put(writing, schema.objectStore, numberKey(3), { }, makeValue(3, 16), IndexedDB::ObjectStoreOverwriteMode::NoOverwrite);
        // The page never saw the last result, which failed: the server aborts the transaction.
        client.commit(writing, 1);
    }
    // An abort of a transaction that is finished, a commit of one that is aborted: both ignored.
    client.abort(writing);
    client.commit(writing);
    client.abort(reading);
    client.close(*db);
    world.digest().addInteger(client.callbackCount());
    return bytes;
}

// Quota: the server asks its space requester before it creates a database, a store or an index, and before each
// write, and answers QuotaExceededError when it is denied; the requester grants the next request.
static size_t quotaDeniedThenGranted(World& world, Excluded&)
{
    size_t bytes = 0;
    auto& client = world.addClient();
    // Denied at the first open: no database is made. Granted at the second.
    world.denyNext(1);
    client.open(world.databaseIdentifier("quota"_s), 1);
    auto denied = client.takeOpened();
    world.digest().addInteger(denied ? static_cast<uint64_t>(denied->type) + 1 : 0);
    auto upgrade = openForUpgrade(client, world, "quota"_s, 1);
    if (!upgrade)
        return 0;
    // Denied at a store, granted on the retry, denied at an index, granted on the retry, denied at a rename.
    world.denyNext(1);
    client.createObjectStore(upgrade->db, upgrade->transaction, "denied"_s);
    auto schema = createSchema(client, *upgrade, "bench"_s, { });
    world.denyNext(1);
    client.createIndex(upgrade->db, upgrade->transaction, schema.objectStore, "denied"_s, false, false);
    auto index = client.createIndex(upgrade->db, upgrade->transaction, schema.objectStore, "granted"_s, false, false);
    schema.indexes.append({ index, false });
    world.denyNext(1);
    client.renameObjectStore(upgrade->transaction, schema.objectStore, "renamedDenied"_s);
    commitUpgrade(client, *upgrade);
    // Denied at one put in the middle of a transaction: it fails, the next is granted, and the page abandons the
    // transaction (the failed result is unhandled).
    auto transaction = client.begin(upgrade->db, IDBTransactionMode::Readwrite, { "bench"_s });
    if (!client.started(transaction))
        return bytes;
    for (unsigned i = 0; i < 100; ++i) {
        if (i == 40 || i == 70)
            world.denyNext(1);
        auto value = makeValue(i, 64);
        client.put(transaction, schema.objectStore, numberKey(i), indexKeysFor(schema, i), value);
        bytes += 8 + valueSize(value);
    }
    client.commit(transaction, 1);
    // Retried: every put granted.
    bytes += populate(client, upgrade->db, schema, 100);
    auto reading = client.begin(upgrade->db, IDBTransactionMode::Readonly, { "bench"_s });
    if (client.started(reading)) {
        client.count(reading, schema.objectStore, std::nullopt, IDBKeyRangeData::allKeys());
        client.commit(reading);
    }
    // A deleted database asks for space again when it is recreated.
    client.close(upgrade->db);
    client.deleteDatabase(world.databaseIdentifier("quota"_s));
    world.denyNext(2);
    client.open(world.databaseIdentifier("quota"_s), 1);
    client.open(world.databaseIdentifier("quota"_s), 1);
    auto last = client.takeOpened();
    world.digest().addInteger(last ? static_cast<uint64_t>(last->type) + 1 : 0);
    if (last && last->type == IDBResultType::OpenDatabaseUpgradeNeeded) {
        Db db { *last->connection, WTF::move(*last->info) };
        Transaction versionChange { *last->transaction, 0 };
        client.commit(versionChange);
        client.finishVersionChange(db, versionChange);
        client.close(db);
    }
    world.digest().addInteger(client.callbackCount());
    return bytes;
}

// Aborts: a version change that creates and writes, and whose abort takes the schema back; an upgrade the page
// abandons; a read-write transaction that aborts with its writes; one that aborts with another waiting behind it.
static size_t abortPaths(World& world, Excluded&)
{
    size_t bytes = 0;
    auto& client = world.addClient();
    auto first = openForUpgrade(client, world, "aborts"_s, 1);
    if (!first)
        return 0;
    auto schema = createSchema(client, *first, "bench"_s, { false });
    commitUpgrade(client, *first);
    bytes += populate(client, first->db, schema, 200);
    client.close(first->db);

    // An upgrade that is aborted after it writes: the store it made is gone and the version is the old one.
    auto upgrade = openForUpgrade(client, world, "aborts"_s, 2);
    if (!upgrade)
        return bytes;
    auto extra = createSchema(client, *upgrade, "extra"_s, { true });
    for (unsigned i = 0; i < 50; ++i)
        client.put(upgrade->transaction, extra.objectStore, numberKey(i), indexKeysFor(extra, i), makeValue(i, 32));
    client.deleteObjectStore(upgrade->transaction, "bench"_s);
    client.abort(upgrade->transaction);
    client.finishVersionChange(upgrade->db, upgrade->transaction);
    client.close(upgrade->db);
    auto reopened = openConnection(client, world, "aborts"_s, 1);
    if (!reopened)
        return bytes;

    // A write transaction that aborts; the one behind it starts and sees none of its writes.
    auto writing = client.begin(*reopened, IDBTransactionMode::Readwrite, { "bench"_s });
    auto waiting = client.begin(*reopened, IDBTransactionMode::Readwrite, { "bench"_s });
    world.digest().addInteger(client.started(writing));
    world.digest().addInteger(client.started(waiting));
    if (client.started(writing)) {
        for (unsigned i = 0; i < 100; ++i)
            client.put(writing, schema.objectStore, numberKey(1000 + i), indexKeysFor(schema, i), makeValue(i, 32));
        client.deleteRecord(writing, schema.objectStore, rangeOf(numberKey(0), numberKey(50)));
        client.abort(writing);
        world.digest().addInteger(client.started(waiting));
    }
    if (client.started(waiting)) {
        client.count(waiting, schema.objectStore, std::nullopt, IDBKeyRangeData::allKeys());
        client.getAll(waiting, schema.objectStore, std::nullopt, rangeOf(numberKey(0), numberKey(10)), IndexedDB::GetAllType::Keys);
        client.commit(waiting);
    }
    // Aborts of what is finished, and of a read-only transaction.
    client.abort(writing);
    client.commit(waiting);
    auto reading = client.begin(*reopened, IDBTransactionMode::Readonly, { "bench"_s });
    if (client.started(reading)) {
        client.get(reading, schema.objectStore, exactly(numberKey(100)));
        client.abort(reading);
    }
    client.close(*reopened);

    // An upgrade the page abandons without asking for its abort (the page is closing): the server drops it.
    auto abandoned = openForUpgrade(client, world, "aborts"_s, 2);
    if (abandoned) {
        client.createObjectStore(abandoned->db, abandoned->transaction, "lost"_s);
        client.abortOpenAndUpgradeNeeded(abandoned->db, abandoned->transaction);
    }
    // And a connection abandoned after open, before any upgrade: no transaction to name.
    auto again = openForUpgrade(client, world, "aborts"_s, 2);
    if (again)
        client.abortOpenAndUpgradeNeeded(again->db);
    auto last = openConnection(client, world, "aborts"_s, 1);
    if (last) {
        auto transaction = client.begin(*last, IDBTransactionMode::Readonly, { "bench"_s });
        if (client.started(transaction)) {
            client.count(transaction, schema.objectStore, std::nullopt, IDBKeyRangeData::allKeys());
            client.commit(transaction);
        }
        client.close(*last);
    }
    world.digest().addInteger(client.callbackCount());
    return bytes;
}

// Deleting a database: one that is not there, one that is idle, one with connections open (they get the event; the
// delete is blocked until they close), two deletes queued, an open queued behind a delete, and a delete cancelled.
static size_t deleteDatabase(World& world, Excluded&)
{
    size_t bytes = 0;
    auto& a = world.addClient();
    auto& b = world.addClient();
    auto& c = world.addClient();
    a.deleteDatabase(world.databaseIdentifier("never-made"_s));
    world.digest().addInteger(a.takeDeleted());

    // An idle database with records.
    auto upgrade = openForUpgrade(a, world, "doomed"_s, 1);
    if (!upgrade)
        return 0;
    auto schema = createSchema(a, *upgrade, "bench"_s, { false });
    commitUpgrade(a, *upgrade);
    bytes += populate(a, upgrade->db, schema, 300);
    a.close(upgrade->db);
    a.deleteDatabase(world.databaseIdentifier("doomed"_s));
    world.digest().addInteger(a.takeDeleted());
    // It is made again, empty.
    auto remade = openForUpgrade(a, world, "doomed"_s, 1);
    if (!remade)
        return bytes;
    commitUpgrade(a, *remade);

    // Two connections open: the delete asks them to close, one does at once and one after it is told the delete is blocked.
    auto dbB = openConnection(b, world, "doomed"_s, 1);
    if (!dbB)
        return bytes;
    c.deleteDatabase(world.databaseIdentifier("doomed"_s));
    auto aEvents = a.takeVersionChanges();
    auto bEvents = b.takeVersionChanges();
    if (aEvents.size() != 1 || bEvents.size() != 1)
        return bytes;
    a.answerVersionChange(aEvents[0], IndexedDB::ConnectionClosedOnBehalfOfServer::No);
    b.answerVersionChange(bEvents[0], IndexedDB::ConnectionClosedOnBehalfOfServer::No);
    world.digest().addInteger(c.takeBlocked());
    a.close(remade->db);
    world.digest().addInteger(c.takeDeleted());
    b.close(*dbB);
    world.digest().addInteger(c.takeDeleted());

    // A second delete and an open queue behind a delete that is blocked by an open connection.
    auto holder = openForUpgrade(a, world, "queued"_s, 1);
    if (!holder)
        return bytes;
    commitUpgrade(a, *holder);
    b.deleteDatabase(world.databaseIdentifier("queued"_s));
    c.deleteDatabase(world.databaseIdentifier("queued"_s));
    c.open(world.databaseIdentifier("queued"_s), 1);
    auto holderEvents = a.takeVersionChanges();
    if (holderEvents.size() == 1)
        a.answerVersionChange(holderEvents[0], IndexedDB::ConnectionClosedOnBehalfOfServer::No);
    a.close(holder->db);
    world.digest().addInteger(b.takeDeleted());
    world.digest().addInteger(c.takeDeleted());
    auto afterDelete = c.takeOpened();
    world.digest().addInteger(afterDelete ? static_cast<uint64_t>(afterDelete->type) + 1 : 0);
    if (afterDelete && afterDelete->type == IDBResultType::OpenDatabaseUpgradeNeeded) {
        Db db { *afterDelete->connection, WTF::move(*afterDelete->info) };
        Transaction transaction { *afterDelete->transaction, 0 };
        c.commit(transaction);
        c.finishVersionChange(db, transaction);
        c.close(db);
    }

    // A delete the page cancels while a connection holds the database.
    auto holding = openConnection(a, world, "queued"_s, 1);
    if (holding) {
        auto request = b.deleteDatabase(world.databaseIdentifier("queued"_s));
        b.cancelOpen(world.databaseIdentifier("queued"_s), 0, request);
        a.close(*holding);
        world.digest().addInteger(b.takeDeleted());
    }
    world.digest().addInteger(a.callbackCount() + b.callbackCount() + c.callbackCount());
    return bytes;
}

// The page goes away or closes with work pending: a connection closed with a transaction running and others waiting,
// a connection closed while the version change waits for it, an open request cancelled while blocked, and the
// whole client process going away with a connection, transactions and requests of every kind.
static size_t closeWithPending(World& world, Excluded&)
{
    size_t bytes = 0;
    auto& a = world.addClient();
    auto& b = world.addClient();
    auto& c = world.addClient();
    auto upgrade = openForUpgrade(a, world, "pending"_s, 1);
    if (!upgrade)
        return 0;
    auto schema = createSchema(a, *upgrade, "bench"_s, { false });
    commitUpgrade(a, *upgrade);
    bytes += populate(a, upgrade->db, schema, 100);
    auto dbB = openConnection(b, world, "pending"_s, 1);
    auto dbC = openConnection(c, world, "pending"_s, 1);
    if (!dbB || !dbC)
        return bytes;

    // B closes with a write transaction running, one waiting behind it, and a reader waiting on both.
    auto running = b.begin(*dbB, IDBTransactionMode::Readwrite, { "bench"_s });
    auto waitingWrite = b.begin(*dbB, IDBTransactionMode::Readwrite, { "bench"_s });
    auto waitingRead = b.begin(*dbB, IDBTransactionMode::Readonly, { "bench"_s });
    if (b.started(running)) {
        for (unsigned i = 0; i < 50; ++i)
            b.put(running, schema.objectStore, numberKey(500 + i), indexKeysFor(schema, i), makeValue(i, 32));
    }
    world.digest().addInteger(b.started(waitingWrite) + 2 * b.started(waitingRead));
    b.pendingClose(*dbB);
    b.close(*dbB);
    // A is not held up by what B left: it writes.
    bytes += populate(a, upgrade->db, schema, 20, 1000);

    // C's transaction waits behind A's; A closes with it still running, and C's starts.
    auto aRunning = a.begin(upgrade->db, IDBTransactionMode::Readwrite, { "bench"_s });
    auto cWaiting = c.begin(*dbC, IDBTransactionMode::Readwrite, { "bench"_s });
    world.digest().addInteger(c.started(cWaiting));
    a.pendingClose(upgrade->db);
    a.close(upgrade->db);
    world.digest().addInteger(c.started(cWaiting));
    if (c.started(cWaiting)) {
        c.put(cWaiting, schema.objectStore, numberKey(7000), indexKeysFor(schema, 7000), makeValue(1, 16));
        c.commit(cWaiting);
    }
    UNUSED_VARIABLE(aRunning);

    // A version change waits for C; its page cancels the open request while it is blocked; a second request waits
    // and goes ahead when C closes.
    auto& d = world.addClient();
    auto request = d.open(world.databaseIdentifier("pending"_s), 2);
    auto events = c.takeVersionChanges();
    if (events.size() == 1)
        c.answerVersionChange(events[0], IndexedDB::ConnectionClosedOnBehalfOfServer::No);
    d.cancelOpen(world.databaseIdentifier("pending"_s), 2, request);
    d.open(world.databaseIdentifier("pending"_s), 3);
    c.pendingClose(*dbC);
    c.close(*dbC);
    auto upgraded = d.takeOpened();
    world.digest().addInteger(upgraded ? static_cast<uint64_t>(upgraded->type) + 1 : 0);
    if (upgraded && upgraded->type == IDBResultType::OpenDatabaseUpgradeNeeded) {
        // The page closes in the middle of the upgrade: the connection closes without the upgrade finishing.
        Db db { *upgraded->connection, WTF::move(*upgraded->info) };
        Transaction transaction { *upgraded->transaction, 0 };
        d.createObjectStore(db, transaction, "unfinished"_s);
        d.close(db);
    }

    // A client process that goes away holding a connection with a transaction running, one waiting, a connection
    // mid-upgrade of another database, and an open request that waits behind it.
    auto& e = world.addClient();
    auto& f = world.addClient();
    auto dbE = openConnection(e, world, "pending"_s, 3);
    if (!dbE)
        return bytes;
    auto eRunning = e.begin(*dbE, IDBTransactionMode::Readwrite, { "bench"_s });
    auto eWaiting = e.begin(*dbE, IDBTransactionMode::Readwrite, { "bench"_s });
    UNUSED_VARIABLE(eWaiting);
    auto midUpgrade = openForUpgrade(e, world, "other"_s, 1);
    if (midUpgrade)
        e.createObjectStore(midUpgrade->db, midUpgrade->transaction, "half"_s);
    f.open(world.databaseIdentifier("other"_s), 2);
    UNUSED_VARIABLE(eRunning);
    world.removeClient(e);
    world.digest().addInteger(f.takeOpened().has_value());
    world.digest().addInteger(f.callbackCount());
    // A client that goes away holding the version change of a database another waits to upgrade.
    auto fUpgrade = openForUpgrade(f, world, "other"_s, 2);
    auto& g = world.addClient();
    g.open(world.databaseIdentifier("other"_s), 3);
    if (fUpgrade)
        f.createObjectStore(fUpgrade->db, fUpgrade->transaction, "dropped"_s);
    world.removeClient(f);
    auto gOpened = g.takeOpened();
    world.digest().addInteger(gOpened ? static_cast<uint64_t>(gOpened->type) + 1 : 0);
    if (gOpened && gOpened->type == IDBResultType::OpenDatabaseUpgradeNeeded) {
        Db db { *gOpened->connection, WTF::move(*gOpened->info) };
        Transaction transaction { *gOpened->transaction, 0 };
        g.commit(transaction);
        g.finishVersionChange(db, transaction);
        g.close(db);
    }
    world.digest().addInteger(a.callbackCount() + b.callbackCount() + c.callbackCount() + d.callbackCount() + g.callbackCount());
    return bytes;
}

// A client the system suspends: its transaction that blocks another is aborted so the other can go on, and the
// client finds out when it resumes.
static size_t clientSuspension(World& world, Excluded&)
{
    size_t bytes = 0;
    auto& a = world.addClient();
    auto& b = world.addClient();
    auto upgrade = openForUpgrade(a, world, "suspend"_s, 1);
    if (!upgrade)
        return 0;
    auto schema = createSchema(a, *upgrade, "bench"_s, { false });
    commitUpgrade(a, *upgrade);
    bytes += populate(a, upgrade->db, schema, 100);
    auto dbB = openConnection(b, world, "suspend"_s, 1);
    if (!dbB)
        return bytes;
    for (unsigned round = 0; round < 10; ++round) {
        auto running = a.begin(upgrade->db, IDBTransactionMode::Readwrite, { "bench"_s });
        auto waiting = b.begin(*dbB, IDBTransactionMode::Readwrite, { "bench"_s });
        if (!a.started(running))
            return bytes;
        a.put(running, schema.objectStore, numberKey(5000 + round), indexKeysFor(schema, round), makeValue(round, 32));
        world.digest().addInteger(b.started(waiting));
        a.setSuspended(true);
        world.digest().addInteger(b.started(waiting));
        if (b.started(waiting)) {
            b.put(waiting, schema.objectStore, numberKey(6000 + round), indexKeysFor(schema, round), makeValue(round, 32));
            bytes += 8 + 32;
            b.commit(waiting);
        }
        a.setSuspended(false);
        // The suspended client's transaction was aborted: its commit gets that answer.
        a.commit(running);
        a.abort(running);
        auto reading = a.begin(upgrade->db, IDBTransactionMode::Readonly, { "bench"_s });
        if (a.started(reading)) {
            a.count(reading, schema.objectStore, std::nullopt, IDBKeyRangeData::allKeys());
            a.commit(reading);
        }
    }
    a.close(upgrade->db);
    b.close(*dbB);
    world.digest().addInteger(a.callbackCount() + b.callbackCount());
    return bytes;
}

// What the server does with whole origins: lists the databases of an origin, the origins it has, how much disk they
// take, and deletes the databases of an origin.
static size_t originOperations(World& world, Excluded&)
{
    size_t bytes = 0;
    auto& client = world.addClient();
    Vector<Db> open;
    for (auto host : { "one.example"_s, "two.example"_s, "three.example"_s }) {
        for (auto name : { "first"_s, "second"_s }) {
            auto upgrade = openForUpgrade(client, world, name, 1, host);
            if (!upgrade)
                return bytes;
            auto schema = createSchema(client, *upgrade, "bench"_s, { false });
            commitUpgrade(client, *upgrade);
            bytes += populate(client, upgrade->db, schema, 50);
            if (name == "first"_s)
                open.append(WTF::move(upgrade->db));
            else
                client.close(upgrade->db);
        }
    }
    auto& digest = world.digest();
    auto sortedHosts = [&](const HashSet<SecurityOriginData>& origins) {
        Vector<String> hosts;
        for (auto& origin : origins)
            hosts.append(origin.host());
        std::sort(hosts.begin(), hosts.end(), [](const String& a, const String& b) {
            return codePointCompareLessThan(a, b);
        });
        for (auto& host : hosts)
            digest.addString(host);
    };
    sortedHosts(world.server().getOrigins());
    ClientOrigin one { SecurityOriginData { "https"_s, "one.example"_s, std::nullopt }, SecurityOriginData { "https"_s, "one.example"_s, std::nullopt } };
    world.server().getAllDatabaseNamesAndVersions(*client.identifier(), client.newResource(), one);
    digest.addInteger(Server::diskUsage(world.directory(), one) > 0);
    SecurityOriginData two { "https"_s, "two.example"_s, std::nullopt };
    ClientOrigin otherOrigin { two, two };
    // The connections close, then the databases of one origin are deleted one by one, as the web process does. (The
    // server's close-and-delete of the databases modified since a time is not here: the base traps on it while
    // databases exist, and its only caller is the legacy port.)
    for (auto& db : open)
        client.close(db);
    digest.addInteger(open.size());
    client.deleteDatabase(world.databaseIdentifier("first"_s, "one.example"_s));
    client.deleteDatabase(world.databaseIdentifier("second"_s, "one.example"_s));
    sortedHosts(world.server().getOrigins());
    digest.addInteger(world.server().getOrigins().size());
    world.server().getAllDatabaseNamesAndVersions(*client.identifier(), client.newResource(), otherOrigin);
    digest.addInteger(client.callbackCount());
    return bytes;
}

} // namespace IDBServerBenchmark

using namespace IDBServerBenchmark;

#define SERVER_BENCH(Name, recorded, script) \
    TEST(IDBServerBench, Name) \
    { \
        run(#Name ## _s, Recorded::recorded, [](Digest& digest, Excluded& excluded) { \
            return onBothStores(digest, excluded, script); \
        }); \
    }

// Runs no workload: alone in a process, its time is the start-up every other test's process also pays.
TEST(IDBServerBench, StartUp)
{
}

SERVER_BENCH(OpenUpgradeClose, openUpgradeClose, openUpgradeClose)
SERVER_BENCH(PutSmallRecordsOneTransaction, putSmallRecordsOneTransaction, putSmallRecordsOneTransaction)
SERVER_BENCH(ManySmallTransactions, manySmallTransactions, manySmallTransactions)
SERVER_BENCH(GetByKey, getByKey, getByKey)
SERVER_BENCH(CursorIterate, cursorIterate, cursorIterate)
SERVER_BENCH(CursorVariants, cursorVariants, cursorVariants)
SERVER_BENCH(ConcurrentReadOnly, concurrentReadOnly, concurrentReadOnly)
SERVER_BENCH(VersionChangeWithOpenConnections, versionChangeWithOpenConnections, versionChangeWithOpenConnections)
SERVER_BENCH(RealisticMix, realisticMix, realisticMix)
SERVER_BENCH(RecordOperations, recordOperations, recordOperations)
SERVER_BENCH(SchemaChanges, schemaChanges, schemaChanges)
SERVER_BENCH(ErrorPaths, errorPaths, errorPaths)
SERVER_BENCH(QuotaDeniedThenGranted, quotaDeniedThenGranted, quotaDeniedThenGranted)
SERVER_BENCH(AbortPaths, abortPaths, abortPaths)
SERVER_BENCH(DeleteDatabase, deleteDatabase, deleteDatabase)
SERVER_BENCH(CloseWithPending, closeWithPending, closeWithPending)
SERVER_BENCH(ClientSuspension, clientSuspension, clientSuspension)
SERVER_BENCH(OriginOperations, originOperations, originOperations)

} // namespace TestWebKitAPI
