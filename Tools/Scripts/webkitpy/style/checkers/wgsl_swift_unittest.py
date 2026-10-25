# Copyright (C) 2026 Apple Inc. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1.  Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
# 2.  Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

"""Unit tests for wgsl_swift.py."""

import os
import re
import shutil
import tempfile
import unittest

from unittest.mock import patch

from webkitpy.style.checker import CheckerDispatcher
from webkitpy.style.checkers.cpp import CppChecker
from webkitpy.style.checkers.swift import SwiftChecker
from webkitpy.style.checkers.wgsl_swift import (
    FUZZ_ENTRY,
    HAVE_WGSL_COMPILER_CATEGORY,
    RULES,
    Context,
    SwiftFile,
    WebGPUHeaderChecker,
    WGSLSwiftChecker,
    is_webgpu_header_path,
    is_wgsl_swift_path,
    lint,
    split_path,
)
from webkitpy.style.error_handlers import DefaultStyleErrorHandler


class Sample(object):
    """Swift source linted as the file at path, next to the context files.

    A negative sample marks each line with a finding with `expect(RULE)` in a comment."""

    def __init__(self, path, text, context=()):
        self.path = path
        self.text = text[1:] if text.startswith('\n') else text
        self.context = context


# Stand-ins for the files the cross-file rules read: L-VISIT-1 takes the hook signatures from the two visitor files,
# L-MSL-3 the reserved spellings from `enum ReservedName`.
AST_VISITOR = ('Source/WebGPU/WGSL/AST/ASTVisitor.swift', '''
public protocol ASTVisitor: ~Copyable {
    var shaderModule: ShaderModule { get set }
    var expectedError: CompilationMessage? { get set }
    var hasError: Bool { get set }

    mutating func visit(_ expression: ExpressionID)
    mutating func visit(_ expression: BinaryExpression, _ id: ExpressionID)
    mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID)
    mutating func visit(_ expression: UnaryExpression, _ id: ExpressionID)
    mutating func visit(_ statement: CompoundStatement, _ id: StatementID)
}

extension ASTVisitor where Self: ~Copyable {
    public mutating func visitChildren(_ expression: BinaryExpression, _ id: ExpressionID) {}
    public mutating func checkErrorAndVisit(_ expression: ExpressionID) {}
}
''')

AST_SCOPED_VISITOR = ('Source/WebGPU/WGSL/AST/ASTScopedVisitor.swift', '''
public protocol ASTScopedVisitor: ASTVisitor, ~Copyable {
    associatedtype ContextValue
    var context: ContextProvider<ContextValue> { get set }
}

extension ASTScopedVisitor where Self: ~Copyable {
    public mutating func readVariable(_ name: IdentifierID) -> ContextValue? { nil }
    public mutating func scopedVisit(_ function: FunctionID) {}
    public mutating func scopedVisit(_ statement: CompoundStatement, _ id: StatementID) {}
}
''')

AST_IDENTIFIER = ('Source/WebGPU/WGSL/AST/ASTIdentifier.swift', r'''
enum ReservedName {
    case arrayLength
    case dynamicOffsets

    var spelling: StaticString {
        switch self {
        case .arrayLength: "__ArrayLength"
        case .dynamicOffsets: "__DynamicOffsets"
        }
    }
}

extension ReservedName {
    func render(_ name: String, _ depth: UInt32) -> String {
        switch self {
        case .arrayLength: "__\(name)_ArrayLength"
        case .dynamicOffsets: "__i\(depth)"
        }
    }
}
''')

