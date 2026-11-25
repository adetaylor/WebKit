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

#include "NetworkCacheKey.h"
#include <WebCore/DOMCacheEngine.h>
#include <WebCore/HTTPParsers.h>
#include <WebCore/ResourceResponse.h>
#include <wtf/CrossThreadCopier.h>
#include <wtf/TZoneMalloc.h>

namespace WebKit {

struct CacheStorageVaryHeader {
    String name;
    String value;

    CacheStorageVaryHeader isolatedCopy() && { return { crossThreadCopy(WTF::move(name)), crossThreadCopy(WTF::move(value)) }; }
    CacheStorageVaryHeader isolatedCopy() const & { return { crossThreadCopy(name), crossThreadCopy(value) }; }
};

struct CacheStorageVaryHeaders {
    bool hasVaryStar { false };
    Vector<CacheStorageVaryHeader> headers;

    CacheStorageVaryHeaders isolatedCopy() && { return { hasVaryStar, crossThreadCopy(WTF::move(headers)) }; }
    CacheStorageVaryHeaders isolatedCopy() const & { return { hasVaryStar, crossThreadCopy(headers) }; }
};

class CacheStorageRecordInformation {
    WTF_MAKE_TZONE_ALLOCATED(CacheStorageRecordInformation);
public:
    CacheStorageRecordInformation() = default;
    CacheStorageRecordInformation(NetworkCache::Key&&, double insertionTime, uint64_t identifier, uint64_t updateResponseCounter, uint64_t size, URL&&, CacheStorageVaryHeaders&&);
    CacheStorageRecordInformation isolatedCopy() &&;
    CacheStorageRecordInformation isolatedCopy() const &;

    const NetworkCache::Key& key() const LIFETIME_BOUND { return m_key; }
    double insertionTime() const { return m_insertionTime; }
    uint64_t identifier() const { return m_identifier; }
    uint64_t updateResponseCounter() const { return m_updateResponseCounter; }
    uint64_t size() const { return m_size; }
    const URL& url() const LIFETIME_BOUND { return m_url; }
    // Swift cannot call a C++ accessor that returns a const reference.
    CacheStorageVaryHeaders varyHeaders() const { return m_varyHeaders; }

    void setKey(const NetworkCache::Key& key) { m_key = key; }
    void setSize(uint64_t size) { m_size = size; }
    void setIdentifier(uint64_t identifier) { m_identifier = identifier; }
    void setUpdateResponseCounter(double updateResponseCounter) { m_updateResponseCounter = updateResponseCounter; }
    void setInsertionTime(double insertionTime) { m_insertionTime = insertionTime; }
    void setURL(const URL& url) { m_url = url; }
    void setVaryHeaders(CacheStorageVaryHeaders&& varyHeaders) { m_varyHeaders = WTF::move(varyHeaders); }

private:
    NetworkCache::Key m_key;
    double m_insertionTime { 0 };
    uint64_t m_identifier { 0 };
    uint64_t m_updateResponseCounter { 0 };
    uint64_t m_size { 0 };
    URL m_url;
    CacheStorageVaryHeaders m_varyHeaders;
};

struct CacheStorageRecord {
    WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(CacheStorageRecord);
    CacheStorageRecord(const CacheStorageRecord&) = delete;
    CacheStorageRecord& operator=(const CacheStorageRecord&) = delete;
    CacheStorageRecord() = default;
    CacheStorageRecord(CacheStorageRecord&&) = default;
    CacheStorageRecord& operator=(CacheStorageRecord&&) = default;
    CacheStorageRecord(const CacheStorageRecordInformation& info, WebCore::FetchHeaders::Guard requestHeadersGuard, const WebCore::ResourceRequest& request, WebCore::FetchOptions options, const String& referrer, WebCore::FetchHeaders::Guard responseHeadersGuard, WebCore::ResourceResponse::CrossThreadData&& responseData, uint64_t responseBodySize, WebCore::DOMCacheEngine::ResponseBody&& responseBody)
        : info(info)
        , requestHeadersGuard(requestHeadersGuard)
        , request(request)
        , options(options)
        , referrer(referrer)
        , responseHeadersGuard(responseHeadersGuard)
        , responseData(WTF::move(responseData))
        , responseBodySize(responseBodySize)
        , responseBody(WTF::move(responseBody))
    {
    }

    CacheStorageRecord isolatedCopy() && {
        return {
            crossThreadCopy(WTF::move(info)),
            requestHeadersGuard,
            crossThreadCopy(WTF::move(request)),
            crossThreadCopy(WTF::move(options)),
            crossThreadCopy(WTF::move(referrer)),
            responseHeadersGuard,
            crossThreadCopy(WTF::move(responseData)),
            responseBodySize,
            WebCore::DOMCacheEngine::isolatedResponseBody(WTF::move(responseBody))
        };
    }

    CacheStorageRecordInformation info;
    WebCore::FetchHeaders::Guard requestHeadersGuard;
    WebCore::ResourceRequest request;
    WebCore::FetchOptions options;
    String referrer;
    WebCore::FetchHeaders::Guard responseHeadersGuard;
    WebCore::ResourceResponse::CrossThreadData responseData;
    uint64_t responseBodySize;
    WebCore::DOMCacheEngine::ResponseBody responseBody;
};

}
