// Copyright (C) 2011-2025 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

internal import WebCore_Private.Core.DocumentClasses
internal import WebCore_Private.Core.GraphicsLayer
internal import WebCore_Private.Core.LocalFrame
internal import WebCore_Private.Core.LocalFrameView
internal import WebCore_Private.Core.Page
internal import WebCore_Private.Core.ScrollingCoordinator
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingNodeID
internal import wtf

extension WebCore.ScrollingCoordinator {
    // The node's layers, as the coordinator takes them; a layer not given is null.
    func setNodeLayers(
        _ nodeID: WebCore.ScrollingNodeID,
        layer: WebCore.GraphicsLayer? = nil,
        scrollContainerLayer: WebCore.GraphicsLayer? = nil,
        scrolledContentsLayer: WebCore.GraphicsLayer? = nil,
        counterScrollingLayer: WebCore.GraphicsLayer? = nil,
        insetClipLayer: WebCore.GraphicsLayer? = nil,
        rootContentsLayer: WebCore.GraphicsLayer? = nil,
        horizontalScrollbarLayer: WebCore.GraphicsLayer? = nil,
        verticalScrollbarLayer: WebCore.GraphicsLayer? = nil,
        viewportAnchorLayer: WebCore.GraphicsLayer? = nil
    ) {
        var nodeLayers = WebCore.ScrollingCoordinator.NodeLayers()
        nodeLayers.layer = .init(layer)
        nodeLayers.scrollContainerLayer = .init(scrollContainerLayer)
        nodeLayers.scrolledContentsLayer = .init(scrolledContentsLayer)
        nodeLayers.counterScrollingLayer = .init(counterScrollingLayer)
        nodeLayers.insetClipLayer = .init(insetClipLayer)
        nodeLayers.rootContentsLayer = .init(rootContentsLayer)
        nodeLayers.horizontalScrollbarLayer = .init(horizontalScrollbarLayer)
        nodeLayers.verticalScrollbarLayer = .init(verticalScrollbarLayer)
        nodeLayers.viewportAnchorLayer = .init(viewportAnchorLayer)
        setNodeLayers(nodeID, nodeLayers)
    }

    // The base's protected members, for AsyncScrollingCoordinator.
    var scrollingPage: WebCore.Page? { page() }

    func scrollContainerLayer(for frameView: WebCore.LocalFrameView) -> WebCore.GraphicsLayer? {
        scrollContainerLayerForFrameView(frameView)
    }

    func scrolledContentsLayer(for frameView: WebCore.LocalFrameView) -> WebCore.GraphicsLayer? {
        scrolledContentsLayerForFrameView(frameView)
    }

    @cxx
    @implementation
    public func pageDestroyed() {
        assert(m_page.get() != nil)
        m_page.clear()
    }

    @cxx
    @implementation
    func frameViewFixedObjectsDidChange(_ frameView: WebCore.LocalFrameView) {
        assert(WTF.isMainThread())
        assert(m_page.get() != nil)

        if !coordinatesScrollingForFrameView(frameView) {
            return
        }

        updateSynchronousScrollingReasons(frameView)
    }

    @cxx
    @implementation
    func updateSynchronousScrollingReasons(_ frameView: WebCore.LocalFrameView) {
        assert(coordinatesScrollingForFrameView(frameView))

        var newSynchronousScrollingReasons = WebCore.SynchronousScrollingReasons()

        // RenderLayerCompositor::updateSynchronousScrollingReasons maintains this bit, so maintain its current value.
        if synchronousScrollingReasons(frameView.scrollingNodeID()).contains(.HasSlowRepaintObjects) {
            newSynchronousScrollingReasons.add(.init(.HasSlowRepaintObjects))
        }

        if m_forceSynchronousScrollLayerPositionUpdates {
            newSynchronousScrollingReasons.add(.init(.ForcedOnMainThread))
        }

        if hasVisibleSlowRepaintViewportConstrainedObjects(frameView) {
            newSynchronousScrollingReasons.add(.init(.HasNonLayerViewportConstrainedObjects))
        }

        if let page = frameView.frame().page(), page.topDocumentHasDocumentClass(.Image) {
            newSynchronousScrollingReasons.add(.init(.IsImageDocument))
        }

        setSynchronousScrollingReasons(frameView.scrollingNodeID(), newSynchronousScrollingReasons)
    }

    @cxx
    @implementation
    public func setForceSynchronousScrollLayerPositionUpdates(_ forceSynchronousScrollLayerPositionUpdates: Bool) {
        if m_forceSynchronousScrollLayerPositionUpdates == forceSynchronousScrollLayerPositionUpdates {
            return
        }

        m_forceSynchronousScrollLayerPositionUpdates = forceSynchronousScrollLayerPositionUpdates
        updateSynchronousScrollingReasonsForAllFrames()
    }

    @cxx
    @implementation
    public func uniqueScrollingNodeID() -> WebCore.ScrollingNodeID {
        WebCore.ScrollingNodeID.generate()
    }
}
