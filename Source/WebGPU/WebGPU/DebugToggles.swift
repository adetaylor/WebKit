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

import Foundation
import Metal
import Synchronization
import WebGPU_Internal.Device

// The process-wide developer toggles, flipped by `notifyutil -p <name>` on the main queue and read on every Instance's
// API thread. Each notification handler is registered by the first reader.

// MARK: GPU frame capture

// Allow GPU frame capture "notifyutil -p com.apple.WebKit.WebGPU.CaptureFrame" when process is
// run with __XPC_METAL_CAPTURE_ENABLED=1
// notifyutil -s com.apple.WebKit.WebGPU.CaptureFrame 10 --> captures 10 GPUQueue.submit calls
private struct FrameCaptureState {
    var captureFirstFrame = false
    var enabled = false
    var submitCallsCaptured: Int32 = 0
    var maxSubmitCallsToCapture: Int32 = 1
}

private let frameCapture = Mutex(FrameCaptureState())

private let frameCaptureRegistration: Void = {
    WebGPU.Metal.registerNotifyHandler("com.apple.WebKit.WebGPU.CaptureFrame") { token in
        let state = WebGPU.Metal.notifyState(token)
        frameCapture.withLock {
            $0.maxSubmitCallsToCapture = max(1, Int32(truncatingIfNeeded: state))
            $0.enabled = true
        }
    }
    WebGPU.Metal.registerNotifyHandler("com.apple.WebKit.WebGPU.ToggleCaptureFirstFrame") { _ in
        frameCapture.withLock { $0.captureFirstFrame.toggle() }
    }
}()

private func captureFrame(_ captureObject: (any MTLDevice)?) {
    let captureManager = MTLCaptureManager.shared()
    if captureManager.isCapturing {
        return
    }
    let descriptor = MTLCaptureDescriptor()
    descriptor.captureObject = captureObject
    descriptor.destination = .gpuTraceDocument
    descriptor.outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gputrace")
    let path = descriptor.outputURL?.absoluteString ?? "(null)"
    do {
        try captureManager.startCapture(with: descriptor)
        WebGPU.Metal.logAlways(
            "Success starting GPU frame capture at path \(path) - frame count = \(frameCapture.withLock { $0.maxSubmitCallsToCapture })"
        )
    } catch {
        WebGPU.Metal.logAlways("Failed to start GPU frame capture at path \(path), error \(error)")
    }
}

@_expose(Cxx)
func registerForFrameCapture(_ captureObject: (any MTLDevice)?) {
    frameCaptureRegistration
    if frameCapture.withLock({ $0.captureFirstFrame }) {
        captureFrame(captureObject)
    }
}

@_expose(Cxx)
func captureSingleFrameIfNeeded(_ captureObject: (any MTLDevice)?) {
    let requested = frameCapture.withLock {
        let enabled = $0.enabled
        $0.enabled = false
        return enabled
    }
    if requested {
        captureFrame(captureObject)
    }
}

@_expose(Cxx)
func shouldStopCaptureAfterSubmit() -> Bool {
    frameCapture.withLock {
        $0.submitCallsCaptured &+= 1
        let result = $0.submitCallsCaptured >= $0.maxSubmitCallsToCapture
        if result {
            $0.submitCallsCaptured = 0
        }
        return result
    }
}

// MARK: Encoder timestamps

private let encoderTimestamps = Atomic<Bool>(false)

private let encoderTimestampsRegistration: Void = WebGPU.Metal.registerNotifyHandler("com.apple.WebKit.WebGPU.EnableEncoderTimestamps") {
    _ in
    let enabled = !encoderTimestamps.load(ordering: .relaxed)
    encoderTimestamps.store(enabled, ordering: .relaxed)
    WebGPU.Metal.logAlways("Encoder timestamps are \(enabled ? "ENABLED" : "DISABLED")")
}

@_expose(Cxx)
func enableEncoderTimestamps() -> Bool {
    encoderTimestampsRegistration
    return encoderTimestamps.load(ordering: .relaxed)
}

// MARK: Generated Metal code

private let dumpMetalCode = Atomic<Bool>(false)

private let dumpMetalCodeRegistration: Void = WebGPU.Metal.registerNotifyHandler("com.apple.WebKit.WebGPU.TogglePrintMetalCode") { _ in
    dumpMetalCode.store(!dumpMetalCode.load(ordering: .relaxed), ordering: .relaxed)
}

// Writes to standard error. Any thread (WGSL compiles on a thread of its own).
func dumpMetalCodeIfNeeded(_ utf8: ContiguousArray<UInt8>) {
    dumpMetalCodeRegistration
    if dumpMetalCode.load(ordering: .relaxed) {
        var output = Data("Generated Metal code:\n".utf8)
        output.append(contentsOf: utf8)
        output.append(UInt8(ascii: "\n"))
        FileHandle.standardError.write(output)
    }
}

// MARK: Shader validation

#if ENABLE_WEBGPU_BY_DEFAULT
private let shaderValidation = Atomic<Bool>(false)

private let shaderValidationRegistration: Void = WebGPU.Metal.registerNotifyHandler("com.apple.WebKit.WebGPU.ToggleShaderValidationState") {
    _ in
    shaderValidation.store(!shaderValidation.load(ordering: .relaxed), ordering: .relaxed)
}

private func shaderValidationState() -> MTLShaderValidation {
    shaderValidationRegistration
    return shaderValidation.load(ordering: .relaxed) ? .enabled : .default
}
#endif

func setComputeShaderValidation(_ descriptor: MTLComputePipelineDescriptor) {
    #if ENABLE_WEBGPU_BY_DEFAULT
    descriptor.shaderValidation = shaderValidationState()
    #endif
}

@_expose(Cxx)
func setRenderShaderValidation(_ descriptor: MTLRenderPipelineDescriptor) {
    #if ENABLE_WEBGPU_BY_DEFAULT
    descriptor.shaderValidation = shaderValidationState()
    #endif
}
