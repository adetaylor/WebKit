// Copyright (C) 2026 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA

import Dispatch
import Foundation
import Synchronization
import WebKit_Internal
import os
@_spi(WebKitGPU) internal import WebCore

private let audioLevelFloorInDBFS: Float = -60
private let audioLevelInterval = 1.0 / 15

private func normalizedLevelFromPeak(_ peak: Float) -> Float {
    if peak <= 0 {
        return 0
    }
    let dbfs = 20 * log10(peak)
    if dbfs <= audioLevelFloorInDBFS {
        return 0
    }
    return min(max((dbfs - audioLevelFloorInDBFS) / -audioLevelFloorInDBFS, 0), 1)
}

// What GPUProcess::startCapturePreview() gets from the preview.
enum CapturePreviewStart: UInt8 {
    // No camera: no layer to host.
    case noVideo = 0
    // The layer it was given shows the camera.
    case started = 1
    // The camera and size are unchanged: the layer it gave last time still shows the camera.
    case unchanged = 2
}

// The camera frames of a capture preview, on the thread the camera produces them on, for the layer they are shown in.
private final class CapturePreviewFrameTarget: CaptureVideoFrameObserver {
    private let layer = Mutex<WebKit.CapturePreviewLayer?>(nil)

    func setLayer(_ newLayer: WebKit.CapturePreviewLayer?) {
        layer.withLock { current in
            current = newLayer
        }
    }

    func captureVideoFrameAvailable(_ frame: CaptureFrame, captureTime: Double) {
        // The layer is held while the frame is enqueued; it is only swapped on the main thread, after the frame observer
        // is removed, so there is no lock order to invert.
        layer.withLock { current in
            current?.enqueue(frame.frame)
        }
    }
}

// The capture preview of a getUserMedia prompt (CapturePreviewManager.mm): the camera's frames in a layer the UI process
// hosts, and the microphone's level, until the prompt goes. GPUProcess sets up the capture environment first, makes the
// layer, and has the UI process monitor the camera's rotation.
@MainActor
final class CapturePreviewManager {
    private let pageIdentifier: UInt64
    private var videoSource: CaptureSource?
    private var audioSource: CaptureSource?
    private var audioPeakSink: MicrophoneSink?
    private let frameTarget = CapturePreviewFrameTarget()
    private var videoDeviceID = ""
    private var audioDeviceID = ""
    private var previewWidth: Int32 = 0
    private var previewHeight: Int32 = 0
    private var orientation: Int32 = 0
    private var audioLevelTimer: (any DispatchSourceTimer)?
    private var audioSessionGeneration: UInt64 = 0
    private var pendingAudioDevice: CaptureDeviceDescription?
    init(pageIdentifier: UInt64) {
        self.pageIdentifier = pageIdentifier
    }


    isolated deinit {
        stop()
    }

    var isRunning: Bool {
        !videoDeviceID.isEmpty || !audioDeviceID.isEmpty
    }

    static func device(_ persistentID: String, _ label: String, _ isDefault: Bool, _ kind: CaptureDeviceKind) -> CaptureDeviceDescription? {
        guard !persistentID.isEmpty else {
            return nil
        }
        return CaptureDeviceDescription(persistentID: persistentID, label: label, groupID: "", kind: kind, isDefault: isDefault, isEphemeral: false, persistentDeviceSalt: "", ephemeralDeviceSalt: "")
    }

    private func createSource(_ device: CaptureDeviceDescription) -> CaptureSource? {
        switch CaptureSourceFactory.create(device: device, pageIdentifier: pageIdentifier) {
        case .success(let source):
            return source
        case .failure(let failure):
            previewLog.error(
                "CapturePreviewManager unable to create \(device.kind == .microphone ? "microphone" : "camera", privacy: .public) preview source, denialReason=\(failure.denialReason), \(failure.message, privacy: .public)"
            )
            return nil
        }
    }

    // CapturePreviewManager::start(): the layer is the one GPUProcess made for the camera, if there is one.
    func start(video: CaptureDeviceDescription?, audio: CaptureDeviceDescription?, width: Int32, height: Int32, layer: WebKit.CapturePreviewLayer?) -> CapturePreviewStart {
        let newVideoDeviceID = video?.persistentID ?? ""
        let newAudioDeviceID = audio?.persistentID ?? ""

        if newAudioDeviceID != audioDeviceID {
            stopAudio()
            if let audio {
                startAudio(audio)
            } else {
                restoreAudioSession()
            }
        }

        if newVideoDeviceID == videoDeviceID && width == previewWidth && height == previewHeight {
            return videoDeviceID.isEmpty ? .noVideo : .unchanged
        }

        stopVideo()

        guard let video, let layer else {
            return .noVideo
        }
        return startVideo(video, width: width, height: height, layer: layer) ? .started : .noVideo
    }

    private func startAudio(_ device: CaptureDeviceDescription) {
        audioDeviceID = device.persistentID
        if !WebKit.GPUProcess.capturePreviewNeedsAudioSession() {
            startAudioSource(device)
            return
        }
        pendingAudioDevice = device
        audioSessionGeneration &+= 1
        WebKit.GPUProcess.beginCapturePreviewAudioSession(audioSessionGeneration)
    }

    // The audio session is ready for the preview (RemoteAudioSessionProxyManager::beginCapturePreview()).
    func audioSessionIsReady(_ generation: UInt64) {
        guard generation == audioSessionGeneration, let device = pendingAudioDevice.take(), device.persistentID == audioDeviceID else {
            return
        }
        startAudioSource(device)
    }

