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
    'TestWithStreamSwiftLentState',
    'TestWithStreamSwiftTypes',
    'TestWithSuperclass',
    'TestWithSuperclassAndWantsAsyncDispatch',
    'TestWithSuperclassAndWantsDispatch',
    'TestWithSwift',
    'TestWithSwiftConditionally',
    'TestWithSwiftConditionallyAndEnabledBy',
    'TestWithSwiftTypes',
    'TestWithSwiftTypesOptIn',
    'TestWithSwiftWorkQueue',
    'TestWithValidator',
    'TestWithWantsAsyncDispatch',
    'TestWithWantsDispatch',
    'TestWithWantsDispatchNoSyncMessages',
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
            if receiver.swift_receiver or receiver.swift_receiver_build_enabled_by:
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
