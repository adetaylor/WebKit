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

// Speed of the service worker server, one test per workload, through WebCore::SWServer and the interfaces the network
// process drives it with (SWServer::Connection, SWServerToContextConnection, SWServerDelegate, SWRegistrationStore and
// SWOriginStore). The tests name no implementation: every server call is the one WebKit's network process makes.
//
// The test objects stand in for the web processes, the processes that host the workers and the registration store.
// They never answer a call from inside it: each answer goes into a queue that the test drains in order, spinning the
// run loop when the queue is empty so the job queues' timers fire. So the server sees its replies arrive later, as it
// does over IPC, and the order of everything is fixed by the workload.
//
// Each pass makes a fresh server, runs the workload with deterministic inputs and feeds every call the test objects
// receive (with its arguments, identifiers named by the scope and generation they belong to) to an FNV-1a digest. By
// default a test runs one pass and EXPECT_EQs the digest against the workload's recorded checksum, and prints
// "<Test>: checksum=<digest> (recorded <value>)" when they differ, which is how a new checksum is recorded. With
// WEBKIT_RUN_BENCHMARKS set it then runs the workload's fixed number of passes (about a second of timed work each on an
// M1, the same work in every build so whole-process counters compare), checks every pass's digest, and prints
//     <Test>: <ms> ms <n> MB/s checksum=<digest>
// where <n> counts the URL, script and header bytes the timed operations carried. Set-up inside a pass (registering
// the service workers a lookup workload looks up, building a store's contents) is measured and left out of the time.
// A build with assertions runs the four largest workloads at a smaller size (workloadSize()), and registers
// RegisterInstallActivate's scopes in steps with their timers drained, as every build does MatchRegistration's
// untimed set-up, so every test finishes in a Debug build with one digest; such a build checks its own recorded
// checksums.

#include "config.h"

#include "Helpers/Test.h"
#include "Helpers/Utilities.h"
#include <WebCore/BackgroundFetchInformation.h>
#include <WebCore/BackgroundFetchStore.h>
#include <WebCore/ClientOrigin.h>
#include <WebCore/ExceptionData.h>
#include <WebCore/FetchOptions.h>
#include <WebCore/MessageWithMessagePorts.h>
#include <WebCore/NotificationData.h>
#include <WebCore/NotificationPayload.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/RegistrableDomain.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/RouterSourceDict.h>
#include <WebCore/RouterSourceEnum.h>
#include <WebCore/RunningStatus.h>
#include <WebCore/SWOriginStore.h>
#include <WebCore/SWRegistrationStore.h>
#include <WebCore/SWServer.h>
#include <WebCore/SWServerDelegate.h>
#include <WebCore/SWServerRegistration.h>
#include <WebCore/SWServerToContextConnection.h>
#include <WebCore/SWServerWorker.h>
#include <WebCore/ScriptBuffer.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/ServiceWorkerClientData.h>
#include <WebCore/ServiceWorkerClientQueryOptions.h>
#include <WebCore/ServiceWorkerContextData.h>
#include <WebCore/ServiceWorkerJobData.h>
#include <WebCore/ServiceWorkerRegistrationData.h>
#include <WebCore/ServiceWorkerRegistrationKey.h>
#include <WebCore/ServiceWorkerRoute.h>
#include <WebCore/ServiceWorkerTypes.h>
#include <WebCore/Site.h>
#include <WebCore/ThreadGlobalData.h>
#include <WebCore/ThreadTimers.h>
#include <WebCore/Timer.h>
#include <WebCore/WorkerFetchResult.h>
#include <WebCore/WorkerThreadMode.h>
#include <algorithm>
#include <cstdlib>
#include <pal/SessionID.h>
#include <wtf/CheckedPtr.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Deque.h>
#include <wtf/HashMap.h>
#include <wtf/HexNumber.h>
#include <wtf/MainThread.h>
#include <wtf/MonotonicTime.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/UUID.h>
#include <wtf/Vector.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringToIntegerConversion.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI::SWServerBenchmark {

// FNV-1a over everything observed.
class Digest {
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

private:
    void addByte(uint8_t byte)
    {
        m_value ^= byte;
        m_value *= 1099511628211ull;
    }

    uint64_t m_value { 1469598103934665603ull };
};

static uint64_t hashString(StringView string)
{
    Digest digest;
    digest.add(string);
    return digest.value();
}

// Time spent on set-up inside a pass, left out of the measurement. A measure() inside another counts once.
class Excluded {
public:
    template<typename Function>
    void measure(NOESCAPE const Function& function)
    {
        if (m_depth) {
            function();
            return;
        }
        ++m_depth;
        auto start = MonotonicTime::now();
        function();
        m_total += MonotonicTime::now() - start;
        --m_depth;
    }

    Seconds total() const { return m_total; }

private:
    Seconds m_total;
    unsigned m_depth { 0 };
};

// The earliest one-shot WebCore timer pending on the main thread that is not yet due. In these tests those are the
// server's: the registrations' soft-update timers, the workers' termination and terminate-if-possible timers, and the
// per-origin and per-event termination timers (1 to 10 s). Ties go in the order the timers were started.
static WebCore::ThreadTimerHeapItem* earliestPendingTimer()
{
    auto now = MonotonicTime::now();
    WebCore::ThreadTimerHeapItem* earliest = nullptr;
    for (auto& item : WebCore::threadGlobalDataSingleton().threadTimers().timerHeap()) {
        if (!item->hasTimer() || item->timer().repeatInterval() || item->time <= now)
            continue;
        if (!earliest || item->time < earliest->time || (item->time == earliest->time && item->insertionOrder < earliest->insertionOrder))
            earliest = item.ptr();
    }
    return earliest;
}

static bool hasDueTimer()
{
    auto now = MonotonicTime::now();
    for (auto& item : WebCore::threadGlobalDataSingleton().threadTimers().timerHeap()) {
        if (item->hasTimer() && item->time <= now)
            return true;
    }
    return false;
}

static unsigned pendingTimerCount()
{
    unsigned count = 0;
    for (auto& item : WebCore::threadGlobalDataSingleton().threadTimers().timerHeap())
        count += item->hasTimer() && !item->timer().repeatInterval();
    return count;
}

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

private:
    uint32_t m_state;
};

enum class Event : uint8_t {
    RejectJob = 1,
    ResolveRegistrationJob,
    ResolveUnregistrationJob,
    StartScriptFetch,
    RegistrationState,
    WorkerState,
    UpdateFound,
    LastUpdateTime,
    UpdateViaCache,
    ControllerChange,
    PostMessageToClient,
    FocusClient,
    BackgroundFetchUpdate,
    ContextConnectionCreated,
    InstallContext,
    AppInitiated,
    FireInstall,
    FireActivate,
    TerminateWorker,
    ScriptsSaved,
    PushEvent,
    NotificationEvent,
    BackgroundFetchEvent,
    OpenWindow,
    ContextConnectionNoLongerNeeded,
    Unresponsive,
    Inspectable,
    SoftUpdateFetch,
    CreateContextConnection,
    AppBoundDomains,
    AllowFirstParty,
    BackgroundFetchPermission,
    StoreUpdate,
    StoreRemove,
    StoreClear,
    StoreRetrieveScripts,
    StoreImportOrigin,
    StoreImportOriginList,
    OriginStoreAdd,
    OriginStoreRemove,
    OriginStoreClear,
    OriginStoreImportComplete,
    // Results the test reads back from the server.
    AddRoutesResult,
    PushResult,
    MatchResult,
    LookupResult,
    RouteResult,
    ReadyResult,
    GetRegistrationsResult,
    OriginsResult,
    ClaimResult,
    MatchAllResult,
    RunWorkerResult,
    ClearDone,
};

// What a scope's next script fetch, start and install do.
enum class Outcome : uint8_t { Succeed, FetchError, StartFailure, InstallFailure };

struct ScopePlan {
    Outcome outcome { Outcome::Succeed };
    unsigned scriptVersion { 0 };
    unsigned importedScriptCount { 0 };
    unsigned importedVersion { 0 };
    unsigned routeCount { 0 };
    unsigned routeVariant { 0 };
};

struct WorkerInfo {
    String scope;
    unsigned generation { 0 };
    std::optional<WebCore::ServiceWorkerJobDataIdentifier> jobDataIdentifier;
    WebCore::ServiceWorkerRegistrationIdentifier registrationIdentifier;
};

struct JobInfo {
    unsigned ordinal { 0 };
    URL scriptURL;
    String scope;
};

class Harness;

static String scriptBody(StringView scope, unsigned version)
{
    return makeString("// service worker for "_s, scope, " version "_s, version, "\nself.addEventListener('fetch', event => { event.respondWith(fetch(event.request)); });\n"_s);
}

static String importedScriptBody(StringView url, unsigned version)
{
    return makeString("// imported "_s, url, " version "_s, version, "\nself.helpers = self.helpers || [];\n"_s);
}

static URL importedScriptURL(StringView scope, unsigned index)
{
    return URL { makeString(scope, "lib/helper"_s, index, ".js"_s) };
}

static WebCore::ProcessIdentifier webProcessIdentifier(unsigned index)
{
    return WebCore::ProcessIdentifier { 0x5357000000ull + index };
}

static WebCore::ScriptExecutionContextIdentifier clientIdentifier(unsigned index, WebCore::ProcessIdentifier process)
{
    auto uuid = WTF::UUID::parse(makeString("5357c11e-0000-4000-8000-"_s, hex(index, 12, Lowercase)));
    return { *uuid, process };
}

// The test's web process: it answers the server's job messages as WebSWClientConnection would.
class TestConnection final : public WebCore::SWServer::Connection {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(TestConnection);
public:
    static Ref<TestConnection> create(WebCore::SWServer& server, Harness& harness, unsigned index)
    {
        return adoptRef(*new TestConnection(server, harness, index));
    }

    unsigned index() const { return m_index; }
    WebCore::ProcessIdentifier processIdentifier() const { return m_processIdentifier; }

    void finishFetchingScript(const WebCore::ServiceWorkerJobDataIdentifier& identifier, const WebCore::ServiceWorkerRegistrationKey& key, WebCore::WorkerFetchResult&& result) { finishFetchingScriptInServer(identifier, key, WTF::move(result)); }
    void addRegistration(WebCore::ServiceWorkerRegistrationIdentifier identifier) { addServiceWorkerRegistrationInServer(identifier); }
    void ready(const WebCore::SecurityOriginData& topOrigin, const URL& clientURL, CompletionHandler<void(std::optional<WebCore::ServiceWorkerRegistrationData>&&)>&& callback) { whenRegistrationReady(topOrigin, clientURL, WTF::move(callback)); }

private:
    TestConnection(WebCore::SWServer& server, Harness& harness, unsigned index)
        : WebCore::SWServer::Connection(server, webProcessIdentifier(index))
        , m_harness(harness)
        , m_index(index)
        , m_processIdentifier(webProcessIdentifier(index))
    {
    }

    void updateRegistrationStateInClient(WebCore::ServiceWorkerRegistrationIdentifier, WebCore::ServiceWorkerRegistrationState, const std::optional<WebCore::ServiceWorkerData>&) final;
    void updateWorkerStateInClient(WebCore::ServiceWorkerIdentifier, WebCore::ServiceWorkerState) final;
    void fireUpdateFoundEvent(WebCore::ServiceWorkerRegistrationIdentifier) final;
    void setRegistrationLastUpdateTime(WebCore::ServiceWorkerRegistrationIdentifier, WallTime) final;
    void setRegistrationUpdateViaCache(WebCore::ServiceWorkerRegistrationIdentifier, WebCore::ServiceWorkerUpdateViaCache) final;
    void notifyClientsOfControllerChange(const HashSet<WebCore::ScriptExecutionContextIdentifier>&, const std::optional<WebCore::ServiceWorkerData>&) final;
    void postMessageToServiceWorkerClient(WebCore::ScriptExecutionContextIdentifier, const WebCore::MessageWithMessagePorts&, WebCore::ServiceWorkerIdentifier, const WebCore::SecurityOriginData&, CompletionHandlerCallingScope&&) final;
    void focusServiceWorkerClient(WebCore::ScriptExecutionContextIdentifier, CompletionHandler<void(std::optional<WebCore::ServiceWorkerClientData>&&)>&&) final;
    void updateBackgroundFetchRegistration(const WebCore::BackgroundFetchInformation&) final;
    void contextConnectionCreated(WebCore::SWServerToContextConnection&) final;
    void rejectJobInClient(WebCore::ServiceWorkerJobIdentifier, const WebCore::ExceptionData&) final;
    void resolveRegistrationJobInClient(WebCore::ServiceWorkerJobIdentifier, const WebCore::ServiceWorkerRegistrationData&, WebCore::ShouldNotifyWhenResolved) final;
    void resolveUnregistrationJobInClient(WebCore::ServiceWorkerJobIdentifier, const WebCore::ServiceWorkerRegistrationKey&, bool registrationResult) final;
    void startScriptFetchInClient(WebCore::ServiceWorkerJobIdentifier, const WebCore::ServiceWorkerRegistrationKey&, WebCore::FetchOptions::Cache) final;

    Harness& m_harness;
    unsigned m_index;
    WebCore::ProcessIdentifier m_processIdentifier;
};

