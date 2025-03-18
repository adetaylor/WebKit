// Copyright (C) 2025 Apple Inc. All rights reserved.
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

import WebKitSwift

@objc(Rot13)
@available(macOS 15.0, iOS 18.0, tvOS 18.0, *)
public final class Rot13: NSObject {
    @objc(rot13PlainText:rotation:completionHandler:)
    public func rot13plainText(plainText: String, rotation: Int, completionHandler: @escaping (Bool, String) -> Void) {
        var ciphertext = "";
        let smalla: Character = "a";
        let biga: Character = "A";
        let smallz: Character = "z";
        let bigz: Character = "Z";
        for c in plainText {
            if let ascii = c.asciiValue {
                if ascii >= smalla.asciiValue! && ascii <= smallz.asciiValue! {
                    let offset = (Int(ascii) - Int(smalla.asciiValue!) + rotation) % 26;
                    ciphertext.append(Character(UnicodeScalar(smalla.asciiValue! + UInt8(offset))));
                } else if ascii >= biga.asciiValue! && ascii <= bigz.asciiValue! {
                    let offset = (Int(ascii) - Int(biga.asciiValue!) + rotation) % 26;
                    ciphertext.append(Character(UnicodeScalar(biga.asciiValue! + UInt8(offset))));
                } else {
                    ciphertext.append(c);
                }
            } else {
                ciphertext.append(c);
            }
        }
        completionHandler(true, ciphertext);
    }
}
