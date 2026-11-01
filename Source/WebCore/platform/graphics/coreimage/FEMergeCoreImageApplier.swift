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

import CoreImage
import WebCore_Internal.FilterSwiftBridge

// FEMergeCoreImageApplier::apply(), which FEMerge runs input by input: feMergeAddCoreImageInput() composites each input
// that has a Core Image result over the result's (the inputs so far), then feMergeFinishCoreImage() crops it, or fails
// without inputs.
func feMergeAddCoreImageInput(_ input: borrowing FilterImageImpl, _ result: inout FilterImageImpl) {
    guard let layerImage = input.ciImage else {
        return
    }
    guard let accumulatedImage = result.ciImage else {
        result.setCIImage(layerImage)
        return
    }
    result.setCIImage(layerImage.composited(over: accumulatedImage))
}

func feMergeFinishCoreImage(_ context: borrowing WebCore.FilterApplyContext, _ hasInputs: Bool, _ result: inout FilterImageImpl) -> Bool {
    if !hasInputs {
        return false
    }
    result.setCIImage(result.ciImage?.cropped(to: context.coreImageRect(result.absoluteImageRect)))
    return true
}

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
