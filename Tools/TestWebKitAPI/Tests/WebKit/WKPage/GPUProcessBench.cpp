/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"

#if WK_HAVE_C_SPI && ENABLE(GPU_PROCESS) && ENABLE(IPC_TESTING_API)

#include "Helpers/PlatformUtilities.h"
#include "Helpers/PlatformWebView.h"
#include "Helpers/Test.h"
#include <WebKit/WKPreferencesRefPrivate.h>
#include <WebKit/WKRetainPtr.h>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <string_view>
#include <wtf/FileSystem.h>
#include <wtf/MonotonicTime.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

// GPU process benchmarks over the IPC testing API, read from LayoutTests/ipc/coreipc.js in the source tree:
// RenderingBackendResourceChurn creates, draws into and releases 10000 image buffers, and GPUProcessStartup times a
// fresh GPU process's first rendering backend reply. Each TEST runs once and compares the digest of what it read back
// with the value recorded below. With WEBKIT_RUN_BENCHMARKS=1 it repeats for at least a second and prints
//     <benchmark>: <ms> ms <n> MB/s checksum=<digest>

namespace TestWebKitAPI {

namespace {

struct RecordedChecksums {
    std::string_view renderingBackendResourceChurn;
    std::string_view gpuProcessStartup;
};
// Recorded on GTK. The buffer is unaccelerated, so its pixels do not depend on the GL driver.
constexpr RecordedChecksums recordedChecksums { "dbb45570", "a3a71bfc" };

constexpr unsigned churnIterations = 10000;
constexpr unsigned churnBufferSide = 16;
constexpr unsigned startupRepetitions = 30;

bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && std::string_view(value) != "0";
}

// The IPC testing API's JavaScript client, LayoutTests/ipc/coreipc.js, as a classic script: its exports dropped, so its
// classes and functions are global to the page's own script.
std::string coreIPCSource()
{
    String root = String::fromUTF8(getenv("WEBKIT_SRC_DIR") ?: "");
    if (root.isEmpty()) {
        // This file is <root>/Tools/TestWebKitAPI/Tests/WebKit/WKPage/GPUProcessBench.cpp.
        root = String::fromUTF8(__FILE__);
        for (unsigned i = 0; i < 6; ++i)
            root = FileSystem::parentPath(root);
    }
    auto contents = FileSystem::readEntireFile(makeString(root, "/LayoutTests/ipc/coreipc.js"_s));
    if (!contents)
        return { };
    String source = String::fromUTF8(contents->span());
    // Every "export " at the start of a line.
    constexpr auto exportKeyword = "export "_s;
    source = makeStringByReplacingAll(source, makeString('\n', exportKeyword), "\n"_s);
    if (source.startsWith(exportKeyword))
        source = source.substring(exportKeyword.length());
    return source.utf8().toStdString();
}

constexpr auto commonScript = R"JS(
function fnv(bytes) {
    let hash = 0x811c9dc5;
    for (let i = 0; i < bytes.length; ++i)
        hash = Math.imul(hash ^ bytes[i], 0x01000193) >>> 0;
    return hash.toString(16).padStart(8, '0');
}
function fnvString(string) {
    return fnv(new TextEncoder().encode(string));
}
function describe(value) {
    return JSON.stringify(value, (key, member) => typeof member === 'bigint' ? member.toString() : member);
}
let nextIdentifier = 300000;
// The receiver of a context's drawing messages.
// IPC.messages names every message of every port; one the build leaves out has null arguments.
const drawingInterface = IPC.messages.RemoteCGRenderer_Save?.arguments ? 'RemoteCGRenderer' : 'RemoteGraphicsContext';
const identifier = () => nextIdentifier++;
function enumValues(name) {
    const values = { };
    for (const entry of IPC.serializedEnumInfo[name].valueMap)
        values[entry.name] = entry.value;
    return values;
}
async function createBackend() {
    const connection = CoreIPC.newStreamConnection();
    const backendIdentifier = identifier();
    CoreIPC.GPU.GPUConnectionToWebProcess.CreateRenderingBackend(0, { renderingBackendIdentifier: backendIdentifier, connectionHandle: connection });
    return { connection, backendIdentifier, backend: connection.newInterface('RemoteRenderingBackend', backendIdentifier) };
}
function barrier(backend) {
    return new Promise(resolve => backend.GetImageBufferResourceLimitsForTesting({ }, parsedReply => resolve(parsedReply)));
}
)JS"_s;

