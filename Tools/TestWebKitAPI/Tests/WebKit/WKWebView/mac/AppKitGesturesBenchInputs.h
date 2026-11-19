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

#pragma once

// The scripted gesture sequences and the driver for AppKitGesturesBench.mm.
//
// The driver names no implementation of the gesture controller. It finds the controller as the delegate of the web
// view's own recognizers (webView.gestureRecognizers; the pan recognizer is the one whose action is
// panGestureRecognized:) and calls what AppKit calls: each recognizer's target/action, and the controller's
// NSGestureRecognizerDelegate and deferring/pointer-tracking delegate methods. Each recognizer is isa-swizzled to a
// subclass of its own class whose state, location, translation, velocity, modifiers, timestamp, touches, magnification
// and rotation come from a script, so the controller's identity checks on the recognizer hold.

#if HAVE(APPKIT_GESTURES_SUPPORT)

#import "Helpers/PlatformUtilities.h"
#import "Helpers/cocoa/TestWKWebView.h"
#import <AppKit/AppKit.h>
#import <AppKit/NSGestureRecognizerSubclass.h>
#import <WebKit/WKUIDelegatePrivate.h>
#import <WebKit/WKWebViewPrivate.h>
#import <WebKit/_WKContextMenuElementInfo.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string>
#import <vector>
#import <wtf/MonotonicTime.h>
#import <wtf/RetainPtr.h>

// SPI the recognizers and the controller answer to, declared locally and called only when the object responds.
@interface NSPanGestureRecognizer (AppKitGesturesBenchSPI)
- (BOOL)_canPanHorizontally;
- (BOOL)_canPanVertically;
@end

@interface NSObject (AppKitGesturesBenchController)
- (NSUInteger)numberOfTouches;
- (void)panGestureRecognized:(NSGestureRecognizer *)g;
- (void)domDoubleClickGestureRecognized:(NSGestureRecognizer *)g;
- (void)mouseTrackingGestureRecognized:(NSGestureRecognizer *)g;
- (BOOL)_gestureRecognizer:(NSGestureRecognizer *)a canPreventGestureRecognizer:(NSGestureRecognizer *)b;
- (BOOL)deferringGestureRecognizer:(NSGestureRecognizer *)d shouldDeferOtherGestureRecognizer:(NSGestureRecognizer *)g;
- (void)deferringGestureRecognizer:(NSGestureRecognizer *)d didTransitionToState:(NSGestureRecognizerState)s;
- (void)pointerTrackingGestureRecognizer:(NSGestureRecognizer *)g didUpdateTouchWithState:(NSGestureRecognizerState)s locationInWindow:(NSPoint)p modifierFlags:(NSEventModifierFlags)m;
- (BOOL)everMagnifiedDuringCurrentGesture;
- (BOOL)isPotentialTapInProgress;
- (NSGestureRecognizer *)activeDragGestureRecognizer;
- (void)reset;
- (void)preferencesDidChange;
- (void)didCommitLoadForMainFrame;
- (void)transformGestureWasNotHandledByContent;
- (void)interruptMomentumForScrollWheelEvent;
- (void)cancelClickHighlight;
- (void)beginSuppressingSingleClickGestureForTextSelection;
- (void)endSuppressingSingleClickGestureForTextSelection;
- (void)didReceiveDragStart;
- (void)clearGestureDragState;
@end

