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
#import <WebCore/AuthenticatorAttachment.h>
#import <WebCore/PublicKeyCredentialCreationOptions.h>
#import <WebCore/PublicKeyCredentialRequestOptions.h>
#import <WebCore/SecurityOrigin.h>
#import <WebCore/SecurityOriginData.h>
#import <WebCore/WellKnownOriginList.h>
#import <WebKit/WKError.h>
#import <WebKit/WKWebViewConfigurationPrivate.h>
#import <WebKit/_WKAuthenticationExtensionsClientInputs.h>
#import <WebKit/_WKAuthenticatorSelectionCriteria.h>
#import <WebKit/_WKPublicKeyCredentialCreationOptions.h>
#import <WebKit/_WKPublicKeyCredentialDescriptor.h>
#import <WebKit/_WKPublicKeyCredentialParameters.h>
#import <WebKit/_WKPublicKeyCredentialRelyingPartyEntity.h>
#import <WebKit/_WKPublicKeyCredentialRequestOptions.h>
#import <WebKit/_WKPublicKeyCredentialUserEntity.h>
#import <WebKit/_WKWebAuthenticationPanel.h>
#import <WebKit/_WKWebAuthenticationPanelForTesting.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <wtf/BlockPtr.h>
#import <wtf/Function.h>
#import <wtf/HashSet.h>
#import <wtf/MonotonicTime.h>
#import <wtf/RetainPtr.h>
#import <wtf/StdLibExtras.h>
#import <wtf/URL.h>
#import <wtf/Vector.h>
#import <wtf/cocoa/SpanCocoa.h>
#import <wtf/darwin/DispatchExtras.h>
#import <wtf/text/MakeString.h>
#import <wtf/text/StringBuilder.h>
#import <wtf/text/WTFString.h>

// One TEST per shape of the WebAuthn requests code that the UI process runs once per ceremony: the request builders
// and the response mapping of the AuthenticationServices path, the transports a request discovers on, the related
// origins list, the panel's option converters and the bindings' JSON parser. Each shape runs through the entry that
// WebKit's own code calls and checks a digest of everything it observed.
//
// The AuthenticationServices shapes (BuildRegistrationRequests, BuildAssertionRequests, MapAssertionResponse) run real
// ceremonies from a page against a stand-in for the framework. The stand-in replaces every method of the classes the
// request code uses with a forwarder that records the call (class, selector, rendered arguments) and answers from a
// script, and puts the methods back afterwards. The log of calls is part of each digest, so the order and the values
// of every call into the framework are compared. CollectTransports runs ceremonies on the mock authenticators, which
// start discovery on the transports the request names; the digest covers the outcome of each.
//
// Each expected checksum is the digest of one pass's outputs. A test given kRequestsUnrecorded prints
// "<Name>: UNRECORDED checksum=<digest>" instead, to record a new one. With WEBKIT_RUN_BENCHMARKS set the pass is
// repeated and the time printed.

namespace TestWebKitAPI {

namespace WebAuthnRequestsBench {

using namespace WebCore;

// Stands for a checksum not yet recorded.
static constexpr uint64_t kRequestsUnrecorded = 0;

// Timed passes per shape, so that each timed loop runs about a second.
static constexpr unsigned timedPassesBuildRegistration = 300;
static constexpr unsigned timedPassesBuildAssertion = 400;
static constexpr unsigned timedPassesMapAssertion = 200;
static constexpr unsigned timedPassesPanelConvert = 30000;

// FNV-1a over everything a test observes, in a fixed order.
class Hash {
public:
    void add(uint64_t value)
    {
        for (unsigned i = 0; i < 8; ++i) {
            m_state ^= (value >> (i * 8)) & 0xff;
            m_state *= 0x100000001b3ULL;
        }
    }

    void add(std::span<const uint8_t> bytes)
    {
        add(static_cast<uint64_t>(bytes.size()));
        for (uint8_t byte : bytes) {
            m_state ^= byte;
            m_state *= 0x100000001b3ULL;
        }
    }

    void add(const String& string)
    {
        add(static_cast<uint64_t>(string.isNull()));
        auto utf8 = string.utf8();
        add(byteCast<uint8_t>(utf8.span()));
    }

    void add(NSString *string)
    {
        add(String { string });
    }

    uint64_t value() const { return m_state; }

private:
    uint64_t m_state { 0xcbf29ce484222325ULL };
};

template<typename Pass>
static void run(ASCIILiteral name, size_t work, uint64_t expected, unsigned passes, Pass&& pass)
{
    uint64_t checksum = pass();
    if (expected == kRequestsUnrecorded)
        SAFE_PRINTF("%s: UNRECORDED checksum=%016llx\n", name, static_cast<unsigned long long>(checksum));
    EXPECT_EQ(expected, checksum);
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    unsigned mismatches = 0;
    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < passes; ++i) {
        if (pass() != checksum)
            ++mismatches;
    }
    Seconds elapsed = MonotonicTime::now() - start;
    EXPECT_EQ(0u, mismatches);
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, elapsed.milliseconds(),
        static_cast<double>(work) * passes / elapsed.microseconds(), static_cast<unsigned long long>(checksum));
}

static NSData *deterministicData(size_t length, uint8_t seed)
{
    Vector<uint8_t> bytes;
    for (size_t i = 0; i < length; ++i)
        bytes.append(static_cast<uint8_t>(seed + i * 7));
    return toNSData(bytes.span()).autorelease();
}

// MARK: - The page that runs ceremonies

// Binary values in a spec are strings that start with "b64:". A ceremony resolves to a JSON string of what the page
// observed, or of the error it got.
static const char* const ceremonyScript = R"JS(
function fromBase64(text) {
    return Uint8Array.from(atob(text), c => c.charCodeAt(0));
}
function toBase64(buffer) {
    let text = "";
    for (const byte of new Uint8Array(buffer))
        text += String.fromCharCode(byte);
    return btoa(text);
}
function replacer(key, value) {
    if (value instanceof ArrayBuffer || ArrayBuffer.isView(value))
        return "b64:" + toBase64(value);
    return value;
}
async function ceremony(kind, specText, mock) {
    if (mock && window.internals)
        internals.setMockWebAuthenticationConfiguration(JSON.parse(mock));
    try {
        const publicKey = JSON.parse(specText, (key, value) => typeof value === "string" && value.startsWith("b64:") ? fromBase64(value.slice(4)) : value);
        const credential = kind === "create" ? await navigator.credentials.create({ publicKey }) : await navigator.credentials.get({ publicKey });
        const response = credential.response;
        const result = { id: credential.id, attachment: credential.authenticatorAttachment, raw: credential.rawId, clientData: response.clientDataJSON, extensions: credential.getClientExtensionResults() };
        if (kind === "create") {
            result.attestation = response.attestationObject;
            result.transports = response.getTransports();
        } else {
            result.authenticatorData = response.authenticatorData;
            result.signature = response.signature;
            result.userHandle = response.userHandle;
        }
        return JSON.stringify(result, replacer);
    } catch (error) {
        return JSON.stringify({ error: error.name, message: error.message });
    }
}
function parseLoop(kind, specTexts, repetitions) {
    let first = null;
    let same = true;
    for (let i = 0; i < repetitions; ++i) {
        const out = [];
        for (const text of specTexts) {
            try {
                const json = JSON.parse(text);
                const options = kind === "create" ? PublicKeyCredential.parseCreationOptionsFromJSON(json) : PublicKeyCredential.parseRequestOptionsFromJSON(json);
                out.push(JSON.stringify(options, replacer));
            } catch (error) {
                out.push(error.name + ":" + error.message);
            }
        }
        const joined = out.join("\n");
        if (first === null)
            first = joined;
        else if (joined !== first)
            same = false;
    }
    return same ? first : "DIFFERENT";
}
)JS";

