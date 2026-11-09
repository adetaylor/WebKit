/*
 * Copyright (C) 2022 Apple Inc. All rights reserved.
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

#pragma once

#include <wtf/Platform.h>

#if PLATFORM(MAC) && defined(__OBJC__)

#import <AppKit/AppKit.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@interface WebControlWindow : NSWindow
@property (class) BOOL hasKeyAppearance;
- (BOOL)_needsToResetDragMargins;
- (void)_setNeedsToResetDragMargins:(BOOL)needs;
@end

@interface WebControlView : NSControl
@property (class) NSRect clipBounds;
@end

@interface WebControlTextFieldCell : NSTextFieldCell
@end

// NSCell's drawing without a view, which AppKit declares with a nonnull view (rdar://105250010).
@protocol WebViewlessCellDrawing
- (void)drawWithFrame:(NSRect)cellFrame inView:(nullable NSView *)controlView;
- (void)drawFocusRingMaskWithFrame:(NSRect)cellFrame inView:(nullable NSView *)controlView;
@end

@interface NSCell (WebViewlessCellDrawing) <WebViewlessCellDrawing>
@end

NS_HEADER_AUDIT_END(nullability, sendability)

#endif // PLATFORM(MAC) && defined(__OBJC__)
