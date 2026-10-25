// Copyright (c) 2023-2026 Apple Inc. All rights reserved.
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

extension RewriteGlobalVariables {
    mutating func def(_ name: IdentifierID, _ variable: VariableID?) {
        defs.add(shaderModule.symbol(of: name), variable)
    }

    @discardableResult
    mutating func readVariable(_ identifier: IdentifierExpression) -> Global? {
        let name = shaderModule.symbol(of: identifier.identifier)
        if defs.contains(name) {
            return nil
        }

        guard let global = globals.find(name) else {
            return nil
        }

        if shaderModule[global.declaration].flavor == .const {
            return nil
        }

        if reads.add(name) {
            if let type = shaderModule[global.declaration].maybeTypeName {
                visit(type)
            }
            if let initializer = shaderModule[global.declaration].maybeInitializer {
                visit(initializer)
            }
            recordTypeReads(shaderModule[global.declaration].storeType)
        }

        return global
    }

    // An override may only ever be named from within a type, e.g. `array<vec4f, N>`, and the type may
    // in turn only be named through an alias, in which case visiting the type expression above never
    // reaches the override. It would then be missing from the entry point's specialization constants,
    // the pipeline would drop the value supplied for it, and the emitted Metal would refer to an
    // undeclared constant. Walk the resolved type so those overrides are recorded as reads too.
    mutating func recordTypeReads(_ type: TypeID?) {
        var type = type
        while let current = type {
            if let array = shaderModule.types.getIf(Types.Array.self, current) {
                if case .overrideSized(let size) = array.size {
                    visit(size)
                }
                type = array.element
                continue
            }

            // Only the element of these can be an override-sized array; a struct member may not be one.
            if let reference = shaderModule.types.getIf(Types.Reference.self, current) {
                type = reference.element
            } else if let pointer = shaderModule.types.getIf(Types.Pointer.self, current) {
                type = pointer.element
            } else if let atomic = shaderModule.types.getIf(Types.Atomic.self, current) {
                type = atomic.element
            } else {
                type = nil
            }
        }
    }

    mutating func insertBeforeCurrentStatement(_ statement: StatementID) {
        pendingInsertions.append(Insertion(statement: statement, index: currentStatementIndex))
    }

    /// C++ `static`; interning the name needs the module.
    mutating func argumentBufferParameterName(_ group: UInt32) -> Identifier {
        shaderModule.makeIdentifier(shaderModule.symbols.intern(.argumentBufferParameter(group: group)))
    }

    mutating func argumentBufferStructName(_ group: UInt32) -> Identifier {
        shaderModule.makeIdentifier(shaderModule.symbols.intern(.argumentBufferStruct(entryPoint: entryPointID, group: group)))
    }

    /// C++ `static`; interning the name needs the module.
    mutating func dynamicOffsetVariableName() -> Identifier {
        shaderModule.makeIdentifier(shaderModule.symbols.intern(.fixed(.dynamicOffsets)))
    }
}
