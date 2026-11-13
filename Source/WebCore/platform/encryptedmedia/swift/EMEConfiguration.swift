// Copyright (C) 2020 Apple Inc. All rights reserved.
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

/// CDMEncryptionScheme.
@frozen public enum EMEEncryptionScheme: Sendable {
    case cenc
    case cbcs
}

/// CDMMediaCapability. Strings are optional where a WTF::String can be null.
public struct EMEMediaCapability: Sendable, Equatable {
    public var contentType: String?
    public var robustness: String?
    public var encryptionScheme: EMEEncryptionScheme?

    public init(contentType: String?, robustness: String?, encryptionScheme: EMEEncryptionScheme?) {
        self.contentType = contentType
        self.robustness = robustness
        self.encryptionScheme = encryptionScheme
    }
}

/// Audio or video, for the capabilities of a configuration.
@frozen public enum EMEMediaType: Sendable {
    case audio
    case video
}

/// CDMKeySystemConfiguration.
public struct EMEKeySystemConfiguration: Sendable, Equatable {
    public var label: String?
    public var initDataTypes: [String?]
    public var audioCapabilities: [EMEMediaCapability]
    public var videoCapabilities: [EMEMediaCapability]
    public var distinctiveIdentifier: EMERequirement
    public var persistentState: EMERequirement
    public var sessionTypes: [EMESessionType]

    public init(
        label: String?,
        initDataTypes: [String?],
        audioCapabilities: [EMEMediaCapability],
        videoCapabilities: [EMEMediaCapability],
        distinctiveIdentifier: EMERequirement,
        persistentState: EMERequirement,
        sessionTypes: [EMESessionType]
    ) {
        self.label = label
        self.initDataTypes = initDataTypes
        self.audioCapabilities = audioCapabilities
        self.videoCapabilities = videoCapabilities
        self.distinctiveIdentifier = distinctiveIdentifier
        self.persistentState = persistentState
        self.sessionTypes = sessionTypes
    }

    public func capabilities(_ type: EMEMediaType) -> [EMEMediaCapability] {
        type == .audio ? audioCapabilities : videoCapabilities
    }

    /// Every entry of this configuration, as the selection the configuration algorithm starts from.
    public var selection: EMEConfigurationSelection {
        EMEConfigurationSelection(
            initDataTypes: Array(initDataTypes.indices),
            audioCapabilities: Array(audioCapabilities.indices),
            videoCapabilities: Array(videoCapabilities.indices),
            distinctiveIdentifier: distinctiveIdentifier,
            persistentState: persistentState,
            sessionTypes: sessionTypes
        )
    }

    /// The configuration made of the entries of this configuration that selection names, with its label.
    public func selecting(_ selection: EMEConfigurationSelection) -> EMEKeySystemConfiguration {
        EMEKeySystemConfiguration(
            label: label,
            initDataTypes: selection.initDataTypes.map { initDataTypes[$0] },
            audioCapabilities: selection.audioCapabilities.map { audioCapabilities[$0] },
            videoCapabilities: selection.videoCapabilities.map { videoCapabilities[$0] },
            distinctiveIdentifier: selection.distinctiveIdentifier,
            persistentState: selection.persistentState,
            sessionTypes: selection.sessionTypes
        )
    }
}

/// CDMRestrictions, without the denied session types, which the configuration algorithm leaves empty.
public struct EMERestrictions: Sendable, Equatable {
    public var distinctiveIdentifierDenied = false
    public var persistentStateDenied = false

    public init(distinctiveIdentifierDenied: Bool = false, persistentStateDenied: Bool = false) {
        self.distinctiveIdentifierDenied = distinctiveIdentifierDenied
        self.persistentStateDenied = persistentStateDenied
    }
}

/// A configuration that the configuration algorithm makes of the entries of a candidate configuration: the indices of
/// its init data types and capabilities in the candidate's, its requirements and its session types.
public struct EMEConfigurationSelection: Sendable, Equatable {
    public var initDataTypes: [Int]
    public var audioCapabilities: [Int]
    public var videoCapabilities: [Int]
    public var distinctiveIdentifier: EMERequirement
    public var persistentState: EMERequirement
    public var sessionTypes: [EMESessionType]

