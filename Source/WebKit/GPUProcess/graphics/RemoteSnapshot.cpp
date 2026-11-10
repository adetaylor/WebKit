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

#if ENABLE(GPU_PROCESS)
#include "RemoteSnapshot.h"

#include "DisplayListData.h"
#include "WebImage.h"
#include <wtf/Borrow.h>
#include <wtf/RunLoop.h>
#include <wtf/TZoneMallocInlines.h>

#if PLATFORM(COCOA)
#include <WebCore/PDFDocumentBuffer.h>
#endif

#if HAVE(IOSURFACE)
#include "ImageBufferShareableMappedIOSurfaceBackend.h"
#endif

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "RemoteCGRendererResources.h"
#include "WebKit-Swift.h"
#include <WebCore/GraphicsContextCG.h>
#endif

namespace WebKit {
using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteSnapshot);

Ref<RemoteSnapshot> RemoteSnapshot::create(std::optional<FrameIdentifier> rootFrameIdentifier)
{
    return adoptRef(*new RemoteSnapshot(rootFrameIdentifier));
}

RemoteSnapshot::RemoteSnapshot(std::optional<FrameIdentifier> rootFrameIdentifier)
    : m_rootFrameIdentifier(rootFrameIdentifier)
{
    if (!rootFrameIdentifier)
        return;
    Locker locker(m_lock);
    m_frames.add(*rootFrameIdentifier, Frame { });
    m_unresolvedFrames = 1;
}

RemoteSnapshot::~RemoteSnapshot() = default;

void RemoteSnapshot::addFrameReference(FrameIdentifier frameIdentifier)
{
    Locker locker(m_lock);
    // A frame painted more than once is referenced more than once, and is still only recorded once.
    // It is ok for setFrame or abandonFrame to win the race.
    if (m_frames.add(frameIdentifier, Frame { }).isNewEntry)
        m_unresolvedFrames++;
}

void RemoteSnapshot::resolveFrameWithLockHeld(Frame& frame)
{
    ASSERT(frame.isResolved());
    ASSERT(m_unresolvedFrames);
    m_unresolvedFrames--;
    dispatchCompletionHandlersIfComplete();
}

void RemoteSnapshot::setFrame(FrameIdentifier frameIdentifier, Recording&& recording, SerialFunctionDispatcher& releaseDispatcher)
{
    Locker locker(m_lock);
    auto result = m_frames.add(frameIdentifier, Frame { });
    auto& frame = result.iterator->value;
    if (result.isNewEntry) {
        // Came in before it was referenced, so it was never counted as unresolved.
        frame.recording = RecordingAndReleaseDispatcher { WTF::move(recording), releaseDispatcher };
        return;
    }
    // Abandoned because the process recording it went away after recording it. Either outcome is fine.
    if (frame.isAbandoned)
        return;
    // It is ok to addFrameReference to win the race. A frame is only asked to record once, so another
    // recording is dropped rather than replacing the first.
    if (frame.recording)
        return;
    frame.recording = RecordingAndReleaseDispatcher { WTF::move(recording), releaseDispatcher };
    resolveFrameWithLockHeld(frame);
}

void RemoteSnapshot::abandonFrame(FrameIdentifier frameIdentifier)
{
    Locker locker(m_lock);
    auto result = m_frames.add(frameIdentifier, Frame { .recording = std::nullopt, .isAbandoned = true });
    if (result.isNewEntry)
        return;
    auto& frame = result.iterator->value;
    if (frame.isResolved())
        return;
    frame.isAbandoned = true;
    resolveFrameWithLockHeld(frame);
}

void RemoteSnapshot::setFrameOwner(FrameIdentifier frameIdentifier, ProcessIdentifier processIdentifier)
{
    Locker locker(m_lock);
    m_frameOwners.set(frameIdentifier, processIdentifier);
}

