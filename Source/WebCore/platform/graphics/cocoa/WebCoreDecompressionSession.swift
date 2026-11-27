// Copyright (C) 2017 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT

internal import CoreMedia
internal import CoreVideo
internal import Foundation
internal import os
internal import Synchronization
internal import VideoToolbox
import WebCore_Private.Core.CMParsingTypes
import WebCore_Private.Core.VPCodecConfigurationRecord
import WebCore_Private.Core.WebCoreDecompressionSession

private let mediaLog = Logger(subsystem: "com.apple.WebKit", category: "Media")

// WebCoreDecompressionSession::DecodingFlag.
struct DecodingFlags: OptionSet {
    let rawValue: UInt8
    static let nonDisplaying = DecodingFlags(rawValue: 1 << 0)
    static let realTime = DecodingFlags(rawValue: 1 << 1)
    static let enableStereo = DecodingFlags(rawValue: 1 << 2)
    // Fail instead of decoding in software formats the content process can decode.
    static let hardwareOnly = DecodingFlags(rawValue: 1 << 3)
}

func createAlphaSampleBuffer(_ alphaDatas: CFArray, _ colorSample: CMSampleBuffer) -> CMSampleBuffer? {
    let alphaDataArray = alphaDatas as NSArray
    let count = alphaDataArray.count
    guard count != 0, count == CMSampleBufferGetNumSamples(colorSample) else {
        return nil
    }

    let formatDescription = CMSampleBufferGetFormatDescription(colorSample)

    let (createdBlockBuffer, blockBufferStatus) = createEmptyBlockBuffer(capacity: UInt32(truncatingIfNeeded: count))
    guard blockBufferStatus == kCMBlockBufferNoErr, let blockBuffer = createdBlockBuffer else {
        return nil
    }

    var timings: [CMSampleTimingInfo] = []
    var sizes: [Int] = []
    var syncFlags: [Bool] = []
    timings.reserveCapacity(count)
    sizes.reserveCapacity(count)
    syncFlags.reserveCapacity(count)

    for index in 0..<count {
        guard let alphaData = alphaDataArray[index] as? NSData else {
            return nil
        }

        guard let sampleBlockBuffer = WebCore.createCMBlockBufferForData(alphaData as CFData),
            CMBlockBufferAppendBufferReference(blockBuffer, targetBBuf: sampleBlockBuffer, offsetToData: 0, dataLength: 0, flags: 0)
                == kCMBlockBufferNoErr
        else {
            return nil
        }

        guard let timing = sampleTimingInfo(of: colorSample, at: index) else {
            return nil
        }
        timings.append(timing)
        sizes.append(alphaData.length)

        #if ENABLE_VP9
        // The alpha stream's keyframes are not guaranteed to align with the
        // color track's, so derive its sync flag from its own bitstream.
        let isSync = WebCore.vpxFrameIsKeyframe(formatDescription.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0, alphaData as CFData)
        #else
        let isSync = false
        #endif
        syncFlags.append(isSync)
    }

    let (createdSampleBuffer, sampleBufferStatus) = makeReadySampleBuffer(
        data: blockBuffer,
        format: formatDescription,
        count: count,
        timings: timings,
        sizes: sizes
    )
    guard sampleBufferStatus == noErr, let sampleBuffer = createdSampleBuffer else {
        return nil
    }

    if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
        CFArrayGetCount(attachmentsArray) == count
    {
        for index in 0..<count where !syncFlags[index] {
            // swift-format-ignore: NeverForceUnwrap
            let attachments = (attachmentsArray as NSArray)[index] as! NSMutableDictionary
            WebCore.setSampleAttachment(
                attachments as CFMutableDictionary,
                CoreMediaSoftLink.kCMSampleAttachmentKey_NotSync,
                kCFBooleanTrue
            )
        }
    }

    return sampleBuffer
}

func createSampleBufferWithPixelBuffer(
    _ pixelBuffer: CVPixelBuffer,
    _ sourceSampleBuffer: CMSampleBuffer,
    _ description: CMFormatDescription?
) -> CMSampleBuffer? {
    guard let description else {
        return nil
    }

    let timing = CMSampleTimingInfo(
        duration: CMSampleBufferGetOutputDuration(sourceSampleBuffer),
        presentationTimeStamp: CMSampleBufferGetOutputPresentationTimeStamp(sourceSampleBuffer),
        decodeTimeStamp: CMSampleBufferGetOutputPresentationTimeStamp(sourceSampleBuffer)
    )
    let (createdSampleBuffer, status) = makeReadySampleBufferWithImageBuffer(
        imageBuffer: castBuffer(pixelBuffer, to: CVBuffer.self),
        format: description,
        timing: timing
    )
    guard status == noErr, let sampleBuffer = createdSampleBuffer else {
        return nil
    }

    if let sourceAttachments = CMSampleBufferGetSampleAttachmentsArray(sourceSampleBuffer, createIfNecessary: false),
        CFArrayGetCount(sourceAttachments) != 0
    {
        if let destAttachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
            CFArrayGetCount(destAttachments) != 0
        {
            // swift-format-ignore: NeverForceUnwrap
            let sourceDictionary = (sourceAttachments as NSArray)[0] as! NSDictionary
            // swift-format-ignore: NeverForceUnwrap
            let destDictionary = (destAttachments as NSArray)[0] as! NSMutableDictionary
            for (key, value) in sourceDictionary {
                destDictionary[key] = value
            }
        }
    }

    return sampleBuffer
}