NEGATIVE_SAMPLES = [
    Sample('Source/WebGPU/WGSL/Support/Half.swift', r'''
func badHalf(_ h: Float16) -> Float { Float(h) }  // expect(L-BD-1)
func badInline() -> InlineArray<4, Int> { [1, 2, 3, 4] }  // expect(L-BD-1)
func badSpan(_ a: [Int]) -> Int { a.span.count }  // expect(L-BD-1)
func badRawSpan(_ s: RawSpan) {}  // expect(L-BD-1)
func badUTF8(_ s: String) -> Bool { s.utf8Span.isEmpty }  // expect(L-BD-1)
func goodSourceSpan(_ m: CompilationMessage) -> SourceSpan { m.span }
'''),
    Sample('Source/WebGPU/WGSL/ConstantFunctions.swift', r'''
func badMax(_ a: Double, _ b: Double) -> Double { Swift.max(a, b) }  // expect(L-CE-1)
func badMin(_ a: Float, _ b: Float) -> Float { min(a, b) }  // expect(L-CE-1)
func badMinimum(_ a: Double, _ b: Double) -> Double { Double.minimum(a, b) }  // expect(L-CE-1)
func badClamp(_ a: Double) -> Double { a.clamped(to: 0...1) }  // expect(L-CE-1)
func goodMin(_ values: [Double]) -> Double? { values.min() }
func goodCxx(_ a: Double, _ b: Double) -> Double { cxxMin(a, b) }
func badMultiLine(_ a: Float, _ b: Float) -> Float {
    max(  // expect(L-CE-1)
        a,
        b
    )
}
'''),
    Sample('Source/WebGPU/WGSL/Support/ConstEvalArithmetic.swift', r'''
func badConvert(_ f: Float) -> Int32 { Int32(f) }  // expect(L-CE-2)
func badRounded(_ d: Double) -> Int { Int(d.rounded(.down)) }  // expect(L-CE-2)
func goodConvert(_ f: Float) -> Int32? { Int32(exactly: f) }
func goodWiden(_ i: Int16) -> Int32 { Int32(i) }
func goodShadow(_ value: Double, _ x: Int8) -> Int32 {
    let value = x
    return Int32(value)
}
'''),
    Sample('Source/WebGPU/WGSL/ConstantFunctions+Numeric.swift', r'''
func badRem(_ a: Double) -> Double { a.remainder(dividingBy: 3) }  // expect(L-CE-3)
func goodFmod(_ a: Double) -> Double { a.truncatingRemainder(dividingBy: 3) }
'''),
    Sample('Source/WebGPU/WGSL/ConstantFunctions+Numeric.swift', r'''
func badRounded(_ a: Double) -> Double { a.rounded() }  // expect(L-CE-4)
func badRound(_ a: inout Float) { a.round() }  // expect(L-CE-4)
func goodRounded(_ a: Double) -> Double { a.rounded(.toNearestOrEven) }
'''),
    Sample('Source/WebGPU/WGSL/Support/ConstInt.swift', r'''
func badAbs(_ a: Int32) -> Int32 { abs(a) }  // expect(L-CE-5)
func badSwiftAbs(_ a: Int32) -> Int32 { Swift.abs(a) }  // expect(L-CE-5)
enum ConstInt {
    static func abs(_ x: Int32) -> Int32 { x == .min ? x : (x < 0 ? 0 &- x : x) }
}
func good(_ a: Int32, _ f: Float) -> (Int32, Float) { (ConstInt.abs(a), f.magnitude) }
'''),
    Sample('Source/WebGPU/WGSL/Support/NumberParsing.swift', r'''
func badLiteral() -> Float? { Float("1.5") }  // expect(L-CE-6)
func badText(_ text: Substring) -> Double? { Double(text) }  // expect(L-CE-6)
func badRadix(_ digits: String) -> Int? { Int(digits, radix: 16) }  // expect(L-CE-6)
func badString(_ token: Token) -> UInt32? { UInt32(String(token.spelling)) }  // expect(L-CE-6)
func badC(_ p: Int) -> Double { strtod(p, nil) }  // expect(L-CE-6)
func goodWiden(_ x: Int32) -> Double { Double(x) }
func badTyped(_ spelling: Substring) -> UInt32? { UInt32(spelling) }  // expect(L-CE-6)
func badNamed(_ s: String) -> Int? { Int(s) }  // expect(L-CE-6)
func badGeneric<T: LosslessStringConvertible>(_ s: String, _ t: T.Type) -> T? { T(s) }  // expect(L-CE-6)
'''),
    Sample('Source/WebGPU/WGSL/ConstantFunctions+Bitwise.swift', r'''
func badAdd(_ a: Int32, _ b: Int32) -> Int32 { a + b }  // expect(L-CE-7)
func badNegate(_ a: Int32) -> Int32 { -a }  // expect(L-CE-7)
func badCompound(_ a: inout Int64) { a *= 3 }  // expect(L-CE-7)
func badInterpolated(_ a: Int32) -> MessageText { "next \(a + 1)" }  // expect(L-CE-7)
func goodWrap(_ a: Int32, _ b: Int32) -> Int32 { a &+ b }
func goodFloat(_ a: Float, _ b: Float) -> Float { a + b }
func goodLiteral() -> Int32 { -1 }
func goodCase(_ x: Int32) -> Bool {
    switch x {
    case -1: true
    case 0: false
    case 1...4: true
    case 5, 6: false
    case 7: false
    case 8: false
    case 9: false
    case 10: false
    case 11: false
    case 12: false
    case 13: false
    case 14: false
    case 15: false
    case 16: false
    case 17...: false
    case Int32.min ..< -1: false
    }
}
func goodArrow(_ x: Int32) -> Int32 { x }
func goodText() -> MessageText { "a - b + c * d" }
'''),
    Sample('Source/WebGPU/WGSL/GlobalSorting.swift', r'''
// The declaration-aware L-DET-1 still flags iteration of a Dictionary/Set reached through members, parameters,
// closure parameters, captures, `self.`, shadowing and members inherited from a base class in the same file.
struct Graph {
    var edges: [Int: [Int]]
    var visited: Set<Int> = []
}

func arrays(_ edges: [Int]) -> [Int] { edges.map { $0 } }

extension Graph {
    func walk() {
        for edge in edges {  // expect(L-DET-1)
            _ = edge
        }
        _ = self.visited.map { $0 }  // expect(L-DET-1)
        func nested() -> [Int] { visited.sorted() }  // expect(L-DET-1)
        _ = nested()
    }
}

func parameters(_ items: [Int], _ table: [Int: Int]) {
    for item in items {
        _ = item
    }
    let pairs = [1].map { _ in table.first }  // expect(L-DET-1)
    _ = pairs
    let items = Set(items)
    items.forEach { _ = $0 }  // expect(L-DET-1)
}

func closureParameter() {
    let run: (Set<Int>) -> Int = { (seen: Set<Int>) in seen.reduce(0, &+) }  // expect(L-DET-1)
    _ = run
}

func ifBinding(_ maybe: [Int: Int]?) {
    if let found = maybe {
        for entry in found {  // expect(L-DET-1)
            _ = entry
        }
    }
}

class Table {
    var byName: [Int: Int] = [:]
}

final class SubTable: Table {
    func names() -> Int {
        var n = 0
        for (k, _) in byName {  // expect(L-DET-1)
            n &+= k
        }
        return n
    }
}
'''),
    Sample('Source/WebGPU/WGSL/IOValidator.swift', r'''
func badKeys(_ d: [Int: Int]) -> [Int] { Array(d.keys) }  // expect(L-DET-1)
func badForIn(_ table: [Int: [String]]) {
    for entry in table {  // expect(L-DET-1)
        _ = entry
    }
}
func badMap(_ seen: Set<Int>) -> [Int] { seen.map { $0 } }  // expect(L-DET-1)
func goodLookup(_ d: [Int: Int]) -> Int { d[3] ?? 0 }
func goodArray(_ items: [Int]) -> [Int] { items.map { $0 } }
'''),
    Sample('Source/WebGPU/WGSL/MangleNames.swift', r'''
func badCompare(_ name: String) -> Bool { name == "main" }  // expect(L-DET-2)
func badKey(_ table: [String: Int]) -> Int { table.count }  // expect(L-DET-2)
func badCharacter(_ c: Character) -> Bool { c.isLetter }  // expect(L-DET-2)
func badCount(_ text: String) -> Int { text.count }  // expect(L-DET-2)
func goodCount(_ text: String) -> Int { text.utf16.count }
func goodArrayCount(_ text: [UInt16]) -> Int { text.count }
'''),
    Sample('Source/WebGPU/WGSL/WGSLEnums.swift', r'''
// Catch-all cases and `default:` labels that do not start a line.
enum Kind { case a, b, c }
func bindingCatchAll(_ k: Kind) -> Int {
    switch k {
    case .a: 1
    case let other: other == .b ? 2 : 3  // expect(L-ENUM-1)
    }
}
func varCatchAll(_ k: Kind) -> Int {
    switch k {
    case .a: return 1
    case var other:  // expect(L-ENUM-1)
        other = .c
        return other == .c ? 2 : 3
    }
}
func sameLine(_ k: Kind) -> Int { switch k { case .a: 1; default: 2 } }  // expect(L-ENUM-1)
func afterBrace(_ k: Kind) -> Int { switch k { default: 2 } }  // expect(L-ENUM-1)
func noSemicolon(_ k: Kind) -> Int { switch k { case .a: return 1 default: return 2 } }  // expect(L-ENUM-1)
func unknownDefault(_ k: Kind) -> Int { switch k { case .a, .b, .c: 1; @unknown default: 2 } }  // expect(L-ENUM-1)
func wildcardMidLine(_ k: Kind) -> Int { switch k { case .a: 1; case _: 2 } }  // expect(L-ENUM-1)
func tuples(_ k: Kind, _ l: Kind) -> Int {
    switch (k, l) {
    case (.a, _): return 1
    case (_, .b): return 2
    case (let x, _): return x == .c ? 3 : 4  // expect(L-ENUM-1)
    }
}
func tuples2(_ k: Kind, _ l: Kind) -> Int {
    switch (k, l) {
    case (.a, .a): 1
    case let (x, y): x == y ? 2 : 3  // expect(L-ENUM-1)
    }
}
func tuples3(_ k: Kind, _ l: Kind) -> Int {
    switch (k, l) {
    case (.a, .a): 1
    case (_, _): 2  // expect(L-ENUM-1)
    }
}
func nextLine(_ k: Kind) -> Int {
    switch k {
    case .a: return 1
    case  // expect(L-ENUM-1)
        let x: return x == .b ? 2 : 3
    }
}
'''),
    Sample('Source/WebGPU/WGSL/WGSLEnums.swift', r'''
enum Kind { case a, b, c }
func badDefault(_ k: Kind) -> Int {
    switch k {
    case .a: 1
    default: 2  // expect(L-ENUM-1)
    }
}
func badWildcard(_ k: Kind) -> Int {
    switch k {
    case .a: 1
    case _: 2  // expect(L-ENUM-1)
    }
}
func badNoReason(_ x: UInt8) -> Int {
    switch x {
    case 0: 1
    default: 2  // lint-exempt(L-ENUM-1) expect(L-ENUM-1)
    }
}
func goodInteger(_ x: UInt8) -> Int {
    switch x {
    case 0: 1
    default: 2  // lint-exempt(L-ENUM-1): integers are an open domain
    }
}
'''),
    Sample('Source/WebGPU/WGSL/Parser.swift', r'''
func badFatal() -> Never { fatalError("bad") }  // expect(L-FATAL-1)
func badPrecondition(_ x: Int) { precondition(x > 0) }  // expect(L-FATAL-1)
func badFailure() -> Never { preconditionFailure("bad") }  // expect(L-FATAL-1)
func good() -> Never { wgslFatal("invariant", cppSite: "Parser.cpp:1") }
func goodDebugOnly(_ x: Int) { assert(x > 0) }
'''),
    Sample('Source/WebGPU/WGSL/CallGraph.swift', r'''
func badUnwrap(_ x: Int?) -> Int { x! }  // expect(L-FORCE-1)
func badTry() -> Int { try! thrower() }  // expect(L-FORCE-1)
func badCast(_ x: Int?) -> Int { x as! Int }  // expect(L-FORCE-1)
func thrower() throws -> Int { 1 }
func goodNot(_ x: Bool, _ y: Int) -> Bool { !x && y != 0 && !(y == 3) }
'''),
    Sample('Source/WebGPU/WGSL/Support/Registry.swift', r'''
var counter = 0  // expect(L-GLOBAL-1)

enum Registry {
    static var entries: [Int] = []  // expect(L-GLOBAL-1)
    static var computed: Int { 4 }
    static let constant = 3
}

struct Cache {
    nonisolated(unsafe) static let shared = Cache()  // expect(L-GLOBAL-1) expect(L-SAFE-1)
}

var globalComputed: Int { 3 }
'''),
    Sample('Source/WebGPU/WGSL/Support/LibM.swift', r'''
internal import Darwin
import Foundation  // expect(L-IMPORT-1)
public import Darwin  // expect(L-IMPORT-1)
'''),
    Sample('Source/WebGPU/WGSL/WGSLShaderModule.swift', r'''
final class ShaderModule {
    var nodes: [Int] = []
    var extra: Any  // expect(L-IR-1)
    weak var owner: Owner?  // expect(L-IR-1)
    #if WGSL_UNOPTIMIZED
    private let addressOnly: Any = ()
    #endif
    var computed: Any { nodes }
}
final class Owner {}
struct TypeChecker<Context> {
    var context: Context  // expect(L-IR-1)
    var provider: any Sequence<Int>  // expect(L-IR-1)
    var concrete: [Context]
}
'''),
    Sample('Source/WebGPU/WGSL/Types+Layout.swift', r'''
struct ByteSize { let bytes: UInt32 }
func badSum(_ a: ByteSize, _ b: ByteSize) -> UInt32 { a.bytes + b.bytes }  // expect(L-LAY-1)
func badScale(_ a: ByteSize) -> UInt32 { 4 * a.bytes }  // expect(L-LAY-1)
func badWrap(_ a: ByteSize, _ pad: UInt32) -> UInt32 { a.bytes &+ pad }  // expect(L-LAY-1)
func goodRead(_ a: ByteSize) -> UInt32 { a.bytes }
'''),
    Sample('Source/WebGPU/WGSL/Metal/MetalFunctionWriter+Expressions.swift', r'''
struct ExpressionEmitter {
    mutating func emit(_ text: StaticString) {}
    mutating func emitIndex() {
        emit("buffer[")  // expect(L-MSL-1)
        emit("[[position]]")  // expect(L-MSL-1)
        emit("float4(")
        wgslFatal("unexpected [kind]", cppSite: "MetalFunctionWriter.cpp:1")
    }
}
'''),
    Sample('Source/WebGPU/WGSL/ConstantValue+Dump.swift', r'''
// `.description` is flagged unless the receiver is known not to be a number: enum payloads, for-in elements,
// optional bindings, closure parameters, `inout`/optional parameters, arithmetic, subscripts, member chains across
// lines, typealiases and receivers of unknown type. Interpolations of values inferred to be floating-point.
typealias AbstractFloat = Double
enum ConstantValue {
    case float(Float)
    case abstractFloat(AbstractFloat)
    case f16(Half)
    case int(Int32)
    var floatValue: Float? { nil }
}
struct Half { var bits: UInt16 }
func payloads(_ value: ConstantValue) -> String {
    switch value {
    case .float(let f):
        return f.description  // expect(L-MSL-2)
    case let .abstractFloat(d):
        return "\(d)"  // expect(L-MSL-2)
    case .f16(let h):
        return h.description  // expect(L-MSL-2)
    case .int(let i):
        return i.description  // expect(L-MSL-2)
    }
}
func ifCase(_ value: ConstantValue) -> String {
    if case .float(let f) = value {
        return f.debugDescription  // expect(L-MSL-2)
    }
    return ""
}
func elements(_ value: ConstantValue, _ floats: [Float]) -> String {
    var s = ""
    if let v = value.floatValue {
        s += v.description  // expect(L-MSL-2)
    }
    for x in floats {
        s += x.description  // expect(L-MSL-2)
        s += "\(x)"  // expect(L-MSL-2)
    }
    for (i, x) in floats.enumerated() {
        s += i.description + "\(x)"  // expect(L-MSL-2)
    }
    s += floats.map { $0.description }.joined()  // expect(L-MSL-2)
    s += floats.map { "\($0)" }.joined()  // expect(L-MSL-2)
    s += floats.map { y in y.description }.joined()  // expect(L-MSL-2)
    return s
}
func parameters(_ a: Float?, _ b: inout Double, _ fs: [Float], _ x: Float, _ y: Float) -> String {
    var s = a?.description ?? ""  // expect(L-MSL-2)
    s += b.description  // expect(L-MSL-2)
    s += fs[0].description  // expect(L-MSL-2)
    s += (x * y).description  // expect(L-MSL-2)
    s += x.magnitude.description  // expect(L-MSL-2)
    s += x
        .description  // expect(L-MSL-2)
    return s
}
func abstract(_ a: AbstractFloat) -> String { a.description }  // expect(L-MSL-2)
func unknown(_ value: ConstantValue) -> String { externalValue(value).description }  // expect(L-MSL-2)
func singleLine(_ v: Float) -> String { "\(v) and \(-v)" }  // expect(L-MSL-2)
func generic<T: BinaryFloatingPoint>(_ v: T) -> String { "\(v)" }  // expect(L-MSL-2)
func multiLine(_ v: Double) -> String {
    """
    value \(v /* expect(L-MSL-2) */)
    """
}
'''),
    Sample('Source/WebGPU/WGSL/ConstantValue+Dump.swift', r'''
// `.description` on integer and floating receivers; interpolated floating values.
struct Extent {
    var width: UInt32
    var scale: Float = 1
}
func literal() -> String { (1.5).description }  // expect(L-MSL-2)
func intLiteral() -> String { 42.description }  // expect(L-MSL-2)
func conversion(_ x: Int64) -> String { Int32(truncatingIfNeeded: x).description }  // expect(L-MSL-2)
func parameter(_ count: Int) -> String { count.description }  // expect(L-MSL-2)
func local() -> String {
    let total = 3
    return total.debugDescription  // expect(L-MSL-2)
}
func collectionCount(_ items: [Int]) -> String { items.count.description }  // expect(L-MSL-2)
func member(_ e: Extent) -> String { e.width.description }  // expect(L-MSL-2)
extension Extent {
    func text() -> String { self.scale.description }  // expect(L-MSL-2)
}
func unresolvedFloatName(_ v: Extent) -> String { v.halfWidth.description }  // expect(L-MSL-2)
func interpolatedFloat(_ e: Extent) -> String {
    let ratio: Double = 0.5
    return "ratio \(ratio)"  // expect(L-MSL-2)
}
func interpolatedMember(_ e: Extent) -> String { "scale \(e.scale * 2.0)" }  // expect(L-MSL-2)
'''),
    Sample('Source/WebGPU/WGSL/ConstantValue+Dump.swift', r'''
func badDescribe(_ x: Int) -> String { String(describing: x) }  // expect(L-MSL-2)
func badDescription(_ x: Double) -> String { x.description }  // expect(L-MSL-2)
func badInterpolation(_ value: Float) -> String { "value \(Float(value) * 2)" }  // expect(L-MSL-2)
func badPrint() { print("debug") }  // expect(L-MSL-2)
func goodNumber(_ value: Double) -> MessageText { "value \(number: value)" }
func goodInteger(_ count: Int32) -> MessageText { "count \(count)" }
'''),
    Sample('Source/WebGPU/WGSL/GlobalSorting.swift', r'''
func reserved() -> StaticString { "__DynamicOffsets" }
func invented() -> StaticString { "__madeUpName" }  // expect(L-MSL-3)
func notReserved() -> StaticString { "_single" }
func runtimeText(_ name: String) -> String { "__\(name)" }  // expect(L-MSL-3)
func parameterisedPrefix(_ depth: UInt32) -> String { "__i\(depth)" }  // expect(L-MSL-3)
''', context=(AST_IDENTIFIER,)),
    Sample('Source/WebGPU/WGSL/AST/ASTStringDumper.swift', r'''
func badByteLiteral(_ sink: inout ByteSink, _ s: String) { sink.append(ByteLiteral(stringLiteral: s)) }  // expect(L-MSL-4)
func badByteLiteralInit(_ s: String) -> ByteLiteral { ByteLiteral.init(stringLiteral: s) }  // expect(L-MSL-4)
func badGrapheme(_ s: String) -> ByteLiteral { ByteLiteral(extendedGraphemeClusterLiteral: s) }  // expect(L-MSL-4)
func badScalar(_ s: String) -> ByteLiteral { .init(unicodeScalarLiteral: s) }  // expect(L-MSL-4)
func badMessageText(_ s: StaticString) -> MessageText { MessageText(stringLiteral: s) }  // expect(L-MSL-4)
func badMSLText(_ s: String) -> MSLText { MSLText.init(stringLiteral: s) }  // expect(L-MSL-4)
func badReference(_ s: String) -> ByteLiteral { let make: (String) -> ByteLiteral = ByteLiteral.init; return make(s) }  // expect(L-MSL-4)
func badStorage(_ sink: inout ByteSink, _ s: String) { sink.sinkBytes.append(contentsOf: s.utf8) }  // expect(L-MSL-4)
func goodLiteral(_ sink: inout ByteSink) { sink.append("float4") }
func goodRead(_ sink: ByteSink) -> Int { sink.bytes.count }
func goodMessage(_ count: Int32) -> MessageText { "found \(count) arguments" }
'''),
    Sample('Source/WebGPU/WGSL/Metal/MSLWriter.swift', r'''
struct MSLText: ExpressibleByStringLiteral {
    let text: String
    init(stringLiteral value: String) { text = value }
}
func badExplicit(_ s: String) -> MSLText { MSLText(stringLiteral: s) }  // expect(L-MSL-4)
func badInit(_ s: String) -> MSLText { .init(stringLiteral: s) }  // expect(L-MSL-4)
func goodLiteral() -> MSLText { "float4" }
'''),
    Sample('Source/WebGPU/WGSL/PointerRewriter.swift', r'''
struct PointerRewriter {
    mutating func visit(_ statement: CompoundStatement, _ id: StatementID) {
        for x in statement.items {  // expect(L-PERF-1)
            _ = x
        }
        statement.items.forEach { _ = $0 }  // expect(L-PERF-1)
        setInferredType(t, for: x)
    }
    func helper(_ values: [Int]) -> Int {
        var total = 0
        for v in values {
            total &+= v
        }
        return total
    }
}
struct LabeledLoops {
    mutating func visit(_ statement: LoopStatement, _ id: StatementID) {
        outer: for x in statement.items {  // expect(L-PERF-1)
            _ = x
        }
    }
}
'''),
    Sample('Source/WebGPU/WGSL/TypeCheck.swift', r'''
struct TypeChecker: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var cache: [Int] = []

    func lookup(_ id: ExpressionID) -> TypeID? { nil }  // expect(L-PERF-2)
    private func helper() -> Int { cache.count }  // expect(L-PERF-2)
    var isTop: Bool { cache.isEmpty }  // expect(L-PERF-2)
    var isEmpty: Bool {  // expect(L-PERF-2)
        get { cache.isEmpty }
    }
    mutating func visit(_ expression: ExpressionID) {}
    mutating func reads(_ id: ExpressionID) -> TypeID? { nil }
    static func pure(_ value: Int) -> Int { value }
    consuming func finish() -> ShaderModule { shaderModule }
}

extension TypeChecker {
    func inExtension() -> Int { 0 }  // expect(L-PERF-2)
    mutating func fine() {}
}

extension ASTScopedVisitor where Self: ~Copyable {
    public func lookupScoped(_ name: Symbol) -> ContextValue? { nil }  // expect(L-PERF-2)
    public mutating func readScoped(_ name: Symbol) -> ContextValue? { nil }
}
''', context=(AST_VISITOR, AST_SCOPED_VISITOR,)),
    Sample('Source/WebGPU/WGSL/Support/Bytes.swift', r'''
func badPointer(_ bytes: [UInt8]) -> UInt8 {
    bytes.withUnsafeBufferPointer { $0[0] }  // expect(L-SAFE-1)
}

func badBitCast(_ x: Float) -> UInt32 { unsafe unsafeBitCast(x, to: UInt32.self) }  // expect(L-SAFE-1)

struct Holder: @unchecked Sendable {  // expect(L-SAFE-1)
    let value: Int
}

func badLiteral(_ s: StaticString) -> Int { s.withUTF8Buffer { $0.count } }  // expect(L-SAFE-1)
'''),
    Sample('Source/WebGPU/WGSL/TypeCheck.swift', r'''
func misuse(_ module: inout ShaderModule, _ state: borrowing ModuleState) {
    ModuleState.withTestScope(&module) { _ in }  // expect(L-SCOPE-1)
    let mark = module.types.openScope()  // expect(L-SCOPE-1)
    module.types.rollback(to: mark)  // expect(L-SCOPE-1)
    module.types = TypeStore()  // expect(L-SCOPE-1)
    module.symbols = SymbolTable.predeclared  // expect(L-SCOPE-1)
    if module.types == state.shaderModule.types {
        _ = module.types.vectorType(2, module.types.f32Type)
    }
    // ModuleState.withTestScope(&module) is fine in a comment
}

func rewrap(_ module: consuming ShaderModule) -> StaticCheckStep {
    ModuleState.staticCheck(module) { _ in .success(warnings: [], entryPoints: []) }  // expect(L-SCOPE-1)
}
'''),
    Sample('Source/WebGPU/WGSL/BoundsCheck.swift', r'''
func badRead(_ m: ShaderModule, _ e: ExpressionID) -> Int? { m.constantValue(of: e) }  // expect(L-STICKY-1)
func goodRead(_ m: ShaderModule, _ e: ExpressionID) -> Int? { m.constantValueForBoundsCheckSkip(e) }
'''),
    Sample('Source/WebGPU/WGSL/GlobalSorting.swift', r'''
// An L-STUB-1 exemption is not accepted (on the line, on the line above, or stray).
func a() -> Int { wgslFatal("unported", cppSite: "GlobalSorting.cpp:1") }  // lint-exempt(L-STUB-1): a later chunk expect(L-STUB-1)
// lint-exempt-next-line(L-STUB-1): another chunk
func b() -> Int { wgslFatal("unported", cppSite: "GlobalSorting.cpp:2") }  // expect(L-STUB-1)
func c() -> Int { 3 }  // lint-exempt(L-STUB-1): stray expect(L-STUB-1)
'''),
    Sample('Source/WebGPU/WGSL/GlobalSorting.swift', r'''
func notYet() -> Int { wgslFatal("unported", cppSite: "GlobalSorting.cpp:1") }  // expect(L-STUB-1)
func fine() -> Never { wgslFatal("unreachable", cppSite: "GlobalSorting.cpp:2") }
'''),
    Sample('Source/WebGPU/WGSL/PointerRewriter.swift', r'''
struct PointerRewriter: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    mutating func visit(_ expression: borrowing BinaryExpression, _ expressionID: ExpressionID) {}
    mutating func visit(_ expression: UnaryExpression, _ id: StatementID) {}  // expect(L-VISIT-1)
    mutating func visitChildren(
        _ expression: BinaryExpression,
        _ id: ExpressionID
    ) {}
    mutating func visitChildren(_ statement: IfStatement) {}  // expect(L-VISIT-1)
    mutating func visit(_ function: Function, _ id: FunctionID) {}  // expect(L-VISIT-1)
    mutating func helper() {}
}

extension PointerRewriter {
    mutating func visit(expression: ExpressionID) {}  // expect(L-VISIT-1)
    mutating func visitShaderModuleChildren(_ module: ShaderModule) {}  // expect(L-VISIT-1)
}

struct ScopedPass: ASTScopedVisitor, ~Copyable {
    mutating func scopedVisit(_ function: FunctionID) {}
    mutating func scopedVisit(_ statement: CompoundStatement, _ id: StatementID) {}
    mutating func scopedVisit(_ statement: WhileStatement, _ id: StatementID) {}  // expect(L-VISIT-1)
}
''', context=(AST_VISITOR, AST_SCOPED_VISITOR,)),
    Sample('Source/WebGPU/WGSL/TypeCheck.swift', r'''
struct TypeChecker: ASTVisitor, ~Copyable {
    mutating func setError(_ error: CompilationMessage) {}  // expect(L-VISIT-2)
    func result() -> CompilationMessage? { nil }  // expect(L-VISIT-2)
    mutating func checkErrorAndVisit(_ e: ExpressionID) {}  // expect(L-VISIT-2)
    mutating func visit(_ expression: ExpressionID) {}
}
''', context=(AST_VISITOR,)),
    Sample('Source/WebGPU/WGSL/WGSL.swift', r'''
enum Compiler {
    static func prepare(_ state: consuming PreparedState) -> PrepareOutcome {
        .prepared(PreparedModule(state: state))
    }
    static func generate(_ state: consuming PreparedState) -> PrepareOutcome {
        PrepareOutcome.prepared(PreparedModule(state: state))  // expect(L-WB-1)
    }
    static func inspect(_ outcome: borrowing PrepareOutcome) -> Bool {
        if case .prepared = outcome {
            return true
        }
        return false
    }
}
'''),
    Sample('Source/WebGPU/WGSL/GlobalVariableRewriter.swift', r'''
func badPlusOne(_ binding: UInt32) -> UInt32 { binding + 1 }  // expect(L-WRAP-1)
func badMinus(_ a: UInt32, _ b: UInt32) -> UInt32 { a - b }  // expect(L-WRAP-1)
func badIncrement(_ a: inout UInt32) { a += 1 }  // expect(L-WRAP-1)
func goodWrap(_ binding: UInt32) -> UInt32 { binding &+ 1 }
func goodExempt(_ values: [Int]) -> Int { values.count - 1 }  // lint-exempt(L-WRAP-1): bounded by the array count
func goodExemptNext(_ values: [Int]) -> Int {
    // lint-exempt-next-line(L-WRAP-1): bounded by the array count
    values.count - 2
}
'''),
]

