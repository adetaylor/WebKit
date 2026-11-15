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
#include <wtf/RefPtr.h>
#include <wtf/SwiftBridging.h>

#if USE(CORE_IMAGE)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurfaceRef.h>
#endif

namespace WebCore {

class NativeImage;

// The optional native image of FEImage's source that FilterEffectView returns (FilterDescriptions.swift).
using RefPtrNativeImage = RefPtr<NativeImage>;

// FEImage's parameters, which FEImage stores (its getters are the IPC model) and passes to its Swift functions. Its
// source image reaches Swift as the NativeImage or ImageBuffer it is (FilterImageSource).
struct FEImageParameters {
    FloatRect sourceImageRect;

    bool operator==(const FEImageParameters&) const = default;
};

// What WebCore's Swift can't do with FEImage's source image itself (FEImageBridge.cpp): draw all of a NativeImage into
// `destinationRect` of `destination`, and with Core Image, read a NativeImage's size and CGImage and an ImageBuffer's
// IOSurface (null if it has none).
void feImageDrawNativeImage(NativeImage&, ImageBuffer& destination, const IntRect& destinationRect);
#if USE(CORE_IMAGE)
IntSize feImageNativeImageSize(NativeImage&);
CF_RETURNS_RETAINED CGImageRef feImageCopyNativeImagePlatformImage(NativeImage&);
CF_RETURNS_NOT_RETAINED IOSurfaceRef feImageImageBufferSurface(ImageBuffer&);
#endif

} // namespace WebCore
