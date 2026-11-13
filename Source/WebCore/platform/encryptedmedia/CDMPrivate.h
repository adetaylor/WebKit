/*
 * Copyright (C) 2016 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(ENCRYPTED_MEDIA)

#include <WebCore/CDMInstance.h>
#include <WebCore/CDMRequirement.h>
#include <WebCore/CDMSessionType.h>
#include <WebCore/CDMKeySystemConfiguration.h>
#include <wtf/CheckedPtr.h>
#include <wtf/CheckedRef.h>
#include <wtf/Forward.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>

#if !RELEASE_LOG_DISABLED
namespace WTF {
class Logger;
}
#endif

namespace WebCore {

struct CDMMediaCapability;
struct CDMRestrictions;
class SharedBuffer;

enum class CDMPrivateLocalStorageAccess : bool {
    NotAllowed,
    Allowed,
};

class CDMPrivateClient {
public:
    virtual ~CDMPrivateClient() = default;

#if !RELEASE_LOG_DISABLED
    virtual const Logger& logger() const = 0;
#endif
};

class CDMPrivate : public CanMakeWeakPtr<CDMPrivate>, public CanMakeCheckedPtr<CDMPrivate> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(CDMPrivate, WEBCORE_EXPORT);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(CDMPrivate);
public:
    WEBCORE_EXPORT virtual ~CDMPrivate();

#if !RELEASE_LOG_DISABLED
    virtual void setLogIdentifier(uint64_t) { };
#endif

    using LocalStorageAccess = CDMPrivateLocalStorageAccess;

    using SupportedConfigurationCallback = Function<void(std::optional<CDMKeySystemConfiguration>)>;
    WEBCORE_EXPORT virtual void getSupportedConfiguration(CDMKeySystemConfiguration&& candidateConfiguration, LocalStorageAccess, SupportedConfigurationCallback&&);

    virtual Vector<String> supportedInitDataTypes() const = 0;
    virtual bool supportsConfiguration(const CDMKeySystemConfiguration&) const = 0;
    virtual bool supportsConfigurationWithRestrictions(const CDMKeySystemConfiguration&, const CDMRestrictions&) const = 0;
    virtual bool supportsSessionTypeWithConfiguration(const CDMSessionType&, const CDMKeySystemConfiguration&) const = 0;
    virtual Vector<String> supportedRobustnesses() const = 0;
    virtual CDMRequirement distinctiveIdentifiersRequirement(const CDMKeySystemConfiguration&, const CDMRestrictions&) const = 0;
    virtual CDMRequirement persistentStateRequirement(const CDMKeySystemConfiguration&, const CDMRestrictions&) const = 0;
    virtual bool distinctiveIdentifiersAreUniquePerOriginAndClearable(const CDMKeySystemConfiguration&) const = 0;
    virtual RefPtr<CDMInstance> createInstance() = 0;
    virtual void loadAndInitialize() = 0;
    virtual bool supportsServerCertificates() const = 0;
    virtual bool supportsSessions() const = 0;
    virtual bool supportsInitData(const String&, const SharedBuffer&) const = 0;
    virtual RefPtr<SharedBuffer> sanitizeResponse(const SharedBuffer&) const = 0;
    virtual std::optional<String> sanitizeSessionId(const String&) const = 0;

protected:
    WEBCORE_EXPORT CDMPrivate();
};

// The lists of a configuration that the configuration algorithm (EMEConfiguration.swift) reads and makes.
enum class CDMConfigurationList : uint8_t {
    InitDataTypes,
    AudioCapabilities,
    VideoCapabilities,
    SessionTypes,
};

// What the configuration algorithm asks of an entry of a candidate configuration.
enum class CDMConfigurationFact : uint8_t {
    InitDataTypeIsEmpty,
    InitDataTypeIsSupported,
    ContentTypeIsEmpty,
    ContentTypeIsSupported,
    RobustnessIsEmpty,
    RobustnessIsSupported,
};

// What the configuration algorithm asks a CDM of a configuration.
enum class CDMConfigurationQuestion : uint8_t {
    SupportsConfiguration,
    SupportsConfigurationWithRestrictions,
    SupportsSessionType,
    DistinctiveIdentifiersAreUniquePerOriginAndClearable,
};

enum class CDMConfigurationRequirementQuestion : uint8_t {
    DistinctiveIdentifiers,
    PersistentState,
};

// Whether a content type is a valid MIME type whose only parameter, if any, is "codecs", whose container is strictly
// audio or video (or an HLS playlist), and which MediaPlayer may support, from a URL or Media Source.
WEBCORE_EXPORT bool cdmSupportsContentType(const String& contentType, bool isVideo);

// What CDMPrivate::getSupportedConfiguration() hands the configuration algorithm (EMEConfiguration.swift): its CDM's
// answers about a candidate configuration's entries and about the configurations it makes of them, named by their
// indices, and the configuration it supports.
class CDMSupportedConfigurationQuery : public RefCounted<CDMSupportedConfigurationQuery> {
    WTF_MAKE_TZONE_ALLOCATED(CDMSupportedConfigurationQuery);
public:
    static Ref<CDMSupportedConfigurationQuery> create(const CDMPrivate&, CDMKeySystemConfiguration&& candidate);

    size_t count(CDMConfigurationList) const;
    bool fact(CDMConfigurationFact, bool isVideo, size_t index) const;
    CDMSessionType sessionType(size_t index) const;
    CDMRequirement distinctiveIdentifier() const { return m_candidate.distinctiveIdentifier; }
    CDMRequirement persistentState() const { return m_candidate.persistentState; }

    // The configuration that the questions are about, or that is supported.
    void startConfiguration(CDMRequirement distinctiveIdentifier, CDMRequirement persistentState);
    void addEntry(CDMConfigurationList, size_t index);
    void addSessionType(CDMSessionType);

    bool answer(CDMConfigurationQuestion, CDMSessionType, bool distinctiveIdentifierDenied, bool persistentStateDenied) const;
    CDMRequirement requirement(CDMConfigurationRequirementQuestion, bool distinctiveIdentifierDenied, bool persistentStateDenied) const;

    void setSupported() { m_supported = true; }
    std::optional<CDMKeySystemConfiguration> takeSupportedConfiguration();

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { RefCounted<CDMSupportedConfigurationQuery>::ref(); }
    void deref() const { RefCounted<CDMSupportedConfigurationQuery>::deref(); }
#endif

private:
    CDMSupportedConfigurationQuery(const CDMPrivate&, CDMKeySystemConfiguration&&);

    const Vector<CDMMediaCapability>& capabilities(bool isVideo) const LIFETIME_BOUND;

    const CheckedRef<const CDMPrivate> m_cdm;
    const CDMKeySystemConfiguration m_candidate;
    const Vector<String> m_supportedInitDataTypes;
    const Vector<String> m_supportedRobustnesses;
    CDMKeySystemConfiguration m_configuration;
    bool m_supported { false };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

}

#endif
