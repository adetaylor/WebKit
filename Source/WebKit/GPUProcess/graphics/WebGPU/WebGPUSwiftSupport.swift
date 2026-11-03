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

// The registry of the WebGPU objects of a RemoteGPU that Swift owns, by identifier, with their receivers, and of the
// references to objects of the RemoteGPU's object heap that Swift receivers made or looked up. Used only on the
// RemoteGPU's work queue, as the heap is.
//
// The registry owns the objects that Swift makes and receives the messages of: their references, receivers and
// registrations, which a receiver removes when the web process destructs its object. The object heap stays the
// authority on the objects that C++ receivers own: it removes an identifier here whenever it removes its own entry,
// and empties the registry when it's cleared or destroyed, so the registry never keeps a reference to one of those
// longer than the heap keeps the object.
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
    private var entries: [UInt64: Entry] = [:]

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(host: WebKit.WebGPUSwiftRegistryHost) {
        self.host = host
    }

    @used
    func remove(_ identifier: UInt64) {
        entries[identifier] = nil
    }

    @used
    func removeAll() {
        entries.removeAll()
    }

    // Makes the receivers of a device that the adapter made, and of its queue.
    @used
    func addDevice(_ backing: WebKit.RemoteDeviceBacking, _ identifier: UInt64, _ queueIdentifier: UInt64) {
        let device = WebGPUSwift.reference(of: backing.get())
        host.trackDevice(backing.get())
        let receiver = RemoteDevice(device, link: WebGPURegistryLink(self, identifier))
        add(identifier, device, receiver: receiver, registration: WebKit.registerWebGPUSwiftReceiver(host, receiver.getMessageReceiver(), .RemoteDevice, identifier))
        RemoteQueue.add(device.queue, WebGPURegistryLink(self, queueIdentifier))
    }

    // The objects that Swift owns, for the C++ receivers that name them.
    @used
    func buffer(_ identifier: UInt64) -> WebKit.OptionalRemoteBufferBacking {
        guard let buffer = entries[identifier]?.object as? BufferReference else {
            return .init()
        }
        return .init(WebKit.RemoteBufferBacking(buffer.apiObject))
    }

    @used
    func device(_ identifier: UInt64) -> WebKit.OptionalRemoteDeviceBacking {
        guard let device = entries[identifier]?.object as? DeviceReference else {
            return .init()
        }
        return .init(WebKit.RemoteDeviceBacking(device.apiObject))
    }

    @used
    func querySet(_ identifier: UInt64) -> WebKit.OptionalRemoteQuerySetBacking {
        guard let querySet = entries[identifier]?.object as? QuerySetReference else {
            return .init()
        }
        return .init(WebKit.RemoteQuerySetBacking(querySet.apiObject))
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

    // Keeps the reference to an object of the object heap that Swift made, until the heap removes it.
    @_expose(!Cxx)
    func addReference(_ identifier: UInt64, _ object: AnyObject) {
        entries[identifier] = Entry(object, receiver: nil, registration: nil)
    }

    // The object with that identifier, if there is one of that type.
    @_expose(!Cxx)
    func object<Object: AnyObject>(_ identifier: IPCTypes.WebGPUIdentifier, as: Object.Type) -> Object? {
        entries[identifier.rawValue]?.object as? Object
    }

    // The object with that identifier, which lookUp() finds in the object heap the first time. nil if there's no such
    // object, or an object of another kind.
    @_expose(!Cxx)
    func object<Object: AnyObject>(_ identifier: IPCTypes.WebGPUIdentifier, _ lookUp: () -> Object?) -> Object? {
        if let entry = entries[identifier.rawValue] {
            return entry.object as? Object
        }
        guard let object = lookUp() else {
            return nil
        }
        addReference(identifier.rawValue, object)
        return object
    }

    // The objects that C++ receivers still make, which Swift receivers name.
    @_expose(!Cxx)
    func commandBuffer(_ identifier: IPCTypes.WebGPUIdentifier) -> CommandBufferReference? {
        object(identifier) {
            host.commandBuffer(identifier.rawValue).map { WebGPUSwift.reference(of: $0) }
        }
    }

    @_expose(!Cxx)
    func texture(_ identifier: IPCTypes.WebGPUIdentifier) -> TextureReference? {
        object(identifier) {
            host.texture(identifier.rawValue).map { WebGPUSwift.reference(of: $0) }
        }
    }

    @_expose(!Cxx)
    func textureView(_ identifier: IPCTypes.WebGPUIdentifier) -> TextureViewReference? {
        object(identifier) {
            host.textureView(identifier.rawValue).map { WebGPUSwift.reference(of: $0) }
        }
    }
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
// object, and the objects its messages name. Weak, so that work still in flight when the registry has gone finds nothing.
struct WebGPURegistryLink {
    private(set) weak var objects: WebGPUImplTable?
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
