// Copyright (C) 2024 Apple Inc. All rights reserved.
// Copyright (C) 2023-2024 Apple Inc. All rights reserved.
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

// The observation of the sample buffer renderers (their errors, automatic flushes, decoding and display state) for
// the audio and video renderer cores, and the renderers' queue management.
//
// WebCore soft-links AVFoundation: its classes and constants come from the generated accessors. No AVFoundation class
// is used where its class object would be needed.

internal import AVFoundation
internal import CoreMedia

// MARK: Renderers

// The queue management of AVSampleBufferDisplayLayer, AVSampleBufferVideoRenderer and AVSampleBufferAudioRenderer,
// which the SDK deprecates in favour of a render synchronizer's sample buffer receivers. The C++ renderers used these
// methods; the cores call them through this protocol, whose deprecated witnesses keep the deprecation warnings out of
// their callers.
protocol QueuedSampleBufferRenderer: Sendable {
    var object: NSObject { get }
    var isReadyForMoreMediaData: Bool { get }
    var status: Int { get }
    var requiresFlushToResumeDecoding: Bool { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
    func stopRequestingMediaData()
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void)
}

// A display layer is used on the main thread only.
struct DisplayLayerHandle: QueuedSampleBufferRenderer, @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer

    var object: NSObject { layer }

    @available(*, deprecated)
    var isReadyForMoreMediaData: Bool { MainActor.assumeIsolated { layer.isReadyForMoreMediaData } }

    @available(*, deprecated)
    var status: Int { MainActor.assumeIsolated { layer.status.rawValue } }

    @available(*, deprecated)
    var requiresFlushToResumeDecoding: Bool { MainActor.assumeIsolated { layer.requiresFlushToResumeDecoding } }

    @available(*, deprecated)
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let box = SampleBufferBox(sampleBuffer: sampleBuffer)
        MainActor.assumeIsolated { layer.enqueue(box.sampleBuffer) }
    }

    @available(*, deprecated)
    func flush() { MainActor.assumeIsolated { layer.flush() } }

    @available(*, deprecated)
    func stopRequestingMediaData() { MainActor.assumeIsolated { layer.stopRequestingMediaData() } }

    @available(*, deprecated)
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        MainActor.assumeIsolated { layer.requestMediaDataWhenReady(on: queue, using: block) }
    }
}

private struct SampleBufferBox: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
}

struct VideoRendererHandle: QueuedSampleBufferRenderer, @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer

    var object: NSObject { renderer }

    @available(*, deprecated)
    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }

    @available(*, deprecated)
    var status: Int { renderer.status.rawValue }

    @available(*, deprecated)
    var requiresFlushToResumeDecoding: Bool { renderer.requiresFlushToResumeDecoding }

    @available(*, deprecated)
    func enqueue(_ sampleBuffer: CMSampleBuffer) { renderer.enqueue(sampleBuffer) }

    @available(*, deprecated)
    func flush() { renderer.flush() }

    @available(*, deprecated)
    func stopRequestingMediaData() { renderer.stopRequestingMediaData() }

    @available(*, deprecated)
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    // The deprecated queue management, through the protocol.
    var queued: any QueuedSampleBufferRenderer { self }

    func expectMinimumUpcomingSampleBufferPresentationTime(_ time: CMTime) {
#if !os(watchOS)
        renderer.__expectMinimumUpcomingSampleBufferPresentationTime(time)
#endif
    }
}

struct AudioRendererHandle: QueuedSampleBufferRenderer, @unchecked Sendable {
    let renderer: AVSampleBufferAudioRenderer

    var object: NSObject { renderer }

    @available(*, deprecated)
    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }

    @available(*, deprecated)
    var status: Int { renderer.status.rawValue }

    var requiresFlushToResumeDecoding: Bool { false }

    @available(*, deprecated)
    func enqueue(_ sampleBuffer: CMSampleBuffer) { renderer.enqueue(sampleBuffer) }

    @available(*, deprecated)
    func flush() { renderer.flush() }

    @available(*, deprecated)
    func stopRequestingMediaData() { renderer.stopRequestingMediaData() }

    @available(*, deprecated)
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    // The deprecated queue management, through the protocol.
    var queued: any QueuedSampleBufferRenderer { self }
}

