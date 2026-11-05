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


#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT

@_spi(WebKitGPU) import WebGPUSwift
import WebKit_Internal

extension IPCTypes.CxxName {
    // The generator names the Swift forms of the C++ types it describes, not of their aliases, which the WebGPU
    // receivers' messages use.
    typealias WebKit_WebGPU_BufferDescriptor = IPCTypes.BufferDescriptor
    typealias WebKit_WebGPU_Color = IPCTypes.Color
    typealias WebKit_WebGPU_CommandBufferDescriptor = IPCTypes.CommandBufferDescriptor
    typealias WebKit_WebGPU_CommandEncoderDescriptor = IPCTypes.CommandEncoderDescriptor
    typealias WebKit_WebGPU_CompilationMessage = IPCTypes.CompilationMessage
    typealias WebKit_WebGPU_Extent3D = IPCTypes.Extent3D
    typealias WebKit_WebGPU_ImageDataLayout = IPCTypes.TexelCopyBufferLayout
    typealias WebKit_WebGPU_QuerySetDescriptor = IPCTypes.QuerySetDescriptor
    typealias WebKit_WebGPU_RenderBundleDescriptor = IPCTypes.RenderBundleDescriptor
    typealias WebKit_WebGPU_SamplerDescriptor = IPCTypes.SamplerDescriptor
    typealias WebKit_WebGPU_SupportedLimits = IPCTypes.Limits
    typealias WebKit_WebGPU_TextureViewDescriptor = IPCTypes.TextureViewDescriptor
}

extension IPCTypes {
    // The name a queue's messages give the type, as WebKit::WebGPU::ImageDataLayout.
    typealias ImageDataLayout = IPCTypes.TexelCopyBufferLayout
}

extension WebGPU.IndexFormat {
    init(_ format: IPCTypes.IndexFormat) {
        switch format {
        case .uint16:
            self = .Uint16
        case .uint32:
            self = .Uint32
        }
    }
}

// The C++ enum or option set with the same numbering as an IPC one: the [Swift] marking that gives the IPC type its Swift
// form numbers both in declaration order, as their coders do.
func sameNumbering<Target: RawRepresentable, Source: RawRepresentable>(_ value: Source) -> Target
where Target.RawValue: FixedWidthInteger, Source.RawValue: FixedWidthInteger {
    guard let target = Target(rawValue: Target.RawValue(value.rawValue)) else {
        preconditionFailure("an IPC value with no C++ counterpart")
    }
    return target
}

// The registry of the WebGPU objects of a RemoteGPU whose messages Swift receives, by identifier: each object's
// reference, its receiver, and the registration that keeps its messages coming, which the receiver removes when the
// web process destructs the object. It has the RemoteGPU's instance, which makes the adapters and canvas contexts. Used
// only on the RemoteGPU's work queue. The RemoteGPU's object heap, which owns the receivers still written in C++, owns
// the registry, and empties it when it's cleared or destroyed.
@_expose(Cxx)
final class WebGPUImplTable {
    private final class Entry {
        let object: AnyObject
        let receiver: AnyObject
        let registration: WebKit.WebGPUSwiftReceiverRegistration?
        let kind: Kind?

        init(_ object: AnyObject, _ receiver: AnyObject, _ registration: WebKit.WebGPUSwiftReceiverRegistration?, _ kind: Kind?) {
            self.object = object
            self.receiver = receiver
            self.registration = registration
            self.kind = kind
        }
    }

    // The kinds of object that messages name, which the stores look up by identifier as their own types.
    private enum Kind {
        case bindGroup
        case bindGroupLayout
        case buffer
        case commandBuffer
        case computePipeline
        case device
        case externalTexture
        case pipelineLayout
        case querySet
        case renderBundle
        case renderPipeline
        case sampler
        case shaderModule
        case texture
        case textureView
    }

    private struct Stores {
        var bindGroups = WebGPUObjectStore<BindGroupReference>()
        var bindGroupLayouts = WebGPUObjectStore<BindGroupLayoutReference>()
        var buffers = WebGPUObjectStore<BufferReference>()
        var commandBuffers = WebGPUObjectStore<CommandBufferReference>()
        var computePipelines = WebGPUObjectStore<ComputePipelineReference>()
        var devices = WebGPUObjectStore<DeviceReference>()
        var externalTextures = WebGPUObjectStore<ExternalTextureReference>()
        var pipelineLayouts = WebGPUObjectStore<PipelineLayoutReference>()
        var querySets = WebGPUObjectStore<QuerySetReference>()
        var renderBundles = WebGPUObjectStore<RenderBundleReference>()
        var renderPipelines = WebGPUObjectStore<RenderPipelineReference>()
        var samplers = WebGPUObjectStore<SamplerReference>()
        var shaderModules = WebGPUObjectStore<ShaderModuleReference>()
        var textures = WebGPUObjectStore<TextureReference>()
        var textureViews = WebGPUObjectStore<TextureViewReference>()

