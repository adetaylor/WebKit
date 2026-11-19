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

#pragma once

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA)

#include <CoreVideo/CVBuffer.h>
#include <WebCore/PlatformMediaCapabilitiesDecodingInfo.h>
#include <WebCore/PlatformMediaCapabilitiesEncodingInfo.h>
#include <WebCore/PlatformMediaDecodingConfiguration.h>
#include <WebCore/PlatformMediaEncodingConfiguration.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/EscapableByteSpan.h>
#include <wtf/Logger.h>
#include <wtf/MediaTime.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>

#if ENABLE(GPU_PROCESS_CDM_SWIFT)
#include <WebCore/CDMPrivate.h>
#endif
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
#include <WebCore/LegacyCDM.h>
#endif
#if HAVE(AVASSETREADER)
#include "SharedBufferReference.h"
#include "SwiftCoding.h"
#include <WebCore/ImageDecoderAVFObjC.h>
#include <WebCore/ShareableBitmap.h>
#endif

namespace IPC {
class Connection;
}

namespace WebCore {
class InbandGenericCue;
class MediaPlayer;
class SerializedPlatformDataCue;
class VideoFrame;
using TrackID = uint64_t;
}

namespace WebKit {

class GPUConnectionToWebProcess;

// What the GPU process's Swift media receivers need of WebCore's C++ media objects that Swift can't do itself: reach a
// connection's logger and media players, and make C++ values that have no Swift form.

// MediaTime's ordering, as Swift can't call operator<=>.
inline bool mediaTimeIsLessThanOrEqual(const MediaTime& a, const MediaTime& b) { return a <= b; }

using RemoteCDMBytes = Vector<uint8_t>;

inline RemoteCDMBytes remoteCDMBufferBytes(const WebCore::SharedBuffer& buffer)
{
    return RemoteCDMBytes { buffer.span() };
}

WebCore::SharedBuffer* WTF_NONNULL makeRemoteCDMBuffer(WTF::SpanUInt8 bytes NOESCAPE) SWIFT_RETURNS_RETAINED;

#if ENABLE(GPU_PROCESS_CDM_SWIFT)
// The C++ CDM for the key system, if any, which logs to the connection's logger.
WebCore::CDMPrivateClientSwiftAdapter* WTF_NULLABLE createCDMPrivate(GPUConnectionToWebProcess&, const String& keySystem, const String& mediaKeysHashSalt) SWIFT_RETURNS_RETAINED;
#endif
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
// The connection's media player with that identifier, if any, for a legacy CDM.
WebCore::RefPtrLegacyCDMMediaPlayer legacyCDMMediaPlayer(GPUConnectionToWebProcess&, uint64_t playerIdentifier);
#endif

#if HAVE(AVASSETREADER)

using ImageDecoderAVFStatusCallback = Function<void(WebCore::EncodedDataStatus)>;

// Null if the decoder can't be made.
WebCore::ImageDecoderAVFObjC* WTF_NULLABLE createImageDecoderAVF(IPC::CxxDecodedArgument<IPC::SharedBufferReference>&, const String& mimeType, const GPUConnectionToWebProcess&) SWIFT_RETURNS_RETAINED;
void setImageDecoderAVFData(WebCore::ImageDecoderAVFObjC&, const IPC::SharedBufferReference&, bool allDataReceived);
// The frames' infos, if it has frames.
std::optional<Vector<WebCore::ImageDecoderFrameInfo>> imageDecoderAVFFrameInfos(WebCore::ImageDecoderAVFObjC&);
// A bitmap the frame is drawn into, if it decodes.
std::optional<WebCore::ShareableBitmapHandle> createImageDecoderAVFFrameBitmap(WebCore::ImageDecoderAVFObjC&, uint64_t index);

#endif // HAVE(AVASSETREADER)

#if ENABLE(VIDEO)
using MediaPlayerCallback = Function<void(WebCore::MediaPlayer&)>;
// The player's performTaskAtTime(), with a task that Swift can make (Swift can't make one that takes a const MediaTime&).
using MediaPlayerTimeTask = Function<void(MediaTime)>;
bool performMediaPlayerTaskAtTime(WebCore::MediaPlayer&, MediaPlayerTimeTask&&, const MediaTime&);
CVBufferRef WTF_NULLABLE videoFramePixelBuffer(const WebCore::VideoFrame&) CF_RETURNS_NOT_RETAINED;
#endif

// Cocoa's media engine configuration factories answer synchronously.
WebCore::PlatformMediaCapabilitiesDecodingInfo createMediaDecodingConfiguration(const WebCore::PlatformMediaDecodingConfiguration&);
WebCore::PlatformMediaCapabilitiesEncodingInfo createMediaEncodingConfiguration(const WebCore::PlatformMediaEncodingConfiguration&);

#if ENABLE(VIDEO) && ENABLE(GPU_PROCESS_MEDIA_SWIFT)
// A text track's cues for the web process (MediaPlayerPrivateRemote.messages.in), for Swift, which can't import a generic
// cue's GenericCueData or a data cue's SerializedPlatformDataCueValue, or pass the senders a std::span.
void sendAddDataCue(IPC::Connection&, uint64_t mediaPlayerIdentifier, WebCore::TrackID, const MediaTime& start, const MediaTime& end, const WebCore::SharedBuffer&);
void sendParseWebVTTCueData(IPC::Connection&, uint64_t mediaPlayerIdentifier, WebCore::TrackID, const WebCore::SharedBuffer&);
enum class RemoteTextTrackCueChange : uint8_t { Add, Update, Remove };
void sendGenericCue(IPC::Connection&, uint64_t mediaPlayerIdentifier, WebCore::TrackID, RemoteTextTrackCueChange, WebCore::InbandGenericCue&);
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
void sendMediaPlayerKeyNeeded(IPC::Connection&, uint64_t mediaPlayerIdentifier, const WebCore::SharedBuffer& message);
#endif
#if ENABLE(DATACUE_VALUE)
// The type is the added cue's.
void sendDataCue(IPC::Connection&, uint64_t mediaPlayerIdentifier, WebCore::TrackID, RemoteTextTrackCueChange, const MediaTime& start, const MediaTime& end, WebCore::SerializedPlatformDataCue&, const String& type);
#endif
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && PLATFORM(COCOA)
