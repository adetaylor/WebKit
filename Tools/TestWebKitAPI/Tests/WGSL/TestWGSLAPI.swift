// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
// Copyright (c) 2022-2026 Apple Inc. All rights reserved.
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
import Testing
import WGSL

/// A shader source a helper accepts: a `String` (converted as WTF::String::fromUTF8 does) or a `SourceText`.
protocol WGSLTestSource {
    var sourceText: SourceText { get }
}

extension String: WGSLTestSource {
    var sourceText: SourceText { wtfSource(self) }
}

extension SourceText: WGSLTestSource {
    var sourceText: SourceText { self }
}

func logCompilationError(_ failedCheck: FailedCheck, sourceLocation: SourceLocation = #_sourceLocation) {
    var message = String(failedCheck.errors.count) + " error" + (failedCheck.errors.count != 1 ? "s" : "")
    message += " generated while compiling the shader:"
    for error in failedCheck.errors {
        message += "\n" + error.dumpDescription
    }
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
}

/// EXPECT_EQ(error.message(), errorMessage): WTF::String equality compares code units, not canonical equivalence as Swift.String does.
func expectMessage(_ error: CompilationMessage?, _ errorMessage: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let matches = error?.utf16.elementsEqual(errorMessage.utf16) ?? false
    #expect(matches, "\"\(error?.message ?? "no error")\" is not \"\(errorMessage)\"", sourceLocation: sourceLocation)
}

func fn(_ test: String) -> String {
    "@compute @workgroup_size(1) fn test() {\n" + test + "\n}"
}

func enableF16(_ test: String) -> String {
    "enable f16;\n\n" + test
}

/// The representation WTF::String::fromUTF8 gives `string`: 8-bit iff all ASCII, else 16-bit.
func wtfSource(_ string: String) -> SourceText {
    SourceText(string)
}

private let shadersPath = Bundle.main.resourcePath.map { ($0 as NSString).appendingPathComponent("shaders") }

func file(_ filePath: String, sourceLocation: SourceLocation = #_sourceLocation) -> SourceText {
    #expect(shadersPath != nil, sourceLocation: sourceLocation)
    let path = (shadersPath.map { ($0 as NSString).appendingPathComponent(filePath) }) ?? filePath
    let readResult = FileManager.default.contents(atPath: path)
    #expect(readResult != nil, "cannot read \(path)", sourceLocation: sourceLocation)
    return SourceText(decodingUTF8WithLatin1Fallback: [UInt8](readResult ?? Data()))
}

/// A check over the MSL: takes the UTF-16 offset to search from and returns the offset the next check starts from.
typealias Check = (_ msl: String, _ offset: UInt32) -> UInt32

/// WTF's notFound truncated to `unsigned`.
let notFound = UInt32.max

func checkLiteral(_ pattern: String, sourceLocation: SourceLocation = #_sourceLocation) -> Check {
    { msl, offset in
        let result = find(pattern, in: msl, from: offset)
        #expect(result != nil, "checkLiteral(\"\(pattern)\") from offset \(offset)", sourceLocation: sourceLocation)
        return result ?? notFound
    }
}

func checkNotLiteral(_ pattern: String, sourceLocation: SourceLocation = #_sourceLocation) -> Check {
    { msl, offset in
        let result = find(pattern, in: msl, from: offset)
        #expect(result == nil, "checkNotLiteral(\"\(pattern)\") from offset \(offset)", sourceLocation: sourceLocation)
        return offset
    }
}

func checkNot(_ pattern: String, sourceLocation: SourceLocation = #_sourceLocation) -> Check {
    { msl, offset in
        let result = firstMatch(of: pattern, in: msl, from: offset, sourceLocation: sourceLocation)
        #expect(result == nil, "checkNot(\"\(pattern)\") from offset \(offset)", sourceLocation: sourceLocation)
        return offset
    }
}

// DEV-12: a miss records an issue and returns notFound where the C++ __builtin_trap()s, so the run continues.
func check(_ pattern: String, sourceLocation: SourceLocation = #_sourceLocation) -> Check {
    { msl, offset in
        let result = firstMatch(of: pattern, in: msl, from: offset, sourceLocation: sourceLocation)
        #expect(result != nil, "check(\"\(pattern)\") from offset \(offset)", sourceLocation: sourceLocation)
        return result ?? notFound
    }
}

