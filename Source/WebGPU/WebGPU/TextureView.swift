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

import Metal
import WebGPU_Internal.CommandEncoder
import WebGPU_Internal.CxxBridging
import WebGPU_Internal.Texture
import WebGPU_Internal.TextureOrTextureView
import WebGPU_Internal.TextureView
import WebGPU_Private.WebGPUCpp

// The state of a GPUTextureView, owned by the C++ shell WebGPU::Metal::TextureView. It reads the parent's state
// (destroyed, initialized, canvas backing, rate maps, descriptor) from the parent's TextureImpl. Used only on its
// Instance's API thread.
@_expose(Cxx)
final class TextureViewImpl {
    // nil only for an invalid view. Replaced by the device placeholder when the parent is destroyed.
    private var backingTexture: (any MTLTexture)?
    // The swizzled view a shader reads; nil when the swizzle is the identity.
    private var backingSampledTexture: (any MTLTexture)?
    // Never null, even for an invalid view: every view keeps its parent alive.
    private let backingParentTexture: WebGPU.Metal.Texture
    // backingParentTexture's state; held alongside it, so it lives exactly as long as the parent's shell.
    private let parentImpl: TextureImpl
    // nil for an invalid view, which has no format or dimension.
    private let descriptor: ResolvedTextureViewDescriptor?
    // The parent's physical extent at baseMipLevel. The parent's descriptor is immutable, so this is computed when
    // asked.
    private var physicalExtent: TextureExtent {
        parentImpl.physicalMiplevelSpecificTextureExtent(descriptor?.baseMipLevel ?? 0)
    }
    /// The encoders that used the view, cleared only by destroy(); entries of encoders that died are pruned.
    @_expose(!Cxx)
    var tracking = EncoderTracking()
    // The parent's device, with a reference of the view's own. Declared last, so that it outlives the rest of the view.
    let device: WebGPU.Metal.Device
    @_expose(Cxx)
    func shellDevice() -> WebGPU.Metal.Device { device }

    init(
        texture: (any MTLTexture)?,
        sampledTexture: (any MTLTexture)?,
        parentTexture: WebGPU.Metal.Texture,
        parentImpl: TextureImpl,
        descriptor: ResolvedTextureViewDescriptor?,
        device: WebGPU.Metal.Device
    ) {
        self.backingTexture = texture
        self.backingSampledTexture = sampledTexture
        self.backingParentTexture = parentTexture
        self.parentImpl = parentImpl
        self.descriptor = descriptor
        self.device = device
    }

    var parentTextureImpl: TextureImpl {
        parentImpl
    }

    /// The view's device is its parent's.
    var deviceImpl: DeviceImpl {
        parentImpl.deviceImpl
    }

    @_expose(!Cxx)
    var formatOrDefault: WebGPU.TextureFormat {
        descriptor?.format ?? .Rgba8unorm
    }

    @_expose(Cxx)
    func setLabel(_ label: WTF.String) {
        backingTexture?.label = CxxBridging.convertWTFStringToNSString(label) as String?
        backingSampledTexture?.label = backingTexture?.label
    }

    @_expose(Cxx)
    func isDestroyed() -> Bool {
        parentImpl.isDestroyed()
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        backingTexture != nil || parentImpl.isDestroyed()
    }

    @_expose(Cxx)
    func texture() -> (any MTLTexture)? {
        parentImpl.isDestroyed() ? parentImpl.texture() : backingTexture
    }

    @_expose(Cxx)
    func sampledTexture() -> (any MTLTexture)? {
        if parentImpl.isDestroyed() {
            return parentImpl.texture()
        }
        return backingSampledTexture ?? backingTexture
    }

    @_expose(Cxx)
    func parentTexture() -> (any MTLTexture)? {
        parentImpl.texture()
    }

    // +1 (SWIFT_RETURNS_RETAINED); the shell borrows it with borrowSwiftRetained.
    @_expose(Cxx)
    func apiParentTexture() -> WebGPU.Metal.Texture {
        backingParentTexture
    }

    @_expose(!Cxx)
    func parentIsCanvasBacking() -> Bool {
        parentImpl.isCanvasBacking()
    }

    // TextureView::destroy, from the parent's destroy.
    @_expose(!Cxx)
    func destroy() {
        backingTexture = deviceImpl.placeholderTexture(isDepthOrStencilFormat(descriptor?.format ?? .Rgba8unorm))
        backingSampledTexture = nil
        if !parentImpl.isCanvasBacking() {
            for encoder in tracking.takeLive() {
                encoder.makeSubmitInvalid(nil)
            }
        }
        tracking.removeAll()
    }

