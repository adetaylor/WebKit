/*
 * Copyright (C) 2006-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2013-2014 Google Inc. All rights reserved.
 * Copyright (C) 2019 Adobe. All rights reserved.
 * Copyright (c) 2020, 2021, 2022, 2026 Igalia S.L.
 *
 * Portions are Copyright (C) 1998 Netscape Communications Corporation.
 *
 * Other contributors:
 *   Robert O'Callahan <roc+@cs.cmu.edu>
 *   David Baron <dbaron@fas.harvard.edu>
 *   Christian Biesinger <cbiesinger@web.de>
 *   Randall Jesup <rjesup@wgate.com>
 *   Roland Mainz <roland.mainz@informatik.med.uni-giessen.de>
 *   Josh Soref <timeless@mac.com>
 *   Boris Zbarsky <bzbarsky@mit.edu>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 *
 * Alternatively, the contents of this file may be used under the terms
 * of either the Mozilla Public License Version 1.1, found at
 * http://www.mozilla.org/MPL/ (the "MPL") or the GNU General Public
 * License Version 2.0, found at http://www.fsf.org/copyleft/gpl.html
 * (the "GPL"), in which case the provisions of the MPL or the GPL are
 * applicable instead of those above.  If you wish to allow use of your
 * version of this file only under the terms of one of those two
 * licenses (the MPL or the GPL) and not to allow others to use your
 * version of this file under the LGPL, indicate your decision by
 * deletingthe provisions above and replace them with the notice and
 * other provisions required by the MPL or the GPL, as the case may be.
 * If you do not delete the provisions above, a recipient may use your
 * version of this file under any of the LGPL, the MPL or the GPL.
 */

#include "config.h"
#include "RenderLayer.h"

#include "AccessibilityRegionContext.h"
#include "BitmapImage.h"
#include "BorderShape.h"
#include "BoxLayoutShape.h"
#include "CSSFilterRenderer.h"
#include "CSSPropertyNames.h"
#include "Chrome.h"
#include "ContainerNodeInlines.h"
#include "DebugPageOverlays.h"
#include "DisplayListRecorderImpl.h"
#include "Document.h"
#include "DocumentMarkerController.h"
#include "Editor.h"
#include "Element.h"
#include "ElementInlines.h"
#include "EventHandler.h"
#include "FEColorMatrix.h"
#include "FEMerge.h"
#include "FloatConversion.h"
#include "FloatPoint3D.h"
#include "FloatRect.h"
#include "FloatRoundedRect.h"
#include "FocusController.h"
#include "FrameInlines.h"
#include "FrameLoader.h"
#include "FrameSelection.h"
#include "FrameTree.h"
#include "Gradient.h"
#include "GraphicsContext.h"
#include "GraphicsLayer.h"
#include "HTMLCanvasElement.h"
#include "HTMLFormControlElement.h"
#include "HTMLFrameElement.h"
#include "HTMLFrameOwnerElement.h"
#include "HTMLIFrameElement.h"
#include "HTMLNames.h"
#include "HitTestRequest.h"
#include "HitTestResult.h"
#include "ImageDocument.h"
#include "InspectorInstrumentation.h"
#include "LayoutIntegrationLineLayout.h"
#include "LegacyRenderSVGForeignObject.h"
#include "LegacyRenderSVGImage.h"
#include "LegacyRenderSVGResourceClipper.h"
#include "LegacyRenderSVGRoot.h"
#include "LineClampUpdater.h"
#include "LocalFrame.h"
#include "LocalFrameLoaderClient.h"
#include "LocalFrameView.h"
#include "Logging.h"
#include "OverlapTestRequestClient.h"
#include "Page.h"
#include "PaintClipPathScope.h"
#include "PlatformMouseEvent.h"
#include "PositionedLayoutConstraints.h"
#include "ReferencedSVGResources.h"
#include "RenderAncestorIterator.h"
#include "RenderBoxInlines.h"
#include "RenderDescendantIterator.h"
#include "RenderElementInlines.h"
#include "RenderElementStyleInlines.h"
#include "RenderFlexibleBox.h"
#include "RenderFragmentContainer.h"
#include "RenderFragmentedFlow.h"
#include "RenderHTMLCanvas.h"
#include "RenderImage.h"
#include "RenderIterator.h"
#include "RenderLayerBacking.h"
#include "RenderLayerCompositor.h"
#include "RenderLayerFilters.h"
#include "RenderLayerInlines.h"
#include "RenderLayerModelObjectInlines.h"
#include "RenderLayerSVGAdditionsInlines.h"
#include "RenderLayerScrollableArea.h"
#include "RenderMarquee.h"
#include "RenderMultiColumnFlow.h"
#include "RenderObjectInlines.h"
#include "RenderReplica.h"
#include "RenderSVGForeignObject.h"
#include "RenderSVGHiddenContainer.h"
#include "RenderSVGInline.h"
#include "RenderSVGModelObject.h"
#include "RenderSVGResourceClipper.h"
#include "RenderSVGResourceContainer.h"
#include "RenderSVGRoot.h"
#include "RenderSVGText.h"
#include "RenderSVGViewportContainer.h"
#include "RenderScrollbar.h"
#include "RenderScrollbarPart.h"
#include "RenderTableCell.h"
#include "RenderTableRow.h"
#include "RenderText.h"
#include "RenderTextControlSingleLine.h"
#include "RenderTheme.h"
#include "RenderTreeAsText.h"
#include "RenderTreeMutationDisallowedScope.h"
#include "RenderView.h"
#include "SVGClipPathElement.h"
#include "SVGFilterElement.h"
#include "SVGNames.h"
#include "ScrollAnimator.h"
#include "ScrollSnapOffsetsInfo.h"
#include "Scrollbar.h"
#include "ScrollbarTheme.h"
#include "ScrollbarUpdateScope.h"
#include "ScrollingCoordinator.h"
#include "Settings.h"
#include "ShadowRoot.h"
#include "SourceGraphic.h"
#include "SpatialPortalController.h"
#include "StyleAdjuster.h"
#include "StyleAttributeMutationScope.h"
#include "StyleComputedStyle+SettersInlines.h"
#include "StylePrimitiveNumericTypes+Evaluation.h"
#include "StylePrimitiveNumericTypes+EvaluationMinimum.h"
#include "StyleProperties.h"
#include "StyleResolver.h"
#include "StyleScaleTransformFunction.h"
#include "StyleTransformResolver.h"
#include "StyleTranslateTransformFunction.h"
#include "Styleable.h"
#include "TransformOperationData.h"
#include "TransformationMatrix.h"
#include "ViewTransition.h"
#include "WheelEventTestMonitor.h"
#include <ranges>
#include <stdio.h>
#include <wtf/HexNumber.h>
#include <wtf/MonotonicTime.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/TextStream.h>

#if ENABLE(AX_CUSTOM_COLOR_MODE)
#include <WebKitAdditions/AXCustomColorBackdropContext.h>
#endif

namespace WebCore {

using namespace HTMLNames;

// The painting views hold their pointers as integers: Swift keeps a non-escapable view from outliving the painting
// call only while the view is trivially copyable.
static_assert(std::is_trivially_copyable_v<RenderLayer::LayerPaintingInfo>);
static_assert(std::is_trivially_copyable_v<PaintInfo>);

class ClipRectsCache {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(ClipRectsCache);
public:
    ClipRectsCache()
    {
#if ASSERT_ENABLED
        for (int i = 0; i < NumCachedClipRectsTypes; ++i) {
            m_clipRectsRoot[i] = nullptr;
        }
#endif

    }

    NODELETE ClipRects* getClipRects(ClipRectsType clipRectsType, bool respectOverflowClip) const
    {
        return m_clipRects[getIndex(clipRectsType, respectOverflowClip)].get();
    }

    void setClipRects(ClipRectsType clipRectsType, bool respectOverflowClip, RefPtr<ClipRects>&& clipRects)
    {
        m_clipRects[getIndex(clipRectsType, respectOverflowClip)] = WTF::move(clipRects);
    }

#if ASSERT_ENABLED
    std::array<const RenderLayer*, NumCachedClipRectsTypes> m_clipRectsRoot;
#endif
private:
    NODELETE unsigned getIndex(ClipRectsType clipRectsType, bool respectOverflowClip) const
    {
        unsigned index = static_cast<unsigned>(clipRectsType);
        if (respectOverflowClip)
            index += static_cast<unsigned>(NumCachedClipRectsTypes);
        ASSERT_WITH_SECURITY_IMPLICATION(index < NumCachedClipRectsTypes * 2);
        return index;
    }