private struct DecodedPixelFormat {
    let format: OSType
    let isFullRange: Bool
    let isTenBit: Bool
}

private func vpcCFromFormatDescription(_ description: CMFormatDescription?) -> NSData? {
    guard let description, let extensions = CMFormatDescriptionGetExtensions(description) else {
        return nil
    }
    guard
        let atoms = (extensions as NSDictionary)[CoreMediaSoftLink.kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
            as? NSDictionary
    else {
        return nil
    }
    return atoms["vpcC"] as? NSData
}

private func decodedPixelFormat(_ description: CMFormatDescription?) -> DecodedPixelFormat? {
    #if ENABLE_VP9
    guard let configuration = vpcCFromFormatDescription(description) else {
        return nil
    }
    let bytes = configuration as Data
    var record = WebCore.VPCodecFields()
    guard parseVPCC(bytes.span, into: &record) else {
        return nil
    }

    let isFullRange = record.videoFullRangeFlag == WebCore.VPConfigurationRange.FullRange
    let isChroma422 = record.chromaSubsampling == WebCore.VPConfigurationChromaSubsampling.Subsampling_422
    if !isChroma422 && record.chromaSubsampling != WebCore.VPConfigurationChromaSubsampling.Subsampling_420_Vertical
        && record.chromaSubsampling != WebCore.VPConfigurationChromaSubsampling.Subsampling_420_Colocated
    {
        return nil
    }

    switch record.bitDepth {
    case 8:
        if isChroma422 {
            return DecodedPixelFormat(
                format: isFullRange ? kCVPixelFormatType_422YpCbCr8BiPlanarFullRange : kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
                isFullRange: isFullRange,
                isTenBit: false
            )
        }
        return DecodedPixelFormat(
            format: isFullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            isFullRange: isFullRange,
            isTenBit: false
        )
    case 10:
        if isChroma422 {
            return DecodedPixelFormat(
                format: isFullRange ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                isFullRange: isFullRange,
                isTenBit: true
            )
        }
        return DecodedPixelFormat(
            format: isFullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            isFullRange: isFullRange,
            isTenBit: true
        )
    default:
        return nil
    }
    #else
    return nil
    #endif
}

private func pixelBufferAttributesWithFormats(_ formats: NSArray) -> NSDictionary {
    [
        kCVPixelBufferPixelFormatTypeKey: formats,
        kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: kCFBooleanTrue as Any,
        WebCore.pixelBufferPreferRealTimeCacheModeKey() as CFString: kCFBooleanTrue as Any,
        kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(), // empty dictionary
    ]
}

// 8-bit in the stream's range keeps coverage unscaled; an explicit format avoids the hardware decoder's lossless-compressed output.
func alphaDecoderPixelBufferAttributes(isFullRange: Bool) -> NSDictionary {
    pixelBufferAttributesWithFormats([
        NSNumber(value: isFullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    ])
}

// VideoToolbox fails to convert '420f' into 'x0a8' at some sizes (rdar://192565918), so 8-bit full range is merged on the CPU.
func colorDecoderPixelBufferAttributesWithAlpha(_ description: CMFormatDescription?) -> NSDictionary {
    if let format = decodedPixelFormat(description) {
        if format.isFullRange && !format.isTenBit {
            return pixelBufferAttributesWithFormats([NSNumber(value: format.format)])
        }
        if let formatWithAlpha = Optional(fromCxx: WebCore.pixelFormatWithAlpha(format.format)) {
            return pixelBufferAttributesWithFormats([NSNumber(value: formatWithAlpha)])
        }
    }
    return pixelBufferAttributesWithFormats(WebCore.createPixelFormatsWithAlphaPlaneArray() as NSArray)
}

func defaultPixelBufferAttributes() -> NSDictionary {
    [
        kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: kCFBooleanTrue as Any,
        WebCore.pixelBufferPreferRealTimeCacheModeKey() as CFString: kCFBooleanTrue as Any,
        kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(), // empty dictionary
    ]
}

func createMVHEVCVideoLayersArray(_ videoFormatDescription: CMVideoFormatDescription?) -> CFArray? {
    guard let videoFormatDescription else {
        return nil
    }

    // Get the tag collection array
    let (copiedTagCollectionArray, status) = tagCollectionArray(of: videoFormatDescription)
    guard status == noErr else {
        return nil
    }

    // Get the layer IDs to decode
    guard let tagCollections = copiedTagCollectionArray, CFArrayGetCount(tagCollections) > 1 else {
        return nil
    }

    let layersArray = NSMutableArray(capacity: 1)

    // The array's elements are only cast to a CMTagCollection once their type is checked.
    for element in tagCollections as NSArray where CFGetTypeID(element as AnyObject) == CMTagCollectionGetTypeID() {
        // swift-format-ignore: NeverForceUnwrap
        let tagCollection = element as! __CMTagCollection
        let (tagStatus, videoLayerIDTag) = firstTag(of: tagCollection, category: .videoLayerID)
        if tagStatus == noErr, let videoLayerIDTag {
            layersArray.add(NSNumber(value: CMTagGetSInt64Value(videoLayerIDTag)))
        }
    }
    return layersArray as CFArray
}

func createMVHEVCStereoViewMap(_ videoFormatDescription: CMVideoFormatDescription?) -> [Int64: UInt64] {
    guard let videoFormatDescription else {
        return [:]
    }

    // Get the tag collection array
    let (copiedTagCollectionArray, status) = tagCollectionArray(of: videoFormatDescription)
    guard status == noErr else {
        return [:]
    }

    // Get the layer IDs to decode
    guard let tagCollections = copiedTagCollectionArray, CFArrayGetCount(tagCollections) > 1 else {
        return [:]
    }

    var stereoViewMap: [Int64: UInt64] = [:]

    // The array's elements are only cast to a CMTagCollection once their type is checked.
    for element in tagCollections as NSArray where CFGetTypeID(element as AnyObject) == CMTagCollectionGetTypeID() {
        // swift-format-ignore: NeverForceUnwrap
        let tagCollection = element as! __CMTagCollection
        let (layerStatus, videoLayerIDTag) = firstTag(of: tagCollection, category: .videoLayerID)
        if layerStatus == noErr, let videoLayerIDTag {
            let videoLayerID = CMTagGetSInt64Value(videoLayerIDTag)
            let (stereoViewStatus, stereoViewTag) = firstTag(of: tagCollection, category: .stereoView)
            if stereoViewStatus == noErr, let stereoViewTag {
                stereoViewMap[videoLayerID] = CMTagGetFlagsValue(stereoViewTag)
            }
        }
    }
    return stereoViewMap
}

func createTagCollectionRequiredFromVideoToolboxOutput(
    _ bufferGroup: __CMTaggedBufferGroup,
    _ layerIDToStereoViewTable: [Int64: UInt64]
) -> [__CMTagCollection]? {
    let bufferGroupCount = CMTaggedBufferGroupGetCount(bufferGroup)
    var tagCollections: [__CMTagCollection] = []
    tagCollections.reserveCapacity(bufferGroupCount)

    for index in 0..<bufferGroupCount {
        guard let tagCollection = CMTaggedBufferGroupGetTagCollectionAtIndex(bufferGroup, index) else {
            return nil
        }

        let (_, copiedTag) = firstTag(of: tagCollection, category: .videoLayerID)
        guard let videoLayerIDTag = copiedTag, !CMTagEqualToTag(CoreMediaSoftLink.kCMTagInvalid, videoLayerIDTag).boolValue else {
            mediaLog.error("Unable to retrieve CMTagCollection")
            return nil
        }
        let videoLayerValue = Int64(bitPattern: videoLayerIDTag.value)
        guard let stereoViewValue = layerIDToStereoViewTable[videoLayerValue] else {
            mediaLog.error("Unable to find stereoView mapping for layer:\(videoLayerValue)")
            return nil
        }
        let stereoView = CMTagMakeWithFlagsValue(.stereoView, stereoViewValue)

        let (refinedTagCollection, status) = makeTagCollection(tags: [CoreMediaSoftLink.kCMTagMediaTypeVideo, videoLayerIDTag, stereoView])
        guard status == noErr, let refinedTagCollection else {
            mediaLog.error("Unable to allocate CMTagCollection for layer:\(videoLayerValue) with error:\(status)")
            return nil
        }
        tagCollections.append(refinedTagCollection)
    }
    if tagCollections.isEmpty {
        return nil
    }

    return tagCollections
}

func createTaggedBufferGroupWithRequiredVideoTagsFromVideoToolboxOutput(
    _ bufferGroup: __CMTaggedBufferGroup,
    _ tagCollections: [__CMTagCollection]
) -> __CMTaggedBufferGroup? {
    let bufferGroupCount = CMTaggedBufferGroupGetCount(bufferGroup)

    guard tagCollections.count == bufferGroupCount else {
        mediaLog.error("Mismatch between tag collection count and buffer group.")
        return nil
    }

    var buffers: [CVPixelBuffer] = []
    buffers.reserveCapacity(bufferGroupCount)
    for index in 0..<bufferGroupCount {
        guard let pixelBuffer = CMTaggedBufferGroupGetCVPixelBufferAtIndex(bufferGroup, index) else {
            return nil
        }
        buffers.append(castBuffer(pixelBuffer, to: CVPixelBuffer.self))
    }

    let (refinedTaggedBufferGroup, status) = makeTaggedBufferGroup(tagCollections: tagCollections, buffers: buffers)
    guard status == noErr else {
        mediaLog.error("Unable to allocate CMTaggedBufferGroup with error:\(status)")
        return bufferGroup
    }
    return refinedTaggedBufferGroup
}

private func isNonRecoverableError(_ status: OSStatus) -> Bool {
    status != noErr && status != kVTVideoDecoderReferenceMissingErr
}

#if WTF_PLATFORM_VISION
private func cfDictionaryCreateCombined(_ a: CFDictionary, _ b: CFDictionary) -> CFDictionary {
    let result = NSMutableDictionary(capacity: CFDictionaryGetCount(a) + CFDictionaryGetCount(b))
    for (key, value) in a as NSDictionary {
        result[key] = value
    }
    for (key, value) in b as NSDictionary {
        result[key] = value
    }
    return result as CFDictionary
}
#endif

private func copyDescriptionExtensionValuesIfNeeded(
    _ description: CMFormatDescription,
    _ originalDescription: CMVideoFormatDescription?,
    _ group: __CMTaggedBufferGroup?
) -> CMFormatDescription {
    #if WTF_PLATFORM_VISION
    guard let metadata = WebCore.copyImmersiveVideoMetadata(originalDescription), CFDictionaryGetCount(metadata) != 0 else {
        return description
    }

    var copyExtensions: CFDictionary = metadata
    if let extensions = CMFormatDescriptionGetExtensions(description) {
        copyExtensions = cfDictionaryCreateCombined(extensions, metadata)
    }

    if let group {
        let (newTaggedGroupDescription, status) = makeTaggedBufferGroupFormatDescription(group: group, extensions: copyExtensions)
        guard status == noErr, let newTaggedGroupDescription else {
            return description
        }
        return newTaggedGroupDescription
    }
    let codecType = CMFormatDescriptionGetMediaSubType(description)
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)

    let (newImageDescription, status) = makeVideoFormatDescription(
        codecType: codecType,
        width: dimensions.width,
        height: dimensions.height,
        extensions: copyExtensions
    )
    guard status == noErr, let newImageDescription else {
        return description
    }
    return newImageDescription
    #else
    return description
    #endif
}

func handleDecompressionOutput(
    _ flags: DecodingFlags,
    _ status: OSStatus,
    _ imageBuffer: CVBuffer?,
    _ group: __CMTaggedBufferGroup?,
    _ presentationTimeStamp: CMTime,
    _ presentationDuration: CMTime,
    _ currentImageDescription: CMFormatDescription?,
    _ description: CMVideoFormatDescription? = nil
) -> (CMSampleBuffer?, OSStatus) {
    if isNonRecoverableError(status) {
        mediaLog.error("Video sample decompression failed with error:\(status)")
        return (nil, status)
    }

    if flags.contains(.nonDisplaying) {
        return (nil, noErr)
    }

    if let group {
        let groupFormatDescription: CMFormatDescription
        if let currentImageDescription {
            groupFormatDescription = currentImageDescription
        } else {
            let (bufferGroupFormatDescription, createStatus) = makeTaggedBufferGroupFormatDescription(group: group)
            guard createStatus == noErr, let bufferGroupFormatDescription else {
                return (nil, createStatus)
            }
            groupFormatDescription = copyDescriptionExtensionValuesIfNeeded(bufferGroupFormatDescription, description, group)
        }
        assert(CMFormatDescriptionGetMediaType(groupFormatDescription) == kCMMediaType_TaggedBufferGroup)
        let (groupSampleBuffer, sampleBufferStatus) = makeTaggedBufferGroupSampleBuffer(
            group: group,
            presentationTimeStamp: presentationTimeStamp,
            duration: presentationDuration,
            format: groupFormatDescription
        )
        guard sampleBufferStatus == noErr else {
            return (nil, sampleBufferStatus)
        }
        return (groupSampleBuffer, noErr)
    }

    guard let imageBuffer else {
        return (nil, noErr)
    }

    let imageBufferDescription: CMFormatDescription
    if let currentImageDescription {
        imageBufferDescription = currentImageDescription
    } else {
        let (createdImageBufferDescription, createStatus) = makeVideoFormatDescriptionForImageBuffer(imageBuffer)
        guard createStatus == noErr, let createdImageBufferDescription else {
            return (nil, createStatus)
        }
        imageBufferDescription = copyDescriptionExtensionValuesIfNeeded(createdImageBufferDescription, description, nil)
    }
    assert(CMFormatDescriptionGetMediaType(imageBufferDescription) == kCMMediaType_Video)
    let imageBufferTiming = CMSampleTimingInfo(
        duration: presentationDuration,
        presentationTimeStamp: presentationTimeStamp,
        decodeTimeStamp: presentationTimeStamp
    )

    let (imageSampleBuffer, sampleBufferStatus) = makeReadySampleBufferWithImageBuffer(
        imageBuffer: imageBuffer,
        format: imageBufferDescription,
        timing: imageBufferTiming
    )
    guard sampleBufferStatus == noErr else {
        return (nil, sampleBufferStatus)
    }
    return (imageSampleBuffer, noErr)
}

private func compressedAlphaData(_ sample: CMSampleBuffer) -> CFArray? {
    (CMGetAttachment(sample, key: WebCore.compressedAlphaDataAttachmentKey(), attachmentModeOut: nil) as? NSArray).map { $0 as CFArray }
}

private func hasSeparateAlphaStream(_ description: CMFormatDescription?) -> Bool {
    guard let description, let key = WebCore.separateAlphaStreamExtensionKey() else {
        return false
    }
    return CMFormatDescriptionGetExtension(description, extensionKey: key) === kCFBooleanTrue
}

private func fourCCString(_ value: OSType) -> Swift.String {
    Swift.String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, as: UTF8.self)
}

