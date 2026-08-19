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

// SwiftData<T> is the storage for the Swift-side state of a C++ class whose
// member functions are implemented in Swift with `@cxx @implementation`. T is a
// Swift struct; its fields are visible as native Swift stored properties from
// within those member function implementations, and are inaccessible to C++.
// The value is constructed by forwarding the constructor arguments to T's
// Swift initializer, and destroyed with the enclosing C++ object.
//
// FIXME: neither this type nor `@cxx @implementation` exists yet. This
// declaration is a stand-in which lets the C++ half of an implementation be
// written and compiled; the resulting binary has no Swift state and cannot run.

namespace WTF {

template<typename SwiftStruct>
class SwiftData {
public:
    template<typename... Arguments>
    explicit SwiftData(Arguments&&...) { }

    SwiftData(const SwiftData&) = delete;
    SwiftData& operator=(const SwiftData&) = delete;
};

} // namespace WTF

using WTF::SwiftData;
