/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "CoreAudioCaptureUnit.h"

#if ENABLE(MEDIA_STREAM)

#include "AudioOutputUnit.h"
#include "Logging.h"

#include <AudioUnit/AudioUnit.h>
#include <AudioUnit/AudioUnitProperties.h>
#include <wtf/cocoa/TypeCastsCocoa.h>

#if PLATFORM(MAC)
#include <CoreAudio/AudioHardware.h>
#endif

#include <pal/cocoa/AVFAudioSoftLink.h>

#if HAVE(AVAUDIOAPPLICATION)

OBJC_CLASS WebCoreAudioInputMuteChangeListener;

namespace WebCore {
void registerAudioInputMuteChangeListener(WebCoreAudioInputMuteChangeListener*);
void unregisterAudioInputMuteChangeListener(WebCoreAudioInputMuteChangeListener*);
}

@interface WebCoreAudioInputMuteChangeListener : NSObject {
}

- (void)start;
- (void)stop;
- (void)handleMuteStatusChangedNotification:(NSNotification*)notification;
@end

@implementation WebCoreAudioInputMuteChangeListener
- (void)start
{
    WebCore::registerAudioInputMuteChangeListener(self);
}

- (void)stop
{
    WebCore::unregisterAudioInputMuteChangeListener(self);
}

- (void)handleMuteStatusChangedNotification:(NSNotification*)notification
{
    RetainPtr newMuteState = dynamic_objc_cast<NSNumber>([notification.userInfo valueForKey:AVAudioApplicationMuteStateKey]);
    WebCore::CoreAudioCaptureUnit::defaultSingleton().handleMuteStatusChangedNotification(newMuteState.get().boolValue);
}

@end
#endif // HAVE(AVAUDIOAPPLICATION)

