/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
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

#if ENABLE(GPU_PROCESS) && ENABLE(WEB_AUDIO) && PLATFORM(COCOA)

#include "MessageReceiver.h"
#include "RemoteAudioDestinationIdentifier.h"
#include <wtf/HashMap.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

class GPUConnectionToWebProcess;
struct SharedPreferencesForWebProcess;

// The output unit of a destination that iOS's spatial experience is set on, 0 if there's no such destination, and whether
// its web process preferred a spatial experience when it made it.
struct RemoteAudioDestinationSpatialTarget {
    uint64_t outputUnitIdentifier { 0 };
    bool prefersSpatialAudioExperience { false };
};

// Receives the audio destination messages of one web process's connection to the GPU process. Its Swift state
// (RemoteAudioDestinationManager.swift), which m_swiftState holds, owns the destinations, which play out the rings the web
// process writes, and handles the messages, apart from iOS's scene identifier, whose spatial experience only C++ can make.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebKit/RemoteAudioDestinationManager.swift") RemoteAudioDestinationManager : private IPC::MessageReceiver {
    WTF_MAKE_TZONE_ALLOCATED(RemoteAudioDestinationManager);
    WTF_MAKE_NONCOPYABLE(RemoteAudioDestinationManager);
public:
    RemoteAudioDestinationManager(GPUConnectionToWebProcess&);
    ~RemoteAudioDestinationManager();

    void ref() const final;
    void deref() const final;

    void didReceiveMessageFromWebProcess(IPC::Connection& connection, IPC::Decoder& decoder) { didReceiveMessage(connection, decoder); }

    // Implemented in Swift: whether no destination is playing.
    bool allowsExitUnderMemoryPressure() const;
    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

    // For the Swift state.
    bool isLockdownModeEnabled() const;
    bool prefersSpatialAudioExperience() const;
    void tryExitIfUnusedAndUnderMemoryPressure();
    void destinationWasDeleted(uint64_t destinationIdentifier);

private:
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&);

#if PLATFORM(IOS_FAMILY)
    void setSceneIdentifier(RemoteAudioDestinationIdentifier, String&&);
#endif
    // Implemented in Swift.
    RemoteAudioDestinationSpatialTarget spatialTarget(uint64_t destinationIdentifier) const;

    // Implemented in Swift.
    uintptr_t createSwiftState();
    // Unsafe: the state must be the one createSwiftState() made, which only the destructor releases.
    SWIFT_UNSAFE static void destroySwiftState(uintptr_t);
    // m_swiftState, for Swift, which can only read it.
    uintptr_t swiftState() const { return m_swiftState; }

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_gpuConnectionToWebProcess;
#if PLATFORM(IOS_FAMILY)
    HashMap<uint64_t, String> m_sceneIdentifiers;
#endif
    // A retained reference to the Swift state, as an address, from the constructor to the destructor.
    uintptr_t m_swiftState __attribute__((availability(swift, unavailable))) { 0 };
};

} // namespace WebKit;

#endif // ENABLE(GPU_PROCESS) && ENABLE(WEB_AUDIO) && PLATFORM(COCOA)
