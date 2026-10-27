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

import Foundation
import Metal
import Synchronization
import WebGPU_Internal.BindableResource
import WebGPU_Internal.CxxBridging
import WebGPU_Internal.Device

// The device's helper pipelines: the GPU-side clamps of index buffers and indirect draw arguments, the ICB encode and
// clamp shaders of render bundles, and the indirect dispatch clamp's buffer and pipeline. DeviceImpl caches the
// pipeline states per device. The shader functions other than the dispatch clamp's are compiled once per process, by
// the first device that asks, so a device on another GPU reuses the first one's functions. The dispatch clamp is
// compiled per device, with that device's limit.

// Must match Device.h's WEBKIT_DRAW_INDEXED_INDIRECT_STRUCT_TYPE and WEBKIT_DRAW_INDIRECT_STRUCT_TYPE.
private let drawIndexedIndirectStructType =
    "struct WebKitMTLDrawIndexedPrimitivesIndirectArguments { MTLDrawIndexedPrimitivesIndirectArguments args; unsigned lostOrOOBRead; };"
private let drawIndirectStructType =
    "struct WebKitMTLDrawPrimitivesIndirectArguments { MTLDrawPrimitivesIndirectArguments args; unsigned lostOrOOBRead; };"

// The buffer index of the ICB container argument buffer. The indirect-encode shader hardcodes [[buffer(1)]] to match.
private let bufferIndexForICBContainerValue = 1

private let indexBufferClampShaderSource = """

    #define vertexCount 0
    #define primitiveRestart 1
    #define indexCountMinusOne 2
        using namespace metal;
        \(drawIndexedIndirectStructType)
        [[vertex]] void vsUshortIndexClamp(device const ushort* indexBuffer [[buffer(0)]], device WebKitMTLDrawIndexedPrimitivesIndirectArguments& wkindexedOutput [[buffer(1)]], const constant uint* data [[buffer(2)]], uint indexId [[vertex_id]])
        {
            device MTLDrawIndexedPrimitivesIndirectArguments& indexedOutput = wkindexedOutput.args;
            ushort indexBufferValue = indexBuffer[min(indexId, data[indexCountMinusOne])];
            uint vertexIndex = uint((ushort)(data[primitiveRestart]) + indexBufferValue);
            if (addsat(vertexIndex, indexedOutput.baseVertex) >= data[vertexCount] + data[primitiveRestart]) {
                indexedOutput.indexCount = 0u;
                indexedOutput.instanceCount = 0u;
                indexedOutput.indexStart = 0u;
                indexedOutput.baseVertex = 0u;
                indexedOutput.baseInstance = 0u;
                wkindexedOutput.lostOrOOBRead = 1;
            }
        }
        [[vertex]] void vsUintIndexClamp(device const uint* indexBuffer [[buffer(0)]], device WebKitMTLDrawIndexedPrimitivesIndirectArguments& wkindexedOutput [[buffer(1)]], const constant uint* data [[buffer(2)]], uint indexId [[vertex_id]])
        {
            device MTLDrawIndexedPrimitivesIndirectArguments& indexedOutput = wkindexedOutput.args;
            uint indexBufferValue = indexBuffer[min(indexId, data[indexCountMinusOne])];
            uint vertexIndex = data[primitiveRestart] + indexBufferValue;
            if (addsat(vertexIndex, indexedOutput.baseVertex) >= data[vertexCount] + data[primitiveRestart]) {
                indexedOutput.indexCount = 0u;
                indexedOutput.instanceCount = 0u;
                indexedOutput.indexStart = 0u;
                indexedOutput.baseVertex = 0u;
                indexedOutput.baseInstance = 0u;
                wkindexedOutput.lostOrOOBRead = 1;
            }
        }
    """

