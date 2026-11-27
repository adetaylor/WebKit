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

#if ENABLE_WEBCORE_SWIFT

internal import CoreMedia
internal import CoreVideo
internal import Foundation
internal import os
internal import VideoToolbox
import WebCore_Private.Core.CMParsingTypes

func createEmptyBlockBuffer(capacity: UInt32) -> (CMBlockBuffer?, OSStatus) {
    var status: OSStatus = 0
    let buffer = WebCore.createEmptyBlockBuffer(capacity, &status)
    return (buffer, status)
}

// The callee reads timings.count and sizes.count entries of the arrays held for the call, and writes one reference to the out-parameter, a local.
private func createReadySampleBuffer(
    data: CMBlockBuffer?,
    format: CMFormatDescription?,
    count: Int,
    timings: [CMSampleTimingInfo],
    sizes: [Int]
) -> (CMSampleBuffer?, OSStatus) {
    var buffer: CMSampleBuffer?
    let status = unsafe CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: data,
        formatDescription: format,
        sampleCount: count,
        sampleTimingEntryCount: timings.count,
        sampleTimingArray: timings,
        sampleSizeEntryCount: sizes.count,
        sampleSizeArray: sizes.isEmpty ? nil : sizes,
        sampleBufferOut: &buffer
    )
    return (buffer, status)
}

func makeReadySampleBuffer(
    data: CMBlockBuffer?,
    format: CMFormatDescription?,
    count: Int,
    timings: [CMSampleTimingInfo],
    sizes: [Int]
) -> (CMSampleBuffer?, OSStatus) {
    createReadySampleBuffer(data: data, format: format, count: count, timings: timings, sizes: sizes)
}

// The callee reads the one timing, a local of this function, and writes one reference to the out-parameter, a local.
private func createReadySampleBufferWithImageBuffer(
    imageBuffer: CVBuffer,
    format: CMVideoFormatDescription,
    timing: CMSampleTimingInfo
) -> (CMSampleBuffer?, OSStatus) {
    var timing = timing
    var buffer: CMSampleBuffer?
    let status = unsafe CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &buffer
    )
    return (buffer, status)
}

func makeReadySampleBufferWithImageBuffer(
    imageBuffer: CVBuffer,
    format: CMVideoFormatDescription,
    timing: CMSampleTimingInfo
) -> (CMSampleBuffer?, OSStatus) {
    createReadySampleBufferWithImageBuffer(imageBuffer: imageBuffer, format: format, timing: timing)
}

// The callee writes one reference to the out-parameter, a local of this function, and nothing else.
private func createVideoFormatDescriptionForImageBuffer(_ imageBuffer: CVBuffer) -> (CMVideoFormatDescription?, OSStatus) {
    var format: CMVideoFormatDescription?
    let status = unsafe CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescriptionOut: &format
    )
    return (format, status)
}

func makeVideoFormatDescriptionForImageBuffer(_ imageBuffer: CVBuffer) -> (CMVideoFormatDescription?, OSStatus) {
    createVideoFormatDescriptionForImageBuffer(imageBuffer)
}

// The callee writes one reference to the out-parameter, a local of this function, and nothing else.
private func createVideoFormatDescription(
    codecType: CMVideoCodecType,
    width: Int32,
    height: Int32,
    extensions: CFDictionary?
) -> (CMVideoFormatDescription?, OSStatus) {
    var format: CMVideoFormatDescription?
    let status = unsafe CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: codecType,
        width: width,
        height: height,
        extensions: extensions,
        formatDescriptionOut: &format
    )
    return (format, status)
}

// The callee reads the description, a local of this function, and the cookie's bytes, held by the CFData for the call, and writes one reference to the out-parameter, a local.
private func createAudioFormatDescription(
    description: AudioStreamBasicDescription,
    cookie: CFData?,
    extensions: CFDictionary?
) -> (CMAudioFormatDescription?, OSStatus) {
    var description = description
    var format: CMAudioFormatDescription?
    let cookieSize = cookie.map { CFDataGetLength($0) } ?? 0
    let status = unsafe CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &description,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: cookieSize,
        magicCookie: cookieSize == 0 ? nil : cookie.flatMap { unsafe CFDataGetBytePtr($0) },
        extensions: extensions,
        formatDescriptionOut: &format
    )
    return (format, status)
}

// The callee reads the attributes, which the call holds, and writes one reference to the out-parameter, a local of this function.
private func createPixelBuffer(width: Int, height: Int, pixelFormat: OSType, attributes: CFDictionary?) -> (CVPixelBuffer?, CVReturn) {
    var buffer: CVPixelBuffer?
    let status = unsafe CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes, &buffer)
    return (buffer, status)
}

// The callee writes one CMSampleTimingInfo to the out-parameter, a local of this function, for an index checked against the sample count.
private func copySampleTimingInfo(of buffer: CMSampleBuffer, at index: Int) -> CMSampleTimingInfo? {
    guard index >= 0, index < CMSampleBufferGetNumSamples(buffer) else { return nil }
    var timing = CMSampleTimingInfo()
    guard unsafe CMSampleBufferGetSampleTimingInfo(buffer, at: index, timingInfoOut: &timing) == noErr else { return nil }
    return timing
}

func sampleTimingInfo(of buffer: CMSampleBuffer, at index: Int) -> CMSampleTimingInfo? {
    copySampleTimingInfo(of: buffer, at: index)
}

// The callee reads the group, held for the call, and writes one reference to the out-parameter, a local of this function.
private func createTaggedBufferGroupFormatDescription(group: __CMTaggedBufferGroup) -> (CMTaggedBufferGroupFormatDescription?, OSStatus) {
    var format: CMTaggedBufferGroupFormatDescription?
    let status = unsafe CMTaggedBufferGroupFormatDescriptionCreateForTaggedBufferGroup(kCFAllocatorDefault, group, &format)
    return (format, status)
}

func makeTaggedBufferGroupFormatDescription(group: __CMTaggedBufferGroup) -> (CMTaggedBufferGroupFormatDescription?, OSStatus) {
    createTaggedBufferGroupFormatDescription(group: group)
}

// The callee reads the group and the extensions, held for the call, and writes one reference to the out-parameter, a local of this function.
private func createTaggedBufferGroupFormatDescription(
    group: __CMTaggedBufferGroup,
    extensions: CFDictionary?
) -> (CMTaggedBufferGroupFormatDescription?, OSStatus) {
    var format: CMTaggedBufferGroupFormatDescription?
    let status = unsafe CMTaggedBufferGroupFormatDescriptionCreateForTaggedBufferGroupWithExtensions(
        kCFAllocatorDefault,
        group,
        extensions,
        &format
    )
    return (format, status)
}

func makeTaggedBufferGroupFormatDescription(
    group: __CMTaggedBufferGroup,
    extensions: CFDictionary?
) -> (CMTaggedBufferGroupFormatDescription?, OSStatus) {
    createTaggedBufferGroupFormatDescription(group: group, extensions: extensions)
}

