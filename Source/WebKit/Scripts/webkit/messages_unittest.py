# Copyright (C) 2010-2023 Apple Inc. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1.  Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
# 2.  Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Examples of how to run:
# python3 Source/WebKit/Scripts/webkit/messages_unittest.py [-r]
# cd Source/WebKit/Scripts && python3 -m webkit.messages_unittest
# cd Source/WebKit/Scripts && python3 -m unittest discover -p '*_unittest.py'

from __future__ import print_function
import io
import os
import re
import sys
import unittest

module_directory = os.path.dirname(os.path.abspath(__file__))

sys.path.append(os.path.abspath(os.path.join(module_directory, os.path.pardir)))
from webkit import messages, model, parser  # noqa: E402

tests_directory = os.path.join(module_directory, 'tests')

reset_results = False

_test_receiver_names = [
    'TestWithCVPixelBuffer',
    'TestWithDeferSendingOption',
    'TestWithDispatchedFromAndTo',
    'TestWithEnabledBy',
    'TestWithEnabledByAndConjunction',
    'TestWithEnabledByOrConjunction',
    'TestWithIfMessage',
    'TestWithImageData',
    'TestWithLegacyReceiver',
    'TestWithMultiLineExtendedAttributes',
    'TestWithMultipleDispatchedFrom',
    'TestWithoutAttributes',
    'TestWithoutUsingIPCConnection',
    'TestWithSemaphore',
    'TestWithSpanOfConst',
    'TestWithStream',
    'TestWithStreamBatched',
    'TestWithStreamBuffer',
    'TestWithStreamServerConnectionHandle',
    'TestWithStreamSwift',
    'TestWithStreamSwiftEnabledBy',
    'TestWithStreamSwiftImplementation',
    'TestWithStreamSwiftLentState',
    'TestWithStreamSwiftRecordable',
    'TestWithStreamSwiftReplyValues',
    'TestWithStreamSwiftState',
    'TestWithStreamSwiftTypes',
    'TestWithSuperclass',
    'TestWithSuperclassAndWantsAsyncDispatch',
    'TestWithSuperclassAndWantsDispatch',
    'TestWithSwift',
    'TestWithSwiftConditionally',
    'TestWithSwiftConditionallyAndEnabledBy',
    'TestWithSwiftImplementation',
    'TestWithSwiftImplementationAndSuperclass',
    'TestWithSwiftImplementationAndWantsDispatch',
    'TestWithSwiftTypes',
    'TestWithSwiftTypesOptIn',
    'TestWithSwiftWorkQueue',
    'TestWithValidator',
    'TestWithWantsAsyncDispatch',
    'TestWithWantsDispatch',
    'TestWithWantsDispatchNoSyncMessages',
    'TestWithWorkQueueSwiftImplementation',
    'TestWithWorkQueueSwiftState',
]


def receiver_header_file_name(receiver_name):
    return '%sMessages.h' % receiver_name


def receiver_implementation_file_name(receiver_name):
    return '%sMessageReceiver.cpp' % receiver_name


def parse_receiver(receiver_name):
    with open(os.path.join(tests_directory, '{}.messages.in'.format(receiver_name))) as in_file:
        return parser.parse(in_file)
    assert(False)


class GeneratedFileContentsTest(unittest.TestCase):
    def setUp(self):
        self.test_receivers = [parse_receiver(receiver_name) for receiver_name in _test_receiver_names]
        self.receivers = model.generate_global_model(self.test_receivers)

    def assertGeneratedFileContentsEqual(self, actual_file_contents, expected_file_name):
        try:
            if reset_results:
                with open(os.path.join(tests_directory, expected_file_name), mode='w') as out_file:
                    out_file.write(actual_file_contents)
                return

            with open(os.path.join(tests_directory, expected_file_name), mode='r') as in_file:
                expected_file_contents = in_file.read()
            actual_line_list = actual_file_contents.splitlines(False)
            expected_line_list = expected_file_contents.splitlines(False)

            for index, actual_line in enumerate(actual_line_list):
                self.assertEqual(actual_line, expected_line_list[index])

            self.assertEqual(len(actual_line_list), len(expected_line_list))
        except Exception:
            sys.stderr.write('In expected file %s\n' % expected_file_name)
            raise

    def test_receiver(self):
        for receiver_name, receiver in zip(_test_receiver_names, self.test_receivers):
            header_contents = messages.generate_messages_header(receiver)
            self.assertGeneratedFileContentsEqual(header_contents, os.path.join(tests_directory, '{}Messages.h'.format(receiver_name)))
            implementation_contents = messages.generate_message_handler(receiver)
            self.assertGeneratedFileContentsEqual(implementation_contents, os.path.join(tests_directory, '{}MessageReceiver.cpp'.format(receiver_name)))
            if receiver.swift_receiver or receiver.swift_receiver_build_enabled_by or receiver.is_swift_implementation():
                swift_implementation_contents = messages.generate_swift_message_handler(receiver)
                self.assertGeneratedFileContentsEqual(swift_implementation_contents, os.path.join(tests_directory, '{}MessageReceiver.swift'.format(receiver_name)))

    def test_message_names(self):
        header_contents = messages.generate_message_names_header(self.receivers)
        self.assertGeneratedFileContentsEqual(header_contents, os.path.join(tests_directory, 'MessageNames.h'))
        implementation_contents = messages.generate_message_names_implementation(self.receivers)
        self.assertGeneratedFileContentsEqual(implementation_contents, os.path.join(tests_directory, 'MessageNames.cpp'))

    def test_message_names_without_async_with_reply_messages(self):
        receivers = model.generate_global_model([parse_receiver(receiver_name) for receiver_name in ['TestWithStreamBuffer', 'TestWithoutUsingIPCConnection']])
        header_contents = messages.generate_message_names_header(receivers)
        self.assertNotIn('FirstAsyncWithReply', header_contents)
        self.assertIn('constexpr bool messageIsAsyncWithReply(MessageName name)\n{\n    UNUSED_PARAM(name);\n    return false;\n}\n', header_contents)

    def test_message_argument_description(self):
        receiver_header_files = ['{}Messages.h'.format(receiver.name) for receiver in self.receivers]
        implementation_contents = messages.generate_message_argument_description_implementation(self.receivers, receiver_header_files)
        self.assertGeneratedFileContentsEqual(implementation_contents, os.path.join(tests_directory, 'MessageArgumentDescriptions.cpp'))


def parse_swift_receiver(attributes, messages_text):
    return parser.parse(io.StringIO("""
[
    ExceptionForDispatchedFrom,
    ExceptionForDispatchedTo,
    %s
]
messages -> TestReceiver {
%s
}
""" % (',\n    '.join(attributes), messages_text)))


class SwiftReceiverTest(unittest.TestCase):
    def test_conditional_message(self):
        receiver = parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], """
    Message(uint32_t value)
#if PLATFORM(COCOA) && ENABLE(FEATURE)
    ConditionalMessage(uint32_t value) -> (uint32_t reply)
#endif
""")
        swift = messages.generate_swift_message_handler(receiver)
        self.assertRegex(swift, r'\n    #if WTF_PLATFORM_COCOA && ENABLE_FEATURE\n    @used\n    func dispatchConditionalMessage\(')
        self.assertRegex(swift, r'private final class ConditionalMessageInvocation \{(.|\n)*\n    \}\n    #endif\n\}\n')
        self.assertNotRegex(swift, r'#if[^\n]*\n    @used\n    func dispatchMessage\(')

    def test_error_message_condition_swift_cannot_evaluate(self):
        receiver = parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver'], """
#if defined(SOME_MACRO)
    Message(uint32_t value)
#endif
""")
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message is under a condition Swift cannot evaluate"):
            messages.generate_swift_message_handler(receiver)

    def test_receiver_condition(self):
        receiver = parser.parse(io.StringIO("""
#if USE(LIBRARY) && PLATFORM(COCOA) && ENABLE(FEATURE)
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftReceiver]
messages -> TestReceiver {
    Message(uint32_t value)
}
#endif
"""))
        swift = messages.generate_swift_message_handler(receiver)
        self.assertEqual(swift.count('\n#if USE_LIBRARY && WTF_PLATFORM_COCOA && ENABLE_FEATURE\n'), 2)

        receiver = parser.parse(io.StringIO("""