    // TextureView::setCommandEncoder: the encoder holds the parent texture, not the view.
    @_expose(Cxx)
    func setCommandEncoder(_ encoder: CommandEncoderImpl) {
        if !tracking.contains(encoder) {
            _ = tracking.add(encoder)
        }
        parentImpl.setCommandEncoder(encoder)
        if parentImpl.isDestroyed() && !parentImpl.isCanvasBacking() {
            encoder.makeSubmitInvalid(nil)
        }
    }

    // 0 for an invalid view.
    @_expose(Cxx)
    func parentRelativeMipLevel() -> UInt32 {
        UInt32(truncatingIfNeeded: backingTexture?.parentRelativeLevel ?? 0)
    }

    @_expose(Cxx)
    func parentRelativeSlice() -> UInt32 {
        UInt32(truncatingIfNeeded: backingTexture?.parentRelativeSlice ?? 0)
    }

    /// The regions an attachment view covers at its base mip level and base array layer: its own aspect, or `requested`
    /// when that names one (a depth-stencil attachment records each aspect separately).
    @_expose(!Cxx)
    func initRegions(selecting requested: WebGPU.TextureAspect) -> InitRegions {
        let viewAspect = descriptor?.aspect ?? .All
        return parentImpl.initRegions(mipLevel: baseMipLevel(), layer: baseArrayLayer(), aspect: requested == .All ? viewAspect : requested)
    }

    @_expose(Cxx)
    func rasterizationMapForSlice(_ slice: UInt32) -> (any MTLRasterizationRateMap)? {
        parentImpl.rasterizationMapForSlice(slice)
    }

    @_expose(Cxx)
    func hasDescriptor() -> Bool {
        descriptor != nil
    }

    @_expose(Cxx)
    func width() -> UInt32 {
        physicalExtent.width
    }

    @_expose(Cxx)
    func height() -> UInt32 {
        physicalExtent.height
    }

    @_expose(Cxx)
    func depthOrArrayLayers() -> UInt32 {
        physicalExtent.depthOrArrayLayers
    }

    @_expose(Cxx)
    func sampleCount() -> UInt32 {
        parentImpl.backingSampleCount
    }

    @_expose(Cxx)
    func parentMipLevelCount() -> UInt32 {
        parentImpl.backingMipLevelCount
    }

    // The WebGPU enums and the usage OptionSet cross back as raw values; the shell casts them. An invalid
    // view reports an arbitrary format and dimension, which only the validation that rejects it sees.
    @_expose(Cxx)
    func parentFormat() -> UInt8 {
        parentImpl.formatOrDefault.rawValue
    }

    @_expose(Cxx)
    func format() -> UInt8 {
        (descriptor?.format ?? WebGPU.TextureFormat.Rgba8unorm).rawValue
    }

    @_expose(Cxx)
    func dimension() -> UInt8 {
        (descriptor?.dimension ?? WebGPU.TextureViewDimension._2d).rawValue
    }

    @_expose(Cxx)
    func aspect() -> UInt8 {
        (descriptor?.aspect ?? WebGPU.TextureAspect.All).rawValue
    }

    // The descriptor's usage was resolved to the parent texture's usage when the view was created
    // if the view did not narrow it, so this is the set of usages the view itself allows.
    @_expose(Cxx)
    func usage() -> UInt8 {
        descriptor?.usage ?? 0
    }

    @_expose(Cxx)
    func baseMipLevel() -> UInt32 {
        descriptor?.baseMipLevel ?? 0
    }

    @_expose(Cxx)
    func mipLevelCount() -> UInt32 {
        descriptor?.mipLevelCount ?? 0
    }

    @_expose(Cxx)
    func baseArrayLayer() -> UInt32 {
        descriptor?.baseArrayLayer ?? 0
    }

    @_expose(Cxx)
    func arrayLayerCount() -> UInt32 {
        descriptor?.arrayLayerCount ?? 0
    }

    // True when the descriptor asked for a swizzle other than "rgba"; the base swizzle the format
    // imposes on top of that one does not count.
    @_expose(Cxx)
    func hasSwizzle() -> Bool {
        guard let descriptor else {
            return false
        }
        return !descriptor.swizzleIsIdentity
    }

    // An invalid view has no dimension, so it is none of these (unlike dimension(), which defaults).
    @_expose(Cxx)
    func is2DTexture() -> Bool {
        descriptor?.dimension == WebGPU.TextureViewDimension._2d
    }

    @_expose(Cxx)
    func is2DArrayTexture() -> Bool {
        descriptor?.dimension == WebGPU.TextureViewDimension._2dArray
    }

