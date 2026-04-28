// Copyright (C) 2024-2025 Apple Inc. All rights reserved.
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

#if USE_APPLE_INTERNAL_SDK || (!os(tvOS) && !os(watchOS))

import Foundation
import WebKit_Internal

@objc
@implementation
extension WKTextExtractionItem {
    let rectInWebView: CGRect
    let children: [WKTextExtractionItem]
    let eventListeners: WKTextExtractionEventListenerTypes
    let ariaAttributes: [Swift.String: Swift.String]
    let accessibilityRole: Swift.String
    let nodeIdentifier: Swift.String?

    @objc
    fileprivate init(
        with rectInWebView: CGRect,
        children: [WKTextExtractionItem],
        eventListeners: WKTextExtractionEventListenerTypes,
        ariaAttributes: [Swift.String: Swift.String],
        accessibilityRole: Swift.String,
        nodeIdentifier: Swift.String?
    ) {
        self.rectInWebView = rectInWebView
        self.children = children
        self.eventListeners = eventListeners
        self.nodeIdentifier = nodeIdentifier
        self.ariaAttributes = ariaAttributes
        self.accessibilityRole = accessibilityRole
    }
}

@objc
@implementation
extension WKTextExtractionFormItem {
    let autocomplete: Swift.String
    let name: Swift.String

    init(
        autocomplete: Swift.String,
        name: Swift.String,
        rectInWebView: CGRect,
        children: [WKTextExtractionItem],
        eventListeners: WKTextExtractionEventListenerTypes,
        ariaAttributes: [Swift.String: Swift.String],
        accessibilityRole: Swift.String,
        nodeIdentifier: Swift.String?
    ) {
        self.autocomplete = autocomplete
        self.name = name
        super
            .init(
                with: rectInWebView,
                children: children,
                eventListeners: eventListeners,
                ariaAttributes: ariaAttributes,
                accessibilityRole: accessibilityRole,
                nodeIdentifier: nodeIdentifier
            )
    }
}

@objc
@implementation
extension WKTextExtractionContainerItem {
    let container: WKTextExtractionContainer

    init(
        container: WKTextExtractionContainer,
        rectInWebView: CGRect,
        children: [WKTextExtractionItem],
        eventListeners: WKTextExtractionEventListenerTypes,
        ariaAttributes: [Swift.String: Swift.String],
        accessibilityRole: Swift.String,
        nodeIdentifier: Swift.String?
    ) {
        self.container = container
        super
            .init(
                with: rectInWebView,
                children: children,
                eventListeners: eventListeners,
                ariaAttributes: ariaAttributes,
                accessibilityRole: accessibilityRole,
                nodeIdentifier: nodeIdentifier
            )
    }
}

@objc
@implementation
extension WKTextExtractionContentEditableItem {
    let contentEditableType: WKTextExtractionEditableType

    @nonobjc
    private let backingIsFocused: Bool
    @objc(focused)
    var isFocused: Bool {
        @objc(isFocused)
        get { backingIsFocused }
    }

    init(
        contentEditableType: WKTextExtractionEditableType,
        isFocused: Bool,
        rectInWebView: CGRect,
        children: [WKTextExtractionItem],
        eventListeners: WKTextExtractionEventListenerTypes,
        ariaAttributes: [Swift.String: Swift.String],
        accessibilityRole: Swift.String,
        nodeIdentifier: Swift.String?
    ) {
        self.contentEditableType = contentEditableType
        self.backingIsFocused = isFocused
        super
            .init(
                with: rectInWebView,
                children: children,
                eventListeners: eventListeners,
                ariaAttributes: ariaAttributes,
                accessibilityRole: accessibilityRole,
                nodeIdentifier: nodeIdentifier
            )
    }
}

@objc
@implementation
extension WKTextExtractionTextFormControlItem {
    fileprivate let editable: WKTextExtractionEditable

    @objc(secure)
    var isSecure: Bool {
        editable.isSecure
    }

    @objc(focused)
    var isFocused: Bool {
        editable.isFocused
    }

    @objc
    var label: Swift.String {
        editable.label
    }

