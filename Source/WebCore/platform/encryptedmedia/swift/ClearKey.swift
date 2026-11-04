// Copyright (C) 2016 Metrological Group B.V.
// Copyright (C) 2016 Igalia S.L.
// Copyright (C) 2020 Metrological Group B.V.
// Copyright (C) 2020 Igalia S.L.
// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above
//    copyright notice, this list of conditions and the following
//    disclaimer in the documentation and/or other materials provided
//    with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_ENCRYPTED_MEDIA

/// CDMRequirement.
public enum EMERequirement: Sendable {
    case required
    case optional
    case notAllowed
}

/// CDMSessionType.
public enum EMESessionType: Sendable {
    case temporary
    case persistentUsageRecord
    case persistentLicense
}

/// CDMKeyStatus, as far as ClearKey uses it.
public enum EMEKeyStatus: Sendable {
    case usable
    case released
}

/// A key ID and its key's status, as CDMInstanceSession::KeyStatusVector lists them.
public struct EMEKeyIDStatus: Sendable {
    /// The key ID.
    public let keyID: ContiguousArray<UInt8>
    /// The key's status.
    public let status: EMEKeyStatus
}

/// What the ClearKey policy reads of a CDMKeySystemConfiguration and its CDMRestrictions.
public struct ClearKeyConfiguration: Sendable {
    /// CDMKeySystemConfiguration::distinctiveIdentifier.
    public var distinctiveIdentifier: EMERequirement
    /// CDMKeySystemConfiguration::persistentState.
    public var persistentState: EMERequirement
    /// Whether CDMKeySystemConfiguration::sessionTypes has 'persistent-license'.
    public var sessionTypesIncludePersistentLicense: Bool
    /// CDMRestrictions::distinctiveIdentifierDenied.
    public var distinctiveIdentifierDenied: Bool
    /// CDMRestrictions::persistentStateDenied.
    public var persistentStateDenied: Bool

    /// A configuration, with no restrictions unless given.
    public init(
        distinctiveIdentifier: EMERequirement,
        persistentState: EMERequirement,
        sessionTypesIncludePersistentLicense: Bool,
        distinctiveIdentifierDenied: Bool = false,
        persistentStateDenied: Bool = false
    ) {
        self.distinctiveIdentifier = distinctiveIdentifier
        self.persistentState = persistentState
        self.sessionTypesIncludePersistentLicense = sessionTypesIncludePersistentLicense
        self.distinctiveIdentifierDenied = distinctiveIdentifierDenied
        self.persistentStateDenied = persistentStateDenied
    }
}

/// The ClearKey CDM (https://www.w3.org/TR/encrypted-media/#clear-key): what CDMFactoryClearKey and CDMPrivateClearKey
/// decide.
///
/// Names and session IDs are WTF::String code units.
public enum ClearKey {
    /// The key system.
    public static let keySystem = "org.w3.clearkey"
    /// CDMPrivate::supportedInitDataTypes().
    public static let supportedInitDataTypes = ["keyids", "cenc", "webm"]
    /// CDMPrivate::supportedRobustnesses(): only the empty robustness.
    public static let supportedRobustnesses = [""]
    /// CDMPrivate::supportsServerCertificates().
    public static let supportsServerCertificates = false
    /// CDMPrivate::supportsSessions().
    public static let supportsSessions = true

    private static let keyIDSize: UInt32 = 16

    /// The init data types ClearKey knows.
    public enum InitDataType: Sendable {
        case keyids
        case cenc
        case webm
        case other
    }

