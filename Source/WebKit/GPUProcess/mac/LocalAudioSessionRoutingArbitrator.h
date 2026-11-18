/*
 * Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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

#if ENABLE(ROUTING_ARBITRATION) && HAVE(AVAUDIO_ROUTING_ARBITER)

#include "Connection.h"
#include "GPUProcessConnectionMessages.h"
#include <WebCore/AudioSession.h>

namespace WebKit {

// The routing arbitration of the GPU process's audio session, which a web process's connection does for it
// (RemoteAudioSessionProxyManager.swift), goes to the web process with these, since Swift can't send a message with a reply.
inline void sendBeginRoutingArbitration(IPC::Connection& connection, WebCore::AudioSessionCategory category, WebCore::AudioSessionRoutingArbitrationCallbacks::CallbackBox& callback)
{
    connection.sendWithAsyncReply(Messages::GPUProcessConnection::BeginRoutingArbitrationWithCategory(category), [callback = Ref { callback }](auto error, auto defaultRouteChanged) {
        (*callback.get())(error, defaultRouteChanged);
    }, 0);
}

inline void sendEndRoutingArbitration(IPC::Connection& connection)
{
    connection.send(Messages::GPUProcessConnection::EndRoutingArbitration(), 0);
}

} // namespace WebKit

#endif
