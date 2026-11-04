// Copyright (C) 2000-2001 Dawit Alemayehu <adawit@kde.org>
// Copyright (C) 2006 Alexey Proskuryakov <ap@webkit.org>
// Copyright (C) 2007-2024 Apple Inc. All rights reserved.
// Copyright (C) 2010 Patrick Gansterer <paroga@paroga.com>
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License (LGPL)
// version 2 as published by the Free Software Foundation.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU Library General Public
// License along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
//
// This code is based on the java implementation in HTTPClient
// package by Ronald Tschalär Copyright (C) 1996-1999.

// Copyright (C) 2006 Alexey Proskuryakov <ap@webkit.org>
// Copyright (C) 2010 Patrick Gansterer <paroga@paroga.com>
// Copyright (C) 2013-2024 Apple Inc. All rights reserved.
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

// Copyright (C) 2007-2026 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT

// Swift builds the safe Span overloads of the views' span() with the Cxx module, which Xcode builds only find if this file
// imports it.
private import Cxx
import WebCore_Private.Core.MediaParsersCxxBridging
import WebCoreEME
import wtf

// Appends the decoded bytes to output, and leaves it unchanged if the input isn't valid. options are
// OptionSet<WTF::Base64DecodeOption>::toRaw().
@_expose(Cxx)
func base64DecodeLatin1Impl(
    _ input: borrowing WebCore.MediaParserLatin1,
    _ options: UInt32,
    _ output: inout WebCore.MediaParserByteVector
) -> Bool {
    let characters: Span<UInt8> = input.span()
    return appendDecoded(WTFBase64.decode(characters, options: WTFBase64.DecodeOptions(rawValue: options)), to: &output)
}

@_expose(Cxx)
func base64DecodeUTF16Impl(
    _ input: borrowing WebCore.MediaParserUTF16,
    _ options: UInt32,
    _ output: inout WebCore.MediaParserByteVector
) -> Bool {
    let characters: Span<UInt16> = input.span()
    return appendDecoded(WTFBase64.decode(characters, options: WTFBase64.DecodeOptions(rawValue: options)), to: &output)
}

// options are OptionSet<WTF::Base64EncodeOption>::toRaw(). Never returns a null String.
@_expose(Cxx)
func base64EncodeToStringImpl(_ input: borrowing WebCore.MediaParserBytes, _ options: UInt32) -> WTF.String {
    let bytes: Span<UInt8> = input.span()
    let encoded = WTFBase64.encode(bytes, options: WTFBase64.EncodeOptions(rawValue: options))
    return WebCore.makeStringFromLatin1(encoded.span)
}

private func appendDecoded(_ decoded: ContiguousArray<UInt8>?, to output: inout WebCore.MediaParserByteVector) -> Bool {
    guard let decoded else {
        return false
    }
    if !decoded.isEmpty {
        WebCore.appendBytes(&output, decoded.span)
    }
    return true
}

#endif // ENABLE_WEBCORE_SWIFT