namespace WebCore {

#if HAVE(AVAUDIOAPPLICATION)
static AVAudioApplication *getSharedAVAudioApplication()
{
    return PAL::isAVFAudioFrameworkAvailable() ? (AVAudioApplication *)[PAL::getAVAudioApplicationClassSingleton() sharedInstance] : nil;
}

#if PLATFORM(MAC)
static void setNoopInputMuteStateChangeHandler(AVAudioApplication *audioApplication, bool shouldAddHandler)
{
    @try {
        NSError *error = nil;
        if (shouldAddHandler) {
            // We set the handler to enable receiving AVAudioApplicationInputMuteStateChangeNotification notifications.
            [audioApplication setInputMuteStateChangeHandler:^(BOOL) {
                return YES;
            } error:&error];
        } else
            [audioApplication setInputMuteStateChangeHandler:nil error:&error];
        RELEASE_LOG_ERROR_IF(error, WebRTC, "WebCoreAudioInputMuteChangeListener failed to set mute state change handler due to error: %@, shouldAddHandler: %d.", error.localizedDescription, shouldAddHandler);
    } @catch (NSException *exception) {
        RELEASE_LOG_ERROR(WebRTC, "WebCoreAudioInputMuteChangeListener failed to set mute state change handler due to exception: %@, shouldAddHandler: %d.", exception, shouldAddHandler);
    }
}
#endif

void registerAudioInputMuteChangeListener(WebCoreAudioInputMuteChangeListener *listener)
{
    RetainPtr audioApplication = getSharedAVAudioApplication();
    if (!audioApplication)
        return;

#if PLATFORM(MAC)
    setNoopInputMuteStateChangeHandler(audioApplication, true);
#endif

    [[NSNotificationCenter defaultCenter] addObserver:listener selector:@selector(handleMuteStatusChangedNotification:) name:AVAudioApplicationInputMuteStateChangeNotification object:audioApplication];

}

void unregisterAudioInputMuteChangeListener(WebCoreAudioInputMuteChangeListener *listener)
{
    RetainPtr audioApplication = getSharedAVAudioApplication();
    if (!audioApplication)
        return;

#if PLATFORM(MAC)
    setNoopInputMuteStateChangeHandler(audioApplication, false);
#endif

    [[NSNotificationCenter defaultCenter] removeObserver:listener];
}
#endif // HAVE(AVAUDIOAPPLICATION)

#if PLATFORM(MAC) && HAVE(VOICEACTIVITYDETECTION)
static bool manageSpeechActivityListener(uint32_t deviceID, bool enable)
{
    uint32_t failedStep = 0;
    auto error = AudioCaptureUnitHandle::setDeviceVoiceActivityDetection(deviceID, enable, failedStep);
    if (failedStep == 1)
        RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit manageSpeechActivityListener unable to set kVoiceActivityDetectionEnable, error %d (%.4s)", (int)error, (char*)&error);
    else if (error && !enable)
        RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit manageSpeechActivityListener unable to remove kVoiceActivityDetectionEnable listener, error %d (%.4s)", (int)error, (char*)&error);
    else if (error)
        RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit manageSpeechActivityListener unable to set kVoiceActivityDetectionEnable listener, error %d (%.4s)", (int)error, (char*)&error);
    return !error;
}
#endif // PLATFORM(MAC) && HAVE(VOICEACTIVITYDETECTION)

// A mock fakes voice activity every 100 ms while its output is muted.
bool CoreAudioCaptureUnit::setUnitVoiceActivityDetection(bool shouldEnable)
{
    if (m_ioUnit->isMock()) {
        m_mockVoiceActivityDetectionEnabled = shouldEnable;
        if (!m_mockVoiceDetectionTimer)
            lazyInitialize(m_mockVoiceDetectionTimer, makeUnique<Timer>(*this, &CoreAudioCaptureUnit::mockVoiceDetected));
        if (!m_mockVoiceActivityDetectionEnabled || !m_mockOutputMuted)
            m_mockVoiceDetectionTimer->stop();
        else
            m_mockVoiceDetectionTimer->startRepeating(100_ms);
        return true;
    }

#if HAVE(VOICEACTIVITYDETECTION)
#if PLATFORM(MAC)
    auto deviceID = CoreAudioCaptureUnit::defaultSingleton().captureDeviceID();
    if (!deviceID && defaultInputDevice(deviceID))
        return false;
    return manageSpeechActivityListener(deviceID, shouldEnable);
#else
    auto err = m_ioUnit->setMutedSpeechActivityListener(shouldEnable);
    RELEASE_LOG_ERROR_IF(err, WebRTC, "CoreAudioCaptureInternalUnit::setVoiceActivityDetection failed activation, error %d (%.4s)", (int)err, (char*)&err);
    return !err;
#endif
#else
    UNUSED_PARAM(shouldEnable);
    return false;
#endif // HAVE(VOICEACTIVITYDETECTION)
}

void CoreAudioCaptureUnit::setMuteStatusChangedCallback(Function<void(bool)>&& callback)
{
    if (!m_muteStatusChangedCallback && !callback)
        return;

    ASSERT(!!m_muteStatusChangedCallback != !!callback);
    m_muteStatusChangedCallback = WTF::move(callback);

#if HAVE(AVAUDIOAPPLICATION)
    if (!m_muteStatusChangedCallback) {
        [m_inputMuteChangeListener stop];
        m_inputMuteChangeListener = nullptr;
        return;
    }

    m_inputMuteChangeListener = adoptNS([[WebCoreAudioInputMuteChangeListener alloc] init]);
    [m_inputMuteChangeListener start];
#endif
}

void CoreAudioCaptureUnit::setMutedState(bool isMuted)
{
#if HAVE(AVAUDIOAPPLICATION)
    RetainPtr audioApplication = getSharedAVAudioApplication();
    if (!audioApplication)
        return;

    NSError *error = nil;
    [audioApplication setInputMuted:isMuted error:&error];
    RELEASE_LOG_ERROR_IF(error, WebRTC, "CoreAudioCaptureUnit::setMutedState failed due to error: %@.", error.localizedDescription);
#else
    UNUSED_PARAM(isMuted);
#endif
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
