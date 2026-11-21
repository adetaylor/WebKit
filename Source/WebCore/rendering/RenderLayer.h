/*
 * Copyright (C) 2003-2024 Apple Inc. All rights reserved.
 * Copyright (c) 2020 Igalia S.L.
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

#pragma once

#include <WebCore/AffineTransform.h>
#include <WebCore/ClipRect.h>
#include <WebCore/GraphicsLayerEnums.h>
#include <WebCore/LayerFragment.h>
#include <WebCore/LayoutRect.h>
#include <WebCore/PaintFrequencyTracker.h>
#include <WebCore/PaintInfo.h>
#include <WebCore/RenderBox.h>
#include <WebCore/RenderLayerSVGAdditions.h>
#include <WebCore/RenderObjectDocument.h>
#include <WebCore/RenderPtr.h>
#include <WebCore/RenderSVGModelObject.h>
#include <WebCore/RenderView.h>
#include <WebCore/ScrollAlignment.h>
#include <WebCore/ScrollBehavior.h>
#include <WebCore/ScrollIntoViewContainer.h>
#include <WebCore/TransformationMatrix.h>
#include <bit>
#include <wtf/InlineWeakPtr.h>
#include <wtf/Markable.h>
#include <wtf/Range.h>
#include <wtf/RefCountedWithInlineWeakPtr.h>

#if defined(__swift__)
// WebCore's headers only forward declare these reference-counted JavaScriptCore types. Swift's importer rejects a
// reference-counted type whose definition it cannot reach, so the definitions are included here for it alone.
#include <JavaScriptCore/DOMJITCallDOMGetterSnippet.h>
#include <JavaScriptCore/Snippet.h>
#include <JavaScriptCore/WasmBranchHints.h>
#include <JavaScriptCore/WasmCalleeGroup.h>
#include <JavaScriptCore/WasmInstanceAnchor.h>
#include <JavaScriptCore/WasmModule.h>
#include <JavaScriptCore/WasmModuleDebugInfo.h>
#endif

namespace WTF {
class TextStream;
}

void outputLayerPositionTreeRecursive(TextStream&, const WebCore::RenderLayer&, unsigned, const WebCore::RenderLayer*);

namespace WebCore {

namespace Style {
class ComputedStyle;
struct Filter;
enum class TransformResolverOption : uint8_t;
}

class ClipRects;
class ClipRectsCache;
class Element;
class HitTestRequest;
class HitTestResult;
class LentGraphicsContext;
class HitTestResultView;
class LayerFragmentsView;
class Region;
namespace Paint {
class ClipPathScope;
}
class RegionContext;
class RenderFragmentedFlow;
class RenderLayerBacking;
class RenderLayerCompositor;
class RenderLayerFilters;
class RenderLayerScrollableArea;
class RenderMarquee;
class RenderReplica;
class RenderScrollbarPart;
class RenderSVGHiddenContainer;
class RenderSVGResourceClipper;
class RenderView;
class Scrollbar;
class TransformationMatrix;

enum BorderRadiusClippingRule { IncludeSelfForBorderRadius, DoNotIncludeSelfForBorderRadius };
enum IncludeSelfOrNot { IncludeSelf, ExcludeSelf };
enum CrossFrameBoundaries : bool { No, Yes };
enum class LayoutUpToDate : bool { No, Yes };

enum class RepaintStatus : uint8_t {
    NeedsNormalRepaint,
    NeedsFullRepaint,
    NeedsFullRepaintForOutOfFlowMovementLayout
};

enum ClipRectsType {
    PaintingClipRects, // Relative to painting ancestor. Used for painting.
    RootRelativeClipRects, // Relative to the ancestor treated as the root (e.g. transformed layer). Used for hit testing.
    AbsoluteClipRects, // Relative to the RenderView's layer. Used for compositing overlap testing.
    NumCachedClipRectsTypes,
    AllClipRectTypes,
};

enum ShouldRespectOverflowClip {
    IgnoreOverflowClip,
    RespectOverflowClip
};

enum ShouldApplyRootOffsetToFragments {
    ApplyRootOffsetToFragments,
    IgnoreRootOffsetForFragments
};

enum TransparencyClipBoxBehavior {
    PaintingTransparencyClipBox,
    HitTestingTransparencyClipBox
};

enum TransparencyClipBoxMode {
    DescendantsOfTransparencyClipBox,
    RootOfTransparencyClipBox
};

enum class RequestState {
    Unknown,
    DontCare,
    False,
    True,
    Undetermined
};

enum class IndirectCompositingReason {
    None,
    Clipping,
    Stacking,
    OverflowScrollPositioning,
    Overlap,
    BackgroundLayer,
    GraphicalEffect, // opacity, mask, filter, transform etc.
    Perspective,
    Preserve3D
};

enum class ShouldAllowCrossOriginScrolling : bool { No, Yes };
enum class SkipScrollingTargetElement : bool { No, Yes };

struct ScrollRectToVisibleOptions {
    SelectionRevealMode revealMode { SelectionRevealMode::Reveal };
    ScrollAlignment alignX { ScrollAlignment::alignCenterIfNeeded };
    ScrollAlignment alignY { ScrollAlignment::alignCenterIfNeeded };
    ShouldAllowCrossOriginScrolling shouldAllowCrossOriginScrolling { ShouldAllowCrossOriginScrolling::No };
    ScrollBehavior behavior { ScrollBehavior::Auto };
    OnlyAllowForwardScrolling onlyAllowForwardScrolling { OnlyAllowForwardScrolling::No };
    AllowScrollingOverflowHidden allowScrollingOverflowHidden { AllowScrollingOverflowHidden::Yes };
    std::optional<LayoutRect> visibilityCheckRect { std::nullopt };
    SkipScrollingTargetElement skipScrollingTargetElement { SkipScrollingTargetElement::No };
    ScrollIntoViewContainer container { ScrollIntoViewContainer::All };
};

enum class UpdateBackingSharingFlags {
    DuringCompositingUpdate = 1 << 0,
};
using UpdateBackingSharingFlagSet = OptionSet<UpdateBackingSharingFlags>;

using ScrollingScope = uint64_t;

// A layer pointer that the link members, which Swift defines, return by value. It holds the address as an integer:
// Swift counts a RenderLayer pointer as a strong reference, and would release the layer when it destroys the value.
class LayerRef {
public:
    LayerRef() = default;
    explicit LayerRef(RenderLayer* layer)
        : m_address(std::bit_cast<uintptr_t>(layer))
    {
    }
    operator RenderLayer*() const { return std::bit_cast<RenderLayer*>(m_address); }
    friend bool operator==(const LayerRef& a, const LayerRef& b) { return a.m_address == b.m_address; }
private:
    uintptr_t m_address { 0 };
};

// A layer's tree links, written only by RenderLayerLinks (RenderLayerOwners.swift), through RenderLayerFactory. The drop
// of a layer unlinks it before it frees the layer.
class RenderLayerTreeLinks {
    WTF_MAKE_NONCOPYABLE(RenderLayerTreeLinks);
    WTF_MAKE_NONMOVABLE(RenderLayerTreeLinks);
public:
    RenderLayerTreeLinks() = default;

    RenderLayer* parent() const { return m_parent; }
    RenderLayer* previousSibling() const { return m_previous; }
    // Null for a layer whose drop has begun, as the weak pointers of these links would read. No link names such a layer:
    // a drop clears the links that name a layer before it marks it dropping.
    inline RenderLayer* nextSibling() const;
    inline RenderLayer* firstChild() const;
    RenderLayer* lastChild() const { return m_last; }

private:
    friend class RenderLayerFactory;
    RenderLayer* m_parent { nullptr };
    RenderLayer* m_previous { nullptr };
    RenderLayer* m_next { nullptr };
    RenderLayer* m_first { nullptr };
    RenderLayer* m_last { nullptr };
};

// A layer that RenderLayerOwners made for a renderer, and the store's handle for the layer's owner.
struct CreatedRenderLayer {
    uint64_t owner;
    LayerRef layer;
};

enum class PaintOrderList : uint8_t { Positive, Negative, NormalFlow };

// A layer's one strong reference is its owner's, in RenderLayerOwners (RenderLayerOwners.swift). The count is private, so no
// C++ pointer can hold a layer (CheckedPtr, protect(), Ref), and the destructor is private, so only the release of that
// reference ends a layer.
class RenderLayer final : private RefCountedWithInlineWeakPtr<RenderLayer> {
#if ENABLE(COMPACT_ALLOCATION_FOR_PREFERABLY_COMPACT_TYPES)
    WTF_ALLOW_COMPACT_POINTERS;
#endif
    friend class WTF::RefCountedWithInlineWeakPtr<RenderLayer>;
    friend class WTF::RefCountHeader; // The release of the last reference: the only caller of ~RenderLayer.
    friend class RenderLayerFactory;
    friend class RenderLayerAncestorWalker;
    friend class RenderLayerPaintOrderListWriter;
    friend class RenderLayerTreeLinks;
    friend class RenderLayerModelObject; // willBeDropped().
    WEBCORE_EXPORT ~RenderLayer();

    // Swift's retain and release of a layer (SWIFT_SHARED_REFERENCE).
    SWIFT_UNSAFE void retainForSwift() const { ref(); }
    SWIFT_UNSAFE void releaseForSwift() const
    {
        // A reference released while the layer is destroyed was taken in its destructor. Not a RELEASE_ASSERT: the flag it
        // reads is kept only where CHECK_REF_COUNTED_LIFECYCLE is set, and keeping it in release builds would add a branch
        // to every release of a layer from Swift.
        ASSERT_WITH_SECURITY_IMPLICATION(!refCountDebugger().deletionHasBegun());
        deref();
    }

    // The owner calls this just before it drops the layer: a layer in resize mode makes the event handler forget it, then
    // removing the reflection runs Swift on this layer, which must not take a reference to it once its destruction has begun.
    SWIFT_UNSAFE void willBeDropped();

public:
    using RefCountedWithInlineWeakPtr<RenderLayer>::RefCountedType; // For InlineWeakPtr.

    friend class RenderReplica;
    friend class RenderLayerFilters;
    friend class RenderLayerBacking;
    friend class RenderLayerCompositor;
    friend class RenderLayerScrollableArea;
    friend class LayerListMutationDetector;
    friend void ::outputLayerPositionTreeRecursive(TextStream&, const WebCore::RenderLayer&, unsigned, const WebCore::RenderLayer*);

    NODELETE WEBCORE_EXPORT RenderLayerScrollableArea* scrollableArea() const;
    WEBCORE_EXPORT RenderLayerScrollableArea* ensureLayerScrollableArea();

    String name() const;

    inline Page& page() const; // Defined in RenderLayerInlines.h
    RenderLayerModelObject& renderer() const { return m_renderer; }
    RenderBox* renderBox() const { return dynamicDowncast<RenderBox>(renderer()); }

    RenderLayer* parent() const LIFETIME_BOUND_EXCEPT_IN_SWIFT { return m_links.parent(); }
    RenderLayer* previousSibling() const LIFETIME_BOUND_EXCEPT_IN_SWIFT { return m_links.previousSibling(); }
    RenderLayer* nextSibling() const LIFETIME_BOUND_EXCEPT_IN_SWIFT { return m_links.nextSibling(); }
    RenderLayer* firstChild() const LIFETIME_BOUND_EXCEPT_IN_SWIFT { return m_links.firstChild(); }
    RenderLayer* lastChild() const LIFETIME_BOUND_EXCEPT_IN_SWIFT { return m_links.lastChild(); }
    NODELETE bool isDescendantOf(const RenderLayer&) const;
    RenderLayer* commonAncestorWithLayer(const RenderLayer& layer) const { return linkCommonAncestorWithLayer(layer); }

    // Out-of-line so that a client built once can read the layer tree in any build of WebCore.
    WEBCORE_EXPORT RenderLayer* parentForTesting() const;
    WEBCORE_EXPORT RenderLayer* previousSiblingForTesting() const;
    WEBCORE_EXPORT RenderLayer* nextSiblingForTesting() const;
    WEBCORE_EXPORT RenderLayer* firstChildForTesting() const;
    WEBCORE_EXPORT RenderLayer* lastChildForTesting() const;
    WEBCORE_EXPORT size_t negativeZOrderLayerCountForTesting() const;
    WEBCORE_EXPORT RenderLayer* negativeZOrderLayerAtForTesting(size_t) const;
    WEBCORE_EXPORT size_t normalFlowLayerCountForTesting() const;
    WEBCORE_EXPORT RenderLayer* normalFlowLayerAtForTesting(size_t) const;
    WEBCORE_EXPORT size_t positiveZOrderLayerCountForTesting() const;
    WEBCORE_EXPORT RenderLayer* positiveZOrderLayerAtForTesting(size_t) const;
    WEBCORE_EXPORT bool zOrderListsDirtyForTesting() const;
    WEBCORE_EXPORT bool normalFlowListDirtyForTesting() const;
    WEBCORE_EXPORT bool isStackingContextForTesting() const;
    WEBCORE_EXPORT bool isNormalFlowOnlyForTesting() const;
    WEBCORE_EXPORT void updateLayerListsIfNeededForTesting();
    WEBCORE_EXPORT void dirtyZOrderListsForTesting();
    WEBCORE_EXPORT void dirtyNormalFlowListForTesting();
    WEBCORE_EXPORT int zIndexForTesting() const;
    WEBCORE_EXPORT bool wasOmittedFromZOrderTreeForTesting() const;
    // Bit 0 hasVisibleContent, 1 hasVisibleDescendant, 2 alwaysIncludedInZOrderLists, 3 hasAlwaysIncludedInZOrderListsDescendants,
    // 4 its status dirty, 5 hadNegativeZOrderList.
    WEBCORE_EXPORT unsigned paintOrderMarksForTesting() const;
    WEBCORE_EXPORT unsigned compositingDirtyBitsForTesting() const;
    WEBCORE_EXPORT SWIFT_UNSAFE void addChildForTesting(RenderLayer& newChild, RenderLayer* beforeChild);
    WEBCORE_EXPORT SWIFT_UNSAFE void removeChildForTesting(RenderLayer&);

    // This does an ancestor tree walk. Avoid it!
    const RenderLayer* root() const
    {
        const RenderLayer* curr = this;
        while (curr->parent())
            curr = curr->parent();
        return curr;
    }

    SWIFT_UNSAFE void addChild(RenderLayer& newChild, RenderLayer* beforeChild = nullptr);
    SWIFT_UNSAFE void removeChild(RenderLayer&);

    SWIFT_UNSAFE void insertOnlyThisLayer();
    SWIFT_UNSAFE void removeOnlyThisLayer();

    bool isNormalFlowOnly() const { return m_isNormalFlowOnly; }

    // isStackingContext is true for layers that we've determined should be stacking contexts for painting.
    // Not all stacking contexts are CSS stacking contexts.
    bool isStackingContext() const { return isCSSStackingContext() || m_isOpportunisticStackingContext; }

    // isCSSStackingContext is true for layers that are stacking contexts from a CSS perspective.
    // isCSSStackingContext() => isStackingContext().
    // FIXME: m_forcedStackingContext should affect isStackingContext(), not isCSSStackingContext(), but doing so breaks media control mix-blend-mode.
    bool isCSSStackingContext() const { return m_isCSSStackingContext || m_forcedStackingContext; }

    // Gets the enclosing stacking context for this layer, excluding this layer itself.
    RenderLayer* stackingContext() const { return linkStackingContext(); }

    // Gets the enclosing stacking container for this layer, possibly the layer
    // itself, if it is a stacking container.
    RenderLayer* enclosingStackingContext() { return isStackingContext() ? this : stackingContext(); }

    void forceStackingContextIfNeeded();

    RenderLayer* paintOrderParent() const;

    NODELETE std::optional<LayoutRect> cachedClippedOverflowRect() const;

    void dirtyNormalFlowList();
    void dirtyZOrderLists();
    void dirtyStackingContextZOrderLists();
    void dirtyHiddenStackingContextAncestorZOrderLists();

    bool normalFlowListDirty() const { return m_normalFlowListDirty; }
    bool zOrderListsDirty() const { return m_zOrderListsDirty; }

    bool layerListMutationAllowed() const { return m_layerListMutationAllowed; }
private:
    void setLayerListMutationAllowed(bool flag) { m_layerListMutationAllowed = flag; }
public:

    bool willCompositeClipPath() const;

    // Convert a point in absolute coords into layer coords, taking transforms into account
    LayoutPoint absoluteToContents(LayoutPoint) const;

    NODELETE void setNeedsPositionUpdate();
    void setSelfAndChildrenNeedPositionUpdate();
    void setSelfAndDescendantsNeedPositionUpdate();

private:
    enum class LayerPositionUpdates : uint8_t {
        NeedsPositionUpdate  = 1 << 0,
        DescendantNeedsPositionUpdate = 1 << 1,
        AllChildrenNeedPositionUpdate = 1 << 2,
        AllDescendantsNeedPositionUpdate = 1 << 3,
    };

    // Adds the bit, and returns whether the bits lacked it.
    bool addLayerPositionDirtyBit(LayerPositionUpdates bit)
    {
        if (m_layerPositionDirtyBits.contains(bit))
            return false;
        m_layerPositionDirtyBits.add(bit);
        return true;
    }

    bool needsPositionUpdate() const;
    void clearLayerPositionDirtyBits() { m_layerPositionDirtyBits = { }; }

    OptionSet<LayerPositionUpdates> m_layerPositionDirtyBits;

private:
    explicit RenderLayer(RenderLayerModelObject&);
    void destroy();

    bool hasVisibleContentForPainting() const
    {
        if (!hasVisibleContent())
            return false;
        if (!m_svgData) [[likely]]
            return true;
        return hasVisibleContentForPaintingForSVG();
    }

    // Defined in RenderLayerSVGAdditions.cpp.
    bool hasVisibleContentForPaintingForSVG() const;

public:
    // These flags propagate in paint order (z-order tree).
    enum class Compositing : uint16_t {
        HasDescendantNeedingRequirementsTraversal           = 1 << 0, // Need to do the overlap-testing tree walk because hierarchy or geometry changed.
        HasDescendantNeedingBackingOrHierarchyTraversal     = 1 << 1, // Need to update geometry, configuration and update the GraphicsLayer tree.

        // Things that trigger HasDescendantNeedingRequirementsTraversal
        NeedsPaintOrderChildrenUpdate                       = 1 << 2, // The paint order children of this layer changed (gained/lost child, order change).
        NeedsPostLayoutUpdate                               = 1 << 3, // Needs compositing to be re-evaluated after layout (it depends on geometry).
        DescendantsNeedRequirementsTraversal                = 1 << 4, // Something changed that forces computeCompositingRequirements to traverse all descendant layers.
        SubsequentLayersNeedRequirementsTraversal           = 1 << 5, // Something changed that forces computeCompositingRequirements to traverse all layers later in paint order.

        // Things that trigger HasDescendantNeedingBackingOrHierarchyTraversal
        NeedsGeometryUpdate                                 = 1 << 6, // This layer needs a geometry update.
        NeedsConfigurationUpdate                            = 1 << 7, // This layer needs a configuration update (updating its internal compositing hierarchy).
        NeedsScrollingTreeUpdate                            = 1 << 8, // Something changed that requires this layer's scrolling tree node to be updated.
        NeedsLayerConnection                                = 1 << 9, // This layer needs hookup with its parents or children.
        ChildrenNeedGeometryUpdate                          = 1 << 10, // This layer's composited children need a geometry update.
        DescendantsNeedBackingAndHierarchyTraversal         = 1 << 11, // Something changed that forces us to traverse all descendant layers in updateBackingAndHierarchy.
    };
    using CompositingBits = OptionSet<Compositing>;
private:

    static constexpr OptionSet<Compositing> computeCompositingRequirementsFlags()
    {
        return {
            Compositing::NeedsPaintOrderChildrenUpdate,
            Compositing::NeedsPostLayoutUpdate,
            Compositing::DescendantsNeedRequirementsTraversal,
            Compositing::SubsequentLayersNeedRequirementsTraversal,
        };
    }

    static constexpr OptionSet<Compositing> updateBackingOrHierarchyFlags()
    {
        return {
            Compositing::NeedsLayerConnection,
            Compositing::NeedsGeometryUpdate,
            Compositing::NeedsConfigurationUpdate,
            Compositing::NeedsScrollingTreeUpdate,
            Compositing::ChildrenNeedGeometryUpdate,
            Compositing::DescendantsNeedBackingAndHierarchyTraversal,
        };
    }

    NODELETE void setAncestorsHaveCompositingDirtyFlag(Compositing);

public:
    bool hasDescendantNeedingCompositingRequirementsTraversal() const { return m_compositingDirtyBits.contains(Compositing::HasDescendantNeedingRequirementsTraversal); }
    bool hasDescendantNeedingUpdateBackingOrHierarchyTraversal() const { return m_compositingDirtyBits.contains(Compositing::HasDescendantNeedingBackingOrHierarchyTraversal); }

    bool needsCompositingPaintOrderChildrenUpdate() const { return m_compositingDirtyBits.contains(Compositing::NeedsPaintOrderChildrenUpdate); }
    bool needsPostLayoutCompositingUpdate() const { return m_compositingDirtyBits.contains(Compositing::NeedsPostLayoutUpdate); }
    bool descendantsNeedCompositingRequirementsTraversal() const { return m_compositingDirtyBits.contains(Compositing::DescendantsNeedRequirementsTraversal); }
    bool subsequentLayersNeedCompositingRequirementsTraversal() const { return m_compositingDirtyBits.contains(Compositing::SubsequentLayersNeedRequirementsTraversal); }

    bool needsCompositingLayerConnection() const { return m_compositingDirtyBits.contains(Compositing::NeedsLayerConnection); }
    bool needsCompositingGeometryUpdate() const { return m_compositingDirtyBits.contains(Compositing::NeedsGeometryUpdate); }
    bool needsCompositingConfigurationUpdate() const { return m_compositingDirtyBits.contains(Compositing::NeedsConfigurationUpdate); }
    bool needsScrollingTreeUpdate() const { return m_compositingDirtyBits.contains(Compositing::NeedsScrollingTreeUpdate); }
    bool childrenNeedCompositingGeometryUpdate() const { return m_compositingDirtyBits.contains(Compositing::ChildrenNeedGeometryUpdate); }
    bool descendantsNeedUpdateBackingAndHierarchyTraversal() const { return m_compositingDirtyBits.contains(Compositing::DescendantsNeedBackingAndHierarchyTraversal); }

    template<Compositing V>
    void setRequirementsTraversalDirtyBit()
    {
        m_compositingDirtyBits.add(V);
        setAncestorsHaveCompositingDirtyFlag(Compositing::HasDescendantNeedingRequirementsTraversal);
    }

    void setNeedsCompositingPaintOrderChildrenUpdate() { setRequirementsTraversalDirtyBit<Compositing::NeedsPaintOrderChildrenUpdate>(); }
    void setNeedsPostLayoutCompositingUpdate() { setRequirementsTraversalDirtyBit<Compositing::NeedsPostLayoutUpdate>(); }
    void setDescendantsNeedCompositingRequirementsTraversal() { setRequirementsTraversalDirtyBit<Compositing::DescendantsNeedRequirementsTraversal>(); }
    void setSubsequentLayersNeedCompositingRequirementsTraversal() { setRequirementsTraversalDirtyBit<Compositing::SubsequentLayersNeedRequirementsTraversal>(); }

    void setNeedsPostLayoutCompositingUpdateOnAncestors() { setAncestorsHaveCompositingDirtyFlag(Compositing::NeedsPostLayoutUpdate); }

    template<Compositing V>
    void setBackingAndHierarchyTraversalDirtyBit()
    {
        m_compositingDirtyBits.add(V);
        setAncestorsHaveCompositingDirtyFlag(Compositing::HasDescendantNeedingBackingOrHierarchyTraversal);
    }

    void setNeedsCompositingLayerConnection() { setBackingAndHierarchyTraversalDirtyBit<Compositing::NeedsLayerConnection>(); }
    void setNeedsCompositingGeometryUpdate() { setBackingAndHierarchyTraversalDirtyBit<Compositing::NeedsGeometryUpdate>(); }
    void setNeedsCompositingConfigurationUpdate() { setBackingAndHierarchyTraversalDirtyBit<Compositing::NeedsConfigurationUpdate>(); }
    void setNeedsScrollingTreeUpdate() { setBackingAndHierarchyTraversalDirtyBit<Compositing::NeedsScrollingTreeUpdate>(); }
    void setChildrenNeedCompositingGeometryUpdate() { setBackingAndHierarchyTraversalDirtyBit<Compositing::ChildrenNeedGeometryUpdate>(); }
    void setDescendantsNeedUpdateBackingAndHierarchyTraversal() { setBackingAndHierarchyTraversalDirtyBit<Compositing::DescendantsNeedBackingAndHierarchyTraversal>(); }

    void setNeedsCompositingGeometryUpdateOnAncestors() { setAncestorsHaveCompositingDirtyFlag(Compositing::NeedsGeometryUpdate); }

    bool needsCompositingRequirementsTraversal() const { return m_compositingDirtyBits.containsAny(computeCompositingRequirementsFlags()); }
    void clearCompositingRequirementsTraversalState()
    {
        m_compositingDirtyBits.remove(Compositing::HasDescendantNeedingRequirementsTraversal);
        m_compositingDirtyBits.remove(computeCompositingRequirementsFlags());
    }

    bool needsUpdateBackingOrHierarchyTraversal() const { return m_compositingDirtyBits.containsAny(updateBackingOrHierarchyFlags()); }
    void clearUpdateBackingOrHierarchyTraversalState()
    {
        m_compositingDirtyBits.remove(Compositing::HasDescendantNeedingBackingOrHierarchyTraversal);
        m_compositingDirtyBits.remove(updateBackingOrHierarchyFlags());
    }

    bool needsAnyCompositingTraversal() const { return !m_compositingDirtyBits.isEmpty(); }
    void clearCompositingPaintOrderState() { m_compositingDirtyBits = { }; }

    class LayerList {
        friend class RenderLayer;
    public:
        using iterator = RenderLayer**;
        using const_iterator = RenderLayer * const *;
        using reverse_iterator = std::reverse_iterator<iterator>;
        using const_reverse_iterator = std::reverse_iterator<const_iterator>;

        iterator begin() { return m_layerList ? m_layerList->begin() : nullptr; }
        iterator end() { return m_layerList ? m_layerList->end() : nullptr; }

        reverse_iterator rbegin() { return reverse_iterator(end()); }
        reverse_iterator rend() { return reverse_iterator(begin()); }

        const_iterator begin() const { return m_layerList ? m_layerList->begin() : nullptr; }
        const_iterator end() const { return m_layerList ? m_layerList->end() : nullptr; }

        const_reverse_iterator rbegin() const { return const_reverse_iterator(end()); }
        const_reverse_iterator rend() const { return const_reverse_iterator(begin()); }

        size_t size() const { return m_layerList ? m_layerList->size() : 0; }

    private:
        LayerList(Vector<RenderLayer*>* layerList)
            : m_layerList(layerList)
        {
        }
        
        Vector<RenderLayer*>* m_layerList;
    };

    LayerList normalFlowLayers() const
    {
        ASSERT(!m_normalFlowListDirty);
        return LayerList(m_normalFlowList.get());
    }

    LayerList positiveZOrderLayers() const
    {
        ASSERT(!m_zOrderListsDirty);
        ASSERT(isStackingContext() || !m_posZOrderList);
        return LayerList(m_posZOrderList.get());
    }

    LayerList negativeZOrderLayers() const
    {
        ASSERT(!m_zOrderListsDirty);
        ASSERT(isStackingContext() || !m_negZOrderList);
        return LayerList(m_negZOrderList.get());
    }

    // Update our normal and z-index lists.
    void updateLayerListsIfNeeded();
    void updateDescendantDependentFlags();
    bool descendantDependentFlagsAreDirty() const
    {
        return m_visibleDescendantStatusDirty
            || m_visibleContentStatusDirty
            || m_hasSelfPaintingLayerDescendantDirty
            || m_hasViewportConstrainedDescendantStatusDirty
            || m_hasNotIsolatedBlendingDescendantsStatusDirty
            || m_hasAlwaysIncludedInZOrderListsDescendantsStatusDirty;
    }

    // SVG-specific methods -- defined in RenderLayerSVGAdditionsInlines.h / RenderLayerSVGAdditions.cpp.
    bool isSVGLayer() const { return !!m_svgData; }
    inline bool isPaintingResourceLayerForSVG() const;
    inline RenderSVGHiddenContainer* enclosingHiddenOrResourceContainerForSVG() const;
    void paintResourceLayerForSVG(GraphicsContext&, const AffineTransform&);
    void dirtyChildrenInDOMOrderForSVG();
    void invalidateEnclosingSVGContainerSegmentation();
    bool shouldSkipRepaintAfterLayoutForSVG() const;
    std::optional<TransformationMatrix> computeContainerTransformForRepaintForSVG() const;
    void setNeedsFullRepaintIfSVGContainerTransformChanged(const RenderLayerModelObject* repaintContainer);
    bool hasFailedFilterForSVG() const;
    void updateAncestorDependentStateForSVG();
    NODELETE bool isCompositedSVGPaintOrderChild() const;
    NODELETE bool paintsInlineInSVGContainer() const;
    bool isFlattenedByEnclosingSVGReferenceFilter() const;

    void repaintIncludingDescendants();

    // Indicate that the layer contents need to be repainted. Only has an effect
    // if layer compositing is being used.
    void setBackingNeedsRepaint(GraphicsLayerShouldClipToLayer = GraphicsLayerShouldClipToLayer::Clip);

    // The rect is in the coordinate space of the layer's render object.
    void setBackingNeedsRepaintInRect(LayoutRect, GraphicsLayerShouldClipToLayer = GraphicsLayerShouldClipToLayer::Clip);
    void repaintIncludingNonCompositingDescendants(const RenderLayerModelObject* repaintContainer);

    void styleChanged(Style::Difference);

    bool isSelfPaintingLayer() const { return m_isSelfPaintingLayer; }

    bool cannotBlitToWindow() const;

    inline bool isTransparent() const; // FIXME: This function is incorrectly named. It's isNotOpaque, sometimes called hasOpacity, not isEntirelyTransparent.

    bool hasReflection() const { return renderer().hasReflection(); }
    bool isReflection() const { return renderer().isRenderReplica(); }
    NODELETE RenderLayer* reflectionLayer() const;
    NODELETE bool isReflectionLayer(const RenderLayer&) const;

    inline const LayoutPoint& location() const LIFETIME_BOUND;
    void setLocation(const LayoutPoint& p) { m_topLeft = p; }

    inline const IntSize& size() const LIFETIME_BOUND;
    void setSize(const IntSize& size) { m_layerSize = size; } // Only public for RenderTreeAsText.

    inline LayoutRect rect() const;

    IntSize visibleSize() const;

    int scrollWidth() const;
    int scrollHeight() const;

    // Returns the nearest enclosing layer that is scrollable.
    // FIXME: This can return the RenderView's layer when callers probably want the FrameView as a ScrollableArea.
    WEBCORE_EXPORT RenderLayer* enclosingScrollableLayer(IncludeSelfOrNot, CrossFrameBoundaries) const;

    // Returns true when the layer could do touch scrolling, but doesn't look at whether there is actually scrollable overflow.
    NODELETE bool canUseCompositedScrolling() const;
    // Returns true when there is actually scrollable overflow (requires layout to be up-to-date).
    NODELETE bool hasCompositedScrollableOverflow() const;
    void computeHasCompositedScrollableOverflow(LayoutUpToDate);

    bool hasOverlayScrollbars() const;

    WEBCORE_EXPORT bool isPointInResizeControl(IntPoint localPoint) const;
    IntSize offsetFromResizeCorner(IntPoint localPoint) const;

    std::optional<ScrollbarUpdateScope> updateScrollInfoAfterLayout();
    void updateScrollbarSteps();

    // Returns true if this RenderLayer is a candidate for scrolling during scrollIntoView operations.
    bool shouldTryToScrollForScrollIntoView(ScrollRectToVisibleOptions) const;
    void autoscroll(const IntPoint&);

    NODELETE bool canResize() const;
    LayoutSize minimumSizeForResizing(float zoomFactor) const;
    void resize(const PlatformMouseEvent&, const LayoutSize&);
    bool inResizeMode() const { return m_inResizeMode; }
    void setInResizeMode(bool b) { m_inResizeMode = b; }

    bool isRenderViewLayer() const { return m_isRenderViewLayer; }
    bool isForcedStackingContext() const { return m_forcedStackingContext; }
    bool isOpportunisticStackingContext() const { return m_isOpportunisticStackingContext; }

    [[clang::always_inline]] RenderLayerCompositor& compositor() const { SUPPRESS_UNCOUNTED_ARG return renderer().view().inlineCompositor(); }

    // Notification from the renderer that its content changed (e.g. current frame of image changed).
    // Allows updates of layer content without repainting.
    // Also, allows specifying the changed rectangle to limit the painting when patform supports it.
    void contentChanged(ContentChangeType, std::optional<FloatRect> = std::nullopt);

    bool canRender3DTransforms() const;

    void updateLayerPositionsAfterStyleChange(bool environmentChanged = false);
    void updateLayerPositionsAfterLayout(bool didFullRepaint, bool environmentChanged);
    void updateLayerPositionsAfterOverflowScroll();
    void updateLayerPositionsAfterDocumentScroll();

    bool hasCompositedLayerInEnclosingPaginationChain() const;
    enum PaginationInclusionMode { ExcludeCompositedPaginatedLayers, IncludeCompositedPaginatedLayers };
    RenderLayer* enclosingPaginationLayer(PaginationInclusionMode mode) const LIFETIME_BOUND_EXCEPT_IN_SWIFT
    {
        if (mode == ExcludeCompositedPaginatedLayers && hasCompositedLayerInEnclosingPaginationChain())
            return nullptr;
        return enclosingPaginationLayerInStore();
    }

    void updateTransform();
    
    void updateBlendMode();
    NODELETE void willRemoveChildWithBlendMode();

    const LayoutSize& offsetForInFlowPosition() const LIFETIME_BOUND { return m_offsetForPosition; }

    void clearClipRectsIncludingDescendants(ClipRectsType typeToClear = AllClipRectTypes);
    void clearClipRects(ClipRectsType typeToClear = AllClipRectTypes);

    NODELETE void addBlockSelectionGapsBounds(LayoutRect);
    NODELETE void clearBlockSelectionGapsBounds();
    void repaintBlockSelectionGaps();

    // FIXME: We should ASSERT(!m_visibleContentStatusDirty) here, but see https://bugs.webkit.org/show_bug.cgi?id=71044
    // ditto for hasVisibleDescendant(), see https://bugs.webkit.org/show_bug.cgi?id=71277
    bool hasVisibleContent() const { return m_hasVisibleContent; }
    bool hasVisibleDescendant() const { return m_hasVisibleDescendant; }

    void setHasVisibleContent();
    NODELETE void dirtyVisibleContentStatus();
    NODELETE void dirtyVisibleContentStatusIncludingAncestors();

    bool hasVisibleBoxDecorationsOrBackground() const;
    bool hasVisibleBoxDecorations() const;
    
    NODELETE void setBehavesAsFixed(bool);
    bool behavesAsFixed() const { return m_behavesAsFixed; }

    struct PaintedContentRequest {
        PaintedContentRequest() = default;

        void setHasPaintedContent() { hasPaintedContent = RequestState::True; }
        void makePaintedContentUndetermined() { hasPaintedContent = RequestState::Undetermined; }
        bool probablyHasPaintedContent() const { return hasPaintedContent == RequestState::True || hasPaintedContent == RequestState::Undetermined; }
        bool isPaintedContentSatisfied() const { return hasPaintedContent != RequestState::Unknown; }

#if HAVE(SUPPORT_HDR_DISPLAY)
        void setHasHDRContent() { hasHDRContent = RequestState::True; }
        void makeHDRContentFalse() { hasHDRContent = RequestState::False; }

        void setHDRRequestState(RequestState state) { hasHDRContent = state; }
        bool isHDRContentSatisfied() const { return hasHDRContent != RequestState::Unknown; }
#endif

        bool isSatisfied() const
        {
#if HAVE(SUPPORT_HDR_DISPLAY)
            if (!isHDRContentSatisfied())
                return false;
#endif
            return isPaintedContentSatisfied();
        }

        RequestState hasPaintedContent { RequestState::Unknown };
#if HAVE(SUPPORT_HDR_DISPLAY)
        RequestState hasHDRContent { RequestState::DontCare };
#endif
    };

    NODELETE bool isVisibilityHiddenOrOpacityZero() const;
    NODELETE bool isSubtreeVisibilityHiddenOrOpacityZero() const;

    // Returns true if this layer has visible content (ignoring any child layers).
    bool isVisuallyNonEmpty(PaintedContentRequest* = nullptr) const;
    bool isVisuallyNonEmptyForSwift() const { return isVisuallyNonEmpty(); }
    bool isVisuallyNonEmptyForSwift(PaintedContentRequest& request) const { return isVisuallyNonEmpty(&request); }
    // True if this layer container renderers that paint.
    void determineNonLayerDescendantsPaintedContent(PaintedContentRequest&) const;
#if HAVE(SUPPORT_HDR_DISPLAY)
    // True if renderer itself draws HDR content, no traversal is done.
    bool rendererHasHDRContent() const;
#endif

    inline bool isViewportConstrained() const;

    // FIXME: We should ASSERT(!m_hasSelfPaintingLayerDescendantDirty); here but we hit the same bugs as visible content above.
    // Part of the issue is with subtree relayout: we don't check if our ancestors have some descendant flags dirty, missing some updates.
    bool hasSelfPaintingLayerDescendant() const { return m_hasSelfPaintingLayerDescendant; }

    bool ancestorLayerIsInContainingBlockChain(const RenderLayer& ancestor, const RenderLayer* checkLimit = nullptr) const;

    // Gets the nearest enclosing positioned ancestor layer (also includes
    // the <html> layer and the root layer).
    RenderLayer* enclosingAncestorForPosition(PositionType position) const { return linkEnclosingAncestorForPosition(position); }
    
    RenderLayer* enclosingLayerInContainingBlockOrder() const { return linkEnclosingLayerInContainingBlockOrder(); }
    RenderLayer* enclosingContainingBlockLayer(CrossFrameBoundaries crossFrameBoundaries) const { return linkEnclosingContainingBlockLayer(crossFrameBoundaries); }
    RenderLayer* enclosingFrameRenderLayer() const { return linkEnclosingFrameRenderLayer(); }

    // The layer relative to which clipping rects for this layer are computed.
    RenderLayer* clippingRootForPainting() const { return linkClippingRootForPainting(); }

    RenderLayer* enclosingOverflowClipLayer(IncludeSelfOrNot includeSelf) const { return linkEnclosingOverflowClipLayer(includeSelf); }

    // Enclosing compositing layer; if includeSelf is true, may return this.
    RenderLayer* enclosingCompositingLayer(IncludeSelfOrNot includeSelf = IncludeSelf) const { return linkEnclosingCompositingLayer(includeSelf); }
    struct EnclosingCompositingLayerStatus {
        EnclosingCompositingLayerStatus() = default;
        EnclosingCompositingLayerStatus(bool fullRepaintAlreadyScheduled, LayerRef layer)
            : fullRepaintAlreadyScheduled(fullRepaintAlreadyScheduled)
            , layer(layer)
        {
        }

        bool fullRepaintAlreadyScheduled { false };
        LayerRef layer;
    };
    EnclosingCompositingLayerStatus enclosingCompositingLayerForRepaint(IncludeSelfOrNot = IncludeSelf) const;
    // Same layer as enclosingCompositingLayerForRepaint().layer, without computing fullRepaintAlreadyScheduled.
    RenderLayer* enclosingRepaintTargetLayer(IncludeSelfOrNot includeSelf = IncludeSelf) const { return linkEnclosingRepaintTargetLayer(includeSelf); }
    // Ancestor compositing layer, excluding this.
    RenderLayer* ancestorCompositingLayer() const { return enclosingCompositingLayer(ExcludeSelf); }

    RenderLayer* enclosingPixelMovingFilterLayer(IncludeSelfOrNot includeSelf = IncludeSelf) const { return linkEnclosingPixelMovingFilterLayer(includeSelf); }
    RenderLayer* enclosingFilterRepaintLayer() const { return linkEnclosingFilterRepaintLayer(); }
    enum class UseFilterOutsets : bool { Add, AlreadyIncluded };
    void setFilterBackendNeedsRepaintingInRect(LayoutRect, UseFilterOutsets = UseFilterOutsets::Add);

    NODELETE inline bool canUseOffsetFromAncestor() const;
    NODELETE bool canUseOffsetFromAncestor(const RenderLayer& ancestor) const;

    // FIXME: adjustForColumns allows us to position compositing layers in columns correctly, but eventually they need to be split across columns too.
    enum ColumnOffsetAdjustment { DontAdjustForColumns, AdjustForColumns };
    void convertToPixelSnappedLayerCoords(const RenderLayer* ancestorLayer, IntPoint& location, ColumnOffsetAdjustment adjustForColumns = DontAdjustForColumns) const;
    LayoutPoint convertToLayerCoords(const RenderLayer* ancestorLayer, LayoutPoint, ColumnOffsetAdjustment adjustForColumns = DontAdjustForColumns) const;
    LayoutSize offsetFromAncestor(const RenderLayer*, ColumnOffsetAdjustment = DontAdjustForColumns) const;

    inline int zIndex() const;

    enum class PaintLayerFlag : uint32_t {
        HaveTransparency                      = 1 << 0,
        AppliedTransform                      = 1 << 1,
        TemporaryClipRects                    = 1 << 2,
        PaintingReflection                    = 1 << 3,
        PaintingOverlayScrollbars             = 1 << 4,
        PaintingCompositingBackgroundPhase    = 1 << 5,
        PaintingCompositingForegroundPhase    = 1 << 6,
        PaintingCompositingMaskPhase          = 1 << 7,
        PaintingCompositingClipPathPhase      = 1 << 8,
        PaintingOverflowContainer             = 1 << 9,
        PaintingOverflowContentsRoot          = 1 << 10,
        PaintingOverflowContents              = 1 << 11,
        PaintingRootBackgroundOnly            = 1 << 12,
        PaintingSkipRootBackground            = 1 << 13,
        PaintingChildClippingMaskPhase        = 1 << 14,
        PaintingSVGClippingMask               = 1 << 15,
        CollectingEventRegion                 = 1 << 16,
        PaintingSkipDescendantViewTransition  = 1 << 17,
    };
    using PaintLayerFlags = OptionSet<PaintLayerFlag>;
    using PaintBehaviors = OptionSet<PaintBehavior>;
    using OptionalLayoutRect = std::optional<LayoutRect>;
    using OptionalFloatRect = std::optional<FloatRect>;
    using OptionalIntRect = std::optional<IntRect>;
    using OptionalFloat = std::optional<float>;
    using OptionalPaintOrderItemRange = std::optional<WTF::Range<unsigned>>;
    using OptionalLayoutSize = std::optional<LayoutSize>;
    static constexpr OptionSet<PaintLayerFlag> paintLayerPaintingCompositingAllPhasesFlags() { return { PaintLayerFlag::PaintingCompositingBackgroundPhase, PaintLayerFlag::PaintingCompositingForegroundPhase }; }

    enum class SecurityOriginPaintPolicy { AnyOrigin, AccessibleOriginOnly };

    // The two main functions that use the layer system.  The paint method
    // paints the layers that intersect the damage rect from back to
    // front.  The hitTest method looks for mouse events by walking
    // layers that intersect the point from front to back.
    void paint(GraphicsContext&, const LayoutRect& damageRect, const LayoutSize& subpixelOffset = LayoutSize(), OptionSet<PaintBehavior> = PaintBehavior::Normal,
        RenderObject* subtreePaintRoot = nullptr, OptionSet<PaintLayerFlag> = { }, SecurityOriginPaintPolicy = SecurityOriginPaintPolicy::AnyOrigin, RegionContext* = nullptr);
    WEBCORE_EXPORT bool hitTest(const HitTestRequest&, HitTestResult&);
    bool hitTest(const HitTestRequest&, const HitTestLocation&, HitTestResult&);
    bool hitTestForSwift(HitTestRequest, HitTestLocation, HitTestResultView);

    enum class ClipRectsOption : uint8_t {
        RespectOverflowClip         = 1 << 0,
        IncludeOverlayScrollbarSize = 1 << 1,
        Temporary                   = 1 << 2,
        OutsideFilter               = 1 << 3,
    };
    using ClipRectsOptions = OptionSet<ClipRectsOption>;

    static constexpr OptionSet<ClipRectsOption> clipRectDefaultOptions = { ClipRectsOption::RespectOverflowClip };
    static constexpr OptionSet<ClipRectsOption> clipRectTemporaryOptions = { ClipRectsOption::RespectOverflowClip, ClipRectsOption::Temporary };
    static constexpr ClipRectsOptions clipRectDefaultOptionsForSwift() { return clipRectDefaultOptions; }
    static constexpr ClipRectsOptions clipRectTemporaryOptionsForSwift() { return clipRectTemporaryOptions; }

    struct SWIFT_UNAVAILABLE_IN_SWIFT ClipRectsContext {
        ClipRectsContext(const RenderLayer* inRootLayer, ClipRectsType inClipRectsType, OptionSet<ClipRectsOption> inOptions = clipRectDefaultOptions)
            : rootLayer(inRootLayer)
            , clipRectsType(inClipRectsType)
            , options(inOptions)
        {
            if (inClipRectsType == RootRelativeClipRects)
                options.add(ClipRectsOption::IncludeOverlayScrollbarSize);
        }
        const RenderLayer* rootLayer;
        ClipRectsType clipRectsType;
        OptionSet<ClipRectsOption> options;

        bool respectOverflowClip() const { return options.contains(ClipRectsOption::RespectOverflowClip); }
        OverlayScrollbarSizeRelevancy overlayScrollbarSizeRelevancy() const { return options.contains(ClipRectsOption::IncludeOverlayScrollbarSize) ? OverlayScrollbarSizeRelevancy::IncludeOverlayScrollbarSize : OverlayScrollbarSizeRelevancy::IgnoreOverlayScrollbarSize; }
    };

    // This method figures out our layerBounds in coordinates relative to
    // |rootLayer|. It also computes our background and foreground clip rects
    // for painting/event handling.
    // Pass offsetFromRoot if known.
    LayerFragment::Rects calculateRects(const ClipRectsContext& context, const LayoutSize& offsetFromRoot, const LayoutRect& paintDirtyRect = LayoutRect::infiniteRect()) const { return calculateRects(context.rootLayer, context.clipRectsType, context.options, offsetFromRoot, paintDirtyRect); }
    LayerFragment::Rects calculateRects(const RenderLayer* rootLayer, ClipRectsType, ClipRectsOptions, LayoutSize offsetFromRoot, LayoutRect paintDirtyRect) const;

    // Public just for RenderTreeAsText.
    void collectFragments(LayerFragments&, const RenderLayer* rootLayer, const LayoutRect& dirtyRect,
        PaginationInclusionMode, ClipRectsType, OptionSet<ClipRectsOption>, const LayoutSize& offsetFromRoot,
        std::optional<LayoutRect> layerBoundingBox = std::nullopt, ShouldApplyRootOffsetToFragments = IgnoreRootOffsetForFragments);
    void collectFragmentsForSwift(LayerFragmentsView, const RenderLayer* rootLayer, LayoutRect dirtyRect, PaginationInclusionMode, ClipRectsType, ClipRectsOptions,
        LayoutSize offsetFromRoot, std::optional<LayoutRect> layerBoundingBox, ShouldApplyRootOffsetToFragments);

    LayoutRect transparencyClipBox(const RenderLayer* rootLayer, TransparencyClipBoxBehavior, TransparencyClipBoxMode, PaintBehaviors, std::optional<LayoutRect> paintDirtyRect) const;
        
    LayoutRect childrenClipRect() const; // Returns the foreground clip rect of the layer in the document's coordinate space.
    LayoutRect selfClipRect() const; // Returns the background clip rect of the layer in the document's coordinate space.

    bool clipCrossesPaintingBoundary(ClipRectsType) const;

    // Pass offsetFromRoot if known.
    bool intersectsDamageRect(LayoutRect layerBounds, LayoutRect damageRect, const RenderLayer* rootLayer, LayoutSize offsetFromRoot, std::optional<LayoutRect> cachedBoundingBox = std::nullopt) const;

    enum CalculateLayerBoundsFlag {
        IncludeSelfTransform                           = 1 << 0,
        UseLocalClipRectIfPossible                     = 1 << 1,
        IncludeFilterOutsets                           = 1 << 2,
        IncludePaintedFilterOutsets                    = 1 << 3,
        ExcludeHiddenDescendants                       = 1 << 4,
        DontConstrainForMask                           = 1 << 5,
        IncludeCompositedDescendants                   = 1 << 6,
        UseFragmentBoxesExcludingCompositing           = 1 << 7,
        UseFragmentBoxesIncludingCompositing           = 1 << 8,
        IncludeRootBackgroundPaintingArea              = 1 << 9,
        PreserveAncestorFlags                          = 1 << 10,
        UseLocalClipRectExcludingCompositingIfPossible = 1 << 11,
        ExcludeViewTransitionCapturedDescendants       = 1 << 12,
        ExcludeFilterOutsetsFromSelfBounds             = 1 << 13,
        IncludeDescendantTransforms                    = 1 << 14,
    };
    using CalculateLayerBoundsFlags = OptionSet<CalculateLayerBoundsFlag>;
    static constexpr OptionSet<CalculateLayerBoundsFlag> defaultCalculateLayerBoundsFlags() { return { IncludeSelfTransform, UseLocalClipRectIfPossible, IncludePaintedFilterOutsets, UseFragmentBoxesExcludingCompositing }; }

    // Bounding box relative to some ancestor layer. Pass offsetFromRoot if known.
    LayoutRect boundingBox(const RenderLayer* rootLayer, LayoutSize offsetFromRoot = LayoutSize(), OptionSet<CalculateLayerBoundsFlag> = { }) const;
    // Bounding box in the coordinates of this layer.
    LayoutRect localBoundingBox(OptionSet<CalculateLayerBoundsFlag> = { }) const;
    // Deprecated: Pixel snapped bounding box relative to the root.
    WEBCORE_EXPORT IntRect absoluteBoundingBox() const;
    // Device pixel snapped bounding box relative to the root. absoluteBoundingBox() callers will be directed to this.
    FloatRect absoluteBoundingBoxForPainting() const;

    // Bounds used for layer overlap testing in RenderLayerCompositor.
    LayoutRect overlapBounds() const;
    
    // Takes transform animations into account, returning true if they could be cheaply computed.
    // Unlike overlapBounds, these bounds include descendant layers.
    bool getOverlapBoundsIncludingChildrenAccountingForTransformAnimations(LayoutRect&, OptionSet<CalculateLayerBoundsFlag> additionalFlags = { }) const;

    // If true, this layer's children are included in its bounds for overlap testing.
    // We can't rely on the children's positions if this layer has a filter that could have moved the children's pixels around.
    inline bool overlapBoundsIncludeChildren() const;

    // Can pass offsetFromRoot if known.
    LayoutRect calculateLayerBounds(const RenderLayer* ancestorLayer, LayoutSize offsetFromRoot, OptionSet<CalculateLayerBoundsFlag> = defaultCalculateLayerBoundsFlags()) const;
    
    NODELETE LayoutRect repaintRectIncludingNonCompositingDescendants() const;

    NODELETE void setRepaintStatus(RepaintStatus);
    RepaintStatus repaintStatus() const { return m_repaintStatus; }
    bool needsFullRepaint() const { return m_repaintStatus == RepaintStatus::NeedsFullRepaint || m_repaintStatus == RepaintStatus::NeedsFullRepaintForOutOfFlowMovementLayout; }
    NODELETE bool scheduledFullRepaintCoversContentPaintedBy(const RenderLayer& paintingLayer) const;

    LayoutUnit staticInlinePosition() const { return m_offsetForPosition.width(); }
    LayoutUnit staticBlockPosition() const { return m_offsetForPosition.height(); }
   
    void setStaticInlinePosition(LayoutUnit position) { m_offsetForPosition.setWidth(position); }
    void setStaticBlockPosition(LayoutUnit position) { m_offsetForPosition.setHeight(position); }

    // currentOpacity computes the opacity which takes accelerated animations into account.
    float currentOpacity() const;
    inline float opacityForPainting(OptionSet<PaintBehavior>) const;

    inline bool isTransformed() const;
    // Note that this transform has the transform-origin baked in.
    TransformationMatrix* transform() const LIFETIME_BOUND { return m_transform.get(); }
    // The transform by value, for Swift, which reads no interior pointer.
    std::optional<TransformationMatrix> transformValue() const { return m_transform ? std::optional { *m_transform } : std::nullopt; }
    // updateTransformFromStyle computes a transform according to the passed options (e.g. transform-origin baked in or excluded) and the given style.
    void updateTransformFromStyle(TransformationMatrix&, const Style::ComputedStyle&, OptionSet<Style::TransformResolverOption>) const;
    // currentTransform computes a transform which takes accelerated animations into account. The
    // resulting transform has transform-origin baked in, unless non-default options are given. If
    // the layer does not have a transform, the identity matrix is returned.
    TransformationMatrix currentTransform(OptionSet<Style::TransformResolverOption>) const;
    TransformationMatrix currentTransform() const;
    TransformationMatrix renderableTransform(OptionSet<PaintBehavior>) const;
    
    // Get the children transform (to apply a perspective on children), which is applied to transformed sublayers, but not this layer.
    // Returns true if the layer has a perspective.
    // Note that this transform has the perspective-origin baked in.
    TransformationMatrix perspectiveTransform() const;
    FloatPoint perspectiveOrigin() const;
    FloatPoint3D transformOriginPixelSnappedIfNeeded() const;

    // Style::TransformResolver's options and computations by value, for Swift, which sees the option enum only as declared.
    using TransformResolverOptions = OptionSet<Style::TransformResolverOption>;
    using OptionalAffineTransform = std::optional<AffineTransform>;
    static TransformResolverOptions allTransformOperations();
    static TransformResolverOptions individualTransformOperations();
    static bool includesTransformOrigin(TransformResolverOptions);
    static FloatPoint3D computeTransformOrigin(const Style::ComputedStyle&, FloatRect referenceBox);
    static FloatPoint computePerspectiveOrigin(const Style::ComputedStyle&, FloatRect referenceBox);
    static FloatPoint evaluatePerspectiveOrigin(const Style::ComputedStyle&, FloatSize referenceBoxSize);
    static TransformationMatrix applyingPerspective(TransformationMatrix, const Style::ComputedStyle&, FloatPoint perspectiveOrigin);
    bool isRunningAcceleratedTransformRelatedAnimation() const;
    inline bool preserves3D() const;
    bool has3DTransform() const { return m_transform && !m_transform->isAffine(); }
    bool hasTransformedAncestor() const { return m_hasTransformedAncestor; }
    bool participatesInPreserve3D() const;

    std::optional<LayoutSize> anchorScrollAdjustment() const { return m_anchorScrollAdjustment; }; // This is zero (rather than missing) on certain fixed boxes that don't have an AnchorScrollAdjuster.
    bool setAnchorScrollAdjustment(LayoutSize); // Returns true if changed.
    void clearAnchorScrollAdjustment();

    bool hasFixedContainingBlockAncestor() const { return m_hasFixedContainingBlockAncestor; }

    inline bool hasFilter() const;
    bool hasFilterOutsets() const { return !filterOutsets().isZero(); }
    bool hasAncestorWithFilterOutsets() const;
    IntOutsets filterOutsets() const;
    void clearFilters();

    inline bool hasBackdropFilter() const;

    bool hasBackdropFilterDescendantsWithoutRoot() const { return m_hasBackdropFilterDescendantsWithoutRoot; }
    void setHasBackdropFilterDescendantsWithoutRoot(bool hasBackdropFilterDescendantsWithoutRoot)
    {
        m_hasBackdropFilterDescendantsWithoutRoot = hasBackdropFilterDescendantsWithoutRoot;
    }
    bool canBeBackdropRoot() const { return m_canBeBackdropRoot; }
    bool isBackdropRoot() const { return hasBackdropFilterDescendantsWithoutRoot() && canBeBackdropRoot(); }

#if HAVE(CORE_MATERIAL)
    inline bool hasAppleVisualEffect() const;
    inline bool hasAppleVisualEffectRequiringBackdropFilter() const;
#endif

    inline bool hasBlendMode() const;
    BlendMode blendMode() const { return static_cast<BlendMode>(m_blendMode); }

    bool isolatesCompositedBlending() const { return m_hasNotIsolatedCompositedBlendingDescendants && m_establishesBlendingIsolationGroup; }
    bool hasNotIsolatedCompositedBlendingDescendants() const { return m_hasNotIsolatedCompositedBlendingDescendants; }
    void setHasNotIsolatedCompositedBlendingDescendants(bool hasNotIsolatedCompositedBlendingDescendants)
    {
        m_hasNotIsolatedCompositedBlendingDescendants = hasNotIsolatedCompositedBlendingDescendants;
    }

    bool isolatesBlending() const { return hasNotIsolatedBlendingDescendants() && m_establishesBlendingIsolationGroup; }

    // FIXME: We should ASSERT(!m_hasNotIsolatedBlendingDescendantsStatusDirty); here but we hit the same bugs as visible content above.
    bool hasNotIsolatedBlendingDescendants() const { return m_hasNotIsolatedBlendingDescendants; }
    bool hasNotIsolatedBlendingDescendantsStatusDirty() const { return m_hasNotIsolatedBlendingDescendantsStatusDirty; }

    bool isComposited() const { return m_backing != nullptr; }
    bool hasCompositingDescendant() const { return m_hasCompositingDescendant; }
    NODELETE bool hasCompositedMask() const;
    bool hasCompositedNonContainedDescendants() const { return m_hasCompositedNonContainedDescendants; }

    bool hasDescendantNeedingEventRegionUpdate() const { return m_hasDescendantNeedingEventRegionUpdate; }
    NODELETE void setAncestorsHaveDescendantNeedingEventRegionUpdate();
    void clearHasDescendantNeedingEventRegionUpdate() { m_hasDescendantNeedingEventRegionUpdate = false; }

    // If non-null, a non-ancestor composited layer that this layer paints into (it is sharing its backing store with this layer).
    RenderLayer* backingProviderLayer() const LIFETIME_BOUND_EXCEPT_IN_SWIFT { return weakField(LayerWeakField::BackingProvider); }
    void setBackingProviderLayer(RenderLayer*, OptionSet<UpdateBackingSharingFlags>);
    bool backingProviderLayerIs(const RenderLayer* layer) const { return backingProviderLayer() == layer; }
    void disconnectFromBackingProviderLayer(OptionSet<UpdateBackingSharingFlags>);

    bool paintsIntoProvidedBacking() const { return !!backingProviderLayer(); }

    RenderLayer* backingProviderLayerAtEndOfCompositingUpdate() const LIFETIME_BOUND_EXCEPT_IN_SWIFT { return weakField(LayerWeakField::BackingProviderAtEndOfCompositingUpdate); }
    void setBackingProviderLayerAtEndOfCompositingUpdate(RenderLayer* provider) { setWeakField(LayerWeakField::BackingProviderAtEndOfCompositingUpdate, provider); }
    RenderLayerModelObject* repaintContainer() const { return m_repaintContainer.get(); }

    RenderLayerBacking* backing() const LIFETIME_BOUND_EXCEPT_IN_SWIFT { return m_backing.get(); }
    RenderLayerBacking* ensureBacking() LIFETIME_BOUND;
    void clearBacking(OptionSet<UpdateBackingSharingFlags>, bool layerBeingDestroyed = false);

    bool hasCompositedScrollingAncestor() const { return m_hasCompositedScrollingAncestor; }
    void setHasCompositedScrollingAncestor(bool hasCompositedScrollingAncestor) { m_hasCompositedScrollingAncestor = hasCompositedScrollingAncestor; }

    bool usesCompositedScrolling() const;

    // Layers with the same ScrollingScope are scrolled by some common ancestor scroller. Used for async scrolling.
    std::optional<ScrollingScope> boxScrollingScope() const { return m_boxScrollingScope; }
    std::optional<ScrollingScope> contentsScrollingScope() const { return m_contentsScrollingScope; }

    inline bool paintsWithTransparency(OptionSet<PaintBehavior>) const;

    // If we will only draw a single item, then we can just apply
    // opacity to the drawing context rather than pushing a transparency
    // layer. This currently only detects a single bitmap image, but could
    // be extended to handle other cases.
    inline bool canPaintTransparencyWithSetOpacity() const;

    bool paintsWithTransform(OptionSet<PaintBehavior>) const;
    bool shouldPaintMask(OptionSet<PaintBehavior>, OptionSet<PaintLayerFlag>) const;
    bool shouldApplyClipPath(OptionSet<PaintBehavior>, OptionSet<PaintLayerFlag>) const;

    // Returns true if background phase is painted opaque in the given rect.
    // The query rect is given in local coordinates.
    bool backgroundIsKnownToBeOpaqueInRect(LayoutRect) const;

    bool shouldPaintWithFilters(OptionSet<PaintBehavior> = { }) const;
    bool requiresFullLayerImageForFilters() const;

    NODELETE Element* enclosingElement() const;

    static Vector<RenderLayer*> topLayerRenderLayers(const RenderView&);
    // The top layer's layer after this one, for Swift, which cannot read the vector.
    static RenderLayer* topLayerRenderLayerAfter(const RenderView& renderView, const RenderLayer& layer)
    {
        auto topLayerLayers = topLayerRenderLayers(renderView);
        auto layerIndex = topLayerLayers.find(&layer);
        if (layerIndex != notFound && layerIndex < topLayerLayers.size() - 1)
            return topLayerLayers[layerIndex + 1];
        return nullptr;
    }

    NODELETE bool establishesTopLayer() const;
    SWIFT_UNSAFE void establishesTopLayerWillChange();
    SWIFT_UNSAFE void establishesTopLayerDidChange();

    bool isBitmapOnly() const;

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    bool allowsDynamicContentScaling() const;
#endif

    enum ViewportConstrainedNotCompositedReason {
        NoNotCompositedReason,
        NotCompositedForBoundsOutOfView,
        NotCompositedForNonViewContainer,
        NotCompositedForNoVisibleContent,
    };

    void setViewportConstrainedNotCompositedReason(ViewportConstrainedNotCompositedReason reason) { m_viewportConstrainedNotCompositedReason = reason; }
    ViewportConstrainedNotCompositedReason viewportConstrainedNotCompositedReason() const { return static_cast<ViewportConstrainedNotCompositedReason>(m_viewportConstrainedNotCompositedReason); }

    IndirectCompositingReason indirectCompositingReason() const { return static_cast<IndirectCompositingReason>(m_indirectCompositingReason); }

    bool isRenderFragmentedFlow() const { return renderer().isRenderFragmentedFlow(); }
    bool isInsideFragmentedFlow() const { return renderer().fragmentedFlowState() != RenderObject::FragmentedFlowState::NotInsideFlow; }

    WEBCORE_EXPORT void simulateFrequentPaint();
    bool paintingFrequently() const { return m_paintFrequencyTracker.paintingFrequently(); }
    WEBCORE_EXPORT void purgeFrontBufferForTesting();
    WEBCORE_EXPORT void purgeBackBufferForTesting();
    WEBCORE_EXPORT void markFrontBufferVolatileForTesting();

    NODELETE WEBCORE_EXPORT bool isTransparentRespectingParentFrames() const;

    // Invalidation can fail if there is no enclosing compositing layer (e.g. nested iframe)
    // or the layer does not maintain an event region.
    enum class EventRegionInvalidationReason { Paint, SettingDidChange, Style, NonCompositedFrame };
    bool invalidateEventRegion(EventRegionInvalidationReason);

    String debugDescription() const;

    bool setIsOpportunisticStackingContext(bool);

    void setIsHiddenByOverflowTruncation(bool);

    bool ancestorLayerIsDOMParent(const RenderLayer* ancestor) const;

    struct LayerPaintingInfo {
        SWIFT_UNAVAILABLE_IN_SWIFT __attribute__((swift_attr("@_lifetime(immortal)"))) LayerPaintingInfo(RenderLayer* inRootLayer, const LayoutRect& inDirtyRect, OptionSet<PaintBehavior> inPaintBehavior, const LayoutSize& inSubpixelOffset, RenderObject* inSubtreePaintRoot = nullptr, OverlapTestRequestMap* inOverlapTestRequests = nullptr, bool inRequireSecurityOriginAccessForWidgets = false)
            : paintDirtyRect(inDirtyRect)
            , subpixelOffset(inSubpixelOffset)
            , paintBehavior(inPaintBehavior)
            , requireSecurityOriginAccessForWidgets(inRequireSecurityOriginAccessForWidgets)
            , m_rootLayer(std::bit_cast<uintptr_t>(inRootLayer))
            , m_subtreePaintRoot(std::bit_cast<uintptr_t>(inSubtreePaintRoot))
            , m_overlapTestRequests(std::bit_cast<uintptr_t>(inOverlapTestRequests))
        { }

        // The painting info of a layer painted as its own root within this painting, with no overlap test requests or
        // region context.
        LayerPaintingInfo forRootLayer(RenderLayer* rootLayer, LayoutRect dirtyRect, OptionSet<PaintBehavior> paintBehavior, LayoutSize subpixelOffset) const LIFETIME_BOUND
        {
            return LayerPaintingInfo(rootLayer, dirtyRect, paintBehavior, subpixelOffset);
        }

        OverlapTestRequestMap* overlapTestRequests() const { return std::bit_cast<OverlapTestRequestMap*>(m_overlapTestRequests); } // May be null.
        void applyOverlapTestRequests(NOESCAPE PaintInfo& paintInfo) const { paintInfo.setOverlapTestRequests(overlapTestRequests()); }

        RenderLayer* rootLayer() const { return std::bit_cast<RenderLayer*>(m_rootLayer); }
        void setRootLayer(RenderLayer* layer) { m_rootLayer = std::bit_cast<uintptr_t>(layer); }
        RenderObject* subtreePaintRoot() const { return std::bit_cast<RenderObject*>(m_subtreePaintRoot); } // Only paint descendants of this object.
        RegionContext* regionContext() const { return std::bit_cast<RegionContext*>(m_regionContext); }
        void setRegionContext(RegionContext* context) { m_regionContext = std::bit_cast<uintptr_t>(context); }

        LayoutRect paintDirtyRect; // Relative to rootLayer;
        LayoutSize subpixelOffset;
        OptionSet<PaintBehavior> paintBehavior;
        bool requireSecurityOriginAccessForWidgets { false };

    private:
        // A view of the painting call's root layer, subtree paint root, region context and overlap test requests, held
        // as integers so that the struct is trivially copyable. It must not outlive the painting call that made it, and
        // Swift reaches the objects only through the accessors above, any of which may return null. It has no operator*.
        // setRootLayer() and setRegionContext() store what they are given, which the caller keeps alive.
        uintptr_t m_rootLayer { 0 };
        uintptr_t m_subtreePaintRoot { 0 };
        uintptr_t m_regionContext { 0 };
        uintptr_t m_overlapTestRequests { 0 };
    } SWIFT_VIEW;

public:
    enum class RepaintRectsUpdate : bool { Recompute, Discard };
private:
    void updateRepaintRectsIncludingDescendants(RepaintRectsUpdate);

    void updateAncestorDependentState();

    // SVG-specific methods -- defined in RenderLayerSVGAdditions.cpp.
    NODELETE bool setupClipPathIfNeededForSVG(OptionSet<PaintLayerFlag>&);
    void paintResourceCorrectedChildLayerForSVG(LentGraphicsContext, RenderLayer& childLayer, LayerPaintingInfo, OptionSet<PaintLayerFlag>, LayoutSize correction) const;
    bool viewBoxDisablesPaintingForSVG() const;

    // Each WithClippingAndMasking member applies a non-layer renderer's clip-path and mask, then paints through the member after it.
    void paintNonLayerRendererWithClippingAndMaskingForSVG(NOESCAPE LentGraphicsContext, RenderElement&, LayoutPoint selfPaintOffset, NOESCAPE LayerPaintingInfo, PaintLayerFlags, PaintBehaviors, RenderObject* subtreePaintRoot, StateSavedByCaller);
    void paintNonLayerRendererInTransformScopeForSVG(LentGraphicsContext, RenderElement&, LayoutPoint selfPaintOffset, LayerPaintingInfo, PaintLayerFlags, PaintBehaviors, RenderObject* subtreePaintRoot, StateSavedByCaller, bool paintsIntoMaskLayer);
    void paintNonLayerChildWithClippingAndMaskingForSVG(NOESCAPE LentGraphicsContext, RenderElement&, LayoutPoint paintOffset, LayoutPoint adjustedPaintOffset, NOESCAPE LayerPaintingInfo, PaintLayerFlags, PaintBehaviors, RenderObject* subtreePaintRoot);
    void paintNonLayerChildInTransformScopeForSVG(LentGraphicsContext, RenderElement&, LayoutPoint paintOffset, LayoutPoint adjustedPaintOffset, LayerPaintingInfo, PaintLayerFlags, PaintBehaviors, RenderObject* subtreePaintRoot);
    void paintNonLayerChildInDOMOrderWithClippingAndMaskingForSVG(NOESCAPE LentGraphicsContext, RenderElement&, unsigned itemIndex, OptionalLayoutSize offsetFromRoot, LayoutSize accumulatedAncestorOffset, const LayerFragments&, NOESCAPE LayerPaintingInfo, PaintLayerFlags, PaintBehaviors, RenderObject* subtreePaintRootForRenderer, LayoutPoint containerBaseOffset, bool isSVGRoot, bool sharedClipApplied);
    void paintNonLayerChildInDOMOrderForSVG(LentGraphicsContext, RenderElement&, unsigned itemIndex, LayoutSize accumulatedAncestorOffset, LayerFragments, LayerPaintingInfo, PaintLayerFlags, PaintBehaviors, RenderObject* subtreePaintRootForRenderer, LayoutPoint containerBaseOffset, bool isSVGRoot, bool sharedClipApplied);
    static bool isOverflowHiddenForSVG(const RenderElement&);
    static FloatRect viewportForSVG(const RenderElement& viewportContainer);
    const RenderObject* enclosingHiddenOrResourceContainerRendererForSVG() const;
    bool svgViewportClipExcludesForSVG(const HitTestLocation&) const;
    unsigned childrenInDOMOrderCountForSVG();
    RenderLayer* childLayerInDOMOrderForSVG(unsigned index);
    RenderElement* childRendererInDOMOrderForSVG(unsigned index);
    OptionSet<PaintPhase> childPhasesToPaintInDOMOrderForSVG(unsigned index);
    LayoutSize childAccumulatedAncestorOffsetInDOMOrderForSVG(unsigned index);

    void collectChildrenInDOMOrderForSVG();
    void clearChildrenInDOMOrderForSVG();
    void appendLayeredChildInDOMOrderForSVG(RenderElement&, RenderLayer&, int zIndex);
    void appendAtomicChildInDOMOrderForSVG(RenderElement&, LayoutSize ancestorOffset);
    void appendOutlineOnlyChildInDOMOrderForSVG(RenderElement&, LayoutSize ancestorOffset);
    static bool clipsSubtreeForSVG(const RenderElement&);
    bool isPaintingSVGResourceLayer() const;
    const Vector<SVGPaintOrderLayerItem>& childrenInDOMOrderForSVG();

    void dirtyPaintOrderListsOnChildChange(RenderLayer&);
    void didAddChild(RenderLayer&);
    void willRemoveChild(RenderLayer&);
    void didRemoveChild(RenderLayer&);

    // RenderLayerOwners' LayerWeakField references (RenderLayerOwnership.cpp).
    void setBackingProviderLayerInStore(RenderLayer* provider) { setWeakField(LayerWeakField::BackingProvider, provider); }
    RenderLayer* enclosingPaginationLayerInStore() const { return weakField(LayerWeakField::EnclosingPagination); }
    void setEnclosingPaginationLayerInStore(RenderLayer* layer) { setWeakField(LayerWeakField::EnclosingPagination, layer); }
    LayerRef LEGACY_NODELETE linkStackingContext() const;
    LayerRef linkEnclosingLayerInContainingBlockOrder() const;
    LayerRef LEGACY_NODELETE linkEnclosingOverflowClipLayer(IncludeSelfOrNot) const;
    LayerRef LEGACY_NODELETE linkEnclosingCompositingLayer(IncludeSelfOrNot) const;
    LayerRef linkEnclosingRepaintTargetLayer(IncludeSelfOrNot) const;
    LayerRef linkEnclosingPixelMovingFilterLayer(IncludeSelfOrNot) const;
    LayerRef linkEnclosingFilterRepaintLayer() const;
    LayerRef linkEnclosingPaginationLayerInSubtree(const RenderLayer* rootLayer, PaginationInclusionMode) const;
    LayerRef linkEnclosingAncestorForPosition(PositionType) const;
    LayerRef LEGACY_NODELETE linkEnclosingFrameRenderLayer() const;
    LayerRef linkClippingRootForPainting() const;
    LayerRef linkCommonAncestorWithLayer(const RenderLayer&) const;
    LayerRef linkEnclosingContainingBlockLayer(CrossFrameBoundaries) const;
    void adjustLocationForColumns(const RenderLayer* ancestorLayer, LayoutPoint&) const;
    LayerRef LEGACY_NODELETE linkEnclosingTransformedAncestor() const;

    bool shouldBeNormalFlowOnly() const;
    bool shouldBeCSSStackingContext() const;
    bool shouldBeCSSStackingContextIgnoringZIndex() const;
    // The z-index part of computeEstablishesBlendingIsolationGroup() for the outermost <svg>, which reads Style::Adjuster.
    bool zIndexMakesOutermostSVGAStackingContext() const;
    bool computeCanBeBackdropRoot() const;

    // Return true if changed.
    bool setIsNormalFlowOnly(bool);

    bool setIsCSSStackingContext(bool);

    NODELETE bool setCanBeBackdropRoot(bool);
    void isStackingContextChanged();

    bool isDirtyStackingContext() const { return m_zOrderListsDirty && isStackingContext(); }

    // The paint-order lists' entries are not counted references, so the lists are built in a LayerFreeForbiddenScope.
    inline void updateZOrderLists();
    SWIFT_UNSAFE void updateDirtyZOrderLists();
public:
    // True in a LayerFreeForbiddenScope.
    static bool layerFreeForbidden() { return s_layerFreeForbiddenCount; }
private:
    friend class LayerFreeForbiddenScope;
    SWIFT_UNAVAILABLE_IN_SWIFT WEBCORE_EXPORT static void enterLayerFreeForbiddenScope();
    SWIFT_UNAVAILABLE_IN_SWIFT WEBCORE_EXPORT static void leaveLayerFreeForbiddenScope();
    static unsigned s_layerFreeForbiddenCount;
    void clearZOrderLists();
    void appendViewLayersToPositiveList();
    void detachKeepingChildren();
    size_t paintOrderListSize(PaintOrderList) const;
    RenderLayer& paintOrderListLayerAt(PaintOrderList, size_t) const;
    void didAddChildEventRegion(RenderLayer&);

    inline void updateNormalFlowList();
    SWIFT_UNSAFE void rebuildNormalFlowList();

    LayoutPoint paintOffsetForRenderer(const LayerFragment& fragment, const LayerPaintingInfo& paintingInfo) const
    {
        auto paintOffset = toLayoutPoint(fragment.layerBounds().location() - rendererLocation() + paintingInfo.subpixelOffset);

        if (m_svgData && m_svgData->isPaintingResourceLayer) [[unlikely]]
            paintOffset.moveBy(renderer().nominalSVGLayoutLocation());

        return paintOffset;
    }

    // Compute and return the clip rects. If useCached is true, will used previously computed clip rects on ancestors
    // (rather than computing them all from scratch up the parent chain).
    void calculateClipRects(const RenderLayer* rootLayer, ClipRectsType, ClipRectsOptions, ClipRects&) const;
    ClipRects* cachedClipRects(ClipRectsType, bool respectOverflowClip, const RenderLayer* rootLayer) const;
    void ensureClipRectsCache(ClipRectsType, const RenderLayer* rootLayer);
    void setCachedClipRects(ClipRectsType, bool respectOverflowClip, ClipRects&);
    bool rendererShouldUsePositionedClipping() const;

    void setAncestorChainHasSelfPaintingLayerDescendant();
    NODELETE void dirtyAncestorChainHasSelfPaintingLayerDescendantStatus();

    std::optional<RenderObject::RepaintRects> repaintRects() const
    {
        if (m_repaintRectsValid)
            return m_repaintRects;

        return { };
    }

    void computeRepaintRects(const RenderLayerModelObject* repaintContainer);

    void compositingStatusChanged(LayoutUpToDate);

    NODELETE void setRepaintRects(const RenderObject::RepaintRects&);
    void updateContainerTransformForRepaintRectsForSVG();
    void setRepaintContainer(const RenderLayerModelObject* repaintContainer) { m_repaintContainer = repaintContainer; }
    NODELETE void clearRepaintRects();

    void clipToRect(GraphicsContext& context, GraphicsContextStateSaver& stateSaver, RegionContextStateSaver& regionContextStateSaver, const LayerPaintingInfo& paintingInfo, OptionSet<PaintBehavior> paintBehavior, const ClipRect& clipRect, BorderRadiusClippingRule rule = IncludeSelfForBorderRadius)
    {
        if (clipToRectNeedsSave(paintingInfo, clipRect))
            stateSaver.save();
        if (auto regionClip = clipToRectAfterSave(LentGraphicsContext { context }, paintingInfo, paintBehavior, clipRect, rule))
            regionContextStateSaver.pushClip(*regionClip);
    }
    bool clipToRectNeedsSave(LayerPaintingInfo, ClipRect) const;
    OptionalIntRect clipToRectAfterSave(LentGraphicsContext, LayerPaintingInfo, PaintBehaviors, ClipRect, BorderRadiusClippingRule);
    void applyAncestorClippingForBorderRadius(LentGraphicsContext, LayerPaintingInfo, PaintBehaviors, BorderRadiusClippingRule);
    static void clipToInnerBorderShape(NOESCAPE LentGraphicsContext, const RenderLayer&, LayoutRect clipRect, LayoutRect paintDirtyRect, float deviceScaleFactor);

    bool shouldRepaintAfterLayout() const;

    void updateSelfPaintingLayer();

    void willUpdateLayerPositions();

    enum UpdateLayerPositionsFlag : uint16_t {
        CheckForRepaint                     = 1 << 0,
        NeedsFullRepaintInBacking           = 1 << 1,
        ContainingClippingLayerChangedSize  = 1 << 2,
        UpdatePagination                    = 1 << 3,
        SeenFixedLayer                      = 1 << 4,
        SeenFixedContainingBlockLayer       = 1 << 5,
        SeenTransformedLayer                = 1 << 6,
        Seen3DTransformedLayer              = 1 << 7,
        SeenCompositedScrollingLayer        = 1 << 8,
        SubtreeNeedsUpdate                  = 1 << 9,
        EnvironmentChanged                  = 1 << 10,
        SeenStickyLayer                     = 1 << 11,
    };
    static OptionSet<UpdateLayerPositionsFlag> flagsForUpdateLayerPositions(RenderLayer& startingLayer);

    // UpdateLayerPositionsFlags that describe changes to the layer tree
    static constexpr OptionSet<UpdateLayerPositionsFlag> invalidationLayerPositionsFlags()
    {
        return {
            UpdateLayerPositionsFlag::NeedsFullRepaintInBacking,
            UpdateLayerPositionsFlag::ContainingClippingLayerChangedSize,
            UpdateLayerPositionsFlag::SubtreeNeedsUpdate,
            UpdateLayerPositionsFlag::EnvironmentChanged,
        };
    }


    void repaintAfterLayoutIfNecessary(bool checkForRepaint);
    void verifyRepaintAfterLayout();
    // Whether the layer-position verification runs: LAYER_POSITIONS_ASSERT_ENABLED in RenderLayer.cpp, whose
    // assertLayerPosition() checks that the two agree.
#if ASSERT_ENABLED || ENABLE(CONJECTURE_ASSERT)
    static constexpr bool layerPositionsAssertEnabled() { return true; }
#else
    static constexpr bool layerPositionsAssertEnabled() { return false; }
#endif
    void assertLayerPosition(bool);
    void layoutReflectionAfterPositionUpdate(bool verifyOnly);
    RenderBox* reflectionForSwift() const;
    void updateBackingAfterLayout(bool needsClippingUpdate, bool needsFullRepaint);
    NODELETE bool ancestorLayerPositionStateChanged(OptionSet<UpdateLayerPositionsFlag>);
    NODELETE static ScrollingScope nextScrollingScope();
    // offsetFromContainer() reports its offset through a bool*, which Swift can only pass as an unsafe pointer.
    LayoutPoint locationInInlineBoxContainingBlock(const RenderLayerModelObject& container) const;

    enum UpdateLayerPositionsAfterScrollFlag {
        IsOverflowScroll                        = 1 << 0,
        HasSeenViewportConstrainedAncestor      = 1 << 1,
        HasSeenAncestorWithOverflowClip         = 1 << 2,
        HasChangedAncestor                      = 1 << 3,
        SkipsUnconstrainedSubtrees              = 1 << 4,
    };
public:
    // Public, so that Swift can name the sets in its definitions of the private members.
    using UpdateLayerPositionsFlags = OptionSet<UpdateLayerPositionsFlag>;
    using UpdateLayerPositionsAfterScrollFlags = OptionSet<UpdateLayerPositionsAfterScrollFlag>;
private:

    RenderLayer* enclosingPaginationLayerInSubtree(const RenderLayer* rootLayer, PaginationInclusionMode mode) const { return linkEnclosingPaginationLayerInSubtree(rootLayer, mode); }

    LayoutPoint rendererLocation() const
    {
        if (auto* box = dynamicDowncast<RenderBox>(renderer()))
            return box->location();
        if (auto* svgModelObject = dynamicDowncast<RenderSVGModelObject>(renderer()))
            return svgModelObject->currentSVGLayoutLocation();
        return { };
    }

    LayoutRect rendererBorderBoxRect() const
    {
        if (auto* box = dynamicDowncast<RenderBox>(renderer()))
            return box->borderBoxRect();
        if (auto* svgModelObject = dynamicDowncast<RenderSVGModelObject>(renderer()))
            return svgModelObject->borderBoxRectEquivalent();
        return { };
    }

    LayoutRect rendererVisualOverflowRect() const
    {
        if (auto* box = dynamicDowncast<RenderBox>(renderer()))
            return box->visualOverflowRect();
        if (auto* svgModelObject = dynamicDowncast<RenderSVGModelObject>(renderer()))
            return svgModelObject->visualOverflowRectEquivalent();
        return { };
    }

    LayoutRect rendererOverflowClipRectForPainting(const LayoutPoint& location, OverlayScrollbarSizeRelevancy relevancy) const
    {
        if (auto* box = dynamicDowncast<RenderBox>(renderer()))
            return box->overflowClipRect(location, relevancy);
        if (auto* svgModelObject = dynamicDowncast<RenderSVGModelObject>(renderer()))
            return svgModelObject->overflowClipRectForPainting(location, relevancy);
        return { };
    }

    LayoutRect rendererOverflowClipRectForChildLayers(const LayoutPoint& location, OverlayScrollbarSizeRelevancy relevancy) const
    {
        if (auto* box = dynamicDowncast<RenderBox>(renderer()))
            return box->overflowClipRectForChildLayers(location, relevancy);
        if (auto* svgModelObject = dynamicDowncast<RenderSVGModelObject>(renderer()))
            return svgModelObject->overflowClipRectForChildLayers(location, relevancy);
        return { };
    }

    bool rendererHasVisualOverflow() const
    {
        if (auto* box = dynamicDowncast<RenderBox>(renderer()))
            return box->hasVisualOverflow();
        if (auto* svgModelObject = dynamicDowncast<RenderSVGModelObject>(renderer()))
            return svgModelObject->hasVisualOverflow();
        return false;
    }

    bool setupFontSubpixelQuantization(NOESCAPE LentGraphicsContext, bool& didQuantizeFonts);

    void clearLayerClipPath();

    RenderLayerFilters& ensureLayerFilters();
    void clearLayerFilters();

    void updateLayerScrollableArea();
    void clearLayerScrollableArea();

    bool shouldHaveFiltersForPainting(NOESCAPE LentGraphicsContext, OptionSet<PaintLayerFlag>, OptionSet<PaintBehavior>) const;
    RenderLayerFilters* filtersForPainting(NOESCAPE LentGraphicsContext, OptionSet<PaintLayerFlag>, OptionSet<PaintBehavior>);

    class FilterPaintScope;
    SWIFT_UNAVAILABLE_IN_SWIFT FilterPaintScope setupFilters(LentGraphicsContext destinationContext, LayerPaintingInfo&, OptionSet<PaintLayerFlag>&, LayoutSize offsetFromRoot, ClipRect backgroundRect);
    SWIFT_UNAVAILABLE_IN_SWIFT void applyFilters(LentGraphicsContext, const FilterPaintScope&, const LayerPaintingInfo&, OptionSet<PaintBehavior>, ClipRect backgroundRect);

    void paintLayer(LentGraphicsContext, LayerPaintingInfo, PaintLayerFlags);
    bool paintLayerIntoCanvasDrawableRecorder(NOESCAPE LentGraphicsContext, const LayerPaintingInfo&, PaintLayerFlags);
    void paintLayerWithEffects(LentGraphicsContext, LayerPaintingInfo, PaintLayerFlags);

    void paintLayerContentsAndReflection(LentGraphicsContext, LayerPaintingInfo, PaintLayerFlags);
    void paintLayerContents(LentGraphicsContext, LayerPaintingInfo, PaintLayerFlags, OptionalPaintOrderItemRange svgPaintOrderItemRange);
    // Applies the clip-path, then paints through paintLayerContentsWithinClipPath.
    void paintLayerContentsWithClipPath(NOESCAPE LentGraphicsContext, NOESCAPE LayerPaintingInfo, PaintLayerFlags paintFlags, PaintLayerFlags localPaintFlags, OptionalPaintOrderItemRange svgPaintOrderItemRange, LayoutSize offsetFromRoot,
        LayoutSize columnAwareOffsetFromRoot, bool shouldPaintContent, bool needToAdjustSubpixelQuantization, bool didQuantizeFonts);
    void paintLayerContentsWithinClipPath(LentGraphicsContext, LayerPaintingInfo, PaintLayerFlags paintFlags, PaintLayerFlags localPaintFlags, OptionalPaintOrderItemRange svgPaintOrderItemRange, LayerFragmentsView,
        LayoutSize offsetFromRoot, LayoutSize columnAwareOffsetFromRoot, bool needsMaskClipping, bool shouldPaintContent, bool needToAdjustSubpixelQuantization, bool didQuantizeFonts);
    // Sets up the filters, paints into their context through paintLayerContentsWithinFilters, and applies them. Returns whether the contents paint.
    // Adds PaintBehavior::DontShowVisitedLinks to the paint behavior when the contents paint into the filters.
    bool paintLayerContentsWithFilters(NOESCAPE LentGraphicsContext, NOESCAPE LayerPaintingInfo, PaintLayerFlags localPaintFlags, OptionalPaintOrderItemRange svgPaintOrderItemRange, NOESCAPE LayerFragmentsView,
        PaintBehaviors&, LayoutSize offsetFromRoot, LayoutSize columnAwareOffsetFromRoot, LayoutSize svgFilterOffset, LayoutSize svgFilterCompensation, ClipRect backgroundRect, bool shouldPaintContent, RenderObject* subtreePaintRootForRenderer);
    bool paintLayerContentsWithinFilters(LentGraphicsContext, LentGraphicsContext filterContext, bool hasFilterContext, LayerPaintingInfo, LayerPaintingInfo localPaintingInfo, PaintLayerFlags localPaintFlags, OptionalPaintOrderItemRange svgPaintOrderItemRange,
        LayerFragmentsView, PaintBehaviors, LayoutSize offsetFromRoot, LayoutSize columnAwareOffsetFromRoot, LayoutSize svgFilterOffset, bool shouldPaintContent, RenderObject* subtreePaintRootForRenderer);
    void paintList(PaintOrderList, LentGraphicsContext, LayerPaintingInfo, PaintLayerFlags);
    static unsigned paintOrderItemRangeBegin(OptionalPaintOrderItemRange range) { return range ? range->begin() : 0; }
    static unsigned paintOrderItemRangeEnd(OptionalPaintOrderItemRange range) { return range ? range->end() : 0; }

    void performOverlapTests(const LayerPaintingInfo&) const;
    void paintContentForRenderer(NOESCAPE PaintInfo&, const LayoutPoint& paintOffset);
    bool hitTestContentForRenderer(const HitTestRequest&, HitTestResult&, const HitTestLocation&, const LayoutPoint& accumulatedOffset, HitTestFilter) const;
    // The spatial portal state of the backing, which Swift's hit testing reads. Without ENABLE(SPATIAL_PORTAL), no layer is hosted.
#if ENABLE(SPATIAL_PORTAL)
    bool isHostedInSpatialPortalScene() const;
    std::optional<TransformationMatrix> hostedPortalContentProjection(const RenderLayer& space) const;
#else
    bool isHostedInSpatialPortalScene() const { return false; }
    std::optional<TransformationMatrix> hostedPortalContentProjection(const RenderLayer&) const { return std::nullopt; }
#endif
    bool isCollectingAXCustomColorBackdrops(const LayerPaintingInfo&) const;
    void collectAXCustomColorBackdropsForFragments(const LayerFragments&, NOESCAPE LentGraphicsContext, const LayerPaintingInfo&, OptionSet<PaintBehavior>);
    NODELETE bool blendModeAppliesToSVGRootContentsOnly() const;

    // The transform and clip rects storage, which Swift cannot allocate or free.
    void makeTransform() { m_transform = makeUnique<TransformationMatrix>(); }
    void resetTransform() { m_transform = nullptr; }
    void setTransformMatrix(const TransformationMatrix& transform) { RELEASE_ASSERT(m_transform); *m_transform = transform; }
    TransformationMatrix animatedStyleTransform(TransformResolverOptions) const;
    bool hasClipRectsCache() const { return !!m_clipRectsCache; }
    void resetClipRectsCache();
    void clearCachedClipRects(ClipRectsType);
    // The filters, a type Swift does not import.
    bool hasLayerFilters() const { return !!m_filters; }
    void makeLayerFilters() { ensureLayerFilters(); }
    IntOutsets layerFiltersOutsets() const;
    void expandLayerFiltersDirtySourceRect(LayoutRect);
    void updateLayerFiltersReferenceClients();
    void removeLayerFiltersReferenceClients();
    // The filter of a style, a type Swift does not import.
    bool filterIsIdentity(const Style::ComputedStyle&) const;
    static bool filterIsReferenceFilter(const Style::ComputedStyle&);
    bool filterDiffersFromOldStyle(const Style::ComputedStyle& oldStyle) const;
    bool currentColorChangeRequiresFilterRepaint(const Style::ComputedStyle& oldStyle) const;
    // The inspector, which Swift does not import.
    void didAddOrRemoveScrollbars();

    bool shouldBeSelfPaintingLayer() const;

    bool isScreenCaptureProtectionLayer() const;

    NODELETE void dirtyAncestorChainVisibleDescendantStatus();
    
    bool computeHasVisibleContent() const;
    void updateCompositingForViewportConstrainedLayerWithNoVisibleContent();

    bool has3DTransformedDescendant() const { ASSERT(!m_3DTransformedDescendantStatusDirty); return m_has3DTransformedDescendant; }
    bool has3DTransformedAncestor() const { return m_has3DTransformedAncestor; }

    NODELETE void setAncestorChainHasViewportConstrainedDescendant();
    NODELETE void dirtyAncestorChainHasViewportConstrainedDescendantStatus();

    bool hasFixedAncestor() const { return m_hasFixedAncestor; }
    bool hasPaginatedAncestor() const { return m_hasPaginatedAncestor; }

    NODELETE void dirty3DTransformedDescendantStatus();
    // Both updates the status, and returns true if descendants of this have 3d.
    bool update3DTransformedDescendantStatus();

    bool isInsideSVGForeignObject() const { return m_insideSVGForeignObject; }
    bool isInsideDrawableCanvas() const { return m_insideDrawableCanvas; }

    SWIFT_UNSAFE void createReflection();
    void updateReflectionAfterStyleChange();
    SWIFT_UNSAFE void removeReflection();

    UniqueRef<Style::ComputedStyle> createReflectionStyle();
    bool paintingInsideReflection() const { return m_paintingInsideReflection; }
    void setPaintingInsideReflection(bool b) { m_paintingInsideReflection = b; }

    void updateFilterPaintingStrategy();

    void updateAncestorChainHasBlendingDescendants();
    bool computeEstablishesBlendingIsolationGroup() const;
    void updateEstablishesBlendingIsolationGroup();
    NODELETE void dirtyAncestorChainHasBlendingDescendants();

    NODELETE void updateAncestorChainHasAlwaysIncludedInZOrderListsDescendants();
    NODELETE void dirtyAncestorChainHasAlwaysIncludedInZOrderListsDescendants();

    bool hasAlwaysIncludedInZOrderListsDescendants() const { return m_hasAlwaysIncludedInZOrderListsDescendants; }
    void setIntrinsicallyComposited(bool);
    void updateAlwaysIncludedInZOrderLists();

    ClipRect backgroundClipRect(const ClipRectsContext& context) const { return backgroundClipRect(context.rootLayer, context.clipRectsType, context.options); }
    ClipRect backgroundClipRect(const RenderLayer* rootLayer, ClipRectsType, ClipRectsOptions) const;

    RenderLayer* enclosingTransformedAncestor() const { return linkEnclosingTransformedAncestor(); }

    bool hasNonOpacityTransparency() const;

    void updatePagination();

    void setWasOmittedFromZOrderTree();
    void setWasIncludedInZOrderTree();
    void removeSelfFromCompositor();
    void removeDescendantsFromCompositor();

    NODELETE void verifyClipRects();
    NODELETE void verifyClipRect(const ClipRectsContext&);

    void setHasCompositingDescendant(bool b)  { m_hasCompositingDescendant = b; }
    void setHasCompositedNonContainedDescendants(bool value) { m_hasCompositedNonContainedDescendants = value; }

    void setIndirectCompositingReason(IndirectCompositingReason reason) { m_indirectCompositingReason = static_cast<unsigned>(reason); }
    bool mustCompositeForIndirectReasons() const { return m_indirectCompositingReason; }

    void removeClipperClientIfNeeded() const;

public:
    struct OverflowControlRects {
        IntRect horizontalScrollbar;
        IntRect verticalScrollbar;
        IntRect scrollCorner;
        IntRect resizer;
        IntRect scrollCornerOrResizerRect() const
        {
            return !scrollCorner.isEmpty() ? scrollCorner : resizer;
        }
        IntRect scrollbarRect(ScrollbarOrientation orientation)
        {
            switch (orientation) {
            case ScrollbarOrientation::Horizontal:
                return horizontalScrollbar;
            case ScrollbarOrientation::Vertical:
                return verticalScrollbar;
            }
            return { };
        }
    };
private:
    OverflowControlRects overflowControlsRects() const;

    OptionSet<Compositing> m_compositingDirtyBits;

    std::optional<float> m_savedAlphaForTransparency;

    const bool m_isRenderViewLayer : 1;
    const bool m_forcedStackingContext : 1;

    bool m_isNormalFlowOnly : 1;
    bool m_isCSSStackingContext : 1;
    bool m_canBeBackdropRoot : 1;
    bool m_hasBackdropFilterDescendantsWithoutRoot : 1;
    bool m_isOpportunisticStackingContext : 1;

    bool m_zOrderListsDirty : 1;
    bool m_normalFlowListDirty: 1;
    bool m_hadNegativeZOrderList : 1;

    // Keeps track of whether the layer is currently resizing, so events can cause resizing to start and stop.
    bool m_inResizeMode : 1;

    bool m_isSelfPaintingLayer : 1;

    // If have no self-painting descendants, we don't have to walk our children during painting. This can lead to
    // significant savings, especially if the tree has lots of non-self-painting layers grouped together (e.g. table cells).
    bool m_hasSelfPaintingLayerDescendant : 1;
    bool m_hasSelfPaintingLayerDescendantDirty : 1;

    bool m_hasViewportConstrainedDescendant : 1;
    bool m_hasViewportConstrainedDescendantStatusDirty : 1;

    bool m_usedTransparency : 1; // Tracks whether we need to close a transparent layer, i.e., whether
                                 // we ended up painting this layer or any descendants (and therefore need to
                                 // blend).
    bool m_paintingInsideReflection : 1;  // A state bit tracking if we are painting inside a replica.
    RepaintStatus m_repaintStatus : 2 { RepaintStatus::NeedsNormalRepaint };

    bool m_visibleContentStatusDirty : 1;
    bool m_hasVisibleContent : 1;
    bool m_visibleDescendantStatusDirty : 1;
    bool m_hasVisibleDescendant : 1;
    bool m_isFixedIntersectingViewport : 1;
    bool m_behavesAsFixed : 1;

    bool m_3DTransformedDescendantStatusDirty : 1;
    bool m_has3DTransformedDescendant : 1;  // Set on a stacking context layer that has 3D descendants anywhere
                                            // in a preserves3D hierarchy. Hint to do 3D-aware hit testing.
    bool m_hasCompositingDescendant : 1; // In the z-order tree.
    bool m_hasCompositedNonContainedDescendants : 1; // Set when a layer has a composited descendant in z-order which is not a descendant in containing block order (e.g. opacity layer with an abspos descendant).

    bool m_hasCompositedScrollingAncestor : 1; // In the layer-order tree.

    bool m_hasFixedContainingBlockAncestor : 1;
    bool m_hasTransformedAncestor : 1;
    bool m_has3DTransformedAncestor : 1;

    bool m_hasStickyAncestor : 1 { false };
    bool m_hasFixedAncestor : 1 { false };
    bool m_hasPaginatedAncestor : 1 { false };

    bool m_insideSVGForeignObject : 1;
    bool m_insideDrawableCanvas : 1 { false };
    bool m_isHiddenByOverflowTruncation : 1 { false };

    bool m_hasDescendantNeedingEventRegionUpdate : 1 { false };

    unsigned m_indirectCompositingReason : 4; // IndirectCompositingReason
    unsigned m_viewportConstrainedNotCompositedReason : 2; // ViewportConstrainedNotCompositedReason

    bool m_layerListMutationAllowed : 1;

    unsigned m_blendMode : 5; // BlendMode
    bool m_hasNotIsolatedCompositedBlendingDescendants : 1;
    bool m_hasNotIsolatedBlendingDescendants : 1;
    bool m_hasNotIsolatedBlendingDescendantsStatusDirty : 1;
    bool m_establishesBlendingIsolationGroup : 1 { false };
    bool m_repaintRectsValid : 1 { false };

    bool m_intrinsicallyComposited : 1 { false };
    bool m_alwaysIncludedInZOrderLists : 1 { false };
    bool m_hasAlwaysIncludedInZOrderListsDescendants : 1 { false };
    bool m_hasAlwaysIncludedInZOrderListsDescendantsStatusDirty : 1 { true };

    bool m_wasOmittedFromZOrderTree : 1 { false };
    bool m_suppressAncestorClippingInsideFilter : 1 { false };
    // 0 before RenderLayerOwners claims the layer, 1 while it owns it, 2 once its drop has begun. Written only by
    // RenderLayerFactory.
    SWIFT_UNAVAILABLE_IN_SWIFT unsigned m_swiftOwnerState : 2 { 0 };

    const CheckedRef<RenderLayerModelObject> m_renderer;

    // Written only by RenderLayerLinks and RenderLayerOwners, through RenderLayerFactory.
    SWIFT_UNAVAILABLE_IN_SWIFT RenderLayerTreeLinks m_links;
    SWIFT_UNAVAILABLE_IN_SWIFT uint64_t m_ownerHandle { 0 };
    // The weak references the store keeps for a layer. Each value is also the reference's bit in m_weakFieldsMayBeSet.
    enum class LayerWeakField : uint8_t { BackingProvider = 1 << 0, BackingProviderAtEndOfCompositingUpdate = 1 << 1, EnclosingPagination = 1 << 2 };
    // A clear bit means null, without asking the store.
    SWIFT_UNAVAILABLE_IN_SWIFT RenderLayer* weakField(LayerWeakField field) const
    {
        if (!(m_weakFieldsMayBeSet & std::to_underlying(field))) {
            ASSERT(!weakFieldInStore(field));
            return nullptr;
        }
        return weakFieldInStore(field);
    }
    SWIFT_UNAVAILABLE_IN_SWIFT void setWeakField(LayerWeakField, RenderLayer*);
    // The store's read of a LayerWeakField reference, whatever the bit. weakField() returns null on a clear bit without it;
    // Debug builds call it anyway, and check that the store agrees.
    SWIFT_UNAVAILABLE_IN_SWIFT RenderLayer* weakFieldInStore(LayerWeakField) const;
    // One bit per LayerWeakField reference the store keeps for the layer, written only by setWeakField(): a clear bit
    // means the reference is null, and a set bit means only that the store must be asked.
    SWIFT_UNAVAILABLE_IN_SWIFT uint8_t m_weakFieldsMayBeSet { 0 };
    SWIFT_UNAVAILABLE_IN_SWIFT static uint64_t s_destructionCount;

    SingleThreadWeakPtr<RenderLayerModelObject> m_repaintContainer;

    // For layers that establish stacking contexts, m_posZOrderList holds a sorted list of all the
    // descendant layers within the stacking context that have z-indices of 0 or greater
    // (auto will count as 0). m_negZOrderList holds descendants within our stacking context with negative
    // z-indices.
    std::unique_ptr<Vector<RenderLayer*>> m_posZOrderList;
    std::unique_ptr<Vector<RenderLayer*>> m_negZOrderList;

    // This list contains child layers that cannot create stacking contexts and appear in normal flow order.
    std::unique_ptr<Vector<RenderLayer*>> m_normalFlowList;

    // Only valid if m_repaintRectsValid is set (std::optional<> not used to avoid padding).
    RenderObject::RepaintRects m_repaintRects;

    // Our current relative or absolute position offset.
    LayoutSize m_offsetForPosition;

    // Our (x,y) coordinates are in our parent layer's coordinate space.
    LayoutPoint m_topLeft;

    // The layer's width/height
    IntSize m_layerSize;

    // If the RenderLayer contains an anchor-positioned box, this is the "default scroll shift"
    // for scroll compensation purpose. This offset aligns the anchor-positioned box with the anchor
    // after scroll, and is applied as a transform.
    std::optional<LayoutSize> m_anchorScrollAdjustment;

    std::unique_ptr<ClipRectsCache> m_clipRectsCache;

    Markable<ScrollingScope, IntegralMarkableTraits<ScrollingScope, 0>> m_boxScrollingScope;
    Markable<ScrollingScope, IntegralMarkableTraits<ScrollingScope, 0>> m_contentsScrollingScope;

    std::unique_ptr<TransformationMatrix> m_transform;

    // May ultimately be extended to many replicas (with their own paint order).
    RenderPtr<RenderReplica> m_reflection;

    // Pads the layer so that, with its reference count, it is allocated from the 320-byte size class rather than the
    // 304-byte one. Walks and edits over many layers, such as moving subtrees, measure faster with layers spaced this way.
    [[maybe_unused]] uint64_t m_allocationSizeClassPadding { 0 };

    IntRect m_blockSelectionGapsBounds;

    RefPtr<RenderLayerFilters> m_filters;
    std::unique_ptr<RenderLayerBacking> m_backing;
    std::unique_ptr<RenderLayerScrollableArea> m_scrollableArea;

    struct SVGData {
        WTF_MAKE_STRUCT_TZONE_ALLOCATED(SVGData);
        bool isPaintingResourceLayer { false };
        bool childrenInDOMOrderDirty { true };
        std::optional<TransformationMatrix> containerTransformForRepaintRects;
        SingleThreadWeakPtr<RenderSVGHiddenContainer> enclosingHiddenOrResourceContainer;
        Vector<SVGPaintOrderLayerItem> childrenInDOMOrder;
    };
    const std::unique_ptr<SVGData> m_svgData;

    Paint::FrequencyTracker m_paintFrequencyTracker;

    // Swift retains and releases a layer through its strong count (retainForSwift() and releaseForSwift(), which are
    // private). The layer's owner in RenderLayerOwners holds one of these references, and only its drop ends the layer:
    // if any other Swift reference is still held then, the drop traps, so C++ never frees a layer that Swift holds.
    // A function that returns a layer leaves it with its owner, and Swift retains it.
} SWIFT_SHARED_REFERENCE(.retainForSwift, .releaseForSwift) SWIFT_PRIVATE_FILEID("WebCore/RenderLayerTree.swift") SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT;

// A list of layers that Swift reads or builds: a backing's sharing layers, the compositor's layers with unresolved relations.
class RenderLayerWeakList {
public:
    void append(RenderLayer& layer) { m_layers.append(layer); }
    size_t size() const { return m_layers.size(); }
    RenderLayer* layerAt(size_t index) const { return m_layers[index].get(); }

private:
    friend class RenderLayerBacking;
    Vector<InlineWeakPtr<RenderLayer>> m_layers;
};

// Makes and claims the layers of RenderLayerOwners and reads and writes their links, for RenderLayerOwners and
// RenderLayerLinks, the only code that can call it (RenderLayerOwners.swift).
class RenderLayerFactory {
    RenderLayerFactory() = delete;

    // A new layer, whose one reference the store adopts as the layer's owner.
    static RenderLayer& create(RenderLayerModelObject& renderer) SWIFT_RETURNS_RETAINED { return *WTF::RefCountedWithInlineWeakPtr<RenderLayer>::create<RenderLayer>(renderer); }

    // True the first time it is called on a layer, false every later time.
    static bool claim(RenderLayer& layer)
    {
        if (layer.m_swiftOwnerState)
            return false;
        layer.m_swiftOwnerState = 1;
        return true;
    }

    // The layer's owner state (m_swiftOwnerState); 2 from the start of its drop.
    [[clang::always_inline]] static unsigned ownerState(LayerRef layer) { return static_cast<RenderLayer*>(layer)->m_swiftOwnerState; }
    [[clang::always_inline]] static void setDropping(LayerRef layer) { static_cast<RenderLayer*>(layer)->m_swiftOwnerState = 2; }

    // The store's handle for the layer's owner, written once, when the store makes the layer.
    static void setOwnerHandle(RenderLayer& layer, uint64_t handle) { layer.m_ownerHandle = handle; }

    // One link of a layer, read or written. Each is one load or one store and calls nothing: the layer named stays alive
    // only because the caller holds a reference to it, or read it as a link with nothing called between.
    [[clang::always_inline]] static LayerRef parent(LayerRef layer) { return LayerRef(static_cast<RenderLayer*>(layer)->m_links.m_parent); }
    [[clang::always_inline]] static LayerRef previousSibling(LayerRef layer) { return LayerRef(static_cast<RenderLayer*>(layer)->m_links.m_previous); }
    [[clang::always_inline]] static LayerRef nextSibling(LayerRef layer) { return LayerRef(static_cast<RenderLayer*>(layer)->m_links.m_next); }
    [[clang::always_inline]] static LayerRef firstChild(LayerRef layer) { return LayerRef(static_cast<RenderLayer*>(layer)->m_links.m_first); }
    [[clang::always_inline]] static LayerRef lastChild(LayerRef layer) { return LayerRef(static_cast<RenderLayer*>(layer)->m_links.m_last); }
    [[clang::always_inline]] static void setParent(LayerRef layer, LayerRef link) { static_cast<RenderLayer*>(layer)->m_links.m_parent = link; }
    [[clang::always_inline]] static void setPreviousSibling(LayerRef layer, LayerRef link) { static_cast<RenderLayer*>(layer)->m_links.m_previous = link; }
    [[clang::always_inline]] static void setNextSibling(LayerRef layer, LayerRef link) { static_cast<RenderLayer*>(layer)->m_links.m_next = link; }
    [[clang::always_inline]] static void setFirstChild(LayerRef layer, LayerRef link) { static_cast<RenderLayer*>(layer)->m_links.m_first = link; }
    [[clang::always_inline]] static void setLastChild(LayerRef layer, LayerRef link) { static_cast<RenderLayer*>(layer)->m_links.m_last = link; }

    // The number of layers whose destruction has begun.
    static uint64_t destructionCount() { return RenderLayer::s_destructionCount; }
} SWIFT_PRIVATE_FILEID("WebCore/RenderLayerOwners.swift");

// The steps of the walks over layers named by LayerRef, so that a walk takes no count per step: only
// RenderLayerAncestorWalks.swift can call them. Each reads or writes only the named layer's own members and calls nothing.
// A LayerRef passed in names a layer reached through its links from a layer the caller holds a reference to, with nothing
// called between: every non-null link names a live layer (the drop of a layer unlinks it before it frees it), and only a
// drop frees one. A test returns false for the null LayerRef, which ends the walk.
class RenderLayerAncestorWalker {
    RenderLayerAncestorWalker() = delete;

    static LayerRef parent(LayerRef layer) { return LayerRef(static_cast<RenderLayer*>(layer)->parent()); }
    // Adds the bit, and returns whether the layer lacked it.
    static bool addDescendantNeedsPositionUpdate(LayerRef layer) { return layer && static_cast<RenderLayer*>(layer)->addLayerPositionDirtyBit(RenderLayer::LayerPositionUpdates::DescendantNeedsPositionUpdate); }
    static void addNeedsPositionUpdate(LayerRef layer) { static_cast<RenderLayer*>(layer)->addLayerPositionDirtyBit(RenderLayer::LayerPositionUpdates::NeedsPositionUpdate); }
    // Sets the dirty bit, and returns whether the layer lacked it.
    static bool dirtyHasSelfPaintingLayerDescendantStatus(LayerRef layer) { auto* current = static_cast<RenderLayer*>(layer); return current && !current->m_hasSelfPaintingLayerDescendantDirty && (current->m_hasSelfPaintingLayerDescendantDirty = true); }
    static bool dirtyVisibleDescendantStatus(LayerRef layer) { auto* current = static_cast<RenderLayer*>(layer); return current && !current->m_visibleDescendantStatusDirty && (current->m_visibleDescendantStatusDirty = true); }
    static bool isNonStackingContext(LayerRef layer) { return layer && !static_cast<RenderLayer*>(layer)->isStackingContext(); }
    static bool hasChildren(LayerRef layer) { return layer && static_cast<RenderLayer*>(layer)->lastChild(); }
    static bool isNormalFlowOnly(LayerRef layer) { return layer && static_cast<RenderLayer*>(layer)->isNormalFlowOnly(); }
    // The layer a LayerRef names, which Swift retains.
    static RenderLayer* layer(LayerRef layer) { return layer; }
} SWIFT_PRIVATE_FILEID("WebCore/RenderLayerAncestorWalks.swift");

// The writers of the paint-order lists, which only RenderLayerPaintOrderLists.swift can call. reset() checks that the list
// may be changed and, for a non-zero capacity, that no layer can be freed; append() writes only within that capacity.
class RenderLayerPaintOrderListWriter {
    RenderLayerPaintOrderListWriter() = delete;

    // Empties the list and reserves the capacity. A list without a buffer gets one only for a non-zero capacity.
    [[clang::always_inline]] static void reset(RenderLayer& layer, PaintOrderList which, size_t capacity, bool shrinkToFit)
    {
        auto& list = listToWrite(layer, which);
        RELEASE_ASSERT(!capacity || RenderLayer::layerFreeForbidden());
        if (!list && capacity)
            list = makeUnique<Vector<RenderLayer*>>();
        if (!list)
            return;
        list->clear();
        if (shrinkToFit)
            list->shrinkToFit();
        list->reserveCapacity(capacity);
    }
    // Appends to a list within the capacity that reset() reserved, which checked the list mutation and the scope.
    [[clang::always_inline]] static void append(RenderLayer& layer, PaintOrderList which, LayerRef entry)
    {
        ASSERT(RenderLayer::layerFreeForbidden() && layer.layerListMutationAllowed());
        auto* list = (which == PaintOrderList::Positive ? layer.m_posZOrderList : which == PaintOrderList::Negative ? layer.m_negZOrderList : layer.m_normalFlowList).get();
        RELEASE_ASSERT(list && list->size() < list->capacity());
        list->append(static_cast<RenderLayer*>(entry));
    }
    static void release(RenderLayer& layer, PaintOrderList which) { listToWrite(layer, which) = nullptr; }
    static LayerRef firstChild(LayerRef layer) { return LayerRef(static_cast<RenderLayer*>(layer)->firstChild()); }
    static LayerRef nextSibling(LayerRef layer) { return LayerRef(static_cast<RenderLayer*>(layer)->nextSibling()); }
    static bool isNormalFlowOnly(LayerRef layer) { return static_cast<RenderLayer*>(layer)->isNormalFlowOnly(); }

    // What only the paint-order list rebuilds read and set.
    static bool isAlwaysIncludedInZOrderLists(const RenderLayer& layer) { return layer.m_alwaysIncludedInZOrderLists || layer.m_hasAlwaysIncludedInZOrderListsDescendants; }
    static uint16_t compositingDirtyBits(const RenderLayer& layer) { return layer.m_compositingDirtyBits.toRaw(); }
    static bool wasOmittedFromZOrderTree(LayerRef layer) { return static_cast<RenderLayer*>(layer)->m_wasOmittedFromZOrderTree; }
    static void setWasIncludedInZOrderTree(LayerRef layer) { static_cast<RenderLayer*>(layer)->setWasIncludedInZOrderTree(); }
    static void setWasOmittedFromZOrderTree(RenderLayer& layer) { layer.setWasOmittedFromZOrderTree(); }

    SWIFT_UNAVAILABLE_IN_SWIFT static std::unique_ptr<Vector<RenderLayer*>>& listToWrite(RenderLayer& layer, PaintOrderList which)
    {
        RELEASE_ASSERT(layer.layerListMutationAllowed());
        return which == PaintOrderList::Positive ? layer.m_posZOrderList : which == PaintOrderList::Negative ? layer.m_negZOrderList : layer.m_normalFlowList;
    }
} SWIFT_PRIVATE_FILEID("WebCore/RenderLayerPaintOrderLists.swift");

// No layer may end while one is alive: the code in its scope holds layers by plain pointers and references.
class LayerFreeForbiddenScope {
    WTF_MAKE_NONCOPYABLE(LayerFreeForbiddenScope);
public:
    LayerFreeForbiddenScope() { RenderLayer::enterLayerFreeForbiddenScope(); }
    ~LayerFreeForbiddenScope() { RenderLayer::leaveLayerFreeForbiddenScope(); }
};

inline RenderLayer* RenderLayerTreeLinks::nextSibling() const { return m_next && m_next->m_swiftOwnerState != 2 ? m_next : nullptr; }
inline RenderLayer* RenderLayerTreeLinks::firstChild() const { return m_first && m_first->m_swiftOwnerState != 2 ? m_first : nullptr; }

inline void RenderLayer::updateZOrderLists()
{
    if (!m_zOrderListsDirty)
        return;
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    updateDirtyZOrderLists();
}

inline void RenderLayer::updateNormalFlowList()
{
    if (!m_normalFlowListDirty)
        return;
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    rebuildNormalFlowList();
}

inline RenderLayer* RenderLayer::paintOrderParent() const
{
    return m_isNormalFlowOnly ? parent() : stackingContext();
}

inline void RenderLayer::setIsHiddenByOverflowTruncation(bool isHidden)
{
    if (m_isHiddenByOverflowTruncation == isHidden)
        return;
    m_isHiddenByOverflowTruncation = isHidden;
    dirtyVisibleContentStatus();
}

class SWIFT_UNSAFE LayerListMutationDetector {
public:
    LayerListMutationDetector(RenderLayer& layer)
        : m_layer(layer)
        , m_previousMutationAllowedState(layer.layerListMutationAllowed())
    {
        m_layer.setLayerListMutationAllowed(false);
    }
    
    ~LayerListMutationDetector()
    {
        m_layer.setLayerListMutationAllowed(m_previousMutationAllowedState);
    }

private:
    RenderLayer& m_layer;
    bool m_previousMutationAllowedState;
};

NODELETE void makeMatrixRenderable(TransformationMatrix&, bool has3DRendering);

NODELETE bool compositedWithOwnBackingStore(const RenderLayer&);

// Walks of the layer links with the reads inlined, for the tree benchmark. Each returns a digest of what it visited.
WEBCORE_EXPORT uint64_t renderLayerPreorderWalkForTesting(const RenderLayer& root);
WEBCORE_EXPORT uint64_t renderLayerAncestorWalkForTesting(std::span<const RenderLayer* const>);
// Queries for the layer's enclosing layers (stacking context, overflow clip layer, common ancestor), folded into a digest.
WEBCORE_EXPORT uint64_t renderLayerEnclosingWalkForTesting(std::span<RenderLayer* const>);
// Weak references to the layer of an element, kept in a table until released; notFound if the element has no layer.
// The table is not synchronized, so Swift may call these only with unsafe.
WEBCORE_EXPORT SWIFT_UNSAFE size_t renderLayerWeakReferenceAcquireForTesting(const Element&);
WEBCORE_EXPORT SWIFT_UNSAFE bool renderLayerWeakReferenceIsNullForTesting(size_t);
WEBCORE_EXPORT SWIFT_UNSAFE void renderLayerWeakReferenceReleaseForTesting(size_t);
// Destroys the layer of the element's renderer and makes it again, as a style change does, without resolving style. False if the element has no layer.
// It ends a layer, so Swift may call it only with unsafe.
WEBCORE_EXPORT SWIFT_UNSAFE bool renderLayerRecreateForTesting(const Element&);

WTF::TextStream& operator<<(WTF::TextStream&, ClipRectsType);
WTF::TextStream& operator<<(WTF::TextStream&, const RenderLayer&);
WTF::TextStream& operator<<(WTF::TextStream&, const RenderLayer::ClipRectsContext&);
WTF::TextStream& operator<<(WTF::TextStream&, RenderLayer::ClipRectsOption);
WTF::TextStream& operator<<(WTF::TextStream&, IndirectCompositingReason);
WTF::TextStream& operator<<(WTF::TextStream&, PaintBehavior);
WTF::TextStream& operator<<(WTF::TextStream&, RenderLayer::PaintLayerFlag);

} // namespace WebCore

#if ENABLE(TREE_DEBUGGING)
// Outside the WebCore namespace for ease of invocation from lldb.
void showLayerTree(const WebCore::RenderLayer*);
void showLayerTree(const WebCore::RenderObject*);
void showPaintOrderTree(const WebCore::RenderLayer*);
void showPaintOrderTree(const WebCore::RenderObject*);
void showLayerPositionTree(const WebCore::RenderLayer* root, const WebCore::RenderLayer* mark = nullptr);
#endif
