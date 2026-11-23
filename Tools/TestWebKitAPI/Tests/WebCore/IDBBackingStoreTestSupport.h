/*
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

#include <WebCore/IDBConnectionToClientDelegate.h>
#include <WebCore/IDBDatabaseNameAndVersion.h>
#include <WebCore/IDBError.h>
#include <WebCore/IDBIndexInfo.h>
#include <WebCore/IDBKeyData.h>
#include <WebCore/IDBKeyPath.h>
#include <WebCore/IDBResourceIdentifier.h>
#include <WebCore/IDBResultData.h>
#include <WebCore/IDBValue.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/SQLiteDatabase.h>
#include <atomic>
#include <wtf/Threading.h>

// What the backing store tests and benchmarks share: a connection delegate that ignores every call, number keys, and
// a way to run a store off the main thread.

namespace TestWebKitAPI {

class NullDelegate final : public WebCore::IDBServer::IDBConnectionToClientDelegate {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(NullDelegate);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(NullDelegate);

public:
    std::optional<WebCore::IDBConnectionIdentifier> identifier() const final { return m_identifier; }
    void didDeleteDatabase(const WebCore::IDBResultData&) final { }
    void didOpenDatabase(const WebCore::IDBResultData&) final { }
    void didAbortTransaction(const WebCore::IDBResourceIdentifier&, const WebCore::IDBError&) final { }
    void didCommitTransaction(const WebCore::IDBResourceIdentifier&, const WebCore::IDBError&) final { }
    void didCreateObjectStore(const WebCore::IDBResultData&) final { }
    void didDeleteObjectStore(const WebCore::IDBResultData&) final { }
    void didRenameObjectStore(const WebCore::IDBResultData&) final { }
    void didClearObjectStore(const WebCore::IDBResultData&) final { }
    void didCreateIndex(const WebCore::IDBResultData&) final { }
    void didDeleteIndex(const WebCore::IDBResultData&) final { }
    void didRenameIndex(const WebCore::IDBResultData&) final { }
    void didPutOrAdd(const WebCore::IDBResultData&) final { }
    void didGetRecord(const WebCore::IDBResultData&) final { }
    void didGetAllRecords(const WebCore::IDBResultData&) final { }
    void didGetCount(const WebCore::IDBResultData&) final { }
    void didDeleteRecord(const WebCore::IDBResultData&) final { }
    void didOpenCursor(const WebCore::IDBResultData&) final { }
    void didIterateCursor(const WebCore::IDBResultData&) final { }
    void fireVersionChangeEvent(WebCore::IDBServer::UniqueIDBDatabaseConnection&, const WebCore::IDBResourceIdentifier&, uint64_t) final { }
    void generateIndexKeyForRecord(const WebCore::IDBResourceIdentifier&, const WebCore::IDBIndexInfo&, const std::optional<WebCore::IDBKeyPath>&, const WebCore::IDBKeyData&, const WebCore::IDBValue&, std::optional<int64_t>) final { }
    void didStartTransaction(const WebCore::IDBResourceIdentifier&, const WebCore::IDBError&) final { }
    void didCloseFromServer(WebCore::IDBServer::UniqueIDBDatabaseConnection&, const WebCore::IDBError&) final { }
    void notifyOpenDBRequestBlocked(const WebCore::IDBResourceIdentifier&, uint64_t, uint64_t) final { }
    void didGetAllDatabaseNamesAndVersions(const WebCore::IDBResourceIdentifier&, Vector<WebCore::IDBDatabaseNameAndVersion>&&) final { }

private:
    // Process::generateIdentifier() asserts it runs on the UI thread in Debug; the store thread has its own counter.
    static WebCore::IDBConnectionIdentifier nextIdentifier()
    {
        static std::atomic<uint64_t> next { 1 };
        return WebCore::IDBConnectionIdentifier(next.fetch_add(1));
    }
    WebCore::IDBConnectionIdentifier m_identifier { nextIdentifier() };
};

inline WebCore::IDBKeyData numberKey(double number)
{
    return WebCore::IDBKeyData { WebCore::IDBKeyData::ValueVariant { number } };
}

// Stores run off the main thread: IDBBackingStore's constructor and destructor RELEASE_ASSERT(!isMainThread()).
template<typename Function>
void runOffMainThread(Function&& function)
{
    // SQLite's one-time initialization runs on the main thread and the main thread waits for it (callOnMainThreadAndWait),
    // which a store thread opening the first database would deadlock against while this thread waits for it. Do it
    // here, on the main thread.
    static bool sqliteInitialized = [] {
        // On the heap: a CheckedPtr-capable object destroyed on the stack asserts in Debug (m_didBeginDeletion).
        auto database = makeUnique<WebCore::SQLiteDatabase>();
        database->open(":memory:"_s);
        return true;
    }();
    UNUSED_VARIABLE(sqliteInitialized);
    Thread::create("IDBBackingStore"_s, [&function] {
        function();
    })->waitForCompletion();
}

} // namespace TestWebKitAPI