typealias DecodeCompletion = WebCore.WebCoreDecompressionSession.DecodeCompletion
private typealias SessionDecodingFlags = DecodingFlags

struct WeakSessionCore: Sendable {
    weak let core: DecompressionSessionCore?
}

private struct CoreRegistry {
    var lastToken: UInt64 = 0
    var cores: [UInt64: DecompressionSessionCore] = [:]
}

private let decompressionSessionCores = Mutex(CoreRegistry())

private enum EnsureDecoderResult {
    case failed(OSStatus)
    case noSession
    case session(VideoToolboxSessionOwner)
}

/// The state of a C++ WebCoreDecompressionSession that Swift owns, found by the session's token.
final class DecompressionSessionCore: Sendable {
    /// Reached on the session's queue, and by decodeSampleSyncSwift on its caller's thread.
    struct SessionState: Sendable {
        var waitingForKeyframe = true
        var currentImageDescription: CMFormatDescription?
        var stereoConfigured = false
        var alphaNeedsReset = false
    }

    let state = Mutex(SessionState())
    fileprivate let decoder: DecoderState
    let queueState = QueueState()
    let invalidated = Atomic<Bool>(false)
    let isAlphaDecoder: Bool
    let stereoSupported: Bool
    let queue: DispatchQueue

    init(pixelBufferAttributes: NSDictionary, isAlphaDecoder: Bool, stereoSupported: Bool, queue: DispatchQueue) {
        decoder = DecoderState(pixelBufferAttributes: pixelBufferAttributes)
        self.isAlphaDecoder = isAlphaDecoder
        self.stereoSupported = stereoSupported
        self.queue = queue
    }

