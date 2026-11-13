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

#include "ImageBuffer.h"
#include "IntRect.h"
#include "IntSize.h"
#include "NativeImage.h"
#include "NotImplemented.h"
#include "TypedArrayPixelBuffer.h"
#include "WebCoreWebGL.h"
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

GLIslandCalls GraphicsContextGLANGLE::islandCalls() const
{
    return GLIslandCalls { m_islandShell };
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
    , m_islandShell(GLIslandCalls::createShell())
{
}

GraphicsContextGLANGLE::~GraphicsContextGLANGLE()
{
    auto island = islandCalls();
    if (island.hasContext()) {
        island.destroy();
        ASSERT(!island.isCurrent());
    }
    {
        Locker locker { contextsLock };
        contexts().remove(m_contextID);
        contextsGeneration.fetch_add(1, std::memory_order_release);
    }
    GLIslandCalls::destroyShell(m_islandShell);
}

std::optional<size_t> GraphicsContextGLANGLE::estimatedMemoryCost()
{
    auto cost = islandCalls().estimatedMemoryCost();
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

    createIslandContext();
    {
        Locker locker { contextsLock };
        contexts().add(m_contextID, this);
    }
    if (!islandCalls().initialize())
        return false;

    // EGL resources are only ever released if we run in process mode where EGL is used on host app threads, e.g. WK1
    // mode.
    static bool tracksUsedDisplays = !(isInWebProcess() || isInGPUProcess());
    if (tracksUsedDisplays) {
        // TODO: Move to ~GraphicsContextGLANGLE() when the function is moved to this file.
        ASSERT(m_displayObj);
        usedDisplays().add(m_displayObj);
    }

    m_knownActiveExtensions = EnumSet<GCGLExtension>::fromRaw(islandCalls().knownActiveExtensions());
    m_requestableExtensions = EnumSet<GCGLExtension>::fromRaw(islandCalls().requestableExtensions());
    return true;
}

void GraphicsContextGLANGLE::createIslandContext()
{
    islandCalls().createContext(m_contextID, wrapDisplay(m_displayObj), wrapContext(m_contextObj), m_isForWebGL2, contextAttributes().supportWebGLDraftExtensions);
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

#if PLATFORM(COCOA)
bool GraphicsContextGLANGLE::makeCurrent(GCGLDisplay display, GCGLContext context)
{
    return GLIslandCalls::makeCurrent(wrapDisplay(display), wrapContext(context));
}
#endif

void GraphicsContextGLANGLE::platformReleaseThreadResources()
{
    GLIslandCalls::forgetCurrentContext();
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

void GraphicsContextGLANGLE::forceContextLost()
{
    if (auto island = islandCalls(); island.hasContext())
        island.didForceContextLost();
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
    if (!islandCalls().readPixelsForPaintResults(lend(pixelBuffer->bytes()).view(), pixelBuffer->size().width(), pixelBuffer->size().height()))
        return nullptr;
    return pixelBuffer;
}

RefPtr<PixelBuffer> GraphicsContextGLANGLE::readRenderingResults()
{
    auto pixelBuffer = createPixelBufferForPaintResults();
    if (!pixelBuffer)
        return nullptr;
    if (!islandCalls().readRenderingResults(lend(pixelBuffer->bytes()).view(), pixelBuffer->size().width(), pixelBuffer->size().height()))
        return nullptr;
    return pixelBuffer;
}

void GraphicsContextGLANGLE::prepareTexture()
{
}

bool GraphicsContextGLANGLE::getBufferSubDataWithStatus(GCGLenum target, GCGLintptr offset, std::span<uint8_t> data)
{
    return islandCalls().getBufferSubData(target, offset, lend(data).view());
}

std::optional<IntSize> GraphicsContextGLANGLE::readPixelsWithStatus(IntRect rect, GCGLenum format, GCGLenum type, GCGLboolean reverseRowOrder, std::span<uint8_t> data)
{
    auto status = islandCalls().readPixelsWithStatus(rect.x(), rect.y(), rect.width(), rect.height(), format, type, reverseRowOrder, lend(data).view());
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
    islandCalls().addErrors(GCGLErrorCodeSet { errorCode }.toRaw());
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
    return islandCalls().enableExtensionsForPlatform(lendCStrings(strings.span()).view());
}

void GraphicsContextGLANGLE::clampMaxInternalFramebufferSize(IntSize size)
{
    islandCalls().clampMaxInternalFramebufferSize(size.width(), size.height());
}

#if ENABLE(WEBXR)
GCGLExternalImage GraphicsContextGLANGLE::addExternalImage(void* eglImage)
{
    return islandCalls().addExternalImage(ANGLEHandles::wrap<ANGLEImageTag>(eglImage));
}

GCGLExternalSync GraphicsContextGLANGLE::addExternalSync(void* eglSync)
{
    return islandCalls().addExternalSync(ANGLEHandles::wrap<ANGLESyncTag>(eglSync));
}
#endif

// The members that lend the island memory, or convert its results. The others are in GraphicsContextGLANGLE.swift.

void GraphicsContextGLANGLE::bindAttribLocation(PlatformGLObject program, GCGLuint index, const UTF8CString& name)
{
    islandCalls().bindAttribLocation(program, index, lendCString(name).view());
}

void GraphicsContextGLANGLE::bufferData(GCGLenum target, std::span<const uint8_t> data, GCGLenum usage)
{
    islandCalls().bufferData(target, lend(data).view(), usage);
}

void GraphicsContextGLANGLE::bufferSubData(GCGLenum target, GCGLintptr offset, std::span<const uint8_t> data)
{
    islandCalls().bufferSubData(target, offset, lend(data).view());
}

Vector<GCGLAttribActiveInfo> GraphicsContextGLANGLE::activeAttribs(PlatformGLObject program)
{
    auto context = islandCalls();
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
    auto context = islandCalls();
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
    islandCalls().getBooleanv(pname, lend(value).view());
}

GCGLErrorCodeSet GraphicsContextGLANGLE::getErrors()
{
    return GCGLErrorCodeSet::fromRaw(islandCalls().getErrors());
}

void GraphicsContextGLANGLE::getFloatv(GCGLenum pname, std::span<GCGLfloat> value)
{
    islandCalls().getFloatv(pname, lend(value).view());
}

void GraphicsContextGLANGLE::getIntegerv(GCGLenum pname, std::span<GCGLint> value)
{
    islandCalls().getIntegerv(pname, lend(value).view());
}

void GraphicsContextGLANGLE::getIntegeri_v(GCGLenum pname, GCGLuint index, std::span<GCGLint, 4> value) // NOLINT
{
    islandCalls().getIntegeri_v(pname, index, lend(std::span<GCGLint> { value }).view());
}

GCGLint GraphicsContextGLANGLE::maxCombinedTextureImageUnits()
{
    return islandCalls().getInteger(MAX_COMBINED_TEXTURE_IMAGE_UNITS);
}

GCGLint GraphicsContextGLANGLE::maxVertexAttribs()
{
    return islandCalls().getInteger(MAX_VERTEX_ATTRIBS);
}

GCGLint GraphicsContextGLANGLE::maxTextureSize()
{
    return islandCalls().getInteger(MAX_TEXTURE_SIZE);
}

GCGLint GraphicsContextGLANGLE::maxCubeMapTextureSize()
{
    return islandCalls().getInteger(MAX_CUBE_MAP_TEXTURE_SIZE);
}

GCGLint GraphicsContextGLANGLE::maxRenderbufferSize()
{
    return islandCalls().getInteger(MAX_RENDERBUFFER_SIZE);
}

GCGLint GraphicsContextGLANGLE::maxSamples()
{
    return islandCalls().getInteger(MAX_SAMPLES);
}

GCGLint GraphicsContextGLANGLE::maxTransformFeedbackSeparateAttribs()
{
    return islandCalls().getInteger(MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS);
}

GCGLint GraphicsContextGLANGLE::maxUniformBufferBindings()
{
    return islandCalls().getInteger(MAX_UNIFORM_BUFFER_BINDINGS);
}

GCGLint GraphicsContextGLANGLE::uniformBufferOffsetAlignment()
{
    return islandCalls().getInteger(UNIFORM_BUFFER_OFFSET_ALIGNMENT);
}

GCGLint GraphicsContextGLANGLE::max3DTextureSize()
{
    return islandCalls().getInteger(MAX_3D_TEXTURE_SIZE);
}

GCGLint GraphicsContextGLANGLE::maxArrayTextureLayers()
{
    return islandCalls().getInteger(MAX_ARRAY_TEXTURE_LAYERS);
}

std::array<GCGLint, 2> GraphicsContextGLANGLE::maxViewportDims()
{
    auto dims = islandCalls().maxViewportDims();
    return { dims.x, dims.y };
}

std::array<GCGLint, 2> GraphicsContextGLANGLE::maxDrawingBufferSize()
{
    auto size = islandCalls().maxDrawingBufferSize();
    return { size.x, size.y };
}

UTF8CString GraphicsContextGLANGLE::getProgramInfoLog(PlatformGLObject program)
{
    auto context = islandCalls();
    return copyIslandLog(context.programInfoLogLength(program), [&](auto& view) { return context.getProgramInfoLog(program, view); });
}

UTF8CString GraphicsContextGLANGLE::getShaderInfoLog(PlatformGLObject shader)
{
    auto context = islandCalls();
    return copyIslandLog(context.shaderInfoLogLength(shader), [&](auto& view) { return context.getShaderInfoLog(shader, view); });
}

void GraphicsContextGLANGLE::getShaderPrecisionFormat(GCGLenum shaderType, GCGLenum precisionType, std::span<GCGLint, 2> range, GCGLint* precision)
{
    auto format = islandCalls().getShaderPrecisionFormat(shaderType, precisionType);
    if (!format.queried)
        return;
    range[0] = format.rangeMin;
    range[1] = format.rangeMax;
    *precision = format.precision;
}

UTF8CString GraphicsContextGLANGLE::getString(GCGLenum name)
{
    auto context = islandCalls();
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

void GraphicsContextGLANGLE::getUniformfv(PlatformGLObject program, GCGLint location, std::span<GCGLfloat> value)
{
    islandCalls().getUniformfv(program, location, lend(value).view());
}

void GraphicsContextGLANGLE::getUniformiv(PlatformGLObject program, GCGLint location, std::span<GCGLint> value)
{
    islandCalls().getUniformiv(program, location, lend(value).view());
}

void GraphicsContextGLANGLE::getUniformuiv(PlatformGLObject program, GCGLint location, std::span<GCGLuint> value)
{
    islandCalls().getUniformuiv(program, location, lend(value).view());
}

void GraphicsContextGLANGLE::readPixels(IntRect rect, GCGLenum format, GCGLenum type, std::span<uint8_t> data, GCGLint alignment, GCGLint rowLength, GCGLboolean reverseRowOrder)
{
    islandCalls().readPixels(rect.x(), rect.y(), rect.width(), rect.height(), format, type, lend(data).view(), alignment, rowLength, reverseRowOrder);
}

void GraphicsContextGLANGLE::readPixelsBufferObject(IntRect rect, GCGLenum format, GCGLenum type, GCGLintptr offset, GCGLint alignment, GCGLint rowLength)
{
    islandCalls().readPixelsBufferObject(rect.x(), rect.y(), rect.width(), rect.height(), format, type, offset, alignment, rowLength);
}

void GraphicsContextGLANGLE::shaderSource(PlatformGLObject shader, const UTF8CString& source)
{
    islandCalls().shaderSource(shader, lendCString(source).view());
}

void GraphicsContextGLANGLE::texImage2D(GCGLenum target, GCGLint level, GCGLenum internalformat, GCGLsizei width, GCGLsizei height, GCGLint border, GCGLenum format, GCGLenum type, std::span<const uint8_t> pixels)
{
    islandCalls().texImage2D(target, level, internalformat, width, height, border, format, type, lend(pixels).view());
}

void GraphicsContextGLANGLE::texSubImage2D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLsizei width, GCGLsizei height, GCGLenum format, GCGLenum type, std::span<const uint8_t> pixels)
{
    islandCalls().texSubImage2D(target, level, xoffset, yoffset, width, height, format, type, lend(pixels).view());
}

void GraphicsContextGLANGLE::compressedTexImage2D(GCGLenum target, GCGLint level, GCGLenum internalformat, GCGLsizei width, GCGLsizei height, GCGLint border, std::span<const uint8_t> data)
{
    islandCalls().compressedTexImage2D(target, level, internalformat, width, height, border, lend(data).view());
}

void GraphicsContextGLANGLE::compressedTexSubImage2D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLsizei width, GCGLsizei height, GCGLenum format, std::span<const uint8_t> data)
{
    islandCalls().compressedTexSubImage2D(target, level, xoffset, yoffset, width, height, format, lend(data).view());
}

void GraphicsContextGLANGLE::uniform1fv(GCGLint location, std::span<const GCGLfloat> v)
{
    islandCalls().uniform1fv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform1iv(GCGLint location, std::span<const GCGLint> v)
{
    islandCalls().uniform1iv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform2fv(GCGLint location, std::span<const GCGLfloat> v)
{
    islandCalls().uniform2fv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform2iv(GCGLint location, std::span<const GCGLint> v)
{
    islandCalls().uniform2iv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform3fv(GCGLint location, std::span<const GCGLfloat> v)
{
    islandCalls().uniform3fv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform3iv(GCGLint location, std::span<const GCGLint> v)
{
    islandCalls().uniform3iv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform4fv(GCGLint location, std::span<const GCGLfloat> v)
{
    islandCalls().uniform4fv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniform4iv(GCGLint location, std::span<const GCGLint> v)
{
    islandCalls().uniform4iv(location, lend(v).view());
}

void GraphicsContextGLANGLE::uniformMatrix2fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> value)
{
    islandCalls().uniformMatrix2fv(location, transpose, lend(value).view());
}

void GraphicsContextGLANGLE::uniformMatrix3fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> value)
{
    islandCalls().uniformMatrix3fv(location, transpose, lend(value).view());
}

void GraphicsContextGLANGLE::uniformMatrix4fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> value)
{
    islandCalls().uniformMatrix4fv(location, transpose, lend(value).view());
}

void GraphicsContextGLANGLE::vertexAttrib1fv(GCGLuint index, std::span<const GCGLfloat, 1> values)
{
    islandCalls().vertexAttrib1fv(index, values[0]);
}

void GraphicsContextGLANGLE::vertexAttrib2fv(GCGLuint index, std::span<const GCGLfloat, 2> values)
{
    islandCalls().vertexAttrib2fv(index, values[0], values[1]);
}

void GraphicsContextGLANGLE::vertexAttrib3fv(GCGLuint index, std::span<const GCGLfloat, 3> values)
{
    islandCalls().vertexAttrib3fv(index, values[0], values[1], values[2]);
}

void GraphicsContextGLANGLE::vertexAttrib4fv(GCGLuint index, std::span<const GCGLfloat, 4> values)
{
    islandCalls().vertexAttrib4fv(index, values[0], values[1], values[2], values[3]);
}

void GraphicsContextGLANGLE::reshape(int width, int height)
{
    islandCalls().reshape(width, height);
}

void GraphicsContextGLANGLE::getBufferSubData(GCGLenum target, GCGLintptr offset, std::span<uint8_t> data)
{
    islandCalls().getBufferSubData(target, offset, lend(data).view());
}

void GraphicsContextGLANGLE::invalidateFramebuffer(GCGLenum target, std::span<const GCGLenum> attachments)
{
    islandCalls().invalidateFramebuffer(target, lend(attachments).view());
}

void GraphicsContextGLANGLE::invalidateSubFramebuffer(GCGLenum target, std::span<const GCGLenum> attachments, GCGLint x, GCGLint y, GCGLsizei width, GCGLsizei height)
{
    islandCalls().invalidateSubFramebuffer(target, lend(attachments).view(), x, y, width, height);
}

void GraphicsContextGLANGLE::getInternalformativ(GCGLenum target, GCGLenum internalformat, GCGLenum pname, std::span<GCGLint> data)
{
    islandCalls().getInternalformativ(target, internalformat, pname, lend(data).view());
}

void GraphicsContextGLANGLE::texImage3D(GCGLenum target, GCGLint level, GCGLint internalformat, GCGLsizei width, GCGLsizei height, GCGLsizei depth, GCGLint border, GCGLenum format, GCGLenum type, std::span<const uint8_t> pixels)
{
    islandCalls().texImage3D(target, level, internalformat, width, height, depth, border, format, type, lend(pixels).view());
}

void GraphicsContextGLANGLE::texSubImage3D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLint zoffset, GCGLsizei width, GCGLsizei height, GCGLsizei depth, GCGLenum format, GCGLenum type, std::span<const uint8_t> pixels)
{
    islandCalls().texSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, lend(pixels).view());
}

void GraphicsContextGLANGLE::compressedTexImage3D(GCGLenum target, GCGLint level, GCGLenum internalformat, GCGLsizei width, GCGLsizei height, GCGLsizei depth, GCGLint border, std::span<const uint8_t> data)
{
    islandCalls().compressedTexImage3D(target, level, internalformat, width, height, depth, border, lend(data).view());
}

void GraphicsContextGLANGLE::compressedTexSubImage3D(GCGLenum target, GCGLint level, GCGLint xoffset, GCGLint yoffset, GCGLint zoffset, GCGLsizei width, GCGLsizei height, GCGLsizei depth, GCGLenum format, std::span<const uint8_t> data)
{
    islandCalls().compressedTexSubImage3D(target, level, xoffset, yoffset, zoffset, width, height, depth, format, lend(data).view());
}

GCGLint GraphicsContextGLANGLE::getFragDataLocation(PlatformGLObject program, const UTF8CString& name)
{
    return islandCalls().getFragDataLocation(program, lendCString(name).view());
}

void GraphicsContextGLANGLE::uniform1uiv(GCGLint location, std::span<const GCGLuint> arg1)
{
    islandCalls().uniform1uiv(location, lend(arg1).view());
}

void GraphicsContextGLANGLE::uniform2uiv(GCGLint location, std::span<const GCGLuint> arg1)
{
    islandCalls().uniform2uiv(location, lend(arg1).view());
}

void GraphicsContextGLANGLE::uniform3uiv(GCGLint location, std::span<const GCGLuint> arg1)
{
    islandCalls().uniform3uiv(location, lend(arg1).view());
}

void GraphicsContextGLANGLE::uniform4uiv(GCGLint location, std::span<const GCGLuint> arg1)
{
    islandCalls().uniform4uiv(location, lend(arg1).view());
}

void GraphicsContextGLANGLE::uniformMatrix2x3fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> data)
{
    islandCalls().uniformMatrix2x3fv(location, transpose, lend(data).view());
}

void GraphicsContextGLANGLE::uniformMatrix3x2fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> data)
{
    islandCalls().uniformMatrix3x2fv(location, transpose, lend(data).view());
}

void GraphicsContextGLANGLE::uniformMatrix2x4fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> data)
{
    islandCalls().uniformMatrix2x4fv(location, transpose, lend(data).view());
}

void GraphicsContextGLANGLE::uniformMatrix4x2fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> data)
{
    islandCalls().uniformMatrix4x2fv(location, transpose, lend(data).view());
}