private func indexedIndirectBufferClampShaderSource(_ maxVertices: UInt32) -> String {
    """

        using namespace metal;
        \(drawIndirectStructType)
        \(drawIndexedIndirectStructType)
        [[vertex]] void vsIndexedIndirect(device const MTLDrawIndexedPrimitivesIndirectArguments& input [[buffer(0)]], device WebKitMTLDrawIndexedPrimitivesIndirectArguments& wkindexedOutput [[buffer(1)]], device WebKitMTLDrawPrimitivesIndirectArguments& wkoutput [[buffer(2)]], const constant uint* indexBufferCount [[buffer(3)]])
        {
            device MTLDrawPrimitivesIndirectArguments& output = wkoutput.args;
            device MTLDrawIndexedPrimitivesIndirectArguments& indexedOutput = wkindexedOutput.args;
            bool lostCondition = input.indexCount > \(maxVertices) || input.instanceCount > \(maxVertices) || madsat(input.indexCount, input.instanceCount, 0u) > \(maxVertices);
            bool condition = lostCondition
                || addsat(input.indexCount, input.indexStart) > indexBufferCount[0]
                || input.indexStart >= indexBufferCount[0]
                || addsat(input.instanceCount, input.baseInstance) > indexBufferCount[1]
                || input.baseInstance >= indexBufferCount[1];
            bool drawsNothing = condition || !input.indexCount;

            indexedOutput.indexCount = metal::select(input.indexCount, 0u, condition);
            indexedOutput.instanceCount = metal::select(input.instanceCount, 0u, drawsNothing);
            indexedOutput.indexStart = metal::select(input.indexStart, 0u, condition);
            indexedOutput.baseVertex = input.baseVertex;
            indexedOutput.baseInstance = input.baseInstance;

            output.vertexCount = metal::select(input.indexCount, 0u, condition);
            output.instanceCount = 1;
            output.vertexStart = input.indexStart;
            output.baseInstance = 0;
            if (lostCondition)
                wkoutput.lostOrOOBRead = 1;
        }
    """
}

private func indirectBufferClampShaderSource(_ maxVertices: UInt32) -> String {
    """

        using namespace metal;
        \(drawIndirectStructType)
        [[vertex]] void vsIndirect(device const MTLDrawPrimitivesIndirectArguments& input [[buffer(0)]], device WebKitMTLDrawPrimitivesIndirectArguments& wkoutput [[buffer(1)]], const constant uint* minCounts [[buffer(2)]])
        {
            device MTLDrawPrimitivesIndirectArguments& output = wkoutput.args;
            bool lostCondition = input.vertexCount > \(maxVertices) || input.instanceCount > \(maxVertices) || madsat(input.vertexCount, input.instanceCount, 0u) > \(maxVertices);
            bool vertexCondition = addsat(input.vertexCount, input.vertexStart) > minCounts[0] || input.vertexStart >= minCounts[0];
            bool instanceCondition = addsat(input.baseInstance, input.instanceCount) > minCounts[1] || input.baseInstance >= minCounts[1];
            auto minVertexCountMinusVertexStart = minCounts[0] > input.vertexStart ? (minCounts[0] - input.vertexStart) : 0u;
            uint vertexCount = metal::select(input.vertexCount, minVertexCountMinusVertexStart, vertexCondition);
            auto minInstanceCountMinusInstanceStart = minCounts[1] > input.baseInstance ? (minCounts[1] - input.baseInstance) : 0u;
            uint instanceCount = metal::select(input.instanceCount, minInstanceCountMinusInstanceStart, instanceCondition);
            bool drawsNothing = lostCondition || !vertexCount || !instanceCount;
            output.vertexCount = metal::select(vertexCount, 0u, drawsNothing);
            output.instanceCount = metal::select(instanceCount, 0u, drawsNothing);
            output.vertexStart = input.vertexStart;
            output.baseInstance = input.baseInstance;
            if (lostCondition)
                wkoutput.lostOrOOBRead = 1;
        }
    """
}

