/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
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

#include "config.h"
#include "CDMPrivate.h"

#if ENABLE(ENCRYPTED_MEDIA)

#include "CDMKeySystemConfiguration.h"
#include "CDMMediaCapability.h"
#include "CDMRequirement.h"
#include "CDMRestrictions.h"
#include "MediaPlayer.h"
#include "NotImplemented.h"
#include "ParsedContentType.h"
#include "PlatformStrategies.h"
#include "SharedBuffer.h"
#include "WebCore-Swift.h"
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMPrivate);

CDMPrivate::CDMPrivate() = default;
CDMPrivate::~CDMPrivate() = default;

void CDMPrivate::getSupportedConfiguration(CDMKeySystemConfiguration&& candidateConfiguration, LocalStorageAccess access, SupportedConfigurationCallback&& callback)
{
    // https://w3c.github.io/encrypted-media/#get-supported-configuration
    std::optional<CDMKeySystemConfiguration> supportedConfiguration;
    {
        Ref query = CDMSupportedConfigurationQuery::create(*this, WTF::move(candidateConfiguration));
        if (cdmSupportedConfigurationImpl(query.ptr(), access == LocalStorageAccess::Allowed))
            supportedConfiguration = query->takeSupportedConfiguration();
    }
    callback(WTF::move(supportedConfiguration));
}

bool cdmSupportsContentType(const String& contentType, bool isVideo)
{
    // https://w3c.github.io/encrypted-media/#get-supported-capabilities-for-audio-video-type
    // W3C Editor's Draft 09 November 2016

    // 3.4. If content type is an invalid or unrecognized MIME type, continue to the next iteration.
    auto parsedContentType = ParsedContentType::create(contentType);
    if (!parsedContentType)
        return false;

    // 3.5. Let container be the container type specified by content type.
    auto container = parsedContentType->mimeType();

    // 3.6. If the user agent does not support container, continue to the next iteration. The case-sensitivity
    //      of string comparisons is determined by the appropriate RFC.
    // 3.7. Let parameters be the RFC 6381 [RFC6381] parameters, if any, specified by content type.
    // 3.8. If the user agent does not recognize one or more parameters, continue to the next iteration.
    // 3.9. Let media types be the set of codecs and codec constraints specified by parameters. The case-sensitivity
    //      of string comparisons is determined by the appropriate RFC or other specification.
    auto codecs = parsedContentType->parameterValueForName("codecs"_s);
    if (parsedContentType->parameterCount() > (codecs.isEmpty() ? 0 : 1))
        return false;

    // 3.10. If media types is empty:
    if (codecs.isEmpty()) {
        // ↳ If container normatively implies a specific set of codecs and codec constraints:
        // ↳ Otherwise:
        notImplemented();
    }

    // 3.11. If content type is not strictly a audio/video type, continue to the next iteration.
    // NOTE: HLS playlists are not distinguised as having audio or video contents
    // at a MIME type level.
    auto expectedTopLevel = isVideo ? "video/"_s : "audio/"_s;
    if (!container.startsWithIgnoringASCIICase(expectedTopLevel)
        && !equalIgnoringASCIICase(container, "application/vnd.apple.mpegurl"_s)
        && !equalIgnoringASCIICase(container, "application/x-mpegurl"_s))
        return false;

    // 3.13. If the user agent and implementation definitely support playback of encrypted media data for the
    //       combination of container, media types, robustness and local accumulated configuration in combination
    //       with restrictions:
    MediaEngineSupportParameters parameters { .type = ContentType(parsedContentType->contentType()) };
    if (MediaPlayer::supportsType(parameters) == MediaPlayer::SupportsType::IsNotSupported) {
        // Try with Media Source:
        parameters.platformType = PlatformMediaDecodingType::MediaSource;
        if (MediaPlayer::supportsType(parameters) == MediaPlayer::SupportsType::IsNotSupported)
            return false;
    }
    return true;
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMSupportedConfigurationQuery);

Ref<CDMSupportedConfigurationQuery> CDMSupportedConfigurationQuery::create(const CDMPrivate& cdm, CDMKeySystemConfiguration&& candidate)
{
    return adoptRef(*new CDMSupportedConfigurationQuery(cdm, WTF::move(candidate)));
}

CDMSupportedConfigurationQuery::CDMSupportedConfigurationQuery(const CDMPrivate& cdm, CDMKeySystemConfiguration&& candidate)
    : m_cdm(cdm)
    , m_candidate(WTF::move(candidate))
    , m_supportedInitDataTypes(cdm.supportedInitDataTypes())
    , m_supportedRobustnesses(cdm.supportedRobustnesses())
{
}

const Vector<CDMMediaCapability>& CDMSupportedConfigurationQuery::capabilities(bool isVideo) const
{
    return isVideo ? m_candidate.videoCapabilities : m_candidate.audioCapabilities;
}

