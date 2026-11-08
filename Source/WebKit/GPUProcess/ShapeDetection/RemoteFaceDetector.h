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

#include "RemoteShapeDetectionSupport.h"
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

// The receiver of a face detector's messages. Swift handles Detect (RemoteShapeDetectors.swift).
class RemoteFaceDetector final : public RemoteShapeDetector {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(RemoteFaceDetector);
public:
    static Ref<RemoteFaceDetector> create(RemoteRenderingBackend& backend, uint16_t maxDetectedFaces) { return adoptRef(*new RemoteFaceDetector(backend, maxDetectedFaces)); }

    uint16_t maxDetectedFaces() const { return m_maxDetectedFaces; }

    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { IPC::StreamMessageReceiver::ref(); }
    void deref() const { IPC::StreamMessageReceiver::deref(); }
#endif

private:
    RemoteFaceDetector(RemoteRenderingBackend& backend, uint16_t maxDetectedFaces)
        : RemoteShapeDetector(backend)
        , m_maxDetectedFaces(maxDetectedFaces)
    {
    }

    friend CGImageRef WTF_NULLABLE copyShapeDetectionImage(const RemoteFaceDetector&, uint64_t, bool&) CF_RETURNS_RETAINED;

    const uint16_t m_maxDetectedFaces;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// RemoteShapeDetector's image, for Swift, which takes what a C++ method returns as unretained whatever its annotation.
inline CGImageRef WTF_NULLABLE copyShapeDetectionImage(const RemoteFaceDetector& detector, uint64_t renderingResourceIdentifier, bool& found) CF_RETURNS_RETAINED
{
    return detector.copyImage(renderingResourceIdentifier, found);
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && HAVE(SHAPE_DETECTION_API_IMPLEMENTATION)