// The test's service worker process for one site: it starts, installs and activates workers and answers events.
class TestContextConnection final : public WebCore::SWServerToContextConnection {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(TestContextConnection);
public:
    static Ref<TestContextConnection> create(WebCore::SWServer& server, Harness& harness, const WebCore::Site& site, std::optional<WebCore::ScriptExecutionContextIdentifier> serviceWorkerPageIdentifier, WebCore::ProcessIdentifier process)
    {
        return adoptRef(*new TestContextConnection(server, harness, site, serviceWorkerPageIdentifier, process));
    }

    const String& domain() const { return m_domain; }
    WebCore::ProcessIdentifier webProcessIdentifier() const final { return m_process; }

private:
    TestContextConnection(WebCore::SWServer& server, Harness& harness, const WebCore::Site& site, std::optional<WebCore::ScriptExecutionContextIdentifier> serviceWorkerPageIdentifier, WebCore::ProcessIdentifier process)
        : WebCore::SWServerToContextConnection(server, WebCore::Site { site }, serviceWorkerPageIdentifier)
        , m_harness(harness)
        , m_domain(site.domain().string())
        , m_process(process)
    {
    }

    void installServiceWorkerContext(const WebCore::ServiceWorkerContextData&, const WebCore::ServiceWorkerData&, const String& userAgent, WebCore::WorkerThreadMode, OptionSet<WebCore::AdvancedPrivacyProtections>) final;
    void updateAppInitiatedValue(WebCore::ServiceWorkerIdentifier, WebCore::LastNavigationWasAppInitiated) final;
    void fireInstallEvent(WebCore::ServiceWorkerIdentifier) final;
    void fireActivateEvent(WebCore::ServiceWorkerIdentifier) final;
    void terminateWorker(WebCore::ServiceWorkerIdentifier) final;
    void didSaveScriptsToDisk(WebCore::ServiceWorkerIdentifier, const WebCore::ScriptBuffer&, const MemoryCompactRobinHoodHashMap<URL, WebCore::ScriptBuffer>&) final;
    void firePushEvent(WebCore::ServiceWorkerIdentifier, const std::optional<Vector<uint8_t>>&, std::optional<WebCore::NotificationPayload>&&, CompletionHandler<void(bool, std::optional<WebCore::NotificationPayload>&&)>&&) final;
    void fireNotificationEvent(WebCore::ServiceWorkerIdentifier, const WebCore::NotificationData&, WebCore::NotificationEventType, CompletionHandler<void(bool)>&&) final;
    void fireBackgroundFetchEvent(WebCore::ServiceWorkerIdentifier, const WebCore::BackgroundFetchInformation&, CompletionHandler<void(bool)>&&) final;
    void fireBackgroundFetchClickEvent(WebCore::ServiceWorkerIdentifier, const WebCore::BackgroundFetchInformation&, CompletionHandler<void(bool)>&&) final;
    void openWindow(WebCore::ServiceWorkerIdentifier, const URL&, OpenWindowCallback&&) final;
    void connectionIsNoLongerNeeded() final;
    void terminateDueToUnresponsiveness() final;
    void setInspectable(WebCore::ServiceWorkerIsInspectable) final;
#if ENABLE(CONTENT_EXTENSIONS)
    void reportNetworkUsageToWorkerClient(const WebCore::ScriptExecutionContextIdentifier, uint64_t) final { }
#endif

    Harness& m_harness;
    String m_domain;
    WebCore::ProcessIdentifier m_process;
};

class TestBackgroundFetchStore final : public WebCore::BackgroundFetchStore {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(TestBackgroundFetchStore);
public:
    static Ref<TestBackgroundFetchStore> create() { return adoptRef(*new TestBackgroundFetchStore); }

private:
    void initializeFetches(const WebCore::ServiceWorkerRegistrationKey&, CompletionHandler<void()>&& callback) final { callback(); }
    void clearFetch(const WebCore::ServiceWorkerRegistrationKey&, const String&, CompletionHandler<void()>&& callback) final { callback(); }
    void clearAllFetches(const WebCore::ServiceWorkerRegistrationKey&, CompletionHandler<void()>&& callback) final { callback(); }
    void storeFetch(const WebCore::ServiceWorkerRegistrationKey&, const String&, uint64_t, uint64_t, std::optional<size_t>, Vector<uint8_t>&&, CompletionHandler<void(StoreResult)>&& callback) final { callback(StoreResult::InternalError); }
    void storeFetchResponseBodyChunk(const WebCore::ServiceWorkerRegistrationKey&, const String&, size_t, const WebCore::SharedBuffer&, CompletionHandler<void(StoreResult)>&& callback) final { callback(StoreResult::InternalError); }
    void retrieveResponseBody(const WebCore::ServiceWorkerRegistrationKey&, const String&, size_t, RetrieveRecordResponseBodyCallback&& callback) final { callback(RefPtr<WebCore::SharedBuffer> { }); }
};

// The registration store, holding registrations a workload imports.
class TestRegistrationStore final : public WebCore::SWRegistrationStore {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(TestRegistrationStore);
public:
    static Ref<TestRegistrationStore> create(Harness& harness) { return adoptRef(*new TestRegistrationStore(harness)); }

    void add(WebCore::ServiceWorkerContextData&& data)
    {
        auto topOrigin = data.registration.key.topOrigin();
        m_origins.add(data.registration.key.clientOrigin());
        m_registrations.ensure(topOrigin, [] {
            return Vector<WebCore::ServiceWorkerContextData> { };
        }).iterator->value.append(WTF::move(data));
    }

    void failScriptRetrievalFor(const URL& scriptURL) { m_failingScripts.add(scriptURL.string()); }

private:
    explicit TestRegistrationStore(Harness& harness)
        : m_harness(harness)
    {
    }

    void clearAll(CompletionHandler<void()>&&) final;
    void flushChanges(CompletionHandler<void()>&&) final;
    void closeFiles(CompletionHandler<void()>&&) final;
    void importRegistrationsForOrigin(const WebCore::SecurityOriginData&, CompletionHandler<void(std::optional<Vector<WebCore::ServiceWorkerContextData>>&&)>&&) final;
    void importOriginList(CompletionHandler<void(std::optional<HashSet<WebCore::ClientOrigin>>&&)>&&) final;
    void updateRegistration(const WebCore::ServiceWorkerContextData&) final;
    void removeRegistration(const WebCore::ServiceWorkerRegistrationKey&) final;
    void retrieveWorkerScripts(WebCore::ServiceWorkerIdentifier, const WebCore::ServiceWorkerRegistrationKey&, const URL& scriptURL, const Vector<URL>& importedScriptURLs, CompletionHandler<void(std::optional<WebCore::ServiceWorkerScripts>&&)>&&) final;

    Harness& m_harness;
    HashSet<WebCore::ClientOrigin> m_origins;
    HashMap<WebCore::SecurityOriginData, Vector<WebCore::ServiceWorkerContextData>> m_registrations;
    HashSet<String> m_failingScripts;
};

class TestOriginStore final : public WebCore::SWOriginStore {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(TestOriginStore);
public:
    explicit TestOriginStore(Harness& harness)
        : m_harness(harness)
    {
    }

private:
    void importComplete() final;
    void addToStore(const WebCore::SecurityOriginData&) final;
    void removeFromStore(const WebCore::SecurityOriginData&) final;
    void clearStore() final;

    Harness& m_harness;
};

class TestDelegate final : public WebCore::SWServerDelegate, public CanMakeCheckedPtr<TestDelegate> {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(TestDelegate);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(TestDelegate);
public:
    explicit TestDelegate(Harness& harness)
        : m_harness(harness)
    {
    }

    OVERRIDE_ABSTRACT_CAN_MAKE_CHECKEDPTR(CanMakeCheckedPtr<TestDelegate>);

private:
    void softUpdate(WebCore::ServiceWorkerJobData&&, bool shouldRefreshCache, WebCore::ResourceRequest&&, CompletionHandler<void(WebCore::WorkerFetchResult&&)>&&) final;
    void createContextConnection(const WebCore::Site&, std::optional<WebCore::ProcessIdentifier>, std::optional<WebCore::ScriptExecutionContextIdentifier>, WebCore::CrossOriginEmbedderPolicyValue, CompletionHandler<void()>&&) final;
    void appBoundDomains(CompletionHandler<void(HashSet<WebCore::RegistrableDomain>&&)>&&) final;
    void addAllowedFirstPartyForCookies(WebCore::ProcessIdentifier, std::optional<WebCore::ProcessIdentifier>, WebCore::RegistrableDomain&&) final;
    void requestBackgroundFetchPermission(const WebCore::ClientOrigin&, CompletionHandler<void(bool)>&&) final;
    RefPtr<WebCore::BackgroundFetchRecordLoader> createBackgroundFetchRecordLoader(WebCore::BackgroundFetchRecordLoaderClient&, const WebCore::BackgroundFetchRequest&, size_t, const WebCore::ClientOrigin&) final { return nullptr; }
    Ref<WebCore::BackgroundFetchStore> createBackgroundFetchStore() final { return TestBackgroundFetchStore::create(); }
    RefPtr<WebCore::SWRegistrationStore> createRegistrationStore(WebCore::SWServer&) final;

    Harness& m_harness;
};

struct ServerOptions {
    bool hasServiceWorkerEntitlement { true };
    std::optional<unsigned> registrationCountLimit;
    Vector<String> appBoundDomains;
    bool hasStore { false };
    unsigned connectionCount { 1 };
    // The server terminates the workers it holds in a hash table keyed by worker identifier, so the order of its
    // terminateWorker() calls depends on the identifier values, which a process-global counter hands out and every
    // earlier pass advances. With this set, a settle() counts its terminations as a set: their sum and count go into
    // the digest when it returns, whatever order they came in.
    bool terminationsInAnyOrder { false };
};

// One server with its test objects, for one pass.
class Harness {
public:
    Harness(Digest& digest, ServerOptions&& options, NOESCAPE const Function<void(TestRegistrationStore&)>& fillStore = { })
        : m_digest(digest)
        , m_options(WTF::move(options))
        , m_delegate(makeUnique<TestDelegate>(*this))
    {
        WTF::initializeMainThread();
        // A timer an earlier pass left would fire into this one.
        if (unsigned leaked = pendingTimerCount())
            ADD_FAILURE() << leaked << " timers were left pending by an earlier server";
        if (m_options.hasStore) {
            m_store = TestRegistrationStore::create(*this);
            if (fillStore)
                fillStore(*m_store);
        }
        m_server = WebCore::SWServer::create(*m_delegate, adoptRef(*new TestOriginStore(*this)), true, String { }, PAL::SessionID::defaultSessionID(), false, m_options.hasServiceWorkerEntitlement, m_options.registrationCountLimit, WebCore::ServiceWorkerIsInspectable::No);
        for (unsigned i = 0; i < m_options.connectionCount; ++i)
            addConnection();
        settle();
    }

    ~Harness()
    {
        m_recording = false;
        m_timerDrain = nullptr;
        m_server->close();
        drainTimers();
        m_connections.clear();
        m_contextConnections.clear();
        m_retiredContextConnections.clear();
        m_server = nullptr;
        // What outlives the server (a worker kept by a pending event's timer) runs out here, not in the next pass.
        drainTimers();
        flushTerminations();
    }

    WebCore::SWServer& server() { return *m_server; }
    TestConnection& connection(unsigned index) { return m_connections[index].get(); }
    TestRegistrationStore* store() { return m_store.get(); }
    const ServerOptions& options() const { return m_options; }

    TestConnection& addConnection()
    {
        Ref connection = TestConnection::create(*m_server, *this, m_nextConnectionIndex++);
        m_connections.append(connection);
        m_server->addConnection(connection.copyRef());
        return m_connections.last().get();
    }

    void removeConnection(unsigned index)
    {
        m_server->removeConnection(m_connections[index]->processIdentifier());
    }

    // Recording.

    void record(Event event, std::initializer_list<uint64_t> words, StringView string = { })
    {
        if (!m_recording)
            return;
        Digest digest;
        digest.add(static_cast<uint64_t>(event));
        for (auto word : words)
            digest.add(word);
        digest.add(string);
        ++m_eventCount;
        if (event == Event::TerminateWorker && m_options.terminationsInAnyOrder) {
            m_terminationSum += digest.value() * 0x9e3779b97f4a7c15ull + 1;
            ++m_terminationCount;
            return;
        }
        if (m_unorderedDepth) {
            // Calls made while the server iterates one of its hash tables come in the table's order, which depends on
            // identifier values: they are summed, so their order does not count.
            m_unorderedSum += digest.value() * 0x9e3779b97f4a7c15ull + 1;
            ++m_unorderedCount;
            return;
        }
        flushUnordered();
        m_digest.add(digest.value());
    }

    template<typename Function>
    void unordered(NOESCAPE const Function& function)
    {
        ++m_unorderedDepth;
        function();
        --m_unorderedDepth;
    }

    void recordException(Event event, uint64_t subject, const WebCore::ExceptionData& exception)
    {
        record(event, { subject, static_cast<uint64_t>(exception.code) }, exception.message);
    }

    uint64_t scopeName(StringView scope) const { return hashString(scope); }

    uint64_t registrationName(WebCore::ServiceWorkerRegistrationIdentifier identifier) const
    {
        auto iterator = m_registrationScopes.find(identifier.toUInt64());
        return iterator == m_registrationScopes.end() ? 0 : hashString(iterator->value);
    }

    uint64_t registrationName(std::optional<WebCore::ServiceWorkerRegistrationIdentifier> identifier) const
    {
        return identifier ? registrationName(*identifier) : 0;
    }

