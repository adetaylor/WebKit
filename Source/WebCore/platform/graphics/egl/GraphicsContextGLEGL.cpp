/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2019 Google Inc. All rights reserved.
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

#include "config.h"
#include "GraphicsContextGLEGL.h"

#if ENABLE(WEBGL) && (USE(GRAPHICS_LAYER_WC) || USE(COORDINATED_GRAPHICS))

#include "ANGLEHeaders.h"
#include "ANGLEUtilities.h"
#include "GLContext.h"
#include "Logging.h"
#include "PixelBuffer.h"
#include "PlatformDisplay.h"
#include "WebCoreWebGL.h"
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>

#if ENABLE(MEDIA_STREAM) || ENABLE(WEB_CODECS)
#include "VideoFrame.h"
#if USE(GSTREAMER)
#include "VideoFrameContentHint.h"
#include "VideoFrameGStreamer.h"
#endif
#endif

#if USE(COORDINATED_GRAPHICS)
#include "GraphicsContextGLCoordinated.h"
#else
#include "PlatformLayerDisplayDelegate.h"
#include "TextureMapperGCGLPlatformLayer.h"
#endif

#if OS(ANDROID)
#include "GraphicsContextGLAndroid.h"
#endif

#if USE(GBM)
#include "GraphicsContextGLGBM.h"
#include "GraphicsLayerContentsDisplayDelegateCoordinated.h"
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(GraphicsContextGLEGL);

#if !USE(COORDINATED_GRAPHICS)
RefPtr<PixelBuffer> GraphicsContextGLEGL::readCompositedResults()
{
    if (!m_isCompositorTextureInitialized)
        return nullptr;
    if (!makeContextCurrent())
        return nullptr;
    if (getInternalFramebufferSize().isEmpty())
        return nullptr;
    // swapCompositorTexture() leaves the drawing buffer framebuffer attached to the texture that will be rendered into
    // next, so the presented frame lives in m_compositorTexture and needs a framebuffer of its own.
    ScopedScratchReadFramebufferBinding fboBinding(m_isForWebGL2, boundReadFramebuffer(), m_compositorTexture);
    return readPixelsForPaintResults();
}
#endif

RefPtr<GraphicsContextGL> createWebProcessGraphicsContextGL(const GraphicsContextGLAttributes& attributes)
{
#if OS(ANDROID) && ENABLE(WEBXR)
    const auto& eglExtensions = PlatformDisplay::sharedDisplay().eglExtensions();
    if (eglExtensions.ANDROID_get_native_client_buffer && eglExtensions.ANDROID_image_native_buffer) {
        if (auto context = GraphicsContextGLAndroid::create(GraphicsContextGLAttributes { attributes }))
            return context;
        LOG_ERROR("Failed to create an Android graphics context, the fallback is not expected to work for WebXR content");
    } else {
        LOG_ERROR("Cannot create an Android graphics context: extension EGL_ANDROID_get_native_client_buffer %s, ANDROID_image_native_buffer %s; textures fallback not expected to work",
            eglExtensions.ANDROID_get_native_client_buffer ? "found" : "missing", eglExtensions.ANDROID_image_native_buffer ? "found" : "missing");
    }
#elif USE(GBM)
    if (GraphicsContextGLGBM::checkRequirements()) {
        RefPtr delegate = GraphicsLayerContentsDisplayDelegateCoordinated::create();
        if (auto context = GraphicsContextGLGBM::create(GraphicsContextGLAttributes { attributes }, WTF::move(delegate)))
            return context;
        LOG_ERROR("Failed to create a graphics context for WebGL using GBM, falling back to textures");
    }
#endif
#if USE(COORDINATED_GRAPHICS)
    return GraphicsContextGLCoordinated::create(GraphicsContextGLAttributes { attributes });
#else
    return GraphicsContextGLEGL::create(GraphicsContextGLAttributes { attributes });
#endif
}

#if !USE(COORDINATED_GRAPHICS)
RefPtr<GraphicsContextGLEGL> GraphicsContextGLEGL::create(GraphicsContextGLAttributes&& attributes)
{
    Ref context = adoptRef(*new GraphicsContextGLEGL(WTF::move(attributes)));
    if (!context->initialize())
        return nullptr;
    return context;
}
#endif

GraphicsContextGLEGL::GraphicsContextGLEGL(GraphicsContextGLAttributes&& attributes)
    : GraphicsContextGLANGLE(WTF::move(attributes))
{
}