        // The object removed, which the caller releases after the change.
        mutating func remove(_ identifier: UInt64, _ kind: Kind) -> AnyObject? {
            switch kind {
            case .bindGroup:
                return bindGroups.remove(identifier)
            case .bindGroupLayout:
                return bindGroupLayouts.remove(identifier)
            case .buffer:
                return buffers.remove(identifier)
            case .commandBuffer:
                return commandBuffers.remove(identifier)
            case .computePipeline:
                return computePipelines.remove(identifier)
            case .device:
                return devices.remove(identifier)
            case .externalTexture:
                return externalTextures.remove(identifier)
            case .pipelineLayout:
                return pipelineLayouts.remove(identifier)
            case .querySet:
                return querySets.remove(identifier)
            case .renderBundle:
                return renderBundles.remove(identifier)
            case .renderPipeline:
                return renderPipelines.remove(identifier)
            case .sampler:
                return samplers.remove(identifier)
            case .shaderModule:
                return shaderModules.remove(identifier)
            case .texture:
                return textures.remove(identifier)
            case .textureView:
                return textureViews.remove(identifier)
            }
        }
    }

    @_expose(!Cxx)
    let host: WebKit.WebGPUSwiftRegistryHost
    private let instance: InstanceReference
    private var entries: [UInt64: Entry] = [:]
    private var stores = Stores()
    // Every device made: work in flight can keep a device alive after its entry is removed.
    private var devices: [DeviceWeakReference] = []

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(host: WebKit.WebGPUSwiftRegistryHost, instanceDescriptor: WebKit.WebGPUSwiftInstanceDescriptor) {
        self.host = host
        var descriptor = instanceDescriptor.take()
        instance = InstanceReference(&descriptor)
    }

    @_expose(!Cxx)
    func remove(_ identifier: UInt64) {
        guard let entry = entries.removeValue(forKey: identifier), let kind = entry.kind else {
            return
        }
        _ = stores.remove(identifier, kind)
    }

