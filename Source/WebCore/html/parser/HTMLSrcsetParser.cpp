/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
 * Copyright (C) 2013 Google Inc. All rights reserved.
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
#include "HTMLSrcsetParser.h"

#include "CSSSerializationContext.h"
#include "Element.h"
#include "HTMLParserIdioms.h"
#include <ranges>
#include <wtf/OrderedHashSet.h>
#include <wtf/URL.h>
#include <wtf/text/ParsingUtilities.h>
#include <wtf/text/StringBuilder.h>

#include "HTMLMicrosyntaxesSwiftTypes.h"
#include "WebCore-Swift.h"

namespace WebCore {

Vector<ImageCandidate> parseImageCandidatesFromSrcsetAttribute(StringView attribute)
{
    Vector<ImageCandidate> imageCandidates;
    for (unsigned position = 0; ; ) {
        auto candidate = attribute.is8Bit() ? htmlMicrosyntaxNextSrcsetCandidate8(attribute.span8(), position) : htmlMicrosyntaxNextSrcsetCandidate16(attribute.span16(), position);
        if (!candidate.found)
            return imageCandidates;
        imageCandidates.append(ImageCandidate(StringViewWithUnderlyingString(attribute.substring(candidate.start, candidate.length), String()), DescriptorParsingResult(), ImageCandidate::SrcsetOrigin));
        imageCandidates.last().density = candidate.density;
        imageCandidates.last().resourceWidth = candidate.width;
    }
}

void getURLsFromSrcsetAttribute(const Element& element, StringView attribute, OrderedHashSet<URL>& urls)
{
    if (attribute.isEmpty())
        return;

    for (auto& candidate : parseImageCandidatesFromSrcsetAttribute(attribute)) {
        if (candidate.isEmpty())
            continue;
        URL url { element.resolveURLStringIfNeeded(candidate.string.toString()) };
        if (!url.isNull())
            urls.add(url);
    }
}

String replaceURLsInSrcsetAttribute(const Element& element, StringView attribute, const CSS::SerializationContext& context)
{
    if (context.replacementURLStrings.isEmpty())
        return attribute.toString();

    auto imageCandidates = parseImageCandidatesFromSrcsetAttribute(attribute);
    StringBuilder result;
    for (const auto& candidate : imageCandidates) {
        if (&candidate != &imageCandidates[0])
            result.append(", "_s);

        auto candidateString = candidate.string.toString();
        auto resolvedURLString = element.resolveURLStringIfNeeded(candidateString);
        auto replacementURLString = context.replacementURLStrings.get(resolvedURLString);
        if (!replacementURLString.isEmpty())
            result.append(replacementURLString);
        else
            result.append(WTF::move(candidateString));
        if (candidate.density != UninitializedDescriptor)
            result.append(' ', candidate.density, 'x');
        if (candidate.resourceWidth != UninitializedDescriptor)
            result.append(' ', candidate.resourceWidth, 'w');
    }

    return result.toString();
}

static ImageCandidate pickBestImageCandidate(float deviceScaleFactor, Vector<ImageCandidate>& imageCandidates, std::optional<float> sourceSize)
{
    if (imageCandidates.isEmpty())
        return { };
    auto keys = imageCandidates.map<Vector<HTMLMicrosyntaxSrcsetPickKey, 16>>([](auto& candidate) {
        return HTMLMicrosyntaxSrcsetPickKey { candidate.density, candidate.resourceWidth, candidate.srcOrigin() };
    });
    auto index = htmlMicrosyntaxPickBestSrcsetCandidate(deviceScaleFactor, keys.mutableSpan(), sourceSize.value_or(0), sourceSize.has_value());
    auto winner = imageCandidates[index];
    winner.density = keys[index].density;
    return winner;
}

ImageCandidate bestFitSourceForImageAttributes(float deviceScaleFactor, const String& srcAttribute, StringView srcsetAttribute, std::optional<float> sourceSize, NOESCAPE const Function<bool(const ImageCandidate&)>& shouldIgnoreCandidateCallback)
{
    if (srcsetAttribute.isNull()) {
        if (srcAttribute.isNull())
            return { };
        return ImageCandidate(StringViewWithUnderlyingString(srcAttribute, srcAttribute), DescriptorParsingResult(), ImageCandidate::SrcOrigin);
    }

    Vector<ImageCandidate> imageCandidates = parseImageCandidatesFromSrcsetAttribute(srcsetAttribute);

    if (!srcAttribute.isEmpty())
        imageCandidates.append(ImageCandidate(StringViewWithUnderlyingString(srcAttribute, srcAttribute), DescriptorParsingResult(), ImageCandidate::SrcOrigin));

    if (shouldIgnoreCandidateCallback)
        imageCandidates.removeAllMatching(shouldIgnoreCandidateCallback);

    return pickBestImageCandidate(deviceScaleFactor, imageCandidates, sourceSize);
}

} // namespace WebCore