#if defined(SOME_MACRO)
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftReceiver]
messages -> TestReceiver {
    Message(uint32_t value)
}
#endif
"""))
        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver is under a condition Swift cannot evaluate"):
            messages.generate_swift_message_handler(receiver)

    def test_shared_preferences_alias(self):
        for attributes, has_alias in [
            (['EnabledBy=SomeFeature', 'SwiftReceiver'], True),
            (['ExceptionForEnabledBy', 'SwiftReceiverBuildEnabledBy=SOME_FLAG'], False),
            (['EnabledBy=SomeFeature'], False),
        ]:
            header = messages.generate_messages_header(parse_swift_receiver(attributes, '    Message(uint32_t value)'))
            self.assertEqual('using OptionalSharedPreferencesForWebProcess = std::optional<SharedPreferencesForWebProcess>;' in header, has_alias, attributes)
            self.assertEqual('#include "SharedPreferencesForWebProcess.h"' in header, has_alias, attributes)

        receiver = parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver'], '    [EnabledBy=SomeFeature] Message(uint32_t value)')
        self.assertIn('using OptionalSharedPreferencesForWebProcess', messages.generate_messages_header(receiver))

    def test_wants_connection_is_for_swift_types_on_a_stream(self):
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'WantsConnection', which is for messages that take Swift types on a stream"):
            parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], '    Message(uint32_t value) WantsConnection')

    def test_swift_types_off_the_main_thread(self):
        for attribute in ['AnyThread', 'MainThreadCallback']:
            receiver = parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], """
    Message(uint32_t value) -> (uint32_t reply) %s
""" % attribute)
            with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message takes Swift types, which are dispatched on the main thread, but is %s" % attribute):
                messages.generate_swift_message_handler(receiver)

        receiver = parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver'], """
    Message(uint32_t value) -> (uint32_t reply) AnyThread
""")
        messages.generate_swift_message_handler(receiver)

        stream_receiver = parser.parse(io.StringIO("""
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftReceiver]
messages -> TestReceiver Stream {
    Message(uint32_t value) -> (uint32_t reply) AnyThread
}
"""))
        self.assertIn('func dispatchMessage(', messages.generate_swift_message_handler(stream_receiver))

    def test_work_queue_receiver(self):
        def parse_work_queue_receiver(attributes, receiver_attributes, messages_text):
            return parser.parse(io.StringIO("""
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy%s]
messages -> TestReceiver %s {
%s
}
""" % (''.join(', ' + attribute for attribute in attributes), receiver_attributes, messages_text)))

        receiver = parse_work_queue_receiver(['SwiftReceiver', 'SwiftTypes'], 'WorkQueue', """
    Message(uint32_t value) -> (uint32_t reply) AnyThread
    CxxMessage(uint32_t value) -> (uint32_t reply) CxxTypes
""")
        swift = messages.generate_swift_message_handler(receiver)
        self.assertNotIn('MainActor', swift)
        self.assertNotIn('Task', swift)
        self.assertNotIn('Invocation', swift)
        self.assertNotIn('Sendable', swift)
        self.assertIn('    private let target: TestReceiver\n', swift)
        self.assertIn('reply: TestReceiverMessageReply(replyEncoder: replyEncoder)', swift)
        self.assertIn('CompletionHandlers.TestReceiver.complete(completionHandler, reply)', swift)
        header = messages.generate_messages_header(receiver)
        self.assertIn('class TestReceiverMessageForwarder final : public IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any> {', header)
        self.assertNotIn('getMessageTarget', header)
        self.assertIn('    void startReceivingMessages(IPC::Connection&, WorkQueue&, uint64_t destinationID = 0);\n', header)
        implementation = messages.generate_message_handler(receiver)
        self.assertNotIn('getMessageTarget', implementation)
        self.assertIn('    ASSERT(m_workQueue && m_workQueue->isCurrent());\n', implementation)
        self.assertIn('    RELEASE_ASSERT(m_workQueue.get() == &workQueue);\n', implementation)

        # With EnabledBy, the forwarder checks its own copy of the shared preferences, which it is given, rather than
        # asking Swift for them.
        receiver = parser.parse(io.StringIO("""
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, SwiftReceiver, SwiftTypes, EnabledBy=SomeFeature]
messages -> TestReceiver WorkQueue {
    Message(uint32_t value)
}
"""))
        header = messages.generate_messages_header(receiver)
        self.assertIn('    void updateSharedPreferences(SharedPreferencesForWebProcess);\n', header)
        self.assertIn('    std::optional<SharedPreferencesForWebProcess> m_sharedPreferences;\n', header)
        self.assertNotIn('m_sharedPreferencesProvider', header)
        implementation = messages.generate_message_handler(receiver)
        self.assertIn('    auto& sharedPreferences = m_sharedPreferences;\n', implementation)
        self.assertIn('    workQueue->dispatch([protectedThis = Ref { *this }, sharedPreferences = WTF::move(sharedPreferences)] mutable {\n', implementation)
        self.assertNotIn('sharedPreferencesForWebProcess', messages.generate_swift_message_handler(receiver))

        # With SwiftActor, dispatch enters the target, an actor on the work queue, with assumeIsolated, and moves the
        # owned arguments into it.
        receiver = parse_work_queue_receiver(['SwiftReceiver', 'SwiftTypes', 'SwiftActor'], 'WorkQueue', """
    Message(uint32_t value) -> (uint32_t reply)
    SyncMessage(uint32_t value) -> (uint32_t reply) Synchronous
    HandleMessage(WebCore::SharedMemory::Handle handle)
    LentMessage([Lent] std::span<const uint8_t> data)
""")
        swift = messages.generate_swift_message_handler(receiver)
        self.assertIn('    private let target: TestReceiver\n', swift)
        self.assertEqual(swift.count('        target.assumeIsolated { target in\n'), 4)
        self.assertIn('    @_expose(!Cxx)\n    init(target: TestReceiver) {\n', swift)
        self.assertIn('        connection: sending IPC.Connection,\n', swift)
        self.assertIn('        nonisolated(unsafe) let dataLent = decoder.lentBytes(dataPosition)\n', swift)
        self.assertIn('                try unsafe mayThrowInvalidMessage(\n', swift)
        self.assertIn('                        data: dataLent\n', swift)
        self.assertIn('        var handleOwned = Optional(handle)\n', swift)
        self.assertIn('handle: handleOwned.take()!', swift)
        self.assertIn('                    reply: TestReceiverMessageReply(replyEncoder: replyEncoder)', swift)
        self.assertNotIn('MainActor', swift)
        self.assertNotIn('Task', swift)
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.CxxMessage takes C\+\+ types, which a receiver with 'SwiftActor' can't"):
            parse_work_queue_receiver(['SwiftReceiver', 'SwiftTypes', 'SwiftActor'], 'WorkQueue', '    CxxMessage(uint32_t value) CxxTypes')
        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver has 'SwiftActor', which is for Swift receivers with 'WorkQueue'"):
            parse_work_queue_receiver(['SwiftReceiver', 'SwiftTypes', 'SwiftActor'], 'Stream', '    Message(uint32_t value)')

        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver has 'WorkQueue', which is for Swift receivers"):
            parse_work_queue_receiver([], 'WorkQueue', '    Message(uint32_t value)')
        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver cannot have both 'WorkQueue' and 'Stream'"):
            parse_work_queue_receiver(['SwiftReceiver'], 'Stream WorkQueue', '    Message(uint32_t value)')

    def test_sync_handler(self):
        receiver = parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], """
    SyncMessage(uint32_t value) -> (uint32_t reply) SwiftSyncHandler
    AsyncMessage(uint32_t value) -> (uint32_t reply)
""")
        swift = messages.generate_swift_message_handler(receiver)
        sync_dispatch = re.search(r'func dispatchSyncMessage\((.|\n)*?\n    \}\n', swift).group(0)
        self.assertIn('MainActor.assumeIsolated {', sync_dispatch)
        self.assertIn('do throws(InvalidMessage) {', sync_dispatch)
        self.assertIn('let reply = try mayThrowInvalidMessage(', sync_dispatch)
        self.assertNotIn('await', sync_dispatch)
        self.assertNotIn('Task', sync_dispatch)
        self.assertNotIn('SyncMessageInvocation', swift)
        self.assertIn('private final class AsyncMessageInvocation', swift)

        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'SwiftSyncHandler', which is for messages a Swift receiver handles"):
            parse_swift_receiver(['ExceptionForEnabledBy'], '    Message(uint32_t value) SwiftSyncHandler')

    def test_swift_implementation(self):
        def parse_swift_implementation(messages_text, stream=True, attributes=('SwiftImplementation', 'SwiftTypes')):
            return parser.parse(io.StringIO("""
