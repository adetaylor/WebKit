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

#include "Helpers/Test.h"
#include "SecurityPoliciesBenchInputs.h"
#include <cstdio>
#include <cstdlib>
#include <wtf/MonotonicTime.h>
#include <wtf/StdLibExtras.h>

// Each test runs one pass over its inputs and checks the checksum of the policies' outputs. With
// WEBKIT_RUN_BENCHMARKS=1 in the environment, it then times a fixed number of passes and prints
// "<Test>: <ms> ms <MB/s> MB/s checksum=<checksum>".

namespace TestWebKitAPI {

namespace SecurityPoliciesBench {

static bool shouldRunBenchmark()
{
    auto* value = std::getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && *value != '0';
}

template<typename Inputs, typename Pass>
static void runShape(ASCIILiteral shape, const Inputs& inputs, uint64_t bytesPerPass, unsigned benchmarkPasses, std::optional<uint64_t> expectedChecksum, const Pass& pass)
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

    if (expectedChecksum)
        EXPECT_EQ(checksum, *expectedChecksum) << shape.characters() << " checksum=0x" << std::hex << checksum;
}

} // namespace SecurityPoliciesBench

TEST(SecurityPoliciesBench, CORSChecks)
{
    auto inputs = SecurityPoliciesBench::makeCORSInputs();
    SecurityPoliciesBench::CheckDisablers disablers;
    SecurityPoliciesBench::runShape("CORSChecks"_s, inputs, inputs.bytes, 4000, 0x8e56ecb5286d65fbULL, [&](auto& shapeInputs, auto& sink) {
        SecurityPoliciesBench::runCORSChecksPass(shapeInputs, disablers, sink);
    });
}

TEST(SecurityPoliciesBench, PreflightCache)
{
    auto inputs = SecurityPoliciesBench::makePreflightCacheInputs();
    SecurityPoliciesBench::runShape("PreflightCache"_s, inputs, inputs.bytes, 11000, 0x9b54b175205bdb4cULL, [](auto& shapeInputs, auto& sink) {
        SecurityPoliciesBench::runPreflightCachePass(shapeInputs, sink);
    });
}

TEST(SecurityPoliciesBench, ResponseFiltering)
{
    auto inputs = SecurityPoliciesBench::makeResponseFilteringInputs();
    SecurityPoliciesBench::runShape("ResponseFiltering"_s, inputs, inputs.bytes, 2600, 0xa08897e91d6f0e34ULL, [](auto& shapeInputs, auto& sink) {
        SecurityPoliciesBench::runResponseFilteringPass(shapeInputs, sink);
    });
}

TEST(SecurityPoliciesBench, PolicyHeaders)
{
    auto inputs = SecurityPoliciesBench::makePolicyHeadersInputs();
    SecurityPoliciesBench::runShape("PolicyHeaders"_s, inputs, inputs.bytes, 3000, 0x6c79b60e156bc8d6ULL, [](auto& shapeInputs, auto& sink) {
        SecurityPoliciesBench::runPolicyHeadersPass(shapeInputs, sink);
    });
}

TEST(SecurityPoliciesBench, IntegrityMetadata)
{
    auto inputs = SecurityPoliciesBench::makeIntegrityMetadataInputs();
    SecurityPoliciesBench::runShape("IntegrityMetadata"_s, inputs, inputs.bytes, 350, 0xfbe724af1e688218ULL, [](auto& shapeInputs, auto& sink) {
        SecurityPoliciesBench::runIntegrityMetadataPass(shapeInputs, sink);
    });
}

TEST(SecurityPoliciesBench, SandboxTokens)
{
    auto inputs = SecurityPoliciesBench::makeSandboxTokensInputs();
    SecurityPoliciesBench::runShape("SandboxTokens"_s, inputs, inputs.bytes, 1400, 0x294a209ca4a067c4ULL, [](auto& shapeInputs, auto& sink) {
        SecurityPoliciesBench::runSandboxTokensPass(shapeInputs, sink);
    });
}

TEST(SecurityPoliciesBench, PermissionsPolicy)
{
    // Feature names behind ENABLE(DEVICE_ORIENTATION), ENABLE(WEB_AUTHN) and ENABLE(WEBXR) are parsed only where those are
    // enabled, so the checksum is recorded for a build with all three.
#if ENABLE(DEVICE_ORIENTATION) && ENABLE(WEB_AUTHN) && ENABLE(WEBXR)
    constexpr std::optional<uint64_t> expectedChecksum = 0xa887d9dce4c8e9a0ULL;
#else
    constexpr std::optional<uint64_t> expectedChecksum;
#endif
    auto inputs = SecurityPoliciesBench::makePermissionsPolicyInputs();
    SecurityPoliciesBench::runShape("PermissionsPolicy"_s, inputs, inputs.bytes, 500, expectedChecksum, [](auto& shapeInputs, auto& sink) {
        SecurityPoliciesBench::runPermissionsPolicyPass(shapeInputs, sink);
    });
}

TEST(SecurityPoliciesBench, FetchHeaders)
{
    auto inputs = SecurityPoliciesBench::makeFetchHeadersInputs();
    SecurityPoliciesBench::runShape("FetchHeaders"_s, inputs, inputs.bytes, 1400, 0x14749305fb4f6f91ULL, [](auto& shapeInputs, auto& sink) {
        SecurityPoliciesBench::runFetchHeadersPass(shapeInputs, sink);
    });
}

TEST(SecurityPoliciesBench, CacheFreshness)
{
    auto inputs = SecurityPoliciesBench::makeCacheFreshnessInputs();
    SecurityPoliciesBench::runShape("CacheFreshness"_s, inputs, inputs.bytes, 600, 0x3c965c4c0232cc67ULL, [](auto& shapeInputs, auto& sink) {
        SecurityPoliciesBench::runCacheFreshnessPass(shapeInputs, sink);
    });
}

TEST(SecurityPoliciesBench, ReferrerHeaders)
{
    auto inputs = SecurityPoliciesBench::makeReferrerHeadersInputs();
    SecurityPoliciesBench::runShape("ReferrerHeaders"_s, inputs, inputs.bytes, 4500, 0xf6a3bf152a90e5c6ULL, [](auto& shapeInputs, auto& sink) {
        SecurityPoliciesBench::runReferrerHeadersPass(shapeInputs, sink);
    });
}

TEST(SecurityPoliciesBench, ResponseMix)
{
    auto inputs = SecurityPoliciesBench::makeResponseMixInputs();
    SecurityPoliciesBench::runShape("ResponseMix"_s, inputs, inputs.bytes, 2300, 0xecf9d3a718336438ULL, [](auto& shapeInputs, auto& sink) {
        SecurityPoliciesBench::runResponseMixPass(shapeInputs, sink);
    });
}

} // namespace TestWebKitAPI