    /// CDMFactory::supportsKeySystem(): the key system, ignoring ASCII case.
    public static func supportsKeySystem<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ keySystem: Span<CodeUnit>) -> Bool {
        equalLettersIgnoringASCIICase(keySystem, "org.w3.clearkey")
    }

    /// supportsKeySystem() of a Swift string.
    public static func supportsKeySystem(_ keySystem: String?) -> Bool {
        supportsKeySystem(codeUnits(keySystem).span)
    }

    /// The type of an init data type name, matched ignoring ASCII case.
    public static func initDataType<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ name: Span<CodeUnit>) -> InitDataType {
        if equalLettersIgnoringASCIICase(name, "keyids") {
            return .keyids
        }
        if equalLettersIgnoringASCIICase(name, "cenc") {
            return .cenc
        }
        if equalLettersIgnoringASCIICase(name, "webm") {
            return .webm
        }
        return .other
    }

    /// initDataType() of a Swift string.
    public static func initDataType(_ name: String?) -> InitDataType {
        initDataType(codeUnits(name).span)
    }

    /// CDMPrivate::supportsInitData(): keyids init data is a JSON object, cenc init data has key IDs in a ClearKey pssh
    /// box, and WebM init data isn't empty.
    public static func supportsInitData(_ type: InitDataType, _ initData: Span<UInt8>) -> Bool {
        switch type {
        case .keyids:
            parseJSONObject(initData) != nil
        case .cenc:
            cencKeyIDs(initData) != nil
        case .webm:
            !initData.isEmpty
        case .other:
            false
        }
    }

    /// Whether CDMPrivate::sanitizeResponse() keeps a response: when it is a JSON object.
    public static func sanitizeResponse(_ response: Span<UInt8>) -> Bool {
        parseJSONObject(response) != nil
    }

    /// Whether CDMPrivate::sanitizeSessionId() keeps a session ID: when parseInteger<uint32_t>() parses it.
    public static func isValidSessionID<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ sessionID: Span<CodeUnit>) -> Bool {
        parseUInt32(sessionID) != nil
    }

    /// isValidSessionID() of a Swift string.
    public static func isValidSessionID(_ sessionID: String?) -> Bool {
        isValidSessionID(codeUnits(sessionID).span)
    }

    /// CDMPrivate::supportsConfigurationWithRestrictions(), and supportsConfiguration() without restrictions.
    ///
    /// Distinctive identifiers can't be required, or optional when denied. Persistent state can't be optional when
    /// denied, or required without the 'persistent-license' session type.
    public static func supportsConfiguration(_ configuration: ClearKeyConfiguration) -> Bool {
        let distinctiveIdentifier = configuration.distinctiveIdentifier
        let persistentState = configuration.persistentState
        if distinctiveIdentifier == .required || (distinctiveIdentifier == .optional && configuration.distinctiveIdentifierDenied) {
            return false
        }
        if persistentState == .optional && configuration.persistentStateDenied {
            return false
        }
        if persistentState == .required && !configuration.sessionTypesIncludePersistentLicense {
            return false
        }
        return true
    }

    /// The session type half of CDMPrivate::supportsSessionTypeWithConfiguration().
    public static func supportsSessionType(_ sessionType: EMESessionType) -> Bool {
        sessionType == .temporary || sessionType == .persistentLicense
    }

    /// CDMPrivate::distinctiveIdentifiersRequirement() and persistentStateRequirement().
    public static func requirement(denied: Bool) -> EMERequirement {
        denied ? .notAllowed : .optional
    }

    /// Whether CDMInstance::initializeWithConfiguration() succeeds.
    public static func initializationSucceeds(allowsDistinctiveIdentifiers: Bool, allowsPersistentState: Bool) -> Bool {
        !allowsDistinctiveIdentifiers && !allowsPersistentState
    }

    // CDMUtilities::parseJSONObject(): buffers too long for a 32-bit size aren't parsed.
    static func parseJSONObject(_ buffer: Span<UInt8>) -> EMEJSONObject? {
        guard UInt(buffer.count) <= UInt(UInt32.max) else {
            return nil
        }
        return EMEJSON.parse(latin1: buffer)?.object
    }

    // The 'license request' and 'license release' formats: {"kids":["<base64url key ID>",...]}.
    static func keyIDsMessage(_ keyIDs: some Sequence<ContiguousArray<UInt8>>) -> ContiguousArray<UInt8> {
        var message = ContiguousArray<UInt8>()
        message.append(0x7B)
        EMEJSON.writeName("kids", to: &message)
        EMEJSON.writeStringArray(keyIDs.map { WTFBase64.urlEncode($0.span) }, to: &message)
        message.append(0x7D)
        return message
    }

    /// A session's license request message.
    public enum LicenseRequest: Sendable {
        // The init data itself.
        case initData
        case message(ContiguousArray<UInt8>)
    }

    // A cenc request lists the key IDs of the ClearKey pssh box, and a WebM request the init data, which is a key ID.
    // Other init data is the request itself.
    static func licenseRequest(_ type: InitDataType, _ initData: Span<UInt8>) -> LicenseRequest {
        switch type {
        case .keyids, .other:
            .initData
        case .cenc, .webm:
            .message(licenseRequestMessage(type, initData) ?? [])
        }
    }

    private static func licenseRequestMessage(_ type: InitDataType, _ initData: Span<UInt8>) -> ContiguousArray<UInt8>? {
        switch type {
        case .cenc:
            guard let keyIDs = cencKeyIDs(initData) else {
                return nil
            }
            var ids: [ContiguousArray<UInt8>] = []
            ids.reserveCapacity(Int(keyIDs.count))
            var offset = Int(keyIDs.firstOffset)
            for _ in 0..<keyIDs.count {
                ids.append(copy(initData, offset..<offset + Int(keyIDSize)))
                offset += Int(keyIDSize)
            }
            return keyIDsMessage(ids)
        case .webm:
            guard !initData.isEmpty, UInt(initData.count) <= UInt(UInt32.max) else {
                return nil
            }
            return keyIDsMessage(CollectionOfOne(copy(initData, 0..<initData.count)))
        case .keyids, .other:
            return nil
        }
    }

    // https://www.w3.org/TR/eme-initdata-cenc/#common-system: 1077efec-c0b2-4d02-ace3-3c1e52e2fb4b.
    private static let cencSystemIDHigh: UInt64 = 0x1077_EFEC_C0B2_4D02
    private static let cencSystemIDLow: UInt64 = 0xACE3_3C1E_52E2_FB4B
    private static let systemIDSize: UInt32 = 16
    // A box header and a full box header.
    private static let psshHeaderSize: UInt32 = 12

    // The search for the ClearKey pssh box in concatenated cenc init data: a box size is its low 16 bits, the key ID
    // count its low byte, each bounds check needs at least one byte past what it reads, and the arithmetic is 32-bit
    // unsigned. nil when there is no such box, or it has no key IDs or they don't fit.
    static func cencKeyIDs(_ data: Span<UInt8>) -> (count: UInt32, firstOffset: UInt32)? {
        guard !data.isEmpty, let size = UInt32(exactly: data.count) else {
            return nil
        }

        var index: UInt32 = 0
        while true {
            // Adds the header size in 32 bits, wrapping, and then the system ID size in 64.
            guard UInt64(index &+ psshHeaderSize) + UInt64(systemIDSize) < UInt64(size),
                let sizeHigh = byte(data, index &+ 2), let sizeLow = byte(data, index &+ 3)
            else {
                return nil
            }
            let psshSize = UInt32(sizeHigh) << 8 | UInt32(sizeLow)
            if psshSize == 0 {
                return nil
            }
            if hasCencSystemID(data, at: index &+ psshHeaderSize) {
                break
            }
            index &+= psshSize
        }

        index &+= psshHeaderSize &+ systemIDSize
        guard index &+ 3 < size, let countByte = byte(data, index &+ 3) else {
            return nil
        }
        let count = UInt32(countByte)
        index &+= 4
        guard count != 0, index != 0, index &+ count &* keyIDSize < size else {
            return nil
        }
        return (count, index)
    }

    private static func byte(_ data: Span<UInt8>, _ index: UInt32) -> UInt8? {
        Int(index) < data.count ? data[Int(index)] : nil
    }

    private static func bigEndianUInt64(_ data: Span<UInt8>, at offset: Int) -> UInt64? {
        guard offset >= 0, data.count - offset >= 8 else {
            return nil
        }
        var value: UInt64 = 0
        for index in offset..<offset + 8 {
            value = value << 8 | UInt64(data[index])
        }
        return value
    }

    private static func hasCencSystemID(_ data: Span<UInt8>, at offset: UInt32) -> Bool {
        bigEndianUInt64(data, at: Int(offset)) == cencSystemIDHigh && bigEndianUInt64(data, at: Int(offset) + 8) == cencSystemIDLow
    }

    static func copy(_ data: Span<UInt8>, _ range: Range<Int>) -> ContiguousArray<UInt8> {
        var result = ContiguousArray<UInt8>()
        result.reserveCapacity(range.count)
        for index in range {
            result.append(data[index])
        }
        return result
    }

    static func codeUnits(_ string: String?) -> ContiguousArray<UInt16> {
        ContiguousArray(string?.utf16 ?? "".utf16)
    }

    // WTF::equalLettersIgnoringASCIICase(), which lowercases with toASCIILowerUnchecked().
    private static func equalLettersIgnoringASCIICase<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ string: Span<CodeUnit>,
        _ lowercaseLiteral: StaticString
    ) -> Bool {
        let literal = lowercaseLiteral.description.utf8
        guard string.count == literal.count else {
            return false
        }
        for (index, byte) in literal.enumerated() where UInt32(string[index]) | 0x20 != UInt32(byte) {
            return false
        }
        return true
    }

    // WTF::parseInteger<uint32_t>(): optional leading and trailing isUnicodeCompatibleASCIIWhitespace, one optional '+',
    // then decimal digits; nil on overflow or anything else.
    private static func parseUInt32<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ string: Span<CodeUnit>) -> UInt32? {
        func isWhitespace(_ character: CodeUnit) -> Bool {
            character == 0x20 || (character >= 0x09 && character <= 0x0D)
        }
        func digit(_ character: CodeUnit) -> UInt32? {
            character >= 0x30 && character <= 0x39 ? UInt32(character - 0x30) : nil
        }
        var position = 0
        while position < string.count && isWhitespace(string[position]) {
            position += 1
        }
        if position < string.count && string[position] == 0x2B {
            position += 1
        }
        guard position < string.count, digit(string[position]) != nil else {
            return nil
        }
        var value: UInt32 = 0
        var overflowed = false
        while position < string.count, let digit = digit(string[position]) {
            let (product, productOverflowed) = value.multipliedReportingOverflow(by: 10)
            let (sum, sumOverflowed) = product.addingReportingOverflow(digit)
            overflowed = overflowed || productOverflowed || sumOverflowed
            value = sum
            position += 1
        }
        while position < string.count && isWhitespace(string[position]) {
            position += 1
        }
        guard !overflowed, position == string.count else {
            return nil
        }
        return value
    }
}

