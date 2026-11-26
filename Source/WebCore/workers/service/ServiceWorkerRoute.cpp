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

#include "config.h"
#include "ServiceWorkerRoute.h"

#include "ExceptionOr.h"
#include "HTTPParsers.h"
#include "URLPattern.h"
#include "URLPatternInit.h"
#include "URLPatternOptions.h"
#include <wtf/CrossThreadCopier.h>

namespace WebCore {

// https://w3c.github.io/ServiceWorker/#count-router-inner-conditions
std::optional<size_t> countRouterInnerConditions(const ServiceWorkerRouteCondition& routeCondition, size_t result, size_t depth)
{
    --result;
    if (!result || !depth)
        return { };

    for (auto& condition : routeCondition.orConditions) {
        auto orResult = countRouterInnerConditions(condition, result, depth - 1);
        if (!orResult)
            return { };
        result = *orResult;
    }

    if (routeCondition.notCondition) {
        auto notResult = countRouterInnerConditions(*routeCondition.notCondition, result, depth - 1);
        if (!notResult)
            return { };
        result = *notResult;
    }
    return result;
}

static ExceptionOr<Ref<URLPattern>> compileRoutePattern(const ServiceWorkerRoutePattern& pattern)
{
    URLPatternInit init {
        .protocol = pattern.protocol,
        .username = pattern.username,
        .password = pattern.password,
        .hostname = pattern.hostname,
        .port = pattern.port,
        .pathname = pattern.pathname,
        .search = pattern.search,
        .hash = pattern.hash,
        .baseURL = { },
    };
    return URLPattern::createWithoutRegExpSupport(WTF::move(init), { }, { .ignoreCase = pattern.shouldIgnoreCase });
}

static inline std::optional<ExceptionData> validateServiceWorkerRouteCondition(ServiceWorkerRouteCondition& condition)
{
    if (condition.urlPattern) {
        auto maybePattern = compileRoutePattern(*condition.urlPattern);
        if (maybePattern.hasException()) {
            auto exception = maybePattern.releaseException();
            return ExceptionData { exception.code(), exception.releaseMessage() };
        }
    }

    for (auto& orCondition : condition.orConditions) {
        if (auto exception = validateServiceWorkerRouteCondition(orCondition))
            return *exception;
    }

    if (condition.notCondition) {
        if (auto exception = validateServiceWorkerRouteCondition(*condition.notCondition))
            return *exception;
    }

    if (!condition.requestMethod.isNull()) {
        if (!isValidHTTPToken(condition.requestMethod))
            return ExceptionData { ExceptionCode::TypeError, "Method is not a valid HTTP token."_s };
        if (isForbiddenMethod(condition.requestMethod))
            return ExceptionData { ExceptionCode::TypeError, "Method is forbidden."_s };

        condition.requestMethod = normalizeHTTPMethod(condition.requestMethod);
    }

    return { };
}

std::optional<ExceptionData> validateServiceWorkerRoute(ServiceWorkerRoute& route)
{
    return validateServiceWorkerRouteCondition(route.condition);
}

bool ServiceWorkerRoutePattern::matches(const URL& url) const
{
    auto maybePattern = compileRoutePattern(*this);
    if (maybePattern.hasException())
        return false;
    Ref pattern = maybePattern.releaseReturnValue();
    return pattern->testWithoutRegExp(url);
}

ServiceWorkerRouteCondition ServiceWorkerRouteCondition::isolatedCopy() &&
{
    std::unique_ptr<ServiceWorkerRouteCondition> notConditionCopy;
    if (notCondition)
        notConditionCopy = makeUnique<ServiceWorkerRouteCondition>(WTF::move(*notCondition));
    return {
        crossThreadCopy(WTF::move(urlPattern)),
        crossThreadCopy(WTF::move(requestMethod)),
        requestMode,
        requestDestination,
        runningStatus,
        crossThreadCopy(WTF::move(orConditions)),
        WTF::move(notConditionCopy)
    };
}

ServiceWorkerRouteCondition ServiceWorkerRouteCondition::isolatedCopy() const &
{
    std::unique_ptr<ServiceWorkerRouteCondition> notConditionCopy;
    if (notCondition)
        notConditionCopy = makeUnique<ServiceWorkerRouteCondition>(notCondition->isolatedCopy());
    return {
        crossThreadCopy(urlPattern),
        crossThreadCopy(requestMethod),
        requestMode,
        requestDestination,
        runningStatus,
        crossThreadCopy(orConditions),
        WTF::move(notConditionCopy)
    };
}

ServiceWorkerRouteCondition ServiceWorkerRouteCondition::copy() const
{
    std::unique_ptr<ServiceWorkerRouteCondition> notConditionCopy;
    if (notCondition)
        notConditionCopy = makeUnique<ServiceWorkerRouteCondition>(notCondition->copy());

    return {
        urlPattern,
        requestMethod,
        requestMode,
        requestDestination,
        runningStatus,
        orConditions.map([](auto& condition) { return condition.copy(); }),
        WTF::move(notConditionCopy)
    };
}

static RouterSource crossThreadCopyRouterSource(RouterSource&& source)
{
    return WTF::switchOn(source, [](RouterSourceDict& dict) -> RouterSource {
        return WTF::move(dict).isolatedCopy();
    }, [](auto value) -> RouterSource {
        return value;
    });
}

static RouterSource crossThreadCopyRouterSource(const RouterSource& source)
{
    return WTF::switchOn(source, [](const RouterSourceDict& dict) -> RouterSource {
        return dict.isolatedCopy();
    }, [](auto value) -> RouterSource {
        return value;
    });
}

ServiceWorkerRoute ServiceWorkerRoute::isolatedCopy() &&
{
    return {
        WTF::move(condition).isolatedCopy(),
        crossThreadCopyRouterSource(WTF::move(source))
    };
}

ServiceWorkerRoute ServiceWorkerRoute::isolatedCopy() const &
{
    return {
        condition.isolatedCopy(),
        crossThreadCopyRouterSource(source)
    };
}

} // namespace WebCore
