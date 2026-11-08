// Copyright (C) 2017-2026 Apple Inc. All rights reserved.
// Copyright (C) 2023 Apple Inc. All rights reserved.
// Copyright (C) 2024 Apple Inc. All rights reserved.
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

#if ENABLE_ENCRYPTED_MEDIA && HAVE_AVCONTENTKEYSESSION

// The FairPlay Streaming CDM's instance and sessions, over AVContentKeySession. CDMInstanceFairPlayStreamingAVFObjC.mm
// keeps the C++ CDMInstance and CDMInstanceSession that own them, for the players and the CDM interfaces.
//
// WebCore soft-links AVFoundation, and its Swift doesn't autolink it (CMakeLists.txt, WebCore.xcconfig): the classes and
// constants come from PAL's getters (pal/cocoa/AVFoundationSoftLink.h). A use of an AVFoundation class that needs its
// class object, such as a container of it, a cast to it or its metatype, references a symbol that WebCore doesn't link,
// and fails the link; such objects are kept in the wrapper structs below, and cast with PAL's helpers.

internal import AVFoundation
private import Cxx
internal import pal.Core.cocoa.AVFoundationSoftLink
internal import pal.spi.cocoa.AVFoundationSPI
import WebCore_Private.Core.CDMInstanceFairPlayStreamingHost
import WebCore_Private.Core.CDMKeyStatus
public import WebCore_Private.Core.CDMMessageType
public import WebCore_Private.Core.CDMSessionType
import WebCore_Private.Core.MediaParsersCxxBridging
import WebCoreEME
import wtf

private let contentKeyReportGroupKey = "ContentKeyReportGroup"
private let initializationDataTypeKey = "InitializationDataType"
private let securityLevelError = -42811
private let maximumDeviceIdentifierSeedSize = 20

private enum FairPlayInitTypeName {
    static let sinf = "sinf"
    static let skd = "skd"
    static let cenc = "cenc"
    static let mpts = "mpts"
}

typealias FairPlayKeyID = ContiguousArray<UInt8>

// MARK: Text and bytes

// Init data type names compare by code unit, as WTF::String does.
private func sameName(_ a: Swift.String, _ b: Swift.String) -> Bool {
    a.utf16.elementsEqual(b.utf16)
}

private func fairPlayString(_ text: borrowing WebCore.MediaParserText) -> Swift.String {
    if text.is8Bit {
        let characters: Span<UInt8> = text.span8()
        var string = ""
        for index in characters.indices {
            string.unicodeScalars.append(Unicode.Scalar(characters[index]))
        }
        return string
    }
    let characters: Span<UInt16> = text.span16()
    var units = ContiguousArray<UInt16>()
    units.reserveCapacity(characters.count)
    for index in characters.indices {
        units.append(characters[index])
    }
    return Swift.String(decoding: units, as: Unicode.UTF16.self)
}

private func fairPlayBytes(_ bytes: Span<UInt8>) -> ContiguousArray<UInt8> {
    var result = ContiguousArray<UInt8>()
    result.reserveCapacity(bytes.count)
    for index in bytes.indices {
        result.append(bytes[index])
    }
    return result
}

private func fairPlayBytes(_ data: Data?) -> ContiguousArray<UInt8> {
    guard let data else {
        return []
    }
    return ContiguousArray(data)
}

private func utf8(_ string: Swift.String) -> ContiguousArray<UInt8> {
    ContiguousArray(string.utf8)
}

// Whether key IDs from C++, back to back with their sizes, include keyID. The players ask with a sample's key IDs.
private func keyIDList(_ bytes: Span<UInt8>, _ sizes: Span<UInt32>, includes keyID: FairPlayKeyID) -> Bool {
    let candidate = keyID.span
    var offset = 0
    for index in sizes.indices {
        let size = Int(sizes[index])
        guard size <= bytes.count - offset else {
            return false
        }
        if size == candidate.count {
            var equal = true
            for byteIndex in 0..<size where bytes[offset + byteIndex] != candidate[byteIndex] {
                equal = false
                break
            }
            if equal {
                return true
            }
        }
        offset += size
    }
    return false
}

private func hexString(_ data: Data) -> Swift.String {
    let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
    var string = ""
    for byte in data {
        string.append(digits[Int(byte >> 4)])
        string.append(digits[Int(byte & 0xF)])
    }
    return string
}

// Whether a response is the given ASCII text once decoded as UTF-8, as TextDecoder does: a leading byte order mark is
// skipped, and any other non-ASCII byte decodes to something else.
private func isText(_ response: ContiguousArray<UInt8>, _ text: Swift.String) -> Bool {
    var bytes = response[...]
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
        bytes = bytes.dropFirst(3)
    }
    return bytes.elementsEqual(text.utf8)
}

private func sessionTypeName(_ type: WebCore.CDMSessionType) -> Swift.String {
    switch type {
    case .Temporary:
        "temporary"
    case .PersistentUsageRecord:
        "persistent-usage-record"
    case .PersistentLicense:
        "persistent-license"
    @unknown default:
        ""
    }
}

// MARK: Key statuses

struct FairPlayKeyStatus {
    var keyID: FairPlayKeyID
    var status: WebCore.CDMKeyStatus
}

// A key status list as the host functions take it.
private func withFlattenedKeyStatuses(
    _ statuses: [FairPlayKeyStatus],
    _ body: (Span<UInt8>, Span<UInt32>, Span<UInt8>) -> Void
) {
    var keyIDs = ContiguousArray<UInt8>()
    var sizes = ContiguousArray<UInt32>()
    var values = ContiguousArray<UInt8>()
    for status in statuses {
        keyIDs.append(contentsOf: status.keyID)
        sizes.append(UInt32(truncatingIfNeeded: status.keyID.count))
        values.append(status.status.rawValue)
    }
    body(keyIDs.span, sizes.span, values.span)
}

private func isPotentiallyUsable(_ status: WebCore.CDMKeyStatus) -> Bool {
    switch status {
    case .Expired, .Released, .InternalError:
        false
    case .Usable, .OutputRestricted, .OutputDownscaled, .StatusPending:
        true
    @unknown default:
        false
    }
}

private func keyStatus(for status: AVContentKeyRequest.Status) -> WebCore.CDMKeyStatus {
    switch status {
    case .requestingResponse, .retried:
        .StatusPending
    case .receivedResponse, .renewed:
        .Usable
    case .cancelled:
        .Released
    case .failed:
        .InternalError
    @unknown default:
        .InternalError
    }
}

#if HAVE_AVCONTENTKEYREQUEST_PENDING_PROTECTION_STATUS
private func keyStatus(for status: AVExternalContentProtectionStatus) -> WebCore.CDMKeyStatus? {
    switch status {
    case .pending:
        return .StatusPending
    case .sufficient:
        return .Usable
    case .insufficient:
        return .OutputRestricted
    @unknown default:
        assertionFailure()
        return nil
    }
}
#endif

// MARK: Requests

// A request in a Swift container, with the key IDs WebCore reads from it.
struct FairPlayKeyRequest {
    let request: AVContentKeyRequest
    let keyIDs: [FairPlayKeyID]

    init(_ request: AVContentKeyRequest) {
        self.request = request
        keyIDs = fairPlayKeyIDs(identifier: request.identifier, initializationData: request.initializationData)
    }
}

// Requests of one init data type, which a session handles as one.
struct FairPlayRequestGroup: Equatable {
    var initType: Swift.String
    var requests: [FairPlayKeyRequest]

    var keyIDs: [FairPlayKeyID] {
        requests.flatMap(\.keyIDs)
    }

    static func == (a: FairPlayRequestGroup, b: FairPlayRequestGroup) -> Bool {
        sameName(a.initType, b.initType)
            && a.requests.elementsEqual(b.requests) { $0.request === $1.request }
    }
}

// The key IDs of a request: its identifier when that's text or data, or else those of its 'sinf' or 'mpts' init data.
func fairPlayKeyIDs(identifier: Any?, initializationData: Data?) -> [FairPlayKeyID] {
    if let identifier = identifier as? NSString {
        return [fairPlayBytes(identifier.data(using: Swift.String.Encoding.utf8.rawValue))]
    }
    if let identifier = identifier as? NSData {
        return [fairPlayBytes(identifier as Data)]
    }
    guard let initializationData else {
        return []
    }
    let bytes = ContiguousArray(initializationData)
    var sinfKeyIDs = WebCore.MediaParserByteVector()
    if FairPlayStreamingParsing.sinfKeyIDs(bytes.span, into: &sinfKeyIDs) {
        let keyIDBytes: Span<UInt8> = sinfKeyIDs.span()
        var keyIDs: [FairPlayKeyID] = []
        for offset in stride(from: 0, to: keyIDBytes.count, by: FairPlayStreamingParsing.sinfKeyIDSize) {
            keyIDs.append(fairPlayBytes(keyIDBytes.extracting(offset..<(offset + FairPlayStreamingParsing.sinfKeyIDSize))))
        }
        return keyIDs
    }
    #if HAVE_FAIRPLAYSTREAMING_MTPS_INITDATA
    if FairPlayJSON.isMptsInitData(bytes.span) {
        return [FairPlayStreamingParsing.mptsKeyID]
    }
    #endif
    return []
}

private func initType(for request: AVContentKeyRequest) -> Swift.String {
    if let identifier = request.identifier as? NSString, identifier.hasPrefix("skd://") {
        return FairPlayInitTypeName.skd
    }
    // The only way for an initialization data to end up here without an appropriate key in the options dictionary is
    // for that data to have been generated by the AVStreamDataParser and currently, the only initialization data
    // supported by the parser is the 'sinf' kind.
    guard let initType = request.options[initializationDataTypeKey] as? NSString else {
        return FairPlayInitTypeName.sinf
    }
    return initType as Swift.String
}

private func initializationData(for request: AVContentKeyRequest) -> ContiguousArray<UInt8> {
    if sameName(initType(for: request), FairPlayInitTypeName.skd) {
        let identifier = request.identifier as? NSString
        return fairPlayBytes(identifier?.data(using: Swift.String.Encoding.utf8.rawValue, allowLossyConversion: true))
    }
    return fairPlayBytes(request.initializationData)
}

