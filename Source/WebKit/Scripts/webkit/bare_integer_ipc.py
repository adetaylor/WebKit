# Copyright (C) 2026 Apple Inc. All rights reserved.
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

"""Enforcement for the rule that an object identifier crossing IPC is an
ObjectIdentifier<Tag>, never a bare integer.

Detecting an identifier from a declaration is not possible: the property that
makes an integer an identifier is that the receiver uses it to look an object up,
which lives in the handler body. Name-based detection fails in both directions -
it misses DataDetectorsDidPresentUI(uint64_t pageOverlay), which is an object
handle whose name does not end in ID, and it flags displayID, logIdentifier and
the ANGLE object names, which are correctly integers.

So the rule is inverted: every bare integer reaching a privileged process from
web content must say what it is. A violation then cannot be an omission, only a
false claim, and a false claim is visible in review.
"""

import os
import re

# Only integer types: a bool or a float cannot be an object identifier, and
# including them would bury the real entries under thousands of flags and sizes.
BARE_INTEGER_TYPES = {
    "short", "unsigned short", "int", "unsigned", "unsigned int",
    "long", "unsigned long", "long long", "unsigned long long",
    "int8_t", "int16_t", "int32_t", "int64_t",
    "uint8_t", "uint16_t", "uint32_t", "uint64_t",
    "size_t", "ssize_t",
}

# Integers that only look like a distinct type. The generator sees a name, not a
# definition, so an alias that resolves to a built-in integer would otherwise walk
# straight past a type-based check. WebCore::PointerID is the reason this exists:
# it reads as a typed identifier in a .messages.in file and is a uint32_t.
RAW_INTEGER_ALIASES = {
    "WebCore::PointerID": "uint32_t",
    "WebCore::PageOverlay::PageOverlayID": "uint64_t",
    "WebKit::DynamicViewportSizeUpdateID": "uint64_t",
    "WebKit::WebSocketTask::TaskIdentifier": "uint64_t",
}

# Single-value wrappers traversed to reach the value being carried. Deliberately not
# Vector or HashSet: a container of integers is a buffer or a set, not an identifier,
# and traversing them would bury the real entries under every byte array on the boundary.
TRAVERSED_CONTAINERS = {
    "std::optional", "Markable",
}

# Processes holding privilege a web content process does not.
PRIVILEGED_PROCESSES = {"UI", "Networking", "GPU", "Model"}

# Why this integer is not an object identifier. Every tracked parameter names one.
VALID_CATEGORIES = {
    # A quantity: a size, count, index, length, offset, rate, duration or quota.
    # Nothing is looked up by it.
    "Measurement",
    # A status, error or result code.
    "StatusCode",
    # A set of flags or an enumeration that has not been given an enum type. Its own
    # smell, but not this rule's concern.
    "EnumLike",
    # Assigned outside WebKit and meaningless as an ObjectIdentifier: a CGDirectDisplayID,
    # an OS process id, an NSPasteboard change count.
    "PlatformValue",
    # An object name minted by a graphics driver or library, validated by it.
    "GraphicsObjectName",
    # Assigned by a third-party library whose wire format we do not choose.
    "ExternalLibrary",
    # An opaque cookie used only for log correlation. Never dereferenced.
    "LoggingCookie",
    # A monotonic generation, epoch or sequence number, compared for equality against
    # locally held state rather than used to look anything up. Often legitimately zero,
    # which ObjectIdentifier cannot represent.
    "SequenceCounter",
    # A row identifier assigned by SQLite.
    "DatabaseRowID",
    # This is an object identifier and should be an ObjectIdentifier<Tag>. The
    # burn-down list.
    "NeedsTyping",
    # Predates this rule and has not been individually reviewed. Seeded in bulk so the
    # ratchet could be turned on; carries no claim that the value is safe. Do not add to
    # this category in new code - pick a real one, or NeedsTyping.
    "LegacyUnreviewed",
}

# A typed identifier has to reach the wire as an integer somewhere, and it does so through
# its own raw-value accessor. A serialized member that IS that accessor is the correct
# pattern, not a violation of it: WTF::ObjectIdentifier { uint64_t toUInt64() } is the
# definition every typed identifier is built on.
IDENTIFIER_RAW_VALUE_ACCESSORS = {
    "toUInt64()", "toRawValue()", "toUInt32()",
}

# Types that ARE an identifier value, serialized by decomposing into the integers that make
# them up. WTF::UUID is 128 bits sent as high() and low(), guarded by its own
# WTF::UUID::isValid validator - the same shape as an ObjectIdentifier's raw-value accessor,
# so every member of such a type is exempt for the same reason.
IDENTIFIER_VALUE_TYPES = {
    "WTF::UUID",
}


# Receivers whose entire interface is a stream of scalars - a command stream for a
# graphics API, where every parameter is a driver enum or dimension and none is a
# WebKit object. Exempting the receiver rather than listing several hundred
# parameters individually. Additions here need a security review.
BULK_SCALAR_RECEIVERS = {
    "RemoteGraphicsContextGL",
}