// The renderer of an object the C++ renderer made, if it is one. No generic code over the classes: it would need their
// class objects, which WebCore doesn't link.
func queuedSampleBufferRenderer(_ object: AnyObject?) -> (any QueuedSampleBufferRenderer)? {
    if let layer = AVFoundationClass.cast(object, to: AVFoundationClass.AVSampleBufferDisplayLayer) {
        return DisplayLayerHandle(layer: layer)
    }
    if let renderer = AVFoundationClass.cast(object, to: AVFoundationClass.AVSampleBufferVideoRenderer) {
        return VideoRendererHandle(renderer: renderer)
    }
    if let renderer = AVFoundationClass.cast(object, to: AVFoundationClass.AVSampleBufferAudioRenderer) {
        return AudioRendererHandle(renderer: renderer)
    }
    return nil
}

// The video renderer that enqueues a display layer's or video renderer's samples. On the main thread.
func videoRendererHandle(_ object: AnyObject?) -> VideoRendererHandle? {
    if let layer = AVFoundationClass.cast(object, to: AVFoundationClass.AVSampleBufferDisplayLayer) {
        let handle = DisplayLayerHandle(layer: layer)
        return MainActor.assumeIsolated { VideoRendererHandle(renderer: handle.layer.sampleBufferRenderer) }
    }
    if let renderer = AVFoundationClass.cast(object, to: AVFoundationClass.AVSampleBufferVideoRenderer) {
        return VideoRendererHandle(renderer: renderer)
    }
    return nil
}

func isDisplayLayer(_ object: AnyObject?) -> Bool {
    if let _ = AVFoundationClass.cast(object, to: AVFoundationClass.AVSampleBufferDisplayLayer) {
        return true
    }
    return false
}

func isVideoRenderer(_ object: AnyObject?) -> Bool {
    if let _ = AVFoundationClass.cast(object, to: AVFoundationClass.AVSampleBufferVideoRenderer) {
        return true
    }
    return isDisplayLayer(object)
}

func isAudioRenderer(_ object: AnyObject?) -> Bool {
    if let _ = AVFoundationClass.cast(object, to: AVFoundationClass.AVSampleBufferAudioRenderer) {
        return true
    }
    return false
}

// A renderer, weakly, for its own request callback.
final class WeakQueuedSampleBufferRenderer: @unchecked Sendable {
    private weak var object: NSObject?

    init(_ renderer: any QueuedSampleBufferRenderer) {
        object = renderer.object
    }

    func stopRequestingMediaData() {
        guard let object, let renderer = queuedSampleBufferRenderer(object) else {
            return
        }
        renderer.stopRequestingMediaData()
    }
}

func onMainThread(_ body: @escaping @Sendable () -> Void) {
    if Thread.isMainThread {
        body()
        return
    }
    DispatchQueue.main.async(execute: body)
}

// MARK: Listener

// What the cores hear from the renderers they observe, on the main thread.
protocol WebAVSampleBufferListenerClient: AnyObject, Sendable {
    func videoRendererDidReceiveError(_ renderer: NSObject, _ error: NSError?)
    func videoRendererRequiresFlushToResumeDecodingChanged(_ renderer: NSObject, _ requiresFlush: Bool)
    func videoRendererReadyForDisplayChanged(_ renderer: NSObject, _ isReadyForDisplay: Bool)
    func outputObscuredDueToInsufficientExternalProtectionChanged(_ obscured: Bool)
    func audioRendererDidReceiveError(_ renderer: NSObject, _ error: NSError?)
    func audioRendererWasAutomaticallyFlushed(_ renderer: NSObject, _ flushTime: CMTime)
}

private let errorKeyPath = "error"
private let outputObscuredDueToInsufficientExternalProtectionKeyPath = "outputObscuredDueToInsufficientExternalProtection"

