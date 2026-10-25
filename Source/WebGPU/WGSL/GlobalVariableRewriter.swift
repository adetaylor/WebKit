// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
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

/// C++ `RewriteGlobalVariables`.
///
/// Its functions are split over the GlobalVariableRewriter+*.swift files in C++ order.
struct RewriteGlobalVariables: ASTVisitor, ~Copyable {
    typealias Global = CallGraph.Global

    typealias IndexMap<Value> = WTFIndexMap<Value>

    /// C++ `IndexMap<IndexMap<const Global*>>`, by group, then binding.
    ///
    /// A `Global` is the value C++ points at in `m_globals`, which never changes once added.
    typealias UsedResources = IndexMap<IndexMap<Global>>
    typealias UsedPrivateGlobals = [Global]

    struct UsedGlobals {
        var resources = UsedResources()
        var privateGlobals: UsedPrivateGlobals = []
    }

    struct Insertion {
        let statement: StatementID
        let index: Int
    }

    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false

    var globals = SymbolMap<Global>()
    // DEV-05: every (group, binding) is an ordinary key; C++ keys on {group + 1, binding + 1}, which traps at UINT_MAX.
    var globalsByBinding = SmallKeyMap<BindingKey, VariableID>()
    var groupBindingMap = IndexMap<[(binding: UInt32, name: Symbol)]>()
    var structTypes = IndexMap<TypeID>()
    var defs = SymbolMap<VariableID?>()
    var reads = OrderedSet<Symbol>()
    var lengthParameters = SideTable<FunctionID, OrderedSet<Symbol>>()
    var visitedFunctions = SideTable<FunctionID, OrderedSet<Symbol>>()
    /// C++ `m_entryPointInformation`: the index in `entryPointInformations` of the entry point being rewritten.
    var entryPointInformation: Int?
    var generateLayoutGroupMapping = LookupMap<UInt32, UInt32>()
    /// C++ `m_generatedLayout`: the index in `entryPointInformations` of the entry point whose default layout is being computed; nil
    /// for an explicit layout.
    var generatedLayout: Int?
    var currentStatementIndex = 0
    var entryPointID: UInt32 = 0
    var pendingInsertions: [Insertion] = []
    var packedStructTypes = SmallKeyMap<TypeID, TypeID>()
    /// packTypes' frames and memo, kept so that the packing of each resource in each prepare allocates neither.
    var packTypesFrames: [PackTypeFrame] = []
    var packTypesMemo = SmallKeyMap<TypeID, TypeID?>()
    var stage = ShaderStage.vertex
    /// C++ `m_pipelineLayouts`: the entry points to rewrite, by source name, each with its explicit layout (an index into
    /// `explicitLayouts`) or nil for a default layout.
    let pipelineLayouts: LookupMap<Name, Int?>
    /// The layouts C++ reaches through the pointers of `m_pipelineLayouts`.
    var explicitLayouts: [ExplicitPipelineLayout]
    var entryPointInformations: Reflection.EntryPointInformations
    var bufferLengthMap = SideTable<VariableID, VariableID>()
    var reverseBufferLengthMap = SideTable<VariableID, VariableID>()
    /// C++ `m_bufferLengthType`, renamed because `bufferLengthType()` keeps the C++ name.
    var cachedBufferLengthType: ExpressionID?
    /// C++ `m_bufferLengthReferenceType`.
    var cachedBufferLengthReferenceType: ExpressionID?
    var currentFunction: FunctionID?
    // DEV-05: every (group, binding) is an ordinary key; C++ keys on {group + 1, binding + 1}, which traps at UINT_MAX.
    var globalsUsingDynamicOffset = SmallKeyMap<BindingKey, DynamicOffsetSlot>()
    var doNotUnpack = IDSet<ExpressionID>()
    var combinedFunctionVariablesSize = CheckedUInt32(0)
    var isTopLevelExpression = true
    var shortCircuitedOperators: [ExpressionID] = []

    init(
        shaderModule: consuming ShaderModule,
        pipelineLayouts: LookupMap<Name, Int?>,
        explicitLayouts: [ExplicitPipelineLayout],
        entryPointInformations: Reflection.EntryPointInformations
    ) {
        self.shaderModule = shaderModule
        self.pipelineLayouts = pipelineLayouts
        self.explicitLayouts = explicitLayouts
        self.entryPointInformations = entryPointInformations
    }

    mutating func run() -> CompilationMessage? {
        if let error = collectGlobals() {
            return error
        }
        var index = 0
        while index < shaderModule.callGraph.entrypoints.count {
            let entryPoint = shaderModule.callGraph.entrypoints[index]
            let maybeError = visitEntryPoint(entryPoint)
            entryPointID &+= 1
            if let maybeError {
                return maybeError
            }
            index &+= 1
        }

        return nil
    }
}

// A (group, binding) pair as a SmallKeyMap key.
struct BindingKey: SmallKey {
    let smallKeyBits: UInt64

