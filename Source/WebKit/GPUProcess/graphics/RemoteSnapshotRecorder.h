/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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

#if ENABLE(GPU_PROCESS)

#include "RemoteDisplayListIdentifier.h"
#include "RemoteSnapshotRecorderIdentifier.h"

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include <WebCore/FrameIdentifier.h>
#include <wtf/FunctionDispatcher.h>
#include <wtf/ThreadSafeRefCounted.h>
#else
#include "RemoteGraphicsContext.h"
#include <WebCore/DisplayListRecorderImpl.h>
#endif

namespace WebKit {
class RemoteSnapshot;

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

class RemoteCGRendererRecorder;
class RemoteRenderingBackend;

// RemoteSnapshotRecorder records the RemoteCGRenderer messages to it in Swift (RemoteCGRendererRecorder), into a frame of a
// snapshot: it has the right to source snapshot subframe renderings, which its DrawSnapshotFrame draws.
class RemoteSnapshotRecorder final : public ThreadSafeRefCounted<RemoteSnapshotRecorder> {
public:
    static Ref<RemoteSnapshotRecorder> create(RemoteSnapshotRecorderIdentifier, RemoteSnapshot&, RemoteRenderingBackend&);
    ~RemoteSnapshotRecorder();
    void stopListeningForIPC();
    NODELETE Ref<RemoteSnapshot> snapshot() const;

    // Makes what it recorded the snapshot's frame, whose recording is released on the dispatcher.
    void sinkIntoSnapshotFrame(WebCore::FrameIdentifier, SerialFunctionDispatcher&);

private:
    RemoteSnapshotRecorder(RemoteSnapshotRecorderIdentifier, RemoteSnapshot&, RemoteRenderingBackend&);
    void startListeningForIPC();

    const Ref<RemoteSnapshot> m_snapshot;
    const Ref<RemoteRenderingBackend> m_renderingBackend;
    const RemoteSnapshotRecorderIdentifier m_identifier;
    const std::unique_ptr<RemoteCGRendererRecorder> m_recorder;
};

#else

// RemoteSnapshotRecorder is a display list recorder that can convert a snapshot subframe rendering into
// its own draw item. In other words, RemoteSnapshotRecorder has the right to source snapshot subframe
// renderings.
class RemoteSnapshotRecorder final : public RemoteGraphicsContext {
public:
    static Ref<RemoteSnapshotRecorder> create(RemoteSnapshotRecorderIdentifier, RemoteSnapshot&, RemoteRenderingBackend&);
    ~RemoteSnapshotRecorder();
    void stopListeningForIPC();
    NODELETE Ref<RemoteSnapshot> snapshot() const;
    Ref<const WebCore::DisplayList::DisplayList> takeDisplayList() { return m_recorder->takeDisplayList(); }

private:
    RemoteSnapshotRecorder(Ref<WebCore::DisplayList::RecorderImpl>&&, RemoteSnapshotRecorderIdentifier, RemoteSnapshot&, RemoteRenderingBackend&);
    void startListeningForIPC();

    // RemoteGraphicsContext overrides.
    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;

    // Messages.
    void drawSnapshotFrame(WebCore::FrameIdentifier);

    const Ref<RemoteSnapshot> m_snapshot;
    const Ref<WebCore::DisplayList::RecorderImpl> m_recorder;
    const RemoteSnapshotRecorderIdentifier m_identifier;
};

#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)
