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

#include "ImageBufferBackendHandle.h"
#include "RemoteSnapshotIdentifier.h"
#include <WebCore/FloatSize.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/ShareableBitmap.h>
#include <wtf/Function.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>

namespace WebCore {
class Gradient;
class ImageBuffer;
class MeshGradient;
class NativeImage;
class PathImpl;
class ColorSpace;
class GraphicsContext;
class SharedBuffer;
class ProcessIdentity;
}

namespace WebKit {

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
class DisplayListDataFonts;
class DisplayListDataImages;
class RemoteCGRendererRecordedMessageEncoder;
class SharedFont;
struct RemoteSnapshotPrintData;
#else
class DisplayListData;
class RemoteSnapshotDisplayLists;
#endif

// A snapshot's identifier, as the Swift registry of snapshots (RemoteSnapshot.swift) knows it.
struct RemoteSnapshotKey {
    uint64_t high { 0 };
    uint64_t low { 0 };
    uint64_t process { 0 };
};

inline RemoteSnapshotKey snapshotKey(const RemoteSnapshotIdentifier& identifier)
{
    return { identifier.object().high(), identifier.object().low(), identifier.processIdentifier().toUInt64() };
}

// What waits for a snapshot in the Swift registry (RemoteSnapshot.swift) to complete: one of the GPU process's sinks, which
// takes the snapshot and draws it, or a wait for it. Swift completes it once, from the thread that completes the snapshot,
// and it then runs its completion on the main thread, after those of the waiters added to the snapshot before it. The
// completion is given the sink, through which it draws, if the snapshot completed with its root, and null otherwise.
// m_swiftState holds the sink's Swift state, which keeps the snapshot and, once it completes, its frames.
class SWIFT_PRIVATE_FILEID("WebKit/RemoteSnapshot.swift") RemoteSnapshotSink final : public ThreadSafeRefCounted<RemoteSnapshotSink> {
public:
    using Completion = Function<void(RemoteSnapshotSink* WTF_NULLABLE)>;
    static Ref<RemoteSnapshotSink> create(const RemoteSnapshotIdentifier&, std::optional<WebCore::FrameIdentifier> rootFrameIdentifier, Completion&&) __attribute__((availability(swift, unavailable)));
    ~RemoteSnapshotSink();

    // Implemented in Swift. A sink waits for the snapshot, which it creates if it doesn't exist yet, and takes it from the
    // registry once it completes; a wait waits only for a snapshot that exists, and returns false otherwise.
    void swiftTakeSnapshotWhenComplete();
    bool swiftWaitForSnapshot();

    // For Swift.
    RemoteSnapshotKey snapshotKey() const { return m_snapshotKey; }
    bool hasRootFrame() const { return !!m_rootFrameIdentifier; }
    uint64_t rootFrameKey() const { return m_rootFrameIdentifier ? m_rootFrameIdentifier->toUInt64() : 0; }
    // Called once, by Swift, which has given the sink its frames if it succeeded: the size is the snapshot's, and, on the
    // ports that record frames as WebCore display lists, the token is its display lists' (GPUProcess::snapshotDisplayLists()).
    void complete(bool success, WebCore::FloatSize, uint64_t displayListsToken);
    // For a wait for a snapshot that doesn't exist: runs the completion now.
    void completeWithoutSnapshot() __attribute__((availability(swift, unavailable)));
    // Unsafe to set: the state must be a retained one that nothing else releases.
    uintptr_t swiftState() const { return m_swiftState; }
    SWIFT_UNSAFE void setSwiftState(uintptr_t);

    // For the completion of a sink whose snapshot completed with its root, on the main thread.
    WebCore::FloatSize size() const { return m_size; }
#ifndef __swift__
    WebCore::FrameIdentifier rootFrameIdentifier() const { return *m_rootFrameIdentifier; }
    bool drawRootFrame(WebCore::GraphicsContext&) const;
    std::optional<WebCore::ShareableBitmap::Handle> drawToBitmap() const;
#if HAVE(IOSURFACE)
    // Rasterizes into a shareable surface, so that a rendering assembled from several sites can be displayed without any of
    // them seeing the pixels.
    std::optional<ImageBufferBackendHandle> drawToIOSurface(float scale, const WebCore::ColorSpace&, const WebCore::ProcessIdentity& resourceOwner, bool useIOSurfaceWebKitBehavior) const;
#endif
#if PLATFORM(COCOA)
    std::optional<RefPtr<WebCore::SharedBuffer>> drawToPDF() const;
#endif
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    // The frames' recordings, for the print process to draw, unless it can't have one of them.
    std::optional<RemoteSnapshotPrintData> createPrintData() const;
#elif PLATFORM(COCOA)
    std::optional<DisplayListData> createDisplayListData() const;
#endif
#endif // __swift__

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { ThreadSafeRefCounted<RemoteSnapshotSink>::ref(); }
    void deref() const { ThreadSafeRefCounted<RemoteSnapshotSink>::deref(); }
#endif

private:
    RemoteSnapshotSink(const RemoteSnapshotIdentifier&, std::optional<WebCore::FrameIdentifier>, Completion&&);
    void runCompletion();

    // Implemented in Swift. The snapshot, once the sink's completion takes it, leaves the registry, unless it was released
    // and replaced there meanwhile.
    void swiftDidTakeSnapshot();
    // Unsafe: the state must be one that setSwiftState() was given, which only the destructor releases.
    SWIFT_UNSAFE static void destroySwiftState(uintptr_t);

    const RemoteSnapshotIdentifier m_snapshotIdentifier;
    const RemoteSnapshotKey m_snapshotKey;
    const std::optional<WebCore::FrameIdentifier> m_rootFrameIdentifier;
    Completion m_completion __attribute__((availability(swift, unavailable)));
    bool m_succeeded { false };
    WebCore::FloatSize m_size;
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    RefPtr<RemoteSnapshotDisplayLists> m_displayLists __attribute__((availability(swift, unavailable)));
#endif
    uintptr_t m_swiftState __attribute__((availability(swift, unavailable))) { 0 };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
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
    void addMeshGradient(uint64_t key, WebCore::MeshGradient&);
    // False where the image's pixels can't be copied for the print process.
    bool addNativeImage(uint64_t key, WebCore::NativeImage&);
    bool addImageBuffer(uint64_t key, WebCore::ImageBuffer&);
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
    const std::unique_ptr<DisplayListDataImages> m_images;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)
