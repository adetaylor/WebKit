/*
 * Copyright (C) 2008-2017 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#import "config.h"
#import "ScrollbarThemeMac.h"

#if PLATFORM(MAC)

#import "ColorMac.h"
#import "GraphicsLayer.h"
#import "ImageBuffer.h"
#import "LocalCurrentGraphicsContext.h"
#import "LocalDefaultSystemAppearance.h"
#import "NSScrollerImpDetails.h"
#import "PlatformMouseEvent.h"
#import "ScrollTypesMac.h"
#import "ScrollView.h"
#import "ScrollbarInlines.h"
#import "ScrollbarMac.h"
#import "ScrollbarTrackCornerSystemImageMac.h"
#import <QuartzCore/CALayer.h>
#import <pal/spi/cg/CoreGraphicsSPI.h>
#import <pal/spi/mac/CoreUISPI.h>
#import <pal/spi/mac/NSAppearanceSPI.h>
#import <pal/spi/mac/NSScrollerImpSPI.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/HashMap.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/SetForScope.h>
#import <wtf/StdLibExtras.h>

// FIXME: There are repainting problems due to Aqua scroll bar buttons' visual overflow.

@interface NSScrollerImp (WebKitSnapshot)
- (void)displayLayer:(CALayer *)layer;
@end

@interface WebSnapshotScrollerImpDelegate : NSObject<NSScrollerImpDelegate, CALayerDelegate>
@property (nonatomic) BOOL useDarkAppearance;
@property (nonatomic, weak) NSScrollerImp *scrollerImp;
@end

@implementation WebSnapshotScrollerImpDelegate

- (NSRect)convertRectToBacking:(NSRect)rect
{
    return rect;
}

- (NSRect)convertRectFromBacking:(NSRect)rect
{
    return rect;
}

- (BOOL)shouldUseLayerPerPartForScrollerImp:(NSScrollerImp *)scrollerImp
{
    return YES;
}

- (NSAppearance *)effectiveAppearanceForScrollerImp:(NSScrollerImp *)scrollerImp
{
    if (auto *appearance = [NSAppearance appearanceNamed:self.useDarkAppearance ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua])
        return appearance;
    return [NSAppearance currentDrawingAppearance];
}

- (void)displayLayer:(CALayer *)layer
{
    // Work around an issue where NSScrollerImp creates layers with NaN corner
    // radii, which the window server interprets as "maximum radius given the
    // size of the layer", but which renderInContext: does not seem to handle.
    [self.scrollerImp displayLayer:layer];
    if (std::isnan(static_cast<double>([layer cornerRadius]))) {
        CGRect frame = [layer frame];
        [layer setCornerRadius:0.5 * std::min(frame.size.width, frame.size.height)];
    }
}

- (CALayer *)layer { return nil; }
- (void)scrollerImp:(NSScrollerImp *)scrollerImp animateKnobAlphaTo:(CGFloat)newKnobAlpha duration:(NSTimeInterval)duration { }
- (void)scrollerImp:(NSScrollerImp *)scrollerImp animateTrackAlphaTo:(CGFloat)newTrackAlpha duration:(NSTimeInterval)duration { }
- (void)scrollerImp:(NSScrollerImp *)scrollerImp overlayScrollerStateChangedTo:(NSOverlayScrollerState)newOverlayScrollerState { }
@end


namespace WebCore {

using ScrollbarSet = HashSet<SingleThreadWeakRef<Scrollbar>>;

NODELETE static ScrollbarSet& scrollbarMap()
{
    static NeverDestroyed<ScrollbarSet> instances;
    return instances;
}

} // namespace WebCore

using WebCore::ScrollbarTheme;
using WebCore::ScrollbarThemeMac;
using WebCore::scrollbarMap;
using WebCore::ScrollbarSet;

@interface WebScrollbarPrefsObserver : NSObject
{
}

+ (void)registerAsObserver;
+ (void)appearancePrefsChanged:(NSNotification *)theNotification;
+ (void)behaviorPrefsChanged:(NSNotification *)theNotification;

@end

@implementation WebScrollbarPrefsObserver

+ (void)appearancePrefsChanged:(NSNotification *)unusedNotification
{
    UNUSED_PARAM(unusedNotification);

    ScrollbarTheme& theme = ScrollbarTheme::theme();
    if (theme.isMockTheme())
        return;

    downcast<ScrollbarThemeMac>(theme).preferencesChanged();

    for (auto& scrollbar : scrollbarMap()) {
        scrollbar->styleChanged();
        scrollbar->invalidate();
    }
}

+ (void)behaviorPrefsChanged:(NSNotification *)unusedNotification
{
    UNUSED_PARAM(unusedNotification);

    ScrollbarTheme& theme = ScrollbarTheme::theme();
    if (theme.isMockTheme())
        return;

    downcast<ScrollbarThemeMac>(theme).preferencesChanged();
}

+ (void)registerAsObserver
{
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(appearancePrefsChanged:) name:@"AppleAquaScrollBarVariantChanged" object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(behaviorPrefsChanged:) name:@"AppleNoRedisplayAppearancePreferenceChanged" object:nil suspensionBehavior:NSNotificationSuspensionBehaviorCoalesce];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(behaviorPrefsChanged:) name:NSPreferredScrollerStyleDidChangeNotification object:nil];
}

@end

namespace WebCore {

ScrollbarTheme& ScrollbarTheme::nativeTheme()
{
    static NeverDestroyed<ScrollbarThemeMac> theme;
    return theme;
}

static bool gJumpOnTrackClick = false;
static bool gUsesOverlayScrollbars = false;

static ScrollbarButtonsPlacement gButtonPlacement = ScrollbarButtonsDoubleEnd;

void ScrollbarThemeMac::didCreateScrollerImp(Scrollbar& scrollbar)
{
#if PLATFORM(MAC)
    RetainPtr scrollerImp = scrollerImpForScrollbar(scrollbar);
    ASSERT(scrollerImp);
    scrollerImp.get().userInterfaceLayoutDirection = protect(scrollbar.scrollableArea())->shouldPlaceVerticalScrollbarOnLeft() ? NSUserInterfaceLayoutDirectionRightToLeft : NSUserInterfaceLayoutDirectionLeftToRight;
#else
    UNUSED_PARAM(scrollbar);
#endif
}

void ScrollbarThemeMac::registerScrollbar(Scrollbar& scrollbar)
{
    if (scrollbar.isCustomScrollbar() || !scrollbar.shouldRegisterScrollbar())
        return;

    scrollbarMap().add(scrollbar);
}

void ScrollbarThemeMac::unregisterScrollbar(Scrollbar& scrollbar)
{
    scrollbarMap().take(scrollbar);
}

NSScrollerImp *ScrollbarThemeMac::scrollerImpForScrollbar(Scrollbar& scrollbar)
{
    if (auto* macScrollbar = dynamicDowncast<ScrollbarMac>(scrollbar))
        return macScrollbar->scrollerImp();
    return nil;
}

bool ScrollbarThemeMac::isLayoutDirectionRTL(Scrollbar& scrollbar)
{
#if PLATFORM(MAC)
    RetainPtr scrollerImp = scrollerImpForScrollbar(scrollbar);
    if (!scrollerImp) {
        if (!scrollbar.shouldRegisterScrollbar())
            return protect(scrollbar.scrollableArea())->shouldPlaceVerticalScrollbarOnLeft() ? NSUserInterfaceLayoutDirectionRightToLeft : NSUserInterfaceLayoutDirectionLeftToRight;
        return false;
    }
    return scrollerImp.get().userInterfaceLayoutDirection == NSUserInterfaceLayoutDirectionRightToLeft;
#else
    UNUSED_PARAM(scrollbar);
    return false;
#endif
}

static bool g_isCurrentlyDrawingIntoLayer;
    
bool ScrollbarThemeMac::isCurrentlyDrawingIntoLayer()
{
    return g_isCurrentlyDrawingIntoLayer;
}

void ScrollbarThemeMac::setIsCurrentlyDrawingIntoLayer(bool b)
{
    g_isCurrentlyDrawingIntoLayer = b;
}

ScrollbarThemeMac::ScrollbarThemeMac()
{
    static bool initialized;
    if (!initialized) {
        initialized = true;
        gButtonPlacement = ScrollbarButtonsNone;
        [WebScrollbarPrefsObserver registerAsObserver];
        preferencesChanged();
    }
}

ScrollbarThemeMac::~ScrollbarThemeMac() = default;

void ScrollbarThemeMac::preferencesChanged()
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults synchronize];
    gJumpOnTrackClick = [defaults boolForKey:@"AppleScrollerPagingBehavior"];
    usesOverlayScrollbarsChanged();
}

int ScrollbarThemeMac::scrollbarThickness(ScrollbarWidth scrollbarWidth, OverlayScrollbarSizeRelevancy overlayRelevancy)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    if (scrollbarWidth == ScrollbarWidth::None || (usesOverlayScrollbars() && overlayRelevancy == OverlayScrollbarSizeRelevancy::IgnoreOverlayScrollbarSize))
        return 0;

    return [[NSScrollerImp self] scrollerWidthForControlSize:nsControlSizeFromScrollbarWidth(scrollbarWidth) scrollerStyle:ScrollerStyle::recommendedScrollerStyle()];
    END_BLOCK_OBJC_EXCEPTIONS
}

bool ScrollbarThemeMac::usesOverlayScrollbars() const
{
    return gUsesOverlayScrollbars;
}

void ScrollbarThemeMac::usesOverlayScrollbarsChanged()
{
    gUsesOverlayScrollbars = ScrollerStyle::recommendedScrollerStyle() == NSScrollerStyleOverlay;
}

void ScrollbarThemeMac::updateScrollbarOverlayStyle(Scrollbar& scrollbar)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    RetainPtr painter = scrollerImpForScrollbar(scrollbar);
    switch (scrollbar.scrollableArea().scrollbarOverlayStyle()) {
    case ScrollbarOverlayStyle::Default:
        [painter setKnobStyle:NSScrollerKnobStyleDefault];
        break;
    case ScrollbarOverlayStyle::Dark:
        [painter setKnobStyle:NSScrollerKnobStyleDark];
        break;
    case ScrollbarOverlayStyle::Light:
        [painter setKnobStyle:NSScrollerKnobStyleLight];
        break;
    }
    END_BLOCK_OBJC_EXCEPTIONS
}

ScrollbarButtonsPlacement ScrollbarThemeMac::buttonsPlacement() const
{
    return gButtonPlacement;
}

int ScrollbarThemeMac::minimumThumbLength(Scrollbar& scrollbar)
{
    if (scrollbar.shouldRegisterScrollbar()) {
        BEGIN_BLOCK_OBJC_EXCEPTIONS
        return [protect(scrollerImpForScrollbar(scrollbar)) knobMinLength];
        END_BLOCK_OBJC_EXCEPTIONS
    } else
        return scrollbar.minimumThumbLength();
}

NODELETE static bool shouldCenterOnThumb(const PlatformMouseEvent& evt)
{
    if (evt.button() != MouseButton::Left)
        return false;
    if (gJumpOnTrackClick)
        return !evt.altKey();
    return evt.altKey();
}

ScrollbarButtonPressAction ScrollbarThemeMac::handleMousePressEvent(Scrollbar&, const PlatformMouseEvent& event, ScrollbarPart pressedPart)
{
    if (event.button() == MouseButton::Right)
        return ScrollbarButtonPressAction::None;

    switch (pressedPart) {
    case BackTrackPart:
    case ForwardTrackPart:
        if (shouldCenterOnThumb(event))
            return ScrollbarButtonPressAction::CenterOnThumb;
        break;
    case ThumbPart:
        return ScrollbarButtonPressAction::StartDrag;
    default:
        break;
    }

    return ScrollbarButtonPressAction::Scroll;
}

bool ScrollbarThemeMac::shouldDragDocumentInsteadOfThumb(Scrollbar&, const PlatformMouseEvent& event)
{
    return event.altKey();
}

void ScrollbarThemeMac::updateEnabledState(Scrollbar& scrollbar)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    [protect(scrollerImpForScrollbar(scrollbar)) setEnabled:scrollbar.enabled()];
    END_BLOCK_OBJC_EXCEPTIONS
}

static std::pair<float, float> scrollbarValueAndProportion(Scrollbar& scrollbar)
{
    float value;
    float overhang;
    ScrollableArea::computeScrollbarValueAndOverhang(scrollbar.currentPos(), scrollbar.totalSize(), scrollbar.visibleSize(), value, overhang);
    float proportion = scrollbar.totalSize() > 0 ? (static_cast<CGFloat>(scrollbar.visibleSize()) - overhang) / scrollbar.totalSize() : 1;
    return { value, proportion };
}

void ScrollbarThemeMac::setPaintCharacteristicsForScrollbar(NSScrollerImp *painter, Scrollbar& scrollbar)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    auto [value, proportion] = scrollbarValueAndProportion(scrollbar);

    [painter setEnabled:scrollbar.enabled()];
    [painter setBoundsSize:scrollbar.frameRect().size()];
    [painter setDoubleValue:value];
#if PLATFORM(MAC)
    [painter setPresentationValue:value];
#endif
    [painter setKnobProportion:proportion];
    END_BLOCK_OBJC_EXCEPTIONS
}

static void paintScrollbarUsingLayersForSnapshot(Scrollbar& scrollbar, GraphicsContext& context)
{
    if (ScrollerStyle::recommendedScrollerStyle() == NSScrollerStyleOverlay)
        return;

    LocalCurrentGraphicsContext localContext { context };

    RetainPtr scrollerImp = [NSScrollerImp scrollerImpWithStyle:NSScrollerStyleLegacy controlSize:nsControlSizeFromScrollbarWidth(scrollbar.widthStyle()) horizontal:scrollbar.orientation() == ScrollbarOrientation::Horizontal replacingScrollerImp:nil];
    CheckedRef scrollableArea = scrollbar.scrollableArea();
    auto [value, proportion] = scrollbarValueAndProportion(scrollbar);
    auto scrollbarColor = scrollableArea->scrollbarColorStyle();
    setScrollerImpValues(scrollerImp.get(), {
        .isEnabled = scrollbar.enabled(),
        .layoutDirection = scrollableArea->shouldPlaceVerticalScrollbarOnLeft() ? UserInterfaceLayoutDirection::RTL : UserInterfaceLayoutDirection::LTR,
        .size = scrollbar.frameRect().size(),
        .value = value,
        .proportion = proportion,
        .trackColor = scrollbarColor ? cocoaColor(scrollbarColor->trackColor) : RetainPtr<NSColor> { },
        .thumbColor = scrollbarColor ? cocoaColor(scrollbarColor->thumbColor) : RetainPtr<NSColor> { },
    });

    RetainPtr delegate = adoptNS([[WebSnapshotScrollerImpDelegate alloc] init]);
    [delegate setUseDarkAppearance:scrollableArea->useDarkAppearanceForScrollbars()];
    [delegate setScrollerImp:scrollerImp.get()];
    [scrollerImp setDelegate:delegate.get()];

    auto size = scrollbar.frameRect().size();

    RetainPtr hostLayer = adoptNS([[CALayer alloc] init]);
    [hostLayer setBounds:CGRectMake(0, 0, size.width(), size.height())];
    [hostLayer setContentsScale:scrollbar.deviceScaleFactor()];
    [hostLayer setGeometryFlipped:YES];
    [scrollerImp setLayer:hostLayer.get()];

    for (CALayer *sublayer in [hostLayer sublayers])
        [sublayer setDelegate:delegate.get()];

    [hostLayer renderInContext:protect(localContext.cgContext())];

    // The scroller is autoreleased, so it can outlive the delegate, which it does not retain.
    [scrollerImp setLayer:nil];
    [scrollerImp setDelegate:nil];
}

static void paintScrollbarUsingLegacyAppearance(Scrollbar& scrollbar, GraphicsContext& context)
{
    LocalCurrentGraphicsContext localContext { context };

    RetainPtr scrollerImp = ScrollbarThemeMac::scrollerImpForScrollbar(scrollbar);
    // Use rectForPart: here; it will take the expansion transition progress into account.
    NSRect trackRect = [scrollerImp rectForPart:NSScrollerKnobSlot];
    [scrollerImp drawKnobSlotInRect:trackRect highlight:NO];

    // If the scrollbar is not enabled, then there is nothing to scroll to, and we shouldn't
    // call drawKnob.
    if (scrollbar.enabled())
        [scrollerImp drawKnob];
}

static void paintScrollbar(Scrollbar& scrollbar, GraphicsContext& context, OptionSet<ScrollbarPaintBehavior> paintBehavior)
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    if (paintBehavior.contains(ScrollbarPaintBehavior::Snapshot) && scrollbar.supportsUpdateOnSecondaryThread())
        paintScrollbarUsingLayersForSnapshot(scrollbar, context);
    else
        paintScrollbarUsingLegacyAppearance(scrollbar, context);
    END_BLOCK_OBJC_EXCEPTIONS
}

bool ScrollbarThemeMac::paint(Scrollbar& scrollbar, GraphicsContext& context, const IntRect& damageRect, OptionSet<ScrollbarPaintBehavior> paintBehavior)
{
    if (context.paintingDisabled())
        return false;

    setPaintCharacteristicsForScrollbar(protect(scrollerImpForScrollbar(scrollbar)).get(), scrollbar);

    if (scrollbar.supportsUpdateOnSecondaryThread() && !paintBehavior.contains(ScrollbarPaintBehavior::Snapshot))
        return true;

    SetForScope isCurrentlyDrawingIntoLayer(g_isCurrentlyDrawingIntoLayer, context.isCALayerContext());

    GraphicsContextStateSaver stateSaver(context);
    context.clip(damageRect);

    auto scrollbarRect = scrollbar.frameRect();
    if (context.hasPlatformContext()) {
        context.translate(scrollbarRect.location());
        paintScrollbar(scrollbar, context, paintBehavior);
    } else {
        // AppKit draws the scroll bar into a CGContext, so display list and PDF contexts get an Unaccelerated buffer.
        auto renderingMode = context.renderingMode() == RenderingMode::Accelerated ? RenderingMode::Accelerated : RenderingMode::Unaccelerated;
        if (auto imageBuffer = [&] -> RefPtr<ImageBuffer> {
            if (auto buffer = context.createImageBuffer(scrollbarRect.size(), scrollbar.deviceScaleFactor(), ColorSpace::SRGB(), renderingMode, RenderingMethod::Local)) {
                paintScrollbar(scrollbar, buffer->context(), paintBehavior);
                return buffer;
            }
            return nullptr;
        }())
            context.drawImageBuffer(*imageBuffer, scrollbarRect);
    }

    return true;
}

void ScrollbarThemeMac::paintScrollCorner(ScrollableArea& area, GraphicsContext& context, const IntRect& cornerRect)
{
    if (context.paintingDisabled())
        return;

#if ENABLE(FORM_CONTROL_REFRESH)
    // The scrollbar tracks will be pill shaped, so they cannot be visually
    // contiguous with the corner. Paint nothing.
    if (area.formControlRefreshEnabled())
        return;
#endif

    // Keep this in sync with ScrollAnimatorMac's effectiveAppearanceForScrollerImp:.
    LocalDefaultSystemAppearance localAppearance(area.useDarkAppearanceForScrollbars());

    context.drawSystemImage(ScrollbarTrackCornerSystemImageMac::create(), cornerRect);
}

#if HAVE(RUBBER_BANDING)
void ScrollbarThemeMac::setUpOverhangAreaShadow(CALayer *layer)
{
    static const CGFloat shadowOpacity = 0.66;
    static const CGFloat shadowRadius = 3;

    // We only need to set these shadow properties once.
    if (!layer.shadowOpacity) {
        layer.shadowColor = RetainPtr { CGColorGetConstantColor(kCGColorBlack) }.get();
        layer.shadowOffset = CGSizeZero;
        layer.shadowOpacity = shadowOpacity;
        layer.shadowRadius = shadowRadius;
    }

    RetainPtr<CGPathRef> shadowPath = adoptCF(CGPathCreateWithRect(layer.bounds, NULL));
    layer.shadowPath = shadowPath.get();
}

void ScrollbarThemeMac::removeOverhangAreaShadow(CALayer *layer)
{
    layer.shadowPath = nil;
    layer.shadowOpacity = 0;
}
#endif

} // namespace WebCore

#endif // PLATFORM(MAC)
