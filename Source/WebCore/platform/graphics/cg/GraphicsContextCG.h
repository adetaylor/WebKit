/*
 * Copyright (C) 2006-2024 Apple Inc. All rights reserved.
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

#if USE(CG)

#include <WebCore/CGRendererSwiftBridge.h>
#include <WebCore/ColorSpaceCG.h>
#include <WebCore/GraphicsContext.h>
#include <wtf/ForbidHeapAllocation.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class CGRendererCore;
class GraphicsContextCGCapture;

class WEBCORE_EXPORT GraphicsContextCG : public GraphicsContext {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(GraphicsContextCG, WEBCORE_EXPORT);
public:
    enum CGContextSource {
        Unknown,
        CGContextFromCALayer
    };
    GraphicsContextCG(CGContextRef, CGContextSource = CGContextSource::Unknown, std::optional<RenderingMode> knownRenderingMode = std::nullopt);

    ~GraphicsContextCG();

    bool hasPlatformContext() const final;

    // Returns the platform context for any purpose, including draws. Conservative estimate.
    CGContextRef platformContext() const final { return contextForDraw(); }

    const ColorSpace& colorSpace() const final;

    void save(GraphicsContextState::Purpose = GraphicsContextState::Purpose::SaveRestore) final;
    void restore(GraphicsContextState::Purpose = GraphicsContextState::Purpose::SaveRestore) final;

    using GraphicsContext::drawNativeImage;
    void drawNativeImage(const NativeImage&, const FloatRect& destRect, const FloatRect& srcRect, RasterDrawingOptions = { }) final;
    void drawRect(const FloatRect&, float borderThickness = 1) final;
    void drawGlyphsImmediate(const FontBase&, std::span<const GlyphBufferGlyph>, std::span<const GlyphBufferAdvance>, const FloatPoint&, FontSmoothingMode) final;
    void drawLine(const FloatPoint&, const FloatPoint&) final;
    void drawEllipse(const FloatRect&) final;

    void applyStrokePattern() final;
    void applyFillPattern() final;
    void drawPath(const Path&) final;
    void fillPath(const Path&) final;
    void strokePath(const Path&) final;

    void beginTransparencyLayer(float opacity) final;
    void beginTransparencyLayer(CompositeOperator, BlendMode) final;
    void endTransparencyLayer() final;

    void applyDeviceScaleFactor(float factor) final;

    using GraphicsContext::fillRect;
    void fillRect(const FloatRect&, RequiresClipToRect = RequiresClipToRect::Yes) final;
    void fillRect(const FloatRect&, const Color&) final;
    void fillRect(const FloatRect&, Gradient&, const AffineTransform&, RequiresClipToRect = RequiresClipToRect::Yes) final;
    void fillRoundedRectImpl(const FloatRoundedRect&, const Color&) final;
    void fillRectWithRoundedHole(const FloatRect&, const FloatRoundedRect& roundedHoleRect, const Color&) final;
    void clearRect(const FloatRect&) final;
    void strokeRect(const FloatRect&, float lineWidth) final;
    void strokeArc(const PathArc&) final;
    void strokeLine(const PathDataLine&) final;

    void fillEllipse(const FloatRect& ellipse) final;
    void strokeEllipse(const FloatRect& ellipse) final;

    bool isCALayerContext() const final;
    bool knownToHaveFloatBasedBacking() const final;

    RenderingMode renderingMode() const final;

    void resetClip() final;
    void clip(const FloatRect&) final;
    void clipOut(const FloatRect&) final;

    void clipOut(const Path&) final;

    void clipPath(const Path&, WindRule = WindRule::EvenOdd) final;
    void clipTransformedPath(const AffineTransform&, const Path&, WindRule = WindRule::EvenOdd) final;

    void clipToNativeImage(const NativeImage&, const FloatRect&) final;

    IntRect clipBounds() const final;

    void setLineCap(LineCap) final;
    void setLineDash(const DashArray&, float dashOffset) final;
    void setLineJoin(LineJoin) final;
    void setMiterLimit(float) final;

    void drawPattern(const NativeImage&, const FloatRect& destRect, const FloatRect& tileRect, const AffineTransform& patternTransform, const FloatPoint& phase, const FloatSize& spacing, RasterDrawingOptions = { }) final;

    using GraphicsContext::scale;
    void scale(const FloatSize&) final;
    void rotate(float angleInRadians) final;
    void translate(float x, float y) final;

    void concatCTM(const AffineTransform&) final;
    void setCTM(const AffineTransform&) override;

    AffineTransform getCTM(IncludeDeviceScale = PossiblyIncludeDeviceScale) const override;

    void drawFocusRing(const Path&, float outlineWidth, const Color&, float zoomFactor) final;
    void drawFocusRing(const Vector<FloatRect>&, float outlineWidth, const Color&, float zoomFactor) final;

    void drawLinesForText(const FloatPoint&, float thickness, std::span<const FloatSegment>, bool isPrinting, bool doubleLines, StrokeStyle) final;

    void drawDotsForDocumentMarker(const FloatRect&, DocumentMarkerLineStyle) final;

    void beginPage(const FloatRect& pageRect) final;
    void unwindStateStack() final;
    void endPage() final;

    void setURLForRect(const URL&, const FloatRect&) final;

    void setDestinationForRect(const String& name, const FloatRect&) final;
    void addDestinationAtPoint(const String& name, const FloatPoint&) final;

    bool supportsInternalLinks() const final;

    void didUpdateState(GraphicsContextState&) final;

    virtual bool canUseShadowBlur() const;

    FloatRect roundToDevicePixels(const FloatRect&) const;

    // Returns the platform context for draws.
    const RetainPtr<CGContextRef>& contextForDraw() const
    {
        ASSERT(m_cgContext);
        m_hasDrawn = true;
        return m_cgContext;
    }

    // Returns false if there has not been any potential draws since last call.
    // Returns true if there has been potential draws since last call.
    NODELETE bool consumeHasDrawn();

#if HAVE(SUPPORT_HDR_DISPLAY)
    void setMaxEDRHeadroom(std::optional<float>) final;
#endif

    // Makes GraphicsContext's state the renderer's, for C++ that reads it after the renderer was used without this context.
    void updateStateFromSwiftRenderer();
    void updateStateFromSwiftRenderer(const CGRendererStateSnapshot&, GraphicsContextState::ChangeFlags);

    bool canLendSwiftRenderer() const final { return true; }

    class SwiftRendererLend;
    // Lends the context's renderer to a Swift receiver for one message: state() is the renderer, which the receiver's handler
    // takes inout. Until the lend ends, nothing else may use the renderer. A lender keeps a reference to the context and
    // registers for as long as it can lend (addSwiftRendererLender()); the context must have no lenders when destroyed. C++
    // only: Swift takes the state from the lend's C++ owner.
    static SwiftRendererLend lendSwiftRenderer(GraphicsContextCG&) __attribute__((availability(swift, unavailable)));

    // Testing only, for the differential harness: lends the renderer to what RemoteCGRenderer's handler for the message does,
    // then draws a rect or ellipse the handler declines as RemoteGraphicsContext's handler would. Returns false where the
    // handler declines a path segment, for the caller to draw it.
    enum class ReceiverMessageForTesting : uint8_t {
        Save, Restore, Translate, Rotate, Scale, SetCTM, ConcatCTM, SetFillPackedColor, SetStrokePackedColor,
        SetStrokePackedColorAndThickness, SetFillRule, SetStrokeThickness, SetStrokeStyle, SetCompositeMode, SetAlpha,
        SetImageInterpolationQuality, SetShouldAntialias, SetShouldSmoothFonts, SetShouldSubpixelQuantizeFonts, SetLineCap,
        SetLineJoin, SetMiterLimit, Clip, ClipOut, ResetClip, DrawLine, FillRect, FillEllipse, StrokeRect, StrokeEllipse,
        ClearRect, ApplyStrokePattern, ApplyFillPattern, FillPathSegment, StrokePathSegment, DrawPathSegment, DrawRect,
        StrokeLinesWithColorAndThickness, FillPath, StrokePath, DrawPath, DrawNativeImage, DrawPattern
    };
    // The path is FillPath's, StrokePath's or DrawPath's; the image DrawNativeImage's or DrawPattern's.
    WEBCORE_EXPORT bool applyReceiverMessageForTesting(const CGRendererReceiverTestMessage&, const Path* = nullptr, CGImageRef = nullptr) __attribute__((availability(swift, unavailable)));
    // The image of an image buffer that this draws (nativeImageForDrawing()), for a Swift receiver's draw of one.
    WEBCORE_EXPORT RefPtr<NativeImage> nativeImageForSwiftReceiver(ImageBuffer&) __attribute__((availability(swift, unavailable)));
    // Testing only: the renderer's saved levels, which include those only a Swift receiver saved.
    WEBCORE_EXPORT unsigned rendererSavedLevelCountForTesting() const __attribute__((availability(swift, unavailable)));
    void addSwiftRendererLender() __attribute__((availability(swift, unavailable)));
    void removeSwiftRendererLender() __attribute__((availability(swift, unavailable)));

private:
    // Whether the renderer, which this context keeps in place, is lent to a Swift receiver (SwiftRendererLend).
    enum class SwiftRendererState : uint8_t { InPlace, InPlaceLent };

    template<typename Function> decltype(auto) withSwiftRenderer(Function&&) const;
    void updateStaleState() final;
    void didUpdateStateForSwiftRenderer(GraphicsContextState&);
    void setSwiftRendererShadow(const GraphicsDropShadow&, bool isStyle);
    bool swiftDrawsShadowBlur() const;
    bool shadowColorChangesFill(const Color&) const;
    void clearCGDropShadow();

    FloatRect boundsIncludingDropShadow(const FloatRect&);
    void paintGradientInClip(Gradient&, const AffineTransform& gradientSpaceTransform, NOESCAPE const Invocable<FloatRect()> auto& computeContentBounds, NOESCAPE const Invocable<void(CGContextRef)> auto& clip);
#if !HAVE(CGSTYLE_FIXES_DROP_SHADOW_BLUR)
    void paintGradientInCGLayer(Gradient&, const AffineTransform& gradientSpaceTransform, const FloatRect& contentBounds, NOESCAPE const Invocable<void(CGContextRef)> auto& clip);
#endif

    // Returns the platform context for purposes of context state change, not draws.
    NODELETE const RetainPtr<CGContextRef>& contextForState() const;

    const RetainPtr<CGContextRef> m_cgContext;
#if ASSERT_ENABLED
    std::unique_ptr<GraphicsContextCGCapture> m_capture;
#endif
    // The CGRendererCore (CGRenderer.swift) this context draws with, built in place. GraphicsContextCG.cpp checks the size.
    static constexpr size_t swiftRendererSize = 304;
    alignas(8) mutable std::byte m_swiftRendererStorage[swiftRendererSize];
    mutable std::optional<ColorSpace> m_colorSpace;
#if HAVE(SUPPORT_HDR_DISPLAY)
    std::optional<float> m_maxEDRHeadroom;
#endif
    const RenderingMode m_renderingMode : 2; // NOLINT
    const bool m_isLayerCGContext : 1;
    // A byte of its own rather than a bitfield, so that lending and returning the renderer are single stores.
    mutable SwiftRendererState m_swiftRendererState;
    unsigned m_swiftRendererLenders { 0 };
    // Flag for pending draws. Start with true because we do not know what commands have been scheduled to the context.
    mutable bool m_hasDrawn : 1 { true };
};

class GraphicsContextCG::SwiftRendererLend {
    WTF_MAKE_NONCOPYABLE(SwiftRendererLend);
    WTF_FORBID_HEAP_ALLOCATION;
public:
    // The receiver may have changed the renderer's state: GraphicsContext's copy is brought up to date when next used.
    ~SwiftRendererLend()
    {
        if (m_context) {
            m_context->m_swiftRendererState = SwiftRendererState::InPlace;
            m_context->m_stateIsStale = true;
        }
    }

    explicit operator bool() const { return m_context; }
    CGRendererCore& state() const { return *m_core; }

private:
    friend class GraphicsContextCG;

    SwiftRendererLend(GraphicsContextCG* context, CGRendererCore* core)
        : m_context(context)
        , m_core(core)
    {
    }

    GraphicsContextCG* const m_context;
    CGRendererCore* const m_core;
};

inline GraphicsContextCG::SwiftRendererLend GraphicsContextCG::lendSwiftRenderer(GraphicsContextCG& context)
{
    // Lent already means that something reached the renderer while a Swift receiver has it.
    RELEASE_ASSERT(context.m_swiftRendererState == SwiftRendererState::InPlace);
    context.m_swiftRendererState = SwiftRendererState::InPlaceLent;
    // Only Swift reaches the renderer through this address.
    return SwiftRendererLend { &context, reinterpret_cast<CGRendererCore*>(context.m_swiftRendererStorage) };
}

CGAffineTransform getUserToBaseCTM(CGContextRef);

enum class SingularValueSelection : bool { Smallest, Largest };
CGFloat singularValue(const CGAffineTransform& userToBaseCTM, SingularValueSelection);

} // namespace WebCore

#include <WebCore/CGContextStateSaver.h>

#endif // USE(CG)
