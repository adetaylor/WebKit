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
@_implementationOnly import WebGPU_Internal.Buffer
@_implementationOnly import WebGPU_Internal.CommandEncoder
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.Queue

private let commandBufferSubmissionTimeoutSeconds = 0.5

// When a command buffer ran on the GPU.
private struct GPUExecutionTimes: Sendable {
    let start: Double
    let end: Double
}

// The part of a command buffer that its Metal completion handler touches on a Metal thread, while
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
    case restoreIndexBufferContents(BufferImpl, NSMutableData)
    case clearMustTakeSlowIndexValidationPath(DeviceImpl, WeakBufferAndEncoder)
}

// The CommandEncoder that finished into a command buffer, read for its state, which holds the pre-commit actions.
private struct FinishedEncoder {
    let impl: CommandEncoderImpl
}

@_spi(WebKitGPU)
public typealias CommandBufferReference = CommandBufferImpl

@_spi(WebKitGPU)
extension CommandBufferImpl {
    // What the callers used when it had a shell too.
    @_expose(!Cxx)
    public var impl: CommandBufferImpl {
        self
    }
}

// One per GPUCommandBuffer, held by its Swift callers, the queue and Instance while its work is in flight, and the C++
// API's shell WebGPU::Metal::CommandBuffer. Holds the CommandEncoder until the command buffer completes or is made
// invalid; the encoder's Impl holds the pre-commit actions.
//
// Used only on its Instance's API thread, so deliberately not Sendable; the Metal thread only ever gets
// `completion()`. The last reference goes on the API thread: the completion handler's hands its reference to the work
// it schedules there.
@_expose(Cxx)
@_spi(WebKitGPU)
public final class CommandBufferImpl: GPUObjectReference {
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

    fileprivate init(
        commandBuffer: (any MTLCommandBuffer)?,
        sharedEvent: (any MTLSharedEvent)?,
        sharedEventSignalValue: UInt64,
        commandEncoder: [FinishedEncoder],
        deviceImpl: DeviceImpl
    ) {
        self.backingCommandBuffer = commandBuffer
        self.sharedEvent = sharedEvent
        self.sharedEventSignalValue = sharedEventSignalValue
        self.commandEncoder = commandEncoder
        self.deviceImpl = deviceImpl
        // Rolled over by the encoder, in the order they have to be committed in, immediately before commandBuffer().
        self.priorCommandBuffers = commandEncoder.first?.impl.takePriorCommandBuffers() ?? []
        self.initializationLedger = commandEncoder.first?.impl.takeInitializationLedger()
    }

    @_expose(Cxx)
    func completion() -> CommandBufferCompletion {
        backingCompletion
    }

    @_expose(Cxx)
    public func isValid() -> Bool {
        backingCommandBuffer != nil
    }

    @_expose(Cxx)
    func commandBuffer() -> (any MTLCommandBuffer)? {
        backingCommandBuffer
    }

    func setLabel(_ label: NSString?) {
        backingCommandBuffer?.label = label as String?
    }

    // As WTF::String::createNSString() makes the label for setLabel(NSString?), a null one is empty.
    @_expose(!Cxx)
    @_spi(WebKitGPU)
    public func setLabel(_ label: Swift.String?) {
        backingCommandBuffer?.label = label ?? ""
    }

    @_expose(!Cxx)
    func takePriorCommandBuffers() -> [any MTLCommandBuffer] {
        let commandBuffers = priorCommandBuffers
        priorCommandBuffers = []
        return commandBuffers
    }

    func gpuExecutionDurationSeconds() -> Double {
        backingCompletion.gpuExecutionDurationSeconds()
    }

    func lastError() -> NSString? {
        backingLastError
    }

    func bufferMapCount() -> Int32 {
        backingBufferMapCount
    }

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
    private func retainTimestampsForOneUpdate() {
        if let encoder = commandEncoder.first {
            deviceImpl.defaultQueueImpl.retainTimestampsForOneUpdate(encoder.impl.timestampBuffers())
        }
    }