    std::array<RefPtr<ClipRects>, NumCachedClipRectsTypes * 2> m_clipRects;
};

void makeMatrixRenderable(TransformationMatrix& matrix, bool has3DRendering)
{
    if (!has3DRendering)
        matrix.makeAffine();
}

ScrollingScope RenderLayer::nextScrollingScope()
{
    static ScrollingScope currentScope = 0;
    return ++currentScope;
}

LayoutPoint RenderLayer::locationInInlineBoxContainingBlock(const RenderLayerModelObject& container) const
{
    return toLayoutPoint(downcast<RenderBox>(renderer()).offsetFromContainer(container, { }));
}

RenderLayer::RenderLayer(RenderLayerModelObject& renderer)
    : m_isRenderViewLayer(renderer.isRenderView())
    , m_forcedStackingContext(renderer.isRenderMedia())
    , m_isNormalFlowOnly(false)
    , m_isCSSStackingContext(false)
    , m_canBeBackdropRoot(false)
    , m_hasBackdropFilterDescendantsWithoutRoot(false)
    , m_isOpportunisticStackingContext(false)
    , m_zOrderListsDirty(false)
    , m_normalFlowListDirty(true)
    , m_hadNegativeZOrderList(false)
    , m_inResizeMode(false)
    , m_hasSelfPaintingLayerDescendant(false)
    , m_hasSelfPaintingLayerDescendantDirty(false)
    , m_hasViewportConstrainedDescendant(false)
    , m_hasViewportConstrainedDescendantStatusDirty(false)
    , m_usedTransparency(false)
    , m_paintingInsideReflection(false)
    , m_visibleContentStatusDirty(true)
    , m_hasVisibleContent(false)
    , m_visibleDescendantStatusDirty(false)
    , m_hasVisibleDescendant(false)
    , m_isFixedIntersectingViewport(false)
    , m_behavesAsFixed(false)
    , m_3DTransformedDescendantStatusDirty(true)
    , m_has3DTransformedDescendant(false)
    , m_hasCompositingDescendant(false)
    , m_hasCompositedNonContainedDescendants(false)
    , m_hasCompositedScrollingAncestor(false)
    , m_hasFixedContainingBlockAncestor(false)
    , m_hasTransformedAncestor(false)
    , m_has3DTransformedAncestor(false)
    , m_insideSVGForeignObject(false)
    , m_indirectCompositingReason(static_cast<unsigned>(IndirectCompositingReason::None))
    , m_viewportConstrainedNotCompositedReason(NoNotCompositedReason)
    , m_layerListMutationAllowed(true)
    , m_blendMode(static_cast<unsigned>(BlendMode::Normal))
    , m_hasNotIsolatedCompositedBlendingDescendants(false)
    , m_hasNotIsolatedBlendingDescendants(false)
    , m_hasNotIsolatedBlendingDescendantsStatusDirty(false)
    , m_renderer(renderer)
{
    if (renderer.isSVGLayerAwareRenderer() && renderer.document().settings().layerBasedSVGEngineEnabled())
        lazyInitialize(m_svgData, makeUnique<SVGData>());

    setIsNormalFlowOnly(shouldBeNormalFlowOnly());
    setIsCSSStackingContext(shouldBeCSSStackingContext());
    updateEstablishesBlendingIsolationGroup();
    setCanBeBackdropRoot(computeCanBeBackdropRoot());
    setNeedsPositionUpdate();

    m_isSelfPaintingLayer = shouldBeSelfPaintingLayer();

    if (isRenderViewLayer())
        m_boxScrollingScope = m_contentsScrollingScope = nextScrollingScope();

    auto needsVisibleContentStatusUpdate = [&]() {
        if (renderer.firstChild())
            return false;

        // Leave m_visibleContentStatusDirty = true in any case. The associated renderer needs to be inserted into the
        // render tree, before we can determine the visible content status. The visible content status of a SVG renderer
        // depends on its ancestors (all children of RenderSVGHiddenContainer are recursively invisible, no matter what).
        if (m_svgData)
            return false;

        //  We need the parent to know if we have skipped content or content-visibility root.
        if (renderer.style().isSkippedRootOrSkippedContent() && !renderer.parent())
            return false;
        return true;
    }();

    if (needsVisibleContentStatusUpdate) {
        m_visibleContentStatusDirty = false;
        m_hasVisibleContent = renderer.usedStyle().visibility() == UsedVisibility::Visible;
    }
}

RenderLayer::~RenderLayer()
{
    ++s_destructionCount;

    // The owner told the event handler and removed the reflection before it dropped the layer (willBeDropped()).
    RELEASE_ASSERT(!m_reflection);

    clearLayerScrollableArea();
    clearLayerFilters();
    clearLayerClipPath();

    // Child layers will be deleted by their corresponding render objects, so
    // we don't need to delete them ourselves.

    clearBacking({ }, true);

    removeClipperClientIfNeeded();

    // Layer and all its children should be removed from the tree before destruction.
    RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(renderer().renderTreeBeingDestroyed() || !parent());
    RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(renderer().renderTreeBeingDestroyed() || !firstChild());
}

void RenderLayer::removeClipperClientIfNeeded() const
{
    WTF::switchOn(renderer().style().clipPath(),
        [&](const Style::ReferencePath& clipPath) {
            if (auto* clipperRenderer = ReferencedSVGResources::referencedClipperRenderer(renderer().treeScopeForSVGReferences(), clipPath))
                clipperRenderer->removeClientFromCache(renderer());
        },
        [](const auto&) { }
    );
}

bool RenderLayer::willCompositeClipPath() const
{
    if (!isComposited())
        return false;

    if (!renderer().hasClipPath())
        return false;

    if (renderer().hasMask())
        return false;

    return GraphicsLayer::supportsLayerType(GraphicsLayer::Type::Shape);
}

bool RenderLayer::zIndexMakesOutermostSVGAStackingContext() const
{
    CheckedRef renderer = this->renderer();
    auto& style = renderer->style();
    auto zIndexApplies = [&] {
        if (renderer->isPositioned())
            return true;
        CheckedPtr parent = renderer->parent();
        return parent && parent->style().display().isFlexibleBoxIncludingDeprecatedOrGridFormattingContextBox();
    };
    return Style::Adjuster::shouldTreatAutoZIndexAsZero(style)
        || (!style.specifiedZIndex().isAuto() && zIndexApplies());
}

unsigned RenderLayer::s_layerFreeForbiddenCount;

void RenderLayer::enterLayerFreeForbiddenScope()
{
    ++s_layerFreeForbiddenCount;
}

void RenderLayer::leaveLayerFreeForbiddenScope()
{
    RELEASE_ASSERT(s_layerFreeForbiddenCount);
    --s_layerFreeForbiddenCount;
}

void RenderLayer::appendViewLayersToPositiveList()
{
    if (isRenderViewLayer() && renderer().document().hasTopLayerElement()) {
        auto topLayerLayers = topLayerRenderLayers(renderer().view());
        if (topLayerLayers.size()) {
            if (!m_posZOrderList)
                m_posZOrderList = makeUnique<Vector<RenderLayer*>>();
            m_posZOrderList->appendVector(topLayerLayers);
        }
    }

    if (isRenderViewLayer() && renderer().document().hasViewTransitionPseudoElementTree()) {
        if (WeakPtr viewTransitionContainingBlock = renderer().view().viewTransitionContainingBlock(); viewTransitionContainingBlock && viewTransitionContainingBlock->hasLayer()) {
            if (!m_posZOrderList)
                m_posZOrderList = makeUnique<Vector<RenderLayer*>>();
            m_posZOrderList->append(viewTransitionContainingBlock->layer());
        }
    }
}

void RenderLayer::removeOnlyThisLayer()
{
    if (!parent())
        return;

    detachKeepingChildren();
    renderer().destroyLayer();
}

size_t RenderLayer::paintOrderListSize(PaintOrderList which) const
{
    auto& list = which == PaintOrderList::Positive ? m_posZOrderList : which == PaintOrderList::Negative ? m_negZOrderList : m_normalFlowList;
    return list ? list->size() : 0;
}

RenderLayer& RenderLayer::paintOrderListLayerAt(PaintOrderList which, size_t index) const
{
    auto& list = which == PaintOrderList::Positive ? m_posZOrderList : which == PaintOrderList::Negative ? m_negZOrderList : m_normalFlowList;
    return *list->at(index);
}

void RenderLayer::didAddChildEventRegion(RenderLayer& child)
{
#if ENABLE(ASYNC_SCROLLING)
    if (child.hasDescendantNeedingEventRegionUpdate() || (child.isComposited() && child.backing()->needsEventRegionUpdate()))
        child.setAncestorsHaveDescendantNeedingEventRegionUpdate();
#else
    UNUSED_PARAM(child);
#endif
}

String RenderLayer::name() const
{
    if (!isReflection())
        return renderer().debugDescription();
    return makeString(renderer().debugDescription(), " (reflection)"_s);
}

void RenderLayer::willUpdateLayerPositions()
{
    if (CheckedPtr markers = renderer().document().markersIfExists())
        markers->invalidateRectsForAllMarkers();
}

#define LAYER_POSITIONS_ASSERT_ENABLED ASSERT_ENABLED || ENABLE(CONJECTURE_ASSERT)
#if ASSERT_ENABLED
#if ENABLE(TREE_DEBUGGING)
#define LAYER_POSITIONS_ASSERT(assertion, ...) do { \
    if (!(assertion)) [[unlikely]] \
        showLayerPositionTree(root(), this); \
    ASSERT(assertion, __VA_ARGS__); \
} while (0)
#define LAYER_POSITIONS_ASSERT_IMPLIES(condition, assertion) do { \
    if (condition && !(assertion)) [[unlikely]] \
        showLayerPositionTree(root(), this); \
    ASSERT_IMPLIES(condition, assertion); \
} while (0)
#else
#define LAYER_POSITIONS_ASSERT(assertion, ...) ASSERT(assertion, __VA_ARGS__)
#define LAYER_POSITIONS_ASSERT_IMPLIES(condition, assertion) ASSERT_IMPLIES(condition, assertion)
#endif // ENABLE(TREE_DEBUGGING)
#elif ENABLE(CONJECTURE_ASSERT)
#define LAYER_POSITIONS_ASSERT(assertion, ...) CONJECTURE_ASSERT(assertion, __VAR_ARGS__)
#define LAYER_POSITIONS_ASSERT_IMPLIES(condition, assertion) CONJECTURE_ASSERT_IMPLIES(condition, assertion)
#else
#define LAYER_POSITIONS_ASSERT(assertion, ...) ((void)0)
#define LAYER_POSITIONS_ASSERT_IMPLIES(condition, assertion) ((void)0)
#endif

void RenderLayer::verifyRepaintAfterLayout()
{
    WeakPtr repaintContainer = renderer().containerForRepaint().renderer.get();
    LAYER_POSITIONS_ASSERT(repaintRects() || (isSubtreeVisibilityHiddenOrOpacityZero() || !isSelfPaintingLayer()));
    LAYER_POSITIONS_ASSERT(m_repaintContainer == repaintContainer);
#if LAYER_POSITIONS_ASSERT_ENABLED
    // Cached repaint rects can lag an accelerated animated transform. Skip the repaint-rect verification in that case.
    auto styleable = Styleable::fromRenderer(renderer());
    bool runningAcceleratedTransformAnimation = styleable && styleable->isRunningAcceleratedTransformRelatedAnimation();
    LAYER_POSITIONS_ASSERT_IMPLIES(repaintRects() && !runningAcceleratedTransformAnimation, *repaintRects() == renderer().rectsForRepaintingAfterLayout(repaintContainer.get(), RepaintOutlineBounds::Yes));
    LAYER_POSITIONS_ASSERT_IMPLIES(m_svgData && !runningAcceleratedTransformAnimation, m_svgData->containerTransformForRepaintRects == computeContainerTransformForRepaintForSVG());
#endif
}

void RenderLayer::assertLayerPosition(bool condition)
{
    // RenderLayer.h states the condition again, for Swift.
#if LAYER_POSITIONS_ASSERT_ENABLED
    static_assert(layerPositionsAssertEnabled());
#else
    static_assert(!layerPositionsAssertEnabled());
#endif
    LAYER_POSITIONS_ASSERT(condition);
    UNUSED_PARAM(condition);
}

void RenderLayer::updateBackingAfterLayout(bool needsClippingUpdate, bool needsFullRepaint)
{
    m_backing->updateAfterLayout(needsClippingUpdate, needsFullRepaint);
}

void RenderLayer::repaintAfterLayoutIfNecessary(bool checkForRepaint)
{
    // FIXME: Paint offset cache does not work with RenderLayers as there is not a 1-to-1
    // mapping between them and the RenderObjects. It would be neat to enable
    // LayoutState outside the layout() phase and use it here.
    ASSERT(!renderer().view().frameView().layoutContext().isPaintOffsetCacheEnabled());

    WeakPtr repaintContainer = renderer().containerForRepaint().renderer.get();

    auto oldRects = repaintRects();
    setNeedsFullRepaintIfSVGContainerTransformChanged(repaintContainer.get());
    computeRepaintRects(repaintContainer.get());
    auto newRects = repaintRects();

    if (checkForRepaint && shouldRepaintAfterLayout() && newRects) {
        auto needsFullRepaint = repaintStatus() == RepaintStatus::NeedsFullRepaint ? RequiresFullRepaint::Yes : RequiresFullRepaint::No;
        auto resolvedOldRects = valueOrDefault(oldRects);
        renderer().repaintAfterLayoutIfNeeded(WTF::move(repaintContainer), needsFullRepaint, resolvedOldRects, *newRects);
    }
}

void RenderLayer::updateContainerTransformForRepaintRectsForSVG()
{
    m_svgData->containerTransformForRepaintRects = computeContainerTransformForRepaintForSVG();
}

void RenderLayer::setRepaintRects(const RenderObject::RepaintRects& rects)
{
    m_repaintRects = rects;
    m_repaintRectsValid = true;
}

void RenderLayer::updateTransformFromStyle(TransformationMatrix& transform, const Style::ComputedStyle& style, OptionSet<Style::TransformResolverOption> options) const
{
    // Not in the tree yet (only the RenderView is legitimately parentless): no reference box to resolve against.
    if (!renderer().parent() && !renderer().isRenderView()) {
        ASSERT(!m_anchorScrollAdjustment);
        return;
    }

    // https://drafts.csswg.org/css-anchor-position-1/#default-scroll-shift
    // > After layout has been performed for abspos, it is additionally shifted by
    // > the default scroll shift, as if affected by a transform
    // > ** (before any other transforms). **
    if (m_anchorScrollAdjustment)
        transform.translate(m_anchorScrollAdjustment->width(), m_anchorScrollAdjustment->height());

    auto referenceBoxRect = snapRectToDevicePixelsIfNeeded(renderer().transformReferenceBoxRect(style), renderer());
    renderer().applyTransform(transform, style, referenceBoxRect, options);

    makeMatrixRenderable(transform, canRender3DTransforms());
}

TransformationMatrix RenderLayer::animatedStyleTransform(TransformResolverOptions options) const
{
    TransformationMatrix transform;
    updateTransformFromStyle(transform, *renderer().animatedStyle(), options);
    return transform;
}

auto RenderLayer::allTransformOperations() -> TransformResolverOptions
{
    return Style::TransformResolver::allTransformOperations;
}

auto RenderLayer::individualTransformOperations() -> TransformResolverOptions
{
    return Style::TransformResolver::individualTransformOperations;
}

bool RenderLayer::includesTransformOrigin(TransformResolverOptions options)
{
    return options.contains(Style::TransformResolverOption::TransformOrigin);
}

FloatPoint3D RenderLayer::computeTransformOrigin(const Style::ComputedStyle& style, FloatRect referenceBox)
{
    return Style::TransformResolver::computeTransformOrigin(style, referenceBox);
}

FloatPoint RenderLayer::computePerspectiveOrigin(const Style::ComputedStyle& style, FloatRect referenceBox)
{
    return Style::TransformResolver::computePerspectiveOrigin(style, referenceBox);
}

FloatPoint RenderLayer::evaluatePerspectiveOrigin(const Style::ComputedStyle& style, FloatSize referenceBoxSize)
{
    return Style::evaluate<FloatPoint>(style.perspectiveOrigin(), referenceBoxSize, style.usedZoomForLength());
}

TransformationMatrix RenderLayer::applyingPerspective(TransformationMatrix transform, const Style::ComputedStyle& style, FloatPoint perspectiveOrigin)
{
    Style::TransformResolver { transform, style }.applyPerspective(perspectiveOrigin);
    return transform;
}

bool RenderLayer::isRunningAcceleratedTransformRelatedAnimation() const
{
    auto styleable = Styleable::fromRenderer(renderer());
    return styleable && styleable->isRunningAcceleratedTransformRelatedAnimation();
}

float RenderLayer::currentOpacity() const
{
    auto styleable = Styleable::fromRenderer(renderer());
    if (styleable && styleable->isRunningAcceleratedAnimationOfProperty(CSSPropertyID::Opacity)) {
        std::unique_ptr<Style::ComputedStyle> animatedStyle = renderer().animatedStyle();
        return Style::evaluate<float>(animatedStyle->opacity());
    }

    return renderer().opacity();
}

RenderLayer* RenderLayer::enclosingScrollableLayer(IncludeSelfOrNot includeSelf, CrossFrameBoundaries crossFrameBoundaries) const
{
    RenderTreeMutationDisallowedScope renderTreeMutationDisallowedScope;

    auto isConsideredScrollable = [](const RenderLayer& layer) {
        auto* box = dynamicDowncast<RenderBox>(layer.renderer());
        return box && box->canBeScrolledAndHasScrollableArea();
    };

    if (includeSelf == IncludeSelfOrNot::IncludeSelf && isConsideredScrollable(*this)) {
        return const_cast<RenderLayer*>(this);
    }
    
    for (auto* nextLayer = enclosingContainingBlockLayer(crossFrameBoundaries); nextLayer; nextLayer = nextLayer->enclosingContainingBlockLayer(crossFrameBoundaries)) {
        if (isConsideredScrollable(*nextLayer))
            return nextLayer;
    }

    return nullptr;
}

bool compositedWithOwnBackingStore(const RenderLayer& layer)
{
    return layer.isComposited() && !layer.backing()->paintsIntoCompositedAncestor();
}

LayoutPoint RenderLayer::absoluteToContents(LayoutPoint absolutePoint) const
{
    // We don't use convertToLayerCoords because it doesn't know about transforms
    return LayoutPoint(renderer().absoluteToLocal(absolutePoint, MapCoordinatesMode::UseTransforms));
}

RenderLayer* RenderLayer::parentForTesting() const { return parent(); }
RenderLayer* RenderLayer::previousSiblingForTesting() const { return previousSibling(); }
RenderLayer* RenderLayer::nextSiblingForTesting() const { return nextSibling(); }
RenderLayer* RenderLayer::firstChildForTesting() const { return firstChild(); }
RenderLayer* RenderLayer::lastChildForTesting() const { return lastChild(); }