GraphicsContextGLEGL::~GraphicsContextGLEGL()
{
#if !USE(COORDINATED_GRAPHICS)
    if (m_compositorTexture) {
        if (!makeContextCurrent())
            return;
        GL_DeleteTextures(1, &m_compositorTexture);
    }
#endif
}

RefPtr<GraphicsLayerContentsDisplayDelegate> GraphicsContextGLEGL::layerContentsDisplayDelegate()
{
    return m_layerContentsDisplayDelegate;
}

#if ENABLE(VIDEO)
bool GraphicsContextGLEGL::copyTextureFromVideoFrame(VideoFrame&, PlatformGLObject, GCGLenum, GCGLint, GCGLenum, GCGLenum, bool, bool)
{
    // FIXME: Implement copy-free (or at least, software copy-free) texture transfer.
    recordVideoUploadForTesting(VideoUploadOutcome::Unsupported, 0);
    return false;
}
#endif

#if ENABLE(MEDIA_STREAM) || ENABLE(WEB_CODECS)
RefPtr<VideoFrame> GraphicsContextGLEGL::surfaceBufferToVideoFrame(SurfaceBuffer buffer)
{
#if USE(GSTREAMER)
    RefPtr pixelBuffer = buffer == SurfaceBuffer::DrawingBuffer ? readRenderingResultsForPainting() : readCompositedResults();
    if (pixelBuffer) {
        VideoFrameGStreamer::CreateOptions options;
        options.rotation = VideoFrameGStreamer::Rotation::UpsideDown;
        options.isMirrored = true;
        return VideoFrameGStreamer::createFromPixelBuffer(pixelBuffer.releaseNonNull(), { }, 30, options);
    }
#else
    UNUSED_PARAM(buffer);
#endif
    return nullptr;
}
#endif

bool GraphicsContextGLEGL::platformInitializeContext()
{
    m_isForWebGL2 = contextAttributes().isWebGL2;

    auto& sharedDisplay = PlatformDisplay::sharedDisplay();
    m_displayObj = sharedDisplay.angleEGLDisplay();
    if (m_displayObj == EGL_NO_DISPLAY)
        return false;

    // WebCoreWebGL makes the EGL objects, and owns them from here.
    bool isSurfacelessDisplay = sharedDisplay.type() == PlatformDisplay::Type::Surfaceless;
    auto handles = islandCalls().createEGLContext(contextID(), ANGLEHandles::wrap<ANGLEDisplayTag>(m_displayObj), ANGLEHandles::wrap<ANGLEContextTag>(sharedDisplay.angleSharingGLContext()), isSurfacelessDisplay, m_isForWebGL2, contextAttributes().supportWebGLDraftExtensions);
    if (handles.context.isNull())
        return false;
    m_configObj = ANGLEHandles::unwrap(handles.config);
    m_surfaceObj = ANGLEHandles::unwrap(handles.surface);
    m_contextObj = ANGLEHandles::unwrap(handles.context);
    if (!makeCurrentImpl()) {
        LOG(WebGL, "ANGLE makeContextCurrent failed.");
        return false;
    }
    didMakeContextCurrent();
    LOG(WebGL, "Got EGLContext");
    return true;
}

#if !USE(COORDINATED_GRAPHICS)
bool GraphicsContextGLEGL::platformInitialize()
{
    lazyInitialize(m_texmapLayer, makeUnique<TextureMapperGCGLPlatformLayer>(*this));
    m_layerContentsDisplayDelegate = PlatformLayerDisplayDelegate::create(m_texmapLayer.get());

    GL_GenTextures(1, &m_compositorTexture);
    GL_BindTexture(GL_TEXTURE_2D, m_compositorTexture);
    GL_TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    GL_TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    GL_TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    GL_TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    GL_BindTexture(GL_TEXTURE_2D, 0);

    return true;
}
#endif

void GraphicsContextGLEGL::attachDrawingBufferTexture()
{
    ScopedRestoreReadFramebufferBinding fboBinding(m_isForWebGL2, boundReadFramebuffer(), drawingBufferFramebuffer());
    GL_FramebufferTexture2D(fboBinding.framebufferTarget(), GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, drawingBufferTexture(), 0);

    GL_Flush();
}