POSITIVE_SAMPLES = [
    Sample('Source/WebGPU/WGSL/ConstantFunctions+Idioms.swift', r'''
func wrapping(_ a: Int32, _ b: Int32) -> Int32 { a &+ b &* 2 }
func negate(_ a: Int32) -> Int32 { 0 &- a }
func literals() -> [Int32] { [-1, -2, 3] }
func floats(_ x: Float, _ y: Float) -> Float { x * y + 1 }
func doubles(_ x: Double) -> Double { -x }
func exponent() -> Double { 1e-5 }
func clamp(_ a: Double) -> Double { cxxClamp(a, 0, 1) }
func minOfArray(_ values: [Int32]) -> Int32? { values.min() }
func label(_ m: ShaderModule, _ e: ExpressionID, _ t: TypeID) { m.setInferredType(t, for: e) }
func message(_ value: Double, _ count: Int32) -> MessageText { "value \(number: value) count \(count)" }
func spans(_ m: CompilationMessage, _ module: ShaderModule, _ e: ExpressionID) -> SourceSpan { m.span }
func spanOf(_ module: ShaderModule, _ e: ExpressionID) -> SourceSpan { module.span(of: e) }
func exempted(_ values: [Int32]) -> Int { values.count - 1 }  // lint-exempt(L-CE-7): bounded by the array count
func range(_ n: Int) -> Range<Int> { 0..<n }
func comparisons(_ a: Int32, _ b: Int32) -> Bool { a != b && !(a == b) }
func ternary(_ a: Int32) -> Int32 { a < 0 ? 0 &- a : a }
func shifts(_ a: UInt32) -> UInt32 { a &<< 3 }
func arrow(_ f: (Int32) -> Int32) -> Int32 { f(1) }
func availability() -> Bool {
    if #available(macOS 26, *) {
        return true
    }
    return false
}
func optionalChain(_ x: Int32?) -> Int32? { x?.byteSwapped }
func convert(_ x: Int64) -> Int32 { Int32(truncatingIfNeeded: x) }
func parseFree(_ x: UInt8) -> Int32 { Int32(x) }
func caseNegative(_ x: Int32) -> Bool {
    switch x {
    case -1: true
    case Int32.min ..< -1: true
    case 0...: false
    }
}
func negativeInfinity() -> Value { -.infinity }
'''),
    Sample('Source/WebGPU/WGSL/Support/Spellings.swift', r'''
// `.description` on receivers inferred not to be numbers (enum payloads, for-in elements, optional bindings, closure
// parameters, members, inherited members, string literals, initialisers), a code-unit view of a receiver of unknown
// type, and interpolations of integers or non-numbers.
enum Spelling {
    case keyword(StaticString)
    case number(Int32)
}
enum Kind: CustomStringConvertible {
    case a, b
    var description: String { self == .a ? "a" : "b" }
}
class Named {
    var name: StaticString = "n"
}
final class Derived: Named {
    func text() -> String { name.description }
}
func payload(_ s: Spelling) -> String {
    switch s {
    case .keyword(let k):
        return k.description
    case let .number(n):
        return "\(n)"
    }
}
func sequences(_ names: [StaticString], _ maybe: StaticString?, _ kinds: [Kind]) -> String {
    var s = ""
    for n in names {
        s += n.description
    }
    if let m = maybe {
        s += m.description
    }
    s += maybe.map { $0.description } ?? ""
    s += kinds.map { $0.description }.joined()
    s += kinds.map { k in k.description }.joined()
    s += Kind.a.description + "abc".description + String(3).description
    return s
}
func codeUnits(_ value: Spelling) -> [UInt8] { Array(externalSpelling(value).description.utf8) }
func members(_ d: Derived) -> String { d.name.description + "\(d.name)" }
'''),
    Sample('Source/WebGPU/WGSL/Support/CodeUnits.swift', r'''
// `.description` on StaticString and other non-numeric receivers, code-unit conversion helpers, integer
// interpolation and words that merely contain "half"/"double".
enum Kind { case a, b }
func toString(_ k: Kind) -> StaticString { k == .a ? "a" : "b" }
func codeUnits(_ literal: StaticString) -> [UInt16] { Array(literal.description.utf16) }
func bytes(_ text: StaticString) -> [UInt8] { Array(text.description.utf8) }
func name(_ k: Kind) -> [UInt16] { Array(toString(k).description.utf16) }
struct Token {
    var spelling: StaticString
    var halfway: Int
}
func spelling(_ t: Token) -> [UInt8] { Array(t.spelling.description.utf8) }
func helper(_ s: StaticString) -> String {
    let doubled = s
    return doubled.description
}
func integers(_ index: Int32, _ items: [Int]) -> String { "item \(index) of \(items.count)" }
func halfway(_ t: Token) -> String { "at \(t.halfway)" }
func numberLabel(_ value: Double) -> String { "\(number: value)" }
func shorthand(_ names: [StaticString]) -> [String] { names.map { $0.description } }
func shorthandMember(_ tokens: [Token]) -> [String] { tokens.map { $0.spelling.description } }
'''),
    Sample('Source/WebGPU/WGSL/GlobalSorting.swift', r'''
// Arrays and locals that share a name with a Dictionary/Set declared in another scope of the same file.
struct Graph {
    var edges: [Int]
    var order: [Int] = []

    func visitAll() -> Int {
        var total = 0
        for edge in edges {
            total &+= edge
        }
        return total
    }
}

func countEdges(_ edges: [Int: Int]) -> Int { edges[0] ?? 0 }

func sortedNames(_ items: [Int]) -> [Int] { items.map { $0 &* 2 } }

func lookup(_ key: Int) -> Int {
    let items: Set<Int> = [1, 2]
    return items.contains(key) ? 1 : 0
}

func shadowed(_ order: Set<Int>) -> [Int] {
    let order = [3, 1, 2]
    return order.sorted()
}

extension Graph {
    func reversedOrder() -> [Int] { order.reversed() }

    func walk() {
        let order = self.order
        for item in order {
            _ = item
        }
        for item in self.edges {
            _ = item
        }
    }
}

func closures(_ table: [Int: Int]) -> [Int] {
    [1, 2].map { table in table &+ 1 }
}

func ifLet(_ maybe: [Int]?, _ values: Set<Int>) -> Int {
    if let values = maybe {
        for value in values {
            _ = value
        }
    }
    guard let values = maybe else {
        return 0
    }
    return values.reduce(0, &+)
}
'''),
    Sample('Source/WebGPU/WGSL/WGSLEnums.swift', r'''
// `default:` as an argument label or enum case name, and cases that bind without catching everything.
enum Mode {
    case `default`
    case named(Int)
}
func counts(_ keys: [Int], _ table: inout [Int: Int]) {
    for key in keys {
        table[key, default: 0] &+= 1
    }
}
func make(default value: Int) -> Int { value }
func call() -> Int {
    make(
        default: 3
    )
}
func labels() -> Int { make(default: 1) &+ make(default: 2) }
func modes(_ m: Mode?) -> Int {
    switch m {
    case .default: return 0
    case .named(let n) where n > 3: return n
    case let .named(n): return n &+ 1
    case let x?: return x == .default ? 1 : 2
    case nil: return 3
    }
}
func patterns(_ k: Int?) -> Int {
    if case let x? = k {
        return x
    }
    for case let x? in [k] {
        return x
    }
    switch k {
    case let x? where x > 0: return x
    case .some(let x): return x &+ 1
    case (.none): return 0
    }
}
func tuples(_ a: Int, _ b: Int) -> Int {
    switch (a, b) {
    case (0, let y): return y
    case (let x, 0): return x
    case (a, b): return 1
    }
}
'''),
    Sample('Source/WebGPU/WGSL/WGSL.swift', r'''
/// The execution context compilations need.
public enum CompileThread {
    #if WGSL_UNOPTIMIZED
    /// 16 MiB.
    public static var recommendedStackSize: Int? { 16 << 20 }
    #else
    /// nil.
    public static var recommendedStackSize: Int? { nil }
    #endif
    static let fixed = 3
    static var observed: Int {
        get { fixed }
    }
}

let globalConstant = 4

enum Compiler {
    static func prepare(_ module: consuming CheckedModule, entryPoints: [Name]) -> PrepareOutcome
    {
        guard let first = entryPoints.first else {
            return .failed(CompilationMessage("no entry point", span: .empty), module)
        }
        _ = first
        return .prepared(PreparedModule(state: PreparedState(), information: []))
    }
}
'''),
    Sample('Source/WebGPU/WGSL/Support/ByteSink.swift', r'''
struct ByteLiteral: ExpressibleByStringLiteral {
    let text: String
    init(stringLiteral value: String) { text = value }
}
struct ByteSink {
    var sinkBytes: ContiguousArray<UInt8> = []
    var bytes: ContiguousArray<UInt8> { sinkBytes }
    mutating func append(_ literal: ByteLiteral) { sinkBytes.append(contentsOf: literal.text.utf8) }
    mutating func append(contentsOf other: ByteSink) { sinkBytes.append(contentsOf: other.sinkBytes) }
}
struct Wrapper: ExpressibleByStringLiteral {
    let literal: ByteLiteral
    init(stringLiteral value: StaticString) { literal = "x" }
}
'''),
    Sample('Source/WebGPU/WGSL/Metal/MSLWriter.swift', r'''
struct MSLWriter {
    var sink: ContiguousArray<UInt8> = []
    mutating func append(_ literal: StaticString) { sink.append(contentsOf: literal.description.utf8) }
    mutating func emitSubscriptOpen() { append("[") }
    mutating func appendAttribute() { append("[[buffer(") }
}
'''),
    Sample('Source/WebGPU/WGSL/WGSL.swift', r'''
// WGSL.swift's staticCheck wraps the checked module (L-SCOPE-1); comparing and growing the TypeStore is fine anywhere.
func staticCheck(_ module: consuming ShaderModule) -> StaticCheckStep {
    ModuleState.staticCheck(module) { module in
        _ = module.types.vectorType(2, module.types.f32Type)
        return .success(warnings: [], entryPoints: [])
    }
}
'''),
    Sample('Source/WebGPU/WGSL/Support/Text.swift', r'''
func tricky() -> [String] {
    let a = "not a // comment { brace default: x! fatalError("
    let b = #"raw \(notInterpolated) "quote" unsafe "#
    let c = """
        multi-line with "quotes" and default: and fatalError( and x! and Float16
        """
    let d = "outer \("inner \("deep")") end"
    /* block /* nested */ fatalError( unsafe Float16 still comment */
    return [a, b, c, d]
}
'''),
    Sample('Source/WebGPU/WGSL/MangleNames.swift', r'''
struct NameManglerVisitor: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError: Bool

    mutating func visit(_ expression: ExpressionID) {
        var cursor = shaderModule.cursor(list)
        while let x = shaderModule.next(&cursor) {
            checkErrorAndVisit(x)
        }
    }

    mutating func visit(
        _ expression: borrowing BinaryExpression,
        _ id: ExpressionID
    ) {
        visitChildren(expression, id)
    }
}
''', context=(AST_VISITOR,)),
    Sample('Source/WebGPU/WGSL/AliasAnalysis.swift', r'''
// Helpers of a pass that only read are `mutating` or `static`; plain structs and the ShaderModule API are not affected.
struct AliasAnalysis: ASTScopedVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var context = ContextProvider<Int>()
    var count = 0
    let limit: Int

    mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID) {
        count &+= lookup(expression.identifier) ?? 0
    }

    private mutating func lookup(_ name: IdentifierID) -> Int? {
        readVariable(name)
    }

    private static func clamp(_ value: Int, _ limit: Int) -> Int { value < limit ? value : limit }

    func report() -> Int { // lint-exempt(L-PERF-2): called once, after the traversal
        count
    }
}

struct Summary {
    var values: [Int] = []
    func total() -> Int { values.count }
    var isEmpty: Bool { values.isEmpty }
}
''', context=(AST_VISITOR, AST_SCOPED_VISITOR,)),
    Sample('Source/WebGPU/WGSL/WGSLFatal.swift', r'''
@_spi(Testing)
public func wgslFatal(_ message: StaticString, cppSite: StaticString) -> Never {
    fatalError("WGSL: \(message) [\(cppSite)]")
}
'''),
]

