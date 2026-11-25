/*
 * Copyright (C) 2022 Apple Inc. All rights reserved.
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

#include "CacheStorageRecord.h"
#include "CacheStorageStore.h"
#include "NetworkCacheKey.h"
#include <WebCore/RetrieveRecordsOptions.h>
#include <algorithm>
#include <wtf/HashMap.h>
#include <wtf/Identified.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/UniqueRef.h>
#include <wtf/WorkQueue.h>

namespace WebCore {
struct ClientOrigin;
}

namespace WebKit {
class CacheStorageCache;
}

namespace WebKit {

class CacheStorageManager;

// Swift spells a Vector specialization only through an alias: it asks for all five template arguments.
using CacheStorageRecordVector = Vector<CacheStorageRecord>;

class SWIFT_PRIVATE_FILEID("WebKit/CacheStorageCache.swift") CacheStorageCache : public RefCountedAndCanMakeWeakPtr<CacheStorageCache>, public Identified<WebCore::DOMCacheIdentifier> {
    WTF_MAKE_TZONE_ALLOCATED(CacheStorageCache);
public:
    static Ref<CacheStorageCache> create(CacheStorageManager&, const String& name, const String& uniqueName, const String& path, Ref<WorkQueue>&&);

    ~CacheStorageCache();
    // The Swift state is keyed by this cache's own identifier.
    uint64_t swiftKey() const { return identifier().object().toUInt64(); }
    const String& name() const LIFETIME_BOUND { return m_name; }
    const String& uniqueName() const LIFETIME_BOUND { return m_uniqueName; }
    // Swift cannot call name(), a C++ accessor that returns a const reference.
    String copiedName() const { return m_name; }
    std::optional<WebCore::ClientOrigin> origin() const;
    RefPtr<CacheStorageManager> manager() const;
    // Identified's identifier() is not imported into Swift.
    WebCore::DOMCacheIdentifier cacheIdentifier() const { return identifier(); }

    void open(CompletionHandler<void(bool)>&&);
    void retrieveRecords(WebCore::RetrieveRecordsOptions&&, WebCore::DOMCacheEngine::RetrieveRecordsCallback&&);
    // For cacheStorageTakeRecords, which takes the records in C++.
    CacheStorageRecordVector toCacheStorageRecords(Vector<WebCore::DOMCacheEngine::CrossThreadRecord>&&);

    Vector<CacheStorageRecordInformation> findRecords(WebCore::RetrieveRecordsOptions);
    void retrieveRecords(const Vector<CacheStorageRecordInformation>&, WebCore::RetrieveRecordsOptions&&, WebCore::DOMCacheEngine::RetrieveRecordsCallback&&);
    static CacheStorageVaryHeaders varyHeaders(String varyValue, WebCore::ResourceResponse::Tainting, WebCore::HTTPHeaderMap requestHeaderFields);

private:
    CacheStorageCache(CacheStorageManager&, const String& name, const String& uniqueName, const String& path, Ref<WorkQueue>&&);
    void initializeState();
    void destroyState();
    // An @implementation cannot take open()'s CompletionHandler.
    void readRecordsForPendingOpens();
    void answerPendingOpens(bool opened);
    // key() returns a const reference, which Swift imports as an unsafe pointer.
    static void setKeyAndInsertionTime(CacheStorageRecordInformation& recordInfo, const CacheStorageRecordInformation& existingRecordInfo)
    {
        recordInfo.setKey(existingRecordInfo.key());
        recordInfo.setInsertionTime(existingRecordInfo.insertionTime());
    }
    // Swift has no in-place sort or filter of a C++ Vector, so it would copy the records.
    static void sortByInsertionTime(CacheStorageStore::RecordInformationVector& recordInfos) { std::ranges::sort(recordInfos, { }, &CacheStorageRecordInformation::insertionTime); }
    static void removeRecordsWithoutIdentifier(CacheStorageRecordVector& records)
    {
        records.removeAllMatching([](auto& record) { return !record.info.identifier(); });
    }
    // Reading a std::optional record in Swift copies it.
    static bool containsRecord(const CacheStorageStore::ReadRecordsResult& records, uint64_t identifier)
    {
        return records.containsIf([&](auto& record) { return record && record->info.identifier() == identifier; });
    }

    // url() and httpMethod() return a const reference, which Swift imports as an unsafe pointer.
    static URL requestURL(const WebCore::ResourceRequest& request) { return request.url(); }
    static String requestMethod(const WebCore::ResourceRequest& request) { return request.httpMethod(); }
    // httpHeaderField and setQuery take a StringView, which Swift cannot pass safely.
    static String requestHeaderField(const WebCore::ResourceRequest& request, String name) { return request.httpHeaderField(name); }
    static URL urlWithoutQuery(URL url)
    {
        url.setQuery({ });
        return url;
    }
    // Swift cannot reach into or build the UniqueRef values of m_recordInformations.
    URL recordURL(uint64_t identifier) const;
    CacheStorageRecordInformation recordInformation(uint64_t identifier) const;
    void setRecordInformation(CacheStorageRecordInformation, uint64_t identifier);
    void removeRecordInformation(uint64_t identifier) { m_recordInformations.remove(identifier); }
    void clearRecordInformations() { m_recordInformations.clear(); }

    const CacheStorageRecordInformation& storedRecordInformation(uint64_t identifier) const LIFETIME_BOUND;

    void assertIsOnCorrectQueue() const
    {
#if ASSERT_ENABLED
        assertIsCurrent(m_queue.get());
#endif
    }

    WeakPtr<CacheStorageManager> m_manager;
    bool m_isInitialized { false };
    Vector<CompletionHandler<void(bool)>> m_pendingOpens;
    String m_name;
    String m_uniqueName;
    // A CacheStorageRecordInformation is too big for HashTable to move on rehash.
    HashMap<uint64_t, UniqueRef<CacheStorageRecordInformation>> m_recordInformations;
#if ASSERT_ENABLED
    const Ref<WorkQueue> m_queue;
#endif
    const Ref<CacheStorageStore> m_store;
};

} // namespace WebKit