static RenderLayer* layerAt(RenderLayer::LayerList list, size_t index)
{
    RELEASE_ASSERT(index < list.size());
    WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN
    return list.begin()[index];
    WTF_ALLOW_UNSAFE_BUFFER_USAGE_END
}

size_t RenderLayer::negativeZOrderLayerCountForTesting() const { return negativeZOrderLayers().size(); }
RenderLayer* RenderLayer::negativeZOrderLayerAtForTesting(size_t index) const { return layerAt(negativeZOrderLayers(), index); }
size_t RenderLayer::normalFlowLayerCountForTesting() const { return normalFlowLayers().size(); }
RenderLayer* RenderLayer::normalFlowLayerAtForTesting(size_t index) const { return layerAt(normalFlowLayers(), index); }
size_t RenderLayer::positiveZOrderLayerCountForTesting() const { return positiveZOrderLayers().size(); }
RenderLayer* RenderLayer::positiveZOrderLayerAtForTesting(size_t index) const { return layerAt(positiveZOrderLayers(), index); }

bool RenderLayer::zOrderListsDirtyForTesting() const { return zOrderListsDirty(); }
bool RenderLayer::normalFlowListDirtyForTesting() const { return normalFlowListDirty(); }
bool RenderLayer::isStackingContextForTesting() const { return isStackingContext(); }
bool RenderLayer::isNormalFlowOnlyForTesting() const { return isNormalFlowOnly(); }
void RenderLayer::updateLayerListsIfNeededForTesting() { updateLayerListsIfNeeded(); }
void RenderLayer::dirtyZOrderListsForTesting() { dirtyZOrderLists(); }
void RenderLayer::dirtyNormalFlowListForTesting() { dirtyNormalFlowList(); }
int RenderLayer::zIndexForTesting() const { return zIndex(); }
bool RenderLayer::wasOmittedFromZOrderTreeForTesting() const { return m_wasOmittedFromZOrderTree; }

unsigned RenderLayer::paintOrderMarksForTesting() const
{
    return (m_hasVisibleContent ? 1u : 0) | (m_hasVisibleDescendant ? 2u : 0) | (m_alwaysIncludedInZOrderLists ? 4u : 0)
        | (m_hasAlwaysIncludedInZOrderListsDescendants ? 8u : 0) | (m_hasAlwaysIncludedInZOrderListsDescendantsStatusDirty ? 16u : 0)
        | (m_hadNegativeZOrderList ? 32u : 0);
}

unsigned RenderLayer::compositingDirtyBitsForTesting() const { return m_compositingDirtyBits.toRaw(); }
void RenderLayer::addChildForTesting(RenderLayer& newChild, RenderLayer* beforeChild) { addChild(newChild, beforeChild); }
void RenderLayer::removeChildForTesting(RenderLayer& oldChild) { removeChild(oldChild); }

static constexpr uint64_t fnvOffsetBasis = 0xcbf29ce484222325ULL;
static constexpr uint64_t fnvPrime = 0x100000001b3ULL;

uint64_t renderLayerPreorderWalkForTesting(const RenderLayer& root)
{
    uint64_t digest = fnvOffsetBasis;
    uint64_t depth = 0;
    for (const RenderLayer* layer = &root; ; ) {
        auto* previous = layer->previousSibling();
        auto* parent = layer->parent();
        uint64_t flags = (layer->isStackingContext() ? 1 : 0) | (layer->isNormalFlowOnly() ? 2 : 0);
        flags |= !previous || previous->nextSibling() == layer ? 4 : 0;
        flags |= !parent || layer->nextSibling() || parent->lastChild() == layer ? 8 : 0;
        digest = (digest ^ (depth << 8 | flags)) * fnvPrime;

        if (auto* child = layer->firstChild()) {
            layer = child;
            ++depth;
            continue;
        }
        while (layer != &root && !layer->nextSibling()) {
            layer = layer->parent();
            --depth;
        }
        if (layer == &root)
            return digest;
        layer = layer->nextSibling();
    }
}

uint64_t renderLayerAncestorWalkForTesting(std::span<const RenderLayer* const> layers)
{
    uint64_t digest = fnvOffsetBasis;
    for (auto* start : layers) {
        uint64_t depth = 0;
        uint64_t stacking = 0;
        for (auto* layer = start; layer; layer = layer->parent()) {
            ++depth;
            stacking += layer->isStackingContext();
        }
        digest = (digest ^ (depth << 32 | stacking)) * fnvPrime;
    }
    return digest;
}

// The enclosing-layer queries of the paint, hit-test and clip paths, over the layers given, for the tree benchmark. Each layer
// contributes what its stacking context, enclosing stacking context, enclosing overflow clip layer and common ancestor with the
// next layer are, described by the layer's own properties and its place relative to the layer itself and its parent.
uint64_t renderLayerEnclosingWalkForTesting(std::span<RenderLayer* const> layers)
{
    uint64_t digest = fnvOffsetBasis;
    auto describe = [](const RenderLayer* layer, const RenderLayer* result) -> uint64_t {
        if (!result)
            return 0;
        uint64_t flags = 1 | (result->isStackingContext() ? 2 : 0) | (result->isNormalFlowOnly() ? 4 : 0) | (result == layer ? 8 : 0) | (result == layer->parent() ? 16 : 0);
        return static_cast<uint64_t>(static_cast<uint32_t>(result->zIndex())) << 8 | flags;
    };
    for (size_t i = 0; i < layers.size(); ++i) {
        auto* layer = layers[i];
        auto* next = layers[(i + 1) % layers.size()];
        uint64_t value = describe(layer, layer->stackingContext());
        value = value * fnvPrime ^ describe(layer, layer->enclosingStackingContext());
        value = value * fnvPrime ^ describe(layer, layer->enclosingOverflowClipLayer(IncludeSelf));
        value = value * fnvPrime ^ describe(layer, layer->commonAncestorWithLayer(*next));
        value = value * fnvPrime ^ (layer->isDescendantOf(*next) ? 1 : 0);
        digest = (digest ^ value) * fnvPrime;
    }
    return digest;
}

// Weak references to layers held on behalf of a benchmark, which cannot name how a layer is weakly referenced.
static Vector<InlineWeakPtr<RenderLayer>>& testingWeakReferences()
{
    static NeverDestroyed<Vector<InlineWeakPtr<RenderLayer>>> references;
    return references;
}

static Vector<size_t>& testingFreeWeakReferenceSlots()
{
    static NeverDestroyed<Vector<size_t>> slots;
    return slots;
}

size_t renderLayerWeakReferenceAcquireForTesting(const Element& element)
{
    auto* renderer = dynamicDowncast<RenderLayerModelObject>(element.renderer());
    auto* layer = renderer ? renderer->layer() : nullptr;
    if (!layer)
        return notFound;
    auto& references = testingWeakReferences();
    auto& freeSlots = testingFreeWeakReferenceSlots();
    if (freeSlots.isEmpty()) {
        references.append(layer);
        return references.size() - 1;
    }
    size_t slot = freeSlots.takeLast();
    references[slot] = layer;
    return slot;
}

bool renderLayerWeakReferenceIsNullForTesting(size_t slot)
{
    return !testingWeakReferences()[slot];
}

void renderLayerWeakReferenceReleaseForTesting(size_t slot)
{
    testingWeakReferences()[slot] = nullptr;
    testingFreeWeakReferenceSlots().append(slot);
}

bool renderLayerRecreateForTesting(const Element& element)
{
    auto* renderer = dynamicDowncast<RenderLayerModelObject>(element.renderer());
    if (!renderer || !renderer->layer())
        return false;
    // As a style change that loses the layer does: its children's layers go to its parent, then the owner drops it.
    renderer->layer()->removeOnlyThisLayer();
    renderer->styleDidChange(Style::DifferenceResult::Equal, &renderer->style());
    return renderer->layer();
}

void RenderLayer::convertToPixelSnappedLayerCoords(const RenderLayer* ancestorLayer, IntPoint& roundedLocation, ColumnOffsetAdjustment adjustForColumns) const
{
    LayoutPoint location = convertToLayerCoords(ancestorLayer, roundedLocation, adjustForColumns);
    roundedLocation = roundedIntPoint(location);
}

void RenderLayer::adjustLocationForColumns(const RenderLayer* ancestorLayer, LayoutPoint& location) const
{
    if (auto* parentLayer = parent(); parentLayer && parentLayer != ancestorLayer) {
        if (auto* multiColumnFlow = dynamicDowncast<RenderMultiColumnFlow>(parentLayer->renderer())) {
            if (auto* fragment = multiColumnFlow->physicalTranslationFromFlowToFragment(location))
                location.move(fragment->topLeftLocation() - parentLayer->renderBox()->topLeftLocation());
        }
    }
}

void RenderLayer::autoscroll(const IntPoint& positionInWindow)
{
    IntPoint currentDocumentPosition = renderer().view().frameView().windowToContents(positionInWindow);
    LocalFrameView::scrollRectToVisible(LayoutRect(currentDocumentPosition, LayoutSize(1, 1)), renderer(), false, { SelectionRevealMode::Reveal, ScrollAlignment::alignToEdgeIfNeeded, ScrollAlignment::alignToEdgeIfNeeded, ShouldAllowCrossOriginScrolling::Yes });
}

void RenderLayer::resize(const PlatformMouseEvent& evt, const LayoutSize& oldOffset)
{
    // FIXME: This should be possible on generated content but is not right now.
    if (!inResizeMode() || !canResize())
        return;

    // FIXME: This should be possible on all elements but is not right now.
    RefPtr styledElement = dynamicDowncast<StyledElement>(renderer().element());
    if (!styledElement)
        return;

    // FIXME: The only case where renderer->element()->renderer() != renderer is with continuations. Do they matter here?
    // If they do it would still be better to deal with them explicitly.
    CheckedPtr renderer = downcast<RenderBox>(styledElement->renderer());

    Ref document = styledElement->document();
    if (!document->frame()->eventHandler().mousePressed())
        return;

    float zoomFactor = renderer->style().usedZoom();

    auto absolutePoint = document->view()->windowToContents(evt.position());
    auto localPoint = roundedIntPoint(absoluteToContents(LayoutPoint(absolutePoint)));

    LayoutSize newOffset = offsetFromResizeCorner(localPoint);
    newOffset.setWidth(newOffset.width() / zoomFactor);
    newOffset.setHeight(newOffset.height() / zoomFactor);

    LayoutSize currentSize = LayoutSize(renderer->borderBoxWidth() / zoomFactor, renderer->borderBoxHeight() / zoomFactor);

    LayoutSize adjustedOldOffset = LayoutSize(oldOffset.width() / zoomFactor, oldOffset.height() / zoomFactor);
    if (renderer->shouldPlaceVerticalScrollbarOnLeft()) {
        newOffset.setWidth(-newOffset.width());
        adjustedOldOffset.setWidth(-adjustedOldOffset.width());
    }

    LayoutSize difference = (currentSize + newOffset - adjustedOldOffset).expandedTo(minimumSizeForResizing(zoomFactor)) - currentSize;

    StyleAttributeMutationScope mutationScope { styledElement.get() };
    bool isBoxSizingBorder = renderer->style().boxSizing() == BoxSizing::BorderBox;

    auto resize = renderer->style().resize();
    bool canResizeWidth = resize == Style::Resize::Horizontal || resize == Style::Resize::Both
        || (renderer->isHorizontalWritingMode() ? resize == Style::Resize::Inline : resize == Style::Resize::Block);
    if (canResizeWidth && difference.width()) {
        if (is<HTMLFormControlElement>(*styledElement)) {
            // Make implicit margins from the theme explicit (see <http://bugs.webkit.org/show_bug.cgi?id=9547>).
            styledElement->setInlineStyleProperty(CSSPropertyID::MarginLeft, renderer->marginLeft() / zoomFactor, CSSUnitType::Px);
            styledElement->setInlineStyleProperty(CSSPropertyID::MarginRight, renderer->marginRight() / zoomFactor, CSSUnitType::Px);
        }
        LayoutUnit baseWidth = renderer->borderBoxWidth() - (isBoxSizingBorder ? 0_lu : renderer->horizontalBorderAndPaddingExtent());
        baseWidth = baseWidth / zoomFactor;
        styledElement->setInlineStyleProperty(CSSPropertyID::Width, roundToInt(baseWidth + difference.width()), CSSUnitType::Px);

        mutationScope.enqueueMutationRecord();
    }

    bool canResizeHeight = resize == Style::Resize::Vertical || resize == Style::Resize::Both
        || (renderer->isHorizontalWritingMode() ? resize == Style::Resize::Block : resize == Style::Resize::Inline);
    if (canResizeHeight && difference.height()) {
        if (is<HTMLFormControlElement>(*styledElement)) {
            // Make implicit margins from the theme explicit (see <http://bugs.webkit.org/show_bug.cgi?id=9547>).
            styledElement->setInlineStyleProperty(CSSPropertyID::MarginTop, renderer->marginTop() / zoomFactor, CSSUnitType::Px);
            styledElement->setInlineStyleProperty(CSSPropertyID::MarginBottom, renderer->marginBottom() / zoomFactor, CSSUnitType::Px);
        }
        LayoutUnit baseHeight = renderer->borderBoxHeight() - (isBoxSizingBorder ? 0_lu : renderer->verticalBorderAndPaddingExtent());
        baseHeight = baseHeight / zoomFactor;
        styledElement->setInlineStyleProperty(CSSPropertyID::Height, roundToInt(baseHeight + difference.height()), CSSUnitType::Px);

        mutationScope.enqueueMutationRecord();
    }

    document->updateLayout();

    // FIXME (Radar 4118564): We should also autoscroll the window as necessary to keep the point under the cursor in view.
}

