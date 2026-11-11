// Copyright (C) 2015-2022 Apple Inc. All rights reserved.
// Copyright (C) 2015-2023 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer
//    in the documentation and/or other materials provided with the
//    distribution.
// 3. Neither the name of Google Inc. nor the names of its contributors
//    may be used to endorse or promote products derived from this
//    software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM

// The mock camera's and the mock display's video: the frames MockRealtimeVideoSource drew with GraphicsContext, drawn
// with CoreGraphics and CoreText, on a serial queue at the source's frame rate. MockRealtimeVideoSourceMac, the mock
// camera's RealtimeMediaSource, holds a generator by identifier through MockVideoSourceHandle and gets its frames and
// photos through MockVideoSourceHandle.h's functions; DisplayCaptureSource.swift's mock capturer holds one directly.

import CoreGraphics
import CoreText
import Dispatch
import Foundation
import ImageIO
import Synchronization
import WebCore_Private.Core.MockVideoSourceHandle

// MARK: Drawing

private let whiteColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
private let grayColor = mockVideoColor(red: 160, green: 160, blue: 160)
private let cyanColor = mockVideoColor(red: 0, green: 255, blue: 255)
private let yellowColor = mockVideoColor(red: 255, green: 255, blue: 0)
private let redColor = mockVideoColor(red: 255, green: 0, blue: 0)
private let boxColors = [
    whiteColor,
    yellowColor,
    cyanColor,
    mockVideoColor(red: 0, green: 128, blue: 0),
    mockVideoColor(red: 255, green: 0, blue: 255),
    redColor,
    mockVideoColor(red: 0, green: 0, blue: 255),
]

// std::numbers::pi_v<float>, rounded to nearest; Float.pi is rounded toward zero, which makes a whole circle empty.
private let floatPi = Float(Double.pi)

private func mockVideoColor(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) -> CGColor {
    CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
}

// What a frame shows, besides the clock and the frame number.
struct MockVideoFrameState: Sendable {
    var kind = WebCore.MockVideoSourceKind.Camera
    // A VideoFacingMode.
    var facingMode: UInt8 = 1
    var fillColor = mockVideoColor(red: 0, green: 0, blue: 0)
    // The size frames are drawn at: the preset's, or the source's.
    var captureWidth: Int = 0
    var captureHeight: Int = 0
    // The source's size and requested frame rate, and the frame rate its observers see.
    var width: Int32 = 0
    var height: Int32 = 0
    var frameRate: Double = 30
    var observedFrameRate: Double = 0
    var zoom: Double = 1
    // Whether to draw more than the background: the source isn't muted, or is muted for a photo.
    var drawsContent = true
}

// FormattedNumber::fixedWidth(value, 1).
private func fixedWidth(_ value: Double) -> Swift.String {
    let tenths = Int((abs(value) * 10).rounded())
    return "\(value < 0 && tenths > 0 ? "-" : "")\(tenths / 10).\(tenths % 10)"
}

// makeString(pad('0', width, value)).
private func padded(_ value: some BinaryInteger, _ width: Int) -> Swift.String {
    let digits = Swift.String(value)
    return Swift.String(repeating: "0", count: max(0, width - digits.count)) + digits
}

// The drawing of the frames, at one size: its bitmap context and its fonts, which MockRealtimeVideoSource kept as its
// image buffer and drawing state.
private final class MockVideoDrawing {
    let width: Int
    let height: Int
    private let context: CGContext
    private let baseFontSize: CGFloat
    private let timeFont: CTFont
    private let bipBopFont: CTFont
    private let statsFont: CTFont

    init?(width: Int, height: Int) {
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        // An unaccelerated BGRA8 ImageBuffer: premultiplied alpha first, in host byte order, with GraphicsContext's
        // top-left origin.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        // With no data, the context allocates and owns its bitmap; nothing else holds a pointer into it.
        guard let context = unsafe CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setLineWidth(1)
        self.width = width
        self.height = height
        self.context = context
        baseFontSize = CGFloat(Float(height) * 0.08)
        timeFont = CTFontCreateWithName("Courier" as CFString, baseFontSize, nil)
        bipBopFont = CTFontCreateWithName("Courier" as CFString, CGFloat(Float(baseFontSize) * 2.5), nil)
        statsFont = CTFontCreateWithName("Courier" as CFString, CGFloat(Float(baseFontSize) * 0.5), nil)
    }

