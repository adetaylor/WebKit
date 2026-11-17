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

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

#include "DisplayListData.h"
#include "RemoteGradientIdentifier.h"
#include "RemoteMeshGradientIdentifier.h"
#include "RemotePathImplIdentifier.h"
#include <WebCore/Gradient.h>
#include <WebCore/MeshGradient.h>
#include <WebCore/NativeImage.h>
#include <WebCore/PathImpl.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <optional>
#include <wtf/Vector.h>

namespace WebCore {
class GraphicsContext;
class ProcessIdentity;
}

namespace WebKit {


// A recording of a remote snapshot's frame or of a display list it draws, for the print process to record again: its
// RemoteCGRenderer messages as the stream sends them, and the resources they name, as the GPU process looks them up. The
// fonts are indices of the snapshot's, the native images and image buffers, by key, identifiers of the snapshot's, and the
// display lists, by key, indices of earlier recordings.
struct RemoteSnapshotPrintRecording {
    Vector<uint8_t> messages;
    Vector<std::pair<WebCore::RenderingResourceIdentifier, uint64_t>> fonts;
    Vector<std::pair<RemoteGradientIdentifier, Ref<const WebCore::Gradient>>> gradients;
    Vector<std::pair<RemotePathImplIdentifier, Ref<WebCore::PathImpl>>> paths;
    Vector<std::pair<RemoteMeshGradientIdentifier, Ref<WebCore::MeshGradient>>> meshGradients;
    Vector<std::pair<WebCore::RenderingResourceIdentifier, WebCore::RenderingResourceIdentifier>> nativeImages;
    Vector<std::pair<WebCore::RenderingResourceIdentifier, WebCore::RenderingResourceIdentifier>> imageBuffers;
    Vector<std::pair<uint64_t, uint64_t>> displayLists;
};

// A remote snapshot, for the print process to draw (RemoteSnapshotPDFDrawingTask): the recordings of its frames and of the
// display lists they draw, earlier ones first, the fonts, native images and image buffers they draw, and its frames by key,
// with the index of each one's recording, or none for a frame that was abandoned.
struct RemoteSnapshotPrintData {
    Vector<WebCore::FontCustomPlatformSerializedData> customFonts;
    Vector<DisplayListDataFont> fonts;
    Vector<DisplayListDataNativeImage> nativeImages;
    Vector<DisplayListDataImageBuffer> imageBuffers;
    Vector<RemoteSnapshotPrintRecording> recordings;
    Vector<std::pair<uint64_t, std::optional<uint64_t>>> frames;
    uint64_t rootFrameKey { 0 };

    // The print process maps the images' pixels while it draws, so it is made the owner of their memory before they are sent.
    void setOwnershipOfMemory(const WebCore::ProcessIdentity&) const;
};

// For RemoteCGRendererImage (RemoteCGRendererSnapshotFrames.addNativeImageToNextRecording()), which can't read the image
// itself: its platform image, size and headroom.
inline CGImageRef _Nullable nativeImageFactsOf(const WebCore::NativeImage& image, float& width, float& height, float& headroom) CF_RETURNS_RETAINED
{
    auto size = image.size();
    width = size.width();
    height = size.height();
    headroom = image.headroom();
    return image.platformImage().leakRef();
}

// Draws a snapshot's print data into a context, in the print process, as the GPU process draws the snapshot: false if the
// data can't be drawn.
bool drawRemoteSnapshotPrintData(RemoteSnapshotPrintData&&, WebCore::GraphicsContext&, bool shouldUseLockdownFontParser);

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