[
    ExceptionForEnabledBy,
    ExceptionForDispatchedFrom,
    ExceptionForDispatchedTo,
    %s
]
messages -> TestReceiver%s {
%s
}
""" % (',\n    '.join(attributes), ' Stream' if stream else '', messages_text)))

        receiver = parse_swift_implementation("""
    SwiftMessage(uint32_t value)
    CxxMessage(MachSendRight sendRight) CxxTypes NotStreamEncodable
""")
        self.assertTrue(receiver.takes_swift_types(receiver.messages[0]))
        self.assertFalse(receiver.takes_swift_types(receiver.messages[1]))
        header = messages.generate_messages_header(receiver)
        self.assertIn('bool dispatchSwiftMessage(WebKit::TestReceiver* WTF_NONNULL, IPC::SwiftDecoder);', header)
        self.assertNotIn('dispatchCxxMessage', header)
        self.assertNotIn('MessageForwarder', header)
        handler = messages.generate_message_handler(receiver)
        self.assertIn('IPC::handleSwiftMessage<Messages::TestReceiver::SwiftMessage>(connection, decoder, this, &SwiftDispatch::TestReceiver::dispatchSwiftMessage);', handler)
        self.assertIn('IPC::handleMessage<Messages::TestReceiver::CxxMessage>(connection, decoder, this, &TestReceiver::cxxMessage);', handler)
        swift = messages.generate_swift_message_handler(receiver)
        self.assertIn('extension SwiftDispatch.TestReceiver {', swift)
        self.assertIn('    static func dispatchSwiftMessage(\n        _ target: WebKit.TestReceiver,\n        _ decoder: IPC.SwiftDecoder\n    ) -> Bool {', swift)
        self.assertNotIn('CxxMessage', swift)
        self.assertNotIn('MessageForwarder', swift)

        # The dispatch function takes what HandleMessage.h passes a Swift receiver's dispatch.
        self.assertIn('bool dispatchSwiftMessage(WebKit::TestReceiver* WTF_NONNULL, IPC::SwiftDecoder, IPC::SwiftReplyEncoder* WTF_NONNULL);', messages.generate_messages_header(parse_swift_implementation('    SwiftMessage(uint32_t value) -> (bool reply)')))
        self.assertIn('bool dispatchSwiftMessage(WebKit::TestReceiver* WTF_NONNULL, IPC::StreamServerConnection* WTF_NONNULL, IPC::SwiftDecoder);', messages.generate_messages_header(parse_swift_implementation('    SwiftMessage(uint32_t value) WantsConnection')))
        self.assertIn('bool dispatchSwiftMessage(WebKit::TestReceiver* WTF_NONNULL, IPC::Connection* WTF_NONNULL, IPC::SwiftDecoder);', messages.generate_messages_header(parse_swift_implementation('    SwiftMessage(uint32_t value)', stream=False)))

        # On the main thread, dispatch discards the Task it starts, and copies the decoder only if it decodes from it.
        swift = messages.generate_swift_message_handler(parse_swift_implementation('    EmptyMessage()\n    SwiftMessage(uint32_t value)', stream=False))
        self.assertIn('        MainActor.assumeIsolated {\n            _ = Task.immediateOnMainActor {\n', swift)
        self.assertIn('        _ target: sending WebKit.TestReceiver,\n', swift)
        self.assertEqual(swift.count('        var decoder = decoder\n'), 1)
        self.assertIn('    ) -> Bool {\n        var decoder = decoder\n        let value: UInt32\n', swift)
        self.assertIn('var decoder = decoder', messages.generate_swift_message_handler(parse_swift_implementation('    EmptyMessage()')))

        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver has 'SwiftImplementation', which is for a C\+\+ receiver, so it cannot be a Swift receiver too"):
            parse_swift_implementation('    SwiftMessage(uint32_t value)', attributes=('SwiftImplementation', 'SwiftReceiver', 'SwiftTypes'))

        # A C++ receiver that Swift implements only some messages of, and only where a feature is: its C++ dispatch calls
        # Swift's only there, and its Swift dispatch compiles to nothing elsewhere. Its header declares the Swift dispatch
        # functions everywhere, with types every port has.
        receiver = parse_swift_implementation("""
    CxxMessage(uint32_t value)
#if HAVE(FEATURE)
    SwiftMessage(uint32_t value) SwiftTypes
    SwiftReplyMessage() -> (Vector<uint8_t> values) Async SwiftTypes
#endif
""", attributes=('SwiftImplementation',))
        self.assertFalse(receiver.takes_swift_types(receiver.messages[0]))
        self.assertTrue(receiver.takes_swift_types(receiver.messages[1]))
        handler = messages.generate_message_handler(receiver)
        self.assertIn('        IPC::handleMessage<Messages::TestReceiver::CxxMessage>(connection, decoder, this, &TestReceiver::cxxMessage);\n        return;\n    }\n#if HAVE(FEATURE)\n    if (decoder.messageName() == Messages::TestReceiver::SwiftMessage::name()) {\n        IPC::handleSwiftMessage<Messages::TestReceiver::SwiftMessage>(connection, decoder, this, &SwiftDispatch::TestReceiver::dispatchSwiftMessage);\n', handler)
        self.assertIn('        IPC::handleSwiftMessageAsync<Messages::TestReceiver::SwiftReplyMessage>(connection, decoder, this, &SwiftDispatch::TestReceiver::dispatchSwiftReplyMessage);\n        return;\n    }\n#endif\n', handler)
        header = messages.generate_messages_header(receiver)
        self.assertIn('#include "SwiftCoding.h"', header)
        self.assertIn('bool dispatchSwiftReplyMessage(WebKit::TestReceiver* WTF_NONNULL, IPC::SwiftDecoder, IPC::SwiftReplyEncoder* WTF_NONNULL);', header)
        self.assertNotIn('dispatchCxxMessage', header)
        swift = messages.generate_swift_message_handler(receiver)
        self.assertIn('extension SwiftDispatch.TestReceiver {\n    #if HAVE_FEATURE\n', swift)
        self.assertEqual(swift.count('    #if HAVE_FEATURE\n'), 2)
        self.assertNotIn('CxxMessage', swift)

        # With 'SwiftReceiverBuildEnabledBy=', a C++ receiver that Swift implements where the flag is enabled, and whose C++
        # handlers take its messages elsewhere.
        receiver = parse_swift_implementation('    SwiftMessage(uint32_t value)\n    SyncMessage() -> (bool reply) Synchronous', stream=False, attributes=('SwiftImplementation', 'SwiftTypes', 'SwiftReceiverBuildEnabledBy=SWIFT_FLAG'))
        self.assertFalse(receiver.is_swift_receiver())
        handler = messages.generate_message_handler(receiver)
        self.assertIn('#if ENABLE(SWIFT_FLAG)\n        IPC::handleSwiftMessage<Messages::TestReceiver::SwiftMessage>(connection, decoder, this, &SwiftDispatch::TestReceiver::dispatchSwiftMessage);\n#else // ENABLE(SWIFT_FLAG)\n        IPC::handleMessage<Messages::TestReceiver::SwiftMessage>(connection, decoder, this, &TestReceiver::swiftMessage);\n#endif // ENABLE(SWIFT_FLAG)\n', handler)
        self.assertIn('#else // ENABLE(SWIFT_FLAG)\n        IPC::handleMessageSynchronous<Messages::TestReceiver::SyncMessage>(connection, decoder, replyEncoder, this, &TestReceiver::syncMessage);\n', handler)
        self.assertNotIn('MessageForwarder', handler)
        swift = messages.generate_swift_message_handler(receiver)
        self.assertEqual(swift.count('#if ENABLE_SWIFT_FLAG\n'), 2)

    def test_cxx_senders(self):
        receiver = parser.parse(io.StringIO("""
