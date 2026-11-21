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

#if PLATFORM(MAC)

#include "ScrollingTreeDelegateRig.h"
#include <WebCore/PlatformLayerIdentifier.h>
#include <cstdlib>
#include <utility>

// The scrolling coordination path from the state tree a coordinator writes to the tree that takes its commit: the
// state tree's building and change tracking, its commit, the layer identifiers a commit carries and the UI process
// connects, the tree's commit of the state nodes, wheel events and display refreshes on the scrolling thread, and
// the first commit of a new page. One test per shape, on ScrollingTreeDelegateRig's trees. Each test runs one pass
// and checks its checksum, a hash of every scroll position and flag the nodes report after each step and of every
// call they make on the tree. With WEBKIT_RUN_BENCHMARKS=1 it runs the pass for a second or more and prints
// <Shape>: <ms> ms <rate> MB/s checksum=<hex>, where the rate is thousands of commits, wheel events and display
// refreshes per second.
//
// Not reached from here: AsyncScrollingCoordinator (it needs a Page, which this suite does not build) and the UI
// process's decode of a transaction and its RemoteScrollingTree (WebKit's IPC serializers). UIProcessCommit
// covers what the UI process does with a decoded transaction that WebCore owns: layer identifiers resolved against
// the UI process's layers, then the commit.

namespace TestWebKitAPI {

using namespace ScrollingTreeDelegate;

namespace {

using PassResult = std::pair<uint64_t, uint64_t>;

// One pass of a shape on the scrolling thread: its digest and how many entries it made. The body returns the entries.
template<typename Body>
PassResult runOnScrollingThread(Body&& body)
{
    Digest digest;
    uint64_t entries = 0;
    onScrollingThread([&] {
        entries = body(digest);
    });
    drainMainThreadTasks();
    return { digest.value(), entries };
}

template<typename Body>
PassResult runSession(Body&& body)
{
    return runOnScrollingThread([&](Digest& digest) {
        Session session(digest);
        body(session, digest);
        return session.entries();
    });
}

// A page's tree: a main frame node and, below it, overflow nodes and a subframe in every twenty-fifth place, each
// under an earlier node in its second two thirds, so the depth grows with the log of the count.
void buildTree(Session& session, unsigned count, Lcg& random, bool withSubframes)
{
    session.addRoot(mainFrameSetup({ 0, 500 }));
    for (unsigned i = 1; i < count; ++i) {
        unsigned parent = random.range(i / 3, i - 1);
        if (withSubframes && !(i % 25)) {
            NodeSetup setup;
            setup.viewport = { 300, 240 };
            setup.contents = { 300, 1800 };
            session.addSubframe(setup, session.scrollingNodeID(parent));
        } else
            session.addOverflow(overflowSetup({ 0, 20.0f * (i % 7) }, i), parent);
    }
}

// The properties a coordinator's update of a node writes: geometry, parameters and position.
void updateNode(Session& session, unsigned index, unsigned round, Lcg& random)
{
    auto setup = index ? overflowSetup({ 0, random.between(0, 400) }, index + round) : mainFrameSetup({ 0, random.between(0, 2000) });
    if (session.state(index)->nodeType() == ScrollingNodeType::Subframe) {
        setup.viewport = { 300, 240 };
        setup.contents = { 300, 1800.0f + 10 * round };
    }
    session.apply(index, setup);
}

PassResult stateTreeCommitPass()
{
    return runSession([](Session& session, Digest&) {
        Lcg random(21);
        buildTree(session, 200, random, true);
        // The first commit, of every node's every property, then rounds in which a coordinator's update rewrites each node.
        session.commit();
        for (unsigned round = 1; round <= 8; ++round) {
            for (unsigned index = 0; index < session.nodeCount(); ++index) {
                updateNode(session, index, round, random);
                if (!((index + round) % 8))
                    session.state(index)->setSnapOffsetsInfo(snapOffsets({ { }, evenlySpaced(0, 100, random.range(2, 30)), 300, round % 2 ? ScrollSnapStrictness::Proximity : ScrollSnapStrictness::Mandatory, std::nullopt }));
            }
            session.commit();
        }
    });
}

PassResult stateTreeIncrementalPass()
{
    return runSession([](Session& session, Digest&) {
        Lcg random(22);
        buildTree(session, 200, random, true);
        session.commit();
        // Each commit changes one property of every node; the property rotates with the round and the node.
        for (unsigned round = 0; round < 120; ++round) {
            for (unsigned index = 0; index < session.nodeCount(); ++index) {
                Ref state = session.state(index);
                switch ((round + index) % 5) {
                case 0:
                    state->setScrollPosition({ 0, random.between(0, 600) });
                    break;
                case 1:
                    state->setTotalContentsSize({ 1200.0f + random.range(0, 8) * 50, 20000.0f + random.range(0, 40) * 100 });
                    break;
                case 2:
                    state->setScrollableAreaSize({ 400.0f + random.range(0, 4) * 10, 300 });
                    break;
                case 3:
                    state->setMouseIsOverContentArea(!(round % 2));
                    break;
                case 4:
                    state->setCurrentVerticalSnapPointIndex(random.chance(50) ? std::optional<unsigned>(random.range(0, 9)) : std::nullopt);
                    break;
                }
            }
            session.commit();
        }
    });
}

// The layers a web process commits are named by identifier and the UI process resolves them: here none resolves
// (the page-wide layer map holds none of this process's layers), so each node is committed with no layer.
class LayerIdentifiers {
public:
    std::optional<PlatformLayerIdentifier> make()
    {
        return PlatformLayerIdentifier { ObjectIdentifier<PlatformLayerIdentifierType>(++m_count), ProcessIdentifier(1) };
    }

