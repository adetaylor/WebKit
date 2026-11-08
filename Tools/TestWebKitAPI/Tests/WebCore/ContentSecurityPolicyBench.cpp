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

#include "ContentSecurityPolicyBenchInputs.h"
#include "Helpers/Test.h"
#include <WebCore/CSPViolationReportBody.h>
#include <WebCore/ContentSecurityPolicy.h>
#include <WebCore/DeprecationReportBody.h>
#include <WebCore/DocumentInlines.h>
#include <WebCore/FormData.h>
#include <WebCore/HTMLDivElement.h>
#include <WebCore/NodeInlines.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/Report.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/Settings.h>
#include <WebCore/ViolationReportType.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <pal/crypto/CryptoDigest.h>
#include <wtf/MonotonicTime.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/URL.h>
#include <wtf/text/Base64.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

// Each test runs one pass over its input and compares a digest of everything the policies delivered (the decisions,
// the violation records, the console messages, the reports and the derived state) with the value recorded for it.
// With WEBKIT_RUN_BENCHMARKS=1 it then runs the pass a fixed number of times and prints
// "<Shape>: <ms> ms <n> MB/s checksum=<digest>", where MB/s counts the policy text parsed and the URLs, nonces and
// inline content checked in a pass.

namespace TestWebKitAPI::ContentSecurityPolicyBenchmark {

using WebCore::ContentSecurityPolicy;
using WebCore::ContentSecurityPolicyHeaderType;
using PolicyFrom = WebCore::ContentSecurityPolicy::PolicyFrom;
using RedirectResponseReceived = WebCore::ContentSecurityPolicy::RedirectResponseReceived;
using InsecureRequestType = WebCore::ContentSecurityPolicy::InsecureRequestType;
using ContentSecurityPolicyBenchInputs::SitePolicy;
using ContentSecurityPolicyBenchInputs::typicalSitePolicies;

class Generator {
public:
    explicit Generator(uint32_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned n)
    {
        m_state = m_state * 1664525u + 1013904223u;
        return (m_state >> 8) % n;
    }

    bool oneIn(unsigned n) { return !below(n); }

    template<typename T, size_t size>
    const T& pick(const std::array<T, size>& choices) { return choices[below(size)]; }

private:
    uint32_t m_state;
};

class Checksum {
public:
    uint64_t value() const { return m_value; }

    void add(uint64_t word)
    {
        for (unsigned i = 0; i < 8; ++i)
            addByte((word >> (8 * i)) & 0xff);
    }

    void add(StringView string)
    {
        if (string.isNull()) {
            add(~0ull);
            return;
        }
        add(string.length());
        for (unsigned i = 0; i < string.length(); ++i) {
            char16_t character = string[i];
            addByte(character & 0xff);
            addByte(character >> 8);
        }
    }

    void add(std::span<const uint8_t> bytes)
    {
        add(bytes.size());
        for (auto byte : bytes)
            addByte(byte);
    }

private:
    void addByte(uint8_t byte)
    {
        m_value ^= byte;
        m_value *= 1099511628211ull;
    }

    uint64_t m_value { 1469598103934665603ull };
};

enum class Delivery : uint8_t {
    ConsoleMessage = 1,
    ViolationEvent,
    ReportObserved,
    ReportSent,
    Decision,
    ResponseHeaders,
    UpgradedURL,
    UpgradeSet,
};

// The client a policy without a document reports to, as the network process's loaders are: it digests every console
// message, violation event and report in the order the policy delivers them.
class RecordingClient final : public WebCore::ContentSecurityPolicyClient, public WebCore::ReportingClient {
public:
    void setChecksum(Checksum* checksum) { m_checksum = checksum; }
    Checksum* checksum() const { return m_checksum; }

private:
    void addConsoleMessage(JSC::MessageSource source, JSC::MessageLevel level, const String& message, unsigned long requestIdentifier) final
    {
        if (!m_checksum)
            return;
        m_checksum->add(static_cast<uint64_t>(Delivery::ConsoleMessage));
        m_checksum->add(static_cast<uint64_t>(source));
        m_checksum->add(static_cast<uint64_t>(level));
        m_checksum->add(message);
        m_checksum->add(requestIdentifier);
    }

    void enqueueSecurityPolicyViolationEvent(WebCore::SecurityPolicyViolationEventInit&& init) final
    {
        if (!m_checksum)
            return;
        m_checksum->add(static_cast<uint64_t>(Delivery::ViolationEvent));
        m_checksum->add(init.documentURI);
        m_checksum->add(init.referrer);
        m_checksum->add(init.blockedURI);
        m_checksum->add(init.violatedDirective);
        m_checksum->add(init.effectiveDirective);
        m_checksum->add(init.originalPolicy);
        m_checksum->add(init.sourceFile);
        m_checksum->add(init.sample);
        m_checksum->add(static_cast<uint64_t>(init.disposition));
        m_checksum->add(init.statusCode);
        m_checksum->add(init.lineNumber);
        m_checksum->add(init.columnNumber);
        m_checksum->add(init.bubbles);
        m_checksum->add(init.cancelable);
        m_checksum->add(init.composed);
    }

    void notifyReportObservers(Ref<WebCore::Report>&& report) final
    {
        if (!m_checksum)
            return;
        m_checksum->add(static_cast<uint64_t>(Delivery::ReportObserved));
        m_checksum->add(report->type());
        m_checksum->add(report->url());
        auto* body = report->body();
        if (!body) {
            m_checksum->add(~0ull);
            return;
        }
        WebCore::ReportBody& reportBody = *body;
        m_checksum->add(reportBody.type());
        if (auto* violation = dynamicDowncast<WebCore::CSPViolationReportBody>(reportBody)) {
            m_checksum->add(violation->documentURL());
            m_checksum->add(violation->referrer());
            m_checksum->add(violation->blockedURL());
            m_checksum->add(violation->effectiveDirective());
            m_checksum->add(violation->originalPolicy());
            m_checksum->add(violation->sourceFile());
            m_checksum->add(violation->sample());
            m_checksum->add(static_cast<uint64_t>(violation->disposition()));
            m_checksum->add(violation->statusCode());
            m_checksum->add(violation->lineNumber().value_or(~0ull));
            m_checksum->add(violation->columnNumber().value_or(~0ull));
        } else if (auto* deprecation = dynamicDowncast<WebCore::DeprecationReportBody>(reportBody)) {
            m_checksum->add(deprecation->id());
            m_checksum->add(deprecation->message());
            m_checksum->add(deprecation->sourceFile());
            m_checksum->add(deprecation->lineNumber().value_or(~0u));
            m_checksum->add(deprecation->columnNumber().value_or(~0u));
        }
    }

    String endpointURIForToken(const String& token) const final
    {
        return makeString("https://reports.example.com/endpoints/"_s, token);
    }

    void sendReportToEndpoints(const URL& baseURL, std::span<const String> endpointURIs, std::span<const String> endpointTokens, Ref<WebCore::FormData>&& report, WebCore::ViolationReportType type) final
    {
        if (!m_checksum)
            return;
        m_checksum->add(static_cast<uint64_t>(Delivery::ReportSent));
        m_checksum->add(baseURL.string());
        m_checksum->add(endpointURIs.size());
        for (auto& endpointURI : endpointURIs)
            m_checksum->add(endpointURI);
        m_checksum->add(endpointTokens.size());
        for (auto& endpointToken : endpointTokens)
            m_checksum->add(endpointToken);
        m_checksum->add(report->flatten().span());
        m_checksum->add(static_cast<uint64_t>(type));
    }

    String httpUserAgent() const final
    {
        return "TestWebKitAPI"_s;
    }

    Checksum* m_checksum { nullptr };
};

static size_t byteLength(StringView string)
{
    return string.length() * (string.is8Bit() ? 1 : 2);
}

static String make16Bit(StringView string)
{
    Vector<char16_t> characters;
    characters.reserveInitialCapacity(string.length());
    for (unsigned i = 0; i < string.length(); ++i)
        characters.append(string[i]);
    String result { characters.span() };
    EXPECT_FALSE(result.is8Bit());
    return result;
}

static const String& referrer()
{
    static NeverDestroyed<String> referrer { "https://search.example.org/"_s };
    return referrer;
}

// A shape's setup parses the policies its checks use; what they deliver then is part of the first pass's checksum.
class Shape {
public:
    Shape()
    {
        m_client.setChecksum(&m_setupChecksum);
    }

    virtual ~Shape() = default;

    void run(Checksum* checksum)
    {
        if (checksum)
            checksum->add(m_setupChecksum.value());
        m_client.setChecksum(checksum);
        runOnce(checksum);
        m_client.setChecksum(nullptr);
    }

    size_t bytesPerPass() const { return m_bytesPerPass; }

protected:
    virtual void runOnce(Checksum*) = 0;

    std::unique_ptr<ContentSecurityPolicy> createPolicy(const URL& protectedURL)
    {
        return ContentSecurityPolicy::create(URL { protectedURL }, &m_client, &m_client);
    }

    void countBytes(StringView string) { m_bytesPerPass += byteLength(string); }
    void countBytes(const URL& url) { m_bytesPerPass += byteLength(url.string()); }

    RecordingClient m_client;
    Checksum m_setupChecksum;
    size_t m_bytesPerPass { 0 };
};

static void addDecision(Checksum* checksum, uint64_t decision)
{
    if (!checksum)
        return;
    checksum->add(static_cast<uint64_t>(Delivery::Decision));
    checksum->add(decision);
}

static void addPolicyState(Checksum* checksum, ContentSecurityPolicy& policy)
{
    if (!checksum)
        return;
    auto responseHeaders = policy.responseHeaders();
    checksum->add(static_cast<uint64_t>(Delivery::ResponseHeaders));
    checksum->add(responseHeaders.headers().size());
    for (auto& [header, type] : responseHeaders.headers()) {
        checksum->add(header);
        checksum->add(static_cast<uint64_t>(type));
    }
    checksum->add(static_cast<uint64_t>(responseHeaders.httpStatusCode()));
    checksum->add(policy.overridesXFrameOptions());
    auto& hashesToReport = policy.hashesToReport();
    checksum->add(hashesToReport.size());
    for (auto& [algorithms, tokens] : hashesToReport) {
        checksum->add(algorithms);
        checksum->add(tokens.size());
        for (auto& token : tokens)
            checksum->add(token);
    }
}

static WebCore::ContentSecurityPolicyResponseHeaders responseHeaders(const SitePolicy& site, int httpStatusCode)
{
    Vector<std::pair<String, ContentSecurityPolicyHeaderType>> headers;
    if (!site.enforce.isEmpty())
        headers.append({ String { site.enforce }, ContentSecurityPolicyHeaderType::Enforce });
    if (!site.reportOnly.isEmpty())
        headers.append({ String { site.reportOnly }, ContentSecurityPolicyHeaderType::Report });
    return { WTF::move(headers), httpStatusCode };
}

// An element for the inline checks, which take the element they report against. With a client, the policy only
// holds it while it reports.
class InlineElement {
public:
    InlineElement()
    {
        WebCore::ProcessWarming::initializeNames();
        m_settings = WebCore::Settings::create(nullptr);
        m_document = WebCore::Document::create(*m_settings, aboutBlankURL());
        m_element = WebCore::HTMLDivElement::create(*m_document);
    }

