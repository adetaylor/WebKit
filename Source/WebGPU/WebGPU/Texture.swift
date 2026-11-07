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

private import CxxStdlib
import Foundation
import Metal
@_implementationOnly import WebGPU_Internal.BindGroup
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.Texture
@_spiOnly import WebGPU_Private.WebGPUCpp

// https://gpuweb.github.io/gpuweb/#dictdef-gputextureviewdescriptor, without its label. The nil members take their
// values from the texture.
@_spi(WebKitGPU)
public struct GPUTextureViewDescriptor {
    public var format: WebGPU.TextureFormat?
    public var dimension: WebGPU.TextureViewDimension?
    public var baseMipLevel: UInt32 = 0
    public var mipLevelCount: UInt32?
    public var baseArrayLayer: UInt32 = 0
    public var arrayLayerCount: UInt32?
    public var aspect = WebGPU.TextureAspect.All
    // The bits of OptionSet<WebGPU::TextureUsage>; none for the usage of the texture.
    public var usage: UInt8 = 0
    public var swizzle = WebGPU.TextureComponentSwizzle()

    public init() {
    }

    var parameters: WebGPU.Metal.TextureViewDescriptorParameters {
        var parameters = WebGPU.Metal.TextureViewDescriptorParameters()
        parameters.format = format ?? .Rgba8unorm
        parameters.hasFormat = format != nil
        parameters.dimension = dimension ?? ._2d
        parameters.hasDimension = dimension != nil
        parameters.baseMipLevel = baseMipLevel
        parameters.mipLevelCount = mipLevelCount ?? 0
        parameters.hasMipLevelCount = mipLevelCount != nil
        parameters.baseArrayLayer = baseArrayLayer
        parameters.arrayLayerCount = arrayLayerCount ?? 0
        parameters.hasArrayLayerCount = arrayLayerCount != nil
        parameters.aspect = aspect
        parameters.usage = usage
        parameters.swizzle = swizzle
        return parameters
    }
}

// A WebGPU::TextureViewDescriptor after
// https://gpuweb.github.io/gpuweb/#abstract-opdef-resolving-gputextureviewdescriptor-defaults.
struct ResolvedTextureViewDescriptor {
    let format: WebGPU.TextureFormat
    let dimension: WebGPU.TextureViewDimension
    let baseMipLevel: UInt32
    let mipLevelCount: UInt32
    let baseArrayLayer: UInt32
    let arrayLayerCount: UInt32
    let aspect: WebGPU.TextureAspect
    let usage: UInt8
    let swizzle: WebGPU.TextureComponentSwizzle

    var swizzleIsIdentity: Bool {
        swizzle.r == .R && swizzle.g == .G && swizzle.b == .B && swizzle.a == .A
    }
}

/// Which aspect of a texel an initialization fact is about.
///
/// Combined depth-stencil formats track the two separately, because a copy can write only one of them.
enum InitAspect {
    case color
    case depth
    case stencil
}

/// One lazily initialized part of a texture.
///
/// One aspect of one array layer of one mip level, or, for a 3D texture, a whole mip level. Only TextureImpl.initRegions
/// makes one, choosing the shape from the texture's dimension, so a 3D mip level cannot be marked plane by plane.
struct InitRegion: Hashable {
    fileprivate let bit: Int
}

/// The regions one (mip level, layer, aspect) selection covers: one, or both aspects of a combined format.
struct InitRegions: Sequence, IteratorProtocol {
    fileprivate var first: InitRegion?
    fileprivate var second: InitRegion?

    mutating func next() -> InitRegion? {
        guard let region = first else {
            return nil
        }
        first = second
        second = nil
        return region
    }
}

/// A canvas or XR texture's GPU frame cost, completion event and rasterization rate maps (TextureImpl.canvasState).
private struct TextureCanvasState {
    var gpuFrameCost: Double = 0
    var sharedEvent: (any MTLSharedEvent)?
    var sharedEventSignalValue: UInt64 = 0
    var leftRasterizationMap: (any MTLRasterizationRateMap)?
    var rightRasterizationMap: (any MTLRasterizationRateMap)?
}

/// One bit per InitRegion, with a count for the "every region initialized" fast path.
///
/// A bit past regionCount names no region, so it reads as initialized and is never stored.
private struct TextureInitState {
    /// Regions 0-63, which is all most textures have, so they allocate nothing.
    private var firstWord: UInt64 = 0
    /// Regions from 64 on, 64 per word.
    private var moreWords: [UInt64]
    private var initializedCount: Int32 = 0
    /// At most 32 mip levels * 2048 layers * 2 aspects.
    private let storedRegionCount: Int32

    init(regionCount: Int) {
        storedRegionCount = Int32(regionCount)
        moreWords = regionCount > 64 ? Array(repeating: 0, count: (regionCount - 1) / 64) : []
    }

    var regionCount: Int {
        Int(storedRegionCount)
    }

    var isFull: Bool {
        initializedCount == storedRegionCount
    }

    private func word(_ bit: Int) -> UInt64 {
        bit < 64 ? firstWord : moreWords[(bit >> 6) - 1]
    }

    private mutating func setWord(_ bit: Int, _ value: UInt64) {
        if bit < 64 {
            firstWord = value
        } else {
            moreWords[(bit >> 6) - 1] = value
        }
    }

    func contains(_ bit: Int) -> Bool {
        guard bit < regionCount else {
            return true
        }
        return word(bit) & (1 &<< UInt64(bit & 63)) != 0
    }

    mutating func insert(_ bit: Int) {
        guard bit < regionCount else {
            return
        }
        let mask: UInt64 = 1 &<< UInt64(bit & 63)
        let current = word(bit)
        if current & mask == 0 {
            setWord(bit, current | mask)
            initializedCount += 1
        }
    }

    mutating func remove(_ bit: Int) {
        guard bit < regionCount else {
            return
        }
        let mask: UInt64 = 1 &<< UInt64(bit & 63)
        let current = word(bit)
        if current & mask != 0 {
            setWord(bit, current & ~mask)
            initializedCount -= 1
        }
    }

    mutating func removeAll() {
        firstWord = 0
        for index in moreWords.indices {
            moreWords[index] = 0
        }
        initializedCount = 0
    }
}

// The state of a GPUTexture, held by its Swift callers and the views, bind groups, attachments and encoders that use it.
// Also runs view creation and its validation. Used only on its
// Instance's API thread.
@_spi(WebKitGPU)
public final class TextureImpl: GPUObjectReference, LinkedImpl {
    private var linkSlot = ImplLinkSlot<TextureImpl>()
    // nil only for an invalid texture. destroy() swaps in the device placeholder unless canvas-backed.
    private var backingTexture: (any MTLTexture)?
    private var destroyed = false
    private var canvasBacking = false
    // Discards recorded by encoders whose command buffers were neither committed nor dropped yet: while one is pending, an
    // initialized region can become uninitialized before a reader runs, so readers record a requirement.
    private(set) var pendingDiscards: Int32 = 0
    // The regions known to hold zeros or contents written on the queue timeline (TextureImpl.initRegions).
    private var initState: TextureInitState
    /// Empty until the texture first records a frame cost, a completion event or rasterization rate maps (canvas and XR
    /// textures), then one element: the others carry one reference instead of the state.
    private var canvasState: [TextureCanvasState] = []