final class WebAVSampleBufferListener: NSObject, @unchecked Sendable {
    private weak var client: (any WebAVSampleBufferListenerClient)?
    // Main.
    private var videoRenderers: [NSObject] = []
    private var audioRenderers: [NSObject] = []

    init(client: any WebAVSampleBufferListenerClient) {
        self.client = client
    }

    func invalidate() {
        client = nil
        for renderer in videoRenderers {
            stopObservingVideoRenderer(renderer)
        }
        for renderer in audioRenderers {
            stopObservingAudioRenderer(renderer)
        }
    }

    func beginObservingVideoRenderer(_ renderer: NSObject) {
        videoRenderers.append(renderer)
        unsafe renderer.addObserver(self, forKeyPath: errorKeyPath, options: .new, context: nil)
        unsafe renderer.addObserver(self, forKeyPath: outputObscuredDueToInsufficientExternalProtectionKeyPath, options: .new, context: nil)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(layerFailedToDecode(_:)), name: AVFoundationSoftLink.AVSampleBufferDisplayLayerFailedToDecodeNotification, object: renderer)
        center.addObserver(self, selector: #selector(layerFailedToDecode(_:)), name: AVFoundationSoftLink.AVSampleBufferVideoRendererDidFailToDecodeNotification, object: renderer)
        center.addObserver(self, selector: #selector(layerRequiresFlushToResumeDecodingChanged(_:)), name: AVFoundationSoftLink.AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChangeNotification, object: renderer)
        center.addObserver(self, selector: #selector(layerRequiresFlushToResumeDecodingChanged(_:)), name: AVFoundationSoftLink.AVSampleBufferVideoRendererRequiresFlushToResumeDecodingDidChangeNotification, object: renderer)
        center.addObserver(self, selector: #selector(layerReadyForDisplayChanged(_:)), name: AVFoundationSoftLink.AVSampleBufferDisplayLayerReadyForDisplayDidChangeNotification, object: renderer)
    }

    func stopObservingVideoRenderer(_ renderer: NSObject) {
        guard let index = videoRenderers.firstIndex(where: { $0 === renderer }) else {
            return
        }
        renderer.removeObserver(self, forKeyPath: errorKeyPath)
        renderer.removeObserver(self, forKeyPath: outputObscuredDueToInsufficientExternalProtectionKeyPath)
        videoRenderers.remove(at: index)
        let center = NotificationCenter.default
        center.removeObserver(self, name: AVFoundationSoftLink.AVSampleBufferDisplayLayerFailedToDecodeNotification, object: renderer)
        center.removeObserver(self, name: AVFoundationSoftLink.AVSampleBufferVideoRendererDidFailToDecodeNotification, object: renderer)
        center.removeObserver(self, name: AVFoundationSoftLink.AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChangeNotification, object: renderer)
        center.removeObserver(self, name: AVFoundationSoftLink.AVSampleBufferVideoRendererRequiresFlushToResumeDecodingDidChangeNotification, object: renderer)
        center.removeObserver(self, name: AVFoundationSoftLink.AVSampleBufferDisplayLayerReadyForDisplayDidChangeNotification, object: renderer)
    }

    func beginObservingAudioRenderer(_ renderer: NSObject) {
        audioRenderers.append(renderer)
        unsafe renderer.addObserver(self, forKeyPath: errorKeyPath, options: .new, context: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioRendererWasAutomaticallyFlushed(_:)), name: AVFoundationSoftLink.AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification, object: renderer)
    }

    func stopObservingAudioRenderer(_ renderer: NSObject) {
        guard let index = audioRenderers.firstIndex(where: { $0 === renderer }) else {
            return
        }
        renderer.removeObserver(self, forKeyPath: errorKeyPath)
        NotificationCenter.default.removeObserver(self, name: AVFoundationSoftLink.AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification, object: renderer)
        audioRenderers.remove(at: index)
    }

    private func isObservedVideoRenderer(_ renderer: NSObject) -> Bool {
        videoRenderers.contains { $0 === renderer }
    }

    private func isObservedAudioRenderer(_ renderer: NSObject) -> Bool {
        audioRenderers.contains { $0 === renderer }
    }

    override func observeValue(forKeyPath keyPath: Swift.String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let renderer = object as? NSObject else {
            return
        }
        let newValue = change?[.newKey]
        let box = SendableBox(renderer: renderer, value: newValue as AnyObject?)
        if keyPath == errorKeyPath {
            guard let error = newValue as? NSError else {
                return
            }
            let errorBox = SendableErrorBox(error: error)
            if isVideoRenderer(renderer) {
                onMainThread { [weak self] in
                    guard let self, self.isObservedVideoRenderer(box.renderer) else {
                        return
                    }
                    self.client?.videoRendererDidReceiveError(box.renderer, errorBox.error)
                }
                return
            }
            if isAudioRenderer(renderer) {
                onMainThread { [weak self] in
                    guard let self, self.isObservedAudioRenderer(box.renderer) else {
                        return
                    }
                    self.client?.audioRendererDidReceiveError(box.renderer, errorBox.error)
                }
            }
            return
        }
        if keyPath == outputObscuredDueToInsufficientExternalProtectionKeyPath {
            let isObscured = (box.value as? NSNumber)?.boolValue ?? false
            onMainThread { [weak self] in
                guard let self, self.isObservedVideoRenderer(box.renderer) else {
                    return
                }
                self.client?.outputObscuredDueToInsufficientExternalProtectionChanged(isObscured)
            }
        }
    }

    @objc private func layerFailedToDecode(_ notification: Notification) {
        guard let renderer = notification.object as? NSObject, isVideoRenderer(renderer) else {
            return
        }
        let error = notification.userInfo?[AVFoundationSoftLink.AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? NSError
        let box = SendableBox(renderer: renderer, value: nil)
        let errorBox = error.map { SendableErrorBox(error: $0) }
        onMainThread { [weak self] in
            guard let self, self.isObservedVideoRenderer(box.renderer) else {
                return
            }
            self.client?.videoRendererDidReceiveError(box.renderer, errorBox?.error)
        }
    }

    @objc private func layerRequiresFlushToResumeDecodingChanged(_ notification: Notification) {
        guard let renderer = notification.object as? NSObject, isVideoRenderer(renderer), let handle = queuedSampleBufferRenderer(renderer) else {
            return
        }
        let box = SendableBox(renderer: renderer, value: nil)
        onMainThread { [weak self] in
            guard let self, self.isObservedVideoRenderer(box.renderer) else {
                return
            }
            self.client?.videoRendererRequiresFlushToResumeDecodingChanged(box.renderer, handle.requiresFlushToResumeDecoding)
        }
    }

    @objc private func layerReadyForDisplayChanged(_ notification: Notification) {
        guard let layer = AVFoundationClass.cast(notification.object as AnyObject?, to: AVFoundationClass.AVSampleBufferDisplayLayer) else {
            return
        }
        let handle = DisplayLayerHandle(layer: layer)
        onMainThread { [weak self] in
            guard let self, self.isObservedVideoRenderer(handle.layer) else {
                return
            }
            self.client?.videoRendererReadyForDisplayChanged(handle.layer, MainActor.assumeIsolated { handle.layer.isReadyForDisplay })
        }
    }

    @objc private func audioRendererWasAutomaticallyFlushed(_ notification: Notification) {
        guard let renderer = notification.object as? NSObject, isAudioRenderer(renderer) else {
            return
        }
        let flushTime = (notification.userInfo?[AVFoundationSoftLink.AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue ?? CMTime(value: 0, timescale: 0, flags: [], epoch: 0)
        let box = SendableBox(renderer: renderer, value: nil)
        onMainThread { [weak self] in
            guard let self, self.isObservedAudioRenderer(box.renderer) else {
                return
            }
            self.client?.audioRendererWasAutomaticallyFlushed(box.renderer, flushTime)
        }
    }
}

private struct SendableBox: @unchecked Sendable {
    let renderer: NSObject
    let value: AnyObject?
}

private struct SendableErrorBox: @unchecked Sendable {
    let error: NSError
}
