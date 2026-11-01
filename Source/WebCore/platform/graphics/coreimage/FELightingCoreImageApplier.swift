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

#if ENABLE_WEBCORE_SWIFT
#if USE_CORE_IMAGE

import CoreGraphics
import CoreImage
import Darwin
import Foundation
import WebCore_Internal.FELightingParameters
import WebCore_Internal.FilterSwiftBridge
import WebCore_Internal.FloatPoint
import WebCore_Internal.FloatRect
import WebCore_Internal.FloatSize
import WebCore_Internal.IntRect
import WebCore_Internal.LightSourceParameters

// FEDiffuseLighting and FESpecularLighting in Core Image: the lighting Metal kernel with the effect's and the light
// source's constants (positions resolved for the filter).
func feLightingApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FELightingParameters,
    _ lightSource: borrowing WebCore.LightSourceParameters,
    _ lightingColor: WebCore.FilterColorComponents,
    _ input: borrowing FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let inputImage = input.ciImage, let kernel = lightingKernel else {
        return false
    }

    let filterRegion = context.absoluteEnclosingFilterRegion
    var extent = context.flippedRectRelativeToAbsoluteEnclosingFilterRegion(result.absoluteImageRect)
    // Work around a bug where the extent of the kernel is too large after compositing with other CIImages (TODO: file the radar).
    extent.shiftMaxXEdgeBy(1)

    var kernelUnitLength = WebCore.FloatSize(parameters.kernelUnitLengthX, parameters.kernelUnitLengthY)
    if kernelUnitLength.isZero() {
        kernelUnitLength = WebCore.FloatSize(1, 1)
    }

    let isDiffuse = parameters.type == .Diffuse
    var lightingConstants = LightingKernelConstants()
    lightingConstants.append(UInt32(isDiffuse ? 0 : 1))
    lightingConstants.pad(to: 8)
    // textureOrigin.
    lightingConstants.append(Float(0))
    lightingConstants.append(Float(0))
    lightingConstants.append(parameters.surfaceScale)
    lightingConstants.append(isDiffuse ? parameters.diffuseConstant : parameters.specularConstant)
    lightingConstants.append(parameters.specularExponent)
    lightingConstants.append(filterRegion.maxY())
    lightingConstants.append(kernelUnitLength.width())
    lightingConstants.append(kernelUnitLength.height())
    lightingConstants.pad(to: 48)
    lightingConstants.append(lightingColor.red)
    lightingConstants.append(lightingColor.green)
    lightingConstants.append(lightingColor.blue)
    lightingConstants.append(lightingColor.alpha)

    var lightSourceConstants = LightingKernelConstants()
    var azimuthRadians: Float = 0
    var elevationRadians: Float = 0
    var specularExponent: Float = 0
    var limitingConeAngleRadians: Float = 0
    var coneCutOffLimit: Float = 0
    var coneFullLight: Float = 0
    var position = (Float(0), Float(0), Float(0))
    var pointsAt = (Float(0), Float(0), Float(0))
    let lightSourceType: UInt32
    switch lightSource.type {
    case .Point:
        lightSourceType = 1
        position = scaledLightPosition(context, lightSource.position)
    case .Spot:
        lightSourceType = 2
        position = scaledLightPosition(context, lightSource.position)
        pointsAt = scaledLightPosition(context, lightSource.pointsAt)
        specularExponent = lightSource.specularExponent
        let limitingConeAngle = lightSource.limitingConeAngle
        limitingConeAngleRadians = LightingModel.deg2rad(limitingConeAngle)
        // FIXME: Share code with the software applier.
        // Spot light edge darkening depends on an absolute treshold
        // according to the SVG 1.1 SE light regression tests (but this is not described in the spec?).
        let antiAliasThreshold = Float(0.016 as Double)
        if limitingConeAngle == 0 {
            coneFullLight = -antiAliasThreshold
        } else {
            var angle = limitingConeAngle.magnitude
            angle = 90 < angle ? 90 : angle
            coneCutOffLimit = cosf(LightingModel.deg2rad(180 - angle))
            coneFullLight = coneCutOffLimit - antiAliasThreshold
        }
    default:
        lightSourceType = 0
        azimuthRadians = LightingModel.deg2rad(lightSource.azimuth)
        elevationRadians = LightingModel.deg2rad(lightSource.elevation)
    }
    lightSourceConstants.append(lightSourceType)
    lightSourceConstants.append(azimuthRadians)
    lightSourceConstants.append(elevationRadians)
    lightSourceConstants.append(specularExponent)
    lightSourceConstants.append(limitingConeAngleRadians)
    lightSourceConstants.append(coneCutOffLimit)
    lightSourceConstants.append(coneFullLight)
    lightSourceConstants.pad(to: 32)
    lightSourceConstants.append(position.0)
    lightSourceConstants.append(position.1)
    lightSourceConstants.append(position.2)
    lightSourceConstants.pad(to: 48)
    lightSourceConstants.append(pointsAt.0)
    lightSourceConstants.append(pointsAt.1)
    lightSourceConstants.append(pointsAt.2)
    lightSourceConstants.pad(to: 64)

    let arguments: [Any] = [inputImage, lightingConstants.data, lightSourceConstants.data]
    guard
        let outputImage = kernel.apply(extent: cgRect(extent), roiCallback: { _, destinationRect in destinationRect }, arguments: arguments)
    else {
        return false
    }

    // Part 2 of the workaround; this extent modification is necessary to avoid this cropping being a no-op.
    extent.shiftMaxXEdgeBy(-1)
    result.setCIImage(outputImage.cropped(to: cgRect(extent)))
    return true
}

