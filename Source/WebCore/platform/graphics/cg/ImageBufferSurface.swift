// Copyright (C) 2020-2023 Apple Inc. All rights reserved.
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
//
// Copyright (C) 2020-2024 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT && USE_CG

import CoreGraphics
#if HAVE_IOSURFACE
import IOSurface
#endif
import Synchronization
import WebCore_Private.Core.ImageBufferBackend
import WebCore_Private.Core.ImageBufferSurface
#if HAVE_IOSURFACE
import WebCore_Private.Core.IOSurface
import WebCore_Private.Core.IOSurfacePool
#endif

private let contextFlushCount = Atomic<UInt64>(0)
private let cachedImageInvalidationCount = Atomic<UInt64>(0)
private let drawingCommandSubmissionCount = Atomic<UInt64>(0)
private let imageCreationCount = Atomic<UInt64>(0)
private let imageReferenceCreationCount = Atomic<UInt64>(0)
private let imageSinkCount = Atomic<UInt64>(0)
private let displayCopyCount = Atomic<UInt64>(0)

private func count(_ counter: borrowing Atomic<UInt64>) {
    counter.wrappingAdd(1, ordering: .relaxed)
}

// The surface of an ImageBufferCGBackend and its state: an IOSurface with the context that draws into it, when Core
// Graphics must flush it and invalidate the images of it, and its volatility; or a bitmap context and the data provider
// that owns its memory. WebCore::ImageBufferSurface is a facade over it for the C++ backends.
// It isn't Sendable: like the backend that owns it, it's used on one thread at a time.
// The context of a surface, in a class, so that a call that draws through it borrows it rather than retaining it.
private final class PlatformContextHolder {
    let platformContext: IOSurfacePlatformContext

    init(_ platformContext: IOSurfacePlatformContext) {
        self.platformContext = platformContext
    }
}

final class ImageBufferSurfaceCore {
    struct BitmapConfiguration {
        let bitsPerComponent: Int
        let bitsPerPixel: Int
        let bytesPerRow: Int
        let bitmapInfo: CGBitmapInfo
    }

    private enum Storage {
        #if HAVE_IOSURFACE
        case ioSurface(IOSurfaceCore)
        #endif
        case bitmap(CGContext, CGDataProvider, BitmapConfiguration)
        case sunk
    }

    let width: Int32
    let height: Int32
    private let colorSpace: CGColorSpace
    private var storage: Storage

    #if HAVE_IOSURFACE
    private let format: IOSurfaceFormat
    private let useLosslessCompression: Bool
    private let displayID: UInt32
    private let useWebKitBehavior: Bool
    private var pool: IOSurfacePoolCore?
    private var platformContext: PlatformContextHolder?
    private var displayCopySendRight = mach_port_t(MACH_PORT_NULL)
    private var needsFirstFlush = true
    private var mayHaveOutstandingBackingStoreReferences = false
    private(set) var volatilityState: WebCore.VolatilityState = .NonVolatile

    init(surface: IOSurfaceCore, pool: IOSurfacePoolCore?, format: IOSurfaceFormat, useLosslessCompression: Bool, displayID: UInt32, useWebKitBehavior: Bool) {
        self.width = surface.width
        self.height = surface.height
        self.colorSpace = surface.colorSpace
        self.storage = .ioSurface(surface)
        self.format = format
        self.useLosslessCompression = useLosslessCompression
        self.displayID = displayID
        self.useWebKitBehavior = useWebKitBehavior
        self.pool = pool
    }
    #endif

    init(context: CGContext, provider: CGDataProvider, colorSpace: CGColorSpace, width: Int32, height: Int32, configuration: BitmapConfiguration) {
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        self.storage = .bitmap(context, provider, configuration)
        #if HAVE_IOSURFACE
        self.format = .BGRA
        self.useLosslessCompression = false
        self.displayID = 0
        self.useWebKitBehavior = false
        #endif
    }