    public init(
        initDataTypes: [Int],
        audioCapabilities: [Int],
        videoCapabilities: [Int],
        distinctiveIdentifier: EMERequirement,
        persistentState: EMERequirement,
        sessionTypes: [EMESessionType]
    ) {
        self.initDataTypes = initDataTypes
        self.audioCapabilities = audioCapabilities
        self.videoCapabilities = videoCapabilities
        self.distinctiveIdentifier = distinctiveIdentifier
        self.persistentState = persistentState
        self.sessionTypes = sessionTypes
    }

    public func capabilities(_ type: EMEMediaType) -> [Int] {
        type == .audio ? audioCapabilities : videoCapabilities
    }

    fileprivate mutating func setCapabilities(_ type: EMEMediaType, _ capabilities: [Int]) {
        if type == .audio {
            audioCapabilities = capabilities
        } else {
            videoCapabilities = capabilities
        }
    }
}

/// What a CDM (CDMPrivate's questions) and the platform (its content types) answer for the configuration algorithm.
/// Entries are named by their indices in the candidate configuration.
public protocol EMEConfigurationImplementation {
    /// Every entry of the candidate configuration.
    var candidate: EMEConfigurationSelection { get }

    func initDataTypeIsEmpty(_ index: Int) -> Bool
    /// Whether CDMPrivate::supportedInitDataTypes() has the init data type, compared case-sensitively.
    func supportsInitDataType(_ index: Int) -> Bool
    func contentTypeIsEmpty(_ type: EMEMediaType, _ index: Int) -> Bool
    /// Whether the content type is a valid MIME type whose only parameter, if any, is "codecs", whose container is
    /// strictly of the media type (or an HLS playlist), and which MediaPlayer may support, from a URL or Media Source.
    func supportsContentType(_ type: EMEMediaType, _ index: Int) -> Bool
    func robustnessIsEmpty(_ type: EMEMediaType, _ index: Int) -> Bool
    /// Whether CDMPrivate::supportedRobustnesses() has the robustness, compared case-sensitively.
    func supportsRobustness(_ type: EMEMediaType, _ index: Int) -> Bool

    func supportsConfiguration(_ configuration: EMEConfigurationSelection) -> Bool
    func supportsConfiguration(_ configuration: EMEConfigurationSelection, restrictions: EMERestrictions) -> Bool
    func supportsSessionType(_ sessionType: EMESessionType, configuration: EMEConfigurationSelection) -> Bool
    func distinctiveIdentifiersRequirement(_ configuration: EMEConfigurationSelection, restrictions: EMERestrictions) -> EMERequirement
    func persistentStateRequirement(_ configuration: EMEConfigurationSelection, restrictions: EMERestrictions) -> EMERequirement
    func distinctiveIdentifiersAreUniquePerOriginAndClearable(_ configuration: EMEConfigurationSelection) -> Bool
}

/// What a Swift CDM answers for the configuration algorithm (CDMPrivate's questions), about configurations made of a
/// candidate's entries.
public protocol EMECDMConfigurationAnswers {
    var supportedInitDataTypes: [String] { get }
    var supportedRobustnesses: [String] { get }
    func supportsConfiguration(_ configuration: EMEKeySystemConfiguration) -> Bool
    func supportsConfiguration(_ configuration: EMEKeySystemConfiguration, restrictions: EMERestrictions) -> Bool
    func supportsSessionType(_ sessionType: EMESessionType, configuration: EMEKeySystemConfiguration) -> Bool
    func distinctiveIdentifiersRequirement(_ configuration: EMEKeySystemConfiguration, restrictions: EMERestrictions) -> EMERequirement
    func persistentStateRequirement(_ configuration: EMEKeySystemConfiguration, restrictions: EMERestrictions) -> EMERequirement
    func distinctiveIdentifiersAreUniquePerOriginAndClearable(_ configuration: EMEKeySystemConfiguration) -> Bool
}

// A Swift CDM's answers about a candidate configuration, with the platform's content type check.
private struct EMESwiftCDMConfigurationImplementation<Answers: EMECDMConfigurationAnswers>: EMEConfigurationImplementation {
    let configuration: EMEKeySystemConfiguration
    let answers: Answers
    let supportsContentType: (String, EMEMediaType) -> Bool

