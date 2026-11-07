/*
 * Copyright (C) 2023 Apple Inc. All rights reserved.
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

#if ENABLE(GPU_PROCESS) && HAVE(SHAPE_DETECTION_API_IMPLEMENTATION)

#include "SharedPreferencesForWebProcess.h"
#include <CoreGraphics/CoreGraphics.h>
#include <optional>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/WeakRef.h>

namespace IPC {
class StreamMessageReceiver;
}

namespace WebCore::ShapeDetection {
struct BarcodeDetectorOptions;
struct FaceDetectorOptions;
}

namespace WebKit {

class RemoteRenderingBackend;

// What the GPU process's Swift shape detection receivers (RemoteShapeDetectors.swift) look up in the rendering backend
// that created them.
class RemoteShapeDetectionResources final : public RefCounted<RemoteShapeDetectionResources> {
public:
    static Ref<RemoteShapeDetectionResources> create(RemoteRenderingBackend& backend) { return adoptRef(*new RemoteShapeDetectionResources(backend)); }
    ~RemoteShapeDetectionResources();

    RemoteRenderingBackend& backend() const;
    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { RefCounted<RemoteShapeDetectionResources>::ref(); }
    void deref() const { RefCounted<RemoteShapeDetectionResources>::deref(); }
#endif

private:
    explicit RemoteShapeDetectionResources(RemoteRenderingBackend&);

    const WeakRef<RemoteRenderingBackend> m_backend;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// The image of the native image the backend has cached under the identifier: found is false if it has none, and the
// image is null if the native image has no platform image. A function, since Swift takes what a C++ method returns as
// unretained whatever its annotation.
CGImageRef WTF_NULLABLE copyShapeDetectionImage(const RemoteShapeDetectionResources&, uint64_t renderingResourceIdentifier, bool& found) CF_RETURNS_RETAINED;

#ifndef __swift__
// The receivers of a new detector's messages, which the backend registers on its stream connection.
Ref<IPC::StreamMessageReceiver> createRemoteBarcodeDetectorReceiver(RemoteRenderingBackend&, const WebCore::ShapeDetection::BarcodeDetectorOptions&);
Ref<IPC::StreamMessageReceiver> createRemoteFaceDetectorReceiver(RemoteRenderingBackend&, const WebCore::ShapeDetection::FaceDetectorOptions&);
Ref<IPC::StreamMessageReceiver> createRemoteTextDetectorReceiver(RemoteRenderingBackend&);
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && HAVE(SHAPE_DETECTION_API_IMPLEMENTATION)
