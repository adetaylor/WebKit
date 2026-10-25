// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

@_spi(Testing)
public struct Parser: ~Copyable {
    @_spi(Testing)
    public internal(set) var shaderModule: ShaderModule
    let lexer: Lexer
    @_spi(Testing)
    public internal(set) var tokens: [Token]
    var warnings: [CompilationMessage] = []
    // "unrecognized diagnostic rule ", widened once per parse: a module can have a warning for every directive.
    var unrecognizedDiagnosticRule = MessageText(codeUnits: [])
    // The symbol of a recent repeated identifier for each slot of a cheap mix of its length and some code units:
    // most identifiers repeat, and a hit, whose text `intern(_: Token)` compares, skips the hash. Text seen once is not
    // cached, so that unique names do not evict repeated ones; crafted text can only make lookups miss.
    var identifierCache: ContiguousArray<Symbol?> = []
    var internedTokenCount = 0
    // parseStructure's member list and duplicate check, kept from one structure to the next.
    var structureMembers: [StructureMemberID] = []
    var seenStructureMembers = SymbolMap<Void>()
    @_spi(Testing)
    public internal(set) var currentTokenIndex = 0
    var parseDepth = ParseDepth()
    var compositeTypeDepth = CompositeTypeNesting()
    @_spi(Testing)
    public internal(set) var current: Token
    var currentPosition: SourcePosition

    @_spi(Testing)
    public init(_ shaderModule: consuming ShaderModule, _ lexer: consuming Lexer) {
        self.shaderModule = shaderModule
        tokens = lexer.lex()
        self.lexer = lexer
        current = tokens[0]
        currentPosition = SourcePosition(line: current.span.line, lineOffset: current.span.lineOffset, offset: current.span.offset)
        reserveCapacityForTokens()
    }

    @_spi(Testing)
    public mutating func takeWarnings() -> [CompilationMessage] {
        var warnings: [CompilationMessage] = []
        swap(&warnings, &self.warnings)
        return warnings
    }

    /// Gives the module back (C++ callers keep their `ShaderModule&`).
    @_spi(Testing)
    public consuming func takeShaderModule() -> ShaderModule {
        shaderModule
    }
}

private struct TemplateTypes {
    let types: [TokenType]

    func includes(_ tokenType: TokenType) -> Bool {
        var index = 0
        while index < types.count {
            if types[index] == tokenType {
                return true
            }
            index += 1
        }
        return false
    }

    func appendNameTo(_ builder: inout MessageText) {
        var index = 0
        while index < types.count - 1 {
            builder.append("\(toString(types[index])), ")
            index += 1
        }
        builder.append("\(toString(types[index]))")
    }
}

// The C++ macros:
//   START_PARSE()                     let startOfElementPosition = currentPosition
//   CURRENT_SOURCE_SPAN()             SourceSpan(startOfElementPosition, currentPosition)
//   MAKE_ARENA_NODE / RETURN_ARENA_NODE  shaderModule.construct…(span: SourceSpan(startOfElementPosition, currentPosition), …)
//   FAIL(message)                     throw fail(message, startOfElementPosition)
//   PARSE(name, X, …) / PARSE_MOVE    let name = try parseX(…) / name = try parseX(…)
//   CONSUME_TYPE(_NAMED)(name, X)     [let name =] try consumeType(.x, startOfElementPosition)
//   CONSUME_TYPES_NAMED(name, X, …)   let name = try consumeTypes([.x, …], startOfElementPosition)
//   CHECK_RECURSION()                 let parseDepthLevel = try parseDepth.enter(SourceSpan(startOfElementPosition, currentPosition))
//                                     defer { parseDepth.leave(parseDepthLevel) }
//   CHECK_COMPOSITE_TYPE_NESTING()    the same with compositeTypeDepth
extension Parser {
    mutating func fail(_ message: MessageText, _ startOfElementPosition: SourcePosition) -> CompilationMessage {
        CompilationMessage(text: message, span: SourceSpan(startOfElementPosition, currentPosition))
    }

