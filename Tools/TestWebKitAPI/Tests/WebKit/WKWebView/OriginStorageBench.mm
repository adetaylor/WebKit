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

#import "Helpers/PlatformUtilities.h"
#import "Helpers/Test.h"
#import "Helpers/cocoa/HTTPServer.h"
#import "Helpers/cocoa/TestWKWebView.h"
#import "OriginStorageBenchPage.h"
#import <WebKit/WKPreferencesPrivate.h>
#import <WebKit/WKWebViewConfigurationPrivate.h>
#import <WebKit/WKWebViewPrivate.h>
#import <WebKit/WKWebsiteDataStorePrivate.h>
#import <WebKit/_WKFeature.h>
#import <WebKit/_WKWebsiteDataStoreConfiguration.h>
#import <WebKit/_WKWebsiteDataStoreDelegate.h>
#import <cstdio>
#import <cstdlib>
#import <wtf/HashMap.h>
#import <wtf/MonotonicTime.h>
#import <wtf/RetainPtr.h>
#import <wtf/StdLibExtras.h>
#import <wtf/text/MakeString.h>
#import <wtf/text/StringToIntegerConversion.h>

// Measures the network process's origin storage (Cache Storage, the origin private file system, Background Fetch's store
// and the quota manager) through the web platform APIs: a page served from a local HTTP server runs each shape's
// calls against a persistent data store in a temporary directory, and returns a digest of what it observed.
// Each test runs one pass and checks the digest; with WEBKIT_RUN_BENCHMARKS=1 it runs the pass repeatedly and prints
// the time of the storage calls (as the page measured them: setup, clearing and hashing are outside it) and the
// megabytes the pass moves per second. Shapes marked "relaunch" run each pass in a new network process, so the
// pass reads what the previous one stored from disk.

@interface OriginStorageBenchDelegate : NSObject <_WKWebsiteDataStoreDelegate>
@end

@implementation OriginStorageBenchDelegate
- (void)requestBackgroundFetchPermission:(NSURL *)mainFrameURL frameOrigin:(NSURL *)frameURL decisionHandler:(void (^)(bool isGranted))decisionHandler
{
    decisionHandler(true);
}

- (void)requestStorageSpace:(NSURL *)mainFrameURL frameOrigin:(NSURL *)frameURL quota:(NSUInteger)quota currentSize:(NSUInteger)currentSize spaceRequired:(NSUInteger)spaceRequired decisionHandler:(void (^)(unsigned long long quota))decisionHandler
{
    decisionHandler(quota);
}
@end