// The callee reads the group and the format, held for the call, and writes one reference to the out-parameter, a local of this function.
private func createTaggedBufferGroupSampleBuffer(
    group: __CMTaggedBufferGroup,
    presentationTimeStamp: CMTime,
    duration: CMTime,
    format: CMTaggedBufferGroupFormatDescription
) -> (CMSampleBuffer?, OSStatus) {
    var buffer: CMSampleBuffer?
    let status = unsafe CMSampleBufferCreateForTaggedBufferGroup(
        kCFAllocatorDefault,
        group,
        presentationTimeStamp,
        duration,
        format,
        &buffer
    )
    return (buffer, status)
}

func makeTaggedBufferGroupSampleBuffer(
    group: __CMTaggedBufferGroup,
    presentationTimeStamp: CMTime,
    duration: CMTime,
    format: CMTaggedBufferGroupFormatDescription
) -> (CMSampleBuffer?, OSStatus) {
    createTaggedBufferGroupSampleBuffer(group: group, presentationTimeStamp: presentationTimeStamp, duration: duration, format: format)
}

// The callee reads the two dictionaries, held for the call, no callback record, and writes one reference to the out-parameter, a local of this function.
private func createDecompressionSession(
    format: CMVideoFormatDescription,
    decoderSpecification: CFDictionary?,
    imageBufferAttributes: CFDictionary?
) -> (VTDecompressionSession?, OSStatus) {
    var session: VTDecompressionSession?
    let status = unsafe VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        format,
        decoderSpecification,
        imageBufferAttributes,
        nil,
        &session
    )
    return (session, status)
}

func makeDecompressionSession(
    format: CMVideoFormatDescription,
    decoderSpecification: CFDictionary?,
    imageBufferAttributes: CFDictionary?
) -> (VTDecompressionSession?, OSStatus) {
    createDecompressionSession(format: format, decoderSpecification: decoderSpecification, imageBufferAttributes: imageBufferAttributes)
}

// The key is fixed and its value is one CFBoolean, so the callee writes one retained object to the out-parameter, a fresh nil local of this function, never an array.
private func copyIsUsingHardwareAcceleratedDecoder(_ session: VTDecompressionSession) -> Bool {
    var value: CFTypeRef?
    let status = unsafe VTSessionCopyProperty(
        session,
        VideoToolboxSoftLink.kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        kCFAllocatorDefault,
        &value
    )
    guard status == noErr, let value else { return false }
    return CFEqual(value, kCFBooleanTrue)
}

func isUsingHardwareAcceleratedDecoder(_ session: VTDecompressionSession) -> Bool {
    copyIsUsingHardwareAcceleratedDecoder(session)
}

// The callee writes one retained CFArray to the out-parameter, a local of this function.
private func copyTagCollectionArray(of format: CMVideoFormatDescription) -> (CFArray?, OSStatus) {
    var array: CFArray?
    let status = unsafe CMVideoFormatDescriptionCopyTagCollectionArray(format, &array)
    return (array, status)
}

func tagCollectionArray(of format: CMVideoFormatDescription) -> (CFArray?, OSStatus) {
    copyTagCollectionArray(of: format)
}

// The callee writes at most tags.count tags to the array held for the call, and one count to a local of this function.
private func copyFirstTag(of collection: __CMTagCollection, category: __CMTagCategory) -> (OSStatus, __CMTag?) {
    var tags = [__CMTag()]
    var copied: CMItemCount = 0
    let status = unsafe CMTagCollectionGetTagsWithCategory(collection, category, &tags, tags.count, &copied)
    return (status, copied == 1 ? tags[0] : nil)
}

func firstTag(of collection: __CMTagCollection, category: __CMTagCategory) -> (OSStatus, __CMTag?) {
    copyFirstTag(of: collection, category: category)
}

// The callee reads tags.count tags from the array held for the call and writes one reference to the out-parameter, a local of this function.
private func createTagCollection(tags: [__CMTag]) -> (__CMTagCollection?, OSStatus) {
    var collection: __CMTagCollection?
    let status = unsafe CMTagCollectionCreate(kCFAllocatorDefault, tags, tags.count, &collection)
    return (collection, status)
}

func makeTagCollection(tags: [__CMTag]) -> (__CMTagCollection?, OSStatus) {
    createTagCollection(tags: tags)
}

// kCMTaggedBufferGroupError_ParamErr, which CoreMedia's header leaves unavailable to Swift.
private let taggedBufferGroupParamErr: OSStatus = -15780

// The callee reads the two arrays of equal length, held for the call, of tag collections and pixel buffers, and writes one reference to the out-parameter, a local of this function.
private func createTaggedBufferGroup(tagCollections: [__CMTagCollection], buffers: [CVPixelBuffer]) -> (__CMTaggedBufferGroup?, OSStatus) {
    guard tagCollections.count == buffers.count else { return (nil, taggedBufferGroupParamErr) }
    var group: __CMTaggedBufferGroup?
    let status = unsafe CMTaggedBufferGroupCreate(
        kCFAllocatorDefault,
        tagCollections as NSArray as CFArray,
        buffers as NSArray as CFArray,
        &group
    )
    return (group, status)
}

func makeTaggedBufferGroup(tagCollections: [__CMTagCollection], buffers: [CVPixelBuffer]) -> (__CMTaggedBufferGroup?, OSStatus) {
    createTaggedBufferGroup(tagCollections: tagCollections, buffers: buffers)
}

func makeVideoFormatDescription(
    codecType: CMVideoCodecType,
    width: Int32,
    height: Int32,
    extensions: CFDictionary?
) -> (CMVideoFormatDescription?, OSStatus) {
    createVideoFormatDescription(codecType: codecType, width: width, height: height, extensions: extensions)
}

private func streamBasicDescription(of format: CMAudioFormatDescription) -> AudioStreamBasicDescription? {
    let result = WebCore.audioStreamBasicDescription(format)
    return result.valid ? result.description : nil
}

private func createAudioFormatDescription(
    description: AudioStreamBasicDescription,
    layout: WebCore.MediaChannelLayout?,
    extensions: CFDictionary?
) -> (CMAudioFormatDescription?, WebCore.AudioFormatDescriptionStatus) {
    var status = WebCore.AudioFormatDescriptionStatus()
    let format = WebCore.createAudioFormatDescriptionWithLayout(
        description,
        layout != nil,
        layout ?? WebCore.MediaChannelLayout(),
        extensions,
        &status
    )
    return (format, status)
}

private let mediaLog = Logger(subsystem: "com.apple.WebKit", category: "Media")

// MediaTime::zeroTime(), made as MediaTime.cpp makes it (the flags are MediaTime::Valid).
private var zeroMediaTime: WTF.MediaTime {
    WTF.MediaTime(0, 1, 1)
}

extension WTF.MediaTime {
    // PAL::toCMTime().
    fileprivate var cmTime: CMTime {
        let scale = Int32(truncatingIfNeeded: timeScale())
        var time =
            hasDoubleValue()
            ? CMTimeMakeWithSeconds(toDouble(), preferredTimescale: scale) : CMTimeMake(value: timeValue(), timescale: scale)
        if isValid() {
            time.flags.insert(.valid)
        } else {
            time.flags.remove(.valid)
        }
        if hasBeenRounded() {
            time.flags.insert(.hasBeenRounded)
        }
        if isPositiveInfinite() {
            time.flags.insert(.positiveInfinity)
        }
        if isNegativeInfinite() {
            time.flags.insert(.negativeInfinity)
        }
        return time
    }

