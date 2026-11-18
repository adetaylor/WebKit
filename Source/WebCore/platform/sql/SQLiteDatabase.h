/*
 * Copyright (C) 2006-2021 Apple Inc. All rights reserved.
 * Copyright (C) 2007 Justin Haygood (jhaygood@reaktix.com)
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#pragma once

#include <functional>
#include <sqlite3.h>
#include <wtf/CheckedRef.h>
#include <wtf/CurrentThread.h>
#include <wtf/Lock.h>
#include <wtf/OptionSet.h>
#include <wtf/Platform.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/UniqueRef.h>
#include <wtf/text/CString.h>
#include <wtf/text/WTFString.h>

struct sqlite3;

namespace WebCore {

class DatabaseAuthorizer;
class SQLiteStatement;
class SQLiteStatementOwner;
class SQLiteTransaction;

class SQLiteDatabase final : public CanMakeThreadSafeCheckedPtr<SQLiteDatabase> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(SQLiteDatabase, WEBCORE_EXPORT);
    WTF_MAKE_NONCOPYABLE(SQLiteDatabase);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(SQLiteDatabase);

    friend class SQLiteTransaction;
public:
    NODELETE WEBCORE_EXPORT SQLiteDatabase();
    WEBCORE_EXPORT ~SQLiteDatabase();

    static constexpr ASCIILiteral inMemoryPath() { return ":memory:"_s; }

    enum class OpenMode : uint8_t { ReadOnly, ReadWrite, ReadWriteCreate };
    enum class OpenOptions : uint8_t {
        CanSuspendWhileLocked = 1 << 0,
    };

    WEBCORE_EXPORT bool open(const String& filename, OpenMode = OpenMode::ReadWriteCreate, OptionSet<OpenOptions> = { });
    bool isOpen() const { return m_db; }
    WEBCORE_EXPORT void close();

    WEBCORE_EXPORT int executeSlow(StringView);
    WEBCORE_EXPORT int execute(ASCIILiteral);
    WEBCORE_EXPORT bool executeCommandSlow(StringView);
    WEBCORE_EXPORT bool executeCommand(ASCIILiteral);
    
    WEBCORE_EXPORT bool tableExists(StringView);
    WEBCORE_EXPORT bool indexExists(StringView);
    WEBCORE_EXPORT String tableSQL(StringView);
    WEBCORE_EXPORT String indexSQL(StringView);
    WEBCORE_EXPORT void clearAllTables();
    WEBCORE_EXPORT int runVacuumCommand();
    WEBCORE_EXPORT int runIncrementalVacuumCommand();
    
    bool transactionInProgress() const { return m_transactionInProgress; }

    WEBCORE_EXPORT std::unique_ptr<SQLiteStatement> prepareStatementSlow(StringView query);
    WEBCORE_EXPORT std::unique_ptr<SQLiteStatement> prepareStatement(ASCIILiteral query);

    // String forms for Swift, which cannot form a StringView or an ASCIILiteral safely. Each passes the same text.
    WEBCORE_EXPORT SQLiteStatementOwner prepareStatementForString(const String& query);
    bool executeCommandForString(const String& query) { return executeCommandSlow(query); }
    bool tableExistsForString(const String& tableName) { return tableExists(tableName); }
    String tableSQLForString(const String& tableName) { return tableSQL(tableName); }
    String indexSQLForString(const String& indexName) { return indexSQL(indexName); }

    // Aborts the current database operation. This is thread safe.
    WEBCORE_EXPORT void interrupt();

    int64_t lastInsertRowID();

    // This function returns the number of rows modified, inserted or deleted by the most recently completed INSERT, UPDATE or DELETE statement.
    WEBCORE_EXPORT int lastChanges();

    void setBusyTimeout(int ms);
    void setBusyHandler(int(*)(void*, int));
    
    void setFullsync(bool);
    
    // This enables automatic WAL truncation via a commit hook that uses SQLITE_CHECKPOINT_TRUNCATE.
    // However, it shouldn't be used if you use a custom busy handler or timeout. This is because
    // SQLITE_CHECKPOINT_TRUNCATE will invoke the busy handler if it can't acquire the necessary
    // locks, which can lead to unintended delays.
    void enableAutomaticWALTruncation();
    enum class CheckpointMode : uint8_t { Full, Truncate };
    void checkpoint(CheckpointMode);

    // Gets/sets the maximum size in bytes
    // Depending on per-database attributes, the size will only be settable in units that are the page size of the database, which is established at creation
    // These chunks will never be anything other than 512, 1024, 2048, 4096, 8192, 16384, or 32768 bytes in size.
    // setMaximumSize() will round the size down to the next smallest chunk if the passed size doesn't align.
    int64_t maximumSize();
    WEBCORE_EXPORT void setMaximumSize(int64_t);
    
    // Gets the number of unused bytes in the database file.
    int64_t freeSpaceSize();
    int64_t totalSize();

    // The SQLite SYNCHRONOUS pragma can be either FULL, NORMAL, or OFF
    // FULL - Any writing calls to the DB block until the data is actually on the disk surface
    // NORMAL - SQLite pauses at some critical moments when writing, but much less than FULL
    // OFF - Calls return immediately after the data has been passed to disk
    enum SynchronousPragma { SyncOff = 0, SyncNormal = 1, SyncFull = 2 };
    void setSynchronous(SynchronousPragma);
    
    WEBCORE_EXPORT int lastError();
    WEBCORE_EXPORT const char* lastErrorMsg() LIFETIME_BOUND;
    // lastErrorMsg() copied into a String, read as Latin-1 as makeString reads unsafeSpan(lastErrorMsg()).
    String lastErrorMessage() { return String::fromLatin1(lastErrorMsg()); }
    
    sqlite3* sqlite3Handle() const LIFETIME_BOUND
    {
#if !PLATFORM(IOS_FAMILY)
        ASSERT(m_sharable || m_openingThreadID == currentThreadID() || !m_db);
#endif
        return m_db;
    }
    
    void setAuthorizer(DatabaseAuthorizer&);

    Lock& databaseMutex() LIFETIME_BOUND { return m_lockingMutex; }
    bool isAutoCommitOn() const;

    // The SQLite AUTO_VACUUM pragma can be either NONE, FULL, or INCREMENTAL.
    // NONE - SQLite does not do any vacuuming
    // FULL - SQLite moves all empty pages to the end of the DB file and truncates
    //        the file to remove those pages after every transaction. This option
    //        requires SQLite to store additional information about each page in
    //        the database file.
    // INCREMENTAL - SQLite stores extra information for each page in the database
    //               file, but removes the empty pages only when PRAGMA INCREMANTAL_VACUUM
    //               is called.
    enum AutoVacuumPragma { AutoVacuumNone = 0, AutoVacuumFull = 1, AutoVacuumIncremental = 2 };
    WEBCORE_EXPORT bool turnOnIncrementalAutoVacuum();

    WEBCORE_EXPORT void setCollationFunction(const String& collationName, Function<int(int, const void*, int, const void*)>&&);

    // Set this flag to allow access from multiple threads.  Not all multi-threaded accesses are safe!
    // See http://www.sqlite.org/cvstrac/wiki?p=MultiThreading for more info.
#if ASSERT_ENABLED
    WEBCORE_EXPORT void disableThreadingChecks();
#else
    void disableThreadingChecks() { }
#endif

    WEBCORE_EXPORT static void useFastMalloc();

    WEBCORE_EXPORT void releaseMemory();

    void incrementStatementCount();
    void decrementStatementCount();

private:
    static int authorizerFunction(void*, int, const char*, const char*, const char*, const char*);

    void enableAuthorizer(bool enable) WTF_REQUIRES_LOCK(m_authorizerLock);
    bool useWALJournalMode();

    int pageSize();

    void overrideUnauthorizedFunctions();

    sqlite3* m_db { nullptr };
    int m_pageSize { -1 };
    
    bool m_transactionInProgress { false };
#if ASSERT_ENABLED
    bool m_sharable { false };
    std::atomic<unsigned> m_statementCount { 0 };
#endif

    bool m_useWAL { false };

    Lock m_authorizerLock;
    RefPtr<DatabaseAuthorizer> m_authorizer WTF_GUARDED_BY_LOCK(m_authorizerLock);

    Lock m_lockingMutex;
    uint32_t m_openingThreadID { 0 };

    Lock m_databaseClosingMutex;

    int m_openError { SQLITE_ERROR };
    UTF8CString m_openErrorMessage;
} SWIFT_SHARED_REFERENCE(retainSQLiteDatabase, releaseSQLiteDatabase) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT;

// The owner Swift holds; Swift reaches the database through get() in a local and never stores the reference.
// Swift never calls SQLiteDatabase() itself: the reference it gets does not own (the object leaks when released).
// Not a std::unique_ptr, whose reset(pointer) would let Swift give a second owner the same database: this one
// cannot adopt a pointer (no constructor, reset or assignment from one), and it never hands its pointer out as
// owning (no release()).
class SQLiteDatabaseOwner {
    WTF_MAKE_NONCOPYABLE(SQLiteDatabaseOwner);
public:
    SQLiteDatabaseOwner(SQLiteDatabaseOwner&&) = default;
    SQLiteDatabase* get() const { return m_database.get(); }
    void reset() { m_database = nullptr; }

private:
    friend SQLiteDatabaseOwner makeSQLiteDatabase();
    SQLiteDatabaseOwner()
        : m_database(makeUnique<SQLiteDatabase>())
    {
    }

    std::unique_ptr<SQLiteDatabase> m_database;
};

inline SQLiteDatabaseOwner makeSQLiteDatabase() { return SQLiteDatabaseOwner(); }

using SQLiteDatabaseOpenOptions = OptionSet<SQLiteDatabase::OpenOptions>;

inline void SQLiteDatabase::incrementStatementCount()
{
#if ASSERT_ENABLED
    ++m_statementCount;
#endif
}

inline void SQLiteDatabase::decrementStatementCount()
{
#if ASSERT_ENABLED
    ASSERT(m_statementCount);
    --m_statementCount;
#endif
}

} // namespace WebCore

// Swift's retain and release of a SQLiteDatabase reference: its checked-pointer count, as a CheckedPtr holds it.
SWIFT_UNSAFE inline void retainSQLiteDatabase(WebCore::SQLiteDatabase* database) { database->incrementCheckedPtrCount(); }
SWIFT_UNSAFE inline void releaseSQLiteDatabase(WebCore::SQLiteDatabase* database) { database->decrementCheckedPtrCount(); }