    @used
    func removeAll() {
        // What's removed is released after the registry is empty.
        var removedEntries: [UInt64: Entry] = [:]
        var removedStores = Stores()
        swap(&entries, &removedEntries)
        swap(&stores, &removedStores)
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpu-requestadapter: makes the adapter and its receiver, and fills in the
    // reply that describes it. False, with no reply, if there's no adapter.
    @used
    func requestAdapter(_ options: WebGPU.RequestAdapterOptions, _ identifier: UInt64, _ response: inout WebKit.RemoteGPURequestAdapterResponse) -> Bool {
        guard let adapter = instance.requestAdapter(options) else {
            return false
        }
        RemoteAdapter.add(adapter, WebGPURegistryLink(self, identifier))

        response.name = WTF.String(adapter.name)
        for feature in adapter.features {
            response.features.append(consuming: feature)
        }
        response.limits = adapter.limits
        response.isFallbackAdapter = false
        let subgroupSizes = adapter.subgroupSizes
        response.subgroupMinSize = subgroupSizes.min
        response.subgroupMaxSize = subgroupSizes.max
        return true
    }

    // Makes the receivers of a device that an adapter made, and of its queue.
    @_expose(!Cxx)
    func addDevice(_ device: DeviceReference, _ identifier: UInt64, _ queueIdentifier: UInt64) {
        devices.append(device.weakReference)
        let receiver = RemoteDevice(device, link: WebGPURegistryLink(self, identifier))
        add(identifier, device, receiver: receiver, registration: WebKit.registerWebGPUSwiftReceiver(host, receiver.getMessageReceiver(), .RemoteDevice, identifier))
        RemoteQueue.add(device.queue, WebGPURegistryLink(self, queueIdentifier))
    }

    // Makes a canvas context, and its receiver, for the compositor integration that shows it, which holds what this
    // returns.
    @used
    func addPresentationContext(_ identifier: UInt64) -> WebGPUCompositorCanvas {
        let presentationContext = instance.createPresentationContext()
        RemotePresentationContext.add(presentationContext, WebGPURegistryLink(self, identifier))
        return WebGPUCompositorCanvas(presentationContext)
    }

    // Makes the receiver of an XR sub-image's current color or depth texture. False if it has none.
    @used
    func addXRSubImageTexture(_ subImage: WebGPUXRSubImage, _ depth: Bool, _ identifier: UInt64) -> Bool {
        guard let texture = subImage.texture(depth: depth) else {
            return false
        }
        RemoteTexture.add(texture, WebGPURegistryLink(self, identifier))
        return true
    }

    // The XR binding of a device whose receiver is making one.
    @used
    func createXRBinding(_ deviceIdentifier: UInt64) -> WebGPUXRBinding {
        guard let device = stores.devices.object(deviceIdentifier) else {
            preconditionFailure("Only for a device in the registry")
        }
        return WebGPUXRBinding(device.createXRBinding())
    }

    @used
    func hasDevice(_ identifier: UInt64) -> Bool {
        stores.devices.object(identifier) != nil
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-destroy for every device still alive.
    @used
    func destroyDevices() {
        for device in devices {
            device.destroy()
        }
        devices = []
    }

    // Whether an object that Swift owns is valid, as WebGPUIntegration::isValid() says for its shell.
    @used
    func objectState(_ identifier: UInt64) -> WebKit.WebGPUSwiftObjectState {
        guard let object = entries[identifier]?.object as? any GPUObjectReference else {
            return .Absent
        }
        return object.isValid ? .Valid : .Invalid
    }

    // Adds an object that Swift owns, in place of any with the same identifier, with its receiver and the registration
    // that keeps the receiver's messages coming. A kind of object that messages name goes in its store too.
    private func add(_ identifier: UInt64, _ entry: Entry) {
        guard let replaced = entries.updateValue(entry, forKey: identifier), let kind = replaced.kind, kind != entry.kind else {
            return
        }
        _ = stores.remove(identifier, kind)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: AdapterReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: BindGroupReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .bindGroup))
        stores.bindGroups.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: BindGroupLayoutReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .bindGroupLayout))
        stores.bindGroupLayouts.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: BufferReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .buffer))
        stores.buffers.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: CommandBufferReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .commandBuffer))
        stores.commandBuffers.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: CommandEncoderReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: ComputePassEncoderReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: ComputePipelineReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .computePipeline))
        stores.computePipelines.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: DeviceReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .device))
        stores.devices.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: ExternalTextureReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .externalTexture))
        stores.externalTextures.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: PipelineLayoutReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .pipelineLayout))
        stores.pipelineLayouts.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: PresentationContextReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: QuerySetReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .querySet))
        stores.querySets.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: QueueReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: RenderBundleReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .renderBundle))
        stores.renderBundles.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: RenderBundleEncoderReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: RenderPassEncoderReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: RenderPipelineReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .renderPipeline))
        stores.renderPipelines.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: SamplerReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .sampler))
        stores.samplers.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: ShaderModuleReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .shaderModule))
        stores.shaderModules.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: TextureReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .texture))
        stores.textures.insert(object, identifier)
    }

    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: TextureViewReference, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .textureView))
        stores.textureViews.insert(object, identifier)
    }

    // The object with that identifier, if there is one of that type.
    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: BindGroupReference.Type) -> BindGroupReference? {
        stores.bindGroups.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: BindGroupLayoutReference.Type) -> BindGroupLayoutReference? {
        stores.bindGroupLayouts.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: BufferReference.Type) -> BufferReference? {
        stores.buffers.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: CommandBufferReference.Type) -> CommandBufferReference? {
        stores.commandBuffers.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: ComputePipelineReference.Type) -> ComputePipelineReference? {
        stores.computePipelines.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: DeviceReference.Type) -> DeviceReference? {
        stores.devices.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: ExternalTextureReference.Type) -> ExternalTextureReference? {
        stores.externalTextures.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: PipelineLayoutReference.Type) -> PipelineLayoutReference? {
        stores.pipelineLayouts.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: QuerySetReference.Type) -> QuerySetReference? {
        stores.querySets.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: RenderBundleReference.Type) -> RenderBundleReference? {
        stores.renderBundles.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: RenderPipelineReference.Type) -> RenderPipelineReference? {
        stores.renderPipelines.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: SamplerReference.Type) -> SamplerReference? {
        stores.samplers.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: ShaderModuleReference.Type) -> ShaderModuleReference? {
        stores.shaderModules.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: TextureReference.Type) -> TextureReference? {
        stores.textures.object(identifier.rawValue)
    }

    @_expose(!Cxx)
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: TextureViewReference.Type) -> TextureViewReference? {
        stores.textureViews.object(identifier.rawValue)
    }
}