    fileprivate var isNegative: Bool {
        WebCore.isMediaTimeLessThan(self, zeroMediaTime)
    }
}

private var shouldPropagate: CMAttachmentMode { CMAttachmentMode(kCMAttachmentMode_ShouldPropagate) }

private func setTrimDurationAttachment(
    _ sampleBuffer: CMSampleBuffer,
    key: CFString,
    _ trimDuration: WTF.MediaTime
) {
    // Against zero, toDouble() <= 0 agrees with MediaTime's <= for every value: integer values share their sign
    // with the quotient, infinities map to +-inf, and invalid, indefinite and NaN-bit values are unordered and NaN.
    if trimDuration.toDouble() <= 0 {
        return
    }
    CMSetAttachment(
        sampleBuffer,
        key: key,
        value: CMTimeCopyAsDictionary(trimDuration.cmTime, allocator: kCFAllocatorDefault),
        attachmentMode: shouldPropagate
    )
}

private func setVideoAttachments(_ sampleBuffer: CMSampleBuffer, _ block: borrowing WebCore.MediaSamplesBlock) -> Bool {
    guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) else {
        return false
    }
    for index in 0..<CFArrayGetCount(attachmentsArray) {
        guard let attachments = WebCore.sampleAttachmentsDictionary(attachmentsArray, index) else {
            fatalError("A sample's attachments are not a dictionary")
        }
        // Each field is read from the block in place: a sample read whole is a copy of its five RefPtrs.
        if block[index].flags & WebCore.MediaSample.IsSync.rawValue == 0 {
            WebCore.setSampleAttachment(attachments, CoreMediaSoftLink.kCMSampleAttachmentKey_NotSync, kCFBooleanTrue)
        }

        if block[index].flags & WebCore.MediaSample.IsNonDisplaying.rawValue != 0 {
            WebCore.setSampleAttachment(attachments, CoreMediaSoftLink.kCMSampleAttachmentKey_DoNotDisplay, kCFBooleanTrue)
        }

        // Attach HDR10+ (aka SMPTE ST 2094-40) metadata, if present:
        if Optional(fromCxx: block[index].hdrMetadataType) == .SmpteSt209440, let hdrMetadata = block[index].hdrMetadata.get() {
            WebCore.setSampleAttachment(
                attachments,
                CoreMediaSoftLink.kCMSampleAttachmentKey_HDR10PlusPerFrameData,
                WebCore.createCFDataForSharedBuffer(hdrMetadata)
            )
        }
    }
    for index in 0..<block.size() where block[index].alphaData.get() == nil {
        return true
    }
    var alphaDatas: [CFData] = []
    alphaDatas.reserveCapacity(block.size())
    for index in 0..<block.size() {
        if let alphaData = block[index].alphaData.get() {
            alphaDatas.append(WebCore.createCFDataForSharedBuffer(alphaData))
        }
    }
    CMSetAttachment(
        sampleBuffer,
        key: WebCore.compressedAlphaDataAttachmentKey(),
        value: alphaDatas as CFArray,
        attachmentMode: shouldPropagate
    )
    return true
}

#if ENABLE_ENCRYPTED_MEDIA
private func setEncryptionAttachments(_ sampleBuffer: CMSampleBuffer, _ block: borrowing WebCore.MediaSamplesBlock) -> Bool {
    guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) else {
        return false
    }
    let attachmentsCount = CFArrayGetCount(attachmentsArray)
    let sampleCount = block.size()
    if attachmentsCount < sampleCount {
        mediaLog.debug(
            "Encrypted sample doesn't contain sufficient attachments: \(UInt32(truncatingIfNeeded: attachmentsCount)) (expected:\(UInt32(truncatingIfNeeded: sampleCount)))"
        )
        return true
    }

    for index in 0..<sampleCount {
        guard let attachments = WebCore.sampleAttachmentsDictionary(attachmentsArray, index) else {
            continue
        }

        WebCore.setSampleAttachment(
            attachments,
            WebCore.sampleBufferAttachmentKey(.BytesOfClearDataCount),
            NSNumber(value: block[index].bytesOfClearDataCount)
        )
        if let cryptorIV = block[index].cryptorIV.get() {
            WebCore.setSampleAttachment(
                attachments,
                WebCore.sampleBufferAttachmentKey(.CryptorIV),
                WebCore.createCFDataForSharedBuffer(cryptorIV)
            )
        }
        if let cryptorSubsampleAuxiliaryData = block[index].cryptorSubsampleAuxiliaryData.get() {
            WebCore.setSampleAttachment(
                attachments,
                CoreMediaSoftLink.kCMSampleAttachmentKey_CryptorSubsampleAuxiliaryData,
                WebCore.createCFDataForSharedBuffer(cryptorSubsampleAuxiliaryData)
            )
        }
    }
    return true
}
#endif

// Where toCMSampleBuffer() fails once it has the block's info, in the order of its messages in CMUtilities.mm.
enum SampleBufferBuildError: UInt8, Error {
    case createEmptyFailed
    case noSampleData
    case createBlockBufferFailed
    case appendBufferReferenceFailed
    case invalidTrimInterval
    case createReadyFailed
    case noSampleAttachment
    case noDecodedAudioSample
    case unsupportedDecodedAudioSampleFormat
    case invalidDecodedAudioFormat
    case noFormatDescription
    case decodedAudioFormatMismatch
    case invalidDecodedAudioData
    case decodedVideoFrameCount
    case unsupportedDecodedVideoPixelFormat
    case noDecodedVideoData
    case invalidDecodedVideoSize
    case createPixelBufferFailed
    case invalidDecodedVideoData
    case createImageBufferFormatDescriptionFailed
    case createReadyWithImageBufferFailed
}

// For toCMSampleBuffer (CMUtilities.mm), with the block's info as its subclass; format is the caller's, if any. On
// failure, error is the SampleBufferBuildError's raw value, which indexes toCMSampleBuffer()'s messages.
// block is toCMSampleBuffer()'s const reference, owned by its caller for the whole call and passed as is. Swift calls
// only its const accessors, CoreMedia and CoreVideo, and the helpers of CMParsingTypes.h and CVUtilities.h on values
// it returns (buffers, infos, times); none calls back, runs script or reaches block except through those values, and
// nothing else touches it during the call.
@_expose(Cxx)
func toCMSampleBufferImpl(
    _ block: borrowing WebCore.MediaSamplesBlock,
    _ audioInfo: consuming WebCore.ConstAudioInfoRefPtr,
    _ videoInfo: consuming WebCore.ConstVideoInfoRefPtr,
    _ format: CMFormatDescription?,
    _ error: inout UInt8
) -> CMSampleBuffer? {
    do {
        return try makeSampleBuffer(block, audioInfo.get(), videoInfo.get(), format)
    } catch let buildError {
        error = buildError.rawValue
        return nil
    }
}

