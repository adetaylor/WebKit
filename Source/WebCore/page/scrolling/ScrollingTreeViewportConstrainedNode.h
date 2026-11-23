/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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

#if ENABLE(ASYNC_SCROLLING)

#include <WebCore/ScrollingConstraints.h>
#include <WebCore/ScrollingPlatformLayer.h>
#include <WebCore/ScrollingTreeNode.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class ViewportConstraints;

// Its Swift members are with the fixed node's, their one caller.
class SWIFT_PRIVATE_FILEID("WebCore/ScrollingTreeFixedNode.swift") ScrollingTreeViewportConstrainedNode : public ScrollingTreeNode {
    WTF_MAKE_TZONE_ALLOCATED(ScrollingTreeViewportConstrainedNode);
protected:
    ScrollingTreeViewportConstrainedNode(ScrollingTree&, ScrollingNodeType, ScrollingNodeID);

    virtual ~ScrollingTreeViewportConstrainedNode();
    virtual const ViewportConstraints& constraints() const LIFETIME_BOUND = 0;
    virtual ScrollingPlatformLayer* layer() const = 0;

    SWIFT_UNSAFE FloatPoint computeLayerPosition() const;
    // For Swift, which does not import constraints(), a reference to an abstract class.
    FloatPoint viewportRelativeLayerPosition(const FloatRect& viewportRect) const { return constraints().viewportRelativeLayerPosition(viewportRect); }
    FloatPoint layerPositionAtLastLayout() const { return constraints().layerPositionAtLastLayout(); }
};

} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING)
