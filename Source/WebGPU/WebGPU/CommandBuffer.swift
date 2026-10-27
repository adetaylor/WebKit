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

import Dispatch
import Foundation
import Metal
import Synchronization
import WebGPU_Internal.Buffer
import WebGPU_Internal.CommandBuffer
import WebGPU_Internal.CommandEncoder
import WebGPU_Internal.Device
import WebGPU_Internal.Queue

private let commandBufferSubmissionTimeoutSeconds = 0.5

// The part of a command buffer that the shell's Metal completion handler touches on a Metal thread, while
// the API thread reads the duration and waits for the signal. Sendable, so the compiler proves it safe to share.
@_expose(Cxx)
final class CommandBufferCompletion: Sendable {
    // A Double's bit pattern: Atomic has no Double.
    private let gpuExecutionDurationBits = Atomic<UInt64>(0)
    // FIXME: we should not need this semaphore - https://bugs.webkit.org/show_bug.cgi?id=272353
    private let semaphore = DispatchSemaphore(value: 0)

    fileprivate init() {}

    // Runs on a Metal completion thread. The semaphore orders the store before a waiter's load.
    @_expose(Cxx)
    func didComplete(gpuStartTime: Double, gpuEndTime: Double) {
        gpuExecutionDurationBits.store((gpuEndTime - gpuStartTime).bitPattern, ordering: .relaxed)
        semaphore.signal()
    }

    fileprivate func wait(timeoutSeconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + timeoutSeconds) == .success
    }

    fileprivate func gpuExecutionDurationSeconds() -> Double {
        Double(bitPattern: gpuExecutionDurationBits.load(ordering: .relaxed))
    }
}

/// Run after the queue committed the command buffer, then dropped.
///
/// The encoder's commit actions for the slow index validation path add them.
enum PostCommitAction {
    /// Waits for the command buffer, then writes back the index data the slow path cleared.
    case restoreIndexBufferContents(WebGPU.Metal.Buffer, BufferImpl, NSMutableData)
    case clearMustTakeSlowIndexValidationPath(WebGPU.Metal.Device, WeakBufferAndEncoder)
}

// The CommandEncoder that finished into a command buffer. The Impl is read for its state and holds the pre-commit
// actions; the shell keeps it alive.
private struct FinishedEncoder {
    let shell: WebGPU.Metal.CommandEncoder
    let impl: CommandEncoderImpl
}

// One per GPUCommandBuffer, owned by the C++ shell WebGPU::Metal::CommandBuffer. Holds the CommandEncoder until the
// command buffer completes or is made invalid; the encoder's Impl holds the pre-commit actions.
//
// Used only on its Instance's API thread, so deliberately not Sendable; the Metal thread only ever gets
// `completion()`.
@_expose(Cxx)
final class CommandBufferImpl {
    private var backingCommandBuffer: (any MTLCommandBuffer)?
    // The committed command buffer, until the completion handler's work item runs.
    private var cachedCommandBuffer: (any MTLCommandBuffer)?
    private var priorCommandBuffers: [any MTLCommandBuffer] = []
    // Zero or one element; an Array rather than an Optional, to avoid the FRT null-retain hazard.
    private var commandEncoder: [FinishedEncoder]
    private let sharedEvent: (any MTLSharedEvent)?
    private let sharedEventSignalValue: UInt64
    private let backingCompletion = CommandBufferCompletion()
    private var backingLastError: NSString?
    private var backingBufferMapCount: Int32 = 0
    private var postCommitActions: [PostCommitAction] = []
    // The finished encoder's InitializationLedger, until submit applies it after the commit, or it is dropped with the
    // command buffer.
    private var initializationLedger: InitializationLedger?
    // Declared last, so that the device outlives the rest of the command buffer.
    let deviceImpl: DeviceImpl
    let device: WebGPU.Metal.Device
    @_expose(Cxx)
    func shellDevice() -> WebGPU.Metal.Device { device }

    fileprivate init(
        commandBuffer: (any MTLCommandBuffer)?,
        sharedEvent: (any MTLSharedEvent)?,
        sharedEventSignalValue: UInt64,
        commandEncoder: [FinishedEncoder],
        device: WebGPU.Metal.Device,
        deviceImpl: DeviceImpl
    ) {
        self.backingCommandBuffer = commandBuffer
        self.sharedEvent = sharedEvent
        self.sharedEventSignalValue = sharedEventSignalValue
        self.commandEncoder = commandEncoder
        self.deviceImpl = deviceImpl
        self.device = device
        // Rolled over by the encoder, in the order they have to be committed in, immediately before commandBuffer().
        self.priorCommandBuffers = commandEncoder.first?.impl.takePriorCommandBuffers() ?? []
        self.initializationLedger = commandEncoder.first?.impl.takeInitializationLedger()
    }

