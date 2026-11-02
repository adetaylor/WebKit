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

#if USE(CG)

#include <WebCore/GraphicsContext.h>
#include <wtf/HashMap.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

// The calls a GraphicsContextCG receives, recorded for replay by the CG renderer's differential harness. Recorded by debug
// builds only, and only when the WEBKIT_CG_CAPTURE environment variable is set (__XPC_WEBKIT_CG_CAPTURE for the GPU
// process). Each process appends its streams to one file in its temporary directory, cgcapture/<pid>.gcop. A call the
// format can't describe ends its stream.
enum class GraphicsContextCGCaptureOp : uint16_t {
    StreamHeader = 1,
    StreamEnd,
    Unsupported,
    DefineImage,
    StateUpdate,
    Save,
    Restore,
    BeginTransparencyLayer,
    BeginTransparencyLayerWithCompositeMode,
    EndTransparencyLayer,
    Translate,
    Scale,
    Rotate,
    ConcatCTM,
    SetCTM,
    ApplyDeviceScaleFactor,
    Clip,
    ClipOut,
    ResetClip,
    ClipPath,
    ClipOutPath,
    ClearRect,
    FillRect,
    FillRectWithColor,
    StrokeRect,
    FillRoundedRect,
    FillRectWithRoundedHole,
    FillEllipse,
    StrokeEllipse,
    DrawRect,
    DrawLine,
    FillPath,
    StrokePath,
    DrawPath,
    StrokeArc,
    StrokeLine,
    SetLineCap,
    SetLineJoin,
    SetMiterLimit,
    SetLineDash,
    DrawNativeImage,
    DrawLinesForText,
    DrawDotsForDocumentMarker,
    DrawPattern,
    FillRectWithGradient,
    DefineFont,
    DrawGlyphs,
    SetMaxEDRHeadroom,
};

// 2: brushes start with their kind (0 color, 1 gradient, 2 pattern). 3: fonts and glyphs. 4: setMaxEDRHeadroom().
constexpr uint32_t graphicsContextCGCaptureVersion = 4;

#if ASSERT_ENABLED

class GraphicsContextCGCapture {
    WTF_MAKE_TZONE_ALLOCATED(GraphicsContextCGCapture);
public:
    static std::unique_ptr<GraphicsContextCGCapture> createIfEnabled(CGContextRef, RenderingMode, bool isLayerContext);
    ~GraphicsContextCGCapture();

    // Only the outermost call is recorded; what it does inside is replayed by replaying it.
    class Scope {
    public:
        explicit Scope(GraphicsContextCGCapture* capture)
            : m_capture(capture && !capture->m_stopped ? capture : nullptr)
        {
            if (m_capture)
                ++m_capture->m_depth;
        }
        ~Scope()
        {
            if (m_capture)
                --m_capture->m_depth;
        }
        GraphicsContextCGCapture* outermost() const { return m_capture && m_capture->m_depth == 1 ? m_capture : nullptr; }
    private:
        GraphicsContextCGCapture* m_capture;
    };

    void stateUpdate(const GraphicsContextState&);
    void save(GraphicsContextState::Purpose);
    void restore(GraphicsContextState::Purpose);
    void beginTransparencyLayer(float opacity);
    void beginTransparencyLayer(CompositeOperator, BlendMode);
    void endTransparencyLayer();
    void translate(float x, float y);
    void scale(const FloatSize&);
    void rotate(float);
    void concatCTM(const AffineTransform&);
    void setCTM(const AffineTransform&);
    void applyDeviceScaleFactor(float);
    void clip(const FloatRect&);
    void clipOut(const FloatRect&);
    void resetClip();
    void clipPath(const Path&, WindRule);
    void clipOut(const Path&);
    void clearRect(const FloatRect&);
    void fillRect(const FloatRect&, GraphicsContext::RequiresClipToRect);
    void fillRect(const FloatRect&, const Color&);
    void fillRect(const FloatRect&, const Gradient&, const AffineTransform& gradientSpaceTransform, GraphicsContext::RequiresClipToRect);
    void strokeRect(const FloatRect&, float lineWidth);
    void fillRoundedRect(const FloatRoundedRect&, const Color&);
    void fillRectWithRoundedHole(const FloatRect&, const FloatRoundedRect&, const Color&);
    void fillEllipse(const FloatRect&);
    void strokeEllipse(const FloatRect&);
    void drawRect(const FloatRect&, float borderThickness);
    void drawLine(const FloatPoint&, const FloatPoint&);
    void fillPath(const Path&);
    void strokePath(const Path&);
    void drawPath(const Path&);
    void strokeArc(const PathArc&);
    void strokeLine(const PathDataLine&);
    void setLineCap(LineCap);
    void setLineJoin(LineJoin);
    void setMiterLimit(float);
    void setLineDash(const DashArray&, float dashOffset);
    void drawNativeImage(const NativeImage&, const FloatRect& destination, const FloatRect& source, ImageDrawingOptions);
    void drawPattern(const NativeImage&, const FloatRect& destination, const FloatRect& tile, const AffineTransform& patternTransform, const FloatPoint& phase, const FloatSize& spacing, ImageDrawingOptions);
    void drawLinesForText(const FloatPoint&, float thickness, std::span<const FloatSegment>, bool isPrinting, bool doubleLines, StrokeStyle);
    void drawDotsForDocumentMarker(const FloatRect&, DocumentMarkerLineStyle);
    void drawGlyphs(const FontBase&, std::span<const GlyphBufferGlyph>, std::span<const GlyphBufferAdvance>, const FloatPoint&, FontSmoothingMode);
    void setMaxEDRHeadroom(std::optional<float>);
    void unsupported(ASCIILiteral);

private:
    GraphicsContextCGCapture() = default;

    void begin(GraphicsContextCGCaptureOp);
    void end();
    void stop(ASCIILiteral reason);
    void write(std::span<const uint8_t>);
    template<typename T> void writeValue(T);
    void writeRect(const FloatRect&);
    void writeTransform(const AffineTransform&);
    void writeCGTransform(const CGAffineTransform&);
    bool writeColor(const Color&);
    void writePath(const Path&);
    void writeRoundedRect(const FloatRoundedRect&);
    void writeShadow(const GraphicsDropShadow&);
    void writeGradient(const Gradient&);
    std::optional<uint32_t> imageIdentifier(CGImageRef);
    std::optional<uint32_t> fontIdentifier(const FontBase&);

    Vector<uint8_t> m_data;
    size_t m_recordStart { 0 };
    HashMap<uint64_t, uint32_t> m_imageIdentifiers;
    HashMap<String, uint32_t> m_fontIdentifiers;
    unsigned m_depth { 0 };
    unsigned m_draws { 0 };
    bool m_stopped { false };
};

#endif // ASSERT_ENABLED

} // namespace WebCore

#endif // USE(CG)
