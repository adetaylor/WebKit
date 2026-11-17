/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#include "RemoteDisplayListIdentifier.h"
#include "RemoteGradientIdentifier.h"
#include "RemoteMeshGradientIdentifier.h"
#include "RemotePathImplIdentifier.h"
#include <WebCore/AffineTransform.h>
#include <WebCore/CGRendererSwiftBridge.h>
#include <WebCore/Pattern.h>
#include <WebCore/Color.h>
#include <WebCore/FilterGraphicsBridge.h>
#include <WebCore/FloatRoundedRect.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/GraphicsTypes.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <wtf/Function.h>
#include <wtf/HashMap.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/Vector.h>

typedef struct CF_BRIDGED_TYPE(id) __CVBuffer* CVPixelBufferRef;

namespace WebCore {
class CGRendererCore;
class Gradient;
class GraphicsContextCG;
class ImageBuffer;
class MeshGradient;
class NativeImage;
class PathImpl;
}

namespace WebKit {

class DisplayListDataFonts;
class RemoteCGRendererFont;
class RemoteCGRendererRecordedGlyphs;
class RemoteCGRendererRecordedMessageEncoder;
class RemoteRenderingBackend;
class SharedFont;
struct RemoteSnapshotPrintData;
struct RemoteSnapshotPrintRecording;
struct SharedVideoFrame;

// The resources that a recording's messages name (RemoteCGRendererRecording.swift), which it keeps from when it records them,
// as a WebCore display list keeps what it records. Read only once recorded, on whichever thread replays the recording.
class RemoteCGRendererRecordedResources final : public ThreadSafeRefCounted<RemoteCGRendererRecordedResources> {
public:
    static Ref<RemoteCGRendererRecordedResources> create();
    ~RemoteCGRendererRecordedResources();

    Ref<RemoteCGRendererRecordedResources> copy() const __attribute__((availability(swift, unavailable)));

    // The resources, for the print process (RemoteSnapshotPrintData): false where it can't have one, such as an image.
    bool exportForPrint(RemoteSnapshotPrintRecording&, DisplayListDataFonts&) const __attribute__((availability(swift, unavailable)));
    // The resources that the print process takes from that, with the fonts it made of the snapshot's.
    bool importFromPrint(RemoteSnapshotPrintRecording&, std::span<const Ref<RemoteCGRendererFont>>) __attribute__((availability(swift, unavailable)));

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { ThreadSafeRefCounted<RemoteCGRendererRecordedResources>::ref(); }
    void deref() const { ThreadSafeRefCounted<RemoteCGRendererRecordedResources>::deref(); }
#endif

private:
    friend class RemoteCGRendererResources;
    RemoteCGRendererRecordedResources();

    HashMap<RemotePathImplIdentifier, Ref<WebCore::PathImpl>> m_paths;
    HashMap<RemoteGradientIdentifier, Ref<WebCore::Gradient>> m_gradients;
    // The fonts, by identifier: the first that the recording kept, which is most often the only one, and the others.
    RefPtr<RemoteCGRendererFont> font(WebCore::RenderingResourceIdentifier) const __attribute__((availability(swift, unavailable)));
    Ref<RemoteCGRendererFont> addFont(WebCore::RenderingResourceIdentifier, Ref<RemoteCGRendererFont>&&) __attribute__((availability(swift, unavailable)));
    void setFont(WebCore::RenderingResourceIdentifier, const Ref<RemoteCGRendererFont>&) __attribute__((availability(swift, unavailable)));
    std::optional<KeyValuePair<WebCore::RenderingResourceIdentifier, Ref<RemoteCGRendererFont>>> m_firstFont;
    HashMap<WebCore::RenderingResourceIdentifier, Ref<RemoteCGRendererFont>> m_fonts;
    HashMap<RemoteMeshGradientIdentifier, Ref<WebCore::MeshGradient>> m_meshGradients;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// What a RemoteCGRenderer looks up by identifier, as RemoteGraphicsContext's handlers do, and what it draws into:
// - an image buffer's receiver's: its rendering backend's resource cache and image buffers, and the buffer;
// - a recorder's: the backend's, which it copies into its recording's resources as it records each message;
// - a replay's into a context: only the resources of the recordings it replays;
// - the print process's recorder's, which records a snapshot's recordings again: those that the GPU process sent with each.
// While a recording is replayed (beginReplay()), its resources are the ones looked up.
class RemoteCGRendererResources final : public RefCounted<RemoteCGRendererResources> {
public:
    static Ref<RemoteCGRendererResources> create(RemoteRenderingBackend& backend, WebCore::ImageBuffer& target) { return adoptRef(*new RemoteCGRendererResources(&backend, &target, nullptr)); }
    static Ref<RemoteCGRendererResources> createForRecorder(RemoteRenderingBackend& backend) { return adoptRef(*new RemoteCGRendererResources(&backend, nullptr, nullptr)); }
    static Ref<RemoteCGRendererResources> createForReplay(WebCore::GraphicsContextCG& target) { return adoptRef(*new RemoteCGRendererResources(nullptr, nullptr, &target)); }
    static Ref<RemoteCGRendererResources> createForRerecording();
    ~RemoteCGRendererResources();

