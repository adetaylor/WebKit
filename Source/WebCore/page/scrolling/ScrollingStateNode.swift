// Copyright (C) 2012 Apple Inc. All rights reserved.
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

#if ENABLE_ASYNC_SCROLLING

internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingStateNode
internal import wtf

// A stream that writes what the caller's stream would: dumpProperties is only called with multiple-line streams.
func makeScrollingDumpStream(
    _ indent: Int32,
    _ formattingFlags: WebCore.TextStreamFormattingFlags,
    _ containerSizeLimit: UInt32
) -> WTF.TextStream {
    var ts = WTF.TextStream(.MultipleLine, formattingFlags, containerSizeLimit)
    ts.setIndent(indent)
    return ts
}

extension WTF.TextStream {
    // TextStream::dumpProperty, with the value written by writeValue.
    mutating func writeScrollingProperty(_ name: Swift.String, _ writeValue: (inout WTF.TextStream) -> Void) {
        startGroup()
        appendUTF8(name.utf8.span)
        appendUTF8(" ".utf8.span)
        writeValue(&self)
        endGroup()
    }
}

extension WebCore.ScrollingStateNodeProperties {
    init(_ properties: WebCore.ScrollingStateNodeProperty...) {
        self.init()
        for property in properties {
            add(.init(property))
        }
    }
}

extension WebCore.ScrollingStateNode {
    // The properties every node has: applicableProperties() and the subclasses' overrides, which cannot call super, add theirs to these.
    var stateNodeApplicableProperties: WebCore.ScrollingStateNodeProperties { .init(.Layer, .ChildNodes) }

    @cxx
    @implementation
    public func applicableProperties() -> WebCore.ScrollingStateNodeProperties {
        stateNodeApplicableProperties
    }

    @cxx
    @implementation
    func setPropertyChanged(_ property: WebCore.ScrollingStateNodeProperty) {
        if hasChangedProperty(property) {
            return
        }

        setPropertyChangedInternal(property)
        scrollingStateTree().setHasChangedProperties(true)
    }

    @cxx
    @implementation
    func attachAfterDeserialization(_ tree: WebCore.ScrollingStateTree) {
        assert(!isAttachedToScrollingStateTree())
        m_scrollingStateTree = .init(tree)

        // Non-deserialization ScrollingStateScrollingNode constructors do this during construction,
        // but since we didn't have a ScrollingStateTree pointer until attaching, do it now.
        if isScrollingNode() {
            tree.scrollingNodeAdded()
        }

        var index = 0
        while let child = WebCore.scrollingStateChildAtIndex(self, index) {
            child.attachAfterDeserialization(tree)
            index += 1
        }
    }

    @cxx
    @implementation
    func appendChild(_ childNode: WebCore.RefScrollingStateNode) {
        childNode.get().setParent(consuming: WebCore.RefPtrScrollingStateNode(self))

        m_children.append(consuming: childNode)
        setPropertyChanged(.ChildNodes)
    }

    @cxx
    @implementation
    func insertChild(_ childNode: WebCore.RefScrollingStateNode, _ index: Int) {
        childNode.get().setParent(consuming: WebCore.RefPtrScrollingStateNode(self))

        if index > m_children.size() {
            assertionFailure("Crash data suggest we can get here.")
            m_children.append(consuming: childNode)
        } else {
            m_children.insert(index, consuming: childNode)
        }

        setPropertyChanged(.ChildNodes)
    }

    @cxx
    @implementation
    func removeFromParent() {
        guard let parent = m_parent.get().get() else {
            return
        }

        parent.removeChild(self)
        m_parent = .init()
    }

    @cxx
    @implementation
    func scrollingStateTreeAsText(_ behavior: WebCore.ScrollingStateTreeAsTextBehaviors) -> WTF.String {
        var ts = WTF.TextStream(.MultipleLine, .init(.SVGStyleRect))

        dump(&ts, behavior)
        ts.appendUTF8("\n".utf8.span)
        return ts.release()
    }

    // The base class's text, which the subclasses' dumpPropertiesText() overrides call, as they cannot call super.
    @cxx
    @implementation
    public func stateNodePropertiesText(
        _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors,
        _ indent: Int32,
        _ formattingFlags: WebCore.TextStreamFormattingFlags,
        _ containerSizeLimit: UInt32
    ) -> WTF.String {
        var ts = makeScrollingDumpStream(indent, formattingFlags, containerSizeLimit)

        if behavior.contains(.IncludeNodeIDs) {
            ts.writeScrollingProperty("nodeID") { $0.append(scrollingNodeID()) }
        }

        if behavior.contains(.IncludeLayerIDs) {
            ts.writeScrollingProperty("layerID") { $0.append(m_layer.layerID()) }
        }

        return ts.release()
    }

    @cxx
    @implementation
    public func dumpPropertiesText(
        _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors,
        _ indent: Int32,
        _ formattingFlags: WebCore.TextStreamFormattingFlags,
        _ containerSizeLimit: UInt32
    ) -> WTF.String {
        stateNodePropertiesText(behavior, indent, formattingFlags, containerSizeLimit)
    }
}

#endif
