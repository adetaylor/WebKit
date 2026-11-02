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

#include "config.h"
#include "RemoteCDMProxy.h"

#if ENABLE(GPU_PROCESS) && ENABLE(ENCRYPTED_MEDIA)

#include "RemoteCDMInstanceConfiguration.h"
#include "RemoteCDMRegistry.h"
#include "SharedPreferencesForWebProcess.h"
#include <WebCore/CDMInstance.h>
#include <WebCore/CDMKeySystemConfiguration.h>

namespace WebKit {

using namespace WebCore;

Ref<RemoteCDMProxy> RemoteCDMProxy::create(RemoteCDMRegistry& registry, Ref<RemoteCDMPrivateHandle>&& cdm)
{
    return adoptRef(*new RemoteCDMProxy(registry, WTF::move(cdm)));
}

RemoteCDMProxy::RemoteCDMProxy(RemoteCDMRegistry& registry, Ref<RemoteCDMPrivateHandle>&& cdm)
    : m_registry(registry)
    , m_cdm(WTF::move(cdm))
{
}

RemoteCDMProxy::~RemoteCDMProxy() = default;

void RemoteCDMProxy::getSupportedConfiguration(CDMKeySystemConfiguration&& configuration, CDMPrivate::LocalStorageAccess access, CompletionHandler<void(std::optional<CDMKeySystemConfiguration>)>&& callback)
{
    m_cdm->getSupportedConfiguration(WTF::move(configuration), access, WTF::move(callback));
}

void RemoteCDMProxy::createInstance(CompletionHandler<void(std::optional<RemoteCDMInstanceIdentifier>, RemoteCDMInstanceConfiguration&&)>&& completion)
{
    RefPtr privateInstance = m_cdm->createInstance();
    RefPtr registry = m_registry;
    if (!privateInstance || !registry) {
        completion(std::nullopt, { });
        return;
    }
    RemoteCDMInstanceConfiguration configuration;
    auto identifier = registry->createInstance(m_cdm, privateInstance.releaseNonNull(), configuration);
    completion(identifier, WTF::move(configuration));
}

void RemoteCDMProxy::loadAndInitialize()
{
    m_cdm->loadAndInitialize();
}

void RemoteCDMProxy::setLogIdentifier(uint64_t logIdentifier)
{
    m_cdm->setLogIdentifier(logIdentifier);
}

std::optional<SharedPreferencesForWebProcess> RemoteCDMProxy::sharedPreferencesForWebProcess() const
{
    if (RefPtr registry = m_registry)
        return registry->sharedPreferencesForWebProcess();
    return std::nullopt;
}

}

#endif
