// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
// Copyright (C) 2022-2023 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


#if ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM && HAVE_SCREEN_CAPTURE_KIT

// The getDisplayMedia prompt through ScreenCaptureKit's content sharing picker, the content filter it picks for the
// capturer, and the capturers' stream sessions, which the picker can update. ScreenCaptureKitSharingSessionManager.mm
// holds the prompt's completion handler for callers in C++.

import Dispatch
import Foundation
import ScreenCaptureKit
import WebCore_Private.Core.DisplayCaptureSourceHandle
import os

private let logger = Logger(subsystem: "com.apple.WebKit", category: "WebRTC")

private let promptWatchdogInterval: TimeInterval = 60

// A capturer's stream and content filter, which the picker can update.
@MainActor
protocol ScreenCaptureSessionSourceObserver: AnyObject {
    func sessionFilterDidChange(_: SCContentFilter)
}

@MainActor
final class ScreenCaptureSessionSource {
    let stream: SCStream
    private(set) var contentFilter: SCContentFilter
    weak var observer: (any ScreenCaptureSessionSourceObserver)?

    init(observer: any ScreenCaptureSessionSourceObserver, stream: SCStream, contentFilter: SCContentFilter) {
        self.observer = observer
        self.stream = stream
        self.contentFilter = contentFilter
    }

    func updateContentFilter(_ contentFilter: SCContentFilter) {
        assert(observer != nil)
        self.contentFilter = contentFilter
        observer?.sessionFilterDidChange(contentFilter)
    }
}

private struct WeakSessionSource {
    weak var source: ScreenCaptureSessionSource?
}

// What the picker reports, for its trip to the main thread: ScreenCaptureKit's filter and stream, which the manager
// only reads and compares there.
private struct PickerUpdate: @unchecked Sendable {
    let filter: SCContentFilter
    let stream: SCStream?
}

// The picker's observer. Every callback hops to the main thread.
private final class PickerObserver: NSObject, SCContentSharingPickerObserver, Sendable {
    @MainActor private var isObservingPicker = false

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ScreenCaptureKitSharingSessionManager.shared.cancelPicking()
            }
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ScreenCaptureKitSharingSessionManager.shared.contentSharingPickerFailed(error)
            }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let update = PickerUpdate(filter: filter, stream: stream)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ScreenCaptureKitSharingSessionManager.shared.contentSharingPickerUpdated(update.filter, for: update.stream)
            }
        }
    }

    @MainActor
    func startObserving(_ picker: SCContentSharingPicker) {
        if isObservingPicker {
            return
        }
        picker.isActive = true
        isObservingPicker = true
        picker.add(self)
    }

    @MainActor
    func stopObserving(_ picker: SCContentSharingPicker) {
        if !isObservingPicker {
            return
        }
        picker.isActive = false
        isObservingPicker = false
        picker.remove(self)
    }
}

// Not exposed: its stub in WebCoreSwift-Generated.h would redefine the C++ WebCore::ScreenCaptureKitSharingSessionManager.
@_expose(!Cxx)
@MainActor
final class ScreenCaptureKitSharingSessionManager {
    static let shared = ScreenCaptureKitSharingSessionManager()

    private var activeSources: [WeakSessionSource] = []
    private var pendingContentFilter: SCContentFilter?
    private var promptObserver: PickerObserver?
    private var isPrompting = false
    private var promptWatchdog: DispatchWorkItem?

    private var picker: SCContentSharingPicker {
        ScreenCaptureKitClass.SCContentSharingPicker.shared
    }

    // Completes the prompt with what it picked, or nothing.
    private func completePrompt(isWindow: Bool = false, deviceID: UInt32 = 0, title: Swift.String? = nil, hasDevice: Bool) {
        isPrompting = false
        WebCore.screenCaptureKitPromptDidComplete(hasDevice, isWindow, deviceID, title)
    }

    func cancelGetDisplayMediaPrompt() {
        if isPrompting {
            cancelPicking()
        }
    }

    func cancelPicking() {
        promptWatchdog?.cancel()
        promptWatchdog = nil

        if activeSources.isEmpty {
            let picker = self.picker
            promptObserver?.stopObserving(picker)
        }

        if !isPrompting {
            return
        }
        completePrompt(hasDevice: false)
    }