String RenderLayer::debugDescription() const
{
    String compositedDescription;
    if (isComposited()) {
        TextStream stream;
        stream << " " << *backing();
        compositedDescription = stream.release();
    }

    return makeString("RenderLayer 0x"_s, hex(reinterpret_cast<uintptr_t>(this), Lowercase),
        ' ', size().width(), 'x', size().height(),
        transform() ? " has transform"_s : ""_s,
        hasFilter() ? " has filter"_s : ""_s,
        hasBackdropFilter() ? " has backdrop filter"_s : ""_s,
#if HAVE(CORE_MATERIAL)
        hasAppleVisualEffect() ? " has apple visual effect"_s : ""_s,
#endif
        hasBlendMode() ? " has blend mode"_s : ""_s,
        isolatesBlending() ? " isolates blending"_s : ""_s,
        compositedDescription);
}

std::optional<ScrollbarUpdateScope> RenderLayer::updateScrollInfoAfterLayout()
{
    updateLayerScrollableArea();
    if (m_scrollableArea)
        return m_scrollableArea->updateScrollInfoAfterLayout();
    return { };
}

void RenderLayer::paint(GraphicsContext& context, const LayoutRect& damageRect, const LayoutSize& subpixelOffset, OptionSet<PaintBehavior> paintBehavior, RenderObject* subtreePaintRoot, OptionSet<PaintLayerFlag> paintFlags, SecurityOriginPaintPolicy paintPolicy, RegionContext* regionContext)
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    OverlapTestRequestMap overlapTestRequests;

    LayerPaintingInfo paintingInfo(this, enclosingIntRect(damageRect), paintBehavior, subpixelOffset, subtreePaintRoot, &overlapTestRequests, paintPolicy == SecurityOriginPaintPolicy::AccessibleOriginOnly);
    if (regionContext) {
        paintingInfo.setRegionContext(regionContext);
        if (is<EventRegionContext>(regionContext))
            paintFlags.add(RenderLayer::PaintLayerFlag::CollectingEventRegion);
    }
    paintLayer(LentGraphicsContext { context }, paintingInfo, paintFlags);

    for (auto& widget : overlapTestRequests.keys())
        widget->setOverlapTestResult(false);
}

static inline DisplayList::RecorderImpl* canvasDrawableRecorder(const RenderLayer& layer, GraphicsContext& context, const RenderLayer* rootLayer)
{
    if (!layer.renderer().isCanvasDrawable())
        return nullptr;

    CheckedPtr canvasRenderer = layer.renderer().drawableCanvas();
    if (!canvasRenderer)
        return nullptr;

    auto elementRelativeBounds = enclosingIntRect(LayoutRect { LayoutPoint { layer.offsetFromAncestor(rootLayer) }, layer.renderer().absoluteBoundingBoxRect().size() });
    return canvasRenderer->canvasDrawableRecorder(layer.renderer(), context, elementRelativeBounds);
}

bool RenderLayer::paintLayerIntoCanvasDrawableRecorder(NOESCAPE LentGraphicsContext context, const LayerPaintingInfo& paintingInfo, PaintLayerFlags paintFlags)
{
    RefPtr recorder = canvasDrawableRecorder(*this, *context, paintingInfo.rootLayer());
    if (!recorder)
        return false;
    paintLayerWithEffects(LentGraphicsContext { *recorder }, paintingInfo, paintFlags);
    return true;
}

void RenderLayer::clipToInnerBorderShape(NOESCAPE LentGraphicsContext context, const RenderLayer& layer, LayoutRect clipRect, LayoutRect paintDirtyRect, float deviceScaleFactor)
{
    auto borderShape = BorderShape::shapeForBorderRect(layer.renderer().usedStyle(), clipRect);
    if (borderShape.innerShapeContains(paintDirtyRect))
        (*context).clip(snapRectToDevicePixels(intersection(paintDirtyRect, clipRect), deviceScaleFactor));
    else
        borderShape.clipToInnerShape(*context, deviceScaleFactor);
}

void RenderLayer::performOverlapTests(const LayerPaintingInfo& paintingInfo) const
{
    if (!paintingInfo.overlapTestRequests() || paintingInfo.overlapTestRequests()->isEmpty())
        return;

    LayoutRect boundingBox = this->boundingBox(paintingInfo.rootLayer(), offsetFromAncestor(paintingInfo.rootLayer()));
    paintingInfo.overlapTestRequests()->removeIf([&](auto& request) {
        if (!boundingBox.intersects(request.value))
            return false;

        request.key->setOverlapTestResult(true);
        return true;
    });
}

bool RenderLayer::setupFontSubpixelQuantization(NOESCAPE LentGraphicsContext contextView, bool& didQuantizeFonts)
{
    GraphicsContext& context = *contextView;
    if (context.paintingDisabled())
        return false;

    CheckedPtr box = dynamicDowncast<RenderBox>(renderer());
    if (!box)
        return false;

    bool documentScrollsOnMainThread = [&]() {
        CheckedRef frameView = renderer().view().frameView();
#if ENABLE(ASYNC_SCROLLING)
        if (RefPtr scrollingCoordinator = page().scrollingCoordinator())
            return scrollingCoordinator->shouldUpdateScrollLayerPositionSynchronously(frameView);
#endif
        if (frameView->isScrollableOrRubberbandable())
            return true;

        return false;
    }();

    bool contentScrollsByPainting = box->hasScrollableOverflow() && !usesCompositedScrolling();
    bool isZooming = !page().chrome().client().hasStablePageScaleFactor();
    if (documentScrollsOnMainThread || contentScrollsByPainting || isZooming) {
        didQuantizeFonts = context.shouldSubpixelQuantizeFonts();
        context.setShouldSubpixelQuantizeFonts(false);
        return true;
    }
    return false;
}

void RenderLayer::paintLayerContentsWithClipPath(NOESCAPE LentGraphicsContext context, NOESCAPE LayerPaintingInfo paintingInfo, PaintLayerFlags paintFlags, PaintLayerFlags localPaintFlags, OptionalPaintOrderItemRange svgPaintOrderItemRange,
    LayoutSize offsetFromRoot, LayoutSize columnAwareOffsetFromRoot, bool shouldPaintContent, bool needToAdjustSubpixelQuantization, bool didQuantizeFonts)
{
    std::optional<Paint::ClipPathScope> clipPathScope;
    bool isCollectingEventRegion = localPaintFlags.contains(PaintLayerFlag::CollectingEventRegion);
    if (shouldApplyClipPath(paintingInfo.paintBehavior, localPaintFlags) && renderer().hasClipPath() && (!context.paintingDisabled() || isCollectingEventRegion) && !paintingInfo.paintDirtyRect.isEmpty()
        && !(m_svgData && setupClipPathIfNeededForSVG(localPaintFlags))) {
        auto clippedContentBounds = calculateLayerBounds(paintingInfo.rootLayer(), columnAwareOffsetFromRoot, { UseLocalClipRectIfPossible });
        clipPathScope.emplace(*context, paintingInfo.regionContext(), renderer(), columnAwareOffsetFromRoot, paintingInfo.subpixelOffset, clippedContentBounds, isCollectingEventRegion, Paint::ClipPathScope::CoordinateMode::LayerPaint);
    }

    // Collected while the contents paint into the filters, and read again by the masks painted after them.
    LayerFragments layerFragments;
    paintLayerContentsWithinClipPath(context, paintingInfo, paintFlags, localPaintFlags, svgPaintOrderItemRange, LayerFragmentsView { layerFragments }, offsetFromRoot, columnAwareOffsetFromRoot,
        clipPathScope && clipPathScope->needsMaskClipping(), shouldPaintContent, needToAdjustSubpixelQuantization, didQuantizeFonts);
}

void RenderLayer::clearLayerClipPath()
{
    if (auto* svgClipper = renderer().legacySVGClipperResourceFromStyle())
        svgClipper->removeClientFromCache(renderer());
}

RenderLayerFilters* RenderLayer::filtersForPainting(NOESCAPE LentGraphicsContext context, OptionSet<PaintLayerFlag> paintFlags, OptionSet<PaintBehavior> paintBehavior)
{
    if (!shouldHaveFiltersForPainting(context, paintFlags, paintBehavior))
        return nullptr;

    return &ensureLayerFilters();
}

// Holds the layer's filters, which own the context they paint into, while the layer's contents paint into it.
class RenderLayer::FilterPaintScope {
    WTF_MAKE_NONCOPYABLE(FilterPaintScope);
public:
    FilterPaintScope(GraphicsContext& context, RefPtr<RenderLayerFilters>&& filters)
        : m_context(context)
        , m_filters(WTF::move(filters))
    {
        if (m_filters)
            m_filters->m_hasPaintScope = true;
    }

    ~FilterPaintScope()
    {
        if (m_filters)
            m_filters->m_hasPaintScope = false;
    }

    GraphicsContext& context() const { return m_context; }
    RenderLayerFilters* filters() const { return m_filters.get(); }

private:
    GraphicsContext& m_context;
    RefPtr<RenderLayerFilters> m_filters;
};

RenderLayer::FilterPaintScope RenderLayer::setupFilters(LentGraphicsContext destinationContext, LayerPaintingInfo& paintingInfo, OptionSet<PaintLayerFlag>& paintFlags, LayoutSize offsetFromRoot, ClipRect backgroundRect)
{
    RefPtr paintingFilters = filtersForPainting(destinationContext, paintFlags, paintingInfo.paintBehavior);
    if (!paintingFilters)
        return FilterPaintScope { *destinationContext, nullptr };

    LayoutRect filterRepaintRect = paintingFilters->dirtySourceRect();
    filterRepaintRect.move(offsetFromRoot);

    auto rootRelativeBounds = calculateLayerBounds(paintingInfo.rootLayer(), offsetFromRoot, { RenderLayer::PreserveAncestorFlags, RenderLayer::IncludeDescendantTransforms });

    // When the filter is applied via a transparency layer directly on the destination context (e.g. CG drop-shadow),
    // the switcher doesn't consult applyFilters's clipToRect path, so the ancestor border-radius clip would be lost.
    // Provide a callback that applies that rounded clip on the destination before the transparency layer begins.
    Function<void(GraphicsContext&)> applyAdditionalDestinationClip;
    if (backgroundRect.affectedByRadius()) {
        applyAdditionalDestinationClip = [this, &paintingInfo](GraphicsContext& context) {
            applyAncestorClippingForBorderRadius(LentGraphicsContext { context }, paintingInfo, paintingInfo.paintBehavior, DoNotIncludeSelfForBorderRadius);
        };
    }

    // Beginning the effect again can replace the context an earlier scope still paints into.
    RELEASE_ASSERT(!paintingFilters->hasPaintScope());
    GraphicsContext* filterContext = paintingFilters->beginFilterEffect(renderer(), *destinationContext, paintingInfo.paintBehavior, enclosingIntRect(rootRelativeBounds), enclosingIntRect(paintingInfo.paintDirtyRect), enclosingIntRect(filterRepaintRect),
        backgroundRect.rect(), applyAdditionalDestinationClip);
    if (!filterContext)
        return FilterPaintScope { *destinationContext, nullptr };

    paintingInfo.paintDirtyRect = paintingFilters->repaintRect();
    if (paintingFilters->hasFilterThatMovesPixels()) {
        m_suppressAncestorClippingInsideFilter = true;
        paintFlags.add(PaintLayerFlag::TemporaryClipRects);
    }
    paintingInfo.requireSecurityOriginAccessForWidgets = paintingFilters->hasFilterThatShouldBeRestrictedBySecurityOrigin();

    return FilterPaintScope { *filterContext, WTF::move(paintingFilters) };
}

void RenderLayer::applyFilters(LentGraphicsContext originalContextView, const FilterPaintScope& filterScope, const LayerPaintingInfo& paintingInfo, OptionSet<PaintBehavior> behavior, ClipRect backgroundRect)
{
    RELEASE_ASSERT(filterScope.filters());
    Ref filters = *filterScope.filters();
    GraphicsContext& originalContext = *originalContextView;
    GraphicsContextStateSaver stateSaver(originalContext, false);
    bool needsClipping = filters->hasSourceImage();

    m_suppressAncestorClippingInsideFilter = false;

    if (needsClipping) {
        RegionContextStateSaver regionContextStateSaver(paintingInfo.regionContext());

        clipToRect(originalContext, stateSaver, regionContextStateSaver, paintingInfo, behavior, backgroundRect, DoNotIncludeSelfForBorderRadius); // The filter output includes our own border, so only clip to ancestors.
    }

    filters->applyFilterEffect(originalContext);
}

bool RenderLayer::paintLayerContentsWithFilters(NOESCAPE LentGraphicsContext context, NOESCAPE LayerPaintingInfo paintingInfo, PaintLayerFlags localPaintFlags, OptionalPaintOrderItemRange svgPaintOrderItemRange,
    NOESCAPE LayerFragmentsView layerFragments, PaintBehaviors& paintBehavior, LayoutSize offsetFromRoot, LayoutSize columnAwareOffsetFromRoot, LayoutSize svgFilterOffset, LayoutSize svgFilterCompensation, ClipRect backgroundRect,
    bool shouldPaintContent, RenderObject* subtreePaintRootForRenderer)
{
    auto localPaintingInfo = paintingInfo;
    auto filterScope = setupFilters(context, localPaintingInfo, localPaintFlags, svgFilterOffset, backgroundRect);
    bool hasFilterContext = !!filterScope.filters();
    if (hasFilterContext)
        paintBehavior.add(PaintBehavior::DontShowVisitedLinks);
    shouldPaintContent = paintLayerContentsWithinFilters(context, LentGraphicsContext { filterScope.context() }, hasFilterContext, paintingInfo, localPaintingInfo, localPaintFlags, svgPaintOrderItemRange,
        layerFragments, paintBehavior, offsetFromRoot, columnAwareOffsetFromRoot, svgFilterOffset, shouldPaintContent, subtreePaintRootForRenderer);
    if (hasFilterContext) {
        GraphicsContextStateSaver filterCompensationSaver(*context, false);
        if (!svgFilterCompensation.isZero()) {
            filterCompensationSaver.save();
            context.translate(svgFilterCompensation);
        }
        applyFilters(context, filterScope, paintingInfo, paintBehavior, backgroundRect);
        // Painting a snapshot might have temporarily overriden the filter painting strategy,
        // make sure it gets reset.
        updateFilterPaintingStrategy();
    }
    return shouldPaintContent;
}

