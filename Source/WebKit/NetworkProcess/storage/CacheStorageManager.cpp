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

#include "config.h"
#include "CacheStorageManager.h"

#include "CacheStorageCache.h"
#include "CacheStorageRegistry.h"
#include <WebCore/ClientOrigin.h>
#include <WebCore/StorageUtilities.h>
#include <wtf/Borrow.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/persistence/PersistentEncoder.h>

namespace WebKit {

static constexpr auto cachesListFileName = "cacheslist"_s;
static constexpr auto cachesOriginFileName = "origin"_s;
static constexpr auto originSaltFileName = "salt"_s;

std::optional<Vector<std::pair<String, String>>> CacheStorageManager::cachesList() const
{
    Vector<std::pair<String, String>> result;
    if (m_path.isEmpty())
        return result;

    auto cachesListFilePath = FileSystem::pathByAppendingComponent(m_path, cachesListFileName);
    if (!FileSystem::fileExists(cachesListFilePath))
        return result;

    const auto cachesList = FileSystem::readEntireFile(cachesListFilePath);
    if (!cachesList)
        return std::nullopt;

    WTF::Persistence::Decoder decoder(*cachesList);
    std::optional<uint64_t> count;
    decoder >> count;
    if (!count)
        return std::nullopt;

    result.reserveInitialCapacity(*count);
    for (size_t index = 0; index < *count; ++index) {
        std::optional<String> name;
        decoder >> name;
        if (!name)
            return std::nullopt;

        std::optional<String> uniqueName;
        decoder >> uniqueName;
        if (!uniqueName)
            return std::nullopt;

        result.append({ WTF::move(*name), WTF::move(*uniqueName) });
    }

    return result;
}

bool CacheStorageManager::writeCachesList(std::optional<size_t> skippedCachesIndex) const
{
    if (m_path.isEmpty())
        return true;

    auto cachesListFilePath = FileSystem::pathByAppendingComponent(m_path, cachesListFileName);
    if (m_caches.isEmpty()) {
        FileSystem::deleteFile(cachesListFilePath);
        return true;
    }

    FileSystem::makeAllDirectories(FileSystem::parentPath(cachesListFilePath));
    WTF::Persistence::Encoder encoder;
    Borrow borrowedCaches = m_caches;
    uint64_t count = m_caches.size();
    if (skippedCachesIndex && *skippedCachesIndex < m_caches.size())
        --count;
    encoder << count;
    for (size_t index = 0; index < m_caches.size(); ++index) {
        if (skippedCachesIndex && index == *skippedCachesIndex)
            continue;
        encoder << borrowedCaches[index]->name();
        encoder << borrowedCaches[index]->uniqueName();
    }

    FileSystem::overwriteEntireFile(cachesListFilePath, encoder.span());
    return true;
}

String CacheStorageManager::saltFilePath(String saltDirectory)
{
    if (saltDirectory.isEmpty())
        return emptyString();

    return FileSystem::pathByAppendingComponent(saltDirectory, originSaltFileName);
}

static FileSystem::Salt readOrMakeSalt(const String& saltPath)
{
    if (saltPath.isEmpty())
        return { };

    return valueOrDefault(FileSystem::readOrMakeSalt(saltPath));
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(CacheStorageManager);

String CacheStorageManager::cacheStorageOriginDirectory(const String& rootDirectory, const WebCore::ClientOrigin& origin)
{
    if (rootDirectory.isEmpty())
        return emptyString();

    auto salt = readOrMakeSalt(saltFilePath(rootDirectory));
    NetworkCache::Key key(origin.topOrigin.toString(), origin.clientOrigin.toString(), { }, { }, salt);
    return FileSystem::pathByAppendingComponent(rootDirectory, key.hashAsString());
}

HashSet<WebCore::ClientOrigin> CacheStorageManager::originsOfCacheStorageData(const String& rootDirectory)
{
    HashSet<WebCore::ClientOrigin> result;
    for (auto& originName : FileSystem::listDirectory(rootDirectory)) {
        auto originFile = FileSystem::pathByAppendingComponents(rootDirectory, std::initializer_list<StringView>({ originName, cachesOriginFileName }));
        if (auto origin = WebCore::StorageUtilities::readOriginFromFile(originFile))
            result.add(*origin);
    }

    return result;
}

bool CacheStorageManager::hasCacheList(const String& cacheStorageDirectory)
{
    return FileSystem::fileExists(FileSystem::pathByAppendingComponent(cacheStorageDirectory, cachesListFileName));
}

Ref<CacheStorageManager> CacheStorageManager::create(const String& path, CacheStorageRegistry& registry, const WebCore::ClientOrigin& origin, ShouldWriteOriginFile shouldWriteOriginFile, QuotaCheckFunction&& quotaCheckFunction, Ref<WorkQueue>&& queue)
{
    return adoptRef(*new CacheStorageManager(path, registry, origin, shouldWriteOriginFile, WTF::move(quotaCheckFunction), WTF::move(queue)));
}

CacheStorageManager::CacheStorageManager(const String& path, CacheStorageRegistry& registry, const WebCore::ClientOrigin& origin, ShouldWriteOriginFile shouldWriteOriginFile, QuotaCheckFunction&& quotaCheckFunction, Ref<WorkQueue>&& queue)
    : m_path(path)
    , m_origin(origin)
    , m_salt(readOrMakeSalt(saltFilePath(m_path)))
    , m_registry(registry)
    , m_quotaCheckFunction(WTF::move(quotaCheckFunction))
    , m_queue(WTF::move(queue))
{
    initializeState();
    if (m_path.isEmpty() || shouldWriteOriginFile == ShouldWriteOriginFile::No)
        return;

    auto originFile = FileSystem::pathByAppendingComponent(m_path, cachesOriginFileName);
    WebCore::StorageUtilities::writeOriginToFile(originFile, m_origin);
}

CacheStorageManager::~CacheStorageManager()
{
    reset();
    destroyState();
}

void CacheStorageManager::reset()
{
    while (!m_pendingSpaceRequests.isEmpty()) {
        auto request = m_pendingSpaceRequests.takeFirst();
        request.second(false);
    }

    for (Ref cache : borrow(m_caches))
        m_registry->unregisterCache(cache->identifier());
    m_caches.clear();

    for (auto& identifier : m_removedCaches.keys())
        m_registry->unregisterCache(identifier);
    m_removedCaches.clear();

    m_isInitialized = false;
    resetState();
}

void CacheStorageManager::moveCacheToRemoved(size_t index)
{
    auto cacheIdentifier = m_caches[index]->identifier();
    m_removedCaches.set(cacheIdentifier, WTF::move(borrow(m_caches)[index]));
    m_caches.removeAt(index);
}

void CacheStorageManager::checkPendingSpaceRequests()
{
    while (!m_pendingSpaceRequests.isEmpty()) {
        auto [size, callback] = m_pendingSpaceRequests.takeFirst();
        m_quotaCheckFunction(size, WTF::move(callback));
    }
}

static void queryCaches(Vector<Ref<CacheStorageCache>>&& caches, size_t index, WebCore::RetrieveRecordsOptions&& options, bool shouldIterate, CompletionHandler<void(std::optional<WebCore::DOMCacheEngine::CrossThreadRecord>&&)>&& callback)
{
    if (index >= caches.size()) {
        callback({ });
        return;
    }

    Ref cache = caches[index];
    cache->open([caches = WTF::move(caches), index, options = WTF::move(options), shouldIterate, callback = WTF::move(callback)](bool opened) mutable {
        if (!opened) {
            if (!shouldIterate) {
                callback({ });
                return;
            }

            queryCaches(WTF::move(caches), index + 1, WTF::move(options), shouldIterate, WTF::move(callback));
            return;
        }

        Ref cache = caches[index];
        auto matches = cache->findRecords(options);
        if (!matches.isEmpty()) {
            cache->retrieveRecords({ WTF::move(matches[0]) }, WTF::move(options), [callback = WTF::move(callback)](auto&& result) mutable {
                // ServiceWorkerFetchTask, the only user, does its own CORP check and reporting.
                if (!result.records.has_value()) {
                    callback({ });
                    return;
                }
                callback(WTF::move(borrow(result.records.value())[0]));
            });
            return;
        }
        if (!shouldIterate) {
            callback({ });
            return;
        }
        queryCaches(WTF::move(caches), index + 1, WTF::move(options), shouldIterate, WTF::move(callback));
    });
}

void CacheStorageManager::query(WebCore::RetrieveRecordsOptions&& options, String&& cacheName, QueryCallback&& callback)
{
    if (!initializeCaches()) {
        callback({ });
        return;
    }

    size_t index = 0;
    if (!cacheName.isEmpty()) {
        index = m_caches.findIf([&](auto& cache) {
            return cache->name() == cacheName;
        });
        if (index == notFound) {
            callback({ });
            return;
        }
    }

    queryCaches(Vector<Ref<CacheStorageCache>> { m_caches }, index, WTF::move(options), cacheName.isEmpty(), WTF::move(callback));
}

} // namespace WebKit
