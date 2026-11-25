/*
 * Copyright (C) 2022-2025 Apple Inc. All rights reserved.
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

#include "Connection.h"
#include "SwiftStateKey.h"
#include <WebCore/ClientOrigin.h>
#include <WebCore/DOMCacheEngine.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>

namespace WebKit {
class CacheStorageManager;
}

namespace WebCore {
struct RetrieveRecordsOptions;
}

namespace WebKit {
class CacheStorageCache;
class CacheStorageRecordInformation;
class CacheStorageRegistry;
class CacheStorageStore;
struct CacheStorageRecord;

enum class ShouldWriteOriginFile : bool { No, Yes };

class SWIFT_PRIVATE_FILEID("WebKit/CacheStorageManager.swift") CacheStorageManager : public RefCountedAndCanMakeWeakPtr<CacheStorageManager>, public SwiftStateKey {
    WTF_MAKE_TZONE_ALLOCATED(CacheStorageManager);
public:
    static String cacheStorageOriginDirectory(const String& rootDirectory, const WebCore::ClientOrigin&);
    static void copySaltFileToOriginDirectory(String rootDirectory, String originDirectory);
    static HashSet<WebCore::ClientOrigin> originsOfCacheStorageData(const String& rootDirectory);
    static uint64_t cacheStorageSize(String originDirectory);
    static bool hasCacheList(const String& cacheListDirectory);

    using QuotaCheckFunction = Function<void(uint64_t spaceRequested, CompletionHandler<void(bool)>&&)>;
    static Ref<CacheStorageManager> create(const String& path, CacheStorageRegistry&, const WebCore::ClientOrigin&, ShouldWriteOriginFile, QuotaCheckFunction&&, Ref<WorkQueue>&&);
    ~CacheStorageManager();
    void reference(IPC::Connection::UniqueID, WebCore::DOMCacheIdentifier);
    void dereference(IPC::Connection::UniqueID, WebCore::DOMCacheIdentifier);

    void connectionClosed(IPC::Connection::UniqueID);
    NODELETE bool hasDataInMemory();
    NODELETE bool isActive();
    String representationString();
    FileSystem::Salt salt() const { return m_salt; }
    void reset();

    using QueryCallback = CompletionHandler<void(std::optional<WebCore::DOMCacheEngine::CrossThreadRecord>&&)>;
    void query(WebCore::RetrieveRecordsOptions&&, String&& cacheName, QueryCallback&&);

private:
    CacheStorageManager(const String& path, CacheStorageRegistry&, const WebCore::ClientOrigin&, ShouldWriteOriginFile, QuotaCheckFunction&&, Ref<WorkQueue>&&);
    void initializeState();
    void destroyState();
    void resetState();
    bool initializeCaches();
    static String saltFilePath(String saltDirectory);

    // Swift cannot iterate a HashMap's keys.
    Vector<WebCore::DOMCacheIdentifier> removedCacheIdentifiers() const { return copyToVector(m_removedCaches.keys()); }
    // Swift cannot call WTF::Persistence's templated coders.
    std::optional<Vector<std::pair<String, String>>> cachesList() const;
    bool writeCachesList(std::optional<size_t> skippedCachesIndex) const;
    // Swift does not import HashMap's set or add, which are templates.
    void moveCacheToRemoved(size_t index);
    // The Deque holds move-only CompletionHandlers, which Swift cannot take out of it.
    bool appendPendingSpaceRequest(uint64_t size, CompletionHandler<void(bool)>&& callback)
    {
        m_pendingSpaceRequests.append({ size, WTF::move(callback) });
        return m_pendingSpaceRequests.size() == 1;
    }
    void checkPendingSpaceRequests();

    bool m_isInitialized { false };
    String m_path;
    WebCore::ClientOrigin m_origin;
    FileSystem::Salt m_salt;
    const Ref<CacheStorageRegistry> m_registry;
    QuotaCheckFunction m_quotaCheckFunction;
    Vector<Ref<CacheStorageCache>> m_caches;
    HashMap<WebCore::DOMCacheIdentifier, Ref<CacheStorageCache>> m_removedCaches;
    const Ref<WorkQueue> m_queue;
    Deque<std::pair<uint64_t, CompletionHandler<void(bool)>>> m_pendingSpaceRequests;
};

} // namespace WebKit