    uint64_t workerName(WebCore::ServiceWorkerIdentifier identifier) const
    {
        auto iterator = m_workers.find(identifier.toUInt64());
        if (iterator == m_workers.end())
            return 0;
        return hashString(iterator->value.scope) * 31 + iterator->value.generation + 1;
    }

    uint64_t workerName(const std::optional<WebCore::ServiceWorkerData>& data) const
    {
        return data ? workerName(data->identifier) * 8 + static_cast<uint64_t>(data->state) : 0;
    }

    uint64_t clientName(const WebCore::ScriptExecutionContextIdentifier& identifier) const
    {
        auto iterator = m_clientIndices.find(identifier.object());
        uint64_t index = iterator == m_clientIndices.end() ? 0xffffffffull : iterator->value;
        return (index << 8) | (identifier.processIdentifier().toUInt64() & 0xff);
    }

    uint64_t jobName(WebCore::ServiceWorkerJobIdentifier identifier) const
    {
        auto iterator = m_jobs.find(identifier.toUInt64());
        return iterator == m_jobs.end() ? 0 : iterator->value.ordinal;
    }

    void learnRegistration(WebCore::ServiceWorkerRegistrationIdentifier identifier, const URL& scope)
    {
        m_registrationScopes.set(identifier.toUInt64(), scope.string());
        m_registrationsByScope.set(scope.string(), identifier);
    }

    std::optional<WebCore::ServiceWorkerRegistrationIdentifier> registrationForScope(const String& scope) const
    {
        auto iterator = m_registrationsByScope.find(scope);
        if (iterator == m_registrationsByScope.end())
            return std::nullopt;
        return iterator->value;
    }

    WebCore::SWServerWorker* activeWorker(const String& scope)
    {
        auto identifier = registrationForScope(scope);
        return identifier ? m_server->activeWorkerFromRegistrationID(*identifier) : nullptr;
    }

    std::optional<WebCore::ServiceWorkerIdentifier> activeWorkerIdentifier(const String& scope)
    {
        auto identifier = registrationForScope(scope);
        if (!identifier)
            return std::nullopt;
        auto* registration = m_server->getRegistration(*identifier);
        if (!registration)
            return std::nullopt;
        auto data = registration->data();
        if (!data.activeWorker)
            return std::nullopt;
        return data.activeWorker->identifier;
    }

    const WorkerInfo* worker(WebCore::ServiceWorkerIdentifier identifier) const
    {
        auto iterator = m_workers.find(identifier.toUInt64());
        return iterator == m_workers.end() ? nullptr : &iterator->value;
    }

    void learnWorker(const WebCore::ServiceWorkerContextData& data, const WebCore::ServiceWorkerData& workerData)
    {
        learnRegistration(data.registration.identifier, data.registration.scopeURL);
        auto scope = data.registration.scopeURL.string();
        m_workers.ensure(workerData.identifier.toUInt64(), [&] {
            unsigned generation = m_workerGenerations.add(scope, 0).iterator->value++;
            return WorkerInfo { scope, generation, data.jobDataIdentifier, data.registration.identifier };
        });
    }

    unsigned addClient(const WebCore::ScriptExecutionContextIdentifier& identifier)
    {
        return m_clientIndices.ensure(identifier.object(), [&] {
            return m_clientIndices.size();
        }).iterator->value;
    }

    ScopePlan& plan(const String& scope) { return m_plans.add(scope, ScopePlan { }).iterator->value; }
    ScopePlan planFor(const String& scope) const { return m_plans.get(scope); }

    // The test objects' replies, run in order.

    void enqueue(Function<void()>&& reply) { m_queue.append(WTF::move(reply)); }

    // Runs the queued replies and the server's timers until nothing more happens. After drainTimersInSettle(), it
    // then drains the timers that are not yet due as well (drainTimers()), in time the pass leaves out.
    void settle()
    {
        runUntilIdle();
        if (m_timerDrain) {
            m_timerDrain->measure([&] {
                drainTimers();
            });
        }
        flushTerminations();
    }

    void drainTimersInSettle(Excluded& excluded) { m_timerDrain = &excluded; }

    // Fires the pending timers now, earliest first, each followed by everything it causes, until none is left: the
    // server's 1 s to 10 s timers then fire at the same point of the workload whatever the time, instead of inside
    // whichever later settle() the clock reaches them in.
    void drainTimers()
    {
        runUntilIdle();
        for (unsigned fired = 0; auto* item = earliestPendingTimer(); ++fired) {
            if (fired == 10000) {
                ADD_FAILURE() << "The server's timers kept starting again";
                return;
            }
            item->timer().startOneShot(0_s);
            ++m_drainedTimers;
            runUntilIdle();
        }
    }

    // Capacities: completion handlers the server holds for the test at once, by kind.
    enum class Owed : uint8_t { Match, Run, Push };
    void owe(Owed kind)
    {
        auto& count = m_owed[static_cast<unsigned>(kind)];
        ++count;
        auto& max = m_maxOwed[static_cast<unsigned>(kind)];
        max = std::max(max, count);
    }
    void paid(Owed kind) { --m_owed[static_cast<unsigned>(kind)]; }
    String capacities() const
    {
        return makeString("handlersHeld(match,run,push)="_s, m_maxOwed[0], ',', m_maxOwed[1], ',', m_maxOwed[2], " timersDrained="_s, m_drainedTimers, " dueTimersFiredByHand="_s, m_kickedTimers);
    }

    void runUntilIdle()
    {
        unsigned idleSpins = 0;
        auto deadline = MonotonicTime::now() + 30_s;
        while (true) {
            if (!m_queue.isEmpty()) {
                auto reply = m_queue.takeFirst();
                reply();
                idleSpins = 0;
                continue;
            }
            auto events = m_eventCount;
            TestWebKitAPI::Util::spinRunLoop(1);
            if (!m_queue.isEmpty() || events != m_eventCount) {
                idleSpins = 0;
                continue;
            }
            if (hasDueTimer()) {
                // After an earlier server's timers were stopped, the thread's shared timer can stay unscheduled with a
                // timer due (the next server's job queue timer): fire it as its run loop would have.
                WebCore::TimerBase::fireTimersInNestedEventLoop();
                ++m_kickedTimers;
                idleSpins = 0;
                if (MonotonicTime::now() <= deadline)
                    continue;
            }
            if (++idleSpins >= 3)
                return;
            if (MonotonicTime::now() > deadline) {
                ADD_FAILURE() << "The server did not settle";
                return;
            }
        }
    }

    // Jobs, as a web process schedules them.

    WebCore::ServiceWorkerJobData makeJob(TestConnection& connection, WebCore::ServiceWorkerJobType type, const String& scope, const URL& scriptURL, const URL& clientURL, WebCore::ServiceWorkerUpdateViaCache updateViaCache = WebCore::ServiceWorkerUpdateViaCache::Imports)
    {
        auto jobIdentifier = WebCore::ServiceWorkerJobIdentifier::generate();
        m_jobs.add(jobIdentifier.toUInt64(), JobInfo { ++m_jobCount, scriptURL, scope });
        auto topOrigin = WebCore::SecurityOriginData::fromURL(clientURL);
        std::optional<WebCore::ServiceWorkerRegistrationOptions> registrationOptions;
        if (type == WebCore::ServiceWorkerJobType::Register)
            registrationOptions = WebCore::ServiceWorkerRegistrationOptions { scope, WebCore::WorkerType::Classic, updateViaCache };
        WebCore::ServiceWorkerOrClientIdentifier sourceContext = clientIdentifier(0xffff00 + connection.index(), connection.processIdentifier());
        return WebCore::ServiceWorkerJobData { WebCore::ServiceWorkerJobDataIdentifier { connection.processIdentifier(), jobIdentifier }, URL { scriptURL }, URL { clientURL }, WTF::move(topOrigin), URL { scope }, WTF::move(sourceContext), WebCore::WorkerType::Classic, type, false, false, WTF::move(registrationOptions) };
    }

    void scheduleRegister(TestConnection& connection, const String& scope, const URL& scriptURL, WebCore::ServiceWorkerUpdateViaCache updateViaCache = WebCore::ServiceWorkerUpdateViaCache::Imports)
    {
        m_server->scheduleJob(makeJob(connection, WebCore::ServiceWorkerJobType::Register, scope, scriptURL, URL { scope }, updateViaCache));
    }

    void scheduleUpdate(TestConnection& connection, const String& scope, const URL& scriptURL)
    {
        m_server->scheduleJob(makeJob(connection, WebCore::ServiceWorkerJobType::Update, scope, scriptURL, URL { scope }));
    }

    void scheduleUnregister(TestConnection& connection, const String& scope)
    {
        m_server->scheduleJob(makeJob(connection, WebCore::ServiceWorkerJobType::Unregister, scope, URL { }, URL { scope }));
    }

    const JobInfo* job(WebCore::ServiceWorkerJobIdentifier identifier) const
    {
        auto iterator = m_jobs.find(identifier.toUInt64());
        return iterator == m_jobs.end() ? nullptr : &iterator->value;
    }

    // Context connections, one per site.

    TestContextConnection& makeContextConnection(const WebCore::Site& site, std::optional<WebCore::ScriptExecutionContextIdentifier> serviceWorkerPageIdentifier)
    {
        auto domain = site.domain().string();
        Ref connection = TestContextConnection::create(*m_server, *this, site, serviceWorkerPageIdentifier, webProcessIdentifier(0x1000 + m_nextContextProcess++));
        if (auto previous = m_contextConnections.take(domain))
            m_retiredContextConnections.append(previous.releaseNonNull());
        m_contextConnections.set(domain, connection.copyRef());
        m_server->addContextConnection(connection.get());
        return *m_contextConnections.get(domain);
    }

    TestContextConnection* contextConnection(const String& domain) { return m_contextConnections.get(domain); }

    void recordContextConnection(const WebCore::SWServerToContextConnection* connection)
    {
        record(Event::RunWorkerResult, { connection ? hashString(static_cast<const TestContextConnection*>(connection)->domain()) : 0 });
    }

    const Vector<String>& appBoundDomains() const { return m_options.appBoundDomains; }

private:
    void flushTerminations()
    {
        if (!m_terminationCount)
            return;
        flushUnordered();
        m_digest.add(m_terminationSum);
        m_digest.add(m_terminationCount);
        m_terminationSum = 0;
        m_terminationCount = 0;
    }

    void flushUnordered()
    {
        if (!m_unorderedCount)
            return;
        m_digest.add(m_unorderedSum);
        m_digest.add(m_unorderedCount);
        m_unorderedSum = 0;
        m_unorderedCount = 0;
    }

    Digest& m_digest;
    ServerOptions m_options;
    std::unique_ptr<TestDelegate> m_delegate;
    RefPtr<TestRegistrationStore> m_store;
    RefPtr<WebCore::SWServer> m_server;
    Vector<Ref<TestConnection>> m_connections;
    HashMap<String, Ref<TestContextConnection>> m_contextConnections;
    Vector<Ref<TestContextConnection>> m_retiredContextConnections;
    Deque<Function<void()>> m_queue;
    HashMap<uint64_t, String> m_registrationScopes;
    HashMap<String, WebCore::ServiceWorkerRegistrationIdentifier> m_registrationsByScope;
    HashMap<uint64_t, WorkerInfo> m_workers;
    HashMap<String, unsigned> m_workerGenerations;
    HashMap<WTF::UUID, unsigned> m_clientIndices;
    HashMap<uint64_t, JobInfo> m_jobs;
    HashMap<String, ScopePlan> m_plans;
    unsigned m_jobCount { 0 };
    unsigned m_nextConnectionIndex { 1 };
    unsigned m_nextContextProcess { 0 };
    uint64_t m_eventCount { 0 };
    unsigned m_unorderedDepth { 0 };
    uint64_t m_unorderedSum { 0 };
    uint64_t m_unorderedCount { 0 };
    uint64_t m_terminationSum { 0 };
    uint64_t m_terminationCount { 0 };
    bool m_recording { true };
    Excluded* m_timerDrain { nullptr };
    uint64_t m_drainedTimers { 0 };
    uint64_t m_kickedTimers { 0 };
    std::array<unsigned, 3> m_owed { };
    std::array<unsigned, 3> m_maxOwed { };
};

static WebCore::WorkerFetchResult fetchResult(const URL& url, const String& body)
{
    return WebCore::WorkerFetchResult { WebCore::ScriptBuffer { body }, url, { }, { }, { }, { }, { } };
}

static WebCore::WorkerFetchResult fetchError(const URL& url)
{
    return WebCore::workerFetchError(WebCore::ResourceError { "WebKitSWServerBench"_s, 404, url, "Not Found"_s });
}

// TestConnection.

void TestConnection::updateRegistrationStateInClient(WebCore::ServiceWorkerRegistrationIdentifier identifier, WebCore::ServiceWorkerRegistrationState state, const std::optional<WebCore::ServiceWorkerData>& worker)
{
    m_harness.record(Event::RegistrationState, { m_index, m_harness.registrationName(identifier), static_cast<uint64_t>(state), m_harness.workerName(worker) });
}

void TestConnection::updateWorkerStateInClient(WebCore::ServiceWorkerIdentifier identifier, WebCore::ServiceWorkerState state)
{
    m_harness.record(Event::WorkerState, { m_index, m_harness.workerName(identifier), static_cast<uint64_t>(state) });
}