static RetainPtr<TestWKWebView> ceremonyWebView()
{
    auto *configuration = [WKWebViewConfiguration _test_configurationWithTestPlugInClassName:@"WebProcessPlugInWithInternals" configureJSCForTesting:YES];
    [configuration _setAllowTestOnlyIPC:YES];
    RetainPtr webView = adoptNS([[TestWKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:configuration]);
    NSString *html = [NSString stringWithFormat:@"<input type='text' id='input'><script>%s</script>", ceremonyScript];
    [webView synchronouslyLoadHTMLString:html baseURL:[NSURL URLWithString:@"https://example.com/"]];
    [webView focus];
    [webView objectByEvaluatingJavaScriptWithUserGesture:@"document.getElementById('input').focus()"];
    return webView;
}

static NSString *ceremony(TestWKWebView *webView, NSString *kind, NSString *spec, NSString *mock = nil)
{
    return [webView objectByCallingAsyncFunction:@"return await ceremony(kind, spec, mock);" withArguments:@{ @"kind": kind, @"spec": spec, @"mock": mock ?: @"" }];
}

// MARK: - The framework stand-in

// Every method of the classes below, and of their superclasses short of NSObject, is replaced by the runtime's
// forwarder. The forwarded call is rendered into the log and answered: an initializer returns the receiver, a getter
// returns what the object's script holds (the zero value otherwise), a provider's factory returns an instance of its
// request class, and the controller's perform methods complete the ceremony with the next scripted answer.
class StandIn {
public:
    StandIn()
    {
        RELEASE_ASSERT(!s_current);
        s_current = this;
        dlopen("/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices", RTLD_NOW);
        m_log = adoptNS([[NSMutableString alloc] init]);
        m_authorizationErrorDomain = valueOf("ASAuthorizationErrorDomain");
        for (NSString *name in classNames())
            patch(NSClassFromString(name));
    }

    ~StandIn()
    {
        for (auto& original : m_originals)
            class_replaceMethod(original.cls, original.selector, original.implementation, original.types);
        s_current = nullptr;
    }

    // The framework could not be loaded or a class is missing: the shapes that need it report it, and do not pass.
    bool isAvailable() const { return !!NSClassFromString(@"ASAuthorizationController"); }

    using Answer = Function<void(StandIn&, id controller, id delegate)>;

    void setAnswers(Vector<Answer>&& answers)
    {
        m_answers = WTF::move(answers);
        m_nextAnswer = 0;
    }

    // The calls recorded since the last take.
    RetainPtr<NSString> takeLog()
    {
        RetainPtr<NSString> result = adoptNS([m_log copy]);
        [m_log setString:@""];
        return result;
    }

    NSString *authorizationErrorDomain() const { return m_authorizationErrorDomain.get(); }

    // An instance of a framework class that answers its getters from a dictionary, for use in a scripted answer.
    id makeObject(NSString *className, NSDictionary *fields)
    {
        Class cls = NSClassFromString(className);
        if (!cls)
            return nil;
        patch(cls);
        id object = class_createInstance(cls, 0);
        objc_setAssociatedObject(object, &s_fieldsKey, fields, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return [object autorelease];
    }

    void complete(id controller, id delegate, NSString *credentialClass, NSDictionary *credentialFields)
    {
        id credential = makeObject(credentialClass, credentialFields);
        id authorization = makeObject(@"ASAuthorization", credential ? @{ @"credential": credential } : @{ });
        NSString *selector = @"authorizationController:didCompleteWithAuthorization:";
        [delegate performSelector:NSSelectorFromString(selector) withObject:controller withObject:authorization];
    }

    void fail(id controller, id delegate, NSString *domain, NSInteger code, NSDictionary *userInfo = nil)
    {
        NSError *error = [NSError errorWithDomain:domain code:code userInfo:userInfo];
        [delegate performSelector:NSSelectorFromString(@"authorizationController:didCompleteWithError:") withObject:controller withObject:error];
    }

private:
    struct Original {
        Class cls;
        SEL selector;
        IMP implementation;
        const char* types;
    };

    static NSArray<NSString *> *classNames()
    {
        return @[
            @"ASAuthorization",
            @"ASAuthorizationController",
            @"ASAuthorizationPlatformPublicKeyCredentialProvider",
            @"ASAuthorizationSecurityKeyPublicKeyCredentialProvider",
            @"ASAuthorizationWebBrowserPlatformPublicKeyCredentialProvider",
            @"ASPublicKeyCredentialClientData",
            @"ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest",
            @"ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest",
            @"ASAuthorizationPlatformPublicKeyCredentialAssertionRequest",
            @"ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest",
            @"ASAuthorizationPlatformPublicKeyCredentialRegistration",
            @"ASAuthorizationSecurityKeyPublicKeyCredentialRegistration",
            @"ASAuthorizationPlatformPublicKeyCredentialAssertion",
            @"ASAuthorizationSecurityKeyPublicKeyCredentialAssertion",
            @"ASAuthorizationPlatformPublicKeyCredentialDescriptor",
            @"ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor",
            @"ASAuthorizationPublicKeyCredentialParameters",
            @"ASAuthorizationPublicKeyCredentialLargeBlobRegistrationInput",
            @"ASAuthorizationPublicKeyCredentialLargeBlobAssertionInput",
            @"ASAuthorizationPublicKeyCredentialLargeBlobRegistrationOutput",
            @"ASAuthorizationPublicKeyCredentialLargeBlobAssertionOutput",
            @"ASAuthorizationPublicKeyCredentialPRFRegistrationInput",
            @"ASAuthorizationPublicKeyCredentialPRFAssertionInput",
            @"ASAuthorizationPublicKeyCredentialPRFAssertionInputValues",
            @"ASAuthorizationPublicKeyCredentialPRFRegistrationOutput",
            @"ASAuthorizationPublicKeyCredentialPRFAssertionOutput",
        ];
    }

    static RetainPtr<NSString> valueOf(const char* symbol)
    {
        void* address = dlsym(RTLD_DEFAULT, symbol);
        if (!address)
            return { };
        return retainPtr(*static_cast<NSString* const*>(address));
    }

    static bool isKeptAsIs(SEL selector)
    {
        static NSSet *kept = [[NSSet alloc] initWithObjects:@"dealloc", @"retain", @"release", @"autorelease", @"retainCount",
            @"class", @"isKindOfClass:", @"isMemberOfClass:", @"respondsToSelector:", @"conformsToProtocol:", @"forwardInvocation:",
            @"methodSignatureForSelector:", @"description", @"debugDescription", @"hash", @"isEqual:", @"copyWithZone:",
            @"mutableCopyWithZone:", @"doesNotRecognizeSelector:", @"forwardingTargetForSelector:", @"superclass", nil];
        NSString *name = NSStringFromSelector(selector);
        return [kept containsObject:name] || [name hasPrefix:@"."] || [name hasPrefix:@"_"];
    }

    void patch(Class cls)
    {
        for (Class current = cls; current && current != NSObject.class; current = class_getSuperclass(current)) {
            if (m_patched.contains(current))
                continue;
            m_patched.add(current);
            unsigned count = 0;
            Method* methods = class_copyMethodList(current, &count);
            for (unsigned i = 0; i < count; ++i) {
                SEL selector = method_getName(methods[i]);
                if (isKeptAsIs(selector))
                    continue;
                const char* types = method_getTypeEncoding(methods[i]);
                m_originals.append({ current, selector, method_getImplementation(methods[i]), types });
                class_replaceMethod(current, selector, reinterpret_cast<IMP>(_objc_msgForward), types);
            }
            free(methods);
            IMP forward = imp_implementationWithBlock(^(id receiver, NSInvocation *invocation) {
                s_current->forward(receiver, invocation);
            });
            class_addMethod(current, @selector(forwardInvocation:), forward, "v@:@");
        }
    }

    static void render(NSMutableString *out, id object)
    {
        if (!object)
            [out appendString:@"nil"];
        else if (object_isClass(object))
            [out appendString:NSStringFromClass(object)];
        else if ([object isKindOfClass:NSString.class])
            [out appendFormat:@"\"%@\"", object];
        else if ([object isKindOfClass:NSData.class]) {
            [out appendString:@"<"];
            for (uint8_t byte : WTF::span(static_cast<NSData *>(object)))
                [out appendFormat:@"%02x", byte];
            [out appendString:@">"];
        } else if ([object isKindOfClass:NSNumber.class])
            [out appendFormat:@"%@", object];
        else if ([object isKindOfClass:NSURL.class])
            [out appendFormat:@"%@", [object absoluteString]];
        else if ([object isKindOfClass:NSArray.class]) {
            [out appendString:@"["];
            bool first = true;
            for (id element in object) {
                if (!first)
                    [out appendString:@", "];
                first = false;
                render(out, element);
            }
            [out appendString:@"]"];
        } else if ([object isKindOfClass:NSDictionary.class]) {
            [out appendString:@"{"];
            bool first = true;
            NSArray *sortedKeys = [[object allKeys] sortedArrayUsingSelector:@selector(compare:)];
            for (id key in sortedKeys) {
                if (!first)
                    [out appendString:@", "];
                first = false;
                render(out, key);
                [out appendString:@": "];
                render(out, object[key]);
            }
            [out appendString:@"}"];
        } else if ([NSStringFromClass([object class]) hasPrefix:@"AS"])
            [out appendString:NSStringFromClass([object class])];
        else
            [out appendString:@"<object>"];
    }

    static void renderArgument(NSMutableString *out, NSInvocation *invocation, NSUInteger index)
    {
        const char* type = [invocation.methodSignature getArgumentTypeAtIndex:index];
        while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' || *type == 'O' || *type == 'R' || *type == 'V')
            ++type;
        switch (*type) {
        case '@': {
            if (type[1] == '?') {
                [out appendString:@"<block>"];
                return;
            }
            id object = nil;
            [invocation getArgument:&object atIndex:index];
            render(out, object);
            return;
        }
        case '#': {
            Class cls = nil;
            [invocation getArgument:&cls atIndex:index];
            [out appendString:NSStringFromClass(cls)];
            return;
        }
        case 'B': {
            bool value = false;
            [invocation getArgument:&value atIndex:index];
            [out appendString:value ? @"YES" : @"NO"];
            return;
        }
        case 'c': case 'C': {
            uint8_t value = 0;
            [invocation getArgument:&value atIndex:index];
            [out appendFormat:@"%d", value];
            return;
        }
        case 's': case 'S': {
            uint16_t value = 0;
            [invocation getArgument:&value atIndex:index];
            [out appendFormat:@"%d", value];
            return;
        }
        case 'i': case 'I': {
            int32_t value = 0;
            [invocation getArgument:&value atIndex:index];
            [out appendFormat:@"%d", value];
            return;
        }
        case 'l': case 'L': case 'q': case 'Q': {
            int64_t value = 0;
            [invocation getArgument:&value atIndex:index];
            [out appendFormat:@"%lld", value];
            return;
        }
        case 'd': {
            double value = 0;
            [invocation getArgument:&value atIndex:index];
            [out appendFormat:@"%.17g", value];
            return;
        }
        case 'f': {
            float value = 0;
            [invocation getArgument:&value atIndex:index];
            [out appendFormat:@"%.9g", value];
            return;
        }
        default:
            [out appendString:@"?"];
        }
    }

    static NSString *requestClassNameForFactory(id receiver, NSString *selectorName)
    {
        // "ASAuthorizationPlatformPublicKeyCredentialProvider" -> "ASAuthorizationPlatformPublicKeyCredential".
        NSString *receiverName = NSStringFromClass([receiver class]);
        receiverName = [receiverName stringByReplacingOccurrencesOfString:@"WebBrowser" withString:@""];
        NSString *prefix = [receiverName stringByReplacingOccurrencesOfString:@"Provider" withString:@""];
        if ([selectorName hasPrefix:@"createCredentialRegistrationRequest"])
            return [prefix stringByAppendingString:@"RegistrationRequest"];
        if ([selectorName hasPrefix:@"createCredentialAssertionRequest"])
            return [prefix stringByAppendingString:@"AssertionRequest"];
        return nil;
    }

    void forward(id receiver, NSInvocation *invocation)
    {
        NSString *selectorName = NSStringFromSelector(invocation.selector);
        NSMethodSignature *signature = invocation.methodSignature;

        NSMutableString *line = [NSMutableString stringWithFormat:@"%@ %@", NSStringFromClass([receiver class]), selectorName];
        for (NSUInteger i = 2; i < signature.numberOfArguments; ++i) {
            [line appendString:i == 2 ? @" (" : @", "];
            renderArgument(line, invocation, i);
        }
        if (signature.numberOfArguments > 2)
            [line appendString:@")"];
        [m_log appendFormat:@"%@\n", line];

        NSDictionary *fields = objc_getAssociatedObject(receiver, &s_fieldsKey);
        id scripted = fields[selectorName];

        if ([selectorName isEqualToString:@"setDelegate:"]) {
            id delegate = nil;
            [invocation getArgument:&delegate atIndex:2];
            m_delegate = delegate;
        } else if ([selectorName isEqualToString:@"performRequests"] || [selectorName isEqualToString:@"performAutoFillAssistedRequests"]) {
            // Completion is asynchronous, as the framework's is.
            RetainPtr<id> controller = receiver;
            RetainPtr<id> delegate = m_delegate;
            dispatch_async(mainDispatchQueueSingleton(), makeBlockPtr([this, controller, delegate] {
                RELEASE_ASSERT(m_nextAnswer < m_answers.size());
                m_answers[m_nextAnswer++](*this, controller.get(), delegate.get());
            }).get());
        }

        const char* returnType = signature.methodReturnType;
        while (*returnType == 'r' || *returnType == 'n' || *returnType == 'N' || *returnType == 'o' || *returnType == 'O' || *returnType == 'R' || *returnType == 'V')
            ++returnType;
        if (*returnType == 'v')
            return;
        if (*returnType == '@') {
            id result = nil;
            if ([selectorName hasPrefix:@"init"])
                result = receiver;
            else if (scripted)
                result = scripted;
            else if (NSString *requestClass = requestClassNameForFactory(receiver, selectorName))
                result = makeObject(requestClass, @{ });
            [invocation setReturnValue:&result];
            return;
        }
        // A scalar: the scripted number, or zero.
        uint8_t buffer[32] = { };
        NSUInteger size = 0;
        NSGetSizeAndAlignment(returnType, &size, nullptr);
        RELEASE_ASSERT(size <= sizeof(buffer));
        if ([scripted isKindOfClass:NSNumber.class]) {
            if (*returnType == 'd') {
                double value = [scripted doubleValue];
                memcpySpan(std::span { buffer }, asByteSpan(value).first(std::min<size_t>(size, sizeof(value))));
            } else if (*returnType == 'f') {
                float value = [scripted floatValue];
                memcpySpan(std::span { buffer }, asByteSpan(value).first(std::min<size_t>(size, sizeof(value))));
            } else {
                int64_t value = [scripted longLongValue];
                memcpySpan(std::span { buffer }, asByteSpan(value).first(std::min<size_t>(size, sizeof(value))));
            }
        }
        [invocation setReturnValue:buffer];
    }

    static inline char s_fieldsKey;
    static inline StandIn* s_current { nullptr };

    RetainPtr<NSMutableString> m_log;
    RetainPtr<NSString> m_authorizationErrorDomain;
    HashSet<Class> m_patched;
    Vector<Original> m_originals;
    Vector<Answer> m_answers;
    size_t m_nextAnswer { 0 };
    RetainPtr<id> m_delegate;
};

// MARK: - Specs

static NSString *creationSpec(const char* extra)
{
    return [NSString stringWithFormat:@"{\"rp\":{\"name\":\"Example\",\"id\":\"example.com\"},"
        "\"user\":{\"id\":\"b64:dXNlcjEyMzQ=\",\"name\":\"user@example.com\",\"displayName\":\"User\"},"
        "\"challenge\":\"b64:AAECAwQFBgcICQoLDA0ODw==\","
        "\"pubKeyCredParams\":[{\"type\":\"public-key\",\"alg\":-7},{\"type\":\"public-key\",\"alg\":-257}]%s}", extra];
}

static NSString *assertionSpec(const char* extra)
{
    return [NSString stringWithFormat:@"{\"rpId\":\"example.com\",\"challenge\":\"b64:AAECAwQFBgcICQoLDA0ODw==\"%s}", extra];
}

static Vector<NSString *> creationSpecs()
{
    static constexpr const char* extras[] = {
        "",
        ",\"authenticatorSelection\":{\"authenticatorAttachment\":\"platform\"}",
        ",\"authenticatorSelection\":{\"authenticatorAttachment\":\"cross-platform\",\"userVerification\":\"required\",\"residentKey\":\"required\"}",
        ",\"authenticatorSelection\":{\"userVerification\":\"discouraged\",\"requireResidentKey\":true}",
        ",\"attestation\":\"direct\"",
        ",\"attestation\":\"enterprise\",\"timeout\":30000",
        ",\"excludeCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\"}]",
        ",\"excludeCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\",\"transports\":[\"internal\",\"hybrid\"]},"
            "{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDI=\",\"transports\":[\"usb\",\"nfc\",\"ble\"]},"
            "{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDM=\",\"transports\":[\"usb\"]}]",
        ",\"extensions\":{\"prf\":{}}",
        ",\"extensions\":{\"prf\":{\"eval\":{\"first\":\"b64:c2FsdC1vbmU=\",\"second\":\"b64:c2FsdC10d28=\"}}}",
        ",\"extensions\":{\"largeBlob\":{\"support\":\"required\"}}",
        ",\"extensions\":{\"credProps\":true},\"timeout\":200000,\"attestation\":\"indirect\"",
    };
    Vector<NSString *> specs;
    for (auto* extra : extras)
        specs.append(creationSpec(extra));
    return specs;
}

static Vector<NSString *> assertionSpecs()
{
    static constexpr const char* extras[] = {
        "",
        ",\"timeout\":1000",
        ",\"userVerification\":\"required\"",
        ",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\"}]",
        ",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\",\"transports\":[\"internal\"]},"
            "{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDI=\",\"transports\":[\"usb\",\"nfc\"]},"
            "{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDM=\"}]",
        ",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\",\"transports\":[\"internal\"]}]",
        ",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\",\"transports\":[\"usb\",\"nfc\",\"hybrid\"]}]",
        ",\"extensions\":{\"appid\":\"https://example.com/appid.json\"}",
        ",\"extensions\":{\"prf\":{\"eval\":{\"first\":\"b64:c2FsdC1vbmU=\"}}}",
        ",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\"}],"
            "\"extensions\":{\"prf\":{\"evalByCredential\":{\"Y3JlZDAwMDE\":{\"first\":\"b64:c2FsdC1vbmU=\",\"second\":\"b64:c2FsdC10d28=\"}}}}",
        ",\"extensions\":{\"largeBlob\":{\"read\":true}}",
        ",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\"}],"
            "\"extensions\":{\"largeBlob\":{\"write\":\"b64:AQIDBA==\"}}",
    };
    Vector<NSString *> specs;
    for (auto* extra : extras)
        specs.append(assertionSpec(extra));
    return specs;
}

static size_t totalLength(const Vector<NSString *>& strings)
{
    size_t total = 0;
    for (NSString *string : strings)
        total += string.length;
    return total;
}

// MARK: - Scripted answers

static Vector<StandIn::Answer> cancelledAnswers(size_t count)
{
    Vector<StandIn::Answer> answers;
    for (size_t i = 0; i < count; ++i) {
        answers.append([](StandIn& standIn, id controller, id delegate) {
            standIn.fail(controller, delegate, standIn.authorizationErrorDomain(), 1001);
        });
    }
    return answers;
}

static NSDictionary *prfOutput(StandIn& standIn, NSString *className, bool withSecond)
{
    NSMutableDictionary *fields = [NSMutableDictionary dictionaryWithObjectsAndKeys:deterministicData(32, 0x40), @"first", @1, @"isSupported", nil];
    if (withSecond)
        fields[@"second"] = deterministicData(32, 0x60);
    id output = standIn.makeObject(className, fields);
    return output ? @{ @"prf": output } : @{ };
}

static NSDictionary *mergedFields(NSDictionary *base, NSDictionary *more)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:base];
    [result addEntriesFromDictionary:more];
    return result;
}