// The objects of one kind in a registry, by identifier: open addressing with linear probing, and a hash of one
// multiplication, as WTF's integer hash tables have, which costs much less than Dictionary's SipHash.
private struct WebGPUObjectStore<Object: AnyObject> {
    private struct Slot {
        var identifier: UInt64 = 0
        var object: Object?
    }

    // Empty, or a power of two at least twice count, so that every probe reaches a slot with no object.
    private var slots: [Slot] = []
    private var count = 0

    private static func home(_ identifier: UInt64, _ mask: Int) -> Int {
        Int(truncatingIfNeeded: (identifier &* 0x9E37_79B9_7F4A_7C15) >> 32) & mask
    }

    func object(_ identifier: UInt64) -> Object? {
        guard !slots.isEmpty else {
            return nil
        }
        let mask = slots.count - 1
        var index = Self.home(identifier, mask)
        while let object = slots[index].object {
            if slots[index].identifier == identifier {
                return object
            }
            index = (index + 1) & mask
        }
        return nil
    }

    mutating func insert(_ object: Object, _ identifier: UInt64) {
        if (count + 1) * 2 > slots.count {
            grow()
        }
        let mask = slots.count - 1
        var index = Self.home(identifier, mask)
        while slots[index].object != nil {
            if slots[index].identifier == identifier {
                slots[index].object = object
                return
            }
            index = (index + 1) & mask
        }
        slots[index] = Slot(identifier: identifier, object: object)
        count += 1
    }

    // The object removed, which the caller releases after the change.
    mutating func remove(_ identifier: UInt64) -> Object? {
        guard !slots.isEmpty else {
            return nil
        }
        let mask = slots.count - 1
        var hole = Self.home(identifier, mask)
        while true {
            guard slots[hole].object != nil else {
                return nil
            }
            if slots[hole].identifier == identifier {
                break
            }
            hole = (hole + 1) & mask
        }
        let removed = slots[hole].object
        // Moves back into the hole each later object of its run that a probe from its home would no longer reach.
        var index = hole
        while true {
            index = (index + 1) & mask
            guard slots[index].object != nil else {
                break
            }
            if (index - Self.home(slots[index].identifier, mask)) & mask >= (index - hole) & mask {
                slots.swapAt(hole, index)
                hole = index
            }
        }
        slots[hole] = Slot()
        count -= 1
        return removed
    }

    private mutating func grow() {
        let previous = slots
        slots = Array(repeating: Slot(), count: max(8, previous.count * 2))
        let mask = slots.count - 1
        for slot in previous where slot.object != nil {
            var index = Self.home(slot.identifier, mask)
            while slots[index].object != nil {
                index = (index + 1) & mask
            }
            slots[index] = slot
        }
    }
}

// The WebXR objects of a device, as the C++ receivers of their messages hold them. Used on the RemoteGPU's work queue.
@_expose(Cxx)
final class WebGPUXRBinding {
    private let binding: XRBindingReference

    @_expose(!Cxx)
    init(_ binding: XRBindingReference) {
        self.binding = binding
    }

    // The formats are the raw values of ::WebGPU::TextureFormat, and the usage the bits of OptionSet<::WebGPU::TextureUsage>.
    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    func createProjectionLayer(
        _ colorFormat: UInt8,
        _ hasDepthStencilFormat: Bool,
        _ depthStencilFormat: UInt8,
        _ textureUsage: UInt8,
        _ scaleFactor: Double
    ) -> WebGPUXRProjectionLayer {
        WebGPUXRProjectionLayer(
            binding.createProjectionLayer(
                colorFormat: textureFormat(colorFormat),
                depthStencilFormat: hasDepthStencilFormat ? textureFormat(depthStencilFormat) : nil,
                textureUsage: textureUsage,
                scaleFactor: scaleFactor
            )
        )
    }

    @used
    func getViewSubImage(_ projectionLayer: WebGPUXRProjectionLayer) -> WebGPUXRSubImage {
        WebGPUXRSubImage(binding.getViewSubImage(projectionLayer.layer))
    }

    private func textureFormat(_ rawValue: UInt8) -> WebGPU.TextureFormat {
        guard let format = WebGPU.TextureFormat(rawValue: rawValue) else {
            preconditionFailure("A texture format that the message decoder accepted")
        }
        return format
    }
}

@_expose(Cxx)
final class WebGPUXRProjectionLayer {
    @_expose(!Cxx)
    let layer: XRProjectionLayerReference

