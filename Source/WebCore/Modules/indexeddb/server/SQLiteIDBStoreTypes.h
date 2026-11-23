/*
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

#pragma once

#include <WebCore/IDBCursorRecord.h>
#include <WebCore/IDBDatabaseInfo.h>
#include <WebCore/IDBDatabaseNameAndVersion.h>
#include <WebCore/IDBError.h>
#include <WebCore/IDBGetAllResult.h>
#include <WebCore/IDBGetResult.h>
#include <WebCore/IDBIndexInfo.h>
#include <WebCore/IDBObjectStoreInfo.h>
#include <WebCore/IDBSerialization.h>
#include <WebCore/IDBValue.h>
#include <WebCore/SQLiteDatabase.h>
#include <WebCore/SQLiteFileSystem.h>
#include <WebCore/SQLiteStatement.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/SwiftIDBTypes.h>
#include <span>
#include <wtf/FileSystem.h>
#include <wtf/HashSet.h>
#include <wtf/UUID.h>
#include <wtf/Vector.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringToIntegerConversion.h>
#include <wtf/text/WTFString.h>

// What the SQLite IndexedDB store's Swift (SQLiteIDBStore*.swift) needs from C++ that it cannot spell itself: IDBError
// and IDBDatabaseInfo construction, makeString, parseInteger, the key path codec (IDBSerialization.cpp, still C++),
// and the file system calls. ALWAYS_INLINE for the same reason as SwiftIDBTypes.h.

namespace WebCore {

ALWAYS_INLINE IDBDatabaseNameAndVersion makeSQLiteIDBNameAndVersion(const String& name, uint64_t version)
{
    return { name, version };
}

ALWAYS_INLINE IDBError makeSQLiteIDBNoError()
{
    return IDBError { };
}

ALWAYS_INLINE IDBError makeSQLiteIDBUnknownError(const String& message)
{
    return IDBError { ExceptionCode::UnknownError, message };
}

ALWAYS_INLINE IDBError makeSQLiteIDBConstraintError(const String& message)
{
    return IDBError { ExceptionCode::ConstraintError, message };
}

ALWAYS_INLINE IDBError makeSQLiteIDBDatabaseError(const String& prefix, SQLiteDatabase& database)
{
    return IDBError { ExceptionCode::UnknownError, makeString(prefix, " ("_s, database.lastError(), ") - "_s, database.lastErrorMessage()) };
}

ALWAYS_INLINE IDBError makeSQLiteIDBValueError(const String& prefix, const String& value, const String& suffix)
{
    return IDBError { ExceptionCode::UnknownError, makeString(prefix, value, suffix) };
}

ALWAYS_INLINE IDBObjectStoreIdentifier makeSQLiteIDBObjectStoreIdentifier(uint64_t value)
{
    return IDBObjectStoreIdentifier { value };
}

ALWAYS_INLINE IDBIndexIdentifier makeSQLiteIDBIndexIdentifier(uint64_t value)
{
    return IDBIndexIdentifier { value };
}

ALWAYS_INLINE bool sqliteIDBParseUInt64(const String& string, uint64_t& result)
{
    auto parsed = parseInteger<uint64_t>(string);
    if (!parsed)
        return false;
    result = *parsed;
    return true;
}

ALWAYS_INLINE String sqliteIDBStringFromUInt64(uint64_t value)
{
    return String::number(value);
}

ALWAYS_INLINE bool sqliteIDBStringsEqualAsUTF8(const String& a, const String& b)
{
    return a.utf8() == b.utf8();
}

ALWAYS_INLINE IDBDatabaseInfo makeSQLiteIDBDatabaseInfo(const String& name, uint64_t version, uint64_t maxIndexID)
{
    return IDBDatabaseInfo { name, version, maxIndexID };
}

// A serialized key path's bytes: false when serializeIDBKeyPath fails (it returns null).
ALWAYS_INLINE bool sqliteIDBSerializeObjectStoreKeyPath(const IDBObjectStoreInfo& info, Vector<uint8_t>& result)
{
    auto buffer = serializeIDBKeyPath(info.keyPath());
    if (!buffer)
        return false;
    result = Vector<uint8_t> { buffer->span() };
    return true;
}

ALWAYS_INLINE bool sqliteIDBSerializeIndexKeyPath(const IDBIndexInfo& info, Vector<uint8_t>& result)
{
    auto buffer = serializeIDBKeyPath(info.keyPath());
    if (!buffer)
        return false;
    result = Vector<uint8_t> { buffer->span() };
    return true;
}

// bindBlob of a byte vector, empty included (Swift cannot pass C++ an empty Span with a null base).
ALWAYS_INLINE int sqliteIDBBindBytes(SQLiteStatement& statement, int index, const Vector<uint8_t>& bytes)
{
    return statement.bindBlob(index, bytes.span());
}

// extractExistingDatabaseInfo's ObjectStoreInfo row: false when the key path does not deserialize.
ALWAYS_INLINE bool sqliteIDBAddExistingObjectStore(IDBDatabaseInfo& info, IDBObjectStoreIdentifier identifier, const String& name, const Vector<uint8_t>& keyPathBytes, bool autoIncrement)
{
    std::optional<IDBKeyPath> keyPath;
    if (!deserializeIDBKeyPath(keyPathBytes.span(), keyPath))
        return false;
    info.addExistingObjectStore({ identifier, name, WTF::move(keyPath), autoIncrement });
    return true;
}

// extractExistingDatabaseInfo's IndexInfo row, first step: whether the key path deserializes to a key path.
ALWAYS_INLINE bool sqliteIDBIndexKeyPathIsValid(const Vector<uint8_t>& keyPathBytes)
{
    std::optional<IDBKeyPath> keyPath;
    return deserializeIDBKeyPath(keyPathBytes.span(), keyPath) && keyPath;
}

// Adds the row once sqliteIDBIndexKeyPathIsValid and the object store check have passed.
ALWAYS_INLINE void sqliteIDBAddExistingIndex(IDBDatabaseInfo& info, IDBIndexIdentifier indexID, IDBObjectStoreIdentifier objectStoreID, const String& name, const Vector<uint8_t>& keyPathBytes, bool unique, bool multiEntry)
{
    std::optional<IDBKeyPath> keyPath;
    deserializeIDBKeyPath(keyPathBytes.span(), keyPath);
    RELEASE_ASSERT(keyPath);
    idbExistingObjectStoreInfo(info, objectStoreID).addExistingIndex(IDBIndexInfo { indexID, objectStoreID, name, WTF::move(*keyPath), unique, multiEntry });
}

ALWAYS_INLINE void sqliteIDBDatabaseInfoAddIndex(IDBDatabaseInfo& info, const IDBIndexInfo& indexInfo)
{
    idbExistingObjectStoreInfo(info, indexInfo.objectStoreIdentifier()).addExistingIndex(indexInfo);
}

// A missing object store traps.
ALWAYS_INLINE void sqliteIDBDatabaseInfoDeleteIndex(IDBDatabaseInfo& info, IDBObjectStoreIdentifier objectStoreID, IDBIndexIdentifier indexID)
{
    idbExistingObjectStoreInfo(info, objectStoreID).deleteIndex(indexID);
}

ALWAYS_INLINE void sqliteIDBDatabaseInfoRenameIndex(IDBDatabaseInfo& info, IDBObjectStoreIdentifier objectStoreID, IDBIndexIdentifier indexID, const String& newName)
{
    auto* indexInfo = idbExistingObjectStoreInfo(info, objectStoreID).infoForExistingIndex(indexID);
    RELEASE_ASSERT(indexInfo);
    indexInfo->rename(newName);
}

ALWAYS_INLINE String sqliteIDBFullDatabasePath(const String& directory)
{
    return FileSystem::pathByAppendingComponent(directory, "IndexedDB.sqlite3"_s);
}

ALWAYS_INLINE void sqliteIDBMakeParentDirectories(const String& path)
{
    FileSystem::makeAllDirectories(FileSystem::parentPath(path));
}

ALWAYS_INLINE bool sqliteIDBFileExists(const String& path)
{
    return FileSystem::fileExists(path);
}

ALWAYS_INLINE String sqliteIDBPathByAppendingComponent(const String& directory, const String& component)
{
    return FileSystem::pathByAppendingComponent(directory, component);
}

ALWAYS_INLINE void sqliteIDBDeleteFile(const String& path)
{
    FileSystem::deleteFile(path);
}

// deleteBackingStore's last two steps.
ALWAYS_INLINE void sqliteIDBDeleteDatabaseFileAndEmptyDirectory(const String& databasePath, const String& directory)
{
    SQLiteFileSystem::deleteDatabaseFile(databasePath);
    SQLiteFileSystem::deleteEmptyDatabaseDirectory(directory);
}

ALWAYS_INLINE IDBError makeSQLiteIDBInvalidStateError(const String& message)
{
    return IDBError { ExceptionCode::InvalidStateError, message };
}

ALWAYS_INLINE bool sqliteIDBObjectStoreHasIndex(IDBObjectStoreInfo& info, IDBIndexIdentifier identifier)
{
    return !!info.infoForExistingIndex(identifier);
}

ALWAYS_INLINE IDBIndexInfo sqliteIDBObjectStoreIndex(IDBObjectStoreInfo& info, IDBIndexIdentifier identifier)
{
    auto* indexInfo = info.infoForExistingIndex(identifier);
    RELEASE_ASSERT(indexInfo);
    return *indexInfo;
}

ALWAYS_INLINE bool sqliteIDBColumnKey(SQLiteStatement& statement, int column, IDBKeyData& result)
{
    return deserializeIDBKeyData(statement.columnBlobAsSpan(column), result);
}

ALWAYS_INLINE ThreadSafeDataBuffer sqliteIDBColumnBuffer(SQLiteStatement& statement, int column)
{
    return ThreadSafeDataBuffer::create(statement.columnBlob(column));
}

ALWAYS_INLINE ThreadSafeDataBuffer sqliteIDBMakeBuffer(const Vector<uint8_t>& bytes)
{
    return ThreadSafeDataBuffer::create(Vector<uint8_t> { bytes });
}

ALWAYS_INLINE bool sqliteIDBDeserializeKeyBytes(const Vector<uint8_t>& bytes, IDBKeyData& result)
{
    return deserializeIDBKeyData(bytes.span(), result);
}

// addRecord's value column. A value decoded from IPC can have no data: that is a crash, never a null dereference.
ALWAYS_INLINE int sqliteIDBBindValueData(SQLiteStatement& statement, int index, const IDBValue& value)
{
    auto* data = value.data().data();
    RELEASE_ASSERT(data);
    return statement.bindBlob(index, *data);
}

using SQLiteIDBStringVector = Vector<String>;

ALWAYS_INLINE void sqliteIDBAppendString(SQLiteIDBStringVector& vector, const String& string)
{
    vector.append(string);
}

ALWAYS_INLINE Vector<String> sqliteIDBValueBlobURLs(const IDBValue& value)
{
    return value.blobURLs();
}

ALWAYS_INLINE Vector<String> sqliteIDBValueBlobFilePaths(const IDBValue& value)
{
    return value.blobFilePaths();
}

ALWAYS_INLINE size_t sqliteIDBValueFileSystemHandleRecordCount(const IDBValue& value)
{
    return value.fileSystemHandleRecords().size();
}

// The FileSystemHandleRecords row of a value's record at index: binds objectStoreRow, globalIdentifier, kind, path, name.
ALWAYS_INLINE bool sqliteIDBBindFileSystemHandleRecord(SQLiteStatement& statement, int64_t recordID, const IDBValue& value, size_t index)
{
    auto& record = value.fileSystemHandleRecords()[index];
    auto rawIdentifier = record.identifier;
    return statement.bindInt64(1, recordID) == SQLITE_OK
        && statement.bindBlob(2, rawIdentifier.span()) == SQLITE_OK
        && statement.bindInt(3, static_cast<int>(record.kind)) == SQLITE_OK
        && statement.bindText(4, record.path) == SQLITE_OK
        && statement.bindText(5, record.name) == SQLITE_OK;
}

using SQLiteIDBFileSystemHandleRecords = Vector<FileSystemHandleRecord>;

// A FileSystemHandleRecords row: false (the row is corrupt) when the identifier blob is not a UUID or the kind is
// neither File nor Directory.
ALWAYS_INLINE bool sqliteIDBAppendFileSystemHandleRecord(SQLiteIDBFileSystemHandleRecords& records, const Vector<uint8_t>& identifier, int kind, const String& path, const String& name)
{
    auto uuid = WTF::UUID::tryCreate(identifier.span());
    if (!uuid)
        return false;
    if (kind != static_cast<int>(FileSystemHandleKind::File) && kind != static_cast<int>(FileSystemHandleKind::Directory))
        return false;
    records.append(FileSystemHandleRecord { FileSystemHandleGlobalIdentifier { *uuid }, static_cast<FileSystemHandleKind>(kind), path, name });
    return true;
}

ALWAYS_INLINE IDBValue makeSQLiteIDBValue(const ThreadSafeDataBuffer& data, const Vector<String>& blobURLs, const Vector<String>& blobFilePaths, const SQLiteIDBFileSystemHandleRecords& records)
{
    auto identifiers = records.map([](auto& record) {
        return record.identifier;
    });
    IDBValue value { data, Vector<String> { blobURLs }, Vector<String> { blobFilePaths }, WTF::move(identifiers) };
    value.setFileSystemHandleRecords(SQLiteIDBFileSystemHandleRecords { records });
    return value;
}

// A record's blob URLs, distinct, in HashSet<String> order.
ALWAYS_INLINE Vector<String> sqliteIDBDistinctStringsInHashOrder(const Vector<String>& strings)
{
    HashSet<String> set;
    for (auto& string : strings)
        set.add(string);
    return copyToVector(set);
}

ALWAYS_INLINE String sqliteIDBBlobFilename(int64_t value)
{
    return makeString(value, ".blob"_s);
}

ALWAYS_INLINE bool sqliteIDBHardLinkOrCopyFile(const String& source, const String& destination)
{
    return FileSystem::hardLinkOrCopyFile(source, destination);
}

ALWAYS_INLINE IDBKeyRangeData makeSQLiteIDBKeyRange(const IDBKeyData& key)
{
    return IDBKeyRangeData { key };
}

ALWAYS_INLINE IDBGetResult makeSQLiteIDBGetResultRecord(const IDBKeyData& key, const IDBValue& value, IDBDatabaseInfo& databaseInfo, IDBObjectStoreIdentifier objectStoreIdentifier)
{
    return IDBGetResult { key, IDBValue { value }, idbExistingObjectStoreInfo(databaseInfo, objectStoreIdentifier).keyPath() };
}

ALWAYS_INLINE IDBGetResult makeSQLiteIDBGetResultValue(const IDBKeyData& key, const IDBKeyData& primaryKey, const IDBValue& value, IDBDatabaseInfo& databaseInfo, IDBObjectStoreIdentifier objectStoreIdentifier)
{
    return IDBGetResult { key, primaryKey, IDBValue { value }, idbExistingObjectStoreInfo(databaseInfo, objectStoreIdentifier).keyPath() };
}

using SQLiteIDBCursorRecords = Vector<IDBCursorRecord>;

ALWAYS_INLINE SQLiteIDBCursorRecords makeSQLiteIDBCursorRecords(size_t capacity)
{
    return SQLiteIDBCursorRecords(ReserveCapacityTag { }, capacity);
}

// The cursor's fetched records are read in place: each helper takes the record (or key) by non-const reference, which Swift
// passes as an inout access to the array element. A const reference to a value stored in a Swift array or class is a copy.
ALWAYS_INLINE bool sqliteIDBKeyDataEqualInPlace(IDBKeyData& a, IDBKeyData& b)
{
    return a == b;
}

ALWAYS_INLINE int sqliteIDBKeyDataCompareInPlace(IDBKeyData& a, IDBKeyData& b)
{
    return a.compare(b);
}

ALWAYS_INLINE void sqliteIDBAppendCursorRecordInPlace(SQLiteIDBCursorRecords& records, IDBCursorRecord& record)
{
    records.append(record);
}

ALWAYS_INLINE IDBGetResult makeSQLiteIDBGetResultFromCursorRecord(IDBCursorRecord& record, IDBDatabaseInfo& databaseInfo, IDBObjectStoreIdentifier objectStoreIdentifier, SQLiteIDBCursorRecords& prefetchedRecords)
{
    prefetchedRecords.shrinkToFit();
    return IDBGetResult { record.key, record.primaryKey, IDBValue { record.value }, idbExistingObjectStoreInfo(databaseInfo, objectStoreIdentifier).keyPath(), WTF::move(prefetchedRecords) };
}

ALWAYS_INLINE IDBGetAllResult makeSQLiteIDBGetAllResult(IndexedDB::GetAllType type, IDBDatabaseInfo& databaseInfo, IDBObjectStoreIdentifier objectStoreIdentifier)
{
    return IDBGetAllResult { type, idbExistingObjectStoreInfo(databaseInfo, objectStoreIdentifier).keyPath() };
}

// getAll's results take their keys and values (moved): the caller copies what it still needs.
ALWAYS_INLINE void sqliteIDBGetAllResultTakeKey(IDBGetAllResult& result, IDBKeyData& key)
{
    result.addKey(WTF::move(key));
}

ALWAYS_INLINE void sqliteIDBGetAllResultTakePrimaryKey(IDBGetAllResult& result, IDBKeyData& key)
{
    result.addPrimaryKey(WTF::move(key));
}

ALWAYS_INLINE void sqliteIDBGetAllResultTakeValue(IDBGetAllResult& result, IDBValue& value)
{
    result.addValue(WTF::move(value));
}

// encodeDatabaseName, decodeDatabaseName and databasesSizeForDirectory.
ALWAYS_INLINE String sqliteIDBEncodeForFileName(const String& name)
{
    return FileSystem::encodeForFileName(name);
}

ALWAYS_INLINE String sqliteIDBDecodeFromFilename(const String& name)
{
    return FileSystem::decodeFromFilename(name);
}

ALWAYS_INLINE String sqliteIDBReplacingAll(const String& string, const String& target, const String& replacement)
{
    return makeStringByReplacingAll(string, target, replacement);
}

ALWAYS_INLINE String sqliteIDBEmptyString()
{
    return emptyString();
}

ALWAYS_INLINE Vector<String> sqliteIDBListDirectory(const String& path)
{
    return FileSystem::listDirectory(path);
}

ALWAYS_INLINE bool sqliteIDBIsDatabaseFileName(const String& fileName)
{
    return fileName.endsWith(".sqlite3"_s);
}

ALWAYS_INLINE uint64_t sqliteIDBDatabaseFileSize(const String& path)
{
    return SQLiteFileSystem::databaseFileSize(path);
}

// Defined in SwiftIDBBackingStore.cpp.

// Opens ":memory:", logging when it fails.
bool sqliteIDBOpenMemoryDatabase(SQLiteDatabase&);
// Sets up the in-memory database: no WAL, a 512 KB cache and the IDBKEY collation.
void sqliteIDBPrepareOpenedMemoryDatabase(SQLiteDatabase&);

// getOrEstablishDatabaseInfo's RELEASE_LOG_ERROR when the file does not open.
void sqliteIDBLogOpenFailure(const String& databasePath, SQLiteDatabase&);

// The RELEASE_LOGs of a metadata version downgrade, of a missing object store and of missing database info.
void sqliteIDBLogMismatchedMetadataVersion();
void sqliteIDBLogMissingObjectStore(const String& function);
void sqliteIDBLogMissingDatabaseInfo(const String& function);

// Sets up the file database's connection: threading checks off, WAL truncation and the IDBKEY collation, which turns
// SQLite's (pointer, length) pairs into spans.
void sqliteIDBPrepareOpenedDatabase(SQLiteDatabase&);

} // namespace WebCore
