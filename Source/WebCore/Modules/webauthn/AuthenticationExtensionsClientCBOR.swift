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

// ENABLE(WEB_AUTHN) (PlatformEnableCocoa.h): every Cocoa platform but watchOS and Mac Catalyst.
#if !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST

// Without these, no operator in this file type-checks: WebCore's C++ operators name types these modules define.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch
internal import wtf
internal import WebCore_Private.Core.WebAuthnSwiftTypes

/// The body of `AuthenticationExtensionsClientInputs::fromCBOR`, which forwards here.
///
/// `buffer` is the caller's buffer, `span(options.extensionsCBOR)` in `_WKWebAuthenticationPanel.mm`: it stays
/// allocated, at its length, for the call, nothing here writes it, and its bytes have no invalid bit patterns.
/// FIXME: Take a `Span<UInt8>` parameter once a `std::span` can cross safely (rdar://186723514).
@_expose(Cxx)
func webAuthnExtensionInputsFromCBOR(_ buffer: cbor.ByteSpan) -> fido.OptionalClientInputs {
    let data = unsafe Span<UInt8>(_unsafeCxxSpan: buffer)
    guard let root = CBORView(data), root.isMap else {
        return fido.OptionalClientInputs()
    }
    var inputs = fido.WebAuthnClientInputsBuilder()
    if let item = root.value(forKey: "appid"), let appid = item.string {
        inputs.setAppid(makeWTFString(appid))
    }
    if let item = root.value(forKey: "credProps"), let credProps = item.bool {
        inputs.setCredProps(credProps)
    }
    if let item = root.value(forKey: "crossDeviceFallbackUrl"), let url = item.string {
        inputs.setCrossDeviceFallbackURL(makeWTFString(url))
    }
    if let largeBlob = root.value(forKey: "largeBlob"), largeBlob.isMap {
        inputs.beginLargeBlob()
        if let item = largeBlob.value(forKey: "support"), let support = item.string {
            inputs.setLargeBlobSupport(makeWTFString(support))
        }
        if let item = largeBlob.value(forKey: "read"), let read = item.bool {
            inputs.setLargeBlobRead(read)
        }
        if let item = largeBlob.value(forKey: "write"), let write = item.byteString {
            inputs.setLargeBlobWrite(makeByteVector(write))
        }
    }
    return inputs.take()
}

/// The body of `AuthenticationExtensionsClientInputs::toCBOR`, which forwards here.
///
/// The keys are written in `ctapLess` order: by length, then by character.
///
/// `inputs` is `*this` of `toCBOR() const`, called on the caller's `options.extensions`, which stays alive and
/// unchanged for the call. Swift reads `String` and `Vector` members of it and calls `BufferSource::span()` on a copy;
/// none of those reaches the caller's `options`.
@_expose(Cxx)
func webAuthnExtensionInputsToCBOR(_ inputs: borrowing WebCore.AuthenticationExtensionsClientInputs) -> cbor.Bytes {
    let writesAppid = !inputs.appid.isEmpty()
    let credProps = Optional(fromCxx: inputs.credProps)
    let writesCrossDeviceFallbackURL = !inputs.crossDeviceFallbackURL.isEmpty()
    let largeBlob = Optional(fromCxx: inputs.largeBlob)
    let prf = Optional(fromCxx: inputs.prf)

    var writer = CBORWriter(reservingCapacity: 64)
    writer.beginMap(
        count: (writesAppid ? 1 : 0) + (credProps != nil ? 1 : 0) + (writesCrossDeviceFallbackURL ? 1 : 0)
            + (largeBlob != nil ? 1 : 0) + (prf != nil ? 1 : 0)
    )
    if let prf {
        let eval = Optional(fromCxx: prf.eval)
        let evalByCredential = Optional(fromCxx: prf.evalByCredential)
        writer.writeTextString("prf")
        writer.beginMap(count: (eval != nil ? 1 : 0) + (evalByCredential != nil ? 1 : 0))
        if let eval {
            writer.writeTextString("eval")
            writePRFValues(&writer, eval)
        }
        if let evalByCredential {
            var entries: [(key: WTF.String, value: [UInt8])] = []
            entries.reserveCapacity(evalByCredential.size())
            for index in 0..<evalByCredential.size() {
                let entry = evalByCredential[index]
                var valuesWriter = CBORWriter(reservingCapacity: 32)
                writePRFValues(&valuesWriter, entry.value)
                entries.append((key: entry.key, value: valuesWriter.takeBytes()))
            }
            writer.writeTextString("evalByCredential")
            writer.appendMap(sortingTextKeys: entries)
        }
    }
    if writesAppid {
        writer.writeTextString("appid")
        writer.writeTextString(makeSwiftString(inputs.appid))
    }
    if let credProps {
        writer.writeTextString("credProps")
        writer.writeBool(credProps)
    }
    if let largeBlob {
        let read = Optional(fromCxx: largeBlob.read)
        let write = Optional(fromCxx: largeBlob.write)
        let writesSupport = !largeBlob.support.isNull()
        writer.writeTextString("largeBlob")
        writer.beginMap(count: (read != nil ? 1 : 0) + (write != nil ? 1 : 0) + (writesSupport ? 1 : 0))
        if let read {
            writer.writeTextString("read")
            writer.writeBool(read)
        }
        if let write {
            let bytes: Span<UInt8> = write.span()
            writer.writeTextString("write")
            writer.writeByteString(bytes)
        }
        if writesSupport {
            writer.writeTextString("support")
            writer.writeTextString(makeSwiftString(largeBlob.support))
        }
    }
    if writesCrossDeviceFallbackURL {
        writer.writeTextString("crossDeviceFallbackUrl")
        writer.writeTextString(makeSwiftString(inputs.crossDeviceFallbackURL))
    }
    return writer.takeVector()
}