static Vector<StandIn::Answer> registrationAnswers()
{
    Vector<StandIn::Answer> answers;
    auto base = [](uint8_t seed, NSInteger attachment) {
        return @{
            @"credentialID": deterministicData(16, seed),
            @"rawAttestationObject": deterministicData(96, seed + 1),
            @"rawClientDataJSON": deterministicData(48, seed + 2),
            @"attachment": @(attachment),
        };
    };
    answers.append([=](StandIn& standIn, id controller, id delegate) {
        id largeBlob = standIn.makeObject(@"ASAuthorizationPublicKeyCredentialLargeBlobRegistrationOutput", @{ @"isSupported": @1 });
        standIn.complete(controller, delegate, @"ASAuthorizationPlatformPublicKeyCredentialRegistration", mergedFields(base(1, 1), largeBlob ? @{ @"largeBlob": largeBlob } : @{ }));
    });
    answers.append([=](StandIn& standIn, id controller, id delegate) {
        standIn.complete(controller, delegate, @"ASAuthorizationPlatformPublicKeyCredentialRegistration", mergedFields(base(2, 0), prfOutput(standIn, @"ASAuthorizationPublicKeyCredentialPRFRegistrationOutput", true)));
    });
    answers.append([=](StandIn& standIn, id controller, id delegate) {
        standIn.complete(controller, delegate, @"ASAuthorizationSecurityKeyPublicKeyCredentialRegistration", mergedFields(base(3, 0), @{ @"transports": @[ @"usb", @"nfc" ] }));
    });
    answers.append([=](StandIn& standIn, id controller, id delegate) {
        standIn.complete(controller, delegate, @"ASAuthorizationSecurityKeyPublicKeyCredentialRegistration", mergedFields(base(4, 0), prfOutput(standIn, @"ASAuthorizationPublicKeyCredentialPRFRegistrationOutput", false)));
    });
    // Each error class and domain the mapping tells apart.
    answers.append([](StandIn& standIn, id controller, id delegate) {
        standIn.fail(controller, delegate, standIn.authorizationErrorDomain(), 1001);
    });
    answers.append([](StandIn& standIn, id controller, id delegate) {
        standIn.fail(controller, delegate, standIn.authorizationErrorDomain(), 1006);
    });
    answers.append([](StandIn& standIn, id controller, id delegate) {
        NSError *underlying = [NSError errorWithDomain:WKErrorDomain code:9 userInfo:@{ NSLocalizedDescriptionKey: @"scripted underlying error" }];
        standIn.fail(controller, delegate, standIn.authorizationErrorDomain(), 1004, @{ NSUnderlyingErrorKey: underlying });
    });
    // A WebKit error carries the exception code in its low byte only.
    answers.append([](StandIn& standIn, id controller, id delegate) {
        standIn.fail(controller, delegate, WKErrorDomain, 0x10B, @{ NSLocalizedDescriptionKey: @"scripted truncated code" });
    });
    answers.append([](StandIn& standIn, id controller, id delegate) {
        standIn.fail(controller, delegate, WKErrorDomain, 0, @{ NSLocalizedDescriptionKey: @"scripted code zero" });
    });
    return answers;
}