void RenderLayer::collectFragments(LayerFragments& fragments, const RenderLayer* rootLayer, const LayoutRect& dirtyRect, PaginationInclusionMode inclusionMode,
    ClipRectsType clipRectsType, OptionSet<ClipRectsOption> clipRectOptions, const LayoutSize& offsetFromRoot,
    std::optional<LayoutRect> layerBoundingBox, ShouldApplyRootOffsetToFragments applyRootOffsetToFragments)
{
    collectFragmentsForSwift(LayerFragmentsView { fragments }, rootLayer, dirtyRect, inclusionMode, clipRectsType, clipRectOptions, offsetFromRoot, layerBoundingBox, applyRootOffsetToFragments);
}

void RenderLayer::paintContentForRenderer(NOESCAPE PaintInfo& paintInfo, const LayoutPoint& paintOffset)
{
    if (renderer().isInlineBox()) {
        // An inline box has no box of its own to paint. Its fragments are part of the containing block's inline content.
        CheckedRef inlineBox = downcast<RenderBoxModelObject>(renderer());
        if (CheckedPtr lineLayout = LayoutIntegration::LineLayout::containing(inlineBox.get()))
            lineLayout->paint(paintInfo, paintOffset, inlineBox.ptr());
        return;
    }

    renderer().paint(paintInfo, paintOffset);
}

bool RenderLayer::isCollectingAXCustomColorBackdrops(const LayerPaintingInfo& paintingInfo) const
{
#if ENABLE(AX_CUSTOM_COLOR_MODE)
    return is<AXCustomColorBackdropContext>(paintingInfo.regionContext());
#else
    UNUSED_PARAM(paintingInfo);
    return false;
#endif
}

void RenderLayer::collectAXCustomColorBackdropsForFragments(const LayerFragments& layerFragments, NOESCAPE LentGraphicsContext context, const LayerPaintingInfo& localPaintingInfo, OptionSet<PaintBehavior> paintBehavior)
{
#if ENABLE(AX_CUSTOM_COLOR_MODE)
    ASSERT(is<AXCustomColorBackdropContext>(localPaintingInfo.regionContext()));

    for (auto phase : { PaintPhase::AXCustomColorCollectBackgrounds, PaintPhase::AXCustomColorComputeBackdrops }) {
        for (const auto& fragment : layerFragments) {
            if (!fragment.shouldPaintContent || fragment.dirtyForegroundRect().isEmpty())
                continue;

            PaintInfo paintInfo(*context, fragment.dirtyForegroundRect().rect(), phase, paintBehavior);
            paintInfo.setRegionContext(localPaintingInfo.regionContext());
            paintInfo.regionContext()->pushClip(enclosingIntRect(fragment.dirtyBackgroundRect().rect()));

            renderer().paint(paintInfo, paintOffsetForRenderer(fragment, localPaintingInfo));
            paintInfo.regionContext()->popClip();
        }
    }
#else
    UNUSED_PARAM(layerFragments);
    UNUSED_PARAM(context);
    UNUSED_PARAM(localPaintingInfo);
    UNUSED_PARAM(paintBehavior);
#endif
}

bool RenderLayer::hitTest(const HitTestRequest& request, HitTestResult& result)
{
    return hitTest(request, result.hitTestLocation(), result);
}

bool RenderLayer::hitTest(const HitTestRequest& request, const HitTestLocation& hitTestLocation, HitTestResult& result)
{
    ASSERT(isSelfPaintingLayer() || hasSelfPaintingLayerDescendant());
    ASSERT(!renderer().view().needsLayout());
    ASSERT(!isRenderFragmentedFlow());
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    return hitTestForSwift(request, hitTestLocation, HitTestResultView { result });
}

#if ENABLE(SPATIAL_PORTAL)
bool RenderLayer::isHostedInSpatialPortalScene() const
{
    return m_backing && m_backing->hostingSpatialPortalController();
}

std::optional<TransformationMatrix> RenderLayer::hostedPortalContentProjection(const RenderLayer& space) const
{
    CheckedPtr controller = m_backing ? m_backing->hostingSpatialPortalController() : nullptr;
    auto* portalLayer = parent();
    if (!controller || !portalLayer)
        return std::nullopt;

    auto portalOffset = offsetFromAncestor(&space) - offsetFromAncestor(portalLayer);
    TransformationMatrix projection;
    projection.translate(portalOffset.width(), portalOffset.height());
    projection.multiply(controller->hostedContentProjection());
    projection.translate(-portalOffset.width(), -portalOffset.height());
    return projection;
}
#endif

Element* RenderLayer::enclosingElement() const
{
    for (RenderElement* r = &renderer(); r; r = r->parent()) {
        if (Element* e = r->element())
            return e;
    }
    return nullptr;
}

Vector<RenderLayer*> RenderLayer::topLayerRenderLayers(const RenderView& renderView)
{
    Vector<RenderLayer*> layers;
    for (auto& element : renderView.document().topLayerElements()) {
        auto* renderer = element->renderer();
        if (!renderer)
            continue;

        auto backdropRenderer = renderer->pseudoElementRenderer(PseudoElementType::Backdrop);
        if (backdropRenderer && backdropRenderer->hasLayer() && backdropRenderer->layer()->parent())
            layers.append(backdropRenderer->layer());

        if (renderer->hasLayer()) {
            auto& modelObject = downcast<RenderLayerModelObject>(*renderer);
            if (modelObject.layer()->parent())
                layers.append(modelObject.layer());
        }
    }
    return layers;
}

static RefPtr<Element> flattenedParent(Element* element)
{
    if (!element)
        return nullptr;
    RefPtr parent = element->parentElementInComposedTree();
    while (parent) {
        if (!parent->isConnected() || parent->computedStyle()->display() != Style::DisplayType::Contents)
            break;
        parent = parent->parentElementInComposedTree();
    }
    return parent;
}

bool RenderLayer::ancestorLayerIsDOMParent(const RenderLayer* ancestor) const
{
    if (!ancestor)
        return false;
    auto parent = flattenedParent(renderer().element());
    if (parent && ancestor->renderer().element() == parent)
        return true;
    if (renderer().style().pseudoElementType()) {
        auto parentPseudoId = parentPseudoElement(*renderer().style().pseudoElementType());
        return parentPseudoId && *parentPseudoId == ancestor->renderer().style().pseudoElementType();
    }
    return false;
}

bool RenderLayer::hitTestContentForRenderer(const HitTestRequest& request, HitTestResult& result, const HitTestLocation& hitTestLocation, const LayoutPoint& accumulatedOffset, HitTestFilter hitTestFilter) const
{
    if (!renderer().isInlineBox())
        return renderer().hitTest(request, result, hitTestLocation, accumulatedOffset, hitTestFilter);

    // An inline box has no box of its own to hit test. Its fragments are part of the containing block's inline content.
    CheckedRef inlineBox = downcast<RenderBoxModelObject>(renderer());
    CheckedPtr lineLayout = LayoutIntegration::LineLayout::containing(inlineBox.get());
    if (!lineLayout)
        return false;

    auto hitTestForAction = [&](HitTestAction hitTestAction) {
        return lineLayout->hitTest(request, result, hitTestLocation, accumulatedOffset, hitTestAction, inlineBox.ptr());
    };

    // See RenderObject::hitTest for the phase order.
    if (hitTestFilter != HitTestFilter::Self) {
        if (hitTestForAction(HitTestAction::Foreground) || hitTestForAction(HitTestAction::Float) || hitTestForAction(HitTestAction::ChildBlockBackgrounds))
            return true;
    }

    if (hitTestFilter != HitTestFilter::Descendants)
        return hitTestForAction(HitTestAction::BlockBackground);

    return false;
}

void RenderLayer::verifyClipRects()
{
#ifdef CHECK_CACHED_CLIP_RECTS
    if (!m_clipRectsCache)
        return;

    for (int i = 0; i < NumCachedClipRectsTypes; ++i) {
        if (!m_clipRectsCache->m_clipRectsRoot[i])
            continue;

        ClipRectsContext clipRectsContext(m_clipRectsCache->m_clipRectsRoot[i], (ClipRectsType)i, { });
        verifyClipRect(clipRectsContext);

        clipRectsContext.options.add(ClipRectsOption::RespectOverflowClip);
        verifyClipRect(clipRectsContext);
    }
#endif
}

void RenderLayer::verifyClipRect(const ClipRectsContext& clipRectsContext)
{
#ifdef CHECK_CACHED_CLIP_RECTS
    ASSERT(m_clipRectsCache);
    if (auto* clipRects = m_clipRectsCache->getClipRects(clipRectsContext.clipRectsType, clipRectsContext.respectOverflowClip())) {

        // This code is useful to check cached clip rects, but is too expensive to leave enabled in debug builds by default.
        ClipRectsContext tempContext(clipRectsContext);
        tempContext.options.add(ClipRectsOption::Temporary);
        Ref<ClipRects> tempClipRects = ClipRects::create();
        calculateClipRects(tempContext.rootLayer, tempContext.clipRectsType, tempContext.options, tempClipRects);
        ASSERT(tempClipRects.get() == *clipRects);
    }
#else
    UNUSED_PARAM(clipRectsContext);
#endif
}

LayoutRect RenderLayer::localBoundingBox(OptionSet<CalculateLayerBoundsFlag> flags) const
{
    // There are three special cases we need to consider.
    // (1) Inline Flows.  For inline flows we will create a bounding box that fully encompasses all of the lines occupied by the
    // inline.  In other words, if some <span> wraps to three lines, we'll create a bounding box that fully encloses the
    // line boxes of all three lines (including overflow on those lines).
    // (2) Left/Top Overflow.  The width/height of layers already includes right/bottom overflow.  However, in the case of left/top
    // overflow, we have to create a bounding box that will extend to include this overflow.
    // (3) Floats.  When a layer has overhanging floats that it paints, we need to make sure to include these overhanging floats
    // as part of our bounding box.  We do this because we are the responsible layer for both hit testing and painting those
    // floats.
    LayoutRect result;
    if (renderer().isInlineBox())
        result = downcast<RenderBoxModelObject>(renderer()).visualOverflowRect();
    else if (CheckedPtr modelObject = dynamicDowncast<RenderSVGModelObject>(renderer()))
        result = modelObject->visualOverflowRectEquivalent();
    else if (CheckedPtr tableRow = dynamicDowncast<RenderTableRow>(renderer())) {
        // Our bounding box is just the union of all of our cells' border/overflow rects.
        for (RenderTableCell* cell = tableRow->firstCell(); cell; cell = cell->nextCell()) {
            LayoutRect bbox = cell->borderBoxRect();
            result.unite(bbox);
            LayoutRect overflowRect = tableRow->visualOverflowRect();
            if (bbox != overflowRect)
                result.unite(overflowRect);
        }
    } else {
        RenderBox* box = renderBox();
        ASSERT(box);
        // An SVG renderer (<text>, <foreignObject>) is masked by an SVG mask resource, and its visual
        // overflow rect already covers that resource. The CSS mask clip rect comes from the border box
        // and leaves out the SVG content that spills outside it, so it would cut that content off.
        if (!(flags & DontConstrainForMask) && box->hasMask() && !box->isSVGLayerAwareRenderer()) {
            result = box->maskClipRect(LayoutPoint());
            box->physicalToBlockStartRelative(result); // The mask clip rect is in physical coordinates, so we have to convert it, since localBoundingBox is not.
        } else if (flags.contains(ExcludeFilterOutsetsFromSelfBounds) && !box->hasLayoutOverflow()) {
            ASSERT(box->hasFilter());
            result = box->applyVisualEffectOverflow(box->borderBoxRect(), { RenderBox::VisualEffectOverflowOption::ExcludeFilterOutsets });
        } else
            result = box->visualOverflowRect();

        if (flags.contains(IncludeRootBackgroundPaintingArea) && renderer().isDocumentElementRenderer()) {
            // If the root layer becomes composited (e.g. because some descendant with negative z-index is composited),
            // then it has to be big enough to cover the viewport in order to display the background. This is akin
            // to the code in RenderBox::paintRootBoxFillLayers().
            CheckedRef frameView = renderer().view().frameView();
            result.setWidth(std::max(result.width(), frameView->contentsWidth() - result.x()));
            result.setHeight(std::max(result.height(), frameView->contentsHeight() - result.y()));
        }
    }
    return result;
}

bool RenderLayer::getOverlapBoundsIncludingChildrenAccountingForTransformAnimations(LayoutRect& bounds, OptionSet<CalculateLayerBoundsFlag> additionalFlags) const
{
    // The animation will override the display transform, so don't include it.
    auto boundsFlags = additionalFlags | (defaultCalculateLayerBoundsFlags() - IncludeSelfTransform);

    bounds = calculateLayerBounds(this, LayoutSize(), boundsFlags);
    if (m_backing)
        bounds.expand(toLayoutBoxExtent(m_backing->filterAnimationOutsets()));

    LayoutRect animatedBounds = bounds;
    if (auto styleable = Styleable::fromRenderer(renderer())) {
        if (styleable->computeAnimationExtent(animatedBounds)) {
            bounds = animatedBounds;
            return true;
        }
    }

    return false;
}

