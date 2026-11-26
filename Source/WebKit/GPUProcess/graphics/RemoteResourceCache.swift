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

#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_RENDERING_BACKEND_SWIFT

#if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
@_spi(WebKitGPU) internal import WebCore
#endif
import WebCore_Private
import WebKit_Internal

#if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
typealias RemoteResourceCacheFont = RemoteCGRendererFont
typealias RemoteResourceCacheFilter = RemoteCGRendererCachedFilter
#else
// The C++ drawing reads the cached fonts and filters themselves (RemoteGraphicsContext).
typealias RemoteResourceCacheFont = WebKit.SharedFont
typealias RemoteResourceCacheFilter = WebCore.Filter
#endif

// Reads the value stored under a defaulted subscript, adding it if missing.
func storedValue<Value>(_ value: inout Value) -> Value {
    value
}

// An identifier that the web process names a display list or a recorder by, as the key of a dictionary that messages look up,
// which hashes it as a C++ HashMap hashes an integer rather than with Hasher.
struct RemoteIdentifierKey: Hashable {
    let value: UInt64

    func hash(into hasher: inout Swift.Hasher) {
        hasher.combine(value)
    }

    // swift-format-ignore: NoLeadingUnderscores
    func _rawHashValue(seed: Int) -> Int {
        var bits = value
        bits ^= bits >> 33
        bits &*= 0xff51_afd7_ed55_8ccd
        bits ^= UInt64(UInt(bitPattern: seed))
        bits ^= bits >> 33
        bits &*= 0xc4ce_b9fe_1a85_ec53
        bits ^= bits >> 33
        return Int(truncatingIfNeeded: bits)
    }
}

// The resources that a rendering backend's web process caches for its draws, by identifier, on the backend's work queue:
// what RemoteCGRenderer looks up for a draw that names one (RemoteCGRendererResources), and what a recorder keeps of them.
// A cache or a release of an identifier that the cache already has, or doesn't have, is an invalid message.
final class RemoteResourceCache {
    private var paths: [RemoteIdentifierKey: WebCore.PathImpl] = [:]
    private var gradients: [RemoteIdentifierKey: WebCore.Gradient] = [:]
    private var meshGradients: [RemoteIdentifierKey: WebCore.MeshGradient] = [:]
    private var fonts: [RemoteIdentifierKey: RemoteResourceCacheFont] = [:]
    private var fontCustomPlatformDatas: [RemoteIdentifierKey: WebCore.FontCustomPlatformData] = [:]
    // The draws keep their own state of a cached filter, which is all they need of it.
    private var filters: [RemoteIdentifierKey: RemoteResourceCacheFilter] = [:]
    #if !ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
    private var displayLists: [RemoteIdentifierKey: WebCore.DisplayList.DisplayList] = [:]
    #endif

    func path(key: UInt64) -> WebCore.PathImpl? {
        paths[RemoteIdentifierKey(value: key)]
    }

    func gradient(key: UInt64) -> WebCore.Gradient? {
        gradients[RemoteIdentifierKey(value: key)]
    }

    func meshGradient(key: UInt64) -> WebCore.MeshGradient? {
        meshGradients[RemoteIdentifierKey(value: key)]
    }

    func font(key: UInt64) -> RemoteResourceCacheFont? {
        fonts[RemoteIdentifierKey(value: key)]
    }

    func filter(key: UInt64) -> RemoteResourceCacheFilter? {
        filters[RemoteIdentifierKey(value: key)]
    }

    fileprivate func cachePath(_ path: WebCore.PathImpl, key: UInt64) -> Bool {
        RemoteResourceCache.add(path, key, to: &paths)
    }

    fileprivate func releasePath(key: UInt64) -> Bool {
        RemoteResourceCache.remove(key, from: &paths)
    }

    fileprivate func cacheGradient(_ gradient: WebCore.Gradient, key: UInt64) -> Bool {
        RemoteResourceCache.add(gradient, key, to: &gradients)
    }

    fileprivate func releaseGradient(key: UInt64) -> Bool {
        RemoteResourceCache.remove(key, from: &gradients)
    }

    fileprivate func cacheMeshGradient(_ gradient: WebCore.MeshGradient, key: UInt64) -> Bool {
        RemoteResourceCache.add(gradient, key, to: &meshGradients)
    }

    fileprivate func releaseMeshGradient(key: UInt64) -> Bool {
        RemoteResourceCache.remove(key, from: &meshGradients)
    }

    fileprivate func cacheFont(_ font: RemoteResourceCacheFont, key: UInt64) -> Bool {
        RemoteResourceCache.add(font, key, to: &fonts)
    }

    fileprivate func releaseFont(key: UInt64) -> Bool {
        RemoteResourceCache.remove(key, from: &fonts)
    }

    fileprivate func fontCustomPlatformData(key: UInt64) -> WebCore.FontCustomPlatformData? {
        fontCustomPlatformDatas[RemoteIdentifierKey(value: key)]
    }

    fileprivate func cacheFontCustomPlatformData(_ data: WebCore.FontCustomPlatformData, key: UInt64) -> Bool {
        RemoteResourceCache.add(data, key, to: &fontCustomPlatformDatas)
    }

    fileprivate func releaseFontCustomPlatformData(key: UInt64) -> Bool {
        RemoteResourceCache.remove(key, from: &fontCustomPlatformDatas)
    }

    #if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
    fileprivate func cacheFilter(key: UInt64, isSVGFilter: Bool) -> Bool {
        RemoteResourceCache.add(RemoteResourceCacheFilter(identifier: key, isSVGFilter: isSVGFilter), key, to: &filters)
    }
    #else
    fileprivate func cacheFilter(_ filter: WebCore.Filter, key: UInt64) -> Bool {
        RemoteResourceCache.add(filter, key, to: &filters)
    }

