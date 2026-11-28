//
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
//

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// those operators take, so they are imported for the operator lookup to resolve (rdar://192229293).
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.ClientOrigin
internal import WebCore_Private.Core.IDBConnectionToClientDelegate
internal import WebCore_Private.Core.IDBDatabaseConnectionIdentifier
internal import WebCore_Private.Core.IDBDatabaseIdentifier
internal import WebCore_Private.Core.IDBDatabaseInfo
internal import WebCore_Private.Core.IDBError
internal import WebCore_Private.Core.IDBGetAllResult
internal import WebCore_Private.Core.IDBGetResult
internal import WebCore_Private.Core.IDBIndexIdentifier
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IDBObjectStoreIdentifier
internal import WebCore_Private.Core.IDBOpenRequestData
internal import WebCore_Private.Core.IDBResourceIdentifier
internal import WebCore_Private.Core.IDBTransactionInfo
internal import WebCore_Private.Core.SwiftIDBTypes

// The types the IndexedDB server's files share. Ownership: an IDBServerCore owns its databases; a UniqueIDBDatabase owns
// its open requests, database connections and transactions as values keyed by identifier or serial; an
// IDBServerRouter owns the connections to clients and maps the identifiers that arrive from clients to the database
// holding them. A continuation captures the database weakly plus identifiers and serials, and looks them up when it
// runs.
//
// No call goes out (to the delegate, the quota requester, the store, the router or the core) while an inout access to
// one of a database's stored properties is open: mutate in one statement, then call out.

// MARK: - Callables

/// Asks for `size` more bytes for `origin`; the completion can run inside the call or later on the same queue.
@_spi(IDBServer)
public typealias IDBSpaceRequester = (WebCore.ClientOrigin, UInt64, @escaping (Bool) -> Void) -> Void

/// Where a database's backing store lives.
@_spi(IDBServer)
public enum IDBBackingStoreKind {
    case memory
    case sqliteMemory
    case sqlite(databaseDirectory: WTF.String)
}

/// Chooses the backing store for a database the first time it is opened.
@_spi(IDBServer)
public typealias IDBBackingStoreFactory = (WebCore.IDBDatabaseIdentifier) -> IDBBackingStoreKind

typealias IDBErrorCallback = (WebCore.IDBError) -> Void
typealias IDBKeyDataCallback = (WebCore.IDBError, WebCore.IDBKeyData) -> Void
typealias IDBGetResultCallback = (WebCore.IDBError, WebCore.IDBGetResult) -> Void
typealias IDBGetAllResultsCallback = (WebCore.IDBError, WebCore.IDBGetAllResult) -> Void
typealias IDBCountCallback = (WebCore.IDBError, UInt64) -> Void

// MARK: - Small values

enum IDBSpaceCheckResult {
    case unknown
    case pass
    case fail
}

/// What registering an identifier that is already registered does.
@_spi(IDBServer)
public enum IDBRegistrationPolicy {
    /// Replaces the entry, as IDBServer's maps do.
    case overwrite
    /// Keeps the first entry, as the network process's registry does.
    case keepFirst
}

/// Names an open request or a transaction within its database.
///
/// The identifiers of both come from the client, which can repeat one; a serial is the database's own and never
/// repeats. An integer key, so the dictionaries keyed by it hash it with the integer hash, not the default `Hasher` (SipHash).
typealias IDBEntitySerial = IDBServerIntegerKey

/// What refers to a database without keeping it alive: a continuation, a routing entry or a handle holds it.
///
/// Its holders keep it strongly; it names the database unowned and gives nil once the database's deinitializer has
/// begun, as a WeakPtr does. No weak reference is involved: a weak reference gives the object it names a side
/// table, after which every retain and release of that object takes the runtime's slow path, and a weak load costs an
/// atomic operation per continuation. A new database under the same identifier has a new reference object, so an old
/// continuation finds nothing.
final class IDBDatabaseReference {
    /// Set by the database's initializer, once it can name itself, and cleared by its deinitializer.
    private unowned var target: UniqueIDBDatabase?

    /// The database, or nil once it has begun to deinitialize.
    var database: UniqueIDBDatabase? {
        target
    }

    /// Called by the database's initializer last.
    func databaseDidInitialize(_ database: UniqueIDBDatabase) {
        target = database
    }

    /// Called by the database's deinitializer first.
    func databaseWillDeinitialize() {
        target = nil
    }
}

/// What a database holds to reach its core, as `IDBDatabaseReference` does for the database: unowned, with a
/// liveness flag the core's deinitializer clears, so the core gets no weak reference's side table and its retains and
/// releases stay on the runtime's fast path.
final class IDBServerCoreReference {
    private unowned let target: IDBServerCore
    private var coreIsLive = true

    init(_ core: IDBServerCore) {
        target = core
    }

    /// The core, or nil once it has begun to deinitialize.
    var core: IDBServerCore? {
        coreIsLive ? target : nil
    }

    /// Called by the core's deinitializer first.
    func coreWillDeinitialize() {
        coreIsLive = false
    }
}

/// A router's entry for a database connection: the connection's database while it is alive.
struct IDBDatabaseLivenessReference {
    let reference: IDBDatabaseReference

    init(database: UniqueIDBDatabase) {
        reference = database.reference
    }

    var database: UniqueIDBDatabase? {
        reference.database
    }
}

/// A router's entry for a transaction: its database while it is alive, and its serial there.
struct IDBTransactionLivenessReference {
    let reference: IDBDatabaseReference
    let serial: IDBEntitySerial

    init(database: UniqueIDBDatabase, serial: IDBEntitySerial) {
        reference = database.reference
        self.serial = serial
    }

    var database: UniqueIDBDatabase? {
        reference.database
    }
}
