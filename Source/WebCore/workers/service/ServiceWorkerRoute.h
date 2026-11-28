/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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

#include <WebCore/ExceptionData.h>
#include <WebCore/FetchRequestDestination.h>
#include <WebCore/FetchRequestMode.h>
#include <WebCore/RouterSourceDict.h>
#include <WebCore/RouterSourceEnum.h>
#include <WebCore/RunningStatus.h>
#include <optional>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

struct ServiceWorkerRoutePattern {
    ServiceWorkerRoutePattern isolatedCopy() &&;
    ServiceWorkerRoutePattern isolatedCopy() const &;

    // Swift cannot build URLPattern's input variant nor read its ExceptionOr result safely: compiling stays C++.
    bool matches(const URL&) const;

    using Component = String;

    bool shouldIgnoreCase { false };
    Component protocol;
    Component username;
    Component password;
    Component hostname;
    Component port;
    Component pathname;
    Component search;
    Component hash;
};

struct ServiceWorkerRouteCondition {
    WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(ServiceWorkerRouteCondition);

    ServiceWorkerRouteCondition isolatedCopy() &&;
    ServiceWorkerRouteCondition isolatedCopy() const &;
    ServiceWorkerRouteCondition copy() const;

    // The not-condition, by reference so that a match does not copy it, through a subscript that asserts it is set.
    enum class NotConditionTag : uint8_t { Condition };
    bool hasNotCondition() const { return !!notCondition; }
    // Reading the pattern out of the optional would copy its eight strings per match.
    bool urlPatternMatches(const URL& url) const { return !urlPattern || urlPattern->matches(url); }
    const ServiceWorkerRouteCondition& operator[](NotConditionTag) const LIFETIME_BOUND { RELEASE_ASSERT(notCondition); return *notCondition; }

    std::optional<ServiceWorkerRoutePattern> urlPattern;
    String requestMethod;
    std::optional<FetchRequestMode> requestMode;
    std::optional<FetchRequestDestination> requestDestination;
    std::optional<RunningStatus> runningStatus;

    Vector<ServiceWorkerRouteCondition> orConditions;
    std::unique_ptr<ServiceWorkerRouteCondition> notCondition;
};

using RouterSource = Variant<RouterSourceDict, RouterSourceEnum>;

// Swift cannot construct a C++ Variant.
inline RouterSource makeRouterSource(RouterSourceEnum source) { return source; }

struct ServiceWorkerRoute {
    ServiceWorkerRouteCondition condition;
    RouterSource source;

    ServiceWorkerRoute copy() const { return { condition.copy(), source }; }
    ServiceWorkerRoute isolatedCopy() &&;
    ServiceWorkerRoute isolatedCopy() const &;
};

NODELETE std::optional<size_t> countRouterInnerConditions(const ServiceWorkerRouteCondition&, size_t result, size_t depth);
std::optional<ExceptionData> validateServiceWorkerRoute(ServiceWorkerRoute&);

} // namespace WebCore
