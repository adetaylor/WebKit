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
#include "IDBBackingStoreFactories.h"

#include "IDBBackingStore.h"
#include "MemoryIDBBackingStore.h"
#include "SQLiteIDBBackingStore.h"
#include "SQLiteMemoryIDBBackingStore.h"
#include <wtf/text/WTFString.h>

namespace WebCore {
namespace IDBServer {

std::unique_ptr<IDBBackingStore> makeSQLiteIDBBackingStore(const IDBDatabaseIdentifier& identifier, const String& databaseDirectory)
{
    return makeUnique<SQLiteIDBBackingStore>(identifier, databaseDirectory);
}

std::unique_ptr<IDBBackingStore> makeSQLiteMemoryIDBBackingStore(const IDBDatabaseIdentifier& identifier)
{
    return makeUnique<SQLiteMemoryIDBBackingStore>(identifier);
}

std::unique_ptr<IDBBackingStore> makeMemoryIDBBackingStore(const IDBDatabaseIdentifier& identifier)
{
    return makeUnique<MemoryIDBBackingStore>(identifier);
}

String fullDatabasePathForDirectory(const String& databaseDirectory)
{
    return SQLiteIDBBackingStore::fullDatabasePathForDirectory(databaseDirectory);
}

std::optional<IDBDatabaseNameAndVersion> databaseNameAndVersionFromFile(const String& databasePath)
{
    return SQLiteIDBBackingStore::databaseNameAndVersionFromFile(databasePath);
}

uint64_t databasesSizeForDirectory(const String& directory)
{
    return SQLiteIDBBackingStore::databasesSizeForDirectory(directory);
}

String encodeDatabaseName(const String& databaseName)
{
    return SQLiteIDBBackingStore::encodeDatabaseName(databaseName);
}

String decodeDatabaseName(const String& encodedDatabaseName)
{
    return SQLiteIDBBackingStore::decodeDatabaseName(encodedDatabaseName);
}

} // namespace IDBServer
} // namespace WebCore
