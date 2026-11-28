//
// Copyright (C) 2016-2026 Apple Inc. All rights reserved.
// Copyright (C) 2013, 2016 Apple Inc. All rights reserved.
// Copyright (C) 2025 Apple Inc. All rights reserved.
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

// The IndexedDB SQLite backing store, on a file or on ":memory:", which SwiftSQLiteIDBBackingStore
// (SwiftIDBBackingStore.cpp) holds. The cursors are SQLiteIDBStoreCursor.swift, the transactions
// SQLiteIDBStoreTransaction.swift.
//
// The SQLite wrapper stays C++. Swift holds only its owners (SQLiteDatabaseOwner, SQLiteStatementOwner),
// reaches the objects through get() in locals and parameters, and drops statements and transactions before the
// database. The SQL text is IDB's on-disk format; do not change it.
//
// Every method the C++ calls is in the class body: @_expose(Cxx) does not reach an extension's members.

#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.IDBDatabaseInfo
internal import WebCore_Private.Core.IDBError
internal import WebCore_Private.Core.IDBIndexInfo
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IDBObjectStoreInfo
internal import WebCore_Private.Core.IDBResourceIdentifier
internal import WebCore_Private.Core.IDBTransactionDurability
internal import WebCore_Private.Core.IDBTransactionInfo
internal import WebCore_Private.Core.IDBTransactionMode
internal import WebCore_Private.Core.SQLiteDatabase
internal import WebCore_Private.Core.SQLiteIDBStoreTypes
internal import WebCore_Private.Core.SQLiteStatement
internal import WebCore_Private.Core.SQLiteTransaction
internal import WebCore_Private.Core.SwiftIDBTypes

// MARK: - Constants

// SQLITE_OK, SQLITE_ROW and SQLITE_DONE, which SwiftIDBBackingStore.cpp checks with a static_assert.
let sqliteIDBResultOK: Int32 = 0
let sqliteIDBResultRow: Int32 = 100
let sqliteIDBResultDone: Int32 = 101

/// The metadata schema's version: 1, the initial one; 2, the database name stored as a blob.
private let sqliteIDBCurrentMetadataVersion: Int32 = 2

/// The spec's maximum key generator value, 2^53.
private let sqliteIDBMaxGeneratorValue: UInt64 = 0x20_0000_0000_0000

/// An ASCII Swift literal (SQL text, an error message) as a WTF.String: Latin-1 and UTF-8 agree on ASCII.
///
/// Out of line, as are the error makers below: each is on a cold path (a statement's first preparation, an error) and
/// has some 200 call sites.
@inline(never)
func sqliteIDBString(_ text: Swift.String) -> WTF.String {
    let bytes = Array(text.utf8)
    return WTF.String(WTF.latin1CharactersOfBytes(bytes.span))
}

@inline(never)
func sqliteIDBUnknownError(_ message: Swift.String) -> WebCore.IDBError {
    WebCore.makeSQLiteIDBUnknownError(sqliteIDBString(message))
}

@inline(never)
private func sqliteIDBConstraintError(_ message: Swift.String) -> WebCore.IDBError {
    WebCore.makeSQLiteIDBConstraintError(sqliteIDBString(message))
}

/// `makeString(message, " (", database.lastError(), ") - ", database.lastErrorMsg())` as an UnknownError.
@inline(never)
private func sqliteIDBDatabaseError(_ message: Swift.String, _ database: WebCore.SQLiteDatabase) -> WebCore.IDBError {
    WebCore.makeSQLiteIDBDatabaseError(sqliteIDBString(message), database)
}

// MARK: - Schema text

private enum SQLiteIDBSchema {
    static let objectStoreInfoTableName = "ObjectStoreInfo"
    static let objectStoreInfoTableNameAlternate = "\"ObjectStoreInfo\""
    static let v2ObjectStoreInfo =
        "CREATE TABLE ObjectStoreInfo (id INTEGER PRIMARY KEY NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT FAIL, name TEXT NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT FAIL, keyPath BLOB NOT NULL ON CONFLICT FAIL, autoInc INTEGER NOT NULL ON CONFLICT FAIL)"
    static let v1IndexRecordsRecordIndex = "CREATE INDEX IndexRecordsRecordIndex ON IndexRecords (objectStoreID, objectStoreRecordID)"
    static let indexRecordsIndex = "CREATE INDEX IndexRecordsIndex ON IndexRecords (indexID, key, value)"

    static let tablePrefix = "CREATE TABLE "
    static let v3RecordsSuffix =
        " (objectStoreID INTEGER NOT NULL ON CONFLICT FAIL, key TEXT COLLATE IDBKEY NOT NULL ON CONFLICT FAIL, value NOT NULL ON CONFLICT FAIL, recordID INTEGER PRIMARY KEY)"
    static let v3IndexRecordsSuffix =
        " (indexID INTEGER NOT NULL ON CONFLICT FAIL, objectStoreID INTEGER NOT NULL ON CONFLICT FAIL, key TEXT COLLATE IDBKEY NOT NULL ON CONFLICT FAIL, value TEXT COLLATE IDBKEY NOT NULL ON CONFLICT FAIL, objectStoreRecordID INTEGER NOT NULL ON CONFLICT FAIL)"
    static let indexInfoSuffix =
        " (id INTEGER NOT NULL ON CONFLICT FAIL, name TEXT NOT NULL ON CONFLICT FAIL, objectStoreID INTEGER NOT NULL ON CONFLICT FAIL, keyPath BLOB NOT NULL ON CONFLICT FAIL, isUnique INTEGER NOT NULL ON CONFLICT FAIL, multiEntry INTEGER NOT NULL ON CONFLICT FAIL)"
    static let blobRecordsSuffix = " (objectStoreRow INTEGER NOT NULL ON CONFLICT FAIL, blobURL TEXT NOT NULL ON CONFLICT FAIL)"
    static let blobFilesSuffix =
        " (blobURL TEXT NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT FAIL, fileName TEXT NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT FAIL)"
    static let fileSystemHandleRecordsSuffix =
        " (objectStoreRow INTEGER NOT NULL ON CONFLICT FAIL, globalIdentifier BLOB NOT NULL ON CONFLICT FAIL, kind INTEGER NOT NULL ON CONFLICT FAIL, path TEXT NOT NULL ON CONFLICT FAIL, name TEXT NOT NULL ON CONFLICT FAIL)"

    static func v1Records(_ tableName: Swift.String) -> Swift.String {
        "CREATE TABLE " + tableName
            + " (objectStoreID INTEGER NOT NULL ON CONFLICT FAIL, key TEXT COLLATE IDBKEY NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT REPLACE, value NOT NULL ON CONFLICT FAIL)"
    }
    static func v2Records(_ tableName: Swift.String) -> Swift.String {
        "CREATE TABLE " + tableName
            + " (objectStoreID INTEGER NOT NULL ON CONFLICT FAIL, key TEXT COLLATE IDBKEY NOT NULL ON CONFLICT FAIL, value NOT NULL ON CONFLICT FAIL)"
    }
    static let v3Records = tablePrefix + "Records" + v3RecordsSuffix
    static let v3RecordsAlternate = tablePrefix + "\"Records\"" + v3RecordsSuffix
    static let v3RecordsTemp = tablePrefix + "_Temp_Records" + v3RecordsSuffix

    static func v1IndexRecords(_ tableName: Swift.String) -> Swift.String {
        "CREATE TABLE " + tableName
            + " (indexID INTEGER NOT NULL ON CONFLICT FAIL, objectStoreID INTEGER NOT NULL ON CONFLICT FAIL, key TEXT COLLATE IDBKEY NOT NULL ON CONFLICT FAIL, value NOT NULL ON CONFLICT FAIL)"
    }
    static func v2IndexRecords(_ tableName: Swift.String) -> Swift.String {
        "CREATE TABLE " + tableName
            + " (indexID INTEGER NOT NULL ON CONFLICT FAIL, objectStoreID INTEGER NOT NULL ON CONFLICT FAIL, key TEXT COLLATE IDBKEY NOT NULL ON CONFLICT FAIL, value TEXT COLLATE IDBKEY NOT NULL ON CONFLICT FAIL)"
    }
    static let v3IndexRecords = tablePrefix + "IndexRecords" + v3IndexRecordsSuffix
    static let v3IndexRecordsAlternate = tablePrefix + "\"IndexRecords\"" + v3IndexRecordsSuffix
    static let v3IndexRecordsTemp = tablePrefix + "_Temp_IndexRecords" + v3IndexRecordsSuffix

    static let blobRecords = tablePrefix + "BlobRecords" + blobRecordsSuffix
    static let blobRecordsAlternate = tablePrefix + "\"BlobRecords\"" + blobRecordsSuffix
    static let blobFiles = tablePrefix + "BlobFiles" + blobFilesSuffix
    static let blobFilesAlternate = tablePrefix + "\"BlobFiles\"" + blobFilesSuffix
    static let fileSystemHandleRecords = tablePrefix + "FileSystemHandleRecords" + fileSystemHandleRecordsSuffix
    static let fileSystemHandleRecordsAlternate = tablePrefix + "\"FileSystemHandleRecords\"" + fileSystemHandleRecordsSuffix

    static func v1ObjectStoreInfo(_ tableName: Swift.String) -> Swift.String {
        "CREATE TABLE " + tableName
            + " (id INTEGER PRIMARY KEY NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT FAIL, name TEXT NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT FAIL, keyPath BLOB NOT NULL ON CONFLICT FAIL, autoInc INTEGER NOT NULL ON CONFLICT FAIL, maxIndexID INTEGER NOT NULL ON CONFLICT FAIL)"
    }
    static func v2ObjectStoreInfo(_ tableName: Swift.String) -> Swift.String {
        "CREATE TABLE " + tableName
            + " (id INTEGER PRIMARY KEY NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT FAIL, name TEXT NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT FAIL, keyPath BLOB NOT NULL ON CONFLICT FAIL, autoInc INTEGER NOT NULL ON CONFLICT FAIL)"
    }
    static let indexInfo = tablePrefix + "IndexInfo" + indexInfoSuffix
    static let indexInfoTemp = tablePrefix + "_Temp_IndexInfo" + indexInfoSuffix
}

/// Whether the SQL text a table or index was created with (tableSQL, indexSQL) is `text`.
private func sqliteIDBSchemaIs(_ statement: WTF.String, _ text: Swift.String) -> Bool {
    WebCore.idbStringEqual(statement, sqliteIDBString(text))
}

// MARK: - The cached statements

/// The index of each statement in the cache.
enum SQLiteIDBStoreSQL: Int {
    case createObjectStoreInfo
    case createObjectStoreKeyGenerator
    case deleteObjectStoreInfo
    case deleteObjectStoreKeyGenerator
    case deleteObjectStoreRecords
    case deleteObjectStoreIndexInfo
    case deleteObjectStoreIndexRecords
    case deleteObjectStoreBlobRecords
    case renameObjectStore
    case clearObjectStoreRecords
    case clearObjectStoreIndexRecords
    case createIndexInfo
    case createTempIndexInfo
    case deleteIndexInfo
    case removeIndexInfo
    case getExistingPrimaryKeyForIndexKey
    case putIndexRecord
    case putTempIndexRecord
    case getIndexRecordForOneKey
    case deleteIndexRecords
    case renameIndex
    case keyExistsInObjectStore
    case getUnusedBlobFilenames
    case deleteUnusedBlobs
    case getObjectStoreRecord
    case deleteBlobRecord
    case deleteObjectStoreRecord
    case deleteObjectStoreIndexRecord
    case addObjectStoreRecord
    case addBlobRecord
    case blobFilenameForBlobURL
    case addBlobFilename
    case getBlobURL
    case addFileSystemHandleRecord
    case deleteFileSystemHandleRecordsByObjectStoreRow
    case deleteFileSystemHandleRecordsByObjectStoreID
    case getFileSystemHandleRecordsByObjectStoreRow
    case getKeyGeneratorValue
    case setKeyGeneratorValue
    case getObjectStoreRecords
    case getAllKeyRecordsLowerOpenUpperOpen
    case getAllKeyRecordsLowerOpenUpperClosed
    case getAllKeyRecordsLowerClosedUpperOpen
    case getAllKeyRecordsLowerClosedUpperClosed
    case getAllValueRecordsLowerOpenUpperOpen
    case getAllValueRecordsLowerOpenUpperClosed
    case getAllValueRecordsLowerClosedUpperOpen
    case getAllValueRecordsLowerClosedUpperClosed
    case getAllKeyRecordsLowerOpenUpperOpenDesc
    case getAllKeyRecordsLowerOpenUpperClosedDesc
    case getAllKeyRecordsLowerClosedUpperOpenDesc
    case getAllKeyRecordsLowerClosedUpperClosedDesc
    case getAllValueRecordsLowerOpenUpperOpenDesc
    case getAllValueRecordsLowerOpenUpperClosedDesc
    case getAllValueRecordsLowerClosedUpperOpenDesc
    case getAllValueRecordsLowerClosedUpperClosedDesc
    case countRecordsLowerOpenUpperOpen
    case countRecordsLowerOpenUpperClosed
    case countRecordsLowerClosedUpperOpen
    case countRecordsLowerClosedUpperClosed
    case countIndexRecordsLowerOpenUpperOpen
    case countIndexRecordsLowerOpenUpperClosed
    case countIndexRecordsLowerClosedUpperOpen
    case countIndexRecordsLowerClosedUpperClosed
}

/// The cache's size.
private let sqliteIDBCachedStatementCount = 64

// MARK: - The store

/// What extractExistingDatabaseInfo found: no database info table, the info, or an error.
private enum SQLiteIDBExistingInfo {
    case none
    case info(WebCore.IDBDatabaseInfo)
    case error(WebCore.IDBError)
}

/// The key of extractExistingDatabaseInfo's map from an index's old ID (with its object store) to its new one.
private struct SQLiteIDBIndexKey: Hashable {
    let objectStoreID: UInt64
    let indexID: UInt64
}

@_expose(Cxx)
final class SQLiteIDBStore {
    private let databaseName: WTF.String
    private let databaseDirectory: WTF.String
    /// The store on ":memory:", with no directory, file or blob files.
    let isInMemory: Bool
    /// The statement cache, 64 slots: each slot is filled on first use and dropped with the database.
    ///
    /// Owners only; a statement is reached through get() for one use.
    private var cachedStatements: InlineArray<64, WebCore.SQLiteStatementOwner?> = InlineArray { _ in nil }
    private var databaseInfo = WebCore.IDBDatabaseInfo()
    private var hasDatabaseInfo = false
    private var originalDatabaseInfoBeforeVersionChange = WebCore.IDBDatabaseInfo()
    private var hasOriginalDatabaseInfoBeforeVersionChange = false
    private var sqliteDB: WebCore.SQLiteDatabaseOwner? = nil
    private var transactions: ContiguousArray<SQLiteIDBStoreTransaction> = []
    /// The cursors the page opened, by identifier; each transaction unregisters its own as it closes them.
    private var registeredCursors: ContiguousArray<SQLiteIDBStoreCursor> = []
    /// forEachObjectStoreRecord's walk: its cursor and transaction while SwiftSQLiteIDBBackingStore applies each record.
    private var forEachCursor: SQLiteIDBStoreCursor? = nil
    private var forEachTransaction: SQLiteIDBStoreTransaction? = nil
    /// What its transactions hold instead of a weak reference to the store.
    private lazy var reference = SQLiteIDBStoreReference(self)
    /// The results of the backing store's calls, taken right after each call.
    private var pendingGetResult: WebCore.IDBGetResult? = nil
    private var pendingGetAllResult = WebCore.IDBGetAllResult()
    private var pendingNumber: UInt64 = 0
    /// Whether getCount reached the point where it zeroes its result (an earlier error leaves it alone).
    private var pendingNumberWritten = false
    private var pendingKeyExists = false

    @_expose(Cxx)
    init(databaseName: consuming WTF.String, databaseDirectory: consuming WTF.String, isInMemory: Bool) {
        self.databaseName = databaseName
        self.databaseDirectory = isInMemory ? WebCore.sqliteIDBEmptyString() : databaseDirectory
        self.isInMemory = isInMemory
    }

    deinit {
        reference.storeWillDeinitialize()
        closeSQLiteDB()
    }

    // MARK: Statements

    /// cachedStatement and SQLiteStatementAutoResetScope: `body` gets the cached statement (prepared on first use; nil
    /// when it does not prepare or the database is closed), which is reset when `body` returns. `query` is evaluated
    /// only to prepare the statement.
    private func withCachedStatement<R>(
        _ sql: SQLiteIDBStoreSQL,
        _ query: @autoclosure () -> Swift.String,
        _ body: (WebCore.SQLiteStatement?) -> R
    ) -> R {
        let slot = sql.rawValue
        var statement = cachedStatements[slot]?.get()
        if statement == nil, let database = sqliteDB?.get() {
            cachedStatements[slot] = database.prepareStatementForString(sqliteIDBString(query()))
            statement = cachedStatements[slot]?.get()
        }
        defer {
            if let statement {
                _ = statement.reset()
            }
        }
        return body(statement)
    }

