/*
 * Copyright (C) 2011-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2018-2023 Apple Inc. All rights reserved.
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
#import "CaptureSourceSupport.h"

#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

#import "ImageRotationSessionVT.h"
#import "ImageTransferSessionVT.h"
#import "RealtimeMediaSourceCenter.h"
#import "RealtimeVideoUtilities.h"
#import "VideoFrameCV.h"
#import <wtf/MediaTime.h>

namespace WebCore {

CaptureVideoFrameSession* CaptureVideoFrameSession::create(bool shouldUseIOSurface)
{
    return &adoptRef(*new CaptureVideoFrameSession(ImageTransferSessionVT::create(preferedPixelBufferFormat(), shouldUseIOSurface), shouldUseIOSurface)).leakRef();
}

CaptureVideoFrameSession* CaptureVideoFrameSession::createWithPixelFormat(uint32_t pixelFormat)
{
    return &adoptRef(*new CaptureVideoFrameSession(ImageTransferSessionVT::create(pixelFormat, true), true)).leakRef();
}

CaptureVideoFrameSession::CaptureVideoFrameSession(std::unique_ptr<ImageTransferSessionVT>&& transferSession, bool shouldUseIOSurface)
    : m_transferSession(WTF::move(transferSession))
    , m_shouldUseIOSurface(shouldUseIOSurface)
{
}

CaptureVideoFrameSession::~CaptureVideoFrameSession() = default;

uint32_t CaptureVideoFrameSession::pixelFormat() const
{
    return m_transferSession ? m_transferSession->pixelFormat() : 0;
}

VideoFrame* CaptureVideoFrameSession::frameFromPixelBuffer(CVBufferRef pixelBuffer, int64_t timeValue, int32_t timeScale, uint16_t rotation, bool isMirrored)
{
    Ref<VideoFrame> frame = VideoFrameCV::create(MediaTime(timeValue, timeScale), isMirrored, static_cast<VideoFrameRotation>(rotation), pixelBuffer);
    return &frame.leakRef();
}

VideoFrame* CaptureVideoFrameSession::frameFromImage(CGImageRef image, double presentationTime, CaptureSourceSize size, uint16_t rotation)
{
    if (!m_transferSession)
        return nullptr;
    return m_transferSession->createVideoFrame(image, MediaTime::createWithDouble(presentationTime), { size.width, size.height }, static_cast<VideoFrameRotation>(rotation)).leakRef();
}

VideoFrame* CaptureVideoFrameSession::frameFromSampleBuffer(CMSampleBufferRef sampleBuffer, double presentationTime, CaptureSourceSize size)
{
    if (!m_transferSession)
        return nullptr;
    return m_transferSession->createVideoFrame(sampleBuffer, MediaTime::createWithDouble(presentationTime), { size.width, size.height }).leakRef();
}

CMSampleBufferRef CaptureVideoFrameSession::croppedSampleBuffer(CMSampleBufferRef sampleBuffer, float x, float y, float width, float height, float frameWidth, float frameHeight)
{
    if (!m_transferSession)
        return nullptr;
    FloatRect contentRect { x, y, width, height };
    m_transferSession->setCroppingRectangle(contentRect, { frameWidth, frameHeight });
    return m_transferSession->convertCMSampleBuffer(sampleBuffer, IntSize { contentRect.size() }).leakRef();
}

VideoFrame* CaptureVideoFrameSession::resize(VideoFrame& frame, CaptureSourceSize size)
{
    if (!m_transferSession)
        return nullptr;
    return m_transferSession->convertVideoFrame(frame, { size.width, size.height }).leakRef();
}

VideoFrame* CaptureVideoFrameSession::rotate(VideoFrame& frame)
{
    if (!m_rotationSession)
        m_rotationSession = makeUnique<ImageRotationSessionVT>(m_shouldUseIOSurface ? ImageRotationSessionVT::ShouldUseIOSurface::Yes : ImageRotationSessionVT::ShouldUseIOSurface::No);
    return m_rotationSession->applyRotation(frame).leakRef();
}

CMSampleBufferRef captureCroppedSampleBuffer(CaptureVideoFrameSession& session, CMSampleBufferRef sampleBuffer, float x, float y, float width, float height, float frameWidth, float frameHeight)
{
    return session.croppedSampleBuffer(sampleBuffer, x, y, width, height, frameWidth, frameHeight);
}

NSString *captureHashStringWithSalt(NSString *string, NSString *salt)
{
    return RealtimeMediaSourceCenter::hashStringWithSalt(string, salt).createNSString().autorelease();
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
