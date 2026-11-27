/*
 * Copyright (C) 2015, 2016 Apple Inc. All rights reserved.
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

#include <WebCore/IDBDatabaseConnectionIdentifier.h>
#include <WebCore/IDBIndexIdentifier.h>
#include <WebCore/IDBObjectStoreIdentifier.h>
#include <WebCore/IDBResourceIdentifier.h>
#include <WebCore/IndexKey.h>
#include <WebCore/IndexedDB.h>
#include <WebCore/SecurityOriginData.h>
#include <wtf/CheckedPtr.h>
#include <wtf/Function.h>
#include <wtf/HashSet.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class IDBCursorInfo;
class IDBIndexInfo;
class IDBKeyData;
class IDBObjectStoreInfo;
class IDBOpenRequestData;
class IDBRequestData;
class IDBTransactionInfo;
class IDBValue;
class SwiftIDBServer;

struct ClientOrigin;
struct IDBGetAllRecordsData;
struct IDBGetRecordData;
struct IDBIterateCursorData;
struct IDBKeyRangeData;

namespace IDBServer {

class IDBConnectionToClientDelegate;

// The in-process server's C++ entry, for callers outside WebCore that cannot include WebCore-Swift.h.
class IDBServer final : public CanMakeThreadSafeCheckedPtr<IDBServer> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(IDBServer, WEBCORE_EXPORT);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(IDBServer);
public:
    using SpaceRequester = Function<bool(const ClientOrigin&, uint64_t spaceRequested)>;
    WEBCORE_EXPORT IDBServer(const String& databaseDirectoryPath, SpaceRequester&&);
    WEBCORE_EXPORT ~IDBServer();

    WEBCORE_EXPORT void registerConnection(IDBConnectionToClientDelegate&);
    WEBCORE_EXPORT void unregisterConnection(IDBConnectionIdentifier);
    WEBCORE_EXPORT void setClientSuspended(IDBConnectionIdentifier, bool);

    // Operations requested by the client.
    WEBCORE_EXPORT void openDatabase(const IDBOpenRequestData&);
    WEBCORE_EXPORT void deleteDatabase(const IDBOpenRequestData&);
    WEBCORE_EXPORT void abortTransaction(const IDBResourceIdentifier&);
    WEBCORE_EXPORT void commitTransaction(const IDBResourceIdentifier&, uint64_t handledRequestResultsCount);
    WEBCORE_EXPORT void didFinishHandlingVersionChangeTransaction(IDBDatabaseConnectionIdentifier, const IDBResourceIdentifier&);
    WEBCORE_EXPORT void createObjectStore(const IDBRequestData&, const IDBObjectStoreInfo&);
    WEBCORE_EXPORT void renameObjectStore(const IDBRequestData&, IDBObjectStoreIdentifier, const String& newName);
    WEBCORE_EXPORT void deleteObjectStore(const IDBRequestData&, const String& objectStoreName);
    WEBCORE_EXPORT void clearObjectStore(const IDBRequestData&, IDBObjectStoreIdentifier);
    WEBCORE_EXPORT void createIndex(const IDBRequestData&, const IDBIndexInfo&);
    WEBCORE_EXPORT void deleteIndex(const IDBRequestData&, IDBObjectStoreIdentifier, const String& indexName);
    WEBCORE_EXPORT void renameIndex(const IDBRequestData&, IDBObjectStoreIdentifier, IDBIndexIdentifier, const String& newName);
    WEBCORE_EXPORT void putOrAdd(const IDBRequestData&, const IDBKeyData&, const IDBValue&, const IndexIDToIndexKeyMap&, IndexedDB::ObjectStoreOverwriteMode);
    WEBCORE_EXPORT void getRecord(const IDBRequestData&, const IDBGetRecordData&);
    WEBCORE_EXPORT void getAllRecords(const IDBRequestData&, const IDBGetAllRecordsData&);
    WEBCORE_EXPORT void getCount(const IDBRequestData&, const IDBKeyRangeData&);
    WEBCORE_EXPORT void deleteRecord(const IDBRequestData&, const IDBKeyRangeData&);
    WEBCORE_EXPORT void openCursor(const IDBRequestData&, const IDBCursorInfo&);
    WEBCORE_EXPORT void iterateCursor(const IDBRequestData&, const IDBIterateCursorData&);

    WEBCORE_EXPORT void establishTransaction(IDBDatabaseConnectionIdentifier, const IDBTransactionInfo&);
    NODELETE WEBCORE_EXPORT void databaseConnectionPendingClose(IDBDatabaseConnectionIdentifier);
    WEBCORE_EXPORT void databaseConnectionClosed(IDBDatabaseConnectionIdentifier);
    WEBCORE_EXPORT void abortOpenAndUpgradeNeeded(IDBDatabaseConnectionIdentifier, const std::optional<IDBResourceIdentifier>& transactionIdentifier);
    WEBCORE_EXPORT void didFireVersionChangeEvent(IDBDatabaseConnectionIdentifier, const IDBResourceIdentifier& requestIdentifier, IndexedDB::ConnectionClosedOnBehalfOfServer);
    WEBCORE_EXPORT void didGenerateIndexKeyForRecord(const IDBResourceIdentifier& transactionIdentifier, const IDBResourceIdentifier& requestIdentifier, const IDBIndexInfo&, const IDBKeyData&, const IndexKey&, std::optional<int64_t> recordID);
    WEBCORE_EXPORT void openDBRequestCancelled(const IDBOpenRequestData&);

    WEBCORE_EXPORT void getAllDatabaseNamesAndVersions(IDBConnectionIdentifier, const IDBResourceIdentifier&, const ClientOrigin&);

    WEBCORE_EXPORT HashSet<SecurityOriginData> getOrigins() const;
    WEBCORE_EXPORT void closeAndDeleteDatabasesModifiedSince(WallTime);

    WEBCORE_EXPORT static uint64_t diskUsage(const String& rootDirectory, const ClientOrigin&);

private:
    std::unique_ptr<SwiftIDBServer> m_server;
};

} // namespace IDBServer
} // namespace WebCore