    // The descriptor. An invalid texture has zero sizes, the 2D dimension, no format and no usage.
    let backingWidth: UInt32
    let backingHeight: UInt32
    let backingDepthOrArrayLayers: UInt32
    let backingMipLevelCount: UInt32
    let backingSampleCount: UInt32
    let backingDimension: WebGPU.TextureDimension
    let backingFormat: WebGPU.TextureFormat?
    let backingUsage: UInt8
    // The formats its views may have besides its own.
    private let viewFormats: [WebGPU.TextureFormat]

    /// The encoders that used the texture.
    var tracking = EncoderTracking()
    // The views made with a descriptor, and the bind groups and render bundles that hold the texture.
    private var views = ImplLinkList<TextureViewImpl>()
    private var bindGroupHolders = ImplLinkList<BindGroupImpl>()
    private var renderBundleHolders = ImplLinkList<RenderBundleImpl>()
    // Declared last, so that the device outlives the rest of the texture.
    let deviceImpl: DeviceImpl

    fileprivate init(
        texture: (any MTLTexture)?,
        parameters: WebGPU.Metal.TextureParameters?,
        viewFormats: [WebGPU.TextureFormat],
        deviceImpl: DeviceImpl
    ) {
        self.deviceImpl = deviceImpl
        self.backingTexture = texture
        self.backingWidth = parameters?.width ?? 0
        self.backingHeight = parameters?.height ?? 0
        self.backingDepthOrArrayLayers = parameters?.depthOrArrayLayers ?? 0
        self.backingMipLevelCount = parameters?.mipLevelCount ?? 0
        self.backingSampleCount = parameters?.sampleCount ?? 0
        self.backingDimension = parameters?.dimension ?? ._2d
        self.backingFormat = parameters?.format
        self.backingUsage = parameters?.usage ?? 0
        self.viewFormats = viewFormats
        let layers = parameters?.dimension == ._2d ? Int(parameters?.depthOrArrayLayers ?? 0) : 1
        let regionCount = parameters.map { Int($0.mipLevelCount) * layers * Self.initAspectCount($0.format) } ?? 0
        self.initState = TextureInitState(regionCount: regionCount)
    }

    deinit {
        linkSlot.end()
    }

    var link: ImplLink<TextureImpl> {
        linkSlot.link(for: self)
    }

    private static func initAspectCount(_ format: WebGPU.TextureFormat) -> Int {
        containsDepthAspect(format) && containsStencilAspect(format) ? 2 : 1
    }

    // An invalid texture reports an arbitrary format, which only the validation that rejects it sees.
    var formatOrDefault: WebGPU.TextureFormat {
        backingFormat ?? .Rgba8unorm
    }

    func width() -> UInt32 {
        backingWidth
    }

    func height() -> UInt32 {
        backingHeight
    }

    func depthOrArrayLayers() -> UInt32 {
        backingDepthOrArrayLayers
    }

    func mipLevelCount() -> UInt32 {
        backingMipLevelCount
    }

    func sampleCount() -> UInt32 {
        backingSampleCount
    }

    // The WebGPU enums and the usage OptionSet as raw values.
    func dimension() -> UInt8 {
        backingDimension.rawValue
    }

    func format() -> UInt8 {
        formatOrDefault.rawValue
    }

    func hasFormat() -> Bool {
        backingFormat != nil
    }

    func usage() -> UInt8 {
        backingUsage
    }

    func arrayLayerCount() -> UInt32 {
        // https://gpuweb.github.io/gpuweb/#abstract-opdef-array-layer-count

        switch backingDimension {
        case ._1d:
            return 1
        case ._2d:
            return backingDepthOrArrayLayers
        case ._3d:
            return 1
        @unknown default:
            preconditionFailure("unknown WebGPU::TextureDimension")
        }
    }

    func is2DTexture() -> Bool {
        backingDimension == ._2d
    }

    func is2DArrayTexture() -> Bool {
        is2DTexture() && arrayLayerCount() > 1
    }

    func is3DTexture() -> Bool {
        backingDimension == ._3d
    }

    // &>> masks the shift amount for mip levels of 32 and above, as arm64 does.
    func logicalMiplevelSpecificTextureExtent(_ mipLevel: UInt32) -> TextureExtent {
        // https://gpuweb.github.io/gpuweb/#abstract-opdef-logical-miplevel-specific-texture-extent

        switch backingDimension {
        case ._1d:
            return TextureExtent(
                width: max(1, backingWidth &>> mipLevel),
                height: 1,
                depthOrArrayLayers: backingDepthOrArrayLayers
            )
        case ._2d:
            return TextureExtent(
                width: max(1, backingWidth &>> mipLevel),
                height: max(1, backingHeight &>> mipLevel),
                depthOrArrayLayers: backingDepthOrArrayLayers
            )
        case ._3d:
            return TextureExtent(
                width: max(1, backingWidth &>> mipLevel),
                height: max(1, backingHeight &>> mipLevel),
                depthOrArrayLayers: max(1, backingDepthOrArrayLayers &>> mipLevel)
            )
        @unknown default:
            preconditionFailure("unknown WebGPU::TextureDimension")
        }
    }

    func physicalMiplevelSpecificTextureExtent(_ mipLevel: UInt32) -> TextureExtent {
        // https://gpuweb.github.io/gpuweb/#abstract-opdef-physical-miplevel-specific-texture-extent
        physicalTextureExtent(backingDimension, formatOrDefault, logicalMiplevelSpecificTextureExtent(mipLevel))
    }

    func texture() -> (any MTLTexture)? {
        backingTexture
    }

    public func isValid() -> Bool {
        destroyed || backingTexture != nil
    }

    func isDestroyed() -> Bool {
        destroyed
    }

    func isCanvasBacking() -> Bool {
        canvasBacking
    }

    func makeCanvasBacking() {
        canvasBacking = true
    }

    func setLabel(_ label: WTF.String) {
        backingTexture?.label = stringNilIfEmpty(label)
    }

    // Texture::destroy, and Device::destroy for each texture it made. A canvas backing keeps its Metal texture, so its
    // views, bind groups, render bundles and encoders are left as they are.
    func destroyAndReleaseHolders() {
        // https://gpuweb.github.io/gpuweb/#dom-gputexture-destroy
        if !canvasBacking {
            backingTexture = deviceImpl.placeholderTexture(isDepthOrStencilFormat(formatOrDefault))
        }
        destroyed = true

        if !canvasBacking {
            let liveViews = views.values
            for view in liveViews {
                view.destroy()
            }
            let bindGroups = bindGroupHolders.values
            for bindGroup in bindGroups {
                bindGroup.releaseDestroyedResources()
            }
            bindGroupHolders.removeAll()
            let renderBundles = renderBundleHolders.values
            for renderBundle in renderBundles {
                renderBundle.releaseDestroyedResources()
            }
            renderBundleHolders.removeAll()
            for encoder in tracking.takeLive() {
                encoder.makeSubmitInvalid(nil)
            }
        }

        tracking.removeAll()
        views.removeAll()
    }

    // MARK: Encoder tracking

    // Texture::setCommandEncoder. Each encoder holds the texture once, from the first use until its clearTracking().
    func setCommandEncoder(_ encoder: CommandEncoderImpl) {
        if !tracking.contains(encoder) && tracking.add(encoder) {
            encoder.trackTexture(self)
        }
        encoder.addTexture(backingTexture)
        if let state = canvasState.first, let event = state.sharedEvent {
            encoder.setSharedEvent(event, state.sharedEventSignalValue)
        }
        if !canvasBacking && destroyed {
            encoder.makeSubmitInvalid(nil)
        }
    }