[
    ExceptionForEnabledBy,
    ExceptionForDispatchedFrom,
    ExceptionForDispatchedTo,
    CxxSenders
]
messages -> TestReceiver {
    PlainMessage(double value, String name)
    EmptyMessage()
    ReplyMessage(uint32_t value) -> (bool reply)
    MovedMessage(MachSendRight sendRight)
#if HAVE(FEATURE)
    ConditionalMessage(bool flag)
#endif
}
"""))
        header = messages.generate_messages_header(receiver)
        self.assertIn('inline void sendPlainMessage(IPC::Connection& connection, uint64_t destinationID, double value, const String& name)\n{\n    connection.send(PlainMessage(value, name), destinationID);\n}\n', header)
        self.assertIn('inline void sendEmptyMessage(IPC::Connection& connection, uint64_t destinationID)\n{\n    connection.send(EmptyMessage(), destinationID);\n}\n', header)
        self.assertIn('#if HAVE(FEATURE)\ninline void sendConditionalMessage(IPC::Connection& connection, uint64_t destinationID, bool flag)\n', header)
        self.assertNotIn('sendReplyMessage', header)
        self.assertNotIn('sendMovedMessage', header)
        self.assertNotIn('inline void send', messages.generate_messages_header(parser.parse(io.StringIO('[ExceptionForEnabledBy, ExceptionForDispatchedFrom, ExceptionForDispatchedTo]\nmessages -> TestReceiver {\n    EmptyMessage()\n}\n'))))

        header = messages.generate_messages_header(parser.parse(io.StringIO('[ExceptionForEnabledBy, ExceptionForDispatchedFrom, ExceptionForDispatchedTo, CxxSenders=FEATURE]\nmessages -> TestReceiver {\n    EmptyMessage()\n}\n')))
        self.assertIn('#if ENABLE(FEATURE)\ninline void sendEmptyMessage(IPC::Connection& connection, uint64_t destinationID)\n{\n    connection.send(EmptyMessage(), destinationID);\n}\n\n#endif\n', header)

        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver has 'CxxSenders', which is for receivers whose messages are sent on an IPC::Connection"):
            parser.parse(io.StringIO('[ExceptionForEnabledBy, ExceptionForDispatchedFrom, ExceptionForDispatchedTo, CxxSenders]\nmessages -> TestReceiver Stream {\n    EmptyMessage()\n}\n'))
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Clash has a parameter named 'connection', which its C\+\+ sender \('CxxSenders'\) takes itself"):
            parser.parse(io.StringIO('[ExceptionForEnabledBy, ExceptionForDispatchedFrom, ExceptionForDispatchedTo, CxxSenders]\nmessages -> TestReceiver {\n    Clash(uint64_t connection)\n}\n'))

    def test_swift_state(self):
        def parse(messages_text, receiver_attributes='WorkQueue', attributes=('SwiftImplementation', 'SwiftTypes', 'SwiftState=TestState')):
            return parser.parse(io.StringIO("""
[
    ExceptionForEnabledBy,
    ExceptionForDispatchedFrom,
    ExceptionForDispatchedTo,
    %s
]
messages -> TestReceiver %s {
%s
}
""" % (',\n    '.join(attributes), receiver_attributes, messages_text)))

        receiver = parse("""
    StateMessage(uint32_t value)
    ReceiverMessage(uint32_t value) WantsReceiver
    CxxMessage(uint32_t value) CxxTypes
""")
        self.assertTrue(receiver.dispatches_to_swift_state(receiver.messages[0]))
        self.assertFalse(receiver.dispatches_to_swift_state(receiver.messages[1]))
        self.assertFalse(receiver.dispatches_to_swift_state(receiver.messages[2]))
        header = messages.generate_messages_header(receiver)
        self.assertIn('bool dispatchReceiverMessage(WebKit::TestReceiver* WTF_NONNULL, IPC::Connection* WTF_NONNULL, IPC::SwiftDecoder);', header)
        self.assertNotIn('dispatchStateMessage', header)
        handler = messages.generate_message_handler(receiver)
        self.assertIn('#include "Shared/WebKit-Swift.h"', handler)
        self.assertIn('static TestReceiverStateDispatch& testReceiverStateDispatch(IPC::SwiftStateDispatch& dispatch, TestReceiver& receiver)\n', handler)
        self.assertIn('IPC::handleSwiftMessage<Messages::TestReceiver::StateMessage>(connection, decoder, &testReceiverStateDispatch(m_swiftStateDispatch, *this), &WebKit::TestReceiverStateDispatch::dispatchStateMessage);', handler)
        self.assertIn('IPC::handleSwiftMessage<Messages::TestReceiver::ReceiverMessage>(connection, decoder, this, &SwiftDispatch::TestReceiver::dispatchReceiverMessage);', handler)
        swift = messages.generate_swift_message_handler(receiver)
        self.assertIn('extension SwiftDispatch.TestReceiver {\n    @cxx\n    @implementation\n    static func dispatchReceiverMessage(\n', swift)
        self.assertIn('@_expose(Cxx)\nfinal class TestReceiverStateDispatch {\n    private let target: TestState\n', swift)
        self.assertIn('        TestReceiverStateDispatch(target: receiver.state)\n', swift)
        state_dispatch = re.search(r'func dispatchStateMessage\((.|\n)*?\n    \}\n', swift).group(0)
        self.assertIn('        decoder: inout IPC.SwiftDecoder\n', state_dispatch)
        self.assertNotIn('var decoder = decoder', state_dispatch)
        self.assertIn('target.stateMessage(', state_dispatch)

        # With every message going to the state, there is no @cxx @implementation dispatch.
        receiver = parse('    StateMessage(uint32_t value)', receiver_attributes='Stream')
        self.assertNotIn('SwiftDispatch', messages.generate_messages_header(receiver))
        swift = messages.generate_swift_message_handler(receiver)
        self.assertNotIn('extension SwiftDispatch', swift)
        self.assertIn('    func dispatchStateMessage(\n        decoder: inout IPC.SwiftDecoder\n    ) -> Bool {\n', swift)

        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver has 'SwiftState=', which is for stream and WorkQueue receivers with 'SwiftImplementation'"):
            parse('    StateMessage(uint32_t value)', receiver_attributes='')
        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver has 'SwiftState=', which is for stream and WorkQueue receivers with 'SwiftImplementation'"):
            parse('    StateMessage(uint32_t value)', attributes=('SwiftReceiver', 'SwiftTypes', 'SwiftState=TestState'))
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'WantsReceiver', which is for messages that take Swift types to receivers with 'SwiftState='"):
            parse('    Message(uint32_t value) WantsReceiver', attributes=('SwiftImplementation', 'SwiftTypes'))
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'WantsReceiver', which is for messages that take Swift types to receivers with 'SwiftState='"):
            parse('    Message(uint32_t value) WantsReceiver CxxTypes')

    def test_swift_types_and_wants_dispatch_message(self):
        def parse(attributes, receiver_attributes):
            return parser.parse(io.StringIO("""
[
    ExceptionForEnabledBy,
    ExceptionForDispatchedFrom,
    ExceptionForDispatchedTo,
    %s
]
messages -> TestReceiver %s {
    SwiftMessage(uint32_t value) SwiftTypes
}
""" % (',\n    '.join(attributes), receiver_attributes)))

        # A C++ receiver that Swift implements handles the messages that take Swift types before it dispatches the rest.
        handler = messages.generate_message_handler(parse(['SwiftImplementation'], 'WantsDispatchMessage'))
        self.assertIn('IPC::handleSwiftMessage<Messages::TestReceiver::SwiftMessage>(connection, decoder, this, &SwiftDispatch::TestReceiver::dispatchSwiftMessage);\n        return;\n    }\n    if (dispatchMessage(connection, decoder))\n', handler)
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.SwiftMessage takes Swift types, which is not supported on a receiver with 'WantsDispatchMessage'"):
            parse(['SwiftReceiver'], 'WantsDispatchMessage')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.SwiftMessage takes Swift types, which is not supported on a receiver with 'WantsAsyncDispatchMessage'"):
            parse(['SwiftImplementation'], 'WantsAsyncDispatchMessage')

    def test_cxx_decoded_arguments(self):
        receiver = parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], """
    Message(uint32_t value, [CxxDecoded] WebKit::NoSwiftForm argument)