private let icbIndirectEncodeShaderSource = """

        using namespace metal;
        struct ICBContainer {
            device uint* outOfBoundsRead [[ id(0) ]];
            command_buffer commandBuffer [[ id(1) ]];
        };

        static_assert(sizeof(primitive_type) == sizeof(uint32_t), "API assumes primitive type is sizeof uint32_t");

        // slotData[0] = ICB slot index, slotData[1] = primitive_type.
        [[vertex]] void vsICBIndirectDraw(device const MTLDrawPrimitivesIndirectArguments& args [[buffer(0)]],
            device ICBContainer *icb_container [[buffer(1)]],
            const constant uint* slotData [[buffer(2)]])
        {
            render_command cmd(icb_container->commandBuffer, slotData[0]);
            cmd.draw_primitives(static_cast<primitive_type>(slotData[1]),
                args.vertexStart,
                args.vertexCount,
                args.instanceCount,
                args.baseInstance);
        }

        // slotData[2] = index buffer element offset.
        [[vertex]] void vsICBIndirectIndexedUint(device const MTLDrawIndexedPrimitivesIndirectArguments& args [[buffer(0)]],
            device ICBContainer *icb_container [[buffer(1)]],
            device uint* indexBuffer [[buffer(2)]],
            const constant uint* slotData [[buffer(3)]])
        {
            render_command cmd(icb_container->commandBuffer, slotData[0]);
            device uint* indexBufferBase = indexBuffer + slotData[2] + args.indexStart;
            cmd.draw_indexed_primitives(static_cast<primitive_type>(slotData[1]),
                args.indexCount,
                indexBufferBase,
                args.instanceCount,
                args.baseVertex,
                args.baseInstance);
        }

        [[vertex]] void vsICBIndirectIndexedUshort(device const MTLDrawIndexedPrimitivesIndirectArguments& args [[buffer(0)]],
            device ICBContainer *icb_container [[buffer(1)]],
            device ushort* indexBuffer [[buffer(2)]],
            const constant uint* slotData [[buffer(3)]])
        {
            render_command cmd(icb_container->commandBuffer, slotData[0]);
            device ushort* indexBufferBase = indexBuffer + slotData[2] + args.indexStart;
            cmd.draw_indexed_primitives(static_cast<primitive_type>(slotData[1]),
                args.indexCount,
                indexBufferBase,
                args.instanceCount,
                args.baseVertex,
                args.baseInstance);
        }
    """

// The MSL static_asserts that pin each field of the clamp shader's index data struct to its offset in
// WebGPU::Metal::IndexData, which C++ fills in.
private func indexDataOffsetAsserts(_ structName: String) -> String {
    let fields: [(name: String, offset: Int?)] = [
        ("renderCommand", MemoryLayout<WebGPU.Metal.IndexData>.offset(of: \.renderCommand)),
        ("minVertexCount", MemoryLayout<WebGPU.Metal.IndexData>.offset(of: \.minVertexCount)),
        ("minInstanceCount", MemoryLayout<WebGPU.Metal.IndexData>.offset(of: \.minInstanceCount)),
        ("indexBuffer", MemoryLayout<WebGPU.Metal.IndexData>.offset(of: \.bufferGpuAddress)),
        ("indexBufferElementCountMinusOne", MemoryLayout<WebGPU.Metal.IndexData>.offset(of: \.indexBufferElementCountMinusOne)),
        ("indexCount", MemoryLayout<WebGPU.Metal.IndexData>.offset(of: \.indexCount)),
        ("instanceCount", MemoryLayout<WebGPU.Metal.IndexData>.offset(of: \.instanceCount)),
        ("firstIndex", MemoryLayout<WebGPU.Metal.IndexData>.offset(of: \.firstIndex)),
        ("baseVertex", MemoryLayout<WebGPU.Metal.IndexData>.offset(of: \.baseVertex)),
        ("baseInstance", MemoryLayout<WebGPU.Metal.IndexData>.offset(of: \.firstInstance)),
        ("primitiveType", MemoryLayout<WebGPU.Metal.IndexData>.offset(of: \.primitiveType)),
    ]
    return
        fields.map { field in
            guard let offset = field.offset else {
                preconditionFailure("IndexData.\(field.name) is not a stored field")
            }
            return
                "static_assert(__builtin_offsetof(\(structName), \(field.name)) == \(offset), \"\(structName).\(field.name) in shader mismatches the API offset\");"
        }
        .joined(separator: "\n    ")
}

