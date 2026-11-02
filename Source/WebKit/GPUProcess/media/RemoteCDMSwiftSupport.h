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

#if ENABLE(GPU_PROCESS) && ENABLE(ENCRYPTED_MEDIA)

#include "RemoteCDMConfiguration.h"
#include "RemoteCDMRegistry.h"
#include <wtf/SwiftBridging.h>
#include <wtf/WeakPtr.h>

namespace WebKit {

// What the Swift EME message receivers use of RemoteCDMRegistry that Swift cannot reach directly: Swift
// cannot hold a WeakPtr, or construct an ObjectIdentifier.

class RemoteCDMRegistryWeakReference {
public:
    explicit RemoteCDMRegistryWeakReference(RemoteCDMRegistry& registry)
        : m_registry(registry)
    {
    }

    // A new reference, so that Swift keeps the registry alive for as long as it uses it.
    RemoteCDMRegistry* WTF_NULLABLE get() const SWIFT_RETURNS_RETAINED { return RefPtr { m_registry.get() }.leakRef(); }

private:
    WeakPtr<RemoteCDMRegistry> m_registry;
} SWIFT_SELF_CONTAINED;

// Returns 0 if no CDM was created.
inline uint64_t createRemoteCDM(RemoteCDMRegistry& registry, const String& keySystem, const String& mediaKeysHashSalt, RemoteCDMConfiguration& configuration)
{
    auto identifier = registry.createCDM(keySystem, mediaKeysHashSalt, configuration);
    return identifier ? identifier->toUInt64() : 0;
}

inline void removeRemoteCDMInstance(RemoteCDMRegistry& registry, uint64_t identifier)
{
    registry.removeInstance(RemoteCDMInstanceIdentifier(identifier));
}

inline void removeRemoteCDMInstanceSession(RemoteCDMRegistry& registry, uint64_t identifier)
{
    registry.removeSession(RemoteCDMInstanceSessionIdentifier(identifier));
}

using RemoteCDMStrings = Vector<String>;

inline size_t remoteCDMStringCount(const RemoteCDMStrings& strings)
{
    return strings.size();
}

inline String remoteCDMString(const RemoteCDMStrings& strings, size_t index)
{
    return index < strings.size() ? strings[index] : String();
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && ENABLE(ENCRYPTED_MEDIA)
