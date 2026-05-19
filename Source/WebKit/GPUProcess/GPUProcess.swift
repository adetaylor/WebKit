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
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. AND ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_GPU_PROCESS_SWIFT

// Skeleton landing for the Swift IPC receiver class that mirrors C++
// WebKit::CxxGPUProcess. Phase 4.1.c will add SwiftReceiverBuildEnabledBy=
// GPU_PROCESS_SWIFT to GPUProcess.messages.in and populate this class with
// stub handlers for every message (each forwarding to
// WebKit.CxxGPUProcess.singleton()) plus the messageForwarder property and
// CxxGPUProcess wiring. The autogen requires every handler to exist before
// the flag is flipped (DerivedSources/GPUProcessMessageReceiver.cpp emits
// target.get()->method(args) for every message), so this commit just lands
// the file as proof that the cmake / Swift module wiring is correct.

final class GPUProcess {
    init() {
    }
}

#endif // ENABLE_GPU_PROCESS_SWIFT
