/*
 * Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

#import "config.h"
#import "ScreenCaptureKitSharingSessionManager.h"

#if HAVE(SCREEN_CAPTURE_KIT)

#import "DisplayCaptureSourceHandle.h"
#import <wtf/MainThread.h>
#import <wtf/NeverDestroyed.h>

namespace WebCore {

bool ScreenCaptureKitSharingSessionManager::isAvailable()
{
    return ScreenCaptureKitSharingSession::isPickerAvailable();
}

ScreenCaptureKitSharingSessionManager& ScreenCaptureKitSharingSessionManager::singleton()
{
    ASSERT(isMainThread());
    static NeverDestroyed<ScreenCaptureKitSharingSessionManager> manager;
    return manager.get();
}

void ScreenCaptureKitSharingSessionManager::promptForGetDisplayMedia(DisplayCapturePromptType promptType, CompletionHandler<void(std::optional<CaptureDevice>)>&& completionHandler)
{
    ASSERT(isAvailable());
    ASSERT(!m_completionHandler);

    m_completionHandler = WTF::move(completionHandler);
    ScreenCaptureKitSharingSession::prompt(promptType);
}

void ScreenCaptureKitSharingSessionManager::cancelGetDisplayMediaPrompt()
{
    ScreenCaptureKitSharingSession::cancelPrompt();
}

void ScreenCaptureKitSharingSessionManager::promptDidComplete(std::optional<CaptureDevice>&& device)
{
    if (auto completionHandler = std::exchange(m_completionHandler, nullptr))
        completionHandler(WTF::move(device));
}

void screenCaptureKitPromptDidComplete(bool hasDevice, bool isWindow, uint32_t deviceID, NSString *title)
{
    std::optional<CaptureDevice> device;
    if (hasDevice) {
        if (isWindow)
            device = CaptureDevice(String::number(deviceID), CaptureDevice::DeviceType::Window, title, emptyString(), true);
        else
            device = CaptureDevice(String::number(deviceID), CaptureDevice::DeviceType::Screen, "Screen "_str, emptyString(), true);
    }
    ScreenCaptureKitSharingSessionManager::singleton().promptDidComplete(WTF::move(device));
}

} // namespace WebCore

#endif // HAVE(SCREEN_CAPTURE_KIT)