    // Draws frame frameNumber, which shows the clock at elapsed seconds, and returns its image.
    func draw(_ state: MockVideoFrameState, frameNumber: UInt32, elapsed: Double) -> CGImage? {
        context.saveGState()
        defer {
            context.restoreGState()
        }

        context.setFillColor(state.zoom >= 2 ? redColor : state.fillColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        if state.drawsContent {
            drawText(state, frameNumber: frameNumber, elapsed: elapsed)
            drawAnimation(state, frameNumber: frameNumber &+ 1)
            drawBoxes()
        }

        return context.makeImage()
    }

    private func drawString(_ string: Swift.String, font: CTFont, color: CGColor, at point: CGPoint) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        guard let attributedString = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attributedString)
        // Glyphs are upright in the flipped context.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private func drawText(_ state: MockVideoFrameState, frameNumber: UInt32, elapsed: Double) {
        let milliseconds = Int(lround(elapsed * 1000))
        let seconds = milliseconds / 1000 % 60
        let minutes = (milliseconds / (1000 * 60)) % 60
        // There is no field for days, so pad the hours on 2 digits and let it wrap around at the 100th hour.
        let hours = (milliseconds / (1000 * 60 * 60)) % 100

        var timeLocation = CGPoint(x: CGFloat(Float(width) * 0.05), y: CGFloat(Float(height) * 0.15))
        drawString("\(padded(hours, 2)):\(padded(minutes, 2)):\(padded(seconds, 2)).\(padded(milliseconds % 1000, 3))", font: timeFont, color: whiteColor, at: timeLocation)

        timeLocation.y += baseFontSize
        drawString(padded(frameNumber, 6), font: timeFont, color: whiteColor, at: timeLocation)

        let statsFontSize = CGFloat(Float(baseFontSize) * 0.5)
        var statsLocation = CGPoint(x: CGFloat(Float(width) * 0.45), y: CGFloat(Float(height) * 0.75))
        drawString("Requested frame rate: \(fixedWidth(state.frameRate)) fps", font: statsFont, color: whiteColor, at: statsLocation)

        statsLocation.y += statsFontSize
        drawString("Observed frame rate: \(fixedWidth(state.observedFrameRate)) fps", font: statsFont, color: whiteColor, at: statsLocation)

        statsLocation.y += statsFontSize
        drawString("Size: \(state.width) x \(state.height)", font: statsFont, color: whiteColor, at: statsLocation)

        let deviceString: Swift.String
        switch state.kind {
        case .Camera:
            statsLocation.y += statsFontSize
            drawString("Preset size: \(width) x \(height)", font: statsFont, color: whiteColor, at: statsLocation)
            switch state.facingMode {
            case 1:
                deviceString = "Camera: User facing"
            case 2:
                deviceString = "Camera: Environment facing"
            case 3:
                deviceString = "Camera: Left facing"
            case 4:
                deviceString = "Camera: Right facing"
            default:
                deviceString = "Camera: Unknown"
            }
        case .Screen, .Window:
            deviceString = "Display capture"
        @unknown default:
            deviceString = "Unknown capture"
        }
        statsLocation.y += statsFontSize
        drawString(deviceString, font: statsFont, color: whiteColor, at: statsLocation)