TOOL_SAMPLES = [
    # The tools are outside the module: only L-SAFE-1 applies to them, and not to the libFuzzer entry.
    Sample('Source/WebGPU/WGSL/wgslc/wgslc.swift', r'''
import Foundation

func read(_ data: Data) -> [UInt8] {
    data.withUnsafeBytes { Array($0) }  // expect(L-SAFE-1)
}

func fail() -> Never { fatalError("usage") }
'''),
]

POSITIVE_TOOL_SAMPLES = [
    Sample(FUZZ_ENTRY, r'''
import WGSL

@_cdecl("LLVMFuzzerTestOneInput")
@unsafe
public func fuzzerTestOneInput(_ data: UnsafePointer<UInt8>?, _ size: Int) -> Int32 {
    _ = SourceText(decodingUTF8WithLatin1Fallback: unsafe Array(UnsafeBufferPointer(start: data, count: size)))
    return 0
}
'''),
]


def markers(text):
    """The (rule, line) pairs a sample marks with expect(RULE)."""
    out = set()
    for ln, comment in enumerate(SwiftFile('', text).comments):
        for m in re.finditer(r'expect\(([A-Z0-9-]+)\)', comment):
            out.add((m.group(1), ln + 1))
    return out


def lint_sample(sample):
    files = {}
    for rel, text in sample.context:
        files[rel] = SwiftFile(rel, text[1:] if text.startswith('\n') else text)
    files[sample.path] = SwiftFile(sample.path, sample.text)
    return lint(Context(files), files[sample.path])


