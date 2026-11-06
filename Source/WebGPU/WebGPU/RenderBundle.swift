// Copyright (c) 2021-2026 Apple Inc. All rights reserved.
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

import Foundation
import Metal
@_implementationOnly import WebGPU_Internal.BindGroup
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.RenderBundleEncoder
@_implementationOnly import WebGPU_Internal.RenderPassEncoder
import WebGPU_Private.WebGPUCpp

// One per GPURenderBundle, built by RenderBundleEncoderImpl.finish(). Owns the ICBs (ICB mode), the encoder (replay
// mode), the resources, the bind groups, the attachment formats and the per-bundle scalars. RenderPassEncoderImpl reads
// it in executeBundles and updates the ICBs' indirect-draw encode caches.
//
// Used only on its Instance's API thread, so deliberately not Sendable.
@_spi(WebKitGPU)
public final class RenderBundleImpl: GPUObjectReference {
    /// Paired with the mutable `mtlResources`.
    let resources: ResourceSet
    private(set) var mtlResources: ResourceLists
    let icbs: [BundleICB]
    private let replay: BundleReplay
    private let bindGroups: [BindGroupImpl]
    private let colorFormats: [WebGPU.TextureFormat?]
    private let commandCount: UInt64
    private let sampleCount: UInt32
    private var minDepth: Float = 0
    private var maxDepth: Float = 1
    private let depthStencilFormat: WebGPU.TextureFormat?
    // An ICB bundle is valid even if it ended up with no ICB.
    private let isICBBundle: Bool
    private let depthReadOnly: Bool
    private let stencilReadOnly: Bool
    private var submitInvalid: Bool
    // Declared last, so that the device outlives the rest of the bundle.
    let deviceImpl: DeviceImpl

    init(
        deviceImpl: DeviceImpl,
        resources: ResourceSet,
        mtlResources: ResourceLists,
        icbs: [BundleICB],
        isICBBundle: Bool,
        replay: consuming BundleReplay,
        bindGroups: [BindGroupImpl],
        colorFormats: [WebGPU.TextureFormat?],
        depthStencilFormat: WebGPU.TextureFormat?,
        sampleCount: UInt32,
        depthReadOnly: Bool,
        stencilReadOnly: Bool,
        commandCount: UInt64,
        submitInvalid: Bool
    ) {
        self.deviceImpl = deviceImpl
        self.resources = resources
        self.mtlResources = mtlResources
        self.icbs = icbs
        self.isICBBundle = isICBBundle
        self.replay = replay
        self.bindGroups = bindGroups
        self.colorFormats = colorFormats
        self.depthStencilFormat = depthStencilFormat
        self.sampleCount = sampleCount
        self.depthReadOnly = depthReadOnly
        self.stencilReadOnly = stencilReadOnly
        self.commandCount = commandCount
        self.submitInvalid = submitInvalid
        // The bundle's commands use these groups' argument buffers as they are now.
        for group in bindGroups {
            group.renderBundleConsumerCount += 1
        }
    }

    deinit {
        for group in bindGroups {
            group.renderBundleConsumerCount -= 1
        }
    }

    init(invalid deviceImpl: DeviceImpl, lastError: String?) {
        self.deviceImpl = deviceImpl
        resources = .empty
        mtlResources = []
        icbs = []
        isICBBundle = false
        replay = .none(lastError: lastError)
        bindGroups = []
        colorFormats = []
        depthStencilFormat = nil
        sampleCount = 0
        depthReadOnly = false
        stencilReadOnly = false
        commandCount = 0
        submitInvalid = false
    }

    public func isValid() -> Bool {
        replay.isEncoder || isICBBundle
    }

    func setLabel(_ label: NSString) {
        setLabel(label as String)
    }

    // As WTF::String::createNSString() makes the label for setLabel(NSString), a null one is empty.
    @_spi(WebKitGPU)
    public func setLabel(_ label: Swift.String?) {
        icbs.first?.indirectCommandBuffer.label = label ?? ""
    }

    func registerAsResourceHolder() {
        resources.registerRenderBundleHolder(self)
    }