void GraphicsContextGLANGLE::uniformMatrix3x4fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> data)
{
    islandCalls().uniformMatrix3x4fv(location, transpose, lend(data).view());
}

void GraphicsContextGLANGLE::uniformMatrix4x3fv(GCGLint location, GCGLboolean transpose, std::span<const GCGLfloat> data)
{
    islandCalls().uniformMatrix4x3fv(location, transpose, lend(data).view());
}

void GraphicsContextGLANGLE::vertexAttribI4iv(GCGLuint index, std::span<const GCGLint, 4> values)
{
    islandCalls().vertexAttribI4iv(index, values[0], values[1], values[2], values[3]);
}

void GraphicsContextGLANGLE::vertexAttribI4uiv(GCGLuint index, std::span<const GCGLuint, 4> values)
{
    islandCalls().vertexAttribI4uiv(index, values[0], values[1], values[2], values[3]);
}

void GraphicsContextGLANGLE::drawBuffers(std::span<const GCGLenum> bufs)
{
    islandCalls().drawBuffers(lend(bufs).view());
}

void GraphicsContextGLANGLE::clearBufferiv(GCGLenum buffer, GCGLint drawbuffer, std::span<const GCGLint> values)
{
    islandCalls().clearBufferiv(buffer, drawbuffer, lend(values).view());
}

