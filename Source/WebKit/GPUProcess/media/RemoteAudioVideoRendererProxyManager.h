/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO) && PLATFORM(COCOA)

#include "Connection.h"
#include "LayerHostingContextManager.h"
#include "MessageReceiver.h"
#include "RemoteAudioVideoRendererIdentifier.h"
#include "RemoteAudioVideoRendererState.h"
#include "RemoteCDMInstanceIdentifier.h"
#include "RemoteLegacyCDMSessionIdentifier.h"
#include "RemoteVideoFrameProxy.h"
#include <WebCore/AudioVideoRenderer.h>
#include <WebCore/HTMLMediaElementIdentifier.h>
#include <WebCore/MediaPlayerEnums.h>
#include <WebCore/MediaPromiseTypes.h>
#include <WebCore/MediaSampleConverter.h>
#include <WebCore/ShareableBitmapHandle.h>
#include <WebCore/SharedTimebase.h>
#include <wtf/Forward.h>
#include <wtf/Logger.h>
#include <wtf/MediaTime.h>
#include <wtf/MonotonicTime.h>
#include <wtf/ObjectIdentifier.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>

namespace WebCore {
class AudioVideoRenderer;
struct MediaPlayerIdentifierType;
using MediaPlayerIdentifier = ObjectIdentifier<MediaPlayerIdentifierType>;
class TextTrackRepresentation;
}

namespace WebKit {

class GPUConnectionToWebProcess;
class RemoteVideoFrameObjectHeap;
struct SharedPreferencesForWebProcess;

// Receives the audio and video renderer messages of one web process's connection to the GPU process. The renderers are
// AudioVideoRendererAVFObjC, whose Swift cores do the work: its Swift state (RemoteAudioVideoRendererProxyManager.swift),
// which m_swiftState holds, is each core's client, and handles the messages that the cores act on (readiness, stalling
// at a time, seeking, flushes, tracks' removal, frame and metrics notifications), sending what the cores tell it. The
// messages that reach a C++ part of a renderer (samples, track information, layers and hosting, content keys, frames,
// the audio renderers' settings, spatial audio, playback with a host time) are handled here, as are the first frame's
// and the rendering mode's notifications, which reach the layers.
// Destroyed on the main thread like the GPUConnectionToWebProcess that owns it, since it holds media objects that
// expect to be torn down there.
class SWIFT_PRIVATE_FILEID("WebKit/RemoteAudioVideoRendererProxyManager.swift") RemoteAudioVideoRendererProxyManager final : public IPC::MessageReceiver, public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<RemoteAudioVideoRendererProxyManager, WTF::DestructionThread::Main> {
    WTF_MAKE_TZONE_ALLOCATED(RemoteAudioVideoRendererProxyManager);
public:
    static Ref<RemoteAudioVideoRendererProxyManager> create(GPUConnectionToWebProcess&);
    ~RemoteAudioVideoRendererProxyManager();

    void ref() const final { ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::ref(); }
    void deref() const final { ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::deref(); }

    void connectionToWebProcessClosed();

    // IPC::MessageReceiver
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;

    bool allowsExitUnderMemoryPressure() { return m_renderers.isEmpty(); }

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

    RefPtr<WebCore::AudioVideoRenderer> rendererFor(std::optional<WebCore::MediaPlayerIdentifier>) const;

    std::optional<WebCore::FloatRect> hostedVideoLayerBoundsForTesting(WebCore::HTMLMediaElementIdentifier) const;

private:
    explicit RemoteAudioVideoRendererProxyManager(GPUConnectionToWebProcess&);

    // Messages
    void createManager(RemoteAudioVideoRendererIdentifier, WebCore::HTMLMediaElementIdentifier, WebCore::MediaPlayerIdentifier, CompletionHandler<void(std::optional<WebCore::SharedTimebaseHandle>)>&&);

    void setPreferences(RemoteAudioVideoRendererIdentifier, WebCore::VideoRendererPreferences);

    // TracksRendererInterface
    using TrackIdentifier = WebCore::AudioVideoRenderer::TrackIdentifier;

    void addTrack(RemoteAudioVideoRendererIdentifier, WebCore::TrackInfo::TrackType, CompletionHandler<void(std::expected<TrackIdentifier, WebCore::PlatformMediaError>)>&&);

    void newTrackInfoForTrack(RemoteAudioVideoRendererIdentifier, TrackIdentifier, Ref<const WebCore::TrackInfo>&&);
    void enqueueSample(RemoteAudioVideoRendererIdentifier, TrackIdentifier, WebCore::MediaSamplesBlock&&, std::optional<MediaTime>, CompletionHandler<void(bool)>&&);

    void setSpatialTrackingInfo(RemoteAudioVideoRendererIdentifier, bool, WebCore::MediaPlayerSoundStageSize, const String&, const String&, const String&);

    // SynchronizerInterface
    void play(RemoteAudioVideoRendererIdentifier, std::optional<MonotonicTime>);
    void pause(RemoteAudioVideoRendererIdentifier, std::optional<MonotonicTime>);
    void setScreenReserved(RemoteAudioVideoRendererIdentifier, bool);

    // AudioInterface
#if HAVE(AUDIO_OUTPUT_DEVICE_UNIQUE_ID)
    void setOutputDeviceId(RemoteAudioVideoRendererIdentifier, const String&);
#endif

