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
 * 3. Neither the name of Google Inc. nor the names of its contributors
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

#import "config.h"
#import "MockRealtimeVideoSourceCocoa.h"

#if ENABLE(MEDIA_STREAM)

#import "ImageTransferSessionVT.h"
#import "MediaConstraints.h"
#import "MockRealtimeMediaSourceCenter.h"
#import "RealtimeVideoUtilities.h"
#import "VideoFrame.h"
#import <wtf/HashMap.h>
#import <wtf/Lock.h>
#import <wtf/MediaTime.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/cocoa/VectorCocoa.h>

namespace WebCore {

static Lock sourcesLock;

static HashMap<uint64_t, ThreadSafeWeakPtr<MockRealtimeVideoSourceMac>>& sources() WTF_REQUIRES_LOCK(sourcesLock)
{
    static NeverDestroyed<HashMap<uint64_t, ThreadSafeWeakPtr<MockRealtimeVideoSourceMac>>> sources;
    return sources;
}

RefPtr<MockRealtimeVideoSourceMac> MockRealtimeVideoSourceMac::sourceWithGeneratorIdentifier(uint64_t identifier)
{
    Locker locker { sourcesLock };
    return sources().get(identifier).get();
}

double mockVideoSourceDidGenerateFrame(uint64_t identifier, CGImageRef image, double presentationTime)
{
    RefPtr source = MockRealtimeVideoSourceMac::sourceWithGeneratorIdentifier(identifier);
    if (!source)
        return 0;
    source->didGenerateFrame(image, presentationTime);
    return source->observedFrameRate();
}

void mockVideoSourceDidTakePhoto(uint64_t identifier, uint64_t requestIdentifier, NSData *data, NSString *errorMessage)
{
    callOnMainThread([identifier, requestIdentifier, data = data ? makeVector(data) : Vector<uint8_t> { }, errorMessage = String { errorMessage }.isolatedCopy()]() mutable {
        if (RefPtr source = MockRealtimeVideoSourceMac::sourceWithGeneratorIdentifier(identifier))
            source->didTakePhoto(requestIdentifier, WTF::move(data), WTF::move(errorMessage));
    });
}

CaptureSourceOrError MockRealtimeVideoSource::create(String&& deviceID, AtomString&& name, MediaDeviceHashSalts&& hashSalts, const MediaConstraints* constraints, std::optional<PageIdentifier> pageIdentifier)
{
#ifndef NDEBUG
    auto device = MockRealtimeMediaSourceCenter::mockDeviceWithPersistentID(deviceID);
    ASSERT(device);
    if (!device)
        return CaptureSourceOrError({ "No mock camera device"_s , MediaAccessDenialReason::PermissionDenied });
#endif

    Ref<RealtimeMediaSource> source = MockRealtimeVideoSourceMac::create(WTF::move(deviceID), WTF::move(name), WTF::move(hashSalts), pageIdentifier);
    if (constraints) {
        if (auto error = source->applyConstraints(*constraints))
            return CaptureSourceOrError(CaptureSourceError { error->invalidConstraint });
    }

    return source;
}

Ref<MockRealtimeVideoSourceMac> MockRealtimeVideoSourceMac::create(String&& deviceID, AtomString&& name, MediaDeviceHashSalts&& hashSalts, std::optional<PageIdentifier> pageIdentifier)
{
    Ref source = adoptRef(*new MockRealtimeVideoSourceMac(WTF::move(deviceID), WTF::move(name), WTF::move(hashSalts), pageIdentifier));
    Locker locker { sourcesLock };
    sources().add(source->generator().identifier(), source.get());
    return source;
}

MockRealtimeVideoSourceMac::MockRealtimeVideoSourceMac(String&& deviceID, AtomString&& name, MediaDeviceHashSalts&& hashSalts, std::optional<PageIdentifier> pageIdentifier)
    : MockRealtimeVideoSource(WTF::move(deviceID), WTF::move(name), WTF::move(hashSalts), pageIdentifier)
{
}

MockRealtimeVideoSourceMac::~MockRealtimeVideoSourceMac()
{
    Locker locker { sourcesLock };
    sources().remove(generator().identifier());
}

void MockRealtimeVideoSourceMac::didGenerateFrame(CGImageRef image, double presentationTime)
{
    ASSERT(!isMainThread());

    if (!m_imageTransferSession) {
        m_imageTransferSession = ImageTransferSessionVT::create(preferedPixelBufferFormat());
        m_imageTransferSession->setMaximumBufferPoolSize(10);
    }

    auto videoFrame = m_imageTransferSession->createVideoFrame(image, MediaTime::createWithDouble(presentationTime), size(), videoFrameRotation());
    if (!videoFrame) {
        static const size_t MaxPixelGenerationFailureCount = 150;
        if (++m_pixelGenerationFailureCount > MaxPixelGenerationFailureCount) {
            callOnMainThread([protectedThis = Ref { *this }] {
                protectedThis->captureFailed();
            });
        }
        return;
    }

    m_pixelGenerationFailureCount = 0;
    VideoFrameTimeMetadata metadata;
    metadata.captureTime = MonotonicTime::now().secondsSinceEpoch();
    dispatchVideoFrameToObservers(*videoFrame, metadata);
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
