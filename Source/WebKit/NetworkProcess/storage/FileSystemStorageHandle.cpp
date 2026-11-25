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
#include "FileSystemStorageHandle.h"

#include "FileSystemStorageError.h"
#include "FileSystemStorageManager.h"
#include "SharedFileHandle.h"
#include <wtf/FileSystem.h>
#include <wtf/Scope.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(FileSystemStorageHandle);

RefPtr<FileSystemStorageHandle> FileSystemStorageHandle::create(FileSystemStorageManager& manager, Type type, String&& path)
{
    bool canAccess = false;
    switch (type) {
    case FileSystemStorageHandle::Type::Directory:
        canAccess = FileSystem::makeAllDirectories(path);
        break;
    case FileSystemStorageHandle::Type::File:
        if (auto handle = FileSystem::openFile(path, FileSystem::FileOpenMode::ReadWrite); handle)
            canAccess = true;
        break;
    case FileSystemStorageHandle::Type::Any:
        ASSERT_NOT_REACHED();
    }

    if (!canAccess)
        return nullptr;

    return adoptRef(*new FileSystemStorageHandle(manager, type, WTF::move(path)));
}

FileSystemStorageHandle::FileSystemStorageHandle(FileSystemStorageManager& manager, Type type, String&& path)
    : m_manager(manager)
    , m_type(type)
{
    ASSERT(!path.isEmpty());
    initializeState(WTF::move(path));
}

FileSystemStorageHandle::~FileSystemStorageHandle()
{
    destroyState();
}

std::expected<FileSystemSyncAccessHandleInfo, FileSystemStorageError> FileSystemStorageHandle::createSyncAccessHandle()
{
    if (auto error = lockForSyncAccessHandle())
        return makeUnexpected(*error);

    bool isLockReleaseNeeded = true;
    auto lockReleaser = makeScopeExit([&] {
        if (isLockReleaseNeeded)
            unlockForSyncAccessHandle();
    });

    auto path = this->path();
    auto handle = FileSystem::openFile(path, FileSystem::FileOpenMode::ReadWrite);
    if (!handle)
        return makeUnexpected(FileSystemStorageError::Unknown);

    auto ipcHandle = IPC::SharedFileHandle::create(WTF::move(handle));
    if (!ipcHandle)
        return makeUnexpected(FileSystemStorageError::BackendNotSupported);

    isLockReleaseNeeded = false;

    auto identifier = activateSyncAccessHandle();
    uint64_t initialCapacity = valueOrDefault(FileSystem::fileSize(path));
    return FileSystemSyncAccessHandleInfo { identifier, WTF::move(*ipcHandle), initialCapacity };
}

} // namespace WebKit
