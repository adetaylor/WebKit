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

#pragma once

#include "FileSystemSyncAccessHandleInfo.h"
#include <WebCore/FileSystemHandleIdentifier.h>
#include <WebCore/FileSystemSyncAccessHandleIdentifier.h>
#include <wtf/Identified.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>

namespace IPC {
class SharedFileHandle;
}

namespace WebCore {
struct ClientOrigin;
}

namespace WebKit {

class FileSystemStorageManager;
enum class FileSystemStorageError : uint8_t;

class SWIFT_PRIVATE_FILEID("WebKit/FileSystemStorageHandle.swift") FileSystemStorageHandle final : public RefCounted<FileSystemStorageHandle>, public CanMakeWeakPtr<FileSystemStorageHandle, WeakPtrFactoryInitialization::Eager>, public Identified<WebCore::FileSystemHandleIdentifier> {
    WTF_MAKE_TZONE_ALLOCATED(FileSystemStorageHandle);
public:
    enum class Type : uint8_t { File, Directory, Any };
    static RefPtr<FileSystemStorageHandle> create(FileSystemStorageManager&, Type, String&& path);
    ~FileSystemStorageHandle();

    // The Swift state is keyed by this handle's own identifier.
    uint64_t swiftKey() const { return identifier().toUInt64(); }
    // Identified's identifier() is not imported into Swift.
    WebCore::FileSystemHandleIdentifier handleIdentifier() const { return identifier(); }
    String path() const;
    Type type() const { return m_type; }
    std::optional<WebCore::ClientOrigin> origin() const;

    // Swift cannot make the std::expected this returns: only its default constructor is imported.
    std::expected<FileSystemSyncAccessHandleInfo, FileSystemStorageError> createSyncAccessHandle();

private:
    FileSystemStorageHandle(FileSystemStorageManager&, Type, String&& path);
    void initializeState(String path);
    void destroyState();
    // The parts of createSyncAccessHandle() that read or change the Swift state.
    std::optional<FileSystemStorageError> lockForSyncAccessHandle();
    void unlockForSyncAccessHandle();
    WebCore::FileSystemSyncAccessHandleIdentifier activateSyncAccessHandle();

    WeakPtr<FileSystemStorageManager> m_manager;
    Type m_type;
};

} // namespace WebKit