#if !USE(COORDINATED_GRAPHICS)
bool GraphicsContextGLEGL::reshapeDrawingBuffer()
{
    auto attrs = contextAttributes();
    const auto size = getInternalFramebufferSize();
    const int width = size.width();
    const int height = size.height();
    GLuint colorFormat = attrs.alpha ? GL_RGBA : GL_RGB;
    GLuint internalColorFormat = colorFormat;
    ScopedRestoreTextureBinding restoreBinding(GL_TEXTURE_BINDING_2D, GL_TEXTURE_2D);
    ScopedBufferBinding scopedPixelUnpackBufferReset(GL_PIXEL_UNPACK_BUFFER, 0, m_isForWebGL2);

    GL_BindTexture(GL_TEXTURE_2D, m_compositorTexture);
    GL_TexImage2D(GL_TEXTURE_2D, 0, internalColorFormat, width, height, 0, colorFormat, GL_UNSIGNED_BYTE, 0);
    GL_BindTexture(GL_TEXTURE_2D, drawingBufferTexture());
    GL_TexImage2D(GL_TEXTURE_2D, 0, internalColorFormat, width, height, 0, colorFormat, GL_UNSIGNED_BYTE, 0);

    m_isCompositorTextureInitialized = false;

    return true;
}

void GraphicsContextGLEGL::prepareForDisplay()
{
    if (!makeContextCurrent())
        return;

    prepareTexture();
    GCGLuint drawingTexture = drawingBufferTexture();
    setDrawingBufferTexture(m_compositorTexture);
    m_compositorTexture = drawingTexture;
    m_isCompositorTextureInitialized = true;
    attachDrawingBufferTexture();
}
#endif

GLContextWrapper::Type GraphicsContextGLEGL::type() const
{
    return GLContextWrapper::Type::Angle;
}

bool GraphicsContextGLEGL::makeCurrentImpl()
{
    return !!EGL_MakeCurrent(m_displayObj, m_surfaceObj, m_surfaceObj, m_contextObj);
}

bool GraphicsContextGLEGL::unmakeCurrentImpl()
{
    // WebCoreWebGL remembers which context it made current, and this one stops being it.
    platformReleaseThreadResources();
    return !!EGL_MakeCurrent(m_displayObj, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

unsigned GraphicsContextGLEGL::glVersion() const
{
    if (!m_version) {
        auto* versionString = byteCast<char>(GL_GetString(GL_VERSION));
        m_version = GLContext::versionFromString(versionString);
    }
    return m_version;
}

#if ENABLE(WEBXR)
GCGLExternalSync GraphicsContextGLEGL::createExternalSync(ExternalSyncSource&&)
{
    const auto& display = PlatformDisplay::sharedDisplay();
    if (!display.eglCheckVersion(1, 5) || !display.eglExtensions().ANDROID_native_fence_sync)
        return { };

    auto eglSync = EGL_CreateSync(m_displayObj, EGL_SYNC_NATIVE_FENCE_ANDROID, nullptr);
    if (!eglSync) {
        addError(GCGLErrorCode::InvalidOperation);
        return { };
    }

    GL_Flush();
    return addExternalSync(eglSync);
}

#if USE(OPENXR)
UnixFileDescriptor GraphicsContextGLEGL::exportExternalSync(GCGLExternalSync sync)
{
    if (!sync)
        return { };

    return UnixFileDescriptor { exportExternalSyncFileDescriptor(sync), UnixFileDescriptor::Adopt };
}
#endif

bool GraphicsContextGLEGL::addFoveation(IntSize, IntSize, IntSize, std::span<const GCGLfloat>, std::span<const GCGLfloat>, std::span<const GCGLfloat>)
{
    return false;
}

void GraphicsContextGLEGL::enableFoveation(GCGLuint)
{
}

void GraphicsContextGLEGL::disableFoveation()
{
}

bool GraphicsContextGLEGL::enableRequiredWebXRExtensions()
{
    if (!makeContextCurrent())
        return false;

    return enableExtensionsImpl({
        "GL_ANGLE_framebuffer_multisample"_s,
        "GL_ANGLE_framebuffer_blit"_s,
        "GL_EXT_discard_framebuffer"_s,
        "GL_OES_EGL_image"_s,
        "GL_OES_rgb8_rgba8"_s
    });
}
#endif

} // namespace WebCore

#endif // ENABLE(WEBGL) && (USE(GRAPHICS_LAYER_WC) || USE(COORDINATED_GRAPHICS))
