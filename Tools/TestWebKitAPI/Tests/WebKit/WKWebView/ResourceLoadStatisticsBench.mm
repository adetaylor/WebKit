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
#import "Helpers/cocoa/TestNavigationDelegate.h"
#import "Helpers/cocoa/TestUIDelegate.h"
#import "Helpers/cocoa/TestWKWebView.h"
#import "Helpers/cocoa/WKWebViewConfigurationExtras.h"
#import "ResourceLoadStatisticsBenchInputs.h"
#import <WebKit/WKArray.h>
#import <WebKit/WKPreferencesPrivate.h>
#import <WebKit/WKRetainPtr.h>
#import <WebKit/WKString.h>
#import <WebKit/WKWebViewPrivate.h>
#import <WebKit/WKWebsiteDataRecordPrivate.h>
#import <WebKit/WKWebsiteDataStorePrivate.h>
#import <WebKit/WKWebsiteDataStoreRef.h>
#import <WebKit/_WKFeature.h>
#import <WebKit/_WKResourceLoadStatisticsFirstParty.h>
#import <WebKit/_WKResourceLoadStatisticsThirdParty.h>
#import <WebKit/_WKWebsiteDataStoreConfiguration.h>
#import <algorithm>
#import <cstdio>
#import <cstdlib>
#import <libproc.h>
#import <mach/mach_time.h>
#import <string>
#import <vector>
#import <wtf/MonotonicTime.h>
#import <wtf/RetainPtr.h>
#import <wtf/URL.h>
#import <wtf/WallTime.h>

// Measures the network process's statistics store through the data store's testing entry points, and checks a digest of its dump.
// Each test runs one pass; with WEBKIT_RUN_BENCHMARKS=1 it runs the pass repeatedly and prints the wall-clock time and
// store calls per millisecond (in the MB/s slot) for the whole round trip. The page shapes time their one pass.

