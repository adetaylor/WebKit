/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
 * Copyright (C) 2017-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2019-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2018 Metrological Group B.V.
 * Copyright (C) 2018 Igalia S.L
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
 * Copyright (C) 2014-2023 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <wtf/Vector.h>

namespace WebCore {

// A 16-byte key ID, system ID or uuid extended type, in two big-endian words: high holds bytes 0 to 7.
struct InlineBytes16 {
    uint64_t high { 0 };
    uint64_t low { 0 };

    std::array<uint8_t, 16> bytes() const
    {
        std::array<uint8_t, 16> result;
        for (size_t index = 0; index < 8; ++index) {
            result[index] = static_cast<uint8_t>(high >> (56 - 8 * index));
            result[index + 8] = static_cast<uint8_t>(low >> (56 - 8 * index));
        }
        return result;
    }

    // Not defaulted: Swift 6.4 references a defaulted operator== it never emits.
    friend bool operator==(const InlineBytes16& a, const InlineBytes16& b) { return a.high == b.high && a.low == b.low; }
};

// Bytes of the buffer a box was parsed from.
struct ISOByteRange {
    size_t offset { 0 };
    size_t size { 0 };
};

// What ISOTrackEncryptionBox holds after a successful parse.
struct ISOTrackEncryptionFields {
    uint8_t version { 0 };
    uint32_t flags { 0 };
    bool hasDefaultCryptAndSkipByteBlocks { false };
    int8_t defaultCryptByteBlock { 0 };
    int8_t defaultSkipByteBlock { 0 };
    int8_t defaultIsProtected { 0 };
    int8_t defaultPerSampleIVSize { 0 };
    InlineBytes16 defaultKID;
    ISOByteRange defaultConstantIV;
};

// The contents of one of a WebVTT cue's string boxes, when the cue has one.
struct ISOWebVTTCueString {
    bool isPresent { false };
    ISOByteRange contents;
};

// The string boxes of a 'vttc' box (ISO/IEC 14496-30) that ISOWebVTTCue sets its fields from. When a type repeats,
// the last box wins.
struct ISOWebVTTCueRanges {
    ISOWebVTTCueString sourceID;
    ISOWebVTTCueString identifier;
    ISOWebVTTCueString originalStartTime;
    ISOWebVTTCueString settings;
    ISOWebVTTCueString cueText;
};

// A box of an in-band WebVTT sample buffer: its type, its size clamped to the buffer, and its cue if it is a 'vttc'.
struct ISOWebVTTSampleBox {
    uint32_t type { 0 };
    uint64_t size { 0 };
    bool isCue { false };
    ISOWebVTTCueRanges cue;
};

// What an ISOBox shell (ISOBox.h) asks Swift for: ISOBox::parse(view, offset), or ISOBox::read(view).
enum class ISOBoxParseMode : uint8_t {
    Parse,
    ReadWhole,
};

// The fields of the ISOBox shells (iso/ISO*Box.h, ISOFairPlayStreamingPsshBox.h). A shell passes its fields to the
// Swift parser and takes them back, so that a failed parse leaves the box as far as it got. Byte payloads come back as
// ranges of the view; their WasRead flag says the parse replaced the box's payload with them.

struct ISOBoxFields {
    uint64_t size { 0 };
    uint32_t type { 0 };
    bool hasExtendedType { false };
    // In box order.
    InlineBytes16 extendedType;
};

struct ISOFullBoxFields {
    ISOBoxFields box;
    uint8_t version { 0 };
    uint32_t flags { 0 };
};

struct ISOOriginalFormatBoxFields {
    ISOBoxFields box;
    uint32_t dataFormat { 0 };
};

struct ISOSchemeTypeBoxFields {
    ISOFullBoxFields fullBox;
    uint32_t schemeType { 0 };
    uint32_t schemeVersion { 0 };
};

struct ISOTrackEncryptionBoxFields {
    ISOFullBoxFields fullBox;
    bool hasDefaultCryptAndSkipByteBlocks { false };
    int8_t defaultCryptByteBlock { 0 };
    int8_t defaultSkipByteBlock { 0 };
    int8_t defaultIsProtected { 0 };
    int8_t defaultPerSampleIVSize { 0 };
    bool hasDefaultKID { false };
    InlineBytes16 defaultKID;
    bool defaultConstantIVWasRead { false };
    ISOByteRange defaultConstantIV;
};

struct ISOSchemeInformationBoxFields {
    ISOBoxFields box;
    // A new 'tenc' box replaced the scheme specific data.
    bool trackEncryptionWasRead { false };
    ISOTrackEncryptionBoxFields trackEncryption;
};

struct ISOProtectionSchemeInfoBoxFields {
    ISOBoxFields box;
    ISOOriginalFormatBoxFields originalFormat;
    // A new 'schm' or 'schi' box replaced the box's own, and read as far as these fields.
    bool schemeTypeWasRead { false };
    ISOSchemeTypeBoxFields schemeType;
    bool schemeInformationWasRead { false };
    ISOSchemeInformationBoxFields schemeInformation;
};

struct ISOProtectionSystemSpecificHeaderBoxFields {
    ISOFullBoxFields fullBox;
    InlineBytes16 systemID;
    // 16 bytes each.
    bool keyIDsWereRead { false };
    ISOByteRange keyIDs;
    bool dataWasRead { false };
    ISOByteRange data;
};

struct ISOFairPlayStreamingInfoBoxFields {
    ISOFullBoxFields fullBox;
    uint32_t scheme { 0 };
};

struct ISOFairPlayStreamingKeyRequestInfoBoxFields {
    ISOFullBoxFields fullBox;
    // The key ID's Vector capacity, which is how many bytes a parse reads.
    size_t keyIDCapacity { 16 };
    bool keyIDWasRead { false };
    ISOByteRange keyID;
};

// 'fkai' and 'fkcx'.
struct ISOFairPlayStreamingKeyDataBoxFields {
    ISOBoxFields box;
    bool dataWasRead { false };
    ISOByteRange data;
};

struct ISOFairPlayStreamingKeyVersionListBoxFields {
    ISOBoxFields box;
    // Big-endian 32-bit versions the parse appended, even if it then failed.
    ISOByteRange appendedVersions;
};

struct ISOFairPlayStreamingKeyRequestBoxFields {
    ISOBoxFields box;
    ISOFairPlayStreamingKeyRequestInfoBoxFields requestInfo;
    // In: whether the box already has the child, which then can't appear again. Out: whether it has it now; the
    // fields are those of a child the parse added.
    bool hasAssetID { false };
    ISOFairPlayStreamingKeyDataBoxFields assetID;
    bool hasContext { false };
    ISOFairPlayStreamingKeyDataBoxFields context;
    bool hasVersionList { false };
    ISOFairPlayStreamingKeyVersionListBoxFields versionList;
};

// Swift can only name this Vector through the typedef.
using ISOFairPlayStreamingKeyRequestBoxFieldsVector = Vector<ISOFairPlayStreamingKeyRequestBoxFields>;

// The requests the parse appended, even if it then failed, go to a separate vector.
struct ISOFairPlayStreamingInitDataBoxFields {
    ISOBoxFields box;
    ISOFairPlayStreamingInfoBoxFields info;
};

struct ISOFairPlayStreamingPsshBoxFields {
    ISOProtectionSystemSpecificHeaderBoxFields pssh;
    ISOFairPlayStreamingInitDataBoxFields initData;
};

}