    /// A destroyed texture has nothing to release later, so it records no holder.
    func addBindGroupHolder(_ bindGroup: BindGroupImpl) {
        if destroyed {
            return
        }
        bindGroupHolders.add(bindGroup)
    }

    func addRenderBundleHolder(_ renderBundle: RenderBundleImpl) {
        if destroyed {
            return
        }
        renderBundleHolders.add(renderBundle)
    }

    func addView(_ view: TextureViewImpl) {
        views.add(view)
    }

    func waitForCommandBufferCompletion() -> Bool {
        var result = true
        let encoders = tracking
        encoders.forEachLive { encoder in
            result = encoder.waitForCommandBufferCompletion() && result
        }
        return result
    }

    // Each call is the canvas handing this backing out for a new frame, either directly or through the
    // undestroy the Web process sends in place of the round trip it elides once the render buffers wrap
    // around. A frame starts as transparent black, so forget having cleared it, and the cost recorded
    // against the frame that is over does not belong to the one starting now.
    func recreateIfNeeded() {
        guard canvasBacking else {
            return
        }
        destroyed = false
        initState.removeAll()
        resetGPUFrameCost()
    }

    // MARK: Lazy zero-initialization

    var isFullyInitialized: Bool {
        destroyed || initState.isFull
    }

    func isInitialized(_ region: InitRegion) -> Bool {
        destroyed || initState.isFull || initState.contains(region.bit)
    }

    /// The only way to mark a region initialized.
    ///
    /// A CommitToken exists only inside QueueImpl, while it commits a command buffer or right after it encoded a zero
    /// fill or a write on its staging command buffer or performed a write.
    func markInitialized(_ region: InitRegion, _ token: borrowing CommitToken) {
        initState.insert(region.bit)
    }

    /// Needs no token: an uninitialized region only makes later readers zero-fill it.
    func markUninitialized(_ region: InitRegion) {
        initState.remove(region.bit)
    }

    func didRecordDiscard() {
        pendingDiscards += 1
    }

    func didSettleDiscard() {
        pendingDiscards -= 1
    }

    /// The regions of (mipLevel, layer) that `aspect` selects.
    ///
    /// A 3D texture has one region per mip level, whatever the layer; a combined depth-stencil format has one per aspect.
    func initRegions(mipLevel: UInt32, layer: UInt32, aspect: WebGPU.TextureAspect) -> InitRegions {
        let is2D = backingDimension == ._2d
        let layers = is2D ? Int(backingDepthOrArrayLayers) : 1
        let layerIndex = is2D ? Int(layer) : 0
        guard let format = backingFormat, Self.initAspectCount(format) == 2 else {
            return InitRegions(first: InitRegion(bit: Int(mipLevel) * layers + layerIndex), second: nil)
        }
        let base = (Int(mipLevel) * layers + layerIndex) * 2
        switch aspect {
        case .DepthOnly:
            return InitRegions(first: InitRegion(bit: base), second: nil)
        case .StencilOnly:
            return InitRegions(first: InitRegion(bit: base + 1), second: nil)
        default:
            return InitRegions(first: InitRegion(bit: base), second: InitRegion(bit: base + 1))
        }
    }

    /// Which aspect `region` is, for its zero fill.
    func initAspect(_ region: InitRegion) -> InitAspect {
        guard let format = backingFormat, Self.initAspectCount(format) == 2 else {
            return .color
        }
        return region.bit & 1 == 0 ? .depth : .stencil
    }

    /// The (mip level, array layer) `region` is in; the layer is 0 for a 3D mip level.
    func initSubresource(_ region: InitRegion) -> (mipLevel: UInt32, layer: UInt32) {
        let perSubresource = region.bit / (backingFormat.map { Self.initAspectCount($0) } ?? 1)
        let layers = backingDimension == ._2d ? max(Int(backingDepthOrArrayLayers), 1) : 1
        return (UInt32(truncatingIfNeeded: perSubresource / layers), UInt32(truncatingIfNeeded: perSubresource % layers))
    }

    /// Memoryless: never stored, so never zero-filled.
    var isTransient: Bool {
        textureUsageContains(backingUsage, .Transient)
    }

    /// Zero-filled with an empty render pass, which needs no zeroed source buffer (big multisampled attachments); a 3D
    /// mip level, or a texture that cannot be a render target, is zero-filled with a blit instead.
    var prefersRenderZeroFill: Bool {
        textureUsageContains(backingUsage, .RenderAttachment) && backingDimension != ._3d
    }

    /// Applies `change` to the canvas state, making it first unless `change` would leave a new one as it is.
    private func modifyCanvasState(unlessDefault isDefault: Bool, _ change: (inout TextureCanvasState) -> Void) {
        if canvasState.isEmpty {
            if isDefault {
                return
            }
            canvasState.append(TextureCanvasState())
        }
        change(&canvasState[0])
    }

    func recordGPUExecutionWindow(_ startTime: Double, _ endTime: Double) {
        let duration = endTime - startTime
        if duration <= 0 {
            return
        }
        modifyCanvasState(unlessDefault: false) { $0.gpuFrameCost = max($0.gpuFrameCost, duration) }
    }

    func gpuFrameCostSeconds() -> Double {
        canvasState.first?.gpuFrameCost ?? 0
    }

    func resetGPUFrameCost() {
        modifyCanvasState(unlessDefault: true) { $0.gpuFrameCost = 0 }
    }

    func updateCompletionEvent(_ event: (any MTLSharedEvent)?, _ signalValue: UInt64) {
        modifyCanvasState(unlessDefault: event == nil && signalValue == 0) {
            $0.sharedEvent = event
            $0.sharedEventSignalValue = signalValue
        }
    }

    func sharedEvent() -> (any MTLSharedEvent)? {
        canvasState.first?.sharedEvent
    }

    func sharedEventSignalValue() -> UInt64 {
        canvasState.first?.sharedEventSignalValue ?? 0
    }

    func setRasterizationRateMaps(_ left: (any MTLRasterizationRateMap)?, _ right: (any MTLRasterizationRateMap)?) {
        modifyCanvasState(unlessDefault: left == nil && right == nil) {
            $0.leftRasterizationMap = left
            $0.rightRasterizationMap = right
        }
    }

    func rasterizationMapForSlice(_ slice: UInt32) -> (any MTLRasterizationRateMap)? {
        guard let state = canvasState.first else {
            return nil
        }
        return slice != 0 ? state.rightRasterizationMap : state.leftRasterizationMap
    }

    // createView, for a Swift caller.
    func createView(_ descriptor: GPUTextureViewDescriptor, label: WTF.String) -> TextureViewImpl {
        createView(descriptor.parameters, label)
    }