class WGSLSwiftRulesTest(unittest.TestCase):

    def assertFindings(self, sample):
        got = {(rule_id, line) for line, rule_id, _ in lint_sample(sample)}
        self.assertEqual(got, markers(sample.text), sample.path)

    def test_negative_samples(self):
        for sample in NEGATIVE_SAMPLES + TOOL_SAMPLES:
            with self.subTest(path=sample.path, first_line=sample.text.split('\n')[0]):
                self.assertTrue(markers(sample.text))
                self.assertFindings(sample)

    def test_positive_samples(self):
        for sample in POSITIVE_SAMPLES + POSITIVE_TOOL_SAMPLES:
            with self.subTest(path=sample.path, first_line=sample.text.split('\n')[0]):
                self.assertEqual(markers(sample.text), set())
                self.assertEqual(lint_sample(sample), [])

    def test_every_rule_has_a_negative_sample(self):
        covered = set()
        for sample in NEGATIVE_SAMPLES + TOOL_SAMPLES:
            covered |= {rule_id for rule_id, _ in markers(sample.text)}
        self.assertEqual(covered, {r.id for r in RULES})

    def test_exemption_needs_a_reason(self):
        sample = Sample('Source/WebGPU/WGSL/CallGraph.swift', '''
func a(_ x: Int?) -> Int { x! }  // lint-exempt(L-FORCE-1): the caller checked it
func b(_ x: Int?) -> Int { x! }  // lint-exempt(L-FORCE-1)
// lint-exempt-next-line(L-FORCE-1, L-DET-2): both are fine here
func c(_ x: Int?, _ s: String) -> Int { s == "a" ? x! : 0 }
''')
        findings = lint_sample(sample)
        self.assertEqual([(line, rule_id) for line, rule_id, _ in findings], [(2, 'L-FORCE-1')])
        self.assertIn('exemption ignored: it has no reason', findings[0][2])