private func makeSampleBuffer(
    _ block: borrowing WebCore.MediaSamplesBlock,
    _ audioInfo: WebCore.AudioInfo?,
    _ videoInfo: WebCore.VideoInfo?,
    _ givenFormat: CMFormatDescription?
) throws(SampleBufferBuildError) -> CMSampleBuffer {
    if let audioInfo, audioInfo.isDecoded() {
        return try makeDecodedAudioSampleBuffer(block, audioInfo, givenFormat)
    }
    if let videoInfo, videoInfo.isDecoded() {
        return try makeDecodedVideoSampleBuffer(block, videoInfo)
    }
    let info = block.info()
    guard let format = givenFormat ?? formatDescription(info, audioInfo, videoInfo) else {
        throw .noFormatDescription
    }
    return try makeSampleBuffer(block, format)
}

// createFormatDescriptionFromTrackInfo() (CMUtilities.mm); info is audioInfo or videoInfo as a TrackInfo.
private func formatDescription(
    _ info: WebCore.TrackInfo?,
    _ audioInfo: WebCore.AudioInfo?,
    _ videoInfo: WebCore.VideoInfo?
) -> CMFormatDescription? {
    guard let info else {
        return nil
    }
    if let audioInfo {
        return audioFormatDescription(info, audioInfo)
    }
    guard let videoInfo else {
        fatalError("A track without a format description is audio or video")
    }
    return videoFormatDescription(info, videoInfo)
}

private func isInterleavedFloat32Format(_ format: CMFormatDescription, _ audioInfo: WebCore.AudioInfo) -> Bool {
    guard let description = streamBasicDescription(of: format) else {
        return false
    }
    return description.mFormatID == kAudioFormatLinearPCM
        && description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        && description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        && description.mBitsPerChannel == 32
        && description.mChannelsPerFrame == audioInfo.channels()
        && description.mSampleRate == Double(audioInfo.rate())
}

// Decoded audio is interleaved F32, so the format is constant bitrate: the sample count is a frame count
// and the timing entry holds the duration of one frame.
private func makeDecodedAudioSampleBuffer(
    _ block: borrowing WebCore.MediaSamplesBlock,
    _ audioInfo: WebCore.AudioInfo,
    _ givenFormat: CMFormatDescription?
) throws(SampleBufferBuildError) -> CMSampleBuffer {
    if block.isEmpty() {
        throw .noDecodedAudioSample
    }
    guard Optional(fromCxx: audioInfo.sampleFormat()) == .F32 else {
        throw .unsupportedDecodedAudioSampleFormat
    }
    let bytesPerFrame = UInt(audioInfo.channels()) * UInt(MemoryLayout<Float>.size)
    guard bytesPerFrame != 0, audioInfo.rate() != 0 else {
        throw .invalidDecodedAudioFormat
    }
    let info = block.info()
    guard let format = givenFormat ?? formatDescription(info, audioInfo, nil) else {
        throw .noFormatDescription
    }
    guard isInterleavedFloat32Format(format, audioInfo) else {
        throw .decodedAudioFormatMismatch
    }

    let sampleCount = block.size()
    var completeBlockBuffer: CMBlockBuffer?
    if sampleCount > 1 {
        let (buffer, status) = createEmptyBlockBuffer(capacity: UInt32(truncatingIfNeeded: sampleCount))
        guard status == kCMBlockBufferNoErr, let buffer else {
            throw .createEmptyFailed
        }
        completeBlockBuffer = buffer
    }

    var totalBytes: UInt = 0
    for index in 0..<sampleCount {
        guard let blockBuffer = WebCore.createCMBlockBufferForSharedBuffer(block, index) else {
            // The size check comes first, so it is read here, off the path that succeeds.
            let failedSize = block[index].data.get().map { UInt(bitPattern: $0.size()) } ?? 0
            throw failedSize != 0 && failedSize % bytesPerFrame == 0 ? .createBlockBufferFailed : .invalidDecodedAudioData
        }
        let size = UInt(bitPattern: CMBlockBufferGetDataLength(blockBuffer))
        guard size != 0, size % bytesPerFrame == 0 else {
            throw .invalidDecodedAudioData
        }

        if let completeBlockBuffer {
            guard
                CMBlockBufferAppendBufferReference(completeBlockBuffer, targetBBuf: blockBuffer, offsetToData: 0, dataLength: 0, flags: 0)
                    == kCMBlockBufferNoErr
            else {
                throw .appendBufferReferenceFailed
            }
        } else {
            completeBlockBuffer = blockBuffer
        }
        // Wraps: a sum past the address space would give a wrong frame count, and no block of buffers in memory reaches one.
        totalBytes &+= size
    }

    // The items of a block are contiguous, so the first presentation time and a per-frame duration describe all of them.
    let timing = CMSampleTimingInfo(
        duration: CMTimeMake(value: 1, timescale: Int32(truncatingIfNeeded: audioInfo.rate())),
        presentationTimeStamp: block[0].presentationTime.cmTime,
        decodeTimeStamp: .invalid
    )
    let (createdSampleBuffer, status) = createReadySampleBuffer(
        data: completeBlockBuffer,
        format: format,
        count: Int(bitPattern: totalBytes / bytesPerFrame),
        timings: [timing],
        sizes: []
    )
    guard status == noErr, let sampleBuffer = createdSampleBuffer else {
        throw .createReadyFailed
    }

    if let discontinuity = Optional(fromCxx: block.discontinuity()) {
        CMSetAttachment(
            sampleBuffer,
            key: CoreMediaSoftLink.kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence,
            value: discontinuity ? kCFBooleanTrue : kCFBooleanFalse,
            attachmentMode: shouldPropagate
        )
    }
    return sampleBuffer
}