void TestConnection::fireUpdateFoundEvent(WebCore::ServiceWorkerRegistrationIdentifier identifier)
{
    m_harness.record(Event::UpdateFound, { m_index, m_harness.registrationName(identifier) });
}

void TestConnection::setRegistrationLastUpdateTime(WebCore::ServiceWorkerRegistrationIdentifier identifier, WallTime)
{
    m_harness.record(Event::LastUpdateTime, { m_index, m_harness.registrationName(identifier) });
}

void TestConnection::setRegistrationUpdateViaCache(WebCore::ServiceWorkerRegistrationIdentifier identifier, WebCore::ServiceWorkerUpdateViaCache updateViaCache)
{
    m_harness.record(Event::UpdateViaCache, { m_index, m_harness.registrationName(identifier), static_cast<uint64_t>(updateViaCache) });
}

void TestConnection::notifyClientsOfControllerChange(const HashSet<WebCore::ScriptExecutionContextIdentifier>& clients, const std::optional<WebCore::ServiceWorkerData>& newController)
{
    Vector<uint64_t> names;
    for (auto& client : clients)
        names.append(m_harness.clientName(client));
    std::ranges::sort(names);
    Digest digest;
    for (auto name : names)
        digest.add(name);
    m_harness.record(Event::ControllerChange, { m_index, names.size(), digest.value(), m_harness.workerName(newController) });
}

void TestConnection::postMessageToServiceWorkerClient(WebCore::ScriptExecutionContextIdentifier client, const WebCore::MessageWithMessagePorts&, WebCore::ServiceWorkerIdentifier source, const WebCore::SecurityOriginData& sourceOrigin, CompletionHandlerCallingScope&&)
{
    m_harness.record(Event::PostMessageToClient, { m_index, m_harness.clientName(client), m_harness.workerName(source) }, sourceOrigin.toString());
}

void TestConnection::focusServiceWorkerClient(WebCore::ScriptExecutionContextIdentifier client, CompletionHandler<void(std::optional<WebCore::ServiceWorkerClientData>&&)>&& callback)
{
    m_harness.record(Event::FocusClient, { m_index, m_harness.clientName(client) });
    m_harness.enqueue([callback = WTF::move(callback)] mutable {
        callback(std::nullopt);
    });
}

void TestConnection::updateBackgroundFetchRegistration(const WebCore::BackgroundFetchInformation&)
{
    m_harness.record(Event::BackgroundFetchUpdate, { m_index });
}

void TestConnection::contextConnectionCreated(WebCore::SWServerToContextConnection& connection)
{
    m_harness.record(Event::ContextConnectionCreated, { m_index, hashString(static_cast<TestContextConnection&>(connection).domain()) });
}

void TestConnection::rejectJobInClient(WebCore::ServiceWorkerJobIdentifier identifier, const WebCore::ExceptionData& exception)
{
    m_harness.recordException(Event::RejectJob, m_harness.jobName(identifier), exception);
}

void TestConnection::resolveRegistrationJobInClient(WebCore::ServiceWorkerJobIdentifier identifier, const WebCore::ServiceWorkerRegistrationData& data, WebCore::ShouldNotifyWhenResolved shouldNotify)
{
    m_harness.learnRegistration(data.identifier, data.scopeURL);
    m_harness.record(Event::ResolveRegistrationJob, { m_harness.jobName(identifier), m_harness.registrationName(data.identifier), static_cast<uint64_t>(shouldNotify), static_cast<uint64_t>(data.updateViaCache), m_harness.workerName(data.installingWorker), m_harness.workerName(data.waitingWorker), m_harness.workerName(data.activeWorker) }, data.scopeURL.string());
    m_harness.enqueue([protectedThis = Ref { *this }, registration = data.identifier, key = data.key, shouldNotify] {
        // The web process makes a ServiceWorkerRegistration object, which subscribes to the registration's updates.
        protectedThis->addRegistration(registration);
        if (shouldNotify == WebCore::ShouldNotifyWhenResolved::Yes)
            protectedThis->didResolveRegistrationPromise(key);
    });
}

void TestConnection::resolveUnregistrationJobInClient(WebCore::ServiceWorkerJobIdentifier identifier, const WebCore::ServiceWorkerRegistrationKey& key, bool registrationResult)
{
    m_harness.record(Event::ResolveUnregistrationJob, { m_harness.jobName(identifier), registrationResult }, key.scope().string());
}

void TestConnection::startScriptFetchInClient(WebCore::ServiceWorkerJobIdentifier identifier, const WebCore::ServiceWorkerRegistrationKey& key, WebCore::FetchOptions::Cache cache)
{
    m_harness.record(Event::StartScriptFetch, { m_harness.jobName(identifier), static_cast<uint64_t>(cache) });
    auto* job = m_harness.job(identifier);
    URL scriptURL = job ? job->scriptURL : URL { };
    auto scope = key.scope().string();
    auto plan = m_harness.planFor(scope);
    auto result = plan.outcome == Outcome::FetchError ? fetchError(scriptURL) : fetchResult(scriptURL, scriptBody(scope, plan.scriptVersion));
    m_harness.enqueue([protectedThis = Ref { *this }, jobDataIdentifier = WebCore::ServiceWorkerJobDataIdentifier { m_processIdentifier, identifier }, key, result = WTF::move(result)] mutable {
        protectedThis->finishFetchingScript(jobDataIdentifier, key, WTF::move(result));
    });
}

// TestContextConnection.

static Vector<WebCore::ServiceWorkerRoute> makeRoutes(unsigned count, unsigned variant);

void TestContextConnection::installServiceWorkerContext(const WebCore::ServiceWorkerContextData& data, const WebCore::ServiceWorkerData& workerData, const String& userAgent, WebCore::WorkerThreadMode, OptionSet<WebCore::AdvancedPrivacyProtections>)
{
    m_harness.learnWorker(data, workerData);
    auto scope = data.registration.scopeURL.string();
    m_harness.record(Event::InstallContext, { m_harness.workerName(workerData.identifier), !!data.jobDataIdentifier, data.loadedFromDisk, data.scriptResourceMap.size(), data.routes.size(), static_cast<uint64_t>(workerData.state) }, userAgent);
    auto plan = m_harness.planFor(scope);
    bool fails = data.jobDataIdentifier && plan.outcome == Outcome::StartFailure;
    m_harness.enqueue([protectedThis = Ref { *this }, jobDataIdentifier = data.jobDataIdentifier, worker = workerData.identifier, scope, plan, fails] {
        if (fails) {
            protectedThis->scriptContextFailedToStart(jobDataIdentifier, worker, "Bench: the script threw while starting"_s);
            return;
        }
        for (unsigned i = 0; i < plan.importedScriptCount; ++i) {
            auto url = importedScriptURL(scope, i);
            auto body = importedScriptBody(url.string(), plan.importedVersion);
            protectedThis->setScriptResource(worker, URL { url }, WebCore::ServiceWorkerContextData::ImportedScript { WebCore::ScriptBuffer { body }, url, "text/javascript"_s });
        }
        protectedThis->scriptContextStarted(jobDataIdentifier, worker, true);
    });
}

void TestContextConnection::updateAppInitiatedValue(WebCore::ServiceWorkerIdentifier identifier, WebCore::LastNavigationWasAppInitiated value)
{
    m_harness.record(Event::AppInitiated, { m_harness.workerName(identifier), static_cast<uint64_t>(value) });
}

void TestContextConnection::fireInstallEvent(WebCore::ServiceWorkerIdentifier identifier)
{
    m_harness.record(Event::FireInstall, { m_harness.workerName(identifier) });
    auto* worker = m_harness.worker(identifier);
    if (!worker)
        return;
    auto plan = m_harness.planFor(worker->scope);
    m_harness.enqueue([protectedThis = Ref { *this }, harness = &m_harness, identifier, jobDataIdentifier = worker->jobDataIdentifier, registration = worker->registrationIdentifier, plan] {
        if (plan.routeCount) {
            RefPtr server = protectedThis->server();
            server->addRoutes(registration, makeRoutes(plan.routeCount, plan.routeVariant), [harness, worker = harness->workerName(identifier)](std::expected<void, WebCore::ExceptionData>&& result) {
                if (result)
                    harness->record(Event::AddRoutesResult, { worker, 0 });
                else
                    harness->recordException(Event::AddRoutesResult, worker, result.error());
            });
        }
        protectedThis->didFinishInstall(jobDataIdentifier, identifier, plan.outcome != Outcome::InstallFailure);
    });
}

void TestContextConnection::fireActivateEvent(WebCore::ServiceWorkerIdentifier identifier)
{
    m_harness.record(Event::FireActivate, { m_harness.workerName(identifier) });
    m_harness.enqueue([protectedThis = Ref { *this }, identifier] {
        protectedThis->didFinishActivation(identifier);
    });
}

void TestContextConnection::terminateWorker(WebCore::ServiceWorkerIdentifier identifier)
{
    m_harness.record(Event::TerminateWorker, { m_harness.workerName(identifier) });
    m_harness.enqueue([protectedThis = Ref { *this }, identifier] {
        protectedThis->workerTerminated(identifier);
    });
}

void TestContextConnection::didSaveScriptsToDisk(WebCore::ServiceWorkerIdentifier identifier, const WebCore::ScriptBuffer&, const MemoryCompactRobinHoodHashMap<URL, WebCore::ScriptBuffer>& importedScripts)
{
    m_harness.record(Event::ScriptsSaved, { m_harness.workerName(identifier), importedScripts.size() });
}

void TestContextConnection::firePushEvent(WebCore::ServiceWorkerIdentifier identifier, const std::optional<Vector<uint8_t>>& data, std::optional<WebCore::NotificationPayload>&&, CompletionHandler<void(bool, std::optional<WebCore::NotificationPayload>&&)>&& callback)
{
    m_harness.record(Event::PushEvent, { m_harness.workerName(identifier), data ? data->size() : 0 });
    // The worker handles a push whose first byte is even.
    bool handled = data && !data->isEmpty() && !((*data)[0] & 1);
    m_harness.enqueue([callback = WTF::move(callback), handled] mutable {
        callback(handled, std::nullopt);
    });
}

void TestContextConnection::fireNotificationEvent(WebCore::ServiceWorkerIdentifier identifier, const WebCore::NotificationData&, WebCore::NotificationEventType type, CompletionHandler<void(bool)>&& callback)
{
    m_harness.record(Event::NotificationEvent, { m_harness.workerName(identifier), static_cast<uint64_t>(type) });
    m_harness.enqueue([callback = WTF::move(callback)] mutable {
        callback(true);
    });
}

void TestContextConnection::fireBackgroundFetchEvent(WebCore::ServiceWorkerIdentifier identifier, const WebCore::BackgroundFetchInformation&, CompletionHandler<void(bool)>&& callback)
{
    m_harness.record(Event::BackgroundFetchEvent, { m_harness.workerName(identifier), 0 });
    m_harness.enqueue([callback = WTF::move(callback)] mutable {
        callback(true);
    });
}

void TestContextConnection::fireBackgroundFetchClickEvent(WebCore::ServiceWorkerIdentifier identifier, const WebCore::BackgroundFetchInformation&, CompletionHandler<void(bool)>&& callback)
{
    m_harness.record(Event::BackgroundFetchEvent, { m_harness.workerName(identifier), 1 });
    m_harness.enqueue([callback = WTF::move(callback)] mutable {
        callback(true);
    });
}

void TestContextConnection::openWindow(WebCore::ServiceWorkerIdentifier identifier, const URL& url, OpenWindowCallback&& callback)
{
    m_harness.record(Event::OpenWindow, { m_harness.workerName(identifier) }, url.string());
    m_harness.enqueue([callback = WTF::move(callback)] mutable {
        callback(std::optional<WebCore::ServiceWorkerClientData> { });
    });
}

void TestContextConnection::connectionIsNoLongerNeeded()
{
    m_harness.record(Event::ContextConnectionNoLongerNeeded, { hashString(m_domain) });
}

void TestContextConnection::terminateDueToUnresponsiveness()
{
    m_harness.record(Event::Unresponsive, { hashString(m_domain) });
}

void TestContextConnection::setInspectable(WebCore::ServiceWorkerIsInspectable inspectable)
{
    m_harness.record(Event::Inspectable, { hashString(m_domain), static_cast<uint64_t>(inspectable) });
}

// TestRegistrationStore.

void TestRegistrationStore::clearAll(CompletionHandler<void()>&& callback)
{
    m_harness.record(Event::StoreClear, { 0 });
    m_registrations.clear();
    m_origins.clear();
    m_harness.enqueue(WTF::move(callback));
}

void TestRegistrationStore::flushChanges(CompletionHandler<void()>&& callback)
{
    m_harness.record(Event::StoreClear, { 1 });
    m_harness.enqueue(WTF::move(callback));
}

void TestRegistrationStore::closeFiles(CompletionHandler<void()>&& callback)
{
    m_harness.record(Event::StoreClear, { 2 });
    m_harness.enqueue(WTF::move(callback));
}

void TestRegistrationStore::importRegistrationsForOrigin(const WebCore::SecurityOriginData& topOrigin, CompletionHandler<void(std::optional<Vector<WebCore::ServiceWorkerContextData>>&&)>&& callback)
{
    auto registrations = m_registrations.take(topOrigin);
    m_harness.record(Event::StoreImportOrigin, { registrations.size() }, topOrigin.toString());
    m_harness.enqueue([callback = WTF::move(callback), registrations = WTF::move(registrations)] mutable {
        callback(WTF::move(registrations));
    });
}

