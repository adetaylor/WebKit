// Copyright (C) 2011-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

// The AVFoundation player's core: the AVPlayerItem's status, buffering, ranges, duration, size and enabled media as
// key-value observing reports them, the AVPlayer's rate and time control status, the requested rate and playing state,
// the current time and its extrapolation, seeking, and the end of playback. MediaPlayerPrivateAVFoundationObjC.mm keeps
// the C++ player that implements MediaPlayerPrivateInterface, creates the AVPlayer and AVPlayerItem, and reaches this
// through MediaPlayerAVFoundationCore's calls; this reaches it through MediaPlayerAVFoundationHost.
//
// WebCore soft-links AVFoundation and CoreMedia: their symbols come from the generated accessors. No AVFoundation class
// is used where its class object would be needed.
//
// Threads: the main thread's, apart from what says otherwise.

internal import AVFoundation
internal import CoreMedia
import WebCore_Private.Core.MediaPlayerAVFoundationHost

// MediaPlayerPrivateAVFoundation::ItemStatus.
private enum ItemStatus: UInt8 {
    case doesNotExist = 0
    case unknown
    case failed
    case readyToPlay
    case playbackBufferEmpty
    case playbackBufferFull
    case playbackLikelyToKeepUp
}

// AVPlayerItemStatus and AVPlayerTimeControlStatus, as the KVO changes and the C++ player have them.
private let itemStatusUnknown = 0
private let itemStatusFailed = 2
private let timeControlStatusPaused = 0
private let timeControlStatusWaitingToPlayAtSpecifiedRate = 1
private let timeControlStatusPlaying = 2

private func utf8(_ string: Swift.String) -> ContiguousArray<UInt8> {
    ContiguousArray(string.utf8)
}

// Only differences of it are used. Not Foundation's Date: its resilient layout costs a metadata lookup per call.
private func wallClockNow() -> Double {
    CFAbsoluteTimeGetCurrent()
}

private func isValidAndNotEmpty(_ range: CMTimeRange) -> Bool {
    // CMTIMERANGE_IS_VALID and !CMTIMERANGE_IS_EMPTY.
    let start = range.start.flags
    let duration = range.duration.flags
    guard start.contains(.valid), duration.contains(.valid), range.duration.epoch == 0, range.duration.value >= 0 else {
        return false
    }
    return CMTimeCompare(range.duration, RendererTime.zero.time) != 0
}

private enum PlayerChange: Sendable {
    case willChangeLikelyToKeepUp
    case willChangeBufferEmpty
    case willChangeBufferFull
    case itemStatus(Int)
    case likelyToKeepUp(Bool)
    case bufferEmpty(Bool)
    case bufferFull(Bool)
    case loadedTimeRanges([CMTimeRange])
    case seekableTimeRanges([CMTimeRange]?, Double, Double)
    case hasEnabledAudio(Bool)
    case hasEnabledVideo(Bool)
    case presentationSize(Float, Float)
    case duration(CMTime)
    case canPlayFastForward(Bool)
    case canPlayFastReverse(Bool)
    case rate(Double)
    case timeControlStatus(Int)
    case didEnd(Double)
    // A change that only logs, as the C++ observer's task did, or does nothing.
    case logOnly(Swift.String)
    case none
}

private struct ObjectBox: @unchecked Sendable {
    let object: NSObject
}

// What MediaPlayerPrivateAVFoundationObjC.mm calls.
@_expose(Cxx)
final class MediaPlayerAVFoundationCore: @unchecked Sendable {
    private let host: WebCore.MediaPlayerAVFoundationHost
    private let listener: MediaPlayerItemListener
    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var periodicTimeObserver: AnyObject?

    private var changes: [UInt64: PlayerChange] = [:]
    private var lastChangeIdentifier: UInt64 = 0

