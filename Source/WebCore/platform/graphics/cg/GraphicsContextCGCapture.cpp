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

#include "config.h"
#include "GraphicsContextCGCapture.h"

#if USE(CG) && ASSERT_ENABLED

#include "FloatRoundedRect.h"
#include "Gradient.h"
#include "NativeImage.h"
#include "Path.h"
#include <fcntl.h>
#include <pal/spi/cg/CoreGraphicsSPI.h>
#include <sys/stat.h>
#include <unistd.h>
#include <wtf/Lock.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/cf/VectorCF.h>
#include <wtf/text/CString.h>
#include <wtf/text/StringConcatenateNumbers.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(GraphicsContextCGCapture);

using Op = GraphicsContextCGCaptureOp;

static constexpr size_t maximumStreamSize = 32 * MB;
static constexpr size_t maximumFileSize = 512 * MB;
static constexpr size_t maximumImageSize = 8 * MB;

static Lock fileLock;
static size_t fileSize WTF_GUARDED_BY_LOCK(fileLock);

static bool isEnabled()
{
    static bool enabled = !!getenv("WEBKIT_CG_CAPTURE");
    return enabled;
}

static void appendToProcessFile(std::span<const uint8_t> data)
{
    Locker locker { fileLock };
    if (fileSize + data.size() > maximumFileSize)
        return;
    std::array<char, PATH_MAX> temporaryDirectory { };
    if (!confstr(_CS_DARWIN_USER_TEMP_DIR, temporaryDirectory.data(), temporaryDirectory.size()))
        return;
    auto directory = makeString(String::fromUTF8(temporaryDirectory.data()), "cgcapture"_s);
    auto directoryPath = directory.utf8();
    mkdir(safePrintfType(directoryPath), 0700);
    auto path = makeString(directory, '/', getpid(), ".gcop"_s).utf8();
    int fd = open(safePrintfType(path), O_WRONLY | O_APPEND | O_CREAT, 0600);
    if (fd < 0)
        return;
    size_t written = 0;
    while (written < data.size()) {
        auto result = ::write(fd, data.subspan(written).data(), data.size() - written);
        if (result <= 0)
            break;
        written += result;
    }
    close(fd);
    fileSize += written;
}

static void writeColorSpace(CGColorSpaceRef, Vector<uint8_t>&);

std::unique_ptr<GraphicsContextCGCapture> GraphicsContextCGCapture::createIfEnabled(CGContextRef context, RenderingMode renderingMode, bool isLayerContext)
{
    if (!isEnabled() || !context)
        return nullptr;
    auto type = CGContextGetType(context);
    if (type != kCGContextTypeBitmap && type != kCGContextTypeIOSurface)
        return nullptr;

    std::unique_ptr<GraphicsContextCGCapture> capture { new GraphicsContextCGCapture };
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t bitmapInfo = 0;
    uint32_t bitsPerComponent = 8;
    RetainPtr<CGColorSpaceRef> colorSpace;
    if (type == kCGContextTypeBitmap) {
        width = CGBitmapContextGetWidth(context);
        height = CGBitmapContextGetHeight(context);
        bitmapInfo = CGBitmapContextGetBitmapInfo(context);
        bitsPerComponent = CGBitmapContextGetBitsPerComponent(context);
        colorSpace = CGBitmapContextGetColorSpace(context);
    } else {
        auto deviceBounds = CGContextConvertRectToDeviceSpace(context, CGContextGetClipBoundingBox(context));
        width = std::round(deviceBounds.size.width);
        height = std::round(deviceBounds.size.height);
        bitmapInfo = CGIOSurfaceContextGetBitmapInfo(context);
        if (bitmapInfo & kCGBitmapFloatComponents)
            bitsPerComponent = 16;
        colorSpace = CGIOSurfaceContextGetColorSpace(context);
    }
    if (!width || !height || width > 8192 || height > 8192)
        return nullptr;

    capture->begin(Op::StreamHeader);
    capture->writeValue(graphicsContextCGCaptureVersion);
    capture->writeValue(width);
    capture->writeValue(height);
    capture->writeValue(static_cast<uint32_t>(type));
    capture->writeValue(bitmapInfo);
    capture->writeValue(bitsPerComponent);
    capture->writeValue(static_cast<uint8_t>(renderingMode));
    capture->writeValue(static_cast<uint8_t>(isLayerContext));
    capture->writeCGTransform(CGContextGetCTM(context));
    capture->writeCGTransform(CGContextGetBaseCTM(context));
    writeColorSpace(colorSpace.get(), capture->m_data);
    capture->end();
    return capture;
}