void TestRegistrationStore::importOriginList(CompletionHandler<void(std::optional<HashSet<WebCore::ClientOrigin>>&&)>&& callback)
{
    m_harness.record(Event::StoreImportOriginList, { m_origins.size() });
    m_harness.enqueue([callback = WTF::move(callback), origins = m_origins] mutable {
        callback(WTF::move(origins));
    });
}

void TestRegistrationStore::updateRegistration(const WebCore::ServiceWorkerContextData& data)
{
    m_harness.record(Event::StoreUpdate, { data.script.buffer() ? data.script.buffer()->size() : 0, data.scriptResourceMap.size() }, data.registration.scopeURL.string());
}

void TestRegistrationStore::removeRegistration(const WebCore::ServiceWorkerRegistrationKey& key)
{
    m_harness.record(Event::StoreRemove, { }, key.scope().string());
}

void TestRegistrationStore::retrieveWorkerScripts(WebCore::ServiceWorkerIdentifier identifier, const WebCore::ServiceWorkerRegistrationKey& key, const URL& scriptURL, const Vector<URL>& importedScriptURLs, CompletionHandler<void(std::optional<WebCore::ServiceWorkerScripts>&&)>&& callback)
{
    bool fails = m_failingScripts.contains(scriptURL.string());
    m_harness.record(Event::StoreRetrieveScripts, { m_harness.workerName(identifier), importedScriptURLs.size(), fails }, scriptURL.string());
    std::optional<WebCore::ServiceWorkerScripts> scripts;
    if (!fails)
        scripts = WebCore::ServiceWorkerScripts { identifier, WebCore::ScriptBuffer { scriptBody(key.scope().string(), 0) }, { } };
    m_harness.enqueue([callback = WTF::move(callback), scripts = WTF::move(scripts)] mutable {
        callback(WTF::move(scripts));
    });
}

// TestOriginStore.

void TestOriginStore::importComplete()
{
    m_harness.record(Event::OriginStoreImportComplete, { });
}

void TestOriginStore::addToStore(const WebCore::SecurityOriginData& origin)
{
    m_harness.record(Event::OriginStoreAdd, { }, origin.toString());
}

void TestOriginStore::removeFromStore(const WebCore::SecurityOriginData& origin)
{
    m_harness.record(Event::OriginStoreRemove, { }, origin.toString());
}

void TestOriginStore::clearStore()
{
    m_harness.record(Event::OriginStoreClear, { });
}

// TestDelegate.

void TestDelegate::softUpdate(WebCore::ServiceWorkerJobData&& jobData, bool shouldRefreshCache, WebCore::ResourceRequest&& request, CompletionHandler<void(WebCore::WorkerFetchResult&&)>&& callback)
{
    auto url = request.url();
    auto scope = jobData.scopeURL.string();
    m_harness.record(Event::SoftUpdateFetch, { m_harness.jobName(jobData.identifier().jobIdentifier), shouldRefreshCache }, url.string());
    auto plan = m_harness.planFor(scope);
    bool isMainScript = url == jobData.scriptURL;
    auto result = plan.outcome == Outcome::FetchError ? fetchError(url) : fetchResult(url, isMainScript ? scriptBody(scope, plan.scriptVersion) : importedScriptBody(url.string(), plan.importedVersion));
    m_harness.enqueue([callback = WTF::move(callback), result = WTF::move(result)] mutable {
        callback(WTF::move(result));
    });
}

void TestDelegate::createContextConnection(const WebCore::Site& site, std::optional<WebCore::ProcessIdentifier> requestingProcess, std::optional<WebCore::ScriptExecutionContextIdentifier> serviceWorkerPageIdentifier, WebCore::CrossOriginEmbedderPolicyValue coep, CompletionHandler<void()>&& completionHandler)
{
    m_harness.record(Event::CreateContextConnection, { requestingProcess ? requestingProcess->toUInt64() : 0, static_cast<uint64_t>(coep) }, site.domain().string());
    m_harness.enqueue([harness = &m_harness, site = WebCore::Site { site }, serviceWorkerPageIdentifier, completionHandler = WTF::move(completionHandler)] mutable {
        harness->makeContextConnection(site, serviceWorkerPageIdentifier);
        completionHandler();
    });
}

void TestDelegate::appBoundDomains(CompletionHandler<void(HashSet<WebCore::RegistrableDomain>&&)>&& callback)
{
    m_harness.record(Event::AppBoundDomains, { m_harness.appBoundDomains().size() });
    HashSet<WebCore::RegistrableDomain> domains;
    for (auto& domain : m_harness.appBoundDomains())
        domains.add(WebCore::RegistrableDomain::uncheckedCreateFromRegistrableDomainString(domain));
    m_harness.enqueue([callback = WTF::move(callback), domains = WTF::move(domains)] mutable {
        callback(WTF::move(domains));
    });
}

void TestDelegate::addAllowedFirstPartyForCookies(WebCore::ProcessIdentifier, std::optional<WebCore::ProcessIdentifier> requestingProcess, WebCore::RegistrableDomain&& domain)
{
    m_harness.record(Event::AllowFirstParty, { requestingProcess ? requestingProcess->toUInt64() : 0 }, domain.string());
}

void TestDelegate::requestBackgroundFetchPermission(const WebCore::ClientOrigin& origin, CompletionHandler<void(bool)>&& callback)
{
    m_harness.record(Event::BackgroundFetchPermission, { }, origin.topOrigin.toString());
    m_harness.enqueue([callback = WTF::move(callback)] mutable {
        callback(false);
    });
}

RefPtr<WebCore::SWRegistrationStore> TestDelegate::createRegistrationStore(WebCore::SWServer&)
{
    return m_harness.store();
}

// Inputs.

static String siteOrigin(unsigned site)
{
    return makeString("https://site"_s, site, ".example"_s);
}

static String siteDomain(unsigned site)
{
    return makeString("site"_s, site, ".example"_s);
}

// Scope `index` of a site: half are top-level paths, half nest inside the previous one, so the longest match matters.
static String scopeURL(unsigned site, unsigned index)
{
    if (index % 2)
        return makeString(siteOrigin(site), "/app"_s, index - 1, "/section"_s, index, '/');
    return makeString(siteOrigin(site), "/app"_s, index, '/');
}

static URL scriptURLForScope(StringView scope)
{
    return URL { makeString(scope, "sw.js"_s) };
}

static size_t registrationBytes(StringView scope)
{
    return scope.length() * 3 + scriptBody(scope, 0).length();
}

// Registers every scope given and runs the server until each is activated (or failed, as its plan says).
static size_t registerScopes(Harness& harness, const Vector<String>& scopes, unsigned connectionIndex = 0)
{
    size_t bytes = 0;
    for (auto& scope : scopes) {
        harness.scheduleRegister(harness.connection(connectionIndex), scope, scriptURLForScope(scope));
        bytes += registrationBytes(scope);
    }
    harness.settle();
    return bytes;
}

static Vector<String> siteScopes(unsigned sites, unsigned scopesPerSite, unsigned firstSite = 0)
{
    Vector<String> scopes;
    for (unsigned site = firstSite; site < firstSite + sites; ++site) {
        for (unsigned index = 0; index < scopesPerSite; ++index)
            scopes.append(scopeURL(site, index));
    }
    return scopes;
}

static WebCore::ServiceWorkerRoutePattern pathPattern(String&& pathname)
{
    WebCore::ServiceWorkerRoutePattern pattern;
    pattern.pathname = WTF::move(pathname);
    return pattern;
}

static WebCore::RouterSource routeSource(unsigned index)
{
    switch (index % 5) {
    case 0:
        return WebCore::RouterSourceEnum::Network;
    case 1:
        return WebCore::RouterSourceEnum::Cache;
    case 2:
        return WebCore::RouterSourceEnum::FetchEvent;
    case 3:
        return WebCore::RouterSourceEnum::RaceNetworkAndFetchHandler;
    default:
        return WebCore::RouterSourceDict { makeString("cache"_s, index) };
    }
}

// `count` routes of every condition kind: URL patterns on the path, host and query, methods, modes, destinations,
// running status, and "or" and "not" conditions. Variant 1 adds the invalid routes the error workload sends.
static Vector<WebCore::ServiceWorkerRoute> makeRoutes(unsigned count, unsigned variant)
{
    Vector<WebCore::ServiceWorkerRoute> routes;
    for (unsigned i = 0; i < count; ++i) {
        WebCore::ServiceWorkerRouteCondition condition;
        switch (i % 8) {
        case 0:
            condition.urlPattern = pathPattern(makeString("/api/v"_s, i, "/*"_s));
            break;
        case 1:
            condition.urlPattern = pathPattern(makeString("/static/"_s, i, "/*.js"_s));
            condition.requestDestination = WebCore::FetchOptions::Destination::Script;
            break;
        case 2: {
            WebCore::ServiceWorkerRoutePattern pattern;
            pattern.hostname = makeString("cdn"_s, i, ".example"_s);
            pattern.pathname = "/assets/:name"_s;
            condition.urlPattern = WTF::move(pattern);
            break;
        }
        case 3:
            condition.requestMethod = (i % 16 == 3) ? "post"_s : "PUT"_s;
            break;
        case 4:
            condition.requestMode = WebCore::FetchOptions::Mode::Navigate;
            condition.runningStatus = (i % 16 == 4) ? WebCore::RunningStatus::Running : WebCore::RunningStatus::NotRunning;
            break;
        case 5: {
            WebCore::ServiceWorkerRouteCondition first;
            first.urlPattern = pathPattern(makeString("/images/"_s, i, "/*"_s));
            WebCore::ServiceWorkerRouteCondition second;
            second.requestDestination = WebCore::FetchOptions::Destination::Image;
            second.requestMode = WebCore::FetchOptions::Mode::Cors;
            condition.orConditions.append(WTF::move(first));
            condition.orConditions.append(WTF::move(second));
            break;
        }
        case 6: {
            auto inner = makeUnique<WebCore::ServiceWorkerRouteCondition>();
            inner->urlPattern = pathPattern("/app*"_s);
            condition.notCondition = WTF::move(inner);
            condition.requestDestination = WebCore::FetchOptions::Destination::Style;
            break;
        }
        default: {
            WebCore::ServiceWorkerRoutePattern pattern = pathPattern(makeString("/search/"_s, i));
            pattern.search = "q=*"_s;
            pattern.shouldIgnoreCase = true;
            condition.urlPattern = WTF::move(pattern);
            break;
        }
        }
        routes.append(WebCore::ServiceWorkerRoute { WTF::move(condition), variant == 6 ? WebCore::RouterSource { WebCore::RouterSourceDict { makeString("route"_s, i) } } : routeSource(i) });
    }
    if (variant == 1) {
        // A regular expression group, which the server's patterns do not support.
        WebCore::ServiceWorkerRouteCondition regexp;
        regexp.urlPattern = pathPattern("/item/(\\d+)"_s);
        routes.append(WebCore::ServiceWorkerRoute { WTF::move(regexp), WebCore::RouterSourceEnum::Network });
    } else if (variant == 2) {
        WebCore::ServiceWorkerRouteCondition forbidden;
        forbidden.requestMethod = "CONNECT"_s;
        routes.append(WebCore::ServiceWorkerRoute { WTF::move(forbidden), WebCore::RouterSourceEnum::Network });
    } else if (variant == 3) {
        WebCore::ServiceWorkerRouteCondition invalid;
        invalid.requestMethod = "BAD METHOD"_s;
        routes.append(WebCore::ServiceWorkerRoute { WTF::move(invalid), WebCore::RouterSourceEnum::Network });
    } else if (variant == 4) {
        // Nested deeper than the router's limit of 10.
        WebCore::ServiceWorkerRouteCondition deep;
        deep.requestMethod = "GET"_s;
        for (unsigned depth = 0; depth < 12; ++depth) {
            WebCore::ServiceWorkerRouteCondition outer;
            outer.notCondition = makeUnique<WebCore::ServiceWorkerRouteCondition>(WTF::move(deep));
            deep = WTF::move(outer);
        }
        routes.append(WebCore::ServiceWorkerRoute { WTF::move(deep), WebCore::RouterSourceEnum::Network });
    } else if (variant == 5) {
        // More conditions than the router's limit of 1024.
        for (unsigned i = 0; i < 1100; ++i) {
            WebCore::ServiceWorkerRouteCondition condition;
            condition.requestMethod = "GET"_s;
            routes.append(WebCore::ServiceWorkerRoute { WTF::move(condition), WebCore::RouterSourceEnum::Network });
        }
    }
    return routes;
}

static uint64_t routeSourceName(const std::optional<WebCore::RouterSource>& source)
{
    if (!source)
        return 0;
    return WTF::switchOn(*source, [](const WebCore::RouterSourceDict& dict) -> uint64_t {
        return hashString(dict.cacheName);
    }, [](WebCore::RouterSourceEnum value) -> uint64_t {
        return static_cast<uint64_t>(value) + 1;
    });
}

struct RouteRequest {
    WebCore::FetchOptions options;
    WebCore::ResourceRequest request;
};