    fileprivate static func core(forToken token: UInt64) -> DecompressionSessionCore? {
        decompressionSessionCores.withLock { $0.cores[token] }
    }

    // On VideoToolbox's output thread: the core is reached only by the hops, on the session's queue.
    static func makeOutputHandler(
        _ weakCore: WeakSessionCore,
        _ handoff: SampleHandoff,
        _ flags: DecodingFlags,
        _ numberOfSamples: Int,
        _ originalDescription: CMFormatDescription?,
        _ completion: @escaping DecodeCompletion,
        _ queue: DispatchQueue
    ) -> MultiImageOutputHandler {
        {
            [weakCore, handoff, flags, numberOfSamples, originalDescription, completion, queue]
            status,
            _,
            imageBuffer,
            taggedBufferGroup,
            presentationTimeStamp,
            presentationDuration in
            let settled = handoff.withLock { h -> Bool in
                if h.isSettled {
                    return false
                }
                var group = taggedBufferGroup
                if let taggedBufferGroup {
                    let tagCollections: [__CMTagCollection]
                    if let existing = h.tagCollections {
                        tagCollections = existing
                    } else {
                        let map = createMVHEVCStereoViewMap(originalDescription)
                        guard let created = createTagCollectionRequiredFromVideoToolboxOutput(taggedBufferGroup, map) else {
                            h.settle(rejecting: kVTCouldNotOutputTaggedBufferGroupErr)
                            return true
                        }
                        tagCollections = created
                        h.tagCollections = created
                        queue.async { [weakCore, handoff] in
                            guard let core = weakCore.core else {
                                return
                            }
                            handoff.withLock { h in
                                core.queueState.withLock { q in q.tagCollections = h.tagCollections }
                            }
                        }
                    }
                    group = createTaggedBufferGroupWithRequiredVideoTagsFromVideoToolboxOutput(taggedBufferGroup, tagCollections)
                }
                let (frame, outputStatus) = handleDecompressionOutput(
                    flags,
                    status,
                    imageBuffer,
                    group,
                    presentationTimeStamp,
                    presentationDuration,
                    h.currentImageDescription,
                    originalDescription
                )
                if outputStatus != noErr {
                    h.settle(rejecting: outputStatus)
                    return true
                }
                if h.currentImageDescription == nil {
                    let description = frame.flatMap { CMSampleBufferGetFormatDescription($0) }
                    h.currentImageDescription = description
                    queue.async { [weakCore, description] in weakCore.core?.state.withLock { $0.currentImageDescription = description } }
                }
                if h.append(frame) == numberOfSamples {
                    h.settle()
                }
                return h.isSettled
            }
            guard settled else {
                return
            }
            handoff.withLock { h in
                let frames = h.takeFrames()
                completion(h.rejection == nil ? frames.map { $0.map { $0 as AnyObject } ?? NSNull() } : nil, h.rejection ?? noErr)
            }
        }
    }