static Vector<StandIn::Answer> assertionAnswers()
{
    Vector<StandIn::Answer> answers;
    auto base = [](uint8_t seed, NSInteger attachment, NSData *userID) {
        return @{
            @"credentialID": deterministicData(16, seed),
            @"rawAuthenticatorData": deterministicData(37, seed + 1),
            @"signature": deterministicData(70, seed + 2),
            @"rawClientDataJSON": deterministicData(48, seed + 3),
            @"userID": userID,
            @"attachment": @(attachment),
        };
    };
    answers.append([=](StandIn& standIn, id controller, id delegate) {
        id largeBlob = standIn.makeObject(@"ASAuthorizationPublicKeyCredentialLargeBlobAssertionOutput", @{ @"readData": deterministicData(12, 0x70), @"didWrite": @1 });
        standIn.complete(controller, delegate, @"ASAuthorizationPlatformPublicKeyCredentialAssertion", mergedFields(base(11, 1, deterministicData(8, 5)), largeBlob ? @{ @"largeBlob": largeBlob } : @{ }));
    });
    answers.append([=](StandIn& standIn, id controller, id delegate) {
        // An empty user handle maps to none.
        standIn.complete(controller, delegate, @"ASAuthorizationPlatformPublicKeyCredentialAssertion", mergedFields(base(12, 0, [NSData data]), prfOutput(standIn, @"ASAuthorizationPublicKeyCredentialPRFAssertionOutput", true)));
    });
    answers.append([=](StandIn& standIn, id controller, id delegate) {
        standIn.complete(controller, delegate, @"ASAuthorizationSecurityKeyPublicKeyCredentialAssertion", mergedFields(base(13, 0, deterministicData(8, 6)), @{ @"appID": @1 }));
    });
    answers.append([=](StandIn& standIn, id controller, id delegate) {
        standIn.complete(controller, delegate, @"ASAuthorizationSecurityKeyPublicKeyCredentialAssertion", mergedFields(base(14, 0, [NSData data]), prfOutput(standIn, @"ASAuthorizationPublicKeyCredentialPRFAssertionOutput", false)));
    });
    answers.append([](StandIn& standIn, id controller, id delegate) {
        standIn.fail(controller, delegate, standIn.authorizationErrorDomain(), 1001);
    });
    answers.append([](StandIn& standIn, id controller, id delegate) {
        NSError *underlying = [NSError errorWithDomain:WKErrorDomain code:0x10B userInfo:@{ NSLocalizedDescriptionKey: @"scripted underlying truncated" }];
        standIn.fail(controller, delegate, standIn.authorizationErrorDomain(), 1004, @{ NSUnderlyingErrorKey: underlying });
    });
    answers.append([](StandIn& standIn, id controller, id delegate) {
        standIn.fail(controller, delegate, WKErrorDomain, 255, @{ NSLocalizedDescriptionKey: @"scripted code 255" });
    });
    return answers;
}