    private func releasePriorCommandBuffers(_ queueImpl: QueueImpl) {
        for commandBuffer in takePriorCommandBuffers() {
            queueImpl.removeMTLCommandBuffer(commandBuffer)
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

    deinit {
        let queueImpl = deviceImpl.defaultQueueImpl
        retainTimestampsForOneUpdate()
        releasePriorCommandBuffers(queueImpl)
        queueImpl.removeMTLCommandBuffer(backingCommandBuffer)
        backingCommandBuffer = nil
        cachedCommandBuffer = nil
        initializationLedger = nil
        // The commit actions go with the command buffer, even if the encoder outlives it.
        clearCommitActions()
        dropCommandEncoder()
    }

    @_expose(Cxx)
    func makeInvalid(_ lastError: NSString?) {
        guard let commandBuffer = backingCommandBuffer, commandBuffer.status.rawValue < MTLCommandBufferStatus.committed.rawValue else {
            return
        }

        let queueImpl = deviceImpl.defaultQueueImpl
        backingLastError = lastError
        queueImpl.removeMTLCommandBuffer(commandBuffer)
        retainTimestampsForOneUpdate()
        releasePriorCommandBuffers(queueImpl)
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

    // Moves the command buffer to `cachedCommandBuffer` and returns it, for registerCompletedHandler() and then the
    // queue's commit.
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

    // Just before the queue commits the command buffer willCommit() returned. The Instance keeps this command buffer
    // until the MTLCommandBuffer goes. On the Metal thread, the handler only gives the GPU times to the Sendable
    // completion, then hands the rest to the API thread through the Instance's scheduler.
    func registerCompletedHandler(_ commandBuffer: (any MTLCommandBuffer)?) {
        deviceImpl.instanceImpl?.retainCommandBuffer(self, commandBuffer)
        guard let commandBuffer else {
            return
        }
        let completion = backingCompletion
        let scheduler = deviceImpl.schedulerHandle()
        let didComplete = APIThreadWork<GPUExecutionTimes> { [self] times in
            commandBufferDidComplete(times.start, times.end)
            deviceImpl.instanceImpl?.releaseCompletedCommandBuffers()
        }
        commandBuffer.addCompletedHandler { completedCommandBuffer in
            // GPUStartTime/GPUEndTime bracket execution on the GPU; kernelStartTime/kernelEndTime only bracket the driver
            // scheduling it.
            let times = GPUExecutionTimes(start: completedCommandBuffer.gpuStartTime, end: completedCommandBuffer.gpuEndTime)
            completion.didComplete(gpuStartTime: times.start, gpuEndTime: times.end)
            didComplete.schedule(times, on: scheduler)
        }
    }

    // The completion handler's work item, on the API thread.
    private func commandBufferDidComplete(_ gpuStartTime: Double, _ gpuEndTime: Double) {
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
    func preCommitHandler() -> Bool {
        guard let encoder = commandEncoder.first else {
            return true
        }
        return encoder.impl.runCommitActions(self)
    }

    func postCommitHandler() {
        let actions = postCommitActions
        postCommitActions = []
        for action in actions {
            switch action {
            case .restoreIndexBufferContents(let bufferImpl, let priorContents):
                cachedCommandBuffer?.waitUntilCompleted()
                bufferImpl.indexBufferContentsWillBeRestored()
                bufferImpl.restoreIndexBufferContents(priorContents)
            case .clearMustTakeSlowIndexValidationPath(_, let pair):
                if let buffer = pair.buffer, !buffer.isDestroyed() {
                    buffer.clearMustTakeSlowIndexValidationPath()
                }
            }
        }
        withExtendedLifetime(actions) {}
    }
}

func makeCommandBufferImpl(
    _ commandBuffer: (any MTLCommandBuffer)?,
    _ sharedEvent: (any MTLSharedEvent)?,
    _ sharedEventSignalValue: UInt64,
    _ commandEncoderImpl: CommandEncoderImpl,
    _ deviceImpl: DeviceImpl
) -> CommandBufferImpl {
    CommandBufferImpl(
        commandBuffer: commandBuffer,
        sharedEvent: sharedEvent,
        sharedEventSignalValue: sharedEventSignalValue,
        commandEncoder: [FinishedEncoder(impl: commandEncoderImpl)],
        deviceImpl: deviceImpl
    )
}

func makeInvalidCommandBufferImpl(_ deviceImpl: DeviceImpl) -> CommandBufferImpl {
    CommandBufferImpl(
        commandBuffer: nil,
        sharedEvent: nil,
        sharedEventSignalValue: 0,
        commandEncoder: [],
        deviceImpl: deviceImpl
    )
}
