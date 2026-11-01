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

import CoreImage
import WebCore_Internal.FETurbulenceParameters
import WebCore_Internal.FilterSwiftBridge
import WebCore_Internal.FloatPoint
import WebCore_Internal.FloatRect
import WebCore_Internal.FloatSize
import WebCore_Internal.IntRect
import WebCore_Internal.IntSize

// FETurbulenceCoreImageApplier::apply().
func feTurbulenceApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FETurbulenceParameters,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let kernel = turbulenceKernel else {
        return false
    }

    let tileSize = WebCore.roundedIntSize(result.primitiveSubregion.size())

    var baseFrequencyX = parameters.baseFrequencyX
    var baseFrequencyY = parameters.baseFrequencyY
    let stitchTiles = parameters.stitchTiles
    let stitchData = turbulenceStitchData(
        tileSize: tileSize,
        baseFrequencyX: &baseFrequencyX,
        baseFrequencyY: &baseFrequencyY,
        stitchTiles: stitchTiles
    )
    let paintingData = TurbulencePaintingData(seed: parameters.seed)

    let absoluteImageRect = result.absoluteImageRect
    let origin = WebCore.FloatPoint(absoluteImageRect.location())
    let scale = context.filterScale
    var extent = context.flippedRectRelativeToAbsoluteEnclosingFilterRegion(absoluteImageRect)
    // Work around a bug where the extent of the kernel is too large after compositing with other CIImages (TODO: file the radar).
    extent.shiftMaxXEdgeBy(1)

    let gradients = gradientBuffers(paintingData)
    let arguments: [Any] = [
        constantsBuffer(
            type: parameters.type,
            stitchTiles: stitchTiles,
            numOctaves: min(parameters.numOctaves, turbulenceMaximumOctaves),
            extentBottom: extent.maxY(),
            origin: origin,
            scale: scale,
            baseFrequencyX: baseFrequencyX,
            baseFrequencyY: baseFrequencyY,
            stitchData: stitchData
        ),
        latticeSelectorBuffer(paintingData),
        gradients.red,
        gradients.green,
        gradients.blue,
        gradients.alpha,
    ]

    guard let outputImage = kernel.apply(extent: cgRect(extent), roiCallback: { _, destRect in destRect }, arguments: arguments) else {
        return false
    }

    // Part 2 of the workaround; this extent modification is necessary to avoid this cropping being a no-op.
    extent.shiftMaxXEdgeBy(-1)
    result.setCIImage(outputImage.cropped(to: cgRect(extent)))
    return true
}

// FloatRect's CGRect conversion.
private func cgRect(_ rect: WebCore.FloatRect) -> CGRect {
    CGRect(x: CGFloat(rect.x()), y: CGFloat(rect.y()), width: CGFloat(rect.width()), height: CGFloat(rect.height()))
}

// The kernel's arguments are the bytes of the C++ structs below, in the host's byte order as C++ copied them.

// struct TurbulenceConstants { uint8_t type; uint8_t stitchTiles; int numOctaves; float extentBottom; float2 origin;
// float2 scale; float2 baseFrequency; int2 stitchSize; int2 stitchWrap; }
private func constantsBuffer(
    type: WebCore.TurbulenceType,
    stitchTiles: Bool,
    numOctaves: Int32,
    extentBottom: Float,
    origin: WebCore.FloatPoint,
    scale: WebCore.FloatSize,
    baseFrequencyX: Float,
    baseFrequencyY: Float,
    stitchData: TurbulenceStitchData
) -> Data {
    var buffer = ContiguousArray<UInt8>(repeating: 0, count: 56)
    do {
        var span = buffer.mutableSpan
        var bytes = span.mutableBytes
        bytes.storeBytes(of: type == .FractalNoise ? 0 : 1, toByteOffset: 0, as: UInt8.self)
        bytes.storeBytes(of: stitchTiles ? 1 : 0, toByteOffset: 1, as: UInt8.self)
        bytes.storeBytes(of: numOctaves, toByteOffset: 4, as: Int32.self)
        bytes.storeBytes(of: extentBottom, toByteOffset: 8, as: Float.self)
        bytes.storeBytes(of: origin.x(), toByteOffset: 16, as: Float.self)
        bytes.storeBytes(of: origin.y(), toByteOffset: 20, as: Float.self)
        bytes.storeBytes(of: scale.width(), toByteOffset: 24, as: Float.self)
        bytes.storeBytes(of: scale.height(), toByteOffset: 28, as: Float.self)
        bytes.storeBytes(of: baseFrequencyX, toByteOffset: 32, as: Float.self)
        bytes.storeBytes(of: baseFrequencyY, toByteOffset: 36, as: Float.self)
        bytes.storeBytes(of: stitchData.width, toByteOffset: 40, as: Int32.self)
        bytes.storeBytes(of: stitchData.height, toByteOffset: 44, as: Int32.self)
        bytes.storeBytes(of: stitchData.wrapX, toByteOffset: 48, as: Int32.self)
        bytes.storeBytes(of: stitchData.wrapY, toByteOffset: 52, as: Int32.self)
    }
    return Data(buffer)
}