""")
        self.assertIn('using MessageArgument = IPC::CxxDecodedArgument<WebKit::NoSwiftForm>;', messages.generate_messages_header(receiver))
        self.assertIn('guard let decodedArgument = CxxDecodedArguments.TestReceiver.MessageArgument.decode(&decoder) else {', messages.generate_swift_message_handler(receiver))

        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message takes Swift types, which is not supported with attributes on reply parameter 'reply': CxxDecoded"):
            parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], '    Message(uint32_t value) -> ([CxxDecoded] WebKit::NoSwiftForm reply)')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'CxxDecoded' on parameter 'argument', which is only for messages that take Swift types"):
            parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], '    Message([CxxDecoded] WebKit::NoSwiftForm argument) CxxTypes')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'CxxDecoded' on parameter 'argument', which is only for messages that take Swift types"):
            parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver'], '    Message([CxxDecoded] WebKit::NoSwiftForm argument)')
        for argument_type in ['std::span<const uint8_t>', 'std::optional<std::span<const float, 4>>', 'Vector<std::span<const uint8_t>>', 'IPC::ArrayReferenceTuple<float, double>', 'StringView', 'WTF::StringView', 'std::string_view']:
            with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'CxxDecoded' on parameter 'argument', which is only for types that own their storage"):
                parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], '    Message([CxxDecoded] %s argument)' % argument_type)
        parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], '    Message([CxxDecoded] WebKit::MutableSpanHolder argument)')

    def test_swift_sends(self):
        sender = parser.parse(io.StringIO("""
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftReceiver, SwiftSends=Destination]
messages -> Sender WorkQueue {
    Message(uint32_t value)
}
"""))
        destination = parser.parse(io.StringIO("""
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy]
messages -> Destination {
    Notify(uint32_t value, String text)
#if PLATFORM(COCOA)
    TakeSemaphore(IPC::Semaphore semaphore)
#endif
    WithReply(uint32_t value) -> (bool done)
    Unmappable(URL url)
    WithoutSwiftForm(WebKit::NoSwiftForm value) SentFromCxx
}
"""))
        parser.resolve_swift_sends([sender, destination])
        swift = messages.generate_swift_message_handler(sender)
        senders = swift[swift.index('extension Sender {'):]
        self.assertIn('    enum DestinationMessages {\n', senders)
        self.assertIn('        static func notify(on ipcConnection: IPC.Connection, to ipcDestinationID: UInt64, value: UInt32, text: String?) {\n'
                      '            let ipcEncoder = IPC.SwiftReplyEncoder.createForMessage(ipcConnection, .Destination_Notify, ipcDestinationID)\n'
                      '            UInt32.encode(value, to: ipcEncoder)\n'
                      '            IPCCoding.WTFString.encode(text, to: ipcEncoder)\n'
                      '            ipcEncoder.send()\n', senders)
        self.assertIn('        #if WTF_PLATFORM_COCOA\n        static func takeSemaphore(on ipcConnection: IPC.Connection, to ipcDestinationID: UInt64, semaphore: consuming IPCTypes.Semaphore) {\n', senders)
        # Swift sends only messages without replies, whose arguments have Swift forms.
        self.assertNotIn('withReply', senders)
        self.assertNotIn('unmappable', senders)
        self.assertNotIn('withoutSwiftForm', senders)

        with self.assertRaisesRegex(Exception, r"ERROR: Receiver Sender has 'SwiftSends=Missing', which is not one of the receivers generated with it"):
            parser.resolve_swift_sends([parser.parse(io.StringIO('[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftReceiver, SwiftSends=Missing]\nmessages -> Sender WorkQueue {\n    Message(uint32_t value)\n}\n'))])
        implementation = parser.parse(io.StringIO("""
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftImplementation, SwiftTypes, SwiftSends=Destination]
messages -> Implemented {
    Message(uint32_t value)
}
"""))
        parser.resolve_swift_sends([implementation, destination])
        swift = messages.generate_swift_message_handler(implementation)
        senders = swift[swift.index('extension WebKit.Implemented {\n    // The Destination messages'):]
        self.assertIn('        static func notify(on ipcConnection: IPC.Connection, to ipcDestinationID: UInt64, value: UInt32, text: String?) {\n', senders)

        with self.assertRaisesRegex(Exception, r"ERROR: Receiver Sender has 'SwiftSends=', which is for Swift receivers and receivers implemented in Swift"):
            parser.resolve_swift_sends([parser.parse(io.StringIO('[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftSends=Destination]\nmessages -> Sender {\n    Message(uint32_t value)\n}\n')), destination])

    def test_swift_receiver_owner(self):
        receiver = parser.parse(io.StringIO("""
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftReceiver, SwiftTypes, SwiftReceiverOwner, SwiftSends=Destination]
messages -> Owned Stream {
    Message(uint32_t value)
}
"""))
        destination = parser.parse(io.StringIO("""
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy]
messages -> Destination {
    Notify(uint32_t value)
}
"""))
        parser.resolve_swift_sends([receiver, destination])
        header = messages.generate_messages_header(receiver)
        self.assertIn('#include "SwiftReceiverOwner.h"\n', header)
        self.assertIn('class OwnedMessageForwarder final : public IPC::StreamMessageReceiver, public IPC::SwiftReceiverOwnerClient {\n', header)
        self.assertIn('    void runScheduledWork() final;\n    void didStopReceiving() final;\n    void didStopWorkQueue() final;\n', header)
        implementation = messages.generate_message_handler(receiver)
        self.assertIn('void OwnedMessageForwarder::runScheduledWork()\n{\n    m_handler->runScheduledWork();\n}\n', implementation)
        self.assertIn('void OwnedMessageForwarder::didStopWorkQueue()\n{\n    m_handler->didStopWorkQueue();\n}\n', implementation)
        swift = messages.generate_swift_message_handler(receiver)
        self.assertIn('    @used\n    func didStopReceiving() {\n        target.didStopReceiving()\n    }\n', swift)
        self.assertIn('extension Owned {\n', swift)
        self.assertIn('    func startReceiving(on owner: IPC.SwiftReceiverOwner) {\n'
                      '        IPC.startSwiftReceiver(owner, WebKit.OwnedMessageForwarder.create(target: self))\n'
                      '    }\n', swift)
        self.assertIn('        static func notify(on owner: IPC.SwiftReceiverOwner, to ipcDestinationID: UInt64, value: UInt32) {\n'
                      '            notify(on: owner.connection(), to: ipcDestinationID, value: value)\n'
                      '        }\n', swift)

        provided = parser.parse(io.StringIO('[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftReceiver, SwiftTypes, SwiftReceiverOwner=OwnedResources]\nmessages -> Owned Stream {\n    Message(uint32_t value)\n}\n'))
        self.assertTrue(provided.has_swift_receiver_owner())
        self.assertIn('class OwnedMessageForwarder final : public IPC::StreamMessageReceiver, public IPC::SwiftReceiverOwnerClient {\n', messages.generate_messages_header(provided))
        self.assertIn('    func startReceiving(on provider: WebKit.OwnedResources) {\n'
                      '        IPC.startSwiftReceiver(provider, WebKit.OwnedMessageForwarder.create(target: self))\n'
                      '    }\n', messages.generate_swift_message_handler(provided))

        for attributes, kind in ((['SwiftReceiver', 'SwiftReceiverOwner'], ''), (['SwiftImplementation', 'SwiftTypes', 'SwiftReceiverOwner'], ' Stream'), (['SwiftReceiver', 'SwiftReceiverOwner'], ' WorkQueue')):
            with self.assertRaisesRegex(Exception, r"ERROR: Receiver Owned has 'SwiftReceiverOwner', which is for Swift stream receivers without a state lender"):
                parser.parse(io.StringIO('[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, %s]\nmessages -> Owned%s {\n    Message(uint32_t value)\n}\n' % (', '.join(attributes), kind)))

    def test_owned_types(self):
        stream_receiver = parser.parse(io.StringIO("""
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftReceiver, SwiftTypes]
messages -> TestReceiver Stream {
    Message(uint32_t value, IPC::Semaphore semaphore) NotStreamEncodable
    SyncMessage(MachSendRight right) -> (Vector<MachSendRight> rights) Synchronous NotStreamEncodable NotStreamEncodableReply SwiftReplyValue
}
"""))
        swift = messages.generate_swift_message_handler(stream_receiver)
        dispatch = re.search(r'func dispatchMessage\((.|\n)*?\n    \}\n', swift).group(0)
        # Each argument decodes in a block of its own, so no path out of a block leaves the ~Copyable value half there.
        self.assertIn('        do {\n            value = try UInt32.decode(from: &decoder)\n        } catch {\n            return false\n        }\n', dispatch)
        self.assertIn('        do {\n            semaphore = try IPCTypes.Semaphore.decode(from: &decoder)\n        } catch {\n            return false\n        }\n', dispatch)
        self.assertIn('consuming func send(_ reply: consuming IPCTypes.MachSendRightVector) {', swift)
        self.assertIn('IPCTypes.MachSendRightVector.encode(reply, to: replyEncoder)', swift)

        def parse_stream_receiver(message):
            return parser.parse(io.StringIO('[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftReceiver, SwiftTypes]\nmessages -> TestReceiver Stream {\n%s\n}\n' % message))

        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message takes Swift types, and the Swift form of 'semaphore' owns what the message carries, so its handler must be called during dispatch"):
            parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], '    Message(IPC::Semaphore semaphore)')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message takes Swift types, and its Synchronous reply carries an owned type, which can't be encoded twice, so it must be 'NotStreamEncodableReply'"):
            parse_stream_receiver('    Message() -> (MachSendRight right) Synchronous')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message takes Swift types, which is not supported with a reply of more than one value that includes an owned type"):
            parse_stream_receiver('    Message() -> (MachSendRight right, uint32_t value) Synchronous NotStreamEncodableReply')
        with self.assertRaisesRegex(Exception, r"cannot take parameter 'semaphores': 'Vector<IPC::Semaphore>' has no Swift form"):
            parse_stream_receiver('    Message(Vector<IPC::Semaphore> semaphores) NotStreamEncodable')

    def test_lent_bytes(self):
        stream_receiver = parser.parse(io.StringIO("""
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftReceiver, SwiftTypes]
messages -> TestReceiver Stream {
    Message(uint32_t value, [Lent] std::span<const uint8_t> bytes, uint64_t tail)
    CopiedMessage(std::span<const uint8_t> bytes)
}
"""))
        swift = messages.generate_swift_message_handler(stream_receiver)
        dispatch = re.search(r'func dispatchMessage\((.|\n)*?\n    \}\n', swift).group(0)
        self.assertIn('        var bytesPosition = IPC.LentBytesPosition()\n', dispatch)
        self.assertRegex(dispatch, r'value = try UInt32.decode\(from: &decoder\)\n            guard decoder.decodeLentBytesPosition\(&bytesPosition\) else \{\n                return false\n            \}\n            tail = try UInt64.decode\(from: &decoder\)\n')
        self.assertRegex(dispatch, r'\n        let bytes = decoder.lentBytes\(bytesPosition\)\n        do throws\(InvalidMessage\) \{\n')
        self.assertIn('bytes: bytes,', dispatch)
        # Without [Lent], a span of bytes is still a copy.
        self.assertIn('bytes = try IPCCoding.Vector<UInt8>.decode(from: &decoder)', re.search(r'func dispatchCopiedMessage\((.|\n)*?\n    \}\n', swift).group(0))

        # A SwiftSyncHandler handler is called inside assumeIsolated, so the bytes are lent there.
        receiver = parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], """
    Message([Lent] std::span<const uint8_t> bytes) SwiftSyncHandler
