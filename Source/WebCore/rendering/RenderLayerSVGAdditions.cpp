/*
 * Copyright (C) 2026 Igalia S.L.
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
 */

#include "config.h"
#include "RenderLayer.h"

#include "CSSFilterRenderer.h"
#include "HitTestRequest.h"
#include "HitTestResult.h"
#include "PaintClipPathScope.h"
#include "ReferencedSVGResources.h"
#include "RenderAncestorIterator.h"
#include "RenderBoxInlines.h"
#include "RenderDescendantIterator.h"
#include "RenderElementInlines.h"
#include "RenderElementStyleInlines.h"
#include "RenderIterator.h"
#include "RenderLayerBacking.h"
#include "RenderLayerFilters.h"
#include "RenderLayerInlines.h"
#include "RenderLayerModelObject.h"
#include "RenderLayerSVGAdditionsInlines.h"
#include "RenderObjectInlines.h"
#include "RenderSVGContainer.h"
#include "RenderSVGForeignObject.h"
#include "RenderSVGHiddenContainer.h"
#include "RenderSVGInline.h"
#include "RenderSVGModelObject.h"
#include "RenderSVGModelObjectInlines.h"
#include "RenderSVGResourceClipper.h"
#include "RenderSVGResourceContainer.h"
#include "RenderSVGRoot.h"
#include "RenderSVGShape.h"
#include "RenderSVGText.h"
#include "RenderSVGViewportContainer.h"
#include "SVGFilterElement.h"
#include "SVGRenderSupport.h"
#include "SVGSVGElement.h"
#include "Settings.h"
#include "StyleTransformResolver.h"
#include "TransformationMatrix.h"
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(RenderLayer::SVGData);

// Applies clip-path and mask to a non-layer SVG renderer for the lifetime of the scope, the
// non-layer counterpart of the layer paint flow. A clip-path clips with a path via ClipPathScope
// when possible. A mask, and a clip-path that cannot be a path, need a transparency layer capturing
// the renderer's foreground, which the destructor composites the mask and the clipper over with
// destination-in once the content is done.
class SVGNonLayerClippingAndMaskingScope {
    WTF_MAKE_NONCOPYABLE(SVGNonLayerClippingAndMaskingScope);
public:
    SVGNonLayerClippingAndMaskingScope(GraphicsContext& context, RenderElement& child, std::optional<LayoutSize> offsetFromRoot, const RenderLayer::LayerPaintingInfo& paintingInfo, OptionSet<PaintBehavior> paintBehavior, RenderObject* subtreePaintRoot, RenderLayer& hostLayer, bool isCollectingEventRegion, StateSavedByCaller stateSavedByCaller = StateSavedByCaller::No)
        : m_context(context)
        , m_paintingInfo(paintingInfo)
        , m_paintBehavior(paintBehavior)
        , m_subtreePaintRoot(subtreePaintRoot)
        , m_hostLayer(hostLayer)
    {
        CheckedPtr svgChild = dynamicDowncast<RenderLayerModelObject>(child);
        if (!svgChild || (!child.hasClipPath() && !child.hasMask()) || !offsetFromRoot || (context.paintingDisabled() && !isCollectingEventRegion) || paintingInfo.paintDirtyRect.isEmpty())
            return;

        m_renderer = svgChild.get();
        m_offsetFromRoot = *offsetFromRoot;

        if (child.hasClipPath())
            m_clipScope.emplace(context, paintingInfo.regionContext(), *svgChild, *offsetFromRoot, LayoutSize(), LayoutRect(), isCollectingEventRegion, Paint::ClipPathScope::CoordinateMode::NonLayerPaint, stateSavedByCaller);

        // The mask, and a clip that can't be a path, composite over the foreground, so they need a
        // painting context. While only the event region is collected there is nothing to composite.
        if (context.paintingDisabled())
            return;

        m_paintsMask = child.hasMask();
        m_paintsClippingMask = m_clipScope && m_clipScope->needsMaskClipping();

        if (m_paintsMask || m_paintsClippingMask)
            m_maskLayer.emplace(context, 1);
    }

    ~SVGNonLayerClippingAndMaskingScope()
    {
        if (!m_maskLayer)
            return;

        CheckedRef renderer = *m_renderer;

        if (m_paintsMask)
            paintPhase(renderer.get(), PaintPhase::Mask, LayoutPoint(m_offsetFromRoot));

        if (m_paintsClippingMask) {
            auto maskOriginTranslation = m_offsetFromRoot;
            if (renderer->isSVGLayerAwareRenderer())
                maskOriginTranslation += toLayoutSize(renderer->currentSVGLayoutLocation()) - toLayoutSize(renderer->nominalSVGLayoutLocation());

            GraphicsContextStateSaver maskCTMSaver(m_context, false);
            if (!maskOriginTranslation.isZero()) {
                maskCTMSaver.save();
                m_context.translate(maskOriginTranslation);
            }

            paintPhase(renderer.get(), PaintPhase::ClippingMask, LayoutPoint());
        }

        m_maskLayer.reset();
    }