    WebCore::Element& element() const { return *m_element; }

private:
    RefPtr<WebCore::Settings> m_settings;
    RefPtr<WebCore::Document> m_document;
    RefPtr<WebCore::Element> m_element;
};

static constexpr std::array base64Characters {
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V',
    'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r',
    's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '/',
};

static void appendBase64(StringBuilder& builder, Generator& generator, unsigned length, bool urlSafe = false)
{
    for (unsigned i = 0; i < length; ++i) {
        char character = generator.pick(base64Characters);
        if (urlSafe && character == '+')
            character = '-';
        else if (urlSafe && character == '/')
            character = '_';
        builder.append(character);
    }
}

static String randomNonce(Generator& generator)
{
    StringBuilder builder;
    unsigned length = 16 + generator.below(16);
    appendBase64(builder, generator, length, generator.oneIn(3));
    if (generator.oneIn(3))
        builder.append("=="_s);
    return builder.toString();
}

using HashAlgorithm = PAL::Crypto::CryptoDigest::Algorithm;

// A hash source for content as the policy hashes it: the UTF-8 of the content, unpaired surrogates replaced.
static String hashSource(HashAlgorithm algorithm, StringView content, bool urlSafe = false)
{
    auto digest = PAL::Crypto::CryptoDigest::create(algorithm);
    auto utf8 = content.utf8(StrictConversionReplacingUnpairedSurrogatesWithFFFD);
    digest->addBytes(byteCast<uint8_t>(utf8.span()));
    auto hash = digest->computeHash();
    ASCIILiteral prefix = algorithm == HashAlgorithm::SHA_256 ? "'sha256-"_s : algorithm == HashAlgorithm::SHA_384 ? "'sha384-"_s : "'sha512-"_s;
    auto options = urlSafe ? OptionSet<Base64EncodeOption> { Base64EncodeOption::URL } : OptionSet<Base64EncodeOption> { };
    return makeString(prefix, base64EncodeToString(hash.span(), options), '\'');
}

static String integrityAttribute(StringView content)
{
    auto digest = PAL::Crypto::CryptoDigest::create(HashAlgorithm::SHA_384);
    auto utf8 = content.utf8();
    digest->addBytes(byteCast<uint8_t>(utf8.span()));
    auto hash = digest->computeHash();
    return makeString("sha384-"_s, base64EncodeToString(hash.span()));
}

static constexpr std::array scriptWords {
    "function"_s, "var"_s, "const"_s, "return"_s, "document"_s, "window"_s, "dataLayer"_s, "push(arguments);"_s,
    "querySelector('#main')"_s, "addEventListener('click',"_s, "=>"_s, "{"_s, "}"_s, "if"_s, "(a"_s, "b)"_s, "="_s, "0;"_s,
    "null;"_s, "this.state"_s, "JSON.parse(data)"_s, "fetch('/api/v1/items')"_s, "new"_s, "Date();"_s,
};

static constexpr std::array styleWords {
    "body{margin:0}"_s, ".header{display:flex;"_s, "align-items:center}"_s, "#main"_s, ">"_s, "a:hover{color:#0a58ca}"_s,
    "@media (max-width:600px){"_s, ".nav{display:none}}"_s, "font-family:-apple-system,system-ui;"_s, "padding:4px 8px;"_s,
};

static constexpr std::array<char16_t, 6> wideCharacters { 0x00E9, 0x2603, 0x3042, 0x4E2D, 0x05D0, 0x20AC };

// Text in the shape of inline script or style. A wide text holds non-Latin-1 characters, surrogate pairs and, when
// asked, one unpaired surrogate, which the policy hashes as U+FFFD.
template<size_t size>
static String inlineText(Generator& generator, const std::array<ASCIILiteral, size>& words, unsigned length, bool wide, bool unpairedSurrogate = false)
{
    StringBuilder builder;
    while (builder.length() < length) {
        builder.append(generator.pick(words), ' ');
        if (wide && generator.oneIn(6)) {
            if (generator.oneIn(4))
                builder.append(static_cast<char16_t>(0xD83D), static_cast<char16_t>(0xDE00));
            else
                builder.append(generator.pick(wideCharacters));
        }
    }
    if (unpairedSurrogate)
        builder.append(static_cast<char16_t>(0xD800), ';');
    return builder.toString();
}

static TextPosition position(unsigned line, unsigned column)
{
    return { OrdinalNumber::fromOneBasedInt(line), OrdinalNumber::fromOneBasedInt(column) };
}

// What a page asks a policy about a fetch, through the check the loader calls for that kind of fetch.
enum class Fetch : uint8_t { Script, Worker, Image, Prefetch, Style, Font, Manifest, Media, ChildFrame, Connect, FormAction, Object, BaseURI };

struct Request {
    Fetch fetch;
    URL url;
    URL preRedirectURL;
    String nonce;
    String integrity;
};

static bool check(const ContentSecurityPolicy& policy, const Request& request)
{
    auto redirect = request.preRedirectURL.isNull() ? RedirectResponseReceived::No : RedirectResponseReceived::Yes;
    switch (request.fetch) {
    case Fetch::Script:
        return policy.allowScriptFromSource(request.url, std::nullopt, redirect, request.preRedirectURL, request.integrity, request.nonce);
    case Fetch::Worker:
        return policy.allowWorkerFromSource(request.url, std::nullopt, redirect, request.preRedirectURL);
    case Fetch::Image:
        return policy.allowImageFromSource(request.url, std::nullopt, redirect, request.preRedirectURL);
    case Fetch::Prefetch:
        return policy.allowPrefetchFromSource(request.url, std::nullopt, redirect, request.preRedirectURL);
    case Fetch::Style:
        return policy.allowStyleFromSource(request.url, std::nullopt, redirect, request.preRedirectURL, request.nonce);
    case Fetch::Font:
        return policy.allowFontFromSource(request.url, std::nullopt, redirect, request.preRedirectURL);
    case Fetch::Manifest:
#if ENABLE(APPLICATION_MANIFEST)
        return policy.allowManifestFromSource(request.url, std::nullopt, redirect, request.preRedirectURL);
#else
        return policy.allowPrefetchFromSource(request.url, std::nullopt, redirect, request.preRedirectURL);
#endif
    case Fetch::Media:
        return policy.allowMediaFromSource(request.url, std::nullopt, redirect, request.preRedirectURL);
    case Fetch::ChildFrame:
        return policy.allowChildFrameFromSource(request.url, std::nullopt, redirect);
    case Fetch::Connect:
        return policy.allowConnectToSource(request.url, std::nullopt, redirect, request.preRedirectURL);
    case Fetch::FormAction:
        return policy.allowFormAction(request.url, std::nullopt, redirect, request.preRedirectURL);
    case Fetch::Object:
        return policy.allowObjectFromSource(request.url, std::nullopt, redirect, request.preRedirectURL);
    case Fetch::BaseURI:
        return policy.allowBaseURI(request.url);
    }
    return false;
}

class RequestShape : public Shape {
protected:
    void addRequest(Fetch fetch, URL&& url, URL&& preRedirectURL = { }, String&& nonce = { }, String&& integrity = { })
    {
        countBytes(url);
        countBytes(preRedirectURL);
        countBytes(nonce);
        countBytes(integrity);
        m_requests.append({ fetch, WTF::move(url), WTF::move(preRedirectURL), WTF::move(nonce), WTF::move(integrity) });
    }

    void checkRequests(Checksum* checksum, const ContentSecurityPolicy& policy)
    {
        for (auto& request : m_requests)
            addDecision(checksum, check(policy, request));
    }

    Vector<Request> m_requests;
};

static URL makeURL(StringView string)
{
    return URL { string.toString() };
}

// ParseTypicalPolicies: each site's policies arrive with a response, and a worker, an about:blank or blob document,
// a plugin document or a navigation's policy copy then takes them from it.
class ParseTypicalPolicies final : public Shape {
public:
    ParseTypicalPolicies()
    {
        static constexpr std::array documentURLs {
            "https://www.example.com/"_s, "https://example.org/wiki/Main_Page"_s, "http://www.example.net/index.html"_s,
            "https://app.example.com/inbox/0"_s, "https://shop.example.org:8443/cart?item=4"_s,
        };
        for (auto& site : typicalSitePolicies) {
            m_documentURLs.append(makeURL(documentURLs[m_documentURLs.size() % documentURLs.size()]));
            m_responseHeaders.append(responseHeaders(site, m_documentURLs.last().protocolIs("http"_s) ? 200 : 0));
            countBytes(site.enforce);
            countBytes(site.reportOnly);
        }
        m_apiPolicy = "default-src 'self' https://*.example.com; script-src 'self' 'unsafe-inline'"_s;
        m_bytesPerPass *= 2;
    }

private:
    void runOnce(Checksum* checksum) final
    {
        for (size_t index = 0; index < m_responseHeaders.size(); ++index) {
            auto policy = createPolicy(m_documentURLs[index]);
            if (index % 8 == 7)
                policy->didReceiveHeader(m_apiPolicy, ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::API, String { referrer() });
            policy->didReceiveHeaders(m_responseHeaders[index], String { referrer() });
            addPolicyState(checksum, *policy);

            auto inherited = createPolicy(m_documentURLs[(index + 1) % m_documentURLs.size()]);
            switch (index % 4) {
            case 0:
                inherited->copyStateFrom(policy.get(), ContentSecurityPolicy::ShouldMakeIsolatedCopy::Yes);
                break;
            case 1:
                inherited->inheritHeadersFrom(policy->responseHeaders());
                break;
            case 2:
                inherited->createPolicyForPluginDocumentFrom(*policy);
                break;
            default:
                inherited->didReceiveHeaders(*policy, ContentSecurityPolicy::ReportParsingErrors::No);
                break;
            }
            addPolicyState(checksum, *inherited);
        }
    }