GraphicsContextCGCapture::~GraphicsContextCGCapture()
{
    if (!m_draws)
        return;
    begin(Op::StreamEnd);
    end();
    appendToProcessFile(m_data.span());
}

void GraphicsContextCGCapture::begin(Op op)
{
    m_recordStart = m_data.size();
    writeValue(static_cast<uint16_t>(op));
    writeValue(static_cast<uint16_t>(0));
    writeValue(static_cast<uint32_t>(0));
}

void GraphicsContextCGCapture::end()
{
    uint32_t length = m_data.size() - m_recordStart - 8;
    memcpySpan(m_data.mutableSpan().subspan(m_recordStart + 4, sizeof(length)), asByteSpan(length));
    if (m_data.size() > maximumStreamSize)
        stop("stream size"_s);
}

void GraphicsContextCGCapture::stop(ASCIILiteral reason)
{
    if (m_stopped)
        return;
    m_data.shrink(m_recordStart);
    begin(Op::Unsupported);
    auto characters = reason.span();
    writeValue(static_cast<uint32_t>(characters.size()));
    write(byteCast<uint8_t>(characters));
    m_stopped = true;
    uint32_t length = m_data.size() - m_recordStart - 8;
    memcpySpan(m_data.mutableSpan().subspan(m_recordStart + 4, sizeof(length)), asByteSpan(length));
}

void GraphicsContextCGCapture::unsupported(ASCIILiteral name)
{
    m_recordStart = m_data.size();
    stop(name);
}

void GraphicsContextCGCapture::write(std::span<const uint8_t> bytes)
{
    m_data.append(bytes);
}

template<typename T> void GraphicsContextCGCapture::writeValue(T value)
{
    write(asByteSpan(value));
}

void GraphicsContextCGCapture::writeRect(const FloatRect& rect)
{
    writeValue(rect.x());
    writeValue(rect.y());
    writeValue(rect.width());
    writeValue(rect.height());
}

void GraphicsContextCGCapture::writeTransform(const AffineTransform& transform)
{
    for (double value : { transform.a(), transform.b(), transform.c(), transform.d(), transform.e(), transform.f() })
        writeValue(value);
}

void GraphicsContextCGCapture::writeCGTransform(const CGAffineTransform& transform)
{
    for (double value : { transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty })
        writeValue(value);
}

bool GraphicsContextCGCapture::writeColor(const Color& color)
{
    if (auto packed = color.tryGetAsPackedInline()) {
        writeValue(static_cast<uint8_t>(0));
        writeValue(packed->value);
        return true;
    }
    if (!color.isValid()) {
        writeValue(static_cast<uint8_t>(2));
        return true;
    }
    auto [colorSpace, components] = color.colorSpaceAndResolvedColorComponents();
    writeValue(static_cast<uint8_t>(1));
    writeValue(static_cast<uint8_t>(colorSpace));
    for (float component : components.components)
        writeValue(component);
    return true;
}

