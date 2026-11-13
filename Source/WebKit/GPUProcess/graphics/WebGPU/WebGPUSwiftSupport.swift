// Copyright (C) 2021-2023 Apple Inc. All rights reserved.
// Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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
internal import WebGPU_Private
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
    typealias WebKit_WebGPU_Origin2D = IPCTypes.Origin2D
    typealias WebKit_WebGPU_QuerySetDescriptor = IPCTypes.QuerySetDescriptor
    typealias WebKit_WebGPU_RenderBundleDescriptor = IPCTypes.RenderBundleDescriptor
    typealias WebKit_WebGPU_RequestAdapterOptions = IPCTypes.RequestAdapterOptions
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
// only on the RemoteGPU's work queue. The RemoteGPU owns the registry (RemoteGPU.swift), which holds it in turn until the
// RemoteGPU empties and releases the registry, when it stops.
final class WebGPUImplTable {
    private final class Entry {
        let object: AnyObject
        let receiver: AnyObject
        let registration: IPC.SwiftStreamReceiverRegistration?
        let kind: Kind?

        init(_ object: AnyObject, _ receiver: AnyObject, _ registration: IPC.SwiftStreamReceiverRegistration?, _ kind: Kind?) {
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
        case xrProjectionLayer
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
        var xrProjectionLayers = WebGPUObjectStore<XRProjectionLayerReference>()

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
            case .xrProjectionLayer:
                return xrProjectionLayers.remove(identifier)
            }
        }
    }

    let host: WebKit.RemoteGPU
    private let instance: InstanceReference
    private var entries: [UInt64: Entry] = [:]
    private var stores = Stores()
    // Every device made: work in flight can keep a device alive after its entry is removed.
    private var devices: [DeviceWeakReference] = []

    init(host: WebKit.RemoteGPU, instance: InstanceReference) {
        self.host = host
        self.instance = instance
    }

    func remove(_ identifier: UInt64) {
        guard let entry = entries.removeValue(forKey: identifier), let kind = entry.kind else {
            return
        }
        _ = stores.remove(identifier, kind)
    }

    func removeAll() {
        // What's removed is released after the registry is empty.
        var removedEntries: [UInt64: Entry] = [:]
        var removedStores = Stores()
        swap(&entries, &removedEntries)
        swap(&stores, &removedStores)
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpu-requestadapter: makes the adapter and its receiver, and the reply that
    // describes it. nil if there's no adapter.
    func requestAdapter(
        _ powerPreference: WebGPU.PowerPreference?,
        _ forceFallbackAdapter: Bool,
        _ xrCompatible: Bool,
        _ identifier: UInt64
    ) -> IPCTypes.RemoteGPURequestAdapterResponse? {
        guard
            let adapter = instance.requestAdapter(
                powerPreference: powerPreference,
                forceFallbackAdapter: forceFallbackAdapter,
                xrCompatible: xrCompatible
            )
        else {
            return nil
        }
        RemoteAdapter.add(adapter, WebGPURegistryLink(self, identifier))
        let subgroupSizes = adapter.subgroupSizes
        return IPCTypes.RemoteGPURequestAdapterResponse(
            name: adapter.name,
            features: adapter.features.map { sameNumbering($0) },
            limits: IPCTypes.Limits(adapter.limits),
            isFallbackAdapter: false,
            subgroupMinSize: subgroupSizes.min,
            subgroupMaxSize: subgroupSizes.max
        )
    }

    // Makes the receivers of a device that an adapter made, and of its queue.
    func addDevice(_ device: DeviceReference, _ identifier: UInt64, _ queueIdentifier: UInt64) {
        devices.append(device.weakReference)
        let receiver = RemoteDevice(device, link: WebGPURegistryLink(self, identifier))
        add(
            identifier,
            device,
            receiver: receiver,
            registration: IPC.registerSwiftStreamReceiver(host, receiver.getMessageReceiver(), .RemoteDevice, identifier)
        )
        RemoteQueue.add(device.queue, WebGPURegistryLink(self, queueIdentifier))
    }

    // Makes the receiver of a compositor integration, whose canvas context comes later (addPresentationContext()).
    func addCompositorIntegration(_ identifier: UInt64) {
        RemoteCompositorIntegration.add(WebGPURegistryLink(self, identifier))
    }

    // Makes a canvas context, and its receiver, for the compositor integration that shows it. False if there's no
    // compositor integration with that identifier.
    func addPresentationContext(_ identifier: UInt64, _ compositorIntegrationIdentifier: UInt64) -> Bool {
        guard let compositorIntegration = entries[compositorIntegrationIdentifier]?.receiver as? RemoteCompositorIntegration else {
            return false
        }
        let presentationContext = instance.createPresentationContext()
        RemotePresentationContext.add(presentationContext, WebGPURegistryLink(self, identifier))
        compositorIntegration.setCanvas(WebGPUCompositorCanvas(presentationContext))
        return true
    }

    func hasDevice(_ identifier: UInt64) -> Bool {
        stores.devices.object(identifier) != nil
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-destroy for every device still alive.
    func destroyDevices() {
        for device in devices {
            device.destroy()
        }
        devices = []
    }

    // Whether there's an object with that identifier, and whether it's valid, as WebGPUIntegration::isValid() says for
    // its shell.
    func objectState(_ identifier: UInt64) -> (exists: Bool, valid: Bool) {
        guard let object = entries[identifier]?.object else {
            return (false, false)
        }
        // The WebXR objects are never invalid, as when C++ received their messages.
        guard let reference = object as? any GPUObjectReference else {
            return (true, true)
        }
        return (true, reference.isValid)
    }

    // Adds an object that Swift owns, in place of any with the same identifier, with its receiver and the registration
    // that keeps the receiver's messages coming. A kind of object that messages name goes in its store too.
    private func add(_ identifier: UInt64, _ entry: Entry) {
        guard let replaced = entries.updateValue(entry, forKey: identifier), let kind = replaced.kind, kind != entry.kind else {
            return
        }
        _ = stores.remove(identifier, kind)
    }

    func add(_ identifier: UInt64, _ compositorIntegration: RemoteCompositorIntegration, registration: IPC.SwiftStreamReceiverRegistration?)
    {
        add(identifier, Entry(compositorIntegration, compositorIntegration, registration, nil))
    }

    func add(_ identifier: UInt64, _ object: AdapterReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    func add(_ identifier: UInt64, _ object: BindGroupReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .bindGroup))
        stores.bindGroups.insert(object, identifier)
    }

    func add(
        _ identifier: UInt64,
        _ object: BindGroupLayoutReference,
        receiver: AnyObject,
        registration: IPC.SwiftStreamReceiverRegistration?
    ) {
        add(identifier, Entry(object, receiver, registration, .bindGroupLayout))
        stores.bindGroupLayouts.insert(object, identifier)
    }

    func add(_ identifier: UInt64, _ object: BufferReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .buffer))
        stores.buffers.insert(object, identifier)
    }

    func add(
        _ identifier: UInt64,
        _ object: CommandBufferReference,
        receiver: AnyObject,
        registration: IPC.SwiftStreamReceiverRegistration?
    ) {
        add(identifier, Entry(object, receiver, registration, .commandBuffer))
        stores.commandBuffers.insert(object, identifier)
    }

    func add(
        _ identifier: UInt64,
        _ object: CommandEncoderReference,
        receiver: AnyObject,
        registration: IPC.SwiftStreamReceiverRegistration?
    ) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    func add(
        _ identifier: UInt64,
        _ object: ComputePassEncoderReference,
        receiver: AnyObject,
        registration: IPC.SwiftStreamReceiverRegistration?
    ) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    func add(
        _ identifier: UInt64,
        _ object: ComputePipelineReference,
        receiver: AnyObject,
        registration: IPC.SwiftStreamReceiverRegistration?
    ) {
        add(identifier, Entry(object, receiver, registration, .computePipeline))
        stores.computePipelines.insert(object, identifier)
    }

    func add(_ identifier: UInt64, _ object: DeviceReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .device))
        stores.devices.insert(object, identifier)
    }

    func add(
        _ identifier: UInt64,
        _ object: ExternalTextureReference,
        receiver: AnyObject,
        registration: IPC.SwiftStreamReceiverRegistration?
    ) {
        add(identifier, Entry(object, receiver, registration, .externalTexture))
        stores.externalTextures.insert(object, identifier)
    }

    func add(
        _ identifier: UInt64,
        _ object: PipelineLayoutReference,
        receiver: AnyObject,
        registration: IPC.SwiftStreamReceiverRegistration?
    ) {
        add(identifier, Entry(object, receiver, registration, .pipelineLayout))
        stores.pipelineLayouts.insert(object, identifier)
    }

    func add(
        _ identifier: UInt64,
        _ object: PresentationContextReference,
        receiver: AnyObject,
        registration: IPC.SwiftStreamReceiverRegistration?
    ) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    func add(_ identifier: UInt64, _ object: QuerySetReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .querySet))
        stores.querySets.insert(object, identifier)
    }

    func add(_ identifier: UInt64, _ object: QueueReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    func add(_ identifier: UInt64, _ object: RenderBundleReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?)
    {
        add(identifier, Entry(object, receiver, registration, .renderBundle))
        stores.renderBundles.insert(object, identifier)
    }

    func add(
        _ identifier: UInt64,
        _ object: RenderBundleEncoderReference,
        receiver: AnyObject,
        registration: IPC.SwiftStreamReceiverRegistration?
    ) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    func add(
        _ identifier: UInt64,
        _ object: RenderPassEncoderReference,
        receiver: AnyObject,
        registration: IPC.SwiftStreamReceiverRegistration?
    ) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    func add(
        _ identifier: UInt64,
        _ object: RenderPipelineReference,
        receiver: AnyObject,
        registration: IPC.SwiftStreamReceiverRegistration?
    ) {
        add(identifier, Entry(object, receiver, registration, .renderPipeline))
        stores.renderPipelines.insert(object, identifier)
    }

    func add(_ identifier: UInt64, _ object: SamplerReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .sampler))
        stores.samplers.insert(object, identifier)
    }

    func add(_ identifier: UInt64, _ object: ShaderModuleReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?)
    {
        add(identifier, Entry(object, receiver, registration, .shaderModule))
        stores.shaderModules.insert(object, identifier)
    }

    func add(_ identifier: UInt64, _ object: TextureReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, .texture))
        stores.textures.insert(object, identifier)
    }

    func add(_ identifier: UInt64, _ object: TextureViewReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?)
    {
        add(identifier, Entry(object, receiver, registration, .textureView))
        stores.textureViews.insert(object, identifier)
    }

    func add(_ identifier: UInt64, _ object: XRBindingReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    func add(
        _ identifier: UInt64,
        _ object: XRProjectionLayerReference,
        receiver: AnyObject,
        registration: IPC.SwiftStreamReceiverRegistration?
    ) {
        add(identifier, Entry(object, receiver, registration, .xrProjectionLayer))
        stores.xrProjectionLayers.insert(object, identifier)
    }

    func add(_ identifier: UInt64, _ object: XRSubImageReference, receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?) {
        add(identifier, Entry(object, receiver, registration, nil))
    }

    // A WebXR view has no object of its own, so its receiver is its entry's object too.
    func add(_ identifier: UInt64, view receiver: AnyObject, registration: IPC.SwiftStreamReceiverRegistration?) {
        add(identifier, Entry(receiver, receiver, registration, nil))
    }

    // The object with that identifier, if there is one of that type.
    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: BindGroupReference.Type) -> BindGroupReference? {
        stores.bindGroups.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: BindGroupLayoutReference.Type) -> BindGroupLayoutReference? {
        stores.bindGroupLayouts.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: BufferReference.Type) -> BufferReference? {
        stores.buffers.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: CommandBufferReference.Type) -> CommandBufferReference? {
        stores.commandBuffers.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: ComputePipelineReference.Type) -> ComputePipelineReference? {
        stores.computePipelines.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: DeviceReference.Type) -> DeviceReference? {
        stores.devices.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: ExternalTextureReference.Type) -> ExternalTextureReference? {
        stores.externalTextures.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: PipelineLayoutReference.Type) -> PipelineLayoutReference? {
        stores.pipelineLayouts.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: QuerySetReference.Type) -> QuerySetReference? {
        stores.querySets.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: RenderBundleReference.Type) -> RenderBundleReference? {
        stores.renderBundles.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: RenderPipelineReference.Type) -> RenderPipelineReference? {
        stores.renderPipelines.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: SamplerReference.Type) -> SamplerReference? {
        stores.samplers.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: ShaderModuleReference.Type) -> ShaderModuleReference? {
        stores.shaderModules.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: TextureReference.Type) -> TextureReference? {
        stores.textures.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: TextureViewReference.Type) -> TextureViewReference? {
        stores.textureViews.object(identifier.rawValue)
    }

    func object(_ identifier: IPCTypes.WebGPUIdentifier, as: XRProjectionLayerReference.Type) -> XRProjectionLayerReference? {
        stores.xrProjectionLayers.object(identifier.rawValue)
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
        self.init(
            width: extent.width,
            height: extent.height,
            depthOrArrayLayers: extent.depthOrArrayLayers
        )
    }
}