    Vector<URL> m_documentURLs;
    Vector<WebCore::ContentSecurityPolicyResponseHeaders> m_responseHeaders;
    String m_apiPolicy;
};

static void appendHostSource(StringBuilder& builder, Generator& generator, unsigned index)
{
    switch (generator.below(9)) {
    case 0:
        builder.append("https://h"_s, index, ".cdn.example.net"_s);
        break;
    case 1:
        builder.append("*.s"_s, index, ".example.com"_s);
        break;
    case 2:
        builder.append('h', index, ".example.org:8443"_s);
        break;
    case 3:
        builder.append("https://static"_s, index, ".example.net/assets/v"_s, generator.below(40), '/');
        break;
    case 4:
        builder.append("wss://socket"_s, index, ".example.com:*"_s);
        break;
    case 5:
        builder.append("http://legacy"_s, index, ".example.org"_s);
        break;
    case 6:
        builder.append("https://*.region"_s, index, ".example.net:443/media/"_s);
        break;
    case 7:
        builder.append("partner"_s, index, ".example.com/widgets/embed.js"_s);
        break;
    default:
        builder.append("https://"_s, index, ".example.org"_s);
        break;
    }
}

static void appendHashSource(StringBuilder& builder, Generator& generator, unsigned algorithm)
{
    bool urlSafe = generator.oneIn(4);
    switch (algorithm) {
    case 0:
        builder.append("'sha256-"_s);
        appendBase64(builder, generator, 43, urlSafe);
        builder.append("='"_s);
        break;
    case 1:
        builder.append("'sha384-"_s);
        appendBase64(builder, generator, 64, urlSafe);
        builder.append('\'');
        break;
    default:
        builder.append("'sha512-"_s);
        appendBase64(builder, generator, 86, urlSafe);
        builder.append("=='"_s);
        break;
    }
}

struct LongDirective {
    ASCIILiteral name;
    bool takesHashes;
    bool takesSchemes;
};

static String longPolicy(Generator& generator, unsigned hosts, unsigned hashesPerAlgorithm, unsigned nonces)
{
    static constexpr std::array directives {
        LongDirective { "default-src"_s, false, false }, LongDirective { "script-src"_s, true, false },
        LongDirective { "style-src"_s, true, false }, LongDirective { "img-src"_s, false, true },
        LongDirective { "connect-src"_s, false, false }, LongDirective { "font-src"_s, false, false },
        LongDirective { "media-src"_s, false, true }, LongDirective { "frame-src"_s, false, false },
    };
    StringBuilder builder;
    unsigned index = 0;
    for (auto& directive : directives) {
        builder.append(directive.name, " 'self'"_s);
        unsigned count = directive.takesHashes ? hosts / 4 : hosts / 12;
        for (unsigned i = 0; i < count; ++i) {
            builder.append(' ');
            appendHostSource(builder, generator, index++);
        }
        if (directive.takesHashes) {
            bool isScriptSrc = directive.name == "script-src"_s;
            unsigned hashes = isScriptSrc ? hashesPerAlgorithm : hashesPerAlgorithm / 10;
            for (unsigned algorithm = 0; algorithm < 3; ++algorithm) {
                for (unsigned i = 0; i < hashes; ++i) {
                    builder.append(' ');
                    appendHashSource(builder, generator, algorithm);
                }
            }
            for (unsigned i = 0; i < (isScriptSrc ? nonces : nonces / 10); ++i) {
                auto nonce = randomNonce(generator);
                builder.append(" 'nonce-"_s, nonce, '\'');
            }
        }
        if (directive.takesSchemes)
            builder.append(" data: blob:"_s);
        builder.append("; "_s);
    }
    builder.append("report-uri https://reports.example.com/csp/long"_s);
    return builder.toString();
}

// ParseLongPolicies: allowlists of 200 to 2,000 sources, with 100 hashes of each algorithm and 100 nonces, one of
// them in 16-bit text.
class ParseLongPolicies final : public Shape {
public:
    ParseLongPolicies()
    {
        static constexpr std::array hostCounts { 200u, 2000u, 400u, 1300u, 700u, 1000u, 300u, 1600u };
        Generator generator(2);
        for (auto hosts : hostCounts) {
            auto policy = longPolicy(generator, hosts, 100, 100);
            if (m_policies.size() == 3)
                policy = make16Bit(policy);
            countBytes(policy);
            m_policies.append(WTF::move(policy));
        }
        m_documentURL = makeURL("https://www.example.com/dashboard"_s);
    }

private:
    void runOnce(Checksum* checksum) final
    {
        for (size_t index = 0; index < m_policies.size(); ++index) {
            auto policy = createPolicy(m_documentURL);
            auto type = index % 3 == 2 ? ContentSecurityPolicyHeaderType::Report : ContentSecurityPolicyHeaderType::Enforce;
            policy->didReceiveHeader(m_policies[index], type, PolicyFrom::HTTPHeader, String { referrer() }, 200);
            addPolicyState(checksum, *policy);
        }
    }

    Vector<String> m_policies;
    URL m_documentURL;
};

// ParseMetaPolicies: <meta http-equiv="Content-Security-Policy"> content as the HTML parser hands it over, with the
// whitespace, line breaks and NUL a page leaves in it, the directives a <meta> policy may not hold, and 16-bit text.
class ParseMetaPolicies final : public Shape {
public:
    ParseMetaPolicies()
    {
        Generator generator(3);
        unsigned variant = 0;
        for (auto& site : typicalSitePolicies) {
            if (site.enforce.isEmpty())
                continue;
            String policy { site.enforce };
            for (unsigned i = 0; i < 3; ++i) {
                String meta;
                switch (variant++ % 6) {
                case 0:
                    meta = policy;
                    break;
                case 1:
                    meta = makeString("\n        "_s, makeStringByReplacingAll(policy, "; "_s, ";\n        "_s), "\n    "_s);
                    break;
                case 2:
                    meta = makeString("\f\t"_s, policy, " \r\n"_s);
                    break;
                case 3:
                    meta = makeString(policy, "; frame-ancestors 'none'; report-uri /csp; sandbox allow-scripts"_s);
                    break;
                case 4:
                    meta = makeString(makeStringByReplacingAll(policy, "; "_s, ";\r\n"_s), '\0', ';');
                    break;
                default:
                    meta = makeString(policy, "; img-src https://bilder.example.com/gr"_s, static_cast<char16_t>(0x00F6), static_cast<char16_t>(0x00DF), "e/"_s);
                    break;
                }
                if (generator.oneIn(2))
                    meta = make16Bit(meta);
                m_metaPolicies.append(WTF::move(meta));
                countBytes(m_metaPolicies.last());
            }
        }
        m_documentURL = makeURL("https://www.example.com/news/article.html"_s);
    }

private:
    void runOnce(Checksum* checksum) final
    {
        for (size_t index = 0; index < m_metaPolicies.size(); ++index) {
            auto policy = createPolicy(m_documentURL);
            policy->didReceiveHeader(m_metaPolicies[index], ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPEquivMeta, String { referrer() });
            if (index % 3 == 1)
                policy->didReceiveHeader(m_metaPolicies[index - 1], ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPEquivMeta, String { referrer() });
            addPolicyState(checksum, *policy);
        }
    }

    Vector<String> m_metaPolicies;
    URL m_documentURL;
};

// ScriptSourceChecks: external scripts and workers against script-src and worker-src host lists, nonces, exact
// paths, redirects and integrity attributes, with a report-only companion.
class ScriptSourceChecks final : public RequestShape {
public:
    ScriptSourceChecks()
    {
        m_policy = createPolicy(makeURL("https://www.example.com/app/"_s));
        m_policy->didReceiveHeader("script-src 'self' https://cdn.example.net https://*.static.example.com https://www.analytics.example.org/analytics.js "
            "https://apis.example.com/js/ 'nonce-Vn2rX0eq4KcL9pTzW8bYgA=='; worker-src 'self' blob: https://workers.example.net; default-src 'self'"_s,
            ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });
        m_policy->didReceiveHeader("script-src 'self' https://cdn.example.net https://*.static.example.com; report-uri /csp-script"_s,
            ContentSecurityPolicyHeaderType::Report, PolicyFrom::HTTPHeader, String { referrer() });

        static constexpr std::array libraries { "jquery"_s, "react"_s, "react-dom"_s, "lodash"_s, "moment"_s, "d3"_s, "vue"_s, "three"_s };
        Generator generator(4);
        for (unsigned i = 0; i < 2000; ++i) {
            auto library = generator.pick(libraries);
            switch (generator.below(20)) {
            case 0: case 1: case 2: case 3: case 4: case 5: case 6:
                addRequest(Fetch::Script, makeURL(makeString("https://cdn.example.net/libs/"_s, library, '/', generator.below(20), ".1.0/"_s, library, ".min.js"_s)));
                break;
            case 7: case 8: case 9: {
                unsigned host = generator.below(6);
                addRequest(Fetch::Script, makeURL(makeString("https://s"_s, host, ".static.example.com/js/"_s, generator.below(100000), ".js"_s)));
                break;
            }
            case 10: case 11:
                addRequest(Fetch::Script, makeURL(makeString("https://www.example.com/static/js/chunk-"_s, generator.below(1000), ".js"_s)));
                break;
            case 12:
                addRequest(Fetch::Script, makeURL(generator.oneIn(2) ? "https://www.analytics.example.org/analytics.js"_s : "https://www.analytics.example.org/analytics_debug.js"_s));
                break;
            case 13:
                addRequest(Fetch::Script, makeURL(makeString("https://apis.example.com/js/platform.js?onload="_s, library)));
                break;
            case 14: case 15: {
                String nonce { generator.oneIn(5) ? "wrong-nonce"_s : " Vn2rX0eq4KcL9pTzW8bYgA== "_s };
                addRequest(Fetch::Script, makeURL(makeString("https://widgets.example.org/"_s, library, "/widget.js"_s)), { }, WTF::move(nonce));
                break;
            }
            case 16:
                addRequest(Fetch::Script, makeURL(makeString("http://cdn.example.net/libs/"_s, library, ".js"_s)));
                break;
            case 17:
                addRequest(Fetch::Script, makeURL(makeString("https://cdn.example.net/libs/"_s, library, ".js"_s)), makeURL(makeString("https://redirect.example.com/r?to="_s, library)));
                break;
            case 18:
                addRequest(Fetch::Script, makeURL(makeString("https://s1.static.example.com/"_s, library, ".js"_s)), { }, { }, integrityAttribute(library));
                break;
            default:
                if (generator.oneIn(3))
                    addRequest(Fetch::Worker, makeURL(makeString("blob:https://www.example.com/"_s, generator.below(1000000))));
                else if (generator.oneIn(2))
                    addRequest(Fetch::Worker, makeURL(makeString("https://workers.example.net/"_s, library, "-worker.js"_s)));
                else
                    addRequest(Fetch::Worker, makeURL(makeString("https://other.example.org/"_s, library, "-worker.js"_s)));
                break;
            }
        }
        for (auto& request : m_requests) {
            if (!request.nonce.isNull())
                m_preloadNonces.append(request.nonce);
        }
    }

private:
    void runOnce(Checksum* checksum) final
    {
        checkRequests(checksum, *m_policy);
        for (auto& nonce : m_preloadNonces)
            addDecision(checksum, m_policy->allowScriptWithNonce(nonce));
    }