    private func transaction(_ identifier: WebCore.IDBResourceIdentifier) -> SQLiteIDBStoreTransaction? {
        for transaction in transactions where WebCore.idbResourceIdentifierEqual(transaction.identifier, identifier) {
            return transaction
        }
        return nil
    }

    private func takeTransaction(_ identifier: WebCore.IDBResourceIdentifier) -> SQLiteIDBStoreTransaction? {
        for i in transactions.indices where WebCore.idbResourceIdentifierEqual(transactions[i].identifier, identifier) {
            return transactions.remove(at: i)
        }
        return nil
    }

    // MARK: Schema

    private func createOrMigrateRecordsTableIfNecessary(_ database: WebCore.SQLiteDatabase) -> WebCore.IDBError {
        let tableStatement = database.tableSQLForString(sqliteIDBString("Records"))
        if tableStatement.isEmpty() {
            if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.v3Records)) {
                return sqliteIDBDatabaseError("Error creating Records table", database)
            }
            return WebCore.makeSQLiteIDBNoError()
        }

        // If the schema in the backing store is the current schema, we're done.
        if sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v3Records)
            || sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v3RecordsAlternate)
        {
            return WebCore.makeSQLiteIDBNoError()
        }

        // Anything but a previous schema is an unrecoverable database.
        if !sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v1Records("Records"))
            && !sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v1Records("\"Records\""))
            && !sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v2Records("Records"))
            && !sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v2Records("\"Records\""))
        {
            WTFCrash()
        }

        var transaction = WebCore.SQLiteTransaction(database, false)
        transaction.beginTransaction()

        // Create a temporary table with the correct schema and migrate all existing content over.
        if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.v3RecordsTemp)) {
            return sqliteIDBDatabaseError("Error creating temporary Records table", database)
        }
        if !database.executeCommandForString(
            sqliteIDBString(
                "INSERT INTO _Temp_Records (objectStoreID, key, value) SELECT objectStoreID, CAST(key AS TEXT), value FROM Records"
            )
        ) {
            return sqliteIDBDatabaseError("Error migrating Records table", database)
        }
        if !database.executeCommandForString(sqliteIDBString("DROP TABLE Records")) {
            return sqliteIDBDatabaseError("Error dropping Records table", database)
        }
        if !database.executeCommandForString(sqliteIDBString("ALTER TABLE _Temp_Records RENAME TO Records")) {
            return sqliteIDBDatabaseError("Error renaming temporary Records table", database)
        }
        transaction.commit()
        return WebCore.makeSQLiteIDBNoError()
    }

    private func ensureValidBlobTables(_ database: WebCore.SQLiteDatabase) -> WebCore.IDBError {
        var recordsTableStatement = database.tableSQLForString(sqliteIDBString("BlobRecords"))
        if recordsTableStatement.isEmpty() {
            if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.blobRecords)) {
                return sqliteIDBDatabaseError("Error creating BlobRecords table", database)
            }
            recordsTableStatement = sqliteIDBString(SQLiteIDBSchema.blobRecords)
        }
        if !sqliteIDBSchemaIs(recordsTableStatement, SQLiteIDBSchema.blobRecords)
            && !sqliteIDBSchemaIs(recordsTableStatement, SQLiteIDBSchema.blobRecordsAlternate)
        {
            WTFCrash()
        }

        var filesTableStatement = database.tableSQLForString(sqliteIDBString("BlobFiles"))
        if filesTableStatement.isEmpty() {
            if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.blobFiles)) {
                return sqliteIDBDatabaseError("Error creating BlobFiles table", database)
            }
            filesTableStatement = sqliteIDBString(SQLiteIDBSchema.blobFiles)
        }
        if !sqliteIDBSchemaIs(filesTableStatement, SQLiteIDBSchema.blobFiles)
            && !sqliteIDBSchemaIs(filesTableStatement, SQLiteIDBSchema.blobFilesAlternate)
        {
            WTFCrash()
        }
        return WebCore.makeSQLiteIDBNoError()
    }

    private func ensureValidFileSystemHandleRecordsTable(_ database: WebCore.SQLiteDatabase) -> WebCore.IDBError {
        var tableStatement = database.tableSQLForString(sqliteIDBString("FileSystemHandleRecords"))
        if tableStatement.isEmpty() {
            if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.fileSystemHandleRecords)) {
                return sqliteIDBDatabaseError("Error creating FileSystemHandleRecords table", database)
            }
            tableStatement = sqliteIDBString(SQLiteIDBSchema.fileSystemHandleRecords)
        }
        if !sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.fileSystemHandleRecords)
            && !sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.fileSystemHandleRecordsAlternate)
        {
            WTFCrash()
        }
        return WebCore.makeSQLiteIDBNoError()
    }

    private func ensureValidRecordsTable(_ database: WebCore.SQLiteDatabase) -> WebCore.IDBError {
        let error = createOrMigrateRecordsTableIfNecessary(database)
        if !error.isNull() {
            return error
        }
        // Whether the records table existed or was just created and migrated, make sure the uniqueness index exists.
        if !database.executeCommandForString(
            sqliteIDBString("CREATE UNIQUE INDEX IF NOT EXISTS RecordsIndex ON Records (objectStoreID, key);")
        ) {
            return sqliteIDBDatabaseError("Error creating RecordsIndex on Records table", database)
        }
        return error
    }

    private func ensureValidIndexRecordsTable(_ database: WebCore.SQLiteDatabase) -> WebCore.IDBError {
        let tableStatement = database.tableSQLForString(sqliteIDBString("IndexRecords"))
        if tableStatement.isEmpty() {
            if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.v3IndexRecords)) {
                return sqliteIDBDatabaseError("Error creating IndexRecords table", database)
            }
            return WebCore.makeSQLiteIDBNoError()
        }

        // If the schema in the backing store is the current schema, we're done.
        if sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v3IndexRecords)
            || sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v3IndexRecordsAlternate)
        {
            return WebCore.makeSQLiteIDBNoError()
        }

        if !sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v1IndexRecords("IndexRecords"))
            && !sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v1IndexRecords("\"IndexRecords\""))
            && !sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v2IndexRecords("IndexRecords"))
            && !sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v2IndexRecords("\"IndexRecords\""))
        {
            WTFCrash()
        }

        var transaction = WebCore.SQLiteTransaction(database, false)
        transaction.beginTransaction()

        // Create a temporary table with the correct schema and migrate all existing content over.
        if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.v3IndexRecordsTemp)) {
            return sqliteIDBDatabaseError("Error creating temporary IndexRecords table", database)
        }
        if !database.executeCommandForString(
            sqliteIDBString(
                "INSERT INTO _Temp_IndexRecords SELECT IndexRecords.indexID, IndexRecords.objectStoreID, IndexRecords.key, IndexRecords.value, Records.rowid FROM IndexRecords INNER JOIN Records ON Records.key = IndexRecords.value AND Records.objectStoreID = IndexRecords.objectStoreID"
            )
        ) {
            return sqliteIDBDatabaseError("Error migrating IndexRecords table", database)
        }
        if !database.executeCommandForString(sqliteIDBString("DROP TABLE IndexRecords")) {
            return sqliteIDBDatabaseError("Error dropping IndexRecords table", database)
        }
        if !database.executeCommandForString(sqliteIDBString("ALTER TABLE _Temp_IndexRecords RENAME TO IndexRecords")) {
            return sqliteIDBDatabaseError("Error renaming temporary IndexRecords table", database)
        }
        transaction.commit()
        return WebCore.makeSQLiteIDBNoError()
    }

    private func ensureValidIndexRecordsIndex(_ database: WebCore.SQLiteDatabase) -> WebCore.IDBError {
        let indexStatement = database.indexSQLForString(sqliteIDBString("IndexRecordsIndex"))
        if sqliteIDBSchemaIs(indexStatement, SQLiteIDBSchema.indexRecordsIndex) {
            return WebCore.makeSQLiteIDBNoError()
        }
        if !database.executeCommandForString(sqliteIDBString("DROP INDEX IF EXISTS IndexRecordsIndex")) {
            return sqliteIDBDatabaseError("Error dropping IndexRecordsIndex index", database)
        }
        if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.indexRecordsIndex)) {
            return sqliteIDBDatabaseError("Error creating IndexRecordsIndex index", database)
        }
        return WebCore.makeSQLiteIDBNoError()
    }

    private func ensureValidIndexRecordsRecordIndex(_ database: WebCore.SQLiteDatabase) -> WebCore.IDBError {
        let indexStatement = database.indexSQLForString(sqliteIDBString("IndexRecordsRecordIndex"))
        if sqliteIDBSchemaIs(indexStatement, SQLiteIDBSchema.v1IndexRecordsRecordIndex) {
            return WebCore.makeSQLiteIDBNoError()
        }
        if !database.executeCommandForString(sqliteIDBString("DROP INDEX IF EXISTS IndexRecordsRecordIndex")) {
            return sqliteIDBDatabaseError("Error dropping IndexRecordsRecordIndex index", database)
        }
        if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.v1IndexRecordsRecordIndex)) {
            return sqliteIDBDatabaseError("Error creating IndexRecordsRecordIndex index", database)
        }
        return WebCore.makeSQLiteIDBNoError()
    }

    /// The metadata tables of a new database, and its info (version 0). nil on any failure.
    private func createAndPopulateInitialDatabaseInfo(_ database: WebCore.SQLiteDatabase) -> WebCore.IDBDatabaseInfo? {
        if !database.executeCommandForString(
            sqliteIDBString(
                "CREATE TABLE IDBDatabaseInfo (key TEXT NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT REPLACE, value TEXT NOT NULL ON CONFLICT FAIL);"
            )
        ) {
            return nil
        }
        if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.v2ObjectStoreInfo)) {
            return nil
        }
        if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.indexInfo)) {
            return nil
        }
        if !database.executeCommandForString(
            sqliteIDBString(
                "CREATE TABLE KeyGenerators (objectStoreID INTEGER NOT NULL ON CONFLICT FAIL UNIQUE ON CONFLICT REPLACE, currentKey INTEGER NOT NULL ON CONFLICT FAIL);"
            )
        ) {
            return nil
        }
        let insertedVersion = Self.withStatement(database, "INSERT INTO IDBDatabaseInfo VALUES ('MetadataVersion', ?);") { statement in
            guard let statement else {
                return false
            }
            return statement.bindInt(1, sqliteIDBCurrentMetadataVersion) == sqliteIDBResultOK && statement.step() == sqliteIDBResultDone
        }
        if !insertedVersion {
            return nil
        }
        let insertedName = Self.withStatement(database, "INSERT INTO IDBDatabaseInfo VALUES ('DatabaseName', ?);") { statement in
            guard let statement else {
                return false
            }
            return statement.bindBlob(1, databaseName) == sqliteIDBResultOK && statement.step() == sqliteIDBResultDone
        }
        if !insertedName {
            return nil
        }
        // Database versions are uint64_t in the spec, which SQLite cannot bind, so the version is stored as text.
        let insertedDatabaseVersion = Self.withStatement(database, "INSERT INTO IDBDatabaseInfo VALUES ('DatabaseVersion', ?);") {
            statement in
            guard let statement else {
                return false
            }
            return statement.bindString(1, WebCore.sqliteIDBStringFromUInt64(0)) == sqliteIDBResultOK
                && statement.step() == sqliteIDBResultDone
        }
        if !insertedDatabaseVersion {
            return nil
        }
        if !database.executeCommandForString(sqliteIDBString("INSERT INTO IDBDatabaseInfo VALUES ('MaxObjectStoreID', 1);")) {
            return nil
        }
        // This initial database info matches the default values just put into the metadata database.
        return WebCore.makeSQLiteIDBDatabaseInfo(databaseName, 0, 0)
    }

    /// nil when the table is missing or its migration fails, else whether the table was upgraded (the v1 schema's
    /// maxIndexID column dropped).
    private func ensureValidObjectStoreInfoTable(_ database: WebCore.SQLiteDatabase) -> Bool? {
        let tableStatement = database.tableSQLForString(sqliteIDBString("ObjectStoreInfo"))
        if tableStatement.isEmpty() {
            return nil
        }
        if sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v2ObjectStoreInfo)
            || sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v2ObjectStoreInfo(SQLiteIDBSchema.objectStoreInfoTableNameAlternate))
        {
            return false
        }
        if !sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v1ObjectStoreInfo(SQLiteIDBSchema.objectStoreInfoTableName))
            && !sqliteIDBSchemaIs(tableStatement, SQLiteIDBSchema.v1ObjectStoreInfo(SQLiteIDBSchema.objectStoreInfoTableNameAlternate))
        {
            WTFCrash()
        }

        // Drop column maxIndexID from table.
        var transaction = WebCore.SQLiteTransaction(database, false)
        transaction.beginTransaction()
        if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.v2ObjectStoreInfo("_Temp_ObjectStoreInfo"))) {
            return nil
        }
        if !database.executeCommandForString(
            sqliteIDBString(
                "INSERT INTO _Temp_ObjectStoreInfo (id, name, keyPath, autoInc) SELECT id, name, keyPath, autoInc FROM ObjectStoreInfo"
            )
        ) {
            return nil
        }
        if !database.executeCommandForString(sqliteIDBString("DROP TABLE ObjectStoreInfo")) {
            return nil
        }
        if !database.executeCommandForString(sqliteIDBString("ALTER TABLE _Temp_ObjectStoreInfo RENAME TO ObjectStoreInfo")) {
            return nil
        }
        transaction.commit()
        return true
    }

    /// The new index ID for a row, from the map filled from every IndexInfo row; traps when the map has no entry.
    private static func newIndexID(_ map: [SQLiteIDBIndexKey: UInt64], _ objectStoreID: UInt64, _ indexID: UInt64) -> UInt64 {
        guard let newID = map[SQLiteIDBIndexKey(objectStoreID: objectStoreID, indexID: indexID)] else {
            WTFCrash()
        }
        return newID
    }

    private func migrateIndexInfoTableForIDUpdate(_ database: WebCore.SQLiteDatabase, _ indexIDMap: [SQLiteIDBIndexKey: UInt64]) -> Bool {
        var transaction = WebCore.SQLiteTransaction(database, false)
        transaction.beginTransaction()
        if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.indexInfoTemp)) {
            return false
        }
        let migrated = Self.withStatement(database, "SELECT id, name, objectStoreID, keyPath, isUnique, multiEntry FROM IndexInfo;") {
            statement -> Bool in
            guard let statement else {
                return false
            }
            var result = statement.step()
            while result == sqliteIDBResultRow {
                let id = UInt64(bitPattern: statement.columnInt64(0))
                let name = statement.columnText(1)
                let objectStoreID = UInt64(bitPattern: statement.columnInt64(2))
                let newID = Self.newIndexID(indexIDMap, objectStoreID, id)
                let keyPath = statement.columnBlob(3)
                let unique = statement.columnInt(4) != 0
                let multiEntry = statement.columnInt(5) != 0
                let added = withCachedStatement(.createTempIndexInfo, "INSERT INTO _Temp_IndexInfo VALUES (?, ?, ?, ?, ?, ?);") {
                    indexStatement in
                    guard let indexStatement else {
                        return false
                    }
                    return indexStatement.bindInt64(1, Int64(bitPattern: newID)) == sqliteIDBResultOK
                        && indexStatement.bindString(2, name) == sqliteIDBResultOK
                        && indexStatement.bindInt64(3, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK
                        && sqliteIDBBindBytes(indexStatement, 4, keyPath) == sqliteIDBResultOK
                        && indexStatement.bindInt(5, unique ? 1 : 0) == sqliteIDBResultOK
                        && indexStatement.bindInt(6, multiEntry ? 1 : 0) == sqliteIDBResultOK
                        && indexStatement.step() == sqliteIDBResultDone
                }
                if !added {
                    return false
                }
                result = statement.step()
            }
            return result == sqliteIDBResultDone
        }
        if !migrated {
            return false
        }
        if !database.executeCommandForString(sqliteIDBString("DROP TABLE IndexInfo")) {
            return false
        }
        if !database.executeCommandForString(sqliteIDBString("ALTER TABLE _Temp_IndexInfo RENAME TO IndexInfo")) {
            return false
        }
        transaction.commit()
        return true
    }

    private func migrateIndexRecordsTableForIDUpdate(_ database: WebCore.SQLiteDatabase, _ indexIDMap: [SQLiteIDBIndexKey: UInt64]) -> Bool
    {
        var transaction = WebCore.SQLiteTransaction(database, false)
        transaction.beginTransaction()
        if !database.executeCommandForString(sqliteIDBString(SQLiteIDBSchema.v3IndexRecordsTemp)) {
            return false
        }
        let migrated = Self.withStatement(database, "SELECT indexID, objectStoreID, key, value, objectStoreRecordID FROM IndexRecords;") {
            statement -> Bool in
            guard let statement else {
                return false
            }
            var result = statement.step()
            while result == sqliteIDBResultRow {
                let id = UInt64(bitPattern: statement.columnInt64(0))
                let objectStoreID = UInt64(bitPattern: statement.columnInt64(1))
                let newID = Self.newIndexID(indexIDMap, objectStoreID, id)
                let key = statement.columnBlob(2)
                let value = statement.columnBlob(3)
                let recordID = statement.columnInt64(4)
                let added = withCachedStatement(
                    .putTempIndexRecord,
                    "INSERT INTO _Temp_IndexRecords VALUES (?, ?, CAST(? AS TEXT), CAST(? AS TEXT), ?);"
                ) { indexStatement in
                    guard let indexStatement else {
                        return false
                    }
                    return indexStatement.bindInt64(1, Int64(bitPattern: newID)) == sqliteIDBResultOK
                        && indexStatement.bindInt64(2, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK
                        && sqliteIDBBindBytes(indexStatement, 3, key) == sqliteIDBResultOK
                        && sqliteIDBBindBytes(indexStatement, 4, value) == sqliteIDBResultOK
                        && indexStatement.bindInt64(5, recordID) == sqliteIDBResultOK
                        && indexStatement.step() == sqliteIDBResultDone
                }
                if !added {
                    return false
                }
                result = statement.step()
            }
            return result == sqliteIDBResultDone
        }
        if !migrated {
            return false
        }
        if !database.executeCommandForString(sqliteIDBString("DROP TABLE IndexRecords")) {
            return false
        }
        if !database.executeCommandForString(sqliteIDBString("ALTER TABLE _Temp_IndexRecords RENAME TO IndexRecords")) {
            return false
        }
        transaction.commit()
        return true
    }

    // MARK: Metadata

    private static func databaseNameFromDatabase(
        _ database: WebCore.SQLiteDatabase,
        _ metadataVersion: UInt64
    ) -> (WTF.String, WebCore.IDBError) {
        Self.withStatement(database, "SELECT value FROM IDBDatabaseInfo WHERE key = 'DatabaseName';") { statement in
            guard let statement else {
                return (WTF.String(), sqliteIDBUnknownError("Cannot get stored database name"))
            }
            let name = metadataVersion == 1 ? statement.columnText(0) : statement.columnBlobAsString(0)
            return (name, WebCore.makeSQLiteIDBNoError())
        }
    }

    private static func databaseMetadataVersionAndName(_ database: WebCore.SQLiteDatabase) -> (UInt64, WTF.String, WebCore.IDBError) {
        var metadataVersion: UInt64 = 0
        let versionError = Self.withStatement(database, "SELECT value FROM IDBDatabaseInfo WHERE key = 'MetadataVersion';") {
            statement -> WebCore.IDBError in
            guard let statement else {
                return sqliteIDBDatabaseError("Failed to prepare statement for getting metadata version", database)
            }
            let stringVersion = statement.columnText(0)
            if !WebCore.sqliteIDBParseUInt64(stringVersion, &metadataVersion) {
                return WebCore.makeSQLiteIDBValueError(
                    sqliteIDBString("Database metadata version on disk ("),
                    stringVersion,
                    sqliteIDBString(") cannot be converted to unsigned 64-bit integer")
                )
            }
            return WebCore.makeSQLiteIDBNoError()
        }
        if !versionError.isNull() {
            return (0, WTF.String(), versionError)
        }
        let (name, error) = databaseNameFromDatabase(database, metadataVersion)
        if !error.isNull() {
            return (0, WTF.String(), error)
        }
        return (metadataVersion, name, error)
    }

    private static func migrateIDBDatabaseInfoTableIfNecessary(
        _ database: WebCore.SQLiteDatabase,
        _ databaseName: WTF.String
    ) -> WebCore.IDBError {
        let tableStatement = database.tableSQLForString(sqliteIDBString("IDBDatabaseInfo"))
        if tableStatement.isEmpty() {
            return sqliteIDBDatabaseError("IDBDatabaseInfo table does not exist", database)
        }
        var (metadataVersion, existingDatabaseName, error) = databaseMetadataVersionAndName(database)
        if !error.isNull() {
            return error
        }
        // UTF-8 encoded names always match, whatever the metadata version.
        if !WebCore.sqliteIDBStringsEqualAsUTF8(existingDatabaseName, databaseName) {
            var validated = false
            // Some clients have the newer metadata version with the old name (rdar://163219457): downgrade the
            // metadata version so that the database is upgraded again.
            if metadataVersion == 2 {
                let (utf8ExistingDatabaseName, nameError) = databaseNameFromDatabase(database, 1)
                if nameError.isNull() && WebCore.idbStringEqual(utf8ExistingDatabaseName, databaseName) {
                    metadataVersion = 1
                    validated = true
                    WebCore.sqliteIDBLogMismatchedMetadataVersion()
                }
            }
            if !validated {
                return sqliteIDBUnknownError("Stored database name does not match requested name")
            }
        }

        if metadataVersion == UInt64(sqliteIDBCurrentMetadataVersion) {
            if WebCore.idbStringEqual(existingDatabaseName, databaseName) {
                return WebCore.makeSQLiteIDBNoError()
            }
            return sqliteIDBUnknownError("Metadata versions match, but stored database name does not match requested name")
        }
        if metadataVersion >= UInt64(sqliteIDBCurrentMetadataVersion) {
            WTFCrash()
        }

        var transaction = WebCore.SQLiteTransaction(database, false)
        transaction.beginTransaction()
        error = Self.withStatement(database, "REPLACE INTO IDBDatabaseInfo VALUES ('DatabaseName', ?);") { statement in
            guard let statement, statement.bindBlob(1, databaseName) == sqliteIDBResultOK, statement.step() == sqliteIDBResultDone else {
                return sqliteIDBDatabaseError("Cannot update database name", database)
            }
            return WebCore.makeSQLiteIDBNoError()
        }
        if !error.isNull() {
            return error
        }
        error = Self.withStatement(database, "REPLACE INTO IDBDatabaseInfo VALUES ('MetadataVersion', ?);") { statement in
            guard let statement, statement.bindInt(1, sqliteIDBCurrentMetadataVersion) == sqliteIDBResultOK,
                statement.step() == sqliteIDBResultDone
            else {
                return sqliteIDBDatabaseError("Cannot update database metadata version", database)
            }
            return WebCore.makeSQLiteIDBNoError()
        }
        if !error.isNull() {
            return error
        }
        transaction.commit()
        return WebCore.makeSQLiteIDBNoError()
    }

    /// A statement prepared for one use.
    private static func withStatement<R>(
        _ database: WebCore.SQLiteDatabase,
        _ query: Swift.String,
        _ body: (WebCore.SQLiteStatement?) -> R
    ) -> R {
        var owner = database.prepareStatementForString(sqliteIDBString(query))
        let result = body(owner.get())
        owner.reset()
        return result
    }

    private func extractExistingDatabaseInfo(_ database: WebCore.SQLiteDatabase) -> SQLiteIDBExistingInfo {
        if !database.tableExistsForString(sqliteIDBString("IDBDatabaseInfo")) {
            return .none
        }
        let error = Self.migrateIDBDatabaseInfoTableIfNecessary(database, databaseName)
        if !error.isNull() {
            return .error(error)
        }

        var databaseVersion: UInt64 = 0
        let versionError = Self.withStatement(database, "SELECT value FROM IDBDatabaseInfo WHERE key = 'DatabaseVersion';") {
            statement -> WebCore.IDBError in
            guard let statement else {
                WTFCrash()
            }
            let stringVersion = statement.columnText(0)
            if !WebCore.sqliteIDBParseUInt64(stringVersion, &databaseVersion) {
                return WebCore.makeSQLiteIDBValueError(
                    sqliteIDBString("Stored database version ("),
                    stringVersion,
                    sqliteIDBString(") is not valid integer")
                )
            }
            return WebCore.makeSQLiteIDBNoError()
        }
        if !versionError.isNull() {
            return .error(versionError)
        }

        var info = WebCore.makeSQLiteIDBDatabaseInfo(databaseName, databaseVersion, 0)
        guard let upgraded = ensureValidObjectStoreInfoTable(database) else {
            return .error(sqliteIDBUnknownError("Stored object info table is invalid"))
        }
        let shouldUpdateIndexID = upgraded

        let objectStoresError = Self.withStatement(database, "SELECT id, name, keyPath, autoInc FROM ObjectStoreInfo;") {
            statement -> WebCore.IDBError in
            guard let statement else {
                return sqliteIDBUnknownError("Failed to object store info from database")
            }
            var result = statement.step()
            while result == sqliteIDBResultRow {
                let objectStoreID = WebCore.makeSQLiteIDBObjectStoreIdentifier(UInt64(bitPattern: statement.columnInt64(0)))
                let objectStoreName = statement.columnText(1)
                let keyPath = statement.columnBlob(2)
                let autoIncrement = statement.columnInt(3) != 0
                if !WebCore.sqliteIDBAddExistingObjectStore(&info, objectStoreID, objectStoreName, keyPath, autoIncrement) {
                    return sqliteIDBUnknownError("Cannot extract key path from database")
                }
                result = statement.step()
            }
            if result != sqliteIDBResultDone {
                return sqliteIDBUnknownError("Failed to complete object store info fetching from database")
            }
            return WebCore.makeSQLiteIDBNoError()
        }
        if !objectStoresError.isNull() {
            return .error(objectStoresError)
        }

        var maxIndexID: UInt64 = 0
        var indexIDMap: [SQLiteIDBIndexKey: UInt64] = [:]
        var existingIndexIDs = Set<UInt64>()
        let indexesError = Self.withStatement(database, "SELECT id, name, objectStoreID, keyPath, isUnique, multiEntry FROM IndexInfo;") {
            statement -> WebCore.IDBError in
            guard let statement else {
                return sqliteIDBUnknownError("Failed to fetch index info from database")
            }
            var result = statement.step()
            while result == sqliteIDBResultRow {
                var indexID = UInt64(bitPattern: statement.columnInt64(0))
                let indexName = statement.columnText(1)
                let objectStoreID = UInt64(bitPattern: statement.columnInt64(2))
                let keyPath = statement.columnBlob(3)
                if !WebCore.sqliteIDBIndexKeyPathIsValid(keyPath) {
                    return sqliteIDBUnknownError("Failed to extract index key path from database")
                }
                let unique = statement.columnInt(4) != 0
                let multiEntry = statement.columnInt(5) != 0
                let objectStoreIdentifier = WebCore.makeSQLiteIDBObjectStoreIdentifier(objectStoreID)
                if !WebCore.idbDatabaseInfoHasObjectStore(&info, objectStoreIdentifier) {
                    return sqliteIDBUnknownError("Index refers to a non-existent object store")
                }
                if shouldUpdateIndexID {
                    maxIndexID += 1
                    indexIDMap[SQLiteIDBIndexKey(objectStoreID: objectStoreID, indexID: indexID)] = maxIndexID
                    indexID = maxIndexID
                } else if !existingIndexIDs.insert(indexID).inserted {
                    return sqliteIDBUnknownError("Index with the same ID already exists")
                }
                WebCore.sqliteIDBAddExistingIndex(
                    &info,
                    WebCore.makeSQLiteIDBIndexIdentifier(indexID),
                    objectStoreIdentifier,
                    indexName,
                    keyPath,
                    unique,
                    multiEntry
                )
                maxIndexID = maxIndexID < indexID ? indexID : maxIndexID
                result = statement.step()
            }
            if result != sqliteIDBResultDone {
                return sqliteIDBUnknownError("Failed to complete index info fetching from database")
            }
            return WebCore.makeSQLiteIDBNoError()
        }
        if !indexesError.isNull() {
            return .error(indexesError)
        }
        info.setMaxIndexID(maxIndexID)

        if shouldUpdateIndexID {
            if !migrateIndexInfoTableForIDUpdate(database, indexIDMap) || !migrateIndexRecordsTableForIDUpdate(database, indexIDMap) {
                return .error(sqliteIDBUnknownError("Stored index records table is invalid"))
            }
        }
        return .info(info)
    }

    // MARK: Opening and closing

    @_expose(Cxx)
    func databasePath() -> WTF.String {
        fullDatabasePath
    }

    var fullDatabasePath: WTF.String {
        isInMemory ? WTF.String() : WebCore.sqliteIDBFullDatabasePath(databaseDirectory)
    }

    /// Opens (and creates, or migrates) the database file on first use.
    func getOrEstablishDatabaseInfo() -> (WebCore.IDBError, WebCore.IDBDatabaseInfo) {
        if hasDatabaseInfo {
            return (WebCore.makeSQLiteIDBNoError(), databaseInfo)
        }

        let databasePath = fullDatabasePath
        if !isInMemory {
            WebCore.sqliteIDBMakeParentDirectories(databasePath)
        }
        // The info is missing with the database open only after a version change whose begin failed was committed. The
        // database is closed first: replacing it under its cached statements trips their CheckedRefs.
        if sqliteDB != nil {
            closeSQLiteDB()
        }
        sqliteDB = WebCore.makeSQLiteDatabase()
        // Each step takes the database as an argument, never a local of this function: closeSQLiteDB() deletes it, and
        // a reference still held would turn the deletion into CheckedPtr's zero-and-leak.
        if isInMemory {
            let opened = sqliteDB?.get().map { WebCore.sqliteIDBOpenMemoryDatabase($0) } ?? false
            if !opened {
                closeSQLiteDB()
                return (sqliteIDBUnknownError("Unable to open in-memory database"), WebCore.IDBDatabaseInfo())
            }
        } else if !SQLiteIDBStore.openDatabase(sqliteDB?.get(), databasePath) {
            closeSQLiteDB()
            return (sqliteIDBUnknownError("Unable to open database file on disk"), WebCore.IDBDatabaseInfo())
        }
        guard let established = sqliteDB?.get().map({ establish($0) }) else {
            WTFCrash()
        }
        switch established {
        case .error(let error):
            closeSQLiteDB()
            return (error, WebCore.IDBDatabaseInfo())
        case .none:
            closeSQLiteDB()
            return (
                sqliteIDBUnknownError(isInMemory ? "Unable to establish IDB in-memory database" : "Unable to establish IDB database file"),
                WebCore.IDBDatabaseInfo()
            )
        case .info(let info):
            databaseInfo = info
            hasDatabaseInfo = true
            return (WebCore.makeSQLiteIDBNoError(), info)
        }
    }

    /// Opens the database file (false, logged, when it does not open).
    private static func openDatabase(_ database: WebCore.SQLiteDatabase?, _ databasePath: WTF.String) -> Bool {
        guard let database else {
            return false
        }
        let options = WebCore.SQLiteDatabaseOpenOptions(WebCore.SQLiteDatabase.OpenOptions.CanSuspendWhileLocked)
        if !database.open(databasePath, WebCore.SQLiteDatabase.OpenMode.ReadWriteCreate, options) {
            WebCore.sqliteIDBLogOpenFailure(databasePath, database)
            return false
        }
        return true
    }

    /// The rest of getOrEstablishDatabaseInfo on the opened database: the collation, the tables, and the info (.none
    /// when a new database's metadata cannot be created).
    private func establish(_ database: WebCore.SQLiteDatabase) -> SQLiteIDBExistingInfo {
        if isInMemory {
            WebCore.sqliteIDBPrepareOpenedMemoryDatabase(database)
        } else {
            WebCore.sqliteIDBPrepareOpenedDatabase(database)
        }

        var error = ensureValidRecordsTable(database)
        if error.isNull() {
            error = ensureValidIndexRecordsTable(database)
        }
        if error.isNull() {
            error = ensureValidIndexRecordsIndex(database)
        }
        if error.isNull() {
            error = ensureValidIndexRecordsRecordIndex(database)
        }
        if error.isNull() {
            error = ensureValidBlobTables(database)
        }
        if error.isNull() {
            error = ensureValidFileSystemHandleRecordsTable(database)
        }
        if !error.isNull() {
            return .error(error)
        }

        switch extractExistingDatabaseInfo(database) {
        case .error(let error):
            return .error(error)
        case .info(let existing):
            return .info(existing)
        case .none:
            guard let created = createAndPopulateInitialDatabaseInfo(database) else {
                return .none
            }
            return .info(created)
        }
    }

    /// The info's, or the file's without opening the store.
    @_expose(Cxx)
    func databaseVersion() -> UInt64 {
        if hasDatabaseInfo {
            return databaseInfo.version()
        }
        let databaseFilename = fullDatabasePath
        if !WebCore.sqliteIDBFileExists(databaseFilename) {
            return 0
        }
        return SQLiteIDBStore.databaseNameAndVersionFromFile(databaseFilename)?.1 ?? 0
    }

    /// Nil when the file does not open, has no metadata, or has version 0.
    static func databaseNameAndVersionFromFile(_ databasePath: WTF.String) -> (WTF.String, UInt64)? {
        var owner = WebCore.makeSQLiteDatabase()
        let result = owner.get().flatMap { nameAndVersion($0, databasePath) }
        owner.reset()
        return result
    }

    private static func nameAndVersion(_ database: WebCore.SQLiteDatabase, _ databasePath: WTF.String) -> (WTF.String, UInt64)? {
        let options = WebCore.SQLiteDatabaseOpenOptions()
        if !database.open(databasePath, WebCore.SQLiteDatabase.OpenMode.ReadWriteCreate, options) {
            return nil
        }
        if !database.tableExistsForString(sqliteIDBString("IDBDatabaseInfo")) {
            return nil
        }
        let (_, databaseName, error) = databaseMetadataVersionAndName(database)
        if !error.isNull() {
            return nil
        }
        let stringVersion = Self.withStatement(database, "SELECT value FROM IDBDatabaseInfo WHERE key = 'DatabaseVersion';") { statement in
            statement?.columnText(0) ?? WTF.String()
        }
        var databaseVersion: UInt64 = 0
        if !WebCore.sqliteIDBParseUInt64(stringVersion, &databaseVersion) {
            return nil
        }
        if databaseVersion == 0 {
            return nil
        }
        return (databaseName, databaseVersion)
    }

    /// Closes the transactions first (they roll back through the database), then the statements, then the database.
    func closeSQLiteDB() {
        // The cursors' statements go before the database.
        forEachCursor?.dropStatements()
        forEachCursor = nil
        forEachTransaction = nil
        for transaction in transactions {
            transaction.dropCursorStatements()
        }
        transactions.removeAll()
        for i in 0..<sqliteIDBCachedStatementCount {
            cachedStatements[i] = nil
        }
        sqliteDB?.get()?.close()
        sqliteDB = nil
    }

    @_expose(Cxx)
    func close() {
        closeSQLiteDB()
    }

    /// The blob files the database names, then the database file and its directory if empty.
    ///
    /// Opens the file to read the blob files' names when the store has not.
    @_expose(Cxx)
    func deleteBackingStore() {
        if isInMemory {
            return
        }
        let databasePath = fullDatabasePath
        if WebCore.sqliteIDBFileExists(databasePath) && sqliteDB == nil {
            sqliteDB = WebCore.makeSQLiteDatabase()
            let opened =
                sqliteDB?.get()?.open(databasePath, WebCore.SQLiteDatabase.OpenMode.ReadWriteCreate, WebCore.SQLiteDatabaseOpenOptions())
                ?? false
            if !opened {
                closeSQLiteDB()
            }
        }
        if let database = sqliteDB?.get() {
            let blobFiles = Self.withStatement(database, "SELECT fileName FROM BlobFiles;") { statement -> [WTF.String] in
                var names: [WTF.String] = []
                guard let statement else {
                    return names
                }
                var result = statement.step()
                while result == sqliteIDBResultRow {
                    names.append(statement.columnText(0))
                    result = statement.step()
                }
                return names
            }
            for file in blobFiles {
                WebCore.sqliteIDBDeleteFile(WebCore.sqliteIDBPathByAppendingComponent(databaseDirectory, file))
            }
        }
        if sqliteDB != nil {
            closeSQLiteDB()
        }
        WebCore.sqliteIDBDeleteDatabaseFileAndEmptyDirectory(databasePath, databaseDirectory)
    }

    @_expose(Cxx)
    func handleLowMemoryWarning() {
        sqliteDB?.get()?.releaseMemory()
    }

    @_expose(Cxx)
    func hasTransaction(_ identifier: WebCore.IDBResourceIdentifier) -> Bool {
        transaction(identifier) != nil
    }

    // MARK: Transactions

    /// Takes the transaction info's fields, not the info (its `consuming` form crashes this toolchain's move-only
    /// checker, and only these fields are read).
    @_expose(Cxx)
    func beginTransaction(
        _ identifier: consuming WebCore.IDBResourceIdentifier,
        _ mode: WebCore.IDBTransactionMode,
        _ durability: WebCore.IDBTransactionDurability,
        _ newVersion: UInt64
    ) -> WebCore.IDBError {
        if transaction(identifier) != nil {
            return sqliteIDBUnknownError("Attempt to establish transaction identifier that already exists")
        }
        let transaction = SQLiteIDBStoreTransaction(identifier, mode, durability, databaseDirectory)
        transaction.storeReference = reference
        transactions.append(transaction)
        guard let database = sqliteDB?.get() else {
            WTFCrash()
        }
        var error = transaction.begin(database)
        if error.isNull() && mode == .Versionchange {
            requireDatabaseInfo()
            originalDatabaseInfoBeforeVersionChange = databaseInfo
            hasOriginalDatabaseInfoBeforeVersionChange = true
            let stored = Self.withStatement(database, "UPDATE IDBDatabaseInfo SET value = ? where key = 'DatabaseVersion';") { statement in
                guard let statement else {
                    return false
                }
                return statement.bindString(1, WebCore.sqliteIDBStringFromUInt64(newVersion)) == sqliteIDBResultOK
                    && statement.step() == sqliteIDBResultDone
            }
            if !stored {
                error = sqliteIDBUnknownError("Failed to store new database version in database")
            }
        }
        return error
    }

    /// Before the first getOrEstablishDatabaseInfo, and after a version change whose begin failed was committed, the
    /// info is missing: trap rather than read an empty info.
    private func requireDatabaseInfo() {
        if !hasDatabaseInfo {
            WTFCrash()
        }
    }

    private func restoreOriginalDatabaseInfo() {
        databaseInfo = originalDatabaseInfoBeforeVersionChange
        dropOriginalDatabaseInfo()
    }

    private func dropOriginalDatabaseInfo() {
        originalDatabaseInfoBeforeVersionChange = WebCore.IDBDatabaseInfo()
        hasOriginalDatabaseInfoBeforeVersionChange = false
    }

    @_expose(Cxx)
    func abortTransaction(_ identifier: consuming WebCore.IDBResourceIdentifier) -> WebCore.IDBError {
        guard let transaction = takeTransaction(identifier) else {
            return sqliteIDBUnknownError("Attempt to abort a transaction that hasn't been established")
        }
        if transaction.mode == .Versionchange && hasOriginalDatabaseInfoBeforeVersionChange {
            restoreOriginalDatabaseInfo()
        }
        return transaction.abort()
    }

    @_expose(Cxx)
    func commitTransaction(_ identifier: consuming WebCore.IDBResourceIdentifier) -> WebCore.IDBError {
        guard let transaction = takeTransaction(identifier) else {
            return sqliteIDBUnknownError("Attempt to commit a transaction that hasn't been established")
        }
        let error = transaction.commit()
        if !error.isNull() {
            if transaction.mode == .Versionchange {
                // A version change whose begin failed has no original info; the next getOrEstablishDatabaseInfo
                // reloads it.
                if hasOriginalDatabaseInfoBeforeVersionChange {
                    restoreOriginalDatabaseInfo()
                } else {
                    databaseInfo = WebCore.IDBDatabaseInfo()
                    hasDatabaseInfo = false
                }
            }
        } else {
            dropOriginalDatabaseInfo()
            if transaction.durability == .Strict, let database = sqliteDB?.get() {
                database.checkpoint(.Full)
            }
        }
        return error
    }

    // MARK: Object stores

    @_expose(Cxx)
    func createObjectStore(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ info: __owned WebCore.IDBObjectStoreInfo
    ) -> WebCore.IDBError {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgressOrReadOnly else {
            return sqliteIDBUnknownError("Attempt to create an object store without an in-progress transaction")
        }
        if transaction.mode != .Versionchange {
            return sqliteIDBUnknownError("Attempt to create an object store in a non-version-change transaction")
        }
        var keyPath = WebCore.IDBSerializedKeyBytes()
        if !WebCore.sqliteIDBSerializeObjectStoreKeyPath(info, &keyPath) {
            return sqliteIDBUnknownError("Unable to serialize IDBKeyPath to save in database for new object store")
        }
        let identifier = info.identifier().toUInt64()
        let name = WebCore.idbObjectStoreInfoName(info)
        let autoIncrement = info.autoIncrement()
        let created = withCachedStatement(.createObjectStoreInfo, "INSERT INTO ObjectStoreInfo VALUES (?, ?, ?, ?);") { statement in
            guard let statement else {
                return false
            }
            return statement.bindInt64(1, Int64(bitPattern: identifier)) == sqliteIDBResultOK
                && statement.bindString(2, name) == sqliteIDBResultOK
                && sqliteIDBBindBytes(statement, 3, keyPath) == sqliteIDBResultOK
                && statement.bindInt(4, autoIncrement ? 1 : 0) == sqliteIDBResultOK
                && statement.step() == sqliteIDBResultDone
        }
        if !created {
            return sqliteIDBUnknownError("Could not create object store")
        }
        let seeded = withCachedStatement(.createObjectStoreKeyGenerator, "INSERT INTO KeyGenerators VALUES (?, 0);") { statement in
            guard let statement else {
                return false
            }
            return statement.bindInt64(1, Int64(bitPattern: identifier)) == sqliteIDBResultOK && statement.step() == sqliteIDBResultDone
        }
        if !seeded {
            return sqliteIDBUnknownError("Could not seed initial key generator value for object store")
        }
        requireDatabaseInfo()
        databaseInfo.addExistingObjectStore(info)
        return WebCore.makeSQLiteIDBNoError()
    }

    /// The object store's records and index records; its cursors are told.
    @_expose(Cxx)
    func clearObjectStore(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier
    ) -> WebCore.IDBError {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Attempt to clear an object store without an in-progress transaction")
        }
        if transaction.mode == .Readonly {
            return sqliteIDBUnknownError("Attempt to clear an object store in a read-only transaction")
        }
        let identifier = objectStoreIdentifier.toUInt64()
        var error = deleteFileSystemHandleRecordsForObjectStore(identifier)
        if !error.isNull() {
            return error
        }
        error = deleteRows(
            .clearObjectStoreRecords,
            "DELETE FROM Records WHERE objectStoreID = ?;",
            identifier,
            "Unable to clear object store"
        )
        if !error.isNull() {
            return error
        }
        error = deleteRows(
            .clearObjectStoreIndexRecords,
            "DELETE FROM IndexRecords WHERE objectStoreID = ?;",
            identifier,
            "Unable to delete index records while clearing object store"
        )
        if !error.isNull() {
            return error
        }
        transaction.notifyCursorsOfChanges(identifier)
        return WebCore.makeSQLiteIDBNoError()
    }

    /// One `DELETE ... WHERE <column> = ?` of an object store's rows, with its error message.
    private func deleteRows(
        _ sql: SQLiteIDBStoreSQL,
        _ query: Swift.String,
        _ identifier: UInt64,
        _ message: Swift.String
    ) -> WebCore.IDBError {
        let deleted = withCachedStatement(sql, query) { statement in
            guard let statement else {
                return false
            }
            return statement.bindInt64(1, Int64(bitPattern: identifier)) == sqliteIDBResultOK && statement.step() == sqliteIDBResultDone
        }
        return deleted ? WebCore.makeSQLiteIDBNoError() : sqliteIDBUnknownError(message)
    }

    private func deleteFileSystemHandleRecordsForObjectStore(_ objectStoreID: UInt64) -> WebCore.IDBError {
        deleteRows(
            .deleteFileSystemHandleRecordsByObjectStoreID,
            "DELETE FROM FileSystemHandleRecords WHERE objectStoreRow IN (SELECT recordID FROM Records WHERE objectStoreID = ?);",
            objectStoreID,
            "Failed to delete FileSystemHandleRecords"
        )
    }

    private func deleteUnusedBlobFileRecords(_ transaction: SQLiteIDBStoreTransaction) -> WebCore.IDBError {
        // Gather the blob file names no longer in use.
        var removedBlobFilenames: [WTF.String] = []
        let gathered = withCachedStatement(
            .getUnusedBlobFilenames,
            "SELECT fileName FROM BlobFiles WHERE blobURL NOT IN (SELECT blobURL FROM BlobRecords)"
        ) { statement -> Bool in
            guard let statement else {
                return false
            }
            var result = statement.step()
            while result == sqliteIDBResultRow {
                let filename = statement.columnText(0)
                if !removedBlobFilenames.contains(where: { WebCore.idbStringEqual($0, filename) }) {
                    removedBlobFilenames.append(filename)
                }
                result = statement.step()
            }
            return result == sqliteIDBResultDone
        }
        if !gathered {
            return sqliteIDBUnknownError("Error deleting stored blobs")
        }
        // Remove the blob records no longer in use.
        if !removedBlobFilenames.isEmpty {
            let deleted = withCachedStatement(
                .deleteUnusedBlobs,
                "DELETE FROM BlobFiles WHERE blobURL NOT IN (SELECT blobURL FROM BlobRecords)"
            ) { statement in
                guard let statement else {
                    return false
                }
                return statement.step() == sqliteIDBResultDone
            }
            if !deleted {
                return sqliteIDBUnknownError("Error deleting stored blobs")
            }
        }
        for filename in removedBlobFilenames {
            transaction.addRemovedBlobFile(filename)
        }
        return WebCore.makeSQLiteIDBNoError()
    }

    @_expose(Cxx)
    func deleteObjectStore(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier
    ) -> WebCore.IDBError {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Attempt to delete an object store without an in-progress transaction")
        }
        if transaction.mode != .Versionchange {
            return sqliteIDBUnknownError("Attempt to delete an object store in a non-version-change transaction")
        }
        let identifier = objectStoreIdentifier.toUInt64()
        var error = deleteFileSystemHandleRecordsForObjectStore(identifier)
        if !error.isNull() {
            return error
        }
        error = deleteRows(.deleteObjectStoreInfo, "DELETE FROM ObjectStoreInfo WHERE id = ?;", identifier, "Could not delete object store")
        if !error.isNull() {
            return error
        }
        error = deleteRows(
            .deleteObjectStoreKeyGenerator,
            "DELETE FROM KeyGenerators WHERE objectStoreID = ?;",
            identifier,
            "Could not delete key generator for deleted object store"
        )
        if !error.isNull() {
            return error
        }
        error = deleteRows(
            .deleteObjectStoreRecords,
            "DELETE FROM Records WHERE objectStoreID = ?;",
            identifier,
            "Could not delete records for deleted object store"
        )
        if !error.isNull() {
            return error
        }
        error = deleteRows(
            .deleteObjectStoreIndexInfo,
            "DELETE FROM IndexInfo WHERE objectStoreID = ?;",
            identifier,
            "Could not delete IDBIndex for deleted object store"
        )
        if !error.isNull() {
            return error
        }
        error = deleteRows(
            .deleteObjectStoreIndexRecords,
            "DELETE FROM IndexRecords WHERE objectStoreID = ?;",
            identifier,
            "Could not delete IDBIndex records for deleted object store"
        )
        if !error.isNull() {
            return error
        }
        // Delete every unused blob URL record.
        let deletedBlobRecords = withCachedStatement(
            .deleteObjectStoreBlobRecords,
            "DELETE FROM BlobRecords WHERE objectStoreRow NOT IN (SELECT recordID FROM Records)"
        ) { statement in
            guard let statement else {
                return false
            }
            return statement.step() == sqliteIDBResultDone
        }
        if !deletedBlobRecords {
            return sqliteIDBUnknownError("Could not delete stored blob records for deleted object store")
        }
        // Delete every unused blob file record.
        error = deleteUnusedBlobFileRecords(transaction)
        if !error.isNull() {
            return error
        }
        requireDatabaseInfo()
        databaseInfo.deleteObjectStore(objectStoreIdentifier)
        return WebCore.makeSQLiteIDBNoError()
    }

    @_expose(Cxx)
    func renameObjectStore(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ newName: consuming WTF.String
    ) -> WebCore.IDBError {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Attempt to rename an object store without an in-progress transaction")
        }
        if transaction.mode != .Versionchange {
            return sqliteIDBUnknownError("Attempt to rename an object store in a non-version-change transaction")
        }
        let identifier = objectStoreIdentifier.toUInt64()
        let renamed = withCachedStatement(.renameObjectStore, "UPDATE ObjectStoreInfo SET name = ? WHERE id = ?;") { statement in
            guard let statement else {
                return false
            }
            return statement.bindString(1, newName) == sqliteIDBResultOK
                && statement.bindInt64(2, Int64(bitPattern: identifier)) == sqliteIDBResultOK
                && statement.step() == sqliteIDBResultDone
        }
        if !renamed {
            return sqliteIDBUnknownError("Could not rename object store")
        }
        requireDatabaseInfo()
        databaseInfo.renameObjectStore(objectStoreIdentifier, newName)
        return WebCore.makeSQLiteIDBNoError()
    }

    // MARK: Indexes

    @_expose(Cxx)
    func addIndex(_ transactionIdentifier: WebCore.IDBResourceIdentifier, _ indexInfo: __owned WebCore.IDBIndexInfo) -> WebCore.IDBError {
        guard let database = sqliteDB?.get(), database.isOpen() else {
            return sqliteIDBUnknownError("Database connection is closed.")
        }
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Transaction is not in progress.")
        }
        if transaction.mode != .Versionchange {
            return sqliteIDBUnknownError("Transaction is not in versionchange mode.")
        }
        if !hasDatabaseInfo {
            WebCore.sqliteIDBLogMissingDatabaseInfo(sqliteIDBString("addIndex"))
            return sqliteIDBUnknownError("Database info is invalid.")
        }
        let objectStoreIdentifier = indexInfo.objectStoreIdentifier()
        if !WebCore.idbDatabaseInfoHasObjectStore(&databaseInfo, objectStoreIdentifier) {
            WebCore.sqliteIDBLogMissingObjectStore(sqliteIDBString("addIndex"))
            return sqliteIDBUnknownError("Object store cannot be found in the database.")
        }
        var keyPath = WebCore.IDBSerializedKeyBytes()
        if !WebCore.sqliteIDBSerializeIndexKeyPath(indexInfo, &keyPath) {
            return sqliteIDBUnknownError("Failed to serialize IDBKeyPath to create index in database.")
        }
        let identifier = indexInfo.identifier().toUInt64()
        let name = WebCore.idbIndexInfoName(indexInfo)
        let unique = indexInfo.unique()
        let multiEntry = indexInfo.multiEntry()
        let created = withCachedStatement(.createIndexInfo, "INSERT INTO IndexInfo VALUES (?, ?, ?, ?, ?, ?);") { statement in
            guard let statement else {
                return false
            }
            return statement.bindInt64(1, Int64(bitPattern: identifier)) == sqliteIDBResultOK
                && statement.bindString(2, name) == sqliteIDBResultOK
                && statement.bindInt64(3, Int64(bitPattern: objectStoreIdentifier.toUInt64())) == sqliteIDBResultOK
                && sqliteIDBBindBytes(statement, 4, keyPath) == sqliteIDBResultOK
                && statement.bindInt(5, unique ? 1 : 0) == sqliteIDBResultOK
                && statement.bindInt(6, multiEntry ? 1 : 0) == sqliteIDBResultOK
                && statement.step() == sqliteIDBResultDone
        }
        if !created {
            return sqliteIDBUnknownError("Failed to create index in database.")
        }
        WebCore.sqliteIDBDatabaseInfoAddIndex(&databaseInfo, indexInfo)
        databaseInfo.setMaxIndexID(identifier)
        return WebCore.makeSQLiteIDBNoError()
    }

    @_expose(Cxx)
    func revertAddIndex(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: consuming WebCore.IDBIndexIdentifier
    ) {
        _ = deleteIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier)
    }

    @_expose(Cxx)
    func deleteIndex(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: consuming WebCore.IDBIndexIdentifier
    ) -> WebCore.IDBError {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Attempt to delete index without an in-progress transaction")
        }
        if transaction.mode != .Versionchange {
            return sqliteIDBUnknownError("Attempt to delete index during a non-version-change transaction")
        }
        let indexID = indexIdentifier.toUInt64()
        let objectStoreID = objectStoreIdentifier.toUInt64()
        let deletedInfo = withCachedStatement(.deleteIndexInfo, "DELETE FROM IndexInfo WHERE id = ? AND objectStoreID = ?;") { statement in
            guard let statement else {
                return false
            }
            return statement.bindInt64(1, Int64(bitPattern: indexID)) == sqliteIDBResultOK
                && statement.bindInt64(2, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK
                && statement.step() == sqliteIDBResultDone
        }
        if !deletedInfo {
            return sqliteIDBUnknownError("Error deleting index from database")
        }
        let error = deleteRows(
            .deleteIndexRecords,
            "DELETE FROM IndexRecords WHERE indexID = ?;",
            indexID,
            "Error deleting index records from database"
        )
        if !error.isNull() {
            return error
        }
        requireDatabaseInfo()
        WebCore.sqliteIDBDatabaseInfoDeleteIndex(&databaseInfo, objectStoreIdentifier, indexIdentifier)
        return WebCore.makeSQLiteIDBNoError()
    }

    @_expose(Cxx)
    func renameIndex(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: consuming WebCore.IDBIndexIdentifier,
        _ newName: consuming WTF.String
    ) -> WebCore.IDBError {
        requireDatabaseInfo()
        if !WebCore.idbDatabaseInfoHasIndex(&databaseInfo, objectStoreIdentifier, indexIdentifier) {
            return sqliteIDBUnknownError("Could not rename index")
        }
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Attempt to rename an index without an in-progress transaction")
        }
        if transaction.mode != .Versionchange {
            return sqliteIDBUnknownError("Attempt to rename an index in a non-version-change transaction")
        }
        let objectStoreID = objectStoreIdentifier.toUInt64()
        let indexID = indexIdentifier.toUInt64()
        let renamed = withCachedStatement(.renameIndex, "UPDATE IndexInfo SET name = ? WHERE objectStoreID = ? AND id = ?;") { statement in
            guard let statement else {
                return false
            }
            return statement.bindString(1, newName) == sqliteIDBResultOK
                && statement.bindInt64(2, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK
                && statement.bindInt64(3, Int64(bitPattern: indexID)) == sqliteIDBResultOK
                && statement.step() == sqliteIDBResultDone
        }
        if !renamed {
            return sqliteIDBUnknownError("Could not rename index")
        }
        WebCore.sqliteIDBDatabaseInfoRenameIndex(&databaseInfo, objectStoreIdentifier, indexIdentifier, newName)
        return WebCore.makeSQLiteIDBNoError()
    }

    // MARK: The key generator

    private func readKeyGeneratorValue(_ objectStoreID: UInt64) -> (WebCore.IDBError, UInt64) {
        withCachedStatement(.getKeyGeneratorValue, "SELECT currentKey FROM KeyGenerators WHERE objectStoreID = ?;") { statement in
            guard let statement, statement.bindInt64(1, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK else {
                return (sqliteIDBUnknownError("Error getting current key generator value from database"), 0)
            }
            if statement.step() != sqliteIDBResultRow {
                return (sqliteIDBUnknownError("Error finding current key generator value in database"), 0)
            }
            let value = statement.columnInt64(0)
            if value < 0 {
                return (sqliteIDBConstraintError("Current key generator value from database is invalid"), 0)
            }
            return (WebCore.makeSQLiteIDBNoError(), UInt64(value))
        }
    }

    private func writeKeyGeneratorValue(_ objectStoreID: UInt64, _ value: UInt64) -> WebCore.IDBError {
        let stored = withCachedStatement(.setKeyGeneratorValue, "INSERT INTO KeyGenerators VALUES (?, ?);") { statement in
            guard let statement else {
                return false
            }
            return statement.bindInt64(1, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK
                && statement.bindInt64(2, Int64(bitPattern: value)) == sqliteIDBResultOK
                && statement.step() == sqliteIDBResultDone
        }
        return stored ? WebCore.makeSQLiteIDBNoError() : sqliteIDBConstraintError("Error storing new key generator value in database")
    }

    /// The third element: whether the number was generated, so SwiftSQLiteIDBBackingStore writes it to its out-parameter
    /// even when storing it then failed.
    func generateKeyNumber(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier
    ) -> (WebCore.IDBError, UInt64, Bool) {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return (sqliteIDBUnknownError("Attempt to generate key in database without an in-progress transaction"), 0, false)
        }
        if transaction.mode == .Readonly {
            return (sqliteIDBUnknownError("Attempt to generate key in a read-only transaction"), 0, false)
        }
        let objectStoreID = objectStoreIdentifier.toUInt64()
        let (error, currentValue) = readKeyGeneratorValue(objectStoreID)
        if !error.isNull() {
            return (error, 0, false)
        }
        // currentValue <= Int64.max (the column read is checked non-negative), so the sum does not overflow.
        if currentValue + 1 > sqliteIDBMaxGeneratorValue {
            return (sqliteIDBConstraintError("Cannot generate new key value over 2^53 for object store operation"), 0, false)
        }
        let generatedKey = currentValue + 1
        return (writeKeyGeneratorValue(objectStoreID, generatedKey), generatedKey, true)
    }

    @_expose(Cxx)
    func revertGeneratedKeyNumber(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ newKeyNumber: UInt64
    ) -> WebCore.IDBError {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Attempt to revert key generator value in database without an in-progress transaction")
        }
        if transaction.mode == .Readonly {
            return sqliteIDBUnknownError("Attempt to revert key generator value in a read-only transaction")
        }
        return writeKeyGeneratorValue(objectStoreIdentifier.toUInt64(), newKeyNumber &- 1)
    }

    @_expose(Cxx)
    func maybeUpdateKeyGeneratorNumber(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ newKeyNumber: Double
    ) -> WebCore.IDBError {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Attempt to update key generator value in database without an in-progress transaction")
        }
        if transaction.mode == .Readonly {
            return sqliteIDBUnknownError("Attempt to update key generator value in a read-only transaction")
        }
        let objectStoreID = objectStoreIdentifier.toUInt64()
        let (error, currentValue) = readKeyGeneratorValue(objectStoreID)
        if !error.isNull() {
            return error
        }
        if newKeyNumber <= Double(currentValue) {
            return WebCore.makeSQLiteIDBNoError()
        }
        // Capped at 2^53 and above currentValue >= 0, so in range. A NaN stores 0.
        let capped = Swift.min(newKeyNumber, Double(sqliteIDBMaxGeneratorValue))
        return writeKeyGeneratorValue(objectStoreID, capped.isNaN ? 0 : UInt64(capped))
    }

    // MARK: Cursor support

    /// The open database, for the cursors' statements.
    @_expose(!Cxx) // For the cursors only: SQLiteDatabase is not declared in SwiftIDBTypes.h.
    func currentDatabase() -> WebCore.SQLiteDatabase? {
        sqliteDB?.get()
    }

    @_expose(!Cxx)
    func unregisterCursor(_ cursor: SQLiteIDBStoreCursor) {
        registeredCursors.removeAll { WebCore.idbResourceIdentifierEqual($0.identifier, cursor.identifier) }
    }

    private func registerCursor(_ cursor: SQLiteIDBStoreCursor) {
        for i in registeredCursors.indices where WebCore.idbResourceIdentifierEqual(registeredCursors[i].identifier, cursor.identifier) {
            registeredCursors[i] = cursor
            return
        }
        registeredCursors.append(cursor)
    }

    private func registeredCursor(_ identifier: WebCore.IDBResourceIdentifier) -> SQLiteIDBStoreCursor? {
        for cursor in registeredCursors where WebCore.idbResourceIdentifierEqual(cursor.identifier, identifier) {
            return cursor
        }
        return nil
    }

    private func hasObjectStoreInfo(_ objectStoreID: UInt64) -> Bool {
        requireDatabaseInfo()
        return WebCore.idbDatabaseInfoHasObjectStore(&databaseInfo, WebCore.makeSQLiteIDBObjectStoreIdentifier(objectStoreID))
    }

    /// An object store or index cursor over `range`, key and value, closed by the caller.
    private func openBackingStoreCursor(
        _ transaction: SQLiteIDBStoreTransaction,
        _ objectStoreID: UInt64,
        _ indexID: UInt64?,
        _ range: WebCore.IDBKeyRangeData,
        _ direction: WebCore.IndexedDB.CursorDirection = .Next
    ) -> SQLiteIDBStoreCursor? {
        let cursor = SQLiteIDBStoreCursor(
            store: self,
            transaction: transaction,
            identifier: transaction.identifier,
            objectStoreID: objectStoreID,
            indexID: indexID,
            direction: direction,
            isKeyAndValue: true,
            range: range,
            isBackingStoreCursor: true
        )
        return transaction.maybeOpenBackingStoreCursor(cursor)
    }

    // MARK: Blobs and file system handles

    /// The record's blob URLs (distinct, in a HashSet's order) and their files.
    @_expose(!Cxx)
    func getBlobRecordsForObjectStoreRecord(
        _ recordID: Int64
    ) -> (WebCore.IDBError, WebCore.SQLiteIDBStringVector, WebCore.SQLiteIDBStringVector) {
        var blobURLs = WebCore.SQLiteIDBStringVector()
        var blobFilePaths = WebCore.SQLiteIDBStringVector()
        let lookupError = "Failed to look up blobURL records in object store by key range"
        var urls = WebCore.SQLiteIDBStringVector()
        let gathered: Bool? = withCachedStatement(.getBlobURL, "SELECT blobURL FROM BlobRecords WHERE objectStoreRow = ?") {
            statement -> Bool? in
            guard let statement, statement.bindInt64(1, recordID) == sqliteIDBResultOK else {
                return false
            }
            var result = statement.step()
            if result == sqliteIDBResultOK || result == sqliteIDBResultDone {
                // No blob URLs for this record.
                return nil
            }
            while result == sqliteIDBResultRow {
                WebCore.sqliteIDBAppendString(&urls, statement.columnText(0))
                result = statement.step()
            }
            return result == sqliteIDBResultDone
        }
        guard let gathered else {
            return (WebCore.makeSQLiteIDBNoError(), blobURLs, blobFilePaths)
        }
        if !gathered {
            return (sqliteIDBUnknownError(lookupError), blobURLs, blobFilePaths)
        }
        let distinct = WebCore.sqliteIDBDistinctStringsInHashOrder(urls)
        for i in 0..<WebCore.idbStringVectorSize(distinct) {
            let blobURL = WebCore.idbStringVectorAt(distinct, i)
            let fileName: WTF.String? = withCachedStatement(.blobFilenameForBlobURL, "SELECT fileName FROM BlobFiles WHERE blobURL = ?;") {
                statement in
                guard let statement, statement.bindString(1, blobURL) == sqliteIDBResultOK, statement.step() == sqliteIDBResultRow else {
                    return nil
                }
                return statement.columnText(0)
            }
            guard let fileName else {
                return (sqliteIDBUnknownError(lookupError), blobURLs, blobFilePaths)
            }
            WebCore.sqliteIDBAppendString(&blobURLs, blobURL)
            WebCore.sqliteIDBAppendString(&blobFilePaths, WebCore.sqliteIDBPathByAppendingComponent(databaseDirectory, fileName))
        }
        return (WebCore.makeSQLiteIDBNoError(), blobURLs, blobFilePaths)
    }

    private func addFileSystemHandleRecords(_ recordID: Int64, _ value: WebCore.IDBValue) -> WebCore.IDBError {
        let count = WebCore.sqliteIDBValueFileSystemHandleRecordCount(value)
        for i in 0..<count {
            let added = withCachedStatement(.addFileSystemHandleRecord, "INSERT INTO FileSystemHandleRecords VALUES (?, ?, ?, ?, ?);") {
                statement in
                guard let statement else {
                    return false
                }
                return WebCore.sqliteIDBBindFileSystemHandleRecord(statement, recordID, value, i) && statement.step() == sqliteIDBResultDone
            }
            if !added {
                return sqliteIDBUnknownError("Failed to record FileSystemHandle in database")
            }
        }
        return WebCore.makeSQLiteIDBNoError()
    }

    private func deleteFileSystemHandleRecordsForObjectStoreRecord(_ recordID: Int64) -> WebCore.IDBError {
        deleteRows(
            .deleteFileSystemHandleRecordsByObjectStoreRow,
            "DELETE FROM FileSystemHandleRecords WHERE objectStoreRow = ?;",
            UInt64(bitPattern: recordID),
            "Failed to delete FileSystemHandleRecords"
        )
    }

    /// The value with its blobs and its file system handle records.
    @_expose(!Cxx)
    func buildIDBValueForRecord(
        _ recordID: Int64,
        _ data: WebCore.ThreadSafeDataBuffer,
        _ blobURLs: WebCore.SQLiteIDBStringVector,
        _ blobFilePaths: WebCore.SQLiteIDBStringVector
    ) -> (WebCore.IDBError, WebCore.IDBValue) {
        var records = WebCore.SQLiteIDBFileSystemHandleRecords()
        let result: Int = withCachedStatement(
            .getFileSystemHandleRecordsByObjectStoreRow,
            "SELECT globalIdentifier, kind, path, name FROM FileSystemHandleRecords WHERE objectStoreRow = ? ORDER BY rowid;"
        ) { statement in
            guard let statement, statement.bindInt64(1, recordID) == sqliteIDBResultOK else {
                return 1
            }
            var step = statement.step()
            while step == sqliteIDBResultRow {
                if !WebCore.sqliteIDBAppendFileSystemHandleRecord(
                    &records,
                    statement.columnBlob(0),
                    statement.columnInt(1),
                    statement.columnText(2),
                    statement.columnText(3)
                ) {
                    return 2
                }
                step = statement.step()
            }
            return step == sqliteIDBResultDone ? 0 : 1
        }
        if result == 1 {
            return (sqliteIDBUnknownError("Failed to look up FileSystemHandleRecords"), WebCore.IDBValue())
        }
        if result == 2 {
            return (sqliteIDBUnknownError("FileSystemHandleRecords row corrupt"), WebCore.IDBValue())
        }
        return (WebCore.makeSQLiteIDBNoError(), WebCore.makeSQLiteIDBValue(data, blobURLs, blobFilePaths, records))
    }

    /// getBlobRecordsForObjectStoreRecord then buildIDBValueForRecord.
    private func valueForRecord(_ recordID: Int64, _ data: WebCore.ThreadSafeDataBuffer) -> (WebCore.IDBError, WebCore.IDBValue) {
        let (error, blobURLs, blobFilePaths) = getBlobRecordsForObjectStoreRecord(recordID)
        if !error.isNull() {
            return (error, WebCore.IDBValue())
        }
        return buildIDBValueForRecord(recordID, data, blobURLs, blobFilePaths)
    }

    // MARK: Index records

    /// Whether an index record has this key, and its primary key.
    private func existingPrimaryKey(_ indexID: UInt64, _ indexKey: WebCore.IDBKeyData) -> (WebCore.IDBError, WebCore.IDBKeyData?) {
        let keyBytes = serializeIDBKeyDataBytes(indexKey)
        var primaryKey = WebCore.IDBKeyData()
        let result: Int = withCachedStatement(
            .getExistingPrimaryKeyForIndexKey,
            "SELECT value FROM IndexRecords WHERE indexID = ? AND key = CAST(? AS TEXT);"
        ) { statement in
            guard let statement, statement.bindInt64(1, Int64(bitPattern: indexID)) == sqliteIDBResultOK,
                sqliteIDBBindBytes(statement, 2, keyBytes) == sqliteIDBResultOK
            else {
                return 1
            }
            let step = statement.step()
            if step == sqliteIDBResultOK || step == sqliteIDBResultDone {
                return 0
            }
            if step != sqliteIDBResultRow {
                return 2
            }
            return WebCore.sqliteIDBColumnKey(statement, 0, &primaryKey) ? 4 : 3
        }
        switch result {
        case 0:
            return (WebCore.makeSQLiteIDBNoError(), nil)
        case 1:
            return (sqliteIDBUnknownError("Error checking for index record in database"), nil)
        case 2:
            return (sqliteIDBUnknownError("Error checking for existence of IDBKey in index"), nil)
        case 3:
            return (sqliteIDBUnknownError("Unable to deserialize primary key referenced by index record"), nil)
        default:
            return (WebCore.makeSQLiteIDBNoError(), primaryKey)
        }
    }

    /// An index key's keys: its entries for a multi-entry index, else the key itself.
    private static func keys(_ indexKey: WebCore.IndexKey, multiEntry: Bool) -> [WebCore.IDBKeyData] {
        if !multiEntry {
            return [indexKey.asOneKey()]
        }
        let vector = indexKey.multiEntry()
        let elements: Span<WebCore.IDBKeyData> = WebCore.idbKeyVectorElements(vector)
        var result: [WebCore.IDBKeyData] = []
        result.reserveCapacity(elements.count)
        for i in 0..<elements.count {
            result.append(elements[i])
        }
        return result
    }

    private func checkIndexConstraintsForPut(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreInfo: inout WebCore.IDBObjectStoreInfo,
        _ key: WebCore.IDBKeyData,
        _ indexKeys: WebCore.IDBIndexKeyMapEntries
    ) -> WebCore.IDBError {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Attempt to check index constraints without an in-progress transaction")
        }
        _ = transaction
        let entries: Span<WebCore.IDBIndexKeyMapEntry> = WebCore.idbIndexKeyMapEntryElements(indexKeys)
        for i in 0..<entries.count {
            let indexIdentifier = entries[i].identifier
            if !WebCore.sqliteIDBObjectStoreHasIndex(&objectStoreInfo, indexIdentifier) {
                return WebCore.makeSQLiteIDBInvalidStateError(sqliteIDBString("Missing index metadata"))
            }
            let indexInfo = WebCore.sqliteIDBObjectStoreIndex(&objectStoreInfo, indexIdentifier)
            if !indexInfo.unique() {
                continue
            }
            for indexKey in SQLiteIDBStore.keys(entries[i].key, multiEntry: indexInfo.multiEntry()) where indexKey.isValid() {
                let (error, existing) = existingPrimaryKey(indexIdentifier.toUInt64(), indexKey)
                if !error.isNull() {
                    return error
                }
                if let existing, !memoryIDBKeyDataEqual(existing, key) {
                    return sqliteIDBConstraintError(
                        "Unable to store record in object store because it does not satisfy the uniqueness requirements of an index"
                    )
                }
            }
        }
        return WebCore.makeSQLiteIDBNoError()
    }

    /// The index records of one index key, after the uniqueness check of a unique index.
    private func putIndexKey(
        _ indexInfo: WebCore.IDBIndexInfo,
        _ key: WebCore.IDBKeyData,
        _ indexKey: WebCore.IndexKey,
        _ recordID: Int64
    ) -> WebCore.IDBError {
        let indexKeys = SQLiteIDBStore.keys(indexKey, multiEntry: indexInfo.multiEntry())
        let indexID = indexInfo.identifier().toUInt64()
        if indexInfo.unique() {
            for oneKey in indexKeys where oneKey.isValid() {
                let (error, existing) = existingPrimaryKey(indexID, oneKey)
                if !error.isNull() {
                    return error
                }
                if existing != nil {
                    return sqliteIDBConstraintError("Index key is not unique")
                }
            }
        }
        let objectStoreID = indexInfo.objectStoreIdentifier().toUInt64()
        for oneKey in indexKeys where oneKey.isValid() {
            let error = putIndexRecord(objectStoreID, indexID, key, oneKey, recordID)
            if !error.isNull() {
                return error
            }
        }
        return WebCore.makeSQLiteIDBNoError()
    }

    private func putIndexRecord(
        _ objectStoreID: UInt64,
        _ indexID: UInt64,
        _ key: WebCore.IDBKeyData,
        _ indexKey: WebCore.IDBKeyData,
        _ recordID: Int64
    ) -> WebCore.IDBError {
        let indexKeyBytes = serializeIDBKeyDataBytes(indexKey)
        let valueBytes = serializeIDBKeyDataBytes(key)
        let put = withCachedStatement(.putIndexRecord, "INSERT INTO IndexRecords VALUES (?, ?, CAST(? AS TEXT), CAST(? AS TEXT), ?);") {
            statement in
            guard let statement else {
                return false
            }
            return statement.bindInt64(1, Int64(bitPattern: indexID)) == sqliteIDBResultOK
                && statement.bindInt64(2, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK
                && sqliteIDBBindBytes(statement, 3, indexKeyBytes) == sqliteIDBResultOK
                && sqliteIDBBindBytes(statement, 4, valueBytes) == sqliteIDBResultOK
                && statement.bindInt64(5, recordID) == sqliteIDBResultOK
                && statement.step() == sqliteIDBResultDone
        }
        return put ? WebCore.makeSQLiteIDBNoError() : sqliteIDBUnknownError("Error putting index record into database")
    }

    private func deleteIndexRecordsOfRecord(_ objectStoreID: UInt64, _ recordID: Int64) -> Bool {
        withCachedStatement(.deleteObjectStoreIndexRecord, "DELETE FROM IndexRecords WHERE objectStoreID = ? AND objectStoreRecordID = ?;")
        { statement in
            guard let statement else {
                return false
            }
            return statement.bindInt64(1, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK
                && statement.bindInt64(2, recordID) == sqliteIDBResultOK
                && statement.step() == sqliteIDBResultDone
        }
    }

    private func deleteRecordRow(_ objectStoreID: UInt64, _ keyBytes: WebCore.IDBSerializedKeyBytes) -> Bool {
        withCachedStatement(.deleteObjectStoreRecord, "DELETE FROM Records WHERE objectStoreID = ? AND key = CAST(? AS TEXT);") {
            statement in
            guard let statement else {
                return false
            }
            return statement.bindInt64(1, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK
                && sqliteIDBBindBytes(statement, 2, keyBytes) == sqliteIDBResultOK
                && statement.step() == sqliteIDBResultDone
        }
    }

    private func updateAllIndexesForAddRecord(
        _ objectStoreInfo: inout WebCore.IDBObjectStoreInfo,
        _ key: WebCore.IDBKeyData,
        _ indexKeys: WebCore.IDBIndexKeyMapEntries,
        _ recordID: Int64
    ) -> WebCore.IDBError {
        var error = WebCore.makeSQLiteIDBNoError()
        var anyRecordsSucceeded = false
        let entries: Span<WebCore.IDBIndexKeyMapEntry> = WebCore.idbIndexKeyMapEntryElements(indexKeys)
        for i in 0..<entries.count {
            let indexIdentifier = entries[i].identifier
            if !WebCore.sqliteIDBObjectStoreHasIndex(&objectStoreInfo, indexIdentifier) {
                error = WebCore.makeSQLiteIDBInvalidStateError(sqliteIDBString("Missing index metadata"))
                break
            }
            error = putIndexKey(WebCore.sqliteIDBObjectStoreIndex(&objectStoreInfo, indexIdentifier), key, entries[i].key, recordID)
            if !error.isNull() {
                break
            }
            anyRecordsSucceeded = true
        }
        if !error.isNull() && anyRecordsSucceeded {
            if !deleteIndexRecordsOfRecord(objectStoreInfo.identifier().toUInt64(), recordID) {
                return sqliteIDBUnknownError("Adding one Index record failed, but failed to remove all others that previously succeeded")
            }
        }
        return error
    }

    // MARK: Records

    private func deleteRecord(
        _ transaction: SQLiteIDBStoreTransaction,
        _ objectStoreID: UInt64,
        _ key: WebCore.IDBKeyData
    ) -> WebCore.IDBError {
        let keyBytes = serializeIDBKeyDataBytes(key)
        let failed = "Failed to delete record from object store"
        // The record's ID: 0 when there is none to delete, -1 when the lookup fails.
        let recordID: Int64 = withCachedStatement(
            .getObjectStoreRecord,
            "SELECT recordID, value FROM Records WHERE objectStoreID = ? AND key = CAST(? AS TEXT);"
        ) { statement in
            guard let statement, statement.bindInt64(1, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK,
                sqliteIDBBindBytes(statement, 2, keyBytes) == sqliteIDBResultOK
            else {
                return -1
            }
            let result = statement.step()
            if result == sqliteIDBResultDone {
                return 0
            }
            if result != sqliteIDBResultRow {
                return -1
            }
            // A stored ID below 1 fails below, as -1 does.
            let rowID = statement.columnInt64(0)
            return rowID < 1 ? -1 : rowID
        }
        if recordID == 0 {
            return WebCore.makeSQLiteIDBNoError()
        }
        if recordID < 1 {
            return sqliteIDBUnknownError(failed)
        }
        var error = deleteRows(.deleteBlobRecord, "DELETE FROM BlobRecords WHERE objectStoreRow = ?;", UInt64(bitPattern: recordID), failed)
        if !error.isNull() {
            return error
        }
        error = deleteUnusedBlobFileRecords(transaction)
        if !error.isNull() {
            return error
        }
        error = deleteFileSystemHandleRecordsForObjectStoreRecord(recordID)
        if !error.isNull() {
            return error
        }
        if !deleteRecordRow(objectStoreID, keyBytes) {
            return sqliteIDBUnknownError(failed)
        }
        if !deleteIndexRecordsOfRecord(objectStoreID, recordID) {
            return sqliteIDBUnknownError("Failed to delete index entries for object store record")
        }
        return WebCore.makeSQLiteIDBNoError()
    }

    @_expose(Cxx)
    func deleteRange(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ keyRange: consuming WebCore.IDBKeyRangeData
    ) -> WebCore.IDBError {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Attempt to delete range from database without an in-progress transaction")
        }
        if transaction.mode == .Readonly {
            return sqliteIDBUnknownError("Attempt to delete records from an object store in a read-only transaction")
        }
        let objectStoreID = objectStoreIdentifier.toUInt64()
        if keyRange.isExactlyOneKey() {
            let error = deleteRecord(transaction, objectStoreID, keyRange.lowerKey)
            if !error.isNull() {
                return error
            }
            transaction.notifyCursorsOfChanges(objectStoreID)
            return WebCore.makeSQLiteIDBNoError()
        }
        guard let cursor = openBackingStoreCursor(transaction, objectStoreID, nil, keyRange) else {
            return sqliteIDBUnknownError("Cannot open cursor to delete range of records from the database")
        }
        defer {
            transaction.closeBackingStoreCursor(cursor)
        }
        var keys: [WebCore.IDBKeyData] = []
        while !cursor.didComplete && !cursor.didError {
            keys.append(cursor.currentKey)
            _ = cursor.advance(1)
        }
        if cursor.didError {
            return sqliteIDBUnknownError("Cursor failed while accumulating range of records from the database")
        }
        var error = WebCore.makeSQLiteIDBNoError()
        // By index: `for key in keys` copies each key out of the array.
        for i in keys.indices {
            error = deleteRecord(transaction, objectStoreID, keys[i])
            if !error.isNull() {
                break
            }
        }
        transaction.notifyCursorsOfChanges(objectStoreID)
        return error
    }

    private func addRecord(
        _ transaction: SQLiteIDBStoreTransaction,
        _ objectStoreInfo: inout WebCore.IDBObjectStoreInfo,
        _ key: WebCore.IDBKeyData,
        _ indexKeys: WebCore.IDBIndexKeyMapEntries,
        _ value: WebCore.IDBValue
    ) -> WebCore.IDBError {
        let objectStoreID = objectStoreInfo.identifier().toUInt64()
        let keyBytes = serializeIDBKeyDataBytes(key)
        let added = withCachedStatement(.addObjectStoreRecord, "INSERT INTO Records VALUES (?, CAST(? AS TEXT), ?, NULL);") { statement in
            guard let statement else {
                return false
            }
            return statement.bindInt64(1, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK
                && sqliteIDBBindBytes(statement, 2, keyBytes) == sqliteIDBResultOK
                && WebCore.sqliteIDBBindValueData(statement, 3, value) == sqliteIDBResultOK
                && statement.step() == sqliteIDBResultDone
        }
        if !added {
            return sqliteIDBUnknownError("Unable to store record in object store")
        }
        guard let database = sqliteDB?.get() else {
            WTFCrash()
        }
        let recordID = database.lastInsertRowID()

        let error = updateAllIndexesForAddRecord(&objectStoreInfo, key, indexKeys, recordID)
        if !error.isNull() {
            if !deleteRecordRow(objectStoreID, keyBytes) {
                return sqliteIDBUnknownError("Indexing new object store record failed, but unable to remove the object store record itself")
            }
            return error
        }

        let blobURLs = WebCore.sqliteIDBValueBlobURLs(value)
        let blobFiles = WebCore.sqliteIDBValueBlobFilePaths(value)
        for i in 0..<WebCore.idbStringVectorSize(blobURLs) {
            let url = WebCore.idbStringVectorAt(blobURLs, i)
            let recorded = withCachedStatement(.addBlobRecord, "INSERT INTO BlobRecords VALUES (?, ?);") { statement in
                guard let statement else {
                    return false
                }
                return statement.bindInt64(1, recordID) == sqliteIDBResultOK
                    && statement.bindString(2, url) == sqliteIDBResultOK
                    && statement.step() == sqliteIDBResultDone
            }
            if !recorded {
                return sqliteIDBUnknownError("Unable to record Blob record in database")
            }
            let potentialFileNameInteger = database.lastInsertRowID()

            // A blob URL that already has a file needs nothing more: 1 has a file, 0 has none, -1 failed.
            let hasFile: Int = withCachedStatement(.blobFilenameForBlobURL, "SELECT fileName FROM BlobFiles WHERE blobURL = ?;") {
                statement in
                guard let statement, statement.bindString(1, url) == sqliteIDBResultOK else {
                    return -1
                }
                let result = statement.step()
                if result != sqliteIDBResultRow && result != sqliteIDBResultDone {
                    return -1
                }
                return result == sqliteIDBResultRow ? 1 : 0
            }
            if hasFile < 0 {
                return sqliteIDBUnknownError("Unable to examine Blob filenames in database")
            }
            if hasFile == 1 {
                continue
            }

            let storedFilename = WebCore.sqliteIDBBlobFilename(potentialFileNameInteger)
            let stored = withCachedStatement(.addBlobFilename, "INSERT INTO BlobFiles VALUES (?, ?);") { statement in
                guard let statement else {
                    return false
                }
                return statement.bindString(1, url) == sqliteIDBResultOK
                    && statement.bindString(2, storedFilename) == sqliteIDBResultOK
                    && statement.step() == sqliteIDBResultDone
            }
            if !stored {
                return sqliteIDBUnknownError("Unable to record Blob file record in database")
            }
            // Traps when the value has fewer files than URLs.
            if i >= WebCore.idbStringVectorSize(blobFiles) {
                WTFCrash()
            }
            transaction.addBlobFile(WebCore.idbStringVectorAt(blobFiles, i), storedFilename)
        }

        let handleError = addFileSystemHandleRecords(recordID, value)
        if !handleError.isNull() {
            return handleError
        }
        transaction.notifyCursorsOfChanges(objectStoreID)
        return error
    }

    /// The uniqueness checks, then the old record's deletion, then the new record.
    @_expose(Cxx)
    func overwriteRecord(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreInfo: __owned WebCore.IDBObjectStoreInfo,
        _ key: consuming WebCore.IDBKeyData,
        _ indexKeys: consuming WebCore.IDBIndexKeyMapEntries,
        _ value: consuming WebCore.IDBValue
    ) -> WebCore.IDBError {
        var info = objectStoreInfo
        var error = checkIndexConstraintsForPut(transactionIdentifier, &info, key, indexKeys)
        if !error.isNull() {
            return error
        }
        error = deleteRange(transactionIdentifier, info.identifier(), WebCore.makeSQLiteIDBKeyRange(key))
        if !error.isNull() {
            return error
        }
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Attempt to store a record in an object store without an in-progress transaction")
        }
        if transaction.mode == .Readonly {
            return sqliteIDBUnknownError("Attempt to store a record in an object store in a read-only transaction")
        }
        return addRecord(transaction, &info, key, indexKeys, value)
    }

    @_expose(Cxx)
    func keyExistsInObjectStore(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ key: consuming WebCore.IDBKeyData
    ) -> WebCore.IDBError {
        pendingKeyExists = false
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Attempt to see if key exists in objectstore without an in-progress transaction")
        }
        _ = transaction
        let keyBytes = serializeIDBKeyDataBytes(key)
        let objectStoreID = objectStoreIdentifier.toUInt64()
        let result: Int = withCachedStatement(
            .keyExistsInObjectStore,
            "SELECT key FROM Records WHERE objectStoreID = ? AND key = CAST(? AS TEXT) LIMIT 1;"
        ) { statement in
            guard let statement, statement.bindInt64(1, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK,
                sqliteIDBBindBytes(statement, 2, keyBytes) == sqliteIDBResultOK
            else {
                return 1
            }
            let step = statement.step()
            if step == sqliteIDBResultOK || step == sqliteIDBResultDone {
                return 0
            }
            return step == sqliteIDBResultRow ? 3 : 2
        }
        switch result {
        case 0:
            return WebCore.makeSQLiteIDBNoError()
        case 1:
            return sqliteIDBUnknownError("Unable to check for existence of IDBKey in object store")
        case 2:
            return sqliteIDBUnknownError("Error checking for existence of IDBKey in object store")
        default:
            pendingKeyExists = true
            return WebCore.makeSQLiteIDBNoError()
        }
    }

    @_expose(Cxx)
    func takeKeyExists() -> Bool {
        pendingKeyExists
    }

    @_expose(Cxx)
    func takeGetResult() -> WebCore.IDBGetResult {
        // Moved out (take), not copied: a copy of an IDBGetResult copies its value and every prefetched record. No result
        // pending is an empty one.
        pendingGetResult.take() ?? WebCore.makeEmptyIDBGetResult()
    }

    @_expose(Cxx)
    func takeGetAllResult() -> WebCore.IDBGetAllResult {
        var result = WebCore.IDBGetAllResult()
        swap(&result, &pendingGetAllResult)
        return result
    }

    @_expose(Cxx)
    func takeNumber() -> UInt64 {
        pendingNumber
    }

    /// Whether getCount wrote its result (takeNumber).
    @_expose(Cxx)
    func countWritten() -> Bool {
        pendingNumberWritten
    }

    /// The range's bounds as getRecord, getAllRecords and getCount bind them: minimum and maximum for null keys.
    private static func boundBytes(_ keyRange: WebCore.IDBKeyRangeData) -> (WebCore.IDBSerializedKeyBytes, WebCore.IDBSerializedKeyBytes) {
        let lower =
            keyRange.lowerKey.isNull()
            ? serializeIDBKeyDataBytes(WebCore.IDBKeyData.minimum()) : serializeIDBKeyDataBytes(keyRange.lowerKey)
        let upper =
            keyRange.upperKey.isNull()
            ? serializeIDBKeyDataBytes(WebCore.IDBKeyData.maximum()) : serializeIDBKeyDataBytes(keyRange.upperKey)
        return (lower, upper)
    }

    private static func rangeOperators(_ lowerOpen: Bool, _ upperOpen: Bool) -> Swift.String {
        "key " + (lowerOpen ? ">" : ">=") + " CAST(? AS TEXT) AND key " + (upperOpen ? "<" : "<=") + " CAST(? AS TEXT)"
    }

    /// The four statements of a (lower, upper) open-closed choice.
    private static func rangeSQL(_ base: SQLiteIDBStoreSQL, _ lowerOpen: Bool, _ upperOpen: Bool) -> SQLiteIDBStoreSQL {
        let offset = (lowerOpen ? 0 : 2) + (upperOpen ? 0 : 1)
        guard let sql = SQLiteIDBStoreSQL(rawValue: base.rawValue + offset) else {
            WTFCrash()
        }
        return sql
    }

    /// The first record in the range, its key alone or with its value.
    ///
    /// The result is taken with takeGetResult. `keyRange` is the backing store's `const IDBKeyRangeData&` from
    /// UniqueIDBDatabase, read only through its fields here: the SQLite statements, `valueForRecord` and the result
    /// builders reach no path back to it.
    @_expose(Cxx)
    func getRecord(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ keyRange: borrowing WebCore.IDBKeyRangeData,
        _ isKeyAndValue: Bool
    ) -> WebCore.IDBError {
        pendingGetResult = nil
        guard let transaction = transaction(transactionIdentifier), transaction.inProgressOrReadOnly else {
            return sqliteIDBUnknownError("Attempt to get a record from database without an in-progress transaction")
        }
        _ = transaction
        let objectStoreID = objectStoreIdentifier.toUInt64()
        if !hasObjectStoreInfo(objectStoreID) {
            return WebCore.makeSQLiteIDBInvalidStateError(sqliteIDBString("Object store cannot be found in the database"))
        }
        let (lowerBytes, upperBytes) = SQLiteIDBStore.boundBytes(keyRange)
        let sql = SQLiteIDBStore.rangeSQL(
            isKeyAndValue ? .getAllValueRecordsLowerOpenUpperOpen : .getAllKeyRecordsLowerOpenUpperOpen,
            keyRange.lowerOpen,
            keyRange.upperOpen
        )
        let lowerOpen = keyRange.lowerOpen
        let upperOpen = keyRange.upperOpen
        var key = WebCore.IDBKeyData()
        var recordID: Int64 = 0
        var valueBuffer = WebCore.ThreadSafeDataBuffer()
        // 0: no record; 1: bind failure; 2: step failure; 3: key does not decode; 4: found.
        let result: Int = withCachedStatement(
            sql,
            (isKeyAndValue
                ? "SELECT key, value, ROWID FROM Records WHERE objectStoreID = ? AND "
                : "SELECT key FROM Records WHERE objectStoreID = ? AND ")
                + SQLiteIDBStore.rangeOperators(lowerOpen, upperOpen) + " ORDER BY key;"
        ) { statement in
            guard let statement,
                statement.bindInt64(1, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK,
                sqliteIDBBindBytes(statement, 2, lowerBytes) == sqliteIDBResultOK,
                sqliteIDBBindBytes(statement, 3, upperBytes) == sqliteIDBResultOK
            else {
                return 1
            }
            let step = statement.step()
            if step == sqliteIDBResultOK || step == sqliteIDBResultDone {
                return 0
            }
            if step != sqliteIDBResultRow {
                return 2
            }
            if !WebCore.sqliteIDBColumnKey(statement, 0, &key) {
                return 3
            }
            if isKeyAndValue {
                valueBuffer = WebCore.sqliteIDBColumnBuffer(statement, 1)
                recordID = statement.columnInt64(2)
            }
            return 4
        }
        switch result {
        case 0:
            return WebCore.makeSQLiteIDBNoError()
        case 1:
            return sqliteIDBUnknownError("Failed to look up record in object store by key range")
        case 2:
            return sqliteIDBUnknownError("Error looking up record in object store by key range")
        case 3:
            return sqliteIDBUnknownError("Error extracting key data from database executing IDBObjectStore get")
        default:
            break
        }
        if !isKeyAndValue {
            pendingGetResult = WebCore.makeIDBGetResultKey(key)
            return WebCore.makeSQLiteIDBNoError()
        }
        let (error, value) = valueForRecord(recordID, valueBuffer)
        if !error.isNull() {
            return error
        }
        pendingGetResult = WebCore.makeSQLiteIDBGetResultRecord(key, value, &databaseInfo, objectStoreIdentifier)
        return WebCore.makeSQLiteIDBNoError()
    }

    /// An object store's records in the range, or an index's.
    ///
    /// The result is taken with takeGetAllResult.
    @_expose(Cxx)
    func getAllRecords(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ hasIndex: Bool,
        _ indexIdentifier: UInt64,
        _ keyRange: consuming WebCore.IDBKeyRangeData,
        _ count: UInt32,
        _ type: WebCore.IndexedDB.GetAllType,
        _ direction: WebCore.IndexedDB.CursorDirection
    ) -> WebCore.IDBError {
        pendingGetAllResult = WebCore.IDBGetAllResult()
        if hasIndex {
            return getAllIndexRecords(transactionIdentifier, objectStoreIdentifier, indexIdentifier, keyRange, count, type, direction)
        }
        return getAllObjectStoreRecords(transactionIdentifier, objectStoreIdentifier, keyRange, count, type, direction)
    }

    private func getAllObjectStoreRecords(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ keyRange: WebCore.IDBKeyRangeData,
        _ count: UInt32,
        _ type: WebCore.IndexedDB.GetAllType,
        _ direction: WebCore.IndexedDB.CursorDirection
    ) -> WebCore.IDBError {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgressOrReadOnly else {
            return sqliteIDBUnknownError("Attempt to get records from database without an in-progress transaction")
        }
        _ = transaction
        let objectStoreID = objectStoreIdentifier.toUInt64()
        let (lowerBytes, upperBytes) = SQLiteIDBStore.boundBytes(keyRange)
        let next = direction == .Next || direction == .Nextunique
        let isKeys = type == .Keys
        let base: SQLiteIDBStoreSQL
        if isKeys {
            base = next ? .getAllKeyRecordsLowerOpenUpperOpen : .getAllKeyRecordsLowerOpenUpperOpenDesc
        } else {
            base = next ? .getAllValueRecordsLowerOpenUpperOpen : .getAllValueRecordsLowerOpenUpperOpenDesc
        }
        let sql = SQLiteIDBStore.rangeSQL(base, keyRange.lowerOpen, keyRange.upperOpen)
        let lowerOpen = keyRange.lowerOpen
        let upperOpen = keyRange.upperOpen
        let targetResults = count != 0 ? count : UInt32.max
        let hasInfo = hasObjectStoreInfo(objectStoreID)
        return withCachedStatement(
            sql,
            (isKeys
                ? "SELECT key FROM Records WHERE objectStoreID = ? AND "
                : "SELECT key, value, ROWID FROM Records WHERE objectStoreID = ? AND ")
                + SQLiteIDBStore.rangeOperators(lowerOpen, upperOpen) + (next ? " ORDER BY key;" : " ORDER BY key DESC;")
        ) { statement -> WebCore.IDBError in
            guard let statement,
                statement.bindInt64(1, Int64(bitPattern: objectStoreID)) == sqliteIDBResultOK,
                sqliteIDBBindBytes(statement, 2, lowerBytes) == sqliteIDBResultOK,
                sqliteIDBBindBytes(statement, 3, upperBytes) == sqliteIDBResultOK
            else {
                return sqliteIDBUnknownError("Failed to look up record in object store by key range")
            }
            if !hasInfo {
                return WebCore.makeSQLiteIDBInvalidStateError(sqliteIDBString("Object store cannot be found in the database"))
            }
            pendingGetAllResult = WebCore.makeSQLiteIDBGetAllResult(type, &databaseInfo, objectStoreIdentifier)
            var result = statement.step()
            var returnedResults: UInt32 = 0
            while result == sqliteIDBResultRow && returnedResults < targetResults {
                var key = WebCore.IDBKeyData()
                if !WebCore.sqliteIDBColumnKey(statement, 0, &key) {
                    return sqliteIDBUnknownError("Unable to deserialize key data while getting all records")
                }
                if type == .Records {
                    var primaryKey = key
                    WebCore.sqliteIDBGetAllResultTakePrimaryKey(&pendingGetAllResult, &primaryKey)
                }
                WebCore.sqliteIDBGetAllResultTakeKey(&pendingGetAllResult, &key)
                if type == .Values || type == .Records {
                    let valueBuffer = WebCore.sqliteIDBColumnBuffer(statement, 1)
                    let recordID = statement.columnInt64(2)
                    var (error, value) = valueForRecord(recordID, valueBuffer)
                    if !error.isNull() {
                        return error
                    }
                    WebCore.sqliteIDBGetAllResultTakeValue(&pendingGetAllResult, &value)
                }
                returnedResults += 1
                result = statement.step()
            }
            if result == sqliteIDBResultOK || result == sqliteIDBResultDone || result == sqliteIDBResultRow {
                return WebCore.makeSQLiteIDBNoError()
            }
            return sqliteIDBUnknownError("Error looking up record in object store by key range")
        }
    }

    private func getAllIndexRecords(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: UInt64,
        _ keyRange: WebCore.IDBKeyRangeData,
        _ count: UInt32,
        _ type: WebCore.IndexedDB.GetAllType,
        _ direction: WebCore.IndexedDB.CursorDirection
    ) -> WebCore.IDBError {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgressOrReadOnly else {
            return sqliteIDBUnknownError("Attempt to get all index records from database without an in-progress transaction")
        }
        let objectStoreID = objectStoreIdentifier.toUInt64()
        guard let cursor = openBackingStoreCursor(transaction, objectStoreID, indexIdentifier, copy keyRange, direction) else {
            return sqliteIDBUnknownError("Cannot open cursor to perform index gets in database")
        }
        defer {
            transaction.closeBackingStoreCursor(cursor)
        }
        if cursor.didError {
            return sqliteIDBUnknownError("Cursor failed while looking up index records in database")
        }
        if !hasObjectStoreInfo(objectStoreID) {
            return WebCore.makeSQLiteIDBInvalidStateError(sqliteIDBString("Object store cannot be found in the database"))
        }
        pendingGetAllResult = WebCore.makeSQLiteIDBGetAllResult(type, &databaseInfo, objectStoreIdentifier)
        var currentCount: UInt32 = 0
        let targetCount = count != 0 ? count : UInt32.max
        while !cursor.didComplete && !cursor.didError && currentCount < targetCount {
            cursor.addCurrentRecord(to: &pendingGetAllResult, type)
            currentCount += 1
            _ = cursor.advance(1)
        }
        if cursor.didError {
            return sqliteIDBUnknownError("Cursor failed while looking up index records in database")
        }
        return WebCore.makeSQLiteIDBNoError()
    }

    /// The first index record in the range, its primary key alone or with the value.
    ///
    /// Taken with takeGetResult.
    @_expose(Cxx)
    func getIndexRecord(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ indexIdentifier: consuming WebCore.IDBIndexIdentifier,
        _ isKey: Bool,
        _ range: consuming WebCore.IDBKeyRangeData
    ) -> WebCore.IDBError {
        pendingGetResult = nil
        guard let transaction = transaction(transactionIdentifier), transaction.inProgressOrReadOnly else {
            return sqliteIDBUnknownError("Attempt to get an index record from database without an in-progress transaction")
        }
        let objectStoreID = objectStoreIdentifier.toUInt64()
        let indexID = indexIdentifier.toUInt64()
        if range.isExactlyOneKey() {
            return getIndexRecordForOneKey(indexID, objectStoreIdentifier, isKey, range.lowerKey)
        }
        guard let cursor = openBackingStoreCursor(transaction, objectStoreID, indexID, range) else {
            return sqliteIDBUnknownError("Cannot open cursor to perform index get in database")
        }
        defer {
            transaction.closeBackingStoreCursor(cursor)
        }
        if cursor.didError {
            return sqliteIDBUnknownError("Cursor failed while looking up index record in database")
        }
        if cursor.didComplete {
            return WebCore.makeSQLiteIDBNoError()
        }
        if isKey {
            pendingGetResult = WebCore.makeIDBGetResultKey(cursor.currentPrimaryKey)
            return WebCore.makeSQLiteIDBNoError()
        }
        if !hasObjectStoreInfo(objectStoreID) {
            WebCore.sqliteIDBLogMissingObjectStore(sqliteIDBString("getIndexRecord"))
            return sqliteIDBUnknownError("Object store cannot be found in the database")
        }
        pendingGetResult = WebCore.makeSQLiteIDBGetResultValue(
            cursor.currentPrimaryKey,
            cursor.currentPrimaryKey,
            cursor.currentValue,
            &databaseInfo,
            objectStoreIdentifier
        )
        return WebCore.makeSQLiteIDBNoError()
    }

    private func getIndexRecordForOneKey(
        _ indexID: UInt64,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier,
        _ isKey: Bool,
        _ key: WebCore.IDBKeyData
    ) -> WebCore.IDBError {
        let keyBytes = serializeIDBKeyDataBytes(key)
        var objectStoreKey = WebCore.IDBKeyData()
        var valueBuffer = WebCore.ThreadSafeDataBuffer()
        var recordID: Int64 = 0
        // 0: none; 1: lookup failure; 2: key does not decode; 3: found.
        let result: Int = withCachedStatement(
            .getIndexRecordForOneKey,
            "SELECT IndexRecords.value, Records.value, Records.recordID FROM Records INNER JOIN IndexRecords ON Records.objectStoreID = IndexRecords.objectStoreID AND Records.recordID = IndexRecords.objectStoreRecordID WHERE IndexRecords.indexID = ? AND IndexRecords.key = CAST(? AS TEXT) ORDER BY IndexRecords.key, IndexRecords.value"
        ) { statement in
            guard let statement, statement.bindInt64(1, Int64(bitPattern: indexID)) == sqliteIDBResultOK,
                sqliteIDBBindBytes(statement, 2, keyBytes) == sqliteIDBResultOK
            else {
                return 1
            }
            let step = statement.step()
            if step != sqliteIDBResultRow && step != sqliteIDBResultDone {
                return 1
            }
            if step == sqliteIDBResultDone {
                return 0
            }
            if !WebCore.sqliteIDBColumnKey(statement, 0, &objectStoreKey) {
                return 2
            }
            if !isKey {
                valueBuffer = WebCore.sqliteIDBColumnBuffer(statement, 1)
                recordID = statement.columnInt64(2)
            }
            return 3
        }
        switch result {
        case 0:
            return WebCore.makeSQLiteIDBNoError()
        case 1:
            return sqliteIDBUnknownError("Unable to lookup index record in database")
        case 2:
            return sqliteIDBUnknownError("Unable to deserialize key looking up index record in database")
        default:
            break
        }
        if isKey {
            pendingGetResult = WebCore.makeIDBGetResultKey(objectStoreKey)
            return WebCore.makeSQLiteIDBNoError()
        }
        let (blobError, blobURLs, blobFilePaths) = getBlobRecordsForObjectStoreRecord(recordID)
        if !blobError.isNull() {
            return blobError
        }
        if !hasObjectStoreInfo(objectStoreIdentifier.toUInt64()) {
            WebCore.sqliteIDBLogMissingObjectStore(sqliteIDBString("getIndexRecordForOneKey"))
            return sqliteIDBUnknownError("Object store cannot be found in the database")
        }
        let (error, value) = buildIDBValueForRecord(recordID, valueBuffer, blobURLs, blobFilePaths)
        if !error.isNull() {
            return error
        }
        pendingGetResult = WebCore.makeSQLiteIDBGetResultValue(objectStoreKey, objectStoreKey, value, &databaseInfo, objectStoreIdentifier)
        return WebCore.makeSQLiteIDBNoError()
    }

    /// The records (or index records) in the range.
    ///
    /// Taken with takeNumber.
    @_expose(Cxx)
    func getCount(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier,
        _ hasIndex: Bool,
        _ indexIdentifier: UInt64,
        _ range: consuming WebCore.IDBKeyRangeData
    ) -> WebCore.IDBError {
        guard let transaction = transaction(transactionIdentifier), transaction.inProgressOrReadOnly else {
            pendingNumberWritten = false
            return sqliteIDBUnknownError("Attempt to get count from database without an in-progress transaction")
        }
        _ = transaction
        pendingNumber = 0
        pendingNumberWritten = true
        let (lowerBytes, upperBytes) = SQLiteIDBStore.boundBytes(range)
        let lowerOpen = range.lowerOpen
        let upperOpen = range.upperOpen
        let sql = SQLiteIDBStore.rangeSQL(
            hasIndex ? .countIndexRecordsLowerOpenUpperOpen : .countRecordsLowerOpenUpperOpen,
            lowerOpen,
            upperOpen
        )
        let boundID = hasIndex ? indexIdentifier : objectStoreIdentifier.toUInt64()
        var count: UInt64 = 0
        // 0: counted; 1: bind failure; 2: step failure.
        let result: Int = withCachedStatement(
            sql,
            (hasIndex
                ? "SELECT COUNT(*) FROM IndexRecords WHERE indexID = ? AND " : "SELECT COUNT(*) FROM Records WHERE objectStoreID = ? AND ")
                + SQLiteIDBStore.rangeOperators(lowerOpen, upperOpen) + ";"
        ) { statement in
            guard let statement,
                statement.bindInt64(1, Int64(bitPattern: boundID)) == sqliteIDBResultOK,
                sqliteIDBBindBytes(statement, 2, lowerBytes) == sqliteIDBResultOK,
                sqliteIDBBindBytes(statement, 3, upperBytes) == sqliteIDBResultOK
            else {
                return 1
            }
            if statement.step() != sqliteIDBResultRow {
                return 2
            }
            count = UInt64(bitPattern: statement.columnInt64(0))
            return 0
        }
        switch result {
        case 1:
            return sqliteIDBUnknownError(
                hasIndex
                    ? "Unable to count records for index due to binding failure"
                    : "Unable to count records in object store due to binding failure"
            )
        case 2:
            return sqliteIDBUnknownError("Unable to count records")
        default:
            pendingNumber = count
            return WebCore.makeSQLiteIDBNoError()
        }
    }

    @_expose(Cxx)
    func generateKeyNumberEntry(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier
    ) -> WebCore.IDBError {
        let (error, keyNumber, written) = generateKeyNumber(transactionIdentifier, objectStoreIdentifier)
        pendingNumber = keyNumber
        pendingNumberWritten = written
        return error
    }

    @_expose(Cxx)
    func establishDatabaseInfo() -> WebCore.IDBError {
        getOrEstablishDatabaseInfo().0
    }

    /// The info after establishDatabaseInfo succeeded.
    @_expose(Cxx)
    func currentDatabaseInfo() -> WebCore.IDBDatabaseInfo {
        databaseInfo
    }

    @_expose(Cxx)
    func hasObjectStore(_ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier) -> Bool {
        requireDatabaseInfo()
        return WebCore.idbDatabaseInfoHasObjectStore(&databaseInfo, objectStoreIdentifier)
    }

    @_expose(Cxx)
    func objectStoreInfo(_ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier) -> WebCore.IDBObjectStoreInfo {
        WebCore.idbDatabaseInfoObjectStore(&databaseInfo, objectStoreIdentifier)
    }

    /// The object store's info, or nil without one: the check and the copy in one access to the schema, as the C++'s
    /// infoForObjectStore is one call (hasObjectStore then objectStoreInfo is two exclusivity checks per request).
    func objectStoreInfoIfPresent(_ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier) -> WebCore.IDBObjectStoreInfo? {
        requireDatabaseInfo()
        return Self.objectStoreInfo(in: &databaseInfo, objectStoreIdentifier)
    }

    private static func objectStoreInfo(
        in info: inout WebCore.IDBDatabaseInfo,
        _ objectStoreIdentifier: WebCore.IDBObjectStoreIdentifier
    ) -> WebCore.IDBObjectStoreInfo? {
        guard WebCore.idbDatabaseInfoHasObjectStore(&info, objectStoreIdentifier) else {
            return nil
        }
        return WebCore.idbDatabaseInfoObjectStore(&info, objectStoreIdentifier)
    }

    // MARK: Cursors

    /// The cursor's first record, taken with takeGetResult.
    @_expose(Cxx)
    func openCursor(_ transactionIdentifier: WebCore.IDBResourceIdentifier, _ info: consuming WebCore.IDBCursorInfo) -> WebCore.IDBError {
        pendingGetResult = nil
        guard let transaction = transaction(transactionIdentifier), transaction.inProgressOrReadOnly else {
            return sqliteIDBUnknownError("Attempt to open a cursor in database without an in-progress transaction")
        }
        let objectStoreID = info.objectStoreIdentifier().toUInt64()
        let indexID: UInt64? = info.cursorSource() == .Index ? WebCore.idbCursorInfoSourceIdentifier(info) : nil
        let candidate = SQLiteIDBStoreCursor(
            store: self,
            transaction: transaction,
            identifier: info.identifier(),
            objectStoreID: objectStoreID,
            indexID: indexID,
            direction: info.cursorDirection(),
            isKeyAndValue: info.cursorType() == .KeyAndValue,
            range: WebCore.idbCursorInfoRange(info),
            isBackingStoreCursor: false
        )
        guard let cursor = transaction.maybeOpenCursor(candidate) else {
            return sqliteIDBUnknownError("Unable to open cursor")
        }
        registerCursor(cursor)
        if !hasObjectStoreInfo(objectStoreID) {
            WebCore.sqliteIDBLogMissingObjectStore(sqliteIDBString("openCursor"))
            return sqliteIDBUnknownError("Object store cannot be found in the database")
        }
        pendingGetResult = cursor.currentData(&databaseInfo, includePrefetchedRecords: false)
        return WebCore.makeSQLiteIDBNoError()
    }

    /// Moves the cursor to a key (and primary key), or by a count; the record, when asked for, taken with takeGetResult.
    @_expose(Cxx)
    func iterateCursor(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ cursorIdentifier: consuming WebCore.IDBResourceIdentifier,
        _ key: consuming WebCore.IDBKeyData,
        _ primaryKey: consuming WebCore.IDBKeyData,
        _ requestedCount: UInt32,
        _ reply: Bool
    ) -> WebCore.IDBError {
        pendingGetResult = nil
        guard let cursor = registeredCursor(cursorIdentifier) else {
            return sqliteIDBUnknownError("Attempt to iterate a cursor that doesn't exist")
        }
        if !cursor.transaction.inProgressOrReadOnly {
            return sqliteIDBUnknownError("Attempt to iterate a cursor without an in-progress transaction")
        }
        if key.isValid() {
            if !cursor.iterate(&key, &primaryKey) {
                return sqliteIDBUnknownError("Attempt to iterate cursor failed")
            }
        } else {
            let count = requestedCount != 0 ? requestedCount : 1
            if !cursor.advance(UInt64(count)) {
                return sqliteIDBUnknownError("Attempt to advance cursor failed")
            }
        }
        if reply {
            if !hasObjectStoreInfo(cursor.objectStoreID) {
                WebCore.sqliteIDBLogMissingObjectStore(sqliteIDBString("iterateCursor"))
                return sqliteIDBUnknownError("Object store cannot be found in the database")
            }
            let shouldPrefetch = key.isNull() && primaryKey.isNull()
            if shouldPrefetch {
                _ = cursor.prefetch()
            }
            pendingGetResult = cursor.currentData(&databaseInfo, includePrefetchedRecords: shouldPrefetch)
        }
        return WebCore.makeSQLiteIDBNoError()
    }

    // MARK: Indexes built from the records (UniqueIDBDatabase's index creation)

    @_expose(Cxx)
    func updateIndexRecordsWithIndexKey(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ indexInfo: __owned WebCore.IDBIndexInfo,
        _ key: consuming WebCore.IDBKeyData,
        _ indexKey: consuming WebCore.IndexKey,
        _ hasRecordID: Bool,
        _ recordID: Int64
    ) -> WebCore.IDBError {
        guard let database = sqliteDB?.get(), database.isOpen() else {
            return sqliteIDBUnknownError("Database connection is closed.")
        }
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Transaction is not in progress.")
        }
        _ = transaction
        if !hasRecordID {
            return sqliteIDBUnknownError("Record ID is invalid.")
        }
        if indexKey.isNull() {
            return WebCore.makeSQLiteIDBNoError()
        }
        return putIndexKey(indexInfo, key, indexKey, recordID)
    }

    /// forEachObjectStoreRecord, a step at a time so that SwiftSQLiteIDBBackingStore applies each record before the next is read: the
    /// error that ends the walk before it starts, or none with the cursor on the first record.
    @_expose(Cxx)
    func beginForEachObjectStoreRecord(
        _ transactionIdentifier: WebCore.IDBResourceIdentifier,
        _ objectStoreIdentifier: consuming WebCore.IDBObjectStoreIdentifier
    ) -> WebCore.IDBError {
        endForEachObjectStoreRecord()
        guard let transaction = transaction(transactionIdentifier), transaction.inProgress else {
            return sqliteIDBUnknownError("Cannot iterate object store records without in-progress transaction")
        }
        guard let cursor = openBackingStoreCursor(transaction, objectStoreIdentifier.toUInt64(), nil, WebCore.IDBKeyRangeData.allKeys())
        else {
            return sqliteIDBUnknownError("Failed to create object store cursor")
        }
        forEachCursor = cursor
        forEachTransaction = transaction
        return WebCore.makeSQLiteIDBNoError()
    }

    @_expose(Cxx)
    func forEachHasRecord() -> Bool {
        guard let cursor = forEachCursor else {
            return false
        }
        return !cursor.currentKey.isNull()
    }

    @_expose(Cxx)
    func forEachKey() -> WebCore.IDBKeyData {
        forEachCursor?.currentKey ?? WebCore.IDBKeyData()
    }

    @_expose(Cxx)
    func forEachValue() -> WebCore.IDBValue {
        forEachCursor?.currentValue ?? WebCore.IDBValue()
    }

    @_expose(Cxx)
    func forEachRowID() -> Int64 {
        forEachCursor?.currentRecordRowID ?? 0
    }

    /// Advances the walk: false (the walk ends with an error) when the cursor fails.
    @_expose(Cxx)
    func forEachAdvance() -> Bool {
        forEachCursor?.advance(1) ?? false
    }

    @_expose(Cxx)
    func endForEachObjectStoreRecord() {
        if let cursor = forEachCursor, let transaction = forEachTransaction {
            transaction.closeBackingStoreCursor(cursor)
        }
        forEachCursor = nil
        forEachTransaction = nil
    }

    // MARK: Database names and sizes

    @_expose(Cxx)
    static func encodeDatabaseName(_ databaseName: consuming WTF.String) -> WTF.String {
        if databaseName.isEmpty() {
            return sqliteIDBString("%00")
        }
        return WebCore.sqliteIDBReplacingAll(WebCore.sqliteIDBEncodeForFileName(databaseName), sqliteIDBString("."), sqliteIDBString("%2E"))
    }

    @_expose(Cxx)
    static func decodeDatabaseName(_ encodedName: consuming WTF.String) -> WTF.String {
        if WebCore.idbStringEqual(encodedName, sqliteIDBString("%00")) {
            return WebCore.sqliteIDBEmptyString()
        }
        return WebCore.sqliteIDBDecodeFromFilename(WebCore.sqliteIDBReplacingAll(encodedName, sqliteIDBString("%2E"), sqliteIDBString(".")))
    }

    /// A version of 0 stands for no value (the file has no usable metadata).
    @_expose(Cxx)
    static func nameAndVersionFromFile(_ databasePath: consuming WTF.String) -> WebCore.IDBDatabaseNameAndVersion {
        if let (name, version) = databaseNameAndVersionFromFile(databasePath) {
            return WebCore.makeSQLiteIDBNameAndVersion(name, version)
        }
        return WebCore.makeSQLiteIDBNameAndVersion(WTF.String(), 0)
    }

    @_expose(Cxx)
    static func fullDatabasePathForDirectory(_ directory: consuming WTF.String) -> WTF.String {
        WebCore.sqliteIDBFullDatabasePath(directory)
    }

    @_expose(Cxx)
    static func databasesSizeForDirectory(_ directory: consuming WTF.String) -> UInt64 {
        var diskUsage: UInt64 = 0
        let databaseDirectories = WebCore.sqliteIDBListDirectory(directory)
        for i in 0..<WebCore.idbStringVectorSize(databaseDirectories) {
            let databaseDirectory = WebCore.sqliteIDBPathByAppendingComponent(directory, WebCore.idbStringVectorAt(databaseDirectories, i))
            let fileNames = WebCore.sqliteIDBListDirectory(databaseDirectory)
            for j in 0..<WebCore.idbStringVectorSize(fileNames) {
                let fileName = WebCore.idbStringVectorAt(fileNames, j)
                if WebCore.sqliteIDBIsDatabaseFileName(fileName) {
                    // File sizes on one disk do not wrap a UInt64 in practice.
                    diskUsage &+= WebCore.sqliteIDBDatabaseFileSize(WebCore.sqliteIDBPathByAppendingComponent(databaseDirectory, fileName))
                }
            }
        }
        return diskUsage
    }
}

/// bindBlob of a byte vector (SQLite copies the bytes before returning).
private func sqliteIDBBindBytes(_ statement: WebCore.SQLiteStatement, _ index: Int32, _ bytes: WebCore.IDBSerializedKeyBytes) -> Int32 {
    WebCore.sqliteIDBBindBytes(statement, index, bytes)
}
