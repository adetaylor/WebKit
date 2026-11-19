/*
 * Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

#include "config.h"
#include "RemoteMediaSwiftSupport.h"

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA)

#include "GPUConnectionToWebProcess.h"
#include "RemoteMediaPlayerManagerProxy.h"
#include "SharedBufferReference.h"
#include "SwiftCoding.h"
#include <WebCore/PlatformMediaEngineConfigurationFactory.h>

#if ENABLE(VIDEO)
#include <WebCore/VideoFrame.h>
#endif

#if ENABLE(VIDEO) && ENABLE(GPU_PROCESS_MEDIA_SWIFT)
#include "MediaPlayerPrivateRemoteMessages.h"
#include <WebCore/InbandGenericCue.h>
#if ENABLE(DATACUE_VALUE)
#include <WebCore/SerializedPlatformDataCue.h>
#endif
#endif

#if HAVE(AVASSETREADER)
#include <WebCore/GraphicsContext.h>
#include <WebCore/NativeImage.h>
#endif

namespace WebKit {

using namespace WebCore;

WebCore::SharedBuffer* makeRemoteCDMBuffer(WTF::SpanUInt8 bytes NOESCAPE)
{
    return &SharedBuffer::create(bytes).leakRef();
}

#if ENABLE(GPU_PROCESS_CDM_SWIFT)
CDMPrivateClientSwiftAdapter* createCDMPrivate(GPUConnectionToWebProcess& connection, const String& keySystem, const String& mediaKeysHashSalt)
{
    return CDMPrivateClientSwiftAdapter::create(keySystem, mediaKeysHashSalt, connection.logger());
}
#endif

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
RefPtr<MediaPlayer> legacyCDMMediaPlayer(GPUConnectionToWebProcess& connection, uint64_t playerIdentifier)
{
    return protect(connection.remoteMediaPlayerManagerProxy())->mediaPlayer(MediaPlayerIdentifier { playerIdentifier });
}
#endif

#if HAVE(AVASSETREADER)

static Ref<SharedBuffer> sharedBuffer(const IPC::SharedBufferReference& data)
{
    return data.isNull() ? SharedBuffer::create() : SharedBuffer::create(data.span());
}

ImageDecoderAVFObjC* createImageDecoderAVF(IPC::CxxDecodedArgument<IPC::SharedBufferReference>& data, const String& mimeType, const GPUConnectionToWebProcess& connection)
{
    return ImageDecoderAVFObjC::create(sharedBuffer(*data.take()), mimeType, AlphaOption::Premultiplied, GammaAndColorProfileOption::Ignored, connection.webProcessIdentity()).leakRef();
}

void setImageDecoderAVFData(ImageDecoderAVFObjC& decoder, const IPC::SharedBufferReference& data, bool allDataReceived)
{
    decoder.setData(sharedBuffer(data), allDataReceived);
}

std::optional<Vector<ImageDecoderFrameInfo>> imageDecoderAVFFrameInfos(ImageDecoderAVFObjC& decoder)
{
    if (!decoder.frameCount())
        return std::nullopt;
    return decoder.frameInfos();
}

std::optional<ShareableBitmapHandle> createImageDecoderAVFFrameBitmap(ImageDecoderAVFObjC& decoder, uint64_t index)
{
    RefPtr nativeImage = NativeImage::createTransient(decoder.createFrameImageAtIndex(index));
    if (!nativeImage)
        return std::nullopt;
    auto imageSize = nativeImage->size();
    RefPtr bitmap = ShareableBitmap::create({ imageSize, nativeImage->colorSpace(), unspecifiedPixelFormat, nativeImage->headroom(), false });
    if (!bitmap)
        return std::nullopt;
    auto context = bitmap->createGraphicsContext();
    if (!context)
        return std::nullopt;
    FloatRect imageRect { { }, imageSize };
    context->drawNativeImage(*nativeImage, imageRect, imageRect, { CompositeOperator::Copy });
    return bitmap->createHandle();
}

#endif // HAVE(AVASSETREADER)

#if ENABLE(VIDEO)
CVBufferRef videoFramePixelBuffer(const VideoFrame& frame)
{
    return frame.pixelBuffer();
}

bool performMediaPlayerTaskAtTime(MediaPlayer& player, MediaPlayerTimeTask&& task, const MediaTime& time)
{
    return player.performTaskAtTime(WTF::move(task), time);
}
#endif

PlatformMediaCapabilitiesDecodingInfo createMediaDecodingConfiguration(const PlatformMediaDecodingConfiguration& configuration)
{
    std::optional<PlatformMediaCapabilitiesDecodingInfo> result;
    PlatformMediaEngineConfigurationFactory::createDecodingConfiguration(PlatformMediaDecodingConfiguration { configuration }, [&result](auto&& info) {
        result = WTF::move(info);
    });
    RELEASE_ASSERT(result);
    return WTF::move(*result);
}

PlatformMediaCapabilitiesEncodingInfo createMediaEncodingConfiguration(const PlatformMediaEncodingConfiguration& configuration)
{
    std::optional<PlatformMediaCapabilitiesEncodingInfo> result;
    PlatformMediaEngineConfigurationFactory::createEncodingConfiguration(PlatformMediaEncodingConfiguration { configuration }, [&result](auto&& info) {
        result = WTF::move(info);
    });
    RELEASE_ASSERT(result);
    return WTF::move(*result);
}

#if ENABLE(VIDEO) && ENABLE(GPU_PROCESS_MEDIA_SWIFT)
void sendAddDataCue(IPC::Connection& connection, uint64_t mediaPlayerIdentifier, TrackID trackID, const MediaTime& start, const MediaTime& end, const SharedBuffer& data)
{
    connection.send(Messages::MediaPlayerPrivateRemote::AddDataCue(trackID, start, end, data.span()), mediaPlayerIdentifier);
}

void sendParseWebVTTCueData(IPC::Connection& connection, uint64_t mediaPlayerIdentifier, TrackID trackID, const SharedBuffer& data)
{
    connection.send(Messages::MediaPlayerPrivateRemote::ParseWebVTTCueData(trackID, data.span()), mediaPlayerIdentifier);
}

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
void sendMediaPlayerKeyNeeded(IPC::Connection& connection, uint64_t mediaPlayerIdentifier, const SharedBuffer& message)
{
    connection.send(Messages::MediaPlayerPrivateRemote::MediaPlayerKeyNeeded(message.span()), mediaPlayerIdentifier);
}
#endif

void sendGenericCue(IPC::Connection& connection, uint64_t mediaPlayerIdentifier, TrackID trackID, RemoteTextTrackCueChange change, InbandGenericCue& cue)
{
    switch (change) {
    case RemoteTextTrackCueChange::Add:
        connection.send(Messages::MediaPlayerPrivateRemote::AddGenericCue(trackID, cue.cueData()), mediaPlayerIdentifier);
        return;
    case RemoteTextTrackCueChange::Update:
        connection.send(Messages::MediaPlayerPrivateRemote::UpdateGenericCue(trackID, cue.cueData()), mediaPlayerIdentifier);
        return;
    case RemoteTextTrackCueChange::Remove:
        connection.send(Messages::MediaPlayerPrivateRemote::RemoveGenericCue(trackID, cue.cueData()), mediaPlayerIdentifier);
        return;
    }
}

#if ENABLE(DATACUE_VALUE)
void sendDataCue(IPC::Connection& connection, uint64_t mediaPlayerIdentifier, TrackID trackID, RemoteTextTrackCueChange change, const MediaTime& start, const MediaTime& end, SerializedPlatformDataCue& cue, const String& type)
{
    switch (change) {
    case RemoteTextTrackCueChange::Add:
        connection.send(Messages::MediaPlayerPrivateRemote::AddDataCueWithType(trackID, start, end, cue.encodableValue(), type), mediaPlayerIdentifier);
        return;
    case RemoteTextTrackCueChange::Update:
        connection.send(Messages::MediaPlayerPrivateRemote::UpdateDataCue(trackID, start, end, cue.encodableValue()), mediaPlayerIdentifier);
        return;
    case RemoteTextTrackCueChange::Remove:
        connection.send(Messages::MediaPlayerPrivateRemote::RemoveDataCue(trackID, start, end, cue.encodableValue()), mediaPlayerIdentifier);
        return;
    }
}
#endif
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && PLATFORM(COCOA)