""")
        dispatch = re.search(r'func dispatchMessage\((.|\n)*?\n    \}\n', messages.generate_swift_message_handler(receiver)).group(0)
        self.assertNotIn('do {', dispatch.split('MainActor.assumeIsolated')[0])
        self.assertRegex(dispatch, r'guard let target else \{\n                return\n            \}\n            let bytes = decoder.lentBytes\(bytesPosition\)\n')

        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'Lent' on parameter 'bytes', whose bytes are lent to its Swift handler during dispatch, so the handler must be called then: on a stream or WorkQueue, or with 'SwiftSyncHandler'"):
            parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], '    Message([Lent] std::span<const uint8_t> bytes)')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'Lent' on parameter 'values', which is only for a std::span<const uint8_t>"):
            parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], '    Message([Lent] std::span<const uint32_t> values) SwiftSyncHandler')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'Lent' on parameter 'bytes', which is only for messages that take Swift types"):
            parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver'], '    Message([Lent] std::span<const uint8_t> bytes)')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message takes Swift types, which is not supported with attributes on reply parameter 'reply': Lent"):
            parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], '    Message() -> ([Lent] std::span<const uint8_t> reply) SwiftSyncHandler')

    def test_lent_cxx_typed_arguments(self):
        def parse_stream_receiver(messages_text):
            return parser.parse(io.StringIO("""
[
    ExceptionForEnabledBy,
    ExceptionForDispatchedFrom,
    ExceptionForDispatchedTo,
    SwiftReceiver
]
messages -> TestReceiver Stream {
%s
}
""" % messages_text))

        # A C++-typed argument that refers into the message is borrowed by a handler called during dispatch.
        receiver = parse_stream_receiver('    Message([Lent] WebCore::PixelBufferSourceView view, WebKit::TestStruct value)')
        dispatch = re.search(r'func dispatchMessage\((.|\n)*?\n    \}\n', messages.generate_swift_message_handler(receiver)).group(0)
        self.assertIn('view: borrowing WebCore.PixelBufferSourceView,', dispatch)
        self.assertIn('value: sending WebKit.TestStruct', dispatch)

        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'Lent' on parameter 'view', which is only for messages that take Swift types"):
            parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver'], '    Message([Lent] WebCore::PixelBufferSourceView view)')
        # Only a listed non-escapable view can be lent: Swift could keep any other type.
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'Lent' on parameter 'view', whose type 'WebKit::TestView' isn't one of the non-escapable views in swift_types.LENT_CXX_VIEW_TYPES"):
            parse_stream_receiver('    Message([Lent] WebKit::TestView view)')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'Lent' on parameter 'bytes', whose type 'std::span<const uint8_t>' isn't one of the non-escapable views in swift_types.LENT_CXX_VIEW_TYPES"):
            parse_stream_receiver('    Message([Lent] std::span<const uint8_t> bytes)')

    def test_cxx_typed_replies(self):
        receiver = parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftTypes'], """
    PrimitiveReply(Ref<WebKit::FrameState> frameState) -> (uint8_t reply) CxxTypes
    EnumReply(Ref<WebKit::FrameState> frameState) -> (enum:bool WebKit::TestEnum reply) CxxTypes
    StructReply(Ref<WebKit::FrameState> frameState) -> (WebKit::TestStruct reply) CxxTypes
