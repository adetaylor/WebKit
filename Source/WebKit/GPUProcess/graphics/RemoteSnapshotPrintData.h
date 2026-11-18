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
#include "RemotePathImplIdentifier.h"
#include <WebCore/Gradient.h>
#include <WebCore/PathImpl.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <optional>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Vector.h>

namespace WebCore {
class GraphicsContext;
}

namespace WebKit {

class SharedFont;
class RemoteCGRendererRecordedMessageEncoder;

// A recording of a remote snapshot's frame or of a display list it draws, for the print process to record again: its
// RemoteCGRenderer messages as the stream sends them, and the resources they name, as the GPU process looks them up. The
// fonts are indices of the snapshot's, and the display lists, by key, indices of earlier recordings.
struct RemoteSnapshotPrintRecording {
    Vector<uint8_t> messages;
    Vector<std::pair<WebCore::RenderingResourceIdentifier, uint64_t>> fonts;
    Vector<std::pair<RemoteGradientIdentifier, Ref<WebCore::Gradient>>> gradients;
    Vector<std::pair<RemotePathImplIdentifier, Ref<WebCore::PathImpl>>> paths;
    Vector<std::pair<uint64_t, uint64_t>> displayLists;
};

// A remote snapshot, for the print process to draw (RemoteSnapshotPDFDrawingTask): the recordings of its frames and of the
// display lists they draw, earlier ones first, the fonts they draw with, and its frames by key, with the index of each one's
// recording, or none for a frame that was abandoned.
struct RemoteSnapshotPrintData {
    Vector<WebCore::FontCustomPlatformSerializedData> customFonts;
    Vector<DisplayListDataFont> fonts;
    Vector<RemoteSnapshotPrintRecording> recordings;
    Vector<std::pair<uint64_t, std::optional<uint64_t>>> frames;
    uint64_t rootFrameKey { 0 };
};

// Collects a snapshot's recordings into print data, as Swift walks them (RemoteCGRendererSnapshotFrames.encode(to:)).
class RemoteSnapshotPrintDataBuilder final : public RefCounted<RemoteSnapshotPrintDataBuilder> {
public:
    static Ref<RemoteSnapshotPrintDataBuilder> create(uint64_t rootFrameKey);
    ~RemoteSnapshotPrintDataBuilder();

    // A recording, with its messages encoded, and the resources they name, which go with the recording added last.
    void addRecording(RemoteCGRendererRecordedMessageEncoder&);
    void addFont(uint64_t key, SharedFont&);
    void addGradient(uint64_t key, WebCore::Gradient&);
    void addPath(uint64_t key, WebCore::PathImpl&);
    // A display list that the recording added last draws, by key: the recording at the index.
    void addDisplayList(uint64_t key, uint64_t index);
    void addFrame(uint64_t key, uint64_t index);
    void addAbandonedFrame(uint64_t key);
    RemoteSnapshotPrintData takeData() __attribute__((availability(swift, unavailable)));

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { RefCounted<RemoteSnapshotPrintDataBuilder>::ref(); }
    void deref() const { RefCounted<RemoteSnapshotPrintDataBuilder>::deref(); }
#endif

private:
    explicit RemoteSnapshotPrintDataBuilder(uint64_t rootFrameKey);

    const std::unique_ptr<RemoteSnapshotPrintData> m_data;
    const std::unique_ptr<DisplayListDataFonts> m_fonts;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// Draws a snapshot's print data into a context, in the print process, as the GPU process draws the snapshot: false if the
// data can't be drawn.
bool drawRemoteSnapshotPrintData(RemoteSnapshotPrintData&&, WebCore::GraphicsContext&, bool shouldUseLockdownFontParser);

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