    @discardableResult
    mutating func consumeType(_ type: TokenType, _ startOfElementPosition: SourcePosition) throws(CompilationMessage) -> Token {
        switch consumeType(type) {
        case .success(let token):
            return token
        case .failure(let error):
            throw fail("Expected a \(toString(type)), but got a \(toString(error))", startOfElementPosition)
        }
    }

    mutating func consumeTypes(_ types: [TokenType], _ startOfElementPosition: SourcePosition) throws(CompilationMessage) -> Token {
        switch consumeTypes(types) {
        case .success(let token):
            return token
        case .failure(let error):
            var builder: MessageText = "Expected one of ["
            TemplateTypes(types: types).appendNameTo(&builder)
            builder.append("], but got a \(toString(error))")
            throw fail(builder, startOfElementPosition)
        }
    }
}

extension Parser {
    @_spi(Testing)
    public mutating func splitMinusMinus() {
        assert(currentTokenIndex + 1 < tokens.count)
        assert(tokens[currentTokenIndex + 1].type == .placeholder)
        current.type = .minus
        tokens[currentTokenIndex + 1].type = .minus
    }

    @_spi(Testing)
    public mutating func canBeginUnaryExpression(_ token: Token) -> Bool {
        switch token.type {
        case .and, .tilde, .star, .minus, .bang:
            return true
        case .minusMinus:
            splitMinusMinus()
            return true
        default: // lint-exempt(L-ENUM-1): every other token type, as the C++ default
            return false
        }
    }
}

func canContinueMultiplicativeExpression(_ token: Token) -> Bool {
    switch token.type {
    case .modulo, .slash, .star:
        true
    default: // lint-exempt(L-ENUM-1): every other token type, as the C++ default
        false
    }
}

extension Parser {
    @_spi(Testing)
    public mutating func canContinueAdditiveExpression(_ token: Token) -> Bool {
        switch token.type {
        case .minus, .plus:
            return true
        case .minusMinus:
            splitMinusMinus()
            return true
        default: // lint-exempt(L-ENUM-1): every other token type, as the C++ default
            return canContinueMultiplicativeExpression(token)
        }
    }
}

func canContinueBitwiseExpression(_ token: Token) -> Bool {
    switch token.type {
    case .and, .or, .xor:
        true
    default: // lint-exempt(L-ENUM-1): every other token type, as the C++ default
        false
    }
}

func canContinueRelationalExpression(_ token: Token) -> Bool {
    switch token.type {
    case .gt, .gtEq, .lt, .ltEq, .eqEq, .bangEq:
        true
    default: // lint-exempt(L-ENUM-1): every other token type, as the C++ default
        false
    }
}

func canContinueShortCircuitAndExpression(_ token: Token) -> Bool {
    token.type == .andAnd
}

func canContinueShortCircuitOrExpression(_ token: Token) -> Bool {
    token.type == .orOr
}

func canContinueCompoundAssignmentStatement(_ token: Token) -> Bool {
    switch token.type {
    case .plusEq, .minusEq, .starEq, .slashEq, .moduloEq, .andEq, .orEq, .xorEq, .gtGtEq, .ltLtEq:
        true
    default: // lint-exempt(L-ENUM-1): every other token type, as the C++ default
        false
    }
}