private func icbCommandClampShaderSource(_ indexDataSize: Int) -> String {
    """

        using namespace metal;
        struct ICBContainer {
            device uint* outOfBoundsRead [[ id(0) ]];
            command_buffer commandBuffer [[ id(1) ]];
        };
        struct IndexDataUshort {
            uint64_t renderCommand { 0 };
            uint32_t minVertexCount { UINT_MAX };
            uint32_t minInstanceCount { UINT_MAX };
            device ushort* indexBuffer;
            uint32_t indexBufferElementCountMinusOne;
            uint32_t indexCount { 0 };
            uint32_t instanceCount { 0 };
            uint32_t firstIndex { 0 };
            uint32_t baseVertex { 0 };
            uint32_t baseInstance { 0 };
            primitive_type primitiveType { primitive_type::triangle };
        };
        struct IndexDataUint {
            uint64_t renderCommand { 0 };
            uint32_t minVertexCount { UINT_MAX };
            uint32_t minInstanceCount { UINT_MAX };
            device uint* indexBuffer;
            uint32_t indexBufferElementCountMinusOne;
            uint32_t indexCount { 0 };
            uint32_t instanceCount { 0 };
            uint32_t firstIndex { 0 };
            uint32_t baseVertex { 0 };
            uint32_t baseInstance { 0 };
            primitive_type primitiveType { primitive_type::triangle };
        };

        static_assert(sizeof(primitive_type) == sizeof(uint32_t), "API assumes primitive type is sizeof uint32_t");
        static_assert(sizeof(IndexDataUshort) == \(indexDataSize), "sizeof(IndexDataUshort) in shader mismatches the API size");
        static_assert(sizeof(IndexDataUint) == \(indexDataSize), "sizeof(IndexDataUint) in shader mismatches the API size");
        \(indexDataOffsetAsserts("IndexDataUshort"))
        \(indexDataOffsetAsserts("IndexDataUint"))

        [[vertex]] void vsICB(device const IndexDataUint* indexData [[buffer(0)]],
            device ICBContainer *icb_container [[buffer(\(bufferIndexForICBContainerValue))]],
            uint indexId [[vertex_id]])
        {
            device const IndexDataUint& data = *indexData;
            uint32_t k = (data.primitiveType == primitive_type::triangle_strip || data.primitiveType == primitive_type::line_strip) ? 1 : 0;
            uint32_t indexBufferValue = data.indexBuffer[min(data.indexBufferElementCountMinusOne, indexId + data.firstIndex)];
            uint32_t vertexIndex = indexBufferValue + k;
            if (addsat(vertexIndex, data.baseVertex) >= data.minVertexCount + k) {
                *icb_container->outOfBoundsRead = 1;
                render_command cmd(icb_container->commandBuffer, data.renderCommand);
                cmd.draw_indexed_primitives(data.primitiveType,
                    0u,
                    data.indexBuffer,
                    data.instanceCount,
                    data.baseVertex,
                    data.baseInstance);
            }
        }

        [[vertex]] void vsUshortICB(device const IndexDataUshort* indexData [[buffer(0)]],
            device ICBContainer *icb_container [[buffer(\(bufferIndexForICBContainerValue))]],
            uint indexId [[vertex_id]])
        {
            device const IndexDataUshort& data = *indexData;
            uint32_t k = (data.primitiveType == primitive_type::triangle_strip || data.primitiveType == primitive_type::line_strip) ? 1 : 0;
            ushort indexBufferValue = data.indexBuffer[min(data.indexBufferElementCountMinusOne, indexId + data.firstIndex)];
            uint32_t vertexIndex = uint(indexBufferValue) + k;
            if (addsat(vertexIndex, data.baseVertex) >= data.minVertexCount + k) {
                *icb_container->outOfBoundsRead = 1;
                render_command cmd(icb_container->commandBuffer, data.renderCommand);
                cmd.draw_indexed_primitives(data.primitiveType,
                    0u,
                    data.indexBuffer,
                    data.instanceCount,
                    data.baseVertex,
                    data.baseInstance);
            }

        }
    """
}