    private var bounds: CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    }

    var context: CGContext {
        switch storage {
        #if HAVE_IOSURFACE
        case .ioSurface(let surface):
            return ensurePlatformContext(surface).platformContext.context
        #endif
        case .bitmap(let context, _, _):
            return context
        case .sunk:
            preconditionFailure("The surface was sunk into an image")
        }
    }

    // An immutable copy of the drawing so far. Consumers may hold on to it, so a later write through the surface must
    // first invalidate the images of it.
    func createImage() -> CGImage? {
        switch storage {
        #if HAVE_IOSURFACE
        case .ioSurface(let surface):
            mayHaveOutstandingBackingStoreReferences = true
            count(imageCreationCount)
            let holder = ensurePlatformContext(surface)
            return surface.createImage(holder.platformContext)
        #endif
        case .bitmap(let context, _, _):
            return context.makeImage()
        case .sunk:
            return nil
        }
    }

    // An image of the surface that only lasts until the next draw into it.
    func createImageReference() -> CGImage? {
        switch storage {
        #if HAVE_IOSURFACE
        case .ioSurface(let surface):
            // The reference is used only synchronously, so a later write needs no invalidation, and
            // mayHaveOutstandingBackingStoreReferences stays as it is.
            count(imageReferenceCreationCount)
            let holder = ensurePlatformContext(surface)
            // The context is one of this surface's. An image made again for every use gets no hits from Core Graphics'
            // per-image caches, nor from GraphicsContext's subimage cache.
            return unsafe WebCore.ioSurfaceContextCreateImageReference(holder.platformContext.context, true)
        #endif
        case .bitmap(_, let provider, let configuration):
            // No decode array.
            return unsafe CGImage(
                width: Int(width),
                height: Int(height),
                bitsPerComponent: configuration.bitsPerComponent,
                bitsPerPixel: configuration.bitsPerPixel,
                bytesPerRow: configuration.bytesPerRow,
                space: colorSpace,
                bitmapInfo: configuration.bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        case .sunk:
            return nil
        }
    }

    #if HAVE_IOSURFACE
    private func ensurePlatformContext(_ surface: IOSurfaceCore) -> PlatformContextHolder {
        if let platformContext {
            return platformContext
        }
        guard let context = surface.createPlatformContext(displayID: displayID, useWebKitBehavior: useWebKitBehavior) else {
            preconditionFailure("Failed to create the context of an ImageBuffer's IOSurface")
        }
        let holder = PlatformContextHolder(context)
        platformContext = holder
        return holder
    }

    private var surface: IOSurfaceCore? {
        guard case .ioSurface(let surface) = storage else {
            return nil
        }
        return surface
    }

    // Makes the context of an accelerated backend's surface: false if it can't.
    fileprivate func createPlatformContext() -> Bool {
        guard let surface, platformContext == nil else {
            return false
        }
        guard let context = surface.createPlatformContext(displayID: displayID, useWebKitBehavior: useWebKitBehavior) else {
            return false
        }
        platformContext = PlatformContextHolder(context)
        return true
    }

    fileprivate func clear() {
        context.clear(bounds)
    }

    func releasePlatformContext() {
        platformContext = nil
    }

    // Flushes the draws through the context, if there are any, and before the first external access. True if it
    // flushed.
    @discardableResult
    func flushContextDraws(contextHasDrawn: Bool) -> Bool {
        guard contextHasDrawn || needsFirstFlush else {
            return false
        }
        needsFirstFlush = false
        count(contextFlushCount)
        context.flush()
        return true
    }

    // Before something other than the context writes to the surface: no image of it, which Core Graphics caches for
    // the context, may still be drawn from, and no draw into it may still be pending.
    func prepareForExternalWrite(contextHasDrawn: Bool) {
        var needsFlush = false
        if mayHaveOutstandingBackingStoreReferences {
            needsFlush = invalidateCachedImage()
            mayHaveOutstandingBackingStoreReferences = false
        }
        // The invalidation marker makes the draws from the surface complete before it does, so flushing the context
        // completes both.
        if flushContextDraws(contextHasDrawn: contextHasDrawn) {
            needsFlush = false
        }
        if needsFlush {
            count(contextFlushCount)
            context.flush()
        }
    }

    var hasOutstandingBackingStoreReferences: Bool {
        mayHaveOutstandingBackingStoreReferences
    }

    // Makes QuartzCore drop the image of the surface it caches, which the surface no longer matches once it's written
    // to (https://webkit.org/b/157966, https://webkit.org/b/228682). True if a flush must complete it.
    private func invalidateCachedImage() -> Bool {
        count(cachedImageInvalidationCount)
        let context = self.context
        // The context is one of this surface's.
        if unsafe WebCore.ioSurfaceContextInvalidateSurface(context) {
            return false
        }
        context.fill(CGRect.zero)
        return true
    }

    func submitDrawingCommands() {
        count(drawingCommandSubmissionCount)
        // The context is one of this surface's.
        if unsafe WebCore.ioSurfaceContextFlushQueue(context) {
            return
        }
        // Making an image makes the rendering start.
        _ = createImage()
    }

    func sinkIntoImage() -> CGImage? {
        guard let surface else {
            return nil
        }
        count(imageSinkCount)
        let context = ensurePlatformContext(surface)
        platformContext = nil
        storage = .sunk
        return IOSurfaceCore.sinkIntoImage(surface, context: context.platformContext)
    }

    func setVolatile() -> Bool {
        guard let surface else {
            return true
        }
        if surface.isInUse {
            return false
        }
        if volatilityState == .Volatile {
            assert(surface.isVolatile)
            return true
        }
        volatilityState = .Volatile
        surface.setVolatile(true)
        return true
    }

    func setNonVolatile() -> WebCore.SetNonVolatileResult {
        guard let surface else {
            return .Valid
        }
        guard volatilityState == .Volatile else {
            assert(!surface.isVolatile)
            return .Valid
        }
        volatilityState = .NonVolatile
        let previousState = surface.setVolatile(false)
        if previousState == .Empty {
            let context = self.context
            assert(context.ctm.isIdentity)
            context.clear(bounds)
        }
        return previousState
    }

    func setVolatilityState(_ state: WebCore.VolatilityState) {
        volatilityState = state
    }

    func setPool(_ pool: IOSurfacePoolCore?) {
        self.pool = pool
    }

    func takeDisplayCopySendRight() -> mach_port_t {
        defer {
            displayCopySendRight = mach_port_t(MACH_PORT_NULL)
        }
        return displayCopySendRight
    }

    func moveSurfaceToPool() {
        guard let surface else {
            return
        }
        platformContext = nil
        storage = .sunk
        pool?.addSurface(surface)
    }

    // A copy of the surface, drawn into a surface from the pool, which goes back to the pool; for the layer, the context
    // that drew it, which the layer flushes before it shows the copy, and the copy's send right, which
    // takeDisplayCopySendRight() hands over.
    func createDisplayCopy() -> CGContext? {
        count(displayCopyCount)
        guard let image = createImage() else {
            return nil
        }
        guard let displaySurface = IOSurfaceCore.create(pool: pool, width: width, height: height, colorSpace: colorSpace, name: .ImageBuffer, format: format, useLosslessCompression: useLosslessCompression) else {
            return nil
        }
        defer {
            pool?.addSurface(displaySurface)
        }
        guard let displayContext = displaySurface.createPlatformContext(displayID: displayID)?.context else {
            return nil
        }
        displayContext.setBlendMode(.copy)
        displayContext.draw(image, in: bounds)
        displayCopySendRight = IOSurfaceCreateMachPort(displaySurface.surface)
        return displayContext
    }
    #endif
}