    // VideoInterface
    void setIsVisible(RemoteAudioVideoRendererIdentifier, bool);
    void setPresentationSize(RemoteAudioVideoRendererIdentifier, const WebCore::IntSize&);
    void setShouldMaintainAspectRatio(RemoteAudioVideoRendererIdentifier, bool);
    void contentBoxRectChanged(RemoteAudioVideoRendererIdentifier, const WebCore::LayoutRect&);
    void setShouldDisableHDR(RemoteAudioVideoRendererIdentifier, bool);
    void setPlatformDynamicRangeLimit(RemoteAudioVideoRendererIdentifier, const WebCore::PlatformDynamicRangeLimit&);
    void setResourceOwner(RemoteAudioVideoRendererIdentifier, const WebCore::ProcessIdentity& resourceOwner);
    void flushAndRemoveImage(RemoteAudioVideoRendererIdentifier);
    void currentVideoFrame(RemoteAudioVideoRendererIdentifier, RemoteVideoFrameReference, CompletionHandler<void(std::optional<RemoteVideoFrameProxy::Properties>)>&&) const;
    void currentBitmapImage(RemoteAudioVideoRendererIdentifier, CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>&&)>&&) const;

    // VideoFullscreenInterface
#if ENABLE(VIDEO_PRESENTATION_MODE)
    void setVideoFullscreenFrame(RemoteAudioVideoRendererIdentifier, const WebCore::FloatRect&);
    void isInFullscreenOrPictureInPictureChanged(RemoteAudioVideoRendererIdentifier, bool);
#endif
    void syncTextTrackBounds(RemoteAudioVideoRendererIdentifier);

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    void setLegacyCDMSession(RemoteAudioVideoRendererIdentifier, std::optional<RemoteLegacyCDMSessionIdentifier>);
#endif
#if ENABLE(ENCRYPTED_MEDIA)
    void setCDMInstance(RemoteAudioVideoRendererIdentifier, std::optional<RemoteCDMInstanceIdentifier>);
    void setInitData(RemoteAudioVideoRendererIdentifier, Ref<WebCore::SharedBuffer>, CompletionHandler<void(std::expected<void, WebCore::PlatformMediaError>)>&&);
    void attemptToDecrypt(RemoteAudioVideoRendererIdentifier);
#endif

    using LayerHostingContextCallback = CompletionHandler<void(WebCore::HostingContext)>;
    void requestHostingContext(RemoteAudioVideoRendererIdentifier, LayerHostingContextCallback&&);
    void setVideoLayerSize(RemoteAudioVideoRendererIdentifier, const WebCore::FloatSize&);
    void setVideoLayerSizeFenced(RemoteAudioVideoRendererIdentifier, const WebCore::FloatSize&, WTF::MachSendRightAnnotated&&);

    // For the Swift state, by the renderer's identifier.
    void shutDownRenderer(uint64_t identifier);
    void destroyRenderer(uint64_t identifier);

    // Implemented in Swift: the core whose token the renderer's swiftToken() is becomes the identifier's.
    void addRenderer(uint64_t identifier, uint64_t token);
    // Implemented in Swift: the Swift state forgets every renderer.
    void clear();

    // Implemented in Swift: the state sends the renderers' notifications on the connection.
    uintptr_t createSwiftState(IPC::Connection&);
    // Unsafe: the state must be the one createSwiftState() made, which only the destructor releases.
    SWIFT_UNSAFE static void destroySwiftState(uintptr_t);
    // m_swiftState, for Swift, which can only read it.
    uintptr_t swiftState() const { return m_swiftState; }

    struct RendererContext {
        RefPtr<WebCore::AudioVideoRenderer> renderer;
        Markable<WebCore::HTMLMediaElementIdentifier> mediaElementIdentifier;
        Markable<WebCore::MediaPlayerIdentifier> playerIdentifier;
        LayerHostingContextManager layerHostingContextManager;
        HashMap<TrackIdentifier, WebCore::MediaSampleConverter> converters { };
        WebCore::VideoRendererPreferences preferences { };
    };
    RefPtr<WebCore::AudioVideoRenderer> rendererFor(RemoteAudioVideoRendererIdentifier) const;
    RemoteAudioVideoRendererState stateFor(RemoteAudioVideoRendererIdentifier) const;
    NODELETE RendererContext& contextFor(RemoteAudioVideoRendererIdentifier);
    void rendereringModeChanged(RemoteAudioVideoRendererIdentifier);
    WebCore::MediaSampleConverter& converterFor(RendererContext&, TrackIdentifier);
    template<typename Message> void publishAndSend(RemoteAudioVideoRendererIdentifier, Message&&);

#if !RELEASE_LOG_DISABLED
    Logger& logger() { return m_logger; }
    NODELETE WTFLogChannel& logChannel() const;
    ASCIILiteral logClassName() const { return "RemoteAudioVideoRendererProxyManager"; }
    uint64_t logIdentifier() const { return m_logIdentifier; }
#endif

    HashMap<RemoteAudioVideoRendererIdentifier, RendererContext> m_renderers;
    const Ref<RemoteVideoFrameObjectHeap> m_videoFrameObjectHeap;

    ThreadSafeWeakRef<GPUConnectionToWebProcess> m_gpuConnectionToWebProcess;
#if !RELEASE_LOG_DISABLED
    uint64_t m_logIdentifier { 0 };
    const Ref<Logger> m_logger;
#endif
    // A retained reference to the Swift state, as an address, from the constructor to the destructor.
    uintptr_t m_swiftState __attribute__((availability(swift, unavailable))) { 0 };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

}

#endif