    // Every view holds this texture. Returns an invalid view (no descriptor) on failure; the texture records only the
    // views that have one. A view's device is its texture's.
    func createView(_ descriptor: WebGPU.Metal.TextureViewDescriptorParameters, _ label: WTF.String) -> TextureViewImpl {
        if destroyed {
            return invalidView()
        }

        // https://gpuweb.github.io/gpuweb/#dom-gputexture-createview

        guard let mtlTexture = backingTexture else {
            deviceImpl.generateAValidationError("GPUTexture.createView: texture is not valid")
            return invalidView()
        }

        guard let resolved = resolveTextureViewDescriptorDefaults(descriptor, mtlTexture) else {
            deviceImpl.generateAValidationError("Validation failure in GPUTexture.createView: descriptor could not be resolved")
            return invalidView()
        }

        if let error = errorValidatingTextureViewCreation(resolved) {
            deviceImpl.generateAValidationError(error)
            return invalidView()
        }

        let pixelFormat = texturePixelFormat(resolved.format)
        if pixelFormat == .invalid {
            deviceImpl.generateAValidationError("GPUTexture.createView: invalid texture format")
            return invalidView()
        }

        if descriptor.usage != 0 && !textureUsageContainsAll(backingUsage, descriptor.usage) {
            deviceImpl.generateAValidationError(
                "GPUTexture.createView: when the view's usage(\(apiTextureUsage(descriptor.usage))) is specified it must be a subset of the Texture's usage(\(apiTextureUsage(backingUsage)))"
            )
            return invalidView()
        }

        let textureType: MTLTextureType
        switch resolved.dimension {
        case ._1d:
            textureType = resolved.arrayLayerCount == 1 ? .type1D : .type1DArray
        case ._2d:
            textureType = backingSampleCount > 1 ? .type2DMultisample : .type2D
        case ._2dArray:
            if backingSampleCount > 1 {
                #if WTF_PLATFORM_WATCHOS || WTF_PLATFORM_APPLETV
                return invalidView()
                #else
                textureType = .type2DMultisampleArray
                #endif
            } else {
                textureType = .type2DArray
            }
        case .Cube:
            textureType = .typeCube
        case .CubeArray:
            textureType = .typeCubeArray
        case ._3d:
            textureType = .type3D
        @unknown default:
            preconditionFailure("unknown WebGPU::TextureViewDimension")
        }

        let levels = Int(resolved.baseMipLevel)..<(Int(resolved.baseMipLevel) + Int(resolved.mipLevelCount))
        let slices = Int(resolved.baseArrayLayer)..<(Int(resolved.baseArrayLayer) + Int(resolved.arrayLayerCount))
        let viewPixelFormat = resolvedPixelFormat(pixelFormat, mtlTexture.pixelFormat)
        let isMemoryless = mtlTexture.storageMode == .memoryless

        guard
            let view = isMemoryless
                ? mtlTexture
                : mtlTexture.makeTextureView(pixelFormat: viewPixelFormat, textureType: textureType, levels: levels, slices: slices)
        else {
            return invalidView()
        }

        view.label = stringNilIfEmpty(label) ?? ""
        if view.label?.isEmpty ?? true {
            view.label = mtlTexture.label
        }

        // A swizzled MTLTexture loses the render target and shader write usages of the texture it is a
        // view of, so it cannot stand in for the one above: it is a second view, used only where a
        // shader reads the texture. A memoryless texture is a render attachment and nothing else, so it
        // never needs one.
        var sampledTexture: (any MTLTexture)?
        if textureUsageContains(resolved.usage, .TextureBinding) && !isMemoryless {
            if let swizzle = composedSwizzleChannels(resolved, deviceImpl) {
                guard
                    let swizzled = mtlTexture.makeTextureView(
                        pixelFormat: viewPixelFormat,
                        textureType: textureType,
                        levels: levels,
                        slices: slices,
                        swizzle: swizzle
                    )
                else {
                    return invalidView()
                }

                swizzled.label = view.label
                sampledTexture = swizzled
            }
        }

        let viewImpl = TextureViewImpl(
            texture: view,
            sampledTexture: sampledTexture,
            parentImpl: self,
            descriptor: resolved
        )
        addView(viewImpl)
        return viewImpl
    }

    private func invalidView() -> TextureViewImpl {
        TextureViewImpl(texture: nil, sampledTexture: nil, parentImpl: self, descriptor: nil)
    }

    private func resolveTextureViewDescriptorDefaults(
        _ descriptor: WebGPU.Metal.TextureViewDescriptorParameters,
        _ mtlTexture: any MTLTexture
    ) -> ResolvedTextureViewDescriptor? {
        // https://gpuweb.github.io/gpuweb/#abstract-opdef-resolving-gputextureviewdescriptor-defaults

        // Only invalid textures have no format, and createView() does not resolve their views.
        guard let textureFormat = backingFormat else {
            return nil
        }

        let format = descriptor.hasFormat ? descriptor.format : resolveTextureFormat(textureFormat, descriptor.aspect) ?? textureFormat

        var mipLevelCount = descriptor.mipLevelCount
        if !descriptor.hasMipLevelCount {
            let (remainingMipLevelCount, overflow) = backingMipLevelCount.subtractingReportingOverflow(descriptor.baseMipLevel)
            if overflow {
                return nil
            }
            mipLevelCount = remainingMipLevelCount
        }

        var dimension = descriptor.dimension
        if !descriptor.hasDimension {
            switch mtlTexture.textureType {
            case .type1D:
                dimension = ._1d
            case .type1DArray:
                preconditionFailure("a 1D array texture has no WebGPU view dimension")
            case .type2D, .type2DMultisample:
                dimension = ._2d
            case .type2DArray, .type2DMultisampleArray:
                dimension = ._2dArray
            case .typeCube:
                dimension = .Cube
            case .typeCubeArray:
                dimension = .CubeArray
            case .type3D:
                dimension = ._3d
            default:
                assertionFailure()
                return nil
            }
        }

        var arrayLayerCount = descriptor.arrayLayerCount
        if !descriptor.hasArrayLayerCount {
            switch dimension {
            case ._1d, ._2d, ._3d:
                arrayLayerCount = 1
            case .Cube:
                arrayLayerCount = 6
            case ._2dArray, .CubeArray:
                let (remainingArrayLayerCount, overflow) = backingDepthOrArrayLayers.subtractingReportingOverflow(descriptor.baseArrayLayer)
                if overflow {
                    return nil
                }
                arrayLayerCount = remainingArrayLayerCount
            @unknown default:
                preconditionFailure("unknown WebGPU::TextureViewDimension")
            }
        }

        return ResolvedTextureViewDescriptor(
            format: format,
            dimension: dimension,
            baseMipLevel: descriptor.baseMipLevel,
            mipLevelCount: mipLevelCount,
            baseArrayLayer: descriptor.baseArrayLayer,
            arrayLayerCount: arrayLayerCount,
            aspect: descriptor.aspect,
            // An empty usage means the view inherits every usage of the texture it is a view of.
            usage: descriptor.usage == 0 ? backingUsage : descriptor.usage,
            swizzle: descriptor.swizzle
        )
    }

