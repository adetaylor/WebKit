/*
 * Copyright (C) 2015-2021 Apple Inc. All rights reserved.
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

#pragma once

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
#include <WebCore/IDBTransactionInfo.h>
#include <WebCore/IDBValue.h>
#include <WebCore/IndexKey.h>
#include <WebCore/SQLiteFileSystem.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/ThreadSafeDataBuffer.h>
#include <memory>
#include <span>
#include <wtf/FileSystem.h>
#include <wtf/Function.h>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/Vector.h>
#include <wtf/WallTime.h>
#include <wtf/text/WTFString.h>

// What the IndexedDB backing stores' Swift (Modules/indexeddb/server/*.swift) needs from C++ that it cannot spell
// itself: names for template specializations, and the few Vector and String operations whose C++ members are templates.
// The helpers are ALWAYS_INLINE because Swift's optimizer leaves imported C++ functions out of line otherwise.

namespace WebCore {

// A serialized key's bytes (serializeIDBKeyDataBytes).
using IDBSerializedKeyBytes = Vector<uint8_t>;
using IDBSerializedKeySpan = std::span<const uint8_t>;

// Swift traps when it passes C++ an empty Span with a null base, so it calls these only with a non-empty one.
ALWAYS_INLINE void appendIDBSerializedKeyBytes(IDBSerializedKeyBytes& vector, std::span<const uint8_t> bytes NOESCAPE)
{
    vector.append(bytes);
}

// encodeKey's Binary case: the buffer's bytes, appended where the buffer has any.
ALWAYS_INLINE void appendIDBKeyBinaryBytes(IDBSerializedKeyBytes& vector, const IDBKeyData& key)
{
    auto* bytes = key.binary().data();
    ASSERT(bytes || !key.binary().size());
    if (bytes)
        vector.append(bytes->span());
}

// encodeKey's Array case: the elements, read in place for as long as the key lives.
ALWAYS_INLINE std::span<const IDBKeyData> idbKeyArrayElements(const IDBKeyData& key LIFETIME_BOUND)
{
    return key.array().span();
}

// decodeKey's String case: String::adopt of a Vector<char16_t> holding the little-endian code units of the bytes.
ALWAYS_INLINE String makeIDBKeyStringFromLittleEndianBytes(std::span<const uint8_t> bytes NOESCAPE)
{
    return String::adopt(Vector<char16_t>(bytes.size() / 2, [&](size_t i) {
        return static_cast<char16_t>(bytes[2 * i] | (bytes[2 * i + 1] << 8));
    }));
}

ALWAYS_INLINE String makeEmptyIDBKeyString()
{
    return String::adopt(Vector<char16_t>());
}

// decodeKey's Binary case: a ThreadSafeDataBuffer created from a Vector copy of the bytes.
ALWAYS_INLINE void setIDBKeyBinaryValue(IDBKeyData& key, std::span<const uint8_t> bytes NOESCAPE)
{
    key.setBinaryValue(ThreadSafeDataBuffer::create(Vector<uint8_t>(bytes)));
}

ALWAYS_INLINE void setEmptyIDBKeyBinaryValue(IDBKeyData& key)
{
    key.setBinaryValue(ThreadSafeDataBuffer::create(Vector<uint8_t>()));
}

// decodeKey's Array case: a vector with the declared capacity reserved before any element is read (a count too
// large to allocate crashes here).
ALWAYS_INLINE IDBKeyDataVector makeIDBKeyDataVector(size_t capacity)
{
    return IDBKeyDataVector(ReserveCapacityTag { }, capacity);
}

// A key the Swift gives up moves into the vector.
ALWAYS_INLINE void appendIDBKeyData(IDBKeyDataVector& vector, IDBKeyData key)
{
    vector.append(WTF::move(key));
}

// MemoryIDBKey's conversion from IDBKeyData: a Binary key's bytes, empty where the buffer has none, and the
// Invalid key, whose variant alternative Swift cannot construct.
ALWAYS_INLINE std::span<const uint8_t> idbKeyBinaryBytes(const IDBKeyData& key LIFETIME_BOUND)
{
    auto* bytes = key.binary().data();
    return bytes ? bytes->span() : std::span<const uint8_t> { };
}

ALWAYS_INLINE IDBKeyData makeInvalidIDBKeyData()
{
    return IDBKeyData { IDBKeyData::Invalid { } };
}

// The memory store (SwiftIDBStore). Errors: the store returns one of these and SwiftIDBBackingStore makes the
// IDBError (makeMemoryIDBStoreError).
enum class MemoryIDBStoreError : uint8_t {
    None,
    Constraint,
    TransactionExists,
    AbortUnknownTransaction,
    CommitUnknownTransaction,
    NoTransactionToDeleteFrom,
    NoObjectStore,
    NoTransactionToPutRecord,
    NoObjectStoreToPutRecord,
    NoTransactionToGetRecord,
    NoTransactionToGetAllRecords,
    NoIndex,
    NoTransactionToGetCount,
    KeyGeneratorOverflow,
    NoTransactionToOpenCursor,
    CannotCreateObjectStoreCursor,
    CannotCreateIndexCursor,
    NoTransactionToIterateCursor,
    NoCursorToIterate,
    DatabaseInfoInvalid,
    ObjectStoreNotInDatabaseInfo,
    NotVersionChange,
    ObjectStoreNotInBackingStore,
    TransactionNotActive,
    TransactionStateInvalid,
    IndexIdentifierExists,
    IndexDoesNotExist,
    MissingIndexMetadata,
    UniquenessViolation,
};

using ThreadSafeDataBufferVector = Vector<ThreadSafeDataBuffer>;

ALWAYS_INLINE ThreadSafeDataBufferVector makeThreadSafeDataBufferVector(size_t capacity)
{
    return ThreadSafeDataBufferVector(ReserveCapacityTag { }, capacity);
}

ALWAYS_INLINE void appendThreadSafeDataBuffer(ThreadSafeDataBufferVector& vector, const ThreadSafeDataBuffer& buffer)
{
    vector.append(buffer);
}

ALWAYS_INLINE bool threadSafeDataBufferHasData(const ThreadSafeDataBuffer& buffer)
{
    return !!buffer.data();
}

// A value's data, copied: Swift imports the LIFETIME_BOUND getter as a pointer.
ALWAYS_INLINE ThreadSafeDataBuffer idbValueData(const IDBValue& value)
{
    return value.data();
}

// The value at index; Vector's operator[] crashes on an index out of range.
ALWAYS_INLINE IDBValue idbValueAt(const ThreadSafeDataBufferVector& values, size_t index)
{
    return IDBValue { values[index] };
}

ALWAYS_INLINE std::span<const IDBKeyData> idbKeyVectorElements(const IDBKeyDataVector& vector LIFETIME_BOUND)
{
    return vector.span();
}

// The infos' `const T&` getters (LIFETIME_BOUND named members), which Swift imports as UnsafePointer: copies instead.
ALWAYS_INLINE String idbObjectStoreInfoName(const IDBObjectStoreInfo& info)
{
    return info.name();
}

ALWAYS_INLINE String idbIndexInfoName(const IDBIndexInfo& info)
{
    return info.name();
}

ALWAYS_INLINE IDBResourceIdentifier idbTransactionInfoIdentifier(const IDBTransactionInfo& info)
{
    return info.identifier();
}

// The same for the server (UniqueIDBDatabase and its owners).
ALWAYS_INLINE std::optional<IDBKeyPath> idbObjectStoreInfoKeyPath(const IDBObjectStoreInfo& info)
{
    return info.keyPath();
}

// The index's info, or nullopt where the object store has no such index (indexMap().find()).
ALWAYS_INLINE std::optional<IDBIndexInfo> idbObjectStoreInfoIndex(const IDBObjectStoreInfo& info, IDBIndexIdentifier indexIdentifier)
{
    auto iterator = info.indexMap().find(indexIdentifier);
    if (iterator == info.indexMap().end())
        return std::nullopt;
    return iterator->value;
}

ALWAYS_INLINE String idbDatabaseInfoName(const IDBDatabaseInfo& info)
{
    return info.name();
}

ALWAYS_INLINE ClientOrigin idbDatabaseIdentifierOrigin(const IDBDatabaseIdentifier& identifier)
{
    return identifier.origin();
}

ALWAYS_INLINE String idbDatabaseIdentifierDatabaseName(const IDBDatabaseIdentifier& identifier)
{
    return identifier.databaseName();
}

ALWAYS_INLINE bool idbTransactionInfoHasOriginalDatabaseInfo(const IDBTransactionInfo& info)
{
    return !!info.originalDatabaseInfo();
}

// A version change transaction's database info from before the change; the caller checks that it has one.
ALWAYS_INLINE IDBDatabaseInfo idbTransactionInfoOriginalDatabaseInfo(const IDBTransactionInfo& info)
{
    return *info.originalDatabaseInfo();
}

// A copy, not a span: the safe overload of a LIFETIME_BOUND span over the (non-copyable) info crashes the
// MoveOnlyChecker (Swift 6.5-dev, SILMoveOnlyWrappedType assertion).
using IDBTransactionObjectStoreNames = Vector<String>;

ALWAYS_INLINE IDBTransactionObjectStoreNames idbTransactionInfoObjectStores(const IDBTransactionInfo& info)
{
    return info.objectStores();
}

ALWAYS_INLINE size_t idbStringVectorSize(const Vector<String>& vector)
{
    return vector.size();
}

// Bounds-checked (Vector::operator[] asserts in range in every build).
ALWAYS_INLINE String idbStringVectorAt(const Vector<String>& vector, size_t index)
{
    return vector[index];
}

ALWAYS_INLINE IDBKeyRangeData idbCursorInfoRange(const IDBCursorInfo& info)
{
    return info.range();
}

ALWAYS_INLINE bool idbResourceIdentifierEqual(const IDBResourceIdentifier& a, const IDBResourceIdentifier& b)
{
    return a == b;
}

// The identifiers' hashes, which their Swift Hashable conformances use: Swift cannot name WTF's Hasher.
ALWAYS_INLINE unsigned idbResourceIdentifierHash(const IDBResourceIdentifier& identifier)
{
    return computeHash(identifier);
}

ALWAYS_INLINE unsigned idbDatabaseIdentifierHash(const IDBDatabaseIdentifier& identifier)
{
    return computeHash(identifier);
}

using IDBDatabaseIdentifierVector = Vector<IDBDatabaseIdentifier>;

// Same keys, adds and removes as the servers' maps of databases, so keys() iterates in their order; the keys function
// takes the map non-const so Swift does not pass a copy, whose table layout can differ. (WTF's HashSet does not
// import as safe; HashMap does.)
using IDBDatabaseIdentifierHashOrder = HashMap<IDBDatabaseIdentifier, bool>;

ALWAYS_INLINE void idbDatabaseIdentifierHashOrderAdd(IDBDatabaseIdentifierHashOrder& order, const IDBDatabaseIdentifier& identifier)
{
    // add, as the server's maps of databases do.
    order.add(identifier, true);
}

ALWAYS_INLINE void idbDatabaseIdentifierHashOrderRemove(IDBDatabaseIdentifierHashOrder& order, const IDBDatabaseIdentifier& identifier)
{
    order.remove(identifier);
}

ALWAYS_INLINE void idbDatabaseIdentifierHashOrderClear(IDBDatabaseIdentifierHashOrder& order)
{
    order.clear();
}

ALWAYS_INLINE IDBDatabaseIdentifierVector idbDatabaseIdentifierHashOrderKeys(IDBDatabaseIdentifierHashOrder& order)
{
    return copyToVector(order.keys());
}

ALWAYS_INLINE size_t idbDatabaseIdentifierVectorSize(const IDBDatabaseIdentifierVector& vector)
{
    return vector.size();
}

// Bounds-checked (Vector::operator[] asserts in range in every build).
ALWAYS_INLINE IDBDatabaseIdentifier idbDatabaseIdentifierVectorAt(const IDBDatabaseIdentifierVector& vector, size_t index)
{
    return vector[index];
}

using IDBResourceIdentifierVector = Vector<IDBResourceIdentifier>;

// As IDBDatabaseIdentifierHashOrder, for a database's in-progress transactions, whose order the aborts follow.
using IDBResourceIdentifierHashOrder = HashMap<IDBResourceIdentifier, bool>;

ALWAYS_INLINE void idbResourceIdentifierHashOrderAdd(IDBResourceIdentifierHashOrder& order, const IDBResourceIdentifier& identifier)
{
    // set, as the database's map of in-progress transactions does.
    order.set(identifier, true);
}

ALWAYS_INLINE void idbResourceIdentifierHashOrderRemove(IDBResourceIdentifierHashOrder& order, const IDBResourceIdentifier& identifier)
{
    order.remove(identifier);
}

ALWAYS_INLINE IDBResourceIdentifierVector idbResourceIdentifierHashOrderKeys(IDBResourceIdentifierHashOrder& order)
{
    return copyToVector(order.keys());
}

ALWAYS_INLINE size_t idbResourceIdentifierVectorSize(const IDBResourceIdentifierVector& vector)
{
    return vector.size();
}

// Bounds-checked (Vector::operator[] asserts in range in every build).
ALWAYS_INLINE IDBResourceIdentifier idbResourceIdentifierVectorAt(const IDBResourceIdentifierVector& vector, size_t index)
{
    return vector[index];
}

ALWAYS_INLINE bool idbStringEqual(const String& a, const String& b)
{
    return a == b;
}

// IDBCursorInfo's source (an object store's or an index's identifier), which is a Variant.
ALWAYS_INLINE uint64_t idbCursorInfoSourceIdentifier(const IDBCursorInfo& info)
{
    return WTF::switchOn(info.sourceIdentifier(), [](auto identifier) {
        return identifier.toUInt64();
    });
}

// An object store's index keys for a put, in the map's own order (the checks stop at the first failing index).
struct IDBIndexKeyMapEntry {
    IDBIndexIdentifier identifier;
    IndexKey key;
};
using IDBIndexKeyMapEntries = Vector<IDBIndexKeyMapEntry>;

ALWAYS_INLINE IDBIndexKeyMapEntries idbIndexKeyMapEntries(const IndexIDToIndexKeyMap& map)
{
    return WTF::map(map, [](auto& entry) {
        return IDBIndexKeyMapEntry { entry.key, entry.value };
    });
}

ALWAYS_INLINE std::span<const IDBIndexKeyMapEntry> idbIndexKeyMapEntryElements(const IDBIndexKeyMapEntries& entries LIFETIME_BOUND)
{
    return entries.span();
}

ALWAYS_INLINE IDBDatabaseInfo makeMemoryIDBDatabaseInfo(const String& name)
{
    return IDBDatabaseInfo(name, 0, 0);
}

// IDBDatabaseInfo and IDBObjectStoreInfo members that return pointers into the info. The info is taken by
// non-const reference so that Swift passes its stored property in place (a modify access): a
// const reference to a class's stored C++ value makes Swift copy it first, and the info holds every store's info.
ALWAYS_INLINE bool idbDatabaseInfoHasObjectStore(IDBDatabaseInfo& info, IDBObjectStoreIdentifier identifier)
{
    return !!info.infoForExistingObjectStore(identifier);
}

ALWAYS_INLINE bool idbDatabaseInfoHasIndex(IDBDatabaseInfo& info, IDBObjectStoreIdentifier objectStoreIdentifier, IDBIndexIdentifier indexIdentifier)
{
    auto* objectStoreInfo = info.infoForExistingObjectStore(objectStoreIdentifier);
    return objectStoreInfo && objectStoreInfo->hasIndex(indexIdentifier);
}

// An object store the info does not have is a crash, never a null dereference.
ALWAYS_INLINE IDBObjectStoreInfo& idbExistingObjectStoreInfo(IDBDatabaseInfo& info, IDBObjectStoreIdentifier identifier)
{
    auto* objectStoreInfo = info.infoForExistingObjectStore(identifier);
    RELEASE_ASSERT(objectStoreInfo);
    return *objectStoreInfo;
}

ALWAYS_INLINE IDBObjectStoreInfo idbDatabaseInfoObjectStore(IDBDatabaseInfo& info, IDBObjectStoreIdentifier identifier)
{
    return idbExistingObjectStoreInfo(info, identifier);
}

ALWAYS_INLINE bool idbDatabaseInfoHasObjectStoreNamed(IDBDatabaseInfo& info, const String& name)
{
    return info.hasObjectStore(name);
}

ALWAYS_INLINE void idbDatabaseInfoAddIndex(IDBDatabaseInfo& info, const IDBIndexInfo& indexInfo)
{
    if (auto* objectStoreInfo = info.infoForExistingObjectStore(indexInfo.objectStoreIdentifier()))
        objectStoreInfo->addExistingIndex(indexInfo);
}

ALWAYS_INLINE void idbDatabaseInfoDeleteIndex(IDBDatabaseInfo& info, IDBObjectStoreIdentifier objectStoreIdentifier, IDBIndexIdentifier indexIdentifier)
{
    if (auto* objectStoreInfo = info.infoForExistingObjectStore(objectStoreIdentifier))
        objectStoreInfo->deleteIndex(indexIdentifier);
}

ALWAYS_INLINE void idbDatabaseInfoRenameIndex(IDBDatabaseInfo& info, IDBObjectStoreIdentifier objectStoreIdentifier, IDBIndexIdentifier indexIdentifier, const String& newName)
{
    if (auto* objectStoreInfo = info.infoForExistingObjectStore(objectStoreIdentifier)) {
        if (auto* indexInfo = objectStoreInfo->infoForExistingIndex(indexIdentifier))
            indexInfo->rename(newName);
    }
}

ALWAYS_INLINE void idbObjectStoreInfoRenameIndex(IDBObjectStoreInfo& info, IDBIndexIdentifier indexIdentifier, const String& newName)
{
    if (auto* indexInfo = info.infoForExistingIndex(indexIdentifier))
        indexInfo->rename(newName);
}

// Results, built with the object store info's key path.
ALWAYS_INLINE IDBGetResult makeEmptyIDBGetResult()
{
    return IDBGetResult();
}

ALWAYS_INLINE IDBGetResult makeIDBGetResultKey(const IDBKeyData& key)
{
    return IDBGetResult(key);
}

// The object store info by non-const reference, as the database info above: Swift passes it in place, not a copy.
ALWAYS_INLINE IDBGetResult makeIDBGetResultKeyValue(const IDBKeyData& key, const ThreadSafeDataBuffer& value, IDBObjectStoreInfo& info)
{
    return IDBGetResult(key, value, info.keyPath());
}

ALWAYS_INLINE IDBGetResult makeIDBCursorResultKeys(const IDBKeyData& key, const IDBKeyData& primaryKey)
{
    return IDBGetResult(key, primaryKey);
}

ALWAYS_INLINE IDBGetResult makeIDBCursorResultValue(const IDBKeyData& key, const IDBKeyData& primaryKey, const ThreadSafeDataBuffer& value, IDBObjectStoreInfo& info)
{
    return IDBGetResult(key, primaryKey, IDBValue(value, { }, { }), info.keyPath());
}

ALWAYS_INLINE IDBGetAllResult makeIDBGetAllResult(IndexedDB::GetAllType type, IDBObjectStoreInfo& info)
{
    return IDBGetAllResult(type, info.keyPath());
}

ALWAYS_INLINE void idbGetAllResultAddKey(IDBGetAllResult& result, const IDBKeyData& key)
{
    result.addKey(IDBKeyData(key));
}

ALWAYS_INLINE void idbGetAllResultAddValue(IDBGetAllResult& result, const ThreadSafeDataBuffer& value)
{
    result.addValue(IDBValue(value));
}

// The server's lists of databases and origins (IDBServer, IDBStorageManager, IDBConnectionToClientDelegate), built and
// read through these: Vector's and HashSet's members are templates.
using IDBDatabaseNameAndVersionVector = Vector<IDBDatabaseNameAndVersion>;
using SecurityOriginDataVector = Vector<SecurityOriginData>;
using ClientOriginVector = Vector<ClientOrigin>;

ALWAYS_INLINE IDBDatabaseNameAndVersionVector makeIDBDatabaseNameAndVersionVector(size_t capacity)
{
    return IDBDatabaseNameAndVersionVector(ReserveCapacityTag { }, capacity);
}

ALWAYS_INLINE void appendIDBDatabaseNameAndVersion(IDBDatabaseNameAndVersionVector& vector, IDBDatabaseNameAndVersion nameAndVersion)
{
    vector.append(WTF::move(nameAndVersion));
}

ALWAYS_INLINE std::span<const IDBDatabaseNameAndVersion> idbDatabaseNameAndVersionElements(const IDBDatabaseNameAndVersionVector& vector LIFETIME_BOUND)
{
    return vector.span();
}

ALWAYS_INLINE void appendSecurityOriginData(SecurityOriginDataVector& vector, const SecurityOriginData& origin)
{
    vector.append(origin);
}

ALWAYS_INLINE void appendClientOrigin(ClientOriginVector& vector, const ClientOrigin& origin)
{
    vector.append(origin);
}

ALWAYS_INLINE std::span<const ClientOrigin> clientOriginElements(const ClientOriginVector& vector LIFETIME_BOUND)
{
    return vector.span();
}

// IDBDatabaseIdentifier's directories by version, "v0" when `isOldVersion` and "v1" otherwise: the version is an
// ASCIILiteral, which does not import.
ALWAYS_INLINE ASCIILiteral idbVersionDirectoryLiteral(bool isOldVersion)
{
    return isOldVersion ? "v0"_s : "v1"_s;
}

ALWAYS_INLINE String idbOriginDirectoryRelativeToRoot(const ClientOrigin& origin, const String& rootDirectory, bool isOldVersion)
{
    return IDBDatabaseIdentifier::databaseDirectoryRelativeToRoot(origin, rootDirectory, idbVersionDirectoryLiteral(isOldVersion));
}

ALWAYS_INLINE String idbOptionalOriginDirectoryRelativeToRoot(const ClientOrigin& origin, const String& rootDirectory, bool isOldVersion)
{
    return IDBDatabaseIdentifier::optionalDatabaseDirectoryRelativeToRoot(origin, rootDirectory, idbVersionDirectoryLiteral(isOldVersion));
}

ALWAYS_INLINE String idbDatabaseDirectoryRelativeToRoot(const IDBDatabaseIdentifier& identifier, const String& rootDirectory, bool isOldVersion)
{
    return identifier.databaseDirectoryRelativeToRoot(rootDirectory, idbVersionDirectoryLiteral(isOldVersion));
}

// std::optional arguments of the delegate's generateIndexKeyForRecord, built from Swift's.
using IDBOptionalKeyPath = std::optional<IDBKeyPath>;
using IDBOptionalInt64 = std::optional<int64_t>;

ALWAYS_INLINE IDBOptionalKeyPath idbOptionalKeyPath(const IDBKeyPath& keyPath)
{
    return keyPath;
}

ALWAYS_INLINE IDBOptionalKeyPath idbNoKeyPath()
{
    return std::nullopt;
}

ALWAYS_INLINE IDBOptionalInt64 idbOptionalInt64(int64_t value)
{
    return value;
}

ALWAYS_INLINE IDBOptionalInt64 idbNoInt64()
{
    return std::nullopt;
}

ALWAYS_INLINE String idbOldVersionDirectoryName()
{
    return idbVersionDirectoryLiteral(true);
}

ALWAYS_INLINE String idbCurrentVersionDirectoryName()
{
    return idbVersionDirectoryLiteral(false);
}

ALWAYS_INLINE ClientOrigin idbMakeClientOrigin(const SecurityOriginData& topOrigin, const SecurityOriginData& clientOrigin)
{
    return { topOrigin, clientOrigin };
}

// The file operations of IDBServer's and IDBStorageManager's directory walks, one call each.
using IDBOptionalSecurityOriginData = std::optional<SecurityOriginData>;

ALWAYS_INLINE size_t idbStringLength(const String& string)
{
    return string.length();
}

ALWAYS_INLINE bool idbStringEndsWithBlobSuffix(const String& string)
{
    return string.endsWith(".blob"_s);
}

ALWAYS_INLINE bool idbStringHasASCIIDigitAt(const String& string, size_t index)
{
    return isASCIIDigit(string[index]);
}

ALWAYS_INLINE IDBOptionalSecurityOriginData idbSecurityOriginFromDatabaseIdentifier(const String& identifier)
{
    return SecurityOriginData::fromDatabaseIdentifier(identifier);
}

ALWAYS_INLINE bool idbMakeAllDirectories(const String& path)
{
    return FileSystem::makeAllDirectories(path);
}

ALWAYS_INLINE bool idbMoveFile(const String& from, const String& to)
{
    return FileSystem::moveFile(from, to);
}

ALWAYS_INLINE bool idbDeleteEmptyDirectory(const String& path)
{
    return FileSystem::deleteEmptyDirectory(path);
}

ALWAYS_INLINE bool idbDeleteNonEmptyDirectory(const String& path)
{
    return FileSystem::deleteNonEmptyDirectory(path);
}

ALWAYS_INLINE bool idbDeleteFile(const String& path)
{
    return FileSystem::deleteFile(path);
}

ALWAYS_INLINE std::optional<FileSystem::FileType> idbFileType(const String& path)
{
    return FileSystem::fileType(path);
}

ALWAYS_INLINE String idbLastComponentOfPathIgnoringTrailingSlash(const String& path)
{
    return FileSystem::lastComponentOfPathIgnoringTrailingSlash(path);
}

// True when the file has no modification time or was last modified before `since`.
ALWAYS_INLINE bool idbFileIsUnmodifiedSince(const String& path, WallTime since)
{
    auto modificationTime = FileSystem::fileModificationTime(path);
    return !modificationTime || modificationTime.value() < since;
}

ALWAYS_INLINE void idbDeleteSQLiteDatabaseFile(const String& path)
{
    SQLiteFileSystem::deleteDatabaseFile(path);
}

ALWAYS_INLINE String idbComputeHashForFileName(const String& name)
{
    return SQLiteFileSystem::computeHashForFileName(name);
}

ALWAYS_INLINE bool idbWallTimeIsInFuture(WallTime time)
{
    return time > WallTime::now();
}

ALWAYS_INLINE bool idbWallTimeIsAboveNegativeInfinity(WallTime time)
{
    return time > -WallTime::infinity();
}

// The in-process server's quota callable (IDBServer::SpaceRequester), which SwiftIDBServer holds: a Function does not
// import, so the C++ owner hands it over in this copyable holder.
class IDBSpaceRequesterHolder {
public:
    using Requester = Function<bool(const ClientOrigin&, uint64_t)>;

    explicit IDBSpaceRequesterHolder(Requester&& requester)
        : m_requester(std::make_shared<Requester>(WTF::move(requester)))
    {
    }

    bool request(const ClientOrigin& origin, uint64_t size) const { return (*m_requester)(origin, size); }

private:
    std::shared_ptr<Requester> m_requester;
};

// For UniqueIDBDatabase's operations: an error with its code, the info's members found by name, a key path's
// strings, and the index keys' placeholders, which Swift cannot reach in the HashMap.
ALWAYS_INLINE IDBError makeIDBServerNoError()
{
    return IDBError { };
}

ALWAYS_INLINE IDBError makeIDBServerError(ExceptionCode code, const String& message)
{
    return IDBError { code, message };
}

ALWAYS_INLINE std::optional<IDBObjectStoreIdentifier> idbDatabaseInfoObjectStoreIdentifierNamed(IDBDatabaseInfo& info, const String& name)
{
    if (auto* objectStoreInfo = info.infoForExistingObjectStore(name))
        return objectStoreInfo->identifier();
    return std::nullopt;
}

ALWAYS_INLINE std::optional<IDBIndexIdentifier> idbDatabaseInfoIndexIdentifierNamed(IDBDatabaseInfo& info, IDBObjectStoreIdentifier objectStoreIdentifier, const String& name)
{
    auto* objectStoreInfo = info.infoForExistingObjectStore(objectStoreIdentifier);
    if (!objectStoreInfo)
        return std::nullopt;
    if (auto* indexInfo = objectStoreInfo->infoForExistingIndex(name))
        return indexInfo->identifier();
    return std::nullopt;
}

// The key path's one string, or its strings.
ALWAYS_INLINE Vector<String> idbKeyPathStrings(const IDBKeyPath& keyPath)
{
    return WTF::switchOn(keyPath, [](const String& path) {
        return Vector<String> { path };
    }, [](const Vector<String>& paths) {
        return paths;
    });
}

ALWAYS_INLINE void idbIndexKeyMapUpdatePlaceholderKeys(IndexIDToIndexKeyMap& map, const IDBKeyData& key)
{
    for (auto& indexKey : map.values())
        indexKey.updatePlaceholderKeys(key);
}

} // namespace WebCore