    private var cachedItemStatus = 0
    private var pendingStatusChanges = 0
    private var cachedLikelyToKeepUp = false
    private var cachedBufferEmpty = false
    private var cachedBufferFull = false
    private var cachedHasEnabledAudio = false
    private var cachedHasEnabledVideo = false
    private var cachedCanPlayFastForward = false
    private var cachedCanPlayFastReverse = false
    private var cachedPresentationSize: (width: Float, height: Float) = (0, 0)
    private var loadedRanges: [WebCore.MediaPlayerAVFoundationTimeRange] = []
    private var cachedSeekableRanges: [CMTimeRange]?
    private var cachedSeekableTimeRangesLastModifiedTime: Double?
    private var cachedLiveUpdateInterval: Double?

    private var cachedRate: Double = 0
    private var cachedTimeControlStatus = timeControlStatusPaused
    private var shouldObserveTimeControlStatus = false
    // The player whose time control status is observed, so that removing the observation can't throw.
    private var timeControlStatusObservedPlayer: AVPlayer?
    private var automaticallyWaitsToMinimizeStalling = false
    private var requestedPlaying = false
    private var requestedRate: Double = 1

    private var wallClockAtCachedCurrentTime: Double?
    private var timeControlStatusAtCachedCurrentTime = timeControlStatusPaused
    private var requestedRateAtCachedCurrentTime: Double = 0
    private var lastPeriodicObserverTime = RendererTime.zero

    @_expose(Cxx)
    init(_ host: WebCore.MediaPlayerAVFoundationHost) {
        self.host = host
        listener = MediaPlayerItemListener()
        listener.core = self
    }

    // MARK: Logging

    private func log(_ level: WebCore.MediaPlayerAVFoundationLogLevel, _ message: @autoclosure () -> Swift.String) {
        guard host.willLog(level) else {
            return
        }
        let bytes = utf8(message())
        host.log(level, bytes.span)
    }

    // MARK: The AVPlayer and AVPlayerItem

    // The AVPlayer or AVPlayerItem that the C++ player made, observed from now on.
    @_expose(Cxx)
    func attach(_ object: NSObject) {
        if let player = AVFoundationClass.cast(object, to: AVFoundationClass.AVPlayer) {
            attachPlayer(player)
            return
        }
        if let item = AVFoundationClass.cast(object, to: AVFoundationClass.AVPlayerItem) {
            attachItem(item)
        }
    }