/// A CDMInstanceClearKey: it numbers its sessions.
public final class ClearKeyInstance {
    private var nextSessionIDValue: UInt32 = 0

    /// An instance whose first session is numbered 0.
    public init() {
    }

    /// CDMInstance::createSession().
    public func makeSession() -> ClearKeySession {
        ClearKeySession(parent: self)
    }

    fileprivate func takeNextSessionIDValue() -> UInt32 {
        defer {
            nextSessionIDValue &+= 1
        }
        return nextSessionIDValue
    }
}

/// The results of CDMInstanceSession::updateLicense().
public struct ClearKeyLicenseUpdate: Sendable {
    /// Whether the response acknowledged a release.
    public let sessionWasClosed: Bool
    /// The session's keys, or nil when no key changed.
    public let changedKeys: [EMEKeyIDStatus]?
    /// Whether the response was a license or a release acknowledgement.
    public let succeeded: Bool
}

/// A CDMInstanceSessionClearKey: its session ID, and the keys of its licenses, which it keeps sorted by key ID (EME's
/// MediaKeyStatusMap order).
public final class ClearKeySession {
    private weak var parent: ClearKeyInstance?
    /// The session ID that requestLicense() gave.
    public private(set) var sessionID = ""
    // Sorted by key ID; a key ID appears once.
    private var keys: [(id: ContiguousArray<UInt8>, value: ContiguousArray<UInt8>)] = []