/// The map of one `PRFValues`: first and, when given, second.
private func writePRFValues(_ writer: inout CBORWriter, _ values: borrowing WebCore.AuthenticationExtensionsClientInputs.PRFValues) {
    let second = Optional(fromCxx: values.second)
    writer.beginMap(count: second != nil ? 2 : 1)
    let first: Span<UInt8> = values.first.span()
    writer.writeTextString("first")
    writer.writeByteString(first)
    if let second {
        let bytes: Span<UInt8> = second.span()
        writer.writeTextString("second")
        writer.writeByteString(bytes)
    }
}

/// The body of `AuthenticationExtensionsClientOutputs::fromCBOR`, which forwards here.
///
/// `buffer` is the `const Vector&` of `fromCBOR`, so it stays allocated and unwritten for the call (a temporary at
/// the caller), and its bytes have no invalid bit patterns.
/// FIXME: Take a `Span<UInt8>` parameter once a `std::span` can cross safely (rdar://186723514).
@_expose(Cxx)
func webAuthnExtensionOutputsFromCBOR(_ buffer: cbor.ByteSpan) -> fido.OptionalClientOutputs {
    let data = unsafe Span<UInt8>(_unsafeCxxSpan: buffer)
    guard let root = CBORView(data), root.isMap else {
        return fido.OptionalClientOutputs()
    }
    var outputs = fido.WebAuthnClientOutputsBuilder()
    if let item = root.value(forKey: "appid"), let appid = item.bool {
        outputs.setAppid(appid)
    }
    if let credProps = root.value(forKey: "credProps"), credProps.isMap {
        outputs.setCredPropsRk(credProps.value(forKey: "rk")?.bool ?? false)
    }
    if let largeBlob = root.value(forKey: "largeBlob"), largeBlob.isMap {
        outputs.beginLargeBlob()
        if let item = largeBlob.value(forKey: "supported"), let supported = item.bool {
            outputs.setLargeBlobSupported(supported)
        }
        if let item = largeBlob.value(forKey: "blob"), let blob = item.byteString {
            outputs.setLargeBlobBlob(makeByteVector(blob))
        }
        if let item = largeBlob.value(forKey: "written"), let written = item.bool {
            outputs.setLargeBlobWritten(written)
        }
    }
    return outputs.take()
}

/// The body of `AuthenticationExtensionsClientOutputs::toCBOR`, which forwards here.
///
/// `outputs` is `*this` of `toCBOR() const`, alive and unchanged for the call. Swift reads its members and calls
/// `fido::largeBlobOutputBytes`, which copies the bytes.
@_expose(Cxx)
func webAuthnExtensionOutputsToCBOR(_ outputs: borrowing WebCore.AuthenticationExtensionsClientOutputs) -> cbor.Bytes {
    let appid = Optional(fromCxx: outputs.appid)
    let credProps = Optional(fromCxx: outputs.credProps)
    let largeBlob = Optional(fromCxx: outputs.largeBlob)

    var writer = CBORWriter(reservingCapacity: 48)
    writer.beginMap(count: (appid != nil ? 1 : 0) + (credProps != nil ? 1 : 0) + (largeBlob != nil ? 1 : 0))
    if let appid {
        writer.writeTextString("appid")
        writer.writeBool(appid)
    }
    if let credProps {
        writer.writeTextString("credProps")
        writer.beginMap(count: 1)
        writer.writeTextString("rk")
        writer.writeBool(credProps.rk)
    }
    if let largeBlob {
        let supported = Optional(fromCxx: largeBlob.supported)
        let blob = Optional(fromCxx: fido.largeBlobOutputBytes(largeBlob))
        let written = Optional(fromCxx: largeBlob.written)
        writer.writeTextString("largeBlob")
        writer.beginMap(count: (supported != nil ? 1 : 0) + (blob != nil ? 1 : 0) + (written != nil ? 1 : 0))
        if let blob {
            writer.writeTextString("blob")
            writer.writeByteString(blob.span())
        }
        if let written {
            writer.writeTextString("written")
            writer.writeBool(written)
        }
        if let supported {
            writer.writeTextString("supported")
            writer.writeBool(supported)
        }
    }
    return writer.takeVector()
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