func toBinaryOperation(_ token: Token) -> BinaryOperation {
    switch token.type {
    case .and, .andEq:
        .and
    case .andAnd:
        .shortCircuitAnd
    case .bangEq:
        .notEqual
    case .eqEq:
        .equal
    case .gt:
        .greaterThan
    case .gtEq:
        .greaterEqual
    case .gtGt, .gtGtEq:
        .rightShift
    case .lt:
        .lessThan
    case .ltEq:
        .lessEqual
    case .ltLt, .ltLtEq:
        .leftShift
    case .minus, .minusEq:
        .subtract
    case .modulo, .moduloEq:
        .modulo
    case .or, .orEq:
        .or
    case .orOr:
        .shortCircuitOr
    case .plus, .plusEq:
        .add
    case .slash, .slashEq:
        .divide
    case .star, .starEq:
        .multiply
    case .xor, .xorEq:
        .xor
    default: // lint-exempt(L-ENUM-1): every other token type, as the C++ default (RELEASE_ASSERT_NOT_REACHED)
        wgslFatal("not a binary operator token", cppSite: "Parser.cpp:308")
    }
}

func toUnaryOperation(_ token: Token) -> UnaryOperation {
    switch token.type {
    case .and:
        .addressOf
    case .tilde:
        .complement
    case .star:
        .dereference
    case .minus:
        .negate
    case .bang:
        .not

    default: // lint-exempt(L-ENUM-1): every other token type, as the C++ default (RELEASE_ASSERT_NOT_REACHED)
        wgslFatal("not a unary operator token", cppSite: "Parser.cpp:327")
    }
}

/// One `Lexer` serves both representations of the source (C++ `parse<Latin1Character>` and `parse<char16_t>`).
@_spi(Testing)
public func parse(_ shaderModule: inout ShaderModule) -> FailedCheck? {
    let lexer = Lexer(shaderModule.source, identifierCharacterClasses: shaderModule.configuration.identifierCharacterClasses)
    var parser = Parser(shaderModule, lexer)
    var result: CompilationMessage?
    do throws(CompilationMessage) {
        try parser.parseShader()
    } catch {
        result = error
    }
    var errors: [CompilationMessage] = []
    let warnings = parser.takeWarnings()
    shaderModule = parser.takeShaderModule()
    if let result {
        errors.append(result)
    }
    if !errors.isEmpty || !warnings.isEmpty {
        return FailedCheck(errors: errors, warnings: warnings)
    }
    return nil
}

extension Parser {
    mutating func consumeType(_ type: TokenType) -> Result<Token, TokenType> {
        if current.type == type {
            let result: Result<Token, TokenType> = .success(current)
            consume()
            return result
        }
        return .failure(current.type)
    }

    mutating func consumeTypes(_ types: [TokenType]) -> Result<Token, TokenType> {
        let token = current
        if TemplateTypes(types: types).includes(token.type) {
            consume()
            return .success(token)
        }
        return .failure(token.type)
    }

    @_spi(Testing)
    public mutating func consume() {
        repeat {
            currentTokenIndex += 1
            current = tokens[currentTokenIndex]
            currentPosition = SourcePosition(line: current.span.line, lineOffset: current.span.lineOffset, offset: current.span.offset)
        } while current.type == .placeholder
    }

    @_spi(Testing)
    public mutating func parseShader() throws(CompilationMessage) {
        let startOfElementPosition = currentPosition
        disambiguateTemplates()
        directives: while current.type != .endOfFile {
            switch current.type {
            case .keywordEnable:
                try parseEnableDirective()
            case .keywordRequires:
                try parseRequireDirective()
            case .keywordDiagnostic:
                consume()
                let diagnostic = try parseDiagnostic()
                try consumeType(.semicolon, startOfElementPosition)
                if let diagnostic {
                    let directive = shaderModule.construct(
                        span: SourceSpan(startOfElementPosition, currentPosition),
                        .diagnosticDirective(DiagnosticDirective(diagnostic: diagnostic))
                    )
                    shaderModule.append(shaderModule.directives, directive)
                }
            default: // lint-exempt(L-ENUM-1): every other token type starts the declarations, as the C++ default
                break directives
            }
        }

        while current.type != .endOfFile {
            if current.type == .semicolon {
                consume()
                continue
            }

            let declaration = try parseDeclaration()
            shaderModule.append(shaderModule.declarations, declaration)
        }
    }