// A set of process-wide helper shader functions: compiled by the first caller, then shared.
private final class HelperFunctions: Sendable {
    private let functions = Mutex<[(any MTLFunction)?]?>(nil)

    func get(_ compile: () -> [(any MTLFunction)?]) -> [(any MTLFunction)?] {
        functions.withLock { functions in
            if let functions {
                return functions
            }
            let compiled = compile()
            functions = compiled
            return compiled
        }
    }
}

private let indexBufferClampFunctions = HelperFunctions()
private let indexedIndirectBufferClampFunctions = HelperFunctions()
private let indirectBufferClampFunctions = HelperFunctions()
private let icbIndirectEncodeFunctions = HelperFunctions()
private let icbCommandClampFunctions = HelperFunctions()

// A library compiled with fast math. A failed compile is logged and is nil, as is a nil device.
private func compileDeviceHelperLibrary(_ metalDevice: (any MTLDevice)?, _ source: String) -> (any MTLLibrary)? {
    let options = MTLCompileOptions()
    options.mathMode = .fast
    do {
        return try metalDevice?.makeLibrary(source: source, options: options)
    } catch {
        WebGPU.Metal.logAlways("\(error)")
        return nil
    }
}

// The named functions of a library compiled with fast math; a nil device or a failed compile gives nil functions.
private func compileHelperFunctions(_ metalDevice: (any MTLDevice)?, _ source: String, _ names: [String]) -> [(any MTLFunction)?] {
    let library = compileDeviceHelperLibrary(metalDevice, source)
    return names.map { library?.makeFunction(name: $0) }
}

// The vertex function of CommandEncoder's clear passes (DeviceImpl.nopVertexFunction()).
func compileNopVertexFunction(_ metalDevice: (any MTLDevice)?) -> (any MTLFunction)? {
    compileHelperFunctions(metalDevice, "[[vertex]] float4 vsNop() { return (float4)0; }", ["vsNop"])[0]
}

// The indirect dispatch clamp: a workgroup count above maxComputeWorkgroupsPerDimension becomes 0.
private func dispatchClampShaderSource(_ maxComputeWorkgroupsPerDimension: UInt32) -> String {
    "[[kernel]] void csDispatchClamp(device const uint* indirectBuffer, device uint* dispatchCallBuffer, uint index [[thread_position_in_grid]]) { dispatchCallBuffer[index] = metal::select(indirectBuffer[index], 0u, indirectBuffer[index] > \(maxComputeWorkgroupsPerDimension)); }"
}

// The function of the pipeline creation code, labelled. A failure is logged and is nil, as is a nil library.
func createFunction(_ library: (any MTLLibrary)?, _ mangledName: Swift.String?, _ label: Swift.String?) -> (any MTLFunction)? {
    guard let library else {
        return nil
    }
    let descriptor = MTLFunctionDescriptor()
    descriptor.name = mangledName
    do {
        let function = try library.makeFunction(descriptor: descriptor)
        function.label = label
        return function
    } catch {
        WebGPU.Metal.logAlways("Function creation error: \(error)")
        return nil
    }
}

// Keys of DeviceImpl's render pipeline cache. helperPipelineSlot() relies on the order: index type, then sample count.
private enum HelperPipelineSlot: UInt8 {
    case indexBufferClampUint
    case indexBufferClampUshort
    case indexBufferClampUintMS
    case indexBufferClampUshortMS
    case indexedIndirectBufferClamp
    case indexedIndirectBufferClampMS
    case indirectBufferClamp
    case indirectBufferClampMS
    case icbCommandClampUint
    case icbCommandClampUshort
    case icbCommandClampUintMS
    case icbCommandClampUshortMS
    case icbIndirectEncodeUint
    case icbIndirectEncodeUshort
    case icbIndirectEncodeUintMS
    case icbIndirectEncodeUshortMS
    case icbIndirectEncodeDraw
    case icbIndirectEncodeDrawMS
}

private func helperPipelineSlot(_ first: HelperPipelineSlot, isUint16: Bool, _ rasterSampleCount: UInt) -> UInt8 {
    first.rawValue + (isUint16 ? 1 : 0) + (rasterSampleCount > 1 ? 2 : 0)
}