// One pass over specs on the stand-in: each ceremony's outcome and the calls it made into the framework.
static uint64_t standInPass(TestWKWebView *webView, StandIn& standIn, NSString *kind, const Vector<NSString *>& specs, Vector<StandIn::Answer>&& answers, unsigned& unreached)
{
    Hash hash;
    RELEASE_ASSERT(answers.size() == specs.size());
    standIn.setAnswers(WTF::move(answers));
    for (NSString *spec : specs) {
        NSString *outcome = ceremony(webView, kind, spec);
        RetainPtr<NSString> log = standIn.takeLog();
        if (!log.get().length)
            ++unreached;
        hash.add(outcome);
        hash.add(log.get());
    }
    return hash.value();
}

} // namespace WebAuthnRequestsBench

using namespace WebAuthnRequestsBench;

TEST(WebAuthnRequestsBench, BuildRegistrationRequests)
{
    StandIn standIn;
    ASSERT_TRUE(standIn.isAvailable());
    auto webView = ceremonyWebView();
    auto specs = creationSpecs();
    unsigned unreached = 0;
    static constexpr uint64_t expected = 0xcbf47dee99582395ULL;
    run("BuildRegistrationRequests"_s, totalLength(specs), expected, timedPassesBuildRegistration, [&] {
        return standInPass(webView.get(), standIn, @"create", specs, cancelledAnswers(specs.size()), unreached);
    });
    // A ceremony that never reached the framework tests only the early rejects.
    EXPECT_EQ(0u, unreached);
}

