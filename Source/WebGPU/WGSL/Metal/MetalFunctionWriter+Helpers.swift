// Copyright (C) 2023-2026 Apple Inc. All rights reserved.
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

extension FunctionDefinitionWriter {
    mutating func emitNecessaryHelpers() {
        helperGenerator.output.append("template<typename T>\n")
        helperGenerator.output.append("struct __UnpackedTypeImpl;\n\n")
        helperGenerator.output.append("template<typename T>\n")
        helperGenerator.output.append("struct __PackedTypeImpl;\n\n")
        helperGenerator.output.append("template<typename T>\n")
        helperGenerator.output.append("using __UnpackedType = typename __UnpackedTypeImpl<T>::Type;\n\n")
        helperGenerator.output.append("template<typename T>\n")
        helperGenerator.output.append("using __PackedType = typename __PackedTypeImpl<T>::Type;\n\n")

        if shaderModule.uses.contains(.packedVec3) {
            helperGenerator.output.append(indent, "template<typename T>\n")
            helperGenerator.output.append(indent, "struct PackedVec3 {\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "union { T x; T r; };\n")
                helperGenerator.output.append(indent, "union { T y; T g; };\n")
                helperGenerator.output.append(indent, "union { T z; T b; };\n")
                helperGenerator.output.append(indent, .packedVec3Padding)
                helperGenerator.output.append(indent, "\n")
                helperGenerator.output.append(indent, "PackedVec3() { }\n")
                helperGenerator.output.append(indent, "\n")
                helperGenerator.output.append(indent, "PackedVec3(packed_vec<T, 3> v) : x(v.x), y(v.y), z(v.z) { }\n")
                helperGenerator.output.append(indent, "\n")
                helperGenerator.output.append(indent, "operator vec<T, 3>() const thread { return vec<T, 3>(x, y, z); }\n")
                helperGenerator.output.append(indent, "operator vec<T, 3>() const device { return vec<T, 3>(x, y, z); }\n")
                helperGenerator.output.append(indent, "operator vec<T, 3>() const constant { return vec<T, 3>(x, y, z); }\n")
                helperGenerator.output.append(indent, "operator vec<T, 3>() const threadgroup { return vec<T, 3>(x, y, z); }\n")
                helperGenerator.output.append(indent, "operator packed_vec<T, 3>() const thread { return packed_vec<T, 3>(x, y, z); }\n")
                helperGenerator.output.append(indent, "operator packed_vec<T, 3>() const device { return packed_vec<T, 3>(x, y, z); }\n")
                helperGenerator.output.append(indent, "operator packed_vec<T, 3>() const constant { return packed_vec<T, 3>(x, y, z); }\n")
                helperGenerator.output.append(
                    indent,
                    "operator packed_vec<T, 3>() const threadgroup { return packed_vec<T, 3>(x, y, z); }\n"
                )
                helperGenerator.output.append(indent, "\n")
                helperGenerator.output.append(indent, .packedVec3Subscript)
                helperGenerator.output.append(indent, .packedVec3DeviceSubscript)
                helperGenerator.output.append(indent, .packedVec3DeviceReferenceSubscript)
                helperGenerator.output.append(indent, .packedVec3ConstantReferenceSubscript)
                helperGenerator.output.append(indent, .packedVec3ThreadReferenceSubscript)
                helperGenerator.output.append(indent, .packedVec3ThreadgroupReferenceSubscript)
            }
            helperGenerator.output.append(indent, "};\n\n")

            helperGenerator.output.append(indent, "template<typename T, int C>\n")
            helperGenerator.output.append(indent, "struct PackedMatrix {\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, .packedMatrixColumns)
            }
            helperGenerator.output.append(indent, "};\n\n")
        }

        if shaderModule.uses.contains(.externalTextures) {
            shaderModule.uses.remove(.externalTextures)
            helperGenerator.output.append("struct texture_external {\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "texture2d<float> FirstPlane;\n")
                helperGenerator.output.append(indent, "texture2d<float> SecondPlane;\n")
                helperGenerator.output.append(indent, "float3x2 UVRemapMatrix;\n")
                helperGenerator.output.append(indent, "float4x3 ColorSpaceConversionMatrix;\n")
                helperGenerator.output.append(indent, "float3x3 PrimariesConversionMatrix;\n")
                helperGenerator.output.append(indent, "uint2 VisibleSize;\n")
                // The size the source presents the frame at, which is what textureDimensions() is owed and
                // is not the size of the plane the frame was decoded into: a VideoFrame carries a display
                // size of its own, and a visible rect crops what the planes hold. A source which could not
                // say leaves this zero, and then the luma plane's size is the best answer available.
                helperGenerator.output.append(
                    indent,
                    "uint get_width(uint lod = 0) const { return VisibleSize.x ? VisibleSize.x : FirstPlane.get_width(lod); }\n"
                )
                helperGenerator.output.append(
                    indent,
                    "uint get_height(uint lod = 0) const { return VisibleSize.y ? VisibleSize.y : FirstPlane.get_height(lod); }\n"
                )
                // The color the shader is owed, from what the frame's two planes hold: rgb has come out
                // of the YCbCr matrix and still carries the frame's own primaries, alpha is the frame's,
                // and premultiplied says whether rgb already has that alpha applied. Reaching the color
                // space the import named is a transfer function round trip, so it can only run on a
                // straight color and the premultiply is undone around it. An all-zero matrix, which no
                // real conversion can be, means the frame's primaries already are that color space, and
                // has to skip the round trip rather than run it to arrive back where it started.
                helperGenerator.output.append(
                    indent,
                    "float4 to_destination_color_space(float3 rgb, float alpha, float premultiplied) const\n"
                )
                helperGenerator.output.append(indent, "{\n")
                helperGenerator.output.append(indent, .textureExternalPrimariesConversionCheck)
                helperGenerator.output.append(indent, "        return float4(rgb * mix(alpha, 1.0f, premultiplied), alpha);\n")
                helperGenerator.output.append(
                    indent,
                    "    float3 const straight = (premultiplied != 0.0f && alpha > 0.0f) ? rgb / alpha : rgb;\n"
                )
                helperGenerator.output.append(indent, "    float3 const magnitude = abs(straight);\n")
                helperGenerator.output.append(
                    indent,
                    "    float3 const linearLight = sign(straight) * select(pow((magnitude + 0.055f) / 1.055f, 2.4f), magnitude / 12.92f, magnitude <= 0.04045f);\n"
                )
                helperGenerator.output.append(indent, "    float3 const converted = PrimariesConversionMatrix * linearLight;\n")
                helperGenerator.output.append(indent, "    float3 const convertedMagnitude = abs(converted);\n")
                helperGenerator.output.append(
                    indent,
                    "    float3 const encoded = sign(converted) * select(1.055f * pow(convertedMagnitude, 1.0f / 2.4f) - 0.055f, convertedMagnitude * 12.92f, convertedMagnitude <= 0.0031308f);\n"
                )
                helperGenerator.output.append(indent, "    return float4(encoded * alpha, alpha);\n")
                helperGenerator.output.append(indent, "}\n")
            }
            helperGenerator.output.append("};\n\n")
        }

        if shaderModule.uses.contains(.packVector) {
            shaderModule.uses.remove(.packVector)
            helperGenerator.output.append(indent, "template<typename T>\n")
            helperGenerator.output.append(
                indent,
                "static __attribute__((always_inline)) packed_vec<T, 3> __pack(vec<T, 3> unpacked) { return unpacked; }\n\n"
            )

            if shaderModule.uses.contains(.packedVec3) {
                helperGenerator.output.append(indent, "template<typename T, int C>\n")
                helperGenerator.output.append(
                    indent,
                    "static __attribute__((always_inline)) PackedMatrix<T, C> __pack(matrix<T, C, 3> unpacked)\n"
                )
                helperGenerator.output.append(indent, "{\n")
                do {
                    indent.increment()
                    defer { indent.decrement() }
                    helperGenerator.output.append(indent, "PackedMatrix<T, C> packed;\n")
                    helperGenerator.output.append(indent, "for (int i = 0; i < C; i++)\n")
                    do {
                        indent.increment()
                        defer { indent.decrement() }
                        helperGenerator.output.append(indent, .packMatrixColumn)
                    }
                    helperGenerator.output.append(indent, "return packed;\n")
                }
                helperGenerator.output.append(indent, "}\n\n")
            }
        }

        if shaderModule.uses.contains(.unpackVector) {
            shaderModule.uses.remove(.unpackVector)
            helperGenerator.output.append(indent, "template<typename T>\n")
            helperGenerator.output.append(
                indent,
                "static __attribute__((always_inline)) vec<T, 3> __unpack(packed_vec<T, 3> packed) { return packed; }\n\n"
            )

            if shaderModule.uses.contains(.packedVec3) {
                helperGenerator.output.append(indent, "template<typename T>\n")
                helperGenerator.output.append(indent, "static vec<T, 3> __unpack(PackedVec3<T> packed) { return packed; }\n\n")

                helperGenerator.output.append(indent, "template<typename T, int C>\n")
                helperGenerator.output.append(
                    indent,
                    "static __attribute__((always_inline)) matrix<T, C, 3> __unpack(PackedMatrix<T, C> packed)\n"
                )
                helperGenerator.output.append(indent, "{\n")
                do {
                    indent.increment()
                    defer { indent.decrement() }
                    helperGenerator.output.append(indent, "matrix<T, C, 3> unpacked;\n")
                    helperGenerator.output.append(indent, "for (int i = 0; i < C; i++)\n")
                    do {
                        indent.increment()
                        defer { indent.decrement() }
                        helperGenerator.output.append(indent, .unpackMatrixColumn)
                    }
                    helperGenerator.output.append(indent, "return unpacked;\n")
                }
                helperGenerator.output.append(indent, "}\n\n")
            }
        }

        if shaderModule.uses.contains(.packArray) {
            shaderModule.uses.remove(.packArray)

            helperGenerator.output.append(indent, "template<typename T, size_t N>\n")
            helperGenerator.output.append(indent, "struct __PackedTypeImpl<array<T, N>> {\n")
            helperGenerator.output.append(indent, "using Type = array<__PackedType<T>, N>;\n")
            helperGenerator.output.append(indent, "};\n\n")

            if shaderModule.uses.contains(.packedVec3) {
                helperGenerator.output.append(indent, "template<typename T, size_t N>\n")
                helperGenerator.output.append(indent, "struct __PackedTypeImpl<array<vec<T, 3>, N>> {")
                helperGenerator.output.append(indent, "using Type = array<PackedVec3<T>, N>;")
                helperGenerator.output.append(indent, "};\n\n")

                helperGenerator.output.append(indent, "template<typename T, int C>\n")
                helperGenerator.output.append(indent, "struct __PackedTypeImpl<matrix<T, C, 3>> {")
                helperGenerator.output.append(indent, "using Type = PackedMatrix<T, C>;")
                helperGenerator.output.append(indent, "};\n\n")

                helperGenerator.output.append(indent, "template<typename T, size_t N>\n")
                helperGenerator.output.append(
                    indent,
                    "static __attribute__((always_inline)) array<PackedVec3<T>, N> __pack(array<vec<T, 3>, N> unpacked)\n"
                )
                helperGenerator.output.append(indent, "{\n")
                do {
                    indent.increment()
                    defer { indent.decrement() }
                    helperGenerator.output.append(indent, "array<PackedVec3<T>, N> packed;\n")
                    helperGenerator.output.append(indent, "for (size_t i = 0; i < N; ++i)\n")
                    do {
                        indent.increment()
                        defer { indent.decrement() }
                        helperGenerator.output.append(indent, .packVec3ArrayElement)
                    }
                    helperGenerator.output.append(indent, "return packed;\n")
                }
                helperGenerator.output.append(indent, "}\n\n")
            }

            helperGenerator.output.append(indent, "template<typename T, size_t N>\n")
            helperGenerator.output.append(
                indent,
                "static __attribute__((always_inline)) array<__PackedType<T>, N> __pack(array<T, N> unpacked)\n"
            )
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "array<__PackedType<T>, N> packed;\n")
                helperGenerator.output.append(indent, "for (size_t i = 0; i < N; ++i)\n")
                do {
                    indent.increment()
                    defer { indent.decrement() }
                    helperGenerator.output.append(indent, .packArrayElement)
                }
                helperGenerator.output.append(indent, "return packed;\n")
            }
            helperGenerator.output.append(indent, "}\n\n")
        }

        if shaderModule.uses.contains(.unpackArray) {
            shaderModule.uses.remove(.unpackArray)

            helperGenerator.output.append(indent, "template<typename T, size_t N>\n")
            helperGenerator.output.append(indent, "struct __UnpackedTypeImpl<array<T, N>> {\n")
            helperGenerator.output.append(indent, "using Type = array<__UnpackedType<T>, N>;\n")
            helperGenerator.output.append(indent, "};\n\n")

            if shaderModule.uses.contains(.packedVec3) {
                helperGenerator.output.append(indent, "template<typename T, size_t N>\n")
                helperGenerator.output.append(indent, "struct __UnpackedTypeImpl<array<PackedVec3<T>, N>> {")
                helperGenerator.output.append(indent, "using Type = array<vec<T, 3>, N>;")
                helperGenerator.output.append(indent, "};\n\n")

                helperGenerator.output.append(indent, "template<typename T, int C>\n")
                helperGenerator.output.append(indent, "struct __UnpackedTypeImpl<PackedMatrix<T, C>> {")
                helperGenerator.output.append(indent, "using Type = matrix<T, C, 3>;")
                helperGenerator.output.append(indent, "};\n\n")

                helperGenerator.output.append(indent, "template<typename T, size_t N>\n")
                helperGenerator.output.append(
                    indent,
                    "static __attribute__((always_inline)) array<vec<T, 3>, N> __unpack(array<PackedVec3<T>, N> packed)\n"
                )
                helperGenerator.output.append(indent, "{\n")
                do {
                    indent.increment()
                    defer { indent.decrement() }
                    helperGenerator.output.append(indent, "array<vec<T, 3>, N> unpacked;\n")
                    helperGenerator.output.append(indent, "for (size_t i = 0; i < N; ++i)\n")
                    do {
                        indent.increment()
                        defer { indent.decrement() }
                        helperGenerator.output.append(indent, .unpackVec3ArrayElement)
                    }
                    helperGenerator.output.append(indent, "return unpacked;\n")
                }
                helperGenerator.output.append(indent, "}\n\n")
            }

            helperGenerator.output.append(indent, "template<typename T, size_t N>\n")
            helperGenerator.output.append(
                indent,
                "static __attribute__((always_inline)) array<__UnpackedType<T>, N> __unpack(array<T, N> packed)\n"
            )
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "array<__UnpackedType<T>, N> unpacked;\n")
                helperGenerator.output.append(indent, "for (size_t i = 0; i < N; ++i)\n")
                do {
                    indent.increment()
                    defer { indent.decrement() }
                    helperGenerator.output.append(indent, .unpackArrayElement)
                }
                helperGenerator.output.append(indent, "return unpacked;\n")
            }
            helperGenerator.output.append(indent, "}\n\n")
        }

        if shaderModule.uses.contains(.workgroupUniformLoad) {
            helperGenerator.output.append(indent, "template<typename T>\n")
            helperGenerator.output.append(indent)
            if shaderValidationEnabled() {
                helperGenerator.output.append(MTLWorkaround.optnoneAttribute)
            }
            helperGenerator.output.append("static T __workgroup_uniform_load(threadgroup T* const ptr)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "threadgroup_barrier(mem_flags::mem_threadgroup);\n")
                helperGenerator.output.append(indent, "auto result = *ptr;\n")
                helperGenerator.output.append(indent, "threadgroup_barrier(mem_flags::mem_threadgroup);\n")
                helperGenerator.output.append(indent, "return result;\n")
            }
            helperGenerator.output.append(indent, "}\n\n")
        }

        if shaderModule.uses.contains(.workgroupUniformLoadAtomic) {
            helperGenerator.output.append(indent, "template<typename T>\n")
            helperGenerator.output.append(indent)
            if shaderValidationEnabled() {
                helperGenerator.output.append(MTLWorkaround.optnoneAttribute)
            }
            helperGenerator.output.append("static T __workgroup_uniform_load(threadgroup atomic<T>* const ptr)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "threadgroup_barrier(mem_flags::mem_threadgroup);\n")
                helperGenerator.output.append(indent, "auto result = atomic_load_explicit(ptr, memory_order_relaxed);\n")
                helperGenerator.output.append(indent, "threadgroup_barrier(mem_flags::mem_threadgroup);\n")
                helperGenerator.output.append(indent, "return result;\n")
            }
            helperGenerator.output.append(indent, "}\n\n")
        }

        if shaderModule.uses.contains(.division) {
            helperGenerator.output.append(indent, "template<typename T, typename U, typename V = conditional_t<is_scalar_v<U>, T, U>>\n")
            helperGenerator.output.append(indent, "static V __wgslDiv(T lhs, U rhs)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "auto predicate = V(rhs) == V(0);\n")
                helperGenerator.output.append(indent, "if constexpr (is_signed_v<U>)\n")
                do {
                    indent.increment()
                    defer { indent.decrement() }
                    helperGenerator.output.append(
                        indent,
                        "predicate = predicate || (V(lhs) == V(numeric_limits<T>::lowest()) && V(rhs) == V(-1));\n"
                    )
                }
                helperGenerator.output.append(indent, "return lhs / select(V(rhs), V(1), predicate);\n")
            }
            helperGenerator.output.append(indent, "}\n\n")
        }

        if shaderModule.uses.contains(.modulo) {
            helperGenerator.output.append(indent, "template<typename T, typename U, typename V = conditional_t<is_scalar_v<U>, T, U>>\n")
            helperGenerator.output.append(indent, "static V __wgslMod(T lhs, U rhs)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "auto predicate = V(rhs) == V(0);\n")
                helperGenerator.output.append(indent, "if constexpr (is_signed_v<U>)\n")
                do {
                    indent.increment()
                    defer { indent.decrement() }
                    helperGenerator.output.append(
                        indent,
                        "predicate = predicate || (V(lhs) == V(numeric_limits<T>::lowest()) && V(rhs) == V(-1));\n"
                    )
                }
                helperGenerator.output.append(indent, "return select(lhs % V(rhs), V(0), predicate);\n")
            }
            helperGenerator.output.append(indent, "}\n\n")
        }

        if shaderModule.uses.contains(.frexp) {
            helperGenerator.output.append(indent, "template<typename T, typename U>\n")
            helperGenerator.output.append(indent, "struct __frexp_result {\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "T fract;\n")
                helperGenerator.output.append(indent, "U exp;\n")
            }
            helperGenerator.output.append(indent, "};\n\n")
            helperGenerator.output.append(
                indent,
                "template<typename T, typename U = conditional_t<is_vector_v<T>, vec<int, vec_elements<T>::value ?: 2>, int>>\n"
            )
            helperGenerator.output.append(indent, "static __frexp_result<T, U> __wgslFrexp(T value)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "__frexp_result<T, U> result;\n")
                helperGenerator.output.append(indent, "result.fract = frexp(value, result.exp);\n")
                helperGenerator.output.append(indent, "return result;\n")
            }
            helperGenerator.output.append(indent, "}\n\n")
        }

        if shaderModule.uses.contains(.modf) {
            helperGenerator.output.append(indent, "template<typename T, typename U>\n")
            helperGenerator.output.append(indent, "struct __modf_result {\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "T fract;\n")
                helperGenerator.output.append(indent, "U whole;\n")
            }
            helperGenerator.output.append(indent, "};\n\n")
            helperGenerator.output.append(indent, "template<typename T>\n")
            helperGenerator.output.append(indent, "static __modf_result<T, T> __wgslModf(T value)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "__modf_result<T, T> result;\n")
                helperGenerator.output.append(indent, "result.fract = modf(value, result.whole);\n")
                helperGenerator.output.append(indent, "return result;\n")
            }
            helperGenerator.output.append(indent, "}\n\n")
        }

        if shaderModule.uses.contains(.atomicCompareExchange) {
            helperGenerator.output.append(indent, "template<typename T, typename U = bool>\n")
            helperGenerator.output.append(indent, "struct __atomic_compare_exchange_result {\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "T old_value;\n")
                helperGenerator.output.append(indent, "U exchanged;\n")
            }
            helperGenerator.output.append(indent, "};\n\n")
            helperGenerator.output.append(
                indent,
                "template<typename T, typename S, typename V> __atomic_compare_exchange_result<S> __wgslAtomicCompareExchangeWeak(T atomic1, S compare, V value) {\n"
            )
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "auto innerCompare = compare;\n")
                helperGenerator.output.append(
                    indent,
                    "bool exchanged = atomic_compare_exchange_weak_explicit(atomic1, &innerCompare, value, memory_order_relaxed, memory_order_relaxed);\n"
                )
                // Use S rather than decltype(compare): the declared type of a parameter carries the
                // thread address space, and a struct field may not be qualified with an address space.
                helperGenerator.output.append(indent, "return __atomic_compare_exchange_result<S> { innerCompare, exchanged };\n")
            }
            helperGenerator.output.append(indent, "}\n")
        }

        if shaderModule.uses.contains(.dot) {
            helperGenerator.output.append(indent, "template<typename T, unsigned N>\n")
            helperGenerator.output.append(indent, "static T __wgslDot(vec<T, N> lhs, vec<T, N> rhs)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, .dotFirstTwoComponents)
                helperGenerator.output.append(indent, .dotThirdComponent)
                helperGenerator.output.append(indent, .dotFourthComponent)
                helperGenerator.output.append(indent, "return result;\n")
            }
            helperGenerator.output.append(indent, "}\n")
        }

        if shaderModule.uses.contains(.dot4I8Packed) {
            helperGenerator.output.append(indent, "static int __wgslDot4I8Packed(uint lhs, uint rhs)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "auto vec1 = as_type<packed_char4>(lhs);")
                helperGenerator.output.append(indent, "auto vec2 = as_type<packed_char4>(rhs);")
                helperGenerator.output.append(indent, .dot4x8PackedSum)
            }
            helperGenerator.output.append(indent, "}\n")
        }

        if shaderModule.uses.contains(.dot4U8Packed) {
            helperGenerator.output.append(indent, "static uint __wgslDot4U8Packed(uint lhs, uint rhs)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "auto vec1 = as_type<packed_uchar4>(lhs);")
                helperGenerator.output.append(indent, "auto vec2 = as_type<packed_uchar4>(rhs);")
                helperGenerator.output.append(indent, .dot4x8PackedSum)
            }
            helperGenerator.output.append(indent, "}\n")
        }

        if shaderModule.uses.contains(.firstLeadingBit) {
            helperGenerator.output.append(indent, "template<typename T>\n")
            helperGenerator.output.append(indent, "static T __wgslFirstLeadingBit(T e)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "if constexpr (is_signed_v<T>)\n")
                helperGenerator.output.append(
                    indent,
                    "    return select(T(31 - select(clz(e), clz(~e), e < T(0))), T(-1), e == T(0) || e == T(-1));\n"
                )
                helperGenerator.output.append(indent, "else\n")
                helperGenerator.output.append(indent, "    return select(T(31 - clz(e)), T(-1), e == T(0));\n")
            }
            helperGenerator.output.append(indent, "}\n")
        }

        if shaderModule.uses.contains(.firstTrailingBit) {
            helperGenerator.output.append(indent, "template<typename T>\n")
            helperGenerator.output.append(indent, "static T __wgslFirstTrailingBit(T e)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "return select(ctz(e), T(-1), e == T(0));\n")
            }
            helperGenerator.output.append(indent, "}\n")
        }

        if shaderModule.uses.contains(.sign) {
            helperGenerator.output.append(indent, "template<typename T>\n")
            helperGenerator.output.append(indent, "static T __wgslSign(T e)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "return select(select(T(-1), T(1), e > 0), T(0), e == 0);\n")
            }
            helperGenerator.output.append(indent, "}\n")
        }

        if shaderModule.uses.contains(.extractBits) {
            helperGenerator.output.append(indent, "template<typename T>\n")
            helperGenerator.output.append(indent, "static T __wgslExtractBits(T e, uint offset, uint count)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "auto o = min(offset, 32u);\n")
                helperGenerator.output.append(indent, "auto c = min(count, 32u - o);\n")
                helperGenerator.output.append(indent, "return select((T)0, extract_bits(e, min(o, 31u), c), c);\n")
            }
            helperGenerator.output.append(indent, "}\n")
        }

        if shaderModule.uses.contains(.min) {
            helperGenerator.output.append(MTLWorkaround.wgslMinHelper)
        }

        if shaderModule.uses.contains(.ftoi) {
            helperGenerator.output.append(indent, "template <typename T, typename S>\n")
            helperGenerator.output.append(indent, "static T __wgslFtoi(S value)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "if constexpr (is_same_v<make_scalar_t<S>, half>)\n")
                helperGenerator.output.append(
                    indent,
                    "return T(select(clamp(value, max(S(numeric_limits<T>::min()), numeric_limits<S>::lowest()), numeric_limits<S>::max()), S(0), isnan(value)));\n"
                )
                helperGenerator.output.append(indent, "else\n")
                helperGenerator.output.append(
                    indent,
                    "return T(select(clamp(value, S(numeric_limits<T>::min()), S(numeric_limits<T>::max() - ((128 << (!is_signed_v<T>)) - 1))), S(0), isnan(value)));\n"
                )
            }
            helperGenerator.output.append(indent, "}\n\n")
        }

        if shaderModule.uses.contains(.insertBits) {
            helperGenerator.output.append(indent, "template <typename T>\n")
            helperGenerator.output.append(indent, "static T __wgslInsertBits(T e, T newBits, unsigned offset, unsigned count)\n")
            helperGenerator.output.append(indent, "{\n")
            do {
                indent.increment()
                defer { indent.decrement() }
                helperGenerator.output.append(indent, "constexpr unsigned w = 8 * static_cast<unsigned>(sizeof(make_scalar_t<T>));\n")
                helperGenerator.output.append(indent, "const unsigned o = min(offset, w);\n")
                helperGenerator.output.append(indent, "const unsigned c = min(count, w - o);\n")
                helperGenerator.output.append(indent, "return insert_bits(e, newBits, min(o, w - 1), c);\n")
            }
            helperGenerator.output.append(indent, "}\n\n")
        }

        if shaderModule.uses.contains(.zeroWorkgroupVar) {
            helperGenerator.output.append(MTLWorkaround.zeroWorkgroupVarHelper)
        }

        shaderModule.uses.remove(.packedVec3)
    }
}

extension MSLWriter {
    /// C++ `append(m_indent, text)`.
    fileprivate mutating func append(_ indentation: Indentation, _ text: MSLText) {
        append(indentation)
        append(text)
    }

    fileprivate mutating func append(_ indentation: Indentation, _ helper: MSLHelperText) {
        append(indentation)
        append(helper)
    }
}

/// Runs `emitNecessaryHelpers` alone over `shaderModule`, which keeps the flags it leaves set (WorkaroundGoldenTests).
@_spi(Testing)
public func emitNecessaryHelpersForTesting(_ shaderModule: inout ShaderModule, deviceState: DeviceState) -> ContiguousArray<UInt8> {
    var writer = FunctionDefinitionWriter(
        shaderModule: shaderModule,
        stringBuilder: MSLWriter(),
        prepareResult: Reflection.EntryPointInformations(),
        constantValues: OverrideValues(),
        deviceState: deviceState
    )
    writer.emitNecessaryHelpers()
    shaderModule = writer.shaderModule
    return writer.helperGenerator.output.finish()
}
