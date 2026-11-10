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

#include "config.h"

#if ENABLE(GPU_PROCESS) && !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "RemoteSnapshotRecorder.h"

#include "DisplayListData.h"
#include "GPUProcess.h"
#include "Logging.h"
#include "RemoteGraphicsContextMessages.h"
#include "RemoteSnapshotRecorderMessages.h"

namespace WebKit {
using namespace WebCore;

static std::atomic<uint64_t> lastSnapshotDisplayListsToken;

RemoteSnapshotDisplayLists::RemoteSnapshotDisplayLists()
    : m_token(++lastSnapshotDisplayListsToken)
{
}

RemoteSnapshotDisplayLists::~RemoteSnapshotDisplayLists() = default;

void RemoteSnapshotDisplayLists::setFrame(FrameIdentifier frameIdentifier, Ref<const DisplayList::DisplayList>&& displayList, SerialFunctionDispatcher& releaseDispatcher)
{
    Locker locker(m_lock);
    // A frame is only asked to record once, so another display list is dropped rather than replacing the first.
    m_frames.add(frameIdentifier, DisplayListAndReleaseDispatcher { WTF::move(displayList), releaseDispatcher });
}

void RemoteSnapshotDisplayLists::abandonFrame(FrameIdentifier frameIdentifier)
{
    Locker locker(m_lock);
    m_frames.set(frameIdentifier, std::nullopt);
}

bool RemoteSnapshotDisplayLists::applyFrame(FrameIdentifier frameIdentifier, GraphicsContext& context) const
{
    RefPtr<const DisplayList::DisplayList> displayList;
    {
        Locker locker(m_lock);
        auto iterator = m_frames.find(frameIdentifier);
        if (iterator == m_frames.end())
            return false;
        if (!iterator->value)
            return true;
        displayList = iterator->value->displayList();
    }
    context.drawDisplayList(*displayList);
    return true;
}

#if PLATFORM(COCOA)
std::optional<DisplayListData> RemoteSnapshotDisplayLists::createDisplayListData(FrameIdentifier rootFrameIdentifier) const
{
    RefPtr<const DisplayList::DisplayList> displayList;
    {
        Locker locker(m_lock);
        auto iterator = m_frames.find(rootFrameIdentifier);
        if (iterator != m_frames.end() && iterator->value)
            displayList = iterator->value->displayList();
    }
    if (!displayList)
        return std::nullopt;
    return DisplayListData::create(*displayList);
}
#endif

RemoteSnapshotDisplayLists::DisplayListAndReleaseDispatcher::DisplayListAndReleaseDispatcher(Ref<const DisplayList::DisplayList>&& displayList, SerialFunctionDispatcher& dispatcher)
    : m_displayList(WTF::move(displayList))
    , m_dispatcher(dispatcher)
{
}

RemoteSnapshotDisplayLists::DisplayListAndReleaseDispatcher::~DisplayListAndReleaseDispatcher()
{
    if (m_displayList)
        m_dispatcher->dispatch([displayList = WTF::move(m_displayList)] mutable { });
}

Ref<RemoteSnapshotRecorder> RemoteSnapshotRecorder::create(RemoteSnapshotRecorderIdentifier identifier, const RemoteSnapshotIdentifier& snapshotIdentifier, RemoteRenderingBackend& renderingBackend)
{
    Ref instance = adoptRef(*new RemoteSnapshotRecorder(DisplayList::RecorderImpl::create(FloatRect { }), identifier, snapshotIdentifier, renderingBackend));
    instance->startListeningForIPC();
    return instance;
}

RemoteSnapshotRecorder::RemoteSnapshotRecorder(Ref<DisplayList::RecorderImpl>&& recorder, RemoteSnapshotRecorderIdentifier identifier, const RemoteSnapshotIdentifier& snapshotIdentifier, RemoteRenderingBackend& renderingBackend)
    : RemoteGraphicsContext(recorder, renderingBackend)
    , m_snapshotIdentifier(snapshotIdentifier)
    , m_displayLists(GPUProcess::snapshotDisplayLists(snapshotIdentifier))
    , m_recorder(WTF::move(recorder))
    , m_identifier(identifier)
{
}

RemoteSnapshotRecorder::~RemoteSnapshotRecorder() = default;

void RemoteSnapshotRecorder::startListeningForIPC()
{
    m_renderingBackend->streamConnection().startReceivingMessages(*this, Messages::RemoteGraphicsContext::messageReceiverName(), m_identifier.toUInt64());
    m_renderingBackend->streamConnection().startReceivingMessages(*this, Messages::RemoteSnapshotRecorder::messageReceiverName(), m_identifier.toUInt64());
}

void RemoteSnapshotRecorder::stopListeningForIPC()
{
    m_renderingBackend->streamConnection().stopReceivingMessages(Messages::RemoteGraphicsContext::messageReceiverName(), m_identifier.toUInt64());
    m_renderingBackend->streamConnection().stopReceivingMessages(Messages::RemoteSnapshotRecorder::messageReceiverName(), m_identifier.toUInt64());
}

void RemoteSnapshotRecorder::sinkIntoSnapshotFrame(FrameIdentifier frameIdentifier, SerialFunctionDispatcher& releaseDispatcher)
{
    // The display list is in place before the snapshot hears of it, so that the frame has it once it is resolved.
    m_displayLists->setFrame(frameIdentifier, m_recorder->takeDisplayList(), releaseDispatcher);
    GPUProcess::snapshotFrameWasRecorded(m_snapshotIdentifier, frameIdentifier, m_displayLists->token());
}

void RemoteSnapshotRecorder::drawSnapshotFrame(FrameIdentifier frameIdentifier)
{
    GPUProcess::addSnapshotFrameReference(m_snapshotIdentifier, frameIdentifier, m_displayLists->token());
    m_recorder->drawPlaceholder([weakDisplayLists = ThreadSafeWeakPtr { m_displayLists.get() }, frameIdentifier](GraphicsContext& context) {
        RefPtr displayLists = weakDisplayLists;
        if (!displayLists)
            return;
        bool result = displayLists->applyFrame(frameIdentifier, context);
        ASSERT_UNUSED(result, result); // Programming error, consistency checked with isComplete().
    });
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