constexpr auto churnScript = R"JS(
async function churnPass(iterations) {
    const side = SIDE;
    const pixelFormat = enumValues('WebCore::PixelFormat').BGRA8;
    const colorSpace = sRGBColorSpace();
    const { connection, backend } = await createBackend();
    let lastBuffer = 0;
    const start = performance.now();
    for (let i = 0; i < iterations; ++i) {
        const bufferIdentifier = identifier();
        const contextIdentifier = identifier();
        backend.CreateImageBuffer({
            logicalSize: { width: side, height: side }, renderingMode: 0, renderingPurpose: 0, resolutionScale: 1.0, colorSpace,
            bufferFormat: { pixelFormat, useLosslessCompression: 0 }, identifier: bufferIdentifier, contextIdentifier
        });
        const context = connection.newInterface(drawingInterface, contextIdentifier);
        context.Save({ });
        context.FillRect({ rect: { location: { x: i % 8, y: i % 5 }, size: { width: 8, height: 6 } }, requiresClipToRect: 0 });
        context.FillEllipse({ rect: { location: { x: i % 3, y: i % 7 }, size: { width: 9, height: 7 } } });
        context.Restore({ });
        if (i + 1 == iterations)
            lastBuffer = bufferIdentifier;
        else
            backend.ReleaseImageBuffer({ identifier: bufferIdentifier });
    }
    const limits = await barrier(backend);
    const milliseconds = performance.now() - start;

    const imageBuffer = connection.newInterface('RemoteImageBuffer', lastBuffer);
    imageBuffer.FlushContext({ });
    const size = side * side * 4;
    const memory = IPC.createSharedMemory(size);
    memory.writeBytes(new Uint8Array(size).fill(0xAA));
    imageBuffer.GetPixelBufferWithNewMemory({
        handle: { protection: 'ReadWrite', handle: memory },
        outputFormat: { alphaFormat: 0, pixelFormat, colorSpace },
        srcPoint: { x: 0, y: 0 }, srcSize: { width: side, height: side }
    });
    const digest = fnv(new Uint8Array(memory.readBytes(0, size)));
    connection.connection.invalidate();
    return milliseconds + '|' + digest;
}
function startBench(iterations) {
    window.benchResult = null;
    churnPass(iterations).then(result => { window.benchResult = result; }, error => { window.benchResult = 'error: ' + error; });
}
)JS"_s;

constexpr auto startupScript = R"JS(
async function startupPass() {
    const start = performance.now();
    const { connection, backend } = await createBackend();
    const limits = await barrier(backend);
    const milliseconds = performance.now() - start;
    connection.connection.invalidate();
    return milliseconds + '|' + fnvString(describe(limits));
}
function startBench() {
    window.benchResult = null;
    startupPass().then(result => { window.benchResult = result; }, error => { window.benchResult = 'error: ' + error; });
}
)JS"_s;

std::string replaceAll(std::string text, std::string_view from, const std::string& to)
{
    for (size_t position = text.find(from); position != std::string::npos; position = text.find(from, position + to.size()))
        text.replace(position, from.size(), to);
    return text;
}

struct EvaluationResult {
    std::string value;
    bool done { false };
};

void didEvaluate(WKTypeRef result, WKErrorRef, void* context)
{
    auto* evaluation = static_cast<EvaluationResult*>(context);
    if (result && WKGetTypeID(result) == WKStringGetTypeID())
        evaluation->value = Util::toSTD(static_cast<WKStringRef>(result));
    evaluation->done = true;
}

std::string evaluate(WKPageRef page, const std::string& script)
{
    EvaluationResult evaluation;
    WKPageEvaluateJavaScriptInMainFrame(page, Util::toWK(script.c_str()).get(), &evaluation, didEvaluate);
    Util::run(&evaluation.done);
    return evaluation.value;
}

bool didFinishLoading;

void didFinishNavigation(WKPageRef, WKNavigationRef, WKTypeRef, const void*)
{
    didFinishLoading = true;
}

struct Measurement {
    bool succeeded { false };
    double milliseconds { 0 };
    std::string digest;
};

