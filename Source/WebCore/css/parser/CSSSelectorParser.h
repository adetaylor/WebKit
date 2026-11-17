// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2020 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#pragma once

#include "CSSParserContext.h"
#include "CSSParserEnum.h"
#include "CSSParserTokenRange.h"
#include "CSSSelectorList.h"
#include "CSSSelectorParserContext.h"
#include "MutableCSSSelector.h"
#include "PseudoElementIdentifier.h"
#include "StyleSheetContents.h"

namespace WebCore {

class CSSParserTokenRange;
class CSSSelectorList;
class StyleSheetContents;
class StyleRule;

class CSSSelectorParser {
public:
    // Unsafe to Swift, which infers std::optional<CSSSelectorList> Sendable though its copies share a non-atomic count.
    SWIFT_UNSAFE WEBCORE_EXPORT static std::optional<CSSSelectorList> parseSelectorList(const String&, const CSSParserContext&, StyleSheetContents* = nullptr, CSSParserEnum::NestedContext = { });

    WEBCORE_EXPORT static CSSSelectorList resolveNestingParent(const CSSSelectorList& nestedSelectorList, const CSSSelectorList* parentResolvedSelectorList, bool parentRuleIsScope = false);
    WEBCORE_EXPORT static CSSSelectorList makeHasScopeSelector(const Vector<const CSSSelector*>& compoundSelectors);
    WEBCORE_EXPORT static CSSSelectorList makeHasArgumentWithScope(const CSSSelector& hasArgument, const CSSSelector& scopeSelector);
    WEBCORE_EXPORT static std::optional<Style::PseudoElementIdentifier> parsePseudoElement(StringView, const CSSSelectorParserContext&);
};

struct ParsedQualifiedName {
    AtomString name;
    AtomString namespacePrefix;
};
std::optional<ParsedQualifiedName> consumeQualifiedName(CSSParserTokenRange&);

SWIFT_UNSAFE std::optional<CSSSelectorList> parseCSSSelectorList(CSSParserTokenRange, const CSSSelectorParserContext&, StyleSheetContents* = nullptr, CSSParserEnum::NestedContext = { });

} // namespace WebCore