    func requiresCommandReplay() -> Bool {
        replay.isEncoder
    }

    func drawCount() -> UInt64 {
        commandCount
    }

    func lastError() -> String? {
        if case .none(let lastError) = replay {
            return lastError
        }
        return nil
    }

    func makeSubmitInvalid() -> Bool {
        submitInvalid
    }

    // Writes the depth range into each ICB's fragment dynamic-offset buffer when it changed.
    func updateMinMaxDepths(_ newMinDepth: Float, _ newMaxDepth: Float) {
        if minDepth == newMinDepth && maxDepth == newMaxDepth {
            return
        }
        minDepth = newMinDepth
        maxDepth = newMaxDepth
        // The two floats, in memory order.
        let depthRange = [newMinDepth.bitPattern, newMaxDepth.bitPattern].flatMap { bits in
            (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        }
        for icb in icbs {
            deviceImpl.defaultQueueImpl.stageBufferWrite(
                deviceImpl,
                icb.fragmentDynamicOffsetsBuffer,
                0,
                bytes: depthRange.span
            )
        }
    }

    func validateRenderPass(_ attachments: PassAttachments) -> Bool {
        if attachments.depthReadOnly && !depthReadOnly {
            return false
        }

        if attachments.stencilReadOnly && !stencilReadOnly {
            return false
        }

        let attachmentCount = attachments.colorViewIndices.count
        if colorFormats.count != attachmentCount {
            return false
        }

        var defaultRasterSampleCount: UInt32 = 0
        for index in 0..<max(attachmentCount, colorFormats.count) {
            let descriptorColorFormat = index < colorFormats.count ? colorFormats[index] : nil
            if index >= attachmentCount {
                if descriptorColorFormat == nil {
                    continue
                }
                return false
            }
            guard let attachmentView = attachments.colorView(index) else {
                if descriptorColorFormat == nil {
                    continue
                }
                return false
            }
            if descriptorColorFormat != attachmentView.format {
                return false
            }
            defaultRasterSampleCount = attachmentView.sampleCount
        }

        if attachments.hasDepthStencil {
            if let texture = attachments.depthStencilView {
                if texture.format != depthStencilFormat {
                    return false
                }
                defaultRasterSampleCount = texture.sampleCount
            } else if depthStencilFormat != nil {
                return false
            }
        } else if depthStencilFormat != nil {
            return false
        }

        return sampleCount == defaultRasterSampleCount
    }

    func replayCommands(into passImpl: RenderPassEncoderImpl) {
        guard case .encoder(let encoderImpl) = replay else {
            return
        }
        encoderImpl.replayCommands(into: passImpl)
    }

    // Every group is visited even after a failure.
    func rebindSamplersIfNeeded() -> Bool {
        var result = true
        for group in bindGroups {
            result = group.rebindSamplersIfNeeded() && result
        }
        return result
    }

    func releaseDestroyedResources() {
        // Moved out and back, so that no release happens during an access to mtlResources (see BindGroupImpl).
        var lists: ResourceLists = []
        swap(&lists, &mtlResources)
        let replacedAnything = resources.replaceDestroyedResourcesWithPlaceholders(&lists)
        swap(&lists, &mtlResources)
        if !replacedAnything {
            return
        }

        submitInvalid = true
        if case .encoder(let encoderImpl) = replay {
            encoderImpl.releaseDestroyedResources()
        }
    }
}

/// What a bundle replays: its encoder (a replay bundle), or nothing, with the error an invalid bundle reports.
///
/// Every case has a payload, so the FRT never sits next to an empty case.
enum BundleReplay {
    case encoder(RenderBundleEncoderImpl)
    case none(lastError: String?)

    var isEncoder: Bool {
        if case .encoder = self {
            return true
        }
        return false
    }
}

@_spi(WebKitGPU)
extension RenderBundleEncoderReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpurenderbundleencoder-finish. A null label is empty.
    public func finish(label: Swift.String?) -> RenderBundleReference {
        finish((label ?? "") as NSString)
    }
}

@_spi(WebKitGPU)
public typealias RenderBundleReference = RenderBundleImpl