private func helperPipelineSlot(_ first: HelperPipelineSlot, _ rasterSampleCount: UInt) -> UInt8 {
    first.rawValue + (rasterSampleCount > 1 ? 1 : 0)
}

extension DeviceImpl {
    // MARK: Index buffer and indirect argument clamps, and the ICB helpers (RenderPassEncoder, RenderBundleEncoder)

    func indexBufferClampPipeline(_ indexType: MTLIndexType, _ rasterSampleCount: UInt) -> (any MTLRenderPipelineState)? {
        guard let metalDevice = device() else {
            return nil
        }
        let isUint16 = indexType == .uint16
        let slot = helperPipelineSlot(.indexBufferClampUint, isUint16: isUint16, rasterSampleCount)
        if let result = cachedRenderPipelineState(slot) {
            return result
        }
        let functions = indexBufferClampFunctions.get {
            compileHelperFunctions(metalDevice, indexBufferClampShaderSource, ["vsUintIndexClamp", "vsUshortIndexClamp"])
        }
        guard let function = functions[0], let functionUshort = functions[1] else {
            preconditionFailure("the index buffer clamp functions did not compile")
        }
        return makeHelperRenderPipelineState(metalDevice, slot, isUint16 ? functionUshort : function, rasterSampleCount)
    }

    func indexedIndirectBufferClampPipeline(_ rasterSampleCount: UInt) -> (any MTLRenderPipelineState)? {
        guard let metalDevice = device() else {
            return nil
        }
        let slot = helperPipelineSlot(.indexedIndirectBufferClamp, rasterSampleCount)
        if let result = cachedRenderPipelineState(slot) {
            return result
        }
        // The first device's vertex limit is compiled in for every device.
        let maxVertices = maxVerticesPerDrawCall()
        let functions = indexedIndirectBufferClampFunctions.get {
            compileHelperFunctions(metalDevice, indexedIndirectBufferClampShaderSource(maxVertices), ["vsIndexedIndirect"])
        }
        guard let function = functions[0] else {
            preconditionFailure("the indexed indirect buffer clamp function did not compile")
        }
        return makeHelperRenderPipelineState(metalDevice, slot, function, rasterSampleCount)
    }

    func indirectBufferClampPipeline(_ rasterSampleCount: UInt) -> (any MTLRenderPipelineState)? {
        guard let metalDevice = device() else {
            return nil
        }
        let slot = helperPipelineSlot(.indirectBufferClamp, rasterSampleCount)
        if let result = cachedRenderPipelineState(slot) {
            return result
        }
        // The first device's vertex limit is compiled in for every device.
        let maxVertices = maxVerticesPerDrawCall()
        let functions = indirectBufferClampFunctions.get {
            compileHelperFunctions(metalDevice, indirectBufferClampShaderSource(maxVertices), ["vsIndirect"])
        }
        guard let function = functions[0] else {
            preconditionFailure("the indirect buffer clamp function did not compile")
        }
        return makeHelperRenderPipelineState(metalDevice, slot, function, rasterSampleCount)
    }

    func icbIndirectEncodePipeline(_ isIndexed: Bool, _ indexType: MTLIndexType, _ rasterSampleCount: UInt) -> (any MTLRenderPipelineState)?
    {
        guard let metalDevice = device() else {
            return nil
        }
        let isUint16 = indexType == .uint16
        let slot =
            isIndexed
            ? helperPipelineSlot(.icbIndirectEncodeUint, isUint16: isUint16, rasterSampleCount)
            : helperPipelineSlot(.icbIndirectEncodeDraw, rasterSampleCount)
        if let result = cachedRenderPipelineState(slot) {
            return result
        }
        return makeHelperRenderPipelineState(metalDevice, slot, icbIndirectEncodeFunction(isIndexed, indexType), rasterSampleCount)
    }

