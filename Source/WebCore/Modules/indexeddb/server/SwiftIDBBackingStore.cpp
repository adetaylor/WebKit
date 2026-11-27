/*
 * Copyright (C) 2015-2021 Apple Inc. All rights reserved.
 * Copyright (C) 2016-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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
#include "SwiftIDBBackingStore.h"

#include "IDBCursorInfo.h"
#include "IDBGetAllRecordsData.h"
#include "IDBGetAllResult.h"
#include "IDBGetRecordData.h"
#include "IDBGetResult.h"
#include "IDBIterateCursorData.h"
#include "IDBTransactionInfo.h"
#include "Logging.h"
#include "SQLiteIDBStoreTypes.h"
#include "SwiftIDBTypes.h"
#include "WebCore-Swift.h"
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

struct SwiftIDBStoreHolder {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(SwiftIDBStoreHolder);

    explicit SwiftIDBStoreHolder(const String& databaseName)
        : store(SwiftIDBStore::init(databaseName))
    {
    }

    SwiftIDBStore store;
};

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(SwiftIDBStoreHolder);
WTF_MAKE_TZONE_ALLOCATED_IMPL(SwiftIDBBackingStore);

// The IDBError the in-memory store returns for each failure.
static IDBError makeMemoryIDBStoreError(MemoryIDBStoreError error)
{
    switch (error) {
    case MemoryIDBStoreError::None:
        return IDBError { };
    case MemoryIDBStoreError::Constraint:
        return IDBError { ExceptionCode::ConstraintError };
    case MemoryIDBStoreError::TransactionExists:
        return IDBError { ExceptionCode::InvalidStateError, "Backing store asked to create transaction it already has a record of"_s };
    case MemoryIDBStoreError::AbortUnknownTransaction:
        return IDBError { ExceptionCode::InvalidStateError, "Backing store asked to abort transaction it didn't have record of"_s };
    case MemoryIDBStoreError::CommitUnknownTransaction:
        return IDBError { ExceptionCode::InvalidStateError, "Backing store asked to commit transaction it didn't have record of"_s };
    case MemoryIDBStoreError::NoTransactionToDeleteFrom:
        return IDBError { ExceptionCode::UnknownError, "No backing store transaction found to delete from"_s };
    case MemoryIDBStoreError::NoObjectStore:
        return IDBError { ExceptionCode::UnknownError, "No backing store object store found"_s };
    case MemoryIDBStoreError::NoTransactionToPutRecord:
        return IDBError { ExceptionCode::UnknownError, "No backing store transaction found to put record"_s };
    case MemoryIDBStoreError::NoObjectStoreToPutRecord:
        return IDBError { ExceptionCode::UnknownError, "No backing store object store found to put record"_s };
    case MemoryIDBStoreError::NoTransactionToGetRecord:
        return IDBError { ExceptionCode::UnknownError, "No backing store transaction found to get record"_s };
    case MemoryIDBStoreError::NoTransactionToGetAllRecords:
        return IDBError { ExceptionCode::UnknownError, "No backing store transaction found to get all records"_s };
    case MemoryIDBStoreError::NoIndex:
        return IDBError { ExceptionCode::UnknownError, "No backing store index found"_s };
    case MemoryIDBStoreError::NoTransactionToGetCount:
        return IDBError { ExceptionCode::UnknownError, "No backing store transaction found to get count"_s };
    case MemoryIDBStoreError::KeyGeneratorOverflow:
        return IDBError { ExceptionCode::ConstraintError, "Cannot generate new key value over 2^53 for object store operation"_s };
    case MemoryIDBStoreError::NoTransactionToOpenCursor:
        return IDBError { ExceptionCode::UnknownError, "No backing store transaction found in which to open a cursor"_s };
    case MemoryIDBStoreError::CannotCreateObjectStoreCursor:
        return IDBError { ExceptionCode::UnknownError, "Could not create object store cursor in backing store"_s };
    case MemoryIDBStoreError::CannotCreateIndexCursor:
        return IDBError { ExceptionCode::UnknownError, "Could not create index cursor in backing store"_s };
    case MemoryIDBStoreError::NoTransactionToIterateCursor:
        return IDBError { ExceptionCode::UnknownError, "No backing store transaction found in which to iterate cursor"_s };
    case MemoryIDBStoreError::NoCursorToIterate:
        return IDBError { ExceptionCode::UnknownError, "No backing store cursor found in which to iterate cursor"_s };
    case MemoryIDBStoreError::DatabaseInfoInvalid:
        return IDBError { ExceptionCode::UnknownError, "Database info is invalid."_s };
    case MemoryIDBStoreError::ObjectStoreNotInDatabaseInfo:
        return IDBError { ExceptionCode::ConstraintError, "Object store does not exist in database info."_s };
    case MemoryIDBStoreError::NotVersionChange:
        return IDBError { ExceptionCode::UnknownError, "Transaction is not in version change mode."_s };
    case MemoryIDBStoreError::ObjectStoreNotInBackingStore:
        return IDBError { ExceptionCode::ConstraintError, "Object store does not exist in backing store."_s };
    case MemoryIDBStoreError::TransactionNotActive:
        return IDBError { ExceptionCode::UnknownError, "Transaction is not active."_s };
    case MemoryIDBStoreError::TransactionStateInvalid:
        return IDBError { ExceptionCode::ConstraintError, "Transaction state is invalid."_s };
    case MemoryIDBStoreError::IndexIdentifierExists:
        return IDBError { ExceptionCode::ConstraintError, "Index identifier already exists"_s };
    case MemoryIDBStoreError::IndexDoesNotExist:
        return IDBError { ExceptionCode::ConstraintError, "Index does not exist."_s };
    case MemoryIDBStoreError::MissingIndexMetadata:
        return IDBError { ExceptionCode::InvalidStateError, "Missing index metadata"_s };
    case MemoryIDBStoreError::UniquenessViolation:
        return IDBError { ExceptionCode::ConstraintError, "Unable to store record in object store because it does not satisfy the uniqueness requirements of an index"_s };
    }
    RELEASE_ASSERT_NOT_REACHED();
}

SwiftIDBBackingStore::SwiftIDBBackingStore(const IDBDatabaseIdentifier& identifier)
    : m_store(makeUnique<SwiftIDBStoreHolder>(identifier.databaseName()))
{
}

SwiftIDBBackingStore::~SwiftIDBBackingStore() = default;

IDBError SwiftIDBBackingStore::getOrEstablishDatabaseInfo(IDBDatabaseInfo& info)
{
    info = m_store->store.establishDatabaseInfo();
    return IDBError { };
}

uint64_t SwiftIDBBackingStore::databaseVersion()
{
    return m_store->store.databaseVersion();
}

IDBError SwiftIDBBackingStore::beginTransaction(const IDBTransactionInfo& info)
{
    return makeMemoryIDBStoreError(m_store->store.beginTransaction(info.identifier(), info.mode(), info.objectStores()));
}

IDBError SwiftIDBBackingStore::abortTransaction(const IDBResourceIdentifier& transactionIdentifier)
{
    return makeMemoryIDBStoreError(m_store->store.abortTransaction(transactionIdentifier));
}

IDBError SwiftIDBBackingStore::commitTransaction(const IDBResourceIdentifier& transactionIdentifier)
{
    return makeMemoryIDBStoreError(m_store->store.commitTransaction(transactionIdentifier));
}

IDBError SwiftIDBBackingStore::createObjectStore(const IDBResourceIdentifier& transactionIdentifier, const IDBObjectStoreInfo& info)
{
    return makeMemoryIDBStoreError(m_store->store.createObjectStore(transactionIdentifier, info));
}

IDBError SwiftIDBBackingStore::deleteObjectStore(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier)
{
    return makeMemoryIDBStoreError(m_store->store.deleteObjectStore(transactionIdentifier, objectStoreIdentifier));
}

IDBError SwiftIDBBackingStore::renameObjectStore(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, const String& newName)
{
    return makeMemoryIDBStoreError(m_store->store.renameObjectStore(transactionIdentifier, objectStoreIdentifier, newName));
}

IDBError SwiftIDBBackingStore::clearObjectStore(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier)
{
    return makeMemoryIDBStoreError(m_store->store.clearObjectStore(transactionIdentifier, objectStoreIdentifier));
}

IDBError SwiftIDBBackingStore::deleteIndex(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, IDBIndexIdentifier indexIdentifier)
{
    return makeMemoryIDBStoreError(m_store->store.deleteIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier));
}

IDBError SwiftIDBBackingStore::renameIndex(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, IDBIndexIdentifier indexIdentifier, const String& newName)
{
    return makeMemoryIDBStoreError(m_store->store.renameIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier, newName));
}

IDBError SwiftIDBBackingStore::keyExistsInObjectStore(const IDBResourceIdentifier&, IDBObjectStoreIdentifier objectStoreIdentifier, const IDBKeyData& key, bool& keyExists)
{
    keyExists = m_store->store.keyExistsInObjectStore(objectStoreIdentifier, key);
    return IDBError { };
}

IDBError SwiftIDBBackingStore::deleteRange(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, const IDBKeyRangeData& range)
{
    return makeMemoryIDBStoreError(m_store->store.deleteRange(transactionIdentifier, objectStoreIdentifier, range));
}

IDBError SwiftIDBBackingStore::overwriteRecord(const IDBResourceIdentifier& transactionIdentifier, const IDBObjectStoreInfo& objectStoreInfo, const IDBKeyData& key, const IndexIDToIndexKeyMap& indexKeys, const IDBValue& value)
{
    return makeMemoryIDBStoreError(m_store->store.overwriteRecord(transactionIdentifier, objectStoreInfo.identifier(), key, idbIndexKeyMapEntries(indexKeys), value.data()));
}

IDBError SwiftIDBBackingStore::getRecord(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, const IDBKeyRangeData& range, IDBGetRecordDataType type, IDBGetResult& outValue)
{
    auto error = m_store->store.getRecordError(transactionIdentifier, objectStoreIdentifier);
    if (error != MemoryIDBStoreError::None)
        return makeMemoryIDBStoreError(error);
    outValue = m_store->store.getRecord(objectStoreIdentifier, range, type == IDBGetRecordDataType::KeyAndValue);
    return IDBError { };
}

IDBError SwiftIDBBackingStore::getAllRecords(const IDBResourceIdentifier& transactionIdentifier, const IDBGetAllRecordsData& data, IDBGetAllResult& result)
{
    bool hasIndex = !!data.indexIdentifier;
    uint64_t indexIdentifier = hasIndex ? data.indexIdentifier->toUInt64() : 0;
    auto error = m_store->store.getAllRecordsError(transactionIdentifier, data.objectStoreIdentifier, hasIndex, indexIdentifier);
    if (error != MemoryIDBStoreError::None)
        return makeMemoryIDBStoreError(error);
    result = m_store->store.getAllRecords(data.objectStoreIdentifier, hasIndex, indexIdentifier, data.keyRangeData, data.count.value_or(0), data.getAllType);
    return IDBError { };
}

IDBError SwiftIDBBackingStore::getIndexRecord(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, IDBIndexIdentifier indexIdentifier, IndexedDB::IndexRecordType recordType, const IDBKeyRangeData& range, IDBGetResult& outValue)
{
    auto error = m_store->store.getRecordError(transactionIdentifier, objectStoreIdentifier);
    if (error != MemoryIDBStoreError::None)
        return makeMemoryIDBStoreError(error);
    outValue = m_store->store.getIndexRecord(objectStoreIdentifier, indexIdentifier, recordType == IndexedDB::IndexRecordType::Key, range);
    return IDBError { };
}

IDBError SwiftIDBBackingStore::getCount(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, std::optional<IDBIndexIdentifier> indexIdentifier, const IDBKeyRangeData& range, uint64_t& outCount)
{
    return makeMemoryIDBStoreError(m_store->store.getCount(transactionIdentifier, objectStoreIdentifier, !!indexIdentifier, indexIdentifier ? indexIdentifier->toUInt64() : 0, range, outCount));
}

IDBError SwiftIDBBackingStore::generateKeyNumber(const IDBResourceIdentifier&, IDBObjectStoreIdentifier objectStoreIdentifier, uint64_t& keyNumber)
{
    return makeMemoryIDBStoreError(m_store->store.generateKeyNumber(objectStoreIdentifier, keyNumber));
}

IDBError SwiftIDBBackingStore::revertGeneratedKeyNumber(const IDBResourceIdentifier&, IDBObjectStoreIdentifier objectStoreIdentifier, uint64_t keyNumber)
{
    m_store->store.revertGeneratedKeyNumber(objectStoreIdentifier, keyNumber);
    return IDBError { };
}

IDBError SwiftIDBBackingStore::maybeUpdateKeyGeneratorNumber(const IDBResourceIdentifier&, IDBObjectStoreIdentifier objectStoreIdentifier, double newKeyNumber)
{
    m_store->store.maybeUpdateKeyGeneratorNumber(objectStoreIdentifier, newKeyNumber);
    return IDBError { };
}

IDBError SwiftIDBBackingStore::openCursor(const IDBResourceIdentifier& transactionIdentifier, const IDBCursorInfo& info, IDBGetResult& outResult)
{
    auto error = m_store->store.openCursorError(transactionIdentifier, info);
    if (error != MemoryIDBStoreError::None)
        return makeMemoryIDBStoreError(error);
    outResult = m_store->store.takeCursorResult();
    return IDBError { };
}

IDBError SwiftIDBBackingStore::iterateCursor(const IDBResourceIdentifier& transactionIdentifier, const IDBResourceIdentifier& cursorIdentifier, const IDBIterateCursorData& data, IDBGetResult& outResult)
{
    auto result = m_store->store.iterateCursor(transactionIdentifier, cursorIdentifier, data.keyData, data.primaryKeyData, data.count);
    auto error = m_store->store.takeIterateCursorError();
    if (error != MemoryIDBStoreError::None)
        return makeMemoryIDBStoreError(error);
    outResult = WTF::move(result);
    return IDBError { };
}

IDBObjectStoreInfo* SwiftIDBBackingStore::infoForObjectStore(IDBObjectStoreIdentifier objectStoreIdentifier)
{
    if (!m_store->store.hasObjectStoreInfo(objectStoreIdentifier))
        return nullptr;
    m_objectStoreInfo = m_store->store.objectStoreInfo(objectStoreIdentifier);
    return &*m_objectStoreInfo;
}

bool SwiftIDBBackingStore::hasTransaction(const IDBResourceIdentifier& identifier) const
{
    return m_store->store.hasTransaction(identifier);
}

IDBError SwiftIDBBackingStore::addIndex(const IDBResourceIdentifier& transactionIdentifier, const IDBIndexInfo& indexInfo)
{
    return makeMemoryIDBStoreError(m_store->store.addIndex(transactionIdentifier, indexInfo));
}

void SwiftIDBBackingStore::revertAddIndex(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, IDBIndexIdentifier indexIdentifier)
{
    m_store->store.revertAddIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier);
}

IDBError SwiftIDBBackingStore::updateIndexRecordsWithIndexKey(const IDBResourceIdentifier& transactionIdentifier, const IDBIndexInfo& indexInfo, const IDBKeyData& key, const IndexKey& indexKey, std::optional<int64_t>)
{
    return makeMemoryIDBStoreError(m_store->store.updateIndexRecordsWithIndexKey(transactionIdentifier, indexInfo, key, indexKey));
}

void SwiftIDBBackingStore::forEachObjectStoreRecord(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, NOESCAPE const Function<void(RecordOrError&&)>& apply)
{
    auto error = m_store->store.forEachObjectStoreRecordError(transactionIdentifier, objectStoreIdentifier);
    if (error != MemoryIDBStoreError::None) {
        apply(makeUnexpected(makeMemoryIDBStoreError(error)));
        return;
    }
    auto keys = m_store->store.objectStoreRecordKeys(objectStoreIdentifier);
    auto values = m_store->store.objectStoreRecordValues(objectStoreIdentifier);
    for (size_t i = 0; i < keys.size(); ++i)
        apply(ObjectStoreRecord { keys[i], values[i], std::nullopt });
}

// SQLiteIDBStore.swift compares SQLite's results to these values.
static_assert(!SQLITE_OK && SQLITE_ROW == 100 && SQLITE_DONE == 101);

struct SwiftSQLiteIDBStoreHolder {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(SwiftSQLiteIDBStoreHolder);

    SwiftSQLiteIDBStoreHolder(const String& databaseName, const String& databaseDirectory, bool isInMemory)
        : store(SQLiteIDBStore::init(databaseName, databaseDirectory, isInMemory))
    {
    }

    SQLiteIDBStore store;
};

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(SwiftSQLiteIDBStoreHolder);
WTF_MAKE_TZONE_ALLOCATED_IMPL(SwiftSQLiteIDBBackingStore);

SwiftSQLiteIDBBackingStore::SwiftSQLiteIDBBackingStore(const IDBDatabaseIdentifier& identifier, const String& databaseDirectory, bool isInMemory)
    : m_store(makeUnique<SwiftSQLiteIDBStoreHolder>(identifier.databaseName(), databaseDirectory, isInMemory))
    , m_isInMemory(isInMemory)
{
}

SwiftSQLiteIDBBackingStore::~SwiftSQLiteIDBBackingStore() = default;

IDBError SwiftSQLiteIDBBackingStore::getOrEstablishDatabaseInfo(IDBDatabaseInfo& info)
{
    auto error = m_store->store.establishDatabaseInfo();
    if (error.isNull())
        info = m_store->store.currentDatabaseInfo();
    return error;
}

uint64_t SwiftSQLiteIDBBackingStore::databaseVersion()
{
    return m_store->store.databaseVersion();
}

void SwiftSQLiteIDBBackingStore::handleLowMemoryWarning()
{
    m_store->store.handleLowMemoryWarning();
}

IDBError SwiftSQLiteIDBBackingStore::beginTransaction(const IDBTransactionInfo& info)
{
    return m_store->store.beginTransaction(info.identifier(), info.mode(), info.durability(), info.newVersion());
}

IDBError SwiftSQLiteIDBBackingStore::abortTransaction(const IDBResourceIdentifier& transactionIdentifier)
{
    return m_store->store.abortTransaction(transactionIdentifier);
}

IDBError SwiftSQLiteIDBBackingStore::commitTransaction(const IDBResourceIdentifier& transactionIdentifier)
{
    return m_store->store.commitTransaction(transactionIdentifier);
}

IDBError SwiftSQLiteIDBBackingStore::createObjectStore(const IDBResourceIdentifier& transactionIdentifier, const IDBObjectStoreInfo& info)
{
    return m_store->store.createObjectStore(transactionIdentifier, info);
}

IDBError SwiftSQLiteIDBBackingStore::deleteObjectStore(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier)
{
    return m_store->store.deleteObjectStore(transactionIdentifier, objectStoreIdentifier);
}

IDBError SwiftSQLiteIDBBackingStore::renameObjectStore(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, const String& newName)
{
    return m_store->store.renameObjectStore(transactionIdentifier, objectStoreIdentifier, newName);
}

IDBError SwiftSQLiteIDBBackingStore::clearObjectStore(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier)
{
    return m_store->store.clearObjectStore(transactionIdentifier, objectStoreIdentifier);
}

IDBError SwiftSQLiteIDBBackingStore::deleteIndex(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, IDBIndexIdentifier indexIdentifier)
{
    return m_store->store.deleteIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier);
}

IDBError SwiftSQLiteIDBBackingStore::renameIndex(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, IDBIndexIdentifier indexIdentifier, const String& newName)
{
    return m_store->store.renameIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier, newName);
}

IDBError SwiftSQLiteIDBBackingStore::keyExistsInObjectStore(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, const IDBKeyData& key, bool& keyExists)
{
    auto error = m_store->store.keyExistsInObjectStore(transactionIdentifier, objectStoreIdentifier, key);
    keyExists = m_store->store.takeKeyExists();
    return error;
}

IDBError SwiftSQLiteIDBBackingStore::deleteRange(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, const IDBKeyRangeData& range)
{
    return m_store->store.deleteRange(transactionIdentifier, objectStoreIdentifier, range);
}

IDBError SwiftSQLiteIDBBackingStore::overwriteRecord(const IDBResourceIdentifier& transactionIdentifier, const IDBObjectStoreInfo& objectStoreInfo, const IDBKeyData& key, const IndexIDToIndexKeyMap& indexKeys, const IDBValue& value)
{
    return m_store->store.overwriteRecord(transactionIdentifier, objectStoreInfo, key, idbIndexKeyMapEntries(indexKeys), value);
}

IDBError SwiftSQLiteIDBBackingStore::getRecord(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, const IDBKeyRangeData& range, IDBGetRecordDataType type, IDBGetResult& outValue)
{
    auto error = m_store->store.getRecord(transactionIdentifier, objectStoreIdentifier, range, type == IDBGetRecordDataType::KeyAndValue);
    if (error.isNull())
        outValue = m_store->store.takeGetResult();
    return error;
}

IDBError SwiftSQLiteIDBBackingStore::getAllRecords(const IDBResourceIdentifier& transactionIdentifier, const IDBGetAllRecordsData& data, IDBGetAllResult& result)
{
    bool hasIndex = !!data.indexIdentifier;
    auto error = m_store->store.getAllRecords(transactionIdentifier, data.objectStoreIdentifier, hasIndex, hasIndex ? data.indexIdentifier->toUInt64() : 0, data.keyRangeData, data.count.value_or(0), data.getAllType, data.cursorDirection);
    // A failure leaves the result begun so far (type and key path), or an empty one.
    result = m_store->store.takeGetAllResult();
    return error;
}

IDBError SwiftSQLiteIDBBackingStore::getIndexRecord(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, IDBIndexIdentifier indexIdentifier, IndexedDB::IndexRecordType recordType, const IDBKeyRangeData& range, IDBGetResult& outValue)
{
    auto error = m_store->store.getIndexRecord(transactionIdentifier, objectStoreIdentifier, indexIdentifier, recordType == IndexedDB::IndexRecordType::Key, range);
    if (error.isNull())
        outValue = m_store->store.takeGetResult();
    return error;
}

IDBError SwiftSQLiteIDBBackingStore::getCount(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, std::optional<IDBIndexIdentifier> indexIdentifier, const IDBKeyRangeData& range, uint64_t& outCount)
{
    auto error = m_store->store.getCount(transactionIdentifier, objectStoreIdentifier, !!indexIdentifier, indexIdentifier ? indexIdentifier->toUInt64() : 0, range);
    if (m_store->store.countWritten())
        outCount = m_store->store.takeNumber();
    return error;
}

IDBError SwiftSQLiteIDBBackingStore::generateKeyNumber(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, uint64_t& keyNumber)
{
    auto error = m_store->store.generateKeyNumberEntry(transactionIdentifier, objectStoreIdentifier);
    // The out-parameter is written once the number is generated, whether or not storing it then failed.
    if (m_store->store.countWritten())
        keyNumber = m_store->store.takeNumber();
    return error;
}

IDBError SwiftSQLiteIDBBackingStore::revertGeneratedKeyNumber(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, uint64_t keyNumber)
{
    return m_store->store.revertGeneratedKeyNumber(transactionIdentifier, objectStoreIdentifier, keyNumber);
}

IDBError SwiftSQLiteIDBBackingStore::maybeUpdateKeyGeneratorNumber(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, double newKeyNumber)
{
    return m_store->store.maybeUpdateKeyGeneratorNumber(transactionIdentifier, objectStoreIdentifier, newKeyNumber);
}

IDBError SwiftSQLiteIDBBackingStore::openCursor(const IDBResourceIdentifier& transactionIdentifier, const IDBCursorInfo& info, IDBGetResult& outResult)
{
    auto error = m_store->store.openCursor(transactionIdentifier, info);
    if (error.isNull())
        outResult = m_store->store.takeGetResult();
    return error;
}

IDBError SwiftSQLiteIDBBackingStore::iterateCursor(const IDBResourceIdentifier& transactionIdentifier, const IDBResourceIdentifier& cursorIdentifier, const IDBIterateCursorData& data, IDBGetResult& outResult)
{
    auto error = m_store->store.iterateCursor(transactionIdentifier, cursorIdentifier, data.keyData, data.primaryKeyData, data.count, data.option == IndexedDB::CursorIterateOption::Reply);
    if (error.isNull() && data.option == IndexedDB::CursorIterateOption::Reply)
        outResult = m_store->store.takeGetResult();
    return error;
}

IDBObjectStoreInfo* SwiftSQLiteIDBBackingStore::infoForObjectStore(IDBObjectStoreIdentifier objectStoreIdentifier)
{
    if (!m_store->store.hasObjectStore(objectStoreIdentifier))
        return nullptr;
    m_objectStoreInfo = m_store->store.objectStoreInfo(objectStoreIdentifier);
    return &*m_objectStoreInfo;
}

void SwiftSQLiteIDBBackingStore::deleteBackingStore()
{
    m_store->store.deleteBackingStore();
}

String SwiftSQLiteIDBBackingStore::fullDatabasePath() const
{
    return m_store->store.databasePath();
}

bool SwiftSQLiteIDBBackingStore::hasTransaction(const IDBResourceIdentifier& identifier) const
{
    return m_store->store.hasTransaction(identifier);
}

IDBError SwiftSQLiteIDBBackingStore::addIndex(const IDBResourceIdentifier& transactionIdentifier, const IDBIndexInfo& indexInfo)
{
    return m_store->store.addIndex(transactionIdentifier, indexInfo);
}

void SwiftSQLiteIDBBackingStore::revertAddIndex(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, IDBIndexIdentifier indexIdentifier)
{
    m_store->store.revertAddIndex(transactionIdentifier, objectStoreIdentifier, indexIdentifier);
}

IDBError SwiftSQLiteIDBBackingStore::updateIndexRecordsWithIndexKey(const IDBResourceIdentifier& transactionIdentifier, const IDBIndexInfo& indexInfo, const IDBKeyData& key, const IndexKey& indexKey, std::optional<int64_t> recordID)
{
    return m_store->store.updateIndexRecordsWithIndexKey(transactionIdentifier, indexInfo, key, indexKey, !!recordID, recordID.value_or(0));
}

void SwiftSQLiteIDBBackingStore::forEachObjectStoreRecord(const IDBResourceIdentifier& transactionIdentifier, IDBObjectStoreIdentifier objectStoreIdentifier, NOESCAPE const Function<void(RecordOrError&&)>& apply)
{
    auto error = m_store->store.beginForEachObjectStoreRecord(transactionIdentifier, objectStoreIdentifier);
    if (!error.isNull()) {
        apply(makeUnexpected(WTF::move(error)));
        return;
    }
    while (m_store->store.forEachHasRecord()) {
        apply(ObjectStoreRecord { m_store->store.forEachKey(), m_store->store.forEachValue(), m_store->store.forEachRowID() });
        if (m_store->store.forEachAdvance())
            continue;
        m_store->store.endForEachObjectStoreRecord();
        apply(makeUnexpected(IDBError { ExceptionCode::UnknownError, "Error advancing cursor when iterating object store records"_s }));
        return;
    }
    m_store->store.endForEachObjectStoreRecord();
}

void SwiftSQLiteIDBBackingStore::close()
{
    m_store->store.close();
}

// The IDBKEY collation of both SQLite stores: a key that does not decode sorts after the other one (the file store),
// or as the in-memory store has it, after when the first does not decode and before when the second does not.
static int sqliteIDBCollate(int aLength, const void* a, int bLength, const void* b, int secondKeyFailure)
{
    // There's no way to indicate an error to SQLite - we have to return a sorting decision.
    IDBKeyData keyA;
    if (!deserializeIDBKeyData(unsafeMakeSpan(static_cast<const uint8_t*>(a), aLength), keyA)) {
        LOG_ERROR("Unable to deserialize key A in collation function.");
        return 1;
    }
    IDBKeyData keyB;
    if (!deserializeIDBKeyData(unsafeMakeSpan(static_cast<const uint8_t*>(b), bLength), keyB)) {
        LOG_ERROR("Unable to deserialize key B in collation function.");
        return secondKeyFailure;
    }
    return keyA.compare(keyB);
}

bool sqliteIDBOpenMemoryDatabase(SQLiteDatabase& database)
{
    if (!database.open(SQLiteDatabase::inMemoryPath())) {
        RELEASE_LOG_ERROR(IndexedDB, "SQLiteIDBStore::getOrEstablishDatabaseInfo: Failed to open in-memory database (%d) - %" PUBLIC_LOG_STRING, database.lastError(), database.lastErrorMsg());
        return false;
    }
    return true;
}

void sqliteIDBPrepareOpenedMemoryDatabase(SQLiteDatabase& database)
{
    database.disableThreadingChecks();
    // A smaller cache for private browsing (negative: in KB, not pages). No WAL: the database is not a file.
    if (!database.executeCommand("PRAGMA cache_size = -512;"_s))
        LOG_ERROR("SQLite in-memory database could not set cache_size");
    database.setCollationFunction("IDBKEY"_s, [](int aLength, const void* a, int bLength, const void* b) {
        return sqliteIDBCollate(aLength, a, bLength, b, -1);
    });
}

void sqliteIDBLogOpenFailure(const String& databasePath, SQLiteDatabase& database)
{
    RELEASE_LOG_ERROR(IndexedDB, "SQLiteIDBStore::getOrEstablishDatabaseInfo: Failed to open database at path '%" PUBLIC_LOG_STRING "' (%d) - %" PUBLIC_LOG_STRING, databasePath.utf8(), database.lastError(), database.lastErrorMsg());
}

void sqliteIDBLogMismatchedMetadataVersion()
{
    RELEASE_LOG(IndexedDB, "migrateIDBDatabaseInfoTableIfNecessary: Found mismatched metadata version; will upgrade again");
}

void sqliteIDBLogMissingObjectStore(const String& function)
{
    RELEASE_LOG_ERROR(IndexedDB, "SQLiteIDBStore::%" PUBLIC_LOG_STRING ": object store cannot be found in database", function.utf8());
}

void sqliteIDBLogMissingDatabaseInfo(const String& function)
{
    RELEASE_LOG_ERROR(IndexedDB, "SQLiteIDBStore::%" PUBLIC_LOG_STRING ": database info is null", function.utf8());
}

void sqliteIDBPrepareOpenedDatabase(SQLiteDatabase& database)
{
    database.disableThreadingChecks();
    database.enableAutomaticWALTruncation();
    database.setCollationFunction("IDBKEY"_s, [](int aLength, const void* a, int bLength, const void* b) {
        return sqliteIDBCollate(aLength, a, bLength, b, 1);
    });
}

} // namespace WebCore