void GraphicsContextCGCapture::writePath(const Path& path)
{
    if (auto line = path.singleDataLine()) {
        writeValue(static_cast<uint8_t>(1));
        writeValue(line->start().x());
        writeValue(line->start().y());
        writeValue(line->end().x());
        writeValue(line->end().y());
        return;
    }
    writeValue(static_cast<uint8_t>(0));
    Vector<uint8_t> elements;
    uint32_t count = 0;
    path.applyElements([&](const PathElement& element) {
        ++count;
        elements.append(static_cast<uint8_t>(element.type));
        unsigned points = 0;
        switch (element.type) {
        case PathElement::Type::MoveToPoint:
        case PathElement::Type::AddLineToPoint:
            points = 1;
            break;
        case PathElement::Type::AddQuadCurveToPoint:
            points = 2;
            break;
        case PathElement::Type::AddCurveToPoint:
            points = 3;
            break;
        case PathElement::Type::CloseSubpath:
            break;
        }
        for (unsigned i = 0; i < points; ++i) {
            elements.append(asByteSpan(element.points[i].x()));
            elements.append(asByteSpan(element.points[i].y()));
        }
    });
    writeValue(count);
    write(elements.span());
}

void GraphicsContextCGCapture::writeGradient(const Gradient& gradient)
{
    WTF::switchOn(gradient.data(),
        [&](const Gradient::LinearData& data) {
            writeValue(static_cast<uint8_t>(0));
            writeValue(data.point0.x());
            writeValue(data.point0.y());
            writeValue(data.point1.x());
            writeValue(data.point1.y());
        },
        [&](const Gradient::RadialData& data) {
            writeValue(static_cast<uint8_t>(1));
            writeValue(data.point0.x());
            writeValue(data.point0.y());
            writeValue(data.point1.x());
            writeValue(data.point1.y());
            writeValue(data.startRadius);
            writeValue(data.endRadius);
            writeValue(data.aspectRatio);
        },
        [&](const Gradient::ConicData& data) {
            writeValue(static_cast<uint8_t>(2));
            writeValue(data.point0.x());
            writeValue(data.point0.y());
            writeValue(data.angleRadians);
        });
    writeValue(static_cast<uint8_t>(gradient.spreadMethod()));
    auto method = gradient.colorInterpolationMethod();
    writeValue(static_cast<uint8_t>(method.colorSpace.index()));
    writeValue(WTF::switchOn(method.colorSpace, [](const auto& colorSpace) -> uint8_t {
        if constexpr (requires { colorSpace.hueInterpolationMethod; })
            return static_cast<uint8_t>(colorSpace.hueInterpolationMethod);
        else
            return 0;
    }));
    writeValue(static_cast<uint8_t>(method.alphaPremultiplication));
    auto& stops = gradient.stops();
    writeValue(static_cast<uint32_t>(stops.size()));
    for (auto& stop : stops) {
        writeValue(stop.offset);
        writeColor(stop.color);
    }
}

void GraphicsContextCGCapture::fillRect(const FloatRect& rect, const Gradient& gradient, const AffineTransform& gradientSpaceTransform, GraphicsContext::RequiresClipToRect requiresClipToRect)
{
    ++m_draws;
    begin(Op::FillRectWithGradient);
    writeRect(rect);
    writeGradient(gradient);
    writeTransform(gradientSpaceTransform);
    writeValue(static_cast<uint8_t>(requiresClipToRect));
    end();
}

void GraphicsContextCGCapture::writeShadow(const GraphicsDropShadow& shadow)
{
    writeValue(shadow.offset.width());
    writeValue(shadow.offset.height());
    writeValue(shadow.radius);
    writeColor(shadow.color);
    writeValue(static_cast<uint8_t>(shadow.radiusMode));
    writeValue(shadow.opacity);
}

void GraphicsContextCGCapture::writeRoundedRect(const FloatRoundedRect& rect)
{
    writeRect(rect.rect());
    for (auto& radius : { rect.radii().topLeft(), rect.radii().topRight(), rect.radii().bottomLeft(), rect.radii().bottomRight() }) {
        writeValue(radius.width());
        writeValue(radius.height());
    }
}