    private func completeDeviceSelection(_ contentFilter: SCContentFilter?) {
        promptWatchdog?.cancel()
        promptWatchdog = nil

        guard let contentFilter, isPrompting else {
            if isPrompting {
                completePrompt(hasDevice: false)
            }
            return
        }

        pendingContentFilter = contentFilter

        switch contentFilter.style {
        case .window:
            let windows = ScreenCaptureKitMember.includedWindows(of: contentFilter)?.includedWindows ?? NSArray()
            assert(windows.count == 1)
            guard windows.count > 0, let window = ScreenCaptureKitClass.cast(windows[0] as AnyObject, to: ScreenCaptureKitClass.SCWindow) else {
                return
            }
            completePrompt(isWindow: true, deviceID: window.windowID, title: window.title, hasDevice: true)
        case .display:
            let displays = ScreenCaptureKitMember.includedDisplays(of: contentFilter)?.includedDisplays ?? NSArray()
            assert(displays.count == 1)
            guard displays.count > 0, let display = ScreenCaptureKitClass.cast(displays[0] as AnyObject, to: ScreenCaptureKitClass.SCDisplay) else {
                return
            }
            completePrompt(isWindow: false, deviceID: display.displayID, hasDevice: true)
        default:
            assertionFailure()
            return
        }
    }

    func contentSharingPickerUpdated(_ contentFilter: SCContentFilter, for stream: SCStream?) {
        logger.log("ScreenCaptureKitSharingSessionManager::contentSharingPickerUpdatedFilterForStream")

        let index = activeSources.firstIndex { entry in
            guard let source = entry.source else {
                return false
            }
            return stream?.isEqual(source.stream) ?? false
        }
        guard let index else {
            if case .some = stream {
                logger.error("ScreenCaptureKitSharingSessionManager::contentFilterWasUpdated - unexpected stream!")
                return
            }
            completeDeviceSelection(contentFilter)
            return
        }

        guard let activeSource = activeSources[index].source, activeSource.observer != nil else {
            logger.error("ScreenCaptureKitSharingSessionManager::contentFilterWasUpdated - null session observer!")
            activeSources.remove(at: index)
            return
        }

        activeSource.updateContentFilter(contentFilter)
    }