    std::unique_ptr<ContentSecurityPolicy> m_policy;
    Vector<String> m_preloadNonces;
};

// SubresourceChecks: images, styles, fonts, media, connections and the other fetches, through a policy that names
// most fetch directives and one that names only default-src.
class SubresourceChecks final : public RequestShape {
public:
    SubresourceChecks()
    {
        m_policy = createPolicy(makeURL("https://www.example.com/"_s));
        m_policy->didReceiveHeader("default-src 'self' https://*.example.net; img-src * data: blob:; style-src 'self' 'unsafe-inline' "
            "https://fonts.example.org https://cdn.example.net; font-src https://fonts.example.org https://*.example.net data:; "
            "media-src 'self' https://media.example.com blob:; connect-src 'self' https://api.example.com wss://socket.example.com "
            "https://*.analytics.example.org"_s, ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });
        m_policy->didReceiveHeader("default-src 'self' https://*.example.net https://cdn.example.org https://fonts.example.org "
            "https://api.example.com https://media.example.com https://*.analytics.example.org wss://socket.example.com data: blob: "
            "https://cdn.example.net https://images.example.com"_s, ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });

        static constexpr std::array imageHosts {
            "https://images.example.com"_s, "https://cdn.example.net"_s, "https://i1.example.net"_s, "https://www.example.com"_s,
            "https://tracker.example.org"_s,
        };
        static constexpr std::array fontHosts { "https://fonts.example.org"_s, "https://static.example.net"_s, "https://fonts.example.com"_s };
        static constexpr std::array connectURLs {
            "https://api.example.com/v2/graphql"_s, "wss://socket.example.com/live"_s, "https://www.example.com/beacon"_s,
            "https://events.analytics.example.org/collect?v=2"_s, "https://api.other.example.org/data"_s, "ws://socket.example.com/live"_s,
        };
        Generator generator(5);
        for (unsigned i = 0; i < 3000; ++i) {
            unsigned n = generator.below(100000);
            switch (generator.below(32)) {
            case 0: case 1: case 2: case 3: case 4: case 5: case 6: case 7: case 8: case 9: {
                auto host = generator.pick(imageHosts);
                addRequest(Fetch::Image, makeURL(makeString(host, "/img/"_s, n, generator.oneIn(2) ? ".webp"_s : ".jpg"_s)));
                break;
            }
            case 10:
                addRequest(Fetch::Image, makeURL(makeString("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"_s, n, "AAAAAElFTkSuQmCC"_s)));
                break;
            case 11:
                addRequest(Fetch::Image, makeURL(makeString("blob:https://www.example.com/"_s, n)));
                break;
            case 12: case 13: case 14:
                addRequest(Fetch::Style, makeURL(makeString(generator.oneIn(2) ? "https://fonts.example.org/css2?family=Inter:wght@"_s : "https://cdn.example.net/css/site."_s, n)));
                break;
            case 15: case 16:
                addRequest(Fetch::Font, makeURL(makeString(generator.pick(fontHosts), "/s/inter/v"_s, n % 20, "/font.woff2"_s)));
                break;
            case 17:
                addRequest(Fetch::Media, makeURL(makeString(generator.oneIn(3) ? "https://videos.example.org/"_s : "https://media.example.com/clips/"_s, n, ".mp4"_s)));
                break;
            case 18: case 19: case 20: case 21: {
                auto url = makeURL(generator.pick(connectURLs));
                addRequest(Fetch::Connect, WTF::move(url), generator.oneIn(8) ? makeURL("https://www.example.com/api/redirect"_s) : URL { });
                break;
            }
            case 22:
                addRequest(Fetch::Prefetch, makeURL(makeString("https://www.example.com/next/"_s, n)));
                break;
            case 23:
                addRequest(Fetch::Manifest, makeURL(generator.oneIn(2) ? "https://www.example.com/manifest.webmanifest"_s : "https://cdn.example.org/manifest.json"_s));
                break;
            case 24:
                addRequest(Fetch::Object, makeURL(makeString("https://www.example.com/docs/"_s, n, ".pdf"_s)));
                break;
            case 25: case 26:
                addRequest(Fetch::ChildFrame, makeURL(generator.oneIn(4) ? "about:blank"_s : generator.oneIn(2) ? "https://player.example.net/embed/1"_s : "https://ads.example.org/frame"_s));
                break;
            case 27: case 28:
                addRequest(Fetch::FormAction, makeURL(generator.oneIn(3) ? "https://checkout.example.org/pay"_s : "https://www.example.com/search?q=x"_s));
                break;
            case 29:
                addRequest(Fetch::BaseURI, makeURL(generator.oneIn(2) ? "https://www.example.com/base/"_s : "https://cdn.example.net/base/"_s));
                break;
            default:
                addRequest(Fetch::Image, makeURL(makeString("http://images.example.com/img/"_s, n, ".png"_s)));
                break;
            }
        }
    }

private:
    void runOnce(Checksum* checksum) final
    {
        checkRequests(checksum, *m_policy);
    }

    std::unique_ptr<ContentSecurityPolicy> m_policy;
};

// WildcardHostsAndPorts: wildcard hosts with zero to four labels in front, the bare host a wildcard does not match,
// explicit, default and wildcard ports, and the http to https and ws to wss upgrades with ports 80 and 443.
class WildcardHostsAndPorts final : public RequestShape {
public:
    WildcardHostsAndPorts()
    {
        static constexpr std::array zoneSources { "*.z%.example.com"_s, "*.z%.example.net:*"_s, "https://z%.example.org:*"_s, "http://*.z%.example.com:8080"_s };
        static constexpr std::array zoneHosts { "z%.example.com"_s, "z%.example.net"_s, "z%.example.org"_s };
        static constexpr unsigned zones = 40;
        StringBuilder imageSources;
        for (unsigned zone = 0; zone < zones; ++zone)
            imageSources.append(' ', makeStringByReplacingAll(String { zoneSources[zone % zoneSources.size()] }, '%', String::number(zone)));
        m_policy = createPolicy(makeURL("https://www.example.com/"_s));
        m_policy->didReceiveHeader(makeString("default-src 'none'; img-src *.example.com *.cdn.example.net:* https://*.example.org:443 "
            "http://*.example.org:8080 media.example.com:8443 *.a.b.c.example.net https://example.net:* http://*.images.example.com"_s,
            imageSources.toString(), "; connect-src wss://*.example.com:* ws://*.example.org:9000 https://*.example.net "
            "*.api.example.org:8443 http://localhost:*"_s), ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });

        static constexpr std::array labels { "www"_s, "img"_s, "a"_s, "eu-west-1"_s, "x1"_s, "static"_s, "b"_s, "c"_s };
        static constexpr std::array domains {
            "example.com"_s, "cdn.example.net"_s, "example.org"_s, "a.b.c.example.net"_s, "example.net"_s, "media.example.com"_s,
            "api.example.org"_s, "images.example.com"_s, "notexample.com"_s, "localhost"_s,
        };
        static constexpr std::array imageSchemes { "https://"_s, "http://"_s };
        static constexpr std::array connectSchemes { "wss://"_s, "ws://"_s, "https://"_s, "http://"_s };
        static constexpr std::array ports { ""_s, ""_s, ""_s, ":443"_s, ":80"_s, ":8080"_s, ":8443"_s, ":9000"_s, ":1234"_s };
        Generator generator(6);
        for (unsigned i = 0; i < 3000; ++i) {
            bool connect = generator.oneIn(3);
            StringBuilder builder;
            builder.append(connect ? generator.pick(connectSchemes) : generator.pick(imageSchemes));
            unsigned depth = generator.below(5);
            for (unsigned j = 0; j < depth; ++j)
                builder.append(generator.pick(labels), '.');
            String domain;
            if (!connect && generator.oneIn(2)) {
                auto zoneHost = generator.pick(zoneHosts);
                domain = makeStringByReplacingAll(String { zoneHost }, '%', String::number(generator.below(zones + 4)));
            } else
                domain = generator.pick(domains);
            auto port = generator.pick(ports);
            builder.append(domain, port, connect ? "/socket"_s : "/i/"_s, generator.below(1000), connect ? ""_s : ".png"_s);
            addRequest(connect ? Fetch::Connect : Fetch::Image, makeURL(builder.toString()));
        }
    }

private:
    void runOnce(Checksum* checksum) final
    {
        checkRequests(checksum, *m_policy);
    }

    std::unique_ptr<ContentSecurityPolicy> m_policy;
};

// PathMatching: directory and exact path matches, paths of one to eight segments, percent-encoded segments, queries
// and fragments, case differences, and redirects, after which paths are not compared.
class PathMatching final : public RequestShape {
public:
    PathMatching()
    {
        m_policy = createPolicy(makeURL("https://www.example.com/"_s));
        m_policy->didReceiveHeader("default-src 'none'; script-src 'self' https://cdn.example.net/js/ https://cdn.example.net/lib/app.js "
            "https://static.example.com/a/b/c/ https://static.example.com/exact/file.min.js https://static.example.com/%E2%9C%93/ "
            "https://static.example.com/a%20b/ https://static.example.com/%7Euser/; img-src 'self' https://img.example.org/photos/ "
            "https://img.example.org/thumbs/2024/ https://img.example.org/p%C3%A9/"_s,
            ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });

