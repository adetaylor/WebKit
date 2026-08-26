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
#include <wtf/HashSet.h>
#include <wtf/StdLibExtras.h>

namespace IPC {

template<typename> struct ArgumentCoder;

enum class ValidationFailure : uint8_t {
    // An expected race rather than evidence of an attack; ignore the message.
    Ignore,
    // The sender should not have been able to produce this value.
    Terminate,
};

template<typename T> using Validated = Expected<T, ValidationFailure>;

enum class UnvalidatedReason : uint8_t {
    NeedsReview,
    ValidatedElsewhere,
    RequestTarget,
    NotSecuritySensitive,
    IPCTestingAPIIntrospection,
};

// True unless the sender could not have produced this value legitimately. A validation that
// fails with ValidationFailure::Ignore lost a race rather than lied, so the message is dropped
// without implicating the sender; see the EXTRACT_WITH_MESSAGE_CHECK macros.
template<typename T> bool senderCouldHaveProducedValue(const Validated<T>& validated)
{
    return validated.has_value() || validated.error() == ValidationFailure::Ignore;
}

template<typename Validator, typename T> struct IsPreordainedValidator : std::false_type { };

template<typename Validator, typename T>
concept PreordainedValidator = IsPreordainedValidator<std::remove_cvref_t<Validator>, T>::value
    && requires (const std::remove_cvref_t<Validator>& validator, T&& value) {
        { validator.validateUntrusted(WTF::move(value)) } -> std::same_as<Validated<T>>;
    };

template<typename T>
class Untrusted {
public:
    explicit Untrusted(T&& value)
        : m_value(WTF::move(value))
    {
    }

    template<typename Validator> requires PreordainedValidator<Validator, T>
    Validated<T> validate(const Validator& validator) &&
    {
        return validator.validateUntrusted(WTF::move(m_value));
    }

    T unsafeExtractWithoutValidation(UnvalidatedReason) &&
    {
        return WTF::move(m_value);
    }

private:
    friend struct ArgumentCoder<Untrusted<T>>;

    T m_value;
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

// Derived classes must republish the base overloads:
//     using UntrustedContainerValidation<MyAuthority>::validateUntrusted;
template<typename Derived>
class UntrustedContainerValidation {
public:
    template<typename T>
    Validated<std::optional<T>> validateUntrusted(std::optional<T>&& value) const
    {
        if (!value)
            return Validated<std::optional<T>> { std::nullopt };
        auto validated = self().validateUntrusted(WTF::move(*value));
        if (!validated)
            return std::unexpected { validated.error() };
        return Validated<std::optional<T>> { WTF::move(*validated) };
    }

    template<typename Container> requires requires (Container& c) { c.begin(); c.takeAny(); }
    Validated<Container> validateUntrusted(Container&& values) const
    {
        Container validatedValues;
        while (!values.isEmpty()) {
            auto validated = self().validateUntrusted(values.takeAny());
            if (!validated)
                return std::unexpected { validated.error() };
            validatedValues.add(WTF::move(*validated));
        }
        return Validated<Container> { WTF::move(validatedValues) };
    }

private:
    const Derived& self() const { return static_cast<const Derived&>(*this); }
};

template<typename Validator, typename T>
struct IsPreordainedValidator<Validator, std::optional<T>> : IsPreordainedValidator<Validator, T> { };

// HashSet's last template parameter is a non-type parameter, so it must be spelled out.
template<typename Validator, typename T, typename HashArg, typename TraitsArg, typename TableTraitsArg, WTF::ShouldValidateKey shouldValidateKey>
struct IsPreordainedValidator<Validator, HashSet<T, HashArg, TraitsArg, TableTraitsArg, shouldValidateKey>> : IsPreordainedValidator<Validator, T> { };

} // namespace IPC
