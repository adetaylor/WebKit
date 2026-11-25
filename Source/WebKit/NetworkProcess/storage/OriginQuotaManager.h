/*
 * Copyright (C) 2022 Apple Inc. All rights reserved.
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

#include "QuotaIncreaseRequestIdentifier.h"
#include "SwiftStateKey.h"
#include <wtf/CompletionHandler.h>
#include <wtf/RefCountable.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>

namespace WebKit {

class SWIFT_PRIVATE_FILEID("WebKit/OriginQuotaManager.swift") OriginQuotaManager : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<OriginQuotaManager>, public SwiftStateKey {
    WTF_MAKE_TZONE_ALLOCATED(OriginQuotaManager);
public:
    using GetUsageFunction = Function<uint64_t()>;
    using IncreaseQuotaFunction = Function<void(QuotaIncreaseRequestIdentifier, uint64_t currentQuota, uint64_t currentUsage, uint64_t requestedIncrease)>;
    using NotifySpaceGrantedFunction = Function<void(uint64_t)>;
    struct Parameters {
        uint64_t quota { 0 };
        uint64_t standardReportedQuota { 0 };
        IncreaseQuotaFunction increaseQuotaFunction;
        NotifySpaceGrantedFunction notifySpaceGrantedFunction;
    };
    static Ref<OriginQuotaManager> create(Parameters&&, GetUsageFunction&&);
    ~OriginQuotaManager();
    uint64_t reportedQuota();
    uint64_t usage();
    enum class Decision : bool { Deny, Grant };
    using RequestCallback = CompletionHandler<void(Decision)>;
    using RequestCallbackBox = CompletionHandlerBox<void(Decision)>;
    void requestSpace(uint64_t spaceRequested, RequestCallback&& callback) { requestSpace(spaceRequested, RequestCallbackBox::create(WTF::move(callback)).get()); }
    SWIFT_UNSAFE void requestSpace(uint64_t spaceRequested, RequestCallbackBox&);
    void didIncreaseQuota(QuotaIncreaseRequestIdentifier, std::optional<uint64_t> newQuota);

    NODELETE void resetQuotaUpdatedBasedOnUsageForTesting();
    NODELETE void resetQuotaForTesting();
    void updateParametersForTesting(Parameters&&);

private:
    OriginQuotaManager(Parameters&&, GetUsageFunction&&);
    void initializeState(uint64_t quota, uint64_t standardReportedQuota);
    void updateQuotaForTesting(uint64_t quota, uint64_t standardReportedQuota);
    void destroyState();

    GetUsageFunction m_getUsageFunction;
    IncreaseQuotaFunction m_increaseQuotaFunction;
    NotifySpaceGrantedFunction m_notifySpaceGrantedFunction;
};

} // namespace WebKit