/// WTF::String::find(pattern, offset) over UTF-16 code units.
private func find(_ pattern: String, in string: String, from offset: UInt32) -> UInt32? {
    let haystack = Array(string.utf16)
    let needle = Array(pattern.utf16)
    let start = Int(offset)
    guard start <= haystack.count else {
        return nil
    }
    guard !needle.isEmpty else {
        return offset
    }
    var index = start
    while needle.count <= haystack.count - index {
        if haystack[index..<index + needle.count].elementsEqual(needle) {
            return UInt32(index)
        }
        index += 1
    }
    return nil
}

/// JSC::Yarr::RegularExpression(pattern).match(string, offset), with the offset and the result in UTF-16 code units.
private func firstMatch(of pattern: String, in string: String, from offset: UInt32, sourceLocation: SourceLocation) -> UInt32? {
    let regularExpression: Regex<AnyRegexOutput>
    do {
        regularExpression = try Regex(pattern).matchingSemantics(.unicodeScalar)
    } catch {
        Issue.record(error, "invalid regular expression \"\(pattern)\"", sourceLocation: sourceLocation)
        return nil
    }
    guard Int(offset) <= string.utf16.count else {
        return nil
    }
    let start = String.Index(utf16Offset: Int(offset), in: string)
    guard let match = string[start...].firstMatch(of: regularExpression) else {
        return nil
    }
    return UInt32(match.range.lowerBound.utf16Offset(in: string))
}

let testsConfiguration = Configuration(
    maxBuffersPlusVertexBuffersForVertexStage: 8,
    maxBuffersForFragmentStage: 8,
    maxBuffersForComputeStage: 8,
    maximumCombinedWorkgroupVariablesSize: 16_384,
    supportedFeatures: [.shaderF16, .clipDistances, .primitiveIndex]
)

let noFeaturesConfiguration = Configuration(maxBuffersPlusVertexBuffersForVertexStage: 8)

// MARK: - Compile thread

/// Proof that code runs inside `onCompileThread`; only `onCompileThread` mints it, and the helpers' compile steps require it.
struct CompileThreadScope: ~Copyable {
    fileprivate init() {}

    func staticCheck(_ wgsl: SourceText, configuration: Configuration = testsConfiguration) -> StaticCheckOutcome {
        WGSL.staticCheck(wgsl, configuration: configuration)
    }

    /// Prepares every entry point, in call-graph order, with a default layout.
    func prepare(_ shaderModule: consuming CheckedModule) -> PrepareOutcome {
        let pipelineLayouts = shaderModule.entryPoints.map(\.name)
        return shaderModule.prepare(entryPoints: pipelineLayouts)
    }

    func generate(_ prepareResult: consuming PreparedModule, _ deviceState: DeviceState = DeviceState()) -> GenerateOutcome {
        prepareResult.generate(overrides: [], deviceState: deviceState)
    }
}

/// Runs `body` on a thread with `CompileThread.recommendedStackSize` and waits for it, or inline when that is nil.
///
/// Swift Testing runs tests on 512 KiB pool threads, not on the 8 MiB main thread.
func onCompileThread<Result: Sendable>(_ body: @escaping @Sendable (borrowing CompileThreadScope) -> Result) -> Result {
    guard let stackSize = CompileThread.recommendedStackSize else {
        return body(CompileThreadScope())
    }
    let completion = CompileThreadCompletion<Result>()
    let thread = Thread {
        completion.complete(body(CompileThreadScope()))
    }
    thread.name = "WGSL compile"
    thread.stackSize = stackSize
    thread.start()
    return completion.wait()
}

private final class CompileThreadCompletion<Result: Sendable>: Sendable {
    private let result = Mutex<Result?>(nil)
    private let done = DispatchSemaphore(value: 0)

    func complete(_ value: Result) {
        result.withLock { $0 = value }
        done.signal()
    }

    func wait() -> Result {
        done.wait()
        guard let value = result.withLock({ $0 }) else {
            preconditionFailure("the compile thread finished without a result")
        }
        return value
    }
}

