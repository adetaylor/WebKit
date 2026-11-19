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

#import "config.h"

#if ENABLE(WEB_AUTHN) && HAVE(UNIFIED_ASC_AUTH_UI)

#import "Helpers/PlatformUtilities.h"
#import "Helpers/Test.h"
#import "Helpers/cocoa/TestWKWebView.h"
#import "Helpers/cocoa/WKWebViewConfigurationExtras.h"
#import <WebKit/WKWebViewConfigurationPrivate.h>
#import <WebKit/_WKWebAuthenticationPanel.h>
#import <wtf/MonotonicTime.h>
#import <wtf/RetainPtr.h>
#import <wtf/Vector.h>
#import <wtf/text/WTFString.h>

// The benchmark that drives CtapAuthenticator over the mock HID device in the UI process: a makeCredential ceremony
// whose device responses are canned, from the request encoder through the transport to the parsed attestation.
// The page reports "Succeeded!" when the ceremony completes. The checksum covers the number of ceremonies completed,
// since the response bytes are fixed by the page.

namespace TestWebKitAPI {

static constexpr uint64_t kUnrecorded = 0;
// A ceremony takes a few hundred milliseconds, so a fixed count, not a time limit, keeps the work the same from run to run.
static constexpr unsigned kBenchmarkCeremonies = 3;
static constexpr uint64_t kExpectedChecksum = 0x89cd31291d2aefa4ULL;

static RetainPtr<TestWKWebView> setUpBenchWebView()
{
    auto *configuration = [WKWebViewConfiguration _test_configurationWithTestPlugInClassName:@"WebProcessPlugInWithInternals" configureJSCForTesting:YES];
    [configuration _setAllowTestOnlyIPC:YES];
    return adoptNS([[TestWKWebView alloc] initWithFrame:NSZeroRect configuration:configuration]);
}

static uint64_t ceremony()
{
    RetainPtr<NSURL> testURL = [NSBundle.test_resourcesBundle URLForResource:@"web-authentication-bench-make-credential-hid" withExtension:@"html"];
    auto webView = setUpBenchWebView();
    [webView focus];
    [webView loadRequest:[NSURLRequest requestWithURL:testURL.get()]];
    [webView waitForMessage:@"Succeeded!"];
    // FNV-1a of one completed ceremony.
    uint64_t state = 0xcbf29ce484222325ULL;
    for (uint64_t i = 0; i < 8; ++i) {
        state ^= (i == 0) ? 1 : 0;
        state *= 0x100000001b3ULL;
    }
    return state;
}

TEST(WebAuthnBench, CtapMakeCredentialMock)
{
    uint64_t checksum = ceremony();
    if (kExpectedChecksum == kUnrecorded)
        SAFE_PRINTF("CtapMakeCredentialMock: UNRECORDED checksum=%016llx\n", static_cast<unsigned long long>(checksum));
    EXPECT_EQ(kExpectedChecksum, checksum);
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    unsigned passes = 0;
    auto start = MonotonicTime::now();
    Seconds elapsed;
    do {
        if (ceremony() != checksum)
            ADD_FAILURE() << "checksum changed";
        ++passes;
        elapsed = MonotonicTime::now() - start;
    } while (passes < kBenchmarkCeremonies);
    SAFE_PRINTF("CtapMakeCredentialMock: %.1f ms %.1f MB/s checksum=%016llx\n", elapsed.milliseconds(),
        static_cast<double>(passes) * 2048 / elapsed.microseconds(), static_cast<unsigned long long>(checksum));
}

// Not a hot path: the benchmark guards against a regression in the credential blob import. The blob is a CBOR map of
// "priv", "key_type", "key_size", "rp" and "tag", imported through the public SPI. A blob that fails before the key is
// created reaches the CBOR decode and the field checks and nothing of the Keychain, so these blobs, which are malformed
// in each way, exercise the decode half of the blob round trip without side effects. The encode half is reached only by
// an export, which reads the Keychain; it has no entry that avoids it, and the benchmark does not run it.

namespace PanelBlob {

class Builder {
public:
    void head(unsigned major, uint64_t argument)
    {
        uint8_t type = static_cast<uint8_t>(major << 5);
        if (argument < 24)
            m_bytes.append(type | static_cast<uint8_t>(argument));
        else if (argument <= 0xff) {
            m_bytes.append(type | 24);
            m_bytes.append(static_cast<uint8_t>(argument));
        } else {
            m_bytes.append(type | 25);
            m_bytes.append(static_cast<uint8_t>(argument >> 8));
            m_bytes.append(static_cast<uint8_t>(argument));
        }
    }
    void integer(uint64_t value) { head(0, value); }
    void text(const char* string)
    {
        size_t length = strlen(string);
        head(3, length);
        for (size_t i = 0; i < length; ++i)
            m_bytes.append(static_cast<uint8_t>(string[i]));
    }
    void byteString(size_t length, uint8_t value)
    {
        head(2, length);
        for (size_t i = 0; i < length; ++i)
            m_bytes.append(value);
    }
    void raw(const Vector<uint8_t>& bytes) { m_bytes.appendVector(bytes); }
    Vector<uint8_t> take() { return WTF::move(m_bytes); }
private:
    Vector<uint8_t> m_bytes;
};

// The values of a blob's five entries, already encoded; an empty one is left out.
struct Fields {
    Vector<uint8_t> rp, tag, priv, keySize, keyType;
};

static Vector<uint8_t> encoded(Fields&& fields, bool swapTagAndPriv = false)
{
    // Canonical key order: by length, then bytewise: "rp", "tag", "priv", "key_size", "key_type".
    struct Entry {
        const char* key;
        const Vector<uint8_t>* value;
    };
    Entry entries[] = { { "rp", &fields.rp }, { "tag", &fields.tag }, { "priv", &fields.priv }, { "key_size", &fields.keySize }, { "key_type", &fields.keyType } };
    if (swapTagAndPriv)
        std::swap(entries[1], entries[2]);
    unsigned count = 0;
    for (auto& entry : entries)
        count += !entry.value->isEmpty();
    Builder builder;
    builder.head(5, count);
    for (auto& entry : entries) {
        if (entry.value->isEmpty())
            continue;
        builder.text(entry.key);
        builder.raw(*entry.value);
    }
    return builder.take();
}

static Vector<uint8_t> value(void (*write)(Builder&))
{
    Builder builder;
    write(builder);
    return builder.take();
}

static Fields valid()
{
    Fields fields;
    fields.rp = value([](Builder& b) {
        b.text("example.com");
    });
    fields.tag = value([](Builder& b) {
        b.head(5, 2);
        b.text("id");
        b.byteString(8, 0x42);
        b.text("name");
        b.text("user");
    });
    fields.priv = value([](Builder& b) {
        b.byteString(32, 0x11);
    });
    fields.keySize = value([](Builder& b) {
        b.integer(256);
    });
    fields.keyType = value([](Builder& b) {
        b.integer(73);
    });
    return fields;
}

static Vector<Vector<uint8_t>> blobs()
{
    Vector<Vector<uint8_t>> blobs;
    auto text = [](Builder& b) {
        b.text("not what is asked for");
    };
    // Each is missing or mistypes one field. The import checks them in the order priv, key_type, key_size, rp, tag, so
    // the last of these decodes and checks every field before it fails.
    auto missing = [&](auto clear) {
        auto fields = valid();
        clear(fields);
        blobs.append(encoded(WTF::move(fields)));
    };
    missing([](Fields& f) {
        f.tag = { };
    });
    missing([](Fields& f) {
        f.priv = { };
    });
    missing([](Fields& f) {
        f.keyType = { };
    });
    missing([](Fields& f) {
        f.keySize = { };
    });
    missing([](Fields& f) {
        f.rp = { };
    });
    auto mistyped = [&](auto set) {
        auto fields = valid();
        set(fields);
        blobs.append(encoded(WTF::move(fields)));
    };
    mistyped([&](Fields& f) {
        f.priv = value(text);
    });
    mistyped([&](Fields& f) {
        f.keyType = value(text);
    });
    mistyped([&](Fields& f) {
        f.keySize = value(text);
    });
    mistyped([](Fields& f) {
        f.rp = value([](Builder& b) {
            b.integer(7);
        });
    });
    mistyped([](Fields& f) {
        f.tag = value([](Builder& b) {
            b.head(4, 0);
        });
    });
    // Not a blob at all, and blobs the CBOR reader rejects.
    blobs.append(Vector<uint8_t> { 0xA0 });
    blobs.append(Vector<uint8_t> { 0x80 });
    blobs.constructAndAppend();
    auto truncated = encoded(valid());
    truncated.shrink(truncated.size() - 3);
    blobs.append(WTF::move(truncated));
    auto trailing = encoded(valid());
    trailing.append(0);
    blobs.append(WTF::move(trailing));
    blobs.append(encoded(valid(), true)); // out of order
    Builder duplicate;
    duplicate.head(5, 2);
    duplicate.text("rp");
    duplicate.text("a");
    duplicate.text("rp");
    duplicate.text("b");
    blobs.append(duplicate.take());
    Vector<uint8_t> arrayHeads;
    for (unsigned i = 0; i < 40; ++i)
        arrayHeads.append(0x81);
    blobs.append(WTF::move(arrayHeads));
    return blobs;
}

} // namespace PanelBlob

static uint64_t panelBlobPass(const Vector<Vector<uint8_t>>& blobs)
{
    uint64_t state = 0xcbf29ce484222325ULL;
    auto add = [&](uint64_t value) {
        for (unsigned i = 0; i < 8; ++i) {
            state ^= (value >> (i * 8)) & 0xff;
            state *= 0x100000001b3ULL;
        }
    };
    @autoreleasepool {
        for (auto& blob : blobs) {
            NSData *data = [NSData dataWithBytes:blob.span().data() length:blob.size()];
            NSError *error = nil;
            NSData *result = [_WKWebAuthenticationPanel importLocalAuthenticatorCredential:data error:&error];
            add(!!result);
            add(static_cast<uint64_t>(error.code));
        }
    }
    return state;
}

TEST(WebAuthnBench, PanelBlobRoundTrip)
{
    auto blobs = PanelBlob::blobs();
    size_t bytes = 0;
    for (auto& blob : blobs)
        bytes += blob.size();
    static constexpr uint64_t expected = 0x5a6979daafe0ada5ULL;
    static constexpr unsigned passes = 160000;
    uint64_t checksum = panelBlobPass(blobs);
    if (expected == kUnrecorded)
        SAFE_PRINTF("PanelBlobRoundTrip: UNRECORDED checksum=%016llx\n", static_cast<unsigned long long>(checksum));
    EXPECT_EQ(expected, checksum);
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    unsigned mismatches = 0;
    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < passes; ++i) {
        if (panelBlobPass(blobs) != checksum)
            ++mismatches;
    }
    Seconds elapsed = MonotonicTime::now() - start;
    EXPECT_EQ(0u, mismatches);
    SAFE_PRINTF("PanelBlobRoundTrip: %.1f ms %.1f MB/s checksum=%016llx\n", elapsed.milliseconds(),
        static_cast<double>(bytes) * passes / elapsed.microseconds(), static_cast<unsigned long long>(checksum));
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUTHN) && HAVE(UNIFIED_ASC_AUTH_UI)
