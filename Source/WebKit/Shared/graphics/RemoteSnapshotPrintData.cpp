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

#include "RemoteCGRendererMessages.h"
#include "SharedFont.h"
#include "WebKit-Swift.h"
#include <WebCore/GraphicsContextCG.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/MeshGradient.h>
#include <WebCore/NativeImage.h>
#include <WebCore/ProcessIdentity.h>
#include <wtf/Borrow.h>
#include <wtf/HashMap.h>

namespace WebKit {
using namespace WebCore;

void RemoteSnapshotPrintData::setOwnershipOfMemory(const ProcessIdentity& processIdentity) const
{
    for (auto& image : borrow(nativeImages))
        image.handle.setOwnershipOfMemory(processIdentity, MemoryLedger::Graphics);
    for (auto& imageBuffer : borrow(imageBuffers))
        imageBuffer.handle.setOwnershipOfMemory(processIdentity, MemoryLedger::Graphics);
}

// Draws a snapshot recorded in Swift for GPUProcessConnection::drawSnapshotPrintDataToPDF(): each recording is recorded
// again, with the resources the GPU process looked up for it, then its root is replayed as the GPU process replays it.
// The data can't be drawn if an identifier names two images, or an image buffer's pixels don't have its size.
bool drawRemoteSnapshotPrintData(RemoteSnapshotPrintData&& data, GraphicsContext& context, bool shouldUseLockdownFontParser)
{
    if (!context.canLendSwiftRenderer())
        return false;
    auto sharedFonts = createSharedFonts(data.customFonts, data.fonts, shouldUseLockdownFontParser);
    if (!sharedFonts)
        return false;
    auto fonts = WTF::map(WTF::move(*sharedFonts), [](auto&& font) {
        return RemoteCGRendererFont::create(font.ptr());
    });

    HashMap<RenderingResourceIdentifier, Ref<NativeImage>> nativeImages;
    for (auto& image : borrow(data.nativeImages)) {
        RefPtr nativeImage = createDisplayListDataNativeImage(WTF::move(image.handle));
        if (!nativeImage || !nativeImages.add(image.identifier, nativeImage.releaseNonNull()).isNewEntry)
            return false;
    }
    HashMap<RenderingResourceIdentifier, Ref<ImageBuffer>> imageBuffers;
    for (auto& image : borrow(data.imageBuffers)) {
        auto identifier = image.identifier;
        if (nativeImages.contains(identifier))
            return false;
        RefPtr imageBuffer = createDisplayListDataImageBuffer(WTF::move(image));
        if (!imageBuffer || !imageBuffers.add(identifier, imageBuffer.releaseNonNull()).isNewEntry)
            return false;
    }

    auto frames = RemoteCGRendererSnapshotFrames::create();
    for (auto& printRecording : data.recordings) {
        auto recordedResources = RemoteCGRendererRecordedResources::create();
        for (auto& [identifier, index] : printRecording.fonts) {
            if (index >= fonts.size())
                return false;
            recordedResources.setFont(identifier.toUInt64(), fonts[index]);
        }
        // Swift takes the gradient as a Gradient, which it only draws.
        for (auto& [identifier, gradient] : printRecording.gradients)
            recordedResources.setGradient(identifier.toUInt64(), const_cast<Gradient*>(gradient.ptr()));
        for (auto& [identifier, pathImpl] : printRecording.paths)
            recordedResources.setPath(identifier.toUInt64(), pathImpl.ptr());
        for (auto& [identifier, meshGradient] : printRecording.meshGradients)
            recordedResources.setMeshGradient(identifier.toUInt64(), meshGradient.ptr());
        for (auto [key, identifier] : printRecording.nativeImages) {
            auto iterator = nativeImages.find(identifier);
            if (iterator == nativeImages.end() || !frames.addNativeImageToNextRecording(key.toUInt64(), iterator->value.ptr()))
                return false;
        }
        for (auto [key, identifier] : printRecording.imageBuffers) {
            auto iterator = imageBuffers.find(identifier);
            if (iterator == imageBuffers.end() || !frames.addImageBufferToNextRecording(key.toUInt64(), iterator->value.ptr()))
                return false;
        }
        for (auto [key, index] : printRecording.displayLists) {
            if (!frames.addDisplayListToNextRecording(key, index))
                return false;
        }
        Ref forwarder = frames.beginRerecording(recordedResources);
        bool isValid = forwarder->didReceiveRecordedMessages(printRecording.messages.span());
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
    GraphicsContextCG::lendSwiftRendererForReplay(static_cast<GraphicsContextCG&>(context), [&](CGRendererCore& state) {
        isDrawn = frames.draw(data.rootFrameKey, state);
    });
    return isDrawn;
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
