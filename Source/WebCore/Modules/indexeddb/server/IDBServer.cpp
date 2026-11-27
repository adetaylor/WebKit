/*
 * Copyright (C) 2015-2024 Apple Inc. All rights reserved.
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
#include "IDBServer.h"

#include "ClientOrigin.h"
#include "IDBBackingStore.h"
#include "IDBConnectionToClientDelegate.h"
#include "IDBCursorInfo.h"
#include "IDBGetAllRecordsData.h"
#include "IDBGetRecordData.h"
#include "IDBIndexInfo.h"
#include "IDBIterateCursorData.h"
#include "IDBKeyData.h"
#include "IDBKeyRangeData.h"
#include "IDBObjectStoreInfo.h"
#include "IDBOpenRequestData.h"
#include "IDBRequestData.h"
#include "IDBTransactionInfo.h"
#include "IDBValue.h"
#include "SwiftIDBTypes.h"
#include "WebCore-Swift.h"
#include <wtf/MainThread.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {
namespace IDBServer {

WTF_MAKE_TZONE_ALLOCATED_IMPL(IDBBackingStore);
WTF_MAKE_TZONE_ALLOCATED_IMPL(IDBServer);

// Each member forwards to SwiftIDBServer, on the caller's queue.

IDBServer::IDBServer(const String& databaseDirectoryPath, SpaceRequester&& spaceRequester)
{
    ASSERT(!isMainThread());
    ASSERT_WITH_SECURITY_IMPLICATION(databaseDirectoryPath.isSafeToSendToAnotherThread());

    m_server = makeUniqueWithoutFastMallocCheck<SwiftIDBServer>(SwiftIDBServer::init(databaseDirectoryPath, IDBSpaceRequesterHolder { WTF::move(spaceRequester) }));
}

IDBServer::~IDBServer()
{
    ASSERT(!isMainThread());
}

void IDBServer::registerConnection(IDBConnectionToClientDelegate& delegate)
{
    m_server->registerConnection(&delegate);
}

void IDBServer::unregisterConnection(IDBConnectionIdentifier identifier)
{
    m_server->unregisterConnection(identifier);
}

void IDBServer::setClientSuspended(IDBConnectionIdentifier identifier, bool isSuspended)
{
    m_server->setClientSuspended(identifier, isSuspended);
}

void IDBServer::openDatabase(const IDBOpenRequestData& requestData)
{
    m_server->openDatabase(requestData);
}

void IDBServer::deleteDatabase(const IDBOpenRequestData& requestData)
{
    m_server->deleteDatabase(requestData);
}

void IDBServer::abortTransaction(const IDBResourceIdentifier& transactionIdentifier)
{
    m_server->abortTransaction(transactionIdentifier);
}

void IDBServer::commitTransaction(const IDBResourceIdentifier& transactionIdentifier, uint64_t handledRequestResultsCount)
{
    m_server->commitTransaction(transactionIdentifier, handledRequestResultsCount);
}

void IDBServer::didFinishHandlingVersionChangeTransaction(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier, const IDBResourceIdentifier& transactionIdentifier)
{
    m_server->didFinishHandlingVersionChangeTransaction(databaseConnectionIdentifier, transactionIdentifier);
}

void IDBServer::createObjectStore(const IDBRequestData& requestData, const IDBObjectStoreInfo& info)
{
    m_server->createObjectStore(requestData, info);
}

void IDBServer::renameObjectStore(const IDBRequestData& requestData, IDBObjectStoreIdentifier objectStoreIdentifier, const String& newName)
{
    m_server->renameObjectStore(requestData, objectStoreIdentifier, newName);
}

void IDBServer::deleteObjectStore(const IDBRequestData& requestData, const String& objectStoreName)
{
    m_server->deleteObjectStore(requestData, objectStoreName);
}

void IDBServer::clearObjectStore(const IDBRequestData& requestData, IDBObjectStoreIdentifier objectStoreIdentifier)
{
    m_server->clearObjectStore(requestData, objectStoreIdentifier);
}

void IDBServer::createIndex(const IDBRequestData& requestData, const IDBIndexInfo& info)
{
    m_server->createIndex(requestData, info);
}

void IDBServer::deleteIndex(const IDBRequestData& requestData, IDBObjectStoreIdentifier objectStoreIdentifier, const String& indexName)
{
    m_server->deleteIndex(requestData, objectStoreIdentifier, indexName);
}

void IDBServer::renameIndex(const IDBRequestData& requestData, IDBObjectStoreIdentifier objectStoreIdentifier, IDBIndexIdentifier indexIdentifier, const String& newName)
{
    m_server->renameIndex(requestData, objectStoreIdentifier, indexIdentifier, newName);
}

void IDBServer::putOrAdd(const IDBRequestData& requestData, const IDBKeyData& keyData, const IDBValue& value, const IndexIDToIndexKeyMap& indexKeys, IndexedDB::ObjectStoreOverwriteMode overwriteMode)
{
    m_server->putOrAdd(requestData, keyData, value, indexKeys, overwriteMode);
}

void IDBServer::getRecord(const IDBRequestData& requestData, const IDBGetRecordData& getRecordData)
{
    m_server->getRecord(requestData, getRecordData);
}

void IDBServer::getAllRecords(const IDBRequestData& requestData, const IDBGetAllRecordsData& getAllRecordsData)
{
    m_server->getAllRecords(requestData, getAllRecordsData);
}

void IDBServer::getCount(const IDBRequestData& requestData, const IDBKeyRangeData& keyRangeData)
{
    m_server->getCount(requestData, keyRangeData);
}

void IDBServer::deleteRecord(const IDBRequestData& requestData, const IDBKeyRangeData& keyRangeData)
{
    m_server->deleteRecord(requestData, keyRangeData);
}

void IDBServer::openCursor(const IDBRequestData& requestData, const IDBCursorInfo& info)
{
    m_server->openCursor(requestData, info);
}

void IDBServer::iterateCursor(const IDBRequestData& requestData, const IDBIterateCursorData& data)
{
    m_server->iterateCursor(requestData, data);
}

void IDBServer::establishTransaction(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier, const IDBTransactionInfo& info)
{
    m_server->establishTransaction(databaseConnectionIdentifier, info);
}

void IDBServer::databaseConnectionPendingClose(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier)
{
    m_server->databaseConnectionPendingClose(databaseConnectionIdentifier);
}

void IDBServer::databaseConnectionClosed(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier)
{
    m_server->databaseConnectionClosed(databaseConnectionIdentifier);
}

void IDBServer::abortOpenAndUpgradeNeeded(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier, const std::optional<IDBResourceIdentifier>& transactionIdentifier)
{
    m_server->abortOpenAndUpgradeNeeded(databaseConnectionIdentifier, transactionIdentifier ? swift::Optional<IDBResourceIdentifier>::init(*transactionIdentifier) : swift::Optional<IDBResourceIdentifier>::none());
}

void IDBServer::didFireVersionChangeEvent(IDBDatabaseConnectionIdentifier databaseConnectionIdentifier, const IDBResourceIdentifier& requestIdentifier, IndexedDB::ConnectionClosedOnBehalfOfServer connectionClosed)
{
    m_server->didFireVersionChangeEvent(databaseConnectionIdentifier, requestIdentifier, connectionClosed);
}

void IDBServer::didGenerateIndexKeyForRecord(const IDBResourceIdentifier& transactionIdentifier, const IDBResourceIdentifier& requestIdentifier, const IDBIndexInfo& indexInfo, const IDBKeyData& key, const IndexKey& indexKey, std::optional<int64_t> recordID)
{
    m_server->didGenerateIndexKeyForRecord(transactionIdentifier, requestIdentifier, indexInfo, key, indexKey, recordID ? swift::Optional<int64_t>::init(*recordID) : swift::Optional<int64_t>::none());
}

void IDBServer::openDBRequestCancelled(const IDBOpenRequestData& requestData)
{
    m_server->openDBRequestCancelled(requestData);
}

void IDBServer::getAllDatabaseNamesAndVersions(IDBConnectionIdentifier serverConnectionIdentifier, const IDBResourceIdentifier& requestIdentifier, const ClientOrigin& origin)
{
    m_server->getAllDatabaseNamesAndVersions(serverConnectionIdentifier, requestIdentifier, origin);
}

HashSet<SecurityOriginData> IDBServer::getOrigins() const
{
    HashSet<SecurityOriginData> origins;
    for (auto& origin : m_server->getOrigins())
        origins.add(origin);
    return origins;
}

void IDBServer::closeAndDeleteDatabasesModifiedSince(WallTime modificationTime)
{
    m_server->closeAndDeleteDatabasesModifiedSince(modificationTime);
}

uint64_t IDBServer::diskUsage(const String& rootDirectory, const ClientOrigin& origin)
{
    return SwiftIDBServer::diskUsage(rootDirectory, origin);
}

} // namespace IDBServer
} // namespace WebCore