TEST(WebAuthnRequestsBench, BuildAssertionRequests)
{
    StandIn standIn;
    ASSERT_TRUE(standIn.isAvailable());
    auto webView = ceremonyWebView();
    auto specs = assertionSpecs();
    unsigned unreached = 0;
    static constexpr uint64_t expected = 0xd8f3984c2d0fa749ULL;
    run("BuildAssertionRequests"_s, totalLength(specs), expected, timedPassesBuildAssertion, [&] {
        return standInPass(webView.get(), standIn, @"get", specs, cancelledAnswers(specs.size()), unreached);
    });
    EXPECT_EQ(0u, unreached);
}

TEST(WebAuthnRequestsBench, MapAssertionResponse)
{
    StandIn standIn;
    ASSERT_TRUE(standIn.isAvailable());
    auto webView = ceremonyWebView();
    // The same request each time; what varies is the scripted answer: each credential class, extension outputs, error
    // domain and code.
    auto creationAnswers = registrationAnswers();
    auto requestAnswers = assertionAnswers();
    Vector<NSString *> creations;
    for (size_t i = 0; i < creationAnswers.size(); ++i)
        creations.append(creationSpec(""));
    Vector<NSString *> assertions;
    for (size_t i = 0; i < requestAnswers.size(); ++i)
        assertions.append(assertionSpec(""));
    size_t work = totalLength(creations) + totalLength(assertions);
    unsigned unreached = 0;
    static constexpr uint64_t expected = 0x727dfa493635bdadULL;
    run("MapAssertionResponse"_s, work, expected, timedPassesMapAssertion, [&] {
        Hash hash;
        hash.add(standInPass(webView.get(), standIn, @"create", creations, registrationAnswers(), unreached));
        hash.add(standInPass(webView.get(), standIn, @"get", assertions, assertionAnswers(), unreached));
        return hash.value();
    });
    EXPECT_EQ(0u, unreached);
}

// MARK: - Transports

// Discovery starts on the transports the request names: every one with no credentials listed or a credential that names
// none, the union of the listed credentials' otherwise, and one for each attachment of a registration. The mock
// authenticators answer at once or the short timeout ends the ceremony; the digest covers each ceremony's result, not
// the transports it started on. No credential names the hybrid transport: the mock authenticators have no hybrid
// service, and a Debug build asserts on one.
TEST(WebAuthnRequestsBench, CollectTransports)
{
    auto webView = ceremonyWebView();
    static constexpr const char* noCredentials = "{\"silentFailure\":true,\"hid\":{\"stage\":\"request\",\"subStage\":\"msg\",\"error\":\"malicious-payload\",\"payloadBase64\":[\"Lg==\",\"Lg==\",\"Lg==\",\"Lg==\",\"Lg==\"]}}";
    static constexpr const char* localOnly = "{\"local\":{\"userVerification\":\"no\",\"acceptAttestation\":false}}";
    static constexpr const char* assertionAllowLists[] = {
        "",
        ",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\"}]",
        ",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\",\"transports\":[\"internal\"]}]",
        ",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\",\"transports\":[\"usb\",\"nfc\"]}]",
        ",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\",\"transports\":[\"ble\"]}]",
        ",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\",\"transports\":[\"internal\",\"usb\"]}]",
        ",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDE=\",\"transports\":[\"smart-card\"]},{\"type\":\"public-key\",\"id\":\"b64:Y3JlZDAwMDI=\",\"transports\":[\"nfc\"]}]",
    };
    static constexpr const char* registrationSelections[] = {
        "",
        ",\"authenticatorSelection\":{\"authenticatorAttachment\":\"platform\"}",
        ",\"authenticatorSelection\":{\"authenticatorAttachment\":\"cross-platform\"}",
    };
    Vector<NSString *> assertions;
    for (auto* allowList : assertionAllowLists)
        assertions.append([NSString stringWithFormat:@"{\"challenge\":\"b64:AAECAwQFBgcICQoLDA0ODw==\",\"timeout\":1000%s}", allowList]);
    // Short timeout, and an algorithm the local mock cannot do: the registration ends without a device.
    Vector<NSString *> registrations;
    for (auto* selection : registrationSelections) {
        registrations.append([NSString stringWithFormat:@"{\"rp\":{\"name\":\"localhost\"},\"user\":{\"id\":\"b64:dXNlcjEyMzQ=\",\"name\":\"user\",\"displayName\":\"User\"},"
            "\"challenge\":\"b64:AAECAwQFBgcICQoLDA0ODw==\",\"pubKeyCredParams\":[{\"type\":\"public-key\",\"alg\":-35}],\"timeout\":100%s}", selection]);
    }
    RetainPtr<NSString> noCredentialsConfiguration = [NSString stringWithUTF8String:noCredentials];
    RetainPtr<NSString> localOnlyConfiguration = [NSString stringWithUTF8String:localOnly];
    static constexpr uint64_t expected = 0x5a4a7b0ec4e461f4ULL;
    run("CollectTransports"_s, totalLength(assertions) + totalLength(registrations), expected, 3, [&] {
        Hash hash;
        for (NSString *spec : assertions)
            hash.add(ceremony(webView.get(), @"get", spec, noCredentialsConfiguration.get()));
        for (NSString *spec : registrations)
            hash.add(ceremony(webView.get(), @"create", spec, localOnlyConfiguration.get()));
        return hash.value();
    });
}

