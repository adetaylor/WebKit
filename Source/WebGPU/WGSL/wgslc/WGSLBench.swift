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
import WGSL

/// `wgslc --bench[=N] [--bench-plan=check|production] <file>...`: per input, one JSON line on standard output with the
/// median, p90 and min over N measured repetitions (after 3 warm-ups) of each phase's thread CPU time and of the total wall time,
/// and the MSL size.
///
/// Every repetition compiles a fresh module with WebGPU's limits and features. `check` runs staticCheck (createShaderModule);
/// `production` then runs, for each entry point in order, what Pipeline.mm and ComputePipeline.mm do: prepare with a default
/// layout, generate for Apple GPU family 9 (which rolls back), and evaluate the workgroup size of a compute entry point. The phases
/// are `check`, `prepare`, `generate` and `evaluate`, summed over the entry points, and `total`.
struct WGSLBench: Sendable {
    enum Plan: Sendable {
        case check
        case production
    }

    static let warmUpRepetitions = 3

    let repetitions: Int
    let plan: Plan
    let files: [String]

    /// Nil unless an argument is `--bench` or `--bench=N`; exits on a malformed bench command line.
    init?(_ arguments: [String]) {
        guard arguments.dropFirst().contains(where: { $0 == "--bench" || $0.utf8.starts(with: "--bench=".utf8) }) else {
            return nil
        }
        var repetitions = 21
        var plan = Plan.production
        var files: [String] = []
        for argument in arguments.dropFirst() {
            if argument == "--bench" {
                continue
            }
            if argument.utf8.starts(with: "--bench=".utf8) {
                guard let count = Int(String(decoding: argument.utf8.dropFirst(8), as: UTF8.self)), count > 0 else {
                    Self.printUsageStatement("Invalid repetition count: \(argument)")
                }
                repetitions = count
                continue
            }
            if argument == "--bench-plan=check" {
                plan = .check
                continue
            }
            if argument == "--bench-plan=production" {
                plan = .production
                continue
            }
            if argument.hasPrefix("-") {
                Self.printUsageStatement("Unsupported option in bench mode: \(argument)")
            }
            files.append(argument)
        }
        if files.isEmpty {
            Self.printUsageStatement("No input files")
        }
        self.repetitions = repetitions
        self.plan = plan
        self.files = files
    }

    private static func printUsageStatement(_ message: String) -> Never {
        dataLogLn(message)
        dataLogLn("Usage: wgslc --bench[=N] [--bench-plan=check|production] <file>...")
        exit(EXIT_FAILURE)
    }

    func run() -> Int32 {
        var status = EXIT_SUCCESS
        for file in files {
            guard let contents = readEntireFile(fromLatin1(file)) else {
                dataLogLn("Failed to open \(fromLatin1(file))")
                printLine(JSONObject().string("file", file).string("status", "unreadable"))
                status = EXIT_FAILURE
                continue
            }
            printLine(measure(file, SourceText(decodingUTF8WithLatin1Fallback: contents)))
        }
        return status
    }

    private func measure(_ file: String, _ source: SourceText) -> JSONObject {
        var samples: [Repetition] = []
        samples.reserveCapacity(repetitions)
        for index in 0..<(Self.warmUpRepetitions + repetitions) {
            let repetition = compile(source)
            if index >= Self.warmUpRepetitions {
                samples.append(repetition)
            }
        }
        guard let last = samples.last else {
            return JSONObject().string("file", file).string("status", "no-repetitions")
        }

        var result = JSONObject()
            .string("file", file)
            .string("plan", plan == .check ? "check" : "production")
            .string("status", last.checkFailed ? "check-failed" : "ok")
            .number("reps", UInt64(repetitions))
            .number("warmups", UInt64(Self.warmUpRepetitions))
        var phases = JSONObject().object("check", Statistics(samples.map(\.check)).json)
        if plan == .production {
            result = result.number("entry_points", UInt64(last.entryPoints))
                .number("prepare_failures", UInt64(last.prepareFailures))
                .number("generate_failures", UInt64(last.generateFailures))
                .number("msl_bytes", UInt64(last.mslBytes))
            phases = phases.object("prepare", Statistics(samples.map(\.prepare)).json)
                .object("generate", Statistics(samples.map(\.generate)).json)
                .object("evaluate", Statistics(samples.map(\.evaluate)).json)
        }
        phases = phases.object("total", Statistics(samples.map(\.total)).json)

        return result.object("thread_cpu_ns", phases)
            .object("wall_ns", JSONObject().object("total", Statistics(samples.map(\.wall)).json))
    }

