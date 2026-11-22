/*
 * Copyright (C) 2018-2025 Apple Inc. All rights reserved.
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

#include "Authenticator.h"
#include "LocalConnection.h"
#include <wtf/SwiftBridging.h>
#include <wtf/UniqueRef.h>

OBJC_CLASS LAContext;

namespace JSC {
class ArrayBuffer;
}

namespace WebCore {
class AuthenticatorAttestationResponse;
class AuthenticatorAssertionResponse;
}

namespace WebKit {

BOOL shouldUseAlternateKeychainAttribute();
// For LocalAuthenticator.swift and WebAuthenticationPanelCredentials.swift, which do not reach AuthenticationServicesCore
// through its soft link.
bool shouldUpdateQuery();
CFDataRef copyEnterpriseAttestationIdentityPersistentReference(const String& rpId) CF_RETURNS_RETAINED;
// For LocalAuthenticator.swift, which cannot hold an LAContext: adds the response's to the Keychain query.
void addAuthenticationContext(const WebCore::AuthenticatorAssertionResponse&, CFMutableDictionaryRef query);

class SWIFT_PRIVATE_FILEID("WebKit/LocalAuthenticator.swift") LocalAuthenticator final : public Authenticator {
public:
    // Here is the FSM.
    // MakeCredential: Init => RequestReceived => PolicyDecided => UserVerified => (Attested) => End
    // GetAssertion: Init => RequestReceived => ResponseSelected => UserVerified => End
    enum class State {
        Init,
        RequestReceived,
        UserVerified,
        Attested,
        ResponseSelected,
        PolicyDecided,
    };

    static Ref<LocalAuthenticator> create(Ref<LocalConnection>&& connection)
    {
        return adoptRef(*new LocalAuthenticator(WTF::move(connection)));
    }

    ~LocalAuthenticator(); // Out of line so the vtable is emitted here: the other virtual members are defined in Swift.

    static void clearAllCredentials();

private:
    explicit LocalAuthenticator(Ref<LocalConnection>&&);

    void makeCredential() final;
    void requestLAContextForUserVerification();
    void continueMakeCredentialAfterReceivingLAContext(LAContext *);
    void continueMakeCredentialAfterUserVerification(SecAccessControlRef, LocalConnection::UserVerification, LAContext *);
    // The halves of makeCredential that Swift implements around the C++ steps that hold the LAContext.
    Vector<uint8_t> userEntityTag() const;
    void continueMakeCredentialAfterCreatingPrivateKey(CFDataRef publicKey, LocalConnection::UserVerification);

    void getAssertion() final;
    // Indices into m_existingCredentials, which Swift reads through existingCredential().
    using CredentialIndices = Vector<size_t>;
    void selectAssertionResponseFromObserver(const CredentialIndices&);
    void continueGetAssertionAfterResponseSelected(Ref<WebCore::AuthenticatorAssertionResponse>&&);
    void continueGetAssertionAfterUserVerification(WebCore::AuthenticatorAssertionResponse&, LocalConnection::UserVerification);
    RefPtr<JSC::ArrayBuffer> alternateBlobIfNecessary() const;

    // By value: an @cxx member cannot take an rvalue reference.
    void receiveException(WebCore::ExceptionData, WebAuthenticationStatus = WebAuthenticationStatus::LAError) const;
    bool validateUserVerification(LocalConnection::UserVerification) const;

    // For LocalAuthenticator.swift: Vector<Ref<AuthenticatorAssertionResponse>> imports as unsafe.
    void appendExistingCredential(WebCore::AuthenticatorAssertionResponse& credential) { m_existingCredentials.append(credential); }
    size_t existingCredentialCount() const { return m_existingCredentials.size(); }
    Ref<WebCore::AuthenticatorAssertionResponse> existingCredential(size_t index) const { return m_existingCredentials[index]; }

    State m_state { State::Init };
    const Ref<LocalConnection> m_connection;
    Vector<Ref<WebCore::AuthenticatorAssertionResponse>> m_existingCredentials;
    Vector<uint8_t> m_provisionalCredentialId;
};

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