    func icbCommandClampPipeline(_ indexType: MTLIndexType, _ rasterSampleCount: UInt) -> (any MTLRenderPipelineState)? {
        guard let metalDevice = device() else {
            return nil
        }
        let slot = helperPipelineSlot(.icbCommandClampUint, isUint16: indexType == .uint16, rasterSampleCount)
        if let result = cachedRenderPipelineState(slot) {
            return result
        }
        return makeHelperRenderPipelineState(metalDevice, slot, icbCommandClampVertexFunction(indexType), rasterSampleCount)
    }

    // Never nil: RenderBundleEncoder makes the ICB container's argument encoder from it without checking the device, so
    // a lost device compiling it first fails the precondition.
    func icbCommandClampFunction(_ indexType: MTLIndexType) -> (any MTLFunction)? {
        icbCommandClampVertexFunction(indexType)
    }

    func bufferIndexForICBContainer() -> Int32 {
        Int32(bufferIndexForICBContainerValue)
    }

    // Encodes an indirect draw into an ICB slot on the GPU, reading the draw counts from the args buffer (clamped shadow
    // args, or the app's raw buffer when no clamping is required) at executeBundles() time.
    private func icbIndirectEncodeFunction(_ isIndexed: Bool, _ indexType: MTLIndexType) -> any MTLFunction {
        precondition(bufferIndexForICBContainerValue == 1)
        let metalDevice = device()
        let functions = icbIndirectEncodeFunctions.get {
            compileHelperFunctions(
                metalDevice,
                icbIndirectEncodeShaderSource,
                ["vsICBIndirectDraw", "vsICBIndirectIndexedUint", "vsICBIndirectIndexedUshort"]
            )
        }
        guard let functionDraw = functions[0], let functionIndexedUint = functions[1], let functionIndexedUshort = functions[2] else {
            preconditionFailure("the ICB indirect encode functions did not compile")
        }
        if !isIndexed {
            return functionDraw
        }
        return indexType == .uint16 ? functionIndexedUshort : functionIndexedUint
    }

    private func icbCommandClampVertexFunction(_ indexType: MTLIndexType) -> any MTLFunction {
        let metalDevice = device()
        let functions = icbCommandClampFunctions.get {
            compileHelperFunctions(
                metalDevice,
                icbCommandClampShaderSource(MemoryLayout<WebGPU.Metal.IndexData>.stride),
                ["vsICB", "vsUshortICB"]
            )
        }
        guard let function = functions[0], let functionUshort = functions[1] else {
            preconditionFailure("the ICB command clamp functions did not compile")
        }
        return indexType == .uint16 ? functionUshort : function
    }

    // The vertex-only pipeline of every helper, cached in `slot` whatever the outcome. A failure is logged and is nil.
    private func makeHelperRenderPipelineState(
        _ metalDevice: any MTLDevice,
        _ slot: UInt8,
        _ vertexFunction: any MTLFunction,
        _ rasterSampleCount: UInt
    ) -> (any MTLRenderPipelineState)? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.isRasterizationEnabled = false
        descriptor.rasterSampleCount = Int(bitPattern: rasterSampleCount)
        descriptor.fragmentFunction = nil
        descriptor.inputPrimitiveTopology = .point
        var result: (any MTLRenderPipelineState)?
        do {
            result = try metalDevice.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            WebGPU.Metal.logAlways("\(error)")
        }
        setCachedRenderPipelineState(slot, result)
        return result
    }

    // MARK: Indirect dispatch clamp (ComputePassEncoderImpl.encodeIndirectDispatchClamp)

    func ensureDispatchCallBuffer() -> (any MTLBuffer)? {
        guard let metalDevice = device() else {
            return nil
        }
        if let buffer = cachedDispatchCallBuffer() {
            return buffer
        }
        let buffer = metalDevice.makeBuffer(
            length: MemoryLayout<MTLDispatchThreadgroupsIndirectArguments>.stride,
            options: .storageModePrivate
        )
        setOwnerWithIdentity(buffer)
        setCachedDispatchCallBuffer(buffer)
        return buffer
    }

    // Compiled for this device, with its own maxComputeWorkgroupsPerDimension, the first time it is needed. A failure is
    // logged, cached as nil and retried next time.
    func ensureDispatchCallPipelineState() -> (any MTLComputePipelineState)? {
        guard let metalDevice = device() else {
            return nil
        }
        if let pipelineState = cachedDispatchCallPipelineState() {
            return pipelineState
        }
        guard
            let function = compileHelperFunctions(
                metalDevice,
                dispatchClampShaderSource(capabilities.limits.maxComputeWorkgroupsPerDimension),
                ["csDispatchClamp"]
            )[0]
        else {
            return nil
        }
        var pipelineState: (any MTLComputePipelineState)?
        do {
            pipelineState = try metalDevice.makeComputePipelineState(function: function)
        } catch {
            WebGPU.Metal.logAlways("Metal code failure: \(error)")
        }
        setCachedDispatchCallPipelineState(pipelineState)
        return pipelineState
    }
}

