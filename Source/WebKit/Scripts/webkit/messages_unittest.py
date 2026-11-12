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
    'TestWithStreamSwiftReplyValues',
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
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message takes Swift types, which is not supported on a receiver with 'SwiftReceiverStateLender='"):
            parse(['SwiftReceiver', 'SwiftTypes', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(uint32_t value)')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has a reply, which is not supported on a receiver with 'SwiftReceiverStateLender='"):
            parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(uint32_t value) -> (uint32_t reply)')
        with self.assertRaisesRegex(Exception, r"ERROR: Message TestReceiver.Message has a parameter named 'state'"):
            parse(['SwiftReceiver', 'SwiftReceiverStateLender=WebKit::Lender'], '    Message(uint32_t state)')


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