private func makeSampleBuffer(
    _ block: borrowing WebCore.MediaSamplesBlock,
    _ format: CMFormatDescription
) throws(SampleBufferBuildError) -> CMSampleBuffer {
    let sampleCount = block.size()
    var completeBlockBuffer: CMBlockBuffer?
    if sampleCount > 1 {
        // Optimisation so that we allocate the entire CMBlockBuffer at once if we have more than one to return.
        let (buffer, status) = createEmptyBlockBuffer(capacity: UInt32(truncatingIfNeeded: sampleCount))
        guard status == kCMBlockBufferNoErr, let buffer else {
            throw .createEmptyFailed
        }
        completeBlockBuffer = buffer
    }

    var timings: [CMSampleTimingInfo] = []
    var sizes: [Int] = []
    timings.reserveCapacity(sampleCount)
    sizes.reserveCapacity(sampleCount)
    var cumulativeTrimDurationAtStart = zeroMediaTime
    var cumulativeTrimDurationAtEnd = zeroMediaTime
    for index in 0..<sampleCount {
        guard let blockBuffer = WebCore.createCMBlockBufferForSharedBuffer(block, index) else {
            throw block[index].data.get() == nil ? .noSampleData : .createBlockBufferFailed
        }

        if let completeBlockBuffer {
            guard
                CMBlockBufferAppendBufferReference(completeBlockBuffer, targetBBuf: blockBuffer, offsetToData: 0, dataLength: 0, flags: 0)
                    == kCMBlockBufferNoErr
            else {
                throw .appendBufferReferenceFailed
            }
        } else {
            completeBlockBuffer = blockBuffer
        }
        let trimAtStart = block[index].trimInterval.first
        let trimAtEnd = block[index].trimInterval.second
        let duration = block[index].duration
        guard trimAtStart.isFinite(), trimAtEnd.isFinite(), !trimAtStart.isNegative, !trimAtEnd.isNegative, !duration.isNegative else {
            throw .invalidTrimInterval
        }
        timings.append(
            CMSampleTimingInfo(
                duration: (duration + trimAtStart + trimAtEnd).cmTime,
                presentationTimeStamp: (block[index].presentationTime - trimAtStart).cmTime,
                decodeTimeStamp: (block[index].decodeTime - trimAtStart).cmTime
            )
        )
        sizes.append(CMBlockBufferGetDataLength(blockBuffer))
        cumulativeTrimDurationAtStart = cumulativeTrimDurationAtStart + trimAtStart
        cumulativeTrimDurationAtEnd = cumulativeTrimDurationAtEnd + trimAtEnd
    }

    let (createdSampleBuffer, status) = createReadySampleBuffer(
        data: completeBlockBuffer,
        format: format,
        count: sizes.count,
        timings: timings,
        sizes: sizes
    )
    guard status == noErr, let sampleBuffer = createdSampleBuffer else {
        throw .createReadyFailed
    }

    if block.isVideo(), sampleCount > 0 {
        guard setVideoAttachments(sampleBuffer, block) else {
            throw .noSampleAttachment
        }
    } else if block.isAudio(), let discontinuity = Optional(fromCxx: block.discontinuity()) {
        CMSetAttachment(
            sampleBuffer,
            key: CoreMediaSoftLink.kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence,
            value: discontinuity ? kCFBooleanTrue : kCFBooleanFalse,
            attachmentMode: shouldPropagate
        )
    }

    setTrimDurationAttachment(
        sampleBuffer,
        key: CoreMediaSoftLink.kCMSampleBufferAttachmentKey_TrimDurationAtStart,
        cumulativeTrimDurationAtStart
    )
    setTrimDurationAttachment(
        sampleBuffer,
        key: CoreMediaSoftLink.kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
        cumulativeTrimDurationAtEnd
    )

    #if ENABLE_ENCRYPTED_MEDIA
    if let info = block.info(), Optional(fromCxx: info.encryptionData()) != nil {
        guard setEncryptionAttachments(sampleBuffer, block) else {
            throw .noSampleAttachment
        }
    }
    #endif
    return sampleBuffer
}

// MARK: - Format descriptions

private let mediaStreamLog = Logger(subsystem: "com.apple.WebKit", category: "MediaStream")

// AudioToolbox doesn't declare a Vorbis format ID; CMUtilities.mm's kAudioFormatVorbis, pinned there by a static_assert.
private let audioFormatVorbis: AudioFormatID = 0x766f_7262

extension NSMutableDictionary {
    // The subscript casts its key to NSCopying at run time; an NSString key needs no cast.
    fileprivate func setExtension(_ key: CFString, _ value: AnyObject?) {
        if let value {
            setObject(value, forKey: key as NSString)
        } else {
            removeObject(forKey: key)
        }
    }
}