private func groupObject(for request: AVContentKeyRequest) -> AnyObject? {
    request.options[contentKeyReportGroupKey] as AnyObject?
}

// The options of a streaming content key request: a device identifier seed from the media keys' hash salt.
private func keyRequestOptions(hashSalt: Swift.String) -> [Swift.String: Any] {
    guard PAL.canLoad_AVFoundation_AVContentKeyRequestRandomDeviceIdentifierSeedKey(),
        PAL.canLoad_AVFoundation_AVContentKeyRequestShouldRandomizeDeviceIdentifierKey()
    else {
        return [:]
    }
    var seed: [UInt8] = []
    for character in hashSalt.utf8 {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            seed.append(character - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            seed.append(character - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            seed.append(character - UInt8(ascii: "A") + 10)
        default:
            break
        }
    }
    if seed.count > maximumDeviceIdentifierSeedSize {
        seed.removeLast(seed.count - maximumDeviceIdentifierSeedSize)
    } else if seed.count < maximumDeviceIdentifierSeedSize {
        seed.append(contentsOf: repeatElement(0, count: maximumDeviceIdentifierSeedSize - seed.count))
    }
    return [
        PAL.get_AVFoundation_AVContentKeyRequestShouldRandomizeDeviceIdentifierKeySingleton(): true,
        PAL.get_AVFoundation_AVContentKeyRequestRandomDeviceIdentifierSeedKeySingleton(): Data(seed),
    ]
}

// MARK: Content key session delegate

@MainActor
protocol FairPlayContentKeySessionClient: AnyObject, Sendable {
    func didProvide(_ request: AVContentKeyRequest)
    func didProvide(_ requests: [FairPlayKeyRequest])
    func didProvideRenewing(_ request: AVContentKeyRequest)
    func didProvidePersistable(_ request: AVContentKeyRequest)
    func didFail(_ request: AVContentKeyRequest, _ error: NSError)
    func didSucceed(_ request: AVContentKeyRequest)
    func shouldRetry(_ request: AVContentKeyRequest) -> Bool
    func sessionIdentifierChanged(_ sessionIdentifier: Data?)
    func groupSessionIdentifierChanged(_ group: ObjectIdentifier?, _ sessionIdentifier: Data?)
    func externalProtectionStatusDidChange(for key: AVContentKey)
    func externalProtectionStatusDidChange(for request: AVContentKeyRequest)
}

private let didProvideRequestsSelector = NSSelectorFromString("contentKeySession:didProvideContentKeyRequests:forInitializationData:")

// The delegate's -contentKeySession:didProvideContentKeyRequests:forInitializationData:, which AVFoundation reaches
// through -forwardingTargetForSelector:. Swift's typed array of requests would need their class object.
private final class FairPlayRequestsDelegate: NSObject, Sendable {
    private weak let client: (any FairPlayContentKeySessionClient)?

    init(client: any FairPlayContentKeySessionClient) {
        self.client = client
    }

    @objc(contentKeySession:didProvideContentKeyRequests:forInitializationData:)
    func didProvideRequests(_ session: AVContentKeySession, requests keyRequests: NSArray, initializationData: Data?) {
        var requests: [FairPlayKeyRequest] = []
        requests.reserveCapacity(keyRequests.count)
        for element in keyRequests {
            if let request = PAL.dynamicCastToAVContentKeyRequest(element) {
                requests.append(FairPlayKeyRequest(request))
            }
        }
        let providedRequests = requests
        MainActor.assumeIsolated {
            client?.didProvide(providedRequests)
        }
    }
}

// Delivers an AVContentKeySession's events, on the main queue, to its instance or session while it lives.
private final class FairPlayContentKeySessionDelegate: NSObject, AVContentKeySessionDelegate {
    private weak let client: (any FairPlayContentKeySessionClient)?
    private let requestsDelegate: FairPlayRequestsDelegate

    init(client: any FairPlayContentKeySessionClient) {
        self.client = client
        requestsDelegate = FairPlayRequestsDelegate(client: client)
    }

    override func responds(to selector: Selector!) -> Bool {
        selector == didProvideRequestsSelector || super.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        selector == didProvideRequestsSelector ? requestsDelegate : super.forwardingTarget(for: selector)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        MainActor.assumeIsolated {
            client?.didProvide(keyRequest)
        }
    }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        MainActor.assumeIsolated {
            client?.didProvideRenewing(keyRequest)
        }
    }

    #if !os(macOS)
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVPersistableContentKeyRequest) {
        MainActor.assumeIsolated {
            client?.didProvidePersistable(keyRequest)
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didUpdatePersistableContentKey persistableContentKey: Data,
        forContentKeyIdentifier keyIdentifier: Any
    ) {
    }
    #endif

    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError error: any Error) {
        let error = error as NSError
        MainActor.assumeIsolated {
            client?.didFail(keyRequest, error)
        }
    }

    func contentKeySession(_ session: AVContentKeySession, contentKeyRequestDidSucceed keyRequest: AVContentKeyRequest) {
        MainActor.assumeIsolated {
            client?.didSucceed(keyRequest)
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        shouldRetry keyRequest: AVContentKeyRequest,
        reason retryReason: AVContentKeyRequest.RetryReason
    ) -> Bool {
        MainActor.assumeIsolated {
            client?.shouldRetry(keyRequest) ?? false
        }
    }

    func contentKeySessionContentProtectionSessionIdentifierDidChange(_ session: AVContentKeySession) {
        let sessionIdentifier = session.contentProtectionSessionIdentifier
        MainActor.assumeIsolated {
            client?.sessionIdentifierChanged(sessionIdentifier)
        }
    }

    #if HAVE_AVCONTENTKEYREPORTGROUP
    // FIXME: Remove after rdar://57430747 is fixed
    @objc(contentKeySession:contentProtectionSessionIdentifierDidChangeForKeyGroup:)
    func contentProtectionSessionIdentifierDidChange(_ session: AVContentKeySession, keyGroup reportGroup: AVContentKeyReportGroup?) {
        contentProtectionSessionIdentifierDidChange(session, reportGroup: reportGroup)
    }

    @objc(contentKeySession:contentProtectionSessionIdentifierDidChangeForReportGroup:)
    func contentProtectionSessionIdentifierDidChange(_ session: AVContentKeySession, reportGroup: AVContentKeyReportGroup?) {
        let group = reportGroup.map { ObjectIdentifier($0) }
        let sessionIdentifier = reportGroup?.contentProtectionSessionIdentifier
        MainActor.assumeIsolated {
            client?.groupSessionIdentifierChanged(group, sessionIdentifier)
        }
    }
    #endif

    #if HAVE_AVCONTENTKEY_EXTERNALCONTENTPROTECTIONSTATUS
    func contentKeySession(_ session: AVContentKeySession, externalProtectionStatusDidChangeFor contentKey: AVContentKey) {
        MainActor.assumeIsolated {
            client?.externalProtectionStatusDidChange(for: contentKey)
        }
    }
    #endif

    // FIXME (118150407): Once -[AVContentKey externalContentProtectionStatus] is available in SDKs used by WebKit
    // builders, only implement this optional delegate method when !HAVE(AVCONTENTKEY_EXTERNALCONTENTPROTECTIONSTATUS)
    @objc(contentKeySession:externalProtectionStatusDidChangeForContentKeyRequest:)
    func externalProtectionStatusDidChange(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest) {
        MainActor.assumeIsolated {
            client?.externalProtectionStatusDidChange(for: keyRequest)
        }
    }
}

// MARK: Built-in key group

// FIXME (116158267): This can be merged into FairPlaySession once we no longer need to support a configuration where
// the BuiltInCDMKeyGroupingStrategyEnabled preference is off.
//
// A session's key group when the key grouping strategy is the built-in one: it tracks the session's keys itself.
@MainActor
private final class FairPlayBuiltInKeyGroup: NSObject {
    private weak var contentKeySession: AVContentKeySession?
    private weak var dataSource: FairPlaySession?
    private let groupIdentifier = UUID()

    init(contentKeySession: AVContentKeySession, dataSource: FairPlaySession) {
        self.contentKeySession = contentKeySession
        self.dataSource = dataSource
        super.init()
        dataSource.log(.Info, "initWithContentKeySession:dataSource:", "groupIdentifier=\(groupIdentifier)")
    }

    var contentProtectionSessionIdentifier: Data {
        let bytes = groupIdentifier.uuid
        return Data([
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15,
        ])
    }

    // The data source tracks unexpected key requests and includes them in its keys, so there's no need to do any
    // explicit association here.
    func associate(_ request: AVContentKeyRequest) {
        dataSource?.log(.Info, "associateContentKeyRequest:", "contentKeyRequest=\(request.description)")
    }

    func expire() {
        #if HAVE_AVCONTENTKEY_REVOKE
        guard let dataSource else {
            return
        }
        var count = 0
        dataSource.forEachContentKey { _ in count += 1 }
        dataSource.log(.Info, "expire", "keys=\(count)")
        if #available(macOS 14.4, iOS 17.4, tvOS 17.4, watchOS 10.4, visionOS 1.1, *) {
            dataSource.forEachContentKey { key in
                // FIXME (117803793): Remove staging code once -[AVContentKey revoke] is available in SDKs used by
                // WebKit builders
                if key.responds(to: #selector(AVContentKey.revoke)) {
                    key.revoke()
                }
            }
        }
        #endif
    }

    func processContentKeyRequest(identifier: (any Sendable)?, initializationData: Data?, options: [Swift.String: any Sendable]?) {
        dataSource?.log(
            .Info,
            "processContentKeyRequestWithIdentifier:initializationData:options:",
            "\(identifier.map { "\($0)" } ?? "(null)"), initializationData=\(initializationData.map { "\($0)" } ?? "(null)"), options=\(options.map { "\($0)" } ?? "(null)")"
        )
        contentKeySession?.processContentKeyRequest(withIdentifier: identifier, initializationData: initializationData, options: options)
    }
}

// MARK: Instance

private struct FairPlayWeakInstance {
    weak var instance: FairPlayInstance?
}

private struct FairPlayWeakSession {
    weak var session: FairPlaySession?
}

@_spi(WebKitGPU)
@MainActor
public final class FairPlayInstance: FairPlayContentKeySessionClient {
    // The instances by token, which C++ hands out for the C++ CDMInstance that owns each (fairPlayInstanceToken()).
    private static var instancesByToken: [UInt64: FairPlayWeakInstance] = [:]
    private static var lastToken: UInt64 = 0

