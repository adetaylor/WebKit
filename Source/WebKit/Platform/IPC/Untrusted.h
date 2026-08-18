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
#include <optional>
#include <wtf/Expected.h>
#include <wtf/StdLibExtras.h>

namespace IPC {

template<typename> struct ArgumentCoder;

// Why a validation attempt did not yield a usable value.
enum class ValidationFailure : uint8_t {
    // The sending process had no authority over the value, but this is an expected
    // race rather than evidence of an attack. Ignore the message.
    Ignore,

    // The sending process had no authority over the value and should not have been
    // able to produce it. Terminate the connection.
    Terminate,
};

template<typename T> using Validated = Expected<T, ValidationFailure>;

// Justification for bypassing validation entirely. Every use of
// Untrusted::extractWithoutValidation() must name one of these, and is tracked in
// Source/WebKit/Scripts/webkit/untrusted_origins.tracking.in.
enum class UnvalidatedReason : uint8_t {
    // Predates this mechanism and has not yet been audited. These are the burn-down
    // list: each one is a code path where a privileged process trusts a web-content
    // supplied origin or URL without proving the sender had authority over it.
    LegacyNeedsAudit,

    // The value is validated by an equivalent check elsewhere on this code path.
    ValidatedElsewhere,

    // The value is not used to make a security decision.
    NotSecuritySensitive,

    // Introspection by the IPC testing API, which does not act on the value.
    IPCTestingAPIIntrospection,
};

// Opt-in marker identifying the pre-ordained validation procedures. Specializing this
// is what makes a type usable with Untrusted::validate(), and is deliberately confined
// to the designated headers listed in untrusted_origins.py.
template<typename Validator, typename T> struct IsPreordainedValidator : std::false_type { };

template<typename Validator, typename T>
concept PreordainedValidator = IsPreordainedValidator<std::remove_cvref_t<Validator>, T>::value
    && requires (const std::remove_cvref_t<Validator>& validator, T&& value) {
        { validator.validateUntrusted(WTF::move(value)) } -> std::same_as<Validated<T>>;
    };

// A value of type T that arrived over IPC from a less privileged process, and which
// therefore carries no authority. The wrapper has no accessors: the only ways to reach
// the underlying value are validate(), which runs one of the pre-ordained validation
// procedures, and extractWithoutValidation(), which must name a justification.
//
// The wire format is identical to that of T, and senders are unaffected: the generated
// message class takes and encodes a T, while its Arguments tuple - and therefore the
// receiving handler's signature - is Untrusted<T>.
template<typename T>
class Untrusted {
public:
    Untrusted() = default;

    explicit Untrusted(T&& value)
        : m_value(WTF::move(value))
    {
    }

    template<typename Validator> requires PreordainedValidator<Validator, T>
    Validated<T> validate(const Validator& validator) &&
    {
        return validator.validateUntrusted(WTF::move(m_value));
    }

    T extractWithoutValidation(UnvalidatedReason) &&
    {
        return WTF::move(m_value);
    }

private:
    friend struct ArgumentCoder<Untrusted<T>>;

    T m_value { };
};

template<typename T> struct ArgumentCoder<Untrusted<T>> {
    template<typename Encoder>
    static void encode(Encoder& encoder, const Untrusted<T>& untrusted)
    {
        encoder << untrusted.m_value;
    }

    template<typename Decoder>
    static std::optional<Untrusted<T>> decode(Decoder& decoder)
    {
        auto value = decoder.template decode<T>();
        if (!value)
            return std::nullopt;
        return Untrusted<T> { WTF::move(*value) };
    }
};

} // namespace IPC
