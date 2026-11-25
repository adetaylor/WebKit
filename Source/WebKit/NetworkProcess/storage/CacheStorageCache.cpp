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

#include "config.h"
#include "CacheStorageCache.h"

#include "CacheStorageDiskStore.h"
#include "CacheStorageManager.h"
#include "CacheStorageMemoryStore.h"
#include <WebCore/CrossOriginAccessControl.h>
#include <WebCore/HTTPHeaderMap.h>
#include <WebCore/OriginAccessPatterns.h>
#include <WebCore/ResourceError.h>
#include <ranges>
#include <wtf/Borrow.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

static Ref<CacheStorageStore> createStore(const String& uniqueName, const String& path, Ref<WorkQueue>&& queue)
{
    if (path.isEmpty())
        return CacheStorageMemoryStore::create();
    return CacheStorageDiskStore::create(uniqueName, path, WTF::move(queue));
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(CacheStorageCache);

Ref<CacheStorageCache> CacheStorageCache::create(CacheStorageManager& manager, const String& name, const String& uniqueName, const String& path, Ref<WorkQueue>&& queue)
{
    return adoptRef(*new CacheStorageCache(manager, name, uniqueName, path, WTF::move(queue)));
}

CacheStorageCache::CacheStorageCache(CacheStorageManager& manager, const String& name, const String& uniqueName, const String& path, Ref<WorkQueue>&& queue)
    : m_manager(manager)
    , m_name(name)
    , m_uniqueName(uniqueName)
#if ASSERT_ENABLED
    , m_queue(queue.copyRef())
#endif
    , m_store(createStore(uniqueName, path, WTF::move(queue)))
{
    assertIsOnCorrectQueue();
    initializeState();
}

CacheStorageCache::~CacheStorageCache()
{
    assertIsOnCorrectQueue();
    answerPendingOpens(false);
    destroyState();
}

RefPtr<CacheStorageManager> CacheStorageCache::manager() const
{
    return m_manager.get();
}

const CacheStorageRecordInformation& CacheStorageCache::storedRecordInformation(uint64_t identifier) const
{
    auto iterator = m_recordInformations.find(identifier);
    // Swift keeps a record's identifier only while m_recordInformations holds it.
    RELEASE_ASSERT(iterator != m_recordInformations.end());
    return iterator->value.get();
}

URL CacheStorageCache::recordURL(uint64_t identifier) const
{
    return storedRecordInformation(identifier).url();
}

CacheStorageRecordInformation CacheStorageCache::recordInformation(uint64_t identifier) const
{
    return storedRecordInformation(identifier);
}

void CacheStorageCache::setRecordInformation(CacheStorageRecordInformation recordInformation, uint64_t identifier)
{
    recordInformation.setIdentifier(identifier);
    // Swift keeps the record's Vary headers.
    recordInformation.setVaryHeaders({ });
    m_recordInformations.set(identifier, makeUniqueRef<CacheStorageRecordInformation>(WTF::move(recordInformation)));
}

static CacheStorageRecord toCacheStorageRecord(WebCore::DOMCacheEngine::CrossThreadRecord&& record, FileSystem::Salt salt, const String& uniqueName)
{
    NetworkCache::Key key { "record"_s, uniqueName, { }, createVersion4UUIDString(), salt };
    CacheStorageRecordInformation recordInfo { WTF::move(key), MonotonicTime::now().secondsSinceEpoch().milliseconds(), record.identifier, 0 , record.responseBodySize, URL { record.request.url() }, CacheStorageCache::varyHeaders(record.response.httpHeaderFields.get(WebCore::HTTPHeaderName::Vary), record.response.tainting, record.request.httpHeaderFields()) };

    return CacheStorageRecord { WTF::move(recordInfo), record.requestHeadersGuard, WTF::move(record.request), record.options, WTF::move(record.referrer), record.responseHeadersGuard, WTF::move(record.response), record.responseBodySize, WTF::move(record.responseBody) };
}

CacheStorageRecordVector CacheStorageCache::toCacheStorageRecords(Vector<WebCore::DOMCacheEngine::CrossThreadRecord>&& records)
{
    RefPtr manager = m_manager;
    if (!manager)
        return { };
    return WTF::map(WTF::move(records), [&](WebCore::DOMCacheEngine::CrossThreadRecord&& record) {
        return toCacheStorageRecord(WTF::move(record), manager->salt(), m_uniqueName);
    });
}

void CacheStorageCache::open(CompletionHandler<void(bool)>&& callback)
{
    assertIsOnCorrectQueue();

    if (m_isInitialized)
        return callback(true);

    m_pendingOpens.append(WTF::move(callback));
    if (m_pendingOpens.size() > 1)
        return;

    readRecordsForPendingOpens();
}

void CacheStorageCache::retrieveRecords(WebCore::RetrieveRecordsOptions&& options, WebCore::DOMCacheEngine::RetrieveRecordsCallback&& callback)
{
    auto targetRecordInfos = findRecords(options);
    retrieveRecords(targetRecordInfos, WTF::move(options), WTF::move(callback));
}

void CacheStorageCache::retrieveRecords(const Vector<CacheStorageRecordInformation>& targetRecordInfos, WebCore::RetrieveRecordsOptions&& options, WebCore::DOMCacheEngine::RetrieveRecordsCallback&& callback)
{
    if (targetRecordInfos.isEmpty())
        return callback({ });
    
    m_store->readRecords(targetRecordInfos, [options = WTF::move(options), callback = WTF::move(callback)](auto&& cacheStorageRecords) mutable {
        using namespace WebCore::DOMCacheEngine;
        Vector<CrossThreadRecord> result(ReserveCapacityTag { }, cacheStorageRecords.size());
        for (auto&& cacheStorageRecord : borrow(cacheStorageRecords)) {
            if (!cacheStorageRecord)
                continue;
    
            CrossThreadRecord record { cacheStorageRecord->info.identifier(), 0, cacheStorageRecord->requestHeadersGuard, WTF::move(cacheStorageRecord->request), cacheStorageRecord->options, WTF::move(cacheStorageRecord->referrer), cacheStorageRecord->responseHeadersGuard, { }, nullptr, 0 };
            if (options.shouldProvideResponse) {
                record.response = WTF::move(cacheStorageRecord->responseData);
                record.responseBody = WTF::move(cacheStorageRecord->responseBody);
                record.responseBodySize = cacheStorageRecord->responseBodySize;
            }

            result.append(WTF::move(record));
        }

        std::ranges::sort(result, { }, &CrossThreadRecord::identifier);

        // The cross-origin resource policy check of https://w3c.github.io/ServiceWorker/#cache-matchall. The caller reports.
        Vector<WebCore::DOMCacheEngine::CORPViolation> corpViolations;
        for (auto& record : borrow(result)) {
            if (record.response.type != WebCore::ResourceResponse::Type::Opaque)
                continue;

            auto crossOriginResourcePolicy = record.response.httpHeaderFields.get(WebCore::HTTPHeaderName::CrossOriginResourcePolicy);
            auto isBlocked = [&](WebCore::CrossOriginEmbedderPolicyValue embedderPolicyValue, WebCore::DocumentIsolationPolicyValue documentIsolationPolicyValue) {
                return !!WebCore::validateCrossOriginResourcePolicy(embedderPolicyValue, documentIsolationPolicyValue, options.sourceOrigin, record.request.url(), false, record.response.url, crossOriginResourcePolicy, record.response.requestIncludesCredentials, WebCore::ForNavigation::No, WebCore::EmptyOriginAccessPatterns::singleton());
            };
            if (isBlocked(WebCore::CrossOriginEmbedderPolicyValue::UnsafeNone, WebCore::DocumentIsolationPolicyValue::None))
                return callback({ makeUnexpected(Error::CORP), WTF::move(corpViolations) });

            bool isBlockedByPolicy = !!WebCore::performCrossOriginResourcePolicyCheck(options.crossOriginEmbedderPolicy, options.documentIsolationPolicy, options.sourceOrigin, record.request.url(), false, record.response.url, crossOriginResourcePolicy, record.response.requestIncludesCredentials, WebCore::ForNavigation::No, WebCore::EmptyOriginAccessPatterns::singleton(), nullptr);
            if (isBlockedByPolicy || isBlocked(options.crossOriginEmbedderPolicy.reportOnlyValue, options.documentIsolationPolicy.reportOnlyValue)) {
                // FIXME: For a redirected response put() under another request, this should be the response's first URL, which the cache doesn't store.
                corpViolations.append({ record.response.isRedirected ? record.request.url() : record.response.url, record.response.url, crossOriginResourcePolicy, record.response.requestIncludesCredentials });
            }
            if (isBlockedByPolicy)
                return callback({ makeUnexpected(Error::CORP), WTF::move(corpViolations) });
        }

        callback({ WTF::move(result), WTF::move(corpViolations) });
    });
}

} // namespace WebKit