    init(_ binding: ResourceBinding) {
        smallKeyBits = UInt64(binding.group) &<< 32 | UInt64(binding.binding)
    }
}

extension TypeID: SmallKey {
    @_spi(Testing)
    public var smallKeyBits: UInt64 { UInt64(raw) }
}

/// C++ `rewriteGlobalVariables(shaderModule, pipelineLayouts, entryPointInformations)`.
///
/// `explicitLayouts` holds the layouts `pipelineLayouts` refers to; the pass records into them the minBindingSize of each buffer an
/// entry point uses, which prepare() writes back into the caller's layout.
@_spi(Testing)
public func rewriteGlobalVariables(
    _ shaderModule: inout ShaderModule,
    _ pipelineLayouts: LookupMap<Name, Int?>,
    _ explicitLayouts: inout [ExplicitPipelineLayout],
    _ entryPointInformations: inout Reflection.EntryPointInformations
) -> CompilationMessage? {
    var rewriter = RewriteGlobalVariables(
        shaderModule: shaderModule,
        pipelineLayouts: pipelineLayouts,
        explicitLayouts: explicitLayouts,
        entryPointInformations: entryPointInformations
    )
    let result = rewriter.run()
    explicitLayouts = rewriter.explicitLayouts
    entryPointInformations = rewriter.entryPointInformations
    shaderModule = rewriter.shaderModule
    return result
}

// MARK: - Swift-only: the pointers into the entry point information

extension RewriteGlobalVariables {
    /// `*m_entryPointInformation`, in place.
    mutating func modifyEntryPointInformation<R>(_ body: (inout Reflection.EntryPointInformation) -> R) -> R {
        guard let entryPointInformation else {
            wgslFatal("m_entryPointInformation is null outside visitEntryPoint", cppSite: "GlobalVariableRewriter.cpp:1151")
        }
        return entryPointInformations.modify(at: entryPointInformation, body)
    }

    /// `*m_generatedLayout`, in place.
    mutating func modifyGeneratedLayout<R>(_ body: (inout PipelineLayout) -> R) -> R {
        guard let generatedLayout else {
            wgslFatal("m_generatedLayout is null for an explicit layout", cppSite: "GlobalVariableRewriter.cpp:1723")
        }
        return entryPointInformations.modify(at: generatedLayout) { information in
            guard var layout = information.defaultLayout.take() else {
                wgslFatal("m_generatedLayout points at an absent default layout", cppSite: "GlobalVariableRewriter.cpp:1188")
            }
            let result = body(&layout)
            information.defaultLayout = layout
            return result
        }
    }
}

// GlobalVariableRewriter.cpp:1208 `auto usedGlobals = *maybeUsedGlobals;` copy-constructs every IndexMap, which re-lays out its
// buckets (sites B-D of the WTF iteration order).
extension RewriteGlobalVariables.UsedGlobals: WTFCopyConstructible {
    func wtfCopy() -> RewriteGlobalVariables.UsedGlobals {
        RewriteGlobalVariables.UsedGlobals(resources: resources.wtfCopy(), privateGlobals: privateGlobals.wtfCopy())
    }
}

@_spi(Testing)
extension CallGraph.Global: WTFCopyConstructible {}

// MARK: - Reflection::EntryPointInformation, as GlobalVariableRewriter fills it

/// C++ `WGSL::Reflection`: what prepare computes per entry point, before the driver converts it to the public
/// `EntryPointInformation`.
@_spi(Testing)
public enum Reflection {
    /// C++ `Reflection::WorkgroupSize`: the expressions of the entry point's `@workgroup_size`.
    @_spi(Testing)
    public struct WorkgroupSize: Hashable, Sendable {
        @_spi(Testing)
        public let width: ExpressionID

        @_spi(Testing)
        public let height: ExpressionID?

        @_spi(Testing)
        public let depth: ExpressionID?
    }

    /// C++ `Variant<Vertex, Fragment, Compute>`; the default-constructed Variant is `.vertex(invariantIsPresent: false)`.
    @_spi(Testing)
    public enum TypedEntryPoint: Hashable, Sendable {
        case vertex(invariantIsPresent: Bool)
        case fragment
        case compute(WorkgroupSize)
    }

    /// C++ `Reflection::SpecializationConstant`, with its key in the C++ map.
    @_spi(Testing)
    public struct SpecializationConstant: Hashable, Sendable {
        /// The override's `@id` in decimal, else its source name.
        @_spi(Testing)
        public let key: Name

        @_spi(Testing)
        public let mangledName: Symbol

        @_spi(Testing)
        public let type: SpecializationConstantType

        @_spi(Testing)
        public let defaultValue: ExpressionID?
    }

    /// C++ `Reflection::EntryPointInformation`.
    @_spi(Testing)
    public struct EntryPointInformation: Sendable {
        @_spi(Testing)
        public internal(set) var originalName: Name

        @_spi(Testing)
        public internal(set) var mangledName: Symbol

