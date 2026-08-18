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

#include "Untrusted.h"
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/ProcessQualified.h>

namespace WebKit {

// The pre-ordained validation procedure for a ProcessQualified identifier that a less
// privileged process sent to a privileged one: the identifier must have been minted by
// the sending process.
//
// This check is what makes a process-qualified identifier meaningful. The object part is
// a per-process monotonic counter starting at 1, so an identifier valid in one web content
// process is trivially guessable from another; the only thing distinguishing them is the
// ProcessIdentifier that ProcessQualified carries alongside it. Where a privileged process
// holds objects belonging to several web content processes - anything under site isolation -
// omitting this check lets one process name another's objects.
//
//     auto layerID = WTF::move(untrustedLayerID).validate(ProcessProvenanceAuthority { sendingProcess });
//     MESSAGE_CHECK_BASE(layerID, connection);
//
class ProcessProvenanceAuthority {
public:
    explicit ProcessProvenanceAuthority(WebCore::ProcessIdentifier sendingProcess)
        : m_sendingProcess(sendingProcess)
    {
    }

    template<typename T>
    IPC::Validated<WebCore::ProcessQualified<T>> validateUntrusted(WebCore::ProcessQualified<T>&& identifier) const
    {
        // A web content process cannot legitimately produce another process's identifier,
        // so a mismatch is evidence of an attack rather than a race worth tolerating.
        if (identifier.processIdentifier() != m_sendingProcess)
            return std::unexpected { IPC::ValidationFailure::Terminate };
        return IPC::Validated<WebCore::ProcessQualified<T>> { WTF::move(identifier) };
    }

private:
    WebCore::ProcessIdentifier m_sendingProcess;
};

} // namespace WebKit

namespace IPC {

template<typename T>
struct IsPreordainedValidator<WebKit::ProcessProvenanceAuthority, WebCore::ProcessQualified<T>> : std::true_type { };

} // namespace IPC
