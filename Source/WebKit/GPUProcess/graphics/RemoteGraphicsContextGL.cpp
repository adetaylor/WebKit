/*
 * Copyright (C) 2020-2021 Apple Inc. All rights reserved.
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
#include "RemoteGraphicsContextGL.h"

#if ENABLE(GPU_PROCESS) && ENABLE(WEBGL)

#include "RemoteGraphicsContextGLMessages.h"
#include <wtf/TZoneMallocInlines.h>

#define MESSAGE_CHECK(assertion) MESSAGE_CHECK_BASE(assertion, m_connection);

namespace WebKit {

using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteGraphicsContextGL);

Ref<RemoteGraphicsContextGL> RemoteGraphicsContextGL::create(IPC::StreamServerConnection& connection, IPC::StreamConnectionWorkQueue& workQueue, GraphicsContextGL& context, const SharedPreferencesForWebProcess& sharedPreferences)
{
    return adoptRef(*new RemoteGraphicsContextGL(connection, workQueue, context, sharedPreferences));
}

RemoteGraphicsContextGL::RemoteGraphicsContextGL(IPC::StreamServerConnection& connection, IPC::StreamConnectionWorkQueue& workQueue, GraphicsContextGL& context, const SharedPreferencesForWebProcess& sharedPreferences)
    : m_connection(connection)
    , m_workQueue(workQueue)
    , m_context(context)
    , m_sharedPreferencesForWebProcess(sharedPreferences)
{
}

RemoteGraphicsContextGL::~RemoteGraphicsContextGL() = default;

void RemoteGraphicsContextGL::getErrors(CompletionHandler<void(GCGLErrorCodeSet)>&& completionHandler)
{
    assertIsCurrent(workQueue());
    completionHandler(protect(m_context)->getErrors());
}

void RemoteGraphicsContextGL::ensureExtensionEnabled(GCGLExtension extension)
{
    assertIsCurrent(workQueue());
    bool success = protect(m_context)->enableExtension(extension);
    MESSAGE_CHECK(success);
}

void RemoteGraphicsContextGL::drawBuffers(std::span<const uint32_t> bufs)
{
    assertIsCurrent(workQueue());
    protect(m_context)->drawBuffers(Vector(bufs));
}

void RemoteGraphicsContextGL::drawBuffersEXT(std::span<const uint32_t> bufs)
{
    assertIsCurrent(workQueue());
    protect(m_context)->drawBuffersEXT(Vector(bufs));
}

void RemoteGraphicsContextGL::invalidateFramebuffer(uint32_t target, std::span<const uint32_t> attachments)
{
    assertIsCurrent(workQueue());
    protect(m_context)->invalidateFramebuffer(target, Vector(attachments));
}

void RemoteGraphicsContextGL::invalidateSubFramebuffer(uint32_t target, std::span<const uint32_t> attachments, int32_t x, int32_t y, int32_t width, int32_t height)
{
    assertIsCurrent(workQueue());
    protect(m_context)->invalidateSubFramebuffer(target, Vector(attachments), x, y, width, height);
}

} // namespace WebKit

#undef MESSAGE_CHECK

#endif // ENABLE(GPU_PROCESS) && ENABLE(WEBGL)