    @_spi(WebKitGPU) public static func instance(forToken token: UInt64) -> FairPlayInstance? {
        instancesByToken[token]?.instance
    }

    let token: UInt64
    let host: WebCore.FairPlayInstanceHost
    let mediaKeysHashSalt: Swift.String
    let supportsPersistableState: Bool
    let supportsPersistentKeys: Bool

    private(set) var serverCertificate: Data?
    private(set) var persistentStateAllowed = true
    private(set) var storageURL: Foundation.URL?

    private var keySession: AVContentKeySession?
    private var delegate: FairPlayContentKeySessionDelegate?
    private var sessions: [FairPlayWeakSession] = []
    private var unexpectedKeyRequests: [FairPlayKeyRequest] = []

    init(host: sending WebCore.FairPlayInstanceHost, mediaKeysHashSalt: Swift.String, supportsPersistableState: Bool, supportsPersistentKeys: Bool) {
        Self.lastToken += 1
        token = Self.lastToken
        self.host = host
        self.mediaKeysHashSalt = mediaKeysHashSalt
        self.supportsPersistableState = supportsPersistableState
        self.supportsPersistentKeys = supportsPersistentKeys
        Self.instancesByToken = Self.instancesByToken.filter { $0.value.instance != nil }
        Self.instancesByToken[token] = FairPlayWeakInstance(instance: self)
    }

    func log(_ level: WebCore.FairPlayLogLevel, _ method: Swift.String, _ message: Swift.String) {
        host.log(level, utf8(method).span, utf8(message).span)
    }

    private var liveSessions: [FairPlaySession] {
        sessions.compactMap(\.session)
    }

    func initialize(
        distinctiveIdentifierRequired: Bool,
        persistentStateRequired: Bool,
        sessionTypesIncludePersistentState: Bool,
        sessionTypesIncludePersistentLicense: Bool,
        allowsPersistentState: Bool
    ) -> Bool {
        // FIXME: verify that FairPlayStreaming does not (and cannot) expose a distinctive identifier to the client
        if distinctiveIdentifierRequired {
            return false
        }
        if !persistentStateRequired && sessionTypesIncludePersistentState {
            return false
        }
        if persistentStateRequired && storageURL == nil {
            return false
        }
        if sessionTypesIncludePersistentLicense && !supportsPersistentKeys {
            return false
        }
        if !PAL.canLoad_AVFoundation_AVContentKeySystemFairPlayStreaming() {
            return false
        }
        persistentStateAllowed = allowsPersistentState
        return true
    }

    @_spi(WebKitGPU) public func setServerCertificate(_ certificate: Data) {
        serverCertificate = certificate
    }

    func setStoragePath(_ path: Swift.String) {
        storageURL = path.isEmpty ? nil : Foundation.URL(fileURLWithPath: path, isDirectory: false)
    }

    func contentKeySession() -> AVContentKeySession? {
        if let keySession {
            return keySession
        }
        guard let newSession = PAL.makeFairPlayStreamingContentKeySession(persistentStateAllowed ? storageURL : nil) else {
            return nil
        }
        keySession = newSession
        let delegate = delegate ?? FairPlayContentKeySessionDelegate(client: self)
        self.delegate = delegate
        newSession.setDelegate(delegate, queue: DispatchQueue.main)
        return newSession
    }

    @_spi(WebKitGPU) public func makeSession(host: any FairPlaySessionHosting) -> FairPlaySession {
        let session = FairPlaySession(instance: self, host: host)
        sessions.removeAll { $0.session == nil }
        sessions.append(FairPlayWeakSession(session: session))
        return session
    }

    func takeUnexpectedKeyRequest(initDataType: Swift.String, initData: ContiguousArray<UInt8>) -> AVContentKeyRequest? {
        guard let index = unexpectedKeyRequests.firstIndex(where: {
            sameName(initType(for: $0.request), initDataType) && initializationData(for: $0.request) == initData
        }) else {
            return nil
        }
        return unexpectedKeyRequests.remove(at: index).request
    }

    func didProvide(_ request: AVContentKeyRequest) {
        if let session = session(for: request) {
            session.didProvide(request)
            return
        }
        log(.Always, "didProvideRequest", "- Unexpected request")
        handleUnexpectedRequests([FairPlayKeyRequest(request)])
    }

    func didProvide(_ requests: [FairPlayKeyRequest]) {
        guard let first = requests.first else {
            return
        }
        if let session = session(for: first.request) {
            session.didProvide(requests)
            return
        }
        handleUnexpectedRequests(requests)
    }

    private func handleUnexpectedRequests(_ requests: [FairPlayKeyRequest]) {
        var requests = requests
        while let request = requests.popLast() {
            if !unexpectedKeyRequests.contains(where: { $0.request === request.request }) {
                unexpectedKeyRequests.append(request)
            }
            host.unrequestedInitializationDataReceived(
                utf8(initType(for: request.request)).span,
                initializationData(for: request.request).span
            )
        }
    }

    private func forResponsibleSession(of request: AVContentKeyRequest, _ method: Swift.String, _ body: (FairPlaySession) -> Void) {
        guard let session = session(for: request) else {
            log(.Error, method, "- no responsible session; dropping")
            assertionFailure()
            return
        }
        body(session)
    }

    func didProvideRenewing(_ request: AVContentKeyRequest) {
        forResponsibleSession(of: request, "didProvideRenewingRequest") { $0.didProvideRenewing(request) }
    }

    func didProvidePersistable(_ request: AVContentKeyRequest) {
        forResponsibleSession(of: request, "didProvidePersistableRequest") { $0.didProvidePersistable(request) }
    }

    func didFail(_ request: AVContentKeyRequest, _ error: NSError) {
        forResponsibleSession(of: request, "didFailToProvideRequest") { $0.didFail(request, error) }
    }

    func didSucceed(_ request: AVContentKeyRequest) {
        forResponsibleSession(of: request, "requestDidSucceed") { $0.didSucceed(request) }
    }

    func shouldRetry(_ request: AVContentKeyRequest) -> Bool {
        guard let session = session(for: request) else {
            log(.Error, "shouldRetryRequestForReason", "- no responsible session; dropping")
            assertionFailure()
            return false
        }
        return session.shouldRetry(request)
    }

    // No-op. If we are getting this callback, there are outstanding AVContentKeyRequestGroups which are managing their
    // own session identifiers.
    func sessionIdentifierChanged(_ sessionIdentifier: Data?) {
    }

    func groupSessionIdentifierChanged(_ group: ObjectIdentifier?, _ sessionIdentifier: Data?) {
        #if HAVE_AVCONTENTKEYREPORTGROUP
        if group == keySession?.defaultContentKeyGroup.map({ ObjectIdentifier($0) }) {
            log(.Info, "groupSessionIdentifierChanged", "- default unused group identifier changed; dropping")
            return
        }
        guard let session = session(forGroup: group) else {
            log(.Error, "groupSessionIdentifierChanged", "- no responsible session; dropping")
            assertionFailure()
            return
        }
        session.groupSessionIdentifierChanged(group, sessionIdentifier)
        #endif
    }

    func outputObscuredDueToInsufficientExternalProtectionChanged(_ obscured: Bool) {
        for session in liveSessions {
            session.outputObscuredDueToInsufficientExternalProtectionChanged(obscured)
        }
    }

    func externalProtectionStatusDidChange(for key: AVContentKey) {
        guard let session = liveSessions.first(where: { $0.hasKey(key) }) else {
            log(.Error, "externalProtectionStatusDidChangeForContentKey", "- no responsible session; dropping")
            return
        }
        session.externalProtectionStatusDidChange(for: key)
    }

    func externalProtectionStatusDidChange(for request: AVContentKeyRequest) {
        forResponsibleSession(of: request, "externalProtectionStatusDidChangeForContentKeyRequest") {
            $0.externalProtectionStatusDidChange(for: request)
        }
    }

    // The content key to attach to a sample with these key IDs.
    func contentKey(forSampleKeyIDs bytes: Span<UInt8>, _ sizes: Span<UInt32>) -> AVContentKey? {
        if sizes.isEmpty {
            return nil
        }
        guard let session = session(forKeyIDs: bytes, sizes) else {
            log(.Error, "attachContentKeyToSample", "- no responsible session; dropping")
            assertionFailure()
            return nil
        }
        return session.contentKey(forSampleKeyIDs: bytes, sizes)
    }

    func session(forKeyIDs bytes: Span<UInt8>, _ sizes: Span<UInt32>) -> FairPlaySession? {
        for weakSession in sessions {
            if let session = weakSession.session, session.hasAnyKeyID(bytes, sizes) {
                return session
            }
        }
        return nil
    }

    private func session(for request: AVContentKeyRequest) -> FairPlaySession? {
        if let session = liveSessions.first(where: { $0.hasRequest(request) }) {
            return session
        }
        return session(forGroup: groupObject(for: request).map { ObjectIdentifier($0) })
    }

    private func session(forGroup group: ObjectIdentifier?) -> FairPlaySession? {
        liveSessions.first { $0.groupIdentifier == group }
    }

    func isAnyKeyUsable(_ bytes: Span<UInt8>, _ sizes: Span<UInt32>) -> Bool {
        for weakSession in sessions {
            if let session = weakSession.session, session.isAnyKeyUsable(bytes, sizes) {
                return true
            }
        }
        return false
    }

    func sessionKeyStatusesChanged() {
        host.keyStatusesChanged()
    }
}

// MARK: Session

// Collects the responses to a 'cenc' license update, one per request.
@MainActor
private final class FairPlayUpdateResponseCollector {
    private var numberOfExpectedResponses: Int
    private var responseCount = 0
    private let callback: (Bool) -> Void

    // callback's argument is whether there are responses; it isn't called if the collector fails first.
    init(numberOfExpectedResponses: Int, callback: @escaping (Bool) -> Void) {
        self.numberOfExpectedResponses = numberOfExpectedResponses
        self.callback = callback
    }

    func addResponse(_ request: AVContentKeyRequest) {
        responseCount += 1
        numberOfExpectedResponses -= 1
        if numberOfExpectedResponses == 0 {
            callback(responseCount > 0)
        }
    }