    var candidate: EMEConfigurationSelection {
        configuration.selection
    }

    func initDataTypeIsEmpty(_ index: Int) -> Bool {
        configuration.initDataTypes[index]?.isEmpty ?? true
    }

    func supportsInitDataType(_ index: Int) -> Bool {
        let initDataType = configuration.initDataTypes[index] ?? ""
        return answers.supportedInitDataTypes.contains { $0.utf16.elementsEqual(initDataType.utf16) }
    }

    func contentTypeIsEmpty(_ type: EMEMediaType, _ index: Int) -> Bool {
        configuration.capabilities(type)[index].contentType?.isEmpty ?? true
    }

    func supportsContentType(_ type: EMEMediaType, _ index: Int) -> Bool {
        supportsContentType(configuration.capabilities(type)[index].contentType ?? "", type)
    }

    func robustnessIsEmpty(_ type: EMEMediaType, _ index: Int) -> Bool {
        configuration.capabilities(type)[index].robustness?.isEmpty ?? true
    }

    func supportsRobustness(_ type: EMEMediaType, _ index: Int) -> Bool {
        let robustness = configuration.capabilities(type)[index].robustness ?? ""
        return answers.supportedRobustnesses.contains { $0.utf16.elementsEqual(robustness.utf16) }
    }

    func supportsConfiguration(_ selection: EMEConfigurationSelection) -> Bool {
        answers.supportsConfiguration(configuration.selecting(selection))
    }

    func supportsConfiguration(_ selection: EMEConfigurationSelection, restrictions: EMERestrictions) -> Bool {
        answers.supportsConfiguration(configuration.selecting(selection), restrictions: restrictions)
    }

    func supportsSessionType(_ sessionType: EMESessionType, configuration selection: EMEConfigurationSelection) -> Bool {
        answers.supportsSessionType(sessionType, configuration: configuration.selecting(selection))
    }

    func distinctiveIdentifiersRequirement(_ selection: EMEConfigurationSelection, restrictions: EMERestrictions) -> EMERequirement {
        answers.distinctiveIdentifiersRequirement(configuration.selecting(selection), restrictions: restrictions)
    }

    func persistentStateRequirement(_ selection: EMEConfigurationSelection, restrictions: EMERestrictions) -> EMERequirement {
        answers.persistentStateRequirement(configuration.selecting(selection), restrictions: restrictions)
    }

    func distinctiveIdentifiersAreUniquePerOriginAndClearable(_ selection: EMEConfigurationSelection) -> Bool {
        answers.distinctiveIdentifiersAreUniquePerOriginAndClearable(configuration.selecting(selection))
    }
}

/// The configuration algorithm of every CDM (https://w3c.github.io/encrypted-media/#get-supported-configuration, W3C
/// Editor's Draft 09 November 2016), as CDMPrivate::getSupportedConfiguration() ran it.
public enum EMEConfigurationAlgorithm {
    /// The supported configuration of a Swift CDM for a candidate configuration, or nil for NotSupported.
    /// supportsContentType is the platform's check of a content type for a media type.
    public static func supportedConfiguration(
        _ candidate: EMEKeySystemConfiguration,
        localStorageAccessAllowed: Bool,
        answers: some EMECDMConfigurationAnswers,
        supportsContentType: @escaping (String, EMEMediaType) -> Bool
    ) -> EMEKeySystemConfiguration? {
        let implementation = EMESwiftCDMConfigurationImplementation(
            configuration: candidate,
            answers: answers,
            supportsContentType: supportsContentType
        )
        return supportedConfiguration(localStorageAccessAllowed: localStorageAccessAllowed, implementation: implementation).map {
            candidate.selecting($0)
        }
    }

    private enum ConsentStatus {
        case consentDenied
        case informUser
        case allowed
    }