ClipRects* RenderLayer::cachedClipRects(ClipRectsType clipRectsType, bool respectOverflowClip, const RenderLayer* rootLayer) const
{
    if (!m_clipRectsCache)
        return nullptr;
    auto* clipRects = m_clipRectsCache->getClipRects(clipRectsType, respectOverflowClip);
    ASSERT_UNUSED(rootLayer, !clipRects || rootLayer == m_clipRectsCache->m_clipRectsRoot[clipRectsType]);
    return clipRects;
}

void RenderLayer::ensureClipRectsCache(ClipRectsType clipRectsType, const RenderLayer* rootLayer)
{
    if (!m_clipRectsCache)
        m_clipRectsCache = makeUnique<ClipRectsCache>();
#if ASSERT_ENABLED
    m_clipRectsCache->m_clipRectsRoot[clipRectsType] = rootLayer;
#else
    UNUSED_PARAM(clipRectsType);
    UNUSED_PARAM(rootLayer);
#endif
}

void RenderLayer::setCachedClipRects(ClipRectsType clipRectsType, bool respectOverflowClip, ClipRects& clipRects)
{
    m_clipRectsCache->setClipRects(clipRectsType, respectOverflowClip, &clipRects);
}

bool RenderLayer::rendererShouldUsePositionedClipping() const
{
    return renderer().shouldUsePositionedClipping();
}

void RenderLayer::resetClipRectsCache()
{
    m_clipRectsCache = nullptr;
}

void RenderLayer::clearCachedClipRects(ClipRectsType typeToClear)
{
    if (!m_clipRectsCache)
        return;
    m_clipRectsCache->setClipRects(typeToClear, RespectOverflowClip, nullptr);
    m_clipRectsCache->setClipRects(typeToClear, IgnoreOverflowClip, nullptr);
}

RenderLayerBacking* RenderLayer::ensureBacking()
{
    if (!m_backing) {
        m_backing = makeUnique<RenderLayerBacking>(*this);
        compositor().layerBecameComposited(*this);

        updateFilterPaintingStrategy();
    }
    return m_backing.get();
}

void RenderLayer::clearBacking(OptionSet<UpdateBackingSharingFlags> flags, bool layerBeingDestroyed)
{
    if (!m_backing)
        return;

    if (!renderer().renderTreeBeingDestroyed())
        compositor().layerBecameNonComposited(*this);
    
    m_backing->willBeDestroyed(flags);
    m_backing = nullptr;

    if (!layerBeingDestroyed)
        updateFilterPaintingStrategy();
}

// Since we're only painting non-composited layers, we know that they all share the same repaintContainer.
void RenderLayer::repaintIncludingNonCompositingDescendants(const RenderLayerModelObject* repaintContainer)
{
    auto clippedOverflowRect = m_repaintRectsValid ? m_repaintRects.clippedOverflowRect : renderer().clippedOverflowRectForRepaint(repaintContainer);
    renderer().repaintUsingContainer(repaintContainer, clippedOverflowRect);

    for (RenderLayer* curr = firstChild(); curr; curr = curr->nextSibling()) {
        if (!curr->isComposited())
            curr->repaintIncludingNonCompositingDescendants(repaintContainer);
    }
}

static bool hasVisibleBoxDecorationsOrBackground(const RenderElement& renderer)
{
    return renderer.hasVisibleBoxDecorations() || renderer.style().hasOutline();
}

#if HAVE(SUPPORT_HDR_DISPLAY)
static bool rendererHasHDRContent(const RenderElement& renderer)
{
    auto& style = renderer.style();

    if (CheckedPtr imageRenderer = dynamicDowncast<RenderImage>(renderer)) {
        if (auto* cachedImage = imageRenderer->cachedImage()) {
            if (cachedImage->hasHDRContent())
                return true;
        }
    } else if (CheckedPtr imageRenderer = dynamicDowncast<LegacyRenderSVGImage>(renderer)) {
        if (auto* cachedImage = imageRenderer->imageResource().cachedImage()) {
            if (cachedImage->hasHDRContent())
                return true;
        }
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    } else if (CheckedPtr canvasRenderer = dynamicDowncast<RenderHTMLCanvas>(renderer)) {
        if (auto* renderingContext = canvasRenderer->canvasElement().renderingContext()) {
            if (renderingContext->isHDR())
                return true;
        }
#endif
    }

    auto styleHasHDRContent = [](const auto& style) {
        if (auto& backgroundLayers = style.backgroundLayers(); Style::hasImageInAnyLayer(backgroundLayers) && Style::hasHDRContent(backgroundLayers)) {
            return true;
        }

        if (auto image = style.borderImageSource().tryImage()) {
            if (auto* cachedImage = image ? image->value->cachedImage() : nullptr) {
                if (cachedImage->hasHDRContent())
                    return true;
            }
        }

        if (RefPtr image = style.listStyleImage().tryStyleImage()) {
            if (auto* cachedImage = image->cachedImage()) {
                if (cachedImage->hasHDRContent())
                    return true;
            }
        }

        return false;
    };

    return styleHasHDRContent(style);
}
#endif

static void determineNonLayerDescendantsPaintedContent(const RenderElement& renderer, unsigned& renderersTraversed, RenderLayer::PaintedContentRequest& request)
{
    // Constrain the depth and breadth of the search for performance.
    static constexpr unsigned maxRendererTraversalCount = 200;

    for (const auto& child : childrenOfType<RenderObject>(renderer)) {
        if (++renderersTraversed > maxRendererTraversalCount) {
            if (!request.isPaintedContentSatisfied())
                request.makePaintedContentUndetermined();
            if (request.isSatisfied())
                return;
        }

        if (CheckedPtr renderText = dynamicDowncast<RenderText>(child)) {
            if (!renderText->hasRenderedText())
                continue;

            if (renderer.style().usedUserSelect() != UserSelect::None)
                request.setHasPaintedContent();

            if (!renderText->text().containsOnly<isASCIIWhitespace>())
                request.setHasPaintedContent();

            if (request.isSatisfied())
                return;
        }
        
        CheckedPtr childRenderElement = dynamicDowncast<RenderElement>(child);
        if (!childRenderElement)
            continue;

        if (auto* modelObject = dynamicDowncast<RenderLayerModelObject>(*childRenderElement); modelObject && modelObject->hasSelfPaintingLayer())
            continue;

        if (hasVisibleBoxDecorationsOrBackground(*childRenderElement)) {
            request.setHasPaintedContent();
            if (request.isSatisfied())
                return;
        }
        
        if (is<RenderReplaced>(*childRenderElement)) {
            request.setHasPaintedContent();

            if (request.isSatisfied())
                return;
        }

#if HAVE(SUPPORT_HDR_DISPLAY)
        if (!request.isHDRContentSatisfied() && rendererHasHDRContent(*childRenderElement)) {
            request.setHasHDRContent();

            if (request.isSatisfied())
                return;
        }
#endif

        determineNonLayerDescendantsPaintedContent(*childRenderElement, renderersTraversed, request);
        if (request.isSatisfied())
            return;
    }
}

void RenderLayer::determineNonLayerDescendantsPaintedContent(PaintedContentRequest& request) const
{
    unsigned renderersTraversed = 0;
    WebCore::determineNonLayerDescendantsPaintedContent(renderer(), renderersTraversed, request);
}

#if HAVE(SUPPORT_HDR_DISPLAY)
bool RenderLayer::rendererHasHDRContent() const
{
    if (auto* imageDocument = dynamicDowncast<ImageDocument>(renderer().document()))
        return imageDocument->drawsHDRContent();
    return WebCore::rendererHasHDRContent(renderer());
}
#endif

bool RenderLayer::isVisuallyNonEmpty(PaintedContentRequest* request) const
{
    ASSERT(!m_visibleContentStatusDirty);

    if (!hasVisibleContent() || renderer().style().opacity().isTransparent())
        return false;

    if (renderer().isRenderReplaced() || (m_scrollableArea && m_scrollableArea->hasOverflowControls())) {
        if (!request)
            return true;

        request->setHasPaintedContent();
        if (request->isSatisfied())
            return true;
    }

#if HAVE(SUPPORT_HDR_DISPLAY)
    if (request && !request->isHDRContentSatisfied() && WebCore::rendererHasHDRContent(renderer())) {
        request->setHasHDRContent();

        if (request->isSatisfied())
            return true;
    }
#endif

    if (hasVisibleBoxDecorationsOrBackground()) {
        if (!request)
            return true;

        request->setHasPaintedContent();
        if (request->isSatisfied())
            return true;
    }

    PaintedContentRequest localRequest;
    if (!request)
        request = &localRequest;

    determineNonLayerDescendantsPaintedContent(*request);
    return request->probablyHasPaintedContent();
}

void RenderLayer::updateReflectionAfterStyleChange()
{
    if (!hasReflection() && m_reflection)
        removeReflection();
    else if (hasReflection()) {
        if (!m_reflection)
            createReflection();
        else
            m_reflection->setStyle(createReflectionStyle());
    }
}

RenderBox* RenderLayer::reflectionForSwift() const
{
    return m_reflection.get();
}

RenderLayer* RenderLayer::reflectionLayer() const
{
    return m_reflection ? m_reflection->layer() : nullptr;
}

void RenderLayer::createReflection()
{
    ASSERT(!m_reflection);
    m_reflection = createRenderer<RenderReplica>(renderer().document(), createReflectionStyle());
    // FIXME: A renderer should be a child of its parent!
    m_reflection->setParent(&renderer()); // We create a 1-way connection.
    m_reflection->initializeStyle();
}

void RenderLayer::willBeDropped()
{
    if (inResizeMode())
        renderer().frame().eventHandler().resizeLayerDestroyed();

    if (m_reflection)
        removeReflection();
}

void RenderLayer::removeReflection()
{
    if (!m_reflection->renderTreeBeingDestroyed()) {
        if (auto* layer = m_reflection->layer())
            removeChild(*layer);
    }

    m_reflection->setParent(nullptr);
    m_reflection = nullptr;
}

UniqueRef<Style::ComputedStyle> RenderLayer::createReflectionStyle()
{
    auto newStyle = Style::ComputedStyle::create();
    newStyle->inheritFrom(renderer().style());
    
    auto reflection = renderer().style().boxReflect().tryReflection();

    switch (reflection->direction) {
    case ReflectionDirection::Below:
        newStyle->setTransform({
            { Style::TranslateTransformFunction::create(0_css_px, 100_css_percentage, Style::TransformFunctionType::Translate) },
            { Style::TranslateTransformFunction::create(0_css_px, reflection->offset, Style::TransformFunctionType::Translate) },
            { Style::ScaleTransformFunction::create(1_css_number, -1_css_number, Style::TransformFunctionType::Scale) },
        });
        break;
    case ReflectionDirection::Above:
        newStyle->setTransform({
            { Style::ScaleTransformFunction::create(1_css_number, -1_css_number, Style::TransformFunctionType::Scale) },
            { Style::TranslateTransformFunction::create(0_css_px, 100_css_percentage, Style::TransformFunctionType::Translate) },
            { Style::TranslateTransformFunction::create(0_css_px, reflection->offset, Style::TransformFunctionType::Translate) },
        });
        break;
    case ReflectionDirection::Right:
        newStyle->setTransform({
            { Style::TranslateTransformFunction::create(100_css_percentage, 0_css_px, Style::TransformFunctionType::Translate) },
            { Style::TranslateTransformFunction::create(reflection->offset, 0_css_px, Style::TransformFunctionType::Translate) },
            { Style::ScaleTransformFunction::create(-1_css_number, 1_css_number, Style::TransformFunctionType::Scale) },
        });
        break;
    case ReflectionDirection::Left:
        newStyle->setTransform({
            { Style::ScaleTransformFunction::create(-1_css_number, 1_css_number, Style::TransformFunctionType::Scale) },
            { Style::TranslateTransformFunction::create(100_css_percentage, 0_css_px, Style::TransformFunctionType::Translate) },
            { Style::TranslateTransformFunction::create(reflection->offset, 0_css_px, Style::TransformFunctionType::Translate) },
        });
        break;
    }

    // Map in our mask.
    newStyle->setMaskBorder(Style::MaskBorder { reflection->mask });

    // Style has transform and mask, so needs to be stacking context.
    newStyle->setUsedZIndex(0);

    return newStyle;
}

RenderLayerFilters& RenderLayer::ensureLayerFilters()
{
    if (m_filters)
        return *m_filters;
    
    m_filters = RenderLayerFilters::create(*this);
    return *m_filters;
}

void RenderLayer::clearLayerFilters()
{
    if (RefPtr filters = std::exchange(m_filters, nullptr))
        filters->detachFromLayer();
}

RenderLayerScrollableArea* RenderLayer::ensureLayerScrollableArea()
{
    bool hadScrollableArea = scrollableArea();
    
    if (!m_scrollableArea)
        m_scrollableArea = makeUnique<RenderLayerScrollableArea>(*this);

    if (!hadScrollableArea) {
        if (renderer().settings().asyncOverflowScrollingEnabled())
            setNeedsCompositingConfigurationUpdate();

        m_scrollableArea->restoreScrollPosition();
    }

    return m_scrollableArea.get();
}

void RenderLayer::clearLayerScrollableArea()
{
    if (m_scrollableArea) {
        m_scrollableArea->clear();
        m_scrollableArea = nullptr;
    }
}

void RenderLayer::didAddOrRemoveScrollbars()
{
    InspectorInstrumentation::didAddOrRemoveScrollbars(m_renderer);
}