static void writeColorSpace(CGColorSpaceRef colorSpace, Vector<uint8_t>& data)
{
    auto append32 = [&](uint32_t value) {
        data.append(asByteSpan(value));
    };
    RetainPtr<CFStringRef> name = colorSpace ? adoptCF(CGColorSpaceCopyName(colorSpace)) : nullptr;
    if (name) {
        auto utf8 = String(name.get()).utf8();
        data.append(static_cast<uint8_t>(0));
        append32(utf8.length());
        data.append(byteCast<uint8_t>(utf8.span()));
        return;
    }
    RetainPtr<CFDataRef> icc = colorSpace ? adoptCF(CGColorSpaceCopyICCData(colorSpace)) : nullptr;
    if (icc) {
        data.append(static_cast<uint8_t>(1));
        auto bytes = span(icc.get());
        append32(bytes.size());
        data.append(bytes);
        return;
    }
    data.append(static_cast<uint8_t>(2));
}

std::optional<uint32_t> GraphicsContextCGCapture::imageIdentifier(CGImageRef image)
{
    RetainPtr<CFDataRef> data = adoptCF(CGDataProviderCopyData(CGImageGetDataProvider(image)));
    if (!data)
        return std::nullopt;
    auto bytes = span(data.get());
    if (bytes.size() > maximumImageSize)
        return std::nullopt;
    uint64_t hash = 14695981039346656037ull;
    auto mix = [&](uint64_t value) {
        hash = (hash ^ value) * 1099511628211ull;
    };
    mix(CGImageGetWidth(image));
    mix(CGImageGetHeight(image));
    mix(CGImageGetBytesPerRow(image));
    mix(CGImageGetBitmapInfo(image));
    for (auto byte : bytes)
        mix(byte);
    auto result = m_imageIdentifiers.add(hash, m_imageIdentifiers.size() + 1);
    uint32_t identifier = result.iterator->value;
    if (!result.isNewEntry)
        return identifier;

    begin(Op::DefineImage);
    writeValue(identifier);
    writeValue(static_cast<uint32_t>(CGImageGetWidth(image)));
    writeValue(static_cast<uint32_t>(CGImageGetHeight(image)));
    writeValue(static_cast<uint32_t>(CGImageGetBitsPerComponent(image)));
    writeValue(static_cast<uint32_t>(CGImageGetBitsPerPixel(image)));
    writeValue(static_cast<uint32_t>(CGImageGetBytesPerRow(image)));
    writeValue(static_cast<uint32_t>(CGImageGetBitmapInfo(image)));
    writeValue(static_cast<uint8_t>(CGImageGetShouldInterpolate(image)));
    writeValue(static_cast<uint32_t>(CGImageGetRenderingIntent(image)));
    writeColorSpace(CGImageGetColorSpace(image), m_data);
    writeValue(static_cast<uint32_t>(bytes.size()));
    write(bytes);
    end();
    return identifier;
}