void GraphicsContextGLANGLE::clearBufferuiv(GCGLenum buffer, GCGLint drawbuffer, std::span<const GCGLuint> values)
{
    islandCalls().clearBufferuiv(buffer, drawbuffer, lend(values).view());
}

void GraphicsContextGLANGLE::clearBufferfv(GCGLenum buffer, GCGLint drawbuffer, std::span<const GCGLfloat> values)
{
    islandCalls().clearBufferfv(buffer, drawbuffer, lend(values).view());
}

GCGLsync GraphicsContextGLANGLE::fenceSync(GCGLenum condition, GCGLbitfield flags)
{
    return reinterpret_cast<GCGLsync>(static_cast<uintptr_t>(islandCalls().fenceSync(condition, flags)));
}

GCGLboolean GraphicsContextGLANGLE::isSync(GCGLsync sync)
{
    return islandCalls().isSync(reinterpret_cast<uintptr_t>(sync));
}

void GraphicsContextGLANGLE::deleteSync(GCGLsync sync)
{
    islandCalls().deleteSync(reinterpret_cast<uintptr_t>(sync));
}

GCGLenum GraphicsContextGLANGLE::clientWaitSync(GCGLsync sync, GCGLbitfield flags, GCGLuint64 timeout)
{
    return islandCalls().clientWaitSync(reinterpret_cast<uintptr_t>(sync), flags, timeout);
}