extension WebCore.FourCC {
    fileprivate var extensionAtomKey: NSString {
        assert(isExtensionAtomFourCCImpl(value))
        let characters: [4 of UInt8] = [
            UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
        guard let key = try? UTF8Span(validating: characters.span) else {
            preconditionFailure("An extension atom's FourCC is printable ASCII")
        }
        return Swift.String(copying: key) as NSString
    }
}

extension NSMutableDictionary {
    // An atom whose FourCC repeats an earlier atom's joins its data in an array.
    fileprivate func addExtensionAtom(_ fourCC: WebCore.FourCC, _ buffer: WebCore.SharedBuffer, isRepeated: Bool) {
        // FourCCs come from IPC; one that isn't printable ASCII can't be a key.
        guard isExtensionAtomFourCCImpl(fourCC.value) else {
            mediaLog.error("Ignoring an extension atom whose FourCC isn't printable")
            return
        }
        let key = fourCC.extensionAtomKey
        let data: CFData = WebCore.createCFDataForSharedBuffer(buffer)
        guard isRepeated, let existing = object(forKey: key) else {
            setObject(data, forKey: key)
            return
        }
        let datas = (existing as? [AnyObject] ?? [existing as AnyObject]) + [data]
        setObject(datas as CFArray, forKey: key)
    }
}

extension WebCore.TrackInfo {
    fileprivate func hasEncryptionInitData(_ fourCC: WebCore.FourCC, before index: Int = .max) -> Bool {
        #if ENABLE_ENCRYPTED_MEDIA
        (0..<min(index, encryptionInitDataCount())).contains { encryptionInitDataFourCC($0).value == fourCC.value }
        #else
        false
        #endif
    }
}

extension WebCore.VideoInfo {
    fileprivate func hasExtensionAtom(_ fourCC: WebCore.FourCC, before index: Int) -> Bool {
        (0..<index).contains { extensionAtomFourCC($0).value == fourCC.value }
    }
}

// The encryption init datas, then the video extension atoms, each with whether an atom before it has its FourCC.
private func forEachExtensionAtom(
    _ info: WebCore.TrackInfo,
    _ videoInfo: WebCore.VideoInfo?,
    _ body: (WebCore.FourCC, Bool, () -> WebCore.SharedBuffer) -> Void
) {
    #if ENABLE_ENCRYPTED_MEDIA
    for index in 0..<info.encryptionInitDataCount() {
        let fourCC = info.encryptionInitDataFourCC(index)
        body(fourCC, info.hasEncryptionInitData(fourCC, before: index)) { info.encryptionInitDataBuffer(index).get() }
    }
    #endif

    if let videoInfo {
        for index in 0..<videoInfo.extensionAtomCount() {
            let fourCC = videoInfo.extensionAtomFourCC(index)
            let isRepeated = info.hasEncryptionInitData(fourCC) || videoInfo.hasExtensionAtom(fourCC, before: index)
            body(fourCC, isRepeated) { videoInfo.extensionAtomBuffer(index).get() }
        }
    }
}

private func createExtensionsDictionary(_ info: WebCore.TrackInfo, _ videoInfo: WebCore.VideoInfo?) -> NSMutableDictionary? {
    if info.isAudio() {
        #if ENABLE_ENCRYPTED_MEDIA && HAVE_AVCONTENTKEYSESSION
        if Optional(fromCxx: info.encryptionData()) == nil {
            return nil
        }
        #else
        return nil
        #endif
    }

    // A sizing hint only; exceeding it costs a rehash. The video counts include the keys
    // createFormatDescriptionFromTrackInfo() goes on to add: FullRangeVideo, BitsPerComponent,
    // ColorPrimaries, TransferFunction, GammaLevel, YCbCrMatrix, both ChromaLocation fields,
    // FieldCount, FieldDetail and PixelAspectRatio.
    #if ENABLE_ENCRYPTED_MEDIA && HAVE_AVCONTENTKEYSESSION
    let maxNumberOfElements = info.isAudio() ? 5 : 15
    #else
    let maxNumberOfElements = info.isAudio() ? 5 : 12
    #endif
    let extensions = NSMutableDictionary(capacity: maxNumberOfElements)

    #if ENABLE_ENCRYPTED_MEDIA && HAVE_AVCONTENTKEYSESSION
    if let encryptionData = Optional(fromCxx: info.encryptionData()) {
        extensions.setExtension("CommonEncryptionProtected" as CFString, kCFBooleanTrue)
        let data = WebCore.createCFDataForSharedBuffer(encryptionData.second.get())
        if encryptionData.first == .CommonEncryptionTrackEncryptionBox {
            extensions.setExtension("CommonEncryptionTrackEncryptionBox" as CFString, data)
        } else if encryptionData.first == .TransportStreamEncryptionInitData {
            extensions.setExtension("TransportStreamEncryptionInitData" as CFString, data)
        }
        if let originalFormat = Optional(fromCxx: info.encryptionOriginalFormat()) {
            extensions.setExtension("CommonEncryptionOriginalFormat" as CFString, NSNumber(value: Int32(bitPattern: originalFormat.value)))
        }
    }
    #endif

    var atomKeyCount = 0
    forEachExtensionAtom(info, videoInfo) { fourCC, isRepeated, _ in
        if !isRepeated && isExtensionAtomFourCCImpl(fourCC.value) {
            atomKeyCount += 1
        }
    }
    if atomKeyCount > 0 {
        // Sized to its key count, it enumerates in the order CFDictionaryCreate's dictionary does.
        let atoms = NSMutableDictionary(capacity: atomKeyCount)
        forEachExtensionAtom(info, videoInfo) { fourCC, isRepeated, buffer in
            atoms.addExtensionAtom(fourCC, buffer(), isRepeated: isRepeated)
        }
        extensions.setExtension(CoreMediaSoftLink.kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms, atoms)
    }

    return extensions
}

extension WebCore.AudioInfo {
    fileprivate var hasCookieData: Bool {
        guard let cookieData = cookieData().get() else {
            return false
        }
        return cookieData.size() != 0
    }
}

private func createAudioFormatDescription(_ info: WebCore.TrackInfo, _ audioInfo: WebCore.AudioInfo) -> CMFormatDescription? {
    let streamDescription = WebCore.audioStreamBasicDescriptionFromAudioInfo(audioInfo)
    let cookie = audioInfo.cookieData().get().flatMap { WebCore.createCFDataForSharedBuffer($0) }
    let extensions = createExtensionsDictionary(info, nil) as CFDictionary?

    let (format, error) = createAudioFormatDescription(description: streamDescription, cookie: cookie, extensions: extensions)
    guard error == noErr else {
        mediaLog.debug("createAudioFormatDescription failed with \(error)")
        return nil
    }
    return format
}

// FIXME: only 32-bit floating point is recognised for 32-bit PCM (the only producer is the WebM parser), and PCM is assumed little-endian.
extension AudioStreamPCMFormat {
    fileprivate init?(encodedBitDepth bitDepth: UInt8) {
        switch bitDepth {
        case 8:
            self = .uint8
        case 16:
            self = .int16
        case 24:
            self = .int24
        case 32:
            self = .float32
        default:
            return nil
        }
    }
}

private func createLinearPCMFormatDescription(_ info: WebCore.TrackInfo, _ audioInfo: WebCore.AudioInfo) -> CMFormatDescription? {
    // Decoded audio is 32-bit float only, as encoded 32-bit PCM is taken to be.
    if audioInfo.isDecoded(), Optional(fromCxx: audioInfo.sampleFormat()) != .F32 {
        return nil
    }
    let bitDepth: UInt8 = audioInfo.isDecoded() ? 32 : audioInfo.bitDepth()
    guard let format = AudioStreamPCMFormat(encodedBitDepth: bitDepth) else {
        return nil
    }
    let isInterleaved = true
    let description = caAudioStreamDescriptionMake(Double(audioInfo.rate()), audioInfo.channels(), format.rawValue, isInterleaved)
    let (newFormat, status) = createAudioFormatDescription(
        description: description,
        layout: Optional(fromCxx: audioInfo.channelLayout()),
        extensions: createExtensionsDictionary(info, nil) as CFDictionary?
    )
    if status.invalidLayout {
        mediaStreamLog.error("createFormatDescriptionFromTrackInfo: invalid channel layout")
        return nil
    }
    guard status.status == noErr else {
        mediaStreamLog.error("createFormatDescriptionFromTrackInfo: CMAudioFormatDescriptionCreate failed with error \(status.status)")
        return nil
    }
    return newFormat
}

// For createFormatDescriptionFromTrackInfo (CMUtilities.mm); info is audioInfo as a TrackInfo.
@_expose(Cxx)
func audioFormatDescriptionImpl(
    _ info: consuming WebCore.ConstTrackInfoRefPtr,
    _ audioInfo: consuming WebCore.ConstAudioInfoRefPtr
) -> CMFormatDescription? {
    guard let info = info.get(), let audioInfo = audioInfo.get() else {
        return nil
    }
    return audioFormatDescription(info, audioInfo)
}

private func audioFormatDescription(_ info: WebCore.TrackInfo, _ audioInfo: WebCore.AudioInfo) -> CMFormatDescription? {
    switch audioInfo.codecName().value {
    #if ENABLE_OPUS
    case kAudioFormatOpus:
        guard WebCore.isOpusDecoderAvailable(), audioInfo.hasCookieData else {
            return nil
        }
        return createAudioFormatDescription(info, audioInfo)
    #endif
    #if ENABLE_VORBIS
    case audioFormatVorbis:
        guard WebCore.isVorbisDecoderAvailable(), audioInfo.hasCookieData else {
            return nil
        }
        return createAudioFormatDescription(info, audioInfo)
    #endif
    case kAudioFormatFLAC:
        guard audioInfo.hasCookieData else {
            return nil
        }
        return createAudioFormatDescription(info, audioInfo)
    case kAudioFormatLinearPCM:
        return createLinearPCMFormatDescription(info, audioInfo)
    default:
        return createAudioFormatDescription(info, audioInfo)
    }
}

extension WebCore.PlatformVideoChromaLocation {
    fileprivate var cmChromaLocation: CFString? {
        switch self {
        case .Left:
            kCVImageBufferChromaLocation_Left
        case .Center:
            kCVImageBufferChromaLocation_Center
        case .TopLeft:
            kCVImageBufferChromaLocation_TopLeft
        case .Top:
            kCVImageBufferChromaLocation_Top
        case .BottomLeft:
            kCVImageBufferChromaLocation_BottomLeft
        case .Bottom:
            kCVImageBufferChromaLocation_Bottom
        case .Dv420:
            kCVImageBufferChromaLocation_DV420
        default:
            nil
        }
    }
}

extension WebCore.PlatformVideoFieldDetail {
    fileprivate var cmFieldDetail: CFString? {
        switch self {
        case .TemporalTopFirst:
            kCVImageBufferFieldDetailTemporalTopFirst
        case .TemporalBottomFirst:
            kCVImageBufferFieldDetailTemporalBottomFirst
        case .SpatialFirstLineEarly:
            kCVImageBufferFieldDetailSpatialFirstLineEarly
        case .SpatialFirstLineLate:
            kCVImageBufferFieldDetailSpatialFirstLineLate
        default:
            nil
        }
    }
}

private func pixelFormatTypeForDecodedVideo(_ videoInfo: WebCore.VideoInfo, _ colorSpace: WebCore.PlatformVideoColorSpace) -> OSType? {
    guard let pixelFormat = Optional(fromCxx: videoInfo.pixelFormat()) else {
        return nil
    }

    // The 8-bit planar formats are repacked into a biplanar buffer when the CVPixelBuffer is created, or a triplanar one with alpha.
    let biPlanarFormat =
        Optional(fromCxx: colorSpace.fullRange) ?? false
        ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    switch pixelFormat {
    case .I420:
        return biPlanarFormat
    case .I420A:
        return Optional(fromCxx: WebCore.pixelFormatWithAlpha(biPlanarFormat))
    default:
        return nil
    }
}

// Calls add() with every property that can be expressed both as a CMFormatDescription extension and
// as a CVImageBuffer attachment.
private func addImageBufferProperties(
    _ videoInfo: WebCore.VideoInfo,
    _ colorSpace: WebCore.PlatformVideoColorSpace,
    _ add: (CFString, AnyObject) -> Void
) {
    if let primaries = Optional(fromCxx: colorSpace.primaries), let cmColorPrimaries = WebCore.convertToCMColorPrimaries(primaries) {
        add(kCVImageBufferColorPrimariesKey, cmColorPrimaries)
    }
    if let transfer = Optional(fromCxx: colorSpace.transfer) {
        if let cmTransferFunction = WebCore.convertToCMTransferFunction(transfer) {
            add(kCVImageBufferTransferFunctionKey, cmTransferFunction)
        }
        if transfer == .Gamma22curve {
            add(kCVImageBufferGammaLevelKey, NSNumber(value: 2.2))
        } else if transfer == .Gamma28curve {
            add(kCVImageBufferGammaLevelKey, NSNumber(value: 2.8))
        }
    }

    if let matrix = Optional(fromCxx: colorSpace.matrix), let cmMatrix = WebCore.convertToCMYCbCRMatrix(matrix) {
        add(kCVImageBufferYCbCrMatrixKey, cmMatrix)
    }

    if let chromaLocation = Optional(fromCxx: colorSpace.chromaLocation), let cmChromaLocation = chromaLocation.cmChromaLocation {
        add(kCVImageBufferChromaLocationTopFieldKey, cmChromaLocation)
        add(kCVImageBufferChromaLocationBottomFieldKey, cmChromaLocation)
    }

    if let fieldCount = Optional(fromCxx: videoInfo.fieldCount()) {
        add(kCVImageBufferFieldCountKey, NSNumber(value: fieldCount.rawValue))
    }

    if let fieldDetail = Optional(fromCxx: videoInfo.fieldDetail()), let cmFieldDetail = fieldDetail.cmFieldDetail {
        add(kCVImageBufferFieldDetailKey, cmFieldDetail)
    }

    // The two spacings are the numerator and denominator of a single fraction, as stored in
    // the `pasp` box. Emit them as an exact integer pair rather than as the two quotients
    // displaySize / size, which only approximate the ratio.
    let size = videoInfo.size()
    let displaySize = videoInfo.displaySize()
    let pixelAspectRatio = pixelAspectRatioImpl(size.width(), size.height(), displaySize.width(), displaySize.height())
    if pixelAspectRatio.valid {
        let spacings = NSMutableDictionary(capacity: 2)
        let horizontalKey = kCVImageBufferPixelAspectRatioHorizontalSpacingKey as NSString
        let verticalKey = kCVImageBufferPixelAspectRatioVerticalSpacingKey as NSString
        spacings.setObject(NSNumber(value: pixelAspectRatio.spacings.horizontal), forKey: horizontalKey)
        spacings.setObject(NSNumber(value: pixelAspectRatio.spacings.vertical), forKey: verticalKey)
        add(kCVImageBufferPixelAspectRatioKey, spacings)
    }
}

// A CVPixelBuffer is a CVBuffer, which some builds import as a class of its own (SharedVideoFrameLayout.swift).
func castBuffer<Target: AnyObject>(_ buffer: AnyObject, to _: Target.Type) -> Target {
    // swift-format-ignore: NeverForceUnwrap
    buffer as! Target
}

// For createFormatDescriptionWithAlpha (CMUtilities.mm); a CVBuffer, which the generated header names as C++ does.
@_expose(Cxx)
func formatDescriptionWithAlphaImpl(_ pixelBuffer: CVBuffer?) -> CMFormatDescription? {
    guard let pixelBuffer else {
        return nil
    }
    return createFormatDescriptionWithAlpha(castBuffer(pixelBuffer, to: CVPixelBuffer.self))
}

private func createFormatDescriptionWithAlpha(_ pixelBuffer: CVPixelBuffer) -> CMFormatDescription? {
    let (createdDescription, status) = createVideoFormatDescriptionForImageBuffer(castBuffer(pixelBuffer, to: CVBuffer.self))
    guard status == noErr, let description = createdDescription else {
        return nil
    }

    guard let extensions = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, CMFormatDescriptionGetExtensions(description))
    else {
        return description
    }
    let extensionsDictionary = extensions as NSMutableDictionary
    extensionsDictionary.setExtension(CoreMediaSoftLink.kCMFormatDescriptionExtension_ContainsAlphaChannel, kCFBooleanTrue)
    extensionsDictionary.setExtension(
        CoreMediaSoftLink.kCMFormatDescriptionExtension_AlphaChannelMode,
        CoreMediaSoftLink.kCMFormatDescriptionAlphaChannelMode_StraightAlpha
    )

