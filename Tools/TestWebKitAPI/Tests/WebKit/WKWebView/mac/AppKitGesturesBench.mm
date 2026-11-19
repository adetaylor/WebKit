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

#if HAVE(APPKIT_GESTURES_SUPPORT)

#import "AppKitGesturesBenchInputs.h"
#import "Helpers/Test.h"
#import <cstdio>
#import <cstdlib>
#import <wtf/StdLibExtras.h>
#import <wtf/text/CString.h>
#import <wtf/text/WTFString.h>

// The AppKit gesture controller's speed, one shape per TEST, through its production entry points (a real WKWebView's
// recognizers, scripted: AppKitGesturesBenchInputs.h). Without WEBKIT_RUN_BENCHMARKS each test runs one pass and
// EXPECT_EQs its checksum against the recorded value. With WEBKIT_RUN_BENCHMARKS=1 it runs a
// fixed number of passes per shape (timedPasses*, about two seconds of work each), so the work, and with it the
// process's cycles, depends on the controller's speed and not on a wall-clock cutoff, and prints
//     <Shape>: <ms> ms <rate> MB/s checksum=<hex>
// where <ms> is the time spent inside the controller's calls (observations, scripting and the web process round trip
// between gestures are outside it) and <rate>, labeled "MB/s", is scripted steps (actions, delegate calls) per
// millisecond. The checksum is FNV-1a over what the controller leaves visible:
// each delegate method's return value, each recognizer's state and enabled flag after every step, the controller's
// public properties, and the state and translation writes the controller made to the recognizers.
//
// The checksum holds only what does not depend on time: every gesture's steps run back to back on the main thread
// (no reply from the web process can arrive inside one), the queues drain after each gesture, each fling's momentum is
// interrupted by a new touch after the first drain, and the controller's real-time windows (the 50 ms transform window) are exercised only
// within a gesture.
//
// Not reached: NSApp's current event (_isOnlyTouchDown: always sees none outside a live direct touch), momentum events
// that follow the display link, and the replies' own timing.

