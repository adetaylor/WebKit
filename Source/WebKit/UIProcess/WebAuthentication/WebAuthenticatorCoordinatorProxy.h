/*
 * Copyright (C) 2018-2021 Apple Inc. All rights reserved.
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

#if ENABLE(WEB_AUTHN)

#include <wtf/Forward.h>
#include <wtf/Noncopyable.h>
#include <wtf/RefCounted.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>

namespace WebKit {

class WebPageProxy;

// Avoid including WebKit-Swift.h in header files to avoid dependency loops.
class WebAuthenticatorCoordinatorProxySwift;
class WebAuthenticatorCoordinatorProxyMessageForwarder;

// The object C++ callers keep (WebPageProxy, RemotePageProxy, WebPageProxyIOS). The receiver is the Swift
// WebAuthenticatorCoordinatorProxySwift (SwiftTarget= in WebAuthenticatorCoordinatorProxy.messages.in); this object
// owns it and the generated forwarder, and registers the forwarder with the page's main frame process.
class WebAuthenticatorCoordinatorProxy : public RefCounted<WebAuthenticatorCoordinatorProxy> {
    WTF_MAKE_TZONE_ALLOCATED(WebAuthenticatorCoordinatorProxy);
    WTF_MAKE_NONCOPYABLE(WebAuthenticatorCoordinatorProxy);
public:
    static Ref<WebAuthenticatorCoordinatorProxy> create(WebPageProxy&);
    ~WebAuthenticatorCoordinatorProxy();

    WebAuthenticatorCoordinatorProxyMessageForwarder& messageReceiver() const;

#if HAVE(WEB_AUTHN_AS_MODERN)
    void makeActiveConditionalAssertion();
    void recordAutofill(const String& username, const URL&);
#endif

private:
    explicit WebAuthenticatorCoordinatorProxy(WebPageProxy&);

    const std::unique_ptr<WebAuthenticatorCoordinatorProxySwift> m_impl;
    const Ref<WebAuthenticatorCoordinatorProxyMessageForwarder> m_messageForwarder;
    WeakPtr<WebPageProxy> m_webPageProxy;
};

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
