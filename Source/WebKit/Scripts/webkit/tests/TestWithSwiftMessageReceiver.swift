internal import WebKit_Internal

@_expose(Cxx)
internal class TestWithSwiftWeakRef {
    weak var target: TestWithSwift?
    init(target: TestWithSwift) {
        self.target = target
    }

    @_expose(Cxx)
    internal func getMessageTarget() -> TestWithSwift? {
        target
    }
}

extension WebKit.TestWithSwiftMessageForwarder {
    internal static func create(target: TestWithSwift) -> RefTestWithSwiftMessageForwarder {
        let weakRefContainer = TestWithSwiftWeakRef(target: target)
        // Safety: we're creating a pointer which will immediately be stored in a
        // proper ref-counted reference on the C++ side before this call returns.
        // Workaround for rdar://163107752.
        return unsafe WebKit.TestWithSwiftMessageForwarder.createFromWeak(
            OpaquePointer(
                Unmanaged.passRetained(weakRefContainer).toOpaque()
            )
        )
    }
}