""")
        swift = messages.generate_swift_message_handler(receiver)
        self.assertIn('CompletionHandlers.TestReceiver.complete(completionHandler, reply)', swift)
        self.assertRegex(swift, r'EnumReplyInvocation \{(.|\n)*?\n                completionHandler\.pointee\(reply\)\n')
        self.assertRegex(swift, r'StructReplyInvocation \{(.|\n)*?\n                completionHandler\.pointee\(consuming: reply\)\n')

    def test_async_cxx_encoded_replies(self):
        def parse_receiver(attributes, kind, messages_text):
            return parser.parse(io.StringIO('[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, %s]\nmessages -> TestReceiver%s {\n%s\n}\n' % (', '.join(attributes), kind, messages_text)))

        message = '    Message(uint32_t value) -> (std::optional<WebKit::ImageBufferBackendHandle> handle, uint64_t identifier) CxxEncodedReply'
        for attributes, kind, target in ((['SwiftReceiver', 'SwiftTypes'], ' Stream', 'm_handler.get(), &TestReceiverWeakRef::dispatchMessage'), (['SwiftReceiver', 'SwiftTypes'], ' WorkQueue', 'm_handler.get(), &TestReceiverWeakRef::dispatchMessage'), (['SwiftReceiver', 'SwiftTypes'], '', 'm_handler.get(), &TestReceiverWeakRef::dispatchMessage'), (['SwiftImplementation', 'SwiftTypes'], ' Stream', 'this, &SwiftDispatch::TestReceiver::dispatchMessage')):
            receiver = parse_receiver(attributes, kind, message)
            # The reply goes out of the stream as any asynchronous reply does, through the reply encoder that C++ encodes into.
            self.assertIn('IPC::handleSwiftMessageAsync<Messages::TestReceiver::Message>(connection, decoder, %s);\n' % target, messages.generate_message_handler(receiver))
            swift = messages.generate_swift_message_handler(receiver)
            self.assertIn('reply: TestReceiverMessageReply(replyEncoder: replyEncoder)', swift)
            self.assertIn('    consuming func send(encodedBy encode: (IPC.SwiftReplyEncoder) -> Void) {\n        encode(replyEncoder)\n        replyEncoder.send()\n    }\n', swift)
            self.assertIn('    deinit {\n        replyEncoder.cancel()\n    }\n', swift)

        # A Synchronous reply that C++ encodes is still given as a value, with the dispatch that sends it out of the stream.
        synchronous = parse_receiver(['SwiftReceiver', 'SwiftTypes'], ' Stream', '    Message(uint32_t value) -> (MachSendRight right) Synchronous NotStreamEncodableReply CxxEncodedReply')
        self.assertIn('IPC::handleSwiftMessageSynchronousWithReplyValue<Messages::TestReceiver::Message>', messages.generate_message_handler(synchronous))

        error = r"ERROR: Message TestReceiver.Message has 'CxxEncodedReply', which is for messages with a reply that take Swift types: asynchronous ones, Synchronous ones to a WorkQueue receiver, or Synchronous ones with 'NotStreamEncodableReply' to a stream receiver"
        with self.assertRaisesRegex(Exception, error):
            parse_receiver(['SwiftReceiver', 'SwiftTypes'], ' Stream', '    Message(uint32_t value) CxxEncodedReply')
        with self.assertRaisesRegex(Exception, error):
            parse_receiver(['SwiftReceiver', 'SwiftTypes'], ' Stream', '    Message(uint32_t value) -> () CxxEncodedReply')
        with self.assertRaisesRegex(Exception, error):
            parse_receiver(['SwiftReceiver'], ' Stream', '    Message(uint32_t value) -> (uint32_t reply) CxxEncodedReply')
        with self.assertRaisesRegex(Exception, error):
            parse_receiver(['SwiftReceiver', 'SwiftTypes'], ' Stream', '    Message(uint32_t value) -> (uint32_t reply) Synchronous CxxEncodedReply')
        # A WorkQueue receiver's Synchronous reply that C++ encodes is given as a value too, through the reply encoder of the
        # Connection's synchronous dispatch, which the handler sends before it returns.
        for attributes, target in ((['SwiftReceiver', 'SwiftTypes'], 'm_handler.get(), &TestReceiverWeakRef::dispatchMessage'), (['SwiftImplementation', 'SwiftTypes'], 'this, &SwiftDispatch::TestReceiver::dispatchMessage')):
            work_queue_synchronous = parse_receiver(attributes, ' WorkQueue', '    Message(uint32_t value) -> (uint32_t reply) Synchronous CxxEncodedReply')
            self.assertIn('IPC::handleSwiftMessageSynchronous<Messages::TestReceiver::Message>(connection, decoder, replyEncoder, %s);\n' % target, messages.generate_message_handler(work_queue_synchronous))
            self.assertNotIn('handleSwiftMessageSynchronousWithReplyValue', messages.generate_message_handler(work_queue_synchronous))
            self.assertIn('reply: TestReceiverMessageReply(replyEncoder: replyEncoder)', messages.generate_swift_message_handler(work_queue_synchronous))
        # SwiftReplyValue stays Synchronous-only.
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'SwiftReplyValue', which is for Synchronous messages with 'NotStreamEncodableReply' to a stream receiver that takes Swift types"):
            parse_receiver(['SwiftReceiver', 'SwiftTypes'], ' Stream', '    Message(uint32_t value) -> (uint32_t reply) SwiftReplyValue')

    def test_conditional_completion_handlers(self):
        receiver = parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver'], """
    Always(uint32_t value) -> (uint8_t reply)
#if PLATFORM(COCOA)
    CocoaOnly(uint32_t value) -> (uint64_t reply)
    CocoaShared(uint32_t value) -> (uint8_t reply)
#endif
""")
        header = messages.generate_messages_header(receiver)
        # A conditional message's completion handler exists only where the message does.
        self.assertIn('#if PLATFORM(COCOA)\nusing CocoaOnlyCompletionHandler = ', header)
        self.assertIn('#if PLATFORM(COCOA)\nvoid completeWithDefaultReply(CocoaOnlyCompletionHandler&);\n#endif\n', header)
        # The declaration that messages with the same reply types share exists if any of them does.
        self.assertIn('\nvoid completeWithDefaultReply(AlwaysCompletionHandler&);\n', header)
        self.assertNotIn('#if PLATFORM(COCOA)\nvoid completeWithDefaultReply(AlwaysCompletionHandler&);', header)
        implementation = messages.generate_message_handler(receiver)
        self.assertIn('#if PLATFORM(COCOA)\nvoid completeWithDefaultReply(CocoaOnlyCompletionHandler& completionHandler)\n', implementation)

        # A conditional message first, then an unconditional one with the same reply types: the shared declaration names the
        # unconditional one's handler, under no condition.
        receiver = parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver'], """
#if PLATFORM(COCOA)
    CocoaFirst(uint32_t value) -> (uint16_t reply)
#endif
    AlwaysLater(uint32_t value) -> (uint16_t reply)
""")
        header = messages.generate_messages_header(receiver)
        self.assertIn('\nvoid completeWithDefaultReply(AlwaysLaterCompletionHandler&);\n', header)
        self.assertNotIn('void completeWithDefaultReply(CocoaFirstCompletionHandler&);', header)
        self.assertIn('\nvoid complete(AlwaysLaterCompletionHandler&, uint16_t);\n', header)
        implementation = messages.generate_message_handler(receiver)
        self.assertIn('\nvoid completeWithDefaultReply(AlwaysLaterCompletionHandler& completionHandler)\n', implementation)
        self.assertNotIn('completeWithDefaultReply(CocoaFirstCompletionHandler& completionHandler)', implementation)

        # Messages with the same reply types under two conditions: each branch names its own message's handler.
        receiver = parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver'], """
#if PLATFORM(COCOA)
    CocoaMessage(uint32_t value) -> (uint16_t reply)
#endif
#if PLATFORM(GTK)
    GTKMessage(uint32_t value) -> (uint16_t reply)
#endif
""")
        header = messages.generate_messages_header(receiver)
        self.assertIn('#if PLATFORM(COCOA)\nvoid completeWithDefaultReply(CocoaMessageCompletionHandler&);\n#elif PLATFORM(GTK)\nvoid completeWithDefaultReply(GTKMessageCompletionHandler&);\n#endif\n', header)
        implementation = messages.generate_message_handler(receiver)
        self.assertIn('#if PLATFORM(COCOA)\nvoid completeWithDefaultReply(CocoaMessageCompletionHandler& completionHandler)\n', implementation)
        self.assertIn('#elif PLATFORM(GTK)\nvoid completeWithDefaultReply(GTKMessageCompletionHandler& completionHandler)\n', implementation)

    def test_swift_destination_id(self):
        def parse_receiver(attributes, kind, messages_text):
            return parser.parse(io.StringIO('[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, %s]\nmessages -> TestReceiver%s {\n%s\n}\n' % (', '.join(attributes), kind, messages_text)))

        receiver = parse_receiver(['SwiftReceiver', 'SwiftTypes', 'SwiftDestinationID'], ' WorkQueue', '    Message(uint32_t value)')
        swift = messages.generate_swift_message_handler(receiver)
        # The destination ID is read before the handler call, which may be in a closure the decoder can't be sent into.
        self.assertIn('        let destinationID = decoder.destinationID()\n', swift)
        self.assertIn('destinationID: destinationID', swift)
        self.assertLess(swift.index('let destinationID = decoder.destinationID()'), swift.index('destinationID: destinationID'))

        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver has 'SwiftDestinationID', which is for Swift receivers with 'WorkQueue'"):
            parse_receiver(['SwiftReceiver', 'SwiftTypes', 'SwiftDestinationID'], ' Stream', '    Message(uint32_t value)')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has a parameter named 'destinationID'"):
            parse_receiver(['SwiftReceiver', 'SwiftTypes', 'SwiftDestinationID'], ' WorkQueue', '    Message(uint64_t destinationID)')

    def test_lent_state_constraints(self):
        stream_receiver = """