        let bipBopLocation = CGPoint(x: CGFloat(Float(width) * 0.6), y: CGFloat(Float(height) * 0.6))
        let frameMod = (frameNumber &+ 1) % 60
        if frameMod <= 15 {
            drawString("Bip", font: bipBopFont, color: cyanColor, at: bipBopLocation)
        } else if frameMod > 30 && frameMod <= 45 {
            drawString("Bop", font: bipBopFont, color: yellowColor, at: bipBopLocation)
        }
    }

    private func drawAnimation(_ state: MockVideoFrameState, frameNumber: UInt32) {
        let radius = CGFloat(Float(width) * 0.09)
        let location = CGPoint(x: CGFloat(Float(width) * 0.8), y: CGFloat(Float(height) * 0.3))

        // Path::addArc() with RotationDirection::Counterclockwise in GraphicsContext's flipped space.
        let circle = CGMutablePath()
        circle.move(to: location)
        circle.addArc(center: location, radius: radius, startAngle: 0, endAngle: CGFloat(2 * floatPi), clockwise: true)
        circle.closeSubpath()
        context.setFillColor(whiteColor)
        context.addPath(circle)
        context.fillPath(using: .winding)

        let frameRate = state.frameRate
        let endAngle = floatPi * Float(((fmod(Double(frameNumber), frameRate) + 0.5) * (2.0 / frameRate)) + 1)
        let wedge = CGMutablePath()
        wedge.move(to: location)
        wedge.addArc(center: location, radius: radius, startAngle: CGFloat(1.5 * floatPi), endAngle: CGFloat(endAngle), clockwise: true)
        wedge.closeSubpath()
        context.setFillColor(grayColor)
        context.addPath(wedge)
        context.fillPath(using: .winding)
    }

    private func drawBoxes() {
        let boxSize = Float(width) * 0.035
        var boxTop = Float(height) * 0.6

        context.setStrokeColor(whiteColor)
        context.setLineWidth(3)
        context.setLineDash(phase: 0, lengths: [6, 6])
        let frame = CGMutablePath()
        frame.addRect(CGRect(x: 2, y: 2, width: width - 3, height: height - 3))
        frame.closeSubpath()
        context.addPath(frame)
        context.strokePath()

        context.setLineDash(phase: 0, lengths: [])
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 0, y: CGFloat(boxTop + boxSize)))
        line.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(boxTop + boxSize)))
        line.closeSubpath()
        context.setLineWidth(2)
        context.addPath(line)
        context.strokePath()

        // GraphicsContext stroked the four hatchings once, after the boxes, at the last thickness it was given.
        let hatching = CGMutablePath()
        var boxLeft = boxSize
        var index: Float = 0
        while index < boxSize / 4 {
            hatching.move(to: CGPoint(x: CGFloat(boxLeft + 4 * index), y: CGFloat(boxTop)))
            hatching.addLine(to: CGPoint(x: CGFloat(boxLeft + 4 * index), y: CGFloat(boxTop + boxSize)))
            index += 1
        }
        boxLeft += boxSize + 2
        index = 0
        while index < boxSize / 4 {
            hatching.move(to: CGPoint(x: CGFloat(boxLeft), y: CGFloat(boxTop + 4 * index)))
            hatching.addLine(to: CGPoint(x: CGFloat(boxLeft + boxSize - 1), y: CGFloat(boxTop + 4 * index)))
            index += 1
        }
        boxLeft += boxSize + 2
        index = 0
        while index < boxSize / 8 {
            hatching.move(to: CGPoint(x: CGFloat(boxLeft + 8 * index), y: CGFloat(boxTop)))
            hatching.addLine(to: CGPoint(x: CGFloat(boxLeft + 8 * index), y: CGFloat(boxTop + boxSize - 1)))
            index += 1
        }
        boxLeft += boxSize + 2
        index = 0
        while index < boxSize / 8 {
            hatching.move(to: CGPoint(x: CGFloat(boxLeft), y: CGFloat(boxTop + 8 * index)))
            hatching.addLine(to: CGPoint(x: CGFloat(boxLeft + boxSize - 1), y: CGFloat(boxTop + 8 * index)))
            index += 1
        }

        boxTop += boxSize + 2
        boxLeft = boxSize
        for color in boxColors {
            context.setFillColor(color)
            context.fill(CGRect(x: CGFloat(boxLeft), y: CGFloat(boxTop), width: CGFloat(boxSize + 1), height: CGFloat(boxSize + 1)))
            boxLeft += boxSize + 1
        }

        context.setLineWidth(3)
        context.addPath(hatching)
        context.strokePath()
    }
}

// MARK: Generator

// The seconds of MonotonicTime.
private func mockVideoNow() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

enum MockVideoPhotoResult: Sendable {
    case png(Data)
    case alreadyTakingPhoto
    case interrupted
    case failed

    // MockRealtimeVideoSource's messages.
    var errorMessage: Swift.String? {
        switch self {
        case .png:
            return nil
        case .alreadyTakingPhoto:
            return "Already taking photo"
        case .interrupted:
            return "Capture interrupted by session reconfiguration"
        case .failed:
            return "Failed to capture photo"
        }
    }
}

// The frames of a mock source: drawn on the generator's queue at the frame rate while its timer runs, from the frame
// state its owner sets on any thread.
final class MockVideoGenerator: Sendable {
    // What the queue's work uses: the drawing, the frame number and when the frames resume after delaySamples().
    private struct QueueState: ~Copyable {
        var drawing: MockVideoDrawing?
        var frameNumber: UInt32 = 0
        var delayUntil: Double = 0
        var timer: (any DispatchSourceTimer)?
    }

    // What the owner sets: the frame state, and the capture clock (when the current run started, NaN if none, and how
    // long the earlier runs took).
    private struct OwnerState {
        var frame = MockVideoFrameState()
        var startTime = Double.nan
        var elapsedTime: Double = 0

        var elapsed: Double {
            startTime.isNaN ? elapsedTime : elapsedTime + (mockVideoNow() - startTime)
        }
    }