    private func compile(_ source: SourceText) -> Repetition {
        var repetition = Repetition()
        let clock = ContinuousClock()
        let wallStart = clock.now
        let start = threadCPUTime()

        let outcome = staticCheck(source, configuration: Self.configuration)
        let checked = threadCPUTime()
        repetition.check = checked &- start

        switch consume outcome {
        case .failure:
            repetition.checkFailed = true
        case .success(var module):
            if plan == .production {
                let entryPoints = module.entryPoints
                repetition.entryPoints = entryPoints.count
                for entryPoint in entryPoints {
                    module = compile(entryPoint, consume module, &repetition)
                }
            }
        }

        repetition.total = threadCPUTime() &- start
        repetition.wall = nanoseconds(clock.now - wallStart)
        return repetition
    }

    private func compile(_ entryPoint: EntryPointIO, _ module: consuming CheckedModule, _ repetition: inout Repetition) -> CheckedModule {
        var start = threadCPUTime()
        switch module.prepare(entryPoints: [entryPoint.name]) {
        case .failed(_, let rolledBack):
            repetition.prepare &+= threadCPUTime() &- start
            repetition.prepareFailures += 1
            return rolledBack
        case .prepared(let prepared):
            let prepareEnd = threadCPUTime()
            repetition.prepare &+= prepareEnd &- start
            start = prepareEnd

            switch prepared.generate(deviceState: Self.deviceState) {
            case .failed(_, let rolledBack):
                repetition.generate &+= threadCPUTime() &- start
                repetition.generateFailures += 1
                return rolledBack
            case .generated(let library, var rolledBack):
                let generateEnd = threadCPUTime()
                repetition.generate &+= generateEnd &- start
                repetition.mslBytes += library.msl.utf8.count

                if entryPoint.stage == .compute {
                    _ = rolledBack.evaluateWorkgroupSize(entryPoint: entryPoint.name, overrides: library.resolvedOverrides)
                    repetition.evaluate &+= threadCPUTime() &- generateEnd
                }
                return rolledBack
            }
        }
    }

    /// Device limits and features like those WebGPU passes.
    private static let configuration = Configuration(
        maxBuffersPlusVertexBuffersForVertexStage: 30,
        maxBuffersForFragmentStage: 11,
        maxBuffersForComputeStage: 11,
        maximumCombinedWorkgroupVariablesSize: 32_768,
        supportedFeatures: [.clipDistances, .shaderF16, .primitiveIndex, .subgroups]
    )

    private static let deviceState = DeviceState(appleGPUFamily: 9, shaderValidationEnabled: false)
}

private struct Repetition {
    var check: UInt64 = 0
    var prepare: UInt64 = 0
    var generate: UInt64 = 0
    var evaluate: UInt64 = 0
    var total: UInt64 = 0
    var wall: UInt64 = 0
    var checkFailed = false
    var entryPoints = 0
    var prepareFailures = 0
    var generateFailures = 0
    var mslBytes = 0
}

private struct Statistics {
    let median: UInt64
    let p90: UInt64
    let min: UInt64

    init(_ values: [UInt64]) {
        let sorted = values.sorted()
        let count = sorted.count
        median = count % 2 == 1 ? sorted[count / 2] : (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        // Nearest rank: the ceil(0.9 * count)-th smallest.
        p90 = sorted[(9 * count + 9) / 10 - 1]
        min = sorted[0]
    }

    var json: JSONObject {
        JSONObject().number("median", median).number("p90", p90).number("min", min)
    }
}

/// A JSON object written in insertion order.
private struct JSONObject {
    private var members: [String] = []

    func string(_ key: String, _ value: String) -> JSONObject {
        appending(key, Self.quoted(value))
    }

    func number(_ key: String, _ value: UInt64) -> JSONObject {
        appending(key, String(value))
    }

    func object(_ key: String, _ value: JSONObject) -> JSONObject {
        appending(key, value.text)
    }

    var text: String { "{" + members.joined(separator: ",") + "}" }

    private func appending(_ key: String, _ value: String) -> JSONObject {
        var result = self
        result.members.append(Self.quoted(key) + ":" + value)
        return result
    }

    private static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\t":
                result += "\\t"
            case "\r":
                result += "\\r"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

private func printLine(_ object: JSONObject) {
    try? FileHandle.standardOutput.write(contentsOf: Data((object.text + "\n").utf8))
}

private func threadCPUTime() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
}

private func nanoseconds(_ duration: Duration) -> UInt64 {
    let (seconds, attoseconds) = duration.components
    return UInt64(clamping: seconds) &* 1_000_000_000 &+ UInt64(clamping: attoseconds / 1_000_000_000)
}
