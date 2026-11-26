/*
 * Copyright (C) 2020-2022 Apple Inc. All rights reserved.
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#if WTF_PLATFORM_MAC

internal import WebCore_Private.Core.Element
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.LocalFrame
internal import WebCore_Private.Core.PlatformWheelEvent
internal import WebCore_Private.Core.ScrollLatchingController

extension WebCore.ScrollLatchingController {
    @cxx
    @implementation
    func clear() {
        m_cumulativeEventDelta = WebCore.FloatSize()
        m_frameStateStack.clear()
    }

    @cxx
    @implementation
    func clearTimerFired() {
        clear()
    }

    @cxx
    @implementation
    func receivedWheelEvent(_ wheelEvent: WebCore.PlatformWheelEvent) {
        clearOrScheduleClearIfNeeded(wheelEvent)

        if wheelEvent.isGestureStart() || wheelEvent.isNonGestureEvent() {
            m_cumulativeEventDelta = wheelEvent.delta()
        } else {
            m_cumulativeEventDelta += wheelEvent.delta()
        }
    }

    @cxx
    @implementation
    func removeLatchingStateForTarget(_ borrowedElement: borrowing WebCore.Element) {
        let element = copy borrowedElement
        if m_frameStateStack.isEmpty() {
            return
        }

        // If this element is found in the latching stack, just clear the whole stack. We can't just remove one entry,
        // since the stack has to match the frame hierarchy.
        for index in 0..<m_frameStateStack.size() {
            if let wheelElement = m_frameStateStack[index].wheelEventElement.get(), element.isEqualNode(wheelElement) {
                m_frameStateStack.clear()
                return
            }
        }
    }

    @cxx
    @implementation
    func removeLatchingStateForFrame(_ borrowedFrame: borrowing WebCore.LocalFrame) {
        let frame = copy borrowedFrame
        if m_frameStateStack.isEmpty() {
            return
        }

        // If the frame was in the latching stack, just clear state.
        if hasStateForFrame(frame) {
            clear()
        }
    }
}

#endif // WTF_PLATFORM_MAC