void RemoteSnapshot::abandonFramesOwnedBy(ProcessIdentifier processIdentifier)
{
    Vector<FrameIdentifier> frames;
    {
        Locker locker(m_lock);
        m_frameOwners.removeIf([&](auto& entry) {
            if (entry.value != processIdentifier)
                return false;
            frames.append(entry.key);
            return true;
        });
    }
    for (auto frameIdentifier : frames)
        abandonFrame(frameIdentifier);
}

void RemoteSnapshot::abandonUnresolvedFrames()
{
    Vector<FrameIdentifier> frames;
    {
        Locker locker(m_lock);
        for (auto& [frameIdentifier, frame] : m_frames) {
            if (!frame.isResolved())
                frames.append(frameIdentifier);
        }
    }
    for (auto frameIdentifier : frames)
        abandonFrame(frameIdentifier);
}

FloatSize RemoteSnapshot::size() const
{
    Locker locker(m_lock);
    return m_size;
}

void RemoteSnapshot::setSize(const FloatSize& size)
{
    Locker locker(m_lock);
    m_size = size;
}

bool RemoteSnapshot::hasFailed() const
{
    Locker locker(m_lock);
    return hasFailedWithLockHeld();
}

bool RemoteSnapshot::hasFailedWithLockHeld() const
{
    if (m_hasFailed)
        return true;
    if (!m_rootFrameIdentifier)
        return false;
    auto iterator = m_frames.find(*m_rootFrameIdentifier);
    return iterator == m_frames.end() || iterator->value.isAbandoned;
}

void RemoteSnapshot::fail()
{
    Locker locker(m_lock);
    m_hasFailed = true;
    dispatchCompletionHandlersIfComplete();
}

bool RemoteSnapshot::isComplete() const
{
    Locker locker(m_lock);
    return isCompleteWithLockHeld();
}

void RemoteSnapshot::whenComplete(CompletionHandler<void(bool)>&& completionHandler)
{
    ASSERT(RunLoop::isMain());
    Locker locker(m_lock);
    m_completionHandlers.append(WTF::move(completionHandler));
    dispatchCompletionHandlersIfComplete();
}

bool RemoteSnapshot::isAwaited() const
{
    Locker locker(m_lock);
    return !m_completionHandlers.isEmpty();
}

void RemoteSnapshot::dispatchCompletionHandlersIfComplete()
{
    if (!isCompleteWithLockHeld() || m_completionHandlers.isEmpty())
        return;
    // Frames are resolved on the rendering backends' work queues. Dispatching even from the main thread keeps
    // the handlers in the order they were added.
    RunLoop::mainSingleton().dispatch([completionHandlers = std::exchange(m_completionHandlers, { }), success = !hasFailedWithLockHeld()] mutable {
        for (auto& completionHandler : borrow(completionHandlers))
            completionHandler(success);
    });
}

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

RemoteCGRendererSnapshotFrames RemoteSnapshot::snapshotFrames() const
{
    auto frames = RemoteCGRendererSnapshotFrames::create();
    Locker locker(m_lock);
    for (auto& [identifier, frame] : m_frames) {
        if (frame.isAbandoned)
            frames.addAbandoned(frameKey(identifier));
        else if (frame.recording)
            frames.add(*frame.recording->recording(), frameKey(identifier));
    }
    return frames;
}

// Replays the frame's recording in Swift, and those of the frames it draws, into a context that lends its renderer for it.
bool RemoteSnapshot::applyFrame(FrameIdentifier frameIdentifier, GraphicsContext& context) const
{
    if (!context.canLendSwiftRenderer()) {
        ASSERT_NOT_REACHED();
        return false;
    }
    auto frames = snapshotFrames();
    bool isDrawn = false;
    replayIntoContext(static_cast<GraphicsContextCG&>(context), [&](CGRendererCore& state, RemoteCGRendererResources& resources) {
        isDrawn = frames.draw(frameKey(frameIdentifier), state, &resources);
    });
    return isDrawn;
}

#else