namespace TestWebKitAPI {
namespace AppKitGesturesBench {

// Checksums of the Objective-C++ controller's output.
static constexpr uint64_t recordedPanScroll = 0x0c770ed06d169206ull;
static constexpr uint64_t recordedMomentumFling = 0xf9ece284020e99a6ull;
static constexpr uint64_t recordedClickSequence = 0x6d9695cc546b95eeull;
static constexpr uint64_t recordedPointerTracking = 0x594a9d8f9339f361ull;
static constexpr uint64_t recordedTransformGesture = 0xc3bd2e19833d53ddull;
static constexpr uint64_t recordedGestureArbitration = 0xcde0a619a91a2a55ull;
static constexpr uint64_t recordedTouchSession = 0x8d1910a779e6e82eull;

// Passes in the timed mode: fixed, so a slower controller costs more cycles than a wall-clock cutoff would. About two
// seconds of passes each.
static constexpr unsigned timedPassesPanScroll = 400;
static constexpr unsigned timedPassesMomentumFling = 350;
static constexpr unsigned timedPassesClickSequence = 180;
static constexpr unsigned timedPassesPointerTracking = 550;
static constexpr unsigned timedPassesTransformGesture = 600;
static constexpr unsigned timedPassesGestureArbitration = 320;
static constexpr unsigned timedPassesTouchSession = 110;

using ShapeFunction = void (*)(Rig&, Pass&);

static void panScrollShape(Rig& rig, Pass& pass)
{
    Lcg random(31);
    for (unsigned i = 0; i < 40 && !pass.failure; ++i)
        panGesture(rig, pass, random, false);
}

static void momentumFlingShape(Rig& rig, Pass& pass)
{
    Lcg random(32);
    for (unsigned i = 0; i < 30 && !pass.failure; ++i)
        panGesture(rig, pass, random, true);
}

static void clickSequenceShape(Rig& rig, Pass& pass)
{
    Lcg random(33);
    for (unsigned i = 0; i < 40 && !pass.failure; ++i)
        clickGesture(rig, pass, random, i % 5);
}

static void pointerTrackingShape(Rig& rig, Pass& pass)
{
    Lcg random(34);
    for (unsigned i = 0; i < 40 && !pass.failure; ++i)
        pointerGesture(rig, pass, random);
}

static void transformGestureShape(Rig& rig, Pass& pass)
{
    Lcg random(35);
    for (unsigned i = 0; i < 30 && !pass.failure; ++i)
        transformGesture(rig, pass, random);
}

static void gestureArbitrationShape(Rig& rig, Pass& pass)
{
    for (unsigned i = 0; i < 20 && !pass.failure; ++i)
        arbitrationMatrix(rig, pass);
}

static void touchSessionShape(Rig& rig, Pass& pass)
{
    Lcg random(36);
    for (unsigned i = 0; i < 80 && !pass.failure; ++i)
        sessionStep(rig, pass, random);
}

static void runShape(ShapeFunction shape, ASCIILiteral name, uint64_t recorded, unsigned timedPasses)
{
    Rig rig;
    std::vector<std::string> writes;
    controllerWrites = &writes;
    if (!rig.setUp()) {
        controllerWrites = nullptr;
        ADD_FAILURE() << "the page did not load, or the web view has no gesture controller";
        return;
    }

    Pass first;
    shape(rig, first);
    if (first.failure) {
        controllerWrites = nullptr;
        ADD_FAILURE() << first.failure << " after " << first.steps << " steps";
        return;
    }
    bool benchmarking = getenv("WEBKIT_RUN_BENCHMARKS");
    if (!benchmarking) {
        SAFE_PRINTF("%s: checksum=%016llx ui-requests=%s\n", name, static_cast<unsigned long long>(first.checksum.value), String([rig.uiDelegate.get().requests componentsJoinedByString:@","]).utf8());
        controllerWrites = nullptr;
        EXPECT_EQ(first.checksum.value, recorded) << name.characters() << " recorded value is " << std::hex << first.checksum.value;
        return;
    }

    uint64_t steps = 0;
    Seconds controllerTime { 0_s };
    for (unsigned i = 0; i < timedPasses; ++i) {
        // Each pass drains its own autoreleased objects, so memory stays flat over the passes.
        @autoreleasepool {
            Pass pass;
            shape(rig, pass);
            if (pass.failure) {
                controllerWrites = nullptr;
                ADD_FAILURE() << pass.failure;
                return;
            }
            steps += pass.steps;
            controllerTime += pass.controllerTime;
        }
    }
    controllerWrites = nullptr;
    double milliseconds = controllerTime.milliseconds();
    SAFE_PRINTF("%s: %.1f ms %.2f MB/s checksum=%016llx\n", name, milliseconds, steps / milliseconds, static_cast<unsigned long long>(first.checksum.value));
    EXPECT_EQ(first.checksum.value, recorded) << name.characters() << " recorded value is " << std::hex << first.checksum.value;
}

} // namespace AppKitGesturesBench

TEST(AppKitGesturesBench, PanScroll)
{
    AppKitGesturesBench::runShape(AppKitGesturesBench::panScrollShape, "PanScroll"_s, AppKitGesturesBench::recordedPanScroll, AppKitGesturesBench::timedPassesPanScroll);
}

TEST(AppKitGesturesBench, MomentumFling)
{
    AppKitGesturesBench::runShape(AppKitGesturesBench::momentumFlingShape, "MomentumFling"_s, AppKitGesturesBench::recordedMomentumFling, AppKitGesturesBench::timedPassesMomentumFling);
}

TEST(AppKitGesturesBench, ClickSequence)
{
    AppKitGesturesBench::runShape(AppKitGesturesBench::clickSequenceShape, "ClickSequence"_s, AppKitGesturesBench::recordedClickSequence, AppKitGesturesBench::timedPassesClickSequence);
}

TEST(AppKitGesturesBench, PointerTracking)
{
    AppKitGesturesBench::runShape(AppKitGesturesBench::pointerTrackingShape, "PointerTracking"_s, AppKitGesturesBench::recordedPointerTracking, AppKitGesturesBench::timedPassesPointerTracking);
}

TEST(AppKitGesturesBench, TransformGesture)
{
    AppKitGesturesBench::runShape(AppKitGesturesBench::transformGestureShape, "TransformGesture"_s, AppKitGesturesBench::recordedTransformGesture, AppKitGesturesBench::timedPassesTransformGesture);
}

TEST(AppKitGesturesBench, GestureArbitration)
{
    AppKitGesturesBench::runShape(AppKitGesturesBench::gestureArbitrationShape, "GestureArbitration"_s, AppKitGesturesBench::recordedGestureArbitration, AppKitGesturesBench::timedPassesGestureArbitration);
}

TEST(AppKitGesturesBench, TouchSession)
{
    AppKitGesturesBench::runShape(AppKitGesturesBench::touchSessionShape, "TouchSession"_s, AppKitGesturesBench::recordedTouchSession, AppKitGesturesBench::timedPassesTouchSession);
}

// A process that only starts and exits: the cost a timed run of a shape subtracts.
TEST(AppKitGesturesBench, StartUp)
{
}

} // namespace TestWebKitAPI

#endif // HAVE(APPKIT_GESTURES_SUPPORT)