    func fail() {
        callback(false)
    }
}

// Collects the data of the requests of a 'cenc' license request, and hands it over on the main queue once the last
// AVFoundation completion handler that holds it has gone.
@MainActor
private final class FairPlayRequestDataAggregator {
    typealias RequestsData = [(keyID: FairPlayKeyID, data: Data?)]

    private var requestsData: RequestsData = []
    private let completionHandler: @MainActor @Sendable (RequestsData) -> Void

    init(completionHandler: @escaping @MainActor @Sendable (RequestsData) -> Void) {
        self.completionHandler = completionHandler
    }

    func append(_ keyID: FairPlayKeyID, _ data: Data?) {
        requestsData.append((keyID, data))
    }

    nonisolated deinit {
        let completionHandler = completionHandler
        let requestsData = requestsData
        DispatchQueue.main.async {
            completionHandler(requestsData)
        }
    }
}

@_spi(WebKitGPU)
@frozen public enum FairPlayLoadSessionResult: Sendable {
    case notHandled
    case succeeded(releasedKeyCount: Int)
    case mismatchedSessionType
    case noSessionData
}

@_spi(WebKitGPU)
public struct FairPlayRemoveSessionDataResult: Sendable {
    @_spi(WebKitGPU) public var releasedKeyCount = 0
    @_spi(WebKitGPU) public var message: Data?
    @_spi(WebKitGPU) public var succeeded = false
}

@_spi(WebKitGPU)
@frozen public enum FairPlaySessionLogLevel: Sendable {
    case always
    case error
    case info
}

// What a FairPlay session tells the client of its CDM session: in C++, the CDMInstanceSessionClient behind the session's
// FairPlaySessionHost; in the GPU process, its Swift CDM receiver. A key status list is the key IDs back to back, their
// sizes, and the raw value of a CDMKeyStatus for each.
@_spi(WebKitGPU)
public protocol FairPlaySessionHosting: AnyObject {
    var hasSessionClient: Bool { get }
    func sendSessionMessage(_ type: WebCore.CDMMessageType, _ message: Span<UInt8>)
    func sessionIdentifierChanged(_ sessionId: Swift.String)
    func sessionKeyStatusesChanged(_ keyIDs: Span<UInt8>, _ keyIDSizes: Span<UInt32>, _ statuses: Span<UInt8>)
    func logFromSession(_ level: FairPlaySessionLogLevel, _ method: Swift.String, _ message: Swift.String)
}

// How a session's license request completes: nil sessionId if the session has no identifier.
@_spi(WebKitGPU)
public protocol FairPlayLicenseRequestCompleting: AnyObject {
    func completeLicenseRequest(_ message: Span<UInt8>, _ sessionId: Swift.String?, _ succeeded: Bool)
}

// How a session's license update completes. Key statuses are listed as FairPlaySessionHosting lists them.
@_spi(WebKitGPU)
public protocol FairPlayLicenseUpdateCompleting: AnyObject {
    func failLicenseUpdate(sessionWasClosed: Bool)
    func succeedLicenseUpdate()
    func succeedLicenseUpdate(keyIDs: Span<UInt8>, keyIDSizes: Span<UInt32>, statuses: Span<UInt8>)
    func succeedLicenseUpdate(messageType: WebCore.CDMMessageType, message: Span<UInt8>)
}

private extension FairPlaySessionLogLevel {
    init(_ level: WebCore.FairPlayLogLevel) {
        switch level {
        case .Always:
            self = .always
        case .Error:
            self = .error
        case .Info:
            self = .info
        @unknown default:
            self = .info
        }
    }
}

private extension WebCore.FairPlayLogLevel {
    init(_ level: FairPlaySessionLogLevel) {
        switch level {
        case .always:
            self = .Always
        case .error:
            self = .Error
        case .info:
            self = .Info
        }
    }
}

// The C++ session's host and completions, as the session takes them.
private final class FairPlayCxxSessionHost: FairPlaySessionHosting {
    private let host: WebCore.FairPlaySessionHost

    init(_ host: WebCore.FairPlaySessionHost) {
        self.host = host
    }

    var hasSessionClient: Bool {
        host.hasClient()
    }

    func sendSessionMessage(_ type: WebCore.CDMMessageType, _ message: Span<UInt8>) {
        host.sendMessage(type, message)
    }

    func sessionIdentifierChanged(_ sessionId: Swift.String) {
        host.sessionIdChanged(utf8(sessionId).span)
    }

    func sessionKeyStatusesChanged(_ keyIDs: Span<UInt8>, _ keyIDSizes: Span<UInt32>, _ statuses: Span<UInt8>) {
        host.updateKeyStatuses(keyIDs, keyIDSizes, statuses)
    }

    func logFromSession(_ level: FairPlaySessionLogLevel, _ method: Swift.String, _ message: Swift.String) {
        host.log(WebCore.FairPlayLogLevel(level), utf8(method).span, utf8(message).span)
    }
}

private final class FairPlayCxxLicenseRequestCompletion: FairPlayLicenseRequestCompleting {
    private let completion: WebCore.FairPlayLicenseCompletion

    init(_ completion: WebCore.FairPlayLicenseCompletion) {
        self.completion = completion
    }

    func completeLicenseRequest(_ message: Span<UInt8>, _ sessionId: Swift.String?, _ succeeded: Bool) {
        completion.complete(message, sessionId != nil, utf8(sessionId ?? "").span, succeeded)
    }
}

private final class FairPlayCxxLicenseUpdateCompletion: FairPlayLicenseUpdateCompleting {
    private let completion: WebCore.FairPlayLicenseUpdateCompletion

    init(_ completion: WebCore.FairPlayLicenseUpdateCompletion) {
        self.completion = completion
    }

    func failLicenseUpdate(sessionWasClosed: Bool) {
        completion.fail(sessionWasClosed)
    }

    func succeedLicenseUpdate() {
        completion.succeed()
    }

    func succeedLicenseUpdate(keyIDs: Span<UInt8>, keyIDSizes: Span<UInt32>, statuses: Span<UInt8>) {
        completion.succeedWithKeyStatuses(keyIDs, keyIDSizes, statuses)
    }

    func succeedLicenseUpdate(messageType: WebCore.CDMMessageType, message: Span<UInt8>) {
        completion.succeedWithMessage(messageType, message)
    }
}

@_spi(WebKitGPU)
@MainActor
public final class FairPlaySession: FairPlayContentKeySessionClient {
    let instance: FairPlayInstance
    let host: any FairPlaySessionHosting

    #if HAVE_AVCONTENTKEYREPORTGROUP
    private var reportGroup: AVContentKeyReportGroup?
    #endif
    private var builtInGroup: FairPlayBuiltInKeyGroup?
    private var ownSession: AVContentKeySession?
    private var delegate: FairPlayContentKeySessionDelegate?
    private var currentRequest: FairPlayRequestGroup?
    private var expiredSessions: [Data] = []
    // nil until the session has an identifier, as WTF's null string.
    private var sessionId: Swift.String?
    private var outputObscured = false
    private var updateResponseCollector: FairPlayUpdateResponseCollector?
    private(set) var keyStatuses: [FairPlayKeyStatus] = []
    private var pendingRequests: [FairPlayRequestGroup] = []
    private var requests: [FairPlayRequestGroup] = []
    private var renewingRequest: FairPlayRequestGroup?
    private var requestLicenseCallback: (any FairPlayLicenseRequestCompleting)?
    private var updateLicenseCallback: (any FairPlayLicenseUpdateCompleting)?

    init(instance: FairPlayInstance, host: any FairPlaySessionHosting) {
        self.instance = instance
        self.host = host
    }

    func log(_ level: WebCore.FairPlayLogLevel, _ method: Swift.String, _ message: Swift.String) {
        host.logFromSession(FairPlaySessionLogLevel(level), method, message)
    }

    // MARK: Groups

    var groupObject: AnyObject? {
        #if HAVE_AVCONTENTKEYREPORTGROUP
        if let reportGroup {
            return reportGroup
        }
        #endif
        return builtInGroup
    }

    // Groups are compared by identity: the report group, which is SPI, isn't Sendable in every SDK.
    var groupIdentifier: ObjectIdentifier? {
        groupObject.map { ObjectIdentifier($0) }
    }

    private var groupContentProtectionSessionIdentifier: Data? {
        #if HAVE_AVCONTENTKEYREPORTGROUP
        if let reportGroup {
            return reportGroup.contentProtectionSessionIdentifier
        }
        #endif
        return builtInGroup?.contentProtectionSessionIdentifier
    }

    private func associateWithGroup(_ request: AVContentKeyRequest) {
        #if HAVE_AVCONTENTKEYREPORTGROUP
        reportGroup?.associateContentKeyRequest(request)
        #endif
        builtInGroup?.associate(request)
    }

    // The group goes in the request's options, where groupObject(for:) finds it.
    private func processContentKeyRequestInGroup(identifier: Swift.String?, initializationData: Data?, initDataType: Swift.String) {
        #if HAVE_AVCONTENTKEYREPORTGROUP
        if let reportGroup {
            let group: AnyObject = reportGroup
            let options: [Swift.String: Any] = [contentKeyReportGroupKey: group, initializationDataTypeKey: initDataType]
            reportGroup.processContentKeyRequest(withIdentifier: identifier, initializationData: initializationData, options: options)
            return
        }
        #endif
        if let builtInGroup {
            let options: [Swift.String: any Sendable] = [contentKeyReportGroupKey: builtInGroup, initializationDataTypeKey: initDataType]
            builtInGroup.processContentKeyRequest(identifier: identifier, initializationData: initializationData, options: options)
        }
    }

    private func expireGroup() {
        #if HAVE_AVCONTENTKEYREPORTGROUP
        if let reportGroup {
            reportGroup.expire()
            return
        }
        #endif
        builtInGroup?.expire()
    }

    // MARK: Keys and requests

    private var contentKeyRequests: [FairPlayKeyRequest] {
        requests.flatMap(\.requests)
    }

    func forEachContentKey(_ body: (AVContentKey) -> Void) {
        for request in contentKeyRequests {
            if let key = request.request.contentKey {
                body(key)
            }
        }
    }