static Vector<RouteRequest> makeRouteRequests(unsigned count, const String& origin, size_t& bytes)
{
    static constexpr std::array methods { "GET"_s, "GET"_s, "GET"_s, "POST"_s, "PUT"_s, "HEAD"_s };
    static constexpr std::array destinations { WebCore::FetchOptions::Destination::EmptyString, WebCore::FetchOptions::Destination::Script, WebCore::FetchOptions::Destination::Image, WebCore::FetchOptions::Destination::Style, WebCore::FetchOptions::Destination::Document, WebCore::FetchOptions::Destination::Font };
    static constexpr std::array modes { WebCore::FetchOptions::Mode::NoCors, WebCore::FetchOptions::Mode::Cors, WebCore::FetchOptions::Mode::SameOrigin, WebCore::FetchOptions::Mode::Navigate };
    Generator generator(0x5357);
    Vector<RouteRequest> requests;
    for (unsigned i = 0; i < count; ++i) {
        unsigned route = generator.below(72);
        String url;
        switch (generator.below(8)) {
        case 0:
            url = makeString(origin, "/api/v"_s, route, "/items/"_s, i);
            break;
        case 1:
            url = makeString(origin, "/static/"_s, route, "/bundle"_s, i % 7, ".js"_s);
            break;
        case 2:
            url = makeString("https://cdn"_s, route, ".example/assets/photo"_s, i % 13, ".png"_s);
            break;
        case 3:
            url = makeString(origin, "/images/"_s, route, "/thumb.jpg"_s);
            break;
        case 4:
            url = makeString(origin, "/SEARCH/"_s, route, "?q="_s, i % 101);
            break;
        case 5:
            url = makeString(origin, "/app/page"_s, i % 31, ".html"_s);
            break;
        default:
            url = makeString(origin, "/content/"_s, i % 97, "/article.html"_s);
            break;
        }
        WebCore::ResourceRequest request { URL { url } };
        request.setHTTPMethod(methods[generator.below(methods.size())]);
        WebCore::FetchOptions options;
        options.destination = destinations[generator.below(destinations.size())];
        options.mode = modes[generator.below(modes.size())];
        bytes += url.length();
        requests.append(RouteRequest { WTF::move(options), WTF::move(request) });
    }
    return requests;
}

static WebCore::ServiceWorkerClientData makeClient(const WebCore::ScriptExecutionContextIdentifier& identifier, const URL& url, bool focused)
{
    return WebCore::ServiceWorkerClientData { identifier, WebCore::ServiceWorkerClientType::Window, WebCore::ServiceWorkerClientFrameType::TopLevel, url, { }, std::nullopt, std::nullopt, WebCore::LastNavigationWasAppInitiated::Yes, { }, true, focused, 0, { }, std::nullopt };
}

static WebCore::ClientOrigin clientOriginFor(const URL& url)
{
    auto origin = WebCore::SecurityOriginData::fromURL(url);
    return WebCore::ClientOrigin { origin, origin };
}

static void recordLookup(Harness& harness, HashMap<WebCore::SWServerRegistration*, uint64_t>& names, WebCore::SWServerRegistration* registration)
{
    uint64_t name = 0;
    if (registration) {
        name = names.ensure(registration, [&] {
            return harness.scopeName(registration->data().scopeURL.string());
        }).iterator->value;
    }
    harness.record(Event::LookupResult, { name });
}

static void recordRegistrationData(Harness& harness, Event event, const std::optional<WebCore::ServiceWorkerRegistrationData>& data)
{
    if (!data) {
        harness.record(event, { 0 });
        return;
    }
    harness.record(event, { harness.registrationName(data->identifier), harness.workerName(data->activeWorker), harness.workerName(data->waitingWorker), harness.workerName(data->installingWorker) }, data->scopeURL.string());
}

// The workloads. Each returns the bytes its timed part carried, and may leave a line of capacities for
// run() to print.

// The count a workload uses: its benchmark size, or in a build with assertions, where the server runs many times
// slower, a smaller one.
static constexpr unsigned workloadSize(unsigned benchmarkCount, unsigned assertionsCount)
{
#if ASSERT_ENABLED
    UNUSED_PARAM(benchmarkCount);
    return assertionsCount;
#else
    UNUSED_PARAM(assertionsCount);
    return benchmarkCount;
#endif
}

// Imports the registrations of the first `sites` sites' origins, as a navigation's first match does, so that a
// workload's synchronous lookups for those top origins can follow (the server asserts the import came first).
static void importSiteOrigins(WebCore::SWServer& server, unsigned sites)
{
    for (unsigned site = 0; site < sites; ++site) {
        auto origin = siteOrigin(site);
        server.getRegistrations(WebCore::SecurityOriginData::fromURL(URL { origin }), URL { makeString(origin, "/"_s) }, [](Vector<WebCore::ServiceWorkerRegistrationData>&&) { });
    }
}

// Registers scopes a site's 20 at a time, each step settled (its timers drained, after drainTimersInSettle()) before
// the next: one settle() of a large workload's scopes can last long enough to reach the server's 1 s to 10 s timers
// inside it, at points that vary run to run.
static size_t registerScopesInSteps(Harness& harness, const Vector<String>& scopes)
{
    size_t bytes = 0;
    for (size_t start = 0; start < scopes.size(); start += 20)
        bytes += registerScopes(harness, scopes.subvector(start, std::min<size_t>(20, scopes.size() - start)));
    return bytes;
}

// Registers a large workload's scopes: with assertions, where one settle() of them all always reaches the server's
// timers, in steps.
static size_t registerWorkloadScopes(Harness& harness, const Vector<String>& scopes)
{
#if ASSERT_ENABLED
    return registerScopesInSteps(harness, scopes);
#else
    return registerScopes(harness, scopes);
#endif
}

static String& capacitiesOfPass()
{
    static NeverDestroyed<String> capacities;
    return capacities;
}

// 1,000 registrations over 50 sites, each through its script fetch, start, install and activation. With assertions,
// a pass is slow enough to reach the server's terminate-if-possible timers inside it, at points that vary run to run:
// the scopes are registered in steps, the timers drained in each step's settle(), and the terminations they cause
// counted in any order.
static size_t registerInstallActivate(Digest& digest, Excluded& excluded)
{
    std::optional<Harness> harness;
#if ASSERT_ENABLED
    harness.emplace(digest, ServerOptions { .terminationsInAnyOrder = true });
    harness->drainTimersInSettle(excluded);
#else
    harness.emplace(digest, ServerOptions { });
#endif
    auto bytes = registerWorkloadScopes(*harness, siteScopes(50, 20));
    excluded.measure([&] {
        capacitiesOfPass() = harness->capacities();
        harness = std::nullopt;
    });
    return bytes;
}

// 100,000 lookups over 1,000 scopes: the per-navigation match, longest scope first, with misses and third-party
// top origins. The set-up registers the scopes in steps with their timers drained in every build: on a loaded machine
// a Release set-up too reaches the workers' 2 s terminate-if-possible timers inside it.
static size_t matchRegistration(Digest& digest, Excluded& excluded)
{
    std::optional<Harness> harness;
    excluded.measure([&] {
        harness.emplace(digest, ServerOptions { .terminationsInAnyOrder = true });
        harness->drainTimersInSettle(excluded);
        registerScopesInSteps(*harness, siteScopes(50, 20));
        importSiteOrigins(harness->server(), 60);
    });
    Vector<std::pair<WebCore::SecurityOriginData, URL>> lookups;
    size_t bytes = 0;
    excluded.measure([&] {
        Generator generator(0x4d61);
        for (unsigned i = 0; i < workloadSize(100000, 5000); ++i) {
            unsigned site = generator.below(52);
            unsigned scope = generator.below(22);
            String url;
            if (scope >= 20)
                url = makeString(siteOrigin(site), "/other/page"_s, i % 17, ".html"_s);
            else
                url = makeString(scopeURL(site, scope), (i % 3) ? "page.html?id="_s : "nested/deeper/index.html#"_s, i % 1000);
            unsigned topSite = generator.oneIn(8) ? generator.below(60) : site;
            bytes += url.length();
            lookups.append({ WebCore::SecurityOriginData::fromURL(URL { siteOrigin(topSite) }), URL { url } });
        }
    });
    HashMap<WebCore::SWServerRegistration*, uint64_t> names;
    auto& server = harness->server();
    unsigned index = 0;
    for (auto& [topOrigin, url] : lookups) {
        if (!(++index % 16)) {
            harness->owe(Harness::Owed::Match);
            harness->connection(0).doRegistrationMatching(topOrigin, url, [&](std::optional<WebCore::ServiceWorkerRegistrationData>&& data) {
                harness->paid(Harness::Owed::Match);
                harness->record(Event::MatchResult, { data ? harness->scopeName(data->scopeURL.string()) : 0 });
            });
            continue;
        }
        RefPtr registration = server.doRegistrationMatchingSync(topOrigin, url);
        recordLookup(*harness, names, registration.get());
    }
    excluded.measure([&] {
        // The length of the server's scope map and the scopes per origin, which the match walks per lookup.
        unsigned total = 0;
        unsigned perOrigin = 0;
        for (unsigned site = 0; site < 60; ++site) {
            auto origin = siteOrigin(site);
            server.getRegistrations(WebCore::SecurityOriginData::fromURL(URL { origin }), URL { makeString(origin, "/"_s) }, [&](Vector<WebCore::ServiceWorkerRegistrationData>&& registrations) {
                total += registrations.size();
                perOrigin = std::max<unsigned>(perOrigin, registrations.size());
            });
        }
        harness->settle();
        capacitiesOfPass() = makeString(harness->capacities(), " scopeMap="_s, total, " scopesPerOrigin="_s, perOrigin, " lookups="_s, lookups.size());
        harness = std::nullopt;
    });
    return bytes;
}

// 100,000 requests against a worker's 64 routes: the per-fetch router.

// A route's shape as the router walks it: its condition nodes, its depth, and the URL patterns the router compiles
// when it tries the route (every one under an "or", so for the route that matches, a bound).
struct RouteShape {
    unsigned conditions { 1 };
    unsigned depth { 1 };
    unsigned compiles { 0 };
};

static RouteShape routeShape(const WebCore::ServiceWorkerRouteCondition& condition)
{
    RouteShape shape;
    auto addChild = [&](const WebCore::ServiceWorkerRouteCondition& child) {
        auto childShape = routeShape(child);
        shape.conditions += childShape.conditions;
        shape.depth = std::max(shape.depth, childShape.depth + 1);
        shape.compiles += childShape.compiles;
    };
    for (auto& child : condition.orConditions)
        addChild(child);
    if (condition.notCondition)
        addChild(*condition.notCondition);
    if (condition.orConditions.isEmpty() && !condition.notCondition && condition.urlPattern)
        shape.compiles = 1;
    return shape;
}

// The same 64 conditions with a source naming each route, so the route each request matches is known: the URL pattern
// compiles per request are those of the routes tried up to it.
static String routeCapacities(const String& scope, const Vector<RouteRequest>& requests)
{
    Digest scratch;
    Harness harness(scratch, ServerOptions { });
    auto& plan = harness.plan(scope);
    plan.routeCount = 64;
    plan.routeVariant = 6;
    registerScopes(harness, { scope });
    auto* worker = harness.activeWorker(scope);
    if (!worker)
        return " routes=?"_s;
    auto routes = makeRoutes(64, 6);
    Vector<unsigned> compilesBefore { 0 };
    unsigned conditions = 0;
    unsigned depth = 0;
    for (auto& route : routes) {
        auto shape = routeShape(route.condition);
        compilesBefore.append(compilesBefore.last() + shape.compiles);
        conditions += shape.conditions;
        depth = std::max(depth, shape.depth);
    }
    uint64_t compiles = 0;
    unsigned maxCompiles = 0;
    unsigned matched = 0;
    for (auto& request : requests) {
        size_t tried = routes.size();
        if (auto source = worker->getRouterSource(request.options.mode, request.options.destination, request.request.url(), request.request.httpMethod())) {
            if (auto* dict = std::get_if<WebCore::RouterSourceDict>(&*source)) {
                tried = parseInteger<unsigned>(StringView { dict->cacheName }.substring(5)).value_or(routes.size() - 1) + 1;
                ++matched;
            }
        }
        compiles += compilesBefore[tried];
        maxCompiles = std::max(maxCompiles, compilesBefore[tried]);
    }
    return makeString(" routes="_s, routes.size(), " conditions="_s, conditions, " depth="_s, depth, " requestsMatched="_s, matched, '/', requests.size(), " urlPatternCompilesPerMatch(mean,max)="_s, static_cast<double>(compiles) / requests.size(), ',', maxCompiles);
}

static size_t routeMatch(Digest& digest, Excluded& excluded)
{
    std::optional<Harness> harness;
    String scope = scopeURL(0, 0);
    Vector<RouteRequest> requests;
    size_t bytes = 0;
    excluded.measure([&] {
        harness.emplace(digest, ServerOptions { });
        harness->plan(scope).routeCount = 64;
        registerScopes(*harness, { scope });
        requests = makeRouteRequests(workloadSize(100000, 5000), siteOrigin(0), bytes);
    });
    auto* worker = harness->activeWorker(scope);
    EXPECT_NE(worker, nullptr);
    if (!worker) {
        auto identifier = harness->registrationForScope(scope);
        auto* registration = identifier ? harness->server().getRegistration(*identifier) : nullptr;
        auto data = registration ? std::optional { registration->data() } : std::nullopt;
        ADD_FAILURE() << "RouteMatch: registration known " << !!identifier << ", in the server " << !!registration << ", installing " << (data && data->installingWorker) << ", waiting " << (data && data->waitingWorker) << ", active " << (data && data->activeWorker) << ", pending timers " << pendingTimerCount();
        return bytes;
    }
    for (auto& request : requests) {
        auto source = worker->getRouterSource(request.options.mode, request.options.destination, request.request.url(), request.request.httpMethod());
        harness->record(Event::RouteResult, { routeSourceName(source) });
    }
    excluded.measure([&] {
        auto capacities = harness->capacities();
        harness = std::nullopt;
        if (capacitiesOfPass().isNull())
            capacitiesOfPass() = makeString(capacities, routeCapacities(scope, requests));
    });
    return bytes;
}

