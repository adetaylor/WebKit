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
#include "RemoteSnapshotPrintData.h"

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

#include "RemoteCGRendererGlyphs.h"
#include "RemoteCGRendererMessages.h"
#include "RemoteCGRendererResources.h"
#include "SharedFont.h"
#include "WebKit-Swift.h"
#include <WebCore/GraphicsContextCG.h>
#include <WebCore/MeshGradient.h>
#include <WebCore/NativeImage.h>

namespace WebKit {
using namespace WebCore;

// DisplayListData's limits: the print process draws no mesh gradients, nor images or image buffers, which a recording keeps in
// Swift (RemoteCGRendererRecording.encodedMessages()).
bool RemoteCGRendererRecordedResources::exportForPrint(RemoteSnapshotPrintRecording& recording, DisplayListDataFonts& fonts) const
{
    if (!m_meshGradients.isEmpty())
        return false;
    if (m_firstFont)
        recording.fonts.append({ m_firstFont->key, fonts.index(m_firstFont->value->sharedFont()) });
    for (auto& [identifier, font] : m_fonts)
        recording.fonts.append({ identifier, fonts.index(font->sharedFont()) });
    for (auto& [identifier, gradient] : m_gradients)
        recording.gradients.append({ identifier, gradient });
    for (auto& [identifier, pathImpl] : m_paths)
        recording.paths.append({ identifier, pathImpl });
    return true;
}

bool RemoteCGRendererRecordedResources::importFromPrint(RemoteSnapshotPrintRecording& recording, std::span<const Ref<RemoteCGRendererFont>> fonts)
{
    for (auto& [identifier, index] : recording.fonts) {
        if (index >= fonts.size())
            return false;
        setFont(identifier, fonts[index]);
    }
    for (auto& [identifier, gradient] : recording.gradients)
        m_gradients.set(identifier, WTF::move(gradient));
    for (auto& [identifier, pathImpl] : recording.paths)
        m_paths.set(identifier, WTF::move(pathImpl));
    return true;
}

Ref<RemoteSnapshotPrintDataBuilder> RemoteSnapshotPrintDataBuilder::create(uint64_t rootFrameKey)
{
    return adoptRef(*new RemoteSnapshotPrintDataBuilder(rootFrameKey));
}

RemoteSnapshotPrintDataBuilder::RemoteSnapshotPrintDataBuilder(uint64_t rootFrameKey)
    : m_data(WTF::makeUniqueWithoutFastMallocCheck<RemoteSnapshotPrintData>())
    , m_fonts(WTF::makeUniqueWithoutFastMallocCheck<DisplayListDataFonts>())
{
    m_data->rootFrameKey = rootFrameKey;
}

RemoteSnapshotPrintDataBuilder::~RemoteSnapshotPrintDataBuilder() = default;

bool RemoteSnapshotPrintDataBuilder::addRecording(RemoteCGRendererRecordedMessageEncoder& encoder, const RemoteCGRendererRecordedResources& resources)
{
    RemoteSnapshotPrintRecording recording;
    if (!resources.exportForPrint(recording, *m_fonts))
        return false;
    recording.messages = encoder.takeEncodedMessages();
    m_data->recordings.append(WTF::move(recording));
    return true;
}

void RemoteSnapshotPrintDataBuilder::addDisplayList(uint64_t key, uint64_t index)
{
    m_data->recordings.last().displayLists.append({ key, index });
}

void RemoteSnapshotPrintDataBuilder::addFrame(uint64_t key, uint64_t index)
{
    m_data->frames.append({ key, index });
}

void RemoteSnapshotPrintDataBuilder::addAbandonedFrame(uint64_t key)
{
    m_data->frames.append({ key, std::nullopt });
}

RemoteSnapshotPrintData RemoteSnapshotPrintDataBuilder::takeData()
{
    m_data->customFonts = m_fonts->takeCustomFonts();
    m_data->fonts = m_fonts->takeFonts();
    return WTF::move(*m_data);
}

// GPUProcessConnection::drawDisplayListToPDF() for a snapshot recorded in Swift: each recording is recorded again, with the
// resources the GPU process looked up for it, then its root is replayed as the GPU process replays it.
bool drawRemoteSnapshotPrintData(RemoteSnapshotPrintData&& data, GraphicsContext& context, bool shouldUseLockdownFontParser)
{
    if (!context.canLendSwiftRenderer())
        return false;
    auto sharedFonts = createSharedFonts(data.customFonts, data.fonts, shouldUseLockdownFontParser);
    if (!sharedFonts)
        return false;
    auto fonts = WTF::map(WTF::move(*sharedFonts), [](auto&& font) {
        return RemoteCGRendererFont::create(WTF::move(font));
    });

    auto frames = RemoteCGRendererSnapshotFrames::create();
    for (auto& printRecording : data.recordings) {
        Ref recordedResources = RemoteCGRendererRecordedResources::create();
        if (!recordedResources->importFromPrint(printRecording, fonts.span()))
            return false;
        for (auto [key, index] : printRecording.displayLists) {
            if (!frames.addDisplayListToNextRecording(key, index))
                return false;
        }
        Ref resources = RemoteCGRendererResources::createForRerecording();
        Ref forwarder = frames.beginRerecording(resources.ptr());
        resources->beginReplay(recordedResources);
        bool isValid = forwarder->didReceiveRecordedMessages(printRecording.messages.span());
        resources->endReplay();
        frames.endRerecording();
        if (!isValid)
            return false;
    }

    for (auto [key, index] : data.frames) {
        if (!index) {
            frames.addAbandoned(key);
            continue;
        }
        if (!frames.addFrame(key, *index))
            return false;
    }

    bool isDrawn = false;
    replayIntoContext(static_cast<GraphicsContextCG&>(context), [&](CGRendererCore& state, RemoteCGRendererResources& resources) {
        isDrawn = frames.draw(data.rootFrameKey, state, &resources);
    });
    return isDrawn;
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
