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

#include "MessageReceiver.h"
#include <concepts>
#include <type_traits>
#include <wtf/Function.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/WeakPtr.h>

namespace IPC {

enum class ReceiverName : uint8_t;

// Keeps the messages to one destination coming to a receiver written in Swift, which its owner registered, until it goes.
class SwiftReceiverRegistration final : public RefCounted<SwiftReceiverRegistration> {
public:
    static Ref<SwiftReceiverRegistration> create(Function<void()>&& unregister)
    {
        return adoptRef(*new SwiftReceiverRegistration(WTF::move(unregister)));
    }

    ~SwiftReceiverRegistration()
    {
        m_unregister();
    }

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy.
    void ref() const { RefCounted<SwiftReceiverRegistration>::ref(); }
    void deref() const { RefCounted<SwiftReceiverRegistration>::deref(); }
#endif

private:
    explicit SwiftReceiverRegistration(Function<void()>&& unregister)
        : m_unregister(WTF::move(unregister))
    {
    }

    Function<void()> m_unregister;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

template<typename> struct IsRefOfMessageReceiver : std::false_type { };
template<typename T> struct IsRefOfMessageReceiver<Ref<T>> : std::bool_constant<std::derived_from<T, MessageReceiver>> { };

// Registers a Swift receiver's message forwarder for the messages to identifier, with the receiver that owns it, which
// routes them from its connection with addSwiftReceiver() until removeSwiftReceiver(). Null if the owner's connection has
// gone. For Swift, which passes the owner, a foreign reference type, as a pointer to it, and which can't pass a forwarder
// as the MessageReceiver it is, but can pass the Ref to it that it holds. The static_asserts are there because the
// constraints aren't enforced for Swift callers.
template<typename OwnerPointer, typename ForwarderRef>
SwiftReceiverRegistration* WTF_NULLABLE registerSwiftReceiver(const OwnerPointer& ownerPointer, const ForwarderRef& forwarder, ReceiverName receiverName, uint64_t identifier) SWIFT_RETURNS_RETAINED
{
    static_assert(std::is_pointer_v<OwnerPointer>);
    static_assert(IsRefOfMessageReceiver<ForwarderRef>::value);
    auto& owner = *ownerPointer;
    if (!owner.addSwiftReceiver(receiverName, identifier, forwarder.get()))
        return nullptr;
    return &SwiftReceiverRegistration::create([weakOwner = WeakPtr { owner }, receiverName, identifier] {
        if (RefPtr owner = weakOwner.get())
            owner->removeSwiftReceiver(receiverName, identifier);
    }).leakRef();
}

} // namespace IPC