extension ImageBufferSurfaceCore {
    // The core a facade's swiftState refers to, which the facade keeps alive.
    fileprivate static func borrowed(_ swiftState: UInt) -> ImageBufferSurfaceCore {
        unsafe Unmanaged<ImageBufferSurfaceCore>.fromOpaque(UnsafeRawPointer(bitPattern: swiftState)!).takeUnretainedValue()
    }

    fileprivate static func retained(_ core: ImageBufferSurfaceCore) -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(core).toOpaque())
    }
}

extension WebCore.ImageBufferSurface {
    #if HAVE_IOSURFACE
    @cxx
    @implementation
    static func createIOSurfaceSwiftState(
        _ surfaceState: UInt,
        _ poolState: UInt,
        _ format: WebCore.IOSurface.Format,
        _ useLosslessCompression: WebCore.UseLosslessCompression,
        _ displayID: UInt32,
        _ useWebKitBehavior: Bool,
        _ shouldClear: Bool
    ) -> UInt {
        let surface = IOSurfaceCore.borrowed(surfaceState)
        let core = ImageBufferSurfaceCore(
            surface: surface,
            pool: IOSurfacePoolCore.borrowed(poolState),
            format: format,
            useLosslessCompression: useLosslessCompression == .Yes,
            displayID: displayID,
            useWebKitBehavior: useWebKitBehavior
        )
        guard core.createPlatformContext() else {
            return 0
        }
        if shouldClear {
            core.clear()
        }
        return ImageBufferSurfaceCore.retained(core)
    }
    #endif