    @_expose(!Cxx)
    init(_ layer: XRProjectionLayerReference) {
        self.layer = layer
    }

    // The mach ports are the frame's send rights, MACH_PORT_NULL for a buffer that the compositor didn't send.
    // @used ensures this is retained even under -O -wmo: rdar://179098545
    @used
    func startFrame(
        _ frameIndex: UInt64,
        _ colorBuffer: UInt32,
        _ depthBuffer: UInt32,
        _ completionSyncEvent: UInt32,
        _ reusableTextureIndex: UInt64,
        _ screenWidth: UInt32,
        _ screenHeight: UInt32,
        _ horizontalSamplesLeft: WebGPU.XRRasterizationSamples,
        _ horizontalSamplesRight: WebGPU.XRRasterizationSamples,
        _ verticalSamples: WebGPU.XRRasterizationSamples
    ) {
        layer.startFrame(
            frameIndex,
            colorBuffer: colorBuffer,
            depthBuffer: depthBuffer,
            completionSyncEvent: completionSyncEvent,
            reusableTextureIndex: reusableTextureIndex,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            horizontalSamplesLeft: horizontalSamplesLeft,
            horizontalSamplesRight: horizontalSamplesRight,
            verticalSamples: verticalSamples
        )
    }
}

@_expose(Cxx)
final class WebGPUXRSubImage {
    private let subImage: XRSubImageReference?

    @_expose(!Cxx)
    init(_ subImage: XRSubImageReference?) {
        self.subImage = subImage
    }

    // False for the sub-image of a device that has none.
    // @used ensures this is retained even under -O -wmo: rdar://179098545
    @used
    func isValid() -> Bool {
        subImage != nil
    }

    @_expose(!Cxx)
    func texture(depth: Bool) -> TextureReference? {
        depth ? subImage?.depthStencilTexture : subImage?.colorTexture
    }
}

// The object a message names, which it must: a message naming one that doesn't exist is invalid.
func messageChecked<Object>(
    _ object: Object?,
    function: StaticString = #function,
    file: StaticString = #fileID,
    line: UInt = #line
) throws(InvalidMessage) -> Object {
    try messageCheck(function: function, file: file, line: line) {
        object != nil
    }
    guard let object else {
        preconditionFailure("messageCheck() didn't throw")
    }
    return object
}

extension WebGPU.Extent3D {
    init(_ extent: IPCTypes.Extent3D) {
        self.init()
        width = extent.width
        height = extent.height
        depthOrArrayLayers = extent.depthOrArrayLayers
    }
}

extension WebGPU.Origin3D {
    init(_ origin: IPCTypes.Origin3D) {
        self.init()
        x = origin.x
        y = origin.y
        z = origin.z
    }
}

extension WebGPU.TexelCopyBufferLayout {
    init(_ layout: IPCTypes.TexelCopyBufferLayout) {
        self.init()
        offset = layout.offset
        if let bytesPerRow = layout.bytesPerRow {
            self.bytesPerRow = .init(bytesPerRow)
        }
        if let rowsPerImage = layout.rowsPerImage {
            self.rowsPerImage = .init(rowsPerImage)
        }
    }
}

extension TextureCopyLocation {
    // ConvertFromBackingContext's conversion of the location, apart from the texture.
    init(_ location: IPCTypes.ImageCopyTexture) {
        self.init()
        mipLevel = location.mipLevel
        origin = location.origin.map { WebGPU.Origin3D($0) } ?? WebGPU.Origin3D()
        aspect = sameNumbering(location.aspect)
    }
}

// A Swift receiver's link to the registry that owns it: its entry, which it removes when the web process destructs its
// object, and the objects its messages name, which most messages look up. Strong, because a weak reference costs as much
// to load as the lookup itself. The cycle through the registry's entries ends when the object heap empties the registry,
// as it does when it's cleared or destroyed; work still in flight after that finds nothing, and the registry's host, whose
// pointers are weak, does nothing.
struct WebGPURegistryLink {
    let objects: WebGPUImplTable?
    let identifier: UInt64

    init(_ objects: WebGPUImplTable, _ identifier: UInt64) {
        self.objects = objects
        self.identifier = identifier
    }

    // A link for a child of the receiver's object, in the same registry.
    func child(_ identifier: IPCTypes.WebGPUIdentifier) -> WebGPURegistryLink? {
        objects.map { WebGPURegistryLink($0, identifier.rawValue) }
    }

    func remove() {
        objects?.remove(identifier)
    }

    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        objects?.host.sharedPreferencesForWebProcess() ?? .init()
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
