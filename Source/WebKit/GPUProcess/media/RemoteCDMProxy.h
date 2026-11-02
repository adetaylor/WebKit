/*
 * Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

#include "MessageReceiver.h"
#include "RemoteCDMInstanceIdentifier.h"
#include <WebCore/CDMPrivate.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Forward.h>
#include <wtf/RefCounted.h>
#include <wtf/WeakPtr.h>

namespace WebCore {
struct CDMKeySystemConfiguration;
}

namespace WebKit {

class RemoteCDMPrivateHandle;
class RemoteCDMRegistry;
struct RemoteCDMInstanceConfiguration;
struct SharedPreferencesForWebProcess;

class RemoteCDMProxy : public RefCounted<RemoteCDMProxy>, public IPC::MessageReceiver {
public:
    static Ref<RemoteCDMProxy> create(RemoteCDMRegistry&, Ref<RemoteCDMPrivateHandle>&&);
    ~RemoteCDMProxy();

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

private:
    RemoteCDMProxy(RemoteCDMRegistry&, Ref<RemoteCDMPrivateHandle>&&);

    // IPC::MessageReceiver
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;

    // Messages
    void getSupportedConfiguration(WebCore::CDMKeySystemConfiguration&&, WebCore::CDMPrivate::LocalStorageAccess, CompletionHandler<void(std::optional<WebCore::CDMKeySystemConfiguration>)>&&);
    void createInstance(CompletionHandler<void(std::optional<RemoteCDMInstanceIdentifier>, RemoteCDMInstanceConfiguration&&)>&&);
    void loadAndInitialize();
    void setLogIdentifier(uint64_t);

    WeakPtr<RemoteCDMRegistry> m_registry;
    const Ref<RemoteCDMPrivateHandle> m_cdm;
};

}

#endif
