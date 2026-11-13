/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2010 Dirk Schulze <krit@webkit.org>
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#pragma once

#include <WebCore/FloatRect.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/IntRect.h>
#include <WebCore/IntSize.h>
#include <wtf/Platform.h>
#include <wtf/SwiftBridging.h>

#if USE(CORE_IMAGE)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurfaceRef.h>
#endif

namespace WebCore {

class SourceImage;

// FEImage's parameters, which FEImage stores (its getters are the IPC model) and passes to its Swift functions. Its
// source image, which Swift doesn't import, stays in FEImage and reaches Swift as an FEImageSource.
struct FEImageParameters {
    FloatRect sourceImageRect;

    bool operator==(const FEImageParameters&) const = default;
};

enum class FEImageSourceKind : uint8_t {
    NativeImage,
    ImageBuffer,
    // An image the GPU process hasn't resolved: only its identifier.
    None
};

// FEImage's source image, lent to Swift for one call: its kind, and its image through the members (FEImageBridge.cpp).
// Swift can't read the source image or keep it. NativeImage stays C++.
class SWIFT_VIEW SWIFT_SAFE FEImageSource {
public:
#if !defined(__swift__)
    explicit FEImageSource(const SourceImage&);
#endif

    // Draws all of the source NativeImage, if the source is one, into `destinationRect` of `destination`.
    void drawNativeImage(ImageBuffer& destination, const IntRect& destinationRect) const;

    // The source ImageBuffer, or null if the source isn't one.
    RefPtr<ImageBuffer> imageBuffer() const;

#if USE(CORE_IMAGE)
    // The source NativeImage's size and CGImage, or empty and null if the source isn't a NativeImage.
    IntSize nativeImageSize() const;
    CF_RETURNS_RETAINED CGImageRef copyNativeImagePlatformImage() const;

    // The IOSurface of the source ImageBuffer, or null if the source isn't an ImageBuffer or the image buffer has none.
    CF_RETURNS_NOT_RETAINED IOSurfaceRef imageBufferSurface() const;
#endif

    FEImageSourceKind kind;

private:
    const SourceImage& m_sourceImage;
};

} // namespace WebCore