    /// 3.1.1.1 Get Supported Configuration: the supported configuration, or nil for NotSupported.
    public static func supportedConfiguration(
        localStorageAccessAllowed: Bool,
        implementation: some EMEConfigurationImplementation
    ) -> EMEConfigurationSelection? {
        // 1. Let supported configuration be ConsentDenied.
        // 2. Initialize restrictions to indicate that no configurations have had user consent denied.
        var candidate = implementation.candidate
        var restrictions = EMERestrictions()

        // 3. Repeat the following step while supported configuration is ConsentDenied: let supported configuration and,
        //    if provided, restrictions be the result of executing the Get Supported Configuration and Consent algorithm.
        //    WebKit runs it again on the accumulated configuration.
        while true {
            guard
                let accumulated = supportedConfigurationAndConsent(
                    candidate,
                    restrictions,
                    localStorageAccessAllowed: localStorageAccessAllowed,
                    implementation: implementation
                )
            else {
                return nil
            }

            // 3.1.1.2 Get Supported Configuration and Consent, ctd.
            // 22. Follow the steps for the value of consent status.
            var updatedRestrictions = restrictions
            switch consentStatus(accumulated, &updatedRestrictions, localStorageAccessAllowed: localStorageAccessAllowed, implementation: implementation) {
            case .consentDenied:
                // Return ConsentDenied and updated restrictions. The same candidate and restrictions would be denied
                // again forever.
                if accumulated == candidate && updatedRestrictions == restrictions {
                    return nil
                }
                candidate = accumulated
                restrictions = updatedRestrictions
            case .informUser, .allowed:
                // InformUser: inform the user that accumulated configuration is in use (not implemented).
                // 23. Return accumulated configuration.
                return accumulated
            }
        }
    }

    // 5.1.1. Is persistent session type?
    private static func isPersistentType(_ sessionType: EMESessionType) -> Bool {
        switch sessionType {
        case .temporary:
            false
        case .persistentLicense, .persistentUsageRecord:
            true
        }
    }

