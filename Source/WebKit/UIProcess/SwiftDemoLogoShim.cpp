/*
 * Copyright (C) 2014-2025 Apple Inc. All rights reserved.
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

#include <config.h>
#if ENABLE(SWIFT_DEMO_URI_SCHEME)
#include "SwiftDemoLogoShim.h"

#pragma clang diagnostic push
// TODO figure out
#pragma clang diagnostic ignored "-Warc-bridge-casts-disallowed-in-nonarc"
#include <WebKit-Swift-CPP.h>
#pragma clang diagnostic pop

using namespace WebKit;

WTF::Vector<uint8_t> WebKit::getSwiftLogoDataWrapper() {
    auto logo2 = getSwiftLogoData();
    WTF::Vector<uint8_t> logo3;
    logo3.reserveCapacity(logo2.getCount());
    for (swift::Int i=0;i<logo2.getCount();i++) {
        // Perhaps there's a better (safe) way to get to the logo's data
        // but it's not yet clear.
        logo3.append(logo2[i]);
    }
    return logo3;
}

#endif
