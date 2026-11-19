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

#if ENABLE_WEBCORE_SWIFT && ENABLE_ENCRYPTED_MEDIA

import WebCore_Private.Core.CDMPrivate
public import WebCoreEME
import wtf

// The configuration algorithm (EMEConfiguration.swift) for the C++ CDM of CDMPrivate::getSupportedConfiguration(),
// and for the GPU process's Swift CDMs.

private struct CxxCDMConfigurationImplementation: EMEConfigurationImplementation {
    let query: WebCore.CDMSupportedConfigurationQuery

    var candidate: EMEConfigurationSelection {
        EMEConfigurationSelection(
            initDataTypes: Array(0..<query.count(.InitDataTypes)),
            audioCapabilities: Array(0..<query.count(.AudioCapabilities)),
            videoCapabilities: Array(0..<query.count(.VideoCapabilities)),
            distinctiveIdentifier: EMERequirement(query.distinctiveIdentifier()),
            persistentState: EMERequirement(query.persistentState()),
            sessionTypes: (0..<query.count(.SessionTypes)).map { EMESessionType(query.sessionType($0)) }
        )
    }

    private func fact(_ fact: WebCore.CDMConfigurationFact, _ type: EMEMediaType, _ index: Int) -> Bool {
        query.fact(fact, type == .video, index)
    }

    func initDataTypeIsEmpty(_ index: Int) -> Bool {
        fact(.InitDataTypeIsEmpty, .audio, index)
    }

    func supportsInitDataType(_ index: Int) -> Bool {
        fact(.InitDataTypeIsSupported, .audio, index)
    }

    func contentTypeIsEmpty(_ type: EMEMediaType, _ index: Int) -> Bool {
        fact(.ContentTypeIsEmpty, type, index)
    }

    func supportsContentType(_ type: EMEMediaType, _ index: Int) -> Bool {
        fact(.ContentTypeIsSupported, type, index)
    }

    func robustnessIsEmpty(_ type: EMEMediaType, _ index: Int) -> Bool {
        fact(.RobustnessIsEmpty, type, index)
    }

    func supportsRobustness(_ type: EMEMediaType, _ index: Int) -> Bool {
        fact(.RobustnessIsSupported, type, index)
    }

    // Makes the query's configuration the selection.
    func select(_ selection: EMEConfigurationSelection) {
        query.startConfiguration(WebCore.CDMRequirement(selection.distinctiveIdentifier), WebCore.CDMRequirement(selection.persistentState))
        for index in selection.initDataTypes {
            query.addEntry(.InitDataTypes, index)
        }
        for index in selection.audioCapabilities {
            query.addEntry(.AudioCapabilities, index)
        }
        for index in selection.videoCapabilities {
            query.addEntry(.VideoCapabilities, index)
        }
        for sessionType in selection.sessionTypes {
            query.addSessionType(WebCore.CDMSessionType(sessionType))
        }
    }

    private func answer(
        _ question: WebCore.CDMConfigurationQuestion,
        _ selection: EMEConfigurationSelection,
        sessionType: EMESessionType = .temporary,
        restrictions: EMERestrictions = EMERestrictions()
    ) -> Bool {
        select(selection)
        return query.answer(
            question,
            WebCore.CDMSessionType(sessionType),
            restrictions.distinctiveIdentifierDenied,
            restrictions.persistentStateDenied
        )
    }

    private func requirement(
        _ question: WebCore.CDMConfigurationRequirementQuestion,
        _ selection: EMEConfigurationSelection,
        _ restrictions: EMERestrictions
    ) -> EMERequirement {
        select(selection)
        return EMERequirement(query.requirement(question, restrictions.distinctiveIdentifierDenied, restrictions.persistentStateDenied))
    }

    func supportsConfiguration(_ configuration: EMEConfigurationSelection) -> Bool {
        answer(.SupportsConfiguration, configuration)
    }

    func supportsConfiguration(_ configuration: EMEConfigurationSelection, restrictions: EMERestrictions) -> Bool {
        answer(.SupportsConfigurationWithRestrictions, configuration, restrictions: restrictions)
    }

    func supportsSessionType(_ sessionType: EMESessionType, configuration: EMEConfigurationSelection) -> Bool {
        answer(.SupportsSessionType, configuration, sessionType: sessionType)
    }

    func distinctiveIdentifiersRequirement(_ configuration: EMEConfigurationSelection, restrictions: EMERestrictions) -> EMERequirement {
        requirement(.DistinctiveIdentifiers, configuration, restrictions)
    }

    func persistentStateRequirement(_ configuration: EMEConfigurationSelection, restrictions: EMERestrictions) -> EMERequirement {
        requirement(.PersistentState, configuration, restrictions)
    }

    func distinctiveIdentifiersAreUniquePerOriginAndClearable(_ configuration: EMEConfigurationSelection) -> Bool {
        answer(.DistinctiveIdentifiersAreUniquePerOriginAndClearable, configuration)
    }
}

