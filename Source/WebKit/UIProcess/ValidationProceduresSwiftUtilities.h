/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#include "Connection.h"
#include "MessageNames.h"
#include "Untrusted.h"
#include "ValidationProcedures.h"
#include <WebCore/SecurityOriginData.h>
#include <optional>
#include <wtf/text/WTFString.h>

// The Swift spelling of EXTRACT_WITH_MESSAGE_CHECK (MessageCheck.swift) is built over these. Swift calls neither
// IPC::Untrusted<T>::validate(), which Untrusted.h makes unavailable to it, nor unsafeExtractWithoutValidation()
// without `unsafe`: each function here opens an IPC::Untrusted with the validation procedure the C++ handlers use,
// and does the check itself, so that no Swift caller can treat a failed validation as an ignored one.

namespace WebCore {
// As the message generator spells it for a Swift receiver's parameter.
using UntrustedSecurityOriginData = IPC::Untrusted<WebCore::SecurityOriginData>;
}

namespace WebKit {

// Marks the message being dispatched on `connection` invalid, which terminates its sender once its handler returns.
// A Swift handler is async, so a check can fail after the handler's first suspension, when the message is no longer
// being dispatched; the sender is then terminated directly, rather than not at all.
inline void markCurrentlyDispatchedMessageAsInvalidOrTerminateSender(IPC::Connection& connection, const String& reason)
{
    if (IPC::Connection::MessageDispatchScope::currentFor(connection)) {
        connection.markCurrentlyDispatchedMessageAsInvalid(reason);
        return;
    }
#if ENABLE(IPC_TESTING_API)
    if (connection.ignoreInvalidMessageForTesting())
        return;
#endif
    connection.dispatchDidReceiveInvalidMessage(IPC::MessageName::Invalid, { });
}

// EXTRACT_WITH_MESSAGE_CHECK_BASE with ProcessSpeaksForDomain { connection }: the origin, once the sending process is
// found to speak for its domain. On std::nullopt the handler replies with its completion value and returns: the
// validation could not be sure, and the message is ignored, or it failed, and the message check failed here, logged
// as from Swift's function, file and line.
inline std::optional<WebCore::SecurityOriginData> extractProcessSpeaksForDomainWithMessageCheck(IPC::Untrusted<WebCore::SecurityOriginData> untrustedOrigin, IPC::Connection& connection, const String& function, const String& file, unsigned line)
{
    auto validated = WTF::move(untrustedOrigin).validate(ProcessSpeaksForDomain { connection });
    if (!IPC::valueMayBeLegitimate(validated)) [[unlikely]] {
        auto reason = "Message check failed: IPC::valueMayBeLegitimate(ProcessSpeaksForDomain)"_s;
        // Logs, and crashes under test, as MESSAGE_CHECK_COMPLETION_BASE does before it marks the message.
        IPC::Connection::logFailedMessageCheck(reason, function, file, line);
        markCurrentlyDispatchedMessageAsInvalidOrTerminateSender(connection, reason);
        return std::nullopt;
    }
    if (!validated)
        return std::nullopt;
    return WTF::move(*validated);
}

// The caller documents where the value is checked, as for IPC::UnvalidatedReason::ValidatedElsewhere.
inline std::optional<WebCore::SecurityOriginData> extractValidatedElsewhere(IPC::Untrusted<std::optional<WebCore::SecurityOriginData>> untrustedOrigin)
{
    return WTF::move(untrustedOrigin).unsafeExtractWithoutValidation(IPC::UnvalidatedReason::ValidatedElsewhere);
}

} // namespace WebKit