    mutating func parseEnableDirective() throws(CompilationMessage) {
        let startOfElementPosition = currentPosition
        try consumeType(.keywordEnable, startOfElementPosition)
        repeat {
            let identifier = try consumeType(.identifier, startOfElementPosition)
            guard let enabledExtension = parseExtension(codeUnits(of: identifier)) else {
                throw fail("Expected 'clip_distances', 'f16', 'primitive_index', or 'subgroups'", startOfElementPosition)
            }
            shaderModule.enableExtension(enabledExtension)

            if current.type != .comma {
                break
            }
            try consumeType(.comma, startOfElementPosition)
        } while current.type != .semicolon
        try consumeType(.semicolon, startOfElementPosition)
    }

    mutating func parseRequireDirective() throws(CompilationMessage) {
        let startOfElementPosition = currentPosition
        try consumeType(.keywordRequires, startOfElementPosition)
        repeat {
            let identifier = try consumeType(.identifier, startOfElementPosition)
            guard let languageFeature = parseLanguageFeature(codeUnits(of: identifier)) else {
                throw fail(
                    "Expected 'clip_distances', 'readonly_and_readwrite_storage_textures', 'packed_4x8_integer_dot_product', 'unrestricted_pointer_parameters', 'texture_formats_tier1', 'subgroup_id', 'subgroup_uniformity', or 'pointer_composite_access'",
                    startOfElementPosition
                )
            }
            shaderModule.addRequiredFeature(languageFeature)

            if current.type != .comma {
                break
            }
            try consumeType(.comma, startOfElementPosition)
        } while current.type != .semicolon
        try consumeType(.semicolon, startOfElementPosition)
    }

    @_spi(Testing)
    public mutating func maybeSplitToken(_ index: Int) {
        let replacement: TokenType
        switch tokens[index + 0].type {
        case .gtGt:
            replacement = .gt
        case .gtEq:
            replacement = .equal
        case .gtGtEq:
            replacement = .gtEq
        default: // lint-exempt(L-ENUM-1): every other token type is not splittable, as the C++ default
            return
        }

        assert(tokens[index + 1].type == .placeholder)
        tokens[index + 0].type = .gt
        tokens[index + 1].type = replacement
    }

    @_spi(Testing)
    public mutating func disambiguateTemplates() {
        // Reference algorithm: https://github.com/gpuweb/gpuweb/issues/3770
        let count = tokens.count

        // The current expression nesting depth.
        // Each '(', '[' increments the depth.
        // Each ')', ']' decrements the depth.
        var expressionDepth: UInt32 = 0

        // A stack of '<' tokens.
        // Used to pair '<' and '>' tokens at the same expression depth.
        struct StackEntry {
            let token: Int // The index of the opening '<' token
            let expressionDepth: UInt32 // The value of 'expr_depth' for the opening '<'
        }
        var stack: [StackEntry] = []

        var i = 0
        while i < count - 1 {
            switch tokens[i].type {
            case .identifier, .keywordVar:
                // Potential start to a template argument list.
                // Push the address-of '<' to the stack, along with the current nesting expr_depth.
                let next = tokens[i + 1]
                if next.type == .lt {
                    if stack.capacity == 0 {
                        stack.reserveCapacity(16)
                    }
                    stack.append(StackEntry(token: i + 1, expressionDepth: expressionDepth))
                    i += 1
                }

            case .gt, .gtGt, .gtEq, .gtGtEq:
                // Note: Depending on your lexer - you may need split '>>', '>=', '>>='.
                // MaybeSplitToken() splits the left-most '>' from the token, updating 'tokens'
                // and returning the first token ('>').
                // If the token is not splittable, then MaybeSplitToken() simply returns 'token'.
                // As 'tokens' is updated with the split tokens, '>>=' may split to ['>', '>='], then
                // on the next iteration again to ['>', '='].
                if let last = stack.last, last.expressionDepth == expressionDepth {
                    maybeSplitToken(i)
                    let opening = stack.removeLast()
                    tokens[opening.token].type = .templateArgsLeft
                    tokens[i].type = .templateArgsRight
                }

            case .parenLeft, .bracketLeft:
                // Entering a nested expression.
                expressionDepth &+= 1

            case .parenRight, .bracketRight:
                // Exiting a nested expression
                // Pop the stack until we return to the current expression expr_depth
                while let last = stack.last, last.expressionDepth == expressionDepth {
                    stack.removeLast()
                }
                if expressionDepth > 0 {
                    expressionDepth -= 1
                }

            case .semicolon, .braceLeft, .equal, .colon:
                // Expression terminating tokens (non-exhaustive).
                // No opening template list can continue across these tokens, so clear
                // the stack and expression depth.
                expressionDepth = 0
                if !stack.isEmpty {
                    stack.removeAll(keepingCapacity: true)
                }

            case .orOr, .andAnd:
                // Exception tokens for template argument lists.
                // Treat 'a < b || c > d' as a logical binary operator of two comparison operators
                // instead of a single template argument 'b||c'.
                // Requires parentheses around 'b||c' to parse as a template argument list.
                while let last = stack.last, last.expressionDepth == expressionDepth {
                    stack.removeLast()
                }

            default: // lint-exempt(L-ENUM-1): every other token type leaves the state unchanged, as the C++ default
                break
            }
            i += 1
        }
    }