// struct LatticeSelector { int data[TURBULENCE_LATTICE_SIZE]; }
private func latticeSelectorBuffer(_ paintingData: TurbulencePaintingData) -> Data {
    let latticeSelector = paintingData.latticeSelector.span
    var buffer = ContiguousArray<UInt8>(repeating: 0, count: 4 * latticeSelector.count)
    do {
        var span = buffer.mutableSpan
        var bytes = span.mutableBytes
        for i in latticeSelector.indices {
            bytes.storeBytes(of: latticeSelector[i], toByteOffset: 4 * i, as: Int32.self)
        }
    }
    return Data(buffer)
}

// struct GradientChannel { float2 data[TURBULENCE_LATTICE_SIZE]; } for red, green, blue and alpha: each channel's
// gradients of the 256 lattice points, repeated, as in the C++ tables. The last two entries, which the kernel never
// reads, are zero.
private func gradientBuffers(_ paintingData: TurbulencePaintingData) -> (red: Data, green: Data, blue: Data, alpha: Data) {
    let gradients = paintingData.gradients.span
    let blockSize = gradients.count / 2
    let byteCount = 8 * paintingData.latticeSelector.count
    var red = ContiguousArray<UInt8>(repeating: 0, count: byteCount)
    var green = ContiguousArray<UInt8>(repeating: 0, count: byteCount)
    var blue = ContiguousArray<UInt8>(repeating: 0, count: byteCount)
    var alpha = ContiguousArray<UInt8>(repeating: 0, count: byteCount)
    do {
        var redSpan = red.mutableSpan
        var greenSpan = green.mutableSpan
        var blueSpan = blue.mutableSpan
        var alphaSpan = alpha.mutableSpan
        var redBytes = redSpan.mutableBytes
        var greenBytes = greenSpan.mutableBytes
        var blueBytes = blueSpan.mutableBytes
        var alphaBytes = alphaSpan.mutableBytes
        for i in 0..<2 * blockSize {
            let x = gradients[2 * (i % blockSize)]
            let y = gradients[2 * (i % blockSize) + 1]
            redBytes.storeBytes(of: SIMD2(x.x, y.x), toByteOffset: 8 * i, as: SIMD2<Float>.self)
            greenBytes.storeBytes(of: SIMD2(x.y, y.y), toByteOffset: 8 * i, as: SIMD2<Float>.self)
            blueBytes.storeBytes(of: SIMD2(x.z, y.z), toByteOffset: 8 * i, as: SIMD2<Float>.self)
            alphaBytes.storeBytes(of: SIMD2(x.w, y.w), toByteOffset: 8 * i, as: SIMD2<Float>.self)
        }
    }
    return (Data(red), Data(green), Data(blue), Data(alpha))
}

// Compiled on first use; nil if compilation failed.
private let turbulenceKernel: CIKernel? = {
    guard let kernels = try? CIKernel.kernels(withMetalString: turbulenceKernelSource) else {
        return nil
    }
    return kernels.first
}()

