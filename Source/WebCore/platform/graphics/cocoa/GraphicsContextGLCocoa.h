/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(WEBGL)

#include <WebCore/GraphicsContextGLANGLE.h>
#include <WebCore/IOSurface.h>
#include <WebCore/ProcessIdentity.h>
#include <memory>
#include <wtf/CheckedPtr.h>

#if ENABLE(WEBXR)
#include <WebCore/PlatformXR.h>
#include <wtf/EnumeratedArray.h>
#endif

OBJC_CLASS MTLSharedEventListener;
#if ENABLE(WEBXR)
OBJC_PROTOCOL(MTLRasterizationRateMap);
#endif

namespace WebCore {

class GraphicsLayerContentsDisplayDelegate;

#if ENABLE(VIDEO)
class GraphicsContextGLCVCocoa;
#endif

class WEBCORE_EXPORT GraphicsContextGLCocoa : public GraphicsContextGLANGLE, public CanMakeCheckedPtr<GraphicsContextGLCocoa> {
    WTF_MAKE_TZONE_ALLOCATED(GraphicsContextGLCocoa);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(GraphicsContextGLCocoa);
public:
    static RefPtr<GraphicsContextGLCocoa> create(WebCore::GraphicsContextGLAttributes&&, ProcessIdentity&& resourceOwner);
    // Returns false after the display was terminated.
    static bool isDisplayInitializedForTesting(GCGLDisplay);
    ~GraphicsContextGLCocoa();
    IOSurface* LEGACY_NODELETE displayBufferSurface();

    enum class PbufferAttachmentUsage { Read, Write, ReadWrite };
    // Returns a handle which, if non-null, must be released via the
    // detach call below.
    void* createPbufferAndAttachIOSurface(GCGLenum target, PbufferAttachmentUsage, GCGLenum internalFormat, GCGLsizei width, GCGLsizei height, GCGLenum type, IOSurfaceRef, GCGLuint plane);
    void destroyPbufferAndDetachIOSurface(void* handle);

#if ENABLE(WEBXR)
    GCGLExternalImage createExternalImage(ExternalImageSource&&, GCGLenum internalFormat, GCGLint layer) final;
    void bindExternalImage(GCGLenum target, GCGLExternalImage) final;

    bool addFoveation(IntSize, IntSize, IntSize, std::span<const GCGLfloat>, std::span<const GCGLfloat>, std::span<const GCGLfloat>) final;
    void enableFoveation(GCGLuint) final;
    void disableFoveation() final;

    RetainPtr<id> newSharedEventWithMachPort(mach_port_t);
    GCGLExternalSync createExternalSync(ExternalSyncSource&&) final;
    bool enableRequiredWebXRExtensions() final;

    // GL_WEBKIT_explicit_resolve_target
    void framebufferResolveRenderbuffer(GCGLenum, GCGLenum, GCGLenum, PlatformGLObject) final;
#endif

    void waitUntilWorkScheduled();

    // GraphicsContextGLANGLE overrides.
    RefPtr<GraphicsLayerContentsDisplayDelegate> layerContentsDisplayDelegate() override;
#if ENABLE(VIDEO)
    bool copyTextureFromVideoFrame(VideoFrame&, PlatformGLObject texture, int32_t level, uint32_t internalFormat, uint32_t format, uint32_t type, bool premultiplyAlpha, bool flipY) final;
#endif
#if ENABLE(MEDIA_STREAM) || ENABLE(WEB_CODECS)
    RefPtr<VideoFrame> surfaceBufferToVideoFrame(SurfaceBuffer) final;
#endif
    RefPtr<PixelBuffer> readCompositedResults() final;
    void setDrawingBufferColorSpace(const ColorSpace&) final;
    void prepareForDisplay() override;

    RefPtr<NativeImage> copyNativeImage(SurfaceBuffer) override;

    // Prepares current frame for display. The `finishedSignal` will be invoked once the frame has finished rendering.
    void prepareForDisplayWithFinishedSignal(Function<void()> finishedSignal);

    bool hasSpareDrawingBuffersInUse() const;
    void releaseIdleSpareDrawingBuffers();

protected:
    GraphicsContextGLCocoa(WebCore::GraphicsContextGLAttributes&&, ProcessIdentity&& resourceOwner);

    // GraphicsContextGLANGLE overrides.
    bool platformInitializeContext() final;
    std::unique_ptr<Island> createIsland() final;
    void invalidateKnownTextureContent(GCGLuint) final;
    bool reshapeDrawingBuffer() final;

#if ENABLE(VIDEO)
    GraphicsContextGLCV* cvContext();
#endif
    // Inserts new fence that will invoke `signal` from a background thread when completed.
    // If not possible, calls the `signal`.
    void insertFinishedSignalOrInvoke(Function<void()> signal);
    void* createMetalSharedEventEGLSync(id, uint64_t);
    RetainPtr<IOSurfaceRef> copySurfaceBuffer(SurfaceBuffer);

    size_t spareDrawingBufferCountForTesting() const;
    // As the kernel has it, rather than as the context last set it.
    size_t volatileSpareDrawingBufferCountForTesting() const;

    ProcessIdentity m_resourceOwner;
    ColorSpace m_drawingBufferColorSpace;
#if ENABLE(VIDEO)
    const std::unique_ptr<GraphicsContextGLCVCocoa> m_cv;
#endif
    const RetainPtr<MTLSharedEventListener> m_finishedMetalSharedEventListener;
    const RetainPtr<id> m_finishedMetalSharedEvent; // FIXME: Remove all C++ includees and use id<MTLSharedEvent>.
#if ENABLE(WEBXR)
    using RasterizationRateMapArray =  EnumeratedArray<PlatformXR::Layout, RetainPtr<MTLRasterizationRateMap>, PlatformXR::Layout::Layered>;
    RasterizationRateMapArray m_rasterizationRateMap;
#endif

    // As the Cocoa platform's, in the island.
    static constexpr size_t maxReusedDrawingBuffers { 3 };
    static constexpr size_t maxSpareDrawingBuffers { 5 };

private:
    friend struct GLContextCallbacks;
    friend class GraphicsContextGLCVCocoa;

    // A drawing buffer surface of the context's colour space and alpha, owned by the context's process, retained.
    RetainPtr<IOSurfaceRef> createDrawingBufferSurface(IntSize);

    // The Cocoa platform of the island, which has the display, the EGL context and the drawing buffers.
    struct CocoaPlatform;
    std::unique_ptr<CocoaPlatform> m_cocoaPlatform;
};

}

#endif