    // The native image that a filter's FEImage names: the backend's, or, in a replay, the one the recording kept for the filter.
    // The image buffer that the receiver draws into, if it draws into one, and the context it draws into otherwise.
    WebCore::ImageBuffer* targetImageBuffer() const { return m_target.get(); }
    WebCore::GraphicsContextCG& targetContext() const __attribute__((availability(swift, unavailable)));
    RefPtr<WebCore::Gradient> cachedGradient(RemoteGradientIdentifier) const;
    RefPtr<RemoteCGRendererFont> cachedFont(WebCore::RenderingResourceIdentifier) const __attribute__((availability(swift, unavailable)));
    RefPtr<WebCore::PathImpl> cachedPathImpl(RemotePathImplIdentifier) const __attribute__((availability(swift, unavailable)));
    RefPtr<WebCore::MeshGradient> cachedMeshGradient(RemoteMeshGradientIdentifier) const __attribute__((availability(swift, unavailable)));
    // The copy of the target that the receiver draws an accelerated target into itself from (copyImageBufferImage()), which
    // the receiver lets go after the draw.
    void releaseSelfCopy() const { m_selfCopy = nullptr; }
    void setSelfCopy(RefPtr<WebCore::ImageBuffer>&& selfCopy) const { m_selfCopy = WTF::move(selfCopy); }

    // Makes the recording's resources the ones looked up, until the matching endReplay(). Replays nest.
    void beginReplay(RemoteCGRendererRecordedResources&) const;
    void endReplay() const;
    bool isReplaying() const { return !m_replayedResources.isEmpty(); }

    // The resources that a recorder's message names, copied into its recording's as RemoteGraphicsContext looks them up for a
    // WebCore display list recorder: false where one is missing, which is an invalid message. The recording keeps the native
    // images and image buffers that its draws name, and its filters, in Swift (RemoteCGRendererRecording).
    bool recordPath(RemotePathImplIdentifier) const;
    bool recordGradient(RemoteGradientIdentifier) const;
    // A DrawGlyphs's font, which the recorded run keeps, with its facts for the run.
    bool recordGlyphs(WebCore::RenderingResourceIdentifier fontIdentifier, const RemoteCGRendererRecordedGlyphs&) const;
    bool recordMeshGradient(RemoteMeshGradientIdentifier) const;
    // The recorder's recording's resources, which it hands to its recording (takeRecordedResources()).
    Ref<RemoteCGRendererRecordedResources> takeRecordedResources() const __attribute__((availability(swift, unavailable)));
    Ref<RemoteCGRendererRecordedResources> copyRecordedResources() const __attribute__((availability(swift, unavailable))) { return m_recordedResources->copy(); }

    RemoteRenderingBackend* backend() const __attribute__((availability(swift, unavailable))) { return m_backend.get(); }

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { RefCounted<RemoteCGRendererResources>::ref(); }
    void deref() const { RefCounted<RemoteCGRendererResources>::deref(); }
#endif

private:
    RemoteCGRendererResources(RemoteRenderingBackend*, WebCore::ImageBuffer* target, WebCore::GraphicsContextCG* targetContext);

    const RefPtr<RemoteRenderingBackend> m_backend;
    const RefPtr<WebCore::ImageBuffer> m_target;
    // A replay's context, which outlives the replay, the only time it is used.
    WebCore::GraphicsContextCG* const m_targetContext;
    mutable Ref<RemoteCGRendererRecordedResources> m_recordedResources;
    mutable Vector<Ref<RemoteCGRendererRecordedResources>, 2> m_replayedResources;
    mutable RefPtr<WebCore::ImageBuffer> m_selfCopy;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// Collects a snapshot's recordings into print data, as Swift walks them (RemoteCGRendererSnapshotFrames.encode(to:)).
class RemoteSnapshotPrintDataBuilder final : public RefCounted<RemoteSnapshotPrintDataBuilder> {
public:
    static Ref<RemoteSnapshotPrintDataBuilder> create(uint64_t rootFrameKey);
    ~RemoteSnapshotPrintDataBuilder();

