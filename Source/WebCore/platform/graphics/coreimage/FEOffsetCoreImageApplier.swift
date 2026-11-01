// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT
#if USE_CORE_IMAGE

import CoreGraphics
import CoreImage
import WebCore_Internal.FEOffsetParameters
import WebCore_Internal.FilterSwiftBridge
import WebCore_Internal.FloatSize

// FEOffsetCoreImageApplier::apply(): the input moved by the offset, cropped to the result.
func feOffsetApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEOffsetParameters,
    _ input: borrowing FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let inputImage = input.ciImage else {
        return false
    }

    let offset = context.resolvedSize(WebCore.FloatSize(parameters.dx, parameters.dy))
    let absoluteOffset = context.scaledByFilterScale(offset)

    let translation = CGAffineTransform(translationX: CGFloat(absoluteOffset.width()), y: CGFloat(-absoluteOffset.height()))
    let image = inputImage.transformed(by: translation)

    result.setCIImage(image.cropped(to: context.coreImageRect(result.absoluteImageRect)))
    return true
}

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