    private func errorValidatingTextureViewCreation(_ descriptor: ResolvedTextureViewDescriptor) -> String? {
        func errorString(_ message: String) -> String {
            "GPUTexture.createView: " + message
        }
        assert(isValid())

        if descriptor.aspect == .All {
            if descriptor.format != backingFormat && !viewFormats.contains(descriptor.format) {
                return errorString("aspect == all and (format != parentTexture's format and !viewFormats.contains(parentTexture's format))")
            }
        } else {
            if descriptor.format != resolveTextureFormat(formatOrDefault, descriptor.aspect) {
                return errorString("aspect == All and (format != resolveTextureFormat(format, aspect))")
            }
        }

        // The view's usage narrows the texture's, and each usage it keeps has to be supported by the
        // view's own format rather than by the format of the texture it is a view of.
        if !textureUsageContainsAll(backingUsage, descriptor.usage) {
            return errorString(
                "view usage(\(apiTextureUsage(descriptor.usage))) is not a subset of the texture's usage(\(apiTextureUsage(backingUsage)))"
            )
        }

        // Transient textures never leave tile memory, so a view of one cannot drop any of the
        // texture's usages. A zero usage has already been resolved to the texture's usage above.
        if textureUsageContains(backingUsage, .Transient) && descriptor.usage != backingUsage {
            return errorString(
                "view usage(\(apiTextureUsage(descriptor.usage))) must be either zero or exactly the transient texture's usage(\(apiTextureUsage(backingUsage)))"
            )
        }

        if !descriptor.swizzleIsIdentity && !deviceImpl.hasFeature(WebGPU.FeatureName.TextureComponentSwizzle) {
            return errorString("swizzle is not \"rgba\" and the texture-component-swizzle feature is not enabled")
        }

        let format = descriptor.format

        if textureUsageContains(descriptor.usage, .StorageBinding) && !hasStorageBindingCapability(format, deviceImpl, .WriteOnly) {
            return errorString("view usage contains storage binding and the view's format does not support it")
        }

        if textureUsageContains(descriptor.usage, .RenderAttachment) && !isDepthOrStencilFormat(format)
            && !isColorRenderableFormat(format, deviceImpl)
        {
            return errorString("view usage contains render attachment and the view's format is not color renderable")
        }

        if descriptor.mipLevelCount == 0 {
            return errorString("!mipLevelCount")
        }

        let (endMipLevel, endMipLevelOverflowed) = descriptor.baseMipLevel.addingReportingOverflow(descriptor.mipLevelCount)
        if endMipLevelOverflowed || endMipLevel > backingMipLevelCount {
            return errorString("endMipLevel is not valid")
        }

        if descriptor.arrayLayerCount == 0 {
            return errorString("!arrayLayerCount")
        }

        // An overflowed sum reports UINT32_MAX, as errorValidatingTextureCopyRange does.
        let (endArrayLayer, endArrayLayerOverflowed) = descriptor.baseArrayLayer.addingReportingOverflow(descriptor.arrayLayerCount)
        if endArrayLayerOverflowed || endArrayLayer > arrayLayerCount() {
            return errorString(
                "endArrayLayer(\(endArrayLayerOverflowed ? UInt32.max : endArrayLayer)) is not valid. Base texture array count is \(arrayLayerCount())"
            )
        }

        if backingSampleCount > 1 {
            if descriptor.dimension != ._2d {
                return errorString("sampleCount > 1 and dimension != 2D")
            }
        }

        switch descriptor.dimension {
        case ._1d:
            if backingDimension != ._1d {
                return errorString("attempting to create 1D texture view from non-1D base texture")
            }

            if descriptor.arrayLayerCount != 1 {
                return errorString("attempting to create 1D texture view with array layers")
            }
        case ._2d:
            if backingDimension != ._2d {
                return errorString("attempting to create 2D texture view from non-2D base texture")
            }

            if descriptor.arrayLayerCount != 1 {
                return errorString("attempting to create 2D texture view with array layers")
            }
        case ._2dArray:
            if backingDimension != ._2d {
                return errorString("attempting to create 2D texture array view from non-2D parent texture")
            }
        case .Cube:
            if backingDimension != ._2d {
                return errorString("attempting to create cube texture view from non-2D parent texture")
            }

            if descriptor.arrayLayerCount != 6 {
                return errorString("attempting to create cube texture view with arrayLayerCount != 6")
            }

            if backingWidth != backingHeight {
                return errorString("attempting to create cube texture view from non-square parent texture")
            }
        case .CubeArray:
            if backingDimension != ._2d {
                return errorString("attempting to create cube array texture view from non-2D parent texture")
            }

            if descriptor.arrayLayerCount % 6 != 0 {
                return errorString("attempting to create cube array texture view with (arrayLayerCount % 6) != 0")
            }

            if backingWidth != backingHeight {
                return errorString("attempting to create cube array texture view from non-square parent texture")
            }
        case ._3d:
            if backingDimension != ._3d {
                return errorString("attempting to create 3D texture view from non-3D parent texture")
            }

            if descriptor.arrayLayerCount != 1 {
                return errorString("attempting to create 3D texture view with array layers")
            }
        @unknown default:
            break
        }
        return nil
    }
}

private func resolvedPixelFormat(_ viewPixelFormat: MTLPixelFormat, _ sourcePixelFormat: MTLPixelFormat) -> MTLPixelFormat {
    switch viewPixelFormat {
    case .stencil8:
        return sourcePixelFormat == .depth32Float_stencil8 ? .x32_stencil8 : sourcePixelFormat
    case .depth32Float:
        return sourcePixelFormat
    default:
        return viewPixelFormat
    }
}

// Resolves one WebGPU component against the base swizzle the format itself imposes, which is the
// mapping from a logical channel name to what the hardware actually reads for it.
private func composeComponentSwizzle(_ component: WebGPU.ComponentSwizzle, _ base: MTLTextureSwizzleChannels) -> MTLTextureSwizzle {
    switch component {
    case .R:
        return base.red
    case .G:
        return base.green
    case .B:
        return base.blue
    case .A:
        return base.alpha
    case .Zero:
        return .zero
    case .One:
        return .one
    @unknown default:
        preconditionFailure("unknown WebGPU::ComponentSwizzle")
    }
}

// Returns the swizzle a shader has to read this view through, or nil when that is the one
// Metal applies anyway and no second MTLTexture is needed.
private func composedSwizzleChannels(
    _ descriptor: ResolvedTextureViewDescriptor,
    _ deviceImpl: DeviceImpl
) -> MTLTextureSwizzleChannels? {
    var base = MTLTextureSwizzleChannels(red: .red, green: .green, blue: .blue, alpha: .alpha)

    // https://gpuweb.github.io/gpuweb/#reading-depth-stencil
    // A depth or stencil aspect has to read as (V, 0, 0, 1) once the feature is enabled. Metal
    // reads it as (V, V, V, 1) on its own, so the zeroes have to be asked for.
    if isDepthOrStencilFormat(descriptor.format) && deviceImpl.hasFeature(WebGPU.FeatureName.TextureComponentSwizzle) {
        base = MTLTextureSwizzleChannels(red: .red, green: .zero, blue: .zero, alpha: .one)
    }

    let channels = MTLTextureSwizzleChannels(
        red: composeComponentSwizzle(descriptor.swizzle.r, base),
        green: composeComponentSwizzle(descriptor.swizzle.g, base),
        blue: composeComponentSwizzle(descriptor.swizzle.b, base),
        alpha: composeComponentSwizzle(descriptor.swizzle.a, base)
    )

    if channels.red == .red && channels.green == .green && channels.blue == .blue && channels.alpha == .alpha {
        return nil
    }

    return channels
}

// WTF::fastLog2: the base-2 logarithm rounded up.
private func roundedUpLog2(_ value: UInt32) -> UInt32 {
    if value == 0 {
        return 0
    }
    var log2 = UInt32(UInt32.bitWidth - 1 - value.leadingZeroBitCount)
    if value & (value - 1) != 0 {
        log2 += 1
    }
    return log2
}