def _strip_const_and_whitespace(type_str):
    if not type_str:
        return ""
    type_str = type_str.strip()
    for prefix in ("const ", "struct ", "class "):
        if type_str.startswith(prefix):
            type_str = type_str[len(prefix):].strip()
    return type_str


def _split_container(type_str):
    """Return (container_name, sole_parameter) for a single-parameter container."""
    match = re.match(r'^([A-Za-z_][\w:]*)<(.+)>$', type_str)
    if not match:
        return None, None
    name, parameters = match.group(1), match.group(2)
    if name not in TRAVERSED_CONTAINERS:
        return None, None
    depth = 0
    for character in parameters:
        if character == '<':
            depth += 1
        elif character == '>':
            depth -= 1
        elif character == ',' and not depth:
            return None, None
    return name, parameters


def resolves_to_bare_integer(type_str, visited=None):
    """Return the built-in integer type this parameter carries, or None.

    Traverses single-value containers and resolves the aliases in
    RAW_INTEGER_ALIASES, so std::optional<WebCore::PointerID> is reported as
    uint32_t rather than being mistaken for a typed identifier.
    """
    if visited is None:
        visited = set()
    if type_str in visited:
        return None
    visited.add(type_str)

    clean = _strip_const_and_whitespace(type_str)
    if clean in BARE_INTEGER_TYPES:
        return clean
    if clean in RAW_INTEGER_ALIASES:
        return RAW_INTEGER_ALIASES[clean]

    _, parameter = _split_container(clean)
    if parameter is None:
        return None
    return resolves_to_bare_integer(parameter, visited)


def is_identifier_raw_value_accessor(member_name, type_name=None):
    """True when this serialized member is how a typed identifier reaches the wire."""
    if type_name is not None and _strip_const_and_whitespace(type_name) in IDENTIFIER_VALUE_TYPES:
        return True
    return member_name.strip() in IDENTIFIER_RAW_VALUE_ACCESSORS


def receiver_is_in_scope(receiver):
    """True when this receiver's integers must be justified.

    In scope when a less privileged process can send to a more privileged one. Where an
    annotation is missing the unproven case is treated as in scope, because it cannot be
    shown safe: both object identifiers known to be untyped today - AcceleratedBackingStore's
    buffer ids and RemoteObjectRegistry's replyID - live in receivers that predate the
    DispatchedTo annotation, so exempting the unproven case would exempt precisely the
    violations that exist.

    A known-unprivileged destination is out of scope even if the sender is unannotated:
    an identifier travelling from a privileged process down to web content cannot be used
    by web content to name something it should not reach.
    """
    if not receiver.receiver_dispatched_to_exception:
        if receiver.receiver_dispatched_to not in PRIVILEGED_PROCESSES:
            return False
        if receiver.receiver_dispatched_from_exception:
            return True
        dispatched_from = receiver.receiver_dispatched_from or []
        # The parser gives a single sender as a string and several as a list.
        if isinstance(dispatched_from, str):
            dispatched_from = [sender.strip() for sender in dispatched_from.split(',')]
        return 'WebContent' in dispatched_from
    return True


class BareIntegerIPCTypes(object):
    """The tracked justifications, keyed by (Receiver.Message, parameterName)."""

    def __init__(self, tracking_file_path=None):
        if tracking_file_path is None:
            tracking_file_path = os.path.join(os.path.dirname(__file__), 'bare_integer_ipc.tracking.in')
        self.message_parameters = {}
        self.struct_members = {}
        self._parse(tracking_file_path)

    def _parse(self, path):
        category = None
        with open(path, 'r') as handle:
            for number, line in enumerate(handle, 1):
                line = line.split('#', 1)[0].strip()
                if not line:
                    continue
                if line == '}':
                    category = None
                    continue
                header = re.match(r'^\[([A-Za-z]+)\]\s*\{$', line)
                if header:
                    category = header.group(1)
                    if category not in VALID_CATEGORIES:
                        raise Exception(
                            f'{os.path.basename(path)}:{number}: unknown category "{category}". '
                            f'Valid categories are: {", ".join(sorted(VALID_CATEGORIES))}')
                    continue
                if category is None:
                    raise Exception(f'{os.path.basename(path)}:{number}: entry outside any [Category] group: {line}')
                fields = line.split()
                if len(fields) != 3 or fields[0] not in ('MessageParam', 'StructMember'):
                    raise Exception(
                        f'{os.path.basename(path)}:{number}: expected '
                        f'"MessageParam Receiver.Message parameterName" or '
                        f'"StructMember Namespace::Type memberName", got: {line}')
                target = self.message_parameters if fields[0] == 'MessageParam' else self.struct_members
                target[(fields[1], fields[2])] = category

    def category_for(self, receiver_name, message_name, parameter_name):
        return self.message_parameters.get((f'{receiver_name}.{message_name}', parameter_name))

    def category_for_struct_member(self, type_name, member_name):
        return self.struct_members.get((type_name, member_name))

    def needs_typing(self):
        entries = list(self.message_parameters.items()) + list(self.struct_members.items())
        return sorted(key for key, category in entries if category == 'NeedsTyping')


