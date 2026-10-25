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

/// The pipeline constant conversion of prepareLibrary (Pipeline.mm:89-140): nil where prepareLibrary returned nullopt.
///
/// It reads the specialization constants of every prepared entry point; with one entry point it is exactly Pipeline.mm.
///
/// The result is `wgslConstantValues`: one assignment per key, in the order of each key's first constant, holding its last value
/// (HashMap::set).
func convertPipelineConstants(
    _ entryPoints: Reflection.EntryPointInformations,
    _ shaderModule: borrowing ShaderModule,
    _ constants: [PipelineConstant]
) -> [OverrideAssignment]? {
    if constants.isEmpty {
        return []
    }
    var specializationConstantTypes = LookupMap<Name, SpecializationConstantType>()
    for entryPointInformation in entryPoints.entries {
        for specializationConstant in entryPointInformation.specializationConstants {
            specializationConstantTypes.add(specializationConstant.key, specializationConstant.type)
        }
    }

    var wgslConstantValues: [OverrideAssignment] = []
    var wgslConstantIndices = LookupMap<Name, Int>()
    func set(_ key: Name, _ value: ScalarValue) {
        if let index = wgslConstantIndices.get(key) {
            wgslConstantValues[index].value = value
            return
        }
        wgslConstantIndices.add(key, wgslConstantValues.count)
        wgslConstantValues.append(OverrideAssignment(key: key, value: value))
    }

    for entry in constants {
        let keyEntry = entry.key
        guard let type = specializationConstantTypes.get(keyEntry) else {
            // Per WebGPU spec: providing a value for an override declared in the
            // shader module but not statically used by this entry point is valid
            // and the value is ignored. Returning an invalid pipeline only when
            // the identifier does not refer to any override in the module.
            if shaderModule.containsOverride(keyEntry) {
                continue
            }
            return nil
        }

        switch type {
        case .boolean:
            let value = entry.value != 0
            set(keyEntry, .bool(value))
        case .float:
            if entry.value < -Double(Float.greatestFiniteMagnitude) || entry.value > Double(Float.greatestFiniteMagnitude) {
                return nil
            }
            let value = Float(entry.value)
            set(keyEntry, .f32(value))
        case .int:
            if entry.value < Double(Int32.min) || entry.value > Double(Int32.max) {
                return nil
            }
            // DEV-13: NaN passes the range check; C++ `int value = NaN` is UB, arm64 FCVTZS gives 0.
            let value = arm64ConvertToInt32(entry.value)
            set(keyEntry, .i32(value))
        case .unsigned:
            if entry.value < 0 || entry.value > Double(UInt32.max) {
                return nil
            }
            // DEV-13: NaN passes the range check; C++ `unsigned value = NaN` is UB, arm64 FCVTZU gives 0.
            let value = arm64ConvertToUInt32(entry.value)
            set(keyEntry, .u32(value))
        case .half:
            let halfMax = 0x1.ffcp15
            let halfLowest = -halfMax
            if entry.value < halfLowest || entry.value > halfMax {
                return nil
            }
            let value = Half(entry.value)
            set(keyEntry, .f16(bits: value.bitPattern))
        }
    }

    return wgslConstantValues
}
