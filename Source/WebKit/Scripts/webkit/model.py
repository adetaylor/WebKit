# Copyright (C) 2010-2025 Apple Inc. All rights reserved.
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

import itertools
import re

from collections import Counter, defaultdict
from .opaque_ipc_types import is_opaque_type, opaque_ipc_types
from .swift_types import UnmappableSwiftType, is_lent_bytes, is_lent_cxx_view, is_owned_type, strip_cpp_type_decorations, swift_type_and_coder, takes_decode_context
from .untrusted_origins import conveys_untrusted_value, is_privileged_receiver, unwrap_if_untrusted, unwrap_untrusted

BUILTIN_ATTRIBUTE = "Builtin"
MAINTHREADCALLBACK_ATTRIBUTE = "MainThreadCallback"
ANYTHREADCALLBACK_ATTRIBUTE = "AnyThread"
CALL_WITH_REPLY_ID_ATTRIBUTE = "CallWithReplyID"
ALLOWEDWHENWAITINGFORSYNCREPLY_ATTRIBUTE = "AllowedWhenWaitingForSyncReply"
ALLOWEDWHENWAITINGFORSYNCREPLYDURINGUNBOUNDEDIPC_ATTRIBUTE = "AllowedWhenWaitingForSyncReplyDuringUnboundedIPC"
SYNCHRONOUS_ATTRIBUTE = 'Synchronous'
STREAM_ATTRIBUTE = "Stream"
# On a Swift receiver whose host registers it with addWorkQueueMessageReceiver(): its generated forwarder is a
# WorkQueueMessageReceiver, and its handlers are called synchronously on that work queue.
WORK_QUEUE_ATTRIBUTE = "WorkQueue"
# On a WorkQueue Swift receiver whose messages all take Swift types: its Swift target is an actor whose executor is the
# queue its forwarder is registered with, and dispatch enters it with assumeIsolated, which traps off that queue.
SWIFT_ACTOR_ATTRIBUTE = "SwiftActor"
SWIFT_TYPES_ATTRIBUTE = 'SwiftTypes'
# A C++ receiver whose messages that take Swift types are decoded and handled in Swift: generated Swift implements a
# dispatch function for each, with @cxx @implementation, that calls the receiver's handler, a Swift method of the C++
# class. Its other messages are C++ messages to C++ handlers, which may call members of the class that Swift implements.
SWIFT_IMPLEMENTATION_ATTRIBUTE = 'SwiftImplementation'
# On a stream or WorkQueue receiver with 'SwiftImplementation': 'SwiftState=State' names the Swift class of the state that
# its Swift extension's `state` gives, which lasts as long as the receiver. The handlers of its messages that take Swift
# types are methods of that class, which generated Swift calls from a Swift object that the receiver's generated C++
# makes for the first of them and keeps, without the receiver, unless the message is 'WantsReceiver'. Its messages must
# all be dispatched on one serial queue, as a stream receiver's are.
SWIFT_STATE_ATTRIBUTE = 'SwiftState'
# On a message that takes Swift types, to a receiver with 'SwiftState=': its handler is a method of the receiver's Swift
# extension, as it is without 'SwiftState='.
WANTS_RECEIVER_ATTRIBUTE = 'WantsReceiver'
# A top-level Swift stream receiver, which an IPC::SwiftReceiverOwner owns: its forwarder is the owner's
# IPC::SwiftReceiverOwnerClient, generated Swift starts it with startReceiving(on:), and its Swift sends can go on the owner.
# 'SwiftReceiverOwner=Provider' starts it on the owner that the C++ class Provider gives, with swiftReceiverOwner().
SWIFT_RECEIVER_OWNER_ATTRIBUTE = 'SwiftReceiverOwner'
CXX_TYPES_ATTRIBUTE = 'CxxTypes'
CXX_SENDERS_ATTRIBUTE = 'CxxSenders'
# On a message that only C++ sends, so that a receiver's 'SwiftSends=' makes no Swift sender for it: for a message whose
# arguments name types that have no Swift forms, which Swift senders would otherwise spell as types in IPCTypes.
SENT_FROM_CXX_ATTRIBUTE = 'SentFromCxx'
# On a parameter of a message that takes Swift types, for a type that has no Swift form yet: its C++ ArgumentCoder decodes
# it into an IPC::CxxDecodedArgument, which the Swift handler passes on to C++.
CXX_DECODED_ATTRIBUTE = 'CxxDecoded'
LENT_ATTRIBUTE = 'Lent'
SWIFT_SYNC_HANDLER_ATTRIBUTE = 'SwiftSyncHandler'
NOT_USING_IPC_CONNECTION_ATTRIBUTE = 'NotUsingIPCConnection'
WANTS_CONNECTION_ATTRIBUTE = 'WantsConnection'
# On a message to a receiver whose state C++ lends: its Swift handler returns false to decline the message, which the
# lender then handles in C++, once the state is no longer lent, with the same arguments.
SWIFT_MAY_DECLINE_ATTRIBUTE = 'SwiftMayDecline'
# On a Swift stream receiver whose state C++ lends: its messages also have a recorded form, values that a recorder, the
# hand-written <Receiver>Recorder, keeps in place of handling them, and a replay of those values through the receiver's
# handlers.
RECORDABLE_ATTRIBUTE = 'Recordable'
# On a parameter of a message to a 'Recordable' receiver whose type a recording can't keep: the type it records instead,
# made from the argument, whose argument() gives the handler the argument back.
RECORDED_AS_ATTRIBUTE_PREFIX = 'RecordedAs='
SWIFT_DECODE_CONTEXT_ATTRIBUTE_PREFIX = 'SwiftDecodeContext='
# On a message to a 'Recordable' receiver that a recording leaves out: the recorder's dispatch calls the recorder's own
# handler of it.
NOT_RECORDED_ATTRIBUTE = 'NotRecorded'
# On a Synchronous message to a stream receiver that takes Swift types, whose reply isn't stream-encodable: its Swift
# handler is given the reply as a value, which it may send after it returns, as a C++ handler may call its completion
# handler later, or drop to send the default reply.
SWIFT_REPLY_VALUE_ATTRIBUTE = 'SwiftReplyValue'
# The same, for a reply whose types have no Swift form: C++ encodes it, with the reply encoder the value gives it.
CXX_ENCODED_REPLY_ATTRIBUTE = 'CxxEncodedReply'
WANTS_DISPATCH_MESSAGE_ATTRIBUTE = 'WantsDispatchMessage'
WANTS_ASYNC_DISPATCH_MESSAGE_ATTRIBUTE = 'WantsAsyncDispatchMessage'