// A page in a fresh process pool whose script defines startBench(...), which leaves "<ms>|<digest>" or "error: ..." in
// window.benchResult.
class BenchPage {
public:
    explicit BenchPage(const std::string& html)
        : m_context(adoptWK(WKContextCreateWithConfiguration(nullptr)))
    {
        auto configuration = adoptWK(WKPageConfigurationCreate());
        WKPageConfigurationSetContext(configuration.get(), m_context.get());
        auto preferences = adoptWK(WKPreferencesCreate());
        WKPageConfigurationSetPreferences(configuration.get(), preferences.get());
        WKPreferencesSetBoolValueForKeyForTesting(preferences.get(), true, Util::toWK("IPCTestingAPIEnabled").get());
        WKPreferencesSetBoolValueForKeyForTesting(preferences.get(), false, Util::toWK("UseGPUProcessForDOMRenderingEnabled").get());
        m_webView = makeUnique<PlatformWebView>(configuration.get());

        WKPageNavigationClientV0 navigationClient;
        zeroBytes(navigationClient);
        navigationClient.base.version = 0;
        navigationClient.didFinishNavigation = didFinishNavigation;
        WKPageSetPageNavigationClient(m_webView->page(), &navigationClient.base);

        didFinishLoading = false;
        WKPageLoadHTMLString(m_webView->page(), Util::toWK(html.c_str()).get(), adoptWK(WKURLCreateWithUTF8CString("about:blank")).get());
        Util::run(&didFinishLoading);
    }

    Measurement run(const std::string& startCall)
    {
        auto page = m_webView->page();
        evaluate(page, startCall + "; 'started'");
        MonotonicTime deadline = MonotonicTime::now() + 120_s;
        std::string result;
        do {
            Util::runFor(0.01_s);
            result = evaluate(page, "String(window.benchResult)");
        } while (result == "null" && MonotonicTime::now() < deadline);

        Measurement measurement;
        auto separator = result.find('|');
        if (separator == std::string::npos) {
            ADD_FAILURE() << "benchmark script did not finish: " << result;
            return measurement;
        }
        measurement.succeeded = true;
        measurement.milliseconds = atof(result.substr(0, separator).c_str());
        measurement.digest = result.substr(separator + 1);
        return measurement;
    }

private:
    WKRetainPtr<WKContextRef> m_context;
    std::unique_ptr<PlatformWebView> m_webView;
};

std::string ipcPage(const std::string& script)
{
    return "<body></body><script>" + coreIPCSource() + "</script><script>" + std::string(commonScript.characters()) + script + "</script>";
}

void printResult(ASCIILiteral name, double milliseconds, double bytes, const std::string& digest)
{
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%s\n", name, milliseconds, bytes / (milliseconds / 1000) / 1e6, ASCIICString(digest));
}

} // namespace

TEST(GPUProcessBench, RenderingBackendResourceChurn)
{
    BenchPage page(ipcPage(replaceAll(std::string(churnScript.characters()), "SIDE", std::to_string(churnBufferSide))));
    auto start = "startBench(" + std::to_string(churnIterations) + ")";

    auto first = page.run(start);
    ASSERT_TRUE(first.succeeded);
    EXPECT_EQ(first.digest, std::string(recordedChecksums.renderingBackendResourceChurn)) << "checksum=" << first.digest;

    if (!runsBenchmarks())
        return;

    unsigned passes = 0;
    double milliseconds = 0;
    do {
        auto pass = page.run(start);
        ASSERT_TRUE(pass.succeeded);
        EXPECT_EQ(pass.digest, first.digest);
        milliseconds += pass.milliseconds;
        ++passes;
    } while (milliseconds < 1000);
    printResult("RenderingBackendResourceChurn"_s, milliseconds, static_cast<double>(churnBufferSide) * churnBufferSide * 4 * churnIterations * passes, first.digest);
}

TEST(GPUProcessBench, GPUProcessStartup)
{
    unsigned repetitions = runsBenchmarks() ? startupRepetitions : 1;
    double milliseconds = 0;
    std::string firstDigest;
    for (unsigned i = 0; i < repetitions; ++i) {
        // A fresh process pool each time: the web process and the GPU process are both new.
        BenchPage page(ipcPage(std::string(startupScript.characters())));
        auto measurement = page.run("startBench()");
        ASSERT_TRUE(measurement.succeeded);
        if (!i) {
            firstDigest = measurement.digest;
            EXPECT_EQ(firstDigest, std::string(recordedChecksums.gpuProcessStartup)) << "checksum=" << firstDigest;
        } else
            EXPECT_EQ(measurement.digest, firstDigest);
        milliseconds += measurement.milliseconds;
    }

    if (!runsBenchmarks())
        return;

    printResult("GPUProcessStartup"_s, milliseconds, 0, firstDigest);
    SAFE_PRINTF("GPUProcessStartup mean of one startup: %.2f ms over %u startups\n", milliseconds / repetitions, repetitions);
}

} // namespace TestWebKitAPI

#endif // WK_HAVE_C_SPI && ENABLE(GPU_PROCESS) && ENABLE(IPC_TESTING_API)