/// The CPU time the calling thread spends in `body`.
///
/// Unlike the time on a clock it leaves out the time other threads and processes run while this one waits, but load still
/// changes it (the core it runs on, the clock rate, shared caches), so tests only compare it with the CPU time of other work
/// on the same thread (`leastCostsPerUnit`).
func threadCPUTime(_ body: () -> Void) -> Duration {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    body()
    return .nanoseconds(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- start)
}

/// The least CPU time per unit of work of `small` and of `large` over up to three rounds that alternate them.
///
/// Each returns the CPU time it took, for `units.small` and `units.large` units of work; the rounds stop once `large`
/// costs at most `factor` times `small` per unit. Work that grows linearly costs about the same per unit in both, and the
/// least of alternating rounds keeps a burst of load in one round from deciding the comparison.
func leastCostsPerUnit(
    units: (small: Int, large: Int),
    factor: Int,
    small: () -> Duration,
    large: () -> Duration
) -> (small: Duration, large: Duration) {
    var least = (small: small() / units.small, large: large() / units.large)
    var rounds = 1
    while rounds < 3 && least.large > least.small * factor {
        least = (small: min(least.small, small() / units.small), large: min(least.large, large() / units.large))
        rounds += 1
    }
    return least
}

private enum CompilationStage {
    case prepare
    case generate
}

private enum CompilationResult: Sendable {
    case staticCheckFailed(FailedCheck)
    case prepareFailed(CompilationMessage)
    case prepared
    case generateFailed(CompilationMessage)
    case generated(String)
}

private func compile(_ wgsl: SourceText, _ deviceState: DeviceState, through stage: CompilationStage) -> CompilationResult {
    onCompileThread { compileThread in
        switch compileThread.staticCheck(wgsl) {
        case .failure(let failedCheck):
            return .staticCheckFailed(failedCheck)
        case .success(let successfulCheck):
            switch compileThread.prepare(successfulCheck) {
            case .failed(let error, _):
                return .prepareFailed(error)
            case .prepared(let prepareResult):
                guard stage == .generate else {
                    return .prepared
                }
                switch compileThread.generate(prepareResult, deviceState) {
                case .generated(let library, _):
                    return .generated(library.msl.string)
                case .failed(let error, _):
                    return .generateFailed(error)
                }
            }
        }
    }
}

private func staticCheckErrors(_ wgsl: SourceText, _ configuration: Configuration) -> FailedCheck? {
    onCompileThread { compileThread in
        switch compileThread.staticCheck(wgsl, configuration: configuration) {
        case .success:
            return nil
        case .failure(let failedCheck):
            return failedCheck
        }
    }
}

// MARK: - Metal

private struct NoMetalDevice: Error {}

func metalCompile(_ msl: String, appleGPUFamily: UInt32 = 8) -> Result<any MTLLibrary, any Error> {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return .failure(NoMetalDevice())
    }
    let options = MTLCompileOptions()
    options.preprocessorMacros = ["__wgslMetalAppleGPUFamily": String(appleGPUFamily) as NSString]
    return Result { try device.makeLibrary(source: msl, options: options) }
}

func performChecks(_ input: String, _ checks: Check...) {
    performChecks(input, checks)
}

func performChecks(_ input: String, _ checks: [Check]) {
    var offset: UInt32 = 0
    for check in checks {
        offset = check(input, offset)
    }
}

// MARK: - TypeCheckingTests.mm

func expectTypeError(_ wgsl: some WGSLTestSource, _ errorMessage: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let result = staticCheckErrors(wgsl.sourceText, testsConfiguration)
    #expect(result != nil, "staticCheck succeeded", sourceLocation: sourceLocation)
    guard let error = result else {
        return
    }
    #expect(error.errors.count == 1, sourceLocation: sourceLocation)
    expectMessage(error.errors.first, errorMessage, sourceLocation: sourceLocation)
}

func expectNoError(_ wgsl: some WGSLTestSource, sourceLocation: SourceLocation = #_sourceLocation) {
    let result = staticCheckErrors(wgsl.sourceText, noFeaturesConfiguration)
    if let failedCheck = result {
        logCompilationError(failedCheck, sourceLocation: sourceLocation)
    }
}