// MARK: - Related origins

static String relatedOriginsResource(unsigned count, unsigned distinctLabels)
{
    // A list of `count` origins that share `distinctLabels` registrable labels, the last of them the caller's.
    StringBuilder builder;
    builder.append("{\"origins\":["_s);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            builder.append(',');
        builder.append("\"https://site"_s, i % distinctLabels, "-host"_s, i, ".example"_s, i % 3, ".com\""_s);
    }
    builder.append("]}"_s);
    return builder.toString();
}

TEST(WebAuthnRequestsBench, RelatedOriginsParse)
{
    Vector<String> resources;
    resources.append(relatedOriginsResource(100, 100));
    resources.append(relatedOriginsResource(100, 5));
    resources.append(relatedOriginsResource(100, 6));
    resources.append(relatedOriginsResource(5, 5));
    resources.append("{\"origins\":[\"https://a.example.com\",7,\"https://b.example.com\"]}"_s);
    resources.append("{\"origins\":[\"https://a.example.com\""_s);
    resources.append("{\"other\":[\"https://a.example.com\"]}"_s);
    resources.append(makeString(char16_t { 0xFEFF }, "{\"origins\":[\"https://a.example.com\"]}"_s));
    resources.append("{\"origins\":[\"https://xn--bcher-kva.example\",\"https://a.example.com\",\"https://a.example.com\"]}"_s);
    resources.append(""_s);

    static constexpr ASCIILiteral callers[] = {
        "https://site0-host0.example0.com"_s,
        "https://site99-host99.example0.com"_s,
        "https://site5-host5.example2.com"_s,
        "https://site4-host4.example1.com"_s,
        "https://a.example.com"_s,
        "https://b.example.com"_s,
        "https://not-listed.example.org"_s,
        "https://xn--bcher-kva.example"_s,
        "http://a.example.com"_s,
        "https://a.example.com:8443"_s,
    };

    Vector<Vector<uint8_t>> bodies;
    size_t bytes = 0;
    for (auto& resource : resources) {
        auto utf8 = resource.utf8();
        bodies.append(Vector<uint8_t>(byteCast<uint8_t>(utf8.span())));
        bytes += utf8.length() * std::size(callers);
    }

    static constexpr uint64_t expected = 0x66c1736ce85edc84ULL;
    run("RelatedOriginsParse"_s, bytes, expected, 400, [&] {
        Hash hash;
        for (auto& body : bodies) {
            for (auto caller : callers) {
                auto origin = WebCore::SecurityOriginData::fromURL(URL { caller });
                hash.add(static_cast<uint64_t>(WebCore::findOriginInWellKnownList(origin, body.span(), "origins"_s)));
            }
        }
        return hash.value();
    });
}

// MARK: - The panel's converters

static void hashDescriptors(Hash& hash, const Vector<WebCore::PublicKeyCredentialDescriptor>& descriptors)
{
    hash.add(static_cast<uint64_t>(descriptors.size()));
    for (auto& descriptor : descriptors) {
        hash.add(static_cast<uint64_t>(descriptor.type));
        hash.add(descriptor.id.span());
        hash.add(static_cast<uint64_t>(descriptor.transports.size()));
        for (auto transport : descriptor.transports)
            hash.add(static_cast<uint64_t>(transport));
    }
}

static NSArray<NSNumber *> *allTransports()
{
    return @[ @(_WKWebAuthenticationTransportUSB), @(_WKWebAuthenticationTransportNFC), @(_WKWebAuthenticationTransportBLE), @(_WKWebAuthenticationTransportInternal), @(_WKWebAuthenticationTransportCaBLE), @(_WKWebAuthenticationTransportHybrid), @(_WKWebAuthenticationTransportSmartCard) ];
}

static NSArray<_WKPublicKeyCredentialDescriptor *> *descriptors(unsigned count, bool withTransports)
{
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned i = 0; i < count; ++i) {
        RetainPtr descriptor = adoptNS([[_WKPublicKeyCredentialDescriptor alloc] initWithIdentifier:deterministicData(16, i)]);
        if (withTransports)
            [descriptor setTransports:allTransports()];
        [result addObject:descriptor.get()];
    }
    return result;
}

static uint64_t panelConvertersPass()
{
    Hash hash;
    @autoreleasepool {
        RetainPtr rp = adoptNS([[_WKPublicKeyCredentialRelyingPartyEntity alloc] initWithName:@"Example"]);
        [rp setIdentifier:@"example.com"];
        [rp setIcon:@"https://example.com/icon.png"];
        RetainPtr user = adoptNS([[_WKPublicKeyCredentialUserEntity alloc] initWithName:@"user@example.com" identifier:deterministicData(16, 3) displayName:@"User"]);
        RetainPtr minimumRP = adoptNS([[_WKPublicKeyCredentialRelyingPartyEntity alloc] initWithName:@"example.com"]);
        RetainPtr minimumParameters = adoptNS([[_WKPublicKeyCredentialParameters alloc] initWithAlgorithm:@-7]);
        RetainPtr secondParameters = adoptNS([[_WKPublicKeyCredentialParameters alloc] initWithAlgorithm:@-257]);

        for (unsigned variant = 0; variant < 12; ++variant) {
            RetainPtr options = adoptNS([[_WKPublicKeyCredentialCreationOptions alloc] initWithRelyingParty:(variant ? rp.get() : minimumRP.get()) user:user.get() publicKeyCredentialParamaters:(variant % 2 ? @[ minimumParameters.get(), secondParameters.get() ] : @[ minimumParameters.get() ])]);
            if (variant > 1)
                [options setTimeout:@(variant * 20000)];
            if (variant > 2)
                [options setExcludeCredentials:descriptors(variant % 4, variant % 2)];
            if (variant > 3) {
                RetainPtr selection = adoptNS([[_WKAuthenticatorSelectionCriteria alloc] init]);
                [selection setAuthenticatorAttachment:static_cast<_WKAuthenticatorAttachment>(variant % 3)];
                [selection setRequireResidentKey:!!(variant % 2)];
                [selection setUserVerification:static_cast<_WKUserVerificationRequirement>(variant % 3)];
                [options setAuthenticatorSelection:selection.get()];
            }
            if (variant > 5)
                [options setAttestation:static_cast<_WKAttestationConveyancePreference>(variant % 3)];
            if (variant > 7) {
                RetainPtr extensions = adoptNS([[_WKAuthenticationExtensionsClientInputs alloc] init]);
                [extensions setAppid:@"https://example.com/appid.json"];
                [options setExtensions:extensions.get()];
            }

            auto result = [_WKWebAuthenticationPanel convertToCoreCreationOptionsWithOptions:options.get()];
            hash.add(result.rp.name);
            hash.add(result.rp.icon);
            hash.add(result.rp.id);
            hash.add(result.user.name);
            hash.add(result.user.icon);
            hash.add(result.user.id.span());
            hash.add(result.user.displayName);
            hash.add(static_cast<uint64_t>(result.pubKeyCredParams.size()));
            for (auto& parameters : result.pubKeyCredParams) {
                hash.add(static_cast<uint64_t>(parameters.type));
                hash.add(static_cast<uint64_t>(parameters.alg));
            }
            hash.add(static_cast<uint64_t>(result.timeout.value_or(0xffffffffu)));
            hashDescriptors(hash, result.excludeCredentials);
            hash.add(static_cast<uint64_t>(!!result.authenticatorSelection));
            if (result.authenticatorSelection) {
                hash.add(static_cast<uint64_t>(result.authenticatorSelection->authenticatorAttachment.has_value()));
                if (result.authenticatorSelection->authenticatorAttachment)
                    hash.add(static_cast<uint64_t>(*result.authenticatorSelection->authenticatorAttachment));
                hash.add(static_cast<uint64_t>(result.authenticatorSelection->requireResidentKey));
                hash.add(static_cast<uint64_t>(result.authenticatorSelection->userVerification));
            }
            hash.add(static_cast<uint64_t>(result.attestation));
            hash.add(static_cast<uint64_t>(!!result.extensions));
            if (result.extensions)
                hash.add(result.extensions->appid);
        }

        for (unsigned variant = 0; variant < 8; ++variant) {
            RetainPtr options = adoptNS([[_WKPublicKeyCredentialRequestOptions alloc] init]);
            if (variant > 0)
                [options setTimeout:@(variant * 30000)];
            if (variant > 1)
                [options setAllowCredentials:descriptors(variant % 4, variant % 2)];
            if (variant > 3)
                [options setRelyingPartyIdentifier:@"example.com"];
            if (variant > 2)
                [options setUserVerification:static_cast<_WKUserVerificationRequirement>(variant % 3)];
            if (variant > 4) {
                RetainPtr extensions = adoptNS([[_WKAuthenticationExtensionsClientInputs alloc] init]);
                [extensions setAppid:@"https://example.com/appid.json"];
                [options setExtensions:extensions.get()];
            }
            auto result = [_WKWebAuthenticationPanel convertToCoreRequestOptionsWithOptions:options.get()];
            hash.add(static_cast<uint64_t>(result.timeout.value_or(0xffffffffu)));
            hash.add(result.rpId);
            hashDescriptors(hash, result.allowCredentials);
            hash.add(static_cast<uint64_t>(result.userVerification));
            hash.add(static_cast<uint64_t>(!!result.extensions));
            if (result.extensions)
                hash.add(result.extensions->appid);
        }
    }
    return hash.value();
}