        static constexpr std::array scriptPaths {
            "https://cdn.example.net/js/app.js"_s, "https://cdn.example.net/js/vendor/chunk.js"_s, "https://cdn.example.net/js"_s,
            "https://cdn.example.net/JS/app.js"_s, "https://cdn.example.net/lib/app.js"_s, "https://cdn.example.net/lib/app.js.map"_s,
            "https://cdn.example.net/lib/app.js?v=3#x"_s, "https://static.example.com/a/b/c/d/e.js"_s, "https://static.example.com/a/b/x.js"_s,
            "https://static.example.com/exact/file.min.js"_s, "https://static.example.com/exact/file.js"_s,
            "https://static.example.com/%E2%9C%93/check.js"_s, "https://static.example.com/%e2%9c%93/check.js"_s,
            "https://static.example.com/a%20b/f.js"_s, "https://static.example.com/a b/f.js"_s, "https://static.example.com/~user/u.js"_s,
            "https://static.example.com/%7Euser/u.js"_s, "https://static.example.com/a/b/c/../../x.js"_s, "https://www.example.com/any/path.js"_s,
        };
        static constexpr std::array imagePaths {
            "https://img.example.org/photos/1.jpg"_s, "https://img.example.org/photos"_s, "https://img.example.org/thumbs/2024/07/a.png"_s,
            "https://img.example.org/thumbs/2023/a.png"_s, "https://img.example.org/p%C3%A9/x.gif"_s, "https://img.example.org/p%c3%a9/x.gif"_s,
            "https://img.example.org/P%C3%A9/x.gif"_s, "https://img.example.org/photos/%2e%2e/secret.png"_s,
        };
        static constexpr std::array scriptPrefixes { "https://cdn.example.net/js/"_s, "https://static.example.com/a/b/c/"_s, "https://static.example.com/a/"_s, "https://www.example.com/"_s };
        static constexpr std::array imagePrefixes { "https://img.example.org/photos/"_s, "https://img.example.org/thumbs/2024/"_s, "https://img.example.org/"_s };
        static constexpr std::array segmentNames { "v2"_s, "lib"_s, "%41pp"_s, "app.js"_s, "x%2Fy"_s, "2024"_s, "img.png"_s, "a%20b"_s, "~u"_s, "index"_s };
        Generator generator(7);
        for (unsigned i = 0; i < 3000; ++i) {
            bool script = generator.below(3);
            URL url;
            if (generator.oneIn(16))
                url = makeURL(script ? makeString("https://static.example.com/"_s, static_cast<char16_t>(0x2713), "/check.js"_s) : makeString("https://img.example.org/p"_s, static_cast<char16_t>(0x00E9), "/x.gif"_s));
            else if (generator.oneIn(3)) {
                StringBuilder path;
                path.append(script ? generator.pick(scriptPrefixes) : generator.pick(imagePrefixes));
                unsigned segments = 1 + generator.below(8);
                for (unsigned j = 0; j < segments; ++j) {
                    auto segment = generator.pick(segmentNames);
                    path.append(j ? "/"_s : ""_s, segment);
                }
                url = makeURL(path.toString());
            } else
                url = makeURL(script ? generator.pick(scriptPaths) : generator.pick(imagePaths));
            URL preRedirectURL;
            if (generator.oneIn(10))
                preRedirectURL = makeURL(makeString("https://www.example.com/redirect?n="_s, i));
            addRequest(script ? Fetch::Script : Fetch::Image, WTF::move(url), WTF::move(preRedirectURL));
        }
    }

private:
    void runOnce(Checksum* checksum) final
    {
        checkRequests(checksum, *m_policy);
    }

    std::unique_ptr<ContentSecurityPolicy> m_policy;
};

struct InlineContent {
    String content;
    String nonce;
    unsigned line { 0 };
};

// InlineNonces: inline scripts and styles carrying a nonce, a padded nonce, a wrong one or none, and the nonce checks
// the preload scanner makes, against policies with nonces and no hashes, so no content is hashed.
class InlineNonces final : public Shape {
public:
    InlineNonces()
    {
        m_policy = createPolicy(makeURL("https://www.example.com/article"_s));
        m_policy->didReceiveHeader("script-src 'nonce-R4nd0mN0nceV4lue01==' 'nonce-c2Vjb25kLW5vbmNl' 'self'; "
            "style-src 'nonce-R4nd0mN0nceV4lue01==' 'self'"_s, ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });
        m_policy->didReceiveHeader("script-src 'nonce-c2Vjb25kLW5vbmNl'; style-src 'nonce-c2Vjb25kLW5vbmNl'; report-uri /csp-inline"_s,
            ContentSecurityPolicyHeaderType::Report, PolicyFrom::HTTPHeader, String { referrer() });
        m_documentURL = "https://www.example.com/article"_s;

        static constexpr std::array nonces {
            "R4nd0mN0nceV4lue01=="_s, "R4nd0mN0nceV4lue01=="_s, "R4nd0mN0nceV4lue01=="_s, "c2Vjb25kLW5vbmNl"_s,
            "\tR4nd0mN0nceV4lue01== \n"_s, "R4nd0mN0nceV4lue01"_s, "wrong"_s, ""_s,
        };
        Generator generator(8);
        for (unsigned i = 0; i < 1500; ++i) {
            bool script = generator.below(3);
            auto content = script ? inlineText(generator, scriptWords, 40 + generator.below(1200), false) : inlineText(generator, styleWords, 30 + generator.below(400), false);
            String nonce { generator.pick(nonces) };
            countBytes(content);
            countBytes(nonce);
            (script ? m_scripts : m_styles).append({ WTF::move(content), WTF::move(nonce), 10 + i });
        }
    }

private:
    void runOnce(Checksum* checksum) final
    {
        auto& element = m_element.element();
        for (auto& script : m_scripts) {
            addDecision(checksum, m_policy->allowScriptWithNonce(script.nonce));
            addDecision(checksum, m_policy->allowInlineScript(m_documentURL, position(script.line, 5), script.content, element, script.nonce));
        }
        for (auto& style : m_styles) {
            addDecision(checksum, m_policy->allowStyleWithNonce(style.nonce));
            addDecision(checksum, m_policy->allowInlineStyle(m_documentURL, OrdinalNumber::fromOneBasedInt(style.line), style.content, WebCore::CheckUnsafeHashes::No, element, style.nonce));
        }
    }

    InlineElement m_element;
    std::unique_ptr<ContentSecurityPolicy> m_policy;
    String m_documentURL;
    Vector<InlineContent> m_scripts;
    Vector<InlineContent> m_styles;
};

// InlineHashes: inline scripts, styles, event handlers, javascript: URLs and style attributes whose hashes a policy
// lists, or does not, for every algorithm, over 8-bit and 16-bit content, some of it with unpaired surrogates.
class InlineHashes final : public Shape {
public:
    InlineHashes()
    {
        static constexpr std::array algorithms { HashAlgorithm::SHA_256, HashAlgorithm::SHA_384, HashAlgorithm::SHA_512 };
        Generator generator(9);
        StringBuilder scriptSources;
        StringBuilder styleSources;
        auto addContent = [&](Vector<String>& list, String&& content, StringBuilder& sources, bool anyAlgorithm) {
            if (!generator.oneIn(4)) {
                auto algorithm = anyAlgorithm ? generator.pick(algorithms) : HashAlgorithm::SHA_256;
                bool urlSafe = generator.oneIn(5);
                sources.append(' ', hashSource(algorithm, content, urlSafe));
            }
            countBytes(content);
            list.append(WTF::move(content));
        };
        auto text = [&](const auto& words, unsigned minimumLength, unsigned extraLength, unsigned wideOneIn, unsigned unpairedOneIn) {
            unsigned length = minimumLength + generator.below(extraLength);
            bool wide = wideOneIn && generator.oneIn(wideOneIn);
            bool unpaired = wide && unpairedOneIn && generator.oneIn(unpairedOneIn);
            return inlineText(generator, words, length, wide, unpaired);
        };
        for (unsigned i = 0; i < 300; ++i)
            addContent(m_scripts, text(scriptWords, 50, 4950, 2, 10), scriptSources, true);
        for (unsigned i = 0; i < 100; ++i)
            addContent(m_styles, text(styleWords, 40, 1500, 4, 0), styleSources, false);
        for (unsigned i = 0; i < 100; ++i)
            addContent(m_eventHandlers, text(scriptWords, 10, 80, 5, 0), scriptSources, true);
        for (unsigned i = 0; i < 50; ++i)
            addContent(m_javaScriptURLs, makeString("javascript:"_s, text(scriptWords, 10, 60, 0, 0)), scriptSources, true);
        for (unsigned i = 0; i < 50; ++i)
            addContent(m_styleAttributes, text(styleWords, 10, 60, 0, 0), styleSources, false);

        auto policyText = makeString("script-src 'self' 'unsafe-hashes'"_s, scriptSources.toString(), "; style-src 'self' 'unsafe-hashes'"_s, styleSources.toString());
        m_policy = createPolicy(makeURL("https://www.example.com/static-site/"_s));
        m_policy->didReceiveHeader(policyText, ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });
        m_documentURL = "https://www.example.com/static-site/"_s;
    }

private:
    void runOnce(Checksum* checksum) final
    {
        auto& element = m_element.element();
        unsigned line = 1;
        for (auto& script : m_scripts)
            addDecision(checksum, m_policy->allowInlineScript(m_documentURL, position(++line, 9), script, element, nullString()));
        for (auto& style : m_styles)
            addDecision(checksum, m_policy->allowInlineStyle(m_documentURL, OrdinalNumber::fromOneBasedInt(++line), style, WebCore::CheckUnsafeHashes::No, element, nullString()));
        for (auto& code : m_eventHandlers)
            addDecision(checksum, m_policy->allowInlineEventHandlers(m_documentURL, OrdinalNumber::fromOneBasedInt(++line), code, &element));
        for (auto& code : m_javaScriptURLs)
            addDecision(checksum, m_policy->allowJavaScriptURLs(m_documentURL, OrdinalNumber::fromOneBasedInt(++line), code, nullptr));
        for (auto& style : m_styleAttributes)
            addDecision(checksum, m_policy->allowInlineStyle(m_documentURL, OrdinalNumber::fromOneBasedInt(++line), style, WebCore::CheckUnsafeHashes::Yes, element, nullString()));
    }

    InlineElement m_element;
    std::unique_ptr<ContentSecurityPolicy> m_policy;
    String m_documentURL;
    Vector<String> m_scripts;
    Vector<String> m_styles;
    Vector<String> m_eventHandlers;
    Vector<String> m_javaScriptURLs;
    Vector<String> m_styleAttributes;
};

struct StrictDynamicScript {
    URL sourceURL;
    String nonce;
    String integrity;
    String content;
    WebCore::ParserInserted parserInserted;
};

