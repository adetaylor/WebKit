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

#include "HTTPHeaderParsersBenchInputs.h"
#include "Helpers/Test.h"
#include <cstdio>
#include <cstdlib>
#include <wtf/MonotonicTime.h>
#include <wtf/StdLibExtras.h>

// Each test runs one pass over its inputs and checks the checksum of the parsers' outputs. With
// WEBKIT_RUN_BENCHMARKS=1 in the environment, it then times a fixed number of passes and prints
// "<Test>: <ms> ms <MB/s> MB/s checksum=<checksum>".

namespace TestWebKitAPI {

namespace HTTPHeaderParsersBench {

static bool shouldRunBenchmark()
{
    auto* value = std::getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && *value != '0';
}

template<typename Inputs, typename Pass>
static void runShape(ASCIILiteral shape, const Inputs& inputs, uint64_t bytesPerPass, unsigned benchmarkPasses, uint64_t expectedChecksum, const Pass& pass)
{
    Digest digest;
    pass(inputs, digest);
    uint64_t checksum = digest.value();

    if (shouldRunBenchmark()) {
        Tally tally;
        auto start = WTF::MonotonicTime::now();
        for (unsigned i = 0; i < benchmarkPasses; ++i)
            pass(inputs, tally);
        auto elapsed = WTF::MonotonicTime::now() - start;
        double megabytes = static_cast<double>(bytesPerPass) * benchmarkPasses / 1000000;
        SAFE_PRINTF("%s: %.1f ms %.2f MB/s checksum=0x%016llx\n", shape, elapsed.milliseconds(), megabytes / elapsed.seconds(), static_cast<unsigned long long>(checksum));
        fflush(stdout);
    }

    EXPECT_EQ(checksum, expectedChecksum) << shape.characters() << " checksum=0x" << std::hex << checksum;
}

} // namespace HTTPHeaderParsersBench

TEST(HTTPHeaderParsersBench, MIMETypes)
{
    auto inputs = HTTPHeaderParsersBench::makeMIMETypeInputs();
    HTTPHeaderParsersBench::runShape("MIMETypes"_s, inputs, inputs.bytes, 1000, 0x48F53185034B3CC7ULL, [](auto& shapeInputs, auto& sink) {
        HTTPHeaderParsersBench::runMIMETypesPass(shapeInputs, sink);
    });
}

TEST(HTTPHeaderParsersBench, RequestHeaderChecks)
{
    auto inputs = HTTPHeaderParsersBench::makeRequestHeaderInputs();
    HTTPHeaderParsersBench::runShape("RequestHeaderChecks"_s, inputs, inputs.bytes, 700, 0xB4BDB386684247C5ULL, [](auto& shapeInputs, auto& sink) {
        HTTPHeaderParsersBench::runRequestHeaderChecksPass(shapeInputs, sink);
    });
}

TEST(HTTPHeaderParsersBench, StructuredFields)
{
    auto inputs = HTTPHeaderParsersBench::makeStructuredFieldInputs();
    HTTPHeaderParsersBench::runShape("StructuredFields"_s, inputs, inputs.bytes, 2200, 0x84495554B5873819ULL, [](auto& shapeInputs, auto& sink) {
        HTTPHeaderParsersBench::runStructuredFieldsPass(shapeInputs, sink);
    });
}

TEST(HTTPHeaderParsersBench, LinkHeaders)
{
    auto inputs = HTTPHeaderParsersBench::makeLinkHeaderInputs();
    HTTPHeaderParsersBench::runShape("LinkHeaders"_s, inputs, inputs.bytes, 2300, 0xC3DCDC099C5BE37BULL, [](auto& shapeInputs, auto& sink) {
        HTTPHeaderParsersBench::runLinkHeadersPass(shapeInputs, sink);
    });
}

TEST(HTTPHeaderParsersBench, CacheControl)
{
    auto inputs = HTTPHeaderParsersBench::makeCacheControlInputs();
    HTTPHeaderParsersBench::runShape("CacheControl"_s, inputs, inputs.bytes, 1500, 0x4ECB8A1DBE53E3D9ULL, [](auto& shapeInputs, auto& sink) {
        HTTPHeaderParsersBench::runCacheControlPass(shapeInputs, sink);
    });
}

TEST(HTTPHeaderParsersBench, RangesAndLengths)
{
    auto inputs = HTTPHeaderParsersBench::makeRangeInputs();
    HTTPHeaderParsersBench::runShape("RangesAndLengths"_s, inputs, inputs.bytes, 3500, 0xC7D2B7969771459BULL, [](auto& shapeInputs, auto& sink) {
        HTTPHeaderParsersBench::runRangesAndLengthsPass(shapeInputs, sink);
    });
}

TEST(HTTPHeaderParsersBench, HeaderLines)
{
    auto inputs = HTTPHeaderParsersBench::makeHeaderLineInputs();
    HTTPHeaderParsersBench::runShape("HeaderLines"_s, inputs, 2 * inputs.data.size(), 2700, 0xE460DEC3909F2B74ULL, [](auto& shapeInputs, auto& sink) {
        HTTPHeaderParsersBench::runHeaderLinesPass(shapeInputs, sink);
    });
}

TEST(HTTPHeaderParsersBench, ServerTiming)
{
    auto inputs = HTTPHeaderParsersBench::makeServerTimingInputs();
    HTTPHeaderParsersBench::runShape("ServerTiming"_s, inputs, inputs.bytes, 1200, 0xE1AA61180724D651ULL, [](auto& shapeInputs, auto& sink) {
        HTTPHeaderParsersBench::runServerTimingPass(shapeInputs, sink);
    });
}

TEST(HTTPHeaderParsersBench, ResponseMix)
{
    auto inputs = HTTPHeaderParsersBench::makeResponseMixInputs();
    HTTPHeaderParsersBench::runShape("ResponseMix"_s, inputs, inputs.bytes, 1100, 0xAC690B595FF55FF7ULL, [](auto& shapeInputs, auto& sink) {
        HTTPHeaderParsersBench::runResponseMixPass(shapeInputs, sink);
    });
}

} // namespace TestWebKitAPI