// 10,000 client registrations and unregistrations over 16 registrations, controlled and not, with updates of a
// registered client, a process swap, and claims and matchAll from the workers.
static size_t clientChurn(Digest& digest, Excluded& excluded)
{
    std::optional<Harness> harness;
    auto scopes = siteScopes(4, 4);
    excluded.measure([&] {
        harness.emplace(digest, ServerOptions { .connectionCount = 2 });
        registerScopes(*harness, scopes);
        importSiteOrigins(harness->server(), 5);
    });
    auto& server = harness->server();
    struct LiveClient {
        WebCore::ClientOrigin origin;
        WebCore::ScriptExecutionContextIdentifier identifier;
    };
    Deque<LiveClient> live;
    size_t bytes = 0;
    Generator generator(0x436c);
    for (unsigned i = 0; i < workloadSize(10000, 1000); ++i) {
        unsigned site = generator.below(5);
        unsigned scopeIndex = generator.below(5);
        URL url { scopeIndex < 4 ? makeString(scopeURL(site, scopeIndex), "client"_s, i, ".html"_s) : makeString(siteOrigin(site), "/elsewhere/"_s, i) };
        bytes += url.string().length();
        auto& connection = harness->connection(i % 2);
        auto identifier = clientIdentifier(i, connection.processIdentifier());
        harness->addClient(identifier);
        auto origin = clientOriginFor(url);
        std::optional<WebCore::ServiceWorkerRegistrationIdentifier> controller;
        if (RefPtr registration = server.doRegistrationMatchingSync(origin.topOrigin, url); registration && !generator.oneIn(4))
            controller = harness->registrationForScope(registration->data().scopeURL.string());
        server.registerServiceWorkerClient(WebCore::ClientOrigin { origin }, makeClient(identifier, url, !(i % 5)), controller, "BenchAgent/1.0"_s, WebCore::SWServer::IsBeingCreatedClient::No);
        live.append({ origin, identifier });

        if (!(i % 97)) {
            // The same client again, from the same process: its data is updated in place.
            server.registerServiceWorkerClient(WebCore::ClientOrigin { origin }, makeClient(identifier, url, true), controller, "BenchAgent/1.0"_s, WebCore::SWServer::IsBeingCreatedClient::No);
        }
        if (!(i % 211)) {
            // The same client from the other process: a process swap.
            auto swapped = WebCore::ScriptExecutionContextIdentifier { identifier.object(), harness->connection((i + 1) % 2).processIdentifier() };
            server.registerServiceWorkerClient(WebCore::ClientOrigin { origin }, makeClient(swapped, url, false), std::nullopt, "BenchAgent/1.0"_s, WebCore::SWServer::IsBeingCreatedClient::Yes);
            live.last().identifier = swapped;
        }
        if (!(i % 500)) {
            auto& scope = scopes[(i / 500) % scopes.size()];
            if (auto workerIdentifier = harness->activeWorkerIdentifier(scope)) {
                auto* contextConnection = harness->contextConnection(WebCore::RegistrableDomain { URL { scope } }.string());
                if (contextConnection) {
                    auto workerName = harness->workerName(*workerIdentifier);
                    contextConnection->claim(*workerIdentifier, [&](std::optional<WebCore::ExceptionData>&& exception) {
                        if (exception)
                            harness->recordException(Event::ClaimResult, workerName, *exception);
                        else
                            harness->record(Event::ClaimResult, { workerName, 0 });
                    });
                    contextConnection->matchAll(*workerIdentifier, WebCore::ServiceWorkerClientQueryOptions { !!(i % 1000), WebCore::ServiceWorkerClientType::Window }, [&](Vector<WebCore::ServiceWorkerClientData>&& clients) {
                        Vector<uint64_t> names;
                        for (auto& client : clients)
                            names.append(harness->clientName(client.identifier));
                        std::ranges::sort(names);
                        Digest namesDigest;
                        for (auto name : names)
                            namesDigest.add(name);
                        harness->record(Event::MatchAllResult, { workerName, names.size(), namesDigest.value() });
                    });
                }
            }
            harness->settle();
        }
        while (live.size() > 64 || (live.size() && generator.oneIn(3))) {
            auto client = live.takeFirst();
            server.unregisterServiceWorkerClient(client.origin, client.identifier);
        }
    }
    while (!live.isEmpty()) {
        auto client = live.takeFirst();
        server.unregisterServiceWorkerClient(client.origin, client.identifier);
    }
    harness->settle();
    excluded.measure([&] {
        capacitiesOfPass() = harness->capacities();
        harness = std::nullopt;
    });
    return bytes;
}

static WebCore::ServiceWorkerContextData storedRegistration(const String& scope, unsigned version)
{
    URL scopeURL { scope };
    auto topOrigin = WebCore::SecurityOriginData::fromURL(scopeURL);
    auto scriptURL = scriptURLForScope(scope);
    WebCore::ServiceWorkerRegistrationData registration { WebCore::ServiceWorkerRegistrationKey { WTF::move(topOrigin), URL { scopeURL } }, WebCore::ServiceWorkerRegistrationIdentifier::generate(), scopeURL, WebCore::ServiceWorkerUpdateViaCache::Imports, WallTime::fromRawSeconds(1.7e9), std::nullopt, std::nullopt, std::nullopt };
    return WebCore::ServiceWorkerContextData { std::nullopt, WTF::move(registration), WebCore::ServiceWorkerIdentifier::generate(), WebCore::ScriptBuffer { scriptBody(scope, version) }, { }, { }, { }, { }, scriptURL, WebCore::WorkerType::Classic, true, std::nullopt, { }, std::nullopt, WebCore::NavigationPreloadState::defaultValue(), { }, std::nullopt };
}

// 1,000 registrations over 100 origins imported from the store, origin by origin as navigations reach them, and one
// worker in ten started, which loads its scripts from the store (one load in five fails, which unregisters).
static size_t importOrigins(Digest& digest, Excluded& excluded)
{
    std::optional<Harness> harness;
    Vector<String> scopes = siteScopes(100, 10);
    size_t bytes = 0;
    HashMap<String, WebCore::ServiceWorkerIdentifier> workers;
    Vector<std::pair<WebCore::ServiceWorkerRegistrationIdentifier, URL>> stored;
    excluded.measure([&] {
        harness.emplace(digest, ServerOptions { .hasStore = true }, [&](TestRegistrationStore& store) {
            unsigned index = 0;
            for (auto& scope : scopes) {
                auto data = storedRegistration(scope, index % 3);
                stored.append({ data.registration.identifier, data.registration.scopeURL });
                workers.add(scope, data.serviceWorkerIdentifier);
                if (!(index % 50))
                    store.failScriptRetrievalFor(data.scriptURL);
                bytes += registrationBytes(scope);
                store.add(WTF::move(data));
                ++index;
            }
        });
        for (auto& [identifier, scope] : stored)
            harness->learnRegistration(identifier, scope);
        harness->drainTimersInSettle(excluded);
    });
    harness->server().getOriginsWithRegistrations([&](const HashSet<WebCore::SecurityOriginData>& origins) {
        uint64_t sum = 0;
        for (auto& origin : origins)
            sum += hashString(origin.toString());
        harness->record(Event::OriginsResult, { origins.size(), sum });
    });
    harness->settle();
    for (unsigned site = 0; site < 100; ++site) {
        auto topOrigin = WebCore::SecurityOriginData::fromURL(URL { siteOrigin(site) });
        URL clientURL { makeString(scopeURL(site, site % 10), "index.html"_s) };
        harness->owe(Harness::Owed::Match);
        harness->connection(0).doRegistrationMatching(topOrigin, clientURL, [&](std::optional<WebCore::ServiceWorkerRegistrationData>&& data) {
            harness->paid(Harness::Owed::Match);
            recordRegistrationData(*harness, Event::MatchResult, data);
        });
    }
    harness->settle();
    for (unsigned index = 0; index < scopes.size(); index += 10) {
        harness->owe(Harness::Owed::Run);
        harness->server().runServiceWorkerIfNecessary(*workers.get(scopes[index]), [&](WebCore::SWServerToContextConnection* connection) {
            harness->paid(Harness::Owed::Run);
            harness->recordContextConnection(connection);
        });
        harness->settle();
    }
    excluded.measure([&] {
        capacitiesOfPass() = harness->capacities();
        harness = std::nullopt;
    });
    return bytes;
}

// Every error the server's jobs and routes report: untrustworthy and cross-origin script and scope URLs, fetch errors,
// scripts that fail to start or install (with and without an active worker to fall back on), updates of missing
// registrations and with another script URL, unregistering a missing scope, routes that are invalid or over the
// limits, events for missing registrations and workers, and a server without the entitlement that rejects a domain
// that is not app-bound.
static size_t errorPaths(Digest& digest, Excluded& excluded)
{
    size_t bytes = 0;
    std::optional<Harness> first;
    first.emplace(digest, ServerOptions { });
    first->drainTimersInSettle(excluded);
    {
        auto& harness = *first;
        auto& connection = harness.connection(0);
        auto& server = harness.server();
        for (unsigned round = 0; round < 40; ++round) {
            unsigned site = round % 8;
            auto scope = [&](unsigned index) {
                return makeString(siteOrigin(site), "/r"_s, round, "/s"_s, index, '/');
            };
            // Untrustworthy script URL, and script and scope from another origin than the client's.
            harness.scheduleRegister(connection, makeString("ws://site"_s, site, ".example/r"_s, round, "/"_s), URL { makeString("ws://site"_s, site, ".example/r"_s, round, "/sw.js"_s) });
            server.scheduleJob(harness.makeJob(connection, WebCore::ServiceWorkerJobType::Register, scope(0), URL { makeString(siteOrigin(site + 1), "/sw.js"_s) }, URL { scope(0) }));
            server.scheduleJob(harness.makeJob(connection, WebCore::ServiceWorkerJobType::Register, makeString(siteOrigin(site + 1), "/r"_s, round, '/'), scriptURLForScope(scope(0)), URL { scope(0) }));
            // Fetch error, start failure and install failure on new registrations.
            harness.plan(scope(1)).outcome = Outcome::FetchError;
            harness.plan(scope(2)).outcome = Outcome::StartFailure;
            harness.plan(scope(3)).outcome = Outcome::InstallFailure;
            for (unsigned index = 1; index <= 3; ++index)
                harness.scheduleRegister(connection, scope(index), scriptURLForScope(scope(index)));
            // Updates of a missing registration and of one with another script URL.
            harness.scheduleUpdate(connection, scope(9), scriptURLForScope(scope(9)));
            harness.scheduleRegister(connection, scope(4), scriptURLForScope(scope(4)));
            harness.scheduleRegister(connection, scope(5), scriptURLForScope(scope(5)));
            harness.settle();
            harness.scheduleUpdate(connection, scope(4), URL { makeString(scope(4), "other.js"_s) });
            // A changed script that fails each way, with an active worker to fall back on.
            auto& plan = harness.plan(scope(5));
            ++plan.scriptVersion;
            plan.outcome = static_cast<Outcome>(1 + round % 3);
            harness.scheduleUpdate(connection, scope(5), scriptURLForScope(scope(5)));
            harness.scheduleUnregister(connection, scope(8));
            harness.settle();
            bytes += 9 * scope(0).length();

            // Routes: no registration, no installing worker, and each invalid or over-limit route list.
            auto recordRoutes = [&](uint64_t subject) {
                return [&harness, subject](std::expected<void, WebCore::ExceptionData>&& result) {
                    if (result)
                        harness.record(Event::AddRoutesResult, { subject, 0 });
                    else
                        harness.recordException(Event::AddRoutesResult, subject, result.error());
                };
            };
            server.addRoutes(WebCore::ServiceWorkerRegistrationIdentifier::generate(), makeRoutes(1, 0), recordRoutes(1));
            if (auto registration = harness.registrationForScope(scope(4)))
                server.addRoutes(*registration, makeRoutes(1, 0), recordRoutes(2));
            for (unsigned variant = 1; variant <= 5; ++variant) {
                auto& plan = harness.plan(scope(10 + variant));
                plan.routeCount = 2;
                plan.routeVariant = variant;
            }
            for (unsigned variant = 1; variant <= 5; ++variant)
                harness.scheduleRegister(connection, scope(10 + variant), scriptURLForScope(scope(10 + variant)));
            harness.settle();

            // Push to a missing scope, and starting a worker that does not exist.
            harness.owe(Harness::Owed::Push);
            server.processPushMessage(Vector<uint8_t> { 2, 4 }, std::nullopt, URL { scope(30) }, [&](bool handled, std::optional<WebCore::NotificationPayload>&&) {
                harness.paid(Harness::Owed::Push);
                harness.record(Event::PushResult, { 0, handled });
            });
            harness.owe(Harness::Owed::Run);
            server.runServiceWorkerIfNecessary(WebCore::ServiceWorkerIdentifier::generate(), [&](WebCore::SWServerToContextConnection* connection) {
                harness.paid(Harness::Owed::Run);
                harness.recordContextConnection(connection);
            });
            harness.settle();
        }
    }
    String capacities;
    excluded.measure([&] {
        capacities = first->capacities();
        first = std::nullopt;
    });
    {
        // Without the entitlement, a register job is allowed only for an app-bound domain, under the count limit.
        ServerOptions options;
        options.hasServiceWorkerEntitlement = false;
        options.registrationCountLimit = 30;
        options.appBoundDomains = { siteDomain(0), siteDomain(2) };
        std::optional<Harness> second;
        second.emplace(digest, WTF::move(options));
        second->drainTimersInSettle(excluded);
        for (unsigned site = 0; site < 4; ++site) {
            auto scopes = siteScopes(1, 10, site);
            bytes += registerScopes(*second, scopes);
        }
        excluded.measure([&] {
            capacitiesOfPass() = makeString(capacities, " withoutEntitlement: "_s, second->capacities());
            second = std::nullopt;
        });
    }
    return bytes;
}

