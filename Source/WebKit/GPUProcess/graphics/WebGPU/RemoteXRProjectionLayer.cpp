/*
 * Copyright (C) 2024-2026 Apple Inc. All rights reserved.
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
#include "RemoteXRProjectionLayer.h"

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "RemoteXRProjectionLayerMessages.h"
#include "StreamServerConnection.h"
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteXRProjectionLayer);

Ref<RemoteXRProjectionLayer> RemoteXRProjectionLayer::create(uintptr_t swiftState)
{
    return adoptRef(*new RemoteXRProjectionLayer(swiftState));
}

RemoteXRProjectionLayer::RemoteXRProjectionLayer(uintptr_t swiftState)
    : m_swiftState(swiftState)
{
    RELEASE_ASSERT(m_swiftState);
}

RemoteXRProjectionLayer::~RemoteXRProjectionLayer()
{
    destroySwiftState(m_swiftState);
}

void RemoteXRProjectionLayer::setSharedPreferencesProvider(Function<std::optional<SharedPreferencesForWebProcess>()>&& provider)
{
    m_sharedPreferencesProvider = WTF::move(provider);
}

std::optional<SharedPreferencesForWebProcess> RemoteXRProjectionLayer::sharedPreferencesForWebProcess() const
{
    return m_sharedPreferencesProvider ? m_sharedPreferencesProvider() : std::nullopt;
}

#if ENABLE(WEBXR) && PLATFORM(COCOA)
void RemoteXRProjectionLayer::startFrame(uint64_t frameIndex, MachSendRight&& colorBuffer, MachSendRight&& depthBuffer, MachSendRight&& completionSyncEvent, uint64_t textureIndex, PlatformXR::RateMapDescription&& rateMapDescription)
{
    startSwiftFrame(frameIndex, colorBuffer.sendRight(), depthBuffer.sendRight(), completionSyncEvent.sendRight(), textureIndex,
        static_cast<uint32_t>(rateMapDescription.screenSize.width()), static_cast<uint32_t>(rateMapDescription.screenSize.height()),
        { rateMapDescription.horizontalSamplesLeft.span() }, { rateMapDescription.horizontalSamplesRight.span() }, { rateMapDescription.verticalSamples.span() });
}
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