    @_expose(Cxx)
    func completion() -> CommandBufferCompletion {
        backingCompletion
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        backingCommandBuffer != nil
    }

    @_expose(Cxx)
    func commandBuffer() -> (any MTLCommandBuffer)? {
        backingCommandBuffer
    }

    @_expose(Cxx)
    func setLabel(_ label: NSString?) {
        backingCommandBuffer?.label = label as String?
    }

    @_expose(!Cxx)
    func takePriorCommandBuffers() -> [any MTLCommandBuffer] {
        let commandBuffers = priorCommandBuffers
        priorCommandBuffers = []
        return commandBuffers
    }

    @_expose(Cxx)
    func gpuExecutionDurationSeconds() -> Double {
        backingCompletion.gpuExecutionDurationSeconds()
    }

    @_expose(Cxx)
    func lastError() -> NSString? {
        backingLastError
    }

    @_expose(Cxx)
    func bufferMapCount() -> Int32 {
        backingBufferMapCount
    }

    @_expose(Cxx)
    func setBufferMapCount(_ count: Int32) {
        backingBufferMapCount = count
    }

    @_expose(Cxx)
    func waitForCompletion() -> Bool {
        let status = cachedCommandBuffer?.status ?? .notEnqueued
        if status == .committed || status == .scheduled {
            return backingCompletion.wait(timeoutSeconds: commandBufferSubmissionTimeoutSeconds)
        }

        return true
    }

    // Releases the CommandEncoder outside any access to `commandEncoder`, because its destructor re-enters the queue.
    private func dropCommandEncoder() {
        let encoder = commandEncoder
        commandEncoder = []
        withExtendedLifetime(encoder) {}
    }

    // Workaround for rdar://143905417
    private func retainTimestampsForOneUpdate(_ queue: WebGPU.Metal.Queue) {
        if let encoder = commandEncoder.first {
            queue.retainTimestampsForOneUpdate(encoder.impl.timestampBuffers())
        }
    }

    private func releasePriorCommandBuffers(_ queue: WebGPU.Metal.Queue, _ queueImpl: QueueImpl) {
        for commandBuffer in takePriorCommandBuffers() {
            queueImpl.removeMTLCommandBuffer(queue, commandBuffer)
        }
    }

    // The pre-commit actions are the encoder's.
    private func clearCommitActions() {
        if let encoder = commandEncoder.first {
            encoder.impl.clearCommitActions()
        }
        let actions = postCommitActions
        postCommitActions = []
        withExtendedLifetime(actions) {}
    }

    // Called from ~CommandBuffer, which must not pass the dying shell into Swift.
    @_expose(Cxx)
    func commandBufferWillBeDestroyed() {
        let queue = deviceImpl.defaultQueue()
        let queueImpl = deviceImpl.defaultQueueImpl
        retainTimestampsForOneUpdate(queue)
        releasePriorCommandBuffers(queue, queueImpl)
        queueImpl.removeMTLCommandBuffer(queue, backingCommandBuffer)
        backingCommandBuffer = nil
        cachedCommandBuffer = nil
        initializationLedger = nil
        // The commit actions go with the command buffer, even if the encoder outlives it.
        clearCommitActions()
        dropCommandEncoder()
    }

    @_expose(Cxx)
    func makeInvalid(_ shell: WebGPU.Metal.CommandBuffer, _ lastError: NSString?) {
        guard let commandBuffer = backingCommandBuffer, commandBuffer.status.rawValue < MTLCommandBufferStatus.committed.rawValue else {
            return
        }

        let queue = deviceImpl.defaultQueue()
        let queueImpl = deviceImpl.defaultQueueImpl
        backingLastError = lastError
        queueImpl.removeMTLCommandBuffer(queue, commandBuffer)
        retainTimestampsForOneUpdate(queue)
        releasePriorCommandBuffers(queue, queueImpl)
        backingCommandBuffer = nil
        cachedCommandBuffer = nil
        initializationLedger = nil
        if let encoder = commandEncoder.first {
            encoder.impl.clearTracking()
        }
        clearCommitActions()
        dropCommandEncoder()
    }

    // MARK: Lazy zero-initialization, for QueueImpl.submit

    @_expose(!Cxx)
    var hasInitializationRequirements: Bool {
        initializationLedger?.hasRequirements ?? false
    }