    func prompt(_ promptType: WebCore.DisplayCapturePromptType) {
        assert(!isPrompting)

        logger.log("ScreenCaptureKitSharingSessionManager::promptForGetDisplayMedia - \(promptType == .Window ? "Window" : "Screen", privacy: .public)")

        if promptObserver == nil {
            promptObserver = PickerObserver()
        }

        isPrompting = true

        promptWithContentSharingPicker(promptType)

        promptWatchdog?.cancel()
        let watchdog = DispatchWorkItem {
            MainActor.assumeIsolated {
                logger.error("ScreenCaptureKitSharingSessionManager::promptForGetDisplayMedia nothing picked after \(promptWatchdogInterval) seconds, cancelling.")
                ScreenCaptureKitSharingSessionManager.shared.cancelPicking()
            }
        }
        promptWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + promptWatchdogInterval, execute: watchdog)
    }

    private func promptWithContentSharingPicker(_ promptType: WebCore.DisplayCapturePromptType) {
        let configuration = ScreenCaptureKitClass.SCContentSharingPickerConfiguration.init()

        let contentStyle: SCShareableContentStyle
        switch promptType {
        case .Window:
            configuration.allowedPickerModes = .singleWindow
            contentStyle = .window
        case .Screen:
            configuration.allowedPickerModes = .singleDisplay
            contentStyle = .display
        case .UserChoose:
            configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
            contentStyle = .none
        @unknown default:
            contentStyle = .none
        }

        let picker = self.picker
        promptObserver?.startObserving(picker)

        // ScreenCaptureKit declares showsMicrophoneControl only where it has it.
        if configuration.responds(to: NSSelectorFromString("setShowsMicrophoneControl:")) {
            configuration.setValue(false, forKey: "showsMicrophoneControl")
        }

        picker.__defaultConfiguration = configuration

        picker.__maximumStreamCount = NSNumber(value: UInt32.max)
        if contentStyle != .none {
            picker.present(using: contentStyle)
        } else {
            picker.present()
        }
    }

    func contentSharingPickerFailed(_ error: any Error) {
        logger.error("ScreenCaptureKitSharingSessionManager::contentSharingPickerFailedWithError content sharing picker failed with error '\((error as NSError).localizedDescription, privacy: .public)'")

        cancelPicking()
    }

    // Whether the filter captures the display, or the window if isWindow, with this ID.
    private func filter(_ filter: SCContentFilter, matchesWindow isWindow: Bool, deviceID: UInt32) -> Bool {
        if !isWindow {
            if filter.style != .display {
                return false
            }
            let displays = ScreenCaptureKitMember.includedDisplays(of: filter)?.includedDisplays ?? NSArray()
            guard displays.count > 0, let display = ScreenCaptureKitClass.cast(displays[0] as AnyObject, to: ScreenCaptureKitClass.SCDisplay) else {
                return false
            }
            return display.displayID == deviceID
        }

        if filter.style != .window {
            return false
        }
        let windows = ScreenCaptureKitMember.includedWindows(of: filter)?.includedWindows ?? NSArray()
        assert(windows.count == 1)
        guard windows.count > 0, let window = ScreenCaptureKitClass.cast(windows[0] as AnyObject, to: ScreenCaptureKitClass.SCWindow) else {
            return false
        }
        return window.windowID == deviceID
    }

    func cancelPendingSession(isWindow: Bool, deviceID: UInt32) {
        guard let pendingContentFilter, filter(pendingContentFilter, matchesWindow: isWindow, deviceID: deviceID) else {
            logger.error("ScreenCaptureKitSharingSessionManager::cancelPendingSessionForDevice - unknown capture device.")
            return
        }

        self.pendingContentFilter = nil
        cancelPicking()
    }

    // The content filter that the prompt picked for this display or window, which only one capturer takes.
    func takeContentFilter(isWindow: Bool, deviceID: UInt32) -> SCContentFilter? {
        guard let pendingContentFilter, filter(pendingContentFilter, matchesWindow: isWindow, deviceID: deviceID) else {
            logger.error("ScreenCaptureKitSharingSessionManager::contentFilterFromCaptureDevice - unknown capture device.")
            return nil
        }

        self.pendingContentFilter = nil
        return pendingContentFilter
    }

    func createSessionSource(observer: any ScreenCaptureSessionSourceObserver, contentFilter: SCContentFilter, configuration: SCStreamConfiguration, delegate: any SCStreamDelegate) -> ScreenCaptureSessionSource? {
        let stream = ScreenCaptureKitClass.SCStream.init(filter: contentFilter, configuration: configuration, delegate: delegate)
        let source = ScreenCaptureSessionSource(observer: observer, stream: stream, contentFilter: contentFilter)
        activeSources.append(WeakSessionSource(source: source))
        return source
    }

    // The capturer released the session source, which held its stream.
    func sessionSourceDidEnd(_ source: ScreenCaptureSessionSource) {
        guard let index = activeSources.firstIndex(where: { $0.source === source }) else {
            logger.error("ScreenCaptureKitSharingSessionManager::cleanupSessionSource - unknown source.")
            return
        }

        activeSources.remove(at: index)

        if !isPrompting {
            cancelPicking()
        }
    }
}

// MARK: Entry points

extension WebCore.ScreenCaptureKitSharingSession {
    @cxx
    @implementation
    static func isFrameworkAvailable() -> Bool {
        ScreenCaptureKitFrameworkIsAvailable
    }

    @cxx
    @implementation
    static func isPickerAvailable() -> Bool {
        _ = ScreenCaptureKitClass.SCContentSharingPicker
        return true
    }

    @cxx
    @implementation
    static func prompt(_ promptType: WebCore.DisplayCapturePromptType) {
        MainActor.assumeIsolated {
            ScreenCaptureKitSharingSessionManager.shared.prompt(promptType)
        }
    }

    @cxx
    @implementation
    static func cancelPrompt() {
        MainActor.assumeIsolated {
            ScreenCaptureKitSharingSessionManager.shared.cancelGetDisplayMediaPrompt()
        }
    }
}

#endif
