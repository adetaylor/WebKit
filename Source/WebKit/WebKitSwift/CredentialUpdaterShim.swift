// Copyright (C) 2025 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

import Foundation

// This file replaces the normally-dynamically-generated
// CredentialUpdaterShim.swift which can't build in the presence of
// the Swift WebBackForwardList due to rdar://161645690
// TODO undo this

public typealias String = Swift.String

@objc(CredentialUpdaterShim)
@available(macOS 16.0, iOS 19.0, *)
public final class CredentialUpdaterShim: NSObject {
    @objc
    @available(macOS 16.0, iOS 19.0, *)
    public static func signalUnknownCredential(relyingPartyIdentifier: String, credentialID: Data) async throws {
    }

    @objc
    @available(macOS 16.0, iOS 19.0, *)
    public static func signalAllAcceptedCredentials(
        relyingPartyIdentifier: String,
        userHandle: Data,
        acceptedCredentialIDs: [Data]
    ) async throws {
    }

    @objc
    @available(macOS 16.0, iOS 19.0, *)
    public static func signalCurrentUserDetails(relyingPartyIdentifier: String, userHandle: Data, newName: String) async throws {
    }
}