namespace TestWebKitAPI::ResourceLoadStatisticsBench {

using namespace ResourceLoadStatisticsBenchInputs;

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
    void add(const std::string& string)
    {
        add(string.size());
        for (unsigned char byte : string)
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

// URL spelling of the nth domain, as the testing entry points take them ("https://site12.co.uk/").
static std::string domainURL(unsigned n)
{
    return "https://site" + std::to_string(n) + "." + suffixes[n % suffixes.size()] + "/";
}

// Host spelling of the nth domain, as removeITPDataForDomain takes it ("site12.co.uk").
static std::string domainHost(unsigned n)
{
    return "site" + std::to_string(n) + "." + suffixes[n % suffixes.size()];
}

static std::string topFrameURL(unsigned n)
{
    return "https://top" + std::to_string(n) + ".example/";
}

static WKRetainPtr<WKStringRef> wkString(const std::string& string)
{
    return adoptWK(WKStringCreateWithUTF8CString(string.c_str()));
}

// RLS_BENCH_DUMP_DIR=<directory> writes each dump a checksum hashes there; RLS_BENCH_TIME_SHIFT=<seconds> moves the clock.
static double timeShiftSeconds()
{
    auto* value = getenv("RLS_BENCH_TIME_SHIFT");
    return value && *value ? strtod(value, nullptr) : 0;
}

static ASCIILiteral currentShape = ""_s;

static void saveDump(const std::string& dump)
{
    static unsigned dumpsSaved;
    auto* directory = getenv("RLS_BENCH_DUMP_DIR");
    if (!directory || !*directory)
        return;
    auto path = std::string(directory) + "/" + currentShape.characters() + "-" + std::to_string(dumpsSaved++) + ".txt";
    if (auto* file = fopen(path.c_str(), "w")) {
        fwrite(dump.data(), 1, dump.size(), file);
        fclose(file);
    }
}

// Counts completions; wait() runs the main run loop until every call issued has completed.
static uint64_t callCount; // store calls issued; the rate a shape prints is thousands of them per millisecond

struct Pending {
    unsigned outstanding { 0 };
    void* context() { ++outstanding; ++callCount; return this; }
    static void done(void* context) { --static_cast<Pending*>(context)->outstanding; }
    static void doneBool(bool, void* context) { done(context); }
    void wait() { Util::waitFor([&] { return !outstanding; }, 1000000); }
};

// One query's answer, written by its completion wherever it lands in the order of completions; 2 until it answers.
struct Answer {
    Pending* pending { nullptr };
    uint8_t value { 2 };

    void* context(Pending& owner)
    {
        pending = &owner;
        owner.context();
        return this;
    }
    static void received(bool value, void* context)
    {
        auto& answer = *static_cast<Answer*>(context);
        answer.value = value;
        Pending::done(answer.pending);
    }
};

static void addAnswers(Checksum* checksum, const std::vector<Answer>& answers)
{
    if (!checksum)
        return;
    for (auto& answer : answers)
        checksum->add(static_cast<uint64_t>(answer.value));
}

static std::string toStdString(WKStringRef string)
{
    size_t size = WKStringGetMaximumUTF8CStringSize(string);
    std::string buffer(size, '\0');
    buffer.resize(WKStringGetUTF8CString(string, buffer.data(), size) - 1);
    return buffer;
}

static RetainPtr<NSURL> domainNSURL(unsigned n)
{
    return [NSURL URLWithString:@(domainURL(n).c_str())];
}

enum class Persistence : bool { Persistent, Ephemeral };

// A data store with every directory under <directory>, so that website data other tests left cannot change the dump.
static RetainPtr<_WKWebsiteDataStoreConfiguration> isolatedStoreConfiguration(NSURL *directory)
{
    RetainPtr configuration = adoptNS([[_WKWebsiteDataStoreConfiguration alloc] initWithDirectory:directory]);
    [configuration _setResourceLoadStatisticsDirectory:directory];
    return configuration;
}

static RetainPtr<NSURL> createTemporaryDirectory()
{
    RetainPtr directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory.get() withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

// One persistent data store in its own temporary directory, with ITP on and test mode set, as an empty database.
class Fixture {
public:
    explicit Fixture(Persistence persistence = Persistence::Persistent)
    {
        if (persistence == Persistence::Persistent) {
            m_directory = createTemporaryDirectory();
            auto configuration = isolatedStoreConfiguration(m_directory.get());
            m_store = adoptNS([[WKWebsiteDataStore alloc] _initWithConfiguration:configuration.get()]);
        } else {
            RetainPtr configuration = adoptNS([[_WKWebsiteDataStoreConfiguration alloc] initNonPersistentConfiguration]);
            m_store = adoptNS([[WKWebsiteDataStore alloc] _initWithConfiguration:configuration.get()]);
        }
        [m_store _setResourceLoadStatisticsEnabled:YES];
        clear();
        Pending pending;
        WKWebsiteDataStoreSetStatisticsIsRunningTest(ref(), true, pending.context(), Pending::done);
        pending.wait();
        // An ephemeral session's store has no database: moving its clock is a RELEASE_ASSERT in the network process.
        if (persistence == Persistence::Persistent)
            advanceTime(0);
    }

    ~Fixture()
    {
        if (m_directory)
            [[NSFileManager defaultManager] removeItemAtURL:m_directory.get() error:nil];
    }

    WKWebsiteDataStore *store() { return m_store.get(); }
    pid_t networkProcessIdentifier() { return [m_store _networkProcessIdentifier]; }
    WKWebsiteDataStoreRef ref() { return (WKWebsiteDataStoreRef)m_store.get(); }

    void clear()
    {
        Pending pending;
        WKWebsiteDataStoreStatisticsClearInMemoryAndPersistentStore(ref(), pending.context(), Pending::done);
        pending.wait();
    }

    std::string dump()
    {
        ++callCount; // a store call like any other, so DumpStatistics has a rate
        std::string result;
        bool finished = false;
        struct Context {
            std::string* result;
            bool* finished;
        };
        Context context { &result, &finished };
        WKWebsiteDataStoreDumpResourceLoadStatistics(ref(), &context, [](WKStringRef string, void* contextPointer) {
            auto& context = *static_cast<Context*>(contextPointer);
            size_t size = WKStringGetMaximumUTF8CStringSize(string);
            std::string buffer(size, '\0');
            buffer.resize(WKStringGetUTF8CString(string, buffer.data(), size) - 1);
            *context.result = WTF::move(buffer);
            *context.finished = true;
        });
        Util::run(&finished);
        return result;
    }

    // domain n's statistic: seen under two top frames, some with interaction, some prevalent, some grandfathered.
    void merge(Pending& pending, unsigned n, unsigned pass, double now)
    {
        bool interaction = !(n % 7);
        bool prevalent = !(n % prevalentSeedEvery);
        auto host = wkString(domainURL(n));
        auto top1 = wkString(topFrameURL(n % topFrameDomains));
        auto top2 = wkString(topFrameURL((n + pass + 1) % topFrameDomains));
        WKWebsiteDataStoreSetStatisticsMergeStatistic(ref(), host.get(), top1.get(), top2.get(), now - recentAgeSeconds - n, interaction, interaction ? now - recentAgeSeconds : 0, !(n % 5), prevalent, prevalent && !(n % 3), n % 4, pending.context(), Pending::done);
    }

    void populate(unsigned count, unsigned pass = 0)
    {
        double now = WallTime::now().secondsSinceEpoch().seconds() + timeShiftSeconds();
        Pending pending;
        for (unsigned n = 0; n < count; ++n) {
            merge(pending, n, pass, now);
            if (pending.outstanding >= mergeBatchSize)
                pending.wait();
        }
        pending.wait();
    }

    // The relations a browsing session records and the classifier follows: redirects, subresources, subframes.
    void addRelations(unsigned count, unsigned passSeed)
    {
        Generator generator { passSeed };
        auto issue = [&](Pending& pending, auto&& call) {
            call();
            if (pending.outstanding >= mergeBatchSize)
                pending.wait();
        };
        Pending pending;
        for (unsigned n = 0; n < count; ++n) {
            auto host = wkString(domainURL(n));
            for (unsigned edge = 0; edge < redirectFanout; ++edge) {
                auto other = wkString(domainURL(generator.below(count)));
                auto top = wkString(topFrameURL(generator.below(topFrameDomains)));
                callCount += 5;
                WKWebsiteDataStoreSetStatisticsSubresourceUniqueRedirectTo(ref(), host.get(), other.get());
                WKWebsiteDataStoreSetStatisticsSubresourceUniqueRedirectFrom(ref(), other.get(), host.get());
                WKWebsiteDataStoreSetStatisticsTopFrameUniqueRedirectTo(ref(), host.get(), other.get());
                WKWebsiteDataStoreSetStatisticsSubresourceUnderTopFrameOrigin(ref(), host.get(), top.get());
                WKWebsiteDataStoreSetStatisticsSubframeUnderTopFrameOrigin(ref(), other.get(), top.get());
            }
            // These entry points have no completion; the batch ends on one that has, which the queue runs after them.
            if (!(n % mergeBatchSize))
                issue(pending, [&] { WKWebsiteDataStoreSetStatisticsHasHadUserInteraction(ref(), host.get(), true, pending.context(), [](void* c) { Pending::done(c); }); });
        }
        pending.wait();
        sync();
    }

    // A call that completes on the store's queue: everything posted before it has run.
    void sync()
    {
        Pending pending;
        WKWebsiteDataStoreStatisticsUpdateCookieBlocking(ref(), pending.context(), Pending::done);
        pending.wait();
    }

    void processStatisticsAndDataRecords()
    {
        Pending pending;
        WKWebsiteDataStoreStatisticsProcessStatisticsAndDataRecords(ref(), pending.context(), Pending::done);
        pending.wait();
    }

    void advanceTime(double seconds)
    {
        Pending pending;
        WKWebsiteDataStoreSetResourceLoadStatisticsTimeAdvanceForTesting(ref(), timeShiftSeconds() + seconds, pending.context(), Pending::done);
        pending.wait();
    }

private:
    RetainPtr<NSURL> m_directory;
    RetainPtr<WKWebsiteDataStore> m_store;
};

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && std::string(value) != "0";
}

// CPU time (user + system, ms) a process has used, 0 when it cannot be read. The store runs in the network process, so a
// shape prints that process's CPU time beside its wall time.
static double cpuMilliseconds(pid_t pid)
{
    struct rusage_info_v4 info { };
    if (pid <= 0 || proc_pid_rusage(pid, RUSAGE_INFO_V4, reinterpret_cast<rusage_info_t*>(&info)))
        return 0;
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom)
        mach_timebase_info(&timebase);
    return static_cast<double>(info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom / 1e6;
}

// The network process's memory after a shape, in KB, printed in the MB/s slot so the benchmark script collects it
// as a shape of its own: "MemFootprint<Shape>" is phys_footprint now, "MemPeak<Shape>" the process's lifetime maximum.
static void printNetworkFootprint(ASCIILiteral name, pid_t pid)
{
    struct rusage_info_v4 info { };
    if (pid <= 0 || proc_pid_rusage(pid, RUSAGE_INFO_V4, reinterpret_cast<rusage_info_t*>(&info)))
        return;
    SAFE_PRINTF("MemFootprint%s: %llu MB/s\n", name, static_cast<unsigned long long>(info.ri_phys_footprint / 1024));
    SAFE_PRINTF("MemPeak%s: %llu MB/s\n", name, static_cast<unsigned long long>(info.ri_lifetime_max_phys_footprint / 1024));
    fflush(stdout);
}

// A shape is a function from a fixture to the digest of what the store ended up holding. It owns the whole pass,
// including clearing the database, so a repeated pass starts where the first one did.
template<typename Pass>
static void runBenchmark(ASCIILiteral name, unsigned iterations, uint64_t expectedChecksum, Pass&& pass, Persistence persistence = Persistence::Persistent)
{
    currentShape = name;
    Fixture fixture { persistence };
    Checksum checksum;
    auto firstStart = MonotonicTime::now();
    pass(fixture, &checksum);
    double firstMilliseconds = (MonotonicTime::now() - firstStart).seconds() * 1000;
    // The first build records the value; until then expectedChecksum is 0 and the test only prints it.
    if (expectedChecksum)
        EXPECT_EQ(checksum.value(), expectedChecksum) << name.characters();
    if (!runsBenchmarks()) {
        SAFE_PRINTF("%s: first pass %.1f ms checksum=%016llx\n", name, firstMilliseconds, static_cast<unsigned long long>(checksum.value()));
        fflush(stdout);
        return;
    }

    pid_t networkPID = fixture.networkProcessIdentifier();
    double networkBefore = cpuMilliseconds(networkPID);
    double uiBefore = cpuMilliseconds(getpid());
    uint64_t callsBefore = callCount;
    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i)
        pass(fixture, nullptr);
    double seconds = (MonotonicTime::now() - start).seconds();
    double calls = static_cast<double>(callCount - callsBefore);
    SAFE_PRINTF("%s: %.1f ms %.6f MB/s network_cpu_ms=%.1f ui_cpu_ms=%.1f checksum=%016llx\n", name, seconds * 1000, calls / (seconds * 1000), cpuMilliseconds(networkPID) - networkBefore, cpuMilliseconds(getpid()) - uiBefore, static_cast<unsigned long long>(checksum.value()));
    fflush(stdout);
    printNetworkFootprint(name, networkPID);
}

static void digestDump(Fixture& fixture, Checksum* checksum)
{
    auto dump = fixture.dump();
    if (checksum) {
        saveDump(dump);
        checksum->add(dump);
    }
}

// Statistics merge and update batches: the whole database merged, then merged again with changed top frames.
static void mergeBatches(Fixture& fixture, Checksum* checksum)
{
    fixture.clear();
    for (unsigned pass = 0; pass < mergePasses; ++pass)
        fixture.populate(databaseDomains, pass);
    digestDump(fixture, checksum);
}

// Relation updates: the redirect and subresource edges a page load logs, and user-interaction flips.
static void updateBatches(Fixture& fixture, Checksum* checksum)
{
    fixture.clear();
    fixture.populate(databaseDomains);
    for (unsigned pass = 0; pass < updatePasses; ++pass)
        fixture.addRelations(databaseDomains, 0x5eed + pass);
    digestDump(fixture, checksum);
}

// The classification pass: processStatisticsAndDataRecords with classification on (markAsPrevalentIfHasRedirectedToPrevalent,
// reclassifyResources) over the database, repeated as time advances so each pass finds new domains to classify.
static void classificationPass(Fixture& fixture, Checksum* checksum)
{
    fixture.clear();
    WKWebsiteDataStoreSetStatisticsShouldClassifyResourcesBeforeDataRecordsRemoval(fixture.ref(), true);
    fixture.populate(databaseDomains);
    fixture.addRelations(databaseDomains, 0xc1a55);
    for (unsigned pass = 0; pass < classificationPasses; ++pass) {
        fixture.advanceTime(pass * 3600.0);
        fixture.processStatisticsAndDataRecords();
        if (checksum)
            digestDump(fixture, checksum);
    }
    digestDump(fixture, checksum);
}

// registrableDomainsToDeleteOrRestrictWebsiteDataFor: aged statistics (expired interaction, grandfathering over,
// prevalent without interaction) so each pass computes and applies the delete / restrict lists.
static void deleteOrRestrict(Fixture& fixture, Checksum* checksum)
{
    fixture.clear();
    Pending pending;
    WKWebsiteDataStoreSetStatisticsGrandfatheringTime(fixture.ref(), 1);
    for (unsigned n = 0; n < databaseDomains; ++n) {
        auto host = wkString(domainURL(n));
        WKWebsiteDataStoreSetStatisticsExpiredStatistic(fixture.ref(), host.get(), 1 + n % 40, !(n % 4), !(n % 6), !(n % 3), pending.context(), Pending::done);
        if (pending.outstanding >= mergeBatchSize)
            pending.wait();
    }
    pending.wait();
    for (unsigned pass = 0; pass < deletePasses; ++pass) {
        fixture.advanceTime(pass * 7 * 24 * 3600.0);
        fixture.processStatisticsAndDataRecords();
        if (checksum)
            digestDump(fixture, checksum);
    }
    digestDump(fixture, checksum);
}

// dumpResourceLoadStatistics over the populated database: the per-domain statements and the sorted text.
static void dumpStatistics(Fixture& fixture, Checksum* checksum)
{
    static bool populated = false;
    if (!populated) {
        fixture.clear();
        fixture.populate(databaseDomains);
        fixture.addRelations(databaseDomains, 0xd0a9);
        populated = true;
    }
    for (unsigned pass = 0; pass < dumpPasses; ++pass) {
        auto dump = fixture.dump();
        if (checksum && !pass) {
            saveDump(dump);
            checksum->add(dump);
        }
    }
}

// Cookie blocking: the store's decision about which domains block cookies, with storage access grants recorded,
// pushed to the network storage session (updateCookieBlocking -> domainsToBlock...).
static void cookieBlockingUpdate(Fixture& fixture, Checksum* checksum)
{
    fixture.clear();
    fixture.populate(databaseDomains);
    fixture.addRelations(databaseDomains, 0xc00c1e);
    for (unsigned pass = 0; pass < classificationPasses; ++pass) {
        Pending pending;
        for (unsigned n = pass; n < databaseDomains; n += 13) {
            auto host = wkString(domainURL(n));
            WKWebsiteDataStoreSetStatisticsPrevalentResource(fixture.ref(), host.get(), !!((n + pass) % 2), pending.context(), Pending::done);
            if (pending.outstanding >= mergeBatchSize)
                pending.wait();
        }
        pending.wait();
        fixture.sync();
    }
    digestDump(fixture, checksum);
}

// The queries the testing entry points send (isPrevalentResource, isVeryPrevalentResource, isGrandfathered,
// hadUserInteraction, isRegisteredAsSubresourceUnder, isRegisteredAsSubFrameUnder, isRegisteredAsRedirectingTo,
// isRelationshipOnlyInDatabaseOnce, domainIDExistsInDatabase), every tenth naming a domain the store has never seen,
// except isRelationshipOnlyInDatabaseOnce, which traps in the network process on an unseen domain, and so names a seen one.
static void statisticsQueries(Fixture& fixture, Checksum* checksum)
{
    constexpr unsigned queriesPerDomain = 9;
    static bool populated = false;
    if (!populated) {
        fixture.clear();
        fixture.populate(databaseDomains);
        fixture.addRelations(databaseDomains, 0x9e41e5);
        populated = true;
    }
    for (unsigned pass = 0; pass < queryPasses; ++pass) {
        std::vector<Answer> answers(databaseDomains * queriesPerDomain + 1);
        Pending pending;
        WKWebsiteDataStoreIsStatisticsEphemeral(fixture.ref(), answers.back().context(pending), Answer::received);
        for (unsigned n = 0; n < databaseDomains; ++n) {
            unsigned subject = !(n % unknownDomainEvery) ? databaseDomains + n : n;
            auto host = wkString(domainURL(subject));
            auto top = wkString(topFrameURL(n % topFrameDomains));
            auto other = wkString(domainURL((n + 1) % databaseDomains));
            auto* answer = &answers[n * queriesPerDomain];
            WKWebsiteDataStoreIsStatisticsPrevalentResource(fixture.ref(), host.get(), answer[0].context(pending), Answer::received);
            WKWebsiteDataStoreIsStatisticsVeryPrevalentResource(fixture.ref(), host.get(), answer[1].context(pending), Answer::received);
            WKWebsiteDataStoreIsStatisticsGrandfathered(fixture.ref(), host.get(), answer[2].context(pending), Answer::received);
            WKWebsiteDataStoreIsStatisticsHasHadUserInteraction(fixture.ref(), host.get(), answer[3].context(pending), Answer::received);
            WKWebsiteDataStoreIsStatisticsRegisteredAsSubresourceUnder(fixture.ref(), host.get(), top.get(), answer[4].context(pending), Answer::received);
            WKWebsiteDataStoreIsStatisticsRegisteredAsSubFrameUnder(fixture.ref(), host.get(), top.get(), answer[5].context(pending), Answer::received);
            WKWebsiteDataStoreIsStatisticsRegisteredAsRedirectingTo(fixture.ref(), host.get(), other.get(), answer[6].context(pending), Answer::received);
            WKWebsiteDataStoreIsStatisticsOnlyInDatabaseOnce(fixture.ref(), wkString(domainURL(n)).get(), top.get(), answer[7].context(pending), Answer::received);
            WKWebsiteDataStoreDoesStatisticsDomainIDExistInDatabase(fixture.ref(), static_cast<int>(subject + 1), answer[8].context(pending), Answer::received);
            if (pending.outstanding >= mergeBatchSize)
                pending.wait();
        }
        pending.wait();
        if (!pass)
            addAnswers(checksum, answers);
    }
}

// Prevalence and interaction logging: setPrevalentResource, setVeryPrevalentResource, clearPrevalentResource,
// logUserInteraction / clearUserInteraction, setLastSeen, setGrandfathered, setPrevalentResourceForDebugMode and debug
// mode, then the classification that follows them.
static void prevalenceAndInteraction(Fixture& fixture, Checksum* checksum)
{
    fixture.clear();
    fixture.populate(databaseDomains);
    {
        Pending pending;
        WKWebsiteDataStoreSetResourceLoadStatisticsDebugModeWithCompletionHandler(fixture.ref(), true, pending.context(), Pending::done);
        pending.wait();
    }
    for (unsigned pass = 0; pass < interactionPasses; ++pass) {
        Pending pending;
        Pending* pendingPointer = &pending;
        for (unsigned n = 0; n < databaseDomains; ++n) {
            auto host = wkString(domainURL(n));
            switch ((n + pass) % 5) {
            case 0:
                WKWebsiteDataStoreSetStatisticsPrevalentResource(fixture.ref(), host.get(), true, pending.context(), Pending::done);
                break;
            case 1:
                WKWebsiteDataStoreSetStatisticsVeryPrevalentResource(fixture.ref(), host.get(), !(pass % 2), pending.context(), Pending::done);
                break;
            case 2:
                pending.context();
                [fixture.store() _clearPrevalentDomain:domainNSURL(n).get() completionHandler:^{
                    Pending::done(pendingPointer);
                }];
                break;
            case 3:
                WKWebsiteDataStoreSetStatisticsHasHadUserInteraction(fixture.ref(), host.get(), !(pass % 2), pending.context(), Pending::done);
                break;
            case 4:
                WKWebsiteDataStoreSetStatisticsLastSeen(fixture.ref(), host.get(), 3600.0 * (n % 48 + 1), pending.context(), Pending::done);
                break;
            }
            if (!(n % 11)) {
                ++callCount;
                WKWebsiteDataStoreSetStatisticsGrandfathered(fixture.ref(), host.get(), (n + pass) % 2);
            }
            if (!(n % 17)) {
                pending.context();
                [fixture.store() _logUserInteraction:domainNSURL(n).get() completionHandler:^{
                    Pending::done(pendingPointer);
                }];
            }
            if (!(n % 97))
                WKWebsiteDataStoreSetResourceLoadStatisticsPrevalentResourceForDebugMode(fixture.ref(), host.get(), pending.context(), Pending::done);
            if (pending.outstanding >= mergeBatchSize)
                pending.wait();
        }
        pending.wait();
        fixture.sync();
        fixture.processStatisticsAndDataRecords();
        if (checksum)
            digestDump(fixture, checksum);
    }
    {
        Pending pending;
        WKWebsiteDataStoreSetResourceLoadStatisticsDebugModeWithCompletionHandler(fixture.ref(), false, pending.context(), Pending::done);
        pending.wait();
    }
    digestDump(fixture, checksum);
}

// The testing setters, each round setting every parameter to a new value, merging a few domains under it and
// processing: grandfathering time, minimum time between removals, classification before removal, user-interaction time
// to live, cache max-age cap, third-party cookie blocking (each policy), first-party website data removal mode, cross-site
// loads with link decoration, isRunningTest and the time advance; then resetParametersToDefaultValues.
static void testingSetters(Fixture& fixture, Checksum* checksum)
{
    fixture.clear();
    for (unsigned round = 0; round < setterRounds; ++round) {
        Pending pending;
        callCount += 3;
        WKWebsiteDataStoreSetStatisticsGrandfatheringTime(fixture.ref(), round % 2 ? 3600 : 1);
        WKWebsiteDataStoreSetStatisticsMinimumTimeBetweenDataRecordsRemoval(fixture.ref(), round % 3);
        WKWebsiteDataStoreSetStatisticsShouldClassifyResourcesBeforeDataRecordsRemoval(fixture.ref(), round % 2);
        WKWebsiteDataStoreSetStatisticsTimeToLiveUserInteraction(fixture.ref(), 86400.0 * (1 + round % 30), pending.context(), Pending::done);
        WKWebsiteDataStoreSetStatisticsCacheMaxAgeCap(fixture.ref(), 3600.0 * (round + 1), pending.context(), Pending::done);
        WKWebsiteDataStoreSetResourceLoadStatisticsShouldBlockThirdPartyCookiesForTesting(fixture.ref(), round % 4 != 3, static_cast<WKThirdPartyCookieBlockingPolicy>(round % 3), pending.context(), Pending::done);
        WKWebsiteDataStoreSetResourceLoadStatisticsFirstPartyWebsiteDataRemovalModeForTesting(fixture.ref(), round % 2, pending.context(), Pending::done);
        auto from = wkString(domainURL(round));
        auto to = wkString(topFrameURL(round % topFrameDomains));
        WKWebsiteDataStoreSetStatisticsCrossSiteLoadWithLinkDecoration(fixture.ref(), from.get(), to.get(), round % 2, pending.context(), Pending::done);
        WKWebsiteDataStoreSetStatisticsIsRunningTest(fixture.ref(), true, pending.context(), Pending::done);
        WKWebsiteDataStoreSetResourceLoadStatisticsTimeAdvanceForTesting(fixture.ref(), timeShiftSeconds() + 3600.0 * round, pending.context(), Pending::done);
        double now = WallTime::now().secondsSinceEpoch().seconds() + timeShiftSeconds();
        for (unsigned domain = 0; domain < setterDomains; ++domain)
            fixture.merge(pending, round * setterDomains + domain, round, now);
        pending.wait();
        fixture.processStatisticsAndDataRecords();
    }
    digestDump(fixture, checksum);

    Pending pending;
    WKWebsiteDataStoreStatisticsResetToConsistentState(fixture.ref(), pending.context(), Pending::done);
    pending.wait();
    WKWebsiteDataStoreSetStatisticsIsRunningTest(fixture.ref(), true, pending.context(), Pending::done);
    pending.wait();
    fixture.advanceTime(0);
    digestDump(fixture, checksum);
}

// Pruning: setMaxStatisticsEntries and setPruneEntriesDownTo, with the database one below the maximum, at it, one above
// it and well above it, each processed.
static void pruneEntries(Fixture& fixture, Checksum* checksum)
{
    for (unsigned count : { pruneMaximumEntries - 1, pruneMaximumEntries, pruneMaximumEntries + 1, databaseDomains }) {
        fixture.clear();
        callCount += 2;
        WKWebsiteDataStoreSetStatisticsMaxStatisticsEntries(fixture.ref(), pruneMaximumEntries);
        WKWebsiteDataStoreSetStatisticsPruneEntriesDownTo(fixture.ref(), pruneEntriesDownTo);
        fixture.populate(count);
        fixture.processStatisticsAndDataRecords();
        digestDump(fixture, checksum);
    }
}

static RetainPtr<NSArray<WKWebsiteDataRecord *>> fetchStatisticsRecords(Fixture& fixture)
{
    ++callCount;
    __block RetainPtr<NSArray<WKWebsiteDataRecord *>> records;
    __block bool done = false;
    [fixture.store() fetchDataRecordsOfTypes:[NSSet setWithObject:_WKWebsiteDataTypeResourceLoadStatistics] completionHandler:^(NSArray<WKWebsiteDataRecord *> *result) {
        records = result;
        done = true;
    }];
    Util::run(&done);
    return [records sortedArrayUsingComparator:^NSComparisonResult(WKWebsiteDataRecord *a, WKWebsiteDataRecord *b) {
        return [a.displayName compare:b.displayName];
    }];
}

static std::string recordsText(NSArray<WKWebsiteDataRecord *> *records)
{
    std::string text;
    for (WKWebsiteDataRecord *record in records)
        text += std::string(record.displayName.UTF8String) + "\n";
    return text;
}

// The data summary (aggregatedThirdPartyData) and the website data records of the statistics type (registrableDomains),
// over a populated database with prevalent domains and relations.
static void thirdPartyDataSummary(Fixture& fixture, Checksum* checksum)
{
    static bool populated = false;
    if (!populated) {
        fixture.clear();
        fixture.populate(databaseDomains);
        fixture.addRelations(databaseDomains, 0x5a11);
        populated = true;
    }
    for (unsigned pass = 0; pass < summaryPasses; ++pass) {
        ++callCount;
        __block RetainPtr<NSArray<_WKResourceLoadStatisticsThirdParty *>> summary;
        __block bool done = false;
        [fixture.store() _getResourceLoadStatisticsDataSummary:^(NSArray<_WKResourceLoadStatisticsThirdParty *> *result) {
            summary = result;
            done = true;
        }];
        Util::run(&done);
        auto records = fetchStatisticsRecords(fixture);
        if (!checksum || pass)
            continue;
        // Time last updated is the clock's; the domains and grants are the store's.
        std::vector<std::string> lines;
        for (_WKResourceLoadStatisticsThirdParty *thirdParty in summary.get()) {
            std::vector<std::string> firstParties;
            for (_WKResourceLoadStatisticsFirstParty *firstParty in thirdParty.underFirstParties)
                firstParties.push_back(std::string(firstParty.firstPartyDomain.UTF8String) + (firstParty.thirdPartyStorageAccessGranted ? "+" : "-"));
            std::ranges::sort(firstParties);
            std::string line = thirdParty.thirdPartyDomain.UTF8String;
            for (auto& firstParty : firstParties)
                line += " " + firstParty;
            lines.push_back(WTF::move(line));
        }
        std::ranges::sort(lines);
        checksum->add(lines.size());
        for (auto& line : lines)
            checksum->add(line);
        checksum->add(recordsText(records.get()));
    }
}

// Website data removal: records of the statistics type removed (removeDataForDomain), removeITPDataForDomain, a clear
// of what was modified in the last hour, and a clear through website data removal.
static void removeWebsiteData(Fixture& fixture, Checksum* checksum)
{
    fixture.clear();
    fixture.populate(databaseDomains);
    fixture.addRelations(databaseDomains, 0x7e30e);

    auto records = fetchStatisticsRecords(fixture);
    if (checksum)
        checksum->add(recordsText(records.get()));
    RetainPtr toRemove = adoptNS([[NSMutableArray alloc] init]);
    for (NSUInteger i = 0; i < [records count]; i += removalStride)
        [toRemove addObject:[records objectAtIndex:i]];
    ++callCount;
    __block bool done = false;
    [fixture.store() removeDataOfTypes:[NSSet setWithObject:_WKWebsiteDataTypeResourceLoadStatistics] forDataRecords:toRemove.get() completionHandler:^{
        done = true;
    }];
    Util::run(&done);
    digestDump(fixture, checksum);

    Pending pending;
    for (unsigned n = 0; n < databaseDomains; n += itpRemovalStride) {
        WKWebsiteDataStoreRemoveITPDataForDomain(fixture.ref(), wkString(domainHost(n)).get(), pending.context(), Pending::done);
        if (pending.outstanding >= mergeBatchSize)
            pending.wait();
    }
    pending.wait();
    fixture.sync();
    digestDump(fixture, checksum);

    // Every fifth domain seen now, the rest an hour and more ago, so the last hour holds exactly the fifths.
    double now = WallTime::now().secondsSinceEpoch().seconds() + timeShiftSeconds();
    for (unsigned n = 0; n < databaseDomains; n += 5) {
        WKWebsiteDataStoreSetStatisticsLastSeen(fixture.ref(), wkString(domainURL(n)).get(), now, pending.context(), Pending::done);
        if (pending.outstanding >= mergeBatchSize)
            pending.wait();
    }
    pending.wait();
    WKWebsiteDataStoreStatisticsClearInMemoryAndPersistentStoreModifiedSinceHours(fixture.ref(), 1, pending.context(), Pending::done);
    pending.wait();
    digestDump(fixture, checksum);

    fixture.populate(databaseDomains / 4);
    WKWebsiteDataStoreStatisticsClearThroughWebsiteDataRemoval(fixture.ref(), pending.context(), Pending::done);
    pending.wait();
    digestDump(fixture, checksum);
}

// An ephemeral session's store: the in-memory interaction paths (logUserInteraction, clearUserInteraction,
// hadUserInteraction), isResourceLoadStatisticsEphemeral and the in-memory clear.
static void ephemeralSession(Fixture& fixture, Checksum* checksum)
{
    fixture.clear();
    std::vector<Answer> answers(2 * ephemeralDomains + 1);
    Pending pending;
    WKWebsiteDataStoreIsStatisticsEphemeral(fixture.ref(), answers.back().context(pending), Answer::received);
    for (unsigned n = 0; n < ephemeralDomains; ++n) {
        auto host = wkString(domainURL(n));
        WKWebsiteDataStoreSetStatisticsHasHadUserInteraction(fixture.ref(), host.get(), true, pending.context(), Pending::done);
        if (!(n % 3))
            WKWebsiteDataStoreSetStatisticsHasHadUserInteraction(fixture.ref(), host.get(), false, pending.context(), Pending::done);
        WKWebsiteDataStoreIsStatisticsHasHadUserInteraction(fixture.ref(), host.get(), answers[n].context(pending), Answer::received);
        if (pending.outstanding >= mergeBatchSize)
            pending.wait();
    }
    pending.wait();
    fixture.clear();
    for (unsigned n = 0; n < ephemeralDomains; ++n) {
        WKWebsiteDataStoreIsStatisticsHasHadUserInteraction(fixture.ref(), wkString(domainURL(n)).get(), answers[ephemeralDomains + n].context(pending), Answer::received);
        if (pending.outstanding >= mergeBatchSize)
            pending.wait();
    }
    pending.wait();
    addAnswers(checksum, answers);
}

static std::string dumpOf(WKWebsiteDataStoreRef store)
{
    struct Context {
        std::string result;
        bool finished { false };
    } context;
    WKWebsiteDataStoreDumpResourceLoadStatistics(store, &context, [](WKStringRef string, void* contextPointer) {
        auto& context = *static_cast<Context*>(contextPointer);
        context.result = toStdString(string);
        context.finished = true;
    });
    Util::run(&context.finished);
    return context.result;
}

// Messages a web process sends per pass of WebProcessMessages, the rate's numerator.
constexpr unsigned webProcessMessagesPerPass = webProcessRounds * (webProcessHostsPerRound + 4) + webProcessFrames * 6 + webProcessPopups * 2;

// One page's pass over the NetworkConnectionToWebProcess messages: resourceLoadStatisticsUpdated (subresource loads, then
// the observer's flush), logUserInteraction, setLoginStatus and isLoggedIn, queryStorageAccessPermission and the
// permission-change subscription, hasStorageAccess and requestStorageAccess, requestStorageAccessUnderOpener (cross-site
// popups with a user gesture), clearFrameLoadRecordsForStorageAccess (the frames removed); then, from the UI process,
// setStorageAccessPermissionForTesting and the storage access entries. A fresh data store and page each pass.
static void webProcessPass(Persistence persistence, Checksum* checksum)
{
    auto frameBody = "<script>(async () => {"
        "let state = 'none';"
        "try { const status = await navigator.permissions.query({ name: 'storage-access' }); state = status.state; status.onchange = () => { }; } catch (e) { state = 'error'; }"
        "const before = await document.hasStorageAccess();"
        "let requested = 'none';"
        "await new Promise(resolve => internals.withUserGesture(() => { document.requestStorageAccess().then(() => { requested = 'granted'; resolve(); }, () => { requested = 'denied'; resolve(); }); }));"
        "const after = await document.hasStorageAccess();"
        "parent.postMessage('frame:' + location.hostname + ':' + state + ':' + before + ':' + requested + ':' + after, '*');"
        "})();</script>"_s;
    auto popupBody = "<script>internals.withUserGesture(() => { });"
        "opener.postMessage('popup:' + location.hostname, '*');</script>"_s;

    HTTPServer httpServer { HTTPServer::UseCoroutines::Yes, [&](Connection connection) -> ConnectionTask {
        while (true) {
            auto request = co_await connection.awaitableReceiveHTTPRequest();
            URL url { HTTPServer::parsePath(request) };
            if (url.string() == "/frame"_s) {
                co_await connection.awaitableSend(HTTPResponse(frameBody).serialize());
                continue;
            }
            if (url.string() == "/popup"_s) {
                co_await connection.awaitableSend(HTTPResponse(popupBody).serialize());
                continue;
            }
            co_await connection.awaitableSend(HTTPResponse("<body></body>"_s).serialize());
        }
    }, HTTPServer::Protocol::HttpsProxy };

    RetainPtr<NSURL> storeDirectory;
    RetainPtr<_WKWebsiteDataStoreConfiguration> storeConfiguration;
    if (persistence == Persistence::Persistent) {
        storeDirectory = createTemporaryDirectory();
        storeConfiguration = isolatedStoreConfiguration(storeDirectory.get());
    } else
        storeConfiguration = adoptNS([[_WKWebsiteDataStoreConfiguration alloc] initNonPersistentConfiguration]);
    storeConfiguration.get().httpsProxy = [NSURL URLWithString:[NSString stringWithFormat:@"https://127.0.0.1:%d/", httpServer.port()]];
    RetainPtr dataStore = adoptNS([[WKWebsiteDataStore alloc] _initWithConfiguration:storeConfiguration.get()]);
    auto storeRef = (WKWebsiteDataStoreRef)dataStore.get();
    RetainPtr configuration = [WKWebViewConfiguration _test_configurationWithTestPlugInClassName:@"WebProcessPlugInWithInternals" configureJSCForTesting:YES];
    [configuration setWebsiteDataStore:dataStore.get()];
    [configuration preferences].javaScriptCanOpenWindowsAutomatically = YES;
    for (_WKFeature *feature in [WKPreferences _features]) {
        if ([feature.key isEqualToString:@"LoginStatusAPIEnabled"])
            [[configuration preferences] _setEnabled:YES forFeature:feature];
    }
    [dataStore _setResourceLoadStatisticsEnabled:YES];

    __block bool done { false };
    [dataStore _clearResourceLoadStatistics:^{
        done = true;
    }];
    Util::run(&done);
    {
        Pending pending;
        WKWebsiteDataStoreSetStatisticsIsRunningTest(storeRef, true, pending.context(), Pending::done);
        // Moving an ephemeral store's clock, or dumping it, is a RELEASE_ASSERT in the network process.
        if (persistence == Persistence::Persistent)
            WKWebsiteDataStoreSetResourceLoadStatisticsTimeAdvanceForTesting(storeRef, timeShiftSeconds(), pending.context(), Pending::done);
        pending.wait();
    }
    for (unsigned frame = 0; frame < webProcessFrames; frame += 2) {
        done = false;
        [dataStore _logUserInteraction:[NSURL URLWithString:[NSString stringWithFormat:@"https://third%u.example/", frame]] completionHandler:^{
            done = true;
        }];
        Util::run(&done);
    }

    RetainPtr navigationDelegate = adoptNS([TestNavigationDelegate new]);
    [navigationDelegate allowAnyTLSCertificate];
    RetainPtr uiDelegate = adoptNS([TestUIDelegate new]);
    RetainPtr popups = adoptNS([[NSMutableArray alloc] init]);
    uiDelegate.get().requestStorageAccessPanelForDomain = ^(WKWebView *, NSString *, NSString *, void (^completionHandler)(BOOL)) {
        completionHandler(YES);
    };
    __weak TestUIDelegate *weakUIDelegate = uiDelegate.get();
    __weak TestNavigationDelegate *weakNavigationDelegate = navigationDelegate.get();
    uiDelegate.get().createWebViewWithConfiguration = ^WKWebView *(WKWebViewConfiguration *popupConfiguration, WKNavigationAction *, WKWindowFeatures *) {
        RetainPtr popup = adoptNS([[TestWKWebView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100) configuration:popupConfiguration]);
        [popup setNavigationDelegate:weakNavigationDelegate];
        [popup setUIDelegate:weakUIDelegate];
        [popups addObject:popup.get()];
        return [popups lastObject];
    };
    RetainPtr webView = adoptNS([[TestWKWebView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100) configuration:configuration.get()]);
    [webView setNavigationDelegate:navigationDelegate.get()];
    [webView setUIDelegate:uiDelegate.get()];
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://top.example/"]]];
    [navigationDelegate waitForDidFinishNavigation];

    // The page reports what each step answered, in a fixed order, and alerts it once every step has run.
    NSString *script = [NSString stringWithFormat:@"(async () => {"
        "const login = navigator.login || navigator;"
        "const report = [];"
        "for (let round = 0; round < %u; ++round) {"
        "  await Promise.all(Array.from({ length: %u }, (_, i) => fetch('https://sub' + round + '-' + i + '.example/pixel', { mode: 'no-cors' }).then(() => 1, () => 0)));"
        "  internals.notifyResourceLoadObserver();"
        "  let status;"
        "  await new Promise(resolve => internals.withUserGesture(() => { try { login.setStatus(round %% 2 ? 'logged-out' : 'logged-in').then(() => { status = 'set'; resolve(); }, () => { status = 'rejected'; resolve(); }); } catch (e) { status = 'error'; resolve(); } }));"
        "  let loggedIn;"
        "  try { loggedIn = await login.isLoggedIn(); } catch (e) { loggedIn = 'error'; }"
        "  report.push('login' + round + ':' + status + ':' + loggedIn);"
        "}"
        "const collect = (prefix, count, start) => new Promise(resolve => {"
        "  const results = [];"
        "  const listener = event => { if (!String(event.data).startsWith(prefix)) return; results.push(event.data); if (results.length == count) { removeEventListener('message', listener); resolve(results.sort()); } };"
        "  addEventListener('message', listener);"
        "  start();"
        "});"
        "report.push(...await collect('frame:', %u, () => { for (let i = 0; i < %u; ++i) { const frame = document.createElement('iframe'); frame.src = 'https://third' + i + '.example/frame'; document.body.appendChild(frame); } }));"
        "report.push(...await collect('popup:', %u, () => { for (let i = 0; i < %u; ++i) internals.withUserGesture(() => { window.open('https://popup' + i + '.example/popup'); }); }));"
        "for (const frame of [...document.querySelectorAll('iframe')]) frame.remove();"
        "try { await login.isLoggedIn(); } catch (e) { }"
        "return report.join('|');"
        "})().then(result => alert(result), error => alert('error:' + error)); true",
        webProcessRounds, webProcessHostsPerRound, webProcessFrames, webProcessFrames, webProcessPopups, webProcessPopups];
    [webView evaluateJavaScript:script completionHandler:nil];
    NSString *report = [uiDelegate waitForAlert];

    {
        Pending pending;
        for (unsigned frame = 0; frame < webProcessFrames; ++frame) {
            auto subFrame = wkString("https://third" + std::to_string(frame) + ".example/");
            WKWebsiteDataStoreSetStorageAccessPermissionForTesting(storeRef, [webView _pageRefForTransitionToWKWebView], frame % 3, wkString("https://top.example/").get(), subFrame.get(), pending.context(), Pending::done);
        }
        pending.wait();
    }
    struct Entries {
        std::vector<std::string> domains;
        bool finished { false };
    } entries;
    WKWebsiteDataStoreGetAllStorageAccessEntries(storeRef, [webView _pageRefForTransitionToWKWebView], &entries, [](void* context, WKArrayRef domains) {
        auto& entries = *static_cast<Entries*>(context);
        for (size_t i = 0; domains && i < WKArrayGetSize(domains); ++i)
            entries.domains.push_back(toStdString((WKStringRef)WKArrayGetItemAtIndex(domains, i)));
        entries.finished = true;
    });
    Util::run(&entries.finished);
    std::ranges::sort(entries.domains);
    std::string dump;
    if (persistence == Persistence::Persistent)
        dump = dumpOf(storeRef);

    if (checksum) {
        checksum->add(std::string(report.UTF8String));
        checksum->add(entries.domains.size());
        for (auto& domain : entries.domains)
            checksum->add(domain);
        saveDump(dump);
        checksum->add(dump);
    }

    if (persistence == Persistence::Persistent && checksum)
        printNetworkFootprint(currentShape, [dataStore _networkProcessIdentifier]);
    for (WKWebView *popup in popups.get())
        [popup _close];
    webView = nil;
    popups = nil;
    dataStore = nil;
    if (storeDirectory)
        [[NSFileManager defaultManager] removeItemAtURL:storeDirectory.get() error:nil];
}

static void runPageBenchmark(ASCIILiteral name, Persistence persistence, uint64_t expectedChecksum)
{
    currentShape = name;
    Checksum checksum;
    auto firstStart = MonotonicTime::now();
    webProcessPass(persistence, &checksum);
    double firstMilliseconds = (MonotonicTime::now() - firstStart).seconds() * 1000;
    EXPECT_EQ(checksum.value(), expectedChecksum) << name.characters();
    if (!runsBenchmarks()) {
        SAFE_PRINTF("%s: first pass %.1f ms checksum=%016llx\n", name, firstMilliseconds, static_cast<unsigned long long>(checksum.value()));
        fflush(stdout);
        return;
    }
    // One fresh page per process: a second page in the same process never finishes its script (its alert does not
    // arrive), so the full run times the first pass, which takes over a second.
    SAFE_PRINTF("%s: %.1f ms %.6f MB/s checksum=%016llx\n", name, firstMilliseconds, webProcessMessagesPerPass / firstMilliseconds, static_cast<unsigned long long>(checksum.value()));
    fflush(stdout);
}

} // namespace TestWebKitAPI::ResourceLoadStatisticsBench