void GraphicsContextGLANGLE::waitSync(GCGLsync sync, GCGLbitfield flags, GCGLint64 timeout)
{
    islandCalls().waitSync(reinterpret_cast<uintptr_t>(sync), flags, timeout);
}

GCGLint GraphicsContextGLANGLE::getSynci(GCGLsync sync, GCGLenum pname)
{
    return islandCalls().getSynci(reinterpret_cast<uintptr_t>(sync), pname);
}

void GraphicsContextGLANGLE::transformFeedbackVaryings(PlatformGLObject program, const Vector<UTF8CString>& varyings, GCGLenum bufferMode)
{
    Vector<const char*> pointersToVaryings = varyings.map([](const UTF8CString& varying) {
        return varying.legacyCStringPointer();
    });
    islandCalls().transformFeedbackVaryings(program, lend(pointersToVaryings.span()).view(), bufferMode);
}

std::optional<GCGLTransformFeedbackActiveInfo> GraphicsContextGLANGLE::getTransformFeedbackVarying(PlatformGLObject program, GCGLuint index)
{
    auto context = islandCalls();
    auto info = context.getTransformFeedbackVarying(program, index);
    if (!info.nameLength)
        return std::nullopt;
    auto name = copyIslandString(info.nameLength, [&](auto& view) { return context.copyLastVariableName(view); });
    context.clearActiveVariables();
    return GCGLTransformFeedbackActiveInfo { WTF::move(name), info.type, info.size };
}

