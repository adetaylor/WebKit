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
#import "DetectedShapes.h"

#if HAVE(SHAPE_DETECTION_API_IMPLEMENTATION) && HAVE(VISION)

namespace WebCore::ShapeDetection {

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
