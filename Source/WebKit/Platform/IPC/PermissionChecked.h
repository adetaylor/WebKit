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

#include <concepts>
#include <wtf/Expected.h>
#include <wtf/StdLibExtras.h>

namespace IPC {

template<typename> struct ArgumentCoder;

// Why a recipient may not be given a value.
enum class PermissionFailure : uint8_t {
    // The recipient has no permission, but this is an expected race rather than
    // evidence of an attack. Send nothing, or an empty value.
    Deny,

    // The recipient could not legitimately have reached this point. Terminate the
    // connection.
    Terminate,
};

template<typename T> class PermissionChecked;

template<typename T> using PermissionCheckResult = Expected<PermissionChecked<T>, PermissionFailure>;

// Justification for sending without a permission check. Every use of
// withoutPermissionCheck() must name one of these.
enum class UncheckedReason : uint8_t {
    // Predates this mechanism and has not yet been audited. The burn-down list.
    LegacyNeedsAudit,

    // An equivalent permission check already happens on this code path.
    CheckedElsewhere,

    // The value is not sensitive.
    NotSecuritySensitive,

    // Introspection by the IPC testing API, which does not send the value.
    IPCTestingAPIIntrospection,
};

// Opt-in marker identifying the pre-ordained permission checks. Specializing this is what
// makes a type usable as the checker argument of PermissionChecked::check(), and is
// deliberately confined to the designated headers listed in permission_checked_data.py.
template<typename Checker, typename T> struct IsPreordainedPermissionChecker : std::false_type { };

template<typename Checker, typename T>
concept PreordainedPermissionChecker = IsPreordainedPermissionChecker<std::remove_cvref_t<Checker>, T>::value
    && requires (const std::remove_cvref_t<Checker>& checker, T&& value) {
        { checker.checkPermissionToReceive(WTF::move(value)) } -> std::same_as<Expected<T, PermissionFailure>>;
    };

// A value of type T that a privileged process has proven the recipient is permitted to
// receive. Sensitive data travelling from a privileged process to a less privileged one
// is declared as PermissionChecked<T> in the .messages.in file, so the generated message
// class - and therefore every sender - can only be constructed from a token, and the only
// ways to mint one are:
//
//   check(checker, value)                     - runs one of the pre-ordained permission
//                                               checks, which confirm the receiving
//                                               process is entitled to the value
//   withoutPermissionCheck(value, reason)     - bypass, and must name a justification
//
// The wire format is identical to that of T, and recipients are unaffected: the message
// class stores and encodes a PermissionChecked<T>, while its Arguments tuple - and
// therefore the receiving handler's signature - is a plain T.
//
// There is deliberately no decoder. The token can only be minted in the process holding
// the authority to mint it, and can never arrive over IPC.
template<typename T>
class PermissionChecked {
public:
    template<typename Checker> requires PreordainedPermissionChecker<Checker, T>
    static PermissionCheckResult<T> check(const Checker& checker, T&& value)
    {
        auto permitted = checker.checkPermissionToReceive(WTF::move(value));
        if (!permitted)
            return std::unexpected { permitted.error() };
        return PermissionChecked { WTF::move(*permitted) };
    }

    static PermissionChecked withoutPermissionCheck(T&& value, UncheckedReason)
    {
        return PermissionChecked { WTF::move(value) };
    }

    // A default-constructed value discloses nothing, so no permission is needed to send
    // one. This is how a denied check, or a cancelled reply, answers.
    static PermissionChecked empty()
    {
        return PermissionChecked { T { } };
    }

    PermissionChecked(PermissionChecked&&) = default;
    PermissionChecked& operator=(PermissionChecked&&) = default;
    PermissionChecked(const PermissionChecked&) = delete;
    PermissionChecked& operator=(const PermissionChecked&) = delete;

private:
    friend struct ArgumentCoder<PermissionChecked<T>>;

    explicit PermissionChecked(T&& value)
        : m_value(WTF::move(value))
    {
    }

    T m_value;
};

template<typename T> struct ArgumentCoder<PermissionChecked<T>> {
    template<typename Encoder>
    static void encode(Encoder& encoder, PermissionChecked<T>&& permissionChecked)
    {
        encoder << WTF::move(permissionChecked.m_value);
    }
};

template<typename> struct AsyncReplyError;

template<typename T> struct AsyncReplyError<PermissionChecked<T>> {
    static PermissionChecked<T> create() { return PermissionChecked<T>::empty(); }
};

// The wrapper is invisible on the wire and on the receiving side, so the machinery that
// checks a handler's signature against a message's decoded types has to compare the two
// modulo the wrapper. See HandleMessage.h.
template<typename T> struct RemovePermissionChecked {
    using Type = T;
};

template<typename T> struct RemovePermissionChecked<PermissionChecked<T>> {
    using Type = T;
};

template<typename> struct RemovePermissionCheckedFromTuple;

template<typename... Ts> struct RemovePermissionCheckedFromTuple<std::tuple<Ts...>> {
    using Type = std::tuple<typename RemovePermissionChecked<Ts>::Type...>;
};

} // namespace IPC
