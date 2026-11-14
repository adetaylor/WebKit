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
#include "RemoteSnapshotSink.h"

#include "WebImage.h"
#include <wtf/RunLoop.h>

#if PLATFORM(COCOA)
#include <WebCore/PDFDocumentBuffer.h>
#endif

#if HAVE(IOSURFACE)
#include "ImageBufferShareableMappedIOSurfaceBackend.h"
#endif

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "RemoteCGRendererResources.h"
#include "RemoteSnapshotPrintData.h"
#include "WebKit-Swift.h"
#include <WebCore/GraphicsContextCG.h>
#else
#include "DisplayListData.h"
#include "GPUProcess.h"
#include "RemoteSnapshotRecorder.h"
#endif

namespace WebKit {
using namespace WebCore;

Ref<RemoteSnapshotSink> RemoteSnapshotSink::create(const RemoteSnapshotIdentifier& snapshotIdentifier, std::optional<FrameIdentifier> rootFrameIdentifier, Completion&& completion)
{
    return adoptRef(*new RemoteSnapshotSink(snapshotIdentifier, rootFrameIdentifier, WTF::move(completion)));
}

RemoteSnapshotSink::RemoteSnapshotSink(const RemoteSnapshotIdentifier& snapshotIdentifier, std::optional<FrameIdentifier> rootFrameIdentifier, Completion&& completion)
    : m_snapshotIdentifier(snapshotIdentifier)
    , m_snapshotKey(WebKit::snapshotKey(snapshotIdentifier))
    , m_rootFrameIdentifier(rootFrameIdentifier)
    , m_completion(WTF::move(completion))
{
}

RemoteSnapshotSink::~RemoteSnapshotSink()
{
    if (m_swiftState)
        destroySwiftState(std::exchange(m_swiftState, 0));
}

void RemoteSnapshotSink::setSwiftState(uintptr_t state)
{
    RELEASE_ASSERT(!m_swiftState);
    m_swiftState = state;
}

void RemoteSnapshotSink::complete(bool success, FloatSize size, uint64_t displayListsToken)
{
    m_succeeded = success && m_rootFrameIdentifier;
    m_size = size;
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    if (m_succeeded)
        m_displayLists = GPUProcess::snapshotDisplayLists(m_snapshotIdentifier, displayListsToken);
#else
    UNUSED_PARAM(displayListsToken);
#endif
    // Swift completes the snapshot's sinks in order, on the thread that completes it, so dispatching even from the main
    // thread keeps them in that order.
    RunLoop::mainSingleton().dispatch([protectedThis = Ref { *this }] {
        protectedThis->runCompletion();
    });
}

void RemoteSnapshotSink::completeWithoutSnapshot()
{
    if (auto completion = std::exchange(m_completion, nullptr))
        completion(nullptr);
}

void RemoteSnapshotSink::runCompletion()
{
    ASSERT(RunLoop::isMain());
    swiftDidTakeSnapshot();
    if (auto completion = std::exchange(m_completion, nullptr))
        completion(m_succeeded ? this : nullptr);
}

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

// Replays the root frame's recording in Swift, and those of the frames it draws, into a context that lends its renderer for it.
bool RemoteSnapshotSink::drawRootFrame(GraphicsContext& context) const
{
    ASSERT(m_succeeded);
    if (!context.canLendSwiftRenderer()) {
        ASSERT_NOT_REACHED();
        return false;
    }
    auto frames = RemoteCGRendererSnapshotFrames::forSink(const_cast<RemoteSnapshotSink*>(this));
    bool isDrawn = false;
    replayIntoContext(static_cast<GraphicsContextCG&>(context), [&](CGRendererCore& state, RemoteCGRendererResources& resources) {
        isDrawn = frames.draw(frameKey(rootFrameIdentifier()), state, &resources);
    });
    return isDrawn;
}

std::optional<RemoteSnapshotPrintData> RemoteSnapshotSink::createPrintData() const
{
    ASSERT(m_succeeded);
    Ref builder = RemoteSnapshotPrintDataBuilder::create(frameKey(rootFrameIdentifier()));
    if (!RemoteCGRendererSnapshotFrames::forSink(const_cast<RemoteSnapshotSink*>(this)).encode(builder.ptr()))
        return std::nullopt;
    return builder->takeData();
}

#else

bool RemoteSnapshotSink::drawRootFrame(GraphicsContext& context) const
{
    ASSERT(m_succeeded);
    return m_displayLists->applyFrame(rootFrameIdentifier(), context);
}

#if PLATFORM(COCOA)
std::optional<DisplayListData> RemoteSnapshotSink::createDisplayListData() const
{
    ASSERT(m_succeeded);
    return m_displayLists->createDisplayListData(rootFrameIdentifier());
}
#endif

#endif

#if PLATFORM(COCOA)

std::optional<RefPtr<SharedBuffer>> RemoteSnapshotSink::drawToPDF() const
{
    auto buffer = PDFDocumentBuffer::create(m_size);
    if (!buffer)
        return nullptr;

    if (!drawRootFrame(buffer->context()))
        return std::nullopt;

    return buffer->takeData();
}

#endif

std::optional<ShareableBitmap::Handle> RemoteSnapshotSink::drawToBitmap() const
{
    Ref image = WebImage::create(m_size, ImageOption::Shareable, ColorSpace::SRGB());
    auto* context = image->context();
    if (!context)
        return std::nullopt;

    if (!drawRootFrame(*context))
        return std::nullopt;

    return image->createHandle(SharedMemory::Protection::ReadOnly);
}

#if HAVE(IOSURFACE)

std::optional<ImageBufferBackendHandle> RemoteSnapshotSink::drawToIOSurface(float scale, const ColorSpace& colorSpace, const ProcessIdentity& resourceOwner, bool useIOSurfaceWebKitBehavior) const
{
    ImageBufferCreationContext creationContext;
    creationContext.resourceOwner = resourceOwner;
    creationContext.useIOSurfaceWebKitBehavior = useIOSurfaceWebKitBehavior;
    RefPtr buffer = ImageBuffer::create<ImageBufferShareableMappedIOSurfaceBackend>(m_size, scale, colorSpace, ImageBufferFormat { PixelFormat::BGRA8 }, RenderingPurpose::Snapshot, creationContext);
    if (!buffer)
        return std::nullopt;

    if (!drawRootFrame(buffer->context()))
        return std::nullopt;

    buffer->flushDrawingContext();

    auto* surface = buffer->surface();
    if (!surface)
        return std::nullopt;

    return ImageBufferBackendHandle { surface->createSendRight() };
}

#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)