// The web view's UI delegate: nothing the controller causes may show a menu, panel or dialog (each would wait for a
// person), so every request is answered at once and recorded. The record is an observation, never part of the checksum
// (the requests arrive from the web process, whose timing the checksum must not depend on).
@interface AGBUIDelegate : NSObject <WKUIDelegate>
@property (nonatomic, readonly) NSMutableArray<NSString *> *requests;
@end
@implementation AGBUIDelegate
- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _requests = [NSMutableArray array];
    return self;
}
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler
{
    [_requests addObject:@"alert"];
    completionHandler();
}
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler
{
    [_requests addObject:@"confirm"];
    completionHandler(NO);
}
- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *))completionHandler
{
    [_requests addObject:@"prompt"];
    completionHandler(nil);
}
- (void)webView:(WKWebView *)webView runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> *))completionHandler
{
    [_requests addObject:@"openpanel"];
    completionHandler(nil);
}
- (void)_webView:(WKWebView *)webView getContextMenuFromProposedMenu:(NSMenu *)menu forElement:(_WKContextMenuElementInfo *)element userInfo:(id<NSSecureCoding>)userInfo completionHandler:(void (^)(NSMenu *))completionHandler
{
    NSMutableString *kind = [NSMutableString stringWithString:@"contextmenu"];
    id hit = [element respondsToSelector:@selector(hitTestResult)] ? [element hitTestResult] : nil;
    for (NSString *key in @[ @"absoluteLinkURL", @"absoluteImageURL", @"absoluteMediaURL" ]) {
        if (hit && [hit respondsToSelector:NSSelectorFromString(key)] && [hit valueForKey:key])
            [kind appendFormat:@" %@", [key substringFromIndex:8]];
    }
    for (NSString *key in @[ @"isContentEditable", @"isSelected" ]) {
        if (hit && [hit respondsToSelector:NSSelectorFromString(key)] && [[hit valueForKey:key] boolValue])
            [kind appendFormat:@" %@", key];
    }
    [_requests addObject:kind];
    completionHandler(nil);
}
@end

@interface AGBScript : NSObject
@property (nonatomic) NSGestureRecognizerState state;
@property (nonatomic) NSPoint locationInWindow;
@property (nonatomic) NSPoint startInWindow;
@property (nonatomic) NSPoint translation;
@property (nonatomic) NSPoint velocity;
@property (nonatomic) NSEventModifierFlags modifiers;
@property (nonatomic) NSTimeInterval timestamp;
@property (nonatomic) NSUInteger touchCount;
@property (nonatomic) CGFloat magnification;
@property (nonatomic) CGFloat rotation; // degrees
@end
@implementation AGBScript
@end

// A touch the recognizers' delegate methods receive.
@interface AGBTouch : NSObject
@property (nonatomic) NSPoint windowPoint;
@property (nonatomic) NSInteger uid;
@end
@implementation AGBTouch
- (NSPoint)locationInView:(NSView *)view { return view ? [view convertPoint:self.windowPoint fromView:nil] : self.windowPoint; }
- (NSInteger)_uid { return self.uid; }
- (NSTouchPhase)phase { return NSTouchPhaseBegan; }
- (NSTouchType)type { return NSTouchTypeDirect; }
- (id<NSObject, NSCopying>)identity { return @(self.uid); }
- (BOOL)isResting { return NO; }
@end

namespace TestWebKitAPI::AppKitGesturesBench {

static constexpr Seconds stepTimeout = 10_s;

struct Fnv {
    uint64_t value { 14695981039346656037ull };