    @_expose(Cxx)
    func is3DTexture() -> Bool {
        descriptor?.dimension == WebGPU.TextureViewDimension._3d
    }
}

@_expose(Cxx)
func makeInvalidTextureViewImpl(
    _ parentTexture: WebGPU.Metal.Texture,
    _ parentImpl: TextureImpl,
    _ device: WebGPU.Metal.Device
) -> TextureViewImpl {
    TextureViewImpl(
        texture: nil,
        sampledTexture: nil,
        parentTexture: parentTexture,
        parentImpl: parentImpl,
        descriptor: nil,
        device: device
    )
}

// MARK: - Render pass attachment checks

// beginRenderPass's checks of an attachment's texture or texture view. Each reads the borrowed attachment before any
// || or &&, which would otherwise consume it.

// A view can narrow the usages it allows, but it cannot make a memoryless texture behave like a regular one, so the
// transient rule follows the texture the view is a view of.
private func isAllowableTextureView(
    _ texture: borrowing WebGPU.Metal.TextureOrTextureView,
    _ loadOp: WebGPU.LoadOp?,
    _ storeOp: WebGPU.StoreOp?
) -> Bool {
    if texture.apiParentTexture().usage().contains(WebGPU.TextureUsage.Transient) {
        if loadOp != .Clear || storeOp != .Discard {
            return false
        }
    }
    return true
}

// A depth stencil attachment has a load and store op per aspect, and only the aspects present in its format may
// specify them, so the transient rule has to be applied per present aspect.
private func isAllowableDepthStencilTextureView(
    _ texture: borrowing WebGPU.Metal.TextureOrTextureView,
    _ hasDepthComponent: Bool,
    _ depthLoadOp: WebGPU.LoadOp?,
    _ depthStoreOp: WebGPU.StoreOp?,
    _ hasStencilComponent: Bool,
    _ stencilLoadOp: WebGPU.LoadOp?,
    _ stencilStoreOp: WebGPU.StoreOp?
) -> Bool {
    if hasDepthComponent {
        if !isAllowableTextureView(texture, depthLoadOp, depthStoreOp) {
            return false
        }
    }
    if !hasStencilComponent {
        return true
    }
    return isAllowableTextureView(texture, stencilLoadOp, stencilStoreOp)
}

// A swizzle only describes how a shader reads the view; an attachment writes it, so a view with one is not renderable.
// https://gpuweb.github.io/gpuweb/#abstract-opdef-renderable-texture-view
private func hasRenderableTextureViewProperties(_ texture: borrowing WebGPU.Metal.TextureOrTextureView) -> Bool {
    let usage = texture.usage()
    let is2DTexture = texture.is2DTexture()
    let is2DArrayTexture = texture.is2DArrayTexture()
    let is3DTexture = texture.is3DTexture()
    let mipLevelCount = texture.mipLevelCount()
    let arrayLayerCount = texture.arrayLayerCount()
    let hasSwizzle = texture.hasSwizzle()
    return usage.contains(WebGPU.TextureUsage.RenderAttachment) && (is2DTexture || is2DArrayTexture || is3DTexture) && mipLevelCount == 1
        && arrayLayerCount <= 1 && !hasSwizzle
}

func isRenderableTextureView(
    _ texture: borrowing WebGPU.Metal.TextureOrTextureView,
    _ loadOp: WebGPU.LoadOp,
    _ storeOp: WebGPU.StoreOp
) -> Bool {
    if !isAllowableTextureView(texture, loadOp, storeOp) {
        return false
    }
    return hasRenderableTextureViewProperties(texture)
}

// The renderable properties of a depth stencil attachment only describe something while the view still has memory
// behind it, but the per-aspect transient rule applies to a destroyed view just the same.
func isRenderableDepthStencilTextureView(
    _ texture: borrowing WebGPU.Metal.TextureOrTextureView,
    _ isDestroyed: Bool,
    _ hasDepthComponent: Bool,
    _ depthLoadOp: WebGPU.LoadOp?,
    _ depthStoreOp: WebGPU.StoreOp?,
    _ hasStencilComponent: Bool,
    _ stencilLoadOp: WebGPU.LoadOp?,
    _ stencilStoreOp: WebGPU.StoreOp?
) -> Bool {
    if !isDestroyed {
        if !isDepthStencilRenderableFormat(texture.format()) {
            return false
        }
        if !hasRenderableTextureViewProperties(texture) {
            return false
        }
    }
    return isAllowableDepthStencilTextureView(
        texture,
        hasDepthComponent,
        depthLoadOp,
        depthStoreOp,
        hasStencilComponent,
        stencilLoadOp,
        stencilStoreOp
    )
}
