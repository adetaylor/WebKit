/*
 * Copyright (C) 2011-2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#include "config.h"

#if ENABLE(VIDEO) && USE(AVFOUNDATION)

#include "MediaPlayerPrivateAVFoundation.h"

#include "DocumentLoader.h"
#include "FloatConversion.h"
#include "GraphicsContext.h"
#include "InbandTextTrackPrivateAVF.h"
#include "InbandTextTrackPrivateClient.h"
#include "Logging.h"
#include "PlatformLayer.h"
#include "PlatformTimeRanges.h"
#include "ScriptDisallowedScope.h"
#include "Settings.h"
#include <CoreMedia/CoreMedia.h>
#include <JavaScriptCore/DataView.h>
#include <JavaScriptCore/HeapInlines.h>
#include <JavaScriptCore/TypedArrayInlines.h>
#include <JavaScriptCore/Uint16Array.h>
#include <wtf/MainThread.h>
#include <wtf/NativePromise.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/SoftLinking.h>
#include <wtf/SortedArrayMap.h>
#include <wtf/StdLibExtras.h>
#include <wtf/StringPrintStream.h>
#include <wtf/URL.h>
#include <wtf/text/CString.h>

namespace WebCore {

MediaPlayerPrivateAVFoundation::MediaPlayerPrivateAVFoundation(MediaPlayer& player)
    : m_player(player)
    , m_networkState(MediaPlayer::NetworkState::Empty)
    , m_readyState(MediaPlayer::ReadyState::HaveNothing)
    , m_preload(MediaPlayer::Preload::Auto)
#if !RELEASE_LOG_DISABLED
    , m_logger(player.mediaPlayerLogger())
    , m_logIdentifier(player.mediaPlayerLogIdentifier())
#endif
    , m_cachedDuration(MediaTime::invalidTime())
    , m_maxTimeLoadedAtLastDidLoadingProgress(MediaTime::invalidTime())
    , m_delayCharacteristicsChangedNotification(0)
    , m_mainThreadCallPending(false)
    , m_assetIsPlayable(false)
    , m_pageIsVisible(false)
    , m_loadingMetadata(false)
    , m_isAllowedToRender(false)
    , m_cachedHasAudio(false)
    , m_cachedHasVideo(false)
    , m_cachedHasCaptions(false)
    , m_ignoreLoadStateChanges(false)
    , m_haveReportedFirstVideoFrame(false)
    , m_characteristicsChanged(false)
    , m_shouldMaintainAspectRatio(true)
    , m_seeking(false)
{
    INFO_LOG(LOGIDENTIFIER);
}

MediaPlayerPrivateAVFoundation::~MediaPlayerPrivateAVFoundation()
{
    INFO_LOG(LOGIDENTIFIER);
    setIgnoreLoadStateChanges(true);
}

MediaPlayerPrivateAVFoundation::MediaRenderingMode MediaPlayerPrivateAVFoundation::currentRenderingMode() const
{
    if (hasVideoInlineLayer())
        return MediaRenderingMode::MediaRenderingToLayer;

    if (hasContextRenderer())
        return MediaRenderingMode::MediaRenderingToContext;

    return MediaRenderingMode::MediaRenderingNone;
}

MediaPlayerPrivateAVFoundation::MediaRenderingMode MediaPlayerPrivateAVFoundation::preferredRenderingMode() const
{
    if (assetStatus() == MediaPlayerAVAssetStatusUnknown)
        return MediaRenderingMode::MediaRenderingNone;

    if (m_readyState >= MediaPlayer::ReadyState::HaveMetadata && !haveBeenAskedToPaint())
        return MediaRenderingMode::MediaRenderingToLayer;

    RefPtr player = m_player.get();
    if (supportsAcceleratedRendering() && player && player->renderingCanBeAccelerated())
        return MediaRenderingMode::MediaRenderingToLayer;

    return MediaRenderingMode::MediaRenderingToContext;
}

bool MediaPlayerPrivateAVFoundation::hasSetUpVideoRendering() const
{
    return hasLayerRenderer() || hasContextRenderer();
}

void MediaPlayerPrivateAVFoundation::setUpVideoRendering()
{
    if (!isReadyForVideoSetup())
        return;

    MediaRenderingMode currentMode = currentRenderingMode();
    MediaRenderingMode preferredMode = preferredRenderingMode();

    if (currentMode == preferredMode && currentMode != MediaRenderingMode::MediaRenderingNone)
        return;

    ALWAYS_LOG(LOGIDENTIFIER, preferredMode);

    switch (preferredMode) {
    case MediaRenderingMode::MediaRenderingNone:
        tearDownVideoRendering();
        break;

    case MediaRenderingMode::MediaRenderingToContext:
        destroyVideoLayer();
        createContextVideoRenderer();
        break;

    case MediaRenderingMode::MediaRenderingToLayer:
        destroyContextVideoRenderer();
        createVideoLayer();
        break;
    }

    // If using a movie layer, inform the client so the compositing tree is updated.
    if (currentMode == MediaRenderingMode::MediaRenderingToLayer || preferredMode == MediaRenderingMode::MediaRenderingToLayer)
        setNeedsRenderingModeChanged();
}

void MediaPlayerPrivateAVFoundation::tearDownVideoRendering()
{
    INFO_LOG(LOGIDENTIFIER);

    destroyContextVideoRenderer();

    if (platformLayer())
        destroyVideoLayer();
}

void MediaPlayerPrivateAVFoundation::setNeedsRenderingModeChanged()
{
    if (m_needsRenderingModeChanged)
        return;
    m_needsRenderingModeChanged = true;

    ALWAYS_LOG(LOGIDENTIFIER);

    queueTaskOnEventLoop([weakThis = ThreadSafeWeakPtr { *this }] {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->renderingModeChanged();
    });
}

void MediaPlayerPrivateAVFoundation::renderingModeChanged()
{
    ASSERT(m_needsRenderingModeChanged);
    m_needsRenderingModeChanged = false;
    if (RefPtr player = m_player.get())
        player->renderingModeChanged();
}

void MediaPlayerPrivateAVFoundation::load(const String& url)
{
    ALWAYS_LOG(LOGIDENTIFIER);

    setNetworkState(m_preload == MediaPlayer::Preload::None ? MediaPlayer::NetworkState::Idle : MediaPlayer::NetworkState::Loading);
    setReadyState(MediaPlayer::ReadyState::HaveNothing);

    m_assetURL = URL({ }, url);
    m_requestedOrigin = SecurityOrigin::create(m_assetURL);

    // Don't do any more work if the url is empty.
    if (!url.length())
        return;

    setPreload(m_preload);
}

void MediaPlayerPrivateAVFoundation::load(const URL& url, const LoadOptions& options)
{
    m_disableTeardownOnVisibilityChange = options.disableTeardownOnVisibilityChange;
    load(url.string());
}

#if ENABLE(MEDIA_SOURCE)
void MediaPlayerPrivateAVFoundation::load(const URL&, const LoadOptions&, MediaSourcePrivateClient&)
{
    setNetworkState(MediaPlayer::NetworkState::FormatError);
}
#endif

void MediaPlayerPrivateAVFoundation::prepareToPlay()
{
    ALWAYS_LOG(LOGIDENTIFIER);
    setPreload(MediaPlayer::Preload::Auto);
}

MediaTime MediaPlayerPrivateAVFoundation::duration() const
{
    if (m_cachedDuration.isValid())
        return m_cachedDuration;

    MediaTime duration = platformDuration();
    if (!duration || duration.isInvalid())
        return MediaTime::zeroTime();

    m_cachedDuration = duration;

    return m_cachedDuration;
}

Ref<MediaTimePromise> MediaPlayerPrivateAVFoundation::seekToTarget(const SeekTarget& target)
{
    m_seekPromise.emplace(PlatformMediaError::Cancelled);
    if (m_seeking) {
        ALWAYS_LOG(LOGIDENTIFIER, "saving pending seek");
        m_pendingSeek = [weakThis = ThreadSafeWeakPtr { * this }, target] {
            if (RefPtr protectedThis = weakThis.get())
                protectedThis->seekInternal(target);
        };
        return *m_seekPromise;
    }

    Ref promise = m_seekPromise->promise();
    seekInternal(target);
    return promise;
}

void MediaPlayerPrivateAVFoundation::seekInternal(const SeekTarget& target)
{
    m_seeking = true;

    if (!metaDataAvailable())
        return;

    SeekTarget adjustedTarget = target;
    if (target.time > duration())
        adjustedTarget.time = duration();

    if (RefPtr track = currentTextTrack().get())
        track->beginSeeking();

    ALWAYS_LOG(LOGIDENTIFIER, "seeking to ", adjustedTarget.time);

    m_lastSeekTime = adjustedTarget.time;
    seekToTargetInternal(adjustedTarget);
}

const PlatformTimeRanges& MediaPlayerPrivateAVFoundation::buffered() const
{
    return platformBufferedTimeRanges();
}

MediaTime MediaPlayerPrivateAVFoundation::maxTimeSeekable() const
{
    if (!metaDataAvailable())
        return MediaTime::zeroTime();

    if (!m_cachedMaxTimeSeekable)
        m_cachedMaxTimeSeekable = platformMaxTimeSeekable();

    return m_cachedMaxTimeSeekable;
}

MediaTime MediaPlayerPrivateAVFoundation::minTimeSeekable() const
{
    if (!metaDataAvailable())
        return MediaTime::zeroTime();

    if (!m_cachedMinTimeSeekable)
        m_cachedMinTimeSeekable = platformMinTimeSeekable();

    return m_cachedMinTimeSeekable;
}

MediaTime MediaPlayerPrivateAVFoundation::maxTimeLoaded() const
{
    if (!metaDataAvailable())
        return MediaTime::zeroTime();

    if (!m_cachedMaxTimeLoaded)
        m_cachedMaxTimeLoaded = platformMaxTimeLoaded();

    return m_cachedMaxTimeLoaded;   
}

bool MediaPlayerPrivateAVFoundation::didLoadingProgress() const
{
    if (!duration())
        return false;
    MediaTime currentMaxTimeLoaded = maxTimeLoaded();
    bool didLoadingProgress = currentMaxTimeLoaded != m_maxTimeLoadedAtLastDidLoadingProgress;
    m_maxTimeLoadedAtLastDidLoadingProgress = currentMaxTimeLoaded;

    return didLoadingProgress;
}

bool MediaPlayerPrivateAVFoundation::paused() const
{
    if (!metaDataAvailable())
        return true;

    return platformPaused();
}

bool MediaPlayerPrivateAVFoundation::seeking() const
{
    if (!metaDataAvailable())
        return false;

    return m_seeking;
}

FloatSize MediaPlayerPrivateAVFoundation::naturalSize() const
{
    if (!metaDataAvailable())
        return IntSize();

    // In spite of the name of this method, return the natural size transformed by the 
    // initial movie scale because the spec says intrinsic size is:
    //
    //    ... the dimensions of the resource in CSS pixels after taking into account the resource's 
    //    dimensions, aspect ratio, clean aperture, resolution, and so forth, as defined for the 
    //    format used by the resource

    return m_cachedNaturalSize;
}

bool MediaPlayerPrivateAVFoundation::isReadyForVideoSetup() const
{
    // AVFoundation will not return true for firstVideoFrameAvailable until
    // an AVPlayerLayer has been added to the AVPlayerItem, so allow video setup
    // here if a video track to trigger allocation of a AVPlayerLayer.
    return (m_isAllowedToRender || m_cachedHasVideo) && m_readyState >= MediaPlayer::ReadyState::HaveMetadata && m_pageIsVisible;
}

MediaPlayerMovieLoadType MediaPlayerPrivateAVFoundation::movieLoadType() const
{
    if (!metaDataAvailable() || assetStatus() == MediaPlayerAVAssetStatusUnknown)
        return MediaPlayer::MovieLoadType::Unknown;

    if (isHLS())
        return MediaPlayer::MovieLoadType::HttpLiveStream;

    return MediaPlayer::MovieLoadType::Download;
}

void MediaPlayerPrivateAVFoundation::prepareForRendering()
{
    if (m_isAllowedToRender)
        return;
    m_isAllowedToRender = true;

    setUpVideoRendering();

    if (currentRenderingMode() == MediaRenderingMode::MediaRenderingToLayer || preferredRenderingMode() == MediaRenderingMode::MediaRenderingToLayer)
        setNeedsRenderingModeChanged();
}

void MediaPlayerPrivateAVFoundation::acceleratedRenderingStateChanged()
{
    // Set up or change the rendering path if necessary.
    setUpVideoRendering();
}

bool MediaPlayerPrivateAVFoundation::supportsFullscreen() const
{
    // FIXME: WebVideoFullscreenController assumes a QTKit/QuickTime media engine
#if ENABLE(FULLSCREEN_API) || (PLATFORM(IOS_FAMILY) && HAVE(AVKIT))
    return true;
#else
    return false;
#endif
}

void MediaPlayerPrivateAVFoundation::setResolvedURL(URL&& resolvedURL)
{
    m_resolvedURL = WTF::move(resolvedURL);
    m_resolvedOrigin = SecurityOrigin::create(m_resolvedURL);
}

void MediaPlayerPrivateAVFoundation::updateStates()
{
    // MediaPlayerPrivateAVFoundation.swift's raw values.
    static_assert(MediaPlayerPrivateAVFoundation::MediaPlayerAVAssetStatusDoesNotExist == 0 && MediaPlayerPrivateAVFoundation::MediaPlayerAVAssetStatusLoading == 2
        && MediaPlayerPrivateAVFoundation::MediaPlayerAVAssetStatusFailed == 3 && MediaPlayerPrivateAVFoundation::MediaPlayerAVAssetStatusCancelled == 4 && MediaPlayerPrivateAVFoundation::MediaPlayerAVAssetStatusNetworkError == 5
        && MediaPlayerPrivateAVFoundation::MediaPlayerAVAssetStatusLoaded == 6 && MediaPlayerPrivateAVFoundation::MediaPlayerAVAssetStatusPlayable == 7);
    static_assert(MediaPlayerPrivateAVFoundation::MediaPlayerAVPlayerItemStatusUnknown == 1 && MediaPlayerPrivateAVFoundation::MediaPlayerAVPlayerItemStatusFailed == 2
        && MediaPlayerPrivateAVFoundation::MediaPlayerAVPlayerItemStatusReadyToPlay == 3 && MediaPlayerPrivateAVFoundation::MediaPlayerAVPlayerItemStatusPlaybackBufferEmpty == 4
        && MediaPlayerPrivateAVFoundation::MediaPlayerAVPlayerItemStatusPlaybackBufferFull == 5 && MediaPlayerPrivateAVFoundation::MediaPlayerAVPlayerItemStatusPlaybackLikelyToKeepUp == 6);

    if (m_ignoreLoadStateChanges)
        return;

    ScriptDisallowedScope::InMainThread scriptDisallowedScope;
    updateReadiness();
}

void MediaPlayerPrivateAVFoundation::timeChanged(const MediaTime& time)
{
    UNUSED_PARAM(time);
    INFO_LOG(LOGIDENTIFIER, "- ", time);
}

void MediaPlayerPrivateAVFoundation::resolveSeekPromiseIfNeeded()
{
    if (m_readyState < MediaPlayer::ReadyState::HaveCurrentData || m_seeking)
        return;
    if (auto seekPromise = std::exchange(m_seekPromise, std::nullopt)) {
        ALWAYS_LOG(LOGIDENTIFIER, "resolving seekPromise at time: ", m_lastSeekTime);
        seekPromise->resolve(m_lastSeekTime);
    }
}

void MediaPlayerPrivateAVFoundation::setPreload(MediaPlayer::Preload preload)
{
    ALWAYS_LOG(LOGIDENTIFIER, " - ", static_cast<int>(preload));
    m_preload = preload;
    if (m_assetURL.isEmpty())
        return;

    if (m_preload >= MediaPlayer::Preload::MetaData && assetStatus() == MediaPlayerAVAssetStatusDoesNotExist)
        createAVAssetForURL(m_assetURL);

    // Don't force creation of the player and player item unless we already know that the asset is playable. If we aren't
    // there yet, or if we already know it is not playable, creating them now won't help.
    if (m_preload == MediaPlayer::Preload::Auto && m_assetIsPlayable) {
        createAVPlayerItem();
        createAVPlayer();
    }
}

void MediaPlayerPrivateAVFoundation::configureInbandTracks()
{
    RefPtr<InbandTextTrackPrivateAVF> trackToEnable;
    
    synchronizeTextTrackState();

    // AVFoundation can only emit cues for one track at a time, so enable the first track that is showing, or the first that
    // is hidden if none are showing. Otherwise disable all tracks.
    for (unsigned i = 0; i < m_textTracks.size(); ++i) {
        RefPtr<InbandTextTrackPrivateAVF> track = m_textTracks[i];
        if (track->mode() == InbandTextTrackPrivate::Mode::Showing) {
            trackToEnable = track;
            break;
        }
        if (track->mode() == InbandTextTrackPrivate::Mode::Hidden)
            trackToEnable = track;
    }

    setCurrentTextTrack(trackToEnable.get());
}

void MediaPlayerPrivateAVFoundation::trackModeChanged()
{
    configureInbandTracks();
}

void MediaPlayerPrivateAVFoundation::clearTextTracks()
{
    auto player = this->player();
    for (auto& track : m_textTracks) {
        if (player)
            player->removeTextTrack(*track);
        track->disconnect();
    }
    m_textTracks.clear();
}

void MediaPlayerPrivateAVFoundation::processNewAndRemovedTextTracks(const Vector<RefPtr<InbandTextTrackPrivateAVF>>& removedTextTracks)
{
    auto player = this->player();
    if (removedTextTracks.size()) {
        for (unsigned i = 0; i < m_textTracks.size(); ) {
            if (!removedTextTracks.contains(m_textTracks[i])) {
                ++i;
                continue;
            }
            if (player)
                player->removeTextTrack(Ref { *m_textTracks[i] });
            m_textTracks.removeAt(i);
        }
    }

    unsigned trackCount = m_textTracks.size();
    unsigned inBandCount = 0;
    for (unsigned i = 0; i < trackCount; ++i) {
        RefPtr<InbandTextTrackPrivateAVF> track = m_textTracks[i];

        if (track->textTrackCategory() == InbandTextTrackPrivateAVF::OutOfBand)
            continue;

        track->setTextTrackIndex(inBandCount);
        ++inBandCount;
        if (track->hasBeenReported())
            continue;

        track->setHasBeenReported(true);
        if (player)
            player->addTextTrack(*track);
    }

    if (trackCount != m_textTracks.size())
        INFO_LOG(LOGIDENTIFIER, "found ", m_textTracks.size(), " text tracks");
}

#if ENABLE(WIRELESS_PLAYBACK_TARGET)
void MediaPlayerPrivateAVFoundation::playbackTargetIsWirelessChanged()
{
    if (RefPtr player = m_player.get())
        player->currentPlaybackTargetIsWirelessChanged(player->isCurrentPlaybackTargetWireless());
}
#endif

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
bool MediaPlayerPrivateAVFoundation::extractKeyURIKeyIDAndCertificateFromInitData(Uint8Array* initData, String& keyURI, String& keyID, RefPtr<Uint8Array>& certificate)
{
    // initData should have the following layout:
    // [4 bytes: keyURI length][N bytes: keyURI][4 bytes: contentID length], [N bytes: contentID], [4 bytes: certificate length][N bytes: certificate]
    if (initData->byteLength() < 4)
        return false;

    RefPtr<ArrayBuffer> initDataBuffer = initData->unsharedBuffer();

    // Use a DataView to read uint32 values from the buffer, as Uint32Array requires the reads be aligned on 4-byte boundaries. 
    auto initDataView = JSC::DataView::create(initDataBuffer.copyRef(), 0, initDataBuffer->byteLength());
    uint32_t offset = 0;
    bool status = true;

    uint32_t keyURILength = initDataView->get<uint32_t>(offset, true, &status);
    offset += 4;
    if (!status || offset + keyURILength > initData->length())
        return false;

    auto keyURIArray = Uint16Array::tryCreate(initDataBuffer.copyRef(), offset, keyURILength);
    if (!keyURIArray)
        return false;

    keyURI = spanReinterpretCast<const char16_t>(keyURIArray->span().first(keyURILength));
    offset += keyURILength;

    uint32_t keyIDLength = initDataView->get<uint32_t>(offset, true, &status);
    offset += 4;
    if (!status || offset + keyIDLength > initData->length())
        return false;

    auto keyIDArray = Uint8Array::tryCreate(initDataBuffer.copyRef(), offset, keyIDLength);
    if (!keyIDArray)
        return false;

    keyID = spanReinterpretCast<const char16_t>(keyIDArray->span().first(keyIDLength));
    offset += keyIDLength;

    uint32_t certificateLength = initDataView->get<uint32_t>(offset, true, &status);
    offset += 4;
    if (!status || offset + certificateLength > initData->length())
        return false;

    certificate = Uint8Array::tryCreate(WTF::move(initDataBuffer), offset, certificateLength);
    if (!certificate)
        return false;

    return true;
}
#endif

bool MediaPlayerPrivateAVFoundation::canSaveMediaData() const
{
    URL url = resolvedURL();

    if (url.protocolIsFile())
        return true;

    if (!url.protocolIsInHTTPFamily())
        return false;

    if (isLiveStream())
        return false;

    return true;
}

bool MediaPlayerPrivateAVFoundation::shouldEnableInheritURIQueryComponent() const
{
    static NeverDestroyed<const AtomString> iTunesInheritsURIQueryComponent(MAKE_STATIC_STRING_IMPL("x-itunes-inherit-uri-query-component"));
    auto player = this->player();
    return player && player->doesHaveAttribute(iTunesInheritsURIQueryComponent);
}

void MediaPlayerPrivateAVFoundation::queueTaskOnEventLoop(Function<void()>&& task)
{
    ASSERT_WITH_SECURITY_IMPLICATION(isMainThread());
    if (RefPtr player = m_player.get())
        player->queueTaskOnEventLoop(WTF::move(task));
}

void MediaPlayerPrivateAVFoundation::notifyMediaPlayer(MediaPlayerNotification notification) const
{
    RefPtr player = m_player.get();
    if (!player)
        return;
    switch (notification) {
    case MediaPlayerNotification::NetworkStateChanged:
        player->networkStateChanged();
        return;
    case MediaPlayerNotification::ReadyStateChanged:
        player->readyStateChanged();
        return;
    case MediaPlayerNotification::SizeChanged:
        player->sizeChanged();
        return;
    case MediaPlayerNotification::CharacteristicChanged:
        player->characteristicChanged();
        return;
    case MediaPlayerNotification::FirstVideoFrameAvailable:
        player->firstVideoFrameAvailable();
        return;
    case MediaPlayerNotification::RateChanged:
        player->rateChanged();
        return;
    case MediaPlayerNotification::BufferedTimeRangesChanged:
        player->bufferedTimeRangesChanged();
        return;
    case MediaPlayerNotification::SeekableTimeRangesChanged:
        player->seekableTimeRangesChanged();
        return;
    case MediaPlayerNotification::TimeChanged:
        player->timeChanged();
        return;
    }
}

bool MediaPlayerPrivateAVFoundation::mediaPlayerRenderingCanBeAccelerated() const
{
    RefPtr player = m_player.get();
    return player && player->renderingCanBeAccelerated();
}

bool MediaPlayerPrivateAVFoundation::runPendingSeek()
{
    auto pendingSeek = std::exchange(m_pendingSeek, nullptr);
    if (!pendingSeek)
        return false;
    ALWAYS_LOG(LOGIDENTIFIER, "issuing pending seek");
    pendingSeek();
    return true;
}

void MediaPlayerPrivateAVFoundation::endSeekingCurrentTextTrack()
{
    if (RefPtr track = currentTextTrack().get())
        track->endSeeking();
}

bool MediaPlayerPrivateAVFoundation::hasLoadedBeyondCurrentTime() const
{
    return maxTimeLoaded() > currentTime();
}

bool MediaPlayerPrivateAVFoundation::hasLoadedToDuration() const
{
    return maxTimeLoaded() >= duration();
}

bool MediaPlayerPrivateAVFoundation::willLogFromSwift(MediaPlayerAVFoundationLogLevel level) const
{
#if !RELEASE_LOG_DISABLED
    // The logger filters again, and tells its observers.
    switch (level) {
    case MediaPlayerAVFoundationLogLevel::Always:
    case MediaPlayerAVFoundationLogLevel::Error:
        return logger().enabled();
    case MediaPlayerAVFoundationLogLevel::Info:
        return logger().willLog(logChannel(), WTFLogLevel::Info, { });
    case MediaPlayerAVFoundationLogLevel::Debug:
        return logger().willLog(logChannel(), WTFLogLevel::Debug, { });
    }
#else
    UNUSED_PARAM(level);
#endif
    return false;
}

void MediaPlayerPrivateAVFoundation::logFromSwift(MediaPlayerAVFoundationLogLevel level, WTF::SpanUInt8 message NOESCAPE) const
{
#if !RELEASE_LOG_DISABLED
    auto text = String::fromUTF8(message);
    switch (level) {
    case MediaPlayerAVFoundationLogLevel::Always:
        ALWAYS_LOG(LOGIDENTIFIER, text);
        return;
    case MediaPlayerAVFoundationLogLevel::Error:
        ERROR_LOG(LOGIDENTIFIER, text);
        return;
    case MediaPlayerAVFoundationLogLevel::Info:
        INFO_LOG(LOGIDENTIFIER, text);
        return;
    case MediaPlayerAVFoundationLogLevel::Debug:
        DEBUG_LOG(LOGIDENTIFIER, text);
        return;
    }
#else
    UNUSED_PARAM(level);
    UNUSED_PARAM(message);
#endif
}

#if !RELEASE_LOG_DISABLED
WTFLogChannel& MediaPlayerPrivateAVFoundation::logChannel() const
{
    return LogMedia;
}
#endif


String convertEnumerationToString(MediaPlayerPrivateAVFoundation::MediaRenderingMode enumerationValue)
{
    static const std::array<NeverDestroyed<String>, 3> values {
        MAKE_STATIC_STRING_IMPL("MediaRenderingNone"),
        MAKE_STATIC_STRING_IMPL("MediaRenderingToContext"),
        MAKE_STATIC_STRING_IMPL("MediaRenderingToLayer"),
    };
    static_assert(static_cast<size_t>(MediaPlayerPrivateAVFoundation::MediaRenderingMode::MediaRenderingNone) == 0, "MediaRenderingMode::MediaRenderingNone is not 0 as expected");
    static_assert(static_cast<size_t>(MediaPlayerPrivateAVFoundation::MediaRenderingMode::MediaRenderingToContext) == 1, "MediaRenderingMode::MediaRenderingToContext is not 1 as expected");
    static_assert(static_cast<size_t>(MediaPlayerPrivateAVFoundation::MediaRenderingMode::MediaRenderingToLayer) == 2, "MediaRenderingMode::MediaRenderingToLayer is not 2 as expected");
    ASSERT(static_cast<size_t>(enumerationValue) < std::size(values));
    return values[static_cast<size_t>(enumerationValue)];
}

} // namespace WebCore

#endif
