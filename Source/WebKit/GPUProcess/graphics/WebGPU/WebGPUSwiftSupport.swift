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
        let receiver: AnyObject?
        let registration: WebKit.WebGPUSwiftReceiverRegistration?

        init(_ object: AnyObject, receiver: AnyObject?, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
            self.object = object
            self.receiver = receiver
            self.registration = registration
        }
    }

    @_expose(!Cxx)
    let host: WebKit.WebGPUSwiftRegistryHost
    private let instance: InstanceReference
    private var entries: [UInt64: Entry] = [:]
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
        entries[identifier] = nil
    }

    @used
    func removeAll() {
        entries.removeAll()
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
        guard let device = entries[deviceIdentifier]?.object as? DeviceReference else {
            preconditionFailure("Only for a device in the registry")
        }
        return WebGPUXRBinding(device.createXRBinding())
    }

    @used
    func hasDevice(_ identifier: UInt64) -> Bool {
        entries[identifier]?.object is DeviceReference
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

    // Adds an object that Swift owns, with its receiver and the registration that keeps the receiver's messages coming.
    @_expose(!Cxx)
    func add(_ identifier: UInt64, _ object: AnyObject, receiver: AnyObject, registration: WebKit.WebGPUSwiftReceiverRegistration?) {
        entries[identifier] = Entry(object, receiver: receiver, registration: registration)
    }

    // The object with that identifier, if there is one of that type.
    @_expose(!Cxx)
    func object<Object: AnyObject>(_ identifier: IPCTypes.WebGPUIdentifier, as: Object.Type) -> Object? {
        entries[identifier.rawValue]?.object as? Object
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
