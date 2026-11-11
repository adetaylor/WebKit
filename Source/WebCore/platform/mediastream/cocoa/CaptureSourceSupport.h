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

#pragma once

#include <wtf/Platform.h>
#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

#include <CoreGraphics/CGImage.h>
#include <CoreMedia/CMSampleBuffer.h>
#include <CoreVideo/CVPixelBuffer.h>
#include <WebCore/CaptureSourceDecisions.h>
#include <cstdint>
#include <memory>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/text/WTFString.h>

OBJC_CLASS NSString;

// The C++ the Swift capture sources of the GPU process (CaptureSource.swift) make video frames with, until frames are
// Swift.

namespace WebCore {

class ImageRotationSessionVT;
class ImageTransferSessionVT;
class UserActivity;
class VideoFrame;

// The C++ that the Swift capture sources make and adapt video frames with: VideoFrameCV, ImageTransferSessionVT and
// ImageRotationSessionVT, which stay C++ while media's frames do. Use one session on one thread at a time.
class CaptureVideoFrameSession final : public ThreadSafeRefCounted<CaptureVideoFrameSession> {
public:
    static CaptureVideoFrameSession* WTF_NONNULL create(bool shouldUseIOSurface) SWIFT_RETURNS_RETAINED;
    static CaptureVideoFrameSession* WTF_NONNULL createWithPixelFormat(uint32_t) SWIFT_RETURNS_RETAINED;
    ~CaptureVideoFrameSession();

    uint32_t pixelFormat() const;

    // A frame of a camera's pixel buffer, as a CVBufferRef (CameraCaptureSourceHandle.h says why).
    static VideoFrame* WTF_NONNULL frameFromPixelBuffer(CVBufferRef WTF_NONNULL, int64_t timeValue, int32_t timeScale, uint16_t rotation, bool isMirrored) SWIFT_RETURNS_RETAINED;
    // A frame of an image or a sample buffer, at the given size, through ImageTransferSessionVT.
    VideoFrame* WTF_NULLABLE frameFromImage(CGImageRef WTF_NONNULL, double presentationTime, CaptureSourceSize, uint16_t rotation) SWIFT_RETURNS_RETAINED;
    VideoFrame* WTF_NULLABLE frameFromSampleBuffer(CMSampleBufferRef WTF_NONNULL, double presentationTime, CaptureSourceSize) SWIFT_RETURNS_RETAINED;
    CMSampleBufferRef WTF_NULLABLE croppedSampleBuffer(CMSampleBufferRef WTF_NONNULL, float x, float y, float width, float height, float frameWidth, float frameHeight);
    // The frame resized, or rotated as its rotation says, or null.
    VideoFrame* WTF_NULLABLE resize(VideoFrame&, CaptureSourceSize) SWIFT_RETURNS_RETAINED;
    VideoFrame* WTF_NULLABLE rotate(VideoFrame&) SWIFT_RETURNS_RETAINED;

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { ThreadSafeRefCounted<CaptureVideoFrameSession>::ref(); }
    void deref() const { ThreadSafeRefCounted<CaptureVideoFrameSession>::deref(); }
#endif

private:
    CaptureVideoFrameSession(std::unique_ptr<ImageTransferSessionVT>&&, bool shouldUseIOSurface);

    std::unique_ptr<ImageTransferSessionVT> m_transferSession;
    std::unique_ptr<ImageRotationSessionVT> m_rotationSession;
    bool m_shouldUseIOSurface { true };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// The UserActivity that keeps a display capture from app nap, as DisplayCaptureSourceCocoa has.
class CaptureUserActivity final : public ThreadSafeRefCounted<CaptureUserActivity, WTF::DestructionThread::Main> {
public:
    static CaptureUserActivity* WTF_NONNULL create() SWIFT_RETURNS_RETAINED;
    ~CaptureUserActivity();

    void start();
    void stop();

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { ThreadSafeRefCounted<CaptureUserActivity, WTF::DestructionThread::Main>::ref(); }
    void deref() const { ThreadSafeRefCounted<CaptureUserActivity, WTF::DestructionThread::Main>::deref(); }
#endif

private:
    CaptureUserActivity();

    std::unique_ptr<UserActivity> m_activity;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// A sample buffer cropped by the session to the rectangle of a frame of the given size. A free function, since Swift
// ignores CF_RETURNS_RETAINED on a method.
CMSampleBufferRef WTF_NULLABLE captureCroppedSampleBuffer(CaptureVideoFrameSession&, CMSampleBufferRef WTF_NONNULL, float x, float y, float width, float height, float frameWidth, float frameHeight) CF_RETURNS_RETAINED;

// RealtimeMediaSourceCenter::hashStringWithSalt(), which hashes the IDs of a device.
NSString * WTF_NONNULL captureHashStringWithSalt(NSString * WTF_NONNULL, NSString * WTF_NONNULL);

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