# Names the generated Swift dispatch of a message that takes Swift types gives its own locals and
# stored properties, so a parameter cannot have them.
_SWIFT_TYPES_RESERVED_PARAMETER_NAMES = frozenset(['connection', 'decoder', 'decodeContext', 'replyEncoder', 'reply', 'target'])
# Types that refer to storage they don't own, which a 'CxxDecoded' holder can't take.
_NON_OWNING_TYPE_PATTERN = re.compile(r'\b(?:span|ArrayReferenceTuple)\s*<|\b(?:StringView|string_view|CStringView)\b')

class MessageReceiver(object):
    cxx_senders_enabled_by = None

    def __init__(self, name, superclass, attributes, receiver_enabled_by, receiver_enabled_by_exception, receiver_enabled_by_conjunction, receiver_dispatched_from, receiver_dispatched_from_exception, receiver_dispatched_to, receiver_dispatched_to_exception, shared_preferences_needs_connection, messages, condition, namespace, swift_receiver, swift_receiver_build_enabled_by, receiver_name, swift_types=False, swift_receiver_state_lender=None, messages_from=None, swift_sends=None, swift_receiver_owner_provider=None, swift_state=None, swift_implementation_build_enabled_by=None):
        self.name = name
        self.superclass = superclass
        self.attributes = frozenset(attributes or [])
        self.receiver_enabled_by = receiver_enabled_by
        self.receiver_enabled_by_exception = receiver_enabled_by_exception
        self.receiver_enabled_by_conjunction = receiver_enabled_by_conjunction
        self.receiver_dispatched_from = receiver_dispatched_from
        self.receiver_dispatched_from_exception = receiver_dispatched_from_exception
        self.receiver_dispatched_to = receiver_dispatched_to
        self.receiver_dispatched_to_exception = receiver_dispatched_to_exception
        self.shared_preferences_needs_connection = shared_preferences_needs_connection
        self.messages = messages
        self.condition = condition
        self.namespace = namespace
        self.swift_receiver = swift_receiver
        self.swift_receiver_build_enabled_by = swift_receiver_build_enabled_by
        self.receiver_name = receiver_name
        self.swift_types = swift_types
        # The C++ class that lends the handlers of a Swift stream receiver the state they take inout.
        self.swift_receiver_state_lender = swift_receiver_state_lender
        # The C++ class that gives the IPC::SwiftReceiverOwner that a receiver with 'SwiftReceiverOwner' starts on, if not
        # the owner itself.
        self.swift_receiver_owner_provider = swift_receiver_owner_provider
        # The Swift class of a 'SwiftImplementation' receiver's state, with 'SwiftState='.
        self.swift_state = swift_state
        # For a receiver with 'SwiftImplementation' and 'SwiftReceiverBuildEnabledBy=FLAG': its Swift dispatch and Swift
        # sends are built only where FLAG is enabled, and elsewhere all its messages go to its C++ handlers.
        self.swift_implementation_build_enabled_by = swift_implementation_build_enabled_by
        # The receiver whose definitions of the messages this one names it takes (parser.resolve_message_references()).
        self.messages_from = messages_from
        # The names of the receivers whose messages this Swift receiver's Swift sends, and, once parser.resolve_swift_sends()
        # has found them, those receivers.
        self.swift_sends_names = swift_sends or []
        self.swift_sends = []

    def iterparameters(self):
        return itertools.chain((parameter for message in self.messages for parameter in message.parameters),
            (reply_parameter for message in self.messages if message.reply_parameters for reply_parameter in message.reply_parameters))

    def has_attribute(self, attribute):
        return attribute in self.attributes

    def is_swift_receiver(self):
        return bool(self.swift_receiver or self.swift_receiver_build_enabled_by)

    def is_swift_implementation(self):
        return self.has_attribute(SWIFT_IMPLEMENTATION_ATTRIBUTE)

    def dispatches_to_swift_state(self, message):
        """Whether a message that takes Swift types goes to the Swift state of a receiver with 'SwiftState=', rather than to
        a handler that is a method of the receiver."""
        return bool(self.swift_state) and self.takes_swift_types(message) and not message.has_attribute(WANTS_RECEIVER_ATTRIBUTE)

    def has_swift_receiver_owner(self):
        return self.has_attribute(SWIFT_RECEIVER_OWNER_ATTRIBUTE)

    def is_recordable(self):
        return self.has_attribute(RECORDABLE_ATTRIBUTE)

    def takes_swift_types(self, message):
        """Whether the Swift receiver decodes this message's arguments, and encodes its reply, as Swift types."""
        if message.is_async_reply or not (self.is_swift_receiver() or self.is_swift_implementation()):
            return False
        if message.has_attribute(SWIFT_TYPES_ATTRIBUTE):
            return True
        if message.has_attribute(CXX_TYPES_ATTRIBUTE):
            return False
        return self.swift_types

    def enforce_swift_types_constraints(self):
        self._enforce_swift_implementation_constraints()
        if self.has_swift_receiver_owner() and (not self.is_swift_receiver() or not self.has_attribute(STREAM_ATTRIBUTE) or self.swift_receiver_state_lender):
            raise Exception("ERROR: Receiver %s has '%s', which is for Swift stream receivers without a state lender" % (self.name, SWIFT_RECEIVER_OWNER_ATTRIBUTE))
        if self.swift_types and not (self.is_swift_receiver() or self.is_swift_implementation()):
            raise Exception("ERROR: Receiver %s has 'SwiftTypes' but is not a Swift receiver: it also needs 'SwiftReceiver' or 'SwiftReceiverBuildEnabledBy='" % self.name)
        if self.has_attribute(WORK_QUEUE_ATTRIBUTE) and not (self.is_swift_receiver() or self.is_swift_implementation()):
            raise Exception("ERROR: Receiver %s has '%s', which is for Swift receivers: a C++ receiver chooses its own base class" % (self.name, WORK_QUEUE_ATTRIBUTE))
        if self.has_attribute(WORK_QUEUE_ATTRIBUTE) and self.has_attribute(STREAM_ATTRIBUTE):
            raise Exception("ERROR: Receiver %s cannot have both '%s' and '%s'" % (self.name, WORK_QUEUE_ATTRIBUTE, STREAM_ATTRIBUTE))
        if self.has_attribute(SWIFT_ACTOR_ATTRIBUTE):
            if not (self.is_swift_receiver() and self.has_attribute(WORK_QUEUE_ATTRIBUTE)):
                raise Exception("ERROR: Receiver %s has '%s', which is for Swift receivers with '%s'" % (self.name, SWIFT_ACTOR_ATTRIBUTE, WORK_QUEUE_ATTRIBUTE))
            for message in self.messages:
                if not message.is_async_reply and not self.takes_swift_types(message):
                    raise Exception("ERROR: Message %s.%s takes C++ types, which a receiver with '%s' can't" % (self.name, message.name, SWIFT_ACTOR_ATTRIBUTE))
        for message in self.messages:
            self._enforce_swift_types_constraints_for_message(message)
        self._enforce_lent_state_constraints()
        self._enforce_recordable_constraints()

    def _lends_cxx_arguments(self):
        """Whether a Swift receiver's handlers are called during the dispatch of the messages that take C++ types, so that
        they can borrow arguments that refer into the message ('Lent')."""
        return self.is_swift_receiver() and not self.swift_receiver_state_lender and (self.has_attribute(STREAM_ATTRIBUTE) or self.has_attribute(WORK_QUEUE_ATTRIBUTE))

    def _enforce_swift_implementation_constraints(self):
        if self.swift_state and not (self.is_swift_implementation() and (self.has_attribute(STREAM_ATTRIBUTE) or self.has_attribute(WORK_QUEUE_ATTRIBUTE))):
            raise Exception("ERROR: Receiver %s has '%s=', which is for stream and WorkQueue receivers with '%s'" % (self.name, SWIFT_STATE_ATTRIBUTE, SWIFT_IMPLEMENTATION_ATTRIBUTE))
        for message in self.messages:
            if message.has_attribute(WANTS_RECEIVER_ATTRIBUTE) and not (self.swift_state and self.takes_swift_types(message)):
                raise Exception("ERROR: Message %s.%s has '%s', which is for messages that take Swift types to receivers with '%s='" % (self.name, message.name, WANTS_RECEIVER_ATTRIBUTE, SWIFT_STATE_ATTRIBUTE))
        if not self.is_swift_implementation():
            return
        if self.is_swift_receiver() or self.swift_receiver_state_lender:
            raise Exception("ERROR: Receiver %s has '%s', which is for a C++ receiver, so it cannot be a Swift receiver too" % (self.name, SWIFT_IMPLEMENTATION_ATTRIBUTE))

    def _enforce_lent_state_constraints(self):
        if not self.swift_receiver_state_lender:
            for message in self.messages:
                if message.has_attribute(SWIFT_MAY_DECLINE_ATTRIBUTE):
                    raise Exception("ERROR: Message %s.%s has '%s', which is for receivers with 'SwiftReceiverStateLender='" % (self.name, message.name, SWIFT_MAY_DECLINE_ATTRIBUTE))
                if message.swift_decode_context():
                    raise Exception("ERROR: Message %s.%s has '%s', which is for receivers with 'SwiftReceiverStateLender='" % (self.name, message.name, SWIFT_DECODE_CONTEXT_ATTRIBUTE_PREFIX))
            return
        if not self.is_swift_receiver() or not self.has_attribute(STREAM_ATTRIBUTE):
            raise Exception("ERROR: Receiver %s has 'SwiftReceiverStateLender=%s', which is for Swift stream receivers" % (self.name, self.swift_receiver_state_lender))
        for message in self.messages:
            description = '%s.%s' % (self.name, message.name)
            # A message that takes Swift types is decoded by its Swift dispatch, while the state is lent.
            if self.takes_swift_types(message):
                if message.has_attribute(SWIFT_MAY_DECLINE_ATTRIBUTE):
                    raise Exception("ERROR: Message %s takes Swift types, so cannot have '%s', since C++ would handle it without its arguments" % (description, SWIFT_MAY_DECLINE_ATTRIBUTE))
                for parameter in message.parameters:
                    if parameter.attributes:
                        raise Exception("ERROR: Message %s takes Swift types, which is not supported with attributes on parameter '%s' on a receiver with 'SwiftReceiverStateLender='" % (description, parameter.name))
            if message.swift_decode_context():
                if not self.takes_swift_types(message):
                    raise Exception("ERROR: Message %s has '%s', which is for messages that take Swift types" % (description, SWIFT_DECODE_CONTEXT_ATTRIBUTE_PREFIX))
                if not any(takes_decode_context(parameter.type) for parameter in message.parameters):
                    raise Exception("ERROR: Message %s has '%s', but none of its parameters has a Swift coder that takes a decoding context" % (description, SWIFT_DECODE_CONTEXT_ATTRIBUTE_PREFIX))
            if message.reply_parameters is not None:
                raise Exception("ERROR: Message %s has a reply, which is not supported on a receiver with 'SwiftReceiverStateLender='" % description)
            for parameter in message.parameters:
                if parameter.name in ('state', 'target'):
                    raise Exception("ERROR: Message %s has a parameter named '%s', which the generated dispatch of a receiver with 'SwiftReceiverStateLender=' uses itself" % (description, parameter.name))

    def _enforce_recordable_constraints(self):
        if not self.is_recordable():
            for message in self.messages:
                if message.has_attribute(NOT_RECORDED_ATTRIBUTE):
                    raise Exception("ERROR: Message %s.%s has '%s', which is for receivers with '%s'" % (self.name, message.name, NOT_RECORDED_ATTRIBUTE, RECORDABLE_ATTRIBUTE))
                for parameter in message.parameters:
                    if parameter.recorded_as_type():
                        raise Exception("ERROR: Message %s.%s has '%s' on parameter '%s', which is for receivers with '%s'" % (self.name, message.name, RECORDED_AS_ATTRIBUTE_PREFIX, parameter.name, RECORDABLE_ATTRIBUTE))
            return
        if not self.swift_receiver_state_lender:
            raise Exception("ERROR: Receiver %s has '%s', which is for Swift stream receivers with 'SwiftReceiverStateLender='" % (self.name, RECORDABLE_ATTRIBUTE))
        # The recorder's dispatch asks for no shared preferences.
        if self.receiver_enabled_by or any(message.enabled_by for message in self.messages):
            raise Exception("ERROR: Receiver %s has '%s', which is not supported together with 'EnabledBy='" % (self.name, RECORDABLE_ATTRIBUTE))
        for message in self.messages:
            description = '%s.%s' % (self.name, message.name)
            # Replay calls the handler of every message, which must handle it.
            if message.has_attribute(SWIFT_MAY_DECLINE_ATTRIBUTE):
                raise Exception("ERROR: Message %s has '%s', which is not supported on a receiver with '%s'" % (description, SWIFT_MAY_DECLINE_ATTRIBUTE, RECORDABLE_ATTRIBUTE))
            if message.reply_parameters is not None:
                raise Exception("ERROR: Message %s has a reply, which is not supported on a receiver with '%s'" % (description, RECORDABLE_ATTRIBUTE))
            if message.has_attribute(WANTS_CONNECTION_ATTRIBUTE):
                raise Exception("ERROR: Message %s has '%s', which is not supported on a receiver with '%s'" % (description, WANTS_CONNECTION_ATTRIBUTE, RECORDABLE_ATTRIBUTE))
            if message.validator:
                raise Exception("ERROR: Message %s has 'Validator=%s', which is not supported on a receiver with '%s'" % (description, message.validator, RECORDABLE_ATTRIBUTE))

    def _enforce_swift_types_constraints_for_message(self, message):
        description = '%s.%s' % (self.name, message.name)
        for attribute in (SWIFT_REPLY_VALUE_ATTRIBUTE, CXX_ENCODED_REPLY_ATTRIBUTE):
            if not message.has_attribute(attribute):
                continue
            if attribute == CXX_ENCODED_REPLY_ATTRIBUTE and self.takes_swift_types(message) and message.reply_parameters and not message.has_attribute(SYNCHRONOUS_ATTRIBUTE):
                continue
            if not (self.takes_swift_types(message) and self.has_attribute(STREAM_ATTRIBUTE) and message.has_attribute(SYNCHRONOUS_ATTRIBUTE) and message.has_attribute('NotStreamEncodableReply')):
                if attribute == CXX_ENCODED_REPLY_ATTRIBUTE:
                    raise Exception("ERROR: Message %s has '%s', which is for messages with a reply that take Swift types: asynchronous ones, or Synchronous ones with 'NotStreamEncodableReply' to a stream receiver" % (description, attribute))
                raise Exception("ERROR: Message %s has '%s', which is for Synchronous messages with 'NotStreamEncodableReply' to a stream receiver that takes Swift types" % (description, attribute))
        if message.has_attribute(SWIFT_SYNC_HANDLER_ATTRIBUTE) and not (self.is_swift_receiver() or self.is_swift_implementation()):
            raise Exception("ERROR: Message %s has '%s', which is for messages a Swift receiver handles" % (description, SWIFT_SYNC_HANDLER_ATTRIBUTE))
        if message.has_attribute(SWIFT_TYPES_ATTRIBUTE) and message.has_attribute(CXX_TYPES_ATTRIBUTE):
            raise Exception("ERROR: Message %s cannot have both 'SwiftTypes' and 'CxxTypes'" % description)
        if message.has_attribute(SWIFT_TYPES_ATTRIBUTE) and not (self.is_swift_receiver() or self.is_swift_implementation()):
            raise Exception("ERROR: Message %s has 'SwiftTypes' but receiver %s is not a Swift receiver: it needs 'SwiftReceiver' or 'SwiftReceiverBuildEnabledBy='" % (description, self.name))
        if message.has_attribute(CXX_TYPES_ATTRIBUTE) and not self.swift_types:
            raise Exception("ERROR: Message %s has 'CxxTypes' but receiver %s does not have 'SwiftTypes'" % (description, self.name))
        if message.has_attribute(WANTS_CONNECTION_ATTRIBUTE) and not (self.takes_swift_types(message) and self.has_attribute(STREAM_ATTRIBUTE)):
            raise Exception("ERROR: Message %s has '%s', which is for messages that take Swift types on a stream" % (description, WANTS_CONNECTION_ATTRIBUTE))
        if not self.takes_swift_types(message):
            for parameter in message.parameters:
                if parameter.has_attribute(LENT_ATTRIBUTE) and self._lends_cxx_arguments():
                    # A C++ view into the message, which the handler borrows during dispatch: its C++ type is one of the
                    # SWIFT_NONESCAPABLE types in swift_types.LENT_CXX_VIEW_TYPES, so that the handler can't keep it.
                    if not is_lent_cxx_view(parameter.type):
                        raise Exception("ERROR: Message %s has '%s' on parameter '%s', whose type '%s' isn't one of the non-escapable views in swift_types.LENT_CXX_VIEW_TYPES" % (description, LENT_ATTRIBUTE, parameter.name, parameter.type))
                    continue
                for attribute in (CXX_DECODED_ATTRIBUTE, LENT_ATTRIBUTE):
                    if parameter.has_attribute(attribute):
                        raise Exception("ERROR: Message %s has '%s' on parameter '%s', which is only for messages that take Swift types" % (description, attribute, parameter.name))
            return

        def unsupported(what):
            return Exception("ERROR: Message %s takes Swift types, which is not supported %s" % (description, what))

        for attribute in (NOT_USING_IPC_CONNECTION_ATTRIBUTE, WANTS_DISPATCH_MESSAGE_ATTRIBUTE, WANTS_ASYNC_DISPATCH_MESSAGE_ATTRIBUTE):
            if attribute == WANTS_DISPATCH_MESSAGE_ATTRIBUTE and self.is_swift_implementation():
                continue
            if self.has_attribute(attribute):
                raise unsupported("on a receiver with '%s'" % attribute)
        if message.has_attribute(CALL_WITH_REPLY_ID_ATTRIBUTE):
            raise unsupported("together with '%s'" % CALL_WITH_REPLY_ID_ATTRIBUTE)
        if message.validator:
            raise unsupported("together with 'Validator=%s'" % message.validator)
        if message.has_attribute(SYNCHRONOUS_ATTRIBUTE) and message.reply_parameters is None:
            raise unsupported("for a '%s' message without a reply" % SYNCHRONOUS_ATTRIBUTE)

        for parameter in message.parameters:
            if parameter.name in _SWIFT_TYPES_RESERVED_PARAMETER_NAMES:
                raise Exception("ERROR: Message %s takes Swift types, so cannot have a parameter named '%s', which the generated Swift uses itself" % (description, parameter.name))
        # C++ encodes a CxxEncodedReply, so its types need no Swift form.
        reply_parameters = [] if message.has_attribute(CXX_ENCODED_REPLY_ATTRIBUTE) else message.reply_parameters or []
        parameters = [('parameter', parameter) for parameter in message.parameters] + [('reply parameter', parameter) for parameter in reply_parameters]
        for kind, parameter in parameters:
            if kind == 'parameter' and parameter.attributes == {CXX_DECODED_ATTRIBUTE}:
                if _NON_OWNING_TYPE_PATTERN.search(parameter.type):
                    raise Exception("ERROR: Message %s has '%s' on parameter '%s', which is only for types that own their storage, not '%s'" % (description, CXX_DECODED_ATTRIBUTE, parameter.name, parameter.type))
                continue
            if kind == 'parameter' and parameter.attributes == {LENT_ATTRIBUTE}:
                # Its bytes are lent to the handler for the dispatch (swift_types.LENT_BYTES_TYPES).
                if not is_lent_bytes(parameter.type):
                    raise Exception("ERROR: Message %s has '%s' on parameter '%s', which is only for a std::span<const uint8_t>" % (description, LENT_ATTRIBUTE, parameter.name))
                if self.swift_receiver_state_lender or not (self.has_attribute(STREAM_ATTRIBUTE) or self.has_attribute(WORK_QUEUE_ATTRIBUTE) or message.has_attribute(SWIFT_SYNC_HANDLER_ATTRIBUTE)):
                    raise Exception("ERROR: Message %s has '%s' on parameter '%s', whose bytes are lent to its Swift handler during dispatch, so the handler must be called then: on a stream or WorkQueue, or with '%s'" % (description, LENT_ATTRIBUTE, parameter.name, SWIFT_SYNC_HANDLER_ATTRIBUTE))
                continue
            if parameter.attributes:
                raise unsupported("with attributes on %s '%s': %s" % (kind, parameter.name, ', '.join(sorted(parameter.attributes))))
            if unwrap_untrusted(parameter.type):
                raise unsupported("with an IPC::Untrusted<> %s '%s'" % (kind, parameter.name))
            try:
                swift_type_and_coder(parameter.type)
            except UnmappableSwiftType as error:
                raise Exception("ERROR: Message %s takes Swift types, but cannot take %s '%s': %s" % (description, kind, parameter.name, error))
        # A Swift value of an owned type (swift_types.is_owned_type) is the only owner of what the message carries, which
        # the handler takes. So the handler must be called during dispatch, and never decline the message, which would
        # have C++ handle it again with arguments Swift has taken: a receiver that lends state calls it during dispatch,
        # and a message of its that takes Swift types can't decline.
        owned_parameters = [parameter for _, parameter in parameters if not parameter.attributes and is_owned_type(parameter.type)]
        if owned_parameters and not (self.has_attribute(STREAM_ATTRIBUTE) or self.has_attribute(WORK_QUEUE_ATTRIBUTE) or message.has_attribute(SWIFT_SYNC_HANDLER_ATTRIBUTE)):
            raise Exception("ERROR: Message %s takes Swift types, and the Swift form of '%s' owns what the message carries, so its handler must be called during dispatch: on a stream or WorkQueue, or with '%s'" % (description, owned_parameters[0].name, SWIFT_SYNC_HANDLER_ATTRIBUTE))
        # A recording keeps the values of its messages, which an owned value can't be shared with.
        if owned_parameters and self.is_recordable() and not message.has_attribute(NOT_RECORDED_ATTRIBUTE):
            raise Exception("ERROR: Message %s takes Swift types, and the Swift form of '%s' owns what the message carries, so a recording can't keep it: it must be '%s'" % (description, owned_parameters[0].name, NOT_RECORDED_ATTRIBUTE))
        if any(is_owned_type(parameter.type) for parameter in reply_parameters):
            if len(reply_parameters) != 1:
                raise unsupported("with a reply of more than one value that includes an owned type (a ~Copyable Swift value)")
            # A Synchronous reply to a stream message that doesn't fit in the stream is encoded a second time.
            if self.has_attribute(STREAM_ATTRIBUTE) and message.has_attribute(SYNCHRONOUS_ATTRIBUTE) and not message.has_attribute('NotStreamEncodableReply'):
                raise Exception("ERROR: Message %s takes Swift types, and its Synchronous reply carries an owned type, which can't be encoded twice, so it must be 'NotStreamEncodableReply'" % description)
        for parameter in message.reply_parameters or []:
            # The reply to a message found to be invalid is built from default-constructed values.
            if re.match(r'(?:WTF::)?Ref<', strip_cpp_type_decorations(parameter.type)):
                raise Exception("ERROR: Message %s takes Swift types, so its reply parameter '%s' cannot be a Ref<>, which has no default value for the reply to an invalid message: use RefPtr<> or std::optional<> instead" % (description, parameter.name))

    def enforce_attribute_constraints(self):
        if not self.receiver_dispatched_from and not self.receiver_dispatched_from_exception:
            raise Exception("ERROR: %s not annotated with 'DispatchedFrom=' attribute" % self.name)
        if not self.receiver_dispatched_to and not self.receiver_dispatched_to_exception:
            raise Exception("ERROR: %s not annotated with 'DispatchedTo=' attribute" % self.name)

    def enforce_opaque_ipc_types_usage(self):
        for message in self.messages:
            for parameter in message.parameters:
                # An opaque type stays opaque inside IPC::Untrusted<>, so look through the wrapper.
                parameter_type = unwrap_if_untrusted(parameter.type)
                if is_opaque_type(parameter_type):
                    if not opaque_ipc_types.message_param_tracked(self.name, message.name, parameter.name, parameter_type):
                        raise Exception(f"Justification needed in opaque_ipc_types.tracking.in: [] MessageParam {self.name}.{message.name} {parameter.name} {parameter_type}")
            if message.reply_parameters is not None:
                for parameter in message.reply_parameters:
                    parameter_type = unwrap_if_untrusted(parameter.type)
                    if is_opaque_type(parameter_type):
                        if not opaque_ipc_types.message_param_reply_tracked(self.name, message.name, parameter.name, parameter_type):
                            raise Exception(f"Justification needed in opaque_ipc_types.tracking.in: [] MessageParamReply {self.name}.{message.name} {parameter.name} {parameter_type}")

    def enforce_untrusted_origin_usage(self):
        """A privileged process must not be handed a bare origin or URL by web content.
        """
        if not is_privileged_receiver(self):
            return
        for message in self.messages:
            for parameter in message.parameters:
                untrusted_type = conveys_untrusted_value(parameter.type)
                if untrusted_type is None or unwrap_untrusted(parameter.type):
                    continue
                raise Exception(
                    f"{self.name}.{message.name} passes {untrusted_type} from web content into the "
                    f"{self.receiver_dispatched_to} process as a bare value. Declare the parameter as "
                    f"IPC::Untrusted<{parameter.type}> and either validate it with one of the "
                    f"designated validation procedures or call unsafeExtractWithoutValidation() with a reason.")


