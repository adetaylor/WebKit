/*
 * Copyright (C) 2022-2023 Apple Inc. All rights reserved.
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

#if HAVE(SCREEN_CAPTURE_KIT)

#include <WebCore/CaptureDevice.h>
#include <WebCore/DisplayCapturePromptType.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Forward.h>
#include <wtf/Noncopyable.h>

namespace WebCore {

// The getDisplayMedia prompt for callers in C++. ScreenCaptureKitSharingSessionManager.swift shows the picker and
// keeps what it picks for the capturer.
class ScreenCaptureKitSharingSessionManager {
    WTF_MAKE_NONCOPYABLE(ScreenCaptureKitSharingSessionManager);
public:
    WEBCORE_EXPORT static ScreenCaptureKitSharingSessionManager& singleton();
    WEBCORE_EXPORT static bool isAvailable();

    WEBCORE_EXPORT void promptForGetDisplayMedia(DisplayCapturePromptType, CompletionHandler<void(std::optional<CaptureDevice>)>&&);
    WEBCORE_EXPORT void cancelGetDisplayMediaPrompt();

    void promptDidComplete(std::optional<CaptureDevice>&&);

private:
    friend class NeverDestroyed<ScreenCaptureKitSharingSessionManager>;
    ScreenCaptureKitSharingSessionManager() = default;

    CompletionHandler<void(std::optional<CaptureDevice>)> m_completionHandler;
};

} // namespace WebCore

#endif // HAVE(SCREEN_CAPTURE_KIT)