        /// The entry point's stage, which the public `EntryPointInformation` reports.
        @_spi(Testing)
        public let stage: ShaderStage

        @_spi(Testing)
        public internal(set) var defaultLayout: PipelineLayout?

        /// C++ `HashMap<String, SpecializationConstant>`, in insertion order.
        @_spi(Testing)
        public private(set) var specializationConstants: [SpecializationConstant] = []

        @_spi(Testing)
        public internal(set) var typedEntryPoint = TypedEntryPoint.vertex(invariantIsPresent: false)

        @_spi(Testing)
        public internal(set) var sizeForWorkgroupVariables: UInt64 = 0

        @_spi(Testing)
        public internal(set) var bindingCount: UInt64 = 0

        @_spi(Testing)
        public internal(set) var usesInvariant = false

        /// Set when the rewrite of the entry point succeeds: the proof that its workgroup variables are zeroed.
        @_spi(Testing)
        public internal(set) var initialized: EntryPointInitialized?

        private var specializationConstantKeys = LookupSet<Name>()

        init(originalName: Name, mangledName: Symbol, stage: ShaderStage) {
            self.originalName = originalName
            self.mangledName = mangledName
            self.stage = stage
        }

        /// `specializationConstants.add(key, constant)`: the first constant of a key wins; returns isNewEntry.
        @discardableResult
        mutating func addSpecializationConstant(_ constant: SpecializationConstant) -> Bool {
            guard specializationConstantKeys.add(constant.key) else {
                return false
            }
            specializationConstants.append(constant)
            return true
        }
    }

    /// C++ `HashMap<String, Reflection::EntryPointInformation>` (`PrepareResult::entryPoints`), in insertion order, which is the
    /// call graph's entry point order.
    @_spi(Testing)
    public struct EntryPointInformations: Sendable {
        @_spi(Testing)
        public private(set) var entries: [EntryPointInformation] = []

        private var indices = LookupMap<Name, Int>()

        /// The slot of each `__dynamicOffset` call insertMaterializations built.
        ///
        /// Not in C++, whose writer prints the call's u32 argument. Its IDs are the prepare scope's, and it lives as long as that
        /// scope: the prepared module drops it when generate or abandon rolls the scope back.
        private var dynamicOffsetSlots = SideTable<ExpressionID, DynamicOffsetSlot>()

        @_spi(Testing)
        public init() {}

        /// `find(name)->value`.
        @_spi(Testing)
        public func find(_ name: Name) -> EntryPointInformation? {
            guard let index = indices.find(name) else {
                return nil
            }
            return entries[index]
        }

        /// HashMap::add keyed by `information.originalName`: the index of the new entry, or nil (and no change) when the name is
        /// present.
        mutating func add(_ information: EntryPointInformation) -> Int? {
            guard indices.add(information.originalName, entries.count) else {
                return nil
            }
            entries.append(information)
            return entries.count &- 1
        }

        mutating func modify<R>(at index: Int, _ body: (inout EntryPointInformation) -> R) -> R {
            body(&entries[index])
        }

        mutating func addDynamicOffsetCall(_ call: ExpressionID, _ slot: DynamicOffsetSlot) {
            dynamicOffsetSlots.add(call, slot)
        }

        func dynamicOffsetSlot(of call: ExpressionID) -> DynamicOffsetSlot? {
            dynamicOffsetSlots.find(call)
        }
    }
}

// MARK: - Testing hooks

/// rewriteGlobalVariables that also returns C++ `m_lengthParameters` as the pass left it: each function with an entry, in declaration
/// order, with its names in order (the callee side-effect-sequence test).
@_spi(Testing)
public func rewriteGlobalVariablesForTesting(
    _ shaderModule: inout ShaderModule,
    _ pipelineLayouts: LookupMap<Name, Int?>,
    _ explicitLayouts: inout [ExplicitPipelineLayout],
    _ entryPointInformations: inout Reflection.EntryPointInformations,
    lengthParameters: inout [(function: FunctionID, names: [Symbol])]
) -> CompilationMessage? {
    var rewriter = RewriteGlobalVariables(
        shaderModule: shaderModule,
        pipelineLayouts: pipelineLayouts,
        explicitLayouts: explicitLayouts,
        entryPointInformations: entryPointInformations
    )
    let result = rewriter.run()
    lengthParameters = []
    var declarations = rewriter.shaderModule.cursor(rewriter.shaderModule.declarations)
    while let declaration = rewriter.shaderModule.next(&declarations) {
        guard case .function(let function) = declaration, let functionLengthParameters = rewriter.lengthParameters.find(function) else {
            continue
        }
        var names: [Symbol] = []
        var iterator = functionLengthParameters.makeIterator()
        while let name = iterator.next() {
            names.append(name)
        }
        lengthParameters.append((function, names))
    }
    explicitLayouts = rewriter.explicitLayouts
    entryPointInformations = rewriter.entryPointInformations
    shaderModule = rewriter.shaderModule
    return result
}