// CDMPrivate::getSupportedConfiguration(): whether its CDM supports a configuration of the query's candidate, which
// is then the query's configuration.
@_expose(Cxx)
func cdmSupportedConfigurationImpl(_ query: WebCore.CDMSupportedConfigurationQuery, _ localStorageAccessAllowed: Bool) -> Bool {
    let implementation = CxxCDMConfigurationImplementation(query: query)
    guard let selection = EMEConfigurationAlgorithm.supportedConfiguration(localStorageAccessAllowed: localStorageAccessAllowed, implementation: implementation) else {
        return false
    }
    implementation.select(selection)
    query.setSupported()
    return true
}

/// The configuration algorithm for the GPU process's Swift CDMs.
@_spi(WebKitGPU)
public enum CDMSupportedConfiguration {
    /// The configuration of candidate that a Swift CDM supports, or nil.
    @_spi(WebKitGPU)
    public static func supportedConfiguration(
        _ candidate: EMEKeySystemConfiguration,
        localStorageAccessAllowed: Bool,
        answers: some EMECDMConfigurationAnswers
    ) -> EMEKeySystemConfiguration? {
        EMEConfigurationAlgorithm.supportedConfiguration(
            candidate,
            localStorageAccessAllowed: localStorageAccessAllowed,
            answers: answers
        ) { contentType, type in
            let units = ContiguousArray(contentType.utf16)
            return WebCore.cdmSupportsContentType(WTF.String(units.span), type == .video)
        }
    }
}

extension EMERequirement {
    fileprivate init(_ requirement: WebCore.CDMRequirement) {
        switch requirement {
        case .Required:
            self = .required
        case .Optional:
            self = .optional
        case .NotAllowed:
            self = .notAllowed
        @unknown default:
            self = .notAllowed
        }
    }
}

extension WebCore.CDMRequirement {
    fileprivate init(_ requirement: EMERequirement) {
        switch requirement {
        case .required:
            self = .Required
        case .optional:
            self = .Optional
        case .notAllowed:
            self = .NotAllowed
        }
    }
}

extension EMESessionType {
    fileprivate init(_ sessionType: WebCore.CDMSessionType) {
        switch sessionType {
        case .Temporary:
            self = .temporary
        case .PersistentUsageRecord:
            self = .persistentUsageRecord
        case .PersistentLicense:
            self = .persistentLicense
        @unknown default:
            self = .temporary
        }
    }
}

extension WebCore.CDMSessionType {
    fileprivate init(_ sessionType: EMESessionType) {
        switch sessionType {
        case .temporary:
            self = .Temporary
        case .persistentUsageRecord:
            self = .PersistentUsageRecord
        case .persistentLicense:
            self = .PersistentLicense
        }
    }
}

#endif // ENABLE_WEBCORE_SWIFT && ENABLE_ENCRYPTED_MEDIA

#if ENABLE_ENCRYPTED_MEDIA

// MARK: Client adapters

import WebCore_Private.Core.CDMPrivate
import WebCore_Private.Core.SharedBuffer
import wtf

// What a CDM instance tells its client. Each call is on the main thread.
@_spi(WebKitGPU) @MainActor public protocol CDMInstanceClientDelegate: AnyObject {
    func cdmInstanceDidReceiveUnrequestedInitializationData(type: WTF.String, initData: WebCore.SharedBuffer)
}

private typealias CDMInstanceClientDelegateBox = SwiftDelegateBox<any CDMInstanceClientDelegate>

// An instance of the CDM, if it makes one, with a client whose callbacks go to `delegate`, which owns the adapter.
@_spi(WebKitGPU) @MainActor public func makeCDMInstanceClientSwiftAdapter(
    cdm: WebCore.CDMPrivateClientSwiftAdapter,
    delegate: any CDMInstanceClientDelegate
) -> (adapter: WebCore.CDMInstanceClientSwiftAdapter, instance: WebCore.CDMInstance)? {
    guard let instance = cdm.createInstance() else {
        return nil
    }
    // Safety: the box is retained for the adapter, whose destructor releases it.
    let adapter = unsafe WebCore.CDMInstanceClientSwiftAdapter.create(cdm, instance, CDMInstanceClientDelegateBox.retained { [weak delegate] in delegate })
    return (adapter, instance)
}

extension WebCore.CDMInstanceClientSwiftAdapter {
    private var delegate: (any CDMInstanceClientDelegate)? {
        unsafe CDMInstanceClientDelegateBox.loadDelegate(m_delegateBox)
    }

    @cxx
    @implementation
    @MainActor
    func didReceiveUnrequestedInitializationData(_ type: WTF.String, _ initData: WebCore.SharedBuffer) {
        MainActor.preconditionIsolated()
        delegate?.cdmInstanceDidReceiveUnrequestedInitializationData(type: type, initData: initData)
    }

    @cxx
    @implementation
    static func releaseDelegateBox(_ box: UInt) {
        unsafe CDMInstanceClientDelegateBox.release(box)
    }
}