namespace TestWebKitAPI {

using namespace ResourceLoadStatisticsBench;

// The process start-up cost alone: the same process start and exit, no shape.
TEST(ResourceLoadStatisticsBench, StartUp)
{
}

TEST(ResourceLoadStatisticsBench, MergeBatches)
{
    runBenchmark("MergeBatches"_s, 2, 0xaa2c5eb275cbbaefull, mergeBatches);
}

TEST(ResourceLoadStatisticsBench, UpdateBatches)
{
    runBenchmark("UpdateBatches"_s, 1, 0x74adda4ee393c5b0ull, updateBatches);
}

TEST(ResourceLoadStatisticsBench, ClassificationPass)
{
    runBenchmark("ClassificationPass"_s, 1, 0x60a428a07dbcb288ull, classificationPass);
}

TEST(ResourceLoadStatisticsBench, DeleteOrRestrictWebsiteData)
{
    runBenchmark("DeleteOrRestrictWebsiteData"_s, 1, 0x51dee71e4ec6c208ull, deleteOrRestrict);
}

TEST(ResourceLoadStatisticsBench, DumpStatistics)
{
    runBenchmark("DumpStatistics"_s, 2, 0x5d1b21bf6c700bafull, dumpStatistics);
}

TEST(ResourceLoadStatisticsBench, CookieBlockingUpdate)
{
    runBenchmark("CookieBlockingUpdate"_s, 1, 0x86f91df0cdbe1d24ull, cookieBlockingUpdate);
}

// Storage access decisions: hasStorageAccess and requestStorageAccess from third-party subframes, which reach the
// store through NetworkConnectionToWebProcess (hasStorageAccess / requestStorageAccess / cookieAccess), the UI
// process's prompt, and grantStorageAccess. A page, because the web process makes these calls.
TEST(ResourceLoadStatisticsBench, StorageAccessDecisions)
{
    using namespace ResourceLoadStatisticsBenchInputs;

    auto frameBody = [] {
        return std::string("<script>(async () => {"
            "let granted = 0, denied = 0;"
            "for (let i = 0; i < ") + std::to_string(storageAccessChecksPerFrame) + "; ++i) {"
            "  if (await document.hasStorageAccess()) ++granted; else ++denied;"
            "  if (i == 1) await new Promise(resolve => internals.withUserGesture(() => { document.requestStorageAccess().then(resolve, resolve); }));"
            "}"
            "parent.postMessage(location.hostname + ':' + granted + ':' + denied, '*');"
            "})();</script>";
    }();

    HTTPServer httpServer { HTTPServer::UseCoroutines::Yes, [&](Connection connection) -> ConnectionTask {
        while (true) {
            auto request = co_await connection.awaitableReceiveHTTPRequest();
            URL url { HTTPServer::parsePath(request) };
            if (url.string() == "/frame"_s) {
                co_await connection.awaitableSend(HTTPResponse(String::fromUTF8(frameBody)).serialize());
                continue;
            }
            co_await connection.awaitableSend(HTTPResponse("<body></body>"_s).serialize());
        }
    }, HTTPServer::Protocol::HttpsProxy };

    auto storeDirectory = createTemporaryDirectory();
    auto storeConfiguration = isolatedStoreConfiguration(storeDirectory.get());
    storeConfiguration.get().httpsProxy = [NSURL URLWithString:[NSString stringWithFormat:@"https://127.0.0.1:%d/", httpServer.port()]];
    auto configuration = [WKWebViewConfiguration _test_configurationWithTestPlugInClassName:@"WebProcessPlugInWithInternals" configureJSCForTesting:YES];
    RetainPtr dataStore = adoptNS([[WKWebsiteDataStore alloc] _initWithConfiguration:storeConfiguration.get()]);
    [configuration setWebsiteDataStore:dataStore.get()];
    [dataStore _setResourceLoadStatisticsEnabled:YES];

    __block bool done { false };
    [dataStore _clearResourceLoadStatistics:^{
        done = true;
    }];
    Util::run(&done);
    {
        Pending pending;
        WKWebsiteDataStoreSetResourceLoadStatisticsTimeAdvanceForTesting((WKWebsiteDataStoreRef)dataStore.get(), timeShiftSeconds(), pending.context(), Pending::done);
        pending.wait();
    }
    for (unsigned frame = 0; frame < storageAccessFrames; ++frame) {
        // Interaction on the third party, so requestStorageAccess is eligible without a prompt on some frames.
        done = false;
        if (!(frame % 2)) {
            [dataStore _logUserInteraction:[NSURL URLWithString:[NSString stringWithFormat:@"https://third%u.example/", frame]] completionHandler:^{
                done = true;
            }];
            Util::run(&done);
        }
    }

    RetainPtr uiDelegate = adoptNS([TestUIDelegate new]);
    uiDelegate.get().requestStorageAccessPanelForDomain = ^(WKWebView *, NSString *, NSString *, void (^completionHandler)(BOOL)) {
        completionHandler(YES);
    };
    RetainPtr webView = adoptNS([[TestWKWebView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100) configuration:configuration]);
    RetainPtr navigationDelegate = adoptNS([TestNavigationDelegate new]);
    [navigationDelegate allowAnyTLSCertificate];
    [webView setNavigationDelegate:navigationDelegate.get()];
    [webView setUIDelegate:uiDelegate.get()];
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://top.example/"]]];
    [navigationDelegate waitForDidFinishNavigation];

    // The frames report "<host>:<granted>:<denied>"; the top frame alerts the sorted list once all have.
    NSString *script = [NSString stringWithFormat:@"let results = [];"
        "addEventListener('message', event => { results.push(event.data); if (results.length == %u) alert(results.sort().join('|')); });"
        "for (let i = 0; i < %u; ++i) { let frame = document.createElement('iframe'); frame.src = 'https://third' + i + '.example/frame'; document.body.appendChild(frame); } true", storageAccessFrames, storageAccessFrames];

    auto start = MonotonicTime::now();
    [webView evaluateJavaScript:script completionHandler:nil];
    NSString *report = [uiDelegate waitForAlert];
    double seconds = (MonotonicTime::now() - start).seconds();

    Checksum checksum;
    checksum.add(std::string(report.UTF8String));
    // Storage-access grants the decisions produced, from the store.
    std::string dumped;
    done = false;
    WKWebsiteDataStoreDumpResourceLoadStatistics((WKWebsiteDataStoreRef)dataStore.get(), &dumped, [](WKStringRef string, void* context) {
        size_t size = WKStringGetMaximumUTF8CStringSize(string);
        std::string buffer(size, '\0');
        buffer.resize(WKStringGetUTF8CString(string, buffer.data(), size) - 1);
        *static_cast<std::string*>(context) = WTF::move(buffer);
    });
    // The dump's callback runs on the main run loop; wait for it.
    Util::waitFor([&] {
        return !dumped.empty();
    }, 100000);
    currentShape = "StorageAccessDecisions"_s;
    saveDump(dumped);
    checksum.add(dumped);

    // Recorded from the first build's output.
    constexpr uint64_t expectedChecksum = 0x56e2d406358cda65ull;
    if (expectedChecksum)
        EXPECT_EQ(checksum.value(), expectedChecksum);

    // One timed pass only: a second one in the same page would see the first's grants.
    printNetworkFootprint("StorageAccessDecisions"_s, [dataStore _networkProcessIdentifier]);
    webView = nil;
    dataStore = nil;
    [[NSFileManager defaultManager] removeItemAtURL:storeDirectory.get() error:nil];

    SAFE_PRINTF("StorageAccessDecisions: %.1f ms %.2f MB/s checksum=%016llx\n", seconds * 1000, storageAccessFrames * storageAccessChecksPerFrame / (seconds * 1000), static_cast<unsigned long long>(checksum.value()));
    fflush(stdout);
}

// Each path of the statistics messages of NetworkProcess and NetworkConnectionToWebProcess, through the testing entry points and the pages that send them.
TEST(ResourceLoadStatisticsBench, StatisticsQueries)
{
    runBenchmark("StatisticsQueries"_s, 2, 0xb891008bb8cc5862ull, statisticsQueries);
}

TEST(ResourceLoadStatisticsBench, PrevalenceAndInteraction)
{
    runBenchmark("PrevalenceAndInteraction"_s, 1, 0x3abf3d560f3cd78full, prevalenceAndInteraction);
}

TEST(ResourceLoadStatisticsBench, TestingSetters)
{
    runBenchmark("TestingSetters"_s, 1, 0x474e24c81f2399f1ull, testingSetters);
}

TEST(ResourceLoadStatisticsBench, PruneEntries)
{
    runBenchmark("PruneEntries"_s, 2, 0xac4c2d006e674af7ull, pruneEntries);
}

TEST(ResourceLoadStatisticsBench, ThirdPartyDataSummary)
{
    runBenchmark("ThirdPartyDataSummary"_s, 3, 0x6857199e2ab7f049ull, thirdPartyDataSummary);
}

TEST(ResourceLoadStatisticsBench, RemoveWebsiteData)
{
    runBenchmark("RemoveWebsiteData"_s, 1, 0x1b443d46b2ae37d6ull, removeWebsiteData);
}

TEST(ResourceLoadStatisticsBench, EphemeralSession)
{
    runBenchmark("EphemeralSession"_s, 4, 0xe9c1dd05687cb783ull, ephemeralSession, Persistence::Ephemeral);
}

TEST(ResourceLoadStatisticsBench, WebProcessMessages)
{
    runPageBenchmark("WebProcessMessages"_s, Persistence::Persistent, 0xcd4c4495a98cc24eull);
}

TEST(ResourceLoadStatisticsBench, WebProcessMessagesEphemeral)
{
    runPageBenchmark("WebProcessMessagesEphemeral"_s, Persistence::Ephemeral, 0xeb12f32141581033ull);
}

} // namespace TestWebKitAPI
