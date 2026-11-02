/*
 * Copyright (C) 2003-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2008 Eric Seidel <eric@webkit.org>
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
#include "GraphicsContextCG.h"

#if USE(CG)

#include "AffineTransform.h"
#include "CGSubimageCacheWithTimer.h"
#include "CGUtilities.h"
#include "DisplayListRecorder.h"
#include "FloatConversion.h"
#include "Font.h"
#include "FontCascade.h"
#include "Gradient.h"
#include "GraphicsContextCGCapture.h"
#include "ImageBuffer.h"
#include "ImageOrientation.h"
#include "Logging.h"
#include "Path.h"
#include "PathCG.h"
#include "Pattern.h"
#include "ShadowBlur.h"
#include "Timer.h"
#include <pal/spi/cg/CoreGraphicsSPI.h>
#include <pal/spi/cg/ImageIOSPI.h>
#include <wtf/MathExtras.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/RetainPtr.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/URL.h>
#include <wtf/ZippedRange.h>
#include <wtf/text/TextStream.h>

#if ENABLE(AX_CUSTOM_COLOR_MODE)
#include <WebKitAdditions/AXCustomColorModeController.h>
#endif

#include "WebCore-Swift.h"

#include <pal/cg/CoreGraphicsSoftLink.h>

#if USE(APPLE_INTERNAL_SDK) && __has_include(<WebKitAdditions/IOSurfaceAdditionsBefore.mm>)
#include <WebKitAdditions/IOSurfaceAdditionsBefore.mm>
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(GraphicsContextCG);

#if ASSERT_ENABLED
#define CAPTURE(call) \
    GraphicsContextCGCapture::Scope captureScope(m_capture.get()); \
    if (auto* capture = captureScope.outermost()) \
        capture->call
#else
#define CAPTURE(call)
#endif

static void setCGFillColor(CGContextRef context, const Color& color, const ColorSpace& colorSpace)
{
    CGContextSetFillColorWithColor(context, cachedCGColorInDestinationStandardRange(color, colorSpace).get());
}

CGAffineTransform getUserToBaseCTM(CGContextRef context)
{
    return CGAffineTransformConcat(CGContextGetCTM(context), CGAffineTransformInvert(CGContextGetBaseCTM(context)));
}

CGFloat singularValue(const CGAffineTransform& userToBaseCTM, SingularValueSelection selection)
{
    CGFloat A = userToBaseCTM.a * userToBaseCTM.a + userToBaseCTM.b * userToBaseCTM.b;
    CGFloat B = userToBaseCTM.a * userToBaseCTM.c + userToBaseCTM.b * userToBaseCTM.d;
    CGFloat D = userToBaseCTM.c * userToBaseCTM.c + userToBaseCTM.d * userToBaseCTM.d;
    CGFloat discriminant = sqrt(4 * B * B + (A - D) * (A - D));
    if (selection == SingularValueSelection::Smallest)
        discriminant = -discriminant;
    return narrowPrecisionToCGFloat(sqrt(0.5 * ((A + D) + discriminant)));
}

static InterpolationQuality coreInterpolationQuality(CGContextRef context)
{
    switch (CGContextGetInterpolationQuality(context)) {
    case kCGInterpolationDefault:
        return InterpolationQuality::Default;
    case kCGInterpolationNone:
        return InterpolationQuality::DoNotInterpolate;
    case kCGInterpolationLow:
        return InterpolationQuality::Low;
    case kCGInterpolationMedium:
        return InterpolationQuality::Medium;
    case kCGInterpolationHigh:
        return InterpolationQuality::High;
    }
    return InterpolationQuality::Default;
}

NODELETE static CGBlendMode selectCGBlendMode(CompositeOperator compositeOperator, BlendMode blendMode)
{
    switch (blendMode) {
    case BlendMode::Normal:
        switch (compositeOperator) {
        case CompositeOperator::Clear:
            return kCGBlendModeClear;
        case CompositeOperator::Copy:
            return kCGBlendModeCopy;
        case CompositeOperator::SourceOver:
            return kCGBlendModeNormal;
        case CompositeOperator::SourceIn:
            return kCGBlendModeSourceIn;
        case CompositeOperator::SourceOut:
            return kCGBlendModeSourceOut;
        case CompositeOperator::SourceAtop:
            return kCGBlendModeSourceAtop;
        case CompositeOperator::DestinationOver:
            return kCGBlendModeDestinationOver;
        case CompositeOperator::DestinationIn:
            return kCGBlendModeDestinationIn;
        case CompositeOperator::DestinationOut:
            return kCGBlendModeDestinationOut;
        case CompositeOperator::DestinationAtop:
            return kCGBlendModeDestinationAtop;
        case CompositeOperator::XOR:
            return kCGBlendModeXOR;
        case CompositeOperator::PlusDarker:
            return kCGBlendModePlusDarker;
        case CompositeOperator::PlusLighter:
            return kCGBlendModePlusLighter;
        case CompositeOperator::Difference:
            return kCGBlendModeDifference;
        }
        break;
    case BlendMode::Multiply:
        return kCGBlendModeMultiply;
    case BlendMode::Screen:
        return kCGBlendModeScreen;
    case BlendMode::Overlay:
        return kCGBlendModeOverlay;
    case BlendMode::Darken:
        return kCGBlendModeDarken;
    case BlendMode::Lighten:
        return kCGBlendModeLighten;
    case BlendMode::ColorDodge:
        return kCGBlendModeColorDodge;
    case BlendMode::ColorBurn:
        return kCGBlendModeColorBurn;
    case BlendMode::HardLight:
        return kCGBlendModeHardLight;
    case BlendMode::SoftLight:
        return kCGBlendModeSoftLight;
    case BlendMode::Difference:
        return kCGBlendModeDifference;
    case BlendMode::Exclusion:
        return kCGBlendModeExclusion;
    case BlendMode::Hue:
        return kCGBlendModeHue;
    case BlendMode::Saturation:
        return kCGBlendModeSaturation;
    case BlendMode::Color:
        return kCGBlendModeColor;
    case BlendMode::Luminosity:
        return kCGBlendModeLuminosity;
    case BlendMode::PlusDarker:
        return kCGBlendModePlusDarker;
    case BlendMode::PlusLighter:
        return kCGBlendModePlusLighter;
    }

    return kCGBlendModeNormal;
}

static void setCGBlendMode(CGContextRef context, CompositeOperator op, BlendMode blendMode)
{
    CGContextSetBlendMode(context, selectCGBlendMode(op, blendMode));
}

static void setCGContextPath(CGContextRef context, const Path& path)
{
    CGContextBeginPath(context);
    addToCGContextPath(context, path);
}

static FloatRect strokedPathBoundingBox(CGContextRef context, NOESCAPE const Invocable<void()> auto& addPathAndStrokeStyle)
{
    CGContextStateSaver stateSaver(context);
    addPathAndStrokeStyle();
    CGContextReplacePathWithStrokedPath(context);
    FloatRect bounds = CGContextGetPathBoundingBox(context);
    CGContextBeginPath(context);
    return bounds;
}

static CGRendererGradientGeometry gradientGeometry(const Gradient& gradient)
{
    CGRendererGradientGeometry geometry { };
    geometry.spreadMethod = static_cast<uint8_t>(gradient.spreadMethod());
    WTF::switchOn(gradient.data(),
        [&](const Gradient::LinearData& data) {
            geometry.kind = 0;
            geometry.x0 = data.point0.x();
            geometry.y0 = data.point0.y();
            geometry.x1 = data.point1.x();
            geometry.y1 = data.point1.y();
        },
        [&](const Gradient::RadialData& data) {
            geometry.kind = 1;
            geometry.x0 = data.point0.x();
            geometry.y0 = data.point0.y();
            geometry.x1 = data.point1.x();
            geometry.y1 = data.point1.y();
            geometry.startRadius = data.startRadius;
            geometry.endRadius = data.endRadius;
            geometry.aspectRatio = data.aspectRatio;
        },
        [&](const Gradient::ConicData& data) {
            geometry.kind = 2;
            geometry.x0 = data.point0.x();
            geometry.y0 = data.point0.y();
            geometry.angleRadians = data.angleRadians;
        });
    return geometry;
}

#if !HAVE(CGSTYLE_FIXES_DROP_SHADOW_BLUR)
// Older transparency layers are bounded by the clip, so content outside of it would lose its shadow.
void GraphicsContextCG::paintGradientInCGLayer(Gradient& gradient, const AffineTransform& gradientSpaceTransform, const FloatRect& contentBounds, NOESCAPE const Invocable<void(CGContextRef)> auto& clip)
{
    FloatRect layerBounds = enclosingIntRect(contentBounds);
    if (layerBounds.isEmpty())
        return;

    const RetainPtr<CGContextRef>& context = contextForDraw();
    FloatSize layerSize = getCTM().mapSize(layerBounds.size());
    RetainPtr layer = adoptCF(CGLayerCreateWithContext(context.get(), layerSize, 0));
    RetainPtr layerContext = CGLayerGetContext(layer.get());

    CGContextScaleCTM(layerContext.get(), layerSize.width() / layerBounds.width(), layerSize.height() / layerBounds.height());
    CGContextTranslateCTM(layerContext.get(), -layerBounds.x(), -layerBounds.y());
    clip(layerContext.get());
    CGContextConcatCTM(layerContext.get(), gradientSpaceTransform);
    if (RetainPtr platformGradient = gradient.platformGradient())
        CGRenderer::paintGradient(layerContext.get(), platformGradient.get(), gradientGeometry(gradient));
    CGContextDrawLayerInRect(context.get(), layerBounds, layer.get());
}
#endif

void GraphicsContextCG::paintGradientInClip(Gradient& gradient, const AffineTransform& gradientSpaceTransform, NOESCAPE const Invocable<FloatRect()> auto& computeContentBounds, NOESCAPE const Invocable<void(CGContextRef)> auto& clip)
{
    bool hasDropShadow = this->hasDropShadow();
#if !HAVE(CGSTYLE_FIXES_DROP_SHADOW_BLUR)
    if (hasDropShadow) {
        paintGradientInCGLayer(gradient, gradientSpaceTransform, computeContentBounds(), clip);
        return;
    }
#endif

    const RetainPtr<CGContextRef>& context = contextForDraw();

    // The clip has to be applied inside the transparency layer, otherwise it would also clip away the shadow.
    // Passing the content bounds to CGContextBeginTransparencyLayerWithRect() would lose the shadow of content
    // outside the clip (rdar://190563103), so bound the layer with a clip covering the content and its shadow.
    if (hasDropShadow) {
        auto layerBounds = boundsIncludingDropShadow(computeContentBounds());
        CGContextSaveGState(context.get());
        CGContextClipToRect(context.get(), layerBounds);
        CGContextBeginTransparencyLayer(context.get(), nullptr);
#if !HAVE(FIX_FOR_RADAR_190563103)
        // FIXME: Remove this workaround once the system framework rdar://190563103 is fixed.
        CGContextClearRect(context.get(), layerBounds);
#endif
    }
    {
        CGContextStateSaver stateSaver(context.get());
        clip(context.get());
        CGContextConcatCTM(context.get(), gradientSpaceTransform);
        if (RetainPtr platformGradient = gradient.platformGradient(Gradient::paintColorSpace(*this)))
            CGRenderer::paintGradient(context.get(), platformGradient.get(), gradientGeometry(gradient));
    }
    if (hasDropShadow) {
        CGContextEndTransparencyLayer(context.get());
        CGContextRestoreGState(context.get());
    }
}

static void drawPathWithCGContext(CGContextRef context, CGPathDrawingMode drawingMode, const Path& path)
{
    CGContextDrawPathDirect(context, drawingMode, protect(path.platformPath()), nullptr);
}

static RenderingMode renderingModeForCGContext(CGContextRef cgContext, GraphicsContextCG::CGContextSource source)
{
    if (!cgContext)
        return RenderingMode::Unaccelerated;
    auto type = CGContextGetType(cgContext);
    if (type == kCGContextTypeIOSurface || (source == GraphicsContextCG::CGContextFromCALayer && type == kCGContextTypeUnknown))
        return RenderingMode::Accelerated;
    if (type == kCGContextTypePDF)
        return RenderingMode::PDFDocument;
    return RenderingMode::Unaccelerated;
}

static GraphicsContext::IsDeferred isDeferredForCGContext(CGContextRef cgContext)
{
    if (!cgContext || CGContextGetType(cgContext) == kCGContextTypeBitmap)
        return GraphicsContext::IsDeferred::No;
    // Other CGContexts are deferred (iosurface, display list) or potentially deferred.
    return GraphicsContext::IsDeferred::Yes;
}

GraphicsContextCG::GraphicsContextCG(CGContextRef cgContext, CGContextSource source, std::optional<RenderingMode> knownRenderingMode)
    : GraphicsContext(isDeferredForCGContext(cgContext), GraphicsContextState::basicChangeFlags, coreInterpolationQuality(cgContext))
    , m_cgContext(cgContext)
    , m_renderingMode(knownRenderingMode.value_or(renderingModeForCGContext(cgContext, source)))
    , m_isLayerCGContext(source == GraphicsContextCG::CGContextFromCALayer)
{
    // Exact where pointers are 8 bytes, so that the storage doesn't outgrow the struct; with 4-byte pointers the struct is smaller.
#if CPU(ADDRESS64)
    static_assert(sizeof(CGRenderer) == swiftRendererSize);
#else
    static_assert(sizeof(CGRenderer) <= swiftRendererSize);
#endif
    static_assert(alignof(CGRenderer) <= 8);
    if (!cgContext) {
        // An invalid context draws nothing: its renderer draws into a stand-in.
        RetainPtr standIn = adoptCF(CGBitmapContextCreate(nullptr, 1, 1, 8, 4, sRGBColorSpaceSingleton(), static_cast<uint32_t>(kCGImageAlphaPremultipliedFirst) | static_cast<uint32_t>(kCGBitmapByteOrder32Little)));
        new (m_swiftRendererStorage) CGRenderer(CGRenderer::init(standIn.get(), true, false, imageInterpolationQuality()));
        return;
    }
    new (m_swiftRendererStorage) CGRenderer(CGRenderer::init(cgContext, m_renderingMode == RenderingMode::Unaccelerated, CGContextGetType(cgContext) == kCGContextTypePDF, imageInterpolationQuality()));
    // Make sure the context starts in sync with our state.
    didUpdateState(m_state);
#if ASSERT_ENABLED
    m_capture = GraphicsContextCGCapture::createIfEnabled(cgContext, m_renderingMode, m_isLayerCGContext);
#endif
}

GraphicsContextCG::~GraphicsContextCG()
{
    std::destroy_at(&swiftRenderer());
}

CGRenderer& GraphicsContextCG::swiftRenderer() const
{
    return *std::launder(reinterpret_cast<CGRenderer*>(m_swiftRendererStorage));
}

bool GraphicsContextCG::hasPlatformContext() const
{
    return true;
}

const RetainPtr<CGContextRef>& GraphicsContextCG::contextForState() const
{
    ASSERT(m_cgContext);
    return m_cgContext;
}

const ColorSpace& GraphicsContextCG::colorSpace() const
{
    if (m_colorSpace)
        return *m_colorSpace;

    const RetainPtr<CGContextRef>& context = contextForDraw();
    RetainPtr<CGColorSpaceRef> colorSpace;

    // FIXME: Need to handle kCGContextTypePDF.
    auto contextType = CGContextGetType(context);
    if (contextType == kCGContextTypeIOSurface)
        colorSpace = CGIOSurfaceContextGetColorSpace(context);
    else if (contextType == kCGContextTypeBitmap)
        colorSpace = CGBitmapContextGetColorSpace(context);
    else
        colorSpace = CGContextGetColorSpace(context);

    // FIXME: Need to ASSERT(colorSpace). For now fall back to sRGB if colorSpace is nil.
    m_colorSpace = colorSpace ? ColorSpace(colorSpace) : ColorSpace::SRGB();
    return *m_colorSpace;
}

void GraphicsContextCG::save(GraphicsContextState::Purpose purpose)
{
    CAPTURE(save(purpose));
    GraphicsContext::save(purpose);
    swiftRenderer().save(purpose == GraphicsContextState::Purpose::TransparencyLayer);
}

void GraphicsContextCG::restore(GraphicsContextState::Purpose purpose)
{
    CAPTURE(restore(purpose));
    if (!stackSize() || m_state.purpose() != purpose)
        return;

    GraphicsContext::restore(purpose);
    swiftRenderer().restore();
    m_userToDeviceTransformKnownToBeIdentity = false;
}

void GraphicsContextCG::drawNativeImage(const NativeImage& nativeImage, const FloatRect& destRect, const FloatRect& srcRect, RasterDrawingOptions options)
{
    CAPTURE(drawNativeImage(nativeImage, destRect, srcRect, options));
    auto image = nativeImage.platformImage();
    if (!image)
        return;

// The renderer doesn't do the iOS family's pixel alignment of images yet: it can't be checked against the C++ here. Nor does it
// limit an image's dynamic range (tone mapping) or invert it (AX); the C++ below draws those.
#if HAVE(SUPPORT_HDR_DISPLAY_APIS) && !PLATFORM(IOS_FAMILY)
    bool rendererDraws = !(options.dynamicRangeLimit() == PlatformDynamicRangeLimit::standard() && options.drawsHDRContent() == DrawsHDRContent::Yes);
#if ENABLE(AX_CUSTOM_COLOR_MODE)
    rendererDraws = rendererDraws && options.invertContent() == InvertContent::No;
#endif
    if (rendererDraws) {
        FloatSize imageSize = nativeImage.size();
        auto result = swiftRenderer().drawNativeImage(image.get(), imageSize.width(), imageSize.height(), destRect.x(), destRect.y(), destRect.width(), destRect.height(), srcRect.x(), srcRect.y(), srcRect.width(), srcRect.height(), options.compositeOperator(), options.blendMode(), options.interpolationQuality(), static_cast<uint8_t>(options.orientation().orientation()), nativeImage.headroom(), options.headroom());
        if (result == 1)
            m_hasDrawn = true;
        if (result)
            return;
    }
#endif

#if ENABLE(AX_CUSTOM_COLOR_MODE) && HAVE(CGSTYLE_COLORMATRIX_BLUR)
    if (auto invertContent = options.invertContent(); invertContent == InvertContent::Yes || invertContent == InvertContent::Forced) {
        auto colorMatrix = [&] -> std::optional<GraphicsColorMatrix> {
            if (invertContent == InvertContent::Forced)
                return AXCustomColorModeController::colorPreservingInvertMatrix();
            auto sourceRect = options.orientation() == ImageOrientation::Orientation::None ? std::optional { normalizeRect(srcRect) } : std::nullopt;
            return AXCustomColorModeController::colorMatrixForImageInversion(nativeImage.paintTimeTransformation(sourceRect));
        }();
        if (colorMatrix) {
            GraphicsContextStateSaver stateSaver(*this);
            clip(normalizeRect(destRect));
            setStyle(*colorMatrix);
            setCompositeOperation(options.compositeOperator(), options.blendMode());
            beginTransparencyLayer(options.compositeOperator(), options.blendMode());
            drawNativeImage(nativeImage, destRect, srcRect, { options, InvertContent::No, CompositeOperator::SourceOver, BlendMode::Normal });
            endTransparencyLayer();
            return;
        }
    }
#endif
    auto imageSize = nativeImage.size();
    if (options.orientation().usesWidthAsHeight())
        imageSize = imageSize.transposedSize();
    auto imageRect = FloatRect { { }, imageSize };
    auto normalizedSrcRect = normalizeRect(srcRect);
    auto normalizedDestRect = normalizeRect(destRect);
    if (!imageRect.intersects(normalizedSrcRect))
        return;

#if !LOG_DISABLED
    MonotonicTime startTime = MonotonicTime::now();
#endif

    auto shouldUseSubimage = [](InterpolationQuality interpolationQuality, const FloatRect& destRect, const FloatRect& srcRect, const AffineTransform& transform) -> bool {
        if (interpolationQuality == InterpolationQuality::DoNotInterpolate)
            return false;
        if (transform.isRotateOrShear())
            return true;
        auto xScale = destRect.width() * transform.xScale() / srcRect.width();
        auto yScale = destRect.height() * transform.yScale() / srcRect.height();
        return !WTF::areEssentiallyEqual(xScale, yScale) || xScale > 1;
    };

    auto getSubimage = [](CGImageRef image, const FloatSize& imageSize, const FloatRect& subimageRect, RasterDrawingOptions options) -> RetainPtr<CGImageRef> {
        auto physicalSubimageRect = subimageRect;

        if (options.orientation() != ImageOrientation::Orientation::None) {
            // subimageRect is in logical coordinates. getSubimage() deals with none-oriented
            // image. We need to convert subimageRect to physical image coordinates.
            if (auto transform = options.orientation().transformFromDefault(imageSize).inverse())
                physicalSubimageRect = transform.value().mapRect(physicalSubimageRect);
        }

#if CACHE_SUBIMAGES
        if (!(CGImageGetCachingFlags(image) & kCGImageCachingTransient))
            return CGSubimageCacheWithTimer::getSubimage(image, physicalSubimageRect);
#endif
        return adoptCF(CGImageCreateWithImageInRect(image, physicalSubimageRect));
    };

#if HAVE(SUPPORT_HDR_DISPLAY_APIS)
    auto setCGDynamicRangeLimitForImage = [](CGContextRef context, CGImageRef image, float dynamicRangeLimit) {
        float edrStrength = dynamicRangeLimit == 1.0 ? 1 : 0;
        float cdrStrength = dynamicRangeLimit == 0.5 ? 1 : 0;
        unsigned averageLightLevel = CGImageGetContentAverageLightLevelNits(image);

        RetainPtr edrStrengthNumber = adoptCF(CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &edrStrength));
        RetainPtr cdrStrengthNumber = adoptCF(CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &cdrStrength));
        RetainPtr averageLightLevelNumber = adoptCF(CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &averageLightLevel));

        CFTypeRef toneMappingKeys[] = { kCGContentEDRStrength, kCGContentAverageLightLevel, kCGConstrainedDynamicRange };
        CFTypeRef toneMappingValues[] = { edrStrengthNumber.get(), averageLightLevelNumber.get(), cdrStrengthNumber.get() };

        RetainPtr toneMappingOptions = adoptCF(CFDictionaryCreate(kCFAllocatorDefault, toneMappingKeys, toneMappingValues, sizeof(toneMappingKeys) / sizeof(toneMappingKeys[0]), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

        CGContentToneMappingInfo toneMappingInfo = { kCGToneMappingReferenceWhiteBased, toneMappingOptions.get() };
        CGContextSetContentToneMappingInfo(context, toneMappingInfo);
    };
#endif

    const RetainPtr<CGContextRef>& context = contextForDraw();
    CGContextStateSaver stateSaver(context, false);
    auto transform = CGContextGetCTM(context);

    auto oldInterpolationQuality = imageInterpolationQuality();
    auto interpolationQuality = imageInterpolationQualityForOptions(options);

    auto subImage = image;

    auto adjustedDestRect = normalizedDestRect;

    if (normalizedSrcRect != imageRect) {
        auto scale = normalizedDestRect.size() / normalizedSrcRect.size();

        if (shouldUseSubimage(interpolationQuality, normalizedDestRect, normalizedSrcRect, transform)) {
            auto subimageRect = enclosingIntRect(normalizedSrcRect);

            // When the image is scaled using high-quality interpolation, we create a temporary CGImage
            // containing only the portion we want to display. We need to do this because high-quality
            // interpolation smoothes sharp edges, causing pixels from outside the source rect to bleed
            // into the destination rect. See <rdar://problem/6112909>.
            subImage = getSubimage(subImage.get(), imageSize, subimageRect, options);

            auto subPixelPadding = normalizedSrcRect.location() - subimageRect.location();
            adjustedDestRect = { adjustedDestRect.location() - subPixelPadding * scale, subimageRect.size() * scale };
        } else {
            // If the source rect is a subportion of the image, then we compute an inflated destination rect
            // that will hold the entire image and then set a clip to the portion that we want to display.
            adjustedDestRect = { adjustedDestRect.location() - toFloatSize(normalizedSrcRect.location()) * scale, imageSize * scale };
        }

        if (!normalizedDestRect.contains(adjustedDestRect)) {
            stateSaver.save();
            CGContextClipToRect(context, normalizedDestRect);
        }
    }

#if PLATFORM(IOS_FAMILY)
    bool wasAntialiased = CGContextGetShouldAntialias(context);
    // Anti-aliasing is on by default on the iPhone. Need to turn it off when drawing images.
    CGContextSetShouldAntialias(context, false);

    // Align to pixel boundaries
    adjustedDestRect = roundToDevicePixels(adjustedDestRect);
#endif

    auto oldCompositeOperator = compositeOperation();
    auto oldBlendMode = blendMode();
    setCGBlendMode(context, options.compositeOperator(), options.blendMode());

    if (interpolationQuality != oldInterpolationQuality)
        CGContextSetInterpolationQuality(context, toCGInterpolationQuality(interpolationQuality));

#if HAVE(SUPPORT_HDR_DISPLAY_APIS)
    auto oldHeadroom = CGContextGetEDRTargetHeadroom(context);
    auto oldToneMappingInfo = CGContextGetContentToneMappingInfo(context);

    auto headroom = options.headroom();
    if (headroom == Headroom::FromImage)
        headroom = nativeImage.headroom();
    if (m_maxEDRHeadroom)
        headroom = Headroom(std::min<float>(headroom, *m_maxEDRHeadroom));

    if (nativeImage.headroom() > headroom) {
        LOG_WITH_STREAM(HDR, stream << "GraphicsContextCG::drawNativeImage setEDRTargetHeadroom " << headroom << " max(" << m_maxEDRHeadroom << ")");
        CGContextSetEDRTargetHeadroom(context, headroom);
    }

    if (options.dynamicRangeLimit() == PlatformDynamicRangeLimit::standard() && options.drawsHDRContent() == DrawsHDRContent::Yes)
        setCGDynamicRangeLimitForImage(context, subImage.get(), options.dynamicRangeLimit().value());
#endif

    // Make the origin be at adjustedDestRect.location()
    CGContextTranslateCTM(context, adjustedDestRect.x(), adjustedDestRect.y());
    adjustedDestRect.setLocation(FloatPoint::zero());

    if (options.orientation() != ImageOrientation::Orientation::None) {
        CGContextConcatCTM(context, options.orientation().transformFromDefault(adjustedDestRect.size()));

        // The destination rect will have its width and height already reversed for the orientation of
        // the image, as it was needed for page layout, so we need to reverse it back here.
        if (options.orientation().usesWidthAsHeight())
            adjustedDestRect = adjustedDestRect.transposedRect();
    }

    // Flip the coords.
    CGContextTranslateCTM(context, 0, adjustedDestRect.height());
    CGContextScaleCTM(context, 1, -1);

    // Draw the image.
    CGContextDrawImage(context, adjustedDestRect, subImage.get());

    if (!stateSaver.didSave()) {
        CGContextSetCTM(context, transform);
#if PLATFORM(IOS_FAMILY)
        CGContextSetShouldAntialias(context, wasAntialiased);
#endif
        setCGBlendMode(context, oldCompositeOperator, oldBlendMode);
        if (interpolationQuality != oldInterpolationQuality)
            CGContextSetInterpolationQuality(context, toCGInterpolationQuality(oldInterpolationQuality));
#if HAVE(SUPPORT_HDR_DISPLAY_APIS)
        CGContextSetContentToneMappingInfo(context, oldToneMappingInfo);
        CGContextSetEDRTargetHeadroom(context, oldHeadroom);
#endif
    }

    LOG_WITH_STREAM(Images, stream << "GraphicsContextCG::drawNativeImage " << image.get() << " size " << imageSize << " into " << destRect << " took " << (MonotonicTime::now() - startTime).milliseconds() << "ms");
}

} // namespace WebCore

CGImageRef CGRendererCopyImageBufferImage(WebCore::ImageBuffer& imageBuffer, float& headroom)
{
    RefPtr nativeImage = imageBuffer.createNativeImageReference();
    if (!nativeImage)
        return nullptr;
    headroom = nativeImage->headroom();
    return RetainPtr { nativeImage->platformImage() }.leakRef();
}

CGImageRef CGRendererCopySubimage(CGImageRef image, CGRect rect)
{
#if CACHE_SUBIMAGES
    if (!(CGImageGetCachingFlags(image) & kCGImageCachingTransient))
        return WebCore::CGSubimageCacheWithTimer::getSubimage(image, rect).leakRef();
#endif
    return CGImageCreateWithImageInRect(image, rect);
}

namespace WebCore {

static void drawPatternCallback(void* info, CGContextRef context)
{
    CGImageRef image = (CGImageRef)info;
    auto rect = cgRoundToDevicePixels(CGContextGetUserSpaceToDeviceSpaceTransform(context), cgImageRect(image));
    CGContextDrawImage(context, rect, image);
}

static void drawPatternReleaseCallback(void* info)
{
    // info is the image reference that drawPattern() transferred to the pattern.
    SUPPRESS_RETAINPTR_CTOR_ADOPT callOnMainThread([image = adoptCF(static_cast<CGImageRef>(info))] { });
}

} // namespace WebCore

CGPatternRef CGRendererCreateImagePattern(CGImageRef image, CGRect tileBounds, CGAffineTransform matrix, CGFloat xStep, CGFloat yStep)
{
#if HAVE(CGPATTERN_CREATE_WITH_IMAGE_TRANSFORM_STEP)
    if (PAL::canLoad_CoreGraphics_CGPatternCreateWithImageTransformStep())
        return PAL::softLink_CoreGraphics_CGPatternCreateWithImageTransformStep(image, matrix, xStep, yStep, kCGPatternTilingConstantSpacing);
#endif
    static const CGPatternCallbacks patternCallbacks = { 0, WebCore::drawPatternCallback, WebCore::drawPatternReleaseCallback };
    // The pattern takes this reference to the image, which drawPatternReleaseCallback() releases.
    // FIXME: If CGPatternCreate() returns NULL, drawPatternReleaseCallback() never runs and the image reference leaks.
    return CGPatternCreate(RetainPtr { image }.leakRef(), tileBounds, matrix, xStep, yStep, kCGPatternTilingConstantSpacing, true, &patternCallbacks);
}

namespace WebCore {

void GraphicsContextCG::drawPattern(const NativeImage& nativeImage, const FloatRect& destRect, const FloatRect& tileRect, const AffineTransform& patternTransform, const FloatPoint& phase, const FloatSize& spacing, RasterDrawingOptions options)
{
    CAPTURE(drawPattern(nativeImage, destRect, tileRect, patternTransform, phase, spacing, options));
    if (!patternTransform.isInvertible())
        return;

#if ENABLE(AX_CUSTOM_COLOR_MODE) && HAVE(CGSTYLE_COLORMATRIX_BLUR)
    // Tiles are never classified, so only an unconditional inversion applies to them.
    if (options.invertContent() == InvertContent::Forced) {
        GraphicsContextStateSaver stateSaver(*this);
        clip(destRect);
        setStyle(AXCustomColorModeController::colorPreservingInvertMatrix());
        setCompositeOperation(options.compositeOperator(), options.blendMode());
        beginTransparencyLayer(options.compositeOperator(), options.blendMode());
        drawPattern(nativeImage, destRect, tileRect, patternTransform, phase, spacing, { options, InvertContent::No, CompositeOperator::SourceOver, BlendMode::Normal });
        endTransparencyLayer();
        return;
    }
#endif

    auto image = nativeImage.platformImage();
    if (!image)
        return;
    auto imageSize = nativeImage.size();
    m_hasDrawn = true;
    swiftRenderer().drawPattern(image.get(), imageSize.width(), imageSize.height(), destRect.x(), destRect.y(), destRect.width(), destRect.height(), tileRect.x(), tileRect.y(), tileRect.width(), tileRect.height(), patternTransform.a(), patternTransform.d(), phase.x(), phase.y(), spacing.width(), spacing.height(), options.compositeOperator(), options.blendMode(), options.interpolationQuality());
}

// Draws a filled rectangle with a stroked border.
void GraphicsContextCG::drawRect(const FloatRect& rect, float borderThickness)
{
    CAPTURE(drawRect(rect, borderThickness));
    // FIXME: this function does not handle patterns and gradients like drawPath does, it probably should.
    ASSERT(!rect.isEmpty());
    m_hasDrawn = true;
    swiftRenderer().drawRect(rect, borderThickness, fillColor() != strokeColor());
}

// This is only used to draw borders.
void GraphicsContextCG::drawLine(const FloatPoint& point1, const FloatPoint& point2)
{
    CAPTURE(drawLine(point1, point2));
    if (swiftRenderer().drawLine(point1.x(), point1.y(), point2.x(), point2.y()))
        m_hasDrawn = true;
}

void GraphicsContextCG::drawGlyphsImmediate(const FontBase& font, std::span<const GlyphBufferGlyph> glyphs, std::span<const GlyphBufferAdvance> advances, const FloatPoint& point, FontSmoothingMode smoothingMode)
{
    CAPTURE(drawGlyphs(font, glyphs, advances, point, smoothingMode));
    {
        // FontCascade::drawGlyphs(), with what the renderer can't know about the font worked out here.
        const auto& platformData = font.platformData();
        if (!platformData.size())
            return;
        if (isInGPUProcess() && font.hasAnyComplexColorFormatGlyphs(glyphs)) {
            ASSERT_NOT_REACHED();
            return;
        }
        if (!font.allowsAntialiasing())
            smoothingMode = FontSmoothingMode::None;
        m_hasDrawn = true;

        Vector<CGSize, 256> translations;
        float ascentDelta = 0;
        RetainPtr ctFont = platformData.ctFont();
        if (platformData.orientation() == FontOrientation::Vertical && !glyphs.empty()) {
            translations.resize(glyphs.size());
            CTFontGetVerticalTranslationsForGlyphs(ctFont.get(), glyphs.data(), translations.mutableSpan().data(), glyphs.size());
            ascentDelta = font.fontMetrics().ascent(FontBaseline::Ideographic) - font.fontMetrics().ascent();
        }

        // A shadow with no blur may be drawn as glyphs in its color, whose alpha is multiplied by the fill color's.
        RetainPtr<CGColorRef> shadowFillColor;
        if (auto shadow = dropShadow(); shadow && shadow->color.isValid() && !shadow->radius)
            shadowFillColor = cachedCGColorInDestinationStandardRange(shadow->color.colorWithAlphaMultipliedBy(fillColor().alphaAsFloat()), colorSpace());

        static const CGAffineTransform verticalTranslationMatrix = computeBaseVerticalTextMatrix(computeBaseOverallTextMatrix(std::nullopt));
        CGRendererGlyphDrawFacts facts {
            computeTextMatrix(font), verticalTranslationMatrix, platformData.size(), font.syntheticBoldOffset(), ascentDelta,
            static_cast<uint8_t>(smoothingMode), platformData.isColorBitmapFont(), isInTransparencyLayer()
        };
        Vector<CGPoint, 256> positions(glyphs.size());
        swiftRenderer().drawGlyphs(ctFont.get(), CGRendererGlyphRun { glyphs, advances, translations.span() }, CGRendererGlyphPositions { positions.mutableSpan() }, facts, shadowFillColor.get(), point.x(), point.y());
    }
}

void GraphicsContextCG::drawEllipse(const FloatRect& rect)
{
    Path path;
    path.addEllipseInRect(rect);
    drawPath(path);
}

// The CGPattern applyFillPattern() and applyStrokePattern() set, for the Swift renderer to set.
RetainPtr<CGPatternRef> GraphicsContextCG::swiftFillPattern()
{
    RefPtr fillPattern = this->fillPattern();
    if (!fillPattern)
        return nullptr;
    return fillPattern->createPlatformPattern(AffineTransform(getUserToBaseCTM(contextForDraw())));
}

RetainPtr<CGPatternRef> GraphicsContextCG::swiftStrokePattern()
{
    RefPtr strokePattern = this->strokePattern();
    if (!strokePattern)
        return nullptr;
    return strokePattern->createPlatformPattern(AffineTransform(getUserToBaseCTM(contextForDraw())));
}

// The renderer draws ShadowBlur's shadows itself where it draws ShadowBlur's images itself (drawNativeImage()).
bool GraphicsContextCG::swiftDrawsShadowBlur() const
{
#if HAVE(SUPPORT_HDR_DISPLAY_APIS) && !PLATFORM(IOS_FAMILY)
    return canUseShadowBlur();
#else
    return false;
#endif
}

// Whether GraphicsContextState::setFillColor() of a shadow's color, as ShadowBlur sets it through a GraphicsContextView,
// would change the fill and so CG's fill color.
bool GraphicsContextCG::shadowColorChangesFill(const Color& shadowColor) const
{
    return !(fillBrush() == SourceBrush { shadowColor }) || m_state.indeterminateProperties().contains(GraphicsContextState::Change::FillBrush);
}

static uint8_t swiftBrushKind(const SourceBrush& brush)
{
    if (brush.gradient())
        return 1;
    return brush.pattern() ? 2 : 0;
}

void GraphicsContextCG::applyStrokePattern()
{
    CAPTURE(unsupported("applyStrokePattern"_s));
    RefPtr strokePattern = this->strokePattern();
    if (!strokePattern)
        return;

    const RetainPtr<CGContextRef>& cgContext = contextForDraw();
    AffineTransform userToBaseCTM = AffineTransform(getUserToBaseCTM(cgContext));

    auto platformPattern = strokePattern->createPlatformPattern(userToBaseCTM);
    if (!platformPattern)
        return;

    RetainPtr<CGColorSpaceRef> patternSpace = adoptCF(CGColorSpaceCreatePattern(0));
    CGContextSetStrokeColorSpace(cgContext, patternSpace.get());

    const CGFloat patternAlpha = 1;
    CGContextSetStrokePattern(cgContext, platformPattern.get(), &patternAlpha);
}

void GraphicsContextCG::applyFillPattern()
{
    CAPTURE(unsupported("applyFillPattern"_s));
    RefPtr fillPattern = this->fillPattern();
    if (!fillPattern)
        return;

    const RetainPtr<CGContextRef>& cgContext = contextForDraw();
    AffineTransform userToBaseCTM = AffineTransform(getUserToBaseCTM(cgContext));

    auto platformPattern = fillPattern->createPlatformPattern(userToBaseCTM);
    if (!platformPattern)
        return;

    RetainPtr<CGColorSpaceRef> patternSpace = adoptCF(CGColorSpaceCreatePattern(nullptr));
    CGContextSetFillColorSpace(cgContext, patternSpace.get());

    const CGFloat patternAlpha = 1;
    CGContextSetFillPattern(cgContext, platformPattern.get(), &patternAlpha);
}

void GraphicsContextCG::drawPath(const Path& path)
{
    CAPTURE(drawPath(path));
    if (path.isEmpty())
        return;

    m_hasDrawn = true;
    auto& renderer = swiftRenderer();
    if (renderer.fillsWithoutGradient() && renderer.strokesWithoutGradient()) {
        if (renderer.drawsPath())
            renderer.drawPath(protect(path.platformPath()).get(), swiftFillPattern().get(), swiftStrokePattern().get());
        return;
    }

    // There's no way to fill and stroke a path with a gradient in one draw.
    fillPath(path);
    strokePath(path);
}

void GraphicsContextCG::fillPath(const Path& path)
{
    CAPTURE(fillPath(path));
    if (path.isEmpty())
        return;

    m_hasDrawn = true;
    if (swiftRenderer().fillsWithoutGradient()) {
        swiftRenderer().fillPath(protect(path.platformPath()).get(), swiftFillPattern().get());
        return;
    }

    // A gradient fills the clip of the path's own segments: a CGPath of it would convert the Path in place.
    RefPtr fillGradient = this->fillGradient();
    paintGradientInClip(*fillGradient, fillGradientSpaceTransform(), [&] {
        return path.fastBoundingRect();
    }, [&](CGContextRef clipContext) {
        setCGContextPath(clipContext, path);
        if (fillRule() == WindRule::EvenOdd)
            CGContextEOClip(clipContext);
        else
            CGContextClip(clipContext);
    });
}

void GraphicsContextCG::strokePath(const Path& path)
{
    CAPTURE(strokePath(path));
    if (path.isEmpty())
        return;

    const RetainPtr<CGContextRef>& context = contextForDraw();
    if (swiftRenderer().strokesWithoutGradient()) {
        if (auto line = path.singleDataLine())
            swiftRenderer().strokeLineSegment(line->start().x(), line->start().y(), line->end().x(), line->end().y(), swiftStrokePattern().get());
        else
            swiftRenderer().strokePath(protect(path.platformPath()).get(), swiftStrokePattern().get());
        return;
    }

    RefPtr strokeGradient = this->strokeGradient();
    paintGradientInClip(*strokeGradient, strokeGradientSpaceTransform(), [&] {
        return strokedPathBoundingBox(context.get(), [&] {
            setCGContextPath(context.get(), path);
        });
    }, [&](CGContextRef clipContext) {
        CGContextSetLineWidth(clipContext, strokeThickness());
        setCGContextPath(clipContext, path);
        CGContextReplacePathWithStrokedPath(clipContext);
        CGContextClip(clipContext);
    });
}

void GraphicsContextCG::fillRect(const FloatRect& rect, RequiresClipToRect requiresClipToRect)
{
    CAPTURE(fillRect(rect, requiresClipToRect));
    const RetainPtr<CGContextRef>& context = contextForDraw();
    auto& renderer = swiftRenderer();
    RetainPtr pattern = swiftFillPattern();
    if (renderer.fillRect(rect, pattern.get()))
        return;

    if (RefPtr fillGradient = this->fillGradient()) {
        fillRect(rect, *fillGradient, fillGradientSpaceTransform(), requiresClipToRect);
        return;
    }

    // The renderer declines only gradients and blurred shadows.
    ASSERT(canUseShadowBlur());
    auto shadow = dropShadow();
    if (swiftDrawsShadowBlur()) {
        renderer.fillRectWithShadowBlur(rect, pattern.get(), shadow->color, shadow->radiusMode == ShadowRadiusMode::Legacy, shadowColorChangesFill(shadow->color));
        return;
    }

    // Where the renderer doesn't draw images (the iOS family), ShadowBlur draws through this context.
    if (fillPattern())
        applyFillPattern();
    CGContextStateSaver stateSaver(context);
    clearCGDropShadow();
    ShadowBlur contextShadow(*shadow, shadowsIgnoreTransforms());
    contextShadow.drawRectShadow(*this, FloatRoundedRect(rect));
    CGContextFillRect(context, rect);
}

void GraphicsContextCG::fillRect(const FloatRect& rect, Gradient& gradient, const AffineTransform& gradientSpaceTransform, RequiresClipToRect requiresClipToRect)
{
    CAPTURE(fillRect(rect, gradient, gradientSpaceTransform, requiresClipToRect));
    paintGradientInClip(gradient, gradientSpaceTransform, [&] {
        return rect;
    }, [&](CGContextRef clipContext) {
        if (requiresClipToRect == RequiresClipToRect::Yes || hasDropShadow())
            CGContextClipToRect(clipContext, rect);
    });
}

void GraphicsContextCG::fillRect(const FloatRect& rect, const Color& color)
{
    CAPTURE(fillRect(rect, color));
    const RetainPtr<CGContextRef>& context = contextForDraw();
    auto& renderer = swiftRenderer();
    bool changesFillColor = fillColor() != color;
    auto packedColor = color.tryGetAsPackedInline();
    if (packedColor) {
        if (renderer.fillRect(rect, packedColor->value, changesFillColor))
            return;
    } else if (renderer.fillRect(rect, cachedCGColorInDestinationStandardRange(color, colorSpace()).get(), changesFillColor))
        return;

    // The renderer declines only blurred shadows.
    ASSERT(canUseShadowBlur());
    auto shadow = dropShadow();
    if (packedColor && swiftDrawsShadowBlur()) {
        renderer.fillRectWithShadowBlur(rect, packedColor->value, changesFillColor, shadow->color, shadow->radiusMode == ShadowRadiusMode::Legacy, shadowColorChangesFill(shadow->color));
        return;
    }

    // ShadowBlur draws through this context: where the renderer doesn't draw images (the iOS family), or for a color that
    // isn't sRGBA8.
    Color oldFillColor = fillColor();
    if (changesFillColor)
        setCGFillColor(context, color, colorSpace());
    {
        CGContextStateSaver stateSaver(context);
        clearCGDropShadow();
        ShadowBlur contextShadow(*shadow, shadowsIgnoreTransforms());
        contextShadow.drawRectShadow(*this, FloatRoundedRect(rect));
        CGContextFillRect(context, rect);
    }
    if (changesFillColor)
        setCGFillColor(context, oldFillColor, colorSpace());
}

void GraphicsContextCG::fillRoundedRectImpl(const FloatRoundedRect& rect, const Color& color)
{
    CAPTURE(fillRoundedRect(rect, color));
    const RetainPtr<CGContextRef>& context = contextForDraw();
    Color oldFillColor = fillColor();

    if (oldFillColor != color)
        setCGFillColor(context, color, colorSpace());

    bool drawOwnShadow = canUseShadowBlur();
    CGContextStateSaver stateSaver(context, drawOwnShadow);
    if (drawOwnShadow) {
        clearCGDropShadow();

        const auto shadow = dropShadow();
        ASSERT(shadow);

        ShadowBlur contextShadow(*shadow, shadowsIgnoreTransforms());
        contextShadow.drawRectShadow(*this, rect);
    }

    const FloatRect& r = rect.rect();
    const CornerRadii& radii = rect.radii();
    bool equalWidths = (radii.topLeft().width() == radii.topRight().width() && radii.topRight().width() == radii.bottomLeft().width() && radii.bottomLeft().width() == radii.bottomRight().width());
    bool equalHeights = (radii.topLeft().height() == radii.bottomLeft().height() && radii.bottomLeft().height() == radii.topRight().height() && radii.topRight().height() == radii.bottomRight().height());
    bool hasCustomFill = fillGradient() || fillPattern();
    if (!hasCustomFill && equalWidths && equalHeights && radii.topLeft().width() * 2 == r.width() && radii.topLeft().height() * 2 == r.height())
        CGContextFillEllipseInRect(context, r);
    else {
        Path path;
        path.addRoundedRect(rect);
        fillPath(path);
    }

    if (drawOwnShadow)
        stateSaver.restore();

    if (oldFillColor != color)
        setCGFillColor(context, oldFillColor, colorSpace());
}

void GraphicsContextCG::fillRectWithRoundedHole(const FloatRect& rect, const FloatRoundedRect& roundedHoleRect, const Color& color)
{
    CAPTURE(fillRectWithRoundedHole(rect, roundedHoleRect, color));
    const RetainPtr<CGContextRef>& context = contextForDraw();

    Path path;
    path.addRect(rect);

    if (!roundedHoleRect.radii().isZero())
        path.addRoundedRect(roundedHoleRect);
    else
        path.addRect(roundedHoleRect.rect());

    Color oldFillColor = fillColor();

    if (oldFillColor != color)
        setCGFillColor(context, color, colorSpace());

    // fillRectWithRoundedHole() assumes that the edges of rect are clipped out, so we only care about shadows cast around inside the hole.
    bool drawOwnShadow = canUseShadowBlur();
    CGContextStateSaver stateSaver(context, drawOwnShadow);
    if (drawOwnShadow) {
        clearCGDropShadow();

        const auto shadow = dropShadow();
        ASSERT(shadow);

        ShadowBlur contextShadow(*shadow, shadowsIgnoreTransforms());
        contextShadow.drawInsetShadow(*this, rect, roundedHoleRect);
    }

    drawPathWithCGContext(context, kCGPathEOFill, path);

    if (drawOwnShadow)
        stateSaver.restore();

    if (oldFillColor != color)
        setCGFillColor(context, oldFillColor, colorSpace());
}

void GraphicsContextCG::resetClip()
{
    CAPTURE(resetClip());
    m_hasDrawn = true;
    swiftRenderer().resetClip();
}

void GraphicsContextCG::clip(const FloatRect& rect)
{
    CAPTURE(clip(rect));
    m_hasDrawn = true;
    swiftRenderer().clip(rect);
}

void GraphicsContextCG::clipOut(const FloatRect& rect)
{
    CAPTURE(clipOut(rect));
    m_hasDrawn = true;
    swiftRenderer().clipOut(rect);
}

void GraphicsContextCG::clipOut(const Path& path)
{
    CAPTURE(clipOut(path));
    const RetainPtr<CGContextRef>& context = contextForDraw();
    CGContextBeginPath(context);
    CGContextAddRect(context, CGContextGetClipBoundingBox(context));
    if (!path.isEmpty())
        addToCGContextPath(context, path);
    CGContextEOClip(context);
}

void GraphicsContextCG::clipPath(const Path& path, WindRule clipRule)
{
    CAPTURE(clipPath(path, clipRule));
    const RetainPtr<CGContextRef>& context = contextForDraw();
    if (path.isEmpty())
        CGContextClipToRect(context, CGRectZero);
    else {
        setCGContextPath(context, path);
        if (clipRule == WindRule::EvenOdd)
            CGContextEOClip(context);
        else
            CGContextClip(context);
    }
}

void GraphicsContextCG::clipTransformedPath(const AffineTransform& pathTransform, const Path& path, WindRule clipRule)
{
    const RetainPtr<CGContextRef>& context = contextForDraw();
    if (path.isEmpty()) {
        CGContextClipToRect(context, CGRectZero);
        return;
    }
    // The clip is stored in device space, so the CTM can be restored afterwards without affecting it.
    auto ctm = CGContextGetCTM(context);
    CGContextConcatCTM(context, pathTransform);
    setCGContextPath(context, path);
    if (clipRule == WindRule::EvenOdd)
        CGContextEOClip(context);
    else
        CGContextClip(context);
    CGContextSetCTM(context, ctm);
}

void GraphicsContextCG::clipToNativeImage(const NativeImage& nativeImage, const FloatRect& destRect)
{
    CAPTURE(unsupported("clipToImageBuffer"_s));
    // FIXME: This image needs to be grayscale to be used as an alpha mask here.
    const RetainPtr<CGContextRef>& context = contextForDraw();
    CGContextTranslateCTM(context, destRect.x(), destRect.maxY());
    CGContextScaleCTM(context, 1, -1);
    CGContextClipToRect(context, { { }, destRect.size() });
    CGContextClipToMask(context, { { }, destRect.size() }, nativeImage.platformImage().get());
    CGContextScaleCTM(context, 1, -1);
    CGContextTranslateCTM(context, -destRect.x(), -destRect.maxY());
}

IntRect GraphicsContextCG::clipBounds() const
{
    m_hasDrawn = true;
    return enclosingIntRect(swiftRenderer().clipBoundingBox());
}

void GraphicsContextCG::beginTransparencyLayer(float opacity)
{
    CAPTURE(beginTransparencyLayer(opacity));
    GraphicsContext::beginTransparencyLayer(opacity);
    GraphicsContext::save(GraphicsContextState::Purpose::TransparencyLayer);
    m_hasDrawn = true;
    swiftRenderer().beginTransparencyLayer(opacity);
    m_userToDeviceTransformKnownToBeIdentity = false;
}

void GraphicsContextCG::beginTransparencyLayer(CompositeOperator compositeOperator, BlendMode blendMode)
{
    CAPTURE(beginTransparencyLayer(compositeOperator, blendMode));
    UNUSED_PARAM(compositeOperator);
    UNUSED_PARAM(blendMode);
    // The layer keeps the current global alpha.
    GraphicsContext::beginTransparencyLayer(state().alpha());
    GraphicsContext::save(GraphicsContextState::Purpose::TransparencyLayer);
    m_hasDrawn = true;
    swiftRenderer().beginTransparencyLayerWithCurrentAlpha();
    m_userToDeviceTransformKnownToBeIdentity = false;
}

void GraphicsContextCG::endTransparencyLayer()
{
    CAPTURE(endTransparencyLayer());
    if (!stackSize() || m_state.purpose() != GraphicsContextState::Purpose::TransparencyLayer)
        return;
    GraphicsContext::endTransparencyLayer();
    m_hasDrawn = true;
    swiftRenderer().endTransparencyLayer();
    GraphicsContext::restore(GraphicsContextState::Purpose::TransparencyLayer);
    m_userToDeviceTransformKnownToBeIdentity = false;
}

static CGFloat scaledBlurRadius(CGFloat blurRadius, const CGAffineTransform& userToBaseCTM, bool shadowsIgnoreTransforms)
{
    if (!shadowsIgnoreTransforms)
        blurRadius *= singularValue(userToBaseCTM, SingularValueSelection::Smallest);

    // Extreme "blur" values can make text drawing crash or take crazy long times, so clamp
    return std::min(blurRadius, narrowPrecisionToCGFloat(1000.0));
}

struct BaseSpaceDropShadow {
    CGSize offset;
    CGFloat blurRadius;
};

static BaseSpaceDropShadow baseSpaceDropShadow(const GraphicsDropShadow& shadow, const CGAffineTransform& userToBaseCTM, bool shadowsIgnoreTransforms)
{
    CGSize offset = shadow.offset;
    if (!shadowsIgnoreTransforms)
        offset = CGSizeApplyAffineTransform(offset, userToBaseCTM);
    return { offset, scaledBlurRadius(shadow.radius, userToBaseCTM, shadowsIgnoreTransforms) };
}



FloatRect GraphicsContextCG::boundsIncludingDropShadow(const FloatRect& bounds)
{
    auto shadow = dropShadow();
    ASSERT(shadow);

    AffineTransform userToBaseCTM = getUserToBaseCTM(contextForDraw());
    auto baseToUserCTM = userToBaseCTM.inverse();
    if (!baseToUserCTM)
        return bounds;

    auto [offset, blurRadius] = baseSpaceDropShadow(*shadow, userToBaseCTM, shadowsIgnoreTransforms());

    // CG blurs shadows with a standard deviation of half the blur radius, and bounds the
    // result at 2.8 standard deviations plus a pixel.
    FloatRect baseSpaceBounds = userToBaseCTM.mapRect(bounds);
    FloatRect shadowBounds = baseSpaceBounds;
    shadowBounds.move(FloatSize(offset));
    shadowBounds.inflate(1.4 * blurRadius + 1);
    return baseToUserCTM->mapRect(unionRect(baseSpaceBounds, shadowBounds));
}

void GraphicsContextCG::clearCGDropShadow()
{
    CGContextSetStyle(contextForDraw(), nullptr);
}

void GraphicsContextCG::setSwiftRendererShadow(CGRenderer& renderer, const GraphicsDropShadow& shadow, bool isStyle)
{
    auto packedColor = shadow.color.tryGetAsPackedInline();
    CGRendererShadowValues values {
        shadow.offset.width(), shadow.offset.height(), shadow.radius, shadow.opacity,
        packedColor ? packedColor->value : 0, shadow.color.isValid(), shadow.color.isVisible()
    };
    if (packedColor || !values.isValid) {
        if (isStyle)
            renderer.setDropShadowStyle(values);
        else
            renderer.setDropShadow(values);
        return;
    }
    RetainPtr color = cachedCGColorInDestinationStandardRange(shadow.color, colorSpace());
    if (isStyle)
        renderer.setDropShadowStyle(values, color.get());
    else
        renderer.setDropShadow(values, color.get());
}

void GraphicsContextCG::didUpdateStateForSwiftRenderer(GraphicsContextState& state)
{
    auto changes = state.changes();
    if (!changes)
        return;

    if (changes.contains(GraphicsContextState::Change::ShadowsIgnoreTransforms)) {
        if (state.dropShadow())
            changes.add(GraphicsContextState::Change::DropShadow);
        if (state.style())
            changes.add(GraphicsContextState::Change::Style);
    }

    m_hasDrawn = true;
    auto& renderer = swiftRenderer();

    // The shadow and style below are converted with the new value, as C++'s state already has it.
    if (changes.contains(GraphicsContextState::Change::ShadowsIgnoreTransforms))
        renderer.setShadowsIgnoreTransforms(state.shadowsIgnoreTransforms());

    for (auto change : changes) {
        switch (change) {
        case GraphicsContextState::Change::FillBrush: {
            auto& brush = state.fillBrush();
            if (auto packedColor = brush.color().tryGetAsPackedInline())
                renderer.setFillPackedColor(packedColor->value, swiftBrushKind(brush));
            else
                renderer.setFillPlatformColor(cachedCGColorInDestinationStandardRange(brush.color(), colorSpace()).get(), swiftBrushKind(brush), brush.color().isVisible());
            break;
        }

        case GraphicsContextState::Change::FillRule:
            renderer.setFillRule(static_cast<uint8_t>(state.fillRule()));
            break;

        case GraphicsContextState::Change::StrokeBrush: {
            auto& brush = state.strokeBrush();
            if (auto packedColor = brush.color().tryGetAsPackedInline())
                renderer.setStrokePackedColor(packedColor->value, swiftBrushKind(brush));
            else
                renderer.setStrokePlatformColor(cachedCGColorInDestinationStandardRange(brush.color(), colorSpace()).get(), swiftBrushKind(brush), brush.color().isVisible());
            break;
        }

        case GraphicsContextState::Change::StrokeThickness:
            renderer.setStrokeThickness(state.strokeThickness());
            break;

        case GraphicsContextState::Change::StrokeStyle:
            renderer.setStrokeStyle(static_cast<uint8_t>(state.strokeStyle()));
            break;

        case GraphicsContextState::Change::CompositeMode:
            renderer.setCompositeMode(state.compositeMode().operation, state.compositeMode().blendMode);
            break;

        case GraphicsContextState::Change::DropShadow:
            if (auto& shadow = state.dropShadow())
                setSwiftRendererShadow(renderer, *shadow, false);
            else
                renderer.clearDropShadow();
            break;

        case GraphicsContextState::Change::Style:
            if (auto& style = state.style()) {
                WTF::switchOn(*style,
                    [&](const GraphicsDropShadow& shadow) {
                        setSwiftRendererShadow(renderer, shadow, true);
                    },
                    [&](const GraphicsGaussianBlur& gaussianBlur) {
#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
                        ASSERT(gaussianBlur.radius.width() == gaussianBlur.radius.height());
                        renderer.setGaussianBlurStyle(gaussianBlur.radius.width());
#else
                        UNUSED_PARAM(gaussianBlur);
#endif
                    },
                    [&](const GraphicsColorMatrix& colorMatrix) {
#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
                        CGRendererColorMatrix values;
                        for (auto [destination, source] : zippedRange(values.values, colorMatrix.values))
                            destination = source;
                        renderer.setColorMatrixStyle(values);
#else
                        UNUSED_PARAM(colorMatrix);
#endif
                    });
            } else
                renderer.setNoStyle();
            break;

        case GraphicsContextState::Change::Alpha:
            renderer.setAlpha(state.alpha());
            break;

        case GraphicsContextState::Change::ImageInterpolationQuality:
            renderer.setImageInterpolationQuality(state.imageInterpolationQuality());
            break;

        case GraphicsContextState::Change::TextDrawingMode:
            renderer.setTextDrawingMode(state.textDrawingMode().toRaw());
            break;

        case GraphicsContextState::Change::ShouldAntialias:
            renderer.setShouldAntialias(state.shouldAntialias());
            break;

        case GraphicsContextState::Change::ShouldSmoothFonts:
            renderer.setShouldSmoothFonts(state.shouldSmoothFonts());
            break;

        case GraphicsContextState::Change::ShouldSubpixelQuantizeFonts:
            renderer.setShouldSubpixelQuantizeFonts(state.shouldSubpixelQuantizeFonts());
            break;

        case GraphicsContextState::Change::ShadowsIgnoreTransforms:
            break;
        }
    }

    state.didApplyChanges();
}

void GraphicsContextCG::didUpdateState(GraphicsContextState& state)
{
    CAPTURE(stateUpdate(state));
    didUpdateStateForSwiftRenderer(state);
}

void GraphicsContextCG::setMiterLimit(float limit)
{
    CAPTURE(setMiterLimit(limit));
    CGContextSetMiterLimit(contextForDraw(), limit);
}

void GraphicsContextCG::clearRect(const FloatRect& r)
{
    CAPTURE(clearRect(r));
    m_hasDrawn = true;
    swiftRenderer().clearRect(r);
}

void GraphicsContextCG::strokeRect(const FloatRect& rect, float lineWidth)
{
    CAPTURE(strokeRect(rect, lineWidth));
    const RetainPtr<CGContextRef>& context = contextForDraw();
    if (swiftRenderer().strokeRect(rect, lineWidth, swiftStrokePattern().get()))
        return;

    // The renderer declines only gradients.
    RefPtr strokeGradient = this->strokeGradient();
    paintGradientInClip(*strokeGradient, strokeGradientSpaceTransform(), [&] {
        return strokedPathBoundingBox(context.get(), [&] {
            CGContextSetLineWidth(context.get(), std::max(lineWidth, 0.f));
            CGContextAddRect(context.get(), rect);
        });
    }, [&](CGContextRef clipContext) {
        CGContextSetLineWidth(clipContext, std::max(lineWidth, 0.f));
        CGContextAddRect(clipContext, rect);
        CGContextReplacePathWithStrokedPath(clipContext);
        CGContextClip(clipContext);
    });
}

void GraphicsContextCG::strokeArc(const PathArc& arc)
{
    CAPTURE(strokeArc(arc));
#if HAVE(CGCONTEXT_STROKE_ARC)
    if (!strokeGradient()) {
        if (strokePattern())
            applyStrokePattern();

        const RetainPtr<CGContextRef>& context = contextForDraw();
        CGContextStrokeArc(context, arc.center.x(), arc.center.y(), arc.radius, arc.startAngle, arc.endAngle, arc.direction == RotationDirection::Counterclockwise);
        return;
    }
#endif
    GraphicsContext::strokeArc(arc);
}

void GraphicsContextCG::strokeLine(const PathDataLine& line)
{
    CAPTURE(strokeLine(line));
    if (swiftRenderer().strokesWithoutGradient()) {
        m_hasDrawn = true;
        swiftRenderer().strokeLineSegment(line.start().x(), line.start().y(), line.end().x(), line.end().y(), swiftStrokePattern().get());
        return;
    }
    // Gradient stroking requires building a stroked path and clipping to it: strokePath() via the base class.
    GraphicsContext::strokeLine(line);
}

void GraphicsContextCG::setLineCap(LineCap cap)
{
    CAPTURE(setLineCap(cap));
    switch (cap) {
    case LineCap::Butt:
        CGContextSetLineCap(contextForDraw(), kCGLineCapButt);
        break;
    case LineCap::Round:
        CGContextSetLineCap(contextForDraw(), kCGLineCapRound);
        break;
    case LineCap::Square:
        CGContextSetLineCap(contextForDraw(), kCGLineCapSquare);
        break;
    }
}

void GraphicsContextCG::setLineDash(const DashArray& dashes, float dashOffset)
{
    CAPTURE(setLineDash(dashes, dashOffset));
    if (dashOffset < 0) {
        float length = 0;
        for (size_t i = 0; i < dashes.size(); ++i)
            length += static_cast<float>(dashes[i]);
        // CGContextSetLineDash repeats odd-length arrays, so the effective cycle is twice the sum.
        if (dashes.size() % 2)
            length *= 2;
        if (length)
            dashOffset = fmod(dashOffset, length) + length;
    }
    auto dashesSpan = dashes.span();
    CGContextSetLineDash(contextForDraw(), dashOffset, dashesSpan.data(), dashesSpan.size());
}

void GraphicsContextCG::setLineJoin(LineJoin join)
{
    CAPTURE(setLineJoin(join));
    switch (join) {
    case LineJoin::Miter:
        CGContextSetLineJoin(contextForDraw(), kCGLineJoinMiter);
        break;
    case LineJoin::Round:
        CGContextSetLineJoin(contextForDraw(), kCGLineJoinRound);
        break;
    case LineJoin::Bevel:
        CGContextSetLineJoin(contextForDraw(), kCGLineJoinBevel);
        break;
    }
}

void GraphicsContextCG::scale(const FloatSize& size)
{
    CAPTURE(scale(size));
    m_hasDrawn = true;
    swiftRenderer().scale(size.width(), size.height());
    m_userToDeviceTransformKnownToBeIdentity = false;
}

void GraphicsContextCG::rotate(float angle)
{
    CAPTURE(rotate(angle));
    m_hasDrawn = true;
    swiftRenderer().rotate(angle);
    m_userToDeviceTransformKnownToBeIdentity = false;
}

void GraphicsContextCG::translate(float x, float y)
{
    CAPTURE(translate(x, y));
    m_hasDrawn = true;
    swiftRenderer().translate(x, y);
    m_userToDeviceTransformKnownToBeIdentity = false;
}

void GraphicsContextCG::concatCTM(const AffineTransform& transform)
{
    CAPTURE(concatCTM(transform));
    m_hasDrawn = true;
    swiftRenderer().concatCTM(transform);
    m_userToDeviceTransformKnownToBeIdentity = false;
}

void GraphicsContextCG::setCTM(const AffineTransform& transform)
{
    CAPTURE(setCTM(transform));
    m_hasDrawn = true;
    swiftRenderer().setCTM(transform);
    m_userToDeviceTransformKnownToBeIdentity = false;
}

AffineTransform GraphicsContextCG::getCTM(IncludeDeviceScale includeScale) const
{
    m_hasDrawn = true;
    return swiftRenderer().ctm(includeScale == DefinitelyIncludeDeviceScale);
}

FloatRect GraphicsContextCG::roundToDevicePixels(const FloatRect& rect) const
{
    CGAffineTransform deviceMatrix;
    if (!m_userToDeviceTransformKnownToBeIdentity) {
        deviceMatrix = CGContextGetUserSpaceToDeviceSpaceTransform(contextForState());
        if (CGAffineTransformIsIdentity(deviceMatrix))
            m_userToDeviceTransformKnownToBeIdentity = true;
    }
    if (m_userToDeviceTransformKnownToBeIdentity)
        return roundedIntRect(rect);
    return cgRoundToDevicePixelsNonIdentity(deviceMatrix, rect);
}

void GraphicsContextCG::drawLinesForText(const FloatPoint& origin, float thickness, std::span<const FloatSegment> lineSegments, bool isPrinting, bool doubleLines, StrokeStyle strokeStyle)
{
    CAPTURE(drawLinesForText(origin, thickness, lineSegments, isPrinting, doubleLines, strokeStyle));
    auto [rects, color] = computeRectsAndStrokeColorForLinesForText(origin, thickness, lineSegments, isPrinting, doubleLines, strokeStyle);
    if (rects.isEmpty())
        return;
    bool changeFillColor = fillColor() != color;
    m_hasDrawn = true;
    CGRendererRects rectsView { rects.span() };
    if (auto packedColor = color.tryGetAsPackedInline())
        swiftRenderer().fillRectsInPackedColor(rectsView, packedColor->value, changeFillColor);
    else
        swiftRenderer().fillRectsInPlatformColor(rectsView, cachedCGColorInDestinationStandardRange(color, colorSpace()).get(), changeFillColor);
}

void GraphicsContextCG::setURLForRect(const URL& link, const FloatRect& destRect)
{
    CAPTURE(unsupported("setURLForRect"_s));
    RetainPtr<CFURLRef> urlRef = link.createCFURL();
    if (!urlRef)
        return;

    m_hasDrawn = true;
    swiftRenderer().setURLForRect(urlRef.get(), destRect);
}

bool GraphicsContextCG::isCALayerContext() const
{
    return m_isLayerCGContext;
}

bool GraphicsContextCG::knownToHaveFloatBasedBacking() const
{
    const RetainPtr<CGContextRef>& context = contextForDraw();

    if (CGContextGetType(context) == kCGContextTypeIOSurface)
        return CGIOSurfaceContextGetBitmapInfo(context) & kCGBitmapFloatComponents;
    if (CGContextGetType(context) == kCGContextTypeBitmap)
        return CGBitmapContextGetBitmapInfo(context) & kCGBitmapFloatComponents;
    return false;
}

RenderingMode GraphicsContextCG::renderingMode() const
{
    return m_renderingMode;
}

void GraphicsContextCG::applyDeviceScaleFactor(float deviceScaleFactor)
{
    CAPTURE(applyDeviceScaleFactor(deviceScaleFactor));
    GraphicsContext::applyDeviceScaleFactor(deviceScaleFactor);
    // CoreGraphics expects the base CTM of a HiDPI context to have the scale factor applied to it. Failing to change the
    // base level CTM will cause certain CG features, such as focus rings, to draw with a scale factor of 1 rather than the
    // actual scale factor.
    m_hasDrawn = true;
    swiftRenderer().applyDeviceScaleFactorToBaseCTM(deviceScaleFactor);
}

void GraphicsContextCG::fillEllipse(const FloatRect& ellipse)
{
    CAPTURE(fillEllipse(ellipse));
    if (swiftRenderer().fillEllipse(ellipse)) {
        m_hasDrawn = true;
        return;
    }
    // CGContextFillEllipseInRect only supports solid colors.
    fillEllipseAsPath(ellipse);
}

void GraphicsContextCG::strokeEllipse(const FloatRect& ellipse)
{
    CAPTURE(strokeEllipse(ellipse));
    if (swiftRenderer().strokeEllipse(ellipse)) {
        m_hasDrawn = true;
        return;
    }
    // CGContextStrokeEllipseInRect only supports solid colors.
    strokeEllipseAsPath(ellipse);
}

void GraphicsContextCG::beginPage(const FloatRect& pageRect)
{
    CAPTURE(unsupported("beginPage"_s));
    const RetainPtr<CGContextRef>& context = contextForDraw();
    if (!swiftRenderer().beginPDFPage(pageRect)) {
        ASSERT_NOT_REACHED();
        return;
    }

    ASSERT(!stackSize());
    m_state = GraphicsContextState { GraphicsContextState::basicChangeFlags, coreInterpolationQuality(context.get()) };
    swiftRenderer().resetState(m_state.imageInterpolationQuality());
    didUpdateState(m_state);
    m_userToDeviceTransformKnownToBeIdentity = false;
}

void GraphicsContextCG::endPage()
{
    CAPTURE(unsupported("endPage"_s));
    m_hasDrawn = true;
    if (!swiftRenderer().endPDFPage())
        ASSERT_NOT_REACHED();
}

bool GraphicsContextCG::supportsInternalLinks() const
{
    return true;
}

void GraphicsContextCG::setDestinationForRect(const String& name, const FloatRect& destRect)
{
    CAPTURE(unsupported("setDestinationForRect"_s));
    m_hasDrawn = true;
    swiftRenderer().setDestinationForRect(name.createCFString().get(), destRect);
}

void GraphicsContextCG::addDestinationAtPoint(const String& name, const FloatPoint& position)
{
    CAPTURE(unsupported("addDestinationAtPoint"_s));
    m_hasDrawn = true;
    swiftRenderer().addDestinationAtPoint(name.createCFString().get(), position.x(), position.y());
}

bool GraphicsContextCG::canUseShadowBlur() const
{
    return (renderingMode() == RenderingMode::Unaccelerated) && hasBlurredDropShadow() && !m_state.shadowsIgnoreTransforms();
}

bool GraphicsContextCG::consumeHasDrawn()
{
    bool hasDrawn = m_hasDrawn;
    m_hasDrawn = false;
    return hasDrawn;
}

#if HAVE(SUPPORT_HDR_DISPLAY)
void GraphicsContextCG::setMaxEDRHeadroom(std::optional<float> headroom)
{
    CAPTURE(setMaxEDRHeadroom(headroom));
    m_maxEDRHeadroom = headroom;
    swiftRenderer().setMaxEDRHeadroom(headroom.value_or(0), !!headroom);
}
#endif


}

#if USE(APPLE_INTERNAL_SDK) && __has_include(<WebKitAdditions/IOSurfaceAdditionsAfter.mm>)
#include <WebKitAdditions/IOSurfaceAdditionsAfter.mm>
#endif

#endif