    // Called on the queue with each frame and its presentation time; returns the frame rate the observers see.
    typealias FrameHandler = @Sendable (CGImage, Double) -> Double

    private let queue = DispatchQueue(label: "WebKit::MockRealtimeVideoSource generateFrame queue")
    private let queueState = Mutex(QueueState())
    private let ownerState: Mutex<OwnerState>
    private let frameHandler: FrameHandler
    private let latestFrame = Mutex<CGImage?>(nil)
    private let isTakingPhoto = Atomic<Bool>(false)
    private let captureWasInterrupted = Atomic<Bool>(false)

    init(state: MockVideoFrameState, frameHandler: @escaping FrameHandler) {
        ownerState = Mutex(OwnerState(frame: state))
        self.frameHandler = frameHandler
    }

    func updateFrameState(_ update: (inout MockVideoFrameState) -> Void) {
        ownerState.withLock {
            update(&$0.frame)
        }
    }

    var latestImage: CGImage? {
        latestFrame.withLock { $0 }
    }

    func startProducingData(frameRate: Double) {
        startTimer(frameRate: frameRate)
        ownerState.withLock {
            $0.startTime = mockVideoNow()
        }
    }

    func stopProducingData() {
        stopTimer()
        ownerState.withLock {
            $0.elapsedTime += mockVideoNow() - $0.startTime
            $0.startTime = .nan
        }
    }

    // The timer fires on the queue, so it starts and stops there, in order.
    func startTimer(frameRate: Double) {
        queue.async { [weak self] in
            self?.startTimerOnQueue(frameRate: frameRate)
        }
    }

    func stopTimer() {
        queue.async { [weak self] in
            self?.queueState.withLock {
                $0.timer?.cancel()
                $0.timer = nil
            }
        }
    }

    private func startTimerOnQueue(frameRate: Double) {
        dispatchPrecondition(condition: .onQueue(queue))
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000 / frameRate))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            self?.timerFired()
        }
        queueState.withLock {
            $0.timer?.cancel()
            $0.timer = timer
        }
        timer.resume()
    }

    func delaySamples(_ seconds: Double) {
        let delayUntil = mockVideoNow() + seconds
        queue.async { [weak self] in
            self?.queueState.withLock {
                $0.delayUntil = delayUntil
            }
        }
    }

    func invalidate() {
        stopTimer()
    }

    private func timerFired() {
        dispatchPrecondition(condition: .onQueue(queue))
        // As MockRealtimeVideoSource::generateFrame() has it: a delay set by delaySamples() drops the frames once it is
        // past, and is cleared by a frame before it.
        let skip = queueState.withLock {
            if $0.delayUntil == 0 {
                return false
            }
            if $0.delayUntil < mockVideoNow() {
                return true
            }
            $0.delayUntil = 0
            return false
        }
        if skip {
            return
        }
        _ = generateFrame(drawsContentOverride: nil)
    }

    // Draws the next frame, hands it to the frame handler and returns it.
    private func generateFrame(drawsContentOverride: Bool?) -> CGImage? {
        dispatchPrecondition(condition: .onQueue(queue))
        let (frame, elapsed) = ownerState.withLock { ($0.frame, $0.elapsed) }
        var state = frame
        if let drawsContentOverride {
            state.drawsContent = drawsContentOverride
        }

        let image: CGImage? = queueState.withLock { queueState in
            if queueState.drawing?.width != state.captureWidth || queueState.drawing?.height != state.captureHeight {
                queueState.drawing = MockVideoDrawing(width: state.captureWidth, height: state.captureHeight)
            }
            guard let drawing = queueState.drawing else {
                return nil
            }
            let frameNumber = queueState.frameNumber
            queueState.frameNumber &+= 1
            return drawing.draw(state, frameNumber: frameNumber, elapsed: elapsed)
        }
        guard let image else {
            return nil
        }

        latestFrame.withLock {
            $0 = image
        }
        let observedFrameRate = frameHandler(image, elapsed + 0.1)
        ownerState.withLock {
            $0.frame.observedFrameRate = observedFrameRate
        }
        return image
    }

    // Takes a photo, the next frame as a PNG, unless one is being taken; the result comes to the handler, on the queue,
    // or now if a photo is being taken.
    func takePhoto(drawsContent: Bool, completion: @escaping @Sendable (MockVideoPhotoResult) -> Void) {
        if isTakingPhoto.exchange(true, ordering: .sequentiallyConsistent) {
            completion(.alreadyTakingPhoto)
            return
        }
        queue.async { [weak self] in
            guard let self else {
                return
            }
            // A photo is drawn at its own size, so the frames after it start over with a fresh drawing.
            queueState.withLock {
                $0.drawing = nil
            }
            let image = generateFrame(drawsContentOverride: drawsContent)
            queueState.withLock {
                $0.drawing = nil
            }
            isTakingPhoto.store(false, ordering: .sequentiallyConsistent)

            if captureWasInterrupted.exchange(false, ordering: .sequentiallyConsistent) {
                completion(.interrupted)
                return
            }
            guard let image, let data = pngData(image) else {
                completion(.failed)
                return
            }
            completion(.png(data))
        }
    }

    // The source's configuration is changing: a photo being taken fails.
    func configurationWillChange() {
        if isTakingPhoto.load(ordering: .sequentiallyConsistent) {
            captureWasInterrupted.store(true, ordering: .sequentiallyConsistent)
        }
    }
}

