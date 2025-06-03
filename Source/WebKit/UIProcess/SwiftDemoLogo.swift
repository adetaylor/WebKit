/*
 * Copyright (C) 2014-2025 Apple Inc. All rights reserved.
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

import Foundation
internal import WebKit_Internal
import struct Swift.String

extension Data {
    var bytes: [UInt8] {
        return [UInt8](self)
    }
}

// This function is contrived to exercise bi-directional C++ -> Swift -> C++
// calls within the main WebKit target. It can be tested by enabling
// ENABLE_SWIFT_DEMO_DATA_URL_ENCODING, and then visiting
// x-swift-demo:// in the browser. The goal is to provide an easy
// but comprehensive test case to determine whether Swift-C++ interop
// is working in a given toolchain.
@available(WK_IOS_TBA, WK_MAC_TBA, WK_XROS_TBA, *)
@_expose(Cxx)
public func getSwiftLogoData() -> [UInt8] {
    let swiftLogoBase64 = String(WebKit_Internal.getSwiftDemoLogoEncodedData());
    guard let data = Data(base64Encoded: swiftLogoBase64) else {
        return [];
    }
    return data.bytes;
}
