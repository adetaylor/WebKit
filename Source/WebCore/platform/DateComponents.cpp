/*
 * Copyright (C) 2009 Google Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "DateComponents.h"

#include <limits.h>
#include <wtf/ASCIICType.h>
#include <wtf/DateMath.h>
#include <wtf/MathExtras.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/ParsingUtilities.h>
#include <wtf/text/StringParsingBuffer.h>

#include "HTMLMicrosyntaxesSwiftTypes.h"
#include "WebCore-Swift.h"

namespace WebCore {

// DateComponents.swift's copies of the year limits.
static_assert(DateComponents::minimumYear() == 1 && DateComponents::maximumYear() == 275760);

// `function` sets what it finds in `date`, a default DateComponents, and returns whether it is valid.
template<typename F, typename... Arguments> static std::optional<DateComponents> dateComponentsIfValid(DateComponents date, const F& function, const Arguments&... arguments)
{
    return function(arguments..., date) ? std::optional { date } : std::nullopt;
}

std::optional<DateComponents> DateComponents::fromParsingMonth(StringView source)
{
    return source.is8Bit() ? dateComponentsIfValid({ }, dateComponentsFromParsing8, source.span8(), DateComponentsType::Month) : dateComponentsIfValid({ }, dateComponentsFromParsing16, source.span16(), DateComponentsType::Month);
}

std::optional<DateComponents> DateComponents::fromParsingDate(StringView source)
{
    return source.is8Bit() ? dateComponentsIfValid({ }, dateComponentsFromParsing8, source.span8(), DateComponentsType::Date) : dateComponentsIfValid({ }, dateComponentsFromParsing16, source.span16(), DateComponentsType::Date);
}

std::optional<DateComponents> DateComponents::fromParsingWeek(StringView source)
{
    return source.is8Bit() ? dateComponentsIfValid({ }, dateComponentsFromParsing8, source.span8(), DateComponentsType::Week) : dateComponentsIfValid({ }, dateComponentsFromParsing16, source.span16(), DateComponentsType::Week);
}

std::optional<DateComponents> DateComponents::fromParsingTime(StringView source)
{
    return source.is8Bit() ? dateComponentsIfValid({ }, dateComponentsFromParsing8, source.span8(), DateComponentsType::Time) : dateComponentsIfValid({ }, dateComponentsFromParsing16, source.span16(), DateComponentsType::Time);
}

std::optional<DateComponents> DateComponents::fromParsingDateTimeLocal(StringView source)
{
    return source.is8Bit() ? dateComponentsIfValid({ }, dateComponentsFromParsing8, source.span8(), DateComponentsType::DateTimeLocal) : dateComponentsIfValid({ }, dateComponentsFromParsing16, source.span16(), DateComponentsType::DateTimeLocal);
}

std::optional<DateComponents> DateComponents::fromMillisecondsSinceEpochForDate(double ms)
{
    return dateComponentsIfValid({ }, dateComponentsFromMillisecondsSinceEpochForDate, ms);
}

std::optional<DateComponents> DateComponents::fromMillisecondsSinceEpochForDateTimeLocal(double ms)
{
    return dateComponentsIfValid({ }, dateComponentsFromMillisecondsSinceEpochForDateTimeLocal, ms);
}

std::optional<DateComponents> DateComponents::fromMillisecondsSinceEpochForMonth(double ms)
{
    return dateComponentsIfValid({ }, dateComponentsFromMillisecondsSinceEpochForMonth, ms);
}

std::optional<DateComponents> DateComponents::fromMillisecondsSinceEpochForWeek(double ms)
{
    return dateComponentsIfValid({ }, dateComponentsFromMillisecondsSinceEpochForWeek, ms);
}

std::optional<DateComponents> DateComponents::fromMillisecondsSinceMidnight(double ms)
{
    return dateComponentsIfValid({ }, dateComponentsFromMillisecondsSinceMidnight, ms);
}

std::optional<DateComponents> DateComponents::fromMonthsSinceEpoch(double months)
{
    return dateComponentsIfValid({ }, dateComponentsFromMonthsSinceEpoch, months);
}

double DateComponents::millisecondsSinceEpoch() const
{
    return dateComponentsMillisecondsSinceEpoch(*this);
}

double DateComponents::monthsSinceEpoch() const
{
    return dateComponentsMonthsSinceEpoch(*this);
}

String DateComponents::toString(SecondFormat format) const
{
    return dateComponentsToString(*this, std::to_underlying(format));
}

} // namespace WebCore