    // On the session's queue, once both of the join's decodes are settled.
    func composite(_ join: Join, _ deliver: DecodeCompletion) {
        join.color.withLock { color in
            join.alpha.withLock { alpha in
                if let rejection = color.rejection {
                    deliver(nil, rejection)
                    return
                }
                if alpha.rejection == kVTInvalidSessionErr {
                    mediaLog.error("WebM alpha decoder session invalidated, will recreate on the next sample")
                    state.withLock { $0.alphaNeedsReset = true }
                }
                let colorFrames = color.takeFrames()
                var alphaPixelBuffers: [CVPixelBuffer?] = []
                if alpha.rejection == nil {
                    let alphaFrames = alpha.takeFrames()
                    if alphaFrames.count == colorFrames.count {
                        alphaPixelBuffers = alphaFrames.map { frame in
                            frame.flatMap { CMSampleBufferGetImageBuffer($0) }.map { castBuffer($0, to: CVPixelBuffer.self) }
                        }
                    }
                }
                queueState.withLock { q in
                    var output: [CMSampleBuffer] = []
                    output.reserveCapacity(colorFrames.count)
                    for (index, frame) in colorFrames.enumerated() {
                        guard let colorFrame = frame else {
                            continue
                        }
                        if index < alphaPixelBuffers.count, let alphaPixelBuffer = alphaPixelBuffers[index] {
                            let colorPixelBuffer = CMSampleBufferGetImageBuffer(colorFrame).map { castBuffer($0, to: CVPixelBuffer.self) }
                            let colorFormat = colorPixelBuffer.map { CVPixelBufferGetPixelFormatType($0) } ?? 0
                            let hasAlphaPlane = WebCore.isPixelFormatWithAlphaPlane(colorFormat)
                            let colorFormatDescription = CMSampleBufferGetFormatDescription(colorFrame)
                            let isSameSource =
                                colorFormatDescription.flatMap { description in
                                    q.mergedSourceFormatDescription.map {
                                        CMFormatDescriptionEqual(description, otherFormatDescription: $0)
                                    }
                                } ?? false
                            if !isSameSource {
                                q.mergedPixelBufferPool = nil
                                if !hasAlphaPlane && Optional(fromCxx: WebCore.pixelFormatWithAlpha(colorFormat)) == nil {
                                    mediaLog.error(
                                        "WebM alpha merge: unsupported colour format \(fourCCString(colorFormat), privacy: .public), playing without alpha"
                                    )
                                }
                                q.mergedFormatDescription = nil
                                q.mergedSourceFormatDescription = colorFormatDescription
                            }
                            if !hasAlphaPlane && q.mergedPixelBufferPool == nil,
                                let mergedFormat = Optional(fromCxx: WebCore.pixelFormatWithAlpha(colorFormat))
                            {
                                var poolStatus: CVReturn = kCVReturnSuccess
                                guard
                                    let pool = WebCore.createMergedPixelBufferPool(
                                        colorPixelBuffer.map { CVPixelBufferGetWidth($0) } ?? 0,
                                        colorPixelBuffer.map { CVPixelBufferGetHeight($0) } ?? 0,
                                        mergedFormat,
                                        &poolStatus
                                    )
                                else {
                                    mediaLog.error("WebM alpha merge: CVPixelBufferPool creation failed (status=\(poolStatus))")
                                    deliver(nil, kVTAllocationFailedErr)
                                    return
                                }
                                q.mergedPixelBufferPool = pool
                            }
                            var merged: CVPixelBuffer?
                            if hasAlphaPlane {
                                if let colorPixelBuffer, WebCore.copyAlphaIntoAlphaPlane(colorPixelBuffer, alphaPixelBuffer) {
                                    merged = colorPixelBuffer
                                }
                            } else if let pool = q.mergedPixelBufferPool {
                                guard let mergedBuffer = WebCore.createMergedPixelBuffer(colorPixelBuffer, alphaPixelBuffer, pool) else {
                                    deliver(nil, kVTAllocationFailedErr)
                                    return
                                }
                                merged = mergedBuffer
                            }
                            if let merged {
                                if q.mergedFormatDescription == nil {
                                    q.mergedFormatDescription = formatDescriptionWithAlphaImpl(castBuffer(merged, to: CVBuffer.self))
                                }
                                if let mergedSample = createSampleBufferWithPixelBuffer(merged, colorFrame, q.mergedFormatDescription) {
                                    output.append(mergedSample)
                                    continue
                                }
                            }
                        }
                        output.append(colorFrame)
                    }
                    deliver(output, noErr)
                }
            }
        }
    }
}

