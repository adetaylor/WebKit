/*
 * Copyright (C) 2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "ShapeDetectionVisionSupport.h"

#if HAVE(SHAPE_DETECTION_API_IMPLEMENTATION) && HAVE(VISION)

#import <CoreML/CoreML.h>
#import <wtf/RetainPtr.h>
#import <wtf/StdLibExtras.h>
#import <pal/cocoa/CoreMLSoftLink.h>
#import <pal/cocoa/VisionSoftLink.h>

namespace WebCore::ShapeDetection {

NSString *visionBarcodeSymbologyName(VisionBarcodeSymbology symbology)
{
    switch (symbology) {
    case VisionBarcodeSymbology::Aztec:
        return PAL::get_Vision_VNBarcodeSymbologyAztecSingleton();
    case VisionBarcodeSymbology::Codabar:
        return PAL::get_Vision_VNBarcodeSymbologyCodabarSingleton();
    case VisionBarcodeSymbology::Code39:
        return PAL::get_Vision_VNBarcodeSymbologyCode39Singleton();
    case VisionBarcodeSymbology::Code39Checksum:
        return PAL::get_Vision_VNBarcodeSymbologyCode39ChecksumSingleton();
    case VisionBarcodeSymbology::Code39FullASCII:
        return PAL::get_Vision_VNBarcodeSymbologyCode39FullASCIISingleton();
    case VisionBarcodeSymbology::Code39FullASCIIChecksum:
        return PAL::get_Vision_VNBarcodeSymbologyCode39FullASCIIChecksumSingleton();
    case VisionBarcodeSymbology::Code93:
        return PAL::get_Vision_VNBarcodeSymbologyCode93Singleton();
    case VisionBarcodeSymbology::Code93i:
        return PAL::get_Vision_VNBarcodeSymbologyCode93iSingleton();
    case VisionBarcodeSymbology::Code128:
        return PAL::get_Vision_VNBarcodeSymbologyCode128Singleton();
    case VisionBarcodeSymbology::DataMatrix:
        return PAL::get_Vision_VNBarcodeSymbologyDataMatrixSingleton();
    case VisionBarcodeSymbology::Ean8:
        return PAL::get_Vision_VNBarcodeSymbologyEAN8Singleton();
    case VisionBarcodeSymbology::Ean13:
        return PAL::get_Vision_VNBarcodeSymbologyEAN13Singleton();
    case VisionBarcodeSymbology::GS1DataBar:
        return PAL::get_Vision_VNBarcodeSymbologyGS1DataBarSingleton();
    case VisionBarcodeSymbology::GS1DataBarExpanded:
        return PAL::get_Vision_VNBarcodeSymbologyGS1DataBarExpandedSingleton();
    case VisionBarcodeSymbology::GS1DataBarLimited:
        return PAL::get_Vision_VNBarcodeSymbologyGS1DataBarLimitedSingleton();
    case VisionBarcodeSymbology::I2of5:
        return PAL::get_Vision_VNBarcodeSymbologyI2of5Singleton();
    case VisionBarcodeSymbology::I2of5Checksum:
        return PAL::get_Vision_VNBarcodeSymbologyI2of5ChecksumSingleton();
    case VisionBarcodeSymbology::Itf14:
        return PAL::get_Vision_VNBarcodeSymbologyITF14Singleton();
    case VisionBarcodeSymbology::MicroPDF417:
        return PAL::get_Vision_VNBarcodeSymbologyMicroPDF417Singleton();
    case VisionBarcodeSymbology::MicroQR:
        return PAL::get_Vision_VNBarcodeSymbologyMicroQRSingleton();
    case VisionBarcodeSymbology::Pdf417:
        return PAL::get_Vision_VNBarcodeSymbologyPDF417Singleton();
    case VisionBarcodeSymbology::Qr:
        return PAL::get_Vision_VNBarcodeSymbologyQRSingleton();
    case VisionBarcodeSymbology::Upce:
        return PAL::get_Vision_VNBarcodeSymbologyUPCESingleton();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static void configureRequestToUseCPUOrGPU(VNRequest *request)
{
    NSError *error = nil;
    RetainPtr supportedComputeStageDevices = [request supportedComputeStageDevicesAndReturnError:&error];
    if (!supportedComputeStageDevices || error)
        return;

    // FIXME: Remove the suppression once https://github.com/llvm/llvm-project/pull/230818 is deployed (rdar://189710680).
    for (SUPPRESS_UNRETAINED_LOCAL VNComputeStage computeStage in supportedComputeStageDevices.get()) {
        bool set = false;
        // FIXME: Remove the suppression once https://github.com/llvm/llvm-project/pull/230818 is deployed (rdar://189710680).
        for (SUPPRESS_UNRETAINED_LOCAL id<MLComputeDeviceProtocol> device in supportedComputeStageDevices.get()[computeStage]) {
            if ([device isKindOfClass:PAL::getMLGPUComputeDeviceClassSingleton()]) {
                [request setComputeDevice:device forComputeStage:computeStage];
                set = true;
                break;
            }
        }
        if (!set) {
            // FIXME: Remove the suppression once https://github.com/llvm/llvm-project/pull/230818 is deployed (rdar://189710680).
            for (SUPPRESS_UNRETAINED_LOCAL id<MLComputeDeviceProtocol> device in supportedComputeStageDevices.get()[computeStage]) {
                if ([device isKindOfClass:PAL::getMLGPUComputeDeviceClassSingleton()]) {
                    [request setComputeDevice:device forComputeStage:computeStage];
                    break;
                }
            }
        }
    }
}

VNDetectBarcodesRequest *createVisionBarcodesRequest()
{
    // It's important that both getSupportedFormats() and detect() use a VNDetectBarcodesRequest that is
    // configured the same way. This function is intended to make sure both VNDetectBarcodesRequests are
    // configured accordingly.
    RetainPtr result = adoptNS([PAL::allocVNDetectBarcodesRequestInstance() init]);
    configureRequestToUseCPUOrGPU(result.get());
    return result.leakRef();
}

VNDetectFaceLandmarksRequest *createVisionFaceLandmarksRequest()
{
    RetainPtr result = adoptNS([PAL::allocVNDetectFaceLandmarksRequestInstance() init]);
    configureRequestToUseCPUOrGPU(result.get());
    return result.leakRef();
}

VNRecognizeTextRequest *createVisionTextRequest()
{
    RetainPtr result = adoptNS([PAL::allocVNRecognizeTextRequestInstance() init]);
    configureRequestToUseCPUOrGPU(result.get());
    return result.leakRef();
}

bool performVisionRequest(CGImageRef image, VNRequest *request)
{
    RetainPtr imageRequestHandler = adoptNS([PAL::allocVNImageRequestHandlerInstance() initWithCGImage:image options:@{ }]);

    NSError *error = nil;
    auto result = [imageRequestHandler performRequests:@[request] error:&error];
    return result && !error;
}

size_t visionResultCount(VNRequest *request)
{
    return request.results.count;
}

VNBarcodeObservation *visionBarcodeObservation(VNDetectBarcodesRequest *request, size_t index)
{
    return request.results[index];
}

VNFaceObservation *visionFaceObservation(VNDetectFaceLandmarksRequest *request, size_t index)
{
    return request.results[index];
}

VNRecognizedTextObservation *visionTextObservation(VNRecognizeTextRequest *request, size_t index)
{
    return request.results[index];
}

NSString *visionTopCandidateString(VNRecognizedTextObservation *observation)
{
    return [observation topCandidates:1][0].string;
}

CGPoint visionLandmarkPointInImage(VNFaceLandmarkRegion2D *landmark, CGSize imageSize, size_t index)
{
    return unsafeMakeSpan([landmark pointsInImageOfSize:imageSize], landmark.pointCount)[index];
}

static Vector<FloatPoint> cornerPoints(CGPoint topLeft, CGPoint topRight, CGPoint bottomRight, CGPoint bottomLeft)
{
    return { topLeft, topRight, bottomRight, bottomLeft };
}

void DetectedShapes::appendBarcode(CGRect boundingBox, NSString *rawValue, BarcodeFormat format, CGPoint topLeft, CGPoint topRight, CGPoint bottomRight, CGPoint bottomLeft)
{
    m_barcodes.append({ boundingBox, rawValue, format, cornerPoints(topLeft, topRight, bottomRight, bottomLeft) });
}

void DetectedShapes::appendFace(CGRect boundingBox)
{
    m_faces.append({ boundingBox, Vector<Landmark> { } });
}

void DetectedShapes::appendFaceLandmark(LandmarkType type)
{
    RELEASE_ASSERT(!m_faces.isEmpty());
    m_faces.last().landmarks->append({ { }, type });
}

void DetectedShapes::appendFaceLandmarkLocation(CGPoint location)
{
    RELEASE_ASSERT(!m_faces.isEmpty() && !m_faces.last().landmarks->isEmpty());
    m_faces.last().landmarks->last().locations.append(location);
}

void DetectedShapes::appendText(CGRect boundingBox, NSString *rawValue, CGPoint topLeft, CGPoint topRight, CGPoint bottomRight, CGPoint bottomLeft)
{
    m_texts.append({ boundingBox, rawValue, cornerPoints(topLeft, topRight, bottomRight, bottomLeft) });
}

} // namespace WebCore::ShapeDetection

#endif // HAVE(SHAPE_DETECTION_API_IMPLEMENTATION) && HAVE(VISION)