// StrictDynamic: the early check a script element makes under 'strict-dynamic', for parser-inserted and inserted
// scripts, with and without a nonce, external scripts allowed by their integrity hash, and inline scripts by nonce or
// hash; then the load and inline checks, which defer to it.
class StrictDynamic final : public Shape {
public:
    StrictDynamic()
    {
        String library = inlineText(m_generator, scriptWords, 2000, false);
        String bootstrap = "window.__bootstrap=function(s){var e=document.createElement('script');e.src=s;document.head.appendChild(e)};"_s;
        auto policyText = makeString("script-src 'nonce-StR1ctDyn4m1cN0nce' 'strict-dynamic' "_s, hashSource(HashAlgorithm::SHA_384, library),
            ' ', hashSource(HashAlgorithm::SHA_256, bootstrap), " https: http: 'unsafe-inline' 'self'; object-src 'none'; base-uri 'none'"_s);
        m_policy = createPolicy(makeURL("https://www.example.com/"_s));
        m_policy->didReceiveHeader(policyText, ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });
        m_policy->didReceiveHeader("script-src 'nonce-StR1ctDyn4m1cN0nce' 'strict-dynamic' 'report-sample'; report-uri /csp-sd"_s,
            ContentSecurityPolicyHeaderType::Report, PolicyFrom::HTTPHeader, String { referrer() });
        m_documentURL = makeURL("https://www.example.com/"_s);
        String integrity = integrityAttribute(library);

        for (unsigned i = 0; i < 2000; ++i) {
            StrictDynamicScript script { { }, { }, { }, { }, WebCore::ParserInserted::Yes };
            unsigned host = m_generator.below(4);
            auto external = makeURL(makeString("https://cdn"_s, host, ".example.net/js/"_s, m_generator.below(100000), ".js"_s));
            switch (m_generator.below(20)) {
            case 0: case 1: case 2: case 3: case 4: case 5: case 6:
                script.sourceURL = WTF::move(external);
                script.nonce = "StR1ctDyn4m1cN0nce"_s;
                break;
            case 7: case 8: case 9: case 10: case 11:
                script.sourceURL = WTF::move(external);
                script.parserInserted = WebCore::ParserInserted::No;
                break;
            case 12: case 13:
                script.sourceURL = WTF::move(external);
                break;
            case 14: case 15:
                script.sourceURL = WTF::move(external);
                script.integrity = integrity;
                break;
            case 16:
                script.nonce = " StR1ctDyn4m1cN0nce"_s;
                script.content = inlineText(m_generator, scriptWords, 100 + m_generator.below(500), false);
                break;
            case 17:
                script.content = bootstrap;
                break;
            default: {
                unsigned length = 50 + m_generator.below(300);
                script.content = inlineText(m_generator, scriptWords, length, m_generator.oneIn(3));
                break;
            }
            }
            countBytes(script.sourceURL);
            countBytes(script.nonce);
            countBytes(script.integrity);
            countBytes(script.content);
            m_scripts.append(WTF::move(script));
        }
    }

private:
    void runOnce(Checksum* checksum) final
    {
        auto& element = m_element.element();
        unsigned line = 1;
        for (auto& script : m_scripts) {
            bool isInline = script.sourceURL.isNull();
            ++line;
            addDecision(checksum, m_policy->allowScriptForStrictDynamic(script.sourceURL, isInline ? m_documentURL : URL { }, OrdinalNumber::fromOneBasedInt(line), script.nonce, script.integrity, script.content, script.parserInserted));
            if (isInline)
                addDecision(checksum, m_policy->allowInlineScript(m_documentURL.string(), position(line, 1), script.content, element, script.nonce));
            else
                addDecision(checksum, m_policy->allowScriptFromSource(script.sourceURL, std::nullopt, RedirectResponseReceived::No, URL { }, script.integrity, script.nonce));
        }
    }

    Generator m_generator { 10 };
    InlineElement m_element;
    std::unique_ptr<ContentSecurityPolicy> m_policy;
    URL m_documentURL;
    Vector<StrictDynamicScript> m_scripts;
};

enum class Violation : uint8_t { Request, InlineScript, InlineStyle, Eval, EventHandler, JavaScriptURL };

struct ViolationCase {
    Violation violation;
    Request request;
    String content;
};

// ReportOnlyViolations: report-only and enforced policies that report most of what a page does, to report-uri
// endpoints and through the Reporting API, over http (with the status code) and https: cross-origin, data:, blob:
// and redirected URLs, inline content with samples, eval, frames, objects and plugin-types' deprecation report.
class ReportOnlyViolations final : public Shape {
public:
    ReportOnlyViolations()
    {
        m_policies.append(createPolicy(makeURL("http://www.example.com/page"_s)));
        auto& httpPolicy = m_policies.last();
        httpPolicy->didReceiveHeader("default-src 'none'; script-src 'self' 'report-sample'; style-src 'self' 'report-sample'; "
            "img-src 'self'; frame-src 'self'; object-src 'none'; plugin-types application/pdf; form-action 'self'; base-uri 'self'; "
            "connect-src 'self'; report-uri https://reports.example.com/csp https://backup.example.net/csp"_s,
            ContentSecurityPolicyHeaderType::Report, PolicyFrom::HTTPHeader, String { referrer() }, 200);
        httpPolicy->didReceiveHeader("img-src 'self' https://images.example.com data:; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; "
            "report-uri /csp-enforce"_s, ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() }, 200);

        m_policies.append(createPolicy(makeURL("https://secure.example.org/account"_s)));
        auto& httpsPolicy = m_policies.last();
        httpsPolicy->didReceiveHeader("default-src 'self'; script-src 'self' 'report-sample'; frame-src 'none'; report-to csp-group; "
            "report-uri https://reports.example.com/legacy"_s, ContentSecurityPolicyHeaderType::Report, PolicyFrom::HTTPHeader, String { referrer() }, 200);
        httpsPolicy->didReceiveHeader("script-src 'self' 'unsafe-inline'; img-src * data:; report-to csp-group"_s,
            ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() }, 200);
        m_documentURL = "https://secure.example.org/account"_s;

        static constexpr std::array blockedURLs {
            "https://evil.example.net/x.png"_s, "https://images.example.com/a.png"_s, "http://www.example.com/same.png"_s,
            "data:image/gif;base64,R0lGODlhAQABAAAAACw="_s, "blob:https://secure.example.org/1234-5678"_s, "file:///etc/hosts"_s,
            "https://user:pass@other.example.org:8443/path/to/thing?query=1#fragment"_s, "https://secure.example.org/self.png"_s,
        };
        static constexpr std::array frameURLs { "https://frames.example.net/embed?id=7"_s, "https://secure.example.org/frame"_s, "http://www.example.com/frame#x"_s };
        static constexpr std::array violatingFetches { Fetch::Image, Fetch::Script, Fetch::Style, Fetch::Font, Fetch::Connect, Fetch::Media, Fetch::FormAction, Fetch::BaseURI };
        Generator generator(11);
        for (unsigned i = 0; i < 800; ++i) {
            ViolationCase item { Violation::Request, { Fetch::Image, { }, { }, { }, { } }, { } };
            switch (generator.below(16)) {
            case 0: case 1: case 2: case 3: case 4: case 5:
                item.request.fetch = generator.pick(violatingFetches);
                item.request.url = makeURL(generator.pick(blockedURLs));
                break;
            case 6:
                item.request.fetch = Fetch::ChildFrame;
                item.request.url = makeURL(generator.pick(frameURLs));
                break;
            case 7:
                item.request.fetch = Fetch::Object;
                item.request.url = makeURL(makeString("https://plugins.example.net/doc"_s, i, ".pdf"_s));
                break;
            case 8:
                item.request.fetch = Fetch::Image;
                item.request.url = makeURL(makeString("https://cdn.example.net/after-redirect/"_s, i, ".png"_s));
                item.request.preRedirectURL = makeURL(makeString("https://secure.example.org/r/"_s, i, "?token=secret"_s));
                break;
            case 9: case 10: {
                item.violation = Violation::InlineScript;
                unsigned length = 20 + generator.below(400);
                item.content = inlineText(generator, scriptWords, length, generator.oneIn(4));
                break;
            }
            case 11:
                item.violation = Violation::InlineStyle;
                item.content = inlineText(generator, styleWords, 20 + generator.below(200), false);
                break;
            case 12: case 13:
                item.violation = Violation::Eval;
                item.content = inlineText(generator, scriptWords, 10 + generator.below(100), false);
                break;
            case 14:
                item.violation = Violation::EventHandler;
                item.content = inlineText(generator, scriptWords, 10 + generator.below(60), false);
                break;
            default:
                item.violation = Violation::JavaScriptURL;
                item.content = makeString("javascript:"_s, inlineText(generator, scriptWords, 10 + generator.below(60), false));
                break;
            }
            countBytes(item.request.url);
            countBytes(item.request.preRedirectURL);
            countBytes(item.content);
            m_cases.append(WTF::move(item));
        }
    }

private:
    void runOnce(Checksum* checksum) final
    {
        auto& element = m_element.element();
        unsigned line = 1;
        for (auto& policy : m_policies) {
            for (auto& item : m_cases) {
                ++line;
                switch (item.violation) {
                case Violation::Request:
                    addDecision(checksum, check(*policy, item.request));
                    break;
                case Violation::InlineScript:
                    addDecision(checksum, policy->allowInlineScript(m_documentURL, position(line, 3), item.content, element, nullString()));
                    break;
                case Violation::InlineStyle:
                    addDecision(checksum, policy->allowInlineStyle(m_documentURL, OrdinalNumber::fromOneBasedInt(line), item.content, WebCore::CheckUnsafeHashes::No, element, nullString()));
                    break;
                case Violation::Eval:
                    addDecision(checksum, policy->allowEval(nullptr, line % 2 ? WebCore::LogToConsole::Yes : WebCore::LogToConsole::No, item.content));
                    break;
                case Violation::EventHandler:
                    addDecision(checksum, policy->allowInlineEventHandlers(m_documentURL, OrdinalNumber::fromOneBasedInt(line), item.content, &element));
                    break;
                case Violation::JavaScriptURL:
                    addDecision(checksum, policy->allowJavaScriptURLs(m_documentURL, OrdinalNumber::fromOneBasedInt(line), item.content, nullptr));
                    break;
                }
            }
        }
    }

    InlineElement m_element;
    Vector<std::unique_ptr<ContentSecurityPolicy>> m_policies;
    String m_documentURL;
    Vector<ViolationCase> m_cases;
};

static void addUpgradeSet(Checksum* checksum, HashSet<WebCore::SecurityOriginData>&& origins)
{
    if (!checksum)
        return;
    auto names = WTF::map(origins, [](auto& origin) {
        return origin.toString();
    });
    std::ranges::sort(names, [](const String& a, const String& b) {
        return codePointCompareLessThan(a, b);
    });
    checksum->add(static_cast<uint64_t>(Delivery::UpgradeSet));
    checksum->add(names.size());
    for (auto& name : names)
        checksum->add(name);
}