[
    ExceptionForEnabledBy,
    ExceptionForDispatchedFrom,
    ExceptionForDispatchedTo,
    %s
]
messages -> TestReceiver Stream {
%s
}
"""

        def parse(attributes, messages_text):
            return parser.parse(io.StringIO(stream_receiver % (',\n    '.join(attributes), messages_text)))

        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'SwiftMayDecline', which is for receivers with 'SwiftReceiverStateLender='"):
            parse(['SwiftReceiver'], '    Message(uint32_t value) SwiftMayDecline')
        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver has 'SwiftReceiverStateLender=WebKit::Lender', which is for Swift stream receivers"):
            parse_swift_receiver(['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(uint32_t value)')
        receiver = parse(['SwiftReceiver', 'SwiftTypes', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(uint32_t value)')
        self.assertTrue(receiver.takes_swift_types(receiver.messages[0]))
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message takes Swift types, so cannot have 'SwiftMayDecline'"):
            parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(uint32_t value) SwiftMayDecline SwiftTypes')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message takes Swift types, which is not supported with attributes on parameter 'buffer' on a receiver with 'SwiftReceiverStateLender='"):
            parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message([CxxDecoded] Ref<WebCore::SharedBuffer> buffer) SwiftTypes')
        receiver = parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(MachSendRight right) SwiftTypes')
        self.assertTrue(receiver.takes_swift_types(receiver.messages[0]))
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message takes Swift types, and the Swift form of 'right' owns what the message carries, so a recording can't keep it: it must be 'NotRecorded'"):
            parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender', 'Recordable'], '    Message(MachSendRight right) SwiftTypes')
        receiver = parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender', 'Recordable'], '    Message(MachSendRight right) NotRecorded SwiftTypes')
        self.assertTrue(receiver.takes_swift_types(receiver.messages[0]))
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has a reply, which is not supported on a receiver with 'SwiftReceiverStateLender='"):
            parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(uint32_t value) -> (uint32_t reply)')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has a parameter named 'state'"):
            parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(uint32_t state)')
        receiver = parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(WebCore::Path path) SwiftTypes SwiftDecodeContext=pathDecodeContext')
        self.assertEqual(receiver.messages[0].swift_decode_context(), 'pathDecodeContext')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'SwiftDecodeContext=', but none of its parameters has a Swift coder that takes a decoding context"):
            parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(uint32_t value) SwiftTypes SwiftDecodeContext=valueDecodeContext')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'SwiftDecodeContext=', which is for messages that take Swift types"):
            parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(WebCore::Path path) SwiftDecodeContext=pathDecodeContext')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'SwiftDecodeContext=', which is for receivers with 'SwiftReceiverStateLender='"):
            parse(['SwiftReceiver', 'SwiftTypes'], '    Message(WebCore::Path path) SwiftDecodeContext=pathDecodeContext')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message takes Swift types, so cannot have a parameter named 'decodeContext'"):
            parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(uint32_t decodeContext) SwiftTypes')

    def test_recordable_constraints(self):
        stream_receiver = """
[
    ExceptionForDispatchedFrom,
    ExceptionForDispatchedTo,
    %s
]
messages -> TestReceiver Stream {
%s
}
"""

        def parse(attributes, messages_text):
            return parser.parse(io.StringIO(stream_receiver % (',\n    '.join(attributes), messages_text)))

        lent = ['ExceptionForEnabledBy', 'SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender']
        receiver = parse(lent + ['Recordable'], '    Message([RecordedAs=WebKit::RecordedRun] WebKit::Run run)')
        self.assertTrue(receiver.is_recordable())
        self.assertEqual(receiver.messages[0].parameters[0].recorded_as_type(), 'WebKit::RecordedRun')
        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver has 'Recordable', which is for Swift stream receivers with 'SwiftReceiverStateLender='"):
            parse(['ExceptionForEnabledBy', 'SwiftReceiver', 'Recordable'], '    Message(uint32_t value)')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'SwiftMayDecline', which is not supported on a receiver with 'Recordable'"):
            parse(lent + ['Recordable'], '    Message(uint32_t value) SwiftMayDecline')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'Validator=ValidateFunction', which is not supported on a receiver with 'Recordable'"):
            parse(lent + ['Recordable'], '    [Validator=ValidateFunction] Message(uint32_t value)')
        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver has 'Recordable', which is not supported together with 'EnabledBy='"):
            parse(['EnabledBy=SomeFeature', 'SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender', 'Recordable'], '    Message(uint32_t value)')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'RecordedAs=' on parameter 'run', which is for receivers with 'Recordable'"):
            parse(lent, '    Message([RecordedAs=WebKit::RecordedRun] WebKit::Run run)')
        receiver = parse(lent + ['Recordable'], '    Message(uint32_t value) NotRecorded')
        self.assertTrue(receiver.messages[0].has_attribute('NotRecorded'))
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has 'NotRecorded', which is for receivers with 'Recordable'"):
            parse(lent, '    Message(uint32_t value) NotRecorded')


class MessagesFromTest(unittest.TestCase):
    source = """
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy]
messages -> SourceReceiver Stream {
    First(uint32_t value) StreamBatched
#if USE(CG)
    Second(WebCore::FloatRect rect) StreamBatched
#endif
    WithReply(uint32_t value) -> (uint32_t reply)
}
"""
    taker = """
[ExceptionForDispatchedFrom, ExceptionForDispatchedTo, ExceptionForEnabledBy, SwiftReceiver, SwiftReceiverStateLender=WebKit::Lender%s]
messages -> TestReceiver Stream {
%s
}
"""

    def parse(self, text):
        return parser.parse(io.StringIO(text))

    def test_named_messages_take_the_definitions(self):
        source = self.parse(self.source)
        taker = self.parse(self.taker % (', MessagesFrom=SourceReceiver', """
    First
#if PLATFORM(COCOA)
    Second SwiftMayDecline
#endif
    Own(float value)
"""))
        written = self.parse(self.taker % ('', """
    First(uint32_t value) StreamBatched
#if PLATFORM(COCOA)
#if USE(CG)
    Second(WebCore::FloatRect rect) StreamBatched SwiftMayDecline
#endif
#endif
    Own(float value)
"""))
        parser.resolve_message_references([taker, source])
        self.assertEqual([message.name for message in taker.messages], ['First', 'Second', 'Own'])
        for generate in (messages.generate_messages_header, messages.generate_message_handler, messages.generate_swift_message_handler):
            self.assertEqual(generate(taker), generate(written))
        self.assertEqual([message.name for message in source.messages], ['First', 'Second', 'WithReply'])
        self.assertFalse(source.messages[1].has_attribute('SwiftMayDecline'))

    def test_attribute_lines_are_not_messages(self):
        source = self.parse(self.source)
        taker = self.parse("""
[
    ExceptionForDispatchedFrom,
    ExceptionForDispatchedTo,
    ExceptionForEnabledBy,
    SwiftReceiver,
    SwiftReceiverStateLender=WebKit::Lender,
    MessagesFrom=SourceReceiver,
    Recordable
]
messages -> TestReceiver Stream {
    First
}
""")
        parser.resolve_message_references([taker, source])
        self.assertTrue(taker.is_recordable())
        self.assertEqual([message.name for message in taker.messages], ['First'])

    def test_errors(self):
        source = self.parse(self.source)
        taker = self.parse(self.taker % (', MessagesFrom=SourceReceiver', '    Missing'))
        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver takes message Missing from SourceReceiver, which has no such message"):
            parser.resolve_message_references([taker, source])
        taker = self.parse(self.taker % (', MessagesFrom=OtherReceiver', '    First'))
        with self.assertRaisesRegex(Exception, r"ERROR: Receiver TestReceiver has 'MessagesFrom=OtherReceiver', which is not one of the receivers generated with it"):
            parser.resolve_message_references([taker, source])
        # A message taken by name meets the constraints of the receiver that takes it.
        taker = self.parse(self.taker % (', MessagesFrom=SourceReceiver', '    WithReply'))
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.WithReply has a reply, which is not supported on a receiver with 'SwiftReceiverStateLender='"):
            parser.resolve_message_references([taker, source])


def parse_sys_argv():
    global reset_results
    for index, arg in enumerate(sys.argv[1:]):
        if arg in ('-r', '--r', '--reset', '--reset-results') or '--reset-results'.startswith(arg):
            reset_results = True
            del sys.argv[index + 1]
            break

    for index, arg in enumerate(sys.argv[1:]):
        if arg in ('-h', '--h', '--help') or '--help'.startswith(arg):
            print('''
Custom Options:
  -r, --reset-results  Reset expected results for {script_name}
'''.format(script_name=os.path.basename(__file__)))
            break


if __name__ == '__main__':
    parse_sys_argv()
    unittest.main()