    let (alphaDescription, alphaStatus) = createVideoFormatDescription(
        codecType: CVPixelBufferGetPixelFormatType(pixelBuffer),
        width: Int32(truncatingIfNeeded: CVPixelBufferGetWidth(pixelBuffer)),
        height: Int32(truncatingIfNeeded: CVPixelBufferGetHeight(pixelBuffer)),
        extensions: extensionsDictionary as CFDictionary
    )
    guard alphaStatus == noErr else {
        return description
    }
    return alphaDescription
}

// A CMSampleBuffer holds a single image buffer, so the block must hold exactly one frame.
// The format description is always derived from the image buffer.
private func makeDecodedVideoSampleBuffer(
    _ block: borrowing WebCore.MediaSamplesBlock,
    _ videoInfo: WebCore.VideoInfo
) throws(SampleBufferBuildError) -> CMSampleBuffer {
    if block.size() != 1 {
        throw .decodedVideoFrameCount
    }

    let colorSpace = videoInfo.colorSpace()
    let hasAlpha = Optional(fromCxx: videoInfo.pixelFormat()) == .I420A
    guard let pixelFormatType = pixelFormatTypeForDecodedVideo(videoInfo, colorSpace) else {
        throw .unsupportedDecodedVideoPixelFormat
    }

    guard let sampleData = block[0].data.get() else {
        throw .noDecodedVideoData
    }

    let videoDimensions = videoDimensionsImpl(videoInfo.size().width(), videoInfo.size().height())
    guard videoDimensions.valid, videoDimensions.dimensions.width > 0, videoDimensions.dimensions.height > 0 else {
        throw .invalidDecodedVideoSize
    }
    let width = Int(videoDimensions.dimensions.width)
    let height = Int(videoDimensions.dimensions.height)

    let attributes = NSMutableDictionary(capacity: 1)
    attributes.setObject(NSMutableDictionary(), forKey: kCVPixelBufferIOSurfacePropertiesKey as NSString)
    let (createdPixelBuffer, pixelBufferStatus) = createPixelBuffer(
        width: width,
        height: height,
        pixelFormat: pixelFormatType,
        attributes: attributes as CFDictionary
    )
    guard pixelBufferStatus == kCVReturnSuccess, let pixelBuffer = createdPixelBuffer else {
        throw .createPixelBufferFailed
    }

    guard WebCore.copyI420ToPixelBuffer(sampleData, width, height, pixelBuffer) else {
        throw .invalidDecodedVideoData
    }

    let imageBuffer = castBuffer(pixelBuffer, to: CVBuffer.self)
    addImageBufferProperties(videoInfo, colorSpace) { key, value in
        CVBufferSetAttachment(imageBuffer, key, value, .shouldPropagate)
    }

    let formatDescription: CMFormatDescription?
    if hasAlpha {
        formatDescription = createFormatDescriptionWithAlpha(pixelBuffer)
    } else {
        let (createdDescription, status) = createVideoFormatDescriptionForImageBuffer(imageBuffer)
        formatDescription = status == noErr ? createdDescription : nil
    }
    guard let formatDescription else {
        throw .createImageBufferFormatDescriptionFailed
    }

    let timing = CMSampleTimingInfo(
        duration: block[0].duration.cmTime,
        presentationTimeStamp: block[0].presentationTime.cmTime,
        decodeTimeStamp: block[0].decodeTime.cmTime
    )
    let (createdSampleBuffer, status) = createReadySampleBufferWithImageBuffer(
        imageBuffer: imageBuffer,
        format: formatDescription,
        timing: timing
    )
    guard status == noErr, let sampleBuffer = createdSampleBuffer else {
        throw .createReadyWithImageBufferFailed
    }

    if block[0].flags & WebCore.MediaSample.IsNonDisplaying.rawValue != 0,
        let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
    {
        guard let attachments = WebCore.sampleAttachmentsDictionary(attachmentsArray, 0) else {
            fatalError("A sample's attachments are not a dictionary")
        }
        WebCore.setSampleAttachment(attachments, CoreMediaSoftLink.kCMSampleAttachmentKey_DoNotDisplay, kCFBooleanTrue)
    }
    return sampleBuffer
}