    mutating func parseIdentifier() throws(CompilationMessage) -> Identifier {
        let startOfElementPosition = currentPosition

        let name = try consumeType(.identifier, startOfElementPosition)

        return Identifier.makeWithSpan(SourceSpan(startOfElementPosition, currentPosition), intern(name))
    }

    mutating func parseDeclaration() throws(CompilationMessage) -> Declaration {
        let startOfElementPosition = currentPosition

        switch current.type {
        case .keywordConst:
            let variable = try parseVariable()
            try consumeType(.semicolon, startOfElementPosition)
            return .variable(variable)
        case .keywordAlias:
            let alias = try parseTypeAlias()
            return .typeAlias(alias)
        case .keywordConstAssert:
            let constAssert = try parseConstAssert()
            return .constAssert(constAssert)
        case .keywordStruct:
            let structure = try parseStructure()
            return .structure(structure)
        default: // lint-exempt(L-ENUM-1): every other token type goes on to the attributed declarations, as the C++ default
            break
        }

        let attributes = try parseAttributes()

        switch current.type {
        case .keywordOverride, .keywordVar:
            let variable = try parseVariableWithAttributes(attributes)
            try consumeType(.semicolon, startOfElementPosition)
            return .variable(variable)
        case .keywordFn:
            let function = try parseFunction(attributes)
            return .function(function)
        default: // lint-exempt(L-ENUM-1): every other token type is an error, as the C++ default
            throw fail("Trying to parse a GlobalDecl, expected 'const', 'fn', 'override', 'struct' or 'var'.", startOfElementPosition)
        }
    }

    mutating func parseConstAssert() throws(CompilationMessage) -> ConstAssertID {
        let startOfElementPosition = currentPosition
        try consumeType(.keywordConstAssert, startOfElementPosition)
        let test = try parseExpression()
        try consumeType(.semicolon, startOfElementPosition)
        return shaderModule.constructConstAssert(span: SourceSpan(startOfElementPosition, currentPosition), test: test)
    }

    mutating func parseAttributes() throws(CompilationMessage) -> [AttributeID] {
        var attributes: [AttributeID] = []

        while current.type == .attribute {
            let attribute = try parseAttribute()
            if let attribute {
                attributes.append(attribute)
            }
        }

        return attributes
    }
}

// MARK: - Identifier text (C++ `Token::ident` and `AST::Identifier` are `String`s)

