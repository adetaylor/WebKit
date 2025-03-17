/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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

#include "config.h"
#include "NavigatorRot13.h"

#include "Chrome.h"
#include "ChromeClient.h"
#include "Modules/rot13/Rot13Request.h"
#include "Rot13Result.h"
#include "ExceptionCode.h"
#include "JSDOMPromiseDeferred.h"
#include "Navigator.h"
#include "Page.h"
#include "wtf/Compiler.h"
#include <WebCore/IDLTypes.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(NavigatorRot13);

void NavigatorRot13::rot13(Navigator& navigator, const String& plaintext, unsigned long rotation, Ref<DeferredPromise>&& promise)
{
    from(navigator).rot13(WTFMove(plaintext), rotation, WTFMove(promise));
}

void NavigatorRot13::rot13(const String& plaintext, unsigned long rotation, Ref<DeferredPromise>&& promise)
{
    RefPtr frame = m_navigator->frame();
    if (!frame || !frame->isMainFrame() || !frame->page()) {
        promise->reject(ExceptionCode::NotAllowedError);
        return;
    }

    Rot13Request request(plaintext, rotation);

    frame->page()->chrome().client().rot13(request, [promise = WTFMove(promise)] (Rot13Result result) {
        if (result.success) {
            promise->resolve<IDLDOMString>(result.ciphertext);
        } else {
            promise->reject(ExceptionCode::NotSupportedError);
        }
    });
}

NavigatorRot13& NavigatorRot13::from(Navigator& navigator)
{
    if (auto supplement = static_cast<NavigatorRot13*>(Supplement<Navigator>::from(&navigator, supplementName())))
        return *supplement;

    auto newSupplement = makeUnique<NavigatorRot13>(navigator);
    auto supplement = newSupplement.get();
    provideTo(&navigator, supplementName(), WTFMove(newSupplement));
    return *supplement;
}

} // namespace WebCore