    // A recording, with its messages encoded, and its resources: false where the print process can't have one of them.
    bool addRecording(RemoteCGRendererRecordedMessageEncoder&, const RemoteCGRendererRecordedResources&);
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

// The recorder's recording's resources, for its recording, and a copy of them, for a recording of what it recorded so far.
RemoteCGRendererRecordedResources* WTF_NONNULL takeRecordedResources(const RemoteCGRendererResources&) SWIFT_RETURNS_RETAINED;
RemoteCGRendererRecordedResources* WTF_NONNULL copyRecordedResources(const RemoteCGRendererResources&) SWIFT_RETURNS_RETAINED;

// A display list recorder's resources (createForRecorder()), for Swift.
inline RemoteCGRendererResources* WTF_NONNULL createDisplayListRecorderResources(RemoteRenderingBackend& backend) SWIFT_RETURNS_RETAINED
{
    return &RemoteCGRendererResources::createForRecorder(backend).leakRef();
}

// Lends the context's renderer to Swift for the draw, which replays a recording into it with the resources.
void replayIntoContext(WebCore::GraphicsContextCG&, NOESCAPE const Function<void(WebCore::CGRendererCore&, RemoteCGRendererResources&)>&) __attribute__((availability(swift, unavailable)));

// The keys by which Swift finds the recording of a display list or a snapshot's frame.
inline uint64_t displayListKey(RemoteDisplayListIdentifier identifier)
{
    return identifier.toUInt64();
}

inline uint64_t frameKey(WebCore::FrameIdentifier identifier)
{
    return identifier.toUInt64();
}

// The allocator of the images of the filters that a RemoteCGRenderer applies (RemoteCGRendererFilters.swift): the backend's
// shared resource cache's, as RemoteGraphicsContext's, or for a replay or a renderer without a backend, the default one.
WebCore::FilterImageAllocator* WTF_NONNULL createFilterImageAllocator(const RemoteCGRendererResources&, bool forReplay) SWIFT_RETURNS_RETAINED;

#if PLATFORM(COCOA) && ENABLE(VIDEO)
// The image of a DrawVideoFrame's frame, whose pixel buffer SharedVideoFrameSource read, as RemoteGraphicsContext makes it
// (VideoFrame::copyNativeImage()), with its size and whether it has alpha; null for a frame it can't make one of.
CGImageRef _Nullable copyVideoFrameImage(CVPixelBufferRef _Nonnull, const SharedVideoFrame&, CGRendererImageFacts&, bool& hasAlpha) CF_RETURNS_RETAINED;
#endif

// The brush of a SetFillCachedGradient, a SetFillPatternNativeImage or a SetFillPatternImageBuffer, or of their stroke
// counterparts, as RemoteGraphicsContext's handlers make it: found is false for a missing resource, and drawsIntoTarget true
// for a pattern of the image buffer the receiver draws into. Swift finds the native image.
CGRendererBrushSource cachedGradientBrush(const RemoteCGRendererResources&, RemoteGradientIdentifier, const WebCore::AffineTransform& spaceTransform, bool& found);
CGRendererBrushSource nativeImagePatternBrush(WebCore::NativeImage&, const WebCore::PatternParameters&);
CGRendererBrushSource imageBufferPatternBrush(const RemoteCGRendererResources&, WebCore::ImageBuffer* _Nullable tileImageBuffer, const WebCore::PatternParameters&, bool& found, bool& drawsIntoTarget);

// The image of a DrawMeshGradient, which MeshGradientRenderer renders for the context's device transform and color space at the
// destination's size in pixels, which the facts give, and the options GraphicsContext draws it with: found is false for a
// missing gradient, and the image is null where nothing is drawn.
CGImageRef _Nullable copyMeshGradientImage(const RemoteCGRendererResources&, RemoteMeshGradientIdentifier, CGAffineTransform deviceTransform, const CGRendererDestinationColorSpace&, CGSize destinationSize, CGRendererImageFacts&, CGRendererImageOptions&) CF_RETURNS_RETAINED;

// The CGPath of a cached path (Path::platformPath()): the backend's, or, in a replay, the one the recording kept. Null for a
// missing path, which is an invalid message. Unsafe in Swift, which shares it with the cache: only CGRendererPlatformPath may
// hold it.
SWIFT_UNSAFE CGPathRef _Nullable copyCachedPlatformPath(const RemoteCGRendererResources&, RemotePathImplIdentifier) CF_RETURNS_RETAINED;

// The CFURL of a SetURLForRect's link, as GraphicsContextCG::setURLForRect() makes it.
CFURLRef _Nullable copyURL(const URL&) CF_RETURNS_RETAINED;

inline WebCore::FloatRect rectOfRoundedRect(WebCore::FloatRoundedRect rect)
{
    return rect.rect();
}

inline uint8_t textDrawingModeValue(WebCore::TextDrawingModeFlags mode)
{
    return mode.toRaw();
}

// GraphicsContextCG::drawNativeImage()'s color matrix for a draw that inverts a native image for an accessibility color mode,
// in the facts, which Swift asks for only for draws whose options invert their image.
inline void setInvertColorMatrix(const WebCore::NativeImage& image, const WebCore::FloatRect& sourceRect, WebCore::RasterDrawingOptions options, CGRendererImageFacts& facts)
{
    CGRendererSetInvertColorMatrix(image, sourceRect, options, facts);
}

// The image of an image buffer, which the receiver looks up, as GraphicsContext draws one (nativeImageForDrawing()), with the
// color matrix that inverts it where the options do; a null image buffer isn't found. An accelerated target drawn into
// itself is drawn from a flushed copy of itself (clonesAcceleratedTarget), which the facts say. A function, since Swift takes
// what a C++ method returns as unretained whatever its annotation.
CGImageRef _Nullable copyImageBufferImage(const RemoteCGRendererResources&, WebCore::ImageBuffer* _Nullable, const WebCore::FloatRect& sourceRect, WebCore::RasterDrawingOptions, bool clonesAcceleratedTarget, CGRendererImageFacts&) CF_RETURNS_RETAINED;

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