private func maximumMiplevelCount(
    _ dimension: WebGPU.TextureDimension,
    _ width: UInt32,
    _ height: UInt32,
    _ depthOrArrayLayers: UInt32
) -> UInt32 {
    // https://gpuweb.github.io/gpuweb/#abstract-opdef-maximum-miplevel-count

    var m: UInt32 = 0

    switch dimension {
    case ._1d:
        return 1
    case ._2d:
        m = max(width, height)
    case ._3d:
        m = max(max(width, height), depthOrArrayLayers)
    @unknown default:
        break
    }

    if m.nonzeroBitCount == 1 {
        return roundedUpLog2(m) + 1
    }
    return roundedUpLog2(m)
}

private func storageMode(
    _ deviceHasUnifiedMemory: Bool,
    _ supportsNonPrivateDepthStencilTextures: Bool,
    _ supportsMemorylessTextures: Bool,
    _ usage: UInt8
) -> MTLStorageMode {
    if textureUsageContains(usage, .Transient) {
        return supportsMemorylessTextures ? .memoryless : .private
    }

    // FIXME: only perform this check if the texture is a depth/stencil texture.
    if !supportsNonPrivateDepthStencilTextures {
        return .private
    }

    if deviceHasUnifiedMemory {
        return .shared
    }

    #if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
    return managedTextureStorageMode
    #else
    return .private
    #endif
}

#if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "Macs without unified memory still need managed storage")
#endif
private let managedTextureStorageMode = MTLStorageMode.managed
#endif

private func textureCreationError(
    _ deviceImpl: DeviceImpl,
    _ descriptor: WebGPU.Metal.TextureParameters,
    _ viewFormats: [WebGPU.TextureFormat]
) -> String? {
    if !deviceImpl.isValid() {
        return "createTexture: Device is not valid"
    }

    if descriptor.usage == 0 {
        return "createTexture: descriptor.usage is zero"
    }

    if textureUsageContains(descriptor.usage, .Invalid) {
        return "createTexture: descriptor.usage contains a usage bit that is not defined"
    }

    if descriptor.width == 0 || descriptor.height == 0 || descriptor.depthOrArrayLayers == 0 {
        return "createTexture: descriptor.size.width/height/depth is zero"
    }

    if descriptor.mipLevelCount == 0 {
        return "createTexture: descriptor.mipLevelCount is zero"
    }

    if descriptor.sampleCount != 1 && descriptor.sampleCount != 4 {
        return "createTexture: descriptor.sampleCount is neither 1 nor 4"
    }

    let format = descriptor.format

    switch descriptor.dimension {
    case ._1d:
        if descriptor.width > deviceImpl.capabilities.limits.maxTextureDimension1D {
            return "createTexture: descriptor.size.width is greater than limits().maxTextureDimension1D"
        }

        if descriptor.height != 1 {
            return "createTexture: descriptor.size.height != 1"
        }

        if descriptor.depthOrArrayLayers != 1 {
            return "createTexture: descriptor.size.depthOrArrayLayers != 1"
        }

        if descriptor.sampleCount != 1 {
            return "createTexture: descriptor.sampleCount != 1"
        }

        if isCompressedFormat(format) || isDepthOrStencilFormat(format) {
            return "createTexture: descriptor.format is compressed or a depth stencil format"
        }
    case ._2d:
        let limits = deviceImpl.capabilities.limits
        if descriptor.width > limits.maxTextureDimension2D {
            return "createTexture: descriptor.size.width is greater than limits().maxTextureDimension2D"
        }

        if descriptor.height > limits.maxTextureDimension2D {
            return "createTexture: descriptor.size.height is greater than limits().maxTextureDimension2D"
        }

        if descriptor.depthOrArrayLayers > limits.maxTextureArrayLayers {
            return "createTexture: descriptor.size.depthOrArrayLayers > limits().maxTextureArrayLayers"
        }
    case ._3d:
        let limits = deviceImpl.capabilities.limits
        if descriptor.width > limits.maxTextureDimension3D {
            return "createTexture: descriptor.size.width > limits().maxTextureDimension3D"
        }

        if descriptor.height > limits.maxTextureDimension3D {
            return "createTexture: descriptor.size.height > limits().maxTextureDimension3D"
        }

        if descriptor.depthOrArrayLayers > limits.maxTextureDimension3D {
            return "createTexture: descriptor.size.depthOrArrayLayers > limits().maxTextureDimension3D"
        }

        if descriptor.sampleCount != 1 {
            return "createTexture: descriptor.sampleCount != 1"
        }

        if let compressedFormatType = compressedFormatType(format) {
            switch compressedFormatType {
            case .bc:
                if !deviceImpl.hasFeature(WebGPU.FeatureName.TextureCompressionBcSliced3d) {
                    return "createTexture: descriptor.format is a compressed format but BC sliced 3D extension is not enabled"
                }
            case .astc:
                if !deviceImpl.hasFeature(WebGPU.FeatureName.TextureCompressionAstcSliced3d) {
                    return "createTexture: descriptor.format is a compressed format but ASTC sliced 3D extension is not enabled"
                }
            case .etc:
                return "createTexture: descriptor.format is a ETC compressed format which is not supported for 3D textures"
            }
        }
        if isDepthOrStencilFormat(format) {
            return "createTexture: descriptor.format is a depth stencil format, this is not allowed for 3D textures"
        }
    @unknown default:
        break
    }

    if descriptor.width % texelBlockWidth(format) != 0 {
        return "createTexture: descriptor.size.width % Texture::texelBlockWidth(descriptor.format)"
    }

    if descriptor.height % texelBlockHeight(format) != 0 {
        return "createTexture: descriptor.size.height % Texture::texelBlockHeight(descriptor.format)"
    }

    if descriptor.sampleCount > 1 {
        if descriptor.mipLevelCount != 1 {
            return "createTexture: descriptor.sampleCount > 1 and descriptor.mipLevelCount != 1"
        }

        if descriptor.depthOrArrayLayers != 1 {
            return "createTexture: descriptor.sampleCount > 1 and descriptor.size.depthOrArrayLayers != 1"
        }

        if textureUsageContains(descriptor.usage, .StorageBinding) || !textureUsageContains(descriptor.usage, .RenderAttachment) {
            return
                "createTexture: descriptor.sampleCount > 1 and (descriptor.usage & WGPUTextureUsage_StorageBinding) || !(descriptor.usage & WGPUTextureUsage_RenderAttachment)"
        }

        if !isRenderableFormat(format, deviceImpl) {
            return "createTexture: descriptor.sampleCount > 1 and !isRenderableFormat(descriptor.format, *this)"
        }

        if !supportsMultisampling(format, deviceImpl) {
            return "createTexture: descriptor.sampleCount > 1 and !supportsMultisampling(descriptor.format, *this)"
        }
    }

    if descriptor.mipLevelCount
        > maximumMiplevelCount(descriptor.dimension, descriptor.width, descriptor.height, descriptor.depthOrArrayLayers)
    {
        return "createTexture: descriptor.mipLevelCount > maximumMiplevelCount(descriptor.dimension, descriptor.size)"
    }

    if textureUsageContains(descriptor.usage, .RenderAttachment) {
        if !isRenderableFormat(format, deviceImpl) {
            return "createTexture: descriptor.usage & WGPUTextureUsage_RenderAttachment && !isRenderableFormat(descriptor.format, *this)"
        }

        if descriptor.dimension == ._1d {
            return
                "createTexture: descriptor.usage & WGPUTextureUsage_RenderAttachment && descriptor.dimension == WebGPU::TextureDimension::_1d"
        }
    }

    if textureUsageContains(descriptor.usage, .StorageBinding) {
        if !hasStorageBindingCapability(format, deviceImpl) {
            return "createTexture: descriptor.usage & WGPUTextureUsage_StorageBinding && !hasStorageBindingCapability(descriptor.format)"
        }
    }

    for viewFormat in viewFormats where !textureViewFormatCompatible(format, viewFormat) {
        return "createTexture: !textureViewFormatCompatible(descriptor.format, viewFormat)"
    }

    if textureUsageContains(descriptor.usage, .Transient) {
        if descriptor.usage != WebGPU.TextureUsage.Transient.rawValue | WebGPU.TextureUsage.RenderAttachment.rawValue {
            return "createTexture: descriptor usage must be exactly Transient | Render_Attachment when using Transient textures"
        }
        if descriptor.dimension != ._2d {
            return "createTexture: descriptor dimension must be 2D when using Transient textures"
        }
        if descriptor.mipLevelCount != 1 {
            return "createTexture: descriptor mipLevelCount must be 1 when using Transient textures"
        }

        if descriptor.depthOrArrayLayers != 1 {
            return "createTexture: descriptor.size.depthOrArrayLayers must be 1 when using Transient textures"
        }

        if !viewFormats.isEmpty {
            return "createTexture: descriptor.viewFormats must be empty when using Transient textures"
        }
    }

    return nil
}