IntOutsets RenderLayer::layerFiltersOutsets() const
{
    if (!m_filters)
        return { };
    return m_filters->calculateOutsets(renderer(), localBoundingBox());
}

void RenderLayer::expandLayerFiltersDirtySourceRect(LayoutRect rect)
{
    if (m_filters)
        m_filters->expandDirtySourceRect(rect);
}

void RenderLayer::updateLayerFiltersReferenceClients()
{
    ensureLayerFilters().updateReferenceFilterClients(renderer().style().filter());
}

void RenderLayer::removeLayerFiltersReferenceClients()
{
    if (m_filters)
        m_filters->removeReferenceFilterClients();
}

bool RenderLayer::filterIsIdentity(const Style::ComputedStyle& style) const
{
    return CSSFilterRenderer::isIdentity(renderer(), style.filter());
}

bool RenderLayer::filterIsReferenceFilter(const Style::ComputedStyle& style)
{
    return style.filter().isReferenceFilter();
}

bool RenderLayer::filterDiffersFromOldStyle(const Style::ComputedStyle& oldStyle) const
{
    return oldStyle.filter() != renderer().style().filter();
}

bool RenderLayer::currentColorChangeRequiresFilterRepaint(const Style::ComputedStyle& oldStyle) const
{
    return oldStyle.color() != renderer().style().color() && oldStyle.filter().hasFilterThatRequiresRepaintForCurrentColorChange();
}

void RenderLayer::clearFilters()
{
    if (m_filters)
        m_filters->clearFilter();
}

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
bool RenderLayer::allowsDynamicContentScaling() const
{
    if (is<RenderHTMLCanvas>(renderer()))
        return false;

    if (isBitmapOnly())
        return false;

    return true;
}
#endif

bool RenderLayer::hasNonOpacityTransparency() const
{
    if (renderer().hasMask())
        return true;

    if (hasBlendMode() || isolatesBlending())
        return true;

    if (!renderer().document().settings().layerBasedSVGEngineEnabled())
        return false;

    // SVG clip-paths may use clipping masks, if so, flag this layer as transparent.
    if (CheckedPtr svgClipper = renderer().svgClipperResourceFromStyle(); svgClipper && !svgClipper->shouldApplyPathClipping())
        return true;

    return false;
}

bool RenderLayer::isBitmapOnly() const
{
    if (hasVisibleBoxDecorationsOrBackground())
        return false;

    if (is<RenderHTMLCanvas>(renderer()))
        return true;

    if (CheckedPtr imageRenderer = dynamicDowncast<RenderImage>(renderer())) {
        if (auto* cachedImage = imageRenderer->cachedImage()) {
            if (!cachedImage->hasImage())
                return false;
            return is<BitmapImage>(cachedImage->image());
        }
        return false;
    }

    return false;
}

void RenderLayer::simulateFrequentPaint()
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    m_paintFrequencyTracker.track(page().lastRenderingUpdateTimestamp());
}

void RenderLayer::purgeFrontBufferForTesting()
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    if (backing())
        backing()->purgeFrontBufferForTesting();
}

void RenderLayer::purgeBackBufferForTesting()
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    if (backing())
        backing()->purgeBackBufferForTesting();
}

void RenderLayer::markFrontBufferVolatileForTesting()
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    if (backing())
        backing()->markFrontBufferVolatileForTesting();
}

RenderLayerScrollableArea* RenderLayer::scrollableArea() const
{
    return m_scrollableArea.get();
}

#if ENABLE(ASYNC_SCROLLING) && !LOG_DISABLED
static TextStream& operator<<(TextStream& ts, RenderLayer::EventRegionInvalidationReason reason)
{
    switch (reason) {
    case RenderLayer::EventRegionInvalidationReason::Paint: ts << "Paint"_s; break;
    case RenderLayer::EventRegionInvalidationReason::SettingDidChange: ts << "SettingDidChange"_s; break;
    case RenderLayer::EventRegionInvalidationReason::Style: ts << "Style"_s; break;
    case RenderLayer::EventRegionInvalidationReason::NonCompositedFrame: ts << "NonCompositedFrame"_s; break;
    }
    return ts;
}
#endif // !LOG_DISABLED

bool RenderLayer::invalidateEventRegion(EventRegionInvalidationReason reason)
{
#if ENABLE(ASYNC_SCROLLING)
    RenderLayer* compositingLayer = enclosingCompositingLayerForRepaint().layer;

    auto shouldInvalidate = [&] {
        if (!compositingLayer)
            return false;

        if (reason == EventRegionInvalidationReason::NonCompositedFrame)
            return true;

        return compositingLayer->backing()->maintainsEventRegion();
    };

    if (!shouldInvalidate())
        return false;

    LOG_WITH_STREAM(EventRegions, stream << this << " invalidateEventRegion for reason " << reason << " invalidating in compositing layer " << compositingLayer);

    compositingLayer->backing()->setNeedsEventRegionUpdate();
    compositingLayer->setAncestorsHaveDescendantNeedingEventRegionUpdate();

    if (reason == EventRegionInvalidationReason::NonCompositedFrame) {
        auto& view = renderer().view();
        LOG_WITH_STREAM(EventRegions, stream << " calling setNeedsEventRegionUpdateForNonCompositedFrame on " << view);
        view.setNeedsEventRegionUpdateForNonCompositedFrame();
        auto visibleDebugOverlayRegions = OptionSet<DebugOverlayRegions>::fromRaw(renderer().settings().visibleDebugOverlayRegions());
        if (visibleDebugOverlayRegions.containsAny({ DebugOverlayRegions::TouchActionRegion, DebugOverlayRegions::EditableElementRegion, DebugOverlayRegions::WheelEventHandlerRegion }))
            view.setNeedsRepaintHackAfterCompositingLayerUpdateForDebugOverlaysOnly();
        view.compositor().scheduleCompositingLayerUpdate();
    }
    return true;
#else
    UNUSED_PARAM(reason);
    return false;
#endif
}

TextStream& operator<<(WTF::TextStream& ts, ClipRectsType clipRectsType)
{
    switch (clipRectsType) {
    case PaintingClipRects: ts << "painting"_s; break;
    case RootRelativeClipRects: ts << "root-relative"_s; break;
    case AbsoluteClipRects: ts << "absolute"_s; break;
    case AllClipRectTypes: ts << "all"_s; break;
    case NumCachedClipRectsTypes:
        ts << '?';
        break;
    }
    return ts;
}

TextStream& operator<<(TextStream& ts, const RenderLayer& layer)
{
    ts << layer.debugDescription();
    return ts;
}

TextStream& operator<<(TextStream& ts, const RenderLayer::ClipRectsContext& context)
{
    ts.dumpProperty("root layer:"_s, context.rootLayer);
    ts.dumpProperty("type:"_s, context.clipRectsType);
    ts.dumpProperty("options:"_s, context.options);

    return ts;
}

TextStream& operator<<(WTF::TextStream& ts, RenderLayer::ClipRectsOption clipRectsOption)
{
    switch (clipRectsOption) {
    case RenderLayer::ClipRectsOption::RespectOverflowClip: ts << "respect-overflow-clip"_s; break;
    case RenderLayer::ClipRectsOption::IncludeOverlayScrollbarSize: ts << "include-overlay-scrollbar-size"_s; break;
    case RenderLayer::ClipRectsOption::Temporary: ts << "temporary"_s; break;
    case RenderLayer::ClipRectsOption::OutsideFilter: ts << "outside-filter"_s; break;
    }
    return ts;
}

TextStream& operator<<(TextStream& ts, IndirectCompositingReason reason)
{
    switch (reason) {
    case IndirectCompositingReason::None: ts << "none"_s; break;
    case IndirectCompositingReason::Clipping: ts << "clipping"_s; break;
    case IndirectCompositingReason::Stacking: ts << "stacking"_s; break;
    case IndirectCompositingReason::OverflowScrollPositioning: ts << "overflow positioning"_s; break;
    case IndirectCompositingReason::Overlap: ts << "overlap"_s; break;
    case IndirectCompositingReason::BackgroundLayer: ts << "background layer"_s; break;
    case IndirectCompositingReason::GraphicalEffect: ts << "graphical effect"_s; break;
    case IndirectCompositingReason::Perspective: ts << "perspective"_s; break;
    case IndirectCompositingReason::Preserve3D: ts << "preserve-3d"_s; break;
    }

    return ts;
}

TextStream& operator<<(TextStream& ts, PaintBehavior behavior)
{
    switch (behavior) {
    case PaintBehavior::Normal: ts << "Normal"_s; break;
    case PaintBehavior::SelectionOnly: ts << "SelectionOnly"_s; break;
    case PaintBehavior::SkipSelectionHighlight: ts << "SkipSelectionHighlight"_s; break;
    case PaintBehavior::ForceBlackText: ts << "ForceBlackText"_s; break;
    case PaintBehavior::ForceWhiteText: ts << "ForceWhiteText"_s; break;
    case PaintBehavior::ForceBlackBorder: ts << "ForceBlackBorder"_s; break;
    case PaintBehavior::RenderingSVGClipOrMask: ts << "RenderingSVGClipOrMask"_s; break;
    case PaintBehavior::SkipRootBackground: ts << "SkipRootBackground"_s; break;
    case PaintBehavior::RootBackgroundOnly: ts << "RootBackgroundOnly"_s; break;
    case PaintBehavior::SelectionAndBackgroundsOnly: ts << "SelectionAndBackgroundsOnly"_s; break;
    case PaintBehavior::ExcludeSelection: ts << "ExcludeSelection"_s; break;
    case PaintBehavior::FlattenCompositingLayers: ts << "FlattenCompositingLayers"_s; break;
    case PaintBehavior::ForceSynchronousImageDecode: ts << "ForceSynchronousImageDecode"_s; break;
    case PaintBehavior::DefaultAsynchronousImageDecode: ts << "DefaultAsynchronousImageDecode"_s; break;
    case PaintBehavior::CompositedOverflowScrollContent: ts << "CompositedOverflowScrollContent"_s; break;
    case PaintBehavior::AnnotateLinks: ts << "AnnotateLinks"_s; break;
    case PaintBehavior::EventRegionIncludeForeground: ts << "EventRegionIncludeForeground"_s; break;
    case PaintBehavior::EventRegionIncludeBackground: ts << "EventRegionIncludeBackground"_s; break;
    case PaintBehavior::Snapshotting: ts << "Snapshotting"_s; break;
    case PaintBehavior::DontShowVisitedLinks: ts << "DontShowVisitedLinks"_s; break;
    case PaintBehavior::ExcludeReplacedContentExceptForIFrames: ts << "ExcludeReplacedContentExceptForIFrames"_s; break;
    case PaintBehavior::ExcludeText: ts << "ExcludeText"_s; break;
    case PaintBehavior::FixedAndStickyLayersOnly: ts << "FixedAndStickyLayersOnly"_s; break;
    case PaintBehavior::DrawsHDRContent: ts << "DrawsHDRContent"_s; break;
    case PaintBehavior::DraggableSnapshot: ts << "DraggableSnapshot"_s; break;
    case PaintBehavior::IncludeDocumentMarkers: ts << "IncludeDocumentMarkers"_s; break;
    case PaintBehavior::FastAndLowQualityFilters: ts << "FastAndLowQualityFilters"_s; break;
    }

    return ts;
}

TextStream& operator<<(TextStream& ts, RenderLayer::PaintLayerFlag flag)
{
    switch (flag) {
    case RenderLayer::PaintLayerFlag::HaveTransparency: ts << "HaveTransparency"_s; break;
    case RenderLayer::PaintLayerFlag::AppliedTransform: ts << "AppliedTransform"_s; break;
    case RenderLayer::PaintLayerFlag::TemporaryClipRects: ts << "TemporaryClipRects"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingReflection: ts << "PaintingReflection"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingOverlayScrollbars: ts << "PaintingOverlayScrollbars"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingCompositingBackgroundPhase: ts << "PaintingCompositingBackgroundPhase"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingCompositingForegroundPhase: ts << "PaintingCompositingForegroundPhase"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingCompositingMaskPhase: ts << "PaintingCompositingMaskPhase"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingCompositingClipPathPhase: ts << "PaintingCompositingClipPathPhase"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingOverflowContainer: ts << "PaintingOverflowContainer"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingOverflowContents: ts << "PaintingOverflowContents"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingOverflowContentsRoot: ts << "PaintingOverflowContentsRoot"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingRootBackgroundOnly: ts << "PaintingRootBackgroundOnly"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingSkipRootBackground: ts << "PaintingSkipRootBackground"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingChildClippingMaskPhase: ts << "PaintingChildClippingMaskPhase"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingSVGClippingMask: ts << "PaintingSVGClippingMask"_s; break;
    case RenderLayer::PaintLayerFlag::CollectingEventRegion: ts << "CollectingEventRegion"_s; break;
    case RenderLayer::PaintLayerFlag::PaintingSkipDescendantViewTransition: ts << "PaintingSkipDescendantViewTransition"_s; break;
    }

    return ts;
}


#undef LAYER_POSITIONS_ASSERT_ENABLED
#undef LAYER_POSITIONS_ASSERT
#undef LAYER_POSITIONS_ASSERT_IMPLIES

bool RenderLayer::isScreenCaptureProtectionLayer() const
{
    CheckedPtr innerBlock = dynamicDowncast<RenderTextControlInnerBlock>(renderer());
    return innerBlock && innerBlock->requiresLayerForScreenCaptureProtection();
}

} // namespace WebCore

#if ENABLE(TREE_DEBUGGING)

