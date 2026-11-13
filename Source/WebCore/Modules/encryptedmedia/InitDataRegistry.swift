// Copyright (C) 2017-2026 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT && ENABLE_ENCRYPTED_MEDIA

// The safe Span overloads Swift synthesizes for the views' span() call a Span initializer from Cxx, which Xcode
// builds don't find unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.EMEParseResults
import WebCore_Private.Core.ISOParseResults
import WebCore_Private.Core.MediaParsersCxxBridging

// The names this file compares with, packed for MediaParserName comparisons.
private enum InitDataNames {
    static let keyids = MediaParserName("keyids")
    static let cenc = MediaParserName("cenc")
    static let webm = MediaParserName("webm")
    static let sinf = MediaParserName("sinf")
    static let skd = MediaParserName("skd")
    static let mpts = MediaParserName("mpts")
}

// The init data parsing of InitDataRegistry: the type names, 'cenc' and 'webm'. InitDataRegistry.cpp keeps the JSON of
// 'keyids' and hands 'sinf', 'skd' and 'mpts' to the FairPlay Streaming CDM.
enum InitDataParsing {
    // https://w3c.github.io/encrypted-media/format-registry/initdata/cenc.html#common-system
    static let maximumCencSize = 64 * 1024
    // The size of a WebM ContentEncKeyID is a 16-bit field.
    // https://matroska.org/technical/specs/index.html#ContentEncKeyID/
    static let maximumWebMKeyIDSize: UInt = 64 * 1024

    // Init data type names are compared case-sensitively.
    static func kind(_ name: WebCore.MediaParserShortName) -> WebCore.InitDataKind {
        if InitDataNames.keyids.matches(name) {
            return .KeyIDs
        }
        if InitDataNames.cenc.matches(name) {
            return .Cenc
        }
        if InitDataNames.webm.matches(name) {
            return .WebM
        }
        #if USE_AVFOUNDATION
        if InitDataNames.sinf.matches(name) {
            return .Sinf
        }
        if InitDataNames.skd.matches(name) {
            return .Skd
        }
        #if HAVE_FAIRPLAYSTREAMING_MTPS_INITDATA
        if InitDataNames.mpts.matches(name) {
            return .Mpts
        }
        #endif
        #endif
        return .Other
    }

    struct CencPsshBoxes {
        var hasFairPlayPssh = false
    }

    static func parseCenc(_ cenc: Span<UInt8>) -> CencPsshBoxes? {
        var unused = WebCore.MediaParserByteVector()
        return parseCenc(cenc, collectingKeyIDs: false, into: &unused)
    }

    // 'cenc' init data is pssh boxes that all parse, in less than 64 KB; trailing bytes that hold no box header are
    // ignored, and no boxes at all is fine. With FairPlay Streaming, a pssh with its system ID is parsed as a FairPlay
    // pssh. The key IDs are, per box, those of the FairPlay key requests when the scheme is valid, then the pssh's own.
    // With collectingKeyIDs, the key IDs are appended to keyIDs, 16 bytes each, straight into its (fastMalloc) buffer;
    // keyIDs is left as it was if the init data isn't valid.
    static func parseCenc(_ cenc: Span<UInt8>, collectingKeyIDs: Bool, into keyIDs: inout WebCore.MediaParserByteVector) -> CencPsshBoxes? {
        let originalKeyIDsSize = keyIDs.size()
        guard let result = parseCenc(cenc, collectingKeyIDs: collectingKeyIDs, appendingTo: &keyIDs) else {
            keyIDs.shrink(originalKeyIDsSize)
            return nil
        }
        return result
    }

    private static func parseCenc(
        _ cenc: Span<UInt8>,
        collectingKeyIDs: Bool,
        appendingTo keyIDs: inout WebCore.MediaParserByteVector
    ) -> CencPsshBoxes? {
        guard cenc.count < maximumCencSize else {
            return nil
        }
        var result = CencPsshBoxes()
        var offset: UInt32 = 0
        while let box = ISOBoxHeader.peek(cenc, at: offset) {
            guard box.type == PsshBox.boxType, box.size <= UInt64(cenc.count) else {
                return nil
            }
            // A generic parse of a pssh succeeds exactly when reading it does, so this read also gives the system ID
            // that picks the FairPlay parser, as PsshBox.peekSystemID() would.
            var genericOffset = offset
            guard let pssh = PsshBox.read(cenc, at: &genericOffset) else {
                return nil
            }
            #if HAVE_FAIRPLAYSTREAMING_CENC_INITDATA
            if isFairPlaySystemID(pssh.systemID) {
                guard let fairPlayPssh = FairPlayStreamingPsshBox.read(cenc, at: &offset) else {
                    return nil
                }
                result.hasFairPlayPssh = true
                if collectingKeyIDs {
                    if FairPlayStreamingParsing.isValidScheme(fairPlayPssh.initData.info.scheme) {
                        for request in fairPlayPssh.initData.requests {
                            appendKeyIDs(cenc, request.requestInfo.keyIDPositions, to: &keyIDs)
                        }
                    }
                    appendKeyIDs(cenc, fairPlayPssh.pssh.keyIDPositions, to: &keyIDs)
                }
                continue
            }
            #endif
            offset = genericOffset
            if collectingKeyIDs {
                appendKeyIDs(cenc, pssh.keyIDPositions, to: &keyIDs)
            }
        }
        return result
    }

