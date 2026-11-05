/*
 * Copyright (C) 2010, 2013 Apple Inc. All rights reserved.
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

#if ENABLE(WEBGL)
#include "GraphicsContextGLANGLE.h"

#include "GraphicsContextGLANGLEIsland.h"
#include "ImageBuffer.h"
#include "IntRect.h"
#include "IntSize.h"
#include "NativeImage.h"
#include "NotImplemented.h"
#include "TypedArrayPixelBuffer.h"
#include <atomic>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/Lock.h>
#include <wtf/MallocSpan.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/StdLibExtras.h>

namespace WebCore {

// GraphicsContextGLANGLE is a shell over the WebGL island's GLContext, which has its GL logic. The shell lends the
// island the memory of its callers' spans, and is the island's client and platform.

// List of displays ever instantiated from EGL. When terminating all EGL resources, we need to
// terminate all displays. However, we cannot ask EGL all the displays it has created.
// We must know all the displays via this set.
// The island mirrors these C++ enums by value.
static_assert(std::to_underlying(GraphicsContextGLSimulatedEventForTesting::GPUStatusFailure) == 0);
static_assert(std::to_underlying(GraphicsContextGLSimulatedEventForTesting::Timeout) == 1);
static_assert(std::to_underlying(GraphicsContextGLSimulatedEventForTesting::DisplayBufferAllocationFailure) == 2);
static_assert(std::to_underlying(GraphicsContextGLSimulatedEventForTesting::RenderbufferAllocationFailure) == 3);
static_assert(std::to_underlying(GCGLErrorCode::ContextLost) == 1 << 0);
static_assert(std::to_underlying(GCGLErrorCode::InvalidFramebufferOperation) == 1 << 1);
static_assert(std::to_underlying(GCGLErrorCode::OutOfMemory) == 1 << 2);
static_assert(std::to_underlying(GCGLErrorCode::InvalidOperation) == 1 << 3);
static_assert(std::to_underlying(GCGLErrorCode::InvalidValue) == 1 << 4);
static_assert(std::to_underlying(GCGLErrorCode::InvalidEnum) == 1 << 5);
static_assert(std::to_underlying(GCGLExtension::HighestEnumValue) == 60, "GLExtensions.swift lists GCGLExtension's names in its order");
static_assert(std::to_underlying(GCGLExtension::CHROMIUM_color_buffer_float_rgb) == 15 && std::to_underlying(GCGLExtension::CHROMIUM_color_buffer_float_rgba) == 16);

static HashSet<GCGLDisplay>& LEGACY_NODELETE usedDisplays()
{
    static NeverDestroyed<HashSet<GCGLDisplay>> s_usedDisplays;
    return s_usedDisplays;
}

static Lock contextsLock;

static HashMap<uint64_t, GraphicsContextGLANGLE*>& contexts() WTF_REQUIRES_LOCK(contextsLock)
{
    static NeverDestroyed<HashMap<uint64_t, GraphicsContextGLANGLE*>> contexts;
    return contexts;
}

// Incremented when a context leaves contexts(), which invalidates every thread's last callback context.
static std::atomic<uint64_t> contextsGeneration;

struct CallbackContext {
    uint64_t contextID { 0 };
    uint64_t generation { 0 };
    SUPPRESS_UNCOUNTED_MEMBER GraphicsContextGLANGLE* context { nullptr };
};

// The context the thread's last callback found, while no context has left contexts() since.
static thread_local CallbackContext lastCallbackContext;

GraphicsContextGLANGLE* GraphicsContextGLANGLE::contextForCallback(uint64_t contextID)
{
    auto& last = lastCallbackContext;
    if (last.context && last.contextID == contextID && last.generation == contextsGeneration.load(std::memory_order_acquire))
        return last.context;
    Locker locker { contextsLock };
    auto* context = contexts().get(contextID);
    last = { contextID, contextsGeneration.load(std::memory_order_relaxed), context };
    return context;
}

static uint64_t nextContextID()
{
    static std::atomic<uint64_t> lastContextID;
    return ++lastContextID;
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(GraphicsContextGLANGLE::Island);

GraphicsContextGLANGLE::Island::Island(GraphicsContextGLANGLE& owner, WebCoreWebGL::GLContext&& context)
    : context(WTF::move(context))
    , contextID(owner.m_contextID)
{
    Locker locker { contextsLock };
    contexts().add(contextID, &owner);
}

GraphicsContextGLANGLE::Island::~Island()
{
    Locker locker { contextsLock };
    contexts().remove(contextID);
    contextsGeneration.fetch_add(1, std::memory_order_release);
}

template<typename T>
static GLLender<T> lend(std::span<T> span)
{
    return GLLender<T> { span };
}

// A string with its NUL terminator, or nothing for a null string.
static GLLender<const uint8_t> lendCString(const UTF8CString& string)
{
    if (string.isNull())
        return GLLender<const uint8_t> { std::span<const uint8_t> { } };
    return GLLender<const uint8_t> { byteCast<uint8_t>(string.spanIncludingNullTerminator()) };
}

static GLLender<const char* const> lendCStrings(std::span<const char* const> strings)
{
    return GLLender<const char* const> { strings };
}

template<typename Copy>
static UTF8CString copyIslandString(GCGLint length, const Copy& copy)
{
    Vector<uint8_t, 64> buffer(static_cast<size_t>(std::max(length, 0)));
    size_t copied = copy(lend(buffer.mutableSpan()).view());
    return UTF8CString { byteCast<char8_t>(buffer.span().first(std::min(copied, buffer.size()))) };
}

// A log or source whose length, with its NUL terminator, is maxLength, or nothing if the context isn't current.
template<typename Get>
static UTF8CString copyIslandLog(GCGLint maxLength, const Get& get)
{
    if (maxLength < 0)
        return { };
    if (!maxLength)
        return ""_s;
    Vector<uint8_t, 64> buffer(static_cast<size_t>(maxLength));
    GCGLsizei length = get(lend(buffer.mutableSpan()).view());
    return UTF8CString { byteCast<char8_t>(buffer.span().first(std::clamp<size_t>(length, 0, buffer.size()))) };
}

static ANGLEDisplay wrapDisplay(GCGLDisplay display)
{
    return ANGLEHandles::wrap<ANGLEDisplayTag>(display);
}

static ANGLEContext wrapContext(GCGLContext context)
{
    return ANGLEHandles::wrap<ANGLEContextTag>(context);
}

void GLContextCallbacks::forceContextLost(uint64_t contextID)
{
    if (auto* context = GraphicsContextGLANGLE::contextForCallback(contextID))
        context->GraphicsContextGL::forceContextLost();
}

void GLContextCallbacks::didChangeMemoryCost(uint64_t contextID)
{
    if (auto* context = GraphicsContextGLANGLE::contextForCallback(contextID))
        context->didChangeMemoryCost();
}

void GLContextCallbacks::didChangeInternalFramebufferSize(uint64_t contextID, int32_t width, int32_t height)
{
    if (auto* context = GraphicsContextGLANGLE::contextForCallback(contextID)) {
        context->m_currentWidth = width;
        context->m_currentHeight = height;
    }
}

bool GLContextCallbacks::platformInitializeExtensions(uint64_t contextID)
{
    auto* context = GraphicsContextGLANGLE::contextForCallback(contextID);
    return context && context->platformInitializeExtensions();
}

bool GLContextCallbacks::platformInitialize(uint64_t contextID)
{
    auto* context = GraphicsContextGLANGLE::contextForCallback(contextID);
    return context && context->platformInitialize();
}

bool GLContextCallbacks::reshapeDrawingBuffer(uint64_t contextID)
{
    auto* context = GraphicsContextGLANGLE::contextForCallback(contextID);
    return context && context->reshapeDrawingBuffer();
}

void GLContextCallbacks::invalidateKnownTextureContent(uint64_t contextID, GLuint texture)
{
    if (auto* context = GraphicsContextGLANGLE::contextForCallback(contextID))
        context->invalidateKnownTextureContent(texture);
}

void GLContextCallbacks::didLoseDisplay(uint64_t contextID)
{
    if (auto* context = GraphicsContextGLANGLE::contextForCallback(contextID))
        context->platformDidLoseDisplay();
}

void GLContextCallbacks::addDebugMessage(uint64_t contextID, GCGLenum type, GCGLenum messageID, GCGLenum severity, std::span<const char8_t> message)
{
    auto* context = GraphicsContextGLANGLE::contextForCallback(contextID);
    if (context && context->m_client)
        context->m_client->addDebugMessage(type, messageID, severity, message);
}

GraphicsContextGLANGLE::GraphicsContextGLANGLE(GraphicsContextGLAttributes attributes)
    : GraphicsContextGL(attributes)
    , m_contextID(nextContextID())
{
}

std::optional<size_t> GraphicsContextGLANGLE::estimatedMemoryCost()
{
    auto cost = m_island->context.estimatedMemoryCost();
    if (cost < 0)
        return std::nullopt;
    return static_cast<size_t>(cost);
}

bool GraphicsContextGLANGLE::initialize()
{
    if (contextAttributes().failContextCreationForTesting == GraphicsContextGLAttributes::SimulatedCreationFailure::FailPlatformContextCreation)
        return false;
    if (!platformInitializeContext())
        return false;

    m_island = createIsland();
    if (!m_island->context.initialize())
        return false;

    // EGL resources are only ever released if we run in process mode where EGL is used on host app threads, e.g. WK1
    // mode.
    static bool tracksUsedDisplays = !(isInWebProcess() || isInGPUProcess());
    if (tracksUsedDisplays) {
        // TODO: Move to ~GraphicsContextGLANGLE() when the function is moved to this file.
        ASSERT(m_displayObj);
        usedDisplays().add(m_displayObj);
    }

    m_knownActiveExtensions = EnumSet<GCGLExtension>::fromRaw(m_island->context.knownActiveExtensions());
    m_requestableExtensions = EnumSet<GCGLExtension>::fromRaw(m_island->context.requestableExtensions());
    return true;
}

std::unique_ptr<GraphicsContextGLANGLE::Island> GraphicsContextGLANGLE::createIsland()
{
    return makeUnique<Island>(*this, WebCoreWebGL::GLContext::init(m_contextID, wrapDisplay(m_displayObj), wrapContext(m_contextObj), m_isForWebGL2, contextAttributes().supportWebGLDraftExtensions));
}

bool GraphicsContextGLANGLE::platformInitializeExtensions()
{
    return true;
}

bool GraphicsContextGLANGLE::platformInitialize()
{
    return true;
}

void GraphicsContextGLANGLE::platformDidLoseDisplay()
{
}

bool GraphicsContextGLANGLE::makeContextCurrent()
{
    return m_island && m_island->context.makeCurrentForPlatform();
}

#if PLATFORM(COCOA)
bool GraphicsContextGLANGLE::makeCurrent(GCGLDisplay display, GCGLContext context)
{
    return WebCoreWebGL::GLContext::makeCurrent(wrapDisplay(display), wrapContext(context));
}
#endif

void GraphicsContextGLANGLE::platformReleaseThreadResources()
{
    WebCoreWebGL::GLContext::forgetCurrentContext();
}

bool GraphicsContextGLANGLE::releaseThreadResources(ReleaseThreadResourceBehavior releaseBehavior)
{
    platformReleaseThreadResources();

    if (!platformIsANGLEAvailable())
        return false;

    // Unset the EGL current context, since the next access might be from another thread, and the
    // context cannot be current on multiple threads.
    if (releaseBehavior == ReleaseThreadResourceBehavior::ReleaseCurrentContext) {
        EGLDisplay display = EGL_GetCurrentDisplay();
        if (display == EGL_NO_DISPLAY)
            return true;
        // At the time of writing, ANGLE does not flush on MakeCurrent. Since we are
        // potentially switching threads, we should flush.
        // Note: Here we assume also that ANGLE has only one platform context -- otherwise
        // we would need to flush each EGL context that has been used.
        GL_Flush();
        return EGL_MakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    if (releaseBehavior == ReleaseThreadResourceBehavior::TerminateAndReleaseThreadResources) {
        EGLDisplay currentDisplay = EGL_GetCurrentDisplay();
        if (currentDisplay != EGL_NO_DISPLAY) {
            ASSERT_NOT_REACHED(); // All resources must have been destroyed.
            EGL_MakeCurrent(currentDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
        for (auto display : usedDisplays())
            EGL_Terminate(display);
        usedDisplays().clear();
    }
    // Called when we do not know if we will ever see another call from this thread again.
    // Unset the EGL current context by releasing whole EGL thread state.
    return EGL_ReleaseThread();
}

void GraphicsContextGLANGLE::checkGPUStatus()
{
    m_island->context.checkGPUStatusForPlatform();
}

void GraphicsContextGLANGLE::forceContextLost()
{
    if (m_island)
        m_island->context.didForceContextLost();
    GraphicsContextGL::forceContextLost();
}

RefPtr<PixelBuffer> GraphicsContextGLANGLE::createPixelBufferForPaintResults()
{
    auto alphaFormat = contextAttributes().premultipliedAlpha ? AlphaPremultiplication::Premultiplied : AlphaPremultiplication::Unpremultiplied;
    auto pixelFormat = contextAttributes().alpha ? PixelFormat::RGBA8 : PixelFormat::RGBX8;
    PixelBufferFormat format { alphaFormat, pixelFormat, ColorSpace::SRGB() };
    return ByteArrayPixelBuffer::tryCreate(format, getInternalFramebufferSize());
}

RefPtr<PixelBuffer> GraphicsContextGLANGLE::readPixelsForPaintResults()
{
    auto pixelBuffer = createPixelBufferForPaintResults();
    if (!pixelBuffer)
        return nullptr;
    if (!m_island->context.readPixelsForPaintResults(lend(pixelBuffer->bytes()).view(), pixelBuffer->size().width(), pixelBuffer->size().height()))
        return nullptr;
    return pixelBuffer;
}

RefPtr<PixelBuffer> GraphicsContextGLANGLE::readRenderingResults()
{
    auto pixelBuffer = createPixelBufferForPaintResults();
    if (!pixelBuffer)
        return nullptr;
    if (!m_island->context.readRenderingResults(lend(pixelBuffer->bytes()).view(), pixelBuffer->size().width(), pixelBuffer->size().height()))
        return nullptr;
    return pixelBuffer;
}

void GraphicsContextGLANGLE::prepareTexture()
{
}

bool GraphicsContextGLANGLE::getBufferSubDataWithStatus(GCGLenum target, GCGLintptr offset, std::span<uint8_t> data)
{
    return m_island->context.getBufferSubData(target, offset, lend(data).view());
}

std::optional<IntSize> GraphicsContextGLANGLE::readPixelsWithStatus(IntRect rect, GCGLenum format, GCGLenum type, GCGLboolean reverseRowOrder, std::span<uint8_t> data)
{
    auto status = m_island->context.readPixelsWithStatus(rect.x(), rect.y(), rect.width(), rect.height(), format, type, reverseRowOrder, lend(data).view());
    if (!status.succeeded)
        return std::nullopt;
    return IntSize { status.width, status.height };
}

// Flips the rows in place, e.g. to convert GL read results to image orientation.
static void flipPixelBufferRows(PixelBuffer& pixelBuffer)
{
    if (pixelBuffer.size().isEmpty())
        return;
    ASSERT(PixelBuffer::bytesPerPixel(pixelBuffer.format().pixelFormat) == 4);
    // FIXME: Make PixelBufferConversions support negative rowBytes and in-place conversions.
    size_t rowStride = pixelBuffer.size().width() * 4;
    auto rowBuffer = MallocSpan<uint8_t>::malloc(rowStride);
    for (auto bytes = pixelBuffer.bytes(); bytes.size() >= rowStride * 2; bytes = bytes.subspan(rowStride, bytes.size() - 2 * rowStride)) {
        auto top = bytes.first(rowStride);
        auto bottom = bytes.last(rowStride);
        memcpySpan(rowBuffer.mutableSpan(), bottom);
        memcpySpan(bottom, top);
        memcpySpan(top, rowBuffer.span());
    }
}

RefPtr<NativeImage> GraphicsContextGLANGLE::copyNativeImage(SurfaceBuffer source)
{
    if (!makeContextCurrent())
        return nullptr;
    if (getInternalFramebufferSize().isEmpty())
        return nullptr;
    RefPtr<PixelBuffer> pixelBuffer;
    if (source == SurfaceBuffer::DrawingBuffer)
        pixelBuffer = readRenderingResults();
    else
        pixelBuffer = readCompositedResults();
    if (!pixelBuffer)
        return nullptr;
    // The first row of the read results is the bottom row of the image.
    flipPixelBufferRows(*pixelBuffer);
    return NativeImage::create(pixelBuffer.releaseNonNull());
}

RefPtr<PixelBuffer> GraphicsContextGLANGLE::readRenderingResultsForPainting()
{
    if (!makeContextCurrent())
        return nullptr;
    if (getInternalFramebufferSize().isEmpty())
        return nullptr;
    return readRenderingResults();
}

void GraphicsContextGLANGLE::addError(GCGLErrorCode errorCode)
{
    m_island->context.addErrors(GCGLErrorCodeSet { errorCode }.toRaw());
}

EnumSet<GCGLExtension> GraphicsContextGLANGLE::knownActiveExtensions() const
{
    return m_knownActiveExtensions;
}

EnumSet<GCGLExtension> GraphicsContextGLANGLE::requestableExtensions() const
{
    return m_requestableExtensions;
}

void GraphicsContextGLANGLE::invalidateKnownTextureContent(GCGLuint)
{
}

bool GraphicsContextGLANGLE::enableExtensionsImpl(std::initializer_list<ASCIILiteral> names)
{
    Vector<const char*, 16> strings;
    strings.reserveInitialCapacity(names.size());
    for (auto name : names)
        strings.append(name.characters());
    return m_island->context.enableExtensionsForPlatform(lendCStrings(strings.span()).view());
}

GCGLuint GraphicsContextGLANGLE::drawingBufferTexture() const
{
    return m_island->context.drawingBufferTexture();
}

GCGLuint GraphicsContextGLANGLE::boundReadFramebuffer() const
{
    return m_island->context.boundReadFramebuffer();
}

GCGLuint GraphicsContextGLANGLE::boundDrawFramebuffer() const
{
    return m_island->context.boundDrawFramebuffer();
}

void GraphicsContextGLANGLE::clampMaxInternalFramebufferSize(IntSize size)
{
    m_island->context.clampMaxInternalFramebufferSize(size.width(), size.height());
}

bool GraphicsContextGLANGLE::takeFailNextDrawingBufferAllocation()
{
    return m_island->context.takeFailNextDrawingBufferAllocation();
}

bool GraphicsContextGLANGLE::failsNextDrawingBufferAllocation() const
{
    return m_island->context.failsNextDrawingBufferAllocation();
}

#if ENABLE(WEBXR)
GCGLExternalImage GraphicsContextGLANGLE::addExternalImage(void* eglImage)
{
    return m_island->context.addExternalImage(ANGLEHandles::wrap<ANGLEImageTag>(eglImage));
}

GCGLExternalSync GraphicsContextGLANGLE::addExternalSync(void* eglSync)
{
    return m_island->context.addExternalSync(ANGLEHandles::wrap<ANGLESyncTag>(eglSync));
}
#endif

// Forwarders to the island.

void GraphicsContextGLANGLE::activeTexture(GCGLenum texture)
{
    m_island->context.activeTexture(texture);
}

void GraphicsContextGLANGLE::attachShader(PlatformGLObject program, PlatformGLObject shader)
{
    m_island->context.attachShader(program, shader);
}

void GraphicsContextGLANGLE::bindAttribLocation(PlatformGLObject program, GCGLuint index, const UTF8CString& name)
{
    m_island->context.bindAttribLocation(program, index, lendCString(name).view());
}

void GraphicsContextGLANGLE::bindBuffer(GCGLenum target, PlatformGLObject arg1)
{
    m_island->context.bindBuffer(target, arg1);
}

void GraphicsContextGLANGLE::bindFramebuffer(GCGLenum target, PlatformGLObject arg1)
{
    m_island->context.bindFramebuffer(target, arg1);
}

void GraphicsContextGLANGLE::bindRenderbuffer(GCGLenum target, PlatformGLObject arg1)
{
    m_island->context.bindRenderbuffer(target, arg1);
}

void GraphicsContextGLANGLE::bindTexture(GCGLenum target, PlatformGLObject arg1)
{
    m_island->context.bindTexture(target, arg1);
}

void GraphicsContextGLANGLE::blendColor(GCGLclampf red, GCGLclampf green, GCGLclampf blue, GCGLclampf alpha)
{
    m_island->context.blendColor(red, green, blue, alpha);
}

void GraphicsContextGLANGLE::blendEquation(GCGLenum mode)
{
    m_island->context.blendEquation(mode);
}

void GraphicsContextGLANGLE::blendEquationSeparate(GCGLenum modeRGB, GCGLenum modeAlpha)
{
    m_island->context.blendEquationSeparate(modeRGB, modeAlpha);
}

void GraphicsContextGLANGLE::blendFunc(GCGLenum sfactor, GCGLenum dfactor)
{
    m_island->context.blendFunc(sfactor, dfactor);
}

void GraphicsContextGLANGLE::blendFuncSeparate(GCGLenum srcRGB, GCGLenum dstRGB, GCGLenum srcAlpha, GCGLenum dstAlpha)
{
    m_island->context.blendFuncSeparate(srcRGB, dstRGB, srcAlpha, dstAlpha);
}

void GraphicsContextGLANGLE::bufferData(GCGLenum target, GCGLsizeiptr size, GCGLenum usage)
{
    m_island->context.bufferDataUninitialized(target, size, usage);
}

void GraphicsContextGLANGLE::bufferData(GCGLenum target, std::span<const uint8_t> data, GCGLenum usage)
{
    m_island->context.bufferData(target, lend(data).view(), usage);
}

void GraphicsContextGLANGLE::bufferSubData(GCGLenum target, GCGLintptr offset, std::span<const uint8_t> data)
{
    m_island->context.bufferSubData(target, offset, lend(data).view());
}

GCGLenum GraphicsContextGLANGLE::checkFramebufferStatus(GCGLenum target)
{
    return m_island->context.checkFramebufferStatus(target);
}

void GraphicsContextGLANGLE::clear(GCGLbitfield mask)
{
    m_island->context.clear(mask);
}

void GraphicsContextGLANGLE::clearColor(GCGLclampf red, GCGLclampf green, GCGLclampf blue, GCGLclampf alpha)
{
    m_island->context.clearColor(red, green, blue, alpha);
}

void GraphicsContextGLANGLE::clearDepth(GCGLclampf depth)
{
    m_island->context.clearDepth(depth);
}

void GraphicsContextGLANGLE::clearStencil(GCGLint s)
{
    m_island->context.clearStencil(s);
}

void GraphicsContextGLANGLE::colorMask(GCGLboolean red, GCGLboolean green, GCGLboolean blue, GCGLboolean alpha)
{
    m_island->context.colorMask(red, green, blue, alpha);
}

void GraphicsContextGLANGLE::compileShader(PlatformGLObject arg0)
{
    m_island->context.compileShader(arg0);
}

void GraphicsContextGLANGLE::copyTexImage2D(GCGLenum target, GCGLint level, GCGLenum internalformat, GCGLint x, GCGLint y, GCGLsizei width, GCGLsizei height, GCGLint border)
{
    m_island->context.copyTexImage2D(target, level, internalformat, x, y, width, height, border);
}

void GraphicsContextGLANGLE::copyTexSubImage2D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLint x, GCGLint y, GCGLsizei width, GCGLsizei height)
{
    m_island->context.copyTexSubImage2D(target, level, xoffset, yoffset, x, y, width, height);
}

void GraphicsContextGLANGLE::cullFace(GCGLenum mode)
{
    m_island->context.cullFace(mode);
}

void GraphicsContextGLANGLE::depthFunc(GCGLenum func)
{
    m_island->context.depthFunc(func);
}

void GraphicsContextGLANGLE::depthMask(GCGLboolean flag)
{
    m_island->context.depthMask(flag);
}

void GraphicsContextGLANGLE::depthRange(GCGLclampf zNear, GCGLclampf zFar)
{
    m_island->context.depthRange(zNear, zFar);
}

void GraphicsContextGLANGLE::detachShader(PlatformGLObject arg0, PlatformGLObject arg1)
{
    m_island->context.detachShader(arg0, arg1);
}

void GraphicsContextGLANGLE::disable(GCGLenum cap)
{
    m_island->context.disable(cap);
}

void GraphicsContextGLANGLE::disableVertexAttribArray(GCGLuint index)
{
    m_island->context.disableVertexAttribArray(index);
}

void GraphicsContextGLANGLE::drawArrays(GCGLenum mode, GCGLint first, GCGLsizei count)
{
    m_island->context.drawArrays(mode, first, count);
}

void GraphicsContextGLANGLE::drawElements(GCGLenum mode, GCGLsizei count, GCGLenum type, GCGLintptr offset)
{
    m_island->context.drawElements(mode, count, type, offset);
}

void GraphicsContextGLANGLE::enable(GCGLenum cap)
{
    m_island->context.enable(cap);
}

void GraphicsContextGLANGLE::enableVertexAttribArray(GCGLuint index)
{
    m_island->context.enableVertexAttribArray(index);
}

void GraphicsContextGLANGLE::finish()
{
    m_island->context.finish();
}

void GraphicsContextGLANGLE::flush()
{
    m_island->context.flush();
}

void GraphicsContextGLANGLE::framebufferRenderbuffer(GCGLenum target, GCGLenum attachment, GCGLenum renderbuffertarget, PlatformGLObject arg3)
{
    m_island->context.framebufferRenderbuffer(target, attachment, renderbuffertarget, arg3);
}

void GraphicsContextGLANGLE::framebufferTexture2D(GCGLenum target, GCGLenum attachment, GCGLenum textarget, PlatformGLObject arg3, GCGLint level)
{
    m_island->context.framebufferTexture2D(target, attachment, textarget, arg3, level);
}

void GraphicsContextGLANGLE::frontFace(GCGLenum mode)
{
    m_island->context.frontFace(mode);
}

void GraphicsContextGLANGLE::generateMipmap(GCGLenum target)
{
    m_island->context.generateMipmap(target);
}

Vector<GCGLAttribActiveInfo> GraphicsContextGLANGLE::activeAttribs(PlatformGLObject program)
{
    auto& context = m_island->context;
    auto count = context.activeAttribCount(program);
    Vector<GCGLAttribActiveInfo> result;
    result.reserveInitialCapacity(count.count);
    Vector<uint8_t, 256> name(static_cast<size_t>(count.maxLength));
    for (GLint index = 0; index < count.count; ++index) {
        auto info = context.activeAttrib(program, index, lend(name.mutableSpan()).view());
        if (!info.nameLength)
            return { };
        result.append(GCGLAttribActiveInfo { UTF8CString { byteCast<char8_t>(name.span().first(info.nameLength)) }, info.type, info.location });
    }
    return result;
}

Vector<GCGLUniformActiveInfo> GraphicsContextGLANGLE::activeUniforms(PlatformGLObject program)
{
    auto& context = m_island->context;
    auto count = context.activeUniformCount(program);
    Vector<GCGLUniformActiveInfo> result;
    result.reserveInitialCapacity(count.count);
    Vector<uint8_t, 256> name(static_cast<size_t>(count.maxLength));
    for (GLint index = 0; index < count.count; ++index) {
        auto info = context.activeUniform(program, index, lend(name.mutableSpan()).view());
        if (!info.nameLength)
            return { };
        GCGLUniformActiveInfo uniform;
        uniform.name = UTF8CString { byteCast<char8_t>(name.span().first(info.nameLength)) };
        uniform.type = info.type;
        uniform.size = info.size;
        uniform.blockIndex = info.blockIndex;
        uniform.offset = info.offset;
        uniform.arrayStride = info.arrayStride;
        uniform.matrixStride = info.matrixStride;
        uniform.isRowMajor = info.isRowMajor;
        if (info.locationCount > 0) {
            uniform.locations = Vector<int>(static_cast<size_t>(info.locationCount));
            if (!context.activeUniformLocations(program, lend(name.span()).view(), info.nameLength, lend(uniform.locations.mutableSpan()).view()))
                return { };
        }
        result.append(WTF::move(uniform));
    }
    return result;
}

void GraphicsContextGLANGLE::getBooleanv(GCGLenum pname, std::span<GCGLboolean> value)
{
    m_island->context.getBooleanv(pname, lend(value).view());
}

GCGLint GraphicsContextGLANGLE::getBufferParameteri(GCGLenum target, GCGLenum pname)
{
    return m_island->context.getBufferParameteri(target, pname);
}

GCGLErrorCodeSet GraphicsContextGLANGLE::getErrors()
{
    return GCGLErrorCodeSet::fromRaw(m_island->context.getErrors());
}

void GraphicsContextGLANGLE::getFloatv(GCGLenum pname, std::span<GCGLfloat> value)
{
    m_island->context.getFloatv(pname, lend(value).view());
}

GCGLint GraphicsContextGLANGLE::getFramebufferAttachmentParameteri(GCGLenum target, GCGLenum attachment, GCGLenum pname)
{
    return m_island->context.getFramebufferAttachmentParameteri(target, attachment, pname);
}

void GraphicsContextGLANGLE::getIntegerv(GCGLenum pname, std::span<GCGLint> value)
{
    m_island->context.getIntegerv(pname, lend(value).view());
}

void GraphicsContextGLANGLE::getIntegeri_v(GCGLenum pname, GCGLuint index, std::span<GCGLint, 4> value) // NOLINT
{
    m_island->context.getIntegeri_v(pname, index, lend(std::span<GCGLint> { value }).view());
}

GCGLint64 GraphicsContextGLANGLE::getInteger64(GCGLenum pname)
{
    return m_island->context.getInteger64(pname);
}

GCGLint64 GraphicsContextGLANGLE::getInteger64i(GCGLenum pname, GCGLuint index)
{
    return m_island->context.getInteger64i(pname, index);
}

GCGLint GraphicsContextGLANGLE::maxCombinedTextureImageUnits()
{
    return m_island->context.getInteger(MAX_COMBINED_TEXTURE_IMAGE_UNITS);
}

GCGLint GraphicsContextGLANGLE::maxVertexAttribs()
{
    return m_island->context.getInteger(MAX_VERTEX_ATTRIBS);
}

GCGLint GraphicsContextGLANGLE::maxTextureSize()
{
    return m_island->context.getInteger(MAX_TEXTURE_SIZE);
}

GCGLint GraphicsContextGLANGLE::maxCubeMapTextureSize()
{
    return m_island->context.getInteger(MAX_CUBE_MAP_TEXTURE_SIZE);
}

GCGLint GraphicsContextGLANGLE::maxRenderbufferSize()
{
    return m_island->context.getInteger(MAX_RENDERBUFFER_SIZE);
}

std::array<GCGLint, 2> GraphicsContextGLANGLE::maxViewportDims()
{
    auto dims = m_island->context.maxViewportDims();
    return { dims.x, dims.y };
}

std::array<GCGLint, 2> GraphicsContextGLANGLE::maxDrawingBufferSize()
{
    auto size = m_island->context.maxDrawingBufferSize();
    return { size.x, size.y };
}

GCGLint GraphicsContextGLANGLE::maxSamples()
{
    return m_island->context.getInteger(MAX_SAMPLES);
}

GCGLint GraphicsContextGLANGLE::maxTransformFeedbackSeparateAttribs()
{
    return m_island->context.getInteger(MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS);
}

GCGLint GraphicsContextGLANGLE::maxUniformBufferBindings()
{
    return m_island->context.getInteger(MAX_UNIFORM_BUFFER_BINDINGS);
}

GCGLint GraphicsContextGLANGLE::uniformBufferOffsetAlignment()
{
    return m_island->context.getInteger(UNIFORM_BUFFER_OFFSET_ALIGNMENT);
}

GCGLint GraphicsContextGLANGLE::max3DTextureSize()
{
    return m_island->context.getInteger(MAX_3D_TEXTURE_SIZE);
}

GCGLint GraphicsContextGLANGLE::maxArrayTextureLayers()
{
    return m_island->context.getInteger(MAX_ARRAY_TEXTURE_LAYERS);
}

GCGLint GraphicsContextGLANGLE::getProgrami(PlatformGLObject program, GCGLenum pname)
{
    return m_island->context.getProgrami(program, pname);
}

UTF8CString GraphicsContextGLANGLE::getProgramInfoLog(PlatformGLObject program)
{
    auto& context = m_island->context;
    return copyIslandLog(context.programInfoLogLength(program), [&](auto& view) { return context.getProgramInfoLog(program, view); });
}

GCGLint GraphicsContextGLANGLE::getRenderbufferParameteri(GCGLenum target, GCGLenum pname)
{
    return m_island->context.getRenderbufferParameteri(target, pname);
}

GCGLint GraphicsContextGLANGLE::getShaderi(PlatformGLObject arg0, GCGLenum pname)
{
    return m_island->context.getShaderi(arg0, pname);
}

UTF8CString GraphicsContextGLANGLE::getShaderInfoLog(PlatformGLObject shader)
{
    auto& context = m_island->context;
    return copyIslandLog(context.shaderInfoLogLength(shader), [&](auto& view) { return context.getShaderInfoLog(shader, view); });
}

void GraphicsContextGLANGLE::getShaderPrecisionFormat(GCGLenum shaderType, GCGLenum precisionType, std::span<GCGLint, 2> range, GCGLint* precision)
{
    auto format = m_island->context.getShaderPrecisionFormat(shaderType, precisionType);
    if (!format.queried)
        return;
    range[0] = format.rangeMin;
    range[1] = format.rangeMax;
    *precision = format.precision;
}

UTF8CString GraphicsContextGLANGLE::getString(GCGLenum name)
{
    auto& context = m_island->context;
    // ANGLE's longest string, the extensions, fits.
    std::array<uint8_t, 8192> buffer;
    auto length = context.copyString(name, lend(std::span<uint8_t> { buffer }).view());
    if (length < 0)
        return { };
    if (static_cast<size_t>(length) <= buffer.size())
        return UTF8CString { byteCast<char8_t>(std::span<const uint8_t> { buffer }.first(static_cast<size_t>(length))) };
    std::span<char8_t> characters;
    auto string = UTF8CString::newUninitialized(static_cast<size_t>(length), characters);
    if (context.copyString(name, lend(asMutableByteSpan(characters)).view()) != length)
        return { };
    return string;
}

GCGLfloat GraphicsContextGLANGLE::getTexParameterf(GCGLenum target, GCGLenum pname)
{
    return m_island->context.getTexParameterf(target, pname);
}

GCGLint GraphicsContextGLANGLE::getTexParameteri(GCGLenum target, GCGLenum pname)
{
    return m_island->context.getTexParameteri(target, pname);
}

void GraphicsContextGLANGLE::getUniformfv(PlatformGLObject program, GCGLint location, std::span<GCGLfloat> value)
{
    m_island->context.getUniformfv(program, location, lend(value).view());
}

void GraphicsContextGLANGLE::getUniformiv(PlatformGLObject program, GCGLint location, std::span<GCGLint> value)
{
    m_island->context.getUniformiv(program, location, lend(value).view());
}

void GraphicsContextGLANGLE::getUniformuiv(PlatformGLObject program, GCGLint location, std::span<GCGLuint> value)
{
    m_island->context.getUniformuiv(program, location, lend(value).view());
}

GCGLsizeiptr GraphicsContextGLANGLE::getVertexAttribOffset(GCGLuint index, GCGLenum pname)
{
    return m_island->context.getVertexAttribOffset(index, pname);
}

void GraphicsContextGLANGLE::hint(GCGLenum target, GCGLenum mode)
{
    m_island->context.hint(target, mode);
}

GCGLboolean GraphicsContextGLANGLE::isBuffer(PlatformGLObject arg0)
{
    return m_island->context.isBuffer(arg0);
}

GCGLboolean GraphicsContextGLANGLE::isEnabled(GCGLenum cap)
{
    return m_island->context.isEnabled(cap);
}

GCGLboolean GraphicsContextGLANGLE::isFramebuffer(PlatformGLObject arg0)
{
    return m_island->context.isFramebuffer(arg0);
}

GCGLboolean GraphicsContextGLANGLE::isProgram(PlatformGLObject arg0)
{
    return m_island->context.isProgram(arg0);
}

GCGLboolean GraphicsContextGLANGLE::isRenderbuffer(PlatformGLObject arg0)
{
    return m_island->context.isRenderbuffer(arg0);
}

GCGLboolean GraphicsContextGLANGLE::isShader(PlatformGLObject arg0)
{
    return m_island->context.isShader(arg0);
}

GCGLboolean GraphicsContextGLANGLE::isTexture(PlatformGLObject arg0)
{
    return m_island->context.isTexture(arg0);
}

void GraphicsContextGLANGLE::lineWidth(GCGLfloat arg0)
{
    m_island->context.lineWidth(arg0);
}

void GraphicsContextGLANGLE::linkProgram(PlatformGLObject arg0)
{
    m_island->context.linkProgram(arg0);
}

void GraphicsContextGLANGLE::pixelStorei(GCGLenum pname, GCGLint param)
{
    m_island->context.pixelStorei(pname, param);
}

void GraphicsContextGLANGLE::polygonOffset(GCGLfloat factor, GCGLfloat units)
{
    m_island->context.polygonOffset(factor, units);
}

void GraphicsContextGLANGLE::readPixels(IntRect rect, GCGLenum format, GCGLenum type, std::span<uint8_t> data, GCGLint alignment, GCGLint rowLength, GCGLboolean reverseRowOrder)
{
    m_island->context.readPixels(rect.x(), rect.y(), rect.width(), rect.height(), format, type, lend(data).view(), alignment, rowLength, reverseRowOrder);
}

void GraphicsContextGLANGLE::readPixelsBufferObject(IntRect rect, GCGLenum format, GCGLenum type, GCGLintptr offset, GCGLint alignment, GCGLint rowLength)
{
    m_island->context.readPixelsBufferObject(rect.x(), rect.y(), rect.width(), rect.height(), format, type, offset, alignment, rowLength);
}

void GraphicsContextGLANGLE::renderbufferStorage(GCGLenum target, GCGLenum internalformat, GCGLsizei width, GCGLsizei height)
{
    m_island->context.renderbufferStorage(target, internalformat, width, height);
}

void GraphicsContextGLANGLE::sampleCoverage(GCGLclampf value, GCGLboolean invert)
{
    m_island->context.sampleCoverage(value, invert);
}

void GraphicsContextGLANGLE::scissor(GCGLint x, GCGLint y, GCGLsizei width, GCGLsizei height)
{
    m_island->context.scissor(x, y, width, height);
}

void GraphicsContextGLANGLE::shaderSource(PlatformGLObject shader, const UTF8CString& source)
{
    m_island->context.shaderSource(shader, lendCString(source).view());
}

void GraphicsContextGLANGLE::stencilFunc(GCGLenum func, GCGLint ref, GCGLuint mask)
{
    m_island->context.stencilFunc(func, ref, mask);
}

void GraphicsContextGLANGLE::stencilFuncSeparate(GCGLenum face, GCGLenum func, GCGLint ref, GCGLuint mask)
{
    m_island->context.stencilFuncSeparate(face, func, ref, mask);
}

void GraphicsContextGLANGLE::stencilMask(GCGLuint mask)
{
    m_island->context.stencilMask(mask);
}

void GraphicsContextGLANGLE::stencilMaskSeparate(GCGLenum face, GCGLuint mask)
{
    m_island->context.stencilMaskSeparate(face, mask);
}

void GraphicsContextGLANGLE::stencilOp(GCGLenum fail, GCGLenum zfail, GCGLenum zpass)
{
    m_island->context.stencilOp(fail, zfail, zpass);
}

void GraphicsContextGLANGLE::stencilOpSeparate(GCGLenum face, GCGLenum fail, GCGLenum zfail, GCGLenum zpass)
{
    m_island->context.stencilOpSeparate(face, fail, zfail, zpass);
}

void GraphicsContextGLANGLE::texImage2D(GCGLenum target, GCGLint level, GCGLenum internalformat, GCGLsizei width, GCGLsizei height, GCGLint border, GCGLenum format, GCGLenum type, std::span<const uint8_t> pixels)
{
    m_island->context.texImage2D(target, level, internalformat, width, height, border, format, type, lend(pixels).view());
}

void GraphicsContextGLANGLE::texImage2D(GCGLenum target, GCGLint level, GCGLenum internalformat, GCGLsizei width, GCGLsizei height, GCGLint border, GCGLenum format, GCGLenum type, GCGLintptr offset)
{
    m_island->context.texImage2DFromUnpackBuffer(target, level, internalformat, width, height, border, format, type, offset);
}

void GraphicsContextGLANGLE::texSubImage2D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLsizei width, GCGLsizei height, GCGLenum format, GCGLenum type, std::span<const uint8_t> pixels)
{
    m_island->context.texSubImage2D(target, level, xoffset, yoffset, width, height, format, type, lend(pixels).view());
}

void GraphicsContextGLANGLE::texSubImage2D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLsizei width, GCGLsizei height, GCGLenum format, GCGLenum type, GCGLintptr offset)
{
    m_island->context.texSubImage2DFromUnpackBuffer(target, level, xoffset, yoffset, width, height, format, type, offset);
}

void GraphicsContextGLANGLE::compressedTexImage2D(GCGLenum target, GCGLint level, GCGLenum internalformat, GCGLsizei width, GCGLsizei height, GCGLint border, std::span<const uint8_t> data)
{
    m_island->context.compressedTexImage2D(target, level, internalformat, width, height, border, lend(data).view());
}

void GraphicsContextGLANGLE::compressedTexImage2D(GCGLenum target, GCGLint level, GCGLenum internalformat, GCGLsizei width, GCGLsizei height, GCGLint border, GCGLsizei imageSize, GCGLintptr offset)
{
    m_island->context.compressedTexImage2DFromUnpackBuffer(target, level, internalformat, width, height, border, imageSize, offset);
}

void GraphicsContextGLANGLE::compressedTexSubImage2D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLsizei width, GCGLsizei height, GCGLenum format, std::span<const uint8_t> data)
{
    m_island->context.compressedTexSubImage2D(target, level, xoffset, yoffset, width, height, format, lend(data).view());
}

void GraphicsContextGLANGLE::compressedTexSubImage2D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLsizei width, GCGLsizei height, GCGLenum format, GCGLsizei imageSize, GCGLintptr offset)
{
    m_island->context.compressedTexSubImage2DFromUnpackBuffer(target, level, xoffset, yoffset, width, height, format, imageSize, offset);
}

void GraphicsContextGLANGLE::texParameterf(GCGLenum target, GCGLenum pname, GCGLfloat param)
{
    m_island->context.texParameterf(target, pname, param);
}

void GraphicsContextGLANGLE::texParameteri(GCGLenum target, GCGLenum pname, GCGLint param)
{
    m_island->context.texParameteri(target, pname, param);
}

void GraphicsContextGLANGLE::uniform1f(GCGLint location, GCGLfloat x)
{
    m_island->context.uniform1f(location, x);
}

void GraphicsContextGLANGLE::uniform1fv(GCGLint location, std::span<const GCGLfloat> v)
{
    m_island->context.uniform1fv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform1i(GCGLint location, GCGLint x)
{
    m_island->context.uniform1i(location, x);
}

void GraphicsContextGLANGLE::uniform1iv(GCGLint location, std::span<const GCGLint> v)
{
    m_island->context.uniform1iv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform2f(GCGLint location, GCGLfloat x, GCGLfloat y)
{
    m_island->context.uniform2f(location, x, y);
}

void GraphicsContextGLANGLE::uniform2fv(GCGLint location, std::span<const GCGLfloat> v)
{
    m_island->context.uniform2fv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform2i(GCGLint location, GCGLint x, GCGLint y)
{
    m_island->context.uniform2i(location, x, y);
}

void GraphicsContextGLANGLE::uniform2iv(GCGLint location, std::span<const GCGLint> v)
{
    m_island->context.uniform2iv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform3f(GCGLint location, GCGLfloat x, GCGLfloat y, GCGLfloat z)
{
    m_island->context.uniform3f(location, x, y, z);
}

void GraphicsContextGLANGLE::uniform3fv(GCGLint location, std::span<const GCGLfloat> v)
{
    m_island->context.uniform3fv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform3i(GCGLint location, GCGLint x, GCGLint y, GCGLint z)
{
    m_island->context.uniform3i(location, x, y, z);
}

void GraphicsContextGLANGLE::uniform3iv(GCGLint location, std::span<const GCGLint> v)
{
    m_island->context.uniform3iv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform4f(GCGLint location, GCGLfloat x, GCGLfloat y, GCGLfloat z, GCGLfloat w)
{
    m_island->context.uniform4f(location, x, y, z, w);
}

void GraphicsContextGLANGLE::uniform4fv(GCGLint location, std::span<const GCGLfloat> v)
{
    m_island->context.uniform4fv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform4i(GCGLint location, GCGLint x, GCGLint y, GCGLint z, GCGLint w)
{
    m_island->context.uniform4i(location, x, y, z, w);
}

void GraphicsContextGLANGLE::uniform4iv(GCGLint location, std::span<const GCGLint> v)
{
    m_island->context.uniform4iv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniformMatrix2fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> value)
{
    m_island->context.uniformMatrix2fv(location, transpose, lend(value).view());
}

void GraphicsContextGLANGLE::uniformMatrix3fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> value)
{
    m_island->context.uniformMatrix3fv(location, transpose, lend(value).view());
}

void GraphicsContextGLANGLE::uniformMatrix4fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> value)
{
    m_island->context.uniformMatrix4fv(location, transpose, lend(value).view());
}

void GraphicsContextGLANGLE::useProgram(PlatformGLObject arg0)
{
    m_island->context.useProgram(arg0);
}

void GraphicsContextGLANGLE::validateProgram(PlatformGLObject arg0)
{
    m_island->context.validateProgram(arg0);
}

void GraphicsContextGLANGLE::vertexAttrib1f(GCGLuint index, GCGLfloat x)
{
    m_island->context.vertexAttrib1f(index, x);
}

void GraphicsContextGLANGLE::vertexAttrib1fv(GCGLuint index, std::span<const GCGLfloat, 1> values)
{
    m_island->context.vertexAttrib1fv(index, values[0]);
}

void GraphicsContextGLANGLE::vertexAttrib2f(GCGLuint index, GCGLfloat x, GCGLfloat y)
{
    m_island->context.vertexAttrib2f(index, x, y);
}

void GraphicsContextGLANGLE::vertexAttrib2fv(GCGLuint index, std::span<const GCGLfloat, 2> values)
{
    m_island->context.vertexAttrib2fv(index, values[0], values[1]);
}

void GraphicsContextGLANGLE::vertexAttrib3f(GCGLuint index, GCGLfloat x, GCGLfloat y, GCGLfloat z)
{
    m_island->context.vertexAttrib3f(index, x, y, z);
}

void GraphicsContextGLANGLE::vertexAttrib3fv(GCGLuint index, std::span<const GCGLfloat, 3> values)
{
    m_island->context.vertexAttrib3fv(index, values[0], values[1], values[2]);
}

void GraphicsContextGLANGLE::vertexAttrib4f(GCGLuint index, GCGLfloat x, GCGLfloat y, GCGLfloat z, GCGLfloat w)
{
    m_island->context.vertexAttrib4f(index, x, y, z, w);
}

void GraphicsContextGLANGLE::vertexAttrib4fv(GCGLuint index, std::span<const GCGLfloat, 4> values)
{
    m_island->context.vertexAttrib4fv(index, values[0], values[1], values[2], values[3]);
}

void GraphicsContextGLANGLE::vertexAttribPointer(GCGLuint index, GCGLint size, GCGLenum type, GCGLboolean normalized, GCGLsizei stride, GCGLintptr offset)
{
    m_island->context.vertexAttribPointer(index, size, type, normalized, stride, offset);
}

void GraphicsContextGLANGLE::viewport(GCGLint x, GCGLint y, GCGLsizei width, GCGLsizei height)
{
    m_island->context.viewport(x, y, width, height);
}

void GraphicsContextGLANGLE::reshape(int width, int height)
{
    m_island->context.reshape(width, height);
}

void GraphicsContextGLANGLE::drawArraysInstanced(GCGLenum mode, GCGLint first, GCGLsizei count, GCGLsizei primcount)
{
    m_island->context.drawArraysInstanced(mode, first, count, primcount);
}

void GraphicsContextGLANGLE::drawElementsInstanced(GCGLenum mode, GCGLsizei count, GCGLenum type, GCGLintptr offset, GCGLsizei primcount)
{
    m_island->context.drawElementsInstanced(mode, count, type, offset, primcount);
}

void GraphicsContextGLANGLE::vertexAttribDivisor(GCGLuint index, GCGLuint divisor)
{
    m_island->context.vertexAttribDivisor(index, divisor);
}

PlatformGLObject GraphicsContextGLANGLE::createVertexArray()
{
    return m_island->context.createVertexArray();
}

void GraphicsContextGLANGLE::deleteVertexArray(PlatformGLObject arg0)
{
    m_island->context.deleteVertexArray(arg0);
}

GCGLboolean GraphicsContextGLANGLE::isVertexArray(PlatformGLObject arg0)
{
    return m_island->context.isVertexArray(arg0);
}

void GraphicsContextGLANGLE::bindVertexArray(PlatformGLObject arg0)
{
    m_island->context.bindVertexArray(arg0);
}

void GraphicsContextGLANGLE::copyBufferSubData(GCGLenum readTarget, GCGLenum writeTarget, GCGLintptr readOffset, GCGLintptr writeOffset, GCGLsizeiptr arg4)
{
    m_island->context.copyBufferSubData(readTarget, writeTarget, readOffset, writeOffset, arg4);
}

void GraphicsContextGLANGLE::getBufferSubData(GCGLenum target, GCGLintptr offset, std::span<uint8_t> data)
{
    m_island->context.getBufferSubData(target, offset, lend(data).view());
}

void GraphicsContextGLANGLE::blitFramebuffer(GCGLint srcX0, GCGLint srcY0, GCGLint srcX1, GCGLint srcY1, GCGLint dstX0, GCGLint dstY0, GCGLint dstX1, GCGLint dstY1, GCGLbitfield mask, GCGLenum filter)
{
    m_island->context.blitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter);
}

void GraphicsContextGLANGLE::framebufferTextureLayer(GCGLenum target, GCGLenum attachment, PlatformGLObject texture, GCGLint level, GCGLint layer)
{
    m_island->context.framebufferTextureLayer(target, attachment, texture, level, layer);
}

void GraphicsContextGLANGLE::invalidateFramebuffer(GCGLenum target, std::span<const GCGLenum> attachments)
{
    m_island->context.invalidateFramebuffer(target, lend(attachments).view());
}

void GraphicsContextGLANGLE::invalidateSubFramebuffer(GCGLenum target, std::span<const GCGLenum> attachments, GCGLint x, GCGLint y, GCGLsizei width, GCGLsizei height)
{
    m_island->context.invalidateSubFramebuffer(target, lend(attachments).view(), x, y, width, height);
}

void GraphicsContextGLANGLE::readBuffer(GCGLenum src)
{
    m_island->context.readBuffer(src);
}

void GraphicsContextGLANGLE::getInternalformativ(GCGLenum target, GCGLenum internalformat, GCGLenum pname, std::span<GCGLint> data)
{
    m_island->context.getInternalformativ(target, internalformat, pname, lend(data).view());
}

void GraphicsContextGLANGLE::renderbufferStorageMultisample(GCGLenum target, GCGLsizei samples, GCGLenum internalformat, GCGLsizei width, GCGLsizei height)
{
    m_island->context.renderbufferStorageMultisample(target, samples, internalformat, width, height);
}

void GraphicsContextGLANGLE::texStorage2D(GCGLenum target, GCGLsizei levels, GCGLenum internalformat, GCGLsizei width, GCGLsizei height)
{
    m_island->context.texStorage2D(target, levels, internalformat, width, height);
}

void GraphicsContextGLANGLE::texStorage3D(GCGLenum target, GCGLsizei levels, GCGLenum internalformat, GCGLsizei width, GCGLsizei height, GCGLsizei depth)
{
    m_island->context.texStorage3D(target, levels, internalformat, width, height, depth);
}

void GraphicsContextGLANGLE::texImage3D(GCGLenum target, GCGLint level, GCGLint internalformat, GCGLsizei width, GCGLsizei height, GCGLsizei depth, GCGLint border, GCGLenum format, GCGLenum type, std::span<const uint8_t> pixels)
{
    m_island->context.texImage3D(target, level, internalformat, width, height, depth, border, format, type, lend(pixels).view());
}

void GraphicsContextGLANGLE::texImage3D(GCGLenum target, GCGLint level, GCGLint internalformat, GCGLsizei width, GCGLsizei height, GCGLsizei depth, GCGLint border, GCGLenum format, GCGLenum type, GCGLintptr offset)
{
    m_island->context.texImage3DFromUnpackBuffer(target, level, internalformat, width, height, depth, border, format, type, offset);
}

void GraphicsContextGLANGLE::texSubImage3D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLint zoffset, GCGLsizei width, GCGLsizei height, GCGLsizei depth, GCGLenum format, GCGLenum type, std::span<const uint8_t> pixels)
{
    m_island->context.texSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, lend(pixels).view());
}

void GraphicsContextGLANGLE::texSubImage3D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLint zoffset, GCGLsizei width, GCGLsizei height, GCGLsizei depth, GCGLenum format, GCGLenum type, GCGLintptr offset)
{
    m_island->context.texSubImage3DFromUnpackBuffer(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, offset);
}

void GraphicsContextGLANGLE::copyTexSubImage3D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLint zoffset, GCGLint x, GCGLint y, GCGLsizei width, GCGLsizei height)
{
    m_island->context.copyTexSubImage3D(target, level, xoffset, yoffset, zoffset, x, y, width, height);
}

void GraphicsContextGLANGLE::compressedTexImage3D(GCGLenum target, GCGLint level, GCGLenum internalformat, GCGLsizei width, GCGLsizei height, GCGLsizei depth, GCGLint border, std::span<const uint8_t> data)
{
    m_island->context.compressedTexImage3D(target, level, internalformat, width, height, depth, border, lend(data).view());
}

void GraphicsContextGLANGLE::compressedTexImage3D(GCGLenum target, GCGLint level, GCGLenum internalformat, GCGLsizei width, GCGLsizei height, GCGLsizei depth, GCGLint border, GCGLsizei imageSize, GCGLintptr offset)
{
    m_island->context.compressedTexImage3DFromUnpackBuffer(target, level, internalformat, width, height, depth, border, imageSize, offset);
}

void GraphicsContextGLANGLE::compressedTexSubImage3D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLint zoffset, GCGLsizei width, GCGLsizei height, GCGLsizei depth, GCGLenum format, std::span<const uint8_t> data)
{
    m_island->context.compressedTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, lend(data).view());
}

void GraphicsContextGLANGLE::compressedTexSubImage3D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLint zoffset, GCGLsizei width, GCGLsizei height, GCGLsizei depth, GCGLenum format, GCGLsizei imageSize, GCGLintptr offset)
{
    m_island->context.compressedTexSubImage3DFromUnpackBuffer(target, level, xoffset, yoffset, zoffset, width, height, depth, format, imageSize, offset);
}

GCGLint GraphicsContextGLANGLE::getFragDataLocation(PlatformGLObject program, const UTF8CString& name)
{
    return m_island->context.getFragDataLocation(program, lendCString(name).view());
}

void GraphicsContextGLANGLE::uniform1ui(GCGLint location, GCGLuint v0)
{
    m_island->context.uniform1ui(location, v0);
}

void GraphicsContextGLANGLE::uniform2ui(GCGLint location, GCGLuint v0, GCGLuint v1)
{
    m_island->context.uniform2ui(location, v0, v1);
}

void GraphicsContextGLANGLE::uniform3ui(GCGLint location, GCGLuint v0, GCGLuint v1, GCGLuint v2)
{
    m_island->context.uniform3ui(location, v0, v1, v2);
}

void GraphicsContextGLANGLE::uniform4ui(GCGLint location, GCGLuint v0, GCGLuint v1, GCGLuint v2, GCGLuint v3)
{
    m_island->context.uniform4ui(location, v0, v1, v2, v3);
}

void GraphicsContextGLANGLE::uniform1uiv(GCGLint location, std::span<const GCGLuint> arg1)
{
    m_island->context.uniform1uiv(location, lend(arg1).view());
}

void GraphicsContextGLANGLE::uniform2uiv(GCGLint location, std::span<const GCGLuint> arg1)
{
    m_island->context.uniform2uiv(location, lend(arg1).view());
}

void GraphicsContextGLANGLE::uniform3uiv(GCGLint location, std::span<const GCGLuint> arg1)
{
    m_island->context.uniform3uiv(location, lend(arg1).view());
}

void GraphicsContextGLANGLE::uniform4uiv(GCGLint location, std::span<const GCGLuint> arg1)
{
    m_island->context.uniform4uiv(location, lend(arg1).view());
}

void GraphicsContextGLANGLE::uniformMatrix2x3fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> data)
{
    m_island->context.uniformMatrix2x3fv(location, transpose, lend(data).view());
}

void GraphicsContextGLANGLE::uniformMatrix3x2fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> data)
{
    m_island->context.uniformMatrix3x2fv(location, transpose, lend(data).view());
}

void GraphicsContextGLANGLE::uniformMatrix2x4fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> data)
{
    m_island->context.uniformMatrix2x4fv(location, transpose, lend(data).view());
}

void GraphicsContextGLANGLE::uniformMatrix4x2fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> data)
{
    m_island->context.uniformMatrix4x2fv(location, transpose, lend(data).view());
}

void GraphicsContextGLANGLE::uniformMatrix3x4fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> data)
{
    m_island->context.uniformMatrix3x4fv(location, transpose, lend(data).view());
}

void GraphicsContextGLANGLE::uniformMatrix4x3fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> data)
{
    m_island->context.uniformMatrix4x3fv(location, transpose, lend(data).view());
}

void GraphicsContextGLANGLE::vertexAttribI4i(GCGLuint index, GCGLint x, GCGLint y, GCGLint z, GCGLint w)
{
    m_island->context.vertexAttribI4i(index, x, y, z, w);
}

void GraphicsContextGLANGLE::vertexAttribI4iv(GCGLuint index, std::span<const GCGLint, 4> values)
{
    m_island->context.vertexAttribI4iv(index, values[0], values[1], values[2], values[3]);
}

void GraphicsContextGLANGLE::vertexAttribI4ui(GCGLuint index, GCGLuint x, GCGLuint y, GCGLuint z, GCGLuint w)
{
    m_island->context.vertexAttribI4ui(index, x, y, z, w);
}

void GraphicsContextGLANGLE::vertexAttribI4uiv(GCGLuint index, std::span<const GCGLuint, 4> values)
{
    m_island->context.vertexAttribI4uiv(index, values[0], values[1], values[2], values[3]);
}

void GraphicsContextGLANGLE::vertexAttribIPointer(GCGLuint index, GCGLint size, GCGLenum type, GCGLsizei stride, GCGLintptr offset)
{
    m_island->context.vertexAttribIPointer(index, size, type, stride, offset);
}

void GraphicsContextGLANGLE::drawRangeElements(GCGLenum mode, GCGLuint start, GCGLuint end, GCGLsizei count, GCGLenum type, GCGLintptr offset)
{
    m_island->context.drawRangeElements(mode, start, end, count, type, offset);
}

void GraphicsContextGLANGLE::drawBuffers(std::span<const GCGLenum> bufs)
{
    m_island->context.drawBuffers(lend(bufs).view());
}

void GraphicsContextGLANGLE::clearBufferiv(GCGLenum buffer, GCGLint drawbuffer, std::span<const GCGLint> values)
{
    m_island->context.clearBufferiv(buffer, drawbuffer, lend(values).view());
}

void GraphicsContextGLANGLE::clearBufferuiv(GCGLenum buffer, GCGLint drawbuffer, std::span<const GCGLuint> values)
{
    m_island->context.clearBufferuiv(buffer, drawbuffer, lend(values).view());
}

void GraphicsContextGLANGLE::clearBufferfv(GCGLenum buffer, GCGLint drawbuffer, std::span<const GCGLfloat> values)
{
    m_island->context.clearBufferfv(buffer, drawbuffer, lend(values).view());
}

void GraphicsContextGLANGLE::clearBufferfi(GCGLenum buffer, GCGLint drawbuffer, GCGLfloat depth, GCGLint stencil)
{
    m_island->context.clearBufferfi(buffer, drawbuffer, depth, stencil);
}

PlatformGLObject GraphicsContextGLANGLE::createQuery()
{
    return m_island->context.createQuery();
}

void GraphicsContextGLANGLE::deleteQuery(PlatformGLObject query)
{
    m_island->context.deleteQuery(query);
}

GCGLboolean GraphicsContextGLANGLE::isQuery(PlatformGLObject query)
{
    return m_island->context.isQuery(query);
}

void GraphicsContextGLANGLE::beginQuery(GCGLenum target, PlatformGLObject query)
{
    m_island->context.beginQuery(target, query);
}

void GraphicsContextGLANGLE::endQuery(GCGLenum target)
{
    m_island->context.endQuery(target);
}

GCGLint GraphicsContextGLANGLE::getQuery(GCGLenum target, GCGLenum pname)
{
    return m_island->context.getQuery(target, pname);
}

GCGLuint GraphicsContextGLANGLE::getQueryObjectui(PlatformGLObject query, GCGLenum pname)
{
    return m_island->context.getQueryObjectui(query, pname);
}

PlatformGLObject GraphicsContextGLANGLE::createSampler()
{
    return m_island->context.createSampler();
}

void GraphicsContextGLANGLE::deleteSampler(PlatformGLObject sampler)
{
    m_island->context.deleteSampler(sampler);
}

GCGLboolean GraphicsContextGLANGLE::isSampler(PlatformGLObject sampler)
{
    return m_island->context.isSampler(sampler);
}

void GraphicsContextGLANGLE::bindSampler(GCGLuint unit, PlatformGLObject sampler)
{
    m_island->context.bindSampler(unit, sampler);
}

void GraphicsContextGLANGLE::samplerParameteri(PlatformGLObject sampler, GCGLenum pname, GCGLint param)
{
    m_island->context.samplerParameteri(sampler, pname, param);
}

void GraphicsContextGLANGLE::samplerParameterf(PlatformGLObject sampler, GCGLenum pname, GCGLfloat param)
{
    m_island->context.samplerParameterf(sampler, pname, param);
}

GCGLfloat GraphicsContextGLANGLE::getSamplerParameterf(PlatformGLObject sampler, GCGLenum pname)
{
    return m_island->context.getSamplerParameterf(sampler, pname);
}

GCGLint GraphicsContextGLANGLE::getSamplerParameteri(PlatformGLObject sampler, GCGLenum pname)
{
    return m_island->context.getSamplerParameteri(sampler, pname);
}

GCGLsync GraphicsContextGLANGLE::fenceSync(GCGLenum condition, GCGLbitfield flags)
{
    return reinterpret_cast<GCGLsync>(static_cast<uintptr_t>(m_island->context.fenceSync(condition, flags)));
}

GCGLboolean GraphicsContextGLANGLE::isSync(GCGLsync sync)
{
    return m_island->context.isSync(reinterpret_cast<uintptr_t>(sync));
}

void GraphicsContextGLANGLE::deleteSync(GCGLsync sync)
{
    m_island->context.deleteSync(reinterpret_cast<uintptr_t>(sync));
}

GCGLenum GraphicsContextGLANGLE::clientWaitSync(GCGLsync sync, GCGLbitfield flags, GCGLuint64 timeout)
{
    return m_island->context.clientWaitSync(reinterpret_cast<uintptr_t>(sync), flags, timeout);
}

void GraphicsContextGLANGLE::waitSync(GCGLsync sync, GCGLbitfield flags, GCGLint64 timeout)
{
    m_island->context.waitSync(reinterpret_cast<uintptr_t>(sync), flags, timeout);
}

GCGLint GraphicsContextGLANGLE::getSynci(GCGLsync sync, GCGLenum pname)
{
    return m_island->context.getSynci(reinterpret_cast<uintptr_t>(sync), pname);
}

PlatformGLObject GraphicsContextGLANGLE::createTransformFeedback()
{
    return m_island->context.createTransformFeedback();
}

void GraphicsContextGLANGLE::deleteTransformFeedback(PlatformGLObject id)
{
    m_island->context.deleteTransformFeedback(id);
}

GCGLboolean GraphicsContextGLANGLE::isTransformFeedback(PlatformGLObject id)
{
    return m_island->context.isTransformFeedback(id);
}

void GraphicsContextGLANGLE::bindTransformFeedback(GCGLenum target, PlatformGLObject id)
{
    m_island->context.bindTransformFeedback(target, id);
}

void GraphicsContextGLANGLE::beginTransformFeedback(GCGLenum primitiveMode)
{
    m_island->context.beginTransformFeedback(primitiveMode);
}

void GraphicsContextGLANGLE::endTransformFeedback()
{
    m_island->context.endTransformFeedback();
}

void GraphicsContextGLANGLE::transformFeedbackVaryings(PlatformGLObject program, const Vector<UTF8CString>& varyings, GCGLenum bufferMode)
{
    Vector<const char*> pointersToVaryings = varyings.map([](const UTF8CString& varying) {
        return varying.legacyCStringPointer();
    });
    m_island->context.transformFeedbackVaryings(program, lend(pointersToVaryings.span()).view(), bufferMode);
}

std::optional<GCGLTransformFeedbackActiveInfo> GraphicsContextGLANGLE::getTransformFeedbackVarying(PlatformGLObject program, GCGLuint index)
{
    auto& context = m_island->context;
    auto info = context.getTransformFeedbackVarying(program, index);
    if (!info.nameLength)
        return std::nullopt;
    auto name = copyIslandString(info.nameLength, [&](auto& view) { return context.copyLastVariableName(view); });
    context.clearActiveVariables();
    return GCGLTransformFeedbackActiveInfo { WTF::move(name), info.type, info.size };
}

void GraphicsContextGLANGLE::pauseTransformFeedback()
{
    m_island->context.pauseTransformFeedback();
}

void GraphicsContextGLANGLE::resumeTransformFeedback()
{
    m_island->context.resumeTransformFeedback();
}

void GraphicsContextGLANGLE::bindBufferBase(GCGLenum target, GCGLuint index, PlatformGLObject buffer)
{
    m_island->context.bindBufferBase(target, index, buffer);
}

void GraphicsContextGLANGLE::bindBufferRange(GCGLenum target, GCGLuint index, PlatformGLObject buffer, GCGLintptr offset, GCGLsizeiptr arg4)
{
    m_island->context.bindBufferRange(target, index, buffer, offset, arg4);
}

GCGLuint GraphicsContextGLANGLE::getUniformBlockIndex(PlatformGLObject program, const UTF8CString& uniformBlockName)
{
    return m_island->context.getUniformBlockIndex(program, lendCString(uniformBlockName).view());
}

UTF8CString GraphicsContextGLANGLE::getActiveUniformBlockName(PlatformGLObject program, GCGLuint uniformBlockIndex)
{
    auto& context = m_island->context;
    GCGLint maxLength = context.activeUniformBlockNameLength(program);
    if (maxLength < 0)
        return { };
    // GL_ACTIVE_UNIFORM_BLOCK_MAX_NAME_LENGTH includes nul termination.
    Vector<uint8_t, 64> buffer(static_cast<size_t>(maxLength));
    GCGLsizei length = context.getActiveUniformBlockName(program, uniformBlockIndex, lend(buffer.mutableSpan()).view());
    if (!length)
        return { };
    return UTF8CString { byteCast<char8_t>(buffer.span().first(length)) };
}

void GraphicsContextGLANGLE::uniformBlockBinding(PlatformGLObject program, GCGLuint uniformBlockIndex, GCGLuint uniformBlockBinding)
{
    m_island->context.uniformBlockBinding(program, uniformBlockIndex, uniformBlockBinding);
}

void GraphicsContextGLANGLE::getActiveUniformBlockiv(PlatformGLObject program, GCGLuint uniformBlockIndex, GCGLenum pname, std::span<GCGLint> params)
{
    m_island->context.getActiveUniformBlockiv(program, uniformBlockIndex, pname, lend(params).view());
}

#if ENABLE(WEBXR)
GCGLExternalImage GraphicsContextGLANGLE::createExternalImage(ExternalImageSource&&, GCGLenum, GCGLint)
{
    notImplemented();
    return { };
}
#endif

#if ENABLE(WEBXR)
void GraphicsContextGLANGLE::deleteExternalImage(GCGLExternalImage image)
{
    m_island->context.deleteExternalImage(image);
}
#endif

#if ENABLE(WEBXR)
void GraphicsContextGLANGLE::bindExternalImage(GCGLenum, GCGLExternalImage)
{
    notImplemented();
}
#endif

#if ENABLE(WEBXR)
GCGLExternalSync GraphicsContextGLANGLE::createExternalSync(ExternalSyncSource&&)
{
    notImplemented();
    return { };
}
#endif

#if ENABLE(WEBXR)
void GraphicsContextGLANGLE::deleteExternalSync(GCGLExternalSync sync)
{
    m_island->context.deleteExternalSync(sync);
}
#endif

#if ENABLE(WEBXR)
void GraphicsContextGLANGLE::framebufferDiscard(GCGLenum target, std::span<const GCGLenum> attachments)
{
    m_island->context.framebufferDiscard(target, lend(attachments).view());
}
#endif

void GraphicsContextGLANGLE::multiDrawArraysANGLE(GCGLenum mode, GCGLSpanTuple<const GCGLint, const GCGLsizei> firstsAndCounts)
{
    m_island->context.multiDrawArraysANGLE(mode, lend(firstsAndCounts.span<0>()).view(), lend(firstsAndCounts.span<1>()).view(), firstsAndCounts.bufSize);
}

void GraphicsContextGLANGLE::multiDrawArraysInstancedANGLE(GCGLenum mode, GCGLSpanTuple<const GCGLint, const GCGLsizei, const GCGLsizei> firstsCountsAndInstanceCounts)
{
    auto& t = firstsCountsAndInstanceCounts;
    m_island->context.multiDrawArraysInstancedANGLE(mode, lend(t.span<0>()).view(), lend(t.span<1>()).view(), lend(t.span<2>()).view(), t.bufSize);
}

void GraphicsContextGLANGLE::multiDrawElementsANGLE(GCGLenum mode, GCGLSpanTuple<const GCGLsizei, const GCGLsizei> countsAndOffsets, GCGLenum type)
{
    auto& t = countsAndOffsets;
    m_island->context.multiDrawElementsANGLE(mode, lend(t.span<0>()).view(), lend(t.span<1>()).view(), type, t.bufSize);
}

void GraphicsContextGLANGLE::multiDrawElementsInstancedANGLE(GCGLenum mode, GCGLSpanTuple<const GCGLsizei, const GCGLsizei, const GCGLsizei> countsOffsetsAndInstanceCounts, GCGLenum type)
{
    auto& t = countsOffsetsAndInstanceCounts;
    m_island->context.multiDrawElementsInstancedANGLE(mode, lend(t.span<0>()).view(), lend(t.span<1>()).view(), lend(t.span<2>()).view(), type, t.bufSize);
}

bool GraphicsContextGLANGLE::enableExtension(GCGLExtension extension)
{
    bool result = m_island->context.enableExtension(std::to_underlying(extension));
    m_knownActiveExtensions = EnumSet<GCGLExtension>::fromRaw(m_island->context.knownActiveExtensions());
    return result;
}

void GraphicsContextGLANGLE::drawBuffersEXT(std::span<const GCGLenum> arg0)
{
    m_island->context.drawBuffersEXT(lend(arg0).view());
}

UTF8CString GraphicsContextGLANGLE::getTranslatedShaderSourceANGLE(PlatformGLObject shader)
{
    auto& context = m_island->context;
    return copyIslandLog(context.translatedShaderSourceLength(shader), [&](auto& view) { return context.getTranslatedShaderSourceANGLE(shader, view); });
}

PlatformGLObject GraphicsContextGLANGLE::createQueryEXT()
{
    return m_island->context.createQueryEXT();
}

void GraphicsContextGLANGLE::deleteQueryEXT(PlatformGLObject query)
{
    m_island->context.deleteQueryEXT(query);
}

GCGLboolean GraphicsContextGLANGLE::isQueryEXT(PlatformGLObject query)
{
    return m_island->context.isQueryEXT(query);
}

void GraphicsContextGLANGLE::beginQueryEXT(GCGLenum target, PlatformGLObject query)
{
    m_island->context.beginQueryEXT(target, query);
}

void GraphicsContextGLANGLE::endQueryEXT(GCGLenum target)
{
    m_island->context.endQueryEXT(target);
}

void GraphicsContextGLANGLE::queryCounterEXT(PlatformGLObject query, GCGLenum target)
{
    m_island->context.queryCounterEXT(query, target);
}

GCGLint GraphicsContextGLANGLE::getQueryiEXT(GCGLenum target, GCGLenum pname)
{
    return m_island->context.getQueryiEXT(target, pname);
}

GCGLint GraphicsContextGLANGLE::getQueryObjectiEXT(PlatformGLObject query, GCGLenum pname)
{
    return m_island->context.getQueryObjectiEXT(query, pname);
}

GCGLuint64 GraphicsContextGLANGLE::getQueryObjectui64EXT(PlatformGLObject query, GCGLenum pname)
{
    return m_island->context.getQueryObjectui64EXT(query, pname);
}

GCGLint64 GraphicsContextGLANGLE::getInteger64EXT(GCGLenum pname)
{
    return m_island->context.getInteger64EXT(pname);
}

void GraphicsContextGLANGLE::enableiOES(GCGLenum target, GCGLuint index)
{
    m_island->context.enableiOES(target, index);
}

void GraphicsContextGLANGLE::disableiOES(GCGLenum target, GCGLuint index)
{
    m_island->context.disableiOES(target, index);
}

void GraphicsContextGLANGLE::blendEquationiOES(GCGLuint buf, GCGLenum mode)
{
    m_island->context.blendEquationiOES(buf, mode);
}

void GraphicsContextGLANGLE::blendEquationSeparateiOES(GCGLuint buf, GCGLenum modeRGB, GCGLenum modeAlpha)
{
    m_island->context.blendEquationSeparateiOES(buf, modeRGB, modeAlpha);
}

void GraphicsContextGLANGLE::blendFunciOES(GCGLuint buf, GCGLenum src, GCGLenum dst)
{
    m_island->context.blendFunciOES(buf, src, dst);
}

void GraphicsContextGLANGLE::blendFuncSeparateiOES(GCGLuint buf, GCGLenum srcRGB, GCGLenum dstRGB, GCGLenum srcAlpha, GCGLenum dstAlpha)
{
    m_island->context.blendFuncSeparateiOES(buf, srcRGB, dstRGB, srcAlpha, dstAlpha);
}

void GraphicsContextGLANGLE::colorMaskiOES(GCGLuint buf, GCGLboolean red, GCGLboolean green, GCGLboolean blue, GCGLboolean alpha)
{
    m_island->context.colorMaskiOES(buf, red, green, blue, alpha);
}

void GraphicsContextGLANGLE::drawArraysInstancedBaseInstanceANGLE(GCGLenum mode, GCGLint first, GCGLsizei count, GCGLsizei instanceCount, GCGLuint baseInstance)
{
    m_island->context.drawArraysInstancedBaseInstanceANGLE(mode, first, count, instanceCount, baseInstance);
}

void GraphicsContextGLANGLE::drawElementsInstancedBaseVertexBaseInstanceANGLE(GCGLenum mode, GCGLsizei count, GCGLenum type, GCGLintptr offset, GCGLsizei instanceCount, GCGLint baseVertex, GCGLuint baseInstance)
{
    m_island->context.drawElementsInstancedBaseVertexBaseInstanceANGLE(mode, count, type, offset, instanceCount, baseVertex, baseInstance);
}

void GraphicsContextGLANGLE::multiDrawArraysInstancedBaseInstanceANGLE(GCGLenum mode, GCGLSpanTuple<const GCGLint, const GCGLsizei, const GCGLsizei, const GCGLuint> firstsCountsInstanceCountsAndBaseInstances)
{
    auto& t = firstsCountsInstanceCountsAndBaseInstances;
    m_island->context.multiDrawArraysInstancedBaseInstanceANGLE(mode, lend(t.span<0>()).view(), lend(t.span<1>()).view(), lend(t.span<2>()).view(), lend(t.span<3>()).view(), t.bufSize);
}

void GraphicsContextGLANGLE::multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(GCGLenum mode, GCGLSpanTuple<const GCGLsizei, const GCGLsizei, const GCGLsizei, const GCGLint, const GCGLuint> countsOffsetsInstanceCountsBaseVerticesAndBaseInstances, GCGLenum type)
{
    auto& t = countsOffsetsInstanceCountsBaseVerticesAndBaseInstances;
    m_island->context.multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(mode, lend(t.span<0>()).view(), lend(t.span<1>()).view(), lend(t.span<2>()).view(), lend(t.span<3>()).view(), lend(t.span<4>()).view(), type, t.bufSize);
}

void GraphicsContextGLANGLE::clipControlEXT(GCGLenum origin, GCGLenum depth)
{
    m_island->context.clipControlEXT(origin, depth);
}

void GraphicsContextGLANGLE::provokingVertexANGLE(GCGLenum provokeMode)
{
    m_island->context.provokingVertexANGLE(provokeMode);
}

void GraphicsContextGLANGLE::polygonModeANGLE(GCGLenum face, GCGLenum mode)
{
    m_island->context.polygonModeANGLE(face, mode);
}

void GraphicsContextGLANGLE::polygonOffsetClampEXT(GCGLfloat factor, GCGLfloat units, GCGLfloat clamp)
{
    m_island->context.polygonOffsetClampEXT(factor, units, clamp);
}

void GraphicsContextGLANGLE::renderbufferStorageMultisampleANGLE(GCGLenum target, GCGLsizei samples, GCGLenum internalformat, GCGLsizei width, GCGLsizei height)
{
    m_island->context.renderbufferStorageMultisampleANGLE(target, samples, internalformat, width, height);
}

PlatformGLObject GraphicsContextGLANGLE::createBuffer()
{
    return m_island->context.createBuffer();
}

PlatformGLObject GraphicsContextGLANGLE::createFramebuffer()
{
    return m_island->context.createFramebuffer();
}

PlatformGLObject GraphicsContextGLANGLE::createProgram()
{
    return m_island->context.createProgram();
}

PlatformGLObject GraphicsContextGLANGLE::createRenderbuffer()
{
    return m_island->context.createRenderbuffer();
}

PlatformGLObject GraphicsContextGLANGLE::createShader(GCGLenum arg0)
{
    return m_island->context.createShader(arg0);
}

PlatformGLObject GraphicsContextGLANGLE::createTexture()
{
    return m_island->context.createTexture();
}

void GraphicsContextGLANGLE::deleteBuffer(PlatformGLObject arg0)
{
    m_island->context.deleteBuffer(arg0);
}

void GraphicsContextGLANGLE::deleteFramebuffer(PlatformGLObject arg0)
{
    m_island->context.deleteFramebuffer(arg0);
}

void GraphicsContextGLANGLE::deleteProgram(PlatformGLObject arg0)
{
    m_island->context.deleteProgram(arg0);
}

void GraphicsContextGLANGLE::deleteRenderbuffer(PlatformGLObject arg0)
{
    m_island->context.deleteRenderbuffer(arg0);
}

void GraphicsContextGLANGLE::deleteShader(PlatformGLObject arg0)
{
    m_island->context.deleteShader(arg0);
}

void GraphicsContextGLANGLE::deleteTexture(PlatformGLObject arg0)
{
    m_island->context.deleteTexture(arg0);
}

void GraphicsContextGLANGLE::simulateEventForTesting(SimulatedEventForTesting event)
{
    m_island->context.simulateEventForTesting(std::to_underlying(event));
}
}

void GL_APIENTRY ANGLE::debugMessageTrampoline(GLenum, GLenum type, GLuint messageID, GLenum severity, GLsizei length, const GLchar* message, const void* contextID)
{
    if (!WebCoreWebGL::GLContext::reportsDebugMessage(type, messageID))
        return;
    WebCore::GLContextCallbacks::addDebugMessage(static_cast<uint64_t>(reinterpret_cast<uintptr_t>(contextID)), type, messageID, severity, byteCast<char8_t>(unsafeMakeSpan(message, length)));
}

#endif // ENABLE(WEBGL)