bare_integer_ipc_types = BareIntegerIPCTypes()


if __name__ == '__main__':
    import unittest

    class TestBareIntegerIPC(unittest.TestCase):

        def test_builtin_integers_are_bare(self):
            for type_string in ('uint64_t', 'uint32_t', 'int', 'unsigned', 'size_t', 'const uint64_t'):
                self.assertEqual(resolves_to_bare_integer(type_string), type_string.replace('const ', ''))

        def test_non_integers_are_not_bare(self):
            for type_string in ('String', 'URL', 'WebCore::FrameIdentifier', 'WebCore::IntRect',
                                'WebCore::PageIdentifier', 'bool', 'float', 'double'):
                self.assertIsNone(resolves_to_bare_integer(type_string))

        def test_single_value_wrappers_are_traversed(self):
            self.assertEqual(resolves_to_bare_integer('std::optional<uint64_t>'), 'uint64_t')
            self.assertEqual(resolves_to_bare_integer('Markable<uint32_t>'), 'uint32_t')
            self.assertEqual(resolves_to_bare_integer('std::optional<Markable<int>>'), 'int')

        def test_byte_buffers_are_not_identifiers(self):
            # A container of integers is a buffer or a set, never an object identifier.
            for type_string in ('Vector<uint8_t>', 'Vector<uint64_t>', 'HashSet<uint32_t>',
                                'std::optional<Vector<uint8_t>>'):
                self.assertIsNone(resolves_to_bare_integer(type_string))

        def test_aliases_hiding_an_integer_are_resolved(self):
            # The case a type-name check alone would walk straight past.
            self.assertEqual(resolves_to_bare_integer('WebCore::PointerID'), 'uint32_t')
            self.assertEqual(resolves_to_bare_integer('std::optional<WebCore::PointerID>'), 'uint32_t')
            self.assertEqual(resolves_to_bare_integer('WebCore::PageOverlay::PageOverlayID'), 'uint64_t')

        def test_object_identifiers_are_not_flagged(self):
            for type_string in ('WebCore::FrameIdentifier', 'WebCore::ScrollingNodeID',
                                'IPC::Untrusted<WebCore::PlatformLayerIdentifier>'):
                self.assertIsNone(resolves_to_bare_integer(type_string))

        def test_production_tracking_file_parses(self):
            tracked = BareIntegerIPCTypes()
            self.assertGreater(len(tracked.message_parameters), 100)
            self.assertGreater(len(tracked.struct_members), 100)
            for category in list(tracked.message_parameters.values()) + list(tracked.struct_members.values()):
                self.assertIn(category, VALID_CATEGORIES)

        def test_struct_members_are_tracked_separately_from_parameters(self):
            tracked = BareIntegerIPCTypes()
            self.assertIsNotNone(tracked.category_for_struct_member('PlatformXR::FrameData', 'predictedDisplayTime'))
            # A struct member lookup must not be satisfied by a message parameter entry.
            self.assertIsNone(tracked.category_for_struct_member('AcceleratedBackingStore.Frame', 'id'))

        def test_identifier_raw_value_accessors_are_exempt(self):
            # WTF::ObjectIdentifier { uint64_t toUInt64() } is the correct pattern, so the
            # rule must not demand a justification for it.
            for accessor in ('toUInt64()', 'toRawValue()'):
                self.assertTrue(is_identifier_raw_value_accessor(accessor))
            self.assertFalse(is_identifier_raw_value_accessor('id'))
            self.assertIsNone(BareIntegerIPCTypes().category_for_struct_member('WTF::ObjectIdentifier', 'toUInt64()'))

        def test_known_untyped_identifiers_are_on_the_burn_down_list(self):
            tracked = BareIntegerIPCTypes()
            needs_typing = tracked.needs_typing()
            self.assertIn(('AcceleratedBackingStore.Frame', 'id'), needs_typing)
            # RemoteObjectRegistry's replyID has been converted to RemoteObjectReplyIdentifier,
            # so it must no longer appear here.
            self.assertNotIn(('RemoteObjectRegistry.CallReplyBlock', 'replyID'), needs_typing)

        def test_unknown_category_is_rejected(self):
            import tempfile
            with tempfile.NamedTemporaryFile('w', suffix='.in', delete=False) as handle:
                handle.write('[NotACategory] {\n    Foo.Bar baz\n}\n')
                path = handle.name
            with self.assertRaises(Exception):
                BareIntegerIPCTypes(path)

    unittest.main()