// A point or spot light's position for the kernel: resolved, then scaled by the filter scale.
// FIXME: this Z scale is different to what the software applier does.
private func scaledLightPosition(_ context: borrowing WebCore.FilterApplyContext, _ position: WebCore.FloatPoint3D) -> (Float, Float, Float)
{
    let scaled = context.scaledByFilterScale(WebCore.FloatPoint(position.x(), position.y()))
    return (scaled.x(), scaled.y(), position.z() * context.filterScale.width())
}

private func cgRect(_ rect: WebCore.FloatRect) -> CGRect {
    CGRect(x: CGFloat(rect.x()), y: CGFloat(rect.y()), width: CGFloat(rect.width()), height: CGFloat(rect.height()))
}

// A kernel constant buffer, laid out as the Metal structs (and the C++ ones the C++ applier copied): little-endian,
// with zeroed padding.
private struct LightingKernelConstants {
    private var bytes: [UInt8]

    init() {
        bytes = []
        bytes.reserveCapacity(64)
    }

    var data: Data {
        Data(bytes)
    }

    mutating func append(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func append(_ value: Float) {
        append(value.bitPattern)
    }

    mutating func pad(to offset: Int) {
        while bytes.count < offset {
            bytes.append(0)
        }
    }
}

// The lighting kernel, compiled on first use; nil if that fails.
private let lightingKernel: CIKernel? = (try? CIKernel.kernels(withMetalString: lightingKernelSource))?.first

private let lightingKernelSource = #"""
     /* NOLINT */
    extern "C" {
    namespace coreimage {

    enum class LightingType : uint32_t {
        Diffuse,
        Specular,
    };

    enum class LightSourceType : uint32_t {
        Distant,
        Point,
        Spot,
    };

    struct LightingConstants {
        LightingType lightingType;
        vector_float2 textureOrigin;
        float surfaceScale;
        float lightingConstant; // diffuse or specular.
        float specularExponent;
        float extentBottom;
        vector_float2 kernelUnitLength;
        vector_float4 lightingColor;
    };

    struct LightSourceConstants {
        LightSourceType lightSourceType;
        float azimuthRadians;
        float elevationRadians;
        float specularExponent;
        float limitingConeAngleRadians;
        float coneCutOffLimit;
        float coneFullLight;
        vector_float3 position; // x, y, z.
        vector_float3 pointsAt; // pointsAtX, Y, Z.
    };

    struct Kernel3x3 {
        vector_float2 data[3][3];
    };

    struct Normal {
        vector_float2 factor;
        vector_float2 data[3][3];
    };


    using LightingFactors = vector_float2[3][3];

    // These are the kernels specified in https://drafts.csswg.org/filter-effects/#feDiffuseLightingElement
    static constant Normal topLeftKernel = {
        { 2.f / 3, 2.f / 3 },
        {
            { {  0,  0 }, {  0,  0 },  {  0,  0 } },
            { {  0,  0 }, { -2, -2 },  {  2, -1 } },
            { {  0,  0 }, { -1,  2 },  {  1,  1 } },
        }
    };

    static constant Normal topRowKernel = {
        { 1 / 3, 1 / 2 },
        {
            { {  0,  0 }, {  0,  0 },  {  0,  0 } },
            { { -2, -1 }, {  0, -2 },  {  2, -1 } },
            { { -1,  1 }, {  0,  2 },  {  1,  1 } },
        }
    };

    static constant Normal topRightKernel = {
        { 2 / 3, 2 / 3 },
        {
            { {  0,  0 }, {  0,  0 },  {  0,  0 } },
            { { -2, -1 }, {  2, -2 },  {  0,  0 } },
            { { -1,  1 }, {  1,  2 },  {  0,  0 } },
        }
    };

    static constant Normal leftKernel = {
        { 1 / 2, 1 / 3 },
        {
            { {  0,  0 }, { -1, -2 },  {  1, -1 } },
            { {  0,  0 }, { -2,  0 },  {  2,  0 } },
            { {  0,  0 }, { -1,  2 },  {  1,  1 } },
        }
    };

    static constant Normal interiorKernel = {
        { 1.f / 4, 1.f / 4 },
        {
            { { -1, -1 }, {  0, -2 },  {  1, -1 } },
            { { -2,  0 }, {  0,  0 },  {  2,  0 } },
            { { -1,  1 }, {  0,  2 },  {  1,  1 } },
        }
    };

    static constant Normal rightKernel = {
        { 1 / 2, 1 / 3 },
        {
            { { -1, -1 }, {  1, -2 },  {  0,  0 } },
            { { -2,  0 }, {  2,  0 },  {  0,  0 } },
            { { -1,  1 }, {  1,  2 },  {  0,  0 } },
        }
    };

    static constant Normal bottomLeftKernel = {
        { 2 / 3, 2 / 3 },
        {
            { {  0,  0 }, { -1, -2 },  {  1, -1 } },
            { {  0,  0 }, { -2,  2 },  {  2,  1 } },
            { {  0,  0 }, {  0,  0 },  {  0,  0 } },
        }
    };

    static constant Normal bottomRowKernel = {
        { 1 / 3, 1 / 2 },
        {
            { { -1, -1 }, {  0, -2 },  {  1, -1 } },
            { { -2,  1 }, {  0,  2 },  {  2,  1 } },
            { {  0,  0 }, {  0,  0 },  {  0,  0 } },
        }
    };

    static constant Normal bottomRightKernel = {
        { 2 / 3, 2 / 3 },
        {
            { { -1, -1 }, {  1, -2 },  {  0,  0 } },
            { { -2,  1 }, {  2,  2 },  {  0,  0 } },
            { {  0,  0 }, {  0,  0 },  {  0,  0 } },
        }
    };


    using Normals = Normal[3][3];

    static constant Normals normals = {
        { topLeftKernel,    topRowKernel,       topRightKernel      },
        { leftKernel,       interiorKernel,     rightKernel         },
        { bottomLeftKernel, bottomRowKernel,    bottomRightKernel   }
    };

    bool isZero(float2 value)
    {
        return value.x == 0 && value.y == 0;
    }

    float computeLightFactor(
        constant LightingConstants* constants,
        float3 lightVector, float2 factor, float2 normal)
    {
        float k = 0;
        switch (constants->lightingType) {
        case LightingType::Diffuse:
            if (isZero(normal)) // approx
                k = lightVector.z;
            else {
                float2 n = normal * -constants->surfaceScale;
                n *= factor;

                float3 surfaceNormal = { 0, 0, 1 };
                surfaceNormal.xy = n;
                k = dot(surfaceNormal, lightVector) / length(surfaceNormal);
            }
            break;
        case LightingType::Specular: {
            const float3 eyeVector = { 0, 0, 1 };

            float3 halfwayVector = lightVector + eyeVector;
            if (length(halfwayVector) == 0)
                return 0;

            // FIXME: Need an "approximately zero".
            if (isZero(normal)) {
                float nDotH = halfwayVector.z / length(halfwayVector);
                k = pow(nDotH, constants->specularExponent);
            } else {
                float2 n = normal * -constants->surfaceScale;
                n *= factor;

                float3 surfaceNormal = { 0, 0, 1 };
                surfaceNormal.xy = n;

                float nDotH = dot(surfaceNormal, halfwayVector) / length(surfaceNormal) / length(halfwayVector);
                k = pow(nDotH, constants->specularExponent);
            }
            break;
        }
        }
        return constants->lightingConstant * k;
    }

    float3 computeLightColor(
        constant LightSourceConstants* lightSource,
        float3 color,
        float3 lightVector)
    {
        switch (lightSource->lightSourceType) {
        case LightSourceType::Distant:
        case LightSourceType::Point:
            return color;

        case LightSourceType::Spot: {
            // Could do outside the shader.
            float3 directionVector = normalize(lightSource->pointsAt - lightSource->position);

            float3 lightColor;
            float cosineOfAngle = dot(lightVector, directionVector);
            if (cosineOfAngle > lightSource->coneCutOffLimit)
                lightColor = { };
            else
                lightColor = color * pow(-cosineOfAngle, lightSource->specularExponent);

            if (cosineOfAngle > lightSource->coneFullLight)
                lightColor *= (lightSource->coneCutOffLimit - cosineOfAngle) / (lightSource->coneCutOffLimit - lightSource->coneFullLight);
            return lightColor;
        }
        }

        return 0;
    }

    float3 computeLightVector(sampler src,
        constant LightingConstants* constants,
        constant LightSourceConstants* lightSource,
        float2 srcPosition, float2 destPosition)
    {
        switch (lightSource->lightSourceType) {
        case LightSourceType::Distant: {
            // FIXME: we could compute these outside of the shader.
            float3 lightVector = {
                cos(lightSource->azimuthRadians) * cos(lightSource->elevationRadians),
                sin(lightSource->azimuthRadians) * cos(lightSource->elevationRadians),
                sin(lightSource->elevationRadians),
            };
            return normalize(lightVector); // Should already be unit length.
        }

        case LightSourceType::Point:
        case LightSourceType::Spot: {
            float4 pixel = src.sample(srcPosition);
            float z = constants->surfaceScale * pixel.a;
            // Flipped texture coords.
            float2 position = destPosition;
            position.y = constants->extentBottom - position.y;

            float3 lightVector;
            lightVector.xy = lightSource->position.xy - position;
            lightVector.z = lightSource->position.z - z;
            return normalize(lightVector);
        }
        }
        return 0;
    }

    [[stitchable]] float4 specular_lighting(sampler src,
        constant LightingConstants* constants,
        constant LightSourceConstants* lightSource,
        destination dest)
    {
        const float2 halfPixel = 0.5f;
        float2 destPosition = dest.coord();
        float2 srcPosition = src.transform(destPosition);

        // z = width, w = height.
        const float2 maxSampleOffset = { src.extent().x + src.extent().z - 1, src.extent().y + src.extent().w - 1 };

        // FIXME: The edge detection is not working.
        const int isLeftEdge = static_cast<int>(srcPosition.x == src.extent().x);
        const int isRightEdge = static_cast<int>(srcPosition.x == maxSampleOffset.x);

        // Flipped coordinates.
        const int isBottomEdge = static_cast<int>(srcPosition.y == src.extent().y);
        const int isTopEdge = static_cast<int>(srcPosition.y == maxSampleOffset.y);

        const int rowIndex = 1 - isTopEdge + isBottomEdge;
        const int colIndex = 1 - isLeftEdge + isRightEdge;

        // FIXME: This edge detection doesn't work. rowIndex and colIndex are always 1.

        constant Normal& normalForPixel = normals[1][1];
        const float2 factor = normalForPixel.factor;

        float2 alphaXYSum = 0;
        for (int col = 0; col < 3; ++col) {
            for (int row = 0; row < 3; ++row) {
                // Need to flip when picking out the constants.
                int flippedRow = 2 - row;
                float2 k = normalForPixel.data[flippedRow][col];
                if (isZero(k))
                    continue;

                const float2 sampleOffset = { constants->kernelUnitLength.x * (col - 1), constants->kernelUnitLength.y * (row - 1) };
                const float2 sampleLocation = srcPosition + sampleOffset;

                float4 nearbyPixel = src.sample(sampleLocation + halfPixel);
                alphaXYSum += nearbyPixel.a * k;
            }
        }

        float3 lightVector = computeLightVector(src, constants, lightSource, srcPosition, destPosition);
        float lightFactor = computeLightFactor(constants, lightVector, normalForPixel.factor, alphaXYSum);
        float3 lightColor = computeLightColor(lightSource, constants->lightingColor.rgb, lightVector);

        lightColor *= lightFactor;

        float4 resultPixel = { };
        resultPixel.rgb = clamp(lightColor, 0, 1);

        if (constants->lightingType == LightingType::Diffuse)
            resultPixel.a = 1;
        else
            resultPixel.a = max(max(resultPixel.r, resultPixel.g), resultPixel.b);

        return resultPixel;
    }

    } // namespace coreimage
    } // extern "C"
    """# + "\n        "

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