    func hasKey(_ key: AVContentKey) -> Bool {
        contentKeyRequests.contains { $0.request.contentKey === key }
    }

    func hasRequest(_ request: AVContentKeyRequest) -> Bool {
        contentKeyRequests.contains { $0.request === request }
    }

    private var lastKeyRequest: AVContentKeyRequest? {
        requests.last?.requests.last?.request
    }

    private func contentKeySession() -> AVContentKeySession? {
        ownSession ?? instance.contentKeySession()
    }

    func hasAnyKeyID(_ bytes: Span<UInt8>, _ sizes: Span<UInt32>) -> Bool {
        for group in requests {
            for request in group.requests {
                for keyID in request.keyIDs where keyIDList(bytes, sizes, includes: keyID) {
                    return true
                }
            }
        }
        return false
    }

    func isAnyKeyUsable(_ bytes: Span<UInt8>, _ sizes: Span<UInt32>) -> Bool {
        for status in keyStatuses where isPotentiallyUsable(status.status) && keyIDList(bytes, sizes, includes: status.keyID) {
            return true
        }
        return false
    }

    func contentKey(forSampleKeyIDs bytes: Span<UInt8>, _ sizes: Span<UInt32>) -> AVContentKey? {
        for group in requests {
            for request in group.requests where isPotentiallyUsable(keyStatus(for: request.request.status)) {
                for keyID in request.keyIDs where keyIDList(bytes, sizes, includes: keyID) {
                    if let contentKey = request.request.contentKey {
                        return contentKey
                    }
                }
            }
        }
        assert(!isAnyKeyUsable(bytes, sizes))
        return nil
    }

    // MARK: Callbacks

    private func takeRequestLicenseCallback() -> (any FairPlayLicenseRequestCompleting)? {
        defer {
            requestLicenseCallback = nil
        }
        return requestLicenseCallback
    }

    private func takeUpdateLicenseCallback() -> (any FairPlayLicenseUpdateCompleting)? {
        defer {
            updateLicenseCallback = nil
        }
        return updateLicenseCallback
    }

    private func complete(_ callback: any FairPlayLicenseRequestCompleting, message: ContiguousArray<UInt8> = [], sessionId: Swift.String?, succeeded: Bool) {
        callback.completeLicenseRequest(message.span, sessionId, succeeded)
    }

    private func completeWithKeyStatuses(_ callback: any FairPlayLicenseUpdateCompleting, _ statuses: [FairPlayKeyStatus]) {
        withFlattenedKeyStatuses(statuses) { keyIDs, sizes, values in
            callback.succeedLicenseUpdate(keyIDs: keyIDs, keyIDSizes: sizes, statuses: values)
        }
    }

    private func sendKeyStatusesToClient() {
        withFlattenedKeyStatuses(keyStatuses) { keyIDs, sizes, values in
            host.sessionKeyStatusesChanged(keyIDs, sizes, values)
        }
    }

    // MARK: CDMInstanceSession

    @_spi(WebKitGPU) public func requestLicense(
        _ licenseType: WebCore.CDMSessionType,
        builtInKeyGrouping: Bool,
        initDataType: Swift.String,
        initData: ContiguousArray<UInt8>,
        callback: any FairPlayLicenseRequestCompleting
    ) {
        if !isLicenseTypeSupported(licenseType) {
            log(.Error, "requestLicense", " false, licenseType \"\(sessionTypeName(licenseType))\" not supported")
            complete(callback, sessionId: "", succeeded: false)
            return
        }
        if instance.serverCertificate == nil {
            log(.Error, "requestLicense", " false, no serverCertificate")
            complete(callback, sessionId: "", succeeded: false)
            return
        }
        if !ensureSessionOrGroup(builtInKeyGrouping: builtInKeyGrouping) {
            log(.Error, "requestLicense", " false, could not create session or group object")
            complete(callback, sessionId: "", succeeded: false)
            return
        }

        if let unexpectedRequest = instance.takeUnexpectedKeyRequest(initDataType: initDataType, initData: initData) {
            log(.Always, "requestLicense", " found unexpectedRequest matching initData")
            associateWithGroup(unexpectedRequest)
            requestLicenseCallback = callback
            didProvide(unexpectedRequest)
            return
        }

        var identifier: Swift.String?
        var initializationData: Data?
        switch requestInitializationData(initDataType: initDataType, initData: initData) {
        case .identifier(let requestIdentifier):
            identifier = requestIdentifier
        case .initializationData(let data):
            initializationData = data
        case .noFairPlayPssh:
            log(.Error, "requestLicense", " no FairPlay PSSH in cenc init data")
            complete(callback, sessionId: "", succeeded: false)
            return
        case .unsupported:
            log(.Error, "requestLicense", " false, initDataType not suppported")
            complete(callback, sessionId: "", succeeded: false)
            return
        }

        log(.Always, "requestLicense", " processing request")
        requestLicenseCallback = callback

        if groupObject != nil {
            processContentKeyRequestInGroup(identifier: identifier, initializationData: initializationData, initDataType: initDataType)
            return
        }

        ownSession?.processContentKeyRequest(
            withIdentifier: identifier,
            initializationData: initializationData,
            options: [initializationDataTypeKey: initDataType]
        )
    }

    private enum RequestInitializationData {
        case identifier(Swift.String?)
        case initializationData(Data?)
        case noFairPlayPssh
        case unsupported
    }

    private func requestInitializationData(initDataType: Swift.String, initData: ContiguousArray<UInt8>) -> RequestInitializationData {
        if sameName(initDataType, FairPlayInitTypeName.sinf) {
            return .initializationData(Data(initData))
        }
        if sameName(initDataType, FairPlayInitTypeName.skd) {
            return .identifier(Swift.String(data: Data(initData), encoding: .utf8))
        }
        #if HAVE_FAIRPLAYSTREAMING_CENC_INITDATA
        if sameName(initDataType, FairPlayInitTypeName.cenc) {
            // AVFoundation's FairPlay PSSH parser only reads the first PSSH atom in the supplied data and rejects the
            // entire blob if its SystemID is not FairPlay's (rdar://179255226). Filter the cenc init data down to the
            // FairPlay PSSH alone before forwarding to AVContentKeySession.
            guard let range = InitDataParsing.fairPlayPsshRange(initData.span) else {
                return .noFairPlayPssh
            }
            let pssh = WTFBase64.encode(initData.span.extracting(range))
            let psshString = Swift.String(decoding: pssh, as: Unicode.UTF8.self)
            return .initializationData(try? JSONSerialization.data(withJSONObject: ["pssh": psshString], options: .prettyPrinted))
        }
        #endif
        #if HAVE_FAIRPLAYSTREAMING_MTPS_INITDATA
        if sameName(initDataType, FairPlayInitTypeName.mpts) {
            return .initializationData(Data(initData))
        }
        #endif
        return .unsupported
    }

    @_spi(WebKitGPU) public func updateLicense(_ responseData: ContiguousArray<UInt8>, callback: any FairPlayLicenseUpdateCompleting) {
        if !expiredSessions.isEmpty && isText(responseData, "acknowledged") {
            guard let certificate = instance.serverCertificate, let storageURL = instance.storageURL else {
                log(.Error, "updateLicense", "\"acknowledged\", Failed, no certificate and storageURL")
                callback.failLicenseUpdate(sessionWasClosed: false)
                return
            }
            log(.Error, "updateLicense", "\"acknowledged\", Succeeded, removing expired session report")
            PAL.removePendingExpiredSessionReports(expiredSessions, certificate, storageURL)
            callback.succeedLicenseUpdate()
            return
        }

        if !requests.isEmpty && isText(responseData, "renew") {
            guard let request = lastKeyRequest else {
                log(.Error, "updateLicense", "\"renew\", Failed, no outstanding keys")
                callback.failLicenseUpdate(sessionWasClosed: false)
                return
            }
            renewingRequest = requests.last
            log(.Always, "updateLicense", "\"renew\", processing renewal")
            contentKeySession()?.renewExpiringResponseData(for: request)
            updateLicenseCallback = callback
            return
        }

        guard let currentRequest else {
            log(.Error, "updateLicense", " Failed, no currentRequest")
            callback.failLicenseUpdate(sessionWasClosed: false)
            return
        }
        let keyIDs = currentRequest.keyIDs
        if keyIDs.isEmpty {
            log(.Error, "updateLicense", " Failed, no keyIDs in currentRequest")
            callback.failLicenseUpdate(sessionWasClosed: false)
            return
        }

        if sameName(currentRequest.initType, FairPlayInitTypeName.cenc) {
            updateResponseCollector?.fail()
            updateResponseCollector = nil
            updateResponseCollector = FairPlayUpdateResponseCollector(numberOfExpectedResponses: currentRequest.requests.count) { [weak self] hasResponses in
                self?.didCollectUpdateResponses(hasResponses)
            }

            guard let entries = FairPlayJSON.cencResponse(responseData.span) else {
                callback.failLicenseUpdate(sessionWasClosed: false)
                return
            }
            for entry in entries {
                if !processCencResponseEntry(entry, of: currentRequest) {
                    log(.Error, "updateLicense", "'cenc' initData, Failed, could not parse response")
                    callback.failLicenseUpdate(sessionWasClosed: false)
                    return
                }
            }
        } else {
            log(.Always, "updateLicense", "'sinf' initData, processing response")
            currentRequest.requests.first?.request.processContentKeyResponse(
                PAL.makeFairPlayStreamingContentKeyResponse(Data(responseData))
            )
        }

        // FIXME(rdar://problem/35592277): stash the callback and call it once AVContentKeyResponse supports a success
        // callback. Every supported AVContentKeySessionDelegate has -contentKeySession:contentKeyRequestDidSucceed:.
        updateLicenseCallback = callback
    }

    private func didCollectUpdateResponses(_ hasResponses: Bool) {
        guard let callback = updateLicenseCallback else {
            return
        }
        if !hasResponses {
            log(.Error, "updateLicense", "'cenc' initData, Failed, no responses")
            updateLicenseCallback = nil
            callback.failLicenseUpdate(sessionWasClosed: true)
            return
        }
        log(.Always, "updateLicense", "'cenc' initData, Succeeded, no keyIDs in currentRequest")
        updateLicenseCallback = nil
        completeWithKeyStatuses(callback, keyStatuses)
        updateResponseCollector = nil
        currentRequest = nil
        nextRequest()
    }