    private func attachPlayer(_ newPlayer: AVPlayer) {
        if let _ = player {
            return
        }
        player = newPlayer
        listener.observePlayer(newPlayer)
        automaticallyWaitsToMinimizeStalling = newPlayer.automaticallyWaitsToMinimizeStalling
        setShouldObserveTimeControlStatus(true)

        periodicTimeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10, flags: .valid, epoch: 0), queue: .main) { [weak self] time in
            guard let self else {
                return
            }
            let mediaTime = RendererTime(time: time)
            if mediaTime == .zero && self.lastPeriodicObserverTime > .zero && !self.host.seeking() {
                self.log(.Always, "MediaPlayerPrivateAVFoundationObjC::createAVPlayer PeriodicTimeObserver called with zero")
            }
            if mediaTime < .zero {
                self.log(.Always, "MediaPlayerPrivateAVFoundationObjC::createAVPlayer PeriodicTimeObserver called with negative time \(mediaTime.logDescription)")
            }
            if mediaTime < self.lastPeriodicObserverTime {
                self.log(.Always, "MediaPlayerPrivateAVFoundationObjC::createAVPlayer PeriodicTimeObserver went backwards, was \(self.lastPeriodicObserverTime.logDescription), is now \(mediaTime.logDescription)")
            }
            if !mediaTime.isFinite {
                self.log(.Always, "MediaPlayerPrivateAVFoundationObjC::createAVPlayer PeriodicTimeObserver called with called with infinite time")
            }
            self.lastPeriodicObserverTime = mediaTime
            self.currentTimeDidChange(time)
        } as AnyObject
    }

    private func attachItem(_ newItem: AVPlayerItem) {
        if let _ = item {
            return
        }
        item = newItem
        listener.observeItem(newItem)
    }

    // The C++ player cancels loading: stop observing and forget what was observed.
    @_expose(Cxx)
    func detach() {
        if let item {
            listener.stopObservingItem(item)
        }
        if let player {
            listener.stopObservingPlayer(player)
            setShouldObserveTimeControlStatus(false)
            if let periodicTimeObserver {
                player.removeTimeObserver(periodicTimeObserver)
            }
        }
        periodicTimeObserver = nil
        item = nil
        player = nil

        pendingStatusChanges = 0
        cachedItemStatus = Int(ItemStatus.doesNotExist.rawValue)
        cachedSeekableRanges = nil
        cachedHasEnabledAudio = false
        cachedHasEnabledVideo = false
        cachedPresentationSize = (0, 0)
        loadedRanges = []
    }

    // MARK: Changes, in the order key-value observing reported them

    fileprivate func enqueue(_ change: PlayerChange) {
        lastChangeIdentifier += 1
        changes[lastChangeIdentifier] = change
        host.queueChange(lastChangeIdentifier)
    }

    // From the media player's event loop.
    @_expose(Cxx)
    func applyChange(_ identifier: UInt64) {
        guard let change = changes.removeValue(forKey: identifier) else {
            return
        }
        switch change {
        case .willChangeLikelyToKeepUp, .willChangeBufferEmpty, .willChangeBufferFull:
            pendingStatusChanges += 1
            logChange(change)
        case .itemStatus(let status):
            cachedItemStatus = status
            host.updateStates()
            logChange(change)
        case .likelyToKeepUp(let value):
            cachedLikelyToKeepUp = value
            settlePendingStatusChange()
            logChange(change)
        case .bufferEmpty(let value):
            cachedBufferEmpty = value
            settlePendingStatusChange()
            logChange(change)
        case .bufferFull(let value):
            cachedBufferFull = value
            settlePendingStatusChange()
            logChange(change)
        case .loadedTimeRanges(let ranges):
            loadedRanges = ranges.filter(isValidAndNotEmpty).map { WebCore.MediaPlayerAVFoundationTimeRange(start: $0.start, end: CMTimeRangeGetEnd($0)) }
            host.loadedTimeRangesDidChange()
            host.updateStates()
        case .seekableTimeRanges(let ranges, let lastModifiedTime, let liveUpdateInterval):
            cachedSeekableRanges = ranges
            cachedSeekableTimeRangesLastModifiedTime = lastModifiedTime
            cachedLiveUpdateInterval = liveUpdateInterval
            host.seekableTimeRangesDidChange()
            host.updateStates()
        case .hasEnabledAudio(let value):
            log(.Always, "MediaPlayerPrivateAVFoundationObjC::hasEnabledAudioDidChange \(value)")
            cachedHasEnabledAudio = value
            host.tracksChanged()
            host.updateStates()
            logChange(change)
        case .hasEnabledVideo(let value):
            log(.Always, "MediaPlayerPrivateAVFoundationObjC::hasEnabledVideoDidChange \(value)")
            cachedHasEnabledVideo = value
            host.tracksChanged()
            host.updateStates()
            logChange(change)
        case .presentationSize(let width, let height):
            cachedPresentationSize = (width, height)
            host.sizeChanged()
            host.updateStates()
            logChange(change)
        case .duration(let duration):
            host.durationDidChange(duration)
            logChange(change)
        case .canPlayFastForward(let value):
            cachedCanPlayFastForward = value
            logChange(change)
        case .canPlayFastReverse(let value):
            cachedCanPlayFastReverse = value
            logChange(change)
        case .rate(let rate):
            rateDidChange(rate)
            logChange(change)
        case .timeControlStatus(let status):
            timeControlStatusDidChange(status)
            logChange(change)
        case .didEnd(let currentTime):
            requestedPlaying = false
            timeControlStatusAtCachedCurrentTime = timeControlStatusPaused
            wallClockAtCachedCurrentTime = nil
            host.didEnd(currentTime)
        case .logOnly:
            logChange(change)
        case .none:
            break
        }
    }

    private func logChange(_ change: PlayerChange) {
        guard host.willLog(.Debug) else {
            return
        }
        let description: Swift.String
        switch change {
        case .willChangeLikelyToKeepUp: description = "will change 'playbackLikelyToKeepUp'"
        case .willChangeBufferEmpty: description = "will change 'playbackBufferEmpty'"
        case .willChangeBufferFull: description = "will change 'playbackBufferFull'"
        case .itemStatus(let value): description = "did change 'status' to \(value)"
        case .likelyToKeepUp(let value): description = "did change 'playbackLikelyToKeepUp' to \(value ? 1 : 0)"
        case .bufferEmpty(let value): description = "did change 'playbackBufferEmpty' to \(value ? 1 : 0)"
        case .bufferFull(let value): description = "did change 'playbackBufferFull' to \(value ? 1 : 0)"
        case .hasEnabledAudio(let value): description = "did change 'hasEnabledAudio' to \(value ? 1 : 0)"
        case .hasEnabledVideo(let value): description = "did change 'hasEnabledVideo' to \(value ? 1 : 0)"
        case .presentationSize(let width, let height): description = "did change 'presentationSize' to {\(width), \(height)}"
        case .duration(let value): description = "did change 'duration' to \(RendererTime(time: value).logDescription)"
        case .canPlayFastForward(let value): description = "did change 'canPlayFastForward' to \(value ? 1 : 0)"
        case .canPlayFastReverse(let value): description = "did change 'canPlayFastReverse' to \(value ? 1 : 0)"
        case .rate(let value): description = "did change 'rate' to \(value)"
        case .timeControlStatus(let value): description = "did change 'timeControlStatus' to \(value)"
        case .logOnly(let keyPath): description = "will change '\(keyPath)'"
        case .loadedTimeRanges, .seekableTimeRanges, .didEnd, .none:
            return
        }
        log(.Debug, "MediaPlayerPrivateAVFoundation::observeValueForKeyPath \(description)")
    }

    private func settlePendingStatusChange() {
        assert(pendingStatusChanges > 0)
        pendingStatusChanges -= 1
        if pendingStatusChanges == 0 {
            host.updateStates()
        }
    }

    // MARK: Status

    // MediaPlayerPrivateAVFoundation::ItemStatus's value.
    @_expose(Cxx)
    func itemStatus() -> UInt8 {
        guard let _ = item else {
            return ItemStatus.doesNotExist.rawValue
        }
        if cachedItemStatus == itemStatusUnknown {
            return ItemStatus.unknown.rawValue
        }
        if cachedItemStatus == itemStatusFailed {
            return ItemStatus.failed.rawValue
        }
        if cachedLikelyToKeepUp {
            return ItemStatus.playbackLikelyToKeepUp.rawValue
        }
        if cachedBufferFull {
            return ItemStatus.playbackBufferFull.rawValue
        }
        if cachedBufferEmpty {
            return ItemStatus.playbackBufferEmpty.rawValue
        }
        return ItemStatus.readyToPlay.rawValue
    }

    @_expose(Cxx)
    func hasEnabledAudio() -> Bool {
        cachedHasEnabledAudio
    }

    @_expose(Cxx)
    func hasEnabledVideo() -> Bool {
        cachedHasEnabledVideo
    }

    @_expose(Cxx)
    func canPlayFastForward() -> Bool {
        cachedCanPlayFastForward
    }

    @_expose(Cxx)
    func canPlayFastReverse() -> Bool {
        cachedCanPlayFastReverse
    }

    // The asset's size, before there is an item.
    @_expose(Cxx)
    func presentationSizeDidChange(_ width: Float, _ height: Float) {
        cachedPresentationSize = (width, height)
        host.sizeChanged()
        host.updateStates()
    }

    @_expose(Cxx)
    func presentationWidth() -> Float {
        cachedPresentationSize.width
    }

    @_expose(Cxx)
    func presentationHeight() -> Float {
        cachedPresentationSize.height
    }

    // MARK: Ranges

    @_expose(Cxx)
    func loadedRangeCount() -> Int {
        loadedRanges.count
    }

    @_expose(Cxx)
    func loadedRange(_ index: Int) -> WebCore.MediaPlayerAVFoundationTimeRange {
        loadedRanges[index]
    }

    private func seekableRanges() -> [CMTimeRange] {
        // No Equatable comparison of CMTimeRange: its conformance is CoreMedia's overlay's.
        if case .none = cachedSeekableRanges, let item {
            cachedSeekableRanges = timeRanges(item.seekableTimeRanges as NSArray)
        }
        return cachedSeekableRanges ?? []
    }

    // Whether the C++ player's maximum seekable time is the duration instead.
    @_expose(Cxx)
    func hasSeekableRanges() -> Bool {
        !seekableRanges().isEmpty
    }

    @_expose(Cxx)
    func minTimeSeekable() -> CMTime {
        guard let ranges = cachedSeekableRanges, !ranges.isEmpty else {
            return RendererTime.zero.time
        }
        var minTimeSeekable = RendererTime.positiveInfinite
        var hasValidRange = false
        for range in ranges where isValidAndNotEmpty(range) {
            hasValidRange = true
            let start = RendererTime(time: range.start)
            if minTimeSeekable > start {
                minTimeSeekable = start
            }
        }
        return hasValidRange ? minTimeSeekable.time : RendererTime.zero.time
    }

    @_expose(Cxx)
    func maxTimeSeekable() -> CMTime {
        var maxTimeSeekable = RendererTime.zero
        for range in seekableRanges() where isValidAndNotEmpty(range) {
            let end = RendererTime(time: CMTimeRangeGetEnd(range))
            if maxTimeSeekable < end {
                maxTimeSeekable = end
            }
        }
        return maxTimeSeekable.time
    }

    @_expose(Cxx)
    func seekableTimeRangesLastModifiedTime() -> Double {
        if cachedSeekableTimeRangesLastModifiedTime == nil {
            var value: Double = 0
            if let item {
                value = doubleProperty(item, "seekableTimeRangesLastModifiedTime")
            }
            cachedSeekableTimeRangesLastModifiedTime = value
        }
        return cachedSeekableTimeRangesLastModifiedTime ?? 0
    }

    @_expose(Cxx)
    func liveUpdateInterval() -> Double {
        if cachedLiveUpdateInterval == nil {
            var value: Double = 0
            if let item {
                value = doubleProperty(item, "liveUpdateInterval")
            }
            cachedLiveUpdateInterval = value
        }
        return cachedLiveUpdateInterval ?? 0
    }

    // MARK: Rate

    @_expose(Cxx)
    func requestedRateValue() -> Double {
        requestedRate
    }

    @_expose(Cxx)
    func effectiveRate() -> Double {
        cachedTimeControlStatus == timeControlStatusWaitingToPlayAtSpecifiedRate ? 0 : cachedRate
    }

    @_expose(Cxx)
    func timeControlStatus() -> Int {
        cachedTimeControlStatus
    }

    @_expose(Cxx)
    func isPaused() -> Bool {
        cachedTimeControlStatus == timeControlStatusPaused
    }

    @_expose(Cxx)
    func setRequestedRate(_ rate: Double) {
        requestedRate = rate
        if requestedPlaying {
            setPlayerRate(rate, nil)
        }
        wallClockAtCachedCurrentTime = nil
    }

    @_expose(Cxx)
    func play(_ hasHostTime: Bool, _ hostTime: UInt64) {
        requestedPlaying = true
        setPlayerRate(requestedRate, hasHostTime ? hostTime : nil)
    }

    @_expose(Cxx)
    func pause(_ hasHostTime: Bool, _ hostTime: UInt64) {
        requestedPlaying = false
        setPlayerRate(0, hasHostTime ? hostTime : nil)
    }

    private func setPlayerRate(_ rate: Double, _ hostTime: UInt64?) {
        host.applyAudioTimePitchAlgorithm()

        setShouldObserveTimeControlStatus(false)

        // -[AVPlayer setRate:time:atHostTime:] will throw if AVPlayer.automaticallyWaitsToMinimizeStalling
        // is set to YES. Disable when synchronized playback is indicated by the optional hostTime parameter
        // and enable otherwise.
        let shouldAutomaticallyWait = hostTime == nil
        if automaticallyWaitsToMinimizeStalling != shouldAutomaticallyWait {
            player?.automaticallyWaitsToMinimizeStalling = shouldAutomaticallyWait
            automaticallyWaitsToMinimizeStalling = shouldAutomaticallyWait
        }

        if let hostTime {
            let cmHostTime = CMClockMakeHostTimeFromSystemUnits(hostTime)
            log(.Info, "MediaPlayerPrivateAVFoundationObjC::setPlayerRate setting rate to \(rate) at host time \(CMTimeGetSeconds(cmHostTime))")
            player?.setRate(Float(rate), time: RendererTime.invalid.time, atHostTime: cmHostTime)
        } else {
            player?.rate = Float(rate)
        }

        setShouldObserveTimeControlStatus(true)

        wallClockAtCachedCurrentTime = nil
    }

    private func setShouldObserveTimeControlStatus(_ shouldObserve: Bool) {
        if shouldObserve == shouldObserveTimeControlStatus {
            return
        }
        shouldObserveTimeControlStatus = shouldObserve
        if shouldObserve {
            guard let player else {
                return
            }
            if case .none = timeControlStatusObservedPlayer {
                listener.observeTimeControlStatus(player)
                timeControlStatusObservedPlayer = player
            }
            timeControlStatusDidChange(player.timeControlStatus.rawValue)
        } else if let observedPlayer = timeControlStatusObservedPlayer {
            listener.stopObservingTimeControlStatus(observedPlayer)
            timeControlStatusObservedPlayer = nil
        }
    }

    private func rateDidChange(_ rate: Double) {
        if cachedRate == rate {
            return
        }
        cachedRate = rate
        host.updateStates()
        host.rateChanged()
    }

    private func timeControlStatusDidChange(_ timeControlStatus: Int) {
        if cachedTimeControlStatus == timeControlStatus {
            return
        }

        log(.Always, "MediaPlayerPrivateAVFoundationObjC::timeControlStatusDidChange \(timeControlStatus), observing = \(shouldObserveTimeControlStatus ? 1 : 0)")

        if !shouldObserveTimeControlStatus {
            return
        }

        cachedTimeControlStatus = timeControlStatus
        host.rateChanged()
        host.updateIsAudible()
        wallClockAtCachedCurrentTime = nil

        if !host.isCurrentPlaybackTargetWireless() {
            return
        }

        let playerIsPlaying = cachedTimeControlStatus != timeControlStatusPaused
        if playerIsPlaying != requestedPlaying {
            requestedPlaying = playerIsPlaying
            host.playbackStateChanged()
        }
    }

    // MARK: Time

    // After the C++ player checked that metadata is available and the item exists. The cached time itself reaches the
    // C++ player through currentTimeDidChange(), which converts it once.
    @_expose(Cxx)
    func currentTimeSample() -> WebCore.MediaPlayerAVFoundationTimeSample {
        guard let wallClockAtCachedCurrentTime else {
            return refreshCurrentTime()
        }
        guard timeControlStatusAtCachedCurrentTime == timeControlStatusPlaying else {
            return WebCore.MediaPlayerAVFoundationTimeSample(elapsed: 0, extrapolate: false)
        }
        return WebCore.MediaPlayerAVFoundationTimeSample(elapsed: (wallClockNow() - wallClockAtCachedCurrentTime) * requestedRateAtCachedCurrentTime, extrapolate: true)
    }

    @inline(never)
    private func refreshCurrentTime() -> WebCore.MediaPlayerAVFoundationTimeSample {
        if let item {
            currentTimeDidChange(item.currentTime())
        }
        guard timeControlStatusAtCachedCurrentTime == timeControlStatusPlaying, let wallClockAtCachedCurrentTime else {
            return WebCore.MediaPlayerAVFoundationTimeSample(elapsed: 0, extrapolate: false)
        }
        return WebCore.MediaPlayerAVFoundationTimeSample(elapsed: (wallClockNow() - wallClockAtCachedCurrentTime) * requestedRateAtCachedCurrentTime, extrapolate: true)
    }

    private func currentTimeDidChange(_ time: CMTime) {
        wallClockAtCachedCurrentTime = wallClockNow()
        timeControlStatusAtCachedCurrentTime = cachedTimeControlStatus
        requestedRateAtCachedCurrentTime = requestedRate
        host.currentTimeDidChange(time)
    }

    // MARK: Seeking

    @_expose(Cxx)
    func seek(_ time: CMTime, _ toleranceBefore: CMTime, _ toleranceAfter: CMTime) {
        // [AVPlayerItem seekToTime] will throw an exception if a tolerance is invalid or negative.
        var before = toleranceBefore
        var after = toleranceAfter
        if !before.flags.contains(.valid) || CMTimeCompare(before, RendererTime.zero.time) < 0 {
            before = RendererTime.positiveInfinite.time
        }
        if !after.flags.contains(.valid) || CMTimeCompare(after, RendererTime.zero.time) < 0 {
            after = RendererTime.positiveInfinite.time
        }

        setShouldObserveTimeControlStatus(false)
        item?.seek(to: time, toleranceBefore: before, toleranceAfter: after) { [weak self] finished in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.setShouldObserveTimeControlStatus(true)
                self.host.seekCompleted(finished)
            }
        }
    }
}

