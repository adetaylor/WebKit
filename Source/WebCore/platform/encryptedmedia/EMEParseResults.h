/*
 * Copyright (C) 2016-2026 Apple Inc. All rights reserved.
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
 *
 * Copyright (C) 2017 Metrological Group B.V.
 * Copyright (C) 2017 Igalia S.L.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials provided
 *    with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(ENCRYPTED_MEDIA)

#include <WebCore/CDMRequirement.h>
#include <cstdint>

namespace WebCore {

enum class ClearKeyInitDataType : uint8_t {
    Other,
    KeyIDs,
    Cenc,
    WebM,
};

struct ClearKeyInitDataSupport {
    ClearKeyInitDataType type { ClearKeyInitDataType::Other };
    bool supported { false };
};

// The key IDs a ClearKey license request lists: keyIDCount IDs of keyIDSize bytes each, back to back from
// firstKeyIDOffset in the init data. Without key IDs the request is empty, unless initDataIsRequest says that the init
// data itself is the request.
struct ClearKeyLicenseRequest {
    uint32_t firstKeyIDOffset { 0 };
    uint32_t keyIDSize { 0 };
    uint32_t keyIDCount { 0 };
    bool initDataIsRequest { false };
};

enum class ClearKeyUpdateKind : uint8_t {
    Invalid,
    License,
    ReleaseAcknowledgement,
};

// What the ClearKey policy reads of a CDMKeySystemConfiguration and its CDMRestrictions. Padded to 8 bytes for Swift
// interop (rdar://191583570).
struct alignas(8) ClearKeyConfiguration {
    CDMRequirement distinctiveIdentifier { CDMRequirement::Optional };
    CDMRequirement persistentState { CDMRequirement::Optional };
    bool sessionTypesIncludePersistentLicense { false };
    bool distinctiveIdentifierDenied { false };
    bool persistentStateDenied { false };
};

// The FairPlay Streaming init data types this platform has.
enum class FairPlayInitDataType : uint8_t {
    Other,
    Sinf,
    Skd,
    Cenc,
    Mpts,
};

// Padded to 4 bytes for Swift interop (rdar://191583570).
struct alignas(4) FairPlaySessionTypes {
    bool temporary { false };
    bool persistentUsageRecord { false };
    bool persistentLicense { false };
};

// What the FairPlay Streaming policy reads of a CDMKeySystemConfiguration, and the answers of the AVFoundation queries
// it needs.
struct FairPlayConfiguration {
    bool hasSupportedInitDataType { false };
    CDMRequirement distinctiveIdentifier { CDMRequirement::Optional };
    CDMRequirement persistentState { CDMRequirement::Optional };
    FairPlaySessionTypes sessionTypes;
    bool hasAudioCapabilities { false };
    bool hasSupportedAudioCapability { false };
    bool hasVideoCapabilities { false };
    bool hasSupportedVideoCapability { false };
    bool supportsPersistableState { false };
    bool supportsPersistentKeys { false };
};

// The first check of the FairPlay Streaming policy that a configuration fails, if any.
enum class FairPlayConfigurationSupport : uint8_t {
    Supported,
    NoSupportedInitDataType,
    NoContentKeySession,
    DistinctiveIdentifierRequired,
    PersistentStateUnsupported,
    PersistentLicenseUnsupported,
    NoSupportedAudioCapability,
    NoSupportedVideoCapability,
};

// The init data types InitDataRegistry handles. Sinf, Skd and Mpts are FairPlay Streaming's, and only exist where it
// does.
enum class InitDataKind : uint8_t {
    Other,
    KeyIDs,
    Cenc,
    WebM,
    Sinf,
    Skd,
    Mpts,
};

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA)