    private func processCencResponseEntry(_ entry: FairPlayJSON.CencResponseEntry, of currentRequest: FairPlayRequestGroup) -> Bool {
        let keyID: ContiguousArray<UInt8>
        switch entry {
        case .noKeyID:
            return false
        case .keyIDOnly(let entryKeyID), .payload(let entryKeyID, _), .error(let entryKeyID, _):
            keyID = entryKeyID
        }
        guard let request = currentRequest.requests.first(where: { $0.keyIDs.contains(keyID) })?.request else {
            return false
        }
        switch entry {
        case .noKeyID, .keyIDOnly:
            return false
        case .payload(_, let payload):
            request.processContentKeyResponse(PAL.makeFairPlayStreamingContentKeyResponse(Data(payload)))
        case .error(_, let code):
            request.processContentKeyResponseError(NSError(domain: "org.webkit.eme", code: Int(code), userInfo: nil))
        }
        return true
    }

    @_spi(WebKitGPU) public func loadSession(_ licenseType: WebCore.CDMSessionType, sessionId requestedSessionId: Swift.String) -> FairPlayLoadSessionResult {
        guard licenseType == .PersistentUsageRecord else {
            return .notHandled
        }
        guard instance.persistentStateAllowed, let storageURL = instance.storageURL else {
            log(.Error, "loadSession", " Failed, mismatched session type")
            return .mismatchedSessionType
        }
        guard let certificate = instance.serverCertificate else {
            log(.Error, "loadSession", " Failed, no sessionCertificate")
            return .noSessionData
        }

        var releasedKeyCount = 0
        for expiredSessionData in PAL.pendingExpiredSessionReports(certificate, storageURL) {
            guard let expiredSession = expiredSessionReport(expiredSessionData),
                let playbackSessionId = expiredSession["PlaybackSessionID"] as? NSString,
                sameName(requestedSessionId, playbackSessionId as Swift.String)
            else {
                continue
            }
            // FIXME(rdar://problem/35934922): use key values stored in expired session report once available
            releasedKeyCount += 1
            expiredSessions.append(expiredSessionData)
        }

        if releasedKeyCount == 0 {
            log(.Error, "loadSession", " Failed, no session data found")
            return .noSessionData
        }
        log(.Always, "loadSession", " Succeeded")
        return .succeeded(releasedKeyCount: releasedKeyCount)
    }

    private func expiredSessionReport(_ data: Data) -> NSDictionary? {
        // The format pointer is nil, which the function allows; nothing else is unsafe.
        let propertyList = try? unsafe PropertyListSerialization.propertyList(from: data, options: 0, format: nil)
        return propertyList as? NSDictionary
    }

    @_spi(WebKitGPU) public func closeSession() {
        log(.Always, "closeSession", "")
        if let callback = takeRequestLicenseCallback() {
            complete(callback, sessionId: sessionId, succeeded: false)
        }
        if let callback = takeUpdateLicenseCallback() {
            callback.failLicenseUpdate(sessionWasClosed: true)
        }
        currentRequest = nil
        pendingRequests = []
        requests = []
    }

    @_spi(WebKitGPU) public func removeSessionData(_ licenseType: WebCore.CDMSessionType, sessionId requestedSessionId: Swift.String) -> FairPlayRemoveSessionDataResult {
        if groupObject != nil {
            expireGroup()
        } else {
            ownSession?.expire()
        }

        guard licenseType == .PersistentUsageRecord else {
            return FairPlayRemoveSessionDataResult()
        }
        guard instance.persistentStateAllowed, let storageURL = instance.storageURL, let certificate = instance.serverCertificate else {
            log(.Error, "removeSessionData", " Failed, persistentState not allowed or no storageURL or no certificate")
            return FairPlayRemoveSessionDataResult()
        }

        var result = FairPlayRemoveSessionDataResult()
        var expiredSessionReports: [NSDictionary] = []
        for expiredSessionData in PAL.pendingExpiredSessionReports(certificate, storageURL) {
            guard let expiredSession = expiredSessionReport(expiredSessionData),
                let playbackSessionId = expiredSession["PlaybackSessionID"] as? NSString,
                sameName(requestedSessionId, playbackSessionId as Swift.String)
            else {
                continue
            }
            // FIXME(rdar://problem/35934922): use key values stored in expired session report once available
            result.releasedKeyCount += 1
            expiredSessions.append(expiredSessionData)
            expiredSessionReports.append(expiredSession)
        }

        result.succeeded = true
        if expiredSessionReports.isEmpty {
            log(.Always, "removeSessionData", " Succeeded, no expired sessions")
            return result
        }

        let propertyList: Any = expiredSessionReports.count == 1 ? expiredSessionReports[0] : expiredSessionReports
        result.message = (try? PropertyListSerialization.data(fromPropertyList: propertyList, format: .binary, options: 0)) ?? Data()

        if expiredSessionReports.count > 1 {
            log(
                .Error,
                "removeSessionData",
                "Multiple(\(expiredSessionReports.count)) expired session reports found with same sessionID(\(requestedSessionId))!"
            )
        }
        log(.Always, "removeSessionData", " Succeeded")
        return result
    }

    @_spi(WebKitGPU) public func displayChanged() {
        updateProtectionStatus()
    }

    // MARK: Content key session events

    func didProvide(_ request: AVContentKeyRequest) {
        let initDataType = initType(for: request)
        if initDataType.isEmpty {
            log(.Error, "didProvideRequest", "- request has empty initDataType")
            return
        }

        let keyRequest = FairPlayKeyRequest(request)
        let newRequest = FairPlayRequestGroup(initType: initDataType, requests: [keyRequest])
        if currentRequest != nil {
            pendingRequests.append(newRequest)
            return
        }

        log(.Always, "didProvideRequest", "")
        currentRequest = newRequest
        requests.append(newRequest)

        let appIdentifier = instance.serverCertificate
        guard let keyID = keyRequest.keyIDs.first else {
            if let callback = takeRequestLicenseCallback() {
                complete(callback, sessionId: sessionId, succeeded: false)
            }
            return
        }

        let exception = WebCore.makeFairPlayStreamingContentKeyRequestData(
            request,
            appIdentifier,
            Data(keyID),
            keyRequestOptions(hashSalt: instance.mediaKeysHashSalt)
        ) { [weak self] contentKeyRequestData, error in
            let failed = error != nil
            DispatchQueue.main.async {
                self?.didMakeRequestData(contentKeyRequestData, failed: failed)
            }
        }
        if let exception {
            log(.Error, "didProvideRequest", exceptionMessage(exception))
            if let callback = takeUpdateLicenseCallback() {
                callback.failLicenseUpdate(sessionWasClosed: false)
            }
        }
    }

    private func didMakeRequestData(_ contentKeyRequestData: Data?, failed: Bool) {
        if sessionId?.isEmpty ?? true {
            sessionIdentifierChanged(groupObject != nil ? groupContentProtectionSessionIdentifier : ownSession?.contentProtectionSessionIdentifier)
        }

        if failed, let callback = takeRequestLicenseCallback() {
            complete(callback, sessionId: sessionId, succeeded: false)
        } else if let callback = takeRequestLicenseCallback() {
            complete(callback, message: fairPlayBytes(contentKeyRequestData), sessionId: sessionId, succeeded: true)
        } else {
            host.sendSessionMessage(.LicenseRequest, fairPlayBytes(contentKeyRequestData).span)
        }
    }

    func didProvide(_ providedRequests: [FairPlayKeyRequest]) {
        guard let first = providedRequests.first else {
            return
        }

        let initDataType = initType(for: first.request)
        if !sameName(initDataType, FairPlayInitTypeName.cenc) {
            didProvide(first.request)
            for request in providedRequests.dropFirst() {
                pendingRequests.append(FairPlayRequestGroup(initType: initDataType, requests: [request]))
            }
            return
        }

        let newRequest = FairPlayRequestGroup(initType: initDataType, requests: providedRequests)
        if currentRequest != nil {
            pendingRequests.append(newRequest)
            return
        }

        log(.Always, "didProvideRequests", "")
        currentRequest = newRequest
        requests.append(newRequest)

        let appIdentifier = instance.serverCertificate
        let aggregator = FairPlayRequestDataAggregator { [weak self] requestsData in
            self?.didMakeCencRequestData(requestsData)
        }

        for request in providedRequests {
            guard let keyID = request.keyIDs.first else {
                continue
            }
            let exception = WebCore.makeFairPlayStreamingContentKeyRequestData(
                request.request,
                appIdentifier,
                Data(keyID),
                keyRequestOptions(hashSalt: instance.mediaKeysHashSalt)
            ) { contentKeyRequestData, _ in
                DispatchQueue.main.async {
                    aggregator.append(keyID, contentKeyRequestData)
                }
            }
            if let exception {
                log(.Error, "didProvideRequests", exceptionMessage(exception))
                if let callback = takeRequestLicenseCallback() {
                    complete(callback, sessionId: sessionId, succeeded: false)
                }
                return
            }
        }
    }

    private func didMakeCencRequestData(_ requestsData: FairPlayRequestDataAggregator.RequestsData) {
        guard let callback = takeRequestLicenseCallback() else {
            return
        }
        if requestsData.isEmpty {
            complete(callback, sessionId: sessionId, succeeded: false)
            return
        }
        var message = ContiguousArray<UInt8>()
        for (index, requestData) in requestsData.enumerated() {
            let payload = fairPlayBytes(requestData.data)
            FairPlayJSON.appendCencRequest(keyID: requestData.keyID.span, payload: payload.span, isFirst: index == 0, to: &message)
        }
        FairPlayJSON.endCencRequest(count: requestsData.count, to: &message)
        complete(callback, message: message, sessionId: sessionId, succeeded: true)
    }

    private func requestMatchesRenewingRequest(_ request: AVContentKeyRequest) -> Bool {
        guard let renewingRequest else {
            return false
        }
        let identifier = request.identifier as? NSObject
        return renewingRequest.requests.contains { renewing in
            (renewing.request.identifier as? NSObject)?.isEqual(identifier) ?? false
        }
    }