    // 3.1.1.2 Get Supported Configuration and Consent, steps 1 to 20: the accumulated configuration, or nil for
    // NotSupported.
    private static func supportedConfigurationAndConsent(
        _ candidate: EMEConfigurationSelection,
        _ restrictions: EMERestrictions,
        localStorageAccessAllowed: Bool,
        implementation: some EMEConfigurationImplementation
    ) -> EMEConfigurationSelection? {
        // 1. Let accumulated configuration be a new CDMKeySystemConfiguration dictionary.
        // 2. Its label is the candidate's.
        var accumulated = EMEConfigurationSelection(
            initDataTypes: [],
            audioCapabilities: [],
            videoCapabilities: [],
            distinctiveIdentifier: .optional,
            persistentState: .optional,
            sessionTypes: []
        )

        // 3. If the initDataTypes member of candidate configuration is non-empty, set the initDataTypes member of
        //    accumulated configuration to those the implementation supports generating requests from, or return
        //    NotSupported if there are none. The empty string is never supported.
        if !candidate.initDataTypes.isEmpty {
            let supportedTypes = candidate.initDataTypes.filter {
                !implementation.initDataTypeIsEmpty($0) && implementation.supportsInitDataType($0)
            }
            if supportedTypes.isEmpty {
                return nil
            }
            accumulated.initDataTypes = supportedTypes
        }

        // 4. Let distinctive identifier requirement be the candidate's.
        // 5. If it is "optional" and Distinctive Identifiers are not allowed according to restrictions, make it
        //    "not-allowed".
        var distinctiveIdentifierRequirement = candidate.distinctiveIdentifier
        if distinctiveIdentifierRequirement == .optional && restrictions.distinctiveIdentifierDenied {
            distinctiveIdentifierRequirement = .notAllowed
        }

        // 6. "required": return NotSupported if the implementation doesn't support Distinctive Identifiers with
        //    accumulated configuration and restrictions. "not-allowed": return NotSupported if it requires them.
        switch distinctiveIdentifierRequirement {
        case .required:
            if implementation.distinctiveIdentifiersRequirement(accumulated, restrictions: restrictions) == .notAllowed {
                return nil
            }
        case .optional:
            break
        case .notAllowed:
            if implementation.distinctiveIdentifiersRequirement(accumulated, restrictions: restrictions) == .required {
                return nil
            }
        }

        // 7. Set the distinctiveIdentifier member of accumulated configuration to distinctive identifier requirement.
        accumulated.distinctiveIdentifier = distinctiveIdentifierRequirement

        // 8. Let persistent state requirement be the candidate's.
        // 9. If it is "optional" and persisting state is not allowed according to restrictions, make it "not-allowed".
        var persistentStateRequirement = candidate.persistentState
        if persistentStateRequirement == .optional && restrictions.persistentStateDenied {
            persistentStateRequirement = .notAllowed
        }

        // 10. "required": return NotSupported if the implementation doesn't support persisting state with accumulated
        //     configuration and restrictions. "not-allowed": return NotSupported if it requires persisting state.
        switch persistentStateRequirement {
        case .required:
            if implementation.persistentStateRequirement(accumulated, restrictions: restrictions) == .notAllowed {
                return nil
            }
        case .optional:
            break
        case .notAllowed:
            if implementation.persistentStateRequirement(accumulated, restrictions: restrictions) == .required {
                return nil
            }
        }

        // 11. Set the persistentState member of accumulated configuration to persistent state requirement.
        accumulated.persistentState = persistentStateRequirement

        // 12. Let session types be the candidate's sessionTypes member if present, or [ "temporary" ].
        let sessionTypes: [EMESessionType] = candidate.sessionTypes.isEmpty ? [.temporary] : candidate.sessionTypes

        // 13. For each session type:
        for sessionType in sessionTypes {
            // 13.2. Return NotSupported if accumulated configuration's persistentState is "not-allowed" and the session
            //       type is persistent.
            if accumulated.persistentState == .notAllowed && isPersistentType(sessionType) {
                return nil
            }

            // 13.3. Return NotSupported if the implementation doesn't support the session type with accumulated
            //       configuration and restrictions for other reasons.
            if !implementation.supportsSessionType(sessionType, configuration: accumulated) {
                return nil
            }

            // 13.4. If accumulated configuration's persistentState is "optional" and the session type is persistent,
            //       make it "required".
            if accumulated.persistentState == .optional && isPersistentType(sessionType) {
                accumulated.persistentState = .required
            }
        }

        // 14. Set the sessionTypes member of accumulated configuration to session types.
        accumulated.sessionTypes = sessionTypes

        // 15. If the videoCapabilities and audioCapabilities members in candidate configuration are both empty, return
        //     NotSupported.
        if candidate.videoCapabilities.isEmpty && candidate.audioCapabilities.isEmpty {
            return nil
        }

        // 16. and 17. Video, then audio: if the candidate's capabilities are non-empty, set accumulated configuration's
        //     to the result of the Get Supported Capabilities for Audio/Video Type algorithm, or return NotSupported if
        //     it is null. Otherwise they're empty.
        for type in [EMEMediaType.video, .audio] {
            let requestedCapabilities = candidate.capabilities(type)
            if requestedCapabilities.isEmpty {
                accumulated.setCapabilities(type, [])
                continue
            }
            guard
                let capabilities = supportedCapabilities(
                    type,
                    requestedCapabilities,
                    accumulated,
                    restrictions,
                    implementation: implementation
                )
            else {
                return nil
            }
            accumulated.setCapabilities(type, capabilities)
        }

        // 18. If accumulated configuration's distinctiveIdentifier is "optional", make it "required" if the
        //     implementation requires Distinctive Identifiers for any of its combinations, and "not-allowed" otherwise.
        if accumulated.distinctiveIdentifier == .optional {
            let requirement = implementation.distinctiveIdentifiersRequirement(accumulated, restrictions: restrictions)
            accumulated.distinctiveIdentifier = requirement == .required ? .required : .notAllowed
        }

        // 19. If accumulated configuration's persistentState is "optional", make it "required" if the implementation
        //     requires persisting state for any of its combinations, and "not-allowed" otherwise.
        if accumulated.persistentState == .optional {
            let requirement = implementation.persistentStateRequirement(accumulated, restrictions: restrictions)
            accumulated.persistentState = requirement == .required ? .required : .notAllowed
        }

        // 20. Return NotSupported if the implementation doesn't support accumulated configuration or it isn't allowed
        //     in the origin.
        if !implementation.supportsConfiguration(accumulated) {
            return nil
        }

        if (accumulated.distinctiveIdentifier == .required || accumulated.persistentState == .required) && !localStorageAccessAllowed {
            return nil
        }

        return accumulated
    }