size_t CDMSupportedConfigurationQuery::count(CDMConfigurationList list) const
{
    switch (list) {
    case CDMConfigurationList::InitDataTypes:
        return m_candidate.initDataTypes.size();
    case CDMConfigurationList::AudioCapabilities:
        return m_candidate.audioCapabilities.size();
    case CDMConfigurationList::VideoCapabilities:
        return m_candidate.videoCapabilities.size();
    case CDMConfigurationList::SessionTypes:
        return m_candidate.sessionTypes.size();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

bool CDMSupportedConfigurationQuery::fact(CDMConfigurationFact fact, bool isVideo, size_t index) const
{
    switch (fact) {
    case CDMConfigurationFact::InitDataTypeIsEmpty:
        return m_candidate.initDataTypes[index].isEmpty();
    case CDMConfigurationFact::InitDataTypeIsSupported:
        return m_supportedInitDataTypes.contains(m_candidate.initDataTypes[index]);
    case CDMConfigurationFact::ContentTypeIsEmpty:
        return capabilities(isVideo)[index].contentType.isEmpty();
    case CDMConfigurationFact::ContentTypeIsSupported:
        return cdmSupportsContentType(capabilities(isVideo)[index].contentType, isVideo);
    case CDMConfigurationFact::RobustnessIsEmpty:
        return capabilities(isVideo)[index].robustness.isEmpty();
    case CDMConfigurationFact::RobustnessIsSupported:
        return m_supportedRobustnesses.contains(capabilities(isVideo)[index].robustness);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

CDMSessionType CDMSupportedConfigurationQuery::sessionType(size_t index) const
{
    return m_candidate.sessionTypes[index];
}

void CDMSupportedConfigurationQuery::startConfiguration(CDMRequirement distinctiveIdentifier, CDMRequirement persistentState)
{
    RELEASE_ASSERT(distinctiveIdentifier <= CDMRequirement::NotAllowed && persistentState <= CDMRequirement::NotAllowed);
    m_configuration = { };
    m_configuration.label = m_candidate.label;
    m_configuration.distinctiveIdentifier = distinctiveIdentifier;
    m_configuration.persistentState = persistentState;
}

void CDMSupportedConfigurationQuery::addEntry(CDMConfigurationList list, size_t index)
{
    switch (list) {
    case CDMConfigurationList::InitDataTypes:
        m_configuration.initDataTypes.append(m_candidate.initDataTypes[index]);
        return;
    case CDMConfigurationList::AudioCapabilities:
        m_configuration.audioCapabilities.append(m_candidate.audioCapabilities[index]);
        return;
    case CDMConfigurationList::VideoCapabilities:
        m_configuration.videoCapabilities.append(m_candidate.videoCapabilities[index]);
        return;
    case CDMConfigurationList::SessionTypes:
        m_configuration.sessionTypes.append(m_candidate.sessionTypes[index]);
        return;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

void CDMSupportedConfigurationQuery::addSessionType(CDMSessionType sessionType)
{
    RELEASE_ASSERT(sessionType <= CDMSessionType::PersistentLicense);
    m_configuration.sessionTypes.append(sessionType);
}

static CDMRestrictions restrictions(bool distinctiveIdentifierDenied, bool persistentStateDenied)
{
    CDMRestrictions restrictions;
    restrictions.distinctiveIdentifierDenied = distinctiveIdentifierDenied;
    restrictions.persistentStateDenied = persistentStateDenied;
    return restrictions;
}

bool CDMSupportedConfigurationQuery::answer(CDMConfigurationQuestion question, CDMSessionType sessionType, bool distinctiveIdentifierDenied, bool persistentStateDenied) const
{
    RELEASE_ASSERT(sessionType <= CDMSessionType::PersistentLicense);
    switch (question) {
    case CDMConfigurationQuestion::SupportsConfiguration:
        return m_cdm->supportsConfiguration(m_configuration);
    case CDMConfigurationQuestion::SupportsConfigurationWithRestrictions:
        return m_cdm->supportsConfigurationWithRestrictions(m_configuration, restrictions(distinctiveIdentifierDenied, persistentStateDenied));
    case CDMConfigurationQuestion::SupportsSessionType:
        return m_cdm->supportsSessionTypeWithConfiguration(sessionType, m_configuration);
    case CDMConfigurationQuestion::DistinctiveIdentifiersAreUniquePerOriginAndClearable:
        return m_cdm->distinctiveIdentifiersAreUniquePerOriginAndClearable(m_configuration);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

CDMRequirement CDMSupportedConfigurationQuery::requirement(CDMConfigurationRequirementQuestion question, bool distinctiveIdentifierDenied, bool persistentStateDenied) const
{
    switch (question) {
    case CDMConfigurationRequirementQuestion::DistinctiveIdentifiers:
        return m_cdm->distinctiveIdentifiersRequirement(m_configuration, restrictions(distinctiveIdentifierDenied, persistentStateDenied));
    case CDMConfigurationRequirementQuestion::PersistentState:
        return m_cdm->persistentStateRequirement(m_configuration, restrictions(distinctiveIdentifierDenied, persistentStateDenied));
    }
    RELEASE_ASSERT_NOT_REACHED();
}

std::optional<CDMKeySystemConfiguration> CDMSupportedConfigurationQuery::takeSupportedConfiguration()
{
    if (!m_supported)
        return std::nullopt;
    return std::exchange(m_configuration, { });
}

}

#endif