// MARK: - MetalCompilationTests.mm

private func expectGenerated(_ generationResult: CompilationResult, _ sourceLocation: SourceLocation) -> String? {
    switch generationResult {
    case .staticCheckFailed(let failedCheck):
        logCompilationError(failedCheck, sourceLocation: sourceLocation)
    case .prepareFailed(let error):
        Issue.record("prepare failed: \(error.dumpDescription)", sourceLocation: sourceLocation)
    case .prepared:
        Issue.record("generate did not run", sourceLocation: sourceLocation)
    case .generateFailed(let error):
        Issue.record("generate failed: \(error.dumpDescription)", sourceLocation: sourceLocation)
    case .generated(let msl):
        return msl
    }
    return nil
}

private func expectMetalLibrary(_ msl: String, _ appleGPUFamily: UInt32, _ sourceLocation: SourceLocation) -> Bool {
    let metalCompilationResult = metalCompile(msl, appleGPUFamily: appleGPUFamily)
    if case .failure(let error) = metalCompilationResult {
        Issue.record(error, "Metal compilation failed", sourceLocation: sourceLocation)
        return false
    }
    return true
}

func testCompilation(_ wgsl: some WGSLTestSource, _ checks: Check..., sourceLocation: SourceLocation = #_sourceLocation) {
    let generationResult = compile(wgsl.sourceText, DeviceState(), through: .generate)
    guard let msl = expectGenerated(generationResult, sourceLocation), expectMetalLibrary(msl, 8, sourceLocation) else {
        return
    }
    performChecks(msl, checks)
}

func testCompilationForAppleGPUFamily(
    _ appleGPUFamily: UInt32,
    _ wgsl: some WGSLTestSource,
    _ checks: Check...,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let generationResult = compile(wgsl.sourceText, DeviceState(appleGPUFamily: appleGPUFamily), through: .generate)
    guard let msl = expectGenerated(generationResult, sourceLocation), expectMetalLibrary(msl, appleGPUFamily, sourceLocation) else {
        return
    }
    performChecks(msl, checks)
}

func expectPrepareError(_ wgsl: some WGSLTestSource, _ errorMessage: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let maybePrepareResult = compile(wgsl.sourceText, DeviceState(), through: .prepare)
    switch maybePrepareResult {
    case .staticCheckFailed(let failedCheck):
        logCompilationError(failedCheck, sourceLocation: sourceLocation)
    case .prepareFailed(let error):
        expectMessage(error, errorMessage, sourceLocation: sourceLocation)
    case .prepared, .generateFailed, .generated:
        Issue.record("prepare succeeded", sourceLocation: sourceLocation)
    }
}

func expectGenerateError(_ wgsl: some WGSLTestSource, _ errorMessage: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let generationResult = compile(wgsl.sourceText, DeviceState(), through: .generate)
    switch generationResult {
    case .staticCheckFailed(let failedCheck):
        logCompilationError(failedCheck, sourceLocation: sourceLocation)
    case .prepareFailed(let error):
        Issue.record("prepare failed: \(error.dumpDescription)", sourceLocation: sourceLocation)
    case .generateFailed(let error):
        expectMessage(error, errorMessage, sourceLocation: sourceLocation)
    case .prepared, .generated:
        Issue.record("generate succeeded", sourceLocation: sourceLocation)
    }
}

func expectNoGenerateError(_ wgsl: some WGSLTestSource, sourceLocation: SourceLocation = #_sourceLocation) {
    let generationResult = compile(wgsl.sourceText, DeviceState(), through: .generate)
    _ = expectGenerated(generationResult, sourceLocation)
}

// MARK: - Self-tests

@Suite
struct WGSLTestWGSLAPITests {
    @Test
    func checkLiteralResumesAtTheStartOfThePreviousMatch() {
        let msl = "let a = vec<float, 2>(0., 0.), b;"
        let start = UInt32(8)
        #expect(checkLiteral("vec<float, 2>(0., 0.),")(msl, 0) == start)
        #expect(checkLiteral("vec<float, 2>(0., 0.),")(msl, start) == start)
        #expect(checkLiteral("b;")(msl, start) == 31)
        performChecks(msl, checkLiteral("vec<float, 2>(0., 0.),"), checkLiteral("vec<float, 2>(0., 0.),"), checkLiteral("b;"))
    }