    @objc
    var placeholder: Swift.String {
        editable.placeholder
    }

    let controlType: Swift.String
    let autocomplete: Swift.String

    @nonobjc
    private let backingIsReadonly: Bool
    @objc(readonly)
    var isReadonly: Bool {
        @objc(isReadonly)
        get { backingIsReadonly }
    }

    @nonobjc
    private let backingIsDisabled: Bool
    @objc(disabled)
    var isDisabled: Bool {
        @objc(isDisabled)
        get { backingIsDisabled }
    }

    @nonobjc
    private let backingIsChecked: Bool
    @objc(checked)
    var isChecked: Bool {
        @objc(isChecked)
        get { backingIsChecked }
    }

    init(
        editable: WKTextExtractionEditable,
        controlType: Swift.String,
        autocomplete: Swift.String,
        isReadonly: Bool,
        isDisabled: Bool,
        isChecked: Bool,
        rectInWebView: CGRect,
        children: [WKTextExtractionItem],
        eventListeners: WKTextExtractionEventListenerTypes,
        ariaAttributes: [Swift.String: Swift.String],
        accessibilityRole: Swift.String,
        nodeIdentifier: Swift.String?
    ) {
        self.editable = editable
        self.controlType = controlType
        self.autocomplete = autocomplete
        self.backingIsReadonly = isReadonly
        self.backingIsDisabled = isDisabled
        self.backingIsChecked = isChecked
        super
            .init(
                with: rectInWebView,
                children: children,
                eventListeners: eventListeners,
                ariaAttributes: ariaAttributes,
                accessibilityRole: accessibilityRole,
                nodeIdentifier: nodeIdentifier
            )
    }
}

@objc
@implementation
extension WKTextExtractionEditable {
    let label: Swift.String
    let placeholder: Swift.String

    // Properties with a customized getter are incorrectly mapped when using ObjCImplementation.
    @nonobjc
    private let backingIsSecure: Bool
    @objc(secure)
    var isSecure: Bool {
        @objc(isSecure)
        get { backingIsSecure }
    }

    // Properties with a customized getter are incorrectly mapped when using ObjCImplementation.
    @nonobjc
    private let backingIsFocused: Bool
    @objc(focused)
    var isFocused: Bool {
        @objc(isFocused)
        get { backingIsFocused }
    }

    init(label: Swift.String, placeholder: Swift.String, isSecure: Bool, isFocused: Bool) {
        self.label = label
        self.placeholder = placeholder
        self.backingIsSecure = isSecure
        self.backingIsFocused = isFocused
    }
}

@objc
@implementation
extension WKTextExtractionLinkItem {
    let target: Swift.String
    @nonobjc
    private let backingURL: NSURL?

    var url: Foundation.URL? { backingURL as Foundation.URL? }

    init(
        target: Swift.String,
        url: Foundation.URL?,
        rectInWebView: CGRect,
        children: [WKTextExtractionItem],
        eventListeners: WKTextExtractionEventListenerTypes,
        ariaAttributes: [Swift.String: Swift.String],
        accessibilityRole: Swift.String,
        nodeIdentifier: Swift.String?
    ) {
        self.target = target
        self.backingURL = url as NSURL?
        super
            .init(
                with: rectInWebView,
                children: children,
                eventListeners: eventListeners,
                ariaAttributes: ariaAttributes,
                accessibilityRole: accessibilityRole,
                nodeIdentifier: nodeIdentifier
            )
    }
}

@objc
@implementation
extension WKTextExtractionLink {
    // Used to workaround the fact that `@objc @implementation` does not support stored properties whose size can change
    // due to Library Evolution. Do not use this property directly.
    @nonobjc
    private let backingURL: NSURL

    var url: Foundation.URL { backingURL as Foundation.URL }

    let range: NSRange

    @objc(initWithURL:range:)
    init(url: Foundation.URL, range: NSRange) {
        self.backingURL = url as NSURL
        self.range = range
    }
}

@objc
@implementation
extension WKTextExtractionIFrameItem {
    let origin: Swift.String

