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

#include <type_traits>
#include <wtf/CompletionHandler.h>
#include <wtf/NativePromise.h>
#include <wtf/RunLoop.h>

namespace WTF {

// Lets Swift wait for a NativePromise. Swift can't pass a closure to whenSettled(), whose callback type is a template
// parameter, but it can make a CompletionHandler from a closure (WTFCompletionHandler+Extras.swift). Name each
// specialization with a `using` alias, which Swift imports.
template<typename Promise>
struct NativePromiseSettler {
    using Result = typename Promise::Result;
    // A copyable result is passed by value and a move-only one by rvalue reference, as CompletionHandler's Swift
    // constructors require.
    using Handler = CompletionHandler<void(std::conditional_t<std::is_copy_constructible_v<Result>, Result, Result&&>)>;

    // Calls handler with the promise's result on the main run loop. The promise is taken as the Ref its producers
    // return, so that Swift needn't name the promise class itself.
    static void whenSettled(Ref<Promise> promise, Handler&& handler)
    {
        promise->whenSettled(RunLoop::mainSingleton(), [handler = WTF::move(handler)](Result&& result) mutable {
            handler(WTF::move(result));
        });
    }
};

} // namespace WTF

using WTF::NativePromiseSettler;