    @Test
    func checkLiteralReturnsNotFoundOnAMiss() {
        #expect(notFound == UInt32.max)
        withKnownIssue {
            #expect(checkLiteral("missing")("abc", 0) == UInt32.max)
        }
        withKnownIssue {
            #expect(checkLiteral("abc")("abc", UInt32.max) == UInt32.max)
        }
        withKnownIssue {
            #expect(checkLiteral("c")("abc", 4) == UInt32.max)
        }
        #expect(checkLiteral("")("abc", 3) == 3)
        #expect(checkLiteral("c")("abc", 2) == 2)
    }

    @Test
    func checkLiteralUsesUTF16Offsets() {
        let msl = "\u{1D538}\u{E9}-x \u{1D538}x"
        #expect(checkLiteral("x")(msl, 0) == 4)
        #expect(checkLiteral("x")(msl, 5) == 8)
        #expect(checkLiteral("\u{1D538}")(msl, 1) == 6)
    }

    @Test
    func checkResumesAtTheStartOfThePreviousMatch() {
        let msl = "let a = vec<float, 2>(0., 0.), b;"
        let pattern = "vec<float, 2>\\(0\\., 0\\.\\),"
        #expect(check(pattern)(msl, 0) == 8)
        #expect(check(pattern)(msl, 8) == 8)
        #expect(check("[a-z];")(msl, 8) == 31)
        performChecks(msl, check(pattern), check(pattern), checkNot("let"), checkLiteral("vec"))
    }

    @Test
    func DEV_12_checkRecordsAnIssueAndReturnsNotFoundOnAMiss() {
        var results: [UInt32] = []
        withKnownIssue {
            results.append(check("[0-9]")("abc", 0))
            results.append(check("a")("abc", UInt32.max))
            results.append(check("a")("abc", 4))
        }
        #expect(results == [UInt32.max, UInt32.max, UInt32.max])
        withKnownIssue {
            performChecks("abc", check("z"), checkLiteral("a"))
        }
    }

    @Test
    func checkUsesUTF16Offsets() {
        let msl = "\u{1D538}\u{E9}-x \u{1D538}x"
        #expect(check("[x]")(msl, 0) == 4)
        #expect(check("x")(msl, 5) == 8)
        #expect(check("-.")(msl, 0) == 3)
        #expect(check("x$")(msl, 0) == 8)
    }

    @Test
    func checkNotKeepsTheOffset() {
        let msl = "abc abc"
        #expect(checkNot("d")(msl, 2) == 2)
        #expect(checkNotLiteral("d")(msl, 2) == 2)
        #expect(checkNot("a")(msl, 5) == 5)
        #expect(checkNotLiteral("a")(msl, 5) == 5)
        withKnownIssue {
            #expect(checkNot("b")(msl, 2) == 2)
        }
        withKnownIssue {
            #expect(checkNotLiteral("b")(msl, 2) == 2)
        }
        #expect(checkNot("a")(msl, UInt32.max) == UInt32.max)
        #expect(checkNotLiteral("a")(msl, UInt32.max) == UInt32.max)
    }