extension Parser {
    /// The identifier token's text as a symbol: the C++ `AST::Identifier` made from `token.ident`.
    mutating func intern(_ token: Token) -> Symbol {
        let range = token.identifierRange
        guard !range.isEmpty else {
            return shaderModule.symbols.intern(shaderModule.source, range)
        }
        if identifierCache.isEmpty {
            // A short module does not pay for the cache.
            internedTokenCount &+= 1
            guard internedTokenCount > Self.identifierCacheSize / 4 else {
                return shaderModule.symbols.intern(shaderModule.source, range)
            }
            identifierCache = ContiguousArray(repeatElement(nil, count: Self.identifierCacheSize))
        }
        // The first, middle and last two code units tell apart the usual repeated names, such as vec2f and vec3f.
        let first = Int(shaderModule.source.codeUnit(at: range.lowerBound))
        let middle = Int(shaderModule.source.codeUnit(at: range.lowerBound + range.count / 2))
        let beforeLast = Int(shaderModule.source.codeUnit(at: range.upperBound - (range.count > 1 ? 2 : 1)))
        let last = Int(shaderModule.source.codeUnit(at: range.upperBound - 1))
        let mix = range.count &* 0x9E &+ first &* 0x1F &+ middle &* 0x0D &+ beforeLast &* 0x07 &+ last
        let slot = (mix ^ mix &>> 7) & (Self.identifierCacheSize - 1)
        if let symbol = identifierCache[slot], shaderModule.symbols.spells(symbol, shaderModule.source, range) {
            return symbol
        }
        let count = shaderModule.symbols.count
        let symbol = shaderModule.symbols.intern(shaderModule.source, range)
        if shaderModule.symbols.count == count {
            identifierCache[slot] = symbol
        }
        return symbol
    }

    private static var identifierCacheSize: Int { 128 }

    /// C++ `token.ident` passed to an `ENUM_DECLARE` parser (`parseExtension(token.ident)`).
    mutating func codeUnits(of token: Token) -> ContiguousArray<UInt16> {
        var units = ContiguousArray<UInt16>()
        shaderModule.source.appendCodeUnits(token.identifierRange, to: &units)
        return units
    }

    /// C++ `identifier` passed to an `ENUM_DECLARE` parser (`parseBuiltin(name)`).
    mutating func codeUnits(of identifier: Identifier) -> ArraySlice<UInt16> {
        shaderModule.symbols.codeUnitsView(of: identifier.symbol)
    }

    /// C++ `token.ident == "text"_s` for an ASCII literal.
    mutating func equal(_ token: Token, _ text: String) -> Bool {
        let range = token.identifierRange
        guard range.count == text.utf8.count else {
            return false
        }
        var index = range.lowerBound
        var units = text.utf8.makeIterator()
        while let unit = units.next() {
            guard shaderModule.source.codeUnit(at: index) == UInt16(unit) else {
                return false
            }
            index += 1
        }
        return true
    }

    /// C++ `identifier == "text"_s` for an ASCII literal.
    mutating func equal(_ identifier: Identifier, _ text: String) -> Bool {
        guard shaderModule.symbols.length(of: identifier.symbol) == text.utf8.count else {
            return false
        }
        var index = 0
        var units = text.utf8.makeIterator()
        while let unit = units.next() {
            guard shaderModule.symbols.codeUnit(of: identifier.symbol, at: index) == UInt16(unit) else {
                return false
            }
            index += 1
        }
        return true
    }
}

// MARK: - Arena reservation