class WGSLSwiftCheckerTest(unittest.TestCase):
    """The checker reads the other Swift files of Source/WebGPU/WGSL from the checkout holding the checked file."""

    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.write(*AST_VISITOR)

    def tearDown(self):
        shutil.rmtree(self.root)

    def write(self, rel, text):
        path = os.path.join(self.root, *rel.split('/'))
        if not os.path.isdir(os.path.dirname(path)):
            os.makedirs(os.path.dirname(path))
        with open(path, 'w') as fh:
            fh.write(text)
        return path

    def check(self, rel, text, on_disk=True):
        path = os.path.join(self.root, *rel.split('/'))
        if on_disk:
            self.write(rel, text)
        errors = []

        def handle_style_error(line_number, category, confidence, message):
            errors.append((line_number, category, confidence, message))

        with patch.object(SwiftChecker, '_swift_format'):
            WGSLSwiftChecker(path, handle_style_error).check(text.split('\n'))
        return errors

    def test_reports_each_finding_once_with_its_rule_as_category(self):
        errors = self.check('Source/WebGPU/WGSL/CallGraph.swift', '''struct Walker: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    mutating func visit(_ expression: ExpressionID) {}
    mutating func visit(_ statement: IfStatement) {}
}
func f(_ x: Int?) -> Int { x! }  // lint-exempt(L-WRAP-1): a different rule
func g(_ x: Int?) -> Int { x! }  // lint-exempt(L-FORCE-1): checked by the caller
''')
        self.assertEqual([(line, category, confidence) for line, category, confidence, _ in errors],
                         [(4, 'wgsl/L-VISIT-1', 5), (6, 'wgsl/L-FORCE-1', 5)])
        self.assertTrue(errors[0][3].startswith('visit(_: IfStatement): L-VISIT-1 bans a `visit`'))
        self.assertIn('; instead: fix the signature. A justified exception takes `// lint-exempt(L-VISIT-1): <reason>`.',
                      errors[0][3])

    def test_stubs_cannot_be_exempted(self):
        errors = self.check('Source/WebGPU/WGSL/GlobalSorting.swift',
                            'func a() -> Int { wgslFatal("unported", cppSite: "GlobalSorting.cpp:1") }  // lint-exempt(L-STUB-1): later\n')
        self.assertEqual([(line, category) for line, category, _, _ in errors], [(1, 'wgsl/L-STUB-1')])
        self.assertNotIn('lint-exempt(L-STUB-1): <reason>', errors[0][3])

    def test_checks_the_lines_it_is_given(self):
        self.write('Source/WebGPU/WGSL/Lexer.swift', 'func f() -> Int { 1 }\n')
        errors = self.check('Source/WebGPU/WGSL/Lexer.swift', 'func f() -> Int { fatalError("x") }\n', on_disk=False)
        self.assertEqual([(line, category) for line, category, _, _ in errors], [(1, 'wgsl/L-FATAL-1')])

    def test_unsafe_is_reported_by_both_checkers_in_the_module(self):
        errors = self.check('Source/WebGPU/WGSL/Lexer.swift', 'func f(_ x: Float) -> UInt32 { unsafe unsafeBitCast(x, to: UInt32.self) }\n')
        self.assertEqual(sorted(category for _, category, _, _ in errors), ['webkit/unsafe', 'wgsl/L-SAFE-1'])

    def test_the_libfuzzer_entry_may_use_unsafe(self):
        self.assertEqual(self.check(FUZZ_ENTRY, POSITIVE_TOOL_SAMPLES[0].text), [])

    def test_category_names(self):
        self.assertEqual(WGSLSwiftChecker.categories - SwiftChecker.categories, {'wgsl/' + r.id for r in RULES})


