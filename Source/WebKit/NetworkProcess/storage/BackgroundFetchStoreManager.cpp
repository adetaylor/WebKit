/*
 * Copyright (C) 2023 Apple Inc. All rights reserved.
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
#include "BackgroundFetchStoreManager.h"

#include "Logging.h"
#include <WebCore/ResourceError.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/Borrow.h>
#include <wtf/CrossThreadCopier.h>
#include <wtf/FileSystem.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/WorkQueue.h>

namespace WebKit {

using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(BackgroundFetchStoreManager);

BackgroundFetchStoreManager::BackgroundFetchStoreManager(const String& path, Ref<WorkQueue>&& taskQueue, QuotaCheckFunction&& quotaCheckFunction)
    : m_path(path)
    , m_taskQueue(WTF::move(taskQueue))
    , m_ioQueue(WorkQueue::create("com.apple.WebKit.BackgroundFetchStoreManager"_s))
    , m_quotaCheckFunction(WTF::move(quotaCheckFunction))
{
    m_ioQueue->dispatch([directoryPath = m_path.isolatedCopy()]() mutable {
        FileSystem::makeAllDirectories(directoryPath);
    });
}

BackgroundFetchStoreManager::~BackgroundFetchStoreManager() = default;

void BackgroundFetchStoreManager::initializeFetches(InitializeCallback&& callback)
{
    assertIsCurrent(m_taskQueue.get());

    if (m_path.isEmpty()) {
        callback({ });
        return;
    }

    m_ioQueue->dispatch([queue = Ref { m_taskQueue }, directoryPath = m_path.isolatedCopy(), callback = WTF::move(callback)]() mutable {
        auto fetches = readStoredFetches(WTF::move(directoryPath));

        queue->dispatch([callback = WTF::move(callback), fetches = WTF::move(fetches)]() mutable {
            callback(WTF::move(fetches));
        });
    });
}

void BackgroundFetchStoreManager::clearFetch(const String& identifier, CompletionHandler<void()>&& callback)
{
    assertIsCurrent(m_taskQueue.get());

    if (m_path.isEmpty()) {
        m_nonPersistentChunks.remove(identifier);
        callback();
        return;
    }

    m_ioQueue->dispatch([queue = Ref { m_taskQueue }, directoryPath = m_path.isolatedCopy(), identifier = identifier.isolatedCopy(), callback = WTF::move(callback)]() mutable {
        removeFilesWithPrefix(WTF::move(directoryPath), WTF::move(identifier));
        queue->dispatch(WTF::move(callback));
    });
}

void BackgroundFetchStoreManager::clearAllFetches(const Vector<String>& identifiers, CompletionHandler<void()>&& callback)
{
    assertIsCurrent(m_taskQueue.get());

    if (m_path.isEmpty()) {
        for (auto& identifier : borrow(identifiers))
            m_nonPersistentChunks.remove(identifier);
        callback();
        return;
    }

    auto filePaths = map(identifiers, [this](auto& identifier) -> String {
        return FileSystem::pathByAppendingComponents(m_path, std::initializer_list<StringView>({ identifier }));
    });
    m_ioQueue->dispatch([queue = Ref { m_taskQueue }, filePaths = crossThreadCopy(WTF::move(filePaths)), callback = WTF::move(callback)]() mutable {
        for (auto& filePath : borrow(filePaths))
            removeFetchAndResponseBodies(filePath);
        queue->dispatch(WTF::move(callback));
    });
}

void BackgroundFetchStoreManager::storeFetch(const String& identifier, uint64_t downloadTotal, uint64_t uploadTotal, std::optional<size_t> responseBodyIndexToClear, Vector<uint8_t>&& data, CompletionHandler<void(StoreResult)>&& callback)
{
    assertIsCurrent(m_taskQueue.get());
    
    uint64_t expectedSpace;
    bool isSafe = WTF::safeAdd(downloadTotal, uploadTotal, expectedSpace)
        && WTF::safeAdd(expectedSpace, data.size(), expectedSpace);
    if (!isSafe) {
        callback(StoreResult::QuotaError);
        return;
    }

    m_quotaCheckFunction(expectedSpace, [weakThis = WeakPtr { *this }, identifier, downloadTotal, uploadTotal, responseBodyIndexToClear, data = WTF::move(data), callback = WTF::move(callback)](bool result) mutable {
        RefPtr protectedThis = weakThis;
        if (!protectedThis) {
            callback(StoreResult::InternalError);
            return;
        }
        if (!result) {
            callback(StoreResult::QuotaError);
            return;
        }
        protectedThis->storeFetchAfterQuotaCheck(identifier, downloadTotal, uploadTotal, responseBodyIndexToClear, WTF::move(data), WTF::move(callback));
    });
}

void BackgroundFetchStoreManager::storeFetchAfterQuotaCheck(const String& identifier, uint64_t downloadTotal, uint64_t uploadTotal, std::optional<size_t> responseBodyIndexToClear, Vector<uint8_t>&& data, CompletionHandler<void(StoreResult)>&& callback)
{
    assertIsCurrent(m_taskQueue.get());

    if (m_path.isEmpty()) {
        callback(StoreResult::OK);
        return;
    }

    auto filePath = FileSystem::pathByAppendingComponents(m_path, std::initializer_list<StringView>({ identifier }));
    m_ioQueue->dispatch([queue = Ref { m_taskQueue }, filePath = WTF::move(filePath).isolatedCopy(), responseBodyIndexToClear, data = WTF::move(data), callback = WTF::move(callback)]() mutable {
        // FIXME: Cover the case of partial write.
        auto result = writeFetch(filePath, responseBodyIndexToClear, WTF::move(data));
        RELEASE_LOG_ERROR_IF(result == StoreResult::InternalError, ServiceWorker, "BackgroundFetchStoreManager::storeFetch failed writing");
        queue->dispatch([result, callback = WTF::move(callback)]() mutable {
            callback(result);
        });
    });
}

void BackgroundFetchStoreManager::storeFetchResponseBodyChunk(const String& identifier, size_t index, const SharedBuffer& data, CompletionHandler<void(StoreResult)>&& callback)
{
    assertIsCurrent(m_taskQueue.get());

    if (m_path.isEmpty()) {
        auto& chunks = m_nonPersistentChunks.ensure(identifier, [] {
            return Vector<SharedBufferBuilder>();
        }).iterator->value;

        while (chunks.size() <= index)
            chunks.append({ });

        borrow(chunks)[index].append(data);

        callback(StoreResult::OK);
        return;
    }

    auto filePath = FileSystem::pathByAppendingComponent(m_path, createFetchResponseBodyFile(identifier, index));
    m_ioQueue->dispatch([queue = Ref { m_taskQueue }, filePath = WTF::move(filePath).isolatedCopy(), data = Ref { data }, callback = WTF::move(callback)]() mutable {
        // FIXME: Cover the case of partial write.
        auto result = writeResponseBodyChunk(filePath, data.get());

        RELEASE_LOG_ERROR_IF(result == StoreResult::InternalError, ServiceWorker, "BackgroundFetchStoreManager::storeFetchResponseBodyChunk failed writing");
        queue->dispatch([result, callback = WTF::move(callback)]() mutable {
            callback(result);
        });
    });
}

void BackgroundFetchStoreManager::retrieveResponseBody(const String& identifier, size_t index, CompletionHandler<void(RefPtr<SharedBuffer>&&)>&& callback)
{
    assertIsCurrent(m_taskQueue.get());

    if (m_path.isEmpty()) {
        auto iterator = m_nonPersistentChunks.find(identifier);
        if (iterator == m_nonPersistentChunks.end() || iterator->value.size() <= index) {
            callback(RefPtr<SharedBuffer> { });
            return;
        }
        callback(borrow(iterator->value)[index].copyBuffer()->makeContiguous());
        return;
    }

    auto filePath = FileSystem::pathByAppendingComponent(m_path, createFetchResponseBodyFile(identifier, index));
    m_ioQueue->dispatch([queue = Ref { m_taskQueue }, filePath = WTF::move(filePath).isolatedCopy(), callback = WTF::move(callback)]() mutable {
        auto buffer = readResponseBody(filePath);

        queue->dispatch([buffer = WTF::move(buffer), callback = WTF::move(callback)]() mutable {
            callback(WTF::move(buffer));
        });
    });
}

} // namespace WebKit
