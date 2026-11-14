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

#if ENABLE(GPU_PROCESS) && !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

#include "RemoteGraphicsContext.h"
#include "RemoteSnapshotIdentifier.h"
#include "RemoteSnapshotRecorderIdentifier.h"
#include <WebCore/DisplayListRecorderImpl.h>
#include <WebCore/FrameIdentifier.h>
#include <wtf/FunctionDispatcher.h>
#include <wtf/HashMap.h>
#include <wtf/Lock.h>
#include <wtf/ThreadSafeRefCounted.h>

namespace WebKit {

class DisplayListData;

// The display lists of a snapshot's frames, on the ports that record them as WebCore display lists: C++ records and draws
// them, and the snapshot (RemoteSnapshot.swift) says when its frames are resolved. A frame that the snapshot abandoned
// draws nothing, even if its display list comes in later.
class RemoteSnapshotDisplayLists final : public ThreadSafeRefCounted<RemoteSnapshotDisplayLists> {
public:
    static Ref<RemoteSnapshotDisplayLists> create() { return adoptRef(*new RemoteSnapshotDisplayLists); }
    ~RemoteSnapshotDisplayLists();

    // Unique to these display lists, so that the snapshot can tell them from another snapshot's with its identifier.
    uint64_t token() const { return m_token; }

    // The first display list of a frame, which is released on the dispatcher.
    void setFrame(WebCore::FrameIdentifier, Ref<const WebCore::DisplayList::DisplayList>&&, SerialFunctionDispatcher&);
    void abandonFrame(WebCore::FrameIdentifier);
    [[nodiscard]] bool applyFrame(WebCore::FrameIdentifier, WebCore::GraphicsContext&) const;
#if PLATFORM(COCOA)
    std::optional<DisplayListData> createDisplayListData(WebCore::FrameIdentifier rootFrameIdentifier) const;
#endif

private:
    RemoteSnapshotDisplayLists();

    // A frame's display list isn't generally threadsafe, but should be fine to replay on a different thread in the GPU
    // process (where Font objects don't get mutated). Make sure we manually return the refs to the originating work queue to
    // avoid ref counting races.
    class DisplayListAndReleaseDispatcher {
    public:
        DisplayListAndReleaseDispatcher(Ref<const WebCore::DisplayList::DisplayList>&&, SerialFunctionDispatcher&);
        DisplayListAndReleaseDispatcher(DisplayListAndReleaseDispatcher&&) = default;
        DisplayListAndReleaseDispatcher& operator=(DisplayListAndReleaseDispatcher&&) = default;
        ~DisplayListAndReleaseDispatcher();

        const RefPtr<const WebCore::DisplayList::DisplayList>& displayList() const { return m_displayList; }

    private:
        RefPtr<const WebCore::DisplayList::DisplayList> m_displayList;
        Ref<SerialFunctionDispatcher> m_dispatcher;
    };

    const uint64_t m_token;
    mutable Lock m_lock;
    // None for a frame that was abandoned.
    HashMap<WebCore::FrameIdentifier, std::optional<DisplayListAndReleaseDispatcher>> m_frames WTF_GUARDED_BY_LOCK(m_lock);
};

// RemoteSnapshotRecorder is a display list recorder that can convert a snapshot subframe rendering into
// its own draw item. In other words, RemoteSnapshotRecorder has the right to source snapshot subframe
// renderings. With the CG renderer in Swift, the rendering backend's Swift state records snapshot frames
// (RemoteRenderingBackend.swift).
class RemoteSnapshotRecorder final : public RemoteGraphicsContext {
public:
    static Ref<RemoteSnapshotRecorder> create(RemoteSnapshotRecorderIdentifier, const RemoteSnapshotIdentifier&, RemoteRenderingBackend&);
    ~RemoteSnapshotRecorder();
    void stopListeningForIPC();
    // Makes what it recorded the snapshot's frame, whose display list is released on the dispatcher.
    void sinkIntoSnapshotFrame(WebCore::FrameIdentifier, SerialFunctionDispatcher&);

private:
    RemoteSnapshotRecorder(Ref<WebCore::DisplayList::RecorderImpl>&&, RemoteSnapshotRecorderIdentifier, const RemoteSnapshotIdentifier&, RemoteRenderingBackend&);
    void startListeningForIPC();

    // RemoteGraphicsContext overrides.
    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;

    // Messages.
    void drawSnapshotFrame(WebCore::FrameIdentifier);

    const RemoteSnapshotIdentifier m_snapshotIdentifier;
    // The snapshot's, or, for a snapshot that no longer exists, ones that are dropped with the recorder.
    const Ref<RemoteSnapshotDisplayLists> m_displayLists;
    const Ref<WebCore::DisplayList::RecorderImpl> m_recorder;
    const RemoteSnapshotRecorderIdentifier m_identifier;
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