class WebGPUHeaderCheckerTest(unittest.TestCase):

    def check(self, text):
        errors = []

        def handle_style_error(line_number, category, confidence, message):
            if category == HAVE_WGSL_COMPILER_CATEGORY:
                errors.append(line_number)

        WebGPUHeaderChecker('Source/WebGPU/WebGPU/ShaderModule.h', 'h', handle_style_error, 1).check(text.split('\n'))
        return errors

    def test_flags_have_wgsl_compiler_in_code(self):
        self.assertEqual(self.check('\n'.join([
            '#pragma once',
            '#if HAVE(WGSL_COMPILER)',
            '#endif',
            '#if defined(HAVE_WGSL_COMPILER) && HAVE_WGSL_COMPILER',
            '#endif',
            'static_assert(HAVE( WGSL_COMPILER ));',
            '#if HAVE(WGSL_COMPILER_SOMETHING) || ENABLE(WEBGPU_SWIFT)',
            '#endif',
        ])), [2, 4, 6])

    def test_ignores_comments_and_literals(self):
        self.assertEqual(self.check('\n'.join([
            '#pragma once',
            '// Never test HAVE_WGSL_COMPILER in a header Swift imports.',
            '/* Nor HAVE(WGSL_COMPILER)',
            '   across lines: HAVE(WGSL_COMPILER) */ int x;',
            'static const char* name = "HAVE(WGSL_COMPILER)";',
            "static const char c = '\"'; // HAVE(WGSL_COMPILER)",
        ])), [])


