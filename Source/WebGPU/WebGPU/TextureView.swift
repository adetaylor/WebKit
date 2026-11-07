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

import Metal
@_implementationOnly import WebGPU_Internal.CommandEncoder
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Texture
@_spiOnly import WebGPU_Private.WebGPUCpp

@_spi(WebKitGPU)
public typealias TextureViewReference = TextureViewImpl

// The state of a GPUTextureView, held by its Swift callers. It
// reads the parent's state (destroyed, initialized, canvas backing, rate maps, descriptor) from the parent's
// TextureImpl. Used only on its Instance's API thread.
@_spi(WebKitGPU)
public final class TextureViewImpl: GPUObjectReference, LinkedImpl {
    private var linkSlot = ImplLinkSlot<TextureViewImpl>()
    // nil only for an invalid view. Replaced by the device placeholder when the parent is destroyed.
    private var backingTexture: (any MTLTexture)?
    // The swizzled view a shader reads; nil when the swizzle is the identity.
    private var backingSampledTexture: (any MTLTexture)?
    // Every view, even an invalid one, keeps its parent alive.
    private let parentImpl: TextureImpl
    // nil for an invalid view, which has no format or dimension.
    private let descriptor: ResolvedTextureViewDescriptor?
    // The parent's physical extent at baseMipLevel. The parent's descriptor is immutable, so this is computed when
    // asked.
    private var physicalExtent: TextureExtent {
        parentImpl.physicalMiplevelSpecificTextureExtent(descriptor?.baseMipLevel ?? 0)
    }
    /// The encoders that used the view, cleared only by destroy(); entries of encoders that died are pruned.
    var tracking = EncoderTracking()
    // The parent's device, with a reference of the view's own. Declared last, so that it outlives the rest of the view.
    let deviceImpl: DeviceImpl

    init(
        texture: (any MTLTexture)?,
        sampledTexture: (any MTLTexture)?,
        parentImpl: TextureImpl,
        descriptor: ResolvedTextureViewDescriptor?
    ) {
        self.backingTexture = texture
        self.backingSampledTexture = sampledTexture
        self.parentImpl = parentImpl
        self.descriptor = descriptor
        deviceImpl = parentImpl.deviceImpl
    }

    deinit {
        linkSlot.end()
    }

    var link: ImplLink<TextureViewImpl> {
        linkSlot.link(for: self)
    }

    var parentTextureImpl: TextureImpl {
        parentImpl
    }

    var formatOrDefault: WebGPU.TextureFormat {
        descriptor?.format ?? .Rgba8unorm
    }

    func setLabel(_ label: WTF.String) {
        setLabel(stringNilIfEmpty(label))
    }

    @_spi(WebKitGPU)
    public func setLabel(_ label: Swift.String?) {
        backingTexture?.label = label?.isEmpty == false ? label : nil
        backingSampledTexture?.label = backingTexture?.label
    }

    func isDestroyed() -> Bool {
        parentImpl.isDestroyed()
    }

    public func isValid() -> Bool {
        backingTexture != nil || parentImpl.isDestroyed()
    }

    func texture() -> (any MTLTexture)? {
        parentImpl.isDestroyed() ? parentImpl.texture() : backingTexture
    }

    func sampledTexture() -> (any MTLTexture)? {
        if parentImpl.isDestroyed() {
            return parentImpl.texture()
        }
        return backingSampledTexture ?? backingTexture
    }

    func parentTexture() -> (any MTLTexture)? {
        parentImpl.texture()
    }

    func parentIsCanvasBacking() -> Bool {
        parentImpl.isCanvasBacking()
    }

    // TextureView::destroy, from the parent's destroy.
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
    func setCommandEncoder(_ encoder: CommandEncoderImpl) {
        if !tracking.contains(encoder) && tracking.add(encoder) {
            encoder.trackTextureView(self)
        }
        parentImpl.setCommandEncoder(encoder)
        if parentImpl.isDestroyed() && !parentImpl.isCanvasBacking() {
            encoder.makeSubmitInvalid(nil)
        }
    }

    func parentRelativeSlice() -> UInt32 {
        UInt32(truncatingIfNeeded: backingTexture?.parentRelativeSlice ?? 0)
    }