/// The color and alpha decodes of one WebM sample with alpha, joined and composited on the session's queue.
final class Join: Sendable {
    let color = SampleHandoff()
    let alpha = SampleHandoff()
    let remaining = Mutex<Int>(2)
    let weakCore: WeakSessionCore
    let deliver: DecodeCompletion
    let queue: DispatchQueue

    init(weakCore: WeakSessionCore, deliver: @escaping DecodeCompletion, queue: DispatchQueue) {
        self.weakCore = weakCore
        self.deliver = deliver
        self.queue = queue
    }

    var colorCompletion: DecodeCompletion {
        { [self] frames, status in settle(color, frames, status) }
    }
    var alphaCompletion: DecodeCompletion {
        { [self] frames, status in settle(alpha, frames, status) }
    }

    // On VideoToolbox's output thread or on the session's queue.
    private func settle(_ handoff: SampleHandoff, _ frames: [Any]?, _ status: OSStatus) {
        handoff.withLock { h in
            guard let frames else {
                h.settle(rejecting: status)
                return
            }
            for element in frames {
                let object = element as AnyObject
                // swift-format-ignore: NeverForceUnwrap
                _ = h.append(CFGetTypeID(object) == CMSampleBufferGetTypeID() ? (object as! CMSampleBuffer) : nil)
            }
            h.settle()
        }
        let isLast = remaining.withLock { count in
            count -= 1
            return count == 0
        }
        guard isLast else {
            return
        }
        queue.async { [self] in
            guard let core = weakCore.core, !core.invalidated.load(ordering: .sequentiallyConsistent) else {
                deliver(nil, 0)
                return
            }
            core.composite(self, deliver)
        }
    }
}

// The C++ session's members that Swift implements; each finds the core by the session's token.
extension WebCore.WebCoreDecompressionSession {
    private var core: DecompressionSessionCore {
        guard let core = DecompressionSessionCore.core(forToken: swiftToken()) else {
            preconditionFailure("The C++ session's core is gone")
        }
        return core
    }

    @cxx
    @implementation
    static func destroySwiftCore(_ token: UInt64) {
        // The core goes after the lock is released, so that nothing is released while it is held.
        _ = decompressionSessionCores.withLock { $0.cores.removeValue(forKey: token) }
    }

    @cxx
    @implementation
    static func markInvalidatedSwift(_ token: UInt64) {
        DecompressionSessionCore.core(forToken: token)?.invalidated.store(true, ordering: .sequentiallyConsistent)
    }