void GraphicsContextCGCapture::stateUpdate(const GraphicsContextState& state)
{
    using Change = GraphicsContextState::Change;
    auto changes = state.changes();
    if (!changes)
        return;
    begin(Op::StateUpdate);
    writeValue(changes.toRaw());
    for (auto change : changes) {
        switch (change) {
        case Change::FillBrush:
        case Change::StrokeBrush: {
            auto& brush = change == Change::FillBrush ? state.fillBrush() : state.strokeBrush();
            if (brush.pattern()) {
                stop("pattern brush"_s);
                return;
            }
            if (RefPtr gradient = brush.gradient()) {
                writeValue(static_cast<uint8_t>(1));
                writeGradient(*gradient);
                writeTransform(brush.gradientSpaceTransform());
            } else
                writeValue(static_cast<uint8_t>(0));
            writeColor(brush.color());
            break;
        }
        case Change::FillRule:
            writeValue(static_cast<uint8_t>(state.fillRule()));
            break;
        case Change::StrokeThickness:
            writeValue(state.strokeThickness());
            break;
        case Change::StrokeStyle:
            writeValue(static_cast<uint8_t>(state.strokeStyle()));
            break;
        case Change::CompositeMode:
            writeValue(static_cast<uint8_t>(state.compositeMode().operation));
            writeValue(static_cast<uint8_t>(state.compositeMode().blendMode));
            break;
        case Change::DropShadow: {
            auto& shadow = state.dropShadow();
            writeValue(static_cast<uint8_t>(!!shadow));
            if (shadow)
                writeShadow(*shadow);
            break;
        }
        case Change::Style:
            if (!state.style()) {
                writeValue(static_cast<uint8_t>(0));
                break;
            }
            WTF::switchOn(*state.style(),
                [&](const GraphicsDropShadow& shadow) {
                    writeValue(static_cast<uint8_t>(1));
                    writeShadow(shadow);
                },
                [&](const GraphicsGaussianBlur& blur) {
                    writeValue(static_cast<uint8_t>(2));
                    writeValue(blur.radius.width());
                    writeValue(blur.radius.height());
                },
                [&](const GraphicsColorMatrix& colorMatrix) {
                    writeValue(static_cast<uint8_t>(3));
                    for (float value : colorMatrix.values)
                        writeValue(value);
                });
            break;
        case Change::Alpha:
            writeValue(state.alpha());
            break;
        case Change::TextDrawingMode:
            writeValue(state.textDrawingMode().toRaw());
            break;
        case Change::ImageInterpolationQuality:
            writeValue(static_cast<uint8_t>(state.imageInterpolationQuality()));
            break;
        case Change::ShouldAntialias:
            writeValue(static_cast<uint8_t>(state.shouldAntialias()));
            break;
        case Change::ShouldSmoothFonts:
            writeValue(static_cast<uint8_t>(state.shouldSmoothFonts()));
            break;
        case Change::ShouldSubpixelQuantizeFonts:
            writeValue(static_cast<uint8_t>(state.shouldSubpixelQuantizeFonts()));
            break;
        case Change::ShadowsIgnoreTransforms:
            writeValue(static_cast<uint8_t>(state.shadowsIgnoreTransforms()));
            break;
        }
    }
    end();
}

#define SIMPLE_OP(name, op) \
    void GraphicsContextCGCapture::name() \
    { \
        begin(op); \
        end(); \
    }

SIMPLE_OP(endTransparencyLayer, Op::EndTransparencyLayer)
SIMPLE_OP(resetClip, Op::ResetClip)

void GraphicsContextCGCapture::save(GraphicsContextState::Purpose purpose)
{
    begin(Op::Save);
    writeValue(static_cast<uint8_t>(purpose));
    end();
}

void GraphicsContextCGCapture::restore(GraphicsContextState::Purpose purpose)
{
    begin(Op::Restore);
    writeValue(static_cast<uint8_t>(purpose));
    end();
}

void GraphicsContextCGCapture::beginTransparencyLayer(float opacity)
{
    begin(Op::BeginTransparencyLayer);
    writeValue(opacity);
    end();
}

void GraphicsContextCGCapture::beginTransparencyLayer(CompositeOperator compositeOperator, BlendMode blendMode)
{
    begin(Op::BeginTransparencyLayerWithCompositeMode);
    writeValue(static_cast<uint8_t>(compositeOperator));
    writeValue(static_cast<uint8_t>(blendMode));
    end();
}

void GraphicsContextCGCapture::translate(float x, float y)
{
    begin(Op::Translate);
    writeValue(x);
    writeValue(y);
    end();
}

void GraphicsContextCGCapture::scale(const FloatSize& size)
{
    begin(Op::Scale);
    writeValue(size.width());
    writeValue(size.height());
    end();
}

void GraphicsContextCGCapture::rotate(float angle)
{
    begin(Op::Rotate);
    writeValue(angle);
    end();
}

void GraphicsContextCGCapture::concatCTM(const AffineTransform& transform)
{
    begin(Op::ConcatCTM);
    writeTransform(transform);
    end();
}

void GraphicsContextCGCapture::setCTM(const AffineTransform& transform)
{
    begin(Op::SetCTM);
    writeTransform(transform);
    end();
}

void GraphicsContextCGCapture::applyDeviceScaleFactor(float factor)
{
    begin(Op::ApplyDeviceScaleFactor);
    writeValue(factor);
    end();
}

void GraphicsContextCGCapture::clip(const FloatRect& rect)
{
    begin(Op::Clip);
    writeRect(rect);
    end();
}

