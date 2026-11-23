/*
 * Copyright (C) 2012-2015 Apple Inc. All rights reserved.
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
#include "ScrollingTree.h"

#if ENABLE(ASYNC_SCROLLING)

#include "AnimationFrameRate.h"
#include "EventNames.h"
#include "Logging.h"
#include "PlatformWheelEvent.h"
#include "RubberbandingState.h"
#include "ScrollingEffectsController.h"
#include "ScrollingStateFrameScrollingNode.h"
#include "ScrollingStateTree.h"
#include "ScrollingTreeFrameHostingNode.h"
#include "ScrollingTreeFrameScrollingNode.h"
#include "ScrollingTreeNode.h"
#include "ScrollingTreeOverflowScrollProxyNode.h"
#include "ScrollingTreeOverflowScrollingNode.h"
#include "ScrollingTreePositionedNode.h"
#include "ScrollingTreeScrollingNode.h"
#include <wtf/Scope.h>
#include <wtf/SetForScope.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>
#include "WebCore-Swift.h"

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollingTree);

ScrollingTree::ScrollingTree()
{
}

ScrollingTree::~ScrollingTree() = default;

bool ScrollingTree::isUserScrollInProgressAtEventLocation(const PlatformWheelEvent& wheelEvent)
{
    RefPtr rootNode = m_rootNode;
    if (!rootNode)
        return false;

    // This method is invoked by the event handling thread
    Locker locker { m_treeStateLock };

    if (m_treeState.nodesWithActiveUserScrolls.isEmpty())
        return false;

    auto position = rootNode->viewToContentsPoint(wheelEvent.position(), m_treeState.mainFrameScrollPosition);
    if (auto node = scrollingNodeForPoint(position))
        return m_treeState.nodesWithActiveUserScrolls.contains(node->scrollingNodeID());

    return false;
}

OptionSet<WheelEventProcessingSteps> ScrollingTree::computeWheelProcessingSteps(const PlatformWheelEvent& wheelEvent)
{
    RefPtr rootNode = m_rootNode;
    if (!rootNode)
        return { WheelEventProcessingSteps::AsyncScrolling };

    auto position = rootNode->viewToContentsPoint(wheelEvent.position(), m_treeState.mainFrameScrollPosition);

    if (!m_treeState.eventTrackingRegions.isEmpty()) {
        IntPoint roundedPosition = roundedIntPoint(position);

        // Event regions are affected by page scale, so no need to map through scale.
        bool isSynchronousDispatchRegion = m_treeState.eventTrackingRegions.trackingTypeForPoint(EventTrackingRegions::EventType::Wheel, roundedPosition) == TrackingType::Synchronous
            || m_treeState.eventTrackingRegions.trackingTypeForPoint(EventTrackingRegions::EventType::Mousewheel, roundedPosition) == TrackingType::Synchronous;
        LOG_WITH_STREAM(Scrolling, stream << "\nScrollingTree::computeWheelProcessingSteps: wheelEvent " << wheelEvent << " mapped to content point " << position << ", in non-fast region " << isSynchronousDispatchRegion);

        if (isSynchronousDispatchRegion)
            return { WheelEventProcessingSteps::SynchronousScrolling, WheelEventProcessingSteps::BlockingDOMEventDispatch };
    }

#if ENABLE(WHEEL_EVENT_REGIONS)
    auto eventListenerTypes = eventListenerRegionTypesForPoint(position);
    if (eventListenerTypes.contains(EventListenerRegionType::NonPassiveWheel)) {
        if (m_treeState.gestureState.value_or(WheelScrollGestureState::Blocking) == WheelScrollGestureState::NonBlocking) {
            LOG_WITH_STREAM(Scrolling, stream << "ScrollingTree::computeWheelProcessingSteps: wheelEvent - gesture state made event non-blocking");
            return { WheelEventProcessingSteps::AsyncScrolling, WheelEventProcessingSteps::NonBlockingDOMEventDispatch };
        }

        return { WheelEventProcessingSteps::SynchronousScrolling, WheelEventProcessingSteps::BlockingDOMEventDispatch };
    }

    if (eventListenerTypes.contains(EventListenerRegionType::Wheel))
        return { WheelEventProcessingSteps::AsyncScrolling, WheelEventProcessingSteps::NonBlockingDOMEventDispatch };
#endif
    return { WheelEventProcessingSteps::AsyncScrolling };
}

OptionSet<WheelEventProcessingSteps> ScrollingTree::determineWheelEventProcessing(const PlatformWheelEvent& wheelEvent)
{
    // This method is invoked by the event handling thread
    Locker locker { m_treeStateLock };

    auto& wheelState = m_latchingController.wheelState();
    ScrollingNodeID latchedNodeID { WTF::HashTableDeletedValue };
    uint8_t latchedProcessingSteps = 0;
    bool latchedToUnscrollableRoot = false;
    if (wheelState.latchingDataForEvent(wheelEvent.useLatchedEventElement(), wheelEvent.isGestureStart(), m_allowLatching, latchedNodeID, latchedProcessingSteps, latchedToUnscrollableRoot)) {
        auto processingSteps = OptionSet<WheelEventProcessingSteps>::fromRaw(latchedProcessingSteps);
        LOG_WITH_STREAM(ScrollLatching, stream << "\nScrollingTree::determineWheelEventProcessing " << wheelEvent << " have latched node " << latchedNodeID << " steps " << processingSteps << " gesture state " << m_treeState.gestureState);
        return processingSteps;
    }
    if (wheelEvent.isGestureStart() || wheelEvent.isNonGestureEvent())
        m_treeState.gestureState = std::nullopt;

    auto processingSteps = computeWheelProcessingSteps(wheelEvent);

    wheelState.receivedWheelEvent(wheelEvent.isGestureStart(), processingSteps.toRaw(), m_allowLatching);

    LOG_WITH_STREAM(Scrolling, stream << "\nScrollingTree::determineWheelEventProcessing: " << wheelEvent << " processingSteps " << processingSteps);

    return processingSteps;
}

WheelEventHandlingResult ScrollingTree::handleWheelEvent(const PlatformWheelEvent& wheelEvent, OptionSet<WheelEventProcessingSteps> processingSteps)
{
    LOG_WITH_STREAM(Scrolling, stream << "ScrollingTree " << this << " handleWheelEvent " << wheelEvent);

    Ref protectedThis { *this };
    Locker locker { m_treeLock };

    if (isMonitoringWheelEvents())
        receivedWheelEventWithPhases(wheelEvent.phase(), wheelEvent.momentumPhase());

    // Scroll updates sent to the main thread carry only a position, so mark wheel scrolls as
    // delta scrolls here.
    m_isApplyingDeltaScroll = true;
    auto clearApplyingDeltaScroll = WTF::makeScopeExit([&] {
        m_isApplyingDeltaScroll = false;
    });

    // The hit test runs here: in the UI process the caller holds the layer hit-test lock.
    WheelEventHandlingResult result;
    {
        ScrollingTreeLockedAccess locked { *this, ScrollingTreeAccessMode::Event };
        auto& wheelState = m_latchingController.wheelState();
        bool needsHitTest = false;
        result = wheelState.handleWheelEvent(locked, wheelEvent, processingSteps.toRaw(), m_allowLatching, !!m_rootNode, asyncFrameOrOverflowScrollingEnabled(), needsHitTest);
        if (needsHitTest) {
            RefPtr rootNode = m_rootNode;
            FloatPoint position;
            {
                Locker locker { m_treeStateLock };
                position = rootNode->viewToContentsPoint(wheelEvent.position(), m_treeState.mainFrameScrollPosition);
            }
            RefPtr node = scrollingNodeForPoint(position);
            if (node)
                result = wheelState.handleWheelEventWithNode(locked, wheelEvent, processingSteps.toRaw(), m_allowLatching, node.get(), dynamicDowncast<ScrollingTreeScrollingNode>(*node), EventTargeting::Propagate);
#if PLATFORM(MAC)
            wheelState.latchToUnscrollableRootIfNeeded(locked, wheelEvent, result, processingSteps.toRaw(), m_allowLatching, node == rootNode);
#endif
        }
    }

    static constexpr OptionSet<WheelEventProcessingSteps> mainThreadSteps = { WheelEventProcessingSteps::NonBlockingDOMEventDispatch, WheelEventProcessingSteps::BlockingDOMEventDispatch };
    result.steps.add(processingSteps & mainThreadSteps);
    return result;
}

WheelEventHandlingResult ScrollingTree::handleWheelEventWithNode(const PlatformWheelEvent& wheelEvent, OptionSet<WheelEventProcessingSteps> processingSteps, ScrollingTreeNode* startingNode, EventTargeting eventTargeting)
{
    // The callers hold the tree's lock and a Ref to the tree taken before it.
    assertIsHeld(m_treeLock);
    if (!startingNode)
        return WheelEventHandlingResult::unhandled();
    ScrollingTreeLockedAccess locked { *this, ScrollingTreeAccessMode::Event };
    return m_latchingController.wheelState().handleWheelEventWithNode(locked, wheelEvent, processingSteps.toRaw(), m_allowLatching, startingNode, dynamicDowncast<ScrollingTreeScrollingNode>(*startingNode), eventTargeting);
}

#if PLATFORM(MAC)
void ScrollingTree::stopSpringAnimationsForWheelEvent(const PlatformWheelEvent& wheelEvent)
{
    // Spring animations last long enough that the user may want to take over before they finish, by touching the trackpad
    // or by scrolling. A nested scroller may handle the event, so stop the springs of all the scrollers that enclose it too.
    if (!wheelEvent.isGestureStart() && !wheelEvent.isNonGestureEvent())
        return;

    // Avoid hit testing when nothing is animating.
    if (!hasNodeWithActiveScrollAnimations())
        return;

    Ref protectedThis { *this };
    Locker locker { m_treeLock };

    RefPtr rootNode = m_rootNode;
    if (!rootNode)
        return;

    FloatPoint position;
    {
        Locker locker { m_treeStateLock };
        position = rootNode->viewToContentsPoint(wheelEvent.position(), m_treeState.mainFrameScrollPosition);
    }

    RefPtr node = scrollingNodeForPoint(position);
    if (node) {
        ScrollingTreeLockedAccess locked { *this, ScrollingTreeAccessMode::Event };
        m_latchingController.wheelState().stopSpringAnimations(locked, node.get());
    }
}
#endif

RefPtr<ScrollingTreeNode> ScrollingTree::scrollingNodeForPoint(FloatPoint)
{
    ASSERT(asyncFrameOrOverflowScrollingEnabled());
    return m_rootNode;
}

#if ENABLE(WHEEL_EVENT_REGIONS)
OptionSet<EventListenerRegionType> ScrollingTree::eventListenerRegionTypesForPoint(FloatPoint) const
{
    return { };
}
#endif

void ScrollingTree::traverseScrollingTree(NOESCAPE const VisitorFunction& visitorFunction)
{
    Locker locker { m_treeLock };
    RefPtr rootNode = m_rootNode;
    if (!rootNode)
        return;
    traverseScrollingTreeRecursive(*rootNode, visitorFunction);
}

void ScrollingTree::traverseScrollingTreeRecursive(ScrollingTreeNode& node, NOESCAPE const VisitorFunction& visitorFunction)
{
    bool scrolledSinceLastCommit = false;
    std::optional<FloatPoint> scrollPosition;
    if (auto* scrollingNode = dynamicDowncast<ScrollingTreeScrollingNode>(node)) {
        scrollPosition = scrollingNode->currentScrollPosition();
        scrolledSinceLastCommit = scrollingNode->scrolledSinceLastCommit();
    }

    std::optional<FloatPoint> layoutViewportOrigin;
    if (auto* frameScrollingNode = dynamicDowncast<ScrollingTreeFrameScrollingNode>(node))
        layoutViewportOrigin = frameScrollingNode->layoutViewport().location();

    visitorFunction(node.scrollingNodeID(), node.nodeType(), scrollPosition, layoutViewportOrigin, scrolledSinceLastCommit);

    for (auto& child : node.children())
        traverseScrollingTreeRecursive(child.get(), visitorFunction);
}

void ScrollingTree::scrollingTreeNodeDidScroll(ScrollingTreeScrollingNode& node, ScrollingLayerPositionAction)
{
    setNeedsApplyLayerPositions();
    if (node.isRootNode())
        setMainFrameScrollPosition(node.currentScrollPosition());
}

void ScrollingTree::mainFrameViewportChangedViaDelegatedScrolling(const FloatPoint& scrollPosition, const FloatRect& layoutViewport, double scale)
{
    LOG_WITH_STREAM(Scrolling, stream << "ScrollingTree::mainFrameViewportChangedViaDelegatedScrolling - layoutViewport " << layoutViewport << " scale " << scale);

    // repositionScrollingLayers() requires the tree lock, and the scrolling thread may be reading the tree.
    Ref protectedThis { *this };
    Locker locker { m_treeLock };

    ScrollingTreeLockedAccess locked { *this, ScrollingTreeAccessMode::Event };
    scrollingTreeMainFrameViewportChangedViaDelegatedScrolling(locked, scrollPosition, layoutViewport, scale);
}

void ScrollingTree::setOverlayScrollbarsEnabled(bool enabled)
{
    if (enabled == m_overlayScrollbarsEnabled)
        return;
    m_overlayScrollbarsEnabled = enabled;
}

void ScrollingTree::removeNode(ScrollingNodeID nodeID, ScrollingTreeFrameHostingNode* hostingNode)
{
    m_latchingController.wheelState().nodeWasRemoved(nodeID);
    if (auto node = m_nodeMap.take(nodeID)) {
        {
            Locker locker { m_frameIDMapLock };
            auto nodeList = m_nodeMapPerFrame.find(node->frameIdentifier());
            if (nodeList != m_nodeMapPerFrame.end())
                nodeList->value.remove(nodeID);
        }
        removeFromActiveNodes(*node);
        if (hostingNode)
            hostingNode->removeHostedChild(*node);
        node->willBeDestroyed();
    }
}

void ScrollingTree::removeFromActiveNodes(ScrollingTreeNode& node)
{
    // The active node sets hold refs, so a node removed from m_nodeMap would otherwise stay in
    // them and remain unresolvable via nodeForID() for the rest of the tree's lifetime.
    if (RefPtr positionedNode = dynamicDowncast<ScrollingTreePositionedNode>(node))
        m_activePositionedNodes.remove(*positionedNode);
    else if (RefPtr scrollProxyNode = dynamicDowncast<ScrollingTreeOverflowScrollProxyNode>(node))
        m_activeOverflowScrollProxyNodes.remove(*scrollProxyNode);

    // Active nodes can also reference the node going away, and those references resolve
    // by ID, so drop the referrers rather than leave them pointing at nothing.
    if (!node.isOverflowScrollingNode())
        return;

    auto removedNodeID = node.scrollingNodeID();

    m_activeOverflowScrollProxyNodes.removeIf([removedNodeID](auto& scrollProxyNode) {
        return scrollProxyNode->overflowScrollingNodeID() == removedNodeID;
    });

    m_activePositionedNodes.removeIf([removedNodeID](auto& positionedNode) {
        return positionedNode->relatedOverflowScrollingNodes().contains(removedNodeID);
    });
}

void ScrollingTree::removeFrameHostingNode(LayerHostingContextIdentifier hostingIdentifier)
{
    m_hostedSubtrees.remove(hostingIdentifier);
}

void ScrollingTree::captureMainFrameRubberbandingState(bool rootStateNodeChanged)
{
#if HAVE(RUBBER_BANDING)
    if (RefPtr rootNode = m_rootNode; rootNode && rootStateNodeChanged) {
        if (auto state = rootNode->captureRubberbandingState()) {
            LOG_WITH_STREAM(ScrollAnimations, stream << "ScrollingTree::commitTreeStateInternal - captured rubberbanding state: initialOverscroll");
            setPendingMainFrameRubberbandingState(WTF::move(state));
        } else
            setPendingMainFrameRubberbandingState(std::nullopt);
    }
#else
    UNUSED_PARAM(rootStateNodeChanged);
#endif
}

void ScrollingTree::updateTreeStateFromRootStateNode(const ScrollingStateTree* scrollingStateTree, bool rootStateNodeChanged)
{
    auto rootNode = scrollingStateTree->rootStateNode();
    Locker locker { m_treeStateLock };

    if (rootStateNodeChanged || rootNode->hasChangedProperty(ScrollingStateNode::Property::ScrolledContentsLayer))
        m_treeState.mainFrameScrollPosition = { };

    if (rootStateNodeChanged || rootNode->hasChangedProperty(ScrollingStateNode::Property::EventTrackingRegion))
        m_treeState.eventTrackingRegions = scrollingStateTree->rootStateNode()->eventTrackingRegions();

    if (rootStateNodeChanged || rootNode->hasChangedProperty(ScrollingStateNode::Property::AsyncFrameOrOverflowScrollingEnabled))
        m_asyncFrameOrOverflowScrollingEnabled = scrollingStateTree->rootStateNode()->asyncFrameOrOverflowScrollingEnabled();

    if (rootStateNodeChanged || rootNode->hasChangedProperty(ScrollingStateNode::Property::WheelEventGesturesBecomeNonBlocking))
        m_wheelEventGesturesBecomeNonBlocking = scrollingStateTree->rootStateNode()->wheelEventGesturesBecomeNonBlocking();

    if (rootStateNodeChanged || rootNode->hasChangedProperty(ScrollingStateNode::Property::ScrollingPerformanceTestingEnabled))
        m_scrollingPerformanceTestingEnabled = scrollingStateTree->rootStateNode()->scrollingPerformanceTestingEnabled();

    if (rootStateNodeChanged || rootNode->hasChangedProperty(ScrollingStateNode::Property::IsMonitoringWheelEvents))
        m_isMonitoringWheelEvents = scrollingStateTree->rootStateNode()->isMonitoringWheelEvents();

    if (rootStateNodeChanged || rootNode->hasChangedProperty(ScrollingStateNode::Property::OverlayScrollbarsEnabled))
        setOverlayScrollbarsEnabled(scrollingStateTree->rootStateNode()->overlayScrollbarsEnabled());
}

bool ScrollingTree::commitTreeState(std::unique_ptr<ScrollingStateTree>&& scrollingStateTree, std::optional<LayerHostingContextIdentifier> hostingContextIdentifier)
{
    SetForScope inCommitTreeState(m_inCommitTreeState, true);
    Ref protectedThis { *this };
    Locker locker { m_treeLock };
    ScrollingTreeLockedAccess locked { *this, ScrollingTreeAccessMode::Commit };
    return locked.commitStateTree(WTF::move(scrollingStateTree), hostingContextIdentifier);
}

RefPtr<ScrollingTreeFrameScrollingNode> ScrollingTree::hostedRootNodeForFrame(FrameIdentifier frameID) const
{
    for (auto& frameHostingNode : m_hostedSubtrees.values()) {
        for (auto& child : frameHostingNode->children()) {
            RefPtr hostedRootNode { dynamicDowncast<ScrollingTreeFrameScrollingNode>(child) };
            if (hostedRootNode && hostedRootNode->frameIdentifier() == frameID)
                return hostedRootNode;
        }
    }
    return nullptr;
}

void ScrollingTree::removeAllNodes()
{
    auto nodes = std::exchange(m_nodeMap, { });

    // Every node is going away, so no entry in the active sets can still be resolved via nodeForID().
    m_activePositionedNodes.clear();
    m_activeOverflowScrollProxyNodes.clear();

    for (auto iter : nodes)
        Ref { iter.value }->willBeDestroyed();

    m_nodeMap.clear();
    {
        Locker locker { m_frameIDMapLock };
        m_nodeMapPerFrame.clear();
    }
}

void ScrollingTree::applyLayerPositions()
{
    Locker locker { m_treeLock };

    if (!m_needsApplyLayerPositions.exchange(false))
        return;

    applyLayerPositionsInternal();
}

void ScrollingTree::applyLayerPositionsInternal()
{
    ASSERT_WITH_SECURITY_IMPLICATION(m_treeLock.isLocked());
    if (RefPtr rootNode = m_rootNode)
        applyLayerPositionsRecursive(*rootNode);
}

void ScrollingTree::applyLayerPositionsRecursive(ScrollingTreeNode& node)
{
    node.applyLayerPositions();

    for (auto& child : node.children())
        applyLayerPositionsRecursive(child.get());
}

void ScrollingTree::notifyRelatedNodesAfterScrollPositionChange(ScrollingTreeScrollingNode& changedNode)
{
    Vector<ScrollingNodeID> additionalUpdateRoots;
    
    if (is<ScrollingTreeOverflowScrollingNode>(changedNode))
        additionalUpdateRoots = overflowRelatedNodes().get(changedNode.scrollingNodeID());

    notifyRelatedNodesRecursive(changedNode);
    
    for (auto positionedNodeID : additionalUpdateRoots) {
        if (RefPtr positionedNode = nodeForID(positionedNodeID))
            notifyRelatedNodesRecursive(*positionedNode);
    }
}

void ScrollingTree::notifyRelatedNodesRecursive(ScrollingTreeNode& node)
{
    node.applyLayerPositions();

    for (auto& child : node.children()) {
        // Never need to cross frame boundaries, since scroll layer adjustments are isolated to each document.
        if (is<ScrollingTreeFrameScrollingNode>(child))
            continue;

        notifyRelatedNodesRecursive(child.get());
    }
}

std::optional<ScrollingNodeID> ScrollingTree::latchedNodeID() const
{
    ScrollingNodeID nodeID { WTF::HashTableDeletedValue };
    uint8_t processingSteps = 0;
    if (!m_latchingController.wheelState().latchedNodeAndSteps(nodeID, processingSteps))
        return std::nullopt;
    return nodeID;
}

bool ScrollingTree::isLatchedToUnscrollableRoot() const
{
    return m_latchingController.wheelState().isLatchedToUnscrollableRoot();
}

void ScrollingTree::clearLatchedNode()
{
    m_latchingController.wheelState().clearLatchedNode();
}

FloatBoxExtent ScrollingTree::mainFrameObscuredContentInsets() const
{
    Locker locker { m_treeStateLock };
    if (auto* rootNode = m_rootNode.get())
        return rootNode->obscuredContentInsets();
    return { };
}

FloatPoint ScrollingTree::mainFrameScrollPosition() const
{
    Locker locker { m_treeStateLock };
    return m_rootNode ? m_rootNode->currentScrollPosition() : FloatPoint { };
}

#if ENABLE(COORDINATED_TOUCH_EVENTS)
std::optional<FloatSize> ScrollingTree::mainFrameScrollOffset() const
{
    RefPtr rootNode = m_rootNode;
    if (!rootNode)
        return { };
    Locker locker { m_treeStateLock };
    return rootNode->viewToContentsOffset(m_treeState.mainFrameScrollPosition);
}
#endif

WebCore::RectEdges<bool> ScrollingTree::pinnedStateIncludingAncestorsAtPoint(FloatPoint viewPoint)
{
    RefPtr rootNode = m_rootNode;
    if (!rootNode)
        return false;

    FloatPoint position;
    {
        Locker locker { m_treeStateLock };
        position = rootNode->viewToContentsPoint(viewPoint, m_treeState.mainFrameScrollPosition);
    }

    HitTestLocker hitTestLocker { *this };

    WebCore::RectEdges<bool> pinnedState = { true, true, true, true };

    RefPtr node = scrollingNodeForPoint(position);
    while (node) {
        if (RefPtr scrollingNode = dynamicDowncast<ScrollingTreeScrollingNode>(*node))
            pinnedState &= scrollingNode->edgePinnedState();

        if (RefPtr scrollProxyNode = dynamicDowncast<ScrollingTreeOverflowScrollProxyNode>(*node)) {
            if (RefPtr relatedNode = nodeForID(scrollProxyNode->overflowScrollingNodeID())) {
                node = WTF::move(relatedNode);
                continue;
            }
        }

        node = node->parent();
    }

    return pinnedState;
}

void ScrollingTree::setRubberBandingInProgressForNode(ScrollingNodeID nodeID, bool isRubberBanding)
{
    Locker locker { m_treeStateLock };
    if (isRubberBanding)
        m_treeState.nodesWithActiveRubberBanding.add(nodeID);
    else
        m_treeState.nodesWithActiveRubberBanding.remove(nodeID);
}

#if HAVE(RUBBER_BANDING)
void ScrollingTree::setPendingMainFrameRubberbandingState(std::optional<RubberbandingState>&& state)
{
    m_pendingMainFrameRubberbandingState = WTF::move(state);
}

std::optional<RubberbandingState> ScrollingTree::takePendingMainFrameRubberbandingState()
{
    return std::exchange(m_pendingMainFrameRubberbandingState, std::nullopt);
}
#endif

void ScrollingTree::clearNodesWithUserScrollInProgress()
{
    Locker locker { m_treeStateLock };
    m_treeState.nodesWithActiveUserScrolls.clear();
}

HashSet<ScrollingNodeID> ScrollingTree::nodesWithActiveScrollAnimations()
{
    Locker locker { m_treeStateLock };
    return m_treeState.nodesWithActiveScrollAnimations;
}

void ScrollingTree::serviceScrollAnimations(MonotonicTime currentTime)
{
    for (auto nodeID : nodesWithActiveScrollAnimations()) {
        RefPtr targetNode = dynamicDowncast<ScrollingTreeScrollingNode>(nodeForID(nodeID));
        if (!targetNode)
            continue;
        targetNode->serviceScrollAnimation(currentTime);
    }
}

RubberBandingBehavior ScrollingTree::clientAllowsMainFrameRubberBandingOnSide(BoxSide side)
{
    Locker locker { m_swipeStateLock };
    return m_swipeState.clientAllowedRubberBandableEdges.at(side);
}

void ScrollingTree::addPendingScrollUpdateInternal(ScrollUpdate update)
{
    Locker locker { m_pendingScrollUpdatesLock };
    for (auto& existingUpdate : m_pendingScrollUpdates) {
        if (existingUpdate.canMerge(update)) {
            existingUpdate.merge(WTF::move(update));
            return;
        }
    }

    m_pendingScrollUpdates.append(WTF::move(update));
}

void ScrollingTree::addPendingScrollUpdate(ScrollUpdate update)
{
    addPendingScrollUpdateInternal(WTF::move(update));
    didAddPendingScrollUpdate();
}

Vector<ScrollUpdate> ScrollingTree::takePendingScrollUpdates()
{
    Locker locker { m_pendingScrollUpdatesLock };
    return std::exchange(m_pendingScrollUpdates, { });
}

bool ScrollingTree::hasPendingScrollUpdates()
{
    Locker locker { m_pendingScrollUpdatesLock };
    return m_pendingScrollUpdates.size();
}

bool ScrollingTree::willWheelEventStartSwipeGesture(const PlatformWheelEvent& wheelEvent)
{
    if (wheelEvent.phase() != PlatformWheelEventPhase::Began)
        return false;

    Locker locker { m_swipeStateLock };

    if (wheelEvent.deltaX() > 0 && m_swipeState.mainFramePinnedState.left() && m_swipeState.clientAllowedRubberBandableEdges.left() == RubberBandingBehavior::Never)
        return true;
    if (wheelEvent.deltaX() < 0 && m_swipeState.mainFramePinnedState.right() && m_swipeState.clientAllowedRubberBandableEdges.right() == RubberBandingBehavior::Never)
        return true;
    if (wheelEvent.deltaY() > 0 && m_swipeState.mainFramePinnedState.top() && m_swipeState.clientAllowedRubberBandableEdges.top() == RubberBandingBehavior::Never)
        return true;
    if (wheelEvent.deltaY() < 0 && m_swipeState.mainFramePinnedState.bottom() && m_swipeState.clientAllowedRubberBandableEdges.bottom() == RubberBandingBehavior::Never)
        return true;

    return false;
}

bool ScrollingTree::hasRecentActivity()
{
    return hasProcessedWheelEventsRecently() || hasNodeWithActiveScrollAnimations();
}

bool ScrollingTree::overlayScrollbarsEnabled()
{
    Locker locker { m_treeStateLock };
    return m_overlayScrollbarsEnabled;
}

Seconds ScrollingTree::frameDuration()
{
    auto displayFPS = nominalFramesPerSecond().value_or(FullSpeedFramesPerSecond);
    return 1_s / (double)displayFPS;
}

Seconds ScrollingTree::maxAllowableRenderingUpdateDurationForSynchronization()
{
    constexpr double allowableFrameFraction = 0.5;
    return allowableFrameFraction * frameDuration();
}

void ScrollingTree::addScrollingNodeToHostedSubtreeMap(LayerHostingContextIdentifier identifier, Ref<ScrollingTreeFrameHostingNode> node)
{
    m_hostedSubtrees.set(identifier, node);
}

std::optional<FrameIdentifier> ScrollingTree::frameIDForScrollingNodeID(ScrollingNodeID scrollingNodeID)
{
    Locker locker { m_frameIDMapLock };

    for (auto& pair : m_nodeMapPerFrame) {
        if (pair.value.contains(scrollingNodeID))
            return pair.key;
    }
    return std::nullopt;
}

String ScrollingTree::scrollingTreeAsText(OptionSet<ScrollingStateTreeAsTextBehavior> behavior)
{
    TextStream ts(TextStream::LineMode::MultipleLine);

    {
        TextStream::GroupScope scope(ts);
        ts << "scrolling tree"_s;

        Locker locker { m_treeStateLock };

        if (auto latchedNodeID = this->latchedNodeID())
            ts.dumpProperty("latched node"_s, latchedNodeID.value());

        if (!m_treeState.mainFrameScrollPosition.isZero())
            ts.dumpProperty("main frame scroll position"_s, m_treeState.mainFrameScrollPosition);
        
        if (RefPtr rootNode = m_rootNode) {
            TextStream::GroupScope scope(ts);
            rootNode->dump(ts, behavior | ScrollingStateTreeAsTextBehavior::IncludeLayerPositions);
        }
        
        if (behavior & ScrollingStateTreeAsTextBehavior::IncludeNodeIDs) {
            if (!m_overflowRelatedNodesMap.isEmpty()) {
                TextStream::GroupScope scope(ts);
                ts << "overflow related nodes"_s;
                {
                    TextStream::IndentScope indentScope(ts);
                    for (auto& it : m_overflowRelatedNodesMap)
                        ts << '\n' << indent << it.key << " -> "_s << it.value;
                }
            }

            if (!m_activeOverflowScrollProxyNodes.isEmpty()) {
                TextStream::GroupScope scope(ts);
                ts << "overflow scroll proxy nodes"_s;
                {
                    TextStream::IndentScope indentScope(ts);
                    for (auto& node : m_activeOverflowScrollProxyNodes)
                        ts << '\n' << indent << node->scrollingNodeID();
                }
            }

            if (!m_activePositionedNodes.isEmpty()) {
                TextStream::GroupScope scope(ts);
                ts << "active positioned nodes"_s;
                {
                    TextStream::IndentScope indentScope(ts);
                    for (const auto& node : m_activePositionedNodes)
                        ts << '\n' << indent << node->scrollingNodeID();
                }
            }
        }
    }
    return ts.release();
}

float ScrollingTree::rubberbandHyperbolicCoefficientForTesting()
{
    RefPtr rootNode = m_rootNode;
    return rootNode ? rootNode->rubberbandHyperbolicCoefficientForTesting() : 0;
}

bool ScrollingTree::hasFixedOrSticky() const
{
    return !m_fixedOrStickyNodes.computeIsEmpty();
}

void ScrollingTree::fixedOrStickyNodeAdded(ScrollingTreeNode& node)
{
    m_fixedOrStickyNodes.add(node);
}

// Swift relocates a noncopyable class with a trivial destructor bitwise, so the destructor is user-provided.
static_assert(!std::is_trivially_destructible_v<ScrollingTreeLockedAccess>);
static_assert(!std::is_copy_constructible_v<ScrollingTreeLockedAccess>);
static_assert(!std::is_copy_assignable_v<ScrollingTreeLockedAccess>);
static_assert(!std::is_move_assignable_v<ScrollingTreeLockedAccess>);
static_assert(!std::is_default_constructible_v<ScrollingTreeLockedAccess>);

ScrollingTreeLockedAccess::ScrollingTreeLockedAccess(ScrollingTree& tree, ScrollingTreeAccessMode mode)
    : m_tree(tree)
    , m_mode(mode)
{
    RELEASE_ASSERT(!tree.m_hasLockedAccess);
    tree.m_hasLockedAccess = true;
}

ScrollingTreeLockedAccess::ScrollingTreeLockedAccess(ScrollingTree& tree)
    : m_tree(tree)
    , m_mode(ScrollingTreeAccessMode::Event)
    , m_holdsTreeLock(true)
{
    tree.m_treeLock.lock();
    RELEASE_ASSERT(!tree.m_hasLockedAccess);
    tree.m_hasLockedAccess = true;
}

ScrollingTreeLockedAccess::ScrollingTreeLockedAccess(ScrollingTreeLockedAccess&& other)
    : m_tree(other.m_tree)
    , m_mode(other.m_mode)
{
    RELEASE_ASSERT_NOT_REACHED();
}

ScrollingTreeLockedAccess::~ScrollingTreeLockedAccess()
{
    auto& tree = this->tree();
    assertIsHeld(tree.m_treeLock);
    tree.m_hasLockedAccess = false;
    if (m_holdsTreeLock)
        tree.m_treeLock.unlock();
}

void ScrollingTreeLockedAccess::checkNode(const ScrollingTreeNode& node) const
{
    // m_tree keeps the tree's weak pointer control block alive, so no node of another tree, live or dead, refers to it.
    // m_scrollingTree is const, so it is read without its lock; the caller's reference keeps node alive.
    static_assert(std::is_const_v<decltype(ScrollingTreeNode::m_scrollingTree)>);
    RELEASE_ASSERT(node.m_scrollingTree.refersToControlBlockWithoutLocking(tree().controlBlock()));
}

void ScrollingTreeLockedAccess::checkCommit() const
{
    // The tree's structure is written only by the commit, on its thread, so readers there need no lock; a change
    // from any other entry, on another thread, would race with them.
    RELEASE_ASSERT(m_mode == ScrollingTreeAccessMode::Commit);
}

RefPtr<ScrollingTreeFrameScrollingNode> ScrollingTreeLockedAccess::rootNode() const
{
    return tree().rootNode();
}

void ScrollingTreeLockedAccess::removeNode(ScrollingNodeID nodeID) const
{
    checkCommit();
    tree().removeNode(nodeID);
}

void ScrollingTreeLockedAccess::removeNode(ScrollingNodeID nodeID, ScrollingTreeFrameHostingNode& hostingNode) const
{
    checkCommit();
    checkNode(hostingNode);
    tree().removeNode(nodeID, &hostingNode);
}

bool ScrollingTreeLockedAccess::commitStateBeforeChildren(ScrollingTreeNode& node, const ScrollingStateNode& stateNode) const
{
    checkCommit();
    checkNode(node);
    return node.commitStateBeforeChildren(stateNode);
}

bool ScrollingTreeLockedAccess::commitStateAfterChildren(ScrollingTreeNode& node, const ScrollingStateNode& stateNode) const
{
    checkCommit();
    checkNode(node);
    return node.commitStateAfterChildren(stateNode);
}

void ScrollingTreeLockedAccess::didCompleteCommitForNode(ScrollingTreeNode& node) const
{
    checkCommit();
    checkNode(node);
    node.didCompleteCommitForNode();
}

void ScrollingTreeLockedAccess::willBeDestroyed(ScrollingTreeNode& node) const
{
    checkCommit();
    checkNode(node);
    node.willBeDestroyed();
}

RefPtr<ScrollingTreeNode> ScrollingTreeLockedAccess::parent(ScrollingTreeNode& node) const
{
    checkNode(node);
    return node.parent();
}

void ScrollingTreeLockedAccess::setParent(ScrollingTreeNode& node, ScrollingTreeNode* parent) const
{
    checkCommit();
    checkNode(node);
    if (parent)
        checkNode(*parent);
    node.setParent(parent);
}

void ScrollingTreeLockedAccess::appendChild(ScrollingTreeNode& parent, ScrollingTreeNode& child) const
{
    checkCommit();
    checkNode(parent);
    checkNode(child);
    parent.appendChild(Ref { child });
}

void ScrollingTreeLockedAccess::removeChild(ScrollingTreeNode& parent, ScrollingTreeNode& child) const
{
    checkCommit();
    checkNode(parent);
    checkNode(child);
    parent.removeChild(child);
}

void ScrollingTreeLockedAccess::removeAllChildren(ScrollingTreeNode& node) const
{
    checkCommit();
    checkNode(node);
    node.removeAllChildren();
}

void ScrollingTreeLockedAccess::setRootNode(ScrollingTreeFrameScrollingNode* node) const
{
    checkCommit();
    if (node)
        checkNode(*node);
    tree().m_rootNode = node;
}

void ScrollingTreeLockedAccess::removeAllNodes() const
{
    checkCommit();
    auto& tree = this->tree();
    assertIsHeld(tree.m_treeLock);
    tree.removeAllNodes();
}

void ScrollingTreeLockedAccess::addNode(ScrollingTreeNode& node, FrameIdentifier frameID) const
{
    checkCommit();
    checkNode(node);
    auto& tree = this->tree();
    tree.m_nodeMap.set(node.scrollingNodeID(), node);
    {
        Locker locker { tree.m_frameIDMapLock };
        tree.m_nodeMapPerFrame.ensure(frameID, [] { return HashSet<ScrollingNodeID> { }; }).iterator->value.add(node.scrollingNodeID());
    }
    node.setFrameIdentifier(frameID);
}

WheelEventHandlingResult ScrollingTreeLockedAccess::handleWheelEvent(ScrollingTreeScrollingNode& node, const PlatformWheelEvent& wheelEvent, EventTargeting eventTargeting) const
{
    checkNode(node);
    return node.handleWheelEvent(wheelEvent, eventTargeting);
}

void ScrollingTreeLockedAccess::stopSpringAnimation(ScrollingTreeScrollingNode& node) const
{
    checkNode(node);
    node.stopSpringAnimation();
}

void ScrollingTreeLockedAccess::serviceScrollAnimation(ScrollingTreeScrollingNode& node, MonotonicTime currentTime) const
{
    checkNode(node);
    node.serviceScrollAnimation(currentTime);
}

void ScrollingTreeLockedAccess::scrollTo(ScrollingTreeScrollingNode& node, const FloatPoint& position, ScrollType scrollType, ScrollClamping clamping) const
{
    checkNode(node);
    node.scrollTo(position, scrollType, clamping);
}

void ScrollingTreeLockedAccess::scrollBy(ScrollingTreeScrollingNode& node, const FloatSize& offset, ScrollClamping clamping) const
{
    checkNode(node);
    node.scrollBy(offset, clamping);
}

void ScrollingTreeLockedAccess::handleWheelEventPhase(ScrollingNodeID nodeID, PlatformWheelEventPhase phase) const
{
    tree().handleWheelEventPhase(nodeID, phase);
}

bool ScrollingTreeLockedAccess::commitStateTree(std::unique_ptr<ScrollingStateTree>&& scrollingStateTree, std::optional<LayerHostingContextIdentifier> hostingContextIdentifier) const
{
    checkCommit();
    auto& tree = this->tree();
    LOG(ScrollingTree, "\nScrollingTree %p commitTreeState", &tree);
    switch (commitScrollingTreeState(*this, &tree, scrollingStateTree.get(), hostingContextIdentifier)) {
    case ScrollingTreeCommitResult::Failed:
        return false;
    case ScrollingTreeCommitResult::Committed:
        return true;
    case ScrollingTreeCommitResult::NeedsHostingNode:
        // Add to hosted subtrees needing pairing since the hosting node is not in the scrolling tree yet
        tree.m_hostedSubtreesNeedingPairing.ensure(*hostingContextIdentifier, [] {
            return Vector<std::unique_ptr<ScrollingStateTree>> { };
        }).iterator->value.append(WTF::move(scrollingStateTree));
        return true;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

bool ScrollingTreeLockedAccess::commitHostedSubtreesNeedingPairing(LayerHostingContextIdentifier hostingID) const
{
    checkCommit();
    auto subtrees = tree().m_hostedSubtreesNeedingPairing.take(hostingID);
    if (subtrees.isEmpty())
        return true;
    LOG_WITH_STREAM(Scrolling, stream << "ScrollingTree::commitTreeState - committing unparented subtrees for hosting context ID: " << hostingID);
    bool succeeded = true;
    for (auto& subtree : subtrees)
        succeeded &= commitStateTree(WTF::move(subtree), hostingID);
    return succeeded;
}

void ScrollingTreeLockedAccess::discardHostedSubtreesNeedingPairing(LayerHostingContextIdentifier hostingID) const
{
    checkCommit();
    tree().m_hostedSubtreesNeedingPairing.remove(hostingID);
}

RefPtr<ScrollingTreeFrameHostingNode> ScrollingTreeLockedAccess::hostingNodeForHostedSubtree(LayerHostingContextIdentifier hostingID) const
{
    return tree().m_hostedSubtrees.get(hostingID);
}

void ScrollingTreeLockedAccess::addHostedChild(ScrollingTreeFrameHostingNode& hostingNode, ScrollingTreeNode& node) const
{
    checkCommit();
    checkNode(hostingNode);
    checkNode(node);
    hostingNode.addHostedChild(node);
}

void ScrollingTreeLockedAccess::removeHostedChildren(ScrollingTreeFrameHostingNode& hostingNode) const
{
    checkCommit();
    checkNode(hostingNode);
    hostingNode.removeHostedChildren();
}

void ScrollingTreeLockedAccess::captureMainFrameRubberbandingState(bool rootStateNodeChanged) const
{
    checkCommit();
    auto& tree = this->tree();
    assertIsHeld(tree.m_treeLock);
    tree.captureMainFrameRubberbandingState(rootStateNodeChanged);
}

void ScrollingTreeLockedAccess::updateTreeStateFromRootStateNode(const ScrollingStateTree& scrollingStateTree, bool rootStateNodeChanged) const
{
    checkCommit();
    tree().updateTreeStateFromRootStateNode(&scrollingStateTree, rootStateNodeChanged);
}

void ScrollingTreeLockedAccess::removeActiveNodesForFrame(FrameIdentifier frameID) const
{
    checkCommit();
    auto& tree = this->tree();
    tree.m_overflowRelatedNodesMap.removeIf([&tree, frameID](auto& keyAndValue) {
        if (auto* scrollingNode = tree.m_nodeMap.get(keyAndValue.key))
            return scrollingNode->frameIdentifier() == frameID;
        return false;
    });

    tree.m_activeOverflowScrollProxyNodes.removeIf([frameID](auto& scrollingNode) {
        return scrollingNode->frameIdentifier() == frameID;
    });

    tree.m_activePositionedNodes.removeIf([frameID](auto& scrollingNode) {
        return scrollingNode->frameIdentifier() == frameID;
    });
}

Vector<ScrollingNodeID> ScrollingTreeLockedAccess::nodeIDsForFrame(FrameIdentifier frameID) const
{
    auto& tree = this->tree();
    Locker locker { tree.m_frameIDMapLock };
    return copyToVector(tree.m_nodeMapPerFrame.get(frameID));
}

void ScrollingTreeLockedAccess::propagateSynchronousScrollingReasons(std::optional<ScrollingNodeID> anySynchronousScrollingNode) const
{
    checkCommit();
    auto& tree = this->tree();
    assertIsHeld(tree.m_treeLock);
    HashSet<ScrollingNodeID> synchronousScrollingNodes;
    if (anySynchronousScrollingNode)
        synchronousScrollingNodes.add(*anySynchronousScrollingNode);
    tree.propagateSynchronousScrollingReasons(synchronousScrollingNodes);
}

bool ScrollingTreeLockedAccess::propagatesSynchronousScrollingReasonsToAncestors() const
{
    return tree().isThreadedScrollingTree();
}

void ScrollingTreeLockedAccess::didCommitTree() const
{
    checkCommit();
    auto& tree = this->tree();
    assertIsHeld(tree.m_treeLock);
    tree.didCommitTree();
}

} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING)