private let turbulenceKernelSource = #"""
     /* NOLINT */
    #define TURBULENCE_BLOCK_SIZE 256
    #define TURBULENCE_LATTICE_SIZE (2 * TURBULENCE_BLOCK_SIZE + 2)
    #define TURBULENCE_GRADIENT_COLUMNS TURBULENCE_BLOCK_SIZE

    #define PERLIN_NOISE 4096
    #define BLOCK_MASK (TURBULENCE_BLOCK_SIZE - 1)

    extern "C" {
    namespace coreimage {

    enum NoiseType : uint8_t {
        FractalNoise,
        Turbulence
    };

    struct TurbulenceStitchData {
        vector_int2 size; // How much to subtract to wrap for stitching.
        vector_int2 wrap; // Minimum value to wrap.
    };

    struct TurbulenceConstants {
        uint8_t type;
        uint8_t stitchTiles;
        int numOctaves;
        float extentBottom;
        float2 origin;
        float2 scale;
        float2 baseFrequency;
        TurbulenceStitchData stitchData;
    };

    struct LatticeSelector {
        int data[TURBULENCE_LATTICE_SIZE];
    };

    struct GradientChannel {
        float2 data[TURBULENCE_LATTICE_SIZE];
    };

    static inline float2 sCurve(float2 t)
    {
        return t * t * (3.0 - 2.0 * t);
    }

    static inline float lerp(float t, float a, float b)
    {
        return a + t * (b - a);
    }

    float noiseForChannel(constant GradientChannel& gradient, int4 indices, float2 fraction, float2 s)
    {
        // q = fGradient[nColorChannel][b00];
        // u = rx0 * q[0] + ry0 * q[1];
        float2 q1 = gradient.data[indices[0] % TURBULENCE_BLOCK_SIZE];
        float u1 = fraction.x * q1[0] + fraction.y * q1[1];

        // q = fGradient[nColorChannel][b10];
        // v = rx1 * q[0] + ry0 * q[1];
        float2 q2 = gradient.data[indices[1] % TURBULENCE_BLOCK_SIZE];
        float v1 = (fraction.x - 1) * q2[0] + fraction.y * q2[1];

        // a = lerp(sx, u, v);
        float a = lerp(s.x, u1, v1);

        // q = fGradient[nColorChannel][b01];
        // u = rx0 * q[0] + ry1 * q[1];
        float2 q3 = gradient.data[indices[2] % TURBULENCE_BLOCK_SIZE];
        float u2 = fraction.x * q3[0] + (fraction.y - 1) * q3[1];

        // q = fGradient[nColorChannel][b11];
        // v = rx1 * q[0] + ry1 * q[1];
        float2 q4 = gradient.data[indices[3] % TURBULENCE_BLOCK_SIZE];
        float v2 = (fraction.x - 1) * q4[0] + (fraction.y - 1) * q4[1];

        // b = lerp(sx, u, v);
        float b = lerp(s.x, u2, v2);

        return lerp(s.y, a, b);
    }

    float4 noise2D(constant TurbulenceConstants& constants,
        constant LatticeSelector& latticeSelector,
        constant GradientChannel& redGradient,
        constant GradientChannel& greenGradient,
        constant GradientChannel& blueGradient,
        constant GradientChannel& alphaGradient,
        float2 noiseVector, TurbulenceStitchData stitchData)
    {
        // t = vec[0] + PerlinN;
        float2 position = noiseVector + PERLIN_NOISE;
        // bx0 = (int)t;
        int2 index = (int2)floor(position);
        // bx1 = bx0 + 1;
        int2 nextIndex = index + 1;
        // rx0 = t - (int)t;
        float2 fraction = position - (float2)index;

        if (constants.stitchTiles) {
            if (index.x >= stitchData.wrap.x)
                index.x -= stitchData.size.x;

            if (nextIndex.x >= stitchData.wrap.x)
                nextIndex.x -= stitchData.size.x;

            if (index.y >= stitchData.wrap.y)
                index.y -= stitchData.size.y;

            if (nextIndex.y >= stitchData.wrap.y)
                nextIndex.y -= stitchData.size.y;
        }

        // bx0 &= BM;
        // bx1 &= BM;
        // by0 &= BM;
        // by1 &= BM;
        index &= BLOCK_MASK;
        nextIndex &= BLOCK_MASK;

        // i = uLatticeSelector[bx0];
        // j = uLatticeSelector[bx1];
        int latticeIndex = latticeSelector.data[index.x];
        int nextLatticeIndex = latticeSelector.data[nextIndex.x];

        // sx = double(s_curve(rx0));
        // sy = double(s_curve(ry0));
        float2 s = sCurve(fraction);

        int4 indices = {
            latticeSelector.data[latticeIndex      + index.y],        // b00 = uLatticeSelector[i + by0]
            latticeSelector.data[nextLatticeIndex  + index.y],        // b10 = uLatticeSelector[j + by0]
            latticeSelector.data[latticeIndex      + nextIndex.y],    // b01 = uLatticeSelector[i + by1]
            latticeSelector.data[nextLatticeIndex  + nextIndex.y],    // b11 = uLatticeSelector[j + by1]
        };

        return {
            noiseForChannel(redGradient,   indices, fraction, s),
            noiseForChannel(greenGradient, indices, fraction, s),
            noiseForChannel(blueGradient,  indices, fraction, s),
            noiseForChannel(alphaGradient, indices, fraction, s),
        };
    }

    [[stitchable]] float4 kernel_turbulence(
        constant TurbulenceConstants* constants,
        constant LatticeSelector* latticeSelector,
        constant GradientChannel* redGradient,
        constant GradientChannel* greenGradient,
        constant GradientChannel* blueGradient,
        constant GradientChannel* alphaGradient,
        destination dest)
    {
        // Texture coordinates are y-flipped. 
        float2 coordinate = dest.coord();
        coordinate.y = constants->extentBottom - coordinate.y;
        coordinate += constants->origin;
        coordinate /= constants->scale;
        coordinate.x += 0.5;
        coordinate.y += 0.5;

        auto stitchData = constants->stitchData;

        float ratio = 1;
        float2 noiseVector = coordinate * constants->baseFrequency;

        float4 resultPixel = { };

        for (int octave = 0; octave < constants->numOctaves; ++octave) {
            if (constants->type == NoiseType::FractalNoise)
                resultPixel += noise2D(*constants, *latticeSelector, *redGradient, *greenGradient, *blueGradient, *alphaGradient, noiseVector, stitchData) / ratio;
            else
                resultPixel += fabs(noise2D(*constants, *latticeSelector, *redGradient, *greenGradient, *blueGradient, *alphaGradient, noiseVector, stitchData)) / ratio;

            if (octave == constants->numOctaves - 1)
                break;

            noiseVector *= 2;
            ratio *= 2;

            if (constants->stitchTiles) {
                stitchData.size *= 2;
                stitchData.wrap = 2 * stitchData.wrap - PERLIN_NOISE;
            }
        }

        if (constants->type == NoiseType::FractalNoise)
            resultPixel = resultPixel * 0.5 + 0.5;

        resultPixel = clamp(resultPixel, 0, 1);
        return premultiply(resultPixel);
    }

    } // extern "C"
    } // namespace coreimage
            
    """#

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