    fileprivate init(parent: ClearKeyInstance) {
        self.parent = parent
    }

    /// CDMInstanceSession::requestLicense(): the session ID is the parent instance's next number, or empty once the
    /// instance is gone.
    public func requestLicense(
        _ type: ClearKey.InitDataType,
        _ initData: Span<UInt8>
    ) -> (request: ClearKey.LicenseRequest, sessionID: String) {
        if let parent {
            sessionID = String(parent.takeNextSessionIDValue())
        } else {
            sessionID = ""
        }
        return (ClearKey.licenseRequest(type, initData), sessionID)
    }

    /// CDMInstanceSession::updateLicense().
    ///
    /// https://www.w3.org/TR/encrypted-media/#clear-key-license-format: a "keys" array of valid keys is a license.
    /// Anything else with a "kids" array is a release acknowledgement, even with invalid keys.
    public func updateLicense(_ response: Span<UInt8>) -> ClearKeyLicenseUpdate {
        let failure = ClearKeyLicenseUpdate(sessionWasClosed: false, changedKeys: nil, succeeded: false)
        guard let root = ClearKey.parseJSONObject(response), parent != nil else {
            return failure
        }

        if let licenseKeys = Self.licenseKeys(root) {
            if licenseKeys.isEmpty {
                return ClearKeyLicenseUpdate(sessionWasClosed: false, changedKeys: nil, succeeded: true)
            }
            for key in licenseKeys {
                add(id: key.id, value: key.value)
            }
            return ClearKeyLicenseUpdate(sessionWasClosed: false, changedKeys: keyStatuses(.usable), succeeded: true)
        }

        if root.array("kids") != nil {
            keys.removeAll()
            return ClearKeyLicenseUpdate(sessionWasClosed: true, changedKeys: nil, succeeded: true)
        }
        return failure
    }