    @cxx
    @implementation
    static func isInvalidatedSwift(_ token: UInt64) -> Bool {
        DecompressionSessionCore.core(forToken: token)?.invalidated.load(ordering: .sequentiallyConsistent) ?? true
    }

    @cxx
    @implementation
    static func decodedFormatIsFullRange(_ description: CMFormatDescription?) -> Bool {
        decodedPixelFormat(description)?.isFullRange ?? false
    }

    /// On m_dispatcher: decodeSample's hop calls it there, and decodeAlphaSample calls it on that turn.
    @cxx
    @implementation
    func decodeOnQueueSwift(_ sample: CMSampleBuffer?, _ flags: UInt8) {
        // Unreachable: both callers pass a sample.
        guard let sample else {
            return
        }
        let core = self.core
        let numberOfSamples = CMSampleBufferGetNumSamples(sample)
        // swift-format-ignore
        let completion = unsafe resetDecodeResults(numberOfSamples) // U5(session queue): on m_dispatcher, per decodeOnQueueSwift's doc comment
        // Unreachable: both callers pass a completion.
        guard let completion else {
            return
        }
        guard let alphaDatas = compressedAlphaData(sample), let alphaSample = createAlphaSampleBuffer(alphaDatas, sample) else {
            decodeInternal(core, sample, flags, numberOfSamples, completion)
            return
        }
        let join = Join(weakCore: WeakSessionCore(core: core), deliver: completion, queue: core.queue)
        let resetAlpha = core.state.withLock { s in
            defer { s.alphaNeedsReset = false }
            return s.alphaNeedsReset
        }
        // swift-format-ignore
        let alphaStarted = unsafe decodeAlphaSample(sample, alphaSample, flags, resetAlpha, join.alphaCompletion) // U5(session queue): on m_dispatcher, per decodeOnQueueSwift's doc comment
        decodeInternal(core, sample, flags, numberOfSamples, alphaStarted ? join.colorCompletion : completion)
    }

    private func decodeInternal(
        _ core: DecompressionSessionCore,
        _ sample: CMSampleBuffer,
        _ flags: UInt8,
        _ numberOfSamples: Int,
        _ completion: @escaping DecodeCompletion
    ) {
        let decodingFlags = SessionDecodingFlags(rawValue: flags)
        let result = ensureDecoder(core, sample, decodingFlags)
        if case .failed(let status) = result {
            completion(nil, status)
            return
        }
        if core.state.withLock({ $0.waitingForKeyframe }) {
            completion([], noErr)
            return
        }
        guard case .session(let owner) = result else {
            let start = startSoftwareDecoder(sample, flags, completion)
            if start == .Rejected {
                completion(nil, 0)
            } else if start == .Present {
                // swift-format-ignore
                unsafe decode(sample, flags, completion) // U5(session queue): on m_dispatcher, per decodeOnQueueSwift's doc comment
            }
            return
        }

        let handoff = SampleHandoff()
        handoff.withLock { h in
            h.reserve(numberOfSamples)
            core.queueState.withLock { q in h.tagCollections = q.tagCollections }
            h.currentImageDescription = core.state.withLock { $0.currentImageDescription }
        }

        var infoFlags = VTDecodeFrameFlags._EnableAsynchronousDecompression.rawValue | VTDecodeFrameFlags._EnableTemporalProcessing.rawValue
        if decodingFlags.contains(.nonDisplaying) {
            infoFlags |= VTDecodeFrameFlags._DoNotOutputFrame.rawValue
        }
        if decodingFlags.contains(.realTime) {
            infoFlags |= VTDecodeFrameFlags._1xRealTimePlayback.rawValue
        }

        if core.stereoSupported && decodingFlags.contains(.enableStereo) {
            let configure = core.state.withLock { s in
                defer { s.stereoConfigured = true }
                return !s.stereoConfigured
            }
            if configure, let layers = createMVHEVCVideoLayersArray(CMSampleBufferGetFormatDescription(sample)) {
                _ = owner.withLock { $0.setProperty(VideoToolboxSoftLink.kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs, layers) }
            }
        }

        let originalDescription = CMSampleBufferGetFormatDescription(sample)
        let handler = DecompressionSessionCore.makeOutputHandler(
            WeakSessionCore(core: core),
            handoff,
            decodingFlags,
            numberOfSamples,
            originalDescription,
            completion,
            core.queue
        )
        let status = owner.withLock { $0.decodeMultiImageFrame(sample, infoFlags, handler) }
        if status != noErr {
            // The handler is not called when the decode returns an error.
            handler(status, 0, nil, nil, CMTime.invalid, CMTime.invalid)
        }
    }

