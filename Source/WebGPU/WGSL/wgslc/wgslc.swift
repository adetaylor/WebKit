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

import Foundation
@_spi(Testing) import WGSL

private func printUsageStatement(_ help: Bool = false) -> Never {
    printToStandardError("Usage: wgsl [options] <file> [entrypoint]\n")
    printToStandardError("  -h|--help  Prints this help message\n")
    printToStandardError("  --dump-ast-after-checking  Dumps the AST after parsing and checking\n")
    printToStandardError("  --dump-ast-at-end  Dumps the AST after generating code\n")
    printToStandardError("  --dump-generated-code  Dumps the generated Metal code\n")
    printToStandardError("  --apple-gpu-family=N  Sets the value for the Apple GPU family (default: 4)\n")
    printToStandardError("  --enable-shader-validation  Enables Metal shader validation (default: false)\n")
    printToStandardError("\n")

    exit(help ? EXIT_SUCCESS : EXIT_FAILURE)
}

private struct CommandLine {
    private(set) var file = ""
    private(set) var entrypoint = ""
    private(set) var dumpASTAfterCheck = false
    private(set) var dumpASTAtEnd = false
    private(set) var dumpGeneratedCode = false
    private(set) var enableShaderValidation = false
    private(set) var appleGPUFamily: UInt32 = 4

    init(_ arguments: [String]) {
        parseArguments(arguments)
    }

    private mutating func parseArguments(_ arguments: [String]) {
        var file: String?
        var entrypoint: String?
        for arg in arguments.dropFirst() {
            if matches(arg, "-h") || matches(arg, "--help") {
                printUsageStatement(true)
            }

            if matches(arg, "--dump-ast-after-checking") {
                dumpASTAfterCheck = true
                continue
            }

            if matches(arg, "--dump-ast-at-end") {
                dumpASTAtEnd = true
                continue
            }

            if matches(arg, "--dump-generated-code") {
                dumpGeneratedCode = true
                continue
            }

            if arg.utf8.starts(with: "--apple-gpu-family=".utf8) {
                let family = atoiValue(arg.utf8.dropFirst(19))
                if family < 4 || family > 9 {
                    printToStandardError("Invalid Apple GPU family: \(family)\n")
                    exit(EXIT_FAILURE)
                }
                appleGPUFamily = UInt32(family)
                continue
            }

            if matches(arg, "--enable-shader-validation") {
                enableShaderValidation = true
                continue
            }

            if file == nil {
                file = arg
            } else if entrypoint == nil {
                entrypoint = arg
            } else {
                printUsageStatement(false)
            }
        }

        guard let file else {
            printUsageStatement(false)
        }
        self.file = file

        self.entrypoint = entrypoint ?? "_"
    }
}

private func runWGSL(_ options: CommandLine) -> Int32 {
    let configuration = Configuration(supportedFeatures: Features(names: ["shader-f16", "clip-distances", "subgroups"]))

    let fileName = fromLatin1(options.file)
    guard let readResult = readEntireFile(fileName) else {
        dataLogLn("Failed to open \(fileName)")
        return EXIT_FAILURE
    }

    let source = SourceText(decodingUTF8WithLatin1Fallback: readResult)

    switch staticCheck(source, configuration: configuration) {
    case .failure(let failedCheck):
        for error in failedCheck.errors {
            dataLogLn(error.dumpDescription)
        }
        return EXIT_FAILURE
    case .success(let shaderModule):
        if options.dumpASTAfterCheck {
            dataLogLn(shaderModule.dumpAST())
        }

        let entrypointName = Name(latin1: ContiguousArray(options.entrypoint.utf8))
        var pipelineLayouts: [Name] = []
        if entrypointName != Name("_") {
            pipelineLayouts.append(entrypointName)
        } else {
            for entryPoint in shaderModule.entryPoints {
                pipelineLayouts.append(entryPoint.name)
            }
        }

        switch shaderModule.prepare(entryPoints: pipelineLayouts) {
        case .failed(let error, _):
            dataLogLn(error.dumpDescription)
            return EXIT_FAILURE
        case .prepared(let result):
            if entrypointName != Name("_") && result.entryPoint(named: entrypointName) == nil {
                dataLogLn("WGSL source does not contain entrypoint named '\(entrypointName)'")
                return EXIT_FAILURE
            }

            // Dumped before generate, which rolls its own scope back: the AST at the end is the prepared one.
            let astAtEnd = options.dumpASTAtEnd ? result.dumpAST() : nil
            let deviceState = DeviceState(appleGPUFamily: options.appleGPUFamily, shaderValidationEnabled: options.enableShaderValidation)
            switch result.generate(overrides: [], deviceState: deviceState) {
            case .failed(let error, _):
                dataLogLn(error.dumpDescription)
                return EXIT_FAILURE
            case .generated(let library, _):
                let msl = library.msl

                if let astAtEnd {
                    dataLogLn(astAtEnd)
                }

                if options.dumpGeneratedCode {
                    // printf("%s") stops at the first NUL.
                    try? FileHandle.standardOutput.write(contentsOf: Data(msl.utf8.prefix { $0 != 0 }))
                }

                return EXIT_SUCCESS
            }
        }
    }
}