// UpgradeInsecureRequests: loads, form submissions and navigations through a policy that upgrades insecure requests
// and holds a set of origins whose navigations it upgrades, and through the policies of a frame and a window that
// copy that state from it.
class UpgradeInsecureRequests final : public Shape {
public:
    UpgradeInsecureRequests()
    {
        m_parent = createPolicy(makeURL("https://www.example.com/"_s));
        m_parent->didReceiveHeader("upgrade-insecure-requests; default-src https: data: blob: 'unsafe-inline'"_s,
            ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });
        HashSet<WebCore::SecurityOriginData> navigationOrigins;
        for (auto origin : { "http://www.example.com/"_s, "http://shop.example.com/"_s, "ws://socket.example.com/"_s, "http://www.example.org:8080/"_s })
            navigationOrigins.add(WebCore::SecurityOriginData::fromURL(makeURL(origin)));
        m_parent->setInsecureNavigationRequestsToUpgrade(WTF::move(navigationOrigins));
        m_frameURL = makeURL("https://frame.example.org/embed"_s);

        static constexpr std::array schemes { "http://"_s, "http://"_s, "http://"_s, "ws://"_s, "https://"_s, "wss://"_s };
        static constexpr std::array hosts {
            "www.example.com"_s, "shop.example.com"_s, "socket.example.com"_s, "www.example.org"_s, "cdn.example.net"_s, "localhost"_s,
            "127.0.0.1"_s, "[::1]"_s, "192.168.1.20"_s, "intranet"_s,
        };
        static constexpr std::array ports { ""_s, ""_s, ":80"_s, ":8080"_s, ":443"_s, ":3000"_s };
        static constexpr std::array others { "data:text/plain,hello"_s, "blob:https://www.example.com/42"_s, "ftp://files.example.com/a"_s, "about:blank"_s };
        Generator generator(12);
        for (unsigned i = 0; i < 4000; ++i) {
            URL url;
            if (generator.oneIn(12))
                url = makeURL(generator.pick(others));
            else {
                auto scheme = generator.pick(schemes);
                auto host = generator.pick(hosts);
                auto port = generator.pick(ports);
                unsigned path = generator.below(10000);
                url = makeURL(makeString(scheme, host, port, "/path/"_s, path, "?q="_s, generator.below(100)));
            }
            countBytes(url);
            m_urls.append(WTF::move(url));
        }
    }

private:
    void runOnce(Checksum* checksum) final
    {
        auto frame = createPolicy(m_frameURL);
        frame->copyUpgradeInsecureRequestStateFrom(*m_parent);
        auto window = createPolicy(m_frameURL);
        window->inheritInsecureNavigationRequestsToUpgradeFromOpener(*m_parent);

        static constexpr std::array types { InsecureRequestType::Load, InsecureRequestType::FormSubmission, InsecureRequestType::Navigation };
        unsigned index = 0;
        for (auto& url : m_urls) {
            ++index;
            auto type = types[index % types.size()];
            auto& policy = index % 4 == 1 ? *frame : index % 4 == 3 ? *window : *m_parent;
            URL upgraded { url };
            auto always = index % 10 == 9 ? ContentSecurityPolicy::AlwaysUpgradeRequest::Yes : ContentSecurityPolicy::AlwaysUpgradeRequest::No;
            policy.upgradeInsecureRequestIfNeeded(upgraded, type, always);
            if (checksum) {
                checksum->add(static_cast<uint64_t>(Delivery::UpgradedURL));
                checksum->add(upgraded.string());
            }
        }
        addUpgradeSet(checksum, frame->takeNavigationRequestsToUpgrade());
        addUpgradeSet(checksum, window->takeNavigationRequestsToUpgrade());
    }

    std::unique_ptr<ContentSecurityPolicy> m_parent;
    URL m_frameURL;
    Vector<URL> m_urls;
};

struct TrustedTypesCase {
    String policyName;
    bool isDuplicate { false };
    String stringContext;
    String sink;
    String sinkGroup;
    String source;
};

// TrustedTypes: policy creation against trusted-types allowlists of up to 50 names ('allow-duplicates', *, 'none',
// default), and the sink checks of require-trusted-types-for, with the samples their reports carry.
class TrustedTypes final : public Shape {
public:
    TrustedTypes()
    {
        StringBuilder names;
        for (unsigned i = 0; i < 45; ++i)
            names.append(" widget-"_s, i);
        m_policies.append(createPolicy(makeURL("https://www.example.com/"_s)));
        auto& first = m_policies.last();
        first->didReceiveHeader(makeString("require-trusted-types-for 'script'; trusted-types default dompurify app-policy#1 lit-html goog#html"_s,
            names.toString(), " 'allow-duplicates'"_s), ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });
        first->didReceiveHeader("require-trusted-types-for 'script'; trusted-types app-policy#1 analytics; report-uri /tt-report"_s,
            ContentSecurityPolicyHeaderType::Report, PolicyFrom::HTTPHeader, String { referrer() });
        m_policies.append(createPolicy(makeURL("https://other.example.org/"_s)));
        auto& second = m_policies.last();
        second->didReceiveHeader("trusted-types *; require-trusted-types-for 'script' 'style'"_s,
            ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });
        second->didReceiveHeader("trusted-types 'none' bad^name; require-trusted-types-for; report-uri /tt"_s,
            ContentSecurityPolicyHeaderType::Report, PolicyFrom::HTTPHeader, String { referrer() });

        static constexpr std::array policyNames {
            "default"_s, "dompurify"_s, "app-policy#1"_s, "lit-html"_s, "goog#html"_s, "analytics"_s, "unknown-policy"_s, "evil"_s,
        };
        static constexpr std::array stringContexts { "TrustedHTML"_s, "TrustedScript"_s, "TrustedScriptURL"_s };
        static constexpr std::array sinks {
            "Element innerHTML"_s, "Element outerHTML"_s, "HTMLScriptElement src"_s, "Function"_s, "eval"_s, "Document write"_s,
        };
        static constexpr std::array functionPrefixes { "function anonymous"_s, "async function anonymous"_s, "function* anonymous"_s, ""_s };
        static constexpr std::array sinkGroups { "script"_s, "script"_s, "script"_s, "style"_s };
        Generator generator(13);
        for (unsigned i = 0; i < 2000; ++i) {
            TrustedTypesCase item;
            item.policyName = generator.oneIn(3) ? makeString("widget-"_s, generator.below(50)) : String { generator.pick(policyNames) };
            item.isDuplicate = generator.oneIn(3);
            item.stringContext = generator.pick(stringContexts);
            item.sink = generator.pick(sinks);
            item.sinkGroup = generator.pick(sinkGroups);
            unsigned length = 10 + generator.below(120);
            auto body = inlineText(generator, scriptWords, length, generator.oneIn(5));
            item.source = item.sink == "Function"_s ? makeString(generator.pick(functionPrefixes), "(a,b\n) {\n"_s, body, "\n}"_s) : body;
            countBytes(item.policyName);
            countBytes(item.source);
            m_cases.append(WTF::move(item));
        }
    }

private:
    void runOnce(Checksum* checksum) final
    {
        for (auto& policy : m_policies) {
            for (auto& item : m_cases) {
                addDecision(checksum, static_cast<uint64_t>(policy->allowTrustedTypesPolicy(item.policyName, item.isDuplicate)));
                addDecision(checksum, policy->requireTrustedTypesForSinkGroup(item.sinkGroup));
                addDecision(checksum, policy->requireTrustedTypesForSinkGroup(item.sinkGroup, WebCore::IncludeReportOnlyPolicies::No));
                addDecision(checksum, policy->allowMissingTrustedTypesForSinkGroup(item.stringContext, item.sink, item.sinkGroup, item.source));
            }
        }
    }

    Vector<std::unique_ptr<ContentSecurityPolicy>> m_policies;
    Vector<TrustedTypesCase> m_cases;
};

// FrameAncestors: chains of one to six ancestor origins (and a few top-level documents), as the network process checks
// them, against frame-ancestors source lists of about 20 sources and 'none', and whether the policies override
// X-Frame-Options.
class FrameAncestors final : public Shape {
public:
    FrameAncestors()
    {
        m_policies.append(createPolicy(makeURL("https://embed.example.com/widget"_s)));
        auto& embed = m_policies.last();
        StringBuilder partners;
        for (unsigned i = 0; i < 16; ++i)
            partners.append(i % 2 ? " https://partner"_s : " *.p"_s, i, ".example.net"_s);
        embed->didReceiveHeader(makeString("frame-ancestors 'self' https://*.example.com https://partner.example.net:8443 example.org"_s,
            partners.toString(), "; default-src 'self'"_s), ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });
        embed->didReceiveHeader("frame-ancestors https://*.example.com; report-uri /frame-ancestors"_s,
            ContentSecurityPolicyHeaderType::Report, PolicyFrom::HTTPHeader, String { referrer() });
        m_policies.append(createPolicy(makeURL("https://www.example.org/login"_s)));
        auto& isolated = m_policies.last();
        isolated->didReceiveHeader("frame-ancestors 'none'; report-uri https://reports.example.com/fa"_s,
            ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() });

        static constexpr std::array origins {
            "https://www.example.com"_s, "https://a.example.com"_s, "https://embed.example.com"_s, "https://partner.example.net:8443"_s,
            "https://partner.example.net"_s, "http://example.org"_s, "https://example.org"_s, "https://evil.example.net"_s,
            "http://www.example.com"_s, "https://deep.sub.example.com:443"_s, "https://partner3.example.net"_s, "https://x.p4.example.net"_s,
            "https://partner5.example.net:8443"_s, "https://p6.example.net"_s,
        };
        Generator generator(14);
        for (unsigned i = 0; i < 1000; ++i) {
            Vector<Ref<WebCore::SecurityOrigin>> chain;
            unsigned depth = generator.oneIn(20) ? 0 : 1 + generator.below(6);
            for (unsigned j = 0; j < depth; ++j) {
                if (generator.oneIn(12)) {
                    chain.append(WebCore::SecurityOrigin::createOpaque());
                    continue;
                }
                auto origin = generator.pick(origins);
                countBytes(origin);
                chain.append(WebCore::SecurityOrigin::create(makeURL(origin)));
            }
            m_chains.append(WTF::move(chain));
            m_urls.append(makeURL(makeString("https://embed.example.com/widget?id="_s, i)));
            countBytes(m_urls.last());
        }
    }