GCGLuint GraphicsContextGLANGLE::getUniformBlockIndex(PlatformGLObject program, const UTF8CString& uniformBlockName)
{
    return islandCalls().getUniformBlockIndex(program, lendCString(uniformBlockName).view());
}

UTF8CString GraphicsContextGLANGLE::getActiveUniformBlockName(PlatformGLObject program, GCGLuint uniformBlockIndex)
{
    auto context = islandCalls();
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

void GraphicsContextGLANGLE::getActiveUniformBlockiv(PlatformGLObject program, GCGLuint uniformBlockIndex, GCGLenum pname, std::span<GCGLint> params)
{
    islandCalls().getActiveUniformBlockiv(program, uniformBlockIndex, pname, lend(params).view());
}

#if ENABLE(WEBXR)
GCGLExternalImage GraphicsContextGLANGLE::createExternalImage(ExternalImageSource&&, GCGLenum, GCGLint)
{
    notImplemented();
    return { };
}
#endif

#if ENABLE(WEBXR)
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
#endif

#if ENABLE(WEBXR)
void GraphicsContextGLANGLE::framebufferDiscard(GCGLenum target, std::span<const GCGLenum> attachments)
{
    islandCalls().framebufferDiscard(target, lend(attachments).view());
}
#endif

void GraphicsContextGLANGLE::multiDrawArraysANGLE(GCGLenum mode, GCGLSpanTuple<const GCGLint, const GCGLsizei> firstsAndCounts)
{
    islandCalls().multiDrawArraysANGLE(mode, lend(firstsAndCounts.span<0>()).view(), lend(firstsAndCounts.span<1>()).view(), firstsAndCounts.bufSize);
}

void GraphicsContextGLANGLE::multiDrawArraysInstancedANGLE(GCGLenum mode, GCGLSpanTuple<const GCGLint, const GCGLsizei, const GCGLsizei> firstsCountsAndInstanceCounts)
{
    auto& t = firstsCountsAndInstanceCounts;
    islandCalls().multiDrawArraysInstancedANGLE(mode, lend(t.span<0>()).view(), lend(t.span<1>()).view(), lend(t.span<2>()).view(), t.bufSize);
}

void GraphicsContextGLANGLE::multiDrawElementsANGLE(GCGLenum mode, GCGLSpanTuple<const GCGLsizei, const GCGLsizei> countsAndOffsets, GCGLenum type)
{
    auto& t = countsAndOffsets;
    islandCalls().multiDrawElementsANGLE(mode, lend(t.span<0>()).view(), lend(t.span<1>()).view(), type, t.bufSize);
}

void GraphicsContextGLANGLE::multiDrawElementsInstancedANGLE(GCGLenum mode, GCGLSpanTuple<const GCGLsizei, const GCGLsizei, const GCGLsizei> countsOffsetsAndInstanceCounts, GCGLenum type)
{
    auto& t = countsOffsetsAndInstanceCounts;
    islandCalls().multiDrawElementsInstancedANGLE(mode, lend(t.span<0>()).view(), lend(t.span<1>()).view(), lend(t.span<2>()).view(), type, t.bufSize);
}

bool GraphicsContextGLANGLE::enableExtension(GCGLExtension extension)
{
    bool result = islandCalls().enableExtension(std::to_underlying(extension));
    m_knownActiveExtensions = EnumSet<GCGLExtension>::fromRaw(islandCalls().knownActiveExtensions());
    return result;
}

void GraphicsContextGLANGLE::drawBuffersEXT(std::span<const GCGLenum> arg0)
{
    islandCalls().drawBuffersEXT(lend(arg0).view());
}

UTF8CString GraphicsContextGLANGLE::getTranslatedShaderSourceANGLE(PlatformGLObject shader)
{
    auto context = islandCalls();
    return copyIslandLog(context.translatedShaderSourceLength(shader), [&](auto& view) { return context.getTranslatedShaderSourceANGLE(shader, view); });
}

void GraphicsContextGLANGLE::multiDrawArraysInstancedBaseInstanceANGLE(GCGLenum mode, GCGLSpanTuple<const GCGLint, const GCGLsizei, const GCGLsizei, const GCGLuint> firstsCountsInstanceCountsAndBaseInstances)
{
    auto& t = firstsCountsInstanceCountsAndBaseInstances;
    islandCalls().multiDrawArraysInstancedBaseInstanceANGLE(mode, lend(t.span<0>()).view(), lend(t.span<1>()).view(), lend(t.span<2>()).view(), lend(t.span<3>()).view(), t.bufSize);
}

void GraphicsContextGLANGLE::multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(GCGLenum mode, GCGLSpanTuple<const GCGLsizei, const GCGLsizei, const GCGLsizei, const GCGLint, const GCGLuint> countsOffsetsInstanceCountsBaseVerticesAndBaseInstances, GCGLenum type)
{
    auto& t = countsOffsetsInstanceCountsBaseVerticesAndBaseInstances;
    islandCalls().multiDrawElementsInstancedBaseVertexBaseInstanceANGLE(mode, lend(t.span<0>()).view(), lend(t.span<1>()).view(), lend(t.span<2>()).view(), lend(t.span<3>()).view(), lend(t.span<4>()).view(), type, t.bufSize);
}

void GraphicsContextGLANGLE::simulateEventForTesting(SimulatedEventForTesting event)
{
    islandCalls().simulateEventForTesting(std::to_underlying(event));
}

}

void GL_APIENTRY ANGLE::debugMessageTrampoline(GLenum, GLenum type, GLuint messageID, GLenum severity, GLsizei length, const GLchar* message, const void* contextID)
{
    if (!WebCore::GLIslandCalls::reportsDebugMessage(type, messageID))
        return;
    WebCore::GLContextCallbacks::addDebugMessage(static_cast<uint64_t>(reinterpret_cast<uintptr_t>(contextID)), type, messageID, severity, byteCast<char8_t>(unsafeMakeSpan(message, length)));
}

#endif // ENABLE(WEBGL)
