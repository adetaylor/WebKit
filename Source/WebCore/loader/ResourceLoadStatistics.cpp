/*
 * Copyright (C) 2016-2022 Apple Inc. All rights reserved.
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
#include "ResourceLoadStatistics.h"

#include "PublicSuffixStore.h"
#include <wtf/MainThread.h>
#include <wtf/text/ASCIILiteral.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringHash.h>

namespace WebCore {

static Seconds timestampResolution { 5_s };

static void appendBoolean(StringBuilder& builder, ASCIILiteral label, bool flag)
{
    builder.append("    "_s, label, ": "_s, flag ? "Yes"_s : "No"_s);
}

static void appendHashSet(StringBuilder& builder, const String& label, const HashSet<RegistrableDomain>& hashSet)
{
    if (hashSet.isEmpty())
        return;

    builder.append("    "_s, label, ":\n"_s);
    for (auto& entry : hashSet)
        builder.append("        "_s, entry.string(), '\n');
}

#if ENABLE(WEB_API_STATISTICS)
template<typename HashSetType>
static void appendHashSet(StringBuilder& builder, const String& label, const HashSetType& hashSet)
{
    if (hashSet.isEmpty())
        return;

    builder.append("    "_s, label, ":\n"_s);
    for (auto& entry : hashSet)
        builder.append("        "_s, entry, '\n');
}

static ASCIILiteral navigatorAPIEnumToString(NavigatorAPIsAccessed navigatorEnum)
{
    switch (navigatorEnum) {
    case NavigatorAPIsAccessed::MimeTypes:
        return "mimeTypes"_s;
    case NavigatorAPIsAccessed::CookieEnabled:
        return "cookieEnabled"_s;
    case NavigatorAPIsAccessed::Plugins:
        return "plugins"_s;
    case NavigatorAPIsAccessed::UserAgent:
        return "userAgent"_s;
    case NavigatorAPIsAccessed::AppVersion:
        return "appVersion"_s;
    }
    ASSERT_NOT_REACHED();
    return "Invalid navigator API"_s;
}

static ASCIILiteral screenAPIEnumToString(ScreenAPIsAccessed screenEnum)
{
    switch (screenEnum) {
    case ScreenAPIsAccessed::Height:
        return "height"_s;
    case ScreenAPIsAccessed::Width:
        return "width"_s;
    case ScreenAPIsAccessed::ColorDepth:
        return "colorDepth"_s;
    case ScreenAPIsAccessed::AvailLeft:
        return "availLeft"_s;
    case ScreenAPIsAccessed::AvailTop:
        return "availTop"_s;
    case ScreenAPIsAccessed::AvailHeight:
        return "availHeight"_s;
    case ScreenAPIsAccessed::AvailWidth:
        return "availWidth"_s;
    }
    ASSERT_NOT_REACHED();
    return "Invalid screen API"_s;
}

static void appendNavigatorAPIOptionSet(StringBuilder& builder, const OptionSet<NavigatorAPIsAccessed>& optionSet)
{
    if (optionSet.isEmpty())
        return;
    builder.append("    navigatorFunctionsAccessed:\n"_s);
    for (auto navigatorAPI : optionSet)
        builder.append("        "_s, navigatorAPIEnumToString(navigatorAPI), '\n');
}

static void appendScreenAPIOptionSet(StringBuilder& builder, const OptionSet<ScreenAPIsAccessed>& optionSet)
{
    if (optionSet.isEmpty())
        return;
    builder.append("    screenFunctionsAccessed:\n"_s);
    for (auto screenAPI : optionSet) {
        builder.append("        "_s, screenAPIEnumToString(screenAPI), '\n');
    }
}
#endif

static bool hasHadRecentUserInteraction(Seconds interactionTimeSeconds)
{
    return interactionTimeSeconds > Seconds(0) && WallTime::now().secondsSinceEpoch() - interactionTimeSeconds < 24_h;
}

String ResourceLoadStatistics::toString() const
{
    StringBuilder builder;
    builder.append("Registrable domain: "_s, registrableDomain.string(), '\n');

    // User interaction
    appendBoolean(builder, "hadUserInteraction"_s, hadUserInteraction);
    builder.append("\n    mostRecentUserInteraction: "_s, hasHadRecentUserInteraction(mostRecentUserInteractionTime.secondsSinceEpoch()) ? "within 24 hours\n"_s : "-1\n"_s);
    appendBoolean(builder, "grandfathered"_s, grandfathered);
    builder.append('\n');

    // Storage access
    appendHashSet(builder, "storageAccessUnderTopFrameDomains"_s, storageAccessUnderTopFrameDomains);

    // Top frame stats
    appendHashSet(builder, "topFrameUniqueRedirectsTo"_s, topFrameUniqueRedirectsTo);
    appendHashSet(builder, "topFrameUniqueRedirectsFrom"_s, topFrameUniqueRedirectsFrom);
    appendHashSet(builder, "topFrameLinkDecorationsFrom"_s, topFrameLinkDecorationsFrom);
    appendBoolean(builder, "gotLinkDecorationFromPrevalentResource"_s, gotLinkDecorationFromPrevalentResource);
    builder.append('\n');
    appendHashSet(builder, "topFrameLoadedThirdPartyScripts"_s, topFrameLoadedThirdPartyScripts);

    // Subframe stats
    appendHashSet(builder, "subframeUnderTopFrameDomains"_s, subframeUnderTopFrameDomains);

    // Subresource stats
    appendHashSet(builder, "subresourceUnderTopFrameDomains"_s, subresourceUnderTopFrameDomains);
    appendHashSet(builder, "subresourceUniqueRedirectsTo"_s, subresourceUniqueRedirectsTo);
    appendHashSet(builder, "subresourceUniqueRedirectsFrom"_s, subresourceUniqueRedirectsFrom);

    // Prevalent Resource
    appendBoolean(builder, "isPrevalentResource"_s, isPrevalentResource);
    builder.append('\n');
    appendBoolean(builder, "isVeryPrevalentResource"_s, isVeryPrevalentResource);
    builder.append("\n    dataRecordsRemoved: "_s, dataRecordsRemoved, '\n');

#if ENABLE(WEB_API_STATISTICS)
    appendHashSet(builder, "fontsFailedToLoad"_s, fontsFailedToLoad);
    appendHashSet(builder, "fontsSuccessfullyLoaded"_s, fontsSuccessfullyLoaded);
    appendHashSet(builder, "topFrameRegistrableDomainsWhichAccessedWebAPIs"_s, topFrameRegistrableDomainsWhichAccessedWebAPIs);
    appendNavigatorAPIOptionSet(builder, navigatorFunctionsAccessed);
    appendScreenAPIOptionSet(builder, screenFunctionsAccessed);
    appendHashSet(builder, "canvasTextWritten"_s, canvasActivityRecord.textWritten);
    appendBoolean(builder, "canvasReadData"_s, canvasActivityRecord.wasDataRead);
    builder.append("\n\n"_s);
#endif

    return builder.toString();
}

WallTime ResourceLoadStatistics::reduceTimeResolution(WallTime time)
{
    return WallTime::fromRawSeconds(std::floor(time.secondsSinceEpoch() / timestampResolution) * timestampResolution.seconds());
}

}