private:
    void runOnce(Checksum* checksum) final
    {
        for (auto& policy : m_policies) {
            addDecision(checksum, policy->overridesXFrameOptions());
            for (size_t i = 0; i < m_chains.size(); ++i)
                addDecision(checksum, policy->allowFrameAncestors(m_chains[i], m_urls[i]));
        }
    }

    Vector<std::unique_ptr<ContentSecurityPolicy>> m_policies;
    Vector<Vector<Ref<WebCore::SecurityOrigin>>> m_chains;
    Vector<URL> m_urls;
};

struct PageLoad {
    URL documentURL;
    String enforce;
    String secondPolicy;
    bool secondPolicyIsMeta { false };
    Vector<Request> requests;
    Vector<InlineContent> scripts;
    Vector<InlineContent> styles;
};

// PageLoadMix: a page's mix: two policies parsed, about 60 resource checks, a few inline scripts and styles, and
// one violation, with a new policy for every page.
class PageLoadMix final : public Shape {
public:
    PageLoadMix()
    {
        static constexpr std::array imageHosts { "https://i0.images.example.net"_s, "https://i1.images.example.net"_s, "https://cdn.example.net"_s, "https://www.example.com"_s };
        static constexpr std::array scriptHosts { "https://cdn.example.net/js/"_s, "https://s1.static.example.com/"_s, "https://www.example.com/assets/"_s };
        Generator generator(15);
        for (unsigned page = 0; page < 40; ++page) {
            PageLoad load;
            load.documentURL = makeURL(makeString("https://www.example.com/articles/"_s, page, ".html"_s));
            auto nonce = randomNonce(generator);
            load.enforce = makeString("default-src 'self'; script-src 'self' 'nonce-"_s, nonce, "' https://cdn.example.net https://*.static.example.com; "
                "style-src 'self' 'unsafe-inline' https://fonts.example.org; img-src 'self' data: https://*.images.example.net https://cdn.example.net; "
                "font-src https://fonts.example.org https://*.static.example.com; connect-src 'self' https://api.example.com wss://live.example.com; "
                "media-src 'self' https://*.video.example.net; frame-src https://www.video.example.net https://ads.example.org; object-src 'none'; "
                "base-uri 'self'; report-uri https://reports.example.com/csp"_s);
            load.secondPolicyIsMeta = page % 2;
            if (load.secondPolicyIsMeta)
                load.secondPolicy = "upgrade-insecure-requests; block-all-mixed-content"_s;
            else {
                load.secondPolicy = makeString("script-src 'self' 'nonce-"_s, nonce, "' https://cdn.example.net https://*.static.example.com 'report-sample'; "
                    "report-uri https://reports.example.com/csp-ro"_s);
            }
            m_bytesPerPass += byteLength(load.enforce) + byteLength(load.secondPolicy);

            auto add = [&](Fetch fetch, URL&& url) {
                countBytes(url);
                load.requests.append({ fetch, WTF::move(url), { }, { }, { } });
            };
            for (unsigned i = 0; i < 15; ++i) {
                auto host = generator.pick(scriptHosts);
                add(Fetch::Script, makeURL(makeString(host, "bundle-"_s, generator.below(10000), ".js"_s)));
                if (generator.oneIn(3))
                    load.requests.last().nonce = nonce;
            }
            for (unsigned i = 0; i < 24; ++i) {
                if (generator.oneIn(10)) {
                    add(Fetch::Image, makeURL(makeString("data:image/svg+xml,%3Csvg%3E"_s, i, "%3C/svg%3E"_s)));
                    continue;
                }
                auto host = generator.pick(imageHosts);
                add(Fetch::Image, makeURL(makeString(host, "/img/"_s, generator.below(100000), ".webp"_s)));
            }
            for (unsigned i = 0; i < 5; ++i)
                add(Fetch::Style, makeURL(generator.oneIn(2) ? makeString("https://fonts.example.org/css?family=f"_s, i) : makeString("https://www.example.com/css/site-"_s, i, ".css"_s)));
            for (unsigned i = 0; i < 4; ++i)
                add(Fetch::Font, makeURL(makeString("https://fonts.example.org/s/f"_s, i, ".woff2"_s)));
            for (unsigned i = 0; i < 6; ++i)
                add(Fetch::Connect, makeURL(i % 3 ? makeString("https://api.example.com/v1/items?page="_s, i) : "wss://live.example.com/updates"_s));
            for (unsigned i = 0; i < 2; ++i)
                add(Fetch::Media, makeURL(makeString("https://cdn.video.example.net/v/"_s, generator.below(1000), ".mp4"_s)));
            add(Fetch::ChildFrame, makeURL("https://www.video.example.net/embed/42"_s));
            add(Fetch::ChildFrame, makeURL("https://ads.example.org/slot?id=3"_s));
            add(Fetch::Image, makeURL(makeString("https://tracker.example.org/pixel.gif?page="_s, page)));

            for (unsigned i = 0; i < 3; ++i) {
                auto content = inlineText(generator, scriptWords, 100 + generator.below(800), false);
                countBytes(content);
                load.scripts.append({ WTF::move(content), nonce, 20 + i * 40 });
            }
            for (unsigned i = 0; i < 2; ++i) {
                auto content = inlineText(generator, styleWords, 100 + generator.below(400), false);
                countBytes(content);
                load.styles.append({ WTF::move(content), { }, 5 + i * 3 });
            }
            m_pages.append(WTF::move(load));
        }
    }

private:
    void runOnce(Checksum* checksum) final
    {
        auto& element = m_element.element();
        for (auto& page : m_pages) {
            auto policy = createPolicy(page.documentURL);
            policy->didReceiveHeader(page.enforce, ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPHeader, String { referrer() }, 200);
            if (page.secondPolicyIsMeta)
                policy->didReceiveHeader(page.secondPolicy, ContentSecurityPolicyHeaderType::Enforce, PolicyFrom::HTTPEquivMeta, String { referrer() });
            else
                policy->didReceiveHeader(page.secondPolicy, ContentSecurityPolicyHeaderType::Report, PolicyFrom::HTTPHeader, String { referrer() }, 200);
            for (auto& request : page.requests)
                addDecision(checksum, check(*policy, request));
            for (auto& script : page.scripts)
                addDecision(checksum, policy->allowInlineScript(page.documentURL.string(), position(script.line, 1), script.content, element, script.nonce));
            for (auto& style : page.styles)
                addDecision(checksum, policy->allowInlineStyle(page.documentURL.string(), OrdinalNumber::fromOneBasedInt(style.line), style.content, WebCore::CheckUnsafeHashes::No, element, style.nonce));
            addPolicyState(checksum, *policy);
        }
    }

    InlineElement m_element;
    Vector<PageLoad> m_pages;
};

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && StringView::fromLatin1(value) != "0"_s;
}

template<typename ShapeType>
static void runBenchmark(ASCIILiteral name, unsigned iterations, uint64_t expectedChecksum)
{
    ShapeType shape;
    Checksum checksum;
    shape.run(&checksum);
    EXPECT_EQ(checksum.value(), expectedChecksum) << name.characters() << ": checksum=" << std::hex << std::setfill('0') << std::setw(16) << checksum.value();
    if (!runsBenchmarks())
        return;

    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i)
        shape.run(nullptr);
    double seconds = (MonotonicTime::now() - start).seconds();
    double bytes = static_cast<double>(shape.bytesPerPass()) * iterations;
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, seconds * 1000, bytes / seconds / 1e6, static_cast<unsigned long long>(checksum.value()));
    fflush(stdout);
}

TEST(ContentSecurityPolicyBench, ParseTypicalPolicies)
{
    runBenchmark<ParseTypicalPolicies>("ParseTypicalPolicies"_s, 21000, 0x2a7c950a8f015a64ull);
}

TEST(ContentSecurityPolicyBench, ParseLongPolicies)
{
    runBenchmark<ParseLongPolicies>("ParseLongPolicies"_s, 550, 0x6c0c146eec1c7be1ull);
}

TEST(ContentSecurityPolicyBench, ParseMetaPolicies)
{
    runBenchmark<ParseMetaPolicies>("ParseMetaPolicies"_s, 8300, 0xb10e013e4c307bacull);
}

TEST(ContentSecurityPolicyBench, ScriptSourceChecks)
{
    runBenchmark<ScriptSourceChecks>("ScriptSourceChecks"_s, 1200, 0xe291e1689e807a7full);
}

TEST(ContentSecurityPolicyBench, SubresourceChecks)
{
    runBenchmark<SubresourceChecks>("SubresourceChecks"_s, 1600, 0x0ea94c84fff1ac4dull);
}

TEST(ContentSecurityPolicyBench, WildcardHostsAndPorts)
{
    runBenchmark<WildcardHostsAndPorts>("WildcardHostsAndPorts"_s, 670, 0xd95f56fe5b6ff20eull);
}

TEST(ContentSecurityPolicyBench, PathMatching)
{
    runBenchmark<PathMatching>("PathMatching"_s, 620, 0x4a29a703dc3d0a22ull);
}

TEST(ContentSecurityPolicyBench, InlineNonces)
{
    runBenchmark<InlineNonces>("InlineNonces"_s, 1100, 0x2bd044c37ed0b2f1ull);
}

TEST(ContentSecurityPolicyBench, InlineHashes)
{
    runBenchmark<InlineHashes>("InlineHashes"_s, 630, 0x11252d6ff9f9346dull);
}

TEST(ContentSecurityPolicyBench, StrictDynamic)
{
    runBenchmark<StrictDynamic>("StrictDynamic"_s, 380, 0x094ae6403b4d1d22ull);
}

TEST(ContentSecurityPolicyBench, ReportOnlyViolations)
{
    runBenchmark<ReportOnlyViolations>("ReportOnlyViolations"_s, 670, 0x7b385314178224fbull);
}

TEST(ContentSecurityPolicyBench, UpgradeInsecureRequests)
{
    runBenchmark<UpgradeInsecureRequests>("UpgradeInsecureRequests"_s, 2100, 0x906cbb43b7e4f12bull);
}

TEST(ContentSecurityPolicyBench, TrustedTypes)
{
    runBenchmark<TrustedTypes>("TrustedTypes"_s, 270, 0x42356ed1275a92bdull);
}

TEST(ContentSecurityPolicyBench, FrameAncestors)
{
    runBenchmark<FrameAncestors>("FrameAncestors"_s, 420, 0xaf7b93e058fb0378ull);
}

TEST(ContentSecurityPolicyBench, PageLoadMix)
{
    runBenchmark<PageLoadMix>("PageLoadMix"_s, 3200, 0x7810e0ca2908cbc9ull);
}

} // namespace TestWebKitAPI::ContentSecurityPolicyBenchmark
