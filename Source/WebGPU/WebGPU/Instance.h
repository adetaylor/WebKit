/*
 * Copyright (c) 2021-2023 Apple Inc. All rights reserved.
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

#pragma once

#import "HardwareCapabilities.h"
#import <Metal/Metal.h>
#import <WebGPU/WebGPU.h>
#import <WebGPU/WebGPUCpp.h>
#import <wtf/Function.h>
#import <wtf/MachSendRight.h>

IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")

namespace WebGPU::Metal {

// For InstanceImpl, which takes the descriptor's scheduleWork and resource owner: Swift can neither test a Function nor
// read the right out of the optional.
bool hasScheduleWork(const WebGPU::InstanceDescriptor&);
Function<void(Function<void()>&&)> takeScheduleWork(WebGPU::InstanceDescriptor&);
// An empty right without one.
MachSendRight takeWebProcessResourceOwner(WebGPU::InstanceDescriptor&);

// https://gpuweb.github.io/gpuweb/#dom-gpu-requestadapter: the device of the adapter that requestAdapter() completes
// with, with its capabilities, or nil.
id<MTLDevice> _Nullable requestAdapterDevice(const WebGPU::RequestAdapterOptions&, HardwareCapabilities&);

// The port of the web process identity, or MACH_PORT_NULL where resources aren't attributed to it, for a canvas
// context's Swift, which copies the right while the caller holds it.
mach_port_t webProcessIdentityPort(const MachSendRight&);

} // namespace WebGPU::Metal

IGNORE_CLANG_WARNINGS_END
