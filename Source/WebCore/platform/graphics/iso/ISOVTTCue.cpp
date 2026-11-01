/*
 * Copyright (C) 2014-2026 Apple Inc. All rights reserved.
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

#include "config.h"
#include "ISOVTTCue.h"

#include <wtf/CrossThreadCopier.h>
#include <wtf/JSONValues.h>
#include <wtf/URL.h>
#include <wtf/text/AtomString.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

ISOWebVTTCue::ISOWebVTTCue(const MediaTime& presentationTime, const MediaTime& duration)
    : m_presentationTime(presentationTime)
    , m_duration(duration)
{
}

ISOWebVTTCue::ISOWebVTTCue(const MediaTime& presentationTime, const MediaTime& duration, std::span<const uint8_t> source, const ISOWebVTTCueRanges& ranges)
    : ISOWebVTTCue(presentationTime, duration)
{
    setStrings(source, ranges);
}

ISOWebVTTCue::ISOWebVTTCue(const MediaTime& presentationTime, const MediaTime& duration, String&& cueID, String&& cueText, String&& settings, String&& sourceID, String&& originalStartTime)
    : m_presentationTime(presentationTime)
    , m_duration(duration)
    , m_sourceID(WTF::move(sourceID))
    , m_identifier(WTF::move(cueID))
    , m_originalStartTime(WTF::move(originalStartTime))
    , m_settings(WTF::move(settings))
    , m_cueText(WTF::move(cueText))
{
}

ISOWebVTTCue::ISOWebVTTCue() = default;
ISOWebVTTCue::ISOWebVTTCue(ISOWebVTTCue&&) = default;
ISOWebVTTCue::~ISOWebVTTCue() = default;

// An empty string box gives an empty string, and invalid UTF-8 a null one.
static String stringFromContents(std::span<const uint8_t> source, const ISOByteRange& contents)
{
    if (!contents.size)
        return emptyString();
    return String::fromUTF8(source.subspan(contents.offset, contents.size));
}

void ISOWebVTTCue::setStrings(std::span<const uint8_t> source, const ISOWebVTTCueRanges& ranges)
{
    if (ranges.sourceID.isPresent)
        m_sourceID = stringFromContents(source, ranges.sourceID.contents);
    if (ranges.identifier.isPresent)
        m_identifier = AtomString { stringFromContents(source, ranges.identifier.contents) };
    if (ranges.originalStartTime.isPresent)
        m_originalStartTime = stringFromContents(source, ranges.originalStartTime.contents);
    if (ranges.settings.isPresent)
        m_settings = stringFromContents(source, ranges.settings.contents);
    if (ranges.cueText.isPresent)
        m_cueText = stringFromContents(source, ranges.cueText.contents);
}

#if ENABLE(WEBCORE_SWIFT)

bool ISOWebVTTCue::read(std::span<const uint8_t> view)
{
    ISOWebVTTCueRanges ranges;
    bool result = readWebVTTCueImpl({ view }, ranges);
    setStrings(view, ranges);
    return result;
}

bool ISOWebVTTCue::parse(std::span<const uint8_t> view, unsigned& offset)
{
    ISOWebVTTCueRanges ranges;
    bool result = parseWebVTTCueImpl({ view }, offset, ranges);
    setStrings(view, ranges);
    return result;
}

#endif // ENABLE(WEBCORE_SWIFT)

String ISOWebVTTCue::toJSONString() const
{
    auto object = JSON::Object::create();

    object->setString("text"_s, m_cueText);
    object->setString("sourceId"_s, encodeWithURLEscapeSequences(m_sourceID));
    object->setString("id"_s, encodeWithURLEscapeSequences(m_identifier));

    object->setString("originalStartTime"_s, encodeWithURLEscapeSequences(m_originalStartTime));
    object->setString("settings"_s, encodeWithURLEscapeSequences(m_settings));

    object->setDouble("presentationTime"_s, m_presentationTime.toDouble());
    object->setDouble("duration"_s, m_duration.toDouble());

    return object->toJSONString();
}

ISOWebVTTCue ISOWebVTTCue::isolatedCopy() const &
{
    return { m_presentationTime, m_duration, crossThreadCopy(m_identifier), crossThreadCopy(m_cueText), crossThreadCopy(m_settings), crossThreadCopy(m_sourceID), crossThreadCopy(m_originalStartTime) };
}

ISOWebVTTCue ISOWebVTTCue::isolatedCopy() &&
{
    return { m_presentationTime, m_duration, crossThreadCopy(WTF::move(m_identifier)), crossThreadCopy(WTF::move(m_cueText)), crossThreadCopy(WTF::move(m_settings)), crossThreadCopy(WTF::move(m_sourceID)), crossThreadCopy(WTF::move(m_originalStartTime)) };
}

} // namespace WebCore
