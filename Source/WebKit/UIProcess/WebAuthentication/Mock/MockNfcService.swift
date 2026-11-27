// Copyright (C) 2019 Apple Inc. All rights reserved.
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

#if ENABLE_WEB_AUTHN

import Foundation
internal import WebCore
import WebCore_Private
import WebKit_Internal
import wtf

#if HAVE_NEAR_FIELD

@objc
@implementation
extension WKMockNFTag {
    let type: NFTagType
    let tagID: Data?
    let technology: NFTechnology = []
    @objc(UID)
    let uid: Data? = nil
    let ndefAvailability: NFNdefAvailability = .unknown
    let ndefMessageSize = 0
    let ndefContainerSize = 0
    @objc(AppData)
    let appData: Data? = nil
    let tagA: (any NFTagA)? = nil
    let tagB: (any NFTagB)? = nil
    let tagF: (any NFTagF)? = nil

    /// A tag with the type and the identifier of `tag`.
    @objc(initWithNFTag:)
    public required init(nfTag tag: any NFTagProtocol) {
        type = tag.type
        tagID = tag.tagID
        super.init()
    }

    convenience init(type: NFTagType) {
        self.init(type: type, tagID: Data([0x01]))
    }

    init(type: NFTagType, tagID: Data) {
        self.type = type
        self.tagID = tagID
        super.init()
    }

    func description() -> String? {
        nil
    }

    @objc(isEqualToNFTag:)
    func isEqual(to tag: (any NFTagProtocol)?) -> Bool {
        false
    }
}

/// The tags the reader session detects, off the main thread.
@_expose(Cxx)
func webAuthnMockNfcTags(wrongTagType: Bool, multipleTags: Bool, multiplePhysicalTags: Bool) -> NSArray {
    var tags = [WKMockNFTag(type: wrongTagType || multipleTags ? .unknown : .generic4A)]
    if multipleTags {
        tags.append(WKMockNFTag(type: .generic4A))
    }
    if multiplePhysicalTags {
        tags.append(WKMockNFTag(type: .generic4A, tagID: Data([0x02])))
    }
    return tags as NSArray
}

/// The service's next scripted response to a reader session's `transceive(_:)`.
@_expose(Cxx)
func webAuthnMockNfcTransceive(_ service: WebKit.MockNfcService) -> NSData? {
    service.transceive()
}

extension WebKit.MockNfcService {
    fileprivate func transceive() -> NSData? {
        guard var nfc = m_configuration.nfc.value else {
            preconditionFailure("An NFC service without an NFC configuration")
        }
        if nfc.payloadBase64.isEmpty() {
            return nil
        }

        let result = NSData(base64Encoded: makeSwiftString(nfc.payloadBase64[0]), options: .ignoreUnknownCharacters)
        nfc.payloadBase64.removeAt(0)
        m_configuration.nfc = .init(nfc)
        return result
    }
}

#endif // HAVE_NEAR_FIELD

extension WebKit.MockNfcService {
    @cxx
    @implementation
    func receiveStopPolling() {
        guard var nfc = m_configuration.nfc.value else {
            preconditionFailure("An NFC service without an NFC configuration")
        }
        // For purpose of restart polling.
        nfc.multiplePhysicalTags = false
        m_configuration.nfc = .init(nfc)
    }
}

#endif // ENABLE_WEB_AUTHN