class Message(object):
    def __init__(self, name, parameters, reply_parameters, attributes, condition, validator=None, enabled_by=None, enabled_by_exception=False, enabled_by_conjunction=None, coalescing_key_indices=None, is_async_reply=False):
        self.name = name
        self.parameters = parameters
        self.reply_parameters = reply_parameters
        self.attributes = frozenset(attributes or [])
        self.condition = condition
        self.validator = validator
        self.enabled_by = enabled_by
        self.enabled_by_exception = enabled_by_exception
        self.enabled_by_conjunction = enabled_by_conjunction
        self.coalescing_key_indices = coalescing_key_indices
        self.is_async_reply = is_async_reply

    def has_attribute(self, attribute):
        return attribute in self.attributes

    # The method of a lent-state receiver that its Swift dispatch asks, with the state, for the context to decode the
    # arguments whose Swift coders take one ('SwiftDecodeContext='), or None.
    def swift_decode_context(self):
        for attribute in self.attributes:
            if attribute.startswith(SWIFT_DECODE_CONTEXT_ATTRIBUTE_PREFIX):
                return attribute[len(SWIFT_DECODE_CONTEXT_ATTRIBUTE_PREFIX):]
        return None


class Parameter(object):
    def __init__(self, kind, type, name, attributes=None, condition=None):
        self.kind = kind
        self.type = type
        self.name = name
        self.attributes = frozenset(attributes or [])
        self.condition = condition

    def has_attribute(self, attribute):
        return attribute in self.attributes

    # The type that a recording of the message keeps for this argument ('RecordedAs='), or None.
    def recorded_as_type(self):
        for attribute in self.attributes:
            if attribute.startswith(RECORDED_AS_ATTRIBUTE_PREFIX):
                return attribute[len(RECORDED_AS_ATTRIBUTE_PREFIX):]
        return None