    @Test(arguments: [UInt32(4), 8])
    func metalCompileCompilesATrivialShader(appleGPUFamily: UInt32) {
        let msl = trivialMSL(requiringAppleGPUFamily: appleGPUFamily)
        #expect(throws: Never.self) {
            _ = try metalCompile(msl, appleGPUFamily: appleGPUFamily).get()
        }
        #expect(throws: (any Error).self) {
            _ = try metalCompile(msl, appleGPUFamily: appleGPUFamily + 1).get()
        }
    }

    @Test
    func metalCompileDefaultsToFamily8AndReportsErrors() {
        #expect(throws: Never.self) {
            _ = try metalCompile(trivialMSL(requiringAppleGPUFamily: 8)).get()
        }
        #expect(throws: (any Error).self) {
            _ = try metalCompile("kernel void test() { undeclared(); }").get()
        }
    }

    @Test
    func onCompileThreadUsesTheRecommendedStackSize() {
        let caller = ObjectIdentifier(Thread.current)
        let observed = onCompileThread { _ in
            CompileThreadObservation(
                thread: ObjectIdentifier(Thread.current),
                stackSize: Thread.current.stackSize,
                stackProbeFrames: CompileThread.recommendedStackSize.map { _ in stackProbe(depth: stackProbeDepth) }
            )
        }
        guard let recommendedStackSize = CompileThread.recommendedStackSize else {
            #expect(observed.thread == caller)
            return
        }
        #expect(observed.thread != caller)
        #expect(observed.stackSize == recommendedStackSize)
        #expect(observed.stackProbeFrames == stackProbeDepth + 1)
    }

    @Test
    func fnAndEnableF16() {
        #expect(fn("return;") == "@compute @workgroup_size(1) fn test() {\nreturn;\n}")
        #expect(enableF16("const x = 1h;") == "enable f16;\n\nconst x = 1h;")
    }

    @Test
    func wtfSourceIs8BitIffASCII() {
        #expect(wtfSource("fn f() {}").isLatin1)
        #expect(wtfSource("fn f() {}").count == 9)
        #expect(!wtfSource("const \u{E9} = 1;").isLatin1)
        #expect(wtfSource("const \u{1D538} = 1;").count == 13)
        #expect("fn f() {}".sourceText.isLatin1)
    }

    @Test
    func fileReadsShaders() {
        let ascii = file("aliases.wgsl")
        #expect(ascii.isLatin1)
        #expect(ascii.count == 1383)
        let utf16 = file("constants-utf16.wgsl")
        #expect(!utf16.isLatin1)
        #expect(utf16.count == 1545)
        var missing = wtfSource("x")
        withKnownIssue {
            missing = file("does-not-exist.wgsl")
        }
        #expect(missing.count == 0)
    }

    @Test
    func configurations() {
        #expect(testsConfiguration.maxBuffersPlusVertexBuffersForVertexStage == 8)
        #expect(testsConfiguration.maxBuffersForFragmentStage == 8)
        #expect(testsConfiguration.maxBuffersForComputeStage == 8)
        #expect(testsConfiguration.maximumCombinedWorkgroupVariablesSize == 16_384)
        #expect(testsConfiguration.supportedFeatures == [.shaderF16, .clipDistances, .primitiveIndex])
        #expect(noFeaturesConfiguration.maxBuffersPlusVertexBuffersForVertexStage == 8)
        #expect(noFeaturesConfiguration.maxBuffersForFragmentStage == 8)
        #expect(noFeaturesConfiguration.maxBuffersForComputeStage == 8)
        #expect(noFeaturesConfiguration.maximumCombinedWorkgroupVariablesSize == 16_384)
        #expect(noFeaturesConfiguration.supportedFeatures.isEmpty)
    }

    @Test
    func expectMessageComparesCodeUnits() {
        let precomposed = CompilationMessage("caf\u{E9}", span: .empty)
        expectMessage(precomposed, "caf\u{E9}")
        #expect("caf\u{E9}" == "cafe\u{301}")
        withKnownIssue {
            expectMessage(precomposed, "cafe\u{301}")
        }
        withKnownIssue {
            expectMessage(nil, "")
        }
    }
}

private struct CompileThreadObservation: Sendable {
    let thread: ObjectIdentifier
    let stackSize: Int
    let stackProbeFrames: Int?
}

/// Overflows a 512 KiB thread at -Onone (between 512 KiB and 2 MiB of frames).
private let stackProbeDepth = 8_192

private func stackProbe(depth: Int) -> Int {
    var frame = (depth, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    frame.15 = depth
    guard depth > 0 else {
        return 1
    }
    return stackProbe(depth: depth - 1) + 1 + frame.15 - frame.0
}

private func trivialMSL(requiringAppleGPUFamily appleGPUFamily: UInt32) -> String {
    """
    #include <metal_stdlib>
    using namespace metal;
    #if __wgslMetalAppleGPUFamily != \(appleGPUFamily)
    #error "unexpected __wgslMetalAppleGPUFamily"
    #endif
    kernel void test(device uint* output [[buffer(0)]]) { output[0] = __wgslMetalAppleGPUFamily; }
    """
}
