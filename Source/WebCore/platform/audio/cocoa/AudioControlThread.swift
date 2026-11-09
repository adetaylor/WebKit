// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT

import Darwin
import Foundation
import WebCore_Private.Core.CARingBufferSwiftBridge

// The thread, one per process, that audio IO threads wake with semaphore_signal() once they posted events that only the
// main thread can act on, such as a track renderer's timeline jump (AudioUnitIsland.swift). It has C++ hop to the main
// thread, which takes each unit's events. IO threads can't do that themselves: it allocates and can block.
func startAudioControlThread(_ semaphore: semaphore_t) {
    let thread = Thread {
        while true {
            if semaphore_wait(semaphore) == KERN_SUCCESS {
                WebCore.audioUnitEventsArrived()
            }
        }
    }
    thread.name = "WebCore: Audio control"
    thread.qualityOfService = .userInteractive
    thread.start()
}

#endif // ENABLE_WEBCORE_SWIFT