void GraphicsContextCGCapture::clipOut(const FloatRect& rect)
{
    begin(Op::ClipOut);
    writeRect(rect);
    end();
}

void GraphicsContextCGCapture::clipPath(const Path& path, WindRule rule)
{
    begin(Op::ClipPath);
    writeValue(static_cast<uint8_t>(rule));
    writePath(path);
    end();
}

void GraphicsContextCGCapture::clipOut(const Path& path)
{
    begin(Op::ClipOutPath);
    writePath(path);
    end();
}

void GraphicsContextCGCapture::clearRect(const FloatRect& rect)
{
    ++m_draws;
    begin(Op::ClearRect);
    writeRect(rect);
    end();
}

void GraphicsContextCGCapture::fillRect(const FloatRect& rect, GraphicsContext::RequiresClipToRect requiresClipToRect)
{
    ++m_draws;
    begin(Op::FillRect);
    writeRect(rect);
    writeValue(static_cast<uint8_t>(requiresClipToRect));
    end();
}

void GraphicsContextCGCapture::fillRect(const FloatRect& rect, const Color& color)
{
    ++m_draws;
    begin(Op::FillRectWithColor);
    writeRect(rect);
    writeColor(color);
    end();
}

void GraphicsContextCGCapture::strokeRect(const FloatRect& rect, float lineWidth)
{
    ++m_draws;
    begin(Op::StrokeRect);
    writeRect(rect);
    writeValue(lineWidth);
    end();
}

void GraphicsContextCGCapture::fillRoundedRect(const FloatRoundedRect& rect, const Color& color)
{
    ++m_draws;
    begin(Op::FillRoundedRect);
    writeRoundedRect(rect);
    writeColor(color);
    end();
}

void GraphicsContextCGCapture::fillRectWithRoundedHole(const FloatRect& rect, const FloatRoundedRect& hole, const Color& color)
{
    ++m_draws;
    begin(Op::FillRectWithRoundedHole);
    writeRect(rect);
    writeRoundedRect(hole);
    writeColor(color);
    end();
}

void GraphicsContextCGCapture::fillEllipse(const FloatRect& rect)
{
    ++m_draws;
    begin(Op::FillEllipse);
    writeRect(rect);
    end();
}

void GraphicsContextCGCapture::strokeEllipse(const FloatRect& rect)
{
    ++m_draws;
    begin(Op::StrokeEllipse);
    writeRect(rect);
    end();
}

void GraphicsContextCGCapture::drawRect(const FloatRect& rect, float borderThickness)
{
    ++m_draws;
    begin(Op::DrawRect);
    writeRect(rect);
    writeValue(borderThickness);
    end();
}

void GraphicsContextCGCapture::drawLine(const FloatPoint& point1, const FloatPoint& point2)
{
    ++m_draws;
    begin(Op::DrawLine);
    writeValue(point1.x());
    writeValue(point1.y());
    writeValue(point2.x());
    writeValue(point2.y());
    end();
}

void GraphicsContextCGCapture::fillPath(const Path& path)
{
    ++m_draws;
    begin(Op::FillPath);
    writePath(path);
    end();
}

void GraphicsContextCGCapture::strokePath(const Path& path)
{
    ++m_draws;
    begin(Op::StrokePath);
    writePath(path);
    end();
}

void GraphicsContextCGCapture::drawPath(const Path& path)
{
    ++m_draws;
    begin(Op::DrawPath);
    writePath(path);
    end();
}

void GraphicsContextCGCapture::strokeArc(const PathArc& arc)
{
    ++m_draws;
    begin(Op::StrokeArc);
    writeValue(arc.center.x());
    writeValue(arc.center.y());
    writeValue(arc.radius);
    writeValue(arc.startAngle);
    writeValue(arc.endAngle);
    writeValue(static_cast<uint8_t>(arc.direction));
    end();
}

void GraphicsContextCGCapture::strokeLine(const PathDataLine& line)
{
    ++m_draws;
    begin(Op::StrokeLine);
    writeValue(line.start().x());
    writeValue(line.start().y());
    writeValue(line.end().x());
    writeValue(line.end().y());
    end();
}

