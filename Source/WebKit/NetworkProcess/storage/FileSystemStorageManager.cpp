/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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
#include "FileSystemStorageManager.h"

#include "FileSystemStorageHandleRegistry.h"
#include "WebFileSystemStorageConnectionMessages.h"
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(FileSystemStorageManager);

Ref<FileSystemStorageManager> FileSystemStorageManager::create(String&& path, FileSystemStorageHandleRegistry& registry, const WebCore::ClientOrigin& origin, QuotaCheckFunction&& quotaCheckFunction)
{
    return adoptRef(*new FileSystemStorageManager(WTF::move(path), registry, origin, WTF::move(quotaCheckFunction)));
}

FileSystemStorageManager::FileSystemStorageManager(String&& path, FileSystemStorageHandleRegistry& registry, const WebCore::ClientOrigin& origin, QuotaCheckFunction&& quotaCheckFunction)
    : m_path(WTF::move(path))
    , m_origin(origin)
    , m_registry(registry)
    , m_quotaCheckFunction(WTF::move(quotaCheckFunction))
{
    ASSERT(!RunLoop::isMain());
    initializeState();
}

FileSystemStorageManager::~FileSystemStorageManager()
{
    ASSERT(!RunLoop::isMain());

    close();
    destroyState();
}

bool FileSystemStorageManager::isActive() const
{
    return !m_handles.isEmpty();
}

void FileSystemStorageManager::addHandle(FileSystemStorageHandle& handle)
{
    if (RefPtr registry = m_registry)
        registry->registerHandle(handle.identifier(), handle);
    m_handles.add(handle.identifier(), Ref { handle });
}

void FileSystemStorageManager::sendInvalidateAccessHandle(IPC::Connection::UniqueID connection, WebCore::FileSystemSyncAccessHandleIdentifier identifier)
{
    IPC::Connection::send(connection, Messages::WebFileSystemStorageConnection::InvalidateAccessHandle(identifier), 0);
}

void FileSystemStorageManager::sendInvalidateWritable(IPC::Connection::UniqueID connection, WebCore::FileSystemWritableFileStreamIdentifier identifier)
{
    IPC::Connection::send(connection, Messages::WebFileSystemStorageConnection::InvalidateWritable(identifier), 0);
}

} // namespace WebKit