// For createFormatDescriptionFromTrackInfo (CMUtilities.mm); info is videoInfo as a TrackInfo.
@_expose(Cxx)
func videoFormatDescriptionImpl(
    _ info: consuming WebCore.ConstTrackInfoRefPtr,
    _ videoInfo: consuming WebCore.ConstVideoInfoRefPtr
) -> CMFormatDescription? {
    guard let info = info.get(), let videoInfo = videoInfo.get() else {
        return nil
    }
    return videoFormatDescription(info, videoInfo)
}

private func videoFormatDescription(_ info: WebCore.TrackInfo, _ videoInfo: WebCore.VideoInfo) -> CMFormatDescription? {
    guard let extensions = createExtensionsDictionary(info, videoInfo) else {
        return nil
    }
    let colorSpace = videoInfo.colorSpace()

    var codecType = videoInfo.codecName().value
    if videoInfo.isDecoded() {
        guard let pixelFormatType = pixelFormatTypeForDecodedVideo(videoInfo, colorSpace) else {
            return nil
        }
        codecType = pixelFormatType
    }

    // The pixel formats with an alpha plane are video range only.
    let alphaPlaneBitDepth = Optional(fromCxx: WebCore.bitDepthOfPixelFormatWithAlphaPlane(codecType))
    if Optional(fromCxx: colorSpace.fullRange) ?? false, alphaPlaneBitDepth == nil {
        extensions.setExtension(CoreMediaSoftLink.kCMFormatDescriptionExtension_FullRangeVideo, kCFBooleanTrue)
    }

    if alphaPlaneBitDepth != nil {
        extensions.setExtension(CoreMediaSoftLink.kCMFormatDescriptionExtension_ContainsAlphaChannel, kCFBooleanTrue)
        extensions.setExtension(
            CoreMediaSoftLink.kCMFormatDescriptionExtension_AlphaChannelMode,
            CoreMediaSoftLink.kCMFormatDescriptionAlphaChannelMode_StraightAlpha
        )
    }

    if videoInfo.hasSeparateAlphaStream(), let separateAlphaStreamKey = WebCore.separateAlphaStreamExtensionKey() {
        extensions.setExtension(separateAlphaStreamKey, kCFBooleanTrue)
    }

    let bitDepth = alphaPlaneBitDepth ?? Int32(videoInfo.bitDepth())
    extensions.setExtension(CoreMediaSoftLink.kCMFormatDescriptionExtension_BitsPerComponent, NSNumber(value: bitDepth))

    addImageBufferProperties(videoInfo, colorSpace) { key, value in
        extensions.setExtension(key, value)
    }

    #if WTF_PLATFORM_VISION
    WebCore.addImmersiveVideoMetadataExtensions(extensions as CFMutableDictionary, videoInfo)
    #endif

    let videoDimensions = videoDimensionsImpl(videoInfo.size().width(), videoInfo.size().height())
    guard videoDimensions.valid else {
        mediaLog.error("createFormatDescriptionFromTrackInfo: invalid video size")
        return nil
    }
    let dimensions = videoDimensions.dimensions

    let (formatDescription, error) = createVideoFormatDescription(
        codecType: codecType,
        width: dimensions.width,
        height: dimensions.height,
        extensions: extensions as CFDictionary
    )
    guard error == noErr else {
        mediaLog.error("CMVideoFormatDescriptionCreate failed with error \(error)")
        return nil
    }
    return formatDescription
}

// For getKeyIDs (CMUtilities.mm).
@_expose(Cxx)
func formatDescriptionKeyIDsImpl(_ description: CMFormatDescription?) -> WebCore.FormatDescriptionKeyIDs {
    var result = WebCore.FormatDescriptionKeyIDs()
    guard let description else {
        return result
    }
    if let extensionValue = CMFormatDescriptionGetExtension(description, extensionKey: "CommonEncryptionTrackEncryptionBox" as CFString) {
        // AVStreamDataParser will attach the 'tenc' box to each sample, not including the leading
        // size and boxType data. Extract the 'tenc' box and use that box to derive the sample's
        // keyID.
        guard let trackEncryptionData = extensionValue as? Data,
            let box = TrackEncryptionBox.parseWithoutTypeAndSize(trackEncryptionData.span)
        else {
            return result
        }
        result.source = .TrackEncryptionBox
        result.keyID = box.fields.defaultKID
        return result
    }
    // AVStreamDataParser will attach a JSON transport stream encryption
    // description object to each sample. Use a static keyID in this case
    // as MPEG2-TS encryption does not specify a particular keyID in the
    // stream.
    if CMFormatDescriptionGetExtension(description, extensionKey: "TransportStreamEncryptionInitData" as CFString) != nil {
        result.source = .TransportStream
    }
    return result
}

#endif // ENABLE_WEBCORE_SWIFT