    // 3.1.1.3 Get Supported Capabilities for Audio/Video Type: the supported media capabilities, or nil for null.
    private static func supportedCapabilities(
        _ type: EMEMediaType,
        _ requestedCapabilities: [Int],
        _ partialConfiguration: EMEConfigurationSelection,
        _ restrictions: EMERestrictions,
        implementation: some EMEConfigurationImplementation
    ) -> [Int]? {
        // 1. Let local accumulated configuration be a local copy of partial configuration.
        var accumulated = partialConfiguration

        // 2. Let supported media capabilities be an empty sequence of CDMMediaCapability dictionaries.
        var supportedMediaCapabilities: [Int] = []

        // 3. For each requested media capability:
        for requestedCapability in requestedCapabilities {
            // 3.3. If content type is the empty string, return null.
            if implementation.contentTypeIsEmpty(type, requestedCapability) {
                return nil
            }

            // 3.12. If robustness is not the empty string and contains an unrecognized value or a value not supported
            //       by implementation, continue to the next iteration. String comparison is case-sensitive.
            if !implementation.robustnessIsEmpty(type, requestedCapability) && !implementation.supportsRobustness(type, requestedCapability) {
                continue
            }

            // 3.4. to 3.11. and the first half of 3.13: continue to the next iteration unless the user agent supports
            //      the content type, strictly of this type, and may play it.
            if !implementation.supportsContentType(type, requestedCapability) {
                continue
            }

            // 3.13. ... and the implementation definitely supports playback of encrypted media data for the combination
            //       of local accumulated configuration, including the requested capability, with restrictions.
            var probeConfiguration = accumulated
            probeConfiguration.setCapabilities(type, accumulated.capabilities(type) + [requestedCapability])
            if !implementation.supportsConfiguration(probeConfiguration, restrictions: restrictions) {
                continue
            }

            // 3.13.1. Add requested media capability to supported media capabilities.
            supportedMediaCapabilities.append(requestedCapability)

            // 3.13.2. Add it to the capabilities of its type of local accumulated configuration.
            accumulated = probeConfiguration
        }

        // 4. If supported media capabilities is empty, return null.
        if supportedMediaCapabilities.isEmpty {
            return nil
        }

        // 5. Return supported media capabilities.
        return supportedMediaCapabilities
    }

    // 3.1.1.2 Get Supported Configuration and Consent, step 21, then 3.1.1.4 Get Consent Status: the consent status,
    // with restrictions updated in the ConsentDenied case.
    private static func consentStatus(
        _ accumulated: EMEConfigurationSelection,
        _ restrictions: inout EMERestrictions,
        localStorageAccessAllowed: Bool,
        implementation: some EMEConfigurationImplementation
    ) -> ConsentStatus {
        // 21. If accumulated configuration's distinctiveIdentifier is "required" and its Distinctive Identifier(s) are
        //     not unique per origin and profile and clearable, update restrictions to reflect that all configurations
        //     described by accumulated configuration do not have user consent.
        if accumulated.distinctiveIdentifier == .required && !implementation.distinctiveIdentifiersAreUniquePerOriginAndClearable(accumulated) {
            restrictions.distinctiveIdentifierDenied = true
            return .consentDenied
        }

        // 1. and 2. Persisted denial and consent are not implemented.
        // 3. Assume that implementations follow all recommendations, that the user agent doesn't require explicit user
        //    consent, and implied consent if the combination of origin and top origin allows it.
        if accumulated.distinctiveIdentifier == .required && !localStorageAccessAllowed {
            restrictions.distinctiveIdentifierDenied = true
            return .consentDenied
        }

        // 4. If the distinctiveIdentifier member of accumulated configuration is not "not-allowed", return InformUser.
        if accumulated.distinctiveIdentifier != .notAllowed {
            return .informUser
        }

        // 5. Assume the user agent doesn't require informing the user for other reasons.
        // 6. Return Allowed.
        return .allowed
    }
}

#endif // ENABLE_ENCRYPTED_MEDIA
