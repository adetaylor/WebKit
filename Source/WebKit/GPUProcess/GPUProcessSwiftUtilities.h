/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#if ENABLE(GPU_PROCESS_SWIFT)

// Stable C++ aliases for the IPC message argument types used by the GPU
// process's Swift message receiver. Swift's C++ interop renders bare
// `std::optional<X>`, `Vector<X>`, `RefPtr<X>`, etc. as Swift type names that
// vary by libc++ release / interop version; pinning each to a hand-written
// `using` here gives the Swift handler signatures (in GPUProcess.swift) a
// predictable spelling. Consumers in Swift refer to these as
// `WebKit.OptionalCaptureDevice` etc.
//
// Mirrors the WebBackForwardListSwiftUtilities.h convention.

#include "CoreIPCAuditToken.h"
#include "GPUProcessConnectionParameters.h"
#include "GPUProcessCreationParameters.h"
#include "GPUProcessPreferences.h"
#include "GPUProcessSessionParameters.h"
#include "RemoteSnapshotIdentifier.h"
#include "SandboxExtension.h"
#include "SharedBufferReference.h"
#include "SharedFileHandle.h"
#include "SharedPreferencesForWebProcess.h"
#include <WebCore/CaptureDevice.h>
#include <WebCore/DisplayCapturePromptType.h>
#include <WebCore/FloatSize.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/IntDegrees.h>
#include <WebCore/MediaPlayerIdentifier.h>
#include <WebCore/MockMediaDevice.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/ProcessIdentity.h>
#include <WebCore/ScreenProperties.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/ShareableBitmap.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/VideoFrameMetadata.h>
#include <pal/SessionID.h>
#include <span>
#include <wtf/Forward.h>
#include <wtf/MonotonicTime.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>

namespace WebKit {

// std::optional<X> aliases — one per X used by GPUProcess.messages.in's
// reply / argument types.
using OptionalCaptureDevice = std::optional<WebCore::CaptureDevice>;
using OptionalCoreIPCAuditToken = std::optional<WebKit::CoreIPCAuditToken>;
using OptionalProcessIdentity = std::optional<WebCore::ProcessIdentity>;
using OptionalShareableBitmapHandle = std::optional<WebCore::ShareableBitmapHandle>;
using OptionalSharedFileHandle = std::optional<IPC::SharedFileHandle>;
using OptionalString = std::optional<String>;

// Vector<X> aliases.
using VectorSandboxExtensionHandle = Vector<WebKit::SandboxExtension::Handle>;
using VectorString = Vector<String>;

// RefPtr<X> alias (only one variant for now — the SinkCompletedSnapshotToPDF
// reply).
using RefPtrSharedBuffer = RefPtr<WebCore::SharedBuffer>;

// std::span<X> alias used by ResolveBookmarkDataForCacheDirectory.
using SpanConstUint8 = std::span<const uint8_t>;

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_SWIFT)