    private func startAudioSource(_ device: CaptureDeviceDescription) {
        detachAudioSource()

        guard let source = createSource(device) else {
            previewLog.error("CapturePreviewManager no audio source")
            return
        }
        audioSource = source
        // The microphone's capture unit keeps the peak on its IO thread.
        let sink = MicrophoneSink.peak()
        audioPeakSink = sink
        source.addMicrophoneSink(sink)
        source.start()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + audioLevelInterval, repeating: audioLevelInterval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.sendAudioLevel()
            }
        }
        timer.resume()
        audioLevelTimer = timer
    }

    private func restoreAudioSession() {
        pendingAudioDevice = nil
        WebKit.GPUProcess.endCapturePreviewAudioSession()
    }

    private func startVideo(_ device: CaptureDeviceDescription, width: Int32, height: Int32, layer: WebKit.CapturePreviewLayer) -> Bool {
        guard let source = createSource(device) else {
            return false
        }
        videoSource = source
        source.monitorOrientation(orientation)

        videoDeviceID = device.persistentID
        previewWidth = width
        previewHeight = height

        // The layer is set before the frame observer is added, so no frame arrives before it can be drawn.
        frameTarget.setLayer(layer)
        source.addVideoFrameObserver(frameTarget)
        source.start()
        return true
    }

    func setOrientation(_ orientation: Int32) {
        self.orientation = orientation
        videoSource?.orientationChanged(orientation)
    }

    func rotationAngleForCaptureDeviceChanged(_ persistentID: String, _ rotation: UInt16) {
        videoSource?.rotationAngleForHorizonLevelDisplayChanged(persistentID, rotation)
    }

    private func stopVideo() {
        if let source = videoSource.take() {
            source.removeVideoFrameObserver(frameTarget)
            source.endImmediately()
        }
        videoDeviceID = ""
        previewWidth = 0
        previewHeight = 0
        frameTarget.setLayer(nil)
    }

    private func detachAudioSource() {
        audioLevelTimer?.cancel()
        audioLevelTimer = nil
        if let source = audioSource.take() {
            if let sink = audioPeakSink.take() {
                source.removeMicrophoneSink(sink)
                sink.invalidate()
            }
            source.endImmediately()
        }
    }

    private func stopAudio() {
        detachAudioSource()
        audioDeviceID = ""
        pendingAudioDevice = nil
    }

    func stop() {
        stopVideo()
        stopAudio()
        restoreAudioSession()
    }

    private func sendAudioLevel() {
        let peak = audioPeakSink?.takePeak() ?? 0
        WebKit.GPUProcess.capturePreviewAudioLevelChanged(pageIdentifier, normalizedLevelFromPeak(peak))
    }
}

private let previewLog = Logger(subsystem: "com.apple.WebKit", category: "WebRTC")

// MARK: GPUProcess

extension WebKit.GPUProcess {
    @cxx
    @implementation
    @MainActor
    func swiftStartCapturePreview(
        _ pageIdentifier: UInt64,
        _ videoDeviceID: WTF.String,
        _ videoDeviceLabel: WTF.String,
        _ videoDeviceIsDefault: Bool,
        _ audioDeviceID: WTF.String,
        _ audioDeviceLabel: WTF.String,
        _ audioDeviceIsDefault: Bool,
        _ previewWidth: Int32,
        _ previewHeight: Int32,
        _ orientation: Int32,
        _ layer: WebKit.CapturePreviewLayer?
    ) -> UInt8 {
        let state = state
        let manager = state.capturePreview ?? CapturePreviewManager(pageIdentifier: pageIdentifier)
        state.capturePreview = manager
        manager.setOrientation(orientation)
        let video = CapturePreviewManager.device(IPCCoding.WTFString.swiftString(videoDeviceID) ?? "", IPCCoding.WTFString.swiftString(videoDeviceLabel) ?? "", videoDeviceIsDefault, .camera)
        let audio = CapturePreviewManager.device(IPCCoding.WTFString.swiftString(audioDeviceID) ?? "", IPCCoding.WTFString.swiftString(audioDeviceLabel) ?? "", audioDeviceIsDefault, .microphone)
        let result = manager.start(video: video, audio: audio, width: previewWidth, height: previewHeight, layer: layer)
        // Nothing could be started, so don't keep the preview, and the process, around for it.
        if !manager.isRunning {
            state.capturePreview = nil
            manager.stop()
        }
        return result.rawValue
    }

    @cxx
    @implementation
    @MainActor
    func swiftStopCapturePreview() {
        state.capturePreview.take()?.stop()
    }

    @cxx
    @implementation
    @MainActor
    func swiftHasCapturePreview() -> Bool {
        state.capturePreview != nil
    }

    @cxx
    @implementation
    @MainActor
    func swiftSetCapturePreviewOrientation(_ orientation: Int32) {
        state.capturePreview?.setOrientation(orientation)
    }

    @cxx
    @implementation
    @MainActor
    func swiftCapturePreviewRotationChanged(_ persistentID: WTF.String, _ rotation: UInt16) {
        state.capturePreview?.rotationAngleForCaptureDeviceChanged(IPCCoding.WTFString.swiftString(persistentID) ?? "", rotation)
    }

    @cxx
    @implementation
    @MainActor
    func capturePreviewAudioSessionIsReady(_ generation: UInt64) {
        state.capturePreview?.audioSessionIsReady(generation)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