    void hash(uint64_t word)
    {
        for (unsigned i = 0; i < 8; ++i) {
            value ^= static_cast<uint8_t>(word >> (8 * i));
            value *= 1099511628211ull;
        }
    }
    void hashSigned(int64_t word) { hash(static_cast<uint64_t>(word)); }
    // Floating-point values go in rounded to 1/1000, so a harmless last-bit difference does not move the digest.
    void hashDouble(double d) { hashSigned(static_cast<int64_t>(std::llround(d * 1000))); }
    void hashString(const char* s)
    {
        for (; s && *s; ++s) {
            value ^= static_cast<uint8_t>(*s);
            value *= 1099511628211ull;
        }
        value ^= 0xff;
        value *= 1099511628211ull;
    }
};

class Lcg {
public:
    explicit Lcg(uint64_t seed)
        : m_state(seed * 6364136223846793005ull + 1442695040888963407ull)
    {
    }
    uint32_t next()
    {
        m_state = m_state * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<uint32_t>(m_state >> 33);
    }
    int range(int low, int high) { return low + static_cast<int>(next() % static_cast<uint32_t>(high - low + 1)); }
private:
    uint64_t m_state;
};

// What one pass leaves behind. `controllerTime` counts only the calls into the controller (actions and delegate
// methods), not the observations, the page round trip that drains the queues, or the scripting.
struct Pass {
    Fnv checksum;
    uint64_t steps { 0 };
    Seconds controllerTime { 0_s };
    const char* failure { nullptr };
};

static char scriptKey;
static std::vector<std::string>* controllerWrites; // state and translation writes the controller makes, in order

static AGBScript *scriptFor(id recognizer) { return objc_getAssociatedObject(recognizer, &scriptKey); }

// Makes `recognizer` read its script. The subclass is made once per class and reused.
static void drive(NSGestureRecognizer *recognizer)
{
    if (scriptFor(recognizer))
        return;
    Class original = object_getClass(recognizer);
    NSString *name = [@"AGBDriven_" stringByAppendingString:NSStringFromClass(original)];
    name = [name stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    Class driven = NSClassFromString(name);
    if (!driven) {
        driven = objc_allocateClassPair(original, name.UTF8String, 0);
        auto add = [&](SEL sel, id block, const char* types) {
            class_addMethod(driven, sel, imp_implementationWithBlock(block), types);
        };
        add(@selector(state), ^NSGestureRecognizerState(id self) {
            return scriptFor(self).state;
        }, "q@:");
        add(@selector(setState:), ^(id self, NSGestureRecognizerState s) {
            if (controllerWrites)
                controllerWrites->push_back("state=" + std::to_string(static_cast<long>(s)));
            scriptFor(self).state = s;
        }, "v@:q");
        add(@selector(locationInView:), ^NSPoint(id self, NSView *v) {
            NSPoint p = scriptFor(self).locationInWindow;
            return v ? [v convertPoint:p fromView:nil] : p;
        }, "{CGPoint=dd}@:@");
        add(@selector(translationInView:), ^NSPoint(id self, NSView *) {
            return scriptFor(self).translation;
        }, "{CGPoint=dd}@:@");
        add(@selector(setTranslation:inView:), ^(id self, NSPoint t, NSView *) {
            if (controllerWrites)
                controllerWrites->push_back("translation=" + std::to_string(std::llround(t.x * 1000)) + "," + std::to_string(std::llround(t.y * 1000)));
            scriptFor(self).translation = t;
        }, "v@:{CGPoint=dd}@");
        add(@selector(velocityInView:), ^NSPoint(id self, NSView *) {
            return scriptFor(self).velocity;
        }, "{CGPoint=dd}@:@");
        add(@selector(modifierFlags), ^NSEventModifierFlags(id self) {
            return scriptFor(self).modifiers;
        }, "Q@:");
        add(@selector(timestamp), ^NSTimeInterval(id self) {
            return scriptFor(self).timestamp;
        }, "d@:");
        add(@selector(magnification), ^CGFloat(id self) {
            return scriptFor(self).magnification;
        }, "d@:");
        add(@selector(rotation), ^CGFloat(id self) {
            return scriptFor(self).rotation * M_PI / 180;
        }, "d@:");
        add(@selector(rotationInDegrees), ^CGFloat(id self) {
            return scriptFor(self).rotation;
        }, "d@:");
        add(@selector(numberOfTouches), ^NSUInteger(id self) {
            return scriptFor(self).touchCount;
        }, "Q@:");
        add(NSSelectorFromString(@"mouseLocationInWindow"), ^NSPoint(id self) {
            return scriptFor(self).locationInWindow;
        }, "{CGPoint=dd}@:");
        add(NSSelectorFromString(@"startLocationInWindow"), ^NSPoint(id self) {
            return scriptFor(self).startInWindow;
        }, "{CGPoint=dd}@:");
        add(NSSelectorFromString(@"movementInWindowSinceStart"), ^NSSize(id self) {
            AGBScript *s = scriptFor(self);
            return NSMakeSize(s.locationInWindow.x - s.startInWindow.x, s.locationInWindow.y - s.startInWindow.y);
        }, "{CGSize=dd}@:");
        add(NSSelectorFromString(@"_startLocationInView:"), ^NSPoint(id self, NSView *v) {
            NSPoint p = scriptFor(self).startInWindow;
            return v ? [v convertPoint:p fromView:nil] : p;
        }, "{CGPoint=dd}@:@");
        objc_registerClassPair(driven);
    }
    RetainPtr script = adoptNS([[AGBScript alloc] init]);
    [script setState:NSGestureRecognizerStatePossible];
    [script setTouchCount:1];
    objc_setAssociatedObject(recognizer, &scriptKey, script.get(), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    object_setClass(recognizer, driven);
}

struct Pose {
    NSGestureRecognizerState state { NSGestureRecognizerStatePossible };
    NSPoint at { 0, 0 };
    NSPoint start { -1, -1 }; // defaults to `at`
    NSPoint translation { 0, 0 };
    NSPoint velocity { 0, 0 };
    NSEventModifierFlags modifiers { 0 };
    NSUInteger touches { 1 };
    CGFloat magnification { 0 };
    CGFloat rotation { 0 };
};

static constexpr NSGestureRecognizerState Possible = NSGestureRecognizerStatePossible;
static constexpr NSGestureRecognizerState Began = NSGestureRecognizerStateBegan;
static constexpr NSGestureRecognizerState Changed = NSGestureRecognizerStateChanged;
static constexpr NSGestureRecognizerState Ended = NSGestureRecognizerStateEnded;
static constexpr NSGestureRecognizerState Cancelled = NSGestureRecognizerStateCancelled;

static NSString *const pageMarkup = @"<style>body { margin: 0; height: 4000px; width: 4000px; }"
    "#link { position: absolute; left: 20px; top: 20px; } #text { position: absolute; left: 20px; top: 120px; width: 400px; }</style>"
    "<a id='link' href='#x'>a link</a><p id='text'>Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p>";

class Rig {
public:
    RetainPtr<TestWKWebView> webView;
    RetainPtr<id> controller;
    std::vector<RetainPtr<NSGestureRecognizer>> recognizers; // the web view's recognizers whose delegate is the controller, in view order
    std::vector<RetainPtr<NSGestureRecognizer>> foreign; // recognizers of other owners, for the arbitration matrix
    RetainPtr<AGBUIDelegate> uiDelegate;
    double clock { 1000 };
    int64_t touchUID { 1000 };

    bool setUp()
    {
        webView = adoptNS([[TestWKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)]);
        [[webView window] setIgnoresMouseEvents:YES]; // the real pointer must not reach the page
        uiDelegate = adoptNS([[AGBUIDelegate alloc] init]);
        [webView setUIDelegate:uiDelegate.get()]; // no modal UI: see AGBUIDelegate
        [webView loadHTMLString:pageMarkup baseURL:nil];
        bool loaded = Util::waitFor([&] {
            return [[webView objectByEvaluatingJavaScript:@"document.readyState == 'complete'"] boolValue];
        });
        if (!loaded)
            return false;
        __block bool done = false;
        [webView _doAfterNextPresentationUpdate:^{
            done = true;
        }];
        if (!Util::runFor(&done, stepTimeout))
            return false;

        for (NSGestureRecognizer *g in webView.get().gestureRecognizers) {
            if (g.action == @selector(panGestureRecognized:))
                controller = g.delegate;
        }
        if (!controller)
            return false;
        for (NSGestureRecognizer *g in webView.get().gestureRecognizers) {
            if (g.delegate == controller.get()) {
                drive(g);
                recognizers.push_back(g);
            }
        }
        // Other kinds the controller's arbitration methods see: a scroll view's pan, a magnification, a click, a press.
        foreign.push_back(adoptNS([[NSPanGestureRecognizer alloc] init]));
        foreign.push_back(adoptNS([[NSMagnificationGestureRecognizer alloc] init]));
        foreign.push_back(adoptNS([[NSClickGestureRecognizer alloc] init]));
        foreign.push_back(adoptNS([[NSPressGestureRecognizer alloc] init]));
        for (auto& g : foreign)
            drive(g.get());
        return true;
    }

    // The first recognizer whose action is `action` (`index` selects among several, such as the mouse-tracking ones).
    NSGestureRecognizer *byAction(SEL action, unsigned index = 0)
    {
        for (auto& g : recognizers) {
            if (g.get().action == action && !index--)
                return g.get();
        }
        return nil;
    }
    NSGestureRecognizer *byName(NSString *name)
    {
        for (auto& g : recognizers) {
            if ([g.get().name isEqualToString:name])
                return g.get();
        }
        return nil;
    }
    NSGestureRecognizer *deferring(unsigned index)
    {
        for (auto& g : recognizers) {
            if (!g.get().action && !index--)
                return g.get();
        }
        return nil;
    }

    NSPoint toWindow(NSPoint inView) { return [webView convertPoint:inView toView:nil]; }

    void pose(NSGestureRecognizer *g, const Pose& p)
    {
        AGBScript *s = scriptFor(g);
        s.state = p.state;
        s.locationInWindow = toWindow(p.at);
        s.startInWindow = toWindow(p.start.x < 0 ? p.at : p.start);
        s.translation = p.translation;
        s.velocity = p.velocity;
        s.modifiers = p.modifiers;
        s.touchCount = p.touches;
        s.magnification = p.magnification;
        s.rotation = p.rotation;
        clock += 1.0 / 60;
        s.timestamp = clock;
    }

    RetainPtr<AGBTouch> touchAt(NSPoint inView)
    {
        RetainPtr t = adoptNS([[AGBTouch alloc] init]);
        [t setUid:++touchUID];
        [t setWindowPoint:toWindow(inView)];
        return t;
    }

    // Waits until the web process has answered everything sent so far (replies arrive in order, ahead of this
    // script's reply), so the next gesture starts from the same state on every run. Never inside a timed region.
    bool drain()
    {
        __block bool done = false;
        [webView evaluateJavaScript:@"0" completionHandler:^(id, NSError *) { done = true; }];
        return Util::runFor(&done, stepTimeout);
    }
};

// MARK: - Observation (untimed): what the controller leaves visible.

static void observe(Rig& rig, Pass& pass)
{
    Fnv& h = pass.checksum;
    if (controllerWrites) {
        for (auto& w : *controllerWrites)
            h.hashString(w.c_str());
        h.hash(controllerWrites->size());
        controllerWrites->clear();
    }
    for (auto& g : rig.recognizers) {
        h.hash(static_cast<uint64_t>(scriptFor(g.get()).state));
        h.hash(g.get().enabled ? 1 : 0);
    }
    id c = rig.controller.get();
    h.hash([c respondsToSelector:@selector(everMagnifiedDuringCurrentGesture)] ? [c everMagnifiedDuringCurrentGesture] : 2);
    h.hash([c respondsToSelector:@selector(isPotentialTapInProgress)] ? [c isPotentialTapInProgress] : 2);
    if ([c respondsToSelector:@selector(activeDragGestureRecognizer)]) {
        NSGestureRecognizer *d = [c activeDragGestureRecognizer];
        h.hashString(d ? (d.name ?: @"?").UTF8String : "nil");
    }
    if (auto* pan = static_cast<NSPanGestureRecognizer *>(rig.byAction(@selector(panGestureRecognized:)))) {
        h.hash([pan respondsToSelector:@selector(_canPanHorizontally)] ? [pan _canPanHorizontally] : 2);
        h.hash([pan respondsToSelector:@selector(_canPanVertically)] ? [pan _canPanVertically] : 2);
    }
    ++pass.steps;
}

#define TIMED(pass, expression) do { auto timedStart_ = MonotonicTime::now(); expression; (pass).controllerTime += MonotonicTime::now() - timedStart_; } while (0)

static void hashDecision(Pass& pass, bool value) { pass.checksum.hash(value ? 1 : 0); }

// One recognizer step: pose it, call its action as AppKit would, observe.
static void step(Rig& rig, Pass& pass, NSGestureRecognizer *g, const Pose& p)
{
    if (!g) {
        pass.failure = "a recognizer the shape needs is missing";
        return;
    }
    rig.pose(g, p);
    id target = g.target;
    SEL action = g.action;
    if (!target || !action) {
        pass.failure = "a recognizer has no action";
        return;
    }
    TIMED(pass, ((void (*)(id, SEL, id))objc_msgSend)(target, action, g));
    observe(rig, pass);
}

static void shouldBegin(Rig& rig, Pass& pass, NSGestureRecognizer *g, const Pose& p)
{
    if (!g) {
        pass.failure = "a recognizer the shape needs is missing";
        return;
    }
    rig.pose(g, p);
    bool result;
    TIMED(pass, result = [(id<NSGestureRecognizerDelegate>)rig.controller.get() gestureRecognizerShouldBegin:g]);
    hashDecision(pass, result);
}

static void shouldReceiveTouch(Rig& rig, Pass& pass, NSGestureRecognizer *g, NSPoint at)
{
    if (!g) {
        pass.failure = "a recognizer the shape needs is missing";
        return;
    }
    auto touch = rig.touchAt(at);
    bool result;
    TIMED(pass, result = [(id<NSGestureRecognizerDelegate>)rig.controller.get() gestureRecognizer:g shouldReceiveTouch:(NSTouch *)touch.get()]);
    hashDecision(pass, result);
    observe(rig, pass);
}

template<typename F> static void entry(Rig& rig, Pass& pass, F&& call)
{
    TIMED(pass, call(rig.controller.get()));
    observe(rig, pass);
}

static void batchEnd(Rig& rig, Pass& pass)
{
    if (!pass.failure && !rig.drain())
        pass.failure = "the web process did not answer within stepTimeout";
}

static NSPoint pointInView(Lcg& random) { return NSMakePoint(random.range(40, 760), random.range(40, 560)); }

// MARK: - Shapes. Each runs `count` gestures; a gesture's steps run back to back, and the queues drain between gestures.

static void panGesture(Rig& rig, Pass& pass, Lcg& random, bool fling)
{
    auto pan = rig.byAction(@selector(panGestureRecognized:));
    NSPoint at = pointInView(random);
    NSUInteger touches = !random.range(0, 4) ? 2 : 1;
    NSEventModifierFlags flags = !random.range(0, 7) ? NSEventModifierFlagShift : 0;
    shouldReceiveTouch(rig, pass, pan, at);
    shouldBegin(rig, pass, pan, { .at = at, .touches = touches });
    // Axis shape: 0 vertical, 1 horizontal, 2 diagonal.
    int axis = random.range(0, 2);
    NSPoint total = at;
    unsigned moves = random.range(3, 12);
    for (unsigned i = 0; i < moves && !pass.failure; ++i) {
        double dx = !axis ? random.range(-2, 2) : random.range(-14, 14);
        double dy = axis == 1 ? random.range(-2, 2) : random.range(-14, 14);
        total = NSMakePoint(total.x + dx, total.y + dy);
        step(rig, pass, pan, { .state = i ? Changed : Began, .at = total, .start = at, .translation = NSMakePoint(dx, dy), .modifiers = flags, .touches = touches });
    }
    double speed = fling ? random.range(1200, 2400) : random.range(0, 19);
    NSPoint velocity = NSMakePoint(!axis ? 0 : speed * (random.range(0, 1) ? 1 : -1), axis == 1 ? 0 : speed * (random.range(0, 1) ? 1 : -1));
    step(rig, pass, pan, { .state = Ended, .at = total, .start = at, .velocity = velocity, .modifiers = flags, .touches = touches });
    if (fling) {
        // The momentum's generator becomes active when the web process has answered the momentum's first event, so the
        // gesture drains first (it is then active on every run: the fling is fast enough to outlast the drain), and a
        // new touch on the moving page then interrupts it, ending it inside the shape. No momentum event, which
        // follows the display link, can reach the controller at a timing-dependent point.
        batchEnd(rig, pass);
        shouldReceiveTouch(rig, pass, pan, pointInView(random));
        entry(rig, pass, [](id c) {
            if ([c respondsToSelector:@selector(interruptMomentumForScrollWheelEvent)])
                [c interruptMomentumForScrollWheelEvent];
        });
    }
    batchEnd(rig, pass);
}

static void clickGesture(Rig& rig, Pass& pass, Lcg& random, unsigned kind)
{
    NSPoint at = random.range(0, 1) ? NSMakePoint(30, 30) : pointInView(random); // over the link, or anywhere
    NSEventModifierFlags flags = kind == 4 ? NSEventModifierFlagCommand : 0;
    NSGestureRecognizer *g = nil;
    SEL kindName = nil;
    switch (kind) {
    case 0: case 4: g = rig.byName(@"WKSingleClickGesture"); break;
    case 1: g = rig.byName(@"WKDoubleClickGesture"); break;
    case 2: g = rig.byAction(@selector(domDoubleClickGestureRecognized:)); break;
    default: g = rig.byName(@"WKSecondaryClickGesture"); break;
    }
    (void)kindName;
    shouldReceiveTouch(rig, pass, g, at);
    shouldBegin(rig, pass, g, { .at = at, .modifiers = flags });
    step(rig, pass, g, { .state = Began, .at = at, .modifiers = flags });
    step(rig, pass, g, { .state = random.range(0, 5) ? Ended : Cancelled, .at = at, .modifiers = flags });
    batchEnd(rig, pass);
}

static void pointerGesture(Rig& rig, Pass& pass, Lcg& random)
{
    id c = rig.controller.get();
    auto g = rig.byName(@"WKPointerTrackingGesture");
    NSPoint at = pointInView(random);
    NSEventModifierFlags flags = !random.range(0, 3) ? NSEventModifierFlagOption : 0;
    shouldBegin(rig, pass, g, { .at = at, .modifiers = flags });
    auto update = [&](NSGestureRecognizerState state, NSPoint p) {
        if (!g || ![c respondsToSelector:@selector(pointerTrackingGestureRecognizer:didUpdateTouchWithState:locationInWindow:modifierFlags:)]) {
            pass.failure = "no pointer tracking recognizer";
            return;
        }
        rig.pose(g, { .state = state, .at = p, .modifiers = flags });
        TIMED(pass, [c pointerTrackingGestureRecognizer:g didUpdateTouchWithState:state locationInWindow:rig.toWindow(p) modifierFlags:flags]);
        observe(rig, pass);
    };
    update(Began, at);
    unsigned moves = random.range(2, 10);
    for (unsigned i = 0; i < moves && !pass.failure; ++i) {
        at = NSMakePoint(at.x + random.range(-6, 6), at.y + random.range(-6, 6));
        update(Changed, at);
    }
    update(random.range(0, 4) ? Ended : Cancelled, at);
    batchEnd(rig, pass);
}

static void transformGesture(Rig& rig, Pass& pass, Lcg& random)
{
    auto magnify = rig.byName(@"WKMagnificationGesture");
    auto rotate = rig.byName(@"WKRotationGesture");
    auto tracking = rig.byAction(@selector(mouseTrackingGestureRecognized:));
    NSPoint at = pointInView(random);
    [rig.webView setAllowsMagnification:!!random.range(0, 3)];
    bool rotation = rotate && !random.range(0, 2);
    auto gesture = rotation ? rotate : magnify;
    double scale = 0;
    double angle = 0;
    unsigned moves = random.range(2, 8);
    for (unsigned i = 0; i < moves && !pass.failure; ++i) {
        scale += random.range(-30, 60) / 1000.0;
        angle += random.range(-30, 30);
        step(rig, pass, gesture, { .state = i ? Changed : Began, .at = at, .touches = 2, .magnification = scale, .rotation = angle });
    }
    step(rig, pass, gesture, { .state = Ended, .at = at, .touches = 2, .magnification = scale, .rotation = angle });
    // Mouse tracking just after the transform ends: suppressed inside the controller's 50 ms window. This follows the
    // transform within microseconds, never across a drain.
    if (tracking && random.range(0, 1)) {
        step(rig, pass, tracking, { .state = Began, .at = at });
        step(rig, pass, tracking, { .state = Changed, .at = NSMakePoint(at.x + 3, at.y + 3), .start = at });
        step(rig, pass, tracking, { .state = Ended, .at = NSMakePoint(at.x + 3, at.y + 3), .start = at });
    }
    if (!random.range(0, 3)) {
        entry(rig, pass, [](id c) {
            if ([c respondsToSelector:@selector(transformGestureWasNotHandledByContent)])
                [c transformGestureWasNotHandledByContent];
        });
    }
    batchEnd(rig, pass);
}

static void arbitrationMatrix(Rig& rig, Pass& pass)
{
    id<NSGestureRecognizerDelegate> c = (id<NSGestureRecognizerDelegate>)rig.controller.get();
    std::vector<NSGestureRecognizer *> all;
    for (auto& g : rig.recognizers)
        all.push_back(g.get());
    for (auto& g : rig.foreign)
        all.push_back(g.get());
    for (auto* a : all) {
        for (auto* b : all) {
            if (a == b)
                continue;
            bool simultaneous, requireFailure, requiredToFail, prevent = false;
            TIMED(pass, simultaneous = [c gestureRecognizer:a shouldRecognizeSimultaneouslyWithGestureRecognizer:b]);
            TIMED(pass, requireFailure = [c gestureRecognizer:a shouldRequireFailureOfGestureRecognizer:b]);
            TIMED(pass, requiredToFail = [c gestureRecognizer:a shouldBeRequiredToFailByGestureRecognizer:b]);
            if ([(id)c respondsToSelector:@selector(_gestureRecognizer:canPreventGestureRecognizer:)])
                TIMED(pass, prevent = [(id)c _gestureRecognizer:a canPreventGestureRecognizer:b]);
            pass.checksum.hash(simultaneous | (requireFailure << 1) | (requiredToFail << 2) | (prevent << 3));
            ++pass.steps;
        }
    }
    // Deferral: each deferring recognizer against every other recognizer.
    for (unsigned d = 0; auto* deferring = rig.deferring(d); ++d) {
        for (auto* other : all) {
            bool defers = false;
            if ([(id)c respondsToSelector:@selector(deferringGestureRecognizer:shouldDeferOtherGestureRecognizer:)])
                TIMED(pass, defers = [(id)c deferringGestureRecognizer:deferring shouldDeferOtherGestureRecognizer:other]);
            hashDecision(pass, defers);
            ++pass.steps;
        }
    }
    // shouldBegin for every own recognizer at points inside the view, at its edge (scrollbar) and outside.
    static const NSPoint points[] = { { 100, 100 }, { 400, 300 }, { 795, 300 }, { 400, 598 }, { 900, 700 } };
    for (auto& g : rig.recognizers) {
        for (auto point : points) {
            rig.pose(g.get(), { .at = point });
            bool result;
            TIMED(pass, result = [c gestureRecognizerShouldBegin:g.get()]);
            hashDecision(pass, result);
            ++pass.steps;
        }
    }
    observe(rig, pass);
}

// A mixed session: the gestures above interleaved by the generator, with deferral, drag and lifecycle calls.
static void sessionStep(Rig& rig, Pass& pass, Lcg& random)
{
    switch (random.range(0, 11)) {
    case 0: case 1: case 2: panGesture(rig, pass, random, false); break;
    case 3: case 4: panGesture(rig, pass, random, true); break;
    case 5: case 6: clickGesture(rig, pass, random, random.range(0, 4)); break;
    case 7: pointerGesture(rig, pass, random); break;
    case 8: transformGesture(rig, pass, random); break;
    case 9: {
        // Text-selection suppression around a click.
        entry(rig, pass, [](id c) {
            [c beginSuppressingSingleClickGestureForTextSelection];
        });
        clickGesture(rig, pass, random, 0);
        entry(rig, pass, [](id c) {
            [c endSuppressingSingleClickGestureForTextSelection];
        });
        break;
    }
    case 10: {
        // A drag press and its lifecycle.
        auto drag = rig.byName(@"WKDragPressGesture");
        NSPoint at = pointInView(random);
        shouldBegin(rig, pass, drag, { .at = at });
        step(rig, pass, drag, { .state = Began, .at = at });
        entry(rig, pass, [](id c) {
            [c didReceiveDragStart];
        });
        step(rig, pass, drag, { .state = Ended, .at = at });
        entry(rig, pass, [](id c) {
            [c clearGestureDragState];
        });
        batchEnd(rig, pass);
        break;
    }
    default: {
        entry(rig, pass, [](id c) {
            [c preferencesDidChange];
        });
        entry(rig, pass, [](id c) {
            [c cancelClickHighlight];
        });
        if (!random.range(0, 3)) {
            entry(rig, pass, [](id c) {
                [c reset];
            });
            batchEnd(rig, pass);
        }
        break;
    }
    }
    for (unsigned d = 0; auto* deferring = rig.deferring(d); ++d) {
        if ([(id)rig.controller.get() respondsToSelector:@selector(deferringGestureRecognizer:didTransitionToState:)] && !random.range(0, 5))
            TIMED(pass, [(id)rig.controller.get() deferringGestureRecognizer:deferring didTransitionToState:NSGestureRecognizerStateFailed]);
    }
}

} // namespace TestWebKitAPI::AppKitGesturesBench

#endif // HAVE(APPKIT_GESTURES_SUPPORT)