    @cxx
    @implementation
    static func createBitmapSwiftState(
        _ context: CGContext?,
        _ provider: CGDataProvider?,
        _ colorSpace: CGColorSpace?,
        _ width: Int32,
        _ height: Int32,
        _ bitsPerComponent: Int,
        _ bitsPerPixel: Int,
        _ bytesPerRow: Int,
        _ bitmapInfo: UInt32
    ) -> UInt {
        guard let context, let provider, let colorSpace else {
            return 0
        }
        let configuration = ImageBufferSurfaceCore.BitmapConfiguration(
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo)
        )
        return ImageBufferSurfaceCore.retained(ImageBufferSurfaceCore(context: context, provider: provider, colorSpace: colorSpace, width: width, height: height, configuration: configuration))
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        unsafe Unmanaged<ImageBufferSurfaceCore>.fromOpaque(UnsafeRawPointer(bitPattern: swiftState)!).release()
    }

    @cxx
    @implementation
    static func swiftPlatformContext(_ swiftState: UInt) -> Unmanaged<CGContext>? {
        unsafe Unmanaged.passRetained(ImageBufferSurfaceCore.borrowed(swiftState).context)
    }

    @cxx
    @implementation
    static func swiftCreateImage(_ swiftState: UInt) -> Unmanaged<CGImage>? {
        guard let image = ImageBufferSurfaceCore.borrowed(swiftState).createImage() else {
            return nil
        }
        return unsafe Unmanaged.passRetained(image)
    }

    @cxx
    @implementation
    static func swiftCreateImageReference(_ swiftState: UInt) -> Unmanaged<CGImage>? {
        guard let image = ImageBufferSurfaceCore.borrowed(swiftState).createImageReference() else {
            return nil
        }
        return unsafe Unmanaged.passRetained(image)
    }

    #if HAVE_IOSURFACE
    @cxx
    @implementation
    static func swiftFlushContextDraws(_ swiftState: UInt, _ contextHasDrawn: Bool) -> Bool {
        ImageBufferSurfaceCore.borrowed(swiftState).flushContextDraws(contextHasDrawn: contextHasDrawn)
    }

    @cxx
    @implementation
    static func swiftPrepareForExternalWrite(_ swiftState: UInt, _ contextHasDrawn: Bool) {
        ImageBufferSurfaceCore.borrowed(swiftState).prepareForExternalWrite(contextHasDrawn: contextHasDrawn)
    }

    @cxx
    @implementation
    static func swiftMayHaveOutstandingBackingStoreReferences(_ swiftState: UInt) -> Bool {
        ImageBufferSurfaceCore.borrowed(swiftState).hasOutstandingBackingStoreReferences
    }

    @cxx
    @implementation
    static func swiftSubmitDrawingCommands(_ swiftState: UInt) {
        ImageBufferSurfaceCore.borrowed(swiftState).submitDrawingCommands()
    }

    @cxx
    @implementation
    static func swiftSinkIntoImage(_ swiftState: UInt) -> Unmanaged<CGImage>? {
        guard let image = ImageBufferSurfaceCore.borrowed(swiftState).sinkIntoImage() else {
            return nil
        }
        return unsafe Unmanaged.passRetained(image)
    }

    @cxx
    @implementation
    static func swiftReleasePlatformContext(_ swiftState: UInt) {
        ImageBufferSurfaceCore.borrowed(swiftState).releasePlatformContext()
    }

    @cxx
    @implementation
    static func swiftSetVolatile(_ swiftState: UInt) -> Bool {
        ImageBufferSurfaceCore.borrowed(swiftState).setVolatile()
    }

    @cxx
    @implementation
    static func swiftSetNonVolatile(_ swiftState: UInt) -> WebCore.SetNonVolatileResult {
        ImageBufferSurfaceCore.borrowed(swiftState).setNonVolatile()
    }

    @cxx
    @implementation
    static func swiftVolatilityState(_ swiftState: UInt) -> WebCore.VolatilityState {
        ImageBufferSurfaceCore.borrowed(swiftState).volatilityState
    }

    @cxx
    @implementation
    static func swiftSetVolatilityState(_ swiftState: UInt, _ state: WebCore.VolatilityState) {
        ImageBufferSurfaceCore.borrowed(swiftState).setVolatilityState(state)
    }

    @cxx
    @implementation
    static func swiftSetSurfacePool(_ swiftState: UInt, _ poolState: UInt) {
        ImageBufferSurfaceCore.borrowed(swiftState).setPool(IOSurfacePoolCore.borrowed(poolState))
    }

    @cxx
    @implementation
    static func swiftMoveSurfaceToPool(_ swiftState: UInt) {
        ImageBufferSurfaceCore.borrowed(swiftState).moveSurfaceToPool()
    }

    @cxx
    @implementation
    static func swiftCreateDisplayCopy(_ swiftState: UInt) -> Unmanaged<CGContext>? {
        unsafe ImageBufferSurfaceCore.borrowed(swiftState).createDisplayCopy().map { unsafe Unmanaged.passRetained($0) }
    }

    @cxx
    @implementation
    static func swiftTakeDisplayCopySendRight(_ swiftState: UInt) -> mach_port_t {
        ImageBufferSurfaceCore.borrowed(swiftState).takeDisplayCopySendRight()
    }
    #endif

    @cxx
    @implementation
    static func swiftCountForTesting(_ index: UInt32) -> UInt64 {
        switch index {
        case 0: contextFlushCount.load(ordering: .relaxed)
        case 1: cachedImageInvalidationCount.load(ordering: .relaxed)
        case 2: drawingCommandSubmissionCount.load(ordering: .relaxed)
        case 3: imageCreationCount.load(ordering: .relaxed)
        case 4: imageReferenceCreationCount.load(ordering: .relaxed)
        case 5: imageSinkCount.load(ordering: .relaxed)
        case 6: displayCopyCount.load(ordering: .relaxed)
        default: 0
        }
    }
}

#endif // ENABLE_WEBCORE_SWIFT && USE_CG