// Functional events and worker lifetime: pushes handled and not, to running workers, to workers terminated by domain,
// and to workers whose context connection went away (so the server creates one and runs the worker in it), with
// context connections removed when possible.
static size_t workerLifetime(Digest& digest, Excluded& excluded)
{
    std::optional<Harness> harness;
    auto scopes = siteScopes(8, 5);
    excluded.measure([&] {
        harness.emplace(digest, ServerOptions { });
        registerScopes(*harness, scopes);
    });
    auto& server = harness->server();
    size_t bytes = 0;
    auto push = [&](unsigned round) {
        for (unsigned i = 0; i < scopes.size(); ++i) {
            Vector<uint8_t> data(FillWith { }, 32 + i % 64, static_cast<uint8_t>(i + round));
            bytes += data.size() + scopes[i].length();
            harness->owe(Harness::Owed::Push);
            server.processPushMessage(WTF::move(data), std::nullopt, URL { scopes[i] }, [&, i](bool handled, std::optional<WebCore::NotificationPayload>&&) {
                harness->paid(Harness::Owed::Push);
                harness->record(Event::PushResult, { i, handled });
            });
            harness->settle();
        }
    };
    for (unsigned round = 0; round < 6; ++round) {
        push(round);
        // Workers of half the sites terminated as if their process exited.
        harness->unordered([&] {
            for (unsigned site = round % 2; site < 8; site += 2)
                server.markAllWorkersForRegistrableDomainAsTerminated(WebCore::RegistrableDomain { URL { siteOrigin(site) } });
            harness->settle();
        });
        push(round + 1);
        // The context connection of one site removed: the next push creates another.
        harness->unordered([&] {
            if (auto* connection = harness->contextConnection(siteDomain(round)))
                server.removeContextConnection(*connection);
            harness->settle();
        });
        push(round + 2);
        harness->unordered([&] {
            if (auto* connection = harness->contextConnection(siteDomain(7 - round)))
                server.terminateContextConnectionWhenPossible(WebCore::RegistrableDomain { URL { siteOrigin(7 - round) } }, connection->webProcessIdentifier());
            server.handleLowMemoryWarning();
            harness->settle();
        });
    }
    excluded.measure([&] {
        capacitiesOfPass() = harness->capacities();
        harness = std::nullopt;
    });
    return bytes;
}

// A mix as browsing produces it: 8 sites with 3 scopes each over two web processes, some with routes, and 2,000 page
// loads that match a registration, become clients, route their subresources and leave, with registrations becoming
// ready, updates (a changed script waits for the page's clients to leave), pushes and an unregistration on the way.
static size_t realisticMix(Digest& digest, Excluded& excluded)
{
    std::optional<Harness> owner;
    owner.emplace(digest, ServerOptions { .connectionCount = 2, .terminationsInAnyOrder = true });
    auto& harness = *owner;
    harness.drainTimersInSettle(excluded);
    excluded.measure([&] {
        importSiteOrigins(harness.server(), 9);
    });
    auto scopes = siteScopes(8, 3);
    size_t bytes = 0;
    for (unsigned i = 0; i < scopes.size(); ++i) {
        if (!(i % 3))
            harness.plan(scopes[i]).routeCount = 16;
        if (i % 4 == 1)
            harness.plan(scopes[i]).importedScriptCount = 1;
        URL clientURL { makeString(scopes[i], "index.html"_s) };
        harness.owe(Harness::Owed::Match);
        harness.connection(i % 2).ready(WebCore::SecurityOriginData::fromURL(clientURL), clientURL, [&](std::optional<WebCore::ServiceWorkerRegistrationData>&& data) {
            harness.paid(Harness::Owed::Match);
            recordRegistrationData(harness, Event::ReadyResult, data);
        });
    }
    bytes += registerScopes(harness, Vector<String> { scopes.span().subspan(0, 12) }, 0);
    bytes += registerScopes(harness, Vector<String> { scopes.span().subspan(12) }, 1);

    auto& server = harness.server();
    size_t requestBytes = 0;
    auto requests = makeRouteRequests(64, siteOrigin(0), requestBytes);
    struct Page {
        WebCore::ClientOrigin origin;
        WebCore::ScriptExecutionContextIdentifier identifier;
    };
    Deque<Page> pages;
    Generator generator(0x4d69);
    constexpr unsigned loads = workloadSize(2000, 400);
    for (unsigned load = 0; load < loads; ++load) {
        unsigned site = generator.below(9);
        unsigned scopeIndex = generator.below(4);
        URL url { scopeIndex < 3 ? makeString(scopeURL(site, scopeIndex), "article"_s, load % 50, ".html"_s) : makeString(siteOrigin(site), "/"_s) };
        bytes += url.string().length();
        auto& connection = harness.connection(load % 2);
        auto origin = clientOriginFor(url);
        RefPtr registration = server.doRegistrationMatchingSync(origin.topOrigin, url);
        std::optional<WebCore::ServiceWorkerRegistrationIdentifier> controller;
        String scope;
        if (registration) {
            scope = registration->data().scopeURL.string();
            controller = harness.registrationForScope(scope);
        }
        harness.record(Event::LookupResult, { scope.isNull() ? 0 : harness.scopeName(scope) });
        auto identifier = clientIdentifier(load, connection.processIdentifier());
        harness.addClient(identifier);
        server.registerServiceWorkerClient(WebCore::ClientOrigin { origin }, makeClient(identifier, url, true), controller, "BenchAgent/1.0"_s, WebCore::SWServer::IsBeingCreatedClient::No);
        pages.append({ origin, identifier });
        if (!scope.isNull()) {
            if (auto* worker = harness.activeWorker(scope)) {
                for (unsigned i = 0; i < 8; ++i) {
                    auto& request = requests[(load * 8 + i) % requests.size()];
                    harness.record(Event::RouteResult, { routeSourceName(worker->getRouterSource(request.options.mode, request.options.destination, request.request.url(), request.request.httpMethod())) });
                    bytes += request.request.url().string().length();
                }
            }
        }
        if (!(load % 100)) {
            auto& updated = scopes[(load / 100) % scopes.size()];
            if (!(load % 500))
                ++harness.plan(updated).scriptVersion;
            harness.scheduleUpdate(harness.connection((load / 100) % 2), updated, scriptURLForScope(updated));
        }
        if (!(load % 300)) {
            auto& pushed = scopes[(load / 300 * 5) % scopes.size()];
            harness.owe(Harness::Owed::Push);
            server.processPushMessage(Vector<uint8_t> { static_cast<uint8_t>(load / 300), 1, 2, 3 }, std::nullopt, URL { pushed }, [&harness, load](bool handled, std::optional<WebCore::NotificationPayload>&&) {
                harness.paid(Harness::Owed::Push);
                harness.record(Event::PushResult, { load, handled });
            });
        }
        if (load == loads * 3 / 4)
            harness.scheduleUnregister(harness.connection(0), scopes[7]);
        while (pages.size() > 16) {
            auto page = pages.takeFirst();
            server.unregisterServiceWorkerClient(page.origin, page.identifier);
        }
        if (!(load % 10))
            harness.settle();
    }
    while (!pages.isEmpty()) {
        auto page = pages.takeFirst();
        server.unregisterServiceWorkerClient(page.origin, page.identifier);
    }
    harness.settle();
    excluded.measure([&] {
        capacitiesOfPass() = harness.capacities();
        owner = std::nullopt;
    });
    return bytes;
}

// The harness.

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && StringView::fromLatin1(value) != "0"_s;
}

// `pass(digest, excluded)` returns the bytes its timed operations carried.
template<typename Pass>
static void run(ASCIILiteral name, uint64_t recordedBenchmark, uint64_t recordedWithAssertions, size_t benchmarkPasses, const Pass& pass)
{
#if ASSERT_ENABLED
    UNUSED_PARAM(recordedBenchmark);
    uint64_t recorded = recordedWithAssertions;
#else
    UNUSED_PARAM(recordedWithAssertions);
    uint64_t recorded = recordedBenchmark;
#endif
    Digest digest;
    Excluded excluded;
    capacitiesOfPass() = String { };
    pass(digest, excluded);
    auto checksum = digest.value();
    EXPECT_EQ(recorded, checksum);
    if (recorded != checksum)
        SAFE_PRINTF("%s: checksum=%016llx (recorded %016llx)\n", name, static_cast<unsigned long long>(checksum), static_cast<unsigned long long>(recorded));
    if (!capacitiesOfPass().isNull())
        SAFE_PRINTF("%s capacities %s\n", name, capacitiesOfPass().utf8());
    fflush(stdout);
    if (!runsBenchmarks())
        return;

    Seconds timed;
    double totalBytes = 0;
    size_t passes = 0;
    size_t mismatches = 0;
    while (passes < benchmarkPasses) {
        Digest passDigest;
        Excluded passExcluded;
        auto start = MonotonicTime::now();
        size_t passBytes = pass(passDigest, passExcluded);
        timed += (MonotonicTime::now() - start) - passExcluded.total();
        totalBytes += passBytes;
        ++passes;
        mismatches += passDigest.value() != checksum;
    }
    EXPECT_EQ(0u, mismatches);
    SAFE_PRINTF("%s: %.1f ms %.3f MB/s checksum=%016llx passes=%zu\n", name, timed.milliseconds(), totalBytes / timed.microseconds(), static_cast<unsigned long long>(checksum), passes);
    fflush(stdout);
}

} // namespace TestWebKitAPI::SWServerBenchmark

using namespace TestWebKitAPI::SWServerBenchmark;

// Runs no workload: alone in a process, its time is the start-up every other test's process also pays.
TEST(SWServerBench, StartUp)
{
}

// Recorded checksums, without and with assertions: each test prints its digest when it differs from the value here.

TEST(SWServerBench, RegisterInstallActivate)
{
    run("RegisterInstallActivate"_s, 0x67722ccee1d88140ull, 0x213385e0ce9be970ull, 50, registerInstallActivate);
}

TEST(SWServerBench, MatchRegistration)
{
    run("MatchRegistration"_s, 0x0d38edaa77f698a3ull, 0xad542b4e63a524b1ull, 3, matchRegistration);
}

TEST(SWServerBench, RouteMatch)
{
    run("RouteMatch"_s, 0x0e08e70722ae4e1eull, 0xe3dd7f7f82bfa6e9ull, 3, routeMatch);
}

TEST(SWServerBench, ClientChurn)
{
    run("ClientChurn"_s, 0x95c4d470286e5600ull, 0xb622db20c3c45360ull, 50, clientChurn);
}

TEST(SWServerBench, ImportOrigins)
{
    run("ImportOrigins"_s, 0xab8e60de28c36cc8ull, 0xab8e60de28c36cc8ull, 250, importOrigins);
}

TEST(SWServerBench, ErrorPaths)
{
    run("ErrorPaths"_s, 0xb8da62a06190a269ull, 0xb8da62a06190a269ull, 60, errorPaths);
}

TEST(SWServerBench, WorkerLifetime)
{
    run("WorkerLifetime"_s, 0xf1b027493a7ef6bbull, 0xf1b027493a7ef6bbull, 130, workerLifetime);
}

TEST(SWServerBench, RealisticMix)
{
    run("RealisticMix"_s, 0xd453a9089f413707ull, 0x147e3bbfa5f7b3f8ull, 12, realisticMix);
}

// A benchmark repeats its pass in one process, and every pass after the first runs with other identifier values: each
// workload's second pass must give the first pass's digest.
TEST(SWServerBench, PassesAgreeInOneProcess)
{
    auto expectAgree = [](ASCIILiteral name, const auto& pass) {
        Digest first;
        Digest second;
        Excluded excluded;
        pass(first, excluded);
        pass(second, excluded);
        EXPECT_EQ(first.value(), second.value()) << name.characters();
    };
    expectAgree("RegisterInstallActivate"_s, registerInstallActivate);
    expectAgree("MatchRegistration"_s, matchRegistration);
    expectAgree("RouteMatch"_s, routeMatch);
    expectAgree("ClientChurn"_s, clientChurn);
    expectAgree("ImportOrigins"_s, importOrigins);
    expectAgree("ErrorPaths"_s, errorPaths);
    expectAgree("WorkerLifetime"_s, workerLifetime);
    expectAgree("RealisticMix"_s, realisticMix);
}