ipc_receiver = MessageReceiver(name="IPC", superclass=None, attributes=[BUILTIN_ATTRIBUTE], receiver_enabled_by=None, receiver_enabled_by_exception=False, receiver_enabled_by_conjunction=None, receiver_dispatched_from=None, receiver_dispatched_from_exception=None, receiver_dispatched_to=None, receiver_dispatched_to_exception=None, shared_preferences_needs_connection=False, swift_receiver=False, swift_receiver_build_enabled_by=None, receiver_name=None, messages=[
    Message('WrappedAsyncMessageForTesting', [], None, attributes=[BUILTIN_ATTRIBUTE, SYNCHRONOUS_ATTRIBUTE, ALLOWEDWHENWAITINGFORSYNCREPLY_ATTRIBUTE], condition=None),
    Message('SyncMessageReply', [], None, attributes=[BUILTIN_ATTRIBUTE], condition=None),
    Message('CancelSyncMessageReply', [], None, attributes=[BUILTIN_ATTRIBUTE], condition=None),
    Message('CancelAsyncReply', [], None, attributes=[BUILTIN_ATTRIBUTE], condition=None),
    Message('InitializeConnection', [], None, attributes=[BUILTIN_ATTRIBUTE], condition="PLATFORM(COCOA)"),
    Message('LegacySessionState', [], None, attributes=[BUILTIN_ATTRIBUTE], condition=None),
    Message('SetStreamDestinationID', [], None, attributes=[BUILTIN_ATTRIBUTE], condition=None),
    Message('ProcessOutOfStreamMessage', [], None, attributes=[BUILTIN_ATTRIBUTE], condition=None),
    Message('InitializeStreamClientConnection', [], None, attributes=[BUILTIN_ATTRIBUTE], condition=None),
], condition=None, namespace="WebKit")