    NODELETE bool paintsIntoMaskLayer() const { return !!m_maskLayer; }

private:
    void paintPhase(RenderLayerModelObject& renderer, PaintPhase phase, const LayoutPoint& paintOffset)
    {
        PaintInfo paintInfo(m_context, m_paintingInfo.paintDirtyRect, phase, m_paintBehavior, m_subtreePaintRoot.get(), nullptr, nullptr, &m_paintingInfo.rootLayer()->renderer(), &m_hostLayer);
        renderer.paint(paintInfo, paintOffset);
    }

    GraphicsContext& m_context;
    const RenderLayer::LayerPaintingInfo m_paintingInfo;
    OptionSet<PaintBehavior> m_paintBehavior;
    CheckedPtr<RenderObject> m_subtreePaintRoot;
    RenderLayer& m_hostLayer;
    CheckedPtr<RenderLayerModelObject> m_renderer;
    LayoutSize m_offsetFromRoot;
    std::optional<Paint::ClipPathScope> m_clipScope;
    std::optional<TransparencyLayerScope> m_maskLayer;
    bool m_paintsMask : 1 { false };
    bool m_paintsClippingMask : 1 { false };
};

void RenderLayer::paintResourceLayerForSVG(GraphicsContext& context, const AffineTransform& layerContentTransform)
{
    ASSERT(m_svgData);
    ASSERT(renderer().document().settings().layerBasedSVGEngineEnabled());

    LayerFreeForbiddenScope layerFreeForbiddenScope;
    bool wasPaintingSVGResourceLayer = m_svgData->isPaintingResourceLayer;
    m_svgData->isPaintingResourceLayer = true;
    context.concatCTM(layerContentTransform);

    auto localPaintDirtyRect = LayoutRect::infiniteRect();

    LayerPaintingInfo paintingInfo(this, localPaintDirtyRect, PaintBehavior::Normal, LayoutSize());

    OptionSet<PaintLayerFlag> flags { PaintLayerFlag::TemporaryClipRects };
    if (!renderer().hasNonVisibleOverflow())
        flags.add({ PaintLayerFlag::PaintingOverflowContents, PaintLayerFlag::PaintingOverflowContentsRoot });

    paintLayer(LentGraphicsContext { context }, paintingInfo, flags);

    m_svgData->isPaintingResourceLayer = wasPaintingSVGResourceLayer;
}

void RenderLayer::paintNonLayerRendererWithClippingAndMaskingForSVG(NOESCAPE LentGraphicsContext context, RenderElement& rendererToPaint, LayoutPoint selfPaintOffset, NOESCAPE LayerPaintingInfo transformedPaintingInfo,
    PaintLayerFlags adjustedPaintFlags, PaintBehaviors paintBehavior, RenderObject* subtreePaintRoot, StateSavedByCaller stateSavedByCaller)
{
    bool isCollectingEventRegion = adjustedPaintFlags.contains(PaintLayerFlag::CollectingEventRegion);
    SVGNonLayerClippingAndMaskingScope clippingAndMaskingScope(*context, rendererToPaint, toLayoutSize(selfPaintOffset), transformedPaintingInfo, paintBehavior, subtreePaintRoot, *this, isCollectingEventRegion, stateSavedByCaller);
    paintNonLayerRendererInTransformScopeForSVG(context, rendererToPaint, selfPaintOffset, transformedPaintingInfo, adjustedPaintFlags, paintBehavior, subtreePaintRoot, stateSavedByCaller, clippingAndMaskingScope.paintsIntoMaskLayer());
}

void RenderLayer::paintNonLayerChildWithClippingAndMaskingForSVG(NOESCAPE LentGraphicsContext context, RenderElement& child, LayoutPoint paintOffset, LayoutPoint adjustedPaintOffset, NOESCAPE LayerPaintingInfo paintingInfo,
    PaintLayerFlags paintFlags, PaintBehaviors paintBehavior, RenderObject* subtreePaintRoot)
{
    bool isCollectingEventRegion = paintFlags.contains(PaintLayerFlag::CollectingEventRegion);
    SVGNonLayerClippingAndMaskingScope clippingAndMaskingScope(*context, child, toLayoutSize(paintOffset), paintingInfo, paintBehavior, subtreePaintRoot, *this, isCollectingEventRegion);
    paintNonLayerChildInTransformScopeForSVG(context, child, paintOffset, adjustedPaintOffset, paintingInfo, paintFlags, paintBehavior, subtreePaintRoot);
}

