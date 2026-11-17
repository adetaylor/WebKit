//
// Copyright (C) 2021-2023 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1.  Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
// 2.  Redistributions in binary form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

import WebKit_Internal

@_expose(Cxx)
final class TestWithStreamSwiftLentStateWeakRef {
    private let target: TestWithStreamSwiftLentState
    init(target: TestWithStreamSwiftLentState) {
        self.target = target
    }

    @used
    func dispatchReset(
        state: inout TestWithStreamSwiftLentState.State
    ) -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.reset(
                    state: &state
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchSetValues(
        state: inout TestWithStreamSwiftLentState.State,
        value: UInt32,
        scale: Float
    ) -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.setValues(
                    state: &state,
                    value: value,
                    scale: scale
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchDraw(
        state: inout TestWithStreamSwiftLentState.State,
        rect: WebCore.FloatRect,
        clip: Bool
    ) -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            let handled = try mayThrowInvalidMessage(
                target.draw(
                    state: &state,
                    rect: rect,
                    clip: clip
                )
            )
            return handled ? .Handled : .Declined
        } catch {
            return .Invalid
        }
    }

    @used
    func dispatchSetLabel(
        state: inout TestWithStreamSwiftLentState.State,
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let label: String?
        let values: [UInt32]
        do {
            label = try IPCCoding.WTFString.decode(from: &decoder)
            values = try IPCCoding.Vector<UInt32>.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.setLabel(
                    state: &state,
                    label: label,
                    values: values
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchFillPath(
        state: inout TestWithStreamSwiftLentState.State,
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let path: IPCTypes.Path
        let decodeContext = target.pathDecodeContext(state: state)
        do {
            path = try IPCTypes.Path.decode(from: &decoder, context: decodeContext)
        } catch {
            IPCTypes.Path.decodeFailed(context: decodeContext)
            return .Invalid
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.fillPath(
                    state: &state,
                    path: path
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchSetSemaphore(
        state: inout TestWithStreamSwiftLentState.State,
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let semaphore: IPCTypes.Semaphore
        let scale: Float
        do {
            semaphore = try IPCTypes.Semaphore.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do {
            scale = try Float.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.setSemaphore(
                    state: &state,
                    semaphore: semaphore,
                    scale: scale
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }
}

extension WebKit.TestWithStreamSwiftLentStateMessageForwarder {
    static func create(target: TestWithStreamSwiftLentState) -> RefTestWithStreamSwiftLentStateMessageForwarder {
        let weakRefContainer = TestWithStreamSwiftLentStateWeakRef(target: target)
        // Safety: we're creating a pointer which will immediately be stored in a
        // proper ref-counted reference on the C++ side before this call returns.
        // Workaround for rdar://163107752.
        return unsafe WebKit.TestWithStreamSwiftLentStateMessageForwarder.createFromWeak(
            OpaquePointer(
                Unmanaged.passRetained(weakRefContainer).toOpaque()
            )
        )
    }
}
