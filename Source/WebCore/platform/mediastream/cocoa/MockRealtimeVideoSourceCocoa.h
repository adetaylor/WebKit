/*
 * Copyright (C) 2015-2022 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer
 *    in the documentation and/or other materials provided with the
 *    distribution.
 * 3. Neither the name of Ericsson nor the names of its contributors
 *    may be used to endorse or promote products derived from this
 *    software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(MEDIA_STREAM)

#include "MockRealtimeVideoSource.h"

typedef struct CGImage *CGImageRef;

namespace WebCore {

class ImageTransferSessionVT;

// The mock camera, whose frames MockVideoSource.swift draws.
class MockRealtimeVideoSourceMac final : public MockRealtimeVideoSource {
public:
    static Ref<MockRealtimeVideoSourceMac> create(String&& deviceID, AtomString&& name, MediaDeviceHashSalts&&, std::optional<PageIdentifier>);

    ~MockRealtimeVideoSourceMac();

    static RefPtr<MockRealtimeVideoSourceMac> sourceWithGeneratorIdentifier(uint64_t);

    // On the generator's queue.
    void didGenerateFrame(CGImageRef, double presentationTime);
    using MockRealtimeVideoSource::didTakePhoto;

private:
    MockRealtimeVideoSourceMac(String&& deviceID, AtomString&& name, MediaDeviceHashSalts&&, std::optional<PageIdentifier>);

    bool canResizeVideoFrames() const final { return true; }

    // Used on the generator's queue only.
    std::unique_ptr<ImageTransferSessionVT> m_imageTransferSession;
    size_t m_pixelGenerationFailureCount { 0 };
};

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
