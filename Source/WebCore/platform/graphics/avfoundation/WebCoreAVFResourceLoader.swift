// Copyright (C) 2012-2025 Apple Inc. All rights reserved.
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

// What WebCoreAVFResourceLoader reads of and tells the AVAssetResourceLoadingRequest it answers: the requested range,
// the content information, the data, and the end of the load. objc/WebCoreAVFResourceLoader.mm keeps the C++ class
// that the AVFoundation player creates for each request, the loads through WebCore's media resource loader and the
// data URL decoder, the timeout, the logging, and finishing a request, which can throw.
//
// Threads: the media resource loader's target dispatcher.

internal import AVFoundation
import WebCore_Private.Core.WebCoreAVFResourceLoader

extension WebCore.WebCoreAVFResourceLoader {
    @cxx
    @implementation
    func startLoading() {
        if isLoadingDataURL() {
            return
        }

        let request = m_avRequest.get()
        let dataRequest = request?.dataRequest
        let requestedOffset = dataRequest?.requestedOffset ?? -1
        let requestedLength = Int64(dataRequest?.requestedLength ?? -1)
        m_currentOffset = requestedOffset
        m_requestedOffset = requestedOffset
        m_requestedLength = requestedLength

        var requestsRange = false
        if let _ = dataRequest {
            requestsRange = requestedLength > 0
        }
        switch startResourceLoad(requestsRange, dataRequest?.requestsAllDataToEndOfResource ?? false) {
        case .Loading:
            startLoadingTimer()
        case .LoadingDataURL:
            return
        case .Failed:
            request?.finishLoading(with: nil)
        @unknown default:
            return
        }
    }

    @cxx
    @implementation
    func didReceiveResponse(_ status: Int32, _ responseOffset: UInt64, _ contentLength: Int64, _ contentType: CFString!, _ isLoadingDataURL: Bool) -> Bool {
        let request = m_avRequest.get()

        if status != 0 && !(200..<300).contains(status) {
            request?.finishLoading(with: nil)
            return true
        }

        m_responseOffset = Int(truncatingIfNeeded: responseOffset)

        guard let request, let contentInformation = request.contentInformationRequest else {
            return false
        }

        contentInformation.contentType = contentType.map { $0 as Swift.String }
        contentInformation.contentLength = contentLength
        contentInformation.isByteRangeAccessSupported = true

        // Do not set "EntireLengthAvailableOnDemand" to YES when the loader is DataURLResourceMediaLoader.
        // When the property is YES, AVAssetResourceLoader will request small data ranges over and over again
        // during the playback. For DataURLResourceMediaLoader, that means it needs to decode the URL repeatedly,
        // which is very inefficient for long URLs.
        // FIXME: don't have blob exception once rdar://132719739 is fixed.
        if !isLoadingDataURL {
            contentInformation.isEntireLengthAvailableOnDemand = true
        }

        if let _ = request.dataRequest {
            return false
        }
        finishRequestLoading()
        stopLoading()
        return true
    }

    @cxx
    @implementation
    func respondWithData(_ segments: CFArray!) -> Bool {
        guard let dataRequest = m_avRequest.get()?.dataRequest else {
            return true
        }

        // Check for possible unsigned overflow.
        assert(m_currentOffset >= m_requestedOffset)
        assert(m_requestedLength >= m_currentOffset &- m_requestedOffset)

        var remainingLength = UInt64(bitPattern: m_requestedLength &- (m_currentOffset &- m_requestedOffset))
        var bytesToSkip = UInt64(bitPattern: m_currentOffset) &- UInt64(truncatingIfNeeded: m_responseOffset)

        let segments = segments.map { $0 as NSArray } ?? NSArray()
        for case let segment as NSData in segments {
            if remainingLength == 0 {
                break
            }
            let length = UInt64(segment.length)
            var usableBytes = length
            var bytesOffset: UInt64 = 0
            if bytesToSkip != 0 {
                if bytesToSkip > length {
                    bytesToSkip -= length
                    continue
                }
                usableBytes = length - bytesToSkip
                bytesOffset = bytesToSkip
                bytesToSkip = 0
            }
            m_currentOffset = m_currentOffset &+ Int64(usableBytes)
            if bytesOffset == 0 && usableBytes <= remainingLength {
                dataRequest.respond(with: segment as Data)
            } else {
                usableBytes = min(usableBytes, remainingLength)
                dataRequest.respond(with: segment.subdata(with: NSRange(location: Int(bytesOffset), length: Int(usableBytes))))
            }
            remainingLength -= usableBytes
        }

        // There was not enough data in the buffer to satisfy the data request.
        if remainingLength != 0 {
            return false
        }

        assert(m_currentOffset >= m_requestedOffset &+ m_requestedLength)

        finishRequestLoading()
        stopLoading()
        return true
    }

    @cxx
    @implementation
    func failLoading(_ error: CFError!) {
        let request = m_avRequest.get()

        // <rdar://problem/13987417> Set the contentType of the contentInformationRequest to an empty
        // string to trigger AVAsset's playable value to complete loading.
        if let contentInformation = request?.contentInformationRequest, contentInformation.contentType == nil {
            contentInformation.contentType = ""
        }

        request?.finishLoading(with: error.map { $0 as any Error })
        stopLoading()
    }
}