#endif // ENABLE_ENCRYPTED_MEDIA

#if ENABLE_LEGACY_ENCRYPTED_MEDIA

// MARK: Legacy client adapters

import WebCore_Private.Core.LegacyCDM
import WebCore_Private.Core.MediaPlayer
import WebCore_Private.Core.SharedBuffer
import wtf

// What a legacy CDM asks its client. Each call is on the main thread.
@_spi(WebKitGPU) @MainActor public protocol LegacyCDMClientDelegate: AnyObject {
    // The media player the CDM is for, if any.
    func legacyCDMMediaPlayer() -> WebCore.RefPtrLegacyCDMMediaPlayer
}

// What a legacy CDM session tells and asks its client. Each call is on the main thread.
@_spi(WebKitGPU) @MainActor public protocol LegacyCDMSessionClientDelegate: AnyObject {
    func legacyCDMSessionSendMessage(_ message: WebCore.SharedBuffer?, destinationURL: WTF.String)
    func legacyCDMSessionSendError(_ errorCode: UInt16, systemCode: UInt32)
    func legacyCDMSessionMediaKeysStorageDirectory() -> WTF.String
}

private typealias LegacyCDMClientDelegateBox = SwiftDelegateBox<any LegacyCDMClientDelegate>
private typealias LegacyCDMSessionClientDelegateBox = SwiftDelegateBox<any LegacyCDMSessionClientDelegate>

// The legacy CDM for the key system, if any, with a client whose callbacks go to `delegate`, which owns the adapter.
@_spi(WebKitGPU) @MainActor public func makeLegacyCDMClientSwiftAdapter(
    keySystem: WTF.String,
    delegate: any LegacyCDMClientDelegate
) -> WebCore.LegacyCDMClientSwiftAdapter? {
    // Safety: the box is retained for the adapter, or released if there's none.
    unsafe WebCore.LegacyCDMClientSwiftAdapter.create(keySystem, LegacyCDMClientDelegateBox.retained { [weak delegate] in delegate })
}

// A session of the legacy CDM, with a client whose callbacks go to `delegate`, which owns the adapter.
@_spi(WebKitGPU) @MainActor public func makeLegacyCDMSessionClientSwiftAdapter(
    cdm: WebCore.LegacyCDMClientSwiftAdapter,
    logger: WTF.Logger,
    logIdentifier: UInt64,
    delegate: any LegacyCDMSessionClientDelegate
) -> WebCore.LegacyCDMSessionClientSwiftAdapter {
    // Safety: the box is retained for the adapter, whose destructor releases it.
    unsafe WebCore.LegacyCDMSessionClientSwiftAdapter.create(
        cdm,
        logger,
        logIdentifier,
        LegacyCDMSessionClientDelegateBox.retained { [weak delegate] in delegate }
    )
}

extension WebCore.LegacyCDMClientSwiftAdapter {
    private var delegate: (any LegacyCDMClientDelegate)? {
        unsafe LegacyCDMClientDelegateBox.loadDelegate(m_delegateBox)
    }

    @cxx
    @implementation
    @MainActor
    func delegateMediaPlayer() -> WebCore.RefPtrLegacyCDMMediaPlayer {
        MainActor.preconditionIsolated()
        return delegate?.legacyCDMMediaPlayer() ?? WebCore.RefPtrLegacyCDMMediaPlayer(nil)
    }

    @cxx
    @implementation
    static func releaseDelegateBox(_ box: UInt) {
        unsafe LegacyCDMClientDelegateBox.release(box)
    }
}

extension WebCore.LegacyCDMSessionClientSwiftAdapter {
    private var delegate: (any LegacyCDMSessionClientDelegate)? {
        unsafe LegacyCDMSessionClientDelegateBox.loadDelegate(m_delegateBox)
    }

    @cxx
    @implementation
    @MainActor
    func delegateSendMessage(_ message: WebCore.SharedBuffer?, _ destinationURL: WTF.String) {
        MainActor.preconditionIsolated()
        delegate?.legacyCDMSessionSendMessage(message, destinationURL: destinationURL)
    }

    @cxx
    @implementation
    @MainActor
    func delegateSendError(_ errorCode: UInt16, _ systemCode: UInt32) {
        MainActor.preconditionIsolated()
        delegate?.legacyCDMSessionSendError(errorCode, systemCode: systemCode)
    }

    @cxx
    @implementation
    @MainActor
    func delegateMediaKeysStorageDirectory() -> WTF.String {
        MainActor.preconditionIsolated()
        return delegate?.legacyCDMSessionMediaKeysStorageDirectory() ?? WTF.String()
    }

    @cxx
    @implementation
    static func releaseDelegateBox(_ box: UInt) {
        unsafe LegacyCDMSessionClientDelegateBox.release(box)
    }
}

#endif // ENABLE_LEGACY_ENCRYPTED_MEDIA