    func displayList(key: UInt64) -> WebCore.DisplayList.DisplayList? {
        displayLists[RemoteIdentifierKey(value: key)]
    }

    fileprivate func cacheDisplayList(_ displayList: WebCore.DisplayList.DisplayList, key: UInt64) -> Bool {
        RemoteResourceCache.add(displayList, key, to: &displayLists)
    }

    fileprivate func releaseDisplayList(key: UInt64) -> Bool {
        RemoteResourceCache.remove(key, from: &displayLists)
    }
    #endif

    fileprivate func releaseFilter(key: UInt64) -> Bool {
        RemoteResourceCache.remove(key, from: &filters)
    }

    // RemoteResourceCache::releaseMemory(). What it removes is released after the change, so that no access to a dictionary
    // can overlap another.
    fileprivate func removeAll() {
        var removedPaths: [RemoteIdentifierKey: WebCore.PathImpl] = [:]
        var removedGradients: [RemoteIdentifierKey: WebCore.Gradient] = [:]
        var removedMeshGradients: [RemoteIdentifierKey: WebCore.MeshGradient] = [:]
        var removedFonts: [RemoteIdentifierKey: RemoteResourceCacheFont] = [:]
        var removedFontCustomPlatformDatas: [RemoteIdentifierKey: WebCore.FontCustomPlatformData] = [:]
        var removedFilters: [RemoteIdentifierKey: RemoteResourceCacheFilter] = [:]
        swap(&paths, &removedPaths)
        swap(&gradients, &removedGradients)
        swap(&meshGradients, &removedMeshGradients)
        swap(&fonts, &removedFonts)
        swap(&fontCustomPlatformDatas, &removedFontCustomPlatformDatas)
        swap(&filters, &removedFilters)
        #if !ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
        var removedDisplayLists: [RemoteIdentifierKey: WebCore.DisplayList.DisplayList] = [:]
        swap(&displayLists, &removedDisplayLists)
        #endif
    }

    // Looks the key up once: the default is made, and added, only for a key that isn't cached.
    private static func add<Value>(_ value: Value, _ key: UInt64, to dictionary: inout [RemoteIdentifierKey: Value]) -> Bool {
        var isAdded = false
        func added() -> Value {
            isAdded = true
            return value
        }
        _ = storedValue(&dictionary[RemoteIdentifierKey(value: key), default: added()])
        return isAdded
    }

    private static func remove<Value>(_ key: UInt64, from dictionary: inout [RemoteIdentifierKey: Value]) -> Bool {
        let removed = dictionary.removeValue(forKey: RemoteIdentifierKey(value: key))
        return removed != nil
    }
}

// The rendering backend's handlers of the messages that cache and release resources (RemoteRenderingBackend.swift), on its work
// queue: false for an identifier already cached, or, for a release, not cached.
extension RemoteRenderingBackendResources {
    func cachePathImpl(_ path: WebCore.PathImpl, key: UInt64) -> Bool {
        cache.cachePath(path, key: key)
    }

    func releasePathImpl(key: UInt64) -> Bool {
        cache.releasePath(key: key)
    }

    func cacheGradient(_ gradient: WebCore.Gradient, key: UInt64) -> Bool {
        cache.cacheGradient(gradient, key: key)
    }

    func releaseGradient(key: UInt64) -> Bool {
        cache.releaseGradient(key: key)
    }

    func cacheMeshGradient(_ gradient: WebCore.MeshGradient, key: UInt64) -> Bool {
        cache.cacheMeshGradient(gradient, key: key)
    }

    func releaseMeshGradient(key: UInt64) -> Bool {
        cache.releaseMeshGradient(key: key)
    }

    func cacheFont(_ font: RemoteResourceCacheFont, key: UInt64) -> Bool {
        cache.cacheFont(font, key: key)
    }

    func releaseFont(key: UInt64) -> Bool {
        cache.releaseFont(key: key)
    }

    func cachedFontCustomPlatformData(key: UInt64) -> WebCore.FontCustomPlatformData? {
        cache.fontCustomPlatformData(key: key)
    }

    func cacheFontCustomPlatformData(_ data: WebCore.FontCustomPlatformData, key: UInt64) -> Bool {
        cache.cacheFontCustomPlatformData(data, key: key)
    }

    func releaseFontCustomPlatformData(key: UInt64) -> Bool {
        cache.releaseFontCustomPlatformData(key: key)
    }

    func cacheFilter(_ filter: WebCore.Filter, key: UInt64) -> Bool {
        #if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
        cache.cacheFilter(key: key, isSVGFilter: filter.isSVGFilterRenderer())
        #else
        cache.cacheFilter(filter, key: key)
        #endif
    }

    #if !ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
    func cacheDisplayList(_ displayList: WebCore.DisplayList.DisplayList, key: UInt64) -> Bool {
        cache.cacheDisplayList(displayList, key: key)
    }

    func releaseDisplayList(key: UInt64) -> Bool {
        cache.releaseDisplayList(key: key)
    }
    #endif

    func releaseFilter(key: UInt64) -> Bool {
        cache.releaseFilter(key: key)
    }

    func filter(key: UInt64) -> RemoteResourceCacheFilter? {
        cache.filter(key: key)
    }

    // RemoteRenderingBackend::releaseMemory(), apart from the display lists.
    func releaseMemoryCaches() {
        cache.removeAll()
    }

    // What the backend releases as it is uninitialized, apart from its image buffers.
    func releaseAllCachedResources() {
        removeAllNativeImages()
        releaseMemoryCaches()
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_RENDERING_BACKEND_SWIFT