namespace TestWebKitAPI {

using namespace OriginStorageBenchInputs;

namespace OriginStorageBench {

struct Shape {
    ASCIILiteral name;
    unsigned iterations; // passes in the timed run, chosen so that a shape runs for about a second
    uint64_t expectedChecksum;
    bool relaunch { false };
    bool backgroundFetch { false };
    NSUInteger perOriginStorageQuota { 0 };
    bool fixedQuota { false }; // no volume-based quota, so a write past it asks the delegate for more space, which refuses
};

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && std::string(value) != "0";
}

static RetainPtr<NSURL> createTemporaryDirectory()
{
    RetainPtr directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory.get() withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

static HTTPServer::ResponseMap pageResponses()
{
    HTTPServer::ResponseMap responses;
    responses.add("/"_s, HTTPResponse(makeString("<!DOCTYPE html><script>"_s, pageScript, "</script>"_s)));
    responses.add("/sw.js"_s, HTTPResponse(Vector<WTF::KeyValuePair<String, String>> { { "Content-Type"_s, "text/javascript"_s } }, String { serviceWorkerScript }));
    responses.add("/worker.js"_s, HTTPResponse(Vector<WTF::KeyValuePair<String, String>> { { "Content-Type"_s, "text/javascript"_s } }, String { workerScript }));
    for (unsigned i = 0; i < 4; ++i)
        responses.add(makeString("/bf/"_s, i), HTTPResponse(Vector<WTF::KeyValuePair<String, String>> { { "Content-Type"_s, "text/plain"_s } }, makeString(backgroundFetchBody, " #"_s, i)));
    return responses;
}

// A persistent data store with every directory under a temporary one, the server that gives the page a secure origin,
// and the page's web view; relaunch() replaces the network process and the web view.
class Fixture {
public:
    explicit Fixture(const Shape& shape)
        : m_server(pageResponses())
        , m_directory(createTemporaryDirectory())
    {
        RetainPtr storeConfiguration = adoptNS([[_WKWebsiteDataStoreConfiguration alloc] initWithDirectory:m_directory.get()]);
        if (shape.perOriginStorageQuota)
            [storeConfiguration setPerOriginStorageQuota:shape.perOriginStorageQuota];
        if (shape.fixedQuota) {
            [storeConfiguration setTotalQuotaRatio:nil];
            [storeConfiguration setOriginQuotaRatio:nil];
        }
        m_dataStore = adoptNS([[WKWebsiteDataStore alloc] _initWithConfiguration:storeConfiguration.get()]);
        [m_dataStore _setResourceLoadStatisticsEnabled:NO];
        m_delegate = adoptNS([[OriginStorageBenchDelegate alloc] init]);
        m_dataStore.get()._delegate = m_delegate.get();

        m_configuration = adoptNS([[WKWebViewConfiguration alloc] init]);
        [m_configuration setWebsiteDataStore:m_dataStore.get()];
        auto preferences = [m_configuration preferences];
        preferences._fileSystemAccessEnabled = YES;
        preferences._accessHandleEnabled = YES;
        preferences._storageAPIEnabled = YES;
        if (shape.backgroundFetch) {
            for (_WKFeature *feature in [WKPreferences _features]) {
                if ([feature.key isEqualToString:@"BackgroundFetchAPIEnabled"])
                    [preferences _setEnabled:YES forFeature:feature];
            }
        }
        openPage();
    }

    ~Fixture()
    {
        m_webView = nil;
        m_dataStore = nil;
        [[NSFileManager defaultManager] removeItemAtURL:m_directory.get() error:nil];
    }

    void relaunch()
    {
        m_webView = nil;
        [m_dataStore _terminateNetworkProcess];
        openPage();
    }

    void reopen() { openPage(); }
    TestWKWebView *webView() const { return m_webView.get(); }
    WKWebsiteDataStore *dataStore() const { return m_dataStore.get(); }

    // The page's reply to `bench.<call>`: { ms, bytes, checksum, note }, or nil with the error printed.
    NSDictionary *call(NSString *script, NSDictionary *arguments)
    {
        NSError *error = nil;
        id result = [m_webView objectByCallingAsyncFunction:script withArguments:arguments error:&error];
        EXPECT_NULL(error);
        if (error)
            SAFE_PRINTF("script failed: %s\n", String { error.userInfo[@"WKJavaScriptExceptionMessage"] ?: error.localizedDescription }.utf8());
        return [result isKindOfClass:NSDictionary.class] ? (NSDictionary *)result : nil;
    }

private:
    void openPage()
    {
        m_webView = adoptNS([[TestWKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:m_configuration.get()]);
        [m_webView synchronouslyLoadRequest:m_server.request()];
    }

    HTTPServer m_server;
    RetainPtr<NSURL> m_directory;
    RetainPtr<WKWebsiteDataStore> m_dataStore;
    RetainPtr<OriginStorageBenchDelegate> m_delegate;
    RetainPtr<WKWebViewConfiguration> m_configuration;
    RetainPtr<TestWKWebView> m_webView;
};

static void runPass(Fixture& fixture, const Shape& shape, unsigned pass, bool relaunch, double* milliseconds, double* bytes, String* checksum)
{
    if (relaunch)
        fixture.relaunch();
    NSDictionary *reply = fixture.call(@"return await bench.run(name, pass)", @{ @"name": @(shape.name.characters()), @"pass": @(pass) });
    EXPECT_NOT_NULL(reply);
    if (!reply)
        return;
    *milliseconds += [reply[@"ms"] doubleValue];
    *bytes += [reply[@"bytes"] doubleValue];
    if (checksum)
        *checksum = String { (NSString *)reply[@"checksum"] };
    if (NSString *note = reply[@"note"])
        SAFE_PRINTF("%s note: %s\n", shape.name, String { note }.utf8());
}

static void runShape(const Shape& shape)
{
    Fixture fixture(shape);
    EXPECT_NOT_NULL(fixture.call(@"await bench.setup(name); return { ok: true }", @{ @"name": @(shape.name.characters()) }));

    double firstMilliseconds = 0;
    double firstBytes = 0;
    String checksum;
    runPass(fixture, shape, 0, shape.relaunch, &firstMilliseconds, &firstBytes, &checksum);
    uint64_t digest = parseInteger<uint64_t>(checksum, 16).value_or(0);
    if (shape.expectedChecksum)
        EXPECT_EQ(digest, shape.expectedChecksum);

    double milliseconds = firstMilliseconds;
    double bytes = firstBytes;
    if (runsBenchmarks()) {
        milliseconds = 0;
        bytes = 0;
        for (unsigned i = 0; i < shape.iterations; ++i)
            runPass(fixture, shape, i + 1, shape.relaunch, &milliseconds, &bytes, nullptr);
    }
    SAFE_PRINTF("%s: %.1f ms %.3f MB/s checksum=%s\n", shape.name, milliseconds, milliseconds ? bytes / (milliseconds * 1000) : 0.0, checksum.utf8());
    fflush(stdout);
}

} // namespace OriginStorageBench

using namespace OriginStorageBench;

// The process start-up cost alone: the same process start and exit, no shape.
TEST(OriginStorageBench, StartUp)
{
}

TEST(OriginStorageBench, CachePut100Vary)
{
    runShape({ "CachePut100Vary"_s, 60, 0xd130d57a9b26f145 });
}

TEST(OriginStorageBench, CachePut10000Vary)
{
    runShape({ "CachePut10000Vary"_s, 1, 0x767700e83a474339 });
}

TEST(OriginStorageBench, CacheMatch100Vary)
{
    runShape({ "CacheMatch100Vary"_s, 100, 0xab60047463eb0b73 });
}

TEST(OriginStorageBench, CacheMatch10000Vary)
{
    runShape({ "CacheMatch10000Vary"_s, 2, 0x1eeefbe632168f7b });
}

TEST(OriginStorageBench, CacheOpen1000)
{
    runShape({ "CacheOpen1000"_s, 8, 0x4a11f4de0db5701b, true });
}

TEST(OriginStorageBench, CacheRecordDecode1000)
{
    runShape({ "CacheRecordDecode1000"_s, 14, 0xca3a77dcde3e4d89, true });
}

TEST(OriginStorageBench, CacheMatchAll1000)
{
    runShape({ "CacheMatchAll1000"_s, 20, 0x7bfde805f5368a04 });
}

TEST(OriginStorageBench, CacheReplaceDelete)
{
    runShape({ "CacheReplaceDelete"_s, 6, 0xf9423d5192b28400 });
}

TEST(OriginStorageBench, CacheManagerOps)
{
    runShape({ "CacheManagerOps"_s, 2, 0x43c818a1585f4bfa });
}

TEST(OriginStorageBench, OpfsWrite1MB)
{
    runShape({ "OpfsWrite1MB"_s, 10, 0xd33f45e606e52ffd });
}

TEST(OriginStorageBench, OpfsWrite64MB)
{
    runShape({ "OpfsWrite64MB"_s, 20, 0x8dedbd43e56e94f0 });
}

TEST(OriginStorageBench, OpfsWritableSmallOps)
{
    runShape({ "OpfsWritableSmallOps"_s, 4, 0x7d0dc119f3c0ece6 });
}

TEST(OriginStorageBench, OpfsGetHandleNames1000)
{
    runShape({ "OpfsGetHandleNames1000"_s, 1, 0x88c49a9d04688c16 });
}

TEST(OriginStorageBench, OpfsMove)
{
    runShape({ "OpfsMove"_s, 2, 0x17c960be7da9c407 });
}

TEST(OriginStorageBench, OpfsErrorPaths)
{
    runShape({ "OpfsErrorPaths"_s, 8, 0xfe500cb91c9e7eac });
}

TEST(OriginStorageBench, OpfsTreeOps)
{
    runShape({ "OpfsTreeOps"_s, 15, 0xea6cf676abf46fbf });
}

TEST(OriginStorageBench, OpfsSyncAccessHandle)
{
    runShape({ "OpfsSyncAccessHandle"_s, 25, 0x4a2923b6a3829259 });
}

TEST(OriginStorageBench, StorageQuotaEstimate)
{
    runShape({ "StorageQuotaEstimate"_s, 28, 0xab0d8e02ca824ba3 });
}

// Writes past a per-origin quota of 4 MB: the refusals are the shape.
TEST(OriginStorageBench, StorageQuotaExceeded)
{
    runShape({ "StorageQuotaExceeded"_s, 15, 0xb85f48354645ed76, false, false, 4 << 20 });
}

// Three thousand Cache Storage puts at once against a per-origin quota of 64 KB: the requests queue in the quota manager.
TEST(OriginStorageBench, StorageQuotaQueued)
{
    runShape({ "StorageQuotaQueued"_s, 2, 0x9befc63a6e7588f5, false, false, 64 << 10, true });
}

// Background Fetch's store: fetches stored, listed and read back through a service worker registration.
TEST(OriginStorageBench, BackgroundFetchStore)
{
    runShape({ "BackgroundFetchStore"_s, 30, 0xbb73d6cadf0e28cd, false, true });
}

// getFile's main-thread hop against a move or remove of the entry, and against the web process closing.
// The awaited order is checked; the order that is not awaited is not forced, so its outcomes are counted and printed.
namespace OriginStorageOrderings {

static NSString *const setUpFile = @"const root = await navigator.storage.getDirectory();"
    "for (const name of ['n', 'moved']) { try { await root.removeEntry(name); } catch (e) { } }"
    "const h = await root.getFileHandle('n', { create: true }); const w = await h.createWritable(); await w.write('abc'); await w.close();"
    "window.root = root; window.h = h; return { outcome: 'ready' }";

static NSString *const readFile = @"async function read(f) { try { return f.name + ':' + await f.text(); } catch (e) { return f.name + ':' + e.name; } }"
    "async function present(name) { try { await root.getFileHandle(name); return 'present'; } catch (e) { return e.name; } }";

static String field(NSDictionary *reply, NSString *key)
{
    id value = reply[key];
    return [value isKindOfClass:NSString.class] ? String { (NSString *)value } : String { "nil"_s };
}

static void printTally(ASCIILiteral name, const HashMap<String, unsigned>& tally)
{
    auto keys = copyToVector(tally.keys());
    std::ranges::sort(keys, codePointCompareLessThan);
    for (auto& key : keys)
        SAFE_PRINTF("%s outcome=%s count=%u\n", name, key.utf8(), tally.get(key));
    fflush(stdout);
}

static void runFileOrder(ASCIILiteral name, NSString *body, ASCIILiteral expectedAfter)
{
    Fixture fixture({ "orderings"_s, 1, 0 });
    HashMap<String, unsigned> tally;
    for (unsigned i = 0; i < 20; ++i) {
        EXPECT_WK_STREQ("ready", field(fixture.call(setUpFile, nil), @"outcome"));
        NSDictionary *reply = fixture.call([readFile stringByAppendingString:body], nil);
        EXPECT_WK_STREQ(expectedAfter, field(reply, @"after"));
        tally.add(field(reply, @"outcome"), 0).iterator->value++;
    }
    printTally(name, tally);
}

static void runCloseOrder(ASCIILiteral name, NSString *body, bool kill)
{
    Fixture fixture({ "orderings"_s, 1, 0 });
    pid_t networkProcess = [fixture.dataStore() _networkProcessIdentifier];
    EXPECT_NE(networkProcess, 0);
    HashMap<String, unsigned> tally;
    for (unsigned i = 0; i < 10; ++i) {
        EXPECT_WK_STREQ("ready", field(fixture.call(setUpFile, nil), @"outcome"));
        tally.add(field(fixture.call([readFile stringByAppendingString:body], nil), @"outcome"), 0).iterator->value++;
        if (kill)
            [fixture.webView() _killWebContentProcess];
        else
            [fixture.webView() _close];
        fixture.reopen();
        NSDictionary *reply = fixture.call([readFile stringByAppendingString:@"const root = await navigator.storage.getDirectory(); return { after: await read(await (await root.getFileHandle('n')).getFile()) }"], nil);
        EXPECT_WK_STREQ("n:abc", field(reply, @"after"));
        EXPECT_EQ(networkProcess, [fixture.dataStore() _networkProcessIdentifier]);
    }
    printTally(name, tally);
}

} // namespace OriginStorageOrderings

using namespace OriginStorageOrderings;

TEST(OriginStorageOrderings, GetFileThenMove)
{
    runFileOrder("GetFileThenMove"_s, @"const f = await h.getFile(); await h.move(root, 'moved'); return { outcome: await read(f), after: await read(await h.getFile()) }", "moved:abc"_s);
}

TEST(OriginStorageOrderings, GetFileMoveNotAwaited)
{
    runFileOrder("GetFileMoveNotAwaited"_s, @"const p = h.getFile(); const m = h.move(root, 'moved'); let outcome; try { outcome = await read(await p); } catch (e) { outcome = 'getFile:' + e.name; } await m; return { outcome, after: await read(await h.getFile()) }", "moved:abc"_s);
}

TEST(OriginStorageOrderings, GetFileThenRemove)
{
    runFileOrder("GetFileThenRemove"_s, @"const f = await h.getFile(); await root.removeEntry('n'); return { outcome: await read(f), after: await present('n') }", "NotFoundError"_s);
}

TEST(OriginStorageOrderings, GetFileRemoveNotAwaited)
{
    runFileOrder("GetFileRemoveNotAwaited"_s, @"const p = h.getFile(); const r = root.removeEntry('n'); let outcome; try { outcome = await read(await p); } catch (e) { outcome = 'getFile:' + e.name; } await r; return { outcome, after: await present('n') }", "NotFoundError"_s);
}

TEST(OriginStorageOrderings, GetFileThenKill)
{
    runCloseOrder("GetFileThenKill"_s, @"return { outcome: await read(await h.getFile()) }", true);
}

TEST(OriginStorageOrderings, GetFileKillNotAwaited)
{
    runCloseOrder("GetFileKillNotAwaited"_s, @"window.pending = h.getFile(); return { outcome: 'sent' }", true);
}

TEST(OriginStorageOrderings, GetFileThenClose)
{
    runCloseOrder("GetFileThenClose"_s, @"return { outcome: await read(await h.getFile()) }", false);
}

TEST(OriginStorageOrderings, GetFileCloseNotAwaited)
{
    runCloseOrder("GetFileCloseNotAwaited"_s, @"window.pending = h.getFile(); return { outcome: 'sent' }", false);
}

} // namespace TestWebKitAPI