void RenderLayer::paintNonLayerChildInDOMOrderWithClippingAndMaskingForSVG(NOESCAPE LentGraphicsContext context, RenderElement& childRenderer, unsigned itemIndex, OptionalLayoutSize offsetFromRoot, LayoutSize accumulatedAncestorOffset,
    const LayerFragments& layerFragments, NOESCAPE LayerPaintingInfo paintingInfo, PaintLayerFlags paintFlags, PaintBehaviors paintBehavior, RenderObject* subtreePaintRootForRenderer, LayoutPoint containerBaseOffset, bool isSVGRoot, bool sharedClipApplied)
{
    bool isCollectingEventRegion = paintFlags.contains(PaintLayerFlag::CollectingEventRegion);
    SVGNonLayerClippingAndMaskingScope clippingAndMaskingScope(*context, childRenderer, offsetFromRoot, paintingInfo, paintBehavior, subtreePaintRootForRenderer, *this, isCollectingEventRegion);
    paintNonLayerChildInDOMOrderForSVG(context, childRenderer, itemIndex, accumulatedAncestorOffset, layerFragments, paintingInfo, paintFlags, paintBehavior, subtreePaintRootForRenderer, containerBaseOffset, isSVGRoot, sharedClipApplied);
}

bool RenderLayer::isOverflowHiddenForSVG(const RenderElement& renderer)
{
    return SVGRenderSupport::isOverflowHidden(renderer);
}

FloatRect RenderLayer::viewportForSVG(const RenderElement& viewportContainer)
{
    return downcast<RenderSVGViewportContainer>(viewportContainer).viewport();
}

const RenderObject* RenderLayer::enclosingHiddenOrResourceContainerRendererForSVG() const
{
    return enclosingHiddenOrResourceContainerForSVG();
}

bool RenderLayer::setupClipPathIfNeededForSVG(OptionSet<PaintLayerFlag>& paintFlags)
{
    ASSERT(m_svgData);
    ASSERT(renderer().document().settings().layerBasedSVGEngineEnabled());

    // Applying clip-path on <clipPath> enforces us to use mask based clipping, so disable path based clipping.
    // If isPaintingResourceLayerForSVG() is true, this function was invoked via paintResourceLayerForSVG() -- clipping on <clipPath> is already
    // handled in RenderSVGResourceClipper::applyMaskClipping(), so do not set paintSVGClippingMask to true here.
    if (!is<RenderSVGResourceClipper>(m_svgData->enclosingHiddenOrResourceContainer.get()))
        return false;

    paintFlags.set(PaintLayerFlag::PaintingSVGClippingMask, !m_svgData->isPaintingResourceLayer);
    return true;
}

bool RenderLayer::viewBoxDisablesPaintingForSVG() const
{
    if (CheckedPtr svgRoot = dynamicDowncast<RenderSVGRoot>(renderer()))
        return svgRoot->svgSVGElement().viewBoxDisablesPainting();

    if (CheckedPtr viewportContainer = dynamicDowncast<RenderSVGViewportContainer>(renderer()))
        return viewportContainer->svgSVGElement().viewBoxDisablesPainting();

    return false;
}

bool RenderLayer::svgViewportClipExcludesForSVG(const HitTestLocation& hitTestLocation) const
{
    ASSERT(m_svgData);
    ASSERT(!renderer().isRenderSVGForeignObject());

    // RenderSVGRoot: viewport-clip points outside the SVG content box.
    if (auto* svgRoot = dynamicDowncast<RenderSVGRoot>(renderer())) {
        if (svgRoot->shouldApplyViewportClip() && !hitTestLocation.intersects(svgRoot->contentBoxRect()))
            return true;
    }

    // Ignore points outside a nested <svg> viewport. hitTestLayer() would only clip them after the children were tested.
    if (auto* viewportContainer = dynamicDowncast<RenderSVGViewportContainer>(renderer())) {
        if (SVGRenderSupport::isOverflowHidden(*viewportContainer) && !hitTestLocation.intersects(viewportContainer->overflowClipRect({ })))
            return true;
    }

    return false;
}

std::optional<TransformationMatrix> RenderLayer::computeContainerTransformForRepaintForSVG() const
{
    // Hidden containers never paint, so their transform needs no repaint.
    CheckedPtr container = dynamicDowncast<RenderSVGContainer>(renderer());
    if (!container || is<RenderSVGHiddenContainer>(*container))
        return std::nullopt;
    return container->computeChildrenToParentUserSpaceTransform();
}