    init(
        origin: Swift.String,
        rectInWebView: CGRect,
        children: [WKTextExtractionItem],
        eventListeners: WKTextExtractionEventListenerTypes,
        ariaAttributes: [Swift.String: Swift.String],
        accessibilityRole: Swift.String,
        nodeIdentifier: Swift.String?
    ) {
        self.origin = origin
        super
            .init(
                with: rectInWebView,
                children: children,
                eventListeners: eventListeners,
                ariaAttributes: ariaAttributes,
                accessibilityRole: accessibilityRole,
                nodeIdentifier: nodeIdentifier
            )
    }
}

@objc
@implementation
extension WKTextExtractionTextItem {
    var content: Swift.String
    var selectedRange: NSRange
    let links: [WKTextExtractionLink]
    let editable: WKTextExtractionEditable?

    init(
        content: Swift.String,
        selectedRange: NSRange,
        links: [WKTextExtractionLink],
        editable: WKTextExtractionEditable?,
        rectInWebView: CGRect,
        children: [WKTextExtractionItem],
        eventListeners: WKTextExtractionEventListenerTypes,
        ariaAttributes: [Swift.String: Swift.String],
        accessibilityRole: Swift.String,
        nodeIdentifier: Swift.String?
    ) {
        self.content = content
        self.selectedRange = selectedRange
        self.links = links
        self.editable = editable
        super
            .init(
                with: rectInWebView,
                children: children,
                eventListeners: eventListeners,
                ariaAttributes: ariaAttributes,
                accessibilityRole: accessibilityRole,
                nodeIdentifier: nodeIdentifier
            )
    }
}

@objc
@implementation
extension WKTextExtractionScrollableItem {
    let contentSize: CGSize

    init(
        contentSize: CGSize,
        rectInWebView: CGRect,
        children: [WKTextExtractionItem],
        eventListeners: WKTextExtractionEventListenerTypes,
        ariaAttributes: [Swift.String: Swift.String],
        accessibilityRole: Swift.String,
        nodeIdentifier: Swift.String?
    ) {
        self.contentSize = contentSize
        super
            .init(
                with: rectInWebView,
                children: children,
                eventListeners: eventListeners,
                ariaAttributes: ariaAttributes,
                accessibilityRole: accessibilityRole,
                nodeIdentifier: nodeIdentifier
            )
    }
}

@objc
@implementation
extension WKTextExtractionSelectItem {
    let selectedValues: [Swift.String]
    let supportsMultiple: Bool

    init(
        selectedValues: [Swift.String],
        supportsMultiple: Bool,
        rectInWebView: CGRect,
        children: [WKTextExtractionItem],
        eventListeners: WKTextExtractionEventListenerTypes,
        ariaAttributes: [Swift.String: Swift.String],
        accessibilityRole: Swift.String,
        nodeIdentifier: Swift.String?
    ) {
        self.selectedValues = selectedValues
        self.supportsMultiple = supportsMultiple
        super
            .init(
                with: rectInWebView,
                children: children,
                eventListeners: eventListeners,
                ariaAttributes: ariaAttributes,
                accessibilityRole: accessibilityRole,
                nodeIdentifier: nodeIdentifier
            )
    }
}

@objc
@implementation
extension WKTextExtractionImageItem {
    let name: Swift.String
    let altText: Swift.String

    init(
        name: Swift.String,
        altText: Swift.String,
        rectInWebView: CGRect,
        children: [WKTextExtractionItem],
        eventListeners: WKTextExtractionEventListenerTypes,
        ariaAttributes: [Swift.String: Swift.String],
        accessibilityRole: Swift.String,
        nodeIdentifier: Swift.String?
    ) {
        self.name = name
        self.altText = altText
        super
            .init(
                with: rectInWebView,
                children: children,
                eventListeners: eventListeners,
                ariaAttributes: ariaAttributes,
                accessibilityRole: accessibilityRole,
                nodeIdentifier: nodeIdentifier
            )
    }
}

#endif // USE_APPLE_INTERNAL_SDK || (!os(tvOS) && !os(watchOS))
