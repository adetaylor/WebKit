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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

import AVFoundation
import CoreMedia
public import Foundation

/// An example of WebCore's Swift reaching soft-linked frameworks through the accessors generated from SoftLinkAccessors.in.
///
/// It uses a CoreMedia function, an AVFoundation constant and an AVFoundation class, each of which loads its framework
/// at first use. TestWebKitAPI's SoftLinkAccessors.SwiftExample calls it.
@_cdecl("WebCoreSoftLinkAccessorsExample")
public func softLinkAccessorsExample() -> NSString {
    // The generated CMTimeMake(value:timescale:) shadows CoreMedia's.
    let time = CMTimeMake(value: 3, timescale: 2)
    let mediaType = AVFoundationSoftLink.AVMediaTypeVideo
    // AVURLAsset(url:) would name the class directly; init through the class that objc_lookUpClass returned instead.
    let asset = AVFoundationClass.AVURLAsset.init(url: URL(fileURLWithPath: "/example.mp4"), options: nil)
    return "\(time.value)/\(time.timescale) \(mediaType.rawValue) \(asset.url.lastPathComponent)" as NSString
}