    func didProvideRenewing(_ request: AVContentKeyRequest) {
        assert(requestLicenseCallback == nil)
        let initDataType = initType(for: request)
        if initDataType.isEmpty {
            return
        }

        let newRequest = FairPlayRequestGroup(initType: initDataType, requests: [FairPlayKeyRequest(request)])
        if currentRequest != nil {
            pendingRequests.append(newRequest)
            return
        }

        log(.Always, "didProvideRenewingRequest", "")
        currentRequest = newRequest

        // The assumption here is that AVContentKeyRequest will only ever notify us of a renewing request as a result of
        // calling -renewExpiringResponseDataForContentKeyRequest: with an existing request.
        if !requestMatchesRenewingRequest(request) {
            log(.Error, "didProvideRenewingRequest", "failed to find renewing request matching identifier \(request.identifier.map { "\($0)" } ?? "(null)")")
            assertionFailure()
            return
        }
        guard let renewingRequest, let renewingIndex = requests.firstIndex(of: renewingRequest) else {
            log(.Error, "didProvideRenewingRequest", "failed to find renewing request index in requests")
            assertionFailure()
            return
        }

        let replacementIdentifier = request.contentKeySpecifier.identifier as? NSObject
        if let index = requests[renewingIndex].requests.firstIndex(where: {
            ($0.request.contentKeySpecifier.identifier as? NSObject)?.isEqual(replacementIdentifier) ?? false
        }) {
            requests[renewingIndex].requests[index] = FairPlayKeyRequest(request)
        }
        self.renewingRequest = nil

        let appIdentifier = instance.serverCertificate
        guard let keyID = newRequest.keyIDs.first else {
            log(.Error, "didProvideRenewingRequest", " Failed, no keyIDs in currentRequest")
            if let callback = takeUpdateLicenseCallback() {
                callback.failLicenseUpdate(sessionWasClosed: false)
            }
            return
        }

        let exception = WebCore.makeFairPlayStreamingContentKeyRequestData(
            request,
            appIdentifier,
            Data(keyID),
            keyRequestOptions(hashSalt: instance.mediaKeysHashSalt)
        ) { [weak self] contentKeyRequestData, error in
            let failed = error != nil
            DispatchQueue.main.async {
                self?.didMakeRenewingRequestData(contentKeyRequestData, failed: failed)
            }
        }
        if let exception {
            log(.Error, "didProvideRenewingRequest", exceptionMessage(exception))
            if let callback = takeUpdateLicenseCallback() {
                callback.failLicenseUpdate(sessionWasClosed: false)
            }
        }
    }

    private func didMakeRenewingRequestData(_ contentKeyRequestData: Data?, failed: Bool) {
        if !host.hasSessionClient || failed {
            return
        }
        if let callback = takeUpdateLicenseCallback() {
            callback.succeedLicenseUpdate(messageType: .LicenseRenewal, message: fairPlayBytes(contentKeyRequestData).span)
        } else {
            host.sendSessionMessage(.LicenseRenewal, fairPlayBytes(contentKeyRequestData).span)
        }
    }

    func didProvidePersistable(_ request: AVContentKeyRequest) {
    }

    func didFail(_ request: AVContentKeyRequest, _ error: NSError) {
        // Rather than reject the update() promise when the CDM indicates that the key requires a higher level of
        // security than it is currently able to provide, signal this state by "succeeding", but set the key status to
        // "output-restricted".
        log(.Error, "didFailToProvideRequest", "- error: \(error)")

        if error.code == securityLevelError {
            didSucceed(request)
            return
        }

        if let updateResponseCollector {
            updateResponseCollector.addResponse(request)
            return
        }

        if let callback = takeUpdateLicenseCallback() {
            callback.failLicenseUpdate(sessionWasClosed: false)
        }
        currentRequest = nil
        nextRequest()
    }

    func didSucceed(_ request: AVContentKeyRequest) {
        log(.Always, "requestDidSucceed", "")

        updateKeyStatuses()

        if let updateResponseCollector {
            updateResponseCollector.addResponse(request)
            return
        }

        if let callback = takeUpdateLicenseCallback() {
            completeWithKeyStatuses(callback, keyStatuses)
        }
        currentRequest = nil
        nextRequest()
    }

    private func nextRequest() {
        if pendingRequests.isEmpty {
            return
        }
        let next = pendingRequests.removeFirst()
        guard let first = next.requests.first else {
            return
        }
        if sameName(next.initType, FairPlayInitTypeName.cenc) {
            didProvide(next.requests)
            return
        }
        if first.request.renewsExpiringResponseData {
            didProvideRenewing(first.request)
        } else {
            didProvide(first.request)
        }
    }

    func shouldRetry(_ request: AVContentKeyRequest) -> Bool {
        false
    }

    func sessionIdentifierChanged(_ sessionIdentifier: Data?) {
        let newSessionId = sessionIdentifier.map(hexString) ?? ""
        if sessionId == newSessionId {
            return
        }
        sessionId = newSessionId
        host.sessionIdentifierChanged(newSessionId)
    }

    func groupSessionIdentifierChanged(_ group: ObjectIdentifier?, _ sessionIdentifier: Data?) {
        #if HAVE_AVCONTENTKEYREPORTGROUP
        sessionIdentifierChanged(sessionIdentifier)
        #endif
    }

    private func updateKeyStatuses() {
        var statuses: [FairPlayKeyStatus] = []
        for request in contentKeyRequests {
            var status = keyStatus(for: request.request.status)
            if (request.request.error as NSError?)?.code == securityLevelError {
                status = .OutputRestricted
            }
            if let protectionStatus = protectionStatus(for: request.request, keyIDs: request.keyIDs) {
                status = protectionStatus
            }
            for keyID in request.keyIDs {
                statuses.append(FairPlayKeyStatus(keyID: keyID, status: status))
            }
        }
        keyStatuses = statuses
        instance.sessionKeyStatusesChanged()
    }

    func outputObscuredDueToInsufficientExternalProtectionChanged(_ obscured: Bool) {
        if obscured == outputObscured {
            return
        }
        log(.Always, "outputObscuredDueToInsufficientExternalProtectionChanged", "\(obscured)")
        outputObscured = obscured
        updateKeyStatuses()
        sendKeyStatusesToClient()
    }

    func externalProtectionStatusDidChange(for key: AVContentKey) {
        updateProtectionStatus()
    }

    func externalProtectionStatusDidChange(for request: AVContentKeyRequest) {
        updateProtectionStatus()
    }

    private func protectionStatus(for request: AVContentKeyRequest, keyIDs: [FairPlayKeyID]) -> WebCore.CDMKeyStatus? {
        #if HAVE_AVCONTENTKEYREQUEST_PENDING_PROTECTION_STATUS
        #if HAVE_AVCONTENTKEY_EXTERNALCONTENTPROTECTIONSTATUS
        guard let contentKey = request.contentKey else {
            return nil
        }
        // FIXME (118150407): Remove staging code once -[AVContentKey externalContentProtectionStatus] is available in
        // SDKs used by WebKit builders
        if #available(macOS 14.4, iOS 17.4, tvOS 17.4, visionOS 1.1, *),
            contentKey.responds(to: #selector(getter: AVContentKey.externalContentProtectionStatus))
        {
            return keyStatus(for: contentKey.externalContentProtectionStatus)
        }
        #endif
        return keyStatus(for: request.externalContentProtectionStatus())
        #else
        #if HAVE_AVCONTENTKEYSESSIONWILLOUTPUTBEOBSCURED
        // FIXME: AVFoundation requires a connection to the WindowServer in order to query the HDCP status of individual
        // displays. Passing in an empty NSArray will cause AVFoundation to fall back to a "minimum supported HDCP level"
        // across all displays. Replace the below with explicit APIs to query the per-display HDCP status in the
        // UIProcess and to query the HDCP level required by each AVContentKeyRequest, and do the comparison between the
        // two in the WebProcess.
        if request.responds(to: #selector(AVContentKeyRequest.willOutputBeObscuredDueToInsufficientExternalProtection(forDisplays:))) {
            // willOutputBeObscuredDueToInsufficientExternalProtectionForDisplays will always return "YES" prior to
            // receiving a response.
            if request.status != .receivedResponse && request.status != .renewed {
                log(.Always, "protectionStatusForRequest", "request has insufficient status \(request.status.rawValue)")
                return nil
            }
            let obscured = request.willOutputBeObscuredDueToInsufficientExternalProtection(forDisplays: [])
            log(
                .Always,
                "protectionStatusForRequest",
                "request { \(keyIDs.map { hexString(Data($0)) }) } willOutputBeObscured...forDisplays:[ nil ] = \(obscured)"
            )
            return obscured ? .OutputRestricted : .Usable
        }
        #endif
        // Only use the non-request-specific "outputObscuredDueToInsufficientExternalProtection" status if
        // AVContentKeyRequests do not support the finer grained "-willOutputBeObscured..." API.
        return outputObscured ? .OutputRestricted : nil
        #endif
    }

    private func updateProtectionStatus() {
        if requests.isEmpty {
            return
        }
        updateKeyStatuses()
        sendKeyStatusesToClient()
    }

    private func ensureSessionOrGroup(builtInKeyGrouping: Bool) -> Bool {
        if case .some = ownSession {
            return true
        }
        if groupObject != nil {
            return true
        }

        if let instanceSession = instance.contentKeySession() {
            if builtInKeyGrouping {
                builtInGroup = FairPlayBuiltInKeyGroup(contentKeySession: instanceSession, dataSource: self)
            } else {
                #if HAVE_AVCONTENTKEYREPORTGROUP
                reportGroup = instanceSession.makeContentKeyGroup()
                #endif
            }
            return true
        }

        guard let newSession = PAL.makeFairPlayStreamingContentKeySession(instance.persistentStateAllowed ? instance.storageURL : nil) else {
            return false
        }
        ownSession = newSession
        let delegate = delegate ?? FairPlayContentKeySessionDelegate(client: self)
        self.delegate = delegate
        newSession.setDelegate(delegate, queue: DispatchQueue.main)
        return true
    }

    private func isLicenseTypeSupported(_ licenseType: WebCore.CDMSessionType) -> Bool {
        switch licenseType {
        case .PersistentLicense:
            instance.persistentStateAllowed && instance.supportsPersistentKeys
        case .PersistentUsageRecord:
            instance.persistentStateAllowed && instance.supportsPersistableState
        case .Temporary:
            true
        @unknown default:
            false
        }
    }
}

private func exceptionMessage(_ exception: NSException) -> Swift.String {
    "exception thrown from -makeStreamingContentKeyRequestDataForApp:contentIdentifier:options:completionHandler: \(exception.name.rawValue), reason : \(exception.reason ?? "(null)")"
}

// MARK: C++

// What CDMInstanceFairPlayStreamingAVFObjC.mm calls. The instance and its sessions are the main thread's, where C++
// calls them.
@_expose(Cxx)
final class FairPlayInstanceBridge: Sendable {
    fileprivate let instance: FairPlayInstance