private func timeRanges(_ array: NSArray?) -> [CMTimeRange] {
    guard let array else {
        return []
    }
    var ranges: [CMTimeRange] = []
    ranges.reserveCapacity(array.count)
    for value in array {
        if let value = value as? NSValue {
            ranges.append(value.timeRangeValue)
        }
    }
    return ranges
}

// AVPlayerItem's seekableTimeRangesLastModifiedTime and liveUpdateInterval, which are SPI.
private func doubleProperty(_ object: NSObject, _ key: Swift.String) -> Double {
    guard object.responds(to: NSSelectorFromString(key)) else {
        return 0
    }
    return (object.value(forKey: key) as? NSNumber)?.doubleValue ?? 0
}

private func boolValue(_ value: Any?) -> Bool {
    (value as? NSNumber)?.boolValue ?? false
}

private func intValue(_ value: Any?) -> Int {
    (value as? NSNumber)?.intValue ?? 0
}

private let itemKeyPaths = [
    "presentationSize",
    "status",
    "seekableTimeRanges",
    "loadedTimeRanges",
    "playbackLikelyToKeepUp",
    "playbackBufferFull",
    "playbackBufferEmpty",
    "duration",
    "hasEnabledAudio",
    "hasEnabledVideo",
    "canPlayFastForward",
    "canPlayFastReverse",
]
private let rateKeyPath = "rate"
private let timeControlStatusKeyPath = "timeControlStatus"