void showLayerTree(const WebCore::RenderLayer* layer)
{
    if (!layer)
        return;

    String output = externalRepresentation(&layer->renderer().frame(), {
        WebCore::RenderAsTextFlag::ShowAllLayers,
        WebCore::RenderAsTextFlag::ShowLayerNesting,
        WebCore::RenderAsTextFlag::ShowCompositedLayers,
        WebCore::RenderAsTextFlag::ShowOverflow,
        WebCore::RenderAsTextFlag::ShowSVGGeometry,
        WebCore::RenderAsTextFlag::ShowLayerFragments,
        WebCore::RenderAsTextFlag::ShowAddresses,
        WebCore::RenderAsTextFlag::ShowIDAndClass,
        WebCore::RenderAsTextFlag::DontUpdateLayout,
        WebCore::RenderAsTextFlag::ShowLayoutState,
    });
    SAFE_FPRINTF(stderr, "\n%s\n", output.utf8());
}

void showLayerTree(const WebCore::RenderObject* renderer)
{
    if (!renderer)
        return;
    showLayerTree(renderer->enclosingLayer());
}

static void outputPaintOrderTreeLegend(TextStream& stream)
{
    stream.nextLine();
    stream << "(T)op layer, (S)tacking Context/(F)orced SC/O(P)portunistic SC, (N)ormal flow only, (O)verflow clip, (A)lpha (opacity or mask), has (B)lend mode, (I)solates blending, (T)ransform-ish, (F)ilter, Fi(X)ed position, Behaves as fi(x)ed, (C)omposited, (P)rovides backing/uses (p)rovided backing/paints to (a)ncestor, (c)omposited descendant, (s)scrolling ancestor, (t)transformed ancestor\n"
        "Dirty (z)-lists, Dirty (n)ormal flow lists\n"
        "Traversal needs: requirements (t)raversal on descendants, (b)acking or hierarchy traversal on descendants, (r)equirements traversal on all descendants, requirements traversal on all (s)ubsequent layers, (h)ierarchy traversal on all descendants, update of paint (o)rder children\n"
        "Update needs:    post-(l)ayout requirements, (g)eometry, (k)ids geometry, (c)onfig, layer conne(x)ion, (s)crolling tree\n"
        "Scrolling scope: box contents\n";
    stream.nextLine();
}

static void outputIndent(TextStream& stream, unsigned depth)
{
    unsigned i = 0;
    while (++i <= depth * 2)
        stream << " ";
}

static void outputPaintOrderTreeRecursive(TextStream& stream, const WebCore::RenderLayer& layer, ASCIILiteral prefix, unsigned depth = 0)
{
    stream << (layer.establishesTopLayer() ? "T"_s : "-"_s);
    stream << (layer.isCSSStackingContext() ? "S"_s : (layer.isForcedStackingContext() ? "F"_s : (layer.isOpportunisticStackingContext() ? "P"_s : "-"_s)));
    stream << (layer.isNormalFlowOnly() ? "N"_s : "-"_s);
    stream << (layer.renderer().hasNonVisibleOverflow() ? "O"_s : "-"_s);
    stream << (layer.isTransparent() ? "A"_s : "-"_s);
    stream << (layer.hasBlendMode() ? "B"_s : "-"_s);
    stream << (layer.isolatesBlending() ? "I"_s : "-"_s);
    stream << (layer.renderer().hasTransformRelatedProperty() ? "T"_s : "-"_s);
    stream << (layer.hasFilter() ? "F"_s : "-"_s);
    stream << (layer.renderer().isFixedPositioned() ? "X"_s : "-"_s);
    stream << (layer.behavesAsFixed() ? "x"_s : "-"_s);
    stream << (layer.isComposited() ? "C"_s : "-"_s);
    
    auto compositedPaintingDestinationString = [&layer]() {
        if (layer.paintsIntoProvidedBacking())
            return "p"_s;

        if (!layer.isComposited())
            return "-"_s;

        if (layer.backing()->hasBackingSharingLayers())
            return "P"_s;
        
        if (layer.backing()->paintsIntoCompositedAncestor())
            return "a"_s;

        return "-"_s;
    };

    stream << compositedPaintingDestinationString();
    stream << (layer.hasCompositingDescendant() ? "c"_s : "-"_s);
    stream << (layer.hasCompositedScrollingAncestor() ? "s"_s : "-"_s);
    stream << (layer.hasTransformedAncestor() ? "t"_s : "-"_s);

    stream << " "_s;

    stream << (layer.zOrderListsDirty() ? "z"_s : "-"_s);
    stream << (layer.normalFlowListDirty() ? "n"_s : "-"_s);

    stream << " "_s;

    stream << (layer.hasDescendantNeedingCompositingRequirementsTraversal() ? "t"_s : "-"_s);
    stream << (layer.hasDescendantNeedingUpdateBackingOrHierarchyTraversal() ? "b"_s : "-"_s);
    stream << (layer.descendantsNeedCompositingRequirementsTraversal() ? "r"_s : "-"_s);
    stream << (layer.subsequentLayersNeedCompositingRequirementsTraversal() ? "s"_s : "-"_s);
    stream << (layer.descendantsNeedUpdateBackingAndHierarchyTraversal() ? "h"_s : "-"_s);
    stream << (layer.needsCompositingPaintOrderChildrenUpdate() ? "o"_s : "-"_s);

    stream << " "_s;

    stream << (layer.needsPostLayoutCompositingUpdate() ? "l"_s : "-"_s);
    stream << (layer.needsCompositingGeometryUpdate() ? "g"_s : "-"_s);
    stream << (layer.childrenNeedCompositingGeometryUpdate() ? "k"_s : "-"_s);
    stream << (layer.needsCompositingConfigurationUpdate() ? "c"_s : "-"_s);
    stream << (layer.needsCompositingLayerConnection() ? "x"_s : "-"_s);
    stream << (layer.needsScrollingTreeUpdate() ? "s"_s : "-"_s);

    stream << " "_s;

    stream << layer.boxScrollingScope();
    stream << " "_s;
    stream << layer.contentsScrollingScope();

    stream << " "_s;

    outputIndent(stream, depth);

    stream << prefix;

    auto layerRect = layer.rect();

    stream << &layer << " "_s << layerRect;

    if (auto* scrollableArea = layer.scrollableArea())
        stream << " [SA "_s << scrollableArea << "]"_s;

    if (layer.isComposited()) {
        auto& backing = *layer.backing();
        stream << " (layerID "_s << (backing.graphicsLayer()->primaryLayerID() ? backing.graphicsLayer()->primaryLayerID()->object().toUInt64() : 0) << ")"_s;
        
        if (layer.indirectCompositingReason() != WebCore::IndirectCompositingReason::None)
            stream << " "_s << layer.indirectCompositingReason();

        auto scrollingNodeID = backing.scrollingNodeIDForRole(WebCore::ScrollCoordinationRole::Scrolling);
        auto frameHostingNodeID = backing.scrollingNodeIDForRole(WebCore::ScrollCoordinationRole::FrameHosting);
        auto pluginHostingNodeID = backing.scrollingNodeIDForRole(WebCore::ScrollCoordinationRole::PluginHosting);
        auto viewportConstrainedNodeID = backing.scrollingNodeIDForRole(WebCore::ScrollCoordinationRole::ViewportConstrained);
        auto positionedNodeID = backing.scrollingNodeIDForRole(WebCore::ScrollCoordinationRole::Positioning);

        if (scrollingNodeID || frameHostingNodeID || viewportConstrainedNodeID || positionedNodeID) {
            stream << " {"_s;
            bool first = true;
            if (scrollingNodeID) {
                stream << "sc "_s << scrollingNodeID;
                first = false;
            }

            if (frameHostingNodeID) {
                if (!first)
                    stream << ", "_s;
                stream << "fh "_s << frameHostingNodeID;
                first = false;
            }

            if (pluginHostingNodeID) {
                if (!first)
                    stream << ", "_s;
                stream << "ph "_s << pluginHostingNodeID;
                first = false;
            }

            if (viewportConstrainedNodeID) {
                if (!first)
                    stream << ", "_s;
                stream << "vc "_s << viewportConstrainedNodeID;
                first = false;
            }

            if (positionedNodeID) {
                if (!first)
                    stream << ", "_s;
                stream << "pos "_s << positionedNodeID;
            }

            stream << "}"_s;
        }

        if (backing.subpixelOffsetFromRenderer() != WebCore::LayoutSize())
            stream << " (subpixel offset "_s << backing.subpixelOffsetFromRenderer() << ")"_s;
    }
    stream << " "_s << layer.name();
    stream.nextLine();

    const_cast<WebCore::RenderLayer&>(layer).updateLayerListsIfNeeded();

    for (auto* child : layer.negativeZOrderLayers())
        outputPaintOrderTreeRecursive(stream, *child, "- "_s, depth + 1);

    for (auto* child : layer.normalFlowLayers())
        outputPaintOrderTreeRecursive(stream, *child, "n "_s, depth + 1);

    for (auto* child : layer.positiveZOrderLayers())
        outputPaintOrderTreeRecursive(stream, *child, "+ "_s, depth + 1);
}

void showPaintOrderTree(const WebCore::RenderLayer* layer)
{
    TextStream stream;
    outputPaintOrderTreeLegend(stream);
    if (layer)
        outputPaintOrderTreeRecursive(stream, *layer, ""_s);
    
    SAFE_WTFLOGALWAYS("%s", stream.release().utf8());
}

void showPaintOrderTree(const WebCore::RenderObject* renderer)
{
    if (!renderer)
        return;
    showPaintOrderTree(renderer->enclosingLayer());
}

static void outputLayerPositionTreeLegend(TextStream& stream)
{
    stream.nextLine();
    stream << "Dirty flags: NeedsPosition(U)pdate, (D)escendantNeedsPositionUpdate, All(C)hildrenNeedPositionUpdate, (A)llDescendantsNeedPositionUpdate\n";
    stream << "Repaint status: (-)NeedsNormalRepaint, Needs(F)ullRepaint, NeedsFullRepaintFor(P)ositionedMovementLayout\n";
    stream << "Layer state: has(P)aginatedAncestor, has(F)ixedAncestor,  hasFixedContaining(B)lockAncestor, has(T)ransformedAncestor, has(3)DTransformedAncestor, hasComposited(S)crollingAncestor, !is(V)isibilityHiddenOrOpacityZero(), isSelfPainting(L)ayer, (C)omposited, CompositedWithOwn(B)ackingStore\n";
    stream.nextLine();
}

void outputLayerPositionTreeRecursive(TextStream& stream, const WebCore::RenderLayer& layer, unsigned depth, const WebCore::RenderLayer* mark)
{
    if (&layer == mark)
        stream << "*"_s;
    else
        stream << " "_s;

    stream << (layer.m_layerPositionDirtyBits.contains(WebCore::RenderLayer::LayerPositionUpdates::NeedsPositionUpdate) ? "U"_s : "-"_s);
    stream << (layer.m_layerPositionDirtyBits.contains(WebCore::RenderLayer::LayerPositionUpdates::DescendantNeedsPositionUpdate) ? "D"_s : "-"_s);
    stream << (layer.m_layerPositionDirtyBits.contains(WebCore::RenderLayer::LayerPositionUpdates::AllChildrenNeedPositionUpdate) ? "C"_s : "-"_s);
    stream << (layer.m_layerPositionDirtyBits.contains(WebCore::RenderLayer::LayerPositionUpdates::AllDescendantsNeedPositionUpdate) ? "A"_s : "-"_s);

    stream << " "_s;

    if (layer.repaintStatus() == WebCore::RepaintStatus::NeedsFullRepaintForOutOfFlowMovementLayout)
        stream << "P";
    else if (layer.repaintStatus() == WebCore::RepaintStatus::NeedsFullRepaint)
        stream << "F";
    else
        stream << "-";

    stream << " "_s;

    stream << (layer.hasPaginatedAncestor() ? "P"_s : "-"_s);
    stream << (layer.hasFixedAncestor() ? "F"_s : "-"_s);
    stream << (layer.hasFixedContainingBlockAncestor() ? "B"_s : "-"_s);
    stream << (layer.hasTransformedAncestor() ? "T"_s : "-"_s);
    stream << (layer.has3DTransformedAncestor() ? "3"_s : "-"_s);
    stream << (layer.hasCompositedScrollingAncestor() ? "S"_s : "-"_s);
    stream << (!layer.isVisibilityHiddenOrOpacityZero() ? "V"_s : "-"_s);
    stream << (layer.isSelfPaintingLayer() ? "L"_s : "-"_s);
    stream << (layer.isComposited() ? "C"_s : "-"_s);
    stream << (compositedWithOwnBackingStore(layer) ? "B"_s : "-"_s);

    // FIXME: cached clip rects?

    stream << " "_s;

    outputIndent(stream, depth);

    auto layerRect = layer.rect();

    stream << &layer << " "_s << layerRect;

    stream << " "_s << layer.name();

    if (layer.paintOrderParent() != layer.parent())
        stream << " (paint order parent " << layer.paintOrderParent() << ")";

    if (layer.m_repaintContainer)
        stream << " (repaint container: " << layer.m_repaintContainer.get() << ")";

    if (layer.repaintRects())
        stream << " (repaint rects " << *layer.repaintRects() << ")";

    if (layer.paintsIntoProvidedBacking())
        stream << " (backing provider " << layer.backingProviderLayer() << ")";

    stream.nextLine();

    for (WebCore::RenderLayer* child = layer.firstChild(); child; child = child->nextSibling())
        outputLayerPositionTreeRecursive(stream, *child, depth + 1, mark);
}

void showLayerPositionTree(const WebCore::RenderLayer* root, const WebCore::RenderLayer* mark)
{
    TextStream stream;
    outputLayerPositionTreeLegend(stream);
    if (root)
        outputLayerPositionTreeRecursive(stream, *root, 0, mark);

    SAFE_WTFLOGALWAYS("%s", stream.release().utf8());
}

#endif