void GraphicsContextCGCapture::setLineCap(LineCap cap)
{
    begin(Op::SetLineCap);
    writeValue(static_cast<uint8_t>(cap));
    end();
}

void GraphicsContextCGCapture::setLineJoin(LineJoin join)
{
    begin(Op::SetLineJoin);
    writeValue(static_cast<uint8_t>(join));
    end();
}

void GraphicsContextCGCapture::setMiterLimit(float limit)
{
    begin(Op::SetMiterLimit);
    writeValue(limit);
    end();
}

void GraphicsContextCGCapture::setLineDash(const DashArray& dashes, float dashOffset)
{
    begin(Op::SetLineDash);
    writeValue(dashOffset);
    writeValue(static_cast<uint32_t>(dashes.size()));
    for (auto dash : dashes)
        writeValue(static_cast<double>(dash));
    end();
}

void GraphicsContextCGCapture::drawNativeImage(const NativeImage& nativeImage, const FloatRect& destination, const FloatRect& source, ImageDrawingOptions options)
{
    RetainPtr image = nativeImage.platformImage();
    if (!image)
        return;
    auto identifier = imageIdentifier(image.get());
    if (!identifier) {
        stop("image"_s);
        return;
    }
    ++m_draws;
    begin(Op::DrawNativeImage);
    writeValue(*identifier);
    writeRect(destination);
    writeRect(source);
    writeValue(static_cast<uint8_t>(options.compositeOperator()));
    writeValue(static_cast<uint8_t>(options.blendMode()));
    writeValue(static_cast<uint8_t>(options.orientation().orientation()));
    writeValue(static_cast<uint8_t>(options.interpolationQuality()));
    writeValue(static_cast<float>(options.headroom()));
    writeValue(options.dynamicRangeLimit().value());
    writeValue(static_cast<uint8_t>(options.drawsHDRContent()));
    end();
}

void GraphicsContextCGCapture::drawPattern(const NativeImage& nativeImage, const FloatRect& destination, const FloatRect& tile, const AffineTransform& patternTransform, const FloatPoint& phase, const FloatSize& spacing, ImageDrawingOptions options)
{
    RetainPtr image = nativeImage.platformImage();
    if (!image)
        return;
    auto identifier = imageIdentifier(image.get());
    if (!identifier) {
        stop("image"_s);
        return;
    }
    ++m_draws;
    begin(Op::DrawPattern);
    writeValue(*identifier);
    writeRect(destination);
    writeRect(tile);
    writeTransform(patternTransform);
    writeValue(phase.x());
    writeValue(phase.y());
    writeValue(spacing.width());
    writeValue(spacing.height());
    writeValue(static_cast<uint8_t>(options.compositeOperator()));
    writeValue(static_cast<uint8_t>(options.blendMode()));
    writeValue(static_cast<uint8_t>(options.interpolationQuality()));
    end();
}

void GraphicsContextCGCapture::drawLinesForText(const FloatPoint& origin, float thickness, std::span<const FloatSegment> segments, bool isPrinting, bool doubleLines, StrokeStyle strokeStyle)
{
    ++m_draws;
    begin(Op::DrawLinesForText);
    writeValue(origin.x());
    writeValue(origin.y());
    writeValue(thickness);
    writeValue(static_cast<uint32_t>(segments.size()));
    for (auto& segment : segments) {
        writeValue(segment.begin);
        writeValue(segment.end);
    }
    writeValue(static_cast<uint8_t>(isPrinting));
    writeValue(static_cast<uint8_t>(doubleLines));
    writeValue(static_cast<uint8_t>(strokeStyle));
    end();
}

void GraphicsContextCGCapture::drawDotsForDocumentMarker(const FloatRect& rect, DocumentMarkerLineStyle style)
{
    ++m_draws;
    begin(Op::DrawDotsForDocumentMarker);
    writeRect(rect);
    writeValue(static_cast<uint8_t>(style.mode));
    writeColor(style.color);
    end();
}

} // namespace WebCore

#endif // USE(CG) && ASSERT_ENABLED