    @_expose(!Cxx)
    func forEachInitializationRequirement(_ body: (TextureImpl, InitRegion) -> Void) {
        guard let requirements = initializationLedger?.requirements else {
            return
        }
        for requirement in requirements {
            body(requirement.texture, requirement.region)
        }
    }

    @_expose(!Cxx)
    func forEachInitializationEffect(_ body: (TextureImpl, InitRegion, InitializationLedger.Effect) -> Void) {
        guard let effects = initializationLedger?.effects else {
            return
        }
        for entry in effects {
            body(entry.texture, entry.region, entry.effect)
        }
    }

    /// The queue appended a zero fill of `fixUp` at the end of this command buffer, after everything it encoded.
    @_expose(!Cxx)
    func noteAppendedZeroFill(_ fixUp: InitFixUp) {
        initializationLedger?.noteWritten(fixUp.texture, fixUp.region)
    }

    /// After the queue committed this command buffer.
    @_expose(!Cxx)
    func applyInitializationEffects(_ token: borrowing CommitToken) {
        initializationLedger.take()?.apply(token)
    }

    /// When the queue could not commit it.
    @_expose(!Cxx)
    func dropInitializationLedger() {
        initializationLedger = nil
    }

    // Moves the command buffer to `cachedCommandBuffer` and returns it, for the shell's
    // registerCompletedHandler() and then the queue's commit.
    func willCommit(_ lastError: NSString?) -> (any MTLCommandBuffer)? {
        let commandBuffer = backingCommandBuffer
        if let sharedEvent, let commandBuffer {
            commandBuffer.encodeSignalEvent(sharedEvent, value: sharedEventSignalValue)
        }
        cachedCommandBuffer = commandBuffer
        backingLastError = lastError
        backingCommandBuffer = nil
        return commandBuffer
    }

    // The completion handler's work item, on the API thread.
    @_expose(Cxx)
    func commandBufferDidComplete(_ gpuStartTime: Double, _ gpuEndTime: Double) {
        cachedCommandBuffer = nil
        if let encoder = commandEncoder.first {
            encoder.impl.recordGPUExecutionWindowOnCanvasTextures(gpuStartTime, gpuEndTime)
            encoder.impl.clearTracking()
        }

        dropCommandEncoder()
    }

    // For the encoder's commit actions, while preCommitHandler runs them.
    @_expose(!Cxx)
    func addPostCommitAction(_ action: PostCommitAction) {
        postCommitActions.append(action)
    }

    // Runs the encoder's commit actions, which then are gone.
    func preCommitHandler(_ shell: WebGPU.Metal.CommandBuffer) -> Bool {
        guard let encoder = commandEncoder.first else {
            return true
        }
        return encoder.impl.runCommitActions(shell, self)
    }

    func postCommitHandler(_ shell: WebGPU.Metal.CommandBuffer) {
        let actions = postCommitActions
        postCommitActions = []
        for action in actions {
            switch action {
            case .restoreIndexBufferContents(let buffer, _, let priorContents):
                WebGPU.Metal.restoreIndexBufferContents(buffer, cachedCommandBuffer, priorContents)
            case .clearMustTakeSlowIndexValidationPath(_, let pair):
                if let buffer = pair.buffer, !buffer.isDestroyed() {
                    buffer.clearMustTakeSlowIndexValidationPath()
                }
            }
        }
        withExtendedLifetime(actions) {}
    }
}

@_expose(Cxx)
func makeCommandBufferImpl(
    _ commandBuffer: (any MTLCommandBuffer)?,
    _ sharedEvent: (any MTLSharedEvent)?,
    _ sharedEventSignalValue: UInt64,
    _ commandEncoder: WebGPU.Metal.CommandEncoder,
    _ commandEncoderImpl: CommandEncoderImpl,
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl
) -> CommandBufferImpl {
    CommandBufferImpl(
        commandBuffer: commandBuffer,
        sharedEvent: sharedEvent,
        sharedEventSignalValue: sharedEventSignalValue,
        commandEncoder: [FinishedEncoder(shell: commandEncoder, impl: commandEncoderImpl)],
        device: device,
        deviceImpl: deviceImpl
    )
}

@_expose(Cxx)
func makeInvalidCommandBufferImpl(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl) -> CommandBufferImpl {
    CommandBufferImpl(
        commandBuffer: nil,
        sharedEvent: nil,
        sharedEventSignalValue: 0,
        commandEncoder: [],
        device: device,
        deviceImpl: deviceImpl
    )
}
