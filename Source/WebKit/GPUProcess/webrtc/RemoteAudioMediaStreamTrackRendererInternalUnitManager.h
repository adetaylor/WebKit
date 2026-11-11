/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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

#if ENABLE(GPU_PROCESS) && ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

#include "AudioMediaStreamTrackRendererInternalUnitIdentifier.h"
#include "MessageReceiver.h"
#include <CoreAudio/CoreAudioTypes.h>
#include <WebCore/AudioSession.h>
#include <wtf/CompletionHandler.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>

namespace WebCore {
class CAAudioStreamDescription;
}

namespace WebKit {

class GPUConnectionToWebProcess;
struct SharedPreferencesForWebProcess;

// What making a unit gave: its stream format and the frames it asks the web process for at a time, unless it has no format.
struct RemoteAudioTrackUnitCreation {
    AudioStreamBasicDescription format { };
    uint64_t frameChunkSize { 0 };
    bool hasFormat { false };
};

// Receives the MediaStream track renderer unit messages of one web process's connection to the GPU process. Its Swift state
// (RemoteAudioMediaStreamTrackRendererInternalUnitManager.swift), which m_swiftState holds, owns the units, which play out the
// rings the web process writes, and handles the messages, apart from the two whose arguments or reply C++ makes.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebKit/RemoteAudioMediaStreamTrackRendererInternalUnitManager.swift") RemoteAudioMediaStreamTrackRendererInternalUnitManager final : public WebCore::AudioSessionInterruptionObserver
    , private IPC::MessageReceiver {
    WTF_MAKE_TZONE_ALLOCATED(RemoteAudioMediaStreamTrackRendererInternalUnitManager);
    WTF_MAKE_NONCOPYABLE(RemoteAudioMediaStreamTrackRendererInternalUnitManager);
public:
    explicit RemoteAudioMediaStreamTrackRendererInternalUnitManager(GPUConnectionToWebProcess&);
    ~RemoteAudioMediaStreamTrackRendererInternalUnitManager();

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&);

    // Implemented in Swift. clear() is for when the web process's connection closes: the Swift state and the manager keep
    // each other alive until then.
    bool hasUnits() const;
    void notifyLastToCaptureAudioChanged();
    void clear();

    USING_CAN_MAKE_WEAKPTR(IPC::MessageReceiver);

    void ref() const final;
    void deref() const final;
    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

    // For the Swift state.
    bool isLastToCaptureAudio() const;
    bool isAudioSessionInterrupted() const;
    void tryExitIfUnusedAndUnderMemoryPressure();
    // Asks the web process to reset the unit, whose timeline jumped.
    void resetUnit(uint64_t identifier);

private:
    // Messages handled in C++.
    void createUnit(AudioMediaStreamTrackRendererInternalUnitIdentifier, const String&, CompletionHandler<void(std::optional<WebCore::CAAudioStreamDescription>, uint64_t)>&&);
    void setLastDeviceUsed(const String&);

    // WebCore::AudioSessionInterruptionObserver
    void beginAudioSessionInterruption() final;
    void endAudioSessionInterruption(WebCore::AudioSession::MayResume) final;

    // Implemented in Swift: the unit for the identifier, on the device (0: the default one); the default capture unit's
    // speaker may play out a unit for the default device instead.
    RemoteAudioTrackUnitCreation createSwiftUnit(uint64_t identifier, uint32_t outputDevice, bool isDefaultDevice);
    void swiftBeginAudioSessionInterruption();
    void swiftEndAudioSessionInterruption();

    // Implemented in Swift.
    uintptr_t createSwiftState();
    // Unsafe: the state must be the one createSwiftState() made, which only the destructor releases.
    SWIFT_UNSAFE static void destroySwiftState(uintptr_t);
    // m_swiftState, for Swift, which can only read it.
    uintptr_t swiftState() const { return m_swiftState; }

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_gpuConnectionToWebProcess;
    // A retained reference to the Swift state, as an address, from the constructor to the destructor.
    uintptr_t m_swiftState __attribute__((availability(swift, unavailable))) { 0 };
};

} // namespace WebKit;

#endif // ENABLE(GPU_PROCESS) && ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