    // The key IDs at these positions of cenc, 16 bytes each.
    @inline(never)
    private static func appendKeyIDs(_ cenc: Span<UInt8>, _ positions: Range<Int>?, to keyIDs: inout WebCore.MediaParserByteVector) {
        // An empty Span may have no base address, which Cxx's std::span conversion traps on.
        guard let positions, !positions.isEmpty else {
            return
        }
        WebCore.appendBytes(&keyIDs, cenc.extracting(positions))
    }

    #if HAVE_FAIRPLAYSTREAMING_CENC_INITDATA
    // Compares the words: Swift 6.4 leaves InlineBytes16's defaulted operator== undefined at link time.
    private static func isFairPlaySystemID(_ systemID: WebCore.InlineBytes16?) -> Bool {
        guard let systemID else {
            return false
        }
        let fairPlay = FairPlayStreamingPsshBox.fairPlaySystemID
        return systemID.high == fairPlay.high && systemID.low == fairPlay.low
    }

    // The bytes of the first pssh box with FairPlay Streaming's system ID, stepping over the boxes before it without
    // parsing them; nil if a box before it isn't a pssh.
    static func fairPlayPsshRange(_ cenc: Span<UInt8>) -> Range<Int>? {
        guard cenc.count < maximumCencSize else {
            return nil
        }
        var offset: UInt32 = 0
        while let box = ISOBoxHeader.peek(cenc, at: offset) {
            guard box.type == PsshBox.boxType, UInt64(offset) + box.size <= UInt64(cenc.count) else {
                return nil
            }
            if isFairPlaySystemID(PsshBox.peekSystemID(cenc, at: offset)) {
                return Int(offset)..<(Int(offset) + Int(box.size))
            }
            // A peeked size is at least 1 and never goes past the end of the bytes.
            offset &+= UInt32(truncatingIfNeeded: box.size)
        }
        return nil
    }
    #endif

    // 'webm' init data is a ContentEncKeyID.
    static func isValidWebM(size: UInt) -> Bool {
        size > 0 && size <= maximumWebMKeyIDSize
    }
}

@_expose(Cxx)
func initDataKindImpl(_ name: WebCore.MediaParserShortName) -> WebCore.InitDataKind {
    InitDataParsing.kind(name)
}

// True for valid 'cenc' init data, whose key IDs are then appended to keyIDs, 16 bytes each. False leaves keyIDs alone.
@_expose(Cxx)
func extractKeyIDsCencImpl(_ cenc: borrowing WebCore.MediaParserBytes, _ keyIDs: inout WebCore.MediaParserByteVector) -> Bool {
    let bytes: Span<UInt8> = cenc.span()
    return InitDataParsing.parseCenc(bytes, collectingKeyIDs: true, into: &keyIDs) != nil
}

@_expose(Cxx)
func isValidCencInitDataImpl(_ cenc: borrowing WebCore.MediaParserBytes) -> Bool {
    let bytes: Span<UInt8> = cenc.span()
    return InitDataParsing.parseCenc(bytes) != nil
}

@_expose(Cxx)
func isValidWebMInitDataImpl(_ size: UInt) -> Bool {
    InitDataParsing.isValidWebM(size: size)
}

#if HAVE_FAIRPLAYSTREAMING_CENC_INITDATA
// True when 'cenc' init data has a FairPlay Streaming pssh box, whose bytes in cenc are then put in range. False leaves
// range alone.
@_expose(Cxx)
func fairPlayPsshRangeImpl(_ cenc: borrowing WebCore.MediaParserBytes, _ range: inout WebCore.ISOByteRange) -> Bool {
    let bytes: Span<UInt8> = cenc.span()
    guard let pssh = InitDataParsing.fairPlayPsshRange(bytes) else {
        return false
    }
    range = WebCore.ISOByteRange(offset: pssh.lowerBound, size: pssh.count)
    return true
}
#endif

#endif // ENABLE_WEBCORE_SWIFT && ENABLE_ENCRYPTED_MEDIA