    @_expose(Cxx)
    init(
        _ host: sending WebCore.FairPlayInstanceHost,
        _ mediaKeysHashSalt: borrowing WebCore.MediaParserText,
        _ supportsPersistableState: Bool,
        _ supportsPersistentKeys: Bool
    ) {
        let hashSalt = fairPlayString(mediaKeysHashSalt)
        instance = MainActor.assumeIsolated {
            FairPlayInstance(
                host: host,
                mediaKeysHashSalt: hashSalt,
                supportsPersistableState: supportsPersistableState,
                supportsPersistentKeys: supportsPersistentKeys
            )
        }
    }

    @_expose(Cxx)
    func initialize(
        _ distinctiveIdentifierRequired: Bool,
        _ persistentStateRequired: Bool,
        _ sessionTypesIncludePersistentState: Bool,
        _ sessionTypesIncludePersistentLicense: Bool,
        _ allowsPersistentState: Bool
    ) -> Bool {
        MainActor.assumeIsolated {
            instance.initialize(
                distinctiveIdentifierRequired: distinctiveIdentifierRequired,
                persistentStateRequired: persistentStateRequired,
                sessionTypesIncludePersistentState: sessionTypesIncludePersistentState,
                sessionTypesIncludePersistentLicense: sessionTypesIncludePersistentLicense,
                allowsPersistentState: allowsPersistentState
            )
        }
    }

    @_expose(Cxx)
    func setServerCertificate(_ certificate: borrowing WebCore.MediaParserBytes) {
        let bytes: Span<UInt8> = certificate.span()
        let data = Data(fairPlayBytes(bytes))
        MainActor.assumeIsolated {
            instance.setServerCertificate(data)
        }
    }

    // An empty path means no storage.
    @_expose(Cxx)
    func setStoragePath(_ path: borrowing WebCore.MediaParserText) {
        let storagePath = fairPlayString(path)
        MainActor.assumeIsolated {
            instance.setStoragePath(storagePath)
        }
    }

    @_expose(Cxx)
    func makeSession(_ host: sending WebCore.FairPlaySessionHost) -> FairPlaySessionBridge {
        FairPlaySessionBridge(session: MainActor.assumeIsolated { instance.makeSession(host: FairPlayCxxSessionHost(host)) })
    }

    // The token of fairPlayInstanceToken().
    @_expose(Cxx)
    func token() -> UInt64 {
        instance.token
    }

    @_expose(Cxx)
    func isAnyKeyUsable(_ keyIDs: borrowing WebCore.MediaParserBytes, _ keyIDSizes: borrowing WebCore.FairPlayKeyIDSizes) -> Bool {
        let bytes: Span<UInt8> = keyIDs.span()
        let sizes: Span<UInt32> = keyIDSizes.span()
        return MainActor.assumeIsolated {
            instance.isAnyKeyUsable(bytes, sizes)
        }
    }

    @_expose(Cxx)
    func hasSession(_ keyIDs: borrowing WebCore.MediaParserBytes, _ keyIDSizes: borrowing WebCore.FairPlayKeyIDSizes) -> Bool {
        let bytes: Span<UInt8> = keyIDs.span()
        let sizes: Span<UInt32> = keyIDSizes.span()
        return MainActor.assumeIsolated {
            instance.session(forKeyIDs: bytes, sizes) != nil
        }
    }

    // The AVContentKeySession of the session that has one of these key IDs.
    @_expose(Cxx)
    func contentKeySession(_ keyIDs: borrowing WebCore.MediaParserBytes, _ keyIDSizes: borrowing WebCore.FairPlayKeyIDSizes) -> NSObject? {
        let bytes: Span<UInt8> = keyIDs.span()
        let sizes: Span<UInt32> = keyIDSizes.span()
        let contentKeySession: AVContentKeySession? = MainActor.assumeIsolated {
            instance.session(forKeyIDs: bytes, sizes)?.contentKeySessionForPlayers
        }
        return contentKeySession
    }

    // The AVContentKey to attach to a sample with these key IDs.
    @_expose(Cxx)
    func contentKey(_ keyIDs: borrowing WebCore.MediaParserBytes, _ keyIDSizes: borrowing WebCore.FairPlayKeyIDSizes) -> NSObject? {
        let bytes: Span<UInt8> = keyIDs.span()
        let sizes: Span<UInt32> = keyIDSizes.span()
        let contentKey: AVContentKey? = MainActor.assumeIsolated {
            instance.contentKey(forSampleKeyIDs: bytes, sizes)
        }
        return contentKey
    }

    @_expose(Cxx)
    func outputObscuredDueToInsufficientExternalProtectionChanged(_ obscured: Bool) {
        MainActor.assumeIsolated {
            instance.outputObscuredDueToInsufficientExternalProtectionChanged(obscured)
        }
    }
}

extension FairPlaySession {
    fileprivate var contentKeySessionForPlayers: AVContentKeySession? {
        contentKeySession()
    }
}

@_expose(Cxx)
final class FairPlaySessionBridge: Sendable {
    fileprivate let session: FairPlaySession

    fileprivate init(session: FairPlaySession) {
        self.session = session
    }

    @_expose(Cxx)
    func requestLicense(
        _ licenseType: WebCore.CDMSessionType,
        _ builtInKeyGrouping: Bool,
        _ initDataType: borrowing WebCore.MediaParserText,
        _ initData: borrowing WebCore.MediaParserBytes,
        _ callback: sending WebCore.FairPlayLicenseCompletion
    ) {
        let type = fairPlayString(initDataType)
        let bytes: Span<UInt8> = initData.span()
        let data = fairPlayBytes(bytes)
        MainActor.assumeIsolated {
            session.requestLicense(licenseType, builtInKeyGrouping: builtInKeyGrouping, initDataType: type, initData: data, callback: FairPlayCxxLicenseRequestCompletion(callback))
        }
    }

    @_expose(Cxx)
    func updateLicense(_ response: borrowing WebCore.MediaParserBytes, _ callback: sending WebCore.FairPlayLicenseUpdateCompletion) {
        let bytes: Span<UInt8> = response.span()
        let data = fairPlayBytes(bytes)
        MainActor.assumeIsolated {
            session.updateLicense(data, callback: FairPlayCxxLicenseUpdateCompletion(callback))
        }
    }

    // A FairPlayLoadSessionStatus; releasedKeyCount is set when it succeeds.
    @_expose(Cxx)
    func loadSession(_ licenseType: WebCore.CDMSessionType, _ sessionId: borrowing WebCore.MediaParserText, _ releasedKeyCount: inout UInt32) -> UInt8 {
        let requestedSessionId = fairPlayString(sessionId)
        let result = MainActor.assumeIsolated {
            session.loadSession(licenseType, sessionId: requestedSessionId)
        }
        switch result {
        case .notHandled:
            return WebCore.FairPlayLoadSessionStatus.NotHandled.rawValue
        case .succeeded(let count):
            releasedKeyCount = UInt32(truncatingIfNeeded: count)
            return WebCore.FairPlayLoadSessionStatus.Succeeded.rawValue
        case .mismatchedSessionType:
            return WebCore.FairPlayLoadSessionStatus.MismatchedSessionType.rawValue
        case .noSessionData:
            return WebCore.FairPlayLoadSessionStatus.NoSessionData.rawValue
        }
    }

    @_expose(Cxx)
    func closeSession() {
        MainActor.assumeIsolated {
            session.closeSession()
        }
    }

    // Whether it succeeded; hasMessage tells whether message is the expired session reports.
    @_expose(Cxx)
    func removeSessionData(
        _ licenseType: WebCore.CDMSessionType,
        _ sessionId: borrowing WebCore.MediaParserText,
        _ releasedKeyCount: inout UInt32,
        _ hasMessage: inout Bool,
        _ message: inout WebCore.MediaParserByteVector
    ) -> Bool {
        let requestedSessionId = fairPlayString(sessionId)
        let result = MainActor.assumeIsolated {
            session.removeSessionData(licenseType, sessionId: requestedSessionId)
        }
        releasedKeyCount = UInt32(truncatingIfNeeded: result.releasedKeyCount)
        if let data = result.message {
            hasMessage = true
            WebCore.appendBytes(&message, fairPlayBytes(data).span)
        }
        return result.succeeded
    }

    @_expose(Cxx)
    func displayChanged() {
        MainActor.assumeIsolated {
            session.displayChanged()
        }
    }
}

// The options of a streaming content key request, for CDMSessionAVContentKeySession.
@_expose(Cxx)
func fairPlayKeyRequestOptionsImpl(_ mediaKeysHashSalt: borrowing WebCore.MediaParserText) -> NSDictionary {
    keyRequestOptions(hashSalt: fairPlayString(mediaKeysHashSalt)) as NSDictionary
}

// The key IDs of a request, from its identifier and init data, for CDMPrivateFairPlayStreaming::keyIDsForRequest():
// appended to keyIDs back to back, with their sizes.
@_expose(Cxx)
func fairPlayRequestKeyIDsImpl(
    _ identifier: NSObject?,
    _ initializationData: NSData?,
    _ keyIDs: inout WebCore.MediaParserByteVector,
    _ keyIDSizes: inout WebCore.MediaParserUInt32Vector
) {
    for keyID in fairPlayKeyIDs(identifier: identifier, initializationData: initializationData as Data?) {
        WebCore.appendBytes(&keyIDs, keyID.span)
        keyIDSizes.append(consuming: UInt32(truncatingIfNeeded: keyID.count))
    }
}

#endif // ENABLE_ENCRYPTED_MEDIA && HAVE_AVCONTENTKEYSESSION