void RenderLayer::setNeedsFullRepaintIfSVGContainerTransformChanged(const RenderLayerModelObject* repaintContainer)
{
    // The children of a container cannot repaint the area under its old transform.
    if (!m_svgData || !m_svgData->containerTransformForRepaintRects || repaintContainer == &renderer())
        return;
    if (m_svgData->containerTransformForRepaintRects != computeContainerTransformForRepaintForSVG())
        m_repaintStatus = RepaintStatus::NeedsFullRepaint;
}

bool RenderLayer::hasFailedFilterForSVG() const
{
    ASSERT(m_svgData);
    ASSERT(renderer().document().settings().layerBasedSVGEngineEnabled());

    // Per the SVG spec, a referenced filter that cannot be applied (missing reference,
    // empty filter) means the element must not be rendered.
    if (!m_filters || m_filters->filter() || !renderer().style().filter().isReferenceFilter())
        return false;
    return WTF::switchOn(renderer().style().filter().first(),
        [&](const Style::FilterReference& reference) {
            return ReferencedSVGResources::referencedFilterElement(protect(renderer().treeScopeForSVGReferences()), reference) != nullptr;
        },
        [&](const auto&) { return false; }
    );
}

void RenderLayer::updateAncestorDependentStateForSVG()
{
    ASSERT(m_svgData);
    ASSERT(renderer().document().settings().layerBasedSVGEngineEnabled());
    m_svgData->enclosingHiddenOrResourceContainer = ancestorsOfType<RenderSVGHiddenContainer>(renderer()).first();
    if (renderer().isRenderSVGRoot())
        updateEstablishesBlendingIsolationGroup();
}

void RenderLayer::dirtyChildrenInDOMOrderForSVG()
{
    ASSERT(m_svgData);
    m_svgData->childrenInDOMOrder.shrink(0); // Use shrink(0) instead of clear() to retain our capacity.
    m_svgData->childrenInDOMOrderDirty = true;

    // Segment ranges index into this flat list, so a rebuild invalidates them. Schedule a configuration
    // update so the segments are recomputed off the fresh list.
    if (isComposited() && backing()->hasSVGPaintOrderSegments())
        setNeedsCompositingConfigurationUpdate();
}

void RenderLayer::clearChildrenInDOMOrderForSVG()
{
    ASSERT(m_svgData);
    m_svgData->childrenInDOMOrderDirty = false;
    m_svgData->childrenInDOMOrder.shrink(0); // Use shrink(0) instead of clear() to retain our capacity.
}

void RenderLayer::appendLayeredChildInDOMOrderForSVG(RenderElement& renderer, RenderLayer& layer, int zIndex)
{
    m_svgData->childrenInDOMOrder.append(SVGPaintOrderLayerItem::makeLayered(renderer, layer, zIndex));
}

void RenderLayer::appendAtomicChildInDOMOrderForSVG(RenderElement& renderer, LayoutSize ancestorOffset)
{
    m_svgData->childrenInDOMOrder.append(SVGPaintOrderLayerItem::makeAtomic(renderer, ancestorOffset));
}

void RenderLayer::appendOutlineOnlyChildInDOMOrderForSVG(RenderElement& renderer, LayoutSize ancestorOffset)
{
    m_svgData->childrenInDOMOrder.append(SVGPaintOrderLayerItem::makeOutlineOnly(renderer, ancestorOffset));
}

bool RenderLayer::clipsSubtreeForSVG(const RenderElement& renderer)
{
    return RenderSVGModelObject::clipsSubtree(renderer);
}

bool RenderLayer::isPaintingSVGResourceLayer() const
{
    return isPaintingResourceLayerForSVG();
}

const Vector<SVGPaintOrderLayerItem>& RenderLayer::childrenInDOMOrderForSVG()
{
    ASSERT(m_svgData);
    if (m_svgData->childrenInDOMOrderDirty)
        collectChildrenInDOMOrderForSVG();
    return m_svgData->childrenInDOMOrder;
}

unsigned RenderLayer::childrenInDOMOrderCountForSVG()
{
    ASSERT(m_svgData);
    return childrenInDOMOrderForSVG().size();
}

RenderLayer* RenderLayer::childLayerInDOMOrderForSVG(unsigned index)
{
    return childrenInDOMOrderForSVG()[index].layer.get();
}

RenderElement* RenderLayer::childRendererInDOMOrderForSVG(unsigned index)
{
    return childrenInDOMOrderForSVG()[index].renderer.get();
}

OptionSet<PaintPhase> RenderLayer::childPhasesToPaintInDOMOrderForSVG(unsigned index)
{
    return childrenInDOMOrderForSVG()[index].phasesToPaint;
}

LayoutSize RenderLayer::childAccumulatedAncestorOffsetInDOMOrderForSVG(unsigned index)
{
    return childrenInDOMOrderForSVG()[index].accumulatedAncestorOffset;
}

} // namespace WebCore
