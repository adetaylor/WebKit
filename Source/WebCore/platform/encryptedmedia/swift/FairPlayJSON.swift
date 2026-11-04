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

#if ENABLE_ENCRYPTED_MEDIA

/// The JSON of FairPlay Streaming's init data and license messages, as CDMFairPlayStreaming.cpp and
/// CDMInstanceFairPlayStreamingAVFObjC.mm read and write it.
public enum FairPlayJSON {
    /// The payloads of 'sinf' init data, {"sinf":["<base64 sinf box payload>",...]}, or nil unless there is a "sinf" array.
    ///
    /// Each string entry is decoded, giving nil when it isn't valid base64, whose padding is optional but checked when
    /// present and which may contain whitespace; entries that aren't strings are left out.
    public static func sinfPayloads(_ initData: Span<UInt8>) -> [ContiguousArray<UInt8>?]? {
        guard UInt(initData.count) <= UInt(UInt32.max), let entries = EMEJSON.parse(latin1: initData)?.object?.array("sinf") else {
            return nil
        }
        var payloads: [ContiguousArray<UInt8>?] = []
        for entry in entries {
            guard let sinf = entry.string else {
                continue
            }
            payloads.append(WTFBase64.decode(sinf.codeUnits.span, options: [.validatePadding, .ignoreWhitespace]))
        }
        return payloads
    }

    /// Whether init data is 'mpts' init data, {"cont":"mpts","codc":<number>,"mtyp":<number>}.
    public static func isMptsInitData(_ initData: Span<UInt8>) -> Bool {
        guard UInt(initData.count) <= UInt(UInt32.max), let root = EMEJSON.parse(latin1: initData)?.object else {
            return false
        }
        return root.string("cont")?.equals("mpts") == true && root.integer("codc") != nil && root.integer("mtyp") != nil
    }

    /// How far an element of a 'cenc' license response parses.
    ///
    /// The session finds the element's request by its key ID before it looks at the rest.
    public enum CencResponseEntry: Sendable, Equatable {
        case noKeyID
        case keyIDOnly(keyID: ContiguousArray<UInt8>)
        case payload(keyID: ContiguousArray<UInt8>, payload: ContiguousArray<UInt8>)
        case error(keyID: ContiguousArray<UInt8>, code: Int32)
    }

    /// The elements of a 'cenc' license response, [{"keyID":"<base64>","payload":"<base64>"|"error":<number>},...].
    ///
    /// The response is nil unless it is a JSON array. An element needs exactly one of a payload and an error.
    public static func cencResponse(_ response: Span<UInt8>) -> [CencResponseEntry]? {
        guard UInt(response.count) <= UInt(UInt32.max), let entries = EMEJSON.parse(latin1: response)?.array else {
            return nil
        }
        return entries.map(cencResponseEntry)
    }

    /// Appends an element of a 'cenc' license request, [{"keyID":"<base64>","payload":"<base64>"},...].
    public static func appendCencRequest(
        keyID: Span<UInt8>,
        payload: Span<UInt8>,
        isFirst: Bool,
        to message: inout ContiguousArray<UInt8>
    ) {
        message.append(isFirst ? 0x5B : 0x2C)
        message.append(0x7B)
        EMEJSON.writeBase64Member("keyID", of: keyID, to: &message)
        message.append(0x2C)
        EMEJSON.writeBase64Member("payload", of: payload, to: &message)
        message.append(0x7D)
    }

    /// Appends the end of a 'cenc' license request with `count` elements.
    public static func endCencRequest(count: Int, to message: inout ContiguousArray<UInt8>) {
        if count == 0 {
            message.append(0x5B)
        }
        message.append(0x5D)
    }

    private static func cencResponseEntry(_ entry: EMEJSONValue) -> CencResponseEntry {
        guard let object = entry.object,
            let keyIDString = object.string("keyID"),
            let keyID = WTFBase64.decode(keyIDString.codeUnits.span)
        else {
            return .noKeyID
        }
        let payload = object.value("payload")
        let error = object.value("error")
        if (payload == nil) == (error == nil) {
            return .keyIDOnly(keyID: keyID)
        }
        if let error {
            guard let code = error.integer else {
                return .keyIDOnly(keyID: keyID)
            }
            return .error(keyID: keyID, code: code)
        }
        guard let payloadString = payload?.string, let payloadBytes = WTFBase64.decode(payloadString.codeUnits.span) else {
            return .keyIDOnly(keyID: keyID)
        }
        return .payload(keyID: keyID, payload: payloadBytes)
    }
}

#endif // ENABLE_ENCRYPTED_MEDIA
