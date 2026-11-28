//
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
//

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// those operators take, so they are imported for the operator lookup to resolve (rdar://192229293).
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.ExceptionCode
internal import WebCore_Private.Core.IDBCursorInfo
internal import WebCore_Private.Core.IDBError
internal import WebCore_Private.Core.IDBGetAllRecordsData
internal import WebCore_Private.Core.IDBGetRecordData
internal import WebCore_Private.Core.IDBIndexIdentifier
internal import WebCore_Private.Core.IDBIndexInfo
internal import WebCore_Private.Core.IDBIterateCursorData
internal import WebCore_Private.Core.IDBKeyData
internal import WebCore_Private.Core.IDBKeyPath
internal import WebCore_Private.Core.IDBKeyRangeData
internal import WebCore_Private.Core.IDBObjectStoreIdentifier
internal import WebCore_Private.Core.IDBObjectStoreInfo
internal import WebCore_Private.Core.IDBRequestData
internal import WebCore_Private.Core.IDBResultData
internal import WebCore_Private.Core.IDBValue
internal import WebCore_Private.Core.IndexKey
internal import WebCore_Private.Core.IndexedDB
internal import WebCore_Private.Core.SwiftIDBTypes

extension UniqueIDBDatabase {
    static func estimateSize(_ key: WebCore.IDBKeyData) -> UInt64 {
        var size: UInt64 = 4
        switch key.type() {
        case .String:
            size &+= UInt64(key.string().sizeInBytes())
        case .Binary:
            size &+= UInt64(key.binaryValue().size())
        case .Array:
            let elements: Span<WebCore.IDBKeyData> = WebCore.idbKeyArrayElements(key)
            for i in elements.indices {
                size &+= estimateSize(elements[i])
            }
        default:
            break
        }
        return size
    }

    static func estimateSize(
        _ info: WebCore.IDBObjectStoreInfo,
        indexKeys: WebCore.IndexIDToIndexKeyMap,
        primaryKeySize: UInt64
    ) -> UInt64 {
        // Each IndexRecord has 5 columns:
        //  - indexID, objectStoreID, recordID: these are varints, estimate 4 bytes each = 12 bytes
        //  - primary key: use primaryKeySize
        //  - secondary index key: use estimateSize(secondary key)
        let baseIndexRowSize: UInt64 = 12
        var size: UInt64 = 0

        let entriesVector = WebCore.idbIndexKeyMapEntries(indexKeys)
        let entries: Span<WebCore.IDBIndexKeyMapEntry> = WebCore.idbIndexKeyMapEntryElements(entriesVector)
        for i in entries.indices {
            let indexInfo = WebCore.idbObjectStoreInfoIndex(info, entries[i].identifier).value
            assert(indexInfo != nil)

            if let indexInfo, indexInfo.multiEntry() {
                let secondaryKeys = entries[i].key.multiEntry()
                let secondaryKeyElements: Span<WebCore.IDBKeyData> = WebCore.idbKeyVectorElements(secondaryKeys)
                for j in secondaryKeyElements.indices {
                    size &+= baseIndexRowSize &+ primaryKeySize &+ estimateSize(secondaryKeyElements[j])
                }
            } else {
                size &+= baseIndexRowSize &+ primaryKeySize &+ estimateSize(entries[i].key.asOneKey())
            }
        }

        return size
    }

    static func estimateSize(_ value: WebCore.IDBValue) -> UInt64 {
        var size: UInt64 = 4
        size &+= UInt64(value.dataValue().size())
        let blobURLs = value.blobURLsValue()
        for i in 0..<WebCore.idbStringVectorSize(blobURLs) {
            size &+= UInt64(WebCore.idbStringVectorAt(blobURLs, i).sizeInBytes())
        }
        let blobFilePaths = value.blobFilePathsValue()
        for i in 0..<WebCore.idbStringVectorSize(blobFilePaths) {
            size &+= UInt64(WebCore.idbStringVectorAt(blobFilePaths, i).sizeInBytes())
        }
        return size
    }

    static func estimateSize(_ keyPath: WebCore.IDBKeyPath) -> UInt64 {
        let paths = WebCore.idbKeyPathStrings(keyPath)
        var size: UInt64 = 0
        for i in 0..<WebCore.idbStringVectorSize(paths) {
            size &+= UInt64(WebCore.idbStringVectorAt(paths, i).sizeInBytes())
        }
        return size
    }

    static func estimateSize(_ info: WebCore.IDBIndexInfo) -> UInt64 {
        var size: UInt64 = 4
        size &+= UInt64(WebCore.idbIndexInfoName(info).sizeInBytes())
        size &+= estimateSize(info.keyPathValue())
        return size
    }

    static func estimateSize(_ info: WebCore.IDBObjectStoreInfo) -> UInt64 {
        var size: UInt64 = 4
        size &+= UInt64(WebCore.idbObjectStoreInfoName(info).sizeInBytes())
        if let keyPath = WebCore.idbObjectStoreInfoKeyPath(info).value {
            size &+= estimateSize(keyPath)
        }
        return size
    }
}
