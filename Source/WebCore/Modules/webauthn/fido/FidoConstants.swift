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

/// FidoConstants.h's string constants (ASCIILiteral, which does not import).
///
/// Each literal is pinned by a static_assert in AuthenticatorGetInfoResponse.cpp.
public enum FidoName {
    /// `kResidentKeyMapKey`.
    public static let residentKey = "rk"
    /// `kUserVerificationMapKey`.
    public static let userVerification = "uv"
    /// `kUserPresenceMapKey`.
    public static let userPresence = "up"
    /// `kClientPinMapKey`.
    public static let clientPin = "clientPin"
    /// `kPlatformDeviceMapKey`.
    public static let platformDevice = "plat"
    /// `kEntityIdMapKey`.
    public static let entityID = "id"
    /// `kEntityNameMapKey`.
    public static let entityName = "name"
    /// `kDisplayNameMapKey`.
    public static let displayName = "displayName"
    /// `kIconUrlMapKey`.
    public static let iconURL = "icon"
    /// `kCredentialTypeMapKey`.
    public static let credentialTypeMap = "type"
    /// `kCredentialAlgorithmMapKey`.
    public static let credentialAlgorithm = "alg"
    /// `kCredentialIdKey`.
    public static let credentialID = "id"
    /// `kCredentialTypeKey`.
    public static let credentialType = "type"
    /// `kPublicKey`.
    public static let publicKey = "public-key"
    /// `kCtap2Version`.
    public static let ctap2Version = "FIDO_2_0"
    /// `kCtap21Version`.
    public static let ctap21Version = "FIDO_2_1"
    /// `kCtap21PreVersion`.
    public static let ctap21PreVersion = "FIDO_2_1_PRE"
    /// `kU2fVersion`.
    public static let u2fVersion = "U2F_V2"
    /// `kFormatKey`.
    public static let format = "fmt"
    /// `kAttestationStatementKey`.
    public static let attestationStatement = "attStmt"
    /// `kAuthDataKey`.
    public static let authData = "authData"
    /// `kExtensionHmacSecret`.
    public static let extensionHmacSecret = "hmac-secret"
    /// `kExtensionHmacSecretMc`.
    public static let extensionHmacSecretMc = "hmac-secret-mc"
}

extension fido.ProtocolVersion {
    /// The name `toString(ProtocolVersion)` gives the version.
    var name: Swift.String {
        switch self {
        case .ctap2: FidoName.ctap2Version
        case .ctap21: FidoName.ctap21Version
        case .ctap21Pre: FidoName.ctap21PreVersion
        case .u2f: FidoName.u2fVersion
        default: "UNKNOWN"
        }
    }
}

extension fido.CtapDeviceResponseCode {
    /// Whether the code is one a CTAP device can send.
    var isDeviceResponseCode: Bool {
        switch self {
        case .success, .ctap1ErrInvalidCommand, .ctap1ErrInvalidParameter, .ctap1ErrInvalidLength, .ctap1ErrInvalidSeq,
            .ctap1ErrTimeout, .ctap1ErrChannelBusy, .ctap1ErrLockRequired, .ctap1ErrInvalidChannel,
            .ctap2ErrCBORParsing, .ctap2ErrUnexpectedType, .ctap2ErrInvalidCBOR, .ctap2ErrInvalidCBORType,
            .ctap2ErrMissingParameter, .ctap2ErrLimitExceeded, .ctap2ErrUnsupportedExtension, .ctap2ErrTooManyElements,
            .ctap2ErrExtensionNotSupported, .ctap2ErrCredentialExcluded, .ctap2ErrProcesssing,
            .ctap2ErrInvalidCredential, .ctap2ErrUserActionPending, .ctap2ErrOperationPending, .ctap2ErrNoOperations,
            .ctap2ErrUnsupportedAlgorithms, .ctap2ErrOperationDenied, .ctap2ErrKeyStoreFull, .ctap2ErrNotBusy,
            .ctap2ErrNoOperationPending, .ctap2ErrUnsupportedOption, .ctap2ErrInvalidOption, .ctap2ErrKeepAliveCancel,
            .ctap2ErrNoCredentials, .ctap2ErrUserActionTimeout, .ctap2ErrUserPresenceRequired, .ctap2ErrNotAllowed,
            .ctap2ErrPinInvalid, .ctap2ErrPinBlocked, .ctap2ErrPinAuthInvalid, .ctap2ErrPinAuthBlocked,
            .ctap2ErrPinNotSet, .ctap2ErrPinRequired, .ctap2ErrPinPolicyViolation, .ctap2ErrPinTokenExpired,
            .ctap2ErrRequestTooLarge, .ctap2ErrActionTimeout, .ctap2ErrOther, .ctap2ErrSpecLast,
            .ctap2ErrExtensionFirst, .ctap2ErrExtensionLast, .ctap2ErrVendorFirst, .ctap2ErrVendorLast:
            true
        default:
            false
        }
    }
}

extension fido {
    /// Whether the version is a CTAP2 one.
    @cxx
    @implementation
    public static func isCtap2Protocol(_ version: fido.ProtocolVersion) -> Bool {
        switch version {
        case .ctap2, .ctap21, .ctap21Pre:
            return true
        default:
            return false
        }
    }

    /// The version's name.
    @cxx
    @implementation
    public static func toString(_ version: fido.ProtocolVersion) -> WTF.String {
        makeWTFString(version.name)
    }
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