@main
enum WGSLC {
    static func main() {
        let arguments = Swift.CommandLine.arguments
        if let bench = WGSLBench(arguments) {
            onCompileThread { bench.run() }
        }

        let commandLine = CommandLine(arguments)
        onCompileThread { runWGSL(commandLine) }
    }
}

// MARK: - Helpers

/// WTF::dataLogLn: the text and a newline on standard error.
func dataLogLn(_ text: String) {
    printToStandardError(text + "\n")
}

func printToStandardError(_ text: String) {
    try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
}

/// Runs `body` and exits with its result, on a thread with `CompileThread.recommendedStackSize` when that is non-nil (the
/// -Onone module needs more than the C++'s 8 MiB main thread), inline otherwise.
func onCompileThread(_ body: @escaping @Sendable () -> Int32) -> Never {
    guard let stackSize = CompileThread.recommendedStackSize else {
        exit(body())
    }
    let thread = Thread { exit(body()) }
    thread.name = "WGSL compile"
    thread.stackSize = stackSize
    thread.start()
    dispatchMain()
}

/// FileSystem::readEntireFile: nil when the file cannot be read, and for an empty file (FileHandle::readAll).
func readEntireFile(_ path: String) -> [UInt8]? {
    guard let contents = FileManager.default.contents(atPath: path), !contents.isEmpty else {
        return nil
    }
    return [UInt8](contents)
}

/// String::fromLatin1 of the argument's bytes.
func fromLatin1(_ argument: String) -> String {
    String(String.UnicodeScalarView(argument.utf8.map { Unicode.Scalar($0) }))
}

private func matches(_ argument: String, _ option: String) -> Bool {
    argument.utf8.elementsEqual(option.utf8)
}

/// atoi as Darwin implements it: (int)strtol(text, NULL, 10).
private func atoiValue(_ text: Substring.UTF8View) -> Int32 {
    var digits = text[...]
    while let first = digits.first, first == UInt8(ascii: " ") || (0x09...0x0D).contains(first) {
        digits.removeFirst()
    }
    var negative = false
    if let sign = digits.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
        negative = sign == UInt8(ascii: "-")
        digits.removeFirst()
    }
    let limit: UInt64 = negative ? UInt64(Int64.max) + 1 : UInt64(Int64.max)
    var magnitude: UInt64 = 0
    for digit in digits {
        guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) else {
            break
        }
        let (product, productOverflow) = magnitude.multipliedReportingOverflow(by: 10)
        let (sum, sumOverflow) = product.addingReportingOverflow(UInt64(digit - UInt8(ascii: "0")))
        magnitude = productOverflow || sumOverflow || sum > limit ? limit : sum
    }
    let value = negative ? 0 &- Int64(truncatingIfNeeded: magnitude) : Int64(truncatingIfNeeded: magnitude)
    return Int32(truncatingIfNeeded: value)
}