extension WebGPU.Origin3D {
    init(_ origin: IPCTypes.Origin3D) {
        self.init(
            x: origin.x,
            y: origin.y,
            z: origin.z
        )
    }
}

extension WebGPU.TexelCopyBufferLayout {
    init(_ layout: IPCTypes.TexelCopyBufferLayout) {
        self.init(offset: layout.offset, bytesPerRow: .init(), rowsPerImage: .init())
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
        origin = location.origin.map { WebGPU.Origin3D($0) } ?? WebGPU.Origin3D(x: 0, y: 0, z: 0)
        aspect = sameNumbering(location.aspect)
    }
}

// WebGPU::maxCrossProcessResourceCopySize (RemoteBufferProxy.h): the most data a write sends in a message of the stream.
private let maxCrossProcessResourceCopySize = 16 * 1024 * 1024

// Whether a write with copy is no larger than the web process sends in a message.
func isValidWebGPUWriteWithCopySize(_ size: Int) -> Bool {
    size <= maxCrossProcessResourceCopySize
}

// The bytes of the shared memory that a message's handle names, mapped read-only, for a write that may read them after
// it returns. nil if there's none, or no more than the message could have carried in the stream.
func mapWebGPUWriteSharedMemory(_ handle: consuming IPCTypes.SharedMemoryHandle?) -> IPCTypes.ReadOnlySharedMemory? {
    switch consume handle {
    case .none:
        return nil
    case .some(let handle):
        guard let memory = handle.mapReadOnly(), memory.size > UInt64(maxCrossProcessResourceCopySize) else {
            return nil
        }
        return memory
    }
}

extension IPCTypes.ReadOnlySharedMemory: GPUByteSource {
}

// The owner a large write keeps the mapping with until it has read it.
func gpuByteOwner(_ memory: IPCTypes.ReadOnlySharedMemory) -> GPUByteOwner {
    // Safety: the mapping is read-only in this process, and stays at the same address and size until the
    // ReadOnlySharedMemory's deinit (SwiftCoding.swift), which, as for any final class with only lets, may run on any thread.
    unsafe GPUByteOwner(memory)
}

// A Swift receiver's link to the registry that owns it: its entry, which it removes when the web process destructs its
// object, and the objects its messages name, which most messages look up. Strong, because a weak reference costs as much
// to load as the lookup itself. The cycle through the registry's entries ends when the RemoteGPU empties the registry, as
// it does when it stops; work still in flight after that finds nothing, and the RemoteGPU, whose stream connection has
// gone by then, registers nothing.
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