private func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        return nil
    }
    return data as Data
}

// MARK: Handle

private let mockVideoSources = Mutex<[UInt64: MockVideoGenerator]>([:])
private let lastMockVideoSourceIdentifier = Atomic<UInt64>(0)

extension MockVideoFrameState {
    init(_ description: WebCore.MockVideoSourceDescription, _ state: WebCore.MockVideoSourceState) {
        self.init()
        kind = description.kind
        fillColor = mockVideoColor(red: description.fillRed, green: description.fillGreen, blue: description.fillBlue, alpha: description.fillAlpha)
        apply(state)
    }

    mutating func apply(_ state: WebCore.MockVideoSourceState) {
        facingMode = state.facingMode
        captureWidth = Int(state.captureWidth)
        captureHeight = Int(state.captureHeight)
        width = state.width
        height = state.height
        frameRate = state.frameRate
        zoom = state.zoom
        drawsContent = state.drawsContent
    }
}

extension WebCore.MockVideoSourceHandle {
    private var generator: MockVideoGenerator? {
        mockVideoSources.withLock { $0[m_identifier] }
    }

    @cxx
    @implementation
    static func create(_ description: WebCore.MockVideoSourceDescription, _ state: WebCore.MockVideoSourceState) -> WebCore.MockVideoSourceHandle {
        let identifier = lastMockVideoSourceIdentifier.add(1, ordering: .relaxed).newValue
        let generator = MockVideoGenerator(state: MockVideoFrameState(description, state)) { image, presentationTime in
            WebCore.mockVideoSourceDidGenerateFrame(identifier, image, presentationTime)
        }
        mockVideoSources.withLock {
            $0[identifier] = generator
        }
        var handle = WebCore.MockVideoSourceHandle()
        handle.m_identifier = identifier
        return handle
    }

    @cxx
    @implementation
    mutating func destroy() {
        let identifier = m_identifier
        m_identifier = 0
        mockVideoSources.withLock { $0.removeValue(forKey: identifier) }?.invalidate()
    }

    @cxx
    @implementation
    func setState(_ state: WebCore.MockVideoSourceState) {
        generator?.updateFrameState {
            $0.apply(state)
        }
    }

    @cxx
    @implementation
    func startProducingData(_ frameRate: Double) {
        generator?.startProducingData(frameRate: frameRate)
    }

    @cxx
    @implementation
    func stopProducingData() {
        generator?.stopProducingData()
    }

    @cxx
    @implementation
    func startTimer(_ frameRate: Double) {
        generator?.startTimer(frameRate: frameRate)
    }

    @cxx
    @implementation
    func stopTimer() {
        generator?.stopTimer()
    }

    @cxx
    @implementation
    func delaySamples(_ seconds: Double) {
        generator?.delaySamples(seconds)
    }

    @cxx
    @implementation
    func takePhoto(_ drawsContent: Bool, _ requestIdentifier: UInt64) {
        let identifier = m_identifier
        guard let generator else {
            WebCore.mockVideoSourceDidTakePhoto(identifier, requestIdentifier, nil, MockVideoPhotoResult.failed.errorMessage)
            return
        }
        generator.takePhoto(drawsContent: drawsContent) { result in
            if case .png(let data) = result {
                WebCore.mockVideoSourceDidTakePhoto(identifier, requestIdentifier, data, nil)
                return
            }
            WebCore.mockVideoSourceDidTakePhoto(identifier, requestIdentifier, nil, result.errorMessage)
        }
    }

    @cxx
    @implementation
    func configurationWillChange() {
        generator?.configurationWillChange()
    }
}


#endif
