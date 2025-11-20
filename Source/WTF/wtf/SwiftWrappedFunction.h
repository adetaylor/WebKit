/*
 * Copyright (C) 2016-2019 Apple Inc. All rights reserved.
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

#include <wtf/Function.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>

namespace WTF {

template<typename> class SWIFT_ESCAPABLE SwiftWrappedFunction;

template <typename Out, typename... In>
class SWIFT_ESCAPABLE SwiftWrappedFunction<Out(In...)>: public RefCounted<SwiftWrappedFunction<Out(In...)>> {
public:
    static Ref<SwiftWrappedFunction<Out(In...)>> create(WTF::Function<Out(In...)>&& fn) {
        return adoptRef(*new SwiftWrappedFunction(WTFMove(fn)));
    }

    Out call(In... in)
    {
        return m_fn(std::forward<In>(in)...);
    }

private:
    SwiftWrappedFunction(WTF::Function<Out(In...)>&& fn) : m_fn(WTFMove(fn)) {}
    Function<Out(In...)> m_fn;
    // The following line requires rdar://160696723, so if it doesn't build,
    // you're probably not using a sufficiently recent swiftc.
};


} // namespace WTF