    void assign(Session& session, unsigned index)
    {
        Ref state = session.state(index);
        state->setScrollContainerLayer(make());
        state->setScrolledContentsLayer(make());
    }

    // As RemoteScrollingCoordinatorProxyMac connects a committed tree's nodes to the layers of the layer tree.
    static void connect(ScrollingStateTree& stateTree, Digest& digest)
    {
        using Property = ScrollingStateNode::Property;
        auto resolve = [&](const LayerRepresentation& representation) -> LayerRepresentation {
            auto id = representation.layerID();
            digest.u(id ? id->object().toUInt64() : 0);
            return static_cast<ScrollingPlatformLayer*>(nullptr);
        };
        for (auto& node : stateTree.nodeMap().values()) {
            if (node->hasChangedProperty(Property::Layer))
                node->setLayer(resolve(node->layer()));
            if (RefPtr scrolling = dynamicDowncast<ScrollingStateScrollingNode>(node)) {
                if (scrolling->hasChangedProperty(Property::ScrollContainerLayer))
                    scrolling->setScrollContainerLayer(resolve(scrolling->scrollContainerLayer()));
                if (scrolling->hasChangedProperty(Property::ScrolledContentsLayer))
                    scrolling->setScrolledContentsLayer(resolve(scrolling->scrolledContentsLayer()));
            }
        }
    }

private:
    uint64_t m_count { 0 };
};

PassResult uiProcessCommitPass()
{
    return runSession([](Session& session, Digest& digest) {
        Lcg random(23);
        LayerIdentifiers layers;
        session.setLayerConnector([&](ScrollingStateTree& stateTree) { LayerIdentifiers::connect(stateTree, digest); });
        buildTree(session, 100, random, true);
        for (unsigned index = 0; index < session.nodeCount(); ++index)
            layers.assign(session, index);
        session.commit();
        for (unsigned round = 0; round < 60; ++round) {
            for (unsigned index = 0; index < session.nodeCount(); ++index) {
                // Every node scrolls; one in seven also gets new layers, as a node whose layers were rebuilt does.
                session.requestScroll(index, ScrollRequestType::PositionUpdate, FloatPoint { 0, random.between(0, 600) });
                if (!((index + round) % 7))
                    layers.assign(session, index);
            }
            session.commit();
        }
    });
}

// Trackpad gestures with momentum and discrete wheel ticks, wheel events only, on a tree of forty scrollers, with a
// commit that moves some of them between every few gestures, as the scrolling thread takes them from the main thread.
PassResult wheelOnScrollingThreadPass()
{
    return runSession([](Session& session, Digest&) {
        Lcg random(24);
        std::vector<unsigned> discreteTargets;
        buildTree(session, 40, random, false);
        session.commit();
        for (unsigned i = 0; i < 48; ++i) {
            unsigned target = random.range(0, session.nodeCount() - 1);
            if (i % 6 == 5) {
                // Discrete ticks come last: after them a gesture's result depends on the build configuration.
                discreteTargets.push_back(target);
            } else {
                Session::Gesture gesture;
                float sign = i % 2 ? -1 : 1;
                gesture.deltas = decayingDeltas({ random.between(-2, 2), sign * random.between(4, 30) }, 0.97f, random.range(10, 30));
                gesture.momentumDeltas = decayingDeltas({ 0, sign * random.between(10, 40) }, 0.94f, random.range(20, 60));
                gesture.framesBetweenEvents = false;
                session.gesture(target, gesture);
            }
            if (i % 4 == 3) {
                for (unsigned moved = 0; moved < 4; ++moved)
                    session.requestScroll(random.range(0, session.nodeCount() - 1), ScrollRequestType::PositionUpdate, FloatPoint { 0, random.between(0, 2000) });
                session.commit();
            }
        }
        session.framesUntilIdle();
        for (unsigned target : discreteTargets) {
            for (unsigned tick = random.range(2, 8); tick; --tick)
                session.wheel(target, { PlatformWheelEventPhase::None, PlatformWheelEventPhase::None, { 0, random.chance(50) ? -40.0f : 40.0f }, PlatformWheelEventGranularity::ScrollByPixelWheelEvent, false }, 0.05);
        }
    });
}

PassResult displayRefreshPass()
{
    return runSession([](Session& session, Digest&) {
        displayRefreshShape(session);
    });
}

// A page being used: commits that move and resize scrollers, gestures, animated and keyboard scrolls, discrete wheel
// ticks, a node moved under the root, and a navigation that replaces the root, on a tree of sixty nodes.
PassResult scrollingPageMixedPass()
{
    return runSession([](Session& session, Digest&) {
        Lcg random(25);
        buildTree(session, 60, random, false);
        session.state(0)->setSnapOffsetsInfo(snapOffsets({ { }, evenlySpaced(0, 600, 30), 600, ScrollSnapStrictness::Proximity, std::nullopt }));
        session.state(3)->setSnapOffsetsInfo(snapOffsets({ { }, evenlySpaced(0, 300, 20), 300, ScrollSnapStrictness::Mandatory, std::nullopt }));
        session.commit();
        static constexpr ScrollDirection directions[] = { ScrollDirection::ScrollDown, ScrollDirection::ScrollUp, ScrollDirection::ScrollRight, ScrollDirection::ScrollLeft };
        for (unsigned i = 0; i < 60; ++i) {
            unsigned count = session.nodeCount();
            unsigned target = random.range(0, count - 1);
            switch (i % 6) {
            case 0: {
                Session::Gesture gesture;
                float sign = random.chance(50) ? -1 : 1;
                gesture.deltas = decayingDeltas({ random.between(-3, 3), sign * random.between(4, 30) }, 0.96f, random.range(8, 24));
                if (random.chance(70))
                    gesture.momentumDeltas = decayingDeltas({ 0, sign * random.between(10, 40) }, 0.92f, random.range(10, 40));
                session.gesture(target, gesture);
                session.framesUntilIdle();
                break;
            }
            case 1:
                if (random.chance(50))
                    session.requestScroll(target, ScrollRequestType::AnimatedPositionUpdate, FloatPoint { 0, random.between(0, 4000) });
                else
                    session.requestScroll(target, ScrollRequestType::AnimatedDeltaUpdate, FloatSize { 0, random.between(-800, 800) });
                session.commit();
                for (unsigned frame = random.range(2, 30); frame; --frame)
                    session.frame();
                session.requestScroll(target, ScrollRequestType::PositionUpdate, FloatPoint { 0, random.between(0, 2000) });
                session.commit();
                session.framesUntilIdle();
                break;
            case 2: {
                auto direction = directions[random.range(0, 3)];
                auto granularity = random.chance(60) ? ScrollGranularity::Line : ScrollGranularity::Page;
                session.requestKeyboardScroll(target, KeyboardScrollAction::StartAnimation, keyboardScroll(direction, granularity, granularity == ScrollGranularity::Line ? 40 : 540));
                session.commit();
                for (unsigned frame = random.range(4, 30); frame; --frame)
                    session.frame();
                session.requestKeyboardScroll(target, random.chance(70) ? KeyboardScrollAction::StopWithAnimation : KeyboardScrollAction::StopImmediately);
                session.commit();
                session.framesUntilIdle();
                break;
            }
            case 3:
                // A rendering update's commit: a few scrollers move, a few change size.
                for (unsigned moved = 0; moved < 6; ++moved)
                    session.requestScroll(random.range(0, count - 1), ScrollRequestType::PositionUpdate, FloatPoint { 0, random.between(0, 2000) });
                for (unsigned grown = 0; grown < 3; ++grown)
                    session.state(random.range(0, count - 1))->setTotalContentsSize({ 800, 3000.0f + 10.0f * random.range(0, 400) });
                session.commit();
                break;
            case 4:
                if (i != 58) {
                    Session::Gesture gesture;
                    gesture.deltas = decayingDeltas({ 0, random.between(-30, 30) }, 0.9f, random.range(4, 12));
                    session.gesture(target, gesture);
                    session.framesUntilIdle();
                    break;
                }
                // Discrete mouse-wheel ticks, last: they arm the nodes' snap timers, which this pass never fires, and a
                // gesture after them gives a result that depends on the build configuration.
                for (unsigned tick = random.range(2, 8); tick; --tick) {
                    session.wheel(target, { PlatformWheelEventPhase::None, PlatformWheelEventPhase::None, { 0, random.chance(50) ? -40.0f : 40.0f }, PlatformWheelEventGranularity::ScrollByPixelWheelEvent, false }, 0.05);
                    session.frame();
                }
                session.framesUntilIdle();
                break;
            case 5:
                if (i == 41) {
                    // A navigation: a new root takes the scrollers.
                    std::vector<NodeSetup> setups;
                    for (unsigned index = 1; index < count; ++index)
                        setups.push_back(overflowSetup({ 0, 20.0f * (index % 7) }, index));
                    session.replaceRoot(mainFrameSetup({ 0, 0 }), setups);
                } else if (count > 2) {
                    // Layout changed a containing block: a scroller moves under the root.
                    session.reparent(session.scrollingNodeID(random.range(1, count - 1)), session.scrollingNodeID(0));
                }
                session.commit();
                session.framesUntilIdle();
                break;
            }
        }
    });
}

// New pages: each a new tree whose first commit creates its nodes, then the first wheel event and display refresh.
PassResult newPagesPass()
{
    return runOnScrollingThread([](Digest& digest) {
        uint64_t entries = 0;
        Lcg random(26);
        for (unsigned page = 0; page < 40; ++page) {
            Session session(digest, 1000 + page);
            session.addRoot(mainFrameSetup({ 0, 0 }));
            for (unsigned i = 1; i < 4 + page % 14; ++i)
                session.addOverflow(overflowSetup({ 0, 0 }, i), random.range(0, i - 1));
            if (page % 5 == 4) {
                NodeSetup setup;
                setup.viewport = { 300, 240 };
                setup.contents = { 300, 1800 };
                session.addSubframe(setup, session.scrollingNodeID(0));
            }
            session.commit();
            session.wheel(random.range(0, session.nodeCount() - 1), { PlatformWheelEventPhase::None, PlatformWheelEventPhase::None, { 0, 40 }, PlatformWheelEventGranularity::ScrollByPixelWheelEvent, false });
            session.frame();
            entries += session.entries();
        }
        return entries;
    });
}

} // namespace

// Runs the pass once and checks its checksum. With WEBKIT_RUN_BENCHMARKS=1, runs it again until a second has passed
// and prints the line the benchmark scripts read.
static void runCoordinationShape(PassResult (*pass)(), const char* name, uint64_t expectedChecksum)
{
    auto [checksum, entries] = pass();
    EXPECT_EQ(checksum, expectedChecksum);

    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    uint64_t totalEntries = 0;
    auto start = MonotonicTime::now();
    Seconds elapsed;
    do {
        auto [passChecksum, passEntries] = pass();
        EXPECT_EQ(passChecksum, checksum);
        totalEntries += passEntries;
        elapsed = MonotonicTime::now() - start;
    } while (elapsed < 1_s);
    double milliseconds = elapsed.milliseconds();
    printf("%s: %.1f ms %.2f MB/s checksum=%016llx\n", name, milliseconds, totalEntries / milliseconds, static_cast<unsigned long long>(checksum));
}

// The checksums are the C++'s, recorded by the first build (DisplayRefresh's is ScrollingTreeDelegateBench's).
TEST(ScrollingCoordinationBench, StateTreeCommit)
{
    runCoordinationShape(stateTreeCommitPass, "StateTreeCommit", 0x2c4df332852a3764ull);
}

TEST(ScrollingCoordinationBench, StateTreeIncremental)
{
    runCoordinationShape(stateTreeIncrementalPass, "StateTreeIncremental", 0xfa0066c6c8acfc84ull);
}

TEST(ScrollingCoordinationBench, UIProcessCommit)
{
    runCoordinationShape(uiProcessCommitPass, "UIProcessCommit", 0x23d258010aa491f8ull);
}

TEST(ScrollingCoordinationBench, WheelOnScrollingThread)
{
    runCoordinationShape(wheelOnScrollingThreadPass, "WheelOnScrollingThread", 0x82959eabd7684db9ull);
}

TEST(ScrollingCoordinationBench, DisplayRefresh)
{
    runCoordinationShape(displayRefreshPass, "DisplayRefresh", 0x599dab7d2ae56305ull);
}

TEST(ScrollingCoordinationBench, ScrollingPageMixed)
{
    runCoordinationShape(scrollingPageMixedPass, "ScrollingPageMixed", 0x51990ff7e3a6ec75ull);
}

// Starts and exits as a shape's process does; compare-arms.py subtracts it.
TEST(ScrollingCoordinationBench, StartUp)
{
}

TEST(ScrollingCoordinationBench, NewPages)
{
    runCoordinationShape(newPagesPass, "NewPages", 0x52825477688ac925ull);
}

} // namespace TestWebKitAPI

#endif // PLATFORM(MAC)