private func copyViewFormats(_ viewFormats: borrowing WebGPU.Metal.TextureFormatsView) -> [WebGPU.TextureFormat] {
    let formats: Span<WebGPU.TextureFormat> = viewFormats.span()
    var result: [WebGPU.TextureFormat] = []
    result.reserveCapacity(formats.count)
    for index in formats.indices {
        result.append(formats[index])
    }
    return result
}

@_spi(WebKitGPU)
public typealias TextureReference = TextureImpl

@_spi(WebKitGPU)
extension TextureImpl {

    // https://gpuweb.github.io/gpuweb/#dom-gputexture-destroy
    public func destroy() {
        destroyAndReleaseHolders()
    }

    public func undestroy() {
        recreateIfNeeded()
    }

    public func setLabel(_ label: Swift.String?) {
        setLabel(WTF.String(label ?? ""))
    }
}

// https://gpuweb.github.io/gpuweb/#dictdef-gputexturedescriptor, without its label.
@_spi(WebKitGPU)
public struct GPUTextureDescriptor {
    // The bits of OptionSet<WebGPU::TextureUsage>.
    public var usage: UInt8 = 0
    public var dimension = WebGPU.TextureDimension._2d
    public var size = WebGPU.Extent3D()
    public var format = WebGPU.TextureFormat.R8unorm
    public var mipLevelCount: UInt32 = 1
    public var sampleCount: UInt32 = 1
    public var viewFormats: [WebGPU.TextureFormat] = []

    public init() {
    }

    var parameters: WebGPU.Metal.TextureParameters {
        var parameters = WebGPU.Metal.TextureParameters()
        parameters.width = size.width
        parameters.height = size.height
        parameters.depthOrArrayLayers = size.depthOrArrayLayers
        parameters.mipLevelCount = mipLevelCount
        parameters.sampleCount = sampleCount
        parameters.dimension = dimension
        parameters.format = format
        parameters.usage = usage
        return parameters
    }
}

func createTextureImpl(_ deviceImpl: DeviceImpl, _ descriptor: GPUTextureDescriptor, label: WTF.String) -> TextureImpl {
    createTextureImpl(
        deviceImpl,
        descriptor.parameters,
        viewFormats: descriptor.viewFormats,
        label,
        hasUnifiedMemory(deviceImpl),
        deviceImpl.supportsNonPrivateDepthStencilTextures(),
        deviceImpl.supportsMemorylessTextures()
    )
}

// Device::createTexture. Returns an invalid texture on failure; the valid ones are recorded in DeviceImpl.
func createTextureImpl(
    _ deviceImpl: DeviceImpl,
    _ descriptor: WebGPU.Metal.TextureParameters,
    _ viewFormatsView: borrowing WebGPU.Metal.TextureFormatsView,
    _ label: WTF.String,
    _ hasUnifiedMemory: Bool,
    _ supportsNonPrivateDepthStencilTextures: Bool,
    _ supportsMemorylessTextures: Bool
) -> TextureImpl {
    createTextureImpl(
        deviceImpl,
        descriptor,
        viewFormats: copyViewFormats(viewFormatsView),
        label,
        hasUnifiedMemory,
        supportsNonPrivateDepthStencilTextures,
        supportsMemorylessTextures
    )
}