    /// The key statuses of CDMInstanceSession::loadSession().
    public func loadSession() -> [EMEKeyIDStatus] {
        keyStatuses(.usable)
    }

    /// CDMInstanceSession::removeSessionData(): the released keys, and the 'license release' message listing them.
    public func removeSessionData() -> (keys: [EMEKeyIDStatus], message: ContiguousArray<UInt8>) {
        let released = keyStatuses(.released)
        let message = ClearKey.keyIDsMessage(keys.lazy.map(\.id))
        keys.removeAll()
        return (released, message)
    }

    private func keyStatuses(_ status: EMEKeyStatus) -> [EMEKeyIDStatus] {
        keys.map { EMEKeyIDStatus(keyID: $0.id, status: status) }
    }

    private func add(id: ContiguousArray<UInt8>, value: ContiguousArray<UInt8>) {
        var low = 0
        var high = keys.count
        while low < high {
            let middle = (low + high) / 2
            if keys[middle].id.lexicographicallyPrecedes(id) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low < keys.count && keys[low].id == id {
            keys[low].value = value
        } else {
            keys.insert((id, value), at: low)
        }
    }

    // Every element of "keys" is an object whose "kty" is "oct" ignoring ASCII case and whose "kid" and "k" decode as
    // base64url; nil otherwise, or if there is no "keys" array.
    static func licenseKeys(_ root: EMEJSONObject) -> [(id: ContiguousArray<UInt8>, value: ContiguousArray<UInt8>)]? {
        guard let keys = root.array("keys") else {
            return nil
        }
        var result: [(id: ContiguousArray<UInt8>, value: ContiguousArray<UInt8>)] = []
        result.reserveCapacity(keys.count)
        for key in keys {
            guard let key = key.object,
                let keyType = key.string("kty"), keyType.equalsIgnoringASCIICase("oct"),
                let keyID = key.string("kid"), let keyValue = key.string("k"),
                let keyIDBytes = WTFBase64.urlDecode(keyID.codeUnits.span),
                let keyValueBytes = WTFBase64.urlDecode(keyValue.codeUnits.span)
            else {
                return nil
            }
            result.append((keyIDBytes, keyValueBytes))
        }
        return result
    }
}

#endif // ENABLE_ENCRYPTED_MEDIA