extension Parser {
    // Reserve from the token counts: upper bounds of what parsing creates (`TokenCounts`; each identifier token gives at
    // most two identifier slots), plus 10% and a few nodes of headroom for the later passes. A module of 2^21 tokens or
    // more reserves from its token count: an expression per token, a statement per two.
    // Lists are estimated, not bounded: about one per four tokens, and an element per two (each element consumed a token).
    private mutating func reserveCapacityForTokens() {
        var identifierTokenCount = tokens.count
        var expressionCount = tokens.count
        var statementCount = tokens.count / 2
        if tokens.count < TokenCounts.exactTokenLimit {
            let counts = lexer.tokenCounts
            identifierTokenCount = counts.identifiers
            expressionCount = counts.identifiers + counts.otherExpressions
            statementCount = counts.statements
        }
        let identifierCount = 2 * identifierTokenCount
        shaderModule.reserveCapacity(
            expressions: expressionCount + expressionCount / 10 + 8,
            statements: statementCount + statementCount / 10 + 8,
            identifiers: identifierCount + identifierCount / 10,
            lists: tokens.count / 4 + 8,
            listElements: tokens.count / 2 + 8
        )
    }
}

/// The counts of a token sequence that bound the expressions and statements parsing it creates, which `Lexer.lex()` adds
/// up as it makes the tokens.
///
/// Each expression consumes a token of its own: an identifier, a literal, an operator (`--` can be two negations), the `(`
/// of a call or the `[` of an index access. Each statement consumes a `;`, a `{`, an `if`, a `for` or a `while` of its
/// own. The counts are packed in one word, 21 bits for the identifier tokens, 22 for the other expressions and 21 for the
/// statements, so they are exact below `exactTokenLimit` tokens.
struct TokenCounts {
    static var exactTokenLimit: Int { 1 << 21 }

    private var packed: UInt64 = 0

    var identifiers: Int { Int(packed & 0x1F_FFFF) }
    var otherExpressions: Int { Int(packed >> 21 & 0x3F_FFFF) }
    var statements: Int { Int(packed >> 43) }

    /// `weight(_:)` by raw value: a table load per token, where a switch in `lex()` would merge with its own.
    static let weights: [UInt64] = {
        let types = TokenType.allCases
        var weights = Array(repeatElement(UInt64(0), count: types.count))
        var index = 0
        while index < types.count {
            weights[Int(types[index].rawValue)] = weight(types[index])
            index += 1
        }
        return weights
    }()

    @inline(__always)
    mutating func add(_ type: TokenType, _ weights: [UInt64]) {
        packed &+= weights[Int(type.rawValue)]
    }

    private static func weight(_ type: TokenType) -> UInt64 {
        switch type {
        case .identifier:
            1
        case .abstractFloatLiteral, .integerLiteral, .integerLiteralSigned, .integerLiteralUnsigned, .floatLiteral, .halfLiteral,
            .keywordFalse, .keywordTrue, .and, .andAnd, .bang, .bangEq, .bracketLeft, .eqEq, .gt, .gtEq, .gtGt, .lt, .ltEq, .ltLt,
            .minus, .modulo, .or, .orOr, .parenLeft, .plus, .slash, .star, .tilde, .xor:
            1 << 21
        case .minusMinus:
            2 << 21
        case .braceLeft, .keywordFor, .keywordIf, .keywordWhile, .semicolon:
            1 << 43
        case .invalid, .endOfFile, .reservedWord, .keywordAlias, .keywordBreak, .keywordCase, .keywordConst, .keywordConstAssert,
            .keywordContinue, .keywordContinuing, .keywordDefault, .keywordDiagnostic, .keywordDiscard, .keywordElse,
            .keywordEnable, .keywordFn, .keywordLet, .keywordLoop, .keywordOverride, .keywordRequires, .keywordReturn,
            .keywordStruct, .keywordSwitch, .keywordVar, .andEq, .arrow, .attribute, .braceRight, .bracketRight, .colon, .comma,
            .equal, .gtGtEq, .ltLtEq, .minusEq, .moduloEq, .orEq, .parenRight, .period, .plusPlus, .plusEq, .slashEq, .starEq,
            .underbar, .xorEq, .placeholder, .templateArgsLeft, .templateArgsRight:
            0
        }
    }
}

// `Parser.consumeType` returns the C++ `std::expected<Token, TokenType>` as a `Result`.
extension TokenType: Error {}