class WGSLSwiftDispatchTest(unittest.TestCase):

    def dispatch(self, file_path):
        return CheckerDispatcher().dispatch(file_path, DefaultStyleErrorHandler('', None, None, []), min_confidence=3, commit_queue=False)

    def test_paths(self):
        self.assertEqual(self.dispatch('Source/WebGPU/WGSL/Lexer.swift').__class__, WGSLSwiftChecker)
        self.assertEqual(self.dispatch('Source/WebGPU/WGSL/AST/ASTVisitor.swift').__class__, WGSLSwiftChecker)
        self.assertEqual(self.dispatch(FUZZ_ENTRY).__class__, WGSLSwiftChecker)
        self.assertEqual(self.dispatch('Source/WebGPU/WebGPU/WGSLBridge.swift').__class__, SwiftChecker)
        self.assertEqual(self.dispatch('Tools/TestWebKitAPI/Tests/WGSL/LexerTests.swift').__class__, SwiftChecker)
        self.assertEqual(self.dispatch('Source/WebGPU/WebGPU/WGSLAPI.h').__class__, WebGPUHeaderChecker)
        self.assertEqual(self.dispatch('Source/WebGPU/WebGPU/Internal/Layout.h').__class__, WebGPUHeaderChecker)
        self.assertEqual(self.dispatch('Source/WebGPU/WebGPU/ShaderModule.mm').__class__, CppChecker)
        self.assertEqual(self.dispatch('Source/WebGPU/WGSL/WGSLStub.c').__class__, CppChecker)

    def test_split_path(self):
        self.assertEqual(split_path('/checkout/Source/WebGPU/WGSL/AST/ASTNode.swift'), ('/checkout', 'Source/WebGPU/WGSL/AST/ASTNode.swift'))
        self.assertEqual(split_path('/checkout/Source/WebGPU/WebGPU/Device.h'), ('/checkout', 'Source/WebGPU/WebGPU/Device.h'))
        self.assertIsNone(split_path('/checkout/Source/WebKit/Shared/Foo.swift'))
        self.assertTrue(is_wgsl_swift_path('/checkout/Source/WebGPU/WGSL/wgslc/wgslc.swift'))
        self.assertFalse(is_wgsl_swift_path('/checkout/Source/WebGPU/WGSL/generator/main.rb'))
        self.assertTrue(is_webgpu_header_path('/checkout/Source/WebGPU/WebGPU/Device.h'))
        self.assertFalse(is_webgpu_header_path('/checkout/Source/WebGPU/WebGPU/Device.mm'))
