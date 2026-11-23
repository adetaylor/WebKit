//
// Copyright (C) 2013, 2016 Apple Inc. All rights reserved.
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

// The SQLite store's transactions (SQLiteIDBStore.swift).

internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
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

/// A transaction of the SQLite store: its SQLite transaction, its cursors, and the blob files it
/// stores and deletes on commit.
final class SQLiteIDBStoreTransaction {
    let identifier: WebCore.IDBResourceIdentifier
    let mode: WebCore.IDBTransactionMode
    let durability: WebCore.IDBTransactionDurability
    /// The SQLite transaction while one is open (never for a read-only transaction).
    ///
    /// A non-owning CheckedRef to the database, so the store drops every transaction before the database owner.
    private var sqliteTransaction: WebCore.SQLiteTransaction? = nil
    private var removedBlobFilenames: [WTF.String] = []
    /// Each stored blob's temporary file and the name it is stored under, moved into place on commit.
    private var blobTemporaryAndStoredFilenames: [(WTF.String, WTF.String)] = []
    private let databaseDirectory: WTF.String
    /// The store, to unregister the cursors this transaction closes.
    weak var store: SQLiteIDBStore?
    /// The cursors the page opened, by identifier, and the store's own cursors while it walks a range.
    private var cursors: ContiguousArray<SQLiteIDBStoreCursor> = []
    private var backingStoreCursors: ContiguousArray<SQLiteIDBStoreCursor> = []

    // Takes the info's fields, not the info: an IDBTransactionInfo parameter passed on crashes the MoveOnlyChecker
    // (Swift 6.5-dev, SILMoveOnlyWrappedType assertion).
    init(
        _ identifier: consuming WebCore.IDBResourceIdentifier,
        _ mode: WebCore.IDBTransactionMode,
        _ durability: WebCore.IDBTransactionDurability,
        _ databaseDirectory: WTF.String
    ) {
        self.identifier = identifier
        self.mode = mode
        self.durability = durability
        self.databaseDirectory = databaseDirectory
    }

    var isReadOnly: Bool { mode == .Readonly }

    var inProgress: Bool {
        sqliteTransaction?.inProgress() ?? false
    }

    var inProgressOrReadOnly: Bool { isReadOnly || inProgress }

    func begin(_ database: WebCore.SQLiteDatabase) -> WebCore.IDBError {
        if isReadOnly {
            return WebCore.makeSQLiteIDBNoError()
        }
        sqliteTransaction = WebCore.SQLiteTransaction(database, false)
        sqliteTransaction?.beginTransaction()
        if inProgress {
            return WebCore.makeSQLiteIDBNoError()
        }
        return sqliteIDBUnknownError("Could not start SQLite transaction in database backend")
    }

    func commit() -> WebCore.IDBError {
        if isReadOnly {
            reset()
            return WebCore.makeSQLiteIDBNoError()
        }
        if !inProgress {
            return sqliteIDBUnknownError("No SQLite transaction in progress to commit")
        }
        sqliteTransaction?.commit()
        if inProgress {
            return sqliteIDBUnknownError("Unable to commit SQLite transaction in database backend")
        }
        deleteBlobFilesIfNecessary()
        moveBlobFilesIfNecessary()
        reset()
        return WebCore.makeSQLiteIDBNoError()
    }

    func abort() -> WebCore.IDBError {
        if isReadOnly {
            reset()
            return WebCore.makeSQLiteIDBNoError()
        }
        for (temporaryPath, _) in blobTemporaryAndStoredFilenames {
            WebCore.sqliteIDBDeleteFile(temporaryPath)
        }
        blobTemporaryAndStoredFilenames.removeAll()
        if !inProgress {
            return sqliteIDBUnknownError("No SQLite transaction in progress to abort")
        }
        sqliteTransaction?.rollback()
        if inProgress {
            return sqliteIDBUnknownError("Unable to abort SQLite transaction in database backend")
        }
        reset()
        return WebCore.makeSQLiteIDBNoError()
    }

    func addRemovedBlobFile(_ filename: WTF.String) {
        for existing in removedBlobFilenames where WebCore.idbStringEqual(existing, filename) {
            return
        }
        removedBlobFilenames.append(filename)
    }

    private func deleteBlobFilesIfNecessary() {
        for filename in removedBlobFilenames {
            WebCore.sqliteIDBDeleteFile(WebCore.sqliteIDBPathByAppendingComponent(databaseDirectory, filename))
        }
        removedBlobFilenames.removeAll()
    }

    func addBlobFile(_ temporaryPath: WTF.String, _ storedFilename: WTF.String) {
        blobTemporaryAndStoredFilenames.append((temporaryPath, storedFilename))
    }

    private func moveBlobFilesIfNecessary() {
        for (temporaryPath, storedFilename) in blobTemporaryAndStoredFilenames {
            // A file that fails to link or copy is logged and otherwise ignored.
            _ = WebCore.sqliteIDBHardLinkOrCopyFile(
                temporaryPath,
                WebCore.sqliteIDBPathByAppendingComponent(databaseDirectory, storedFilename)
            )
            WebCore.sqliteIDBDeleteFile(temporaryPath)
        }
        blobTemporaryAndStoredFilenames.removeAll()
    }

    private func reset() {
        sqliteTransaction = nil
        clearCursors()
    }

    deinit {
        // The SQLite transaction rolls back as it is destroyed; the cursors are unregistered from the store.
        clearCursors()
    }

    // MARK: Cursors

    func cursor(_ identifier: WebCore.IDBResourceIdentifier) -> SQLiteIDBStoreCursor? {
        for cursor in cursors where WebCore.idbResourceIdentifierEqual(cursor.identifier, identifier) {
            return cursor
        }
        return nil
    }

    /// The cursor the page opened, or the one already open under its identifier.
    func maybeOpenCursor(_ cursor: SQLiteIDBStoreCursor) -> SQLiteIDBStoreCursor? {
        if sqliteTransaction != nil && !inProgress {
            return nil
        }
        let established = cursor.establish()
        if let existing = self.cursor(cursor.identifier) {
            return existing
        }
        if !established {
            return nil
        }
        cursors.append(cursor)
        return cursor
    }

    /// Registers the cursor for change notifications until closeBackingStoreCursor.
    func maybeOpenBackingStoreCursor(_ cursor: SQLiteIDBStoreCursor) -> SQLiteIDBStoreCursor? {
        if !cursor.establish() {
            return nil
        }
        backingStoreCursors.append(cursor)
        return cursor
    }

    func closeBackingStoreCursor(_ cursor: SQLiteIDBStoreCursor) {
        backingStoreCursors.removeAll { $0 === cursor }
    }

    func notifyCursorsOfChanges(_ objectStoreID: UInt64) {
        for cursor in cursors where cursor.objectStoreID == objectStoreID {
            cursor.objectStoreRecordsChanged()
        }
        for cursor in backingStoreCursors where cursor.objectStoreID == objectStoreID {
            cursor.objectStoreRecordsChanged()
        }
    }

    func clearCursors() {
        for cursor in cursors {
            store?.unregisterCursor(cursor)
            cursor.dropStatements()
        }
        cursors.removeAll()
    }

    /// Before the store closes the database: no statement may outlive it.
    func dropCursorStatements() {
        for cursor in backingStoreCursors {
            cursor.dropStatements()
        }
        clearCursors()
    }
}