bool RemoteSnapshot::applyFrame(FrameIdentifier frameIdentifier, GraphicsContext& context) const
{
    RefPtr<const DisplayList::DisplayList> displayList;
    {
        Locker locker(m_lock);
        auto iterator = m_frames.find(frameIdentifier);
        if (iterator == m_frames.end())
            return false;
        if (iterator->value.isAbandoned)
            return true;
        if (iterator->value.recording)
            displayList = iterator->value.recording->recording();
    }
    if (!displayList)
        return false;
    context.drawDisplayList(*displayList);
    return true;
}

#endif

RemoteSnapshot::RecordingAndReleaseDispatcher::RecordingAndReleaseDispatcher(Recording&& recording, SerialFunctionDispatcher& dispatcher)
    : m_recording(WTF::move(recording))
    , m_dispatcher(dispatcher)
{
}

RemoteSnapshot::RecordingAndReleaseDispatcher::~RecordingAndReleaseDispatcher()
{
    if (m_recording)
        m_dispatcher->dispatch([recording = WTF::move(m_recording)]() mutable { });
}

#if PLATFORM(COCOA)

std::optional<RefPtr<SharedBuffer>> RemoteSnapshot::drawToPDF(const FloatSize& size, FrameIdentifier rootIdentifier)
{
    ASSERT(isComplete());
    auto buffer = PDFDocumentBuffer::create(size);
    if (!buffer)
        return nullptr;

    if (!applyFrame(rootIdentifier, buffer->context()))
        return std::nullopt;

    return buffer->takeData();
}

#endif

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
std::optional<RemoteSnapshotPrintData> RemoteSnapshot::createPrintData(FrameIdentifier rootFrameIdentifier) const
{
    ASSERT(isComplete());
    Ref builder = RemoteSnapshotPrintDataBuilder::create(frameKey(rootFrameIdentifier));
    if (!snapshotFrames().encode(builder.ptr()))
        return std::nullopt;
    return builder->takeData();
}
#else
std::optional<DisplayListData> RemoteSnapshot::createDisplayListData(FrameIdentifier rootFrameIdentifier) const
{
    ASSERT(isComplete());
    RefPtr<const DisplayList::DisplayList> displayList;
    {
        Locker locker(m_lock);
        auto iterator = m_frames.find(rootFrameIdentifier);
        if (iterator != m_frames.end() && iterator->value.recording)
            displayList = iterator->value.recording->recording();
    }
    if (!displayList)
        return std::nullopt;
    return DisplayListData::create(*displayList);
}
#endif

std::optional<ShareableBitmap::Handle> RemoteSnapshot::drawToBitmap(const FloatSize& size, FrameIdentifier rootFrameIdentifier)
{
    ASSERT(isComplete());
    Ref image = WebImage::create(size, ImageOption::Shareable, ColorSpace::SRGB());
    auto* context = image->context();
    if (!context)
        return std::nullopt;

    if (!applyFrame(rootFrameIdentifier, *context))
        return std::nullopt;

    return image->createHandle(SharedMemory::Protection::ReadOnly);
}

#if HAVE(IOSURFACE)

std::optional<ImageBufferBackendHandle> RemoteSnapshot::drawToIOSurface(const FloatSize& size, float scale, const ColorSpace& colorSpace, FrameIdentifier rootFrameIdentifier, const ProcessIdentity& resourceOwner, bool useIOSurfaceWebKitBehavior)
{
    ASSERT(isComplete());
    ImageBufferCreationContext creationContext;
    creationContext.resourceOwner = resourceOwner;
    creationContext.useIOSurfaceWebKitBehavior = useIOSurfaceWebKitBehavior;
    RefPtr buffer = ImageBuffer::create<ImageBufferShareableMappedIOSurfaceBackend>(size, scale, colorSpace, ImageBufferFormat { PixelFormat::BGRA8 }, RenderingPurpose::Snapshot, creationContext);
    if (!buffer)
        return std::nullopt;

    if (!applyFrame(rootFrameIdentifier, buffer->context()))
        return std::nullopt;

    buffer->flushDrawingContext();

    auto* surface = buffer->surface();
    if (!surface)
        return std::nullopt;

    return ImageBufferBackendHandle { surface->createSendRight() };
}

#endif

}

#endif