private func createTextureImpl(
    _ deviceImpl: DeviceImpl,
    _ descriptor: WebGPU.Metal.TextureParameters,
    viewFormats: [WebGPU.TextureFormat],
    _ label: WTF.String,
    _ hasUnifiedMemory: Bool,
    _ supportsNonPrivateDepthStencilTextures: Bool,
    _ supportsMemorylessTextures: Bool
) -> TextureImpl {
    if !deviceImpl.isValid() {
        return makeInvalidTextureImpl(deviceImpl)
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-createtexture

    if let error = textureCreationError(deviceImpl, descriptor, viewFormats) {
        deviceImpl.generateAValidationError(error)
        return makeInvalidTextureImpl(deviceImpl)
    }

    let textureDescriptor = MTLTextureDescriptor()

    let format = descriptor.format
    textureDescriptor.usage = metalTextureUsage(descriptor.usage, format)

    switch descriptor.dimension {
    case ._1d:
        textureDescriptor.width = Int(descriptor.width)
        if descriptor.depthOrArrayLayers > 1 {
            textureDescriptor.textureType = .type1DArray
            textureDescriptor.arrayLength = Int(descriptor.depthOrArrayLayers)
        } else {
            textureDescriptor.textureType = .type1D
        }
    case ._2d:
        textureDescriptor.width = Int(descriptor.width)
        textureDescriptor.height = Int(descriptor.height)
        if descriptor.depthOrArrayLayers > 1 {
            textureDescriptor.arrayLength = Int(descriptor.depthOrArrayLayers)
            if descriptor.sampleCount > 1 {
                #if WTF_PLATFORM_WATCHOS || WTF_PLATFORM_APPLETV
                return makeInvalidTextureImpl(deviceImpl)
                #else
                textureDescriptor.textureType = .type2DMultisampleArray
                #endif
            } else {
                textureDescriptor.textureType = .type2DArray
            }
        } else {
            if descriptor.sampleCount > 1 {
                textureDescriptor.textureType = .type2DMultisample
            } else {
                textureDescriptor.textureType = .type2D
            }
        }
    case ._3d:
        textureDescriptor.width = Int(descriptor.width)
        textureDescriptor.height = Int(descriptor.height)
        textureDescriptor.depth = Int(descriptor.depthOrArrayLayers)
        textureDescriptor.textureType = .type3D
    @unknown default:
        break
    }

    textureDescriptor.pixelFormat = texturePixelFormat(format)
    if textureDescriptor.pixelFormat == .invalid {
        deviceImpl.generateAValidationError("GPUDevice.createTexture: invalid texture format")
        return makeInvalidTextureImpl(deviceImpl)
    }

    textureDescriptor.mipmapLevelCount = Int(descriptor.mipLevelCount)

    textureDescriptor.sampleCount = Int(descriptor.sampleCount)

    textureDescriptor.storageMode = storageMode(
        hasUnifiedMemory,
        supportsNonPrivateDepthStencilTextures,
        supportsMemorylessTextures,
        descriptor.usage
    )

    // FIXME(PERFORMANCE): Consider write-combining CPU cache mode.
    // FIXME(PERFORMANCE): Consider implementing hazard tracking ourself.

    guard let texture = deviceImpl.device()?.makeTexture(descriptor: textureDescriptor) else {
        deviceImpl.generateAnOutOfMemoryError("out of memory")
        return makeInvalidTextureImpl(deviceImpl)
    }

    deviceImpl.setOwnerWithIdentity(texture)
    texture.label = stringNilIfEmpty(label) ?? ""

    let impl = TextureImpl(texture: texture, parameters: descriptor, viewFormats: viewFormats, deviceImpl: deviceImpl)
    deviceImpl.textures.add(impl)
    return impl
}

/// A texture made elsewhere (the canvas render buffers, XR), which allows views in `viewFormats`.
func makeTexture(
    _ texture: (any MTLTexture)?,
    _ parameters: WebGPU.Metal.TextureParameters,
    viewFormats: [WebGPU.TextureFormat],
    _ deviceImpl: DeviceImpl
) -> TextureImpl {
    TextureImpl(texture: texture, parameters: parameters, viewFormats: viewFormats, deviceImpl: deviceImpl)
}

/// The parameters of a 2D texture of one mip level.
func twoDimensionalTextureParameters(
    _ format: WebGPU.TextureFormat,
    usage: UInt8,
    width: UInt32,
    height: UInt32,
    depthOrArrayLayers: UInt32 = 1,
    sampleCount: UInt32 = 1
) -> WebGPU.Metal.TextureParameters {
    var parameters = WebGPU.Metal.TextureParameters()
    parameters.width = width
    parameters.height = height
    parameters.depthOrArrayLayers = depthOrArrayLayers
    parameters.mipLevelCount = 1
    parameters.sampleCount = sampleCount
    parameters.dimension = ._2d
    parameters.format = format
    parameters.usage = usage
    return parameters
}

/// Device::errorValidatingTextureCreation() for Swift callers.
func errorValidatingTextureCreation(
    _ deviceImpl: DeviceImpl,
    _ parameters: WebGPU.Metal.TextureParameters,
    viewFormats: [WebGPU.TextureFormat]
) -> String? {
    textureCreationError(deviceImpl, parameters, viewFormats)
}

func makeInvalidTextureImpl(_ deviceImpl: DeviceImpl) -> TextureImpl {
    TextureImpl(texture: nil, parameters: nil, viewFormats: [], deviceImpl: deviceImpl)
}

func errorValidatingImageCopyTexture(
    _ texture: TextureImpl,
    _ mipLevel: UInt32,
    _ origin: WebGPU.Origin3D,
    _ copySize: WebGPU.Extent3D
) -> String? {
    // https://gpuweb.github.io/gpuweb/#abstract-opdef-validating-gpuimagecopytexture

    let blockWidth = texelBlockWidth(texture.formatOrDefault)

    let blockHeight = texelBlockHeight(texture.formatOrDefault)

    if !texture.isValid() {
        return "imageCopyTexture is not valid"
    }

    if mipLevel >= texture.backingMipLevelCount {
        return
            "imageCopyTexture mip level(\(mipLevel)) is greater than or equal to the mipLevelCount(\(texture.backingMipLevelCount)) in the texture"
    }

    if origin.x % blockWidth != 0 {
        return "imageCopyTexture.origin.x(\(origin.x)) is not a multiple of the texture blockWidth(\(blockWidth))"
    }

    if origin.y % blockHeight != 0 {
        return "imageCopyTexture.origin.y(\(origin.y)) is not a multiple of the texture blockHeight(\(blockHeight))"
    }

    if isDepthOrStencilFormat(texture.formatOrDefault) || texture.backingSampleCount > 1 {
        // https://gpuweb.github.io/gpuweb/#imagecopytexture-subresource-size
        let subresourceSize = texture.physicalMiplevelSpecificTextureExtent(mipLevel)
        if subresourceSize.width != copySize.width || (copySize.height > 1 && subresourceSize.height != copySize.height) {
            return
                "subresourceSize.width(\(subresourceSize.width)) != copySize.width(\(copySize.width)) || subresourceSize.height(\(subresourceSize.height)) != copySize.height(\(copySize.height)) || subresourceSize.depthOrArrayLayers(\(subresourceSize.depthOrArrayLayers)) != copySize.depthOrArrayLayers(\(copySize.depthOrArrayLayers))"
        }
    }

    return nil
}

func errorValidatingTextureCopyRange(
    _ texture: TextureImpl,
    _ mipLevel: UInt32,
    _ origin: WebGPU.Origin3D,
    _ copySize: WebGPU.Extent3D
) -> String? {
    // https://gpuweb.github.io/gpuweb/#validating-texture-copy-range

    let blockWidth = texelBlockWidth(texture.formatOrDefault)

    let blockHeight = texelBlockHeight(texture.formatOrDefault)

    // https://gpuweb.github.io/gpuweb/#imagecopytexture-subresource-size
    let subresourceSize = texture.physicalMiplevelSpecificTextureExtent(mipLevel)

    let (endX, endXOverflowed) = origin.x.addingReportingOverflow(copySize.width)
    if endXOverflowed || endX > subresourceSize.width {
        return "endX(\(endXOverflowed ? UInt32.max : endX)) > subresourceSize.width(\(subresourceSize.width))"
    }

    let (endY, endYOverflowed) = origin.y.addingReportingOverflow(copySize.height)
    if endYOverflowed || endY > subresourceSize.height {
        return "endY(\(endYOverflowed ? UInt32.max : endY)) > subresourceSize.height(\(subresourceSize.height))"
    }

    let (endZ, endZOverflowed) = origin.z.addingReportingOverflow(copySize.depthOrArrayLayers)
    if endZOverflowed || endZ > subresourceSize.depthOrArrayLayers {
        return "endZ(\(endZOverflowed ? UInt32.max : endZ)) > subresourceSize.depthOrArrayLayers(\(subresourceSize.depthOrArrayLayers))"
    }

    if copySize.width % blockWidth != 0 {
        return "copySize.width(\(copySize.width)) is not divisible by blockWidth(\(blockWidth))"
    }

    if copySize.height % blockHeight != 0 {
        return "copySize.height(\(copySize.height)) is not divisible by blockHeight(\(blockHeight))"
    }

    return nil
}

@_spi(WebKitGPU)
extension DeviceReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-createtexture: an invalid texture on failure.
    public func createTexture(_ descriptor: GPUTextureDescriptor, label: Swift.String?) -> TextureReference {
        createTextureImpl(self, descriptor, label: WTF.String(label ?? ""))
    }
}

@_spi(WebKitGPU)
extension TextureImpl {
    // https://gpuweb.github.io/gpuweb/#dom-gputexture-createview. A view's device is its texture's.
    public func createView(_ descriptor: GPUTextureViewDescriptor?, label: Swift.String?) -> TextureViewReference {
        createView(descriptor ?? GPUTextureViewDescriptor(), label: WTF.String(label ?? ""))
    }
}
