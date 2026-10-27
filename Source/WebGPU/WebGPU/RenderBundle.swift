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
import WebGPU_Internal.BindGroup
import WebGPU_Internal.Device
import WebGPU_Internal.RenderBundle
import WebGPU_Internal.RenderBundleEncoder
import WebGPU_Internal.RenderPassEncoder
import WebGPU_Private.WebGPUCpp

// One per GPURenderBundle, built by RenderBundleEncoderImpl.finish(). Owns the ICBs (ICB mode), the encoder (replay
// mode), the resources, the bind groups, the attachment formats and the per-bundle scalars. RenderPassEncoderImpl reads
// it in executeBundles and updates the ICBs' indirect-draw encode caches.
//
// Used only on its Instance's API thread, so deliberately not Sendable.
@_expose(Cxx)
final class RenderBundleImpl {
    let deviceImpl: DeviceImpl
    /// Paired with the mutable `mtlResources`.
    let resources: ResourceSet
    @_expose(!Cxx)
    private(set) var mtlResources: ResourceLists
    let icbs: [BundleICB]
    private let replay: BundleReplay
    private let bindGroups: [(shell: WebGPU.Metal.BindGroup, impl: BindGroupImpl)]
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
    let device: WebGPU.Metal.Device

    @_expose(!Cxx)
    init(
        device: WebGPU.Metal.Device,
        deviceImpl: DeviceImpl,
        resources: ResourceSet,
        mtlResources: ResourceLists,
        icbs: [BundleICB],
        isICBBundle: Bool,
        replay: consuming BundleReplay,
        bindGroups: [(shell: WebGPU.Metal.BindGroup, impl: BindGroupImpl)],
        colorFormats: [WebGPU.TextureFormat?],
        depthStencilFormat: WebGPU.TextureFormat?,
        sampleCount: UInt32,
        depthReadOnly: Bool,
        stencilReadOnly: Bool,
        commandCount: UInt64,
        submitInvalid: Bool
    ) {
        self.deviceImpl = deviceImpl
        self.device = device
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
    }

    @_expose(!Cxx)
    init(invalid device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl, lastError: String?) {
        self.deviceImpl = deviceImpl
        self.device = device
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

    @_expose(Cxx)
    func isValid() -> Bool {
        replay.isEncoder || isICBBundle
    }

    @_expose(Cxx)
    func setLabel(_ label: NSString) {
        icbs.first?.indirectCommandBuffer.label = label as String
    }

    @_expose(!Cxx)
    func registerAsResourceHolder() {
        resources.registerRenderBundleHolder(self)
    }

    @_expose(!Cxx)
    func requiresCommandReplay() -> Bool {
        replay.isEncoder
    }

    @_expose(!Cxx)
    func drawCount() -> UInt64 {
        commandCount
    }

    @_expose(!Cxx)
    func lastError() -> String? {
        if case .none(let lastError) = replay {
            return lastError
        }
        return nil
    }

    @_expose(!Cxx)
    func makeSubmitInvalid() -> Bool {
        submitInvalid
    }

    // Writes the depth range into each ICB's fragment dynamic-offset buffer when it changed.
    @_expose(!Cxx)
    func updateMinMaxDepths(_ device: WebGPU.Metal.Device, _ newMinDepth: Float, _ newMaxDepth: Float) {
        if minDepth == newMinDepth && maxDepth == newMaxDepth {
            return
        }
        minDepth = newMinDepth
        maxDepth = newMaxDepth
        for icb in icbs {
            WebGPU.Metal.writeRenderBundleDepthRange(device, icb.fragmentDynamicOffsetsBuffer, newMinDepth, newMaxDepth)
        }
    }

    @_expose(!Cxx)
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

    @_expose(!Cxx)
    func replayCommands(into passImpl: RenderPassEncoderImpl) {
        guard case .encoder(let encoderShell, let encoderImpl) = replay else {
            return
        }
        encoderImpl.replayCommands(encoderShell, into: passImpl)
    }

    // Every group is visited even after a failure.
    @_expose(!Cxx)
    func rebindSamplersIfNeeded() -> Bool {
        var result = true
        for group in bindGroups {
            result = group.impl.rebindSamplersIfNeeded() && result
        }
        return result
    }

    @_expose(!Cxx)
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
        if case .encoder(_, let encoderImpl) = replay {
            encoderImpl.releaseDestroyedResources()
        }
    }
}

/// What a bundle replays: its encoder (a replay bundle), or nothing, with the error an invalid bundle reports.
///
/// Every case has a payload, so the FRT never sits next to an empty case.
enum BundleReplay {
    case encoder(WebGPU.Metal.RenderBundleEncoder, RenderBundleEncoderImpl)
    case none(lastError: String?)

    var isEncoder: Bool {
        if case .encoder = self {
            return true
        }
        return false
    }
}