TEST(WebAuthnRequestsBench, PanelConvertCreationOptions)
{
    static constexpr uint64_t expected = 0x7cbb1e1d834777ecULL;
    // Each pass converts twelve creation and eight request option sets, about 160 bytes of identifiers and strings each.
    run("PanelConvertCreationOptions"_s, 20 * 160, expected, timedPassesPanelConvert, [] {
        return panelConvertersPass();
    });
}

// MARK: - The bindings' JSON parser

TEST(WebAuthnRequestsBench, ParseCreationOptionsFromJSON)
{
    auto webView = ceremonyWebView();
    // The same options as the registration shape, as the JSON dictionaries the static function takes (base64url
    // strings for the binary members), and some it must reject.
    static constexpr const char* base = "\"rp\":{\"name\":\"Example\",\"id\":\"example.com\"},"
        "\"user\":{\"id\":\"dXNlcjEyMzQ\",\"name\":\"user@example.com\",\"displayName\":\"User\"},"
        "\"challenge\":\"AAECAwQFBgcICQoLDA0ODw\","
        "\"pubKeyCredParams\":[{\"type\":\"public-key\",\"alg\":-7},{\"type\":\"public-key\",\"alg\":-257}]";
    static constexpr const char* extras[] = {
        "",
        ",\"timeout\":30000,\"attestation\":\"direct\"",
        ",\"authenticatorSelection\":{\"authenticatorAttachment\":\"platform\",\"residentKey\":\"required\",\"userVerification\":\"preferred\"}",
        ",\"excludeCredentials\":[{\"type\":\"public-key\",\"id\":\"Y3JlZDAwMDE\",\"transports\":[\"usb\",\"hybrid\"]},{\"type\":\"public-key\",\"id\":\"Y3JlZDAwMDI\"}]",
        ",\"extensions\":{\"prf\":{\"eval\":{\"first\":\"c2FsdC1vbmU\",\"second\":\"c2FsdC10d28\"}},\"largeBlob\":{\"support\":\"preferred\"},\"credProps\":true}",
        ",\"hints\":[\"security-key\",\"client-device\"]",
        // Rejected: a challenge that is not base64url, a user ID with padding, an unknown enumeration value.
    };
    Vector<NSString *> specs;
    for (auto* extra : extras)
        specs.append([NSString stringWithFormat:@"{%s%s}", base, extra]);
    specs.append(@"{\"rp\":{\"name\":\"Example\"},\"user\":{\"id\":\"dXNlcjEyMzQ\",\"name\":\"u\",\"displayName\":\"U\"},\"challenge\":\"***\",\"pubKeyCredParams\":[]}");
    specs.append(@"{\"rp\":{\"name\":\"Example\"},\"user\":{\"id\":\"dXNlcjEyMzQ=\",\"name\":\"u\",\"displayName\":\"U\"},\"challenge\":\"AAECAwQ\",\"pubKeyCredParams\":[]}");
    specs.append(@"{\"rp\":{\"name\":\"Example\"},\"user\":{\"id\":\"dXNlcjEyMzQ\",\"name\":\"u\",\"displayName\":\"U\"},\"challenge\":\"AAECAwQ\",\"pubKeyCredParams\":[],\"attestation\":\"sometimes\"}");

    NSMutableArray *specArray = [NSMutableArray array];
    for (NSString *spec : specs)
        [specArray addObject:spec];

    // One pass is `repetitions` parses of every spec in the page; the digest is of the first one's results, and the page
    // reports a difference between repetitions.
    auto parse = [&](unsigned repetitions) {
        NSString *result = [webView objectByCallingAsyncFunction:@"return parseLoop('create', specs, repetitions);" withArguments:@{ @"specs": specArray, @"repetitions": @(repetitions) }];
        Hash hash;
        hash.add(result);
        return hash.value();
    };
    static constexpr uint64_t expected = 0xf152d0c600ead201ULL;
    static constexpr unsigned repetitionsPerPass = 10000;
    run("ParseCreationOptionsFromJSON"_s, totalLength(specs) * repetitionsPerPass, expected, 3, [&] {
        return parse(repetitionsPerPass);
    });
}

// A process that only starts and exits: the cost a timed run of a shape subtracts.
TEST(WebAuthnRequestsBench, StartUp)
{
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUTHN) && HAVE(UNIFIED_ASC_AUTH_UI)