// Observes the AVPlayerItem's and AVPlayer's keys that the core caches, and the item's end of playback, and hands what
// they report to the core on the main thread.
final class MediaPlayerItemListener: NSObject, @unchecked Sendable {
    fileprivate weak var core: MediaPlayerAVFoundationCore?
    private let backgroundQueue = DispatchQueue(label: "MediaPlayerAVFoundationCore Background Queue")

    func observeItem(_ item: NSObject) {
        NotificationCenter.default.addObserver(self, selector: #selector(didEnd(_:)), name: AVFoundationSoftLink.AVPlayerItemDidPlayToEndTimeNotification, object: item)
        for keyPath in itemKeyPaths {
            var options: NSKeyValueObservingOptions = [.new, .prior]
            if keyPath == "duration" {
                options.insert(.initial)
            }
            unsafe item.addObserver(self, forKeyPath: keyPath, options: options, context: nil)
        }
    }

    func stopObservingItem(_ item: NSObject) {
        NotificationCenter.default.removeObserver(self, name: AVFoundationSoftLink.AVPlayerItemDidPlayToEndTimeNotification, object: item)
        for keyPath in itemKeyPaths {
            item.removeObserver(self, forKeyPath: keyPath)
        }
    }

    func observePlayer(_ player: NSObject) {
        unsafe player.addObserver(self, forKeyPath: rateKeyPath, options: [.new], context: nil)
    }

    func stopObservingPlayer(_ player: NSObject) {
        player.removeObserver(self, forKeyPath: rateKeyPath)
    }

    func observeTimeControlStatus(_ player: NSObject) {
        unsafe player.addObserver(self, forKeyPath: timeControlStatusKeyPath, options: [.new], context: nil)
    }

    func stopObservingTimeControlStatus(_ player: NSObject) {
        player.removeObserver(self, forKeyPath: timeControlStatusKeyPath)
    }

    private func enqueue(_ change: PlayerChange) {
        onMainThread { [weak self] in
            self?.core?.enqueue(change)
        }
    }

    @objc private func didEnd(_ notification: Notification) {
        var currentTime: Double = 0
        if let item = AVFoundationClass.cast(notification.object as AnyObject?, to: AVFoundationClass.AVPlayerItem) {
            currentTime = CMTimeGetSeconds(item.currentTime())
        }
        enqueue(.didEnd(currentTime))
    }

    override func observeValue(forKeyPath keyPath: Swift.String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath else {
            return
        }
        let newValue = change?[.newKey]
        let willChange = boolValue(change?[.notificationIsPriorKey])

        if keyPath == rateKeyPath {
            enqueue(.rate((newValue as? NSNumber)?.doubleValue ?? 0))
            return
        }
        if keyPath == timeControlStatusKeyPath {
            enqueue(.timeControlStatus(intValue(newValue)))
            return
        }

        if keyPath == "seekableTimeRanges" {
            // -liveUpdateInterval and -seekableTimeRangesLastModifiedTime are not KVO observable, but may also hang when queried.
            // Query their values here on a background thread, and pass to the main thread for caching.
            let ranges = (newValue as? NSArray).map { timeRanges($0) }
            if let object = object as? NSObject, let item = AVFoundationClass.cast(object, to: AVFoundationClass.AVPlayerItem) {
                let box = ObjectBox(object: item)
                backgroundQueue.async { [weak self] in
                    guard let item = AVFoundationClass.cast(box.object, to: AVFoundationClass.AVPlayerItem) else {
                        return
                    }
                    let lastModifiedTime = doubleProperty(item, "seekableTimeRangesLastModifiedTime")
                    let liveUpdateInterval = doubleProperty(item, "liveUpdateInterval")
                    self?.enqueue(.seekableTimeRanges(ranges, lastModifiedTime, liveUpdateInterval))
                }
            }
        }

        if willChange {
            switch keyPath {
            case "playbackLikelyToKeepUp": enqueue(.willChangeLikelyToKeepUp)
            case "playbackBufferEmpty": enqueue(.willChangeBufferEmpty)
            case "playbackBufferFull": enqueue(.willChangeBufferFull)
            case "loadedTimeRanges", "seekableTimeRanges": enqueue(.none)
            default: enqueue(.logOnly(keyPath))
            }
            return
        }

        switch keyPath {
        case "status":
            enqueue(.itemStatus(intValue(newValue)))
        case "playbackLikelyToKeepUp":
            enqueue(.likelyToKeepUp(boolValue(newValue)))
        case "playbackBufferEmpty":
            enqueue(.bufferEmpty(boolValue(newValue)))
        case "playbackBufferFull":
            enqueue(.bufferFull(boolValue(newValue)))
        case "loadedTimeRanges":
            enqueue(.loadedTimeRanges(timeRanges(newValue as? NSArray)))
        case "hasEnabledAudio":
            enqueue(.hasEnabledAudio(boolValue(newValue)))
        case "hasEnabledVideo":
            enqueue(.hasEnabledVideo(boolValue(newValue)))
        case "presentationSize":
            // The item's size, which the change's NSValue holds; NSValue's size accessor is AppKit's.
            var size = CGSize.zero
            if let object = object as? NSObject, let item = AVFoundationClass.cast(object, to: AVFoundationClass.AVPlayerItem) {
                size = item.presentationSize
            }
            enqueue(.presentationSize(Float(size.width), Float(size.height)))
        case "duration":
            enqueue(.duration((newValue as? NSValue)?.timeValue ?? RendererTime.invalid.time))
        case "canPlayFastReverse":
            enqueue(.canPlayFastReverse(boolValue(newValue)))
        case "canPlayFastForward":
            enqueue(.canPlayFastForward(boolValue(newValue)))
        case "seekableTimeRanges":
            enqueue(.none)
        default:
            break
        }
    }
}