    private func ensureDecoder(
        _ core: DecompressionSessionCore,
        _ sample: CMSampleBuffer,
        _ flags: SessionDecodingFlags
    ) -> EnsureDecoderResult {
        let isWaitingForKeyframe = core.state.withLock { s -> Bool in
            if s.waitingForKeyframe {
                if !WebCore.isCMSampleBufferRandomAccess(sample) {
                    return true
                }
                mediaLog.info("VTDecompressionSession received keyframe after format change, creating new VTDecompressionSession")
                s.waitingForKeyframe = false
            }
            return false
        }
        if isWaitingForKeyframe {
            return .noSession
        }

        return core.decoder.withLock { d -> EnsureDecoderResult in
            // The old session is invalidated last, once no call holds its owner.
            var old: VideoToolboxSessionOwner?
            defer { withExtendedLifetime(old) {} }

            let description = CMSampleBufferGetFormatDescription(sample)
            let changed =
                d.lastFormatDescription.map { last in
                    description.map { !CMFormatDescriptionEqual($0, otherFormatDescription: last) } ?? true
                } ?? true

            let software = checkSoftwareDecoder(changed)
            if software == .Invalidated {
                return .failed(kVTInvalidSessionErr)
            }
            if software == .Present {
                return .noSession
            }

            if changed && d.owner != nil && !d.canAccept(description) {
                let status = d.waitForAsynchronousFrames()
                old = d.takeOwner()
                d.isHardwareAccelerated = nil
                if !WebCore.isCMSampleBufferRandomAccess(sample) {
                    mediaLog.error(
                        "VTDecompressionSession can't accept format description change on non-keyframe, waiting for keyframe status:\(status)"
                    )
                    core.state.withLock { $0.waitingForKeyframe = true }
                    return .noSession
                }
                mediaLog.info(
                    "VTDecompressionSession can't accept format description change on keyframe, creating new VTDecompressionSession status:\(status)"
                )
            }

            d.lastFormatDescription = description

            if d.owner == nil {
                var attributes = d.pixelBufferAttributes
                if !core.isAlphaDecoder && (hasSeparateAlphaStream(description) || compressedAlphaData(sample) != nil) {
                    attributes = colorDecoderPixelBufferAttributesWithAlpha(description)
                }
                let requiresHardware =
                    flags.contains(.hardwareOnly) && WebCore.WebCoreDecompressionSession.canDecodeInContentProcess(description)
                let specificationKey =
                    requiresHardware
                    ? VideoToolboxSoftLink.kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder
                    : VideoToolboxSoftLink.kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder
                let specification = NSDictionary(object: true as NSNumber, forKey: specificationKey as NSString)
                let created = description.flatMap { description in
                    makeDecompressionSession(
                        format: description,
                        decoderSpecification: specification as CFDictionary,
                        imageBufferAttributes: attributes as CFDictionary
                    )
                    .0
                }
                if let created {
                    d.install(created: created)
                } else if requiresHardware {
                    mediaLog.error("Couldn't create a hardware VTDecompressionSession")
                    return .failed(kVTCouldNotFindVideoDecoderErr)
                }
                if isDispatcherCurrent() {
                    core.state.withLock { s in
                        s.currentImageDescription = nil
                        s.stereoConfigured = false
                    }
                    core.queueState.withLock { $0.tagCollections = nil }
                }
            }

            return d.owner.map { .session($0) } ?? .noSession
        }
    }

    /// Only C++'s decodeSampleSync calls it, on any thread.
    ///
    /// The result is +0 and autoreleased: the caller retains what it keeps inside a pool.
    @cxx
    @implementation
    func decodeSampleSyncSwift(_ sample: CMSampleBuffer?) -> CFArray? {
        let outputs = SampleHandoff()
        if let sample, case .session(let owner) = ensureDecoder(core, sample, []) {
            let semaphore = DispatchSemaphore(value: 0)
            let status = owner.withLock { o in
                o.decodeFrame(sample, 0) { _, _, imageBuffer, _, _ in
                    outputs.withLock { $0.appendOutput(imageBuffer) }
                    semaphore.signal()
                }
            }
            if status == noErr {
                semaphore.wait()
            }
        }
        // withLock's result must be Sendable, which CVBuffer is not.
        var buffers: [CVBuffer] = []
        outputs.withLock { buffers = $0.takeOutputs() }
        return buffers as NSArray as CFArray
    }

    /// The member of the C++ class, which WebCore's callers outside this file reach.
    @cxx
    @implementation
    public func flush() {
        bumpFlushId()
        flushAlpha()
        let core = self.core
        core.queue.async { [core] in core.state.withLock { $0.waitingForKeyframe = true } }
    }

    @cxx
    @implementation
    func isHardwareAccelerated() -> Bool {
        core.decoder.withLock { d in
            if hasDecoder() {
                return false
            }
            if let isHardwareAccelerated = d.isHardwareAccelerated {
                return isHardwareAccelerated
            }
            let isHardwareAccelerated = d.owner != nil && d.isUsingHardwareAcceleratedDecoder()
            d.isHardwareAccelerated = isHardwareAccelerated
            return isHardwareAccelerated
        }
    }
}

@_expose(Cxx)
func createDecompressionSessionCore(
    _ pixelBufferAttributes: NSDictionary?,
    _ isAlphaDecoder: Bool,
    _ alphaIsFullRange: Bool,
    _ stereoSupported: Bool,
    _ queue: DispatchQueue
) -> UInt64 {
    let attributes =
        isAlphaDecoder
        ? alphaDecoderPixelBufferAttributes(isFullRange: alphaIsFullRange) : (pixelBufferAttributes ?? defaultPixelBufferAttributes())
    let core = DecompressionSessionCore(
        pixelBufferAttributes: attributes,
        isAlphaDecoder: isAlphaDecoder,
        stereoSupported: stereoSupported,
        queue: queue
    )
    return decompressionSessionCores.withLock { registry in
        registry.lastToken += 1
        registry.cores[registry.lastToken] = core
        return registry.lastToken
    }
}

#endif // ENABLE_WEBCORE_SWIFT