// MARK: Default queue (Device::create)

// nil when Metal cannot make one, which makes the device invalid. The label goes on the queue, not on the MTLDevice,
// which every context in the process shares (see Device::setLabel).
@_expose(Cxx)
func makeDefaultCommandQueue(_ metalDevice: (any MTLDevice)?, _ deviceLabel: WTF.String) -> (any MTLCommandQueue)? {
    guard let commandQueue = metalDevice?.makeCommandQueue(maxCommandBufferCount: 4096) else {
        return nil
    }
    if let label = CxxBridging.convertWTFStringToNSString(deviceLabel) as String? {
        commandQueue.label = "Default queue for device \(label)"
    } else {
        commandQueue.label = "Default queue"
    }
    return commandQueue
}

#if WTF_PLATFORM_WATCHOS
// watchOS has no Metal Swift overlay, so these are the overlay methods WebGPU uses, written over the
// Objective-C methods the overlay refines.
extension MTLBlitCommandEncoder {
    func fill(buffer: any MTLBuffer, range: Range<Int>, value: UInt8) {
        __fill(buffer, range: NSRange(range), value: value)
    }

    func copyIndirectCommandBuffer(
        _ buffer: any MTLIndirectCommandBuffer,
        sourceRange: Range<Int>,
        destination: any MTLIndirectCommandBuffer,
        destinationIndex: Int
    ) {
        __copy(buffer, sourceRange: NSRange(sourceRange), destination: destination, destinationIndex: destinationIndex)
    }

    func resolveCounters(
        _ sampleBuffer: any MTLCounterSampleBuffer,
        range: Range<Int>,
        destinationBuffer: any MTLBuffer,
        destinationOffset: Int
    ) {
        __resolveCounters(sampleBuffer, in: NSRange(range), destinationBuffer: destinationBuffer, destinationOffset: destinationOffset)
    }
}

extension MTLComputeCommandEncoder {
    func useResources(_ resources: [any MTLResource], usage: MTLResourceUsage) {
        unsafe __use(resources, count: resources.count, usage: usage)
    }
}

extension MTLRenderCommandEncoder {
    func useResources(_ resources: [any MTLResource], usage: MTLResourceUsage, stages: MTLRenderStages) {
        unsafe __use(resources, count: resources.count, usage: usage, stages: stages)
    }

    func executeCommandsInBuffer(_ buffer: any MTLIndirectCommandBuffer, range: Range<Int>) {
        __executeCommands(in: buffer, with: NSRange(range))
    }
}

extension MTLTexture {
    func makeTextureView(
        pixelFormat: MTLPixelFormat,
        textureType: MTLTextureType,
        levels: Range<Int>,
        slices: Range<Int>
    ) -> (any MTLTexture)? {
        __newTextureView(with: pixelFormat, textureType: textureType, levels: NSRange(levels), slices: NSRange(slices))
    }

    func makeTextureView(
        pixelFormat: MTLPixelFormat,
        textureType: MTLTextureType,
        levels: Range<Int>,
        slices: Range<Int>,
        swizzle: MTLTextureSwizzleChannels
    ) -> (any MTLTexture)? {
        __newTextureView(with: pixelFormat, textureType: textureType, levels: NSRange(levels), slices: NSRange(slices), swizzle: swizzle)
    }
}
#endif