    /// The regions an attachment view covers at its base mip level and base array layer: its own aspect, or `requested`
    /// when that names one (a depth-stencil attachment records each aspect separately).
    func initRegions(selecting requested: WebGPU.TextureAspect) -> InitRegions {
        let viewAspect = descriptor?.aspect ?? .All
        return parentImpl.initRegions(mipLevel: baseMipLevel(), layer: baseArrayLayer(), aspect: requested == .All ? viewAspect : requested)
    }

    func rasterizationMapForSlice(_ slice: UInt32) -> (any MTLRasterizationRateMap)? {
        parentImpl.rasterizationMapForSlice(slice)
    }

    func width() -> UInt32 {
        physicalExtent.width
    }

    func height() -> UInt32 {
        physicalExtent.height
    }

    func depthOrArrayLayers() -> UInt32 {
        physicalExtent.depthOrArrayLayers
    }

    func sampleCount() -> UInt32 {
        parentImpl.backingSampleCount
    }

    func format() -> UInt8 {
        (descriptor?.format ?? WebGPU.TextureFormat.Rgba8unorm).rawValue
    }

    func dimension() -> UInt8 {
        (descriptor?.dimension ?? WebGPU.TextureViewDimension._2d).rawValue
    }

    func aspect() -> UInt8 {
        (descriptor?.aspect ?? WebGPU.TextureAspect.All).rawValue
    }

    // The descriptor's usage was resolved to the parent texture's usage when the view was created
    // if the view did not narrow it, so this is the set of usages the view itself allows.
    func usage() -> UInt8 {
        descriptor?.usage ?? 0
    }

    func baseMipLevel() -> UInt32 {
        descriptor?.baseMipLevel ?? 0
    }

    func mipLevelCount() -> UInt32 {
        descriptor?.mipLevelCount ?? 0
    }

    func baseArrayLayer() -> UInt32 {
        descriptor?.baseArrayLayer ?? 0
    }

    func arrayLayerCount() -> UInt32 {
        descriptor?.arrayLayerCount ?? 0
    }

    // True when the descriptor asked for a swizzle other than "rgba"; the base swizzle the format
    // imposes on top of that one does not count.
    func hasSwizzle() -> Bool {
        guard let descriptor else {
            return false
        }
        return !descriptor.swizzleIsIdentity
    }

    // An invalid view has no dimension, so it is none of these (unlike dimension(), which defaults).
    func is2DTexture() -> Bool {
        descriptor?.dimension == WebGPU.TextureViewDimension._2d
    }

    func is2DArrayTexture() -> Bool {
        descriptor?.dimension == WebGPU.TextureViewDimension._2dArray
    }

    func is3DTexture() -> Bool {
        descriptor?.dimension == WebGPU.TextureViewDimension._3d
    }
}

// MARK: - Render pass attachment checks

// beginRenderPass's checks of an attachment's texture or texture view.

// A view can narrow the usages it allows, but it cannot make a memoryless texture behave like a regular one, so the
// transient rule follows the texture the view is a view of.
private func isAllowableTextureView(
    _ texture: AttachmentImpl,
    _ loadOp: WebGPU.LoadOp?,
    _ storeOp: WebGPU.StoreOp?
) -> Bool {
    if texture.isTransient {
        if loadOp != .Clear || storeOp != .Discard {
            return false
        }
    }
    return true
}

// A depth stencil attachment has a load and store op per aspect, and only the aspects present in its format may
// specify them, so the transient rule has to be applied per present aspect.
private func isAllowableDepthStencilTextureView(
    _ texture: AttachmentImpl,
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
private func hasRenderableTextureViewProperties(_ texture: AttachmentImpl) -> Bool {
    texture.usageContains(.RenderAttachment) && (texture.is2DTexture || texture.is2DArrayTexture || texture.is3DTexture)
        && texture.mipLevelCount == 1 && texture.arrayLayerCount <= 1 && !texture.hasSwizzle
}

func isRenderableTextureView(
    _ texture: AttachmentImpl,
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
    _ texture: AttachmentImpl,
    _ isDestroyed: Bool,
    _ hasDepthComponent: Bool,
    _ depthLoadOp: WebGPU.LoadOp?,
    _ depthStoreOp: WebGPU.StoreOp?,
    _ hasStencilComponent: Bool,
    _ stencilLoadOp: WebGPU.LoadOp?,
    _ stencilStoreOp: WebGPU.StoreOp?
) -> Bool {
    if !isDestroyed {
        if !isDepthStencilRenderableFormat(texture.format) {
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