def check_global_model_inputs(receivers):
    errors = []
    receiver_counts = Counter([r.name for r in receivers])
    receiver_duplicates = [n for n, c in receiver_counts.items() if c > 1]
    if receiver_duplicates:
        errors.append('Duplicate message receiver names: %s' % (', '.join(receiver_duplicates)))

    # A message might be defined multiple times using ifdef conditions.
    # Certain attributes must match in this case. E.g. USE(COCOA) cannot have a sync message that
    # would be non-sync in USE(GTK).
    matching_attributes = [SYNCHRONOUS_ATTRIBUTE, SWIFT_TYPES_ATTRIBUTE, CXX_TYPES_ATTRIBUTE, SWIFT_SYNC_HANDLER_ATTRIBUTE]
    for receiver in receivers:
        receiver_messages = defaultdict(list)
        for message in receiver.messages:
            receiver_messages[message.name].append(message)
        for messages in receiver_messages.values():
            m0 = messages[0]
            for i in range(1, len(messages)):
                mi = messages[i]
                if any(m0.has_attribute(a) != mi.has_attribute(a) for a in matching_attributes):
                    errors.append('Receiver %s message %s attribute mismatch: %s (%s) != %s (%s))' % (receiver.name, message.name,
                                  m0.attributes, m0.condition, mi.attributes, mi.condition))
    return errors


def generate_global_model(receivers):
    for receiver in receivers:
        async_reply_messages = []
        for message in receiver.messages:
            if message.reply_parameters is not None and not message.has_attribute(SYNCHRONOUS_ATTRIBUTE):
                async_reply_messages.append(Message(name='%sReply' % message.name, parameters=message.reply_parameters, reply_parameters=None, attributes=None, condition=message.condition, enabled_by=message.enabled_by, enabled_by_exception=message.enabled_by_exception, enabled_by_conjunction=message.enabled_by_conjunction, coalescing_key_indices=message.coalescing_key_indices, is_async_reply=True))
        receiver.messages = receiver.messages + async_reply_messages

    return [ipc_receiver] + receivers
