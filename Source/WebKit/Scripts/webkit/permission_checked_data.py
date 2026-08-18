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

"""Enforces that sensitive data crossing from a privileged process into a less
privileged one is sent as IPC::PermissionChecked<T>.

A privileged process holds data that the process it is talking to may have no right
to see. Under site isolation a web content process is entitled to the cookies of its
own site and no others, so sending a cookie to it is only correct once someone has
checked that this particular process is permitted to receive that particular cookie.

Wrapping such a parameter in IPC::PermissionChecked<T> makes that obligation part of
the type: the generated message class can only be constructed from a token, and the
only ways to mint one are the pre-ordained permission checks (see
Platform/IPC/PermissionChecked.h) or a justified bypass. Recipients are unaffected -
the wrapper is invisible on the receiving side, and has no decoder at all.

Any unwrapped occurrence must be justified in permission_checked_data.tracking.in.

This mechanism is not specific to cookies. CATEGORIES below is the registry of data
that must be permission checked before it is sent to a less privileged process;
adding a category is how the invariant is extended to something new.
"""

import os
import re


# Categories of sensitive data. Each maps a human-readable reason - used in the build
# error - to the set of type names that convey it. A type belongs here if a privileged
# process can hold a value of it that the process it is sending to may have no right to
# see.
CATEGORIES = {
    'a cookie': {
        'WebCore::Cookie',
        'WebCore::CookieHeaderString',
        'WebKit::WebExtensionCookieParameters',
    },
}

SENSITIVE_TYPES = {type_name for types in CATEGORIES.values() for type_name in types}

# Processes that hold privilege a web content process does not.
PRIVILEGED_PROCESSES = {
    'UI',
    'Networking',
    'GPU',
    'Model',
}

# The least privileged process, and so the one this mechanism protects data from.
UNPRIVILEGED_PROCESS = 'WebContent'

# Containers traversed when looking for sensitive data. Every template parameter is
# examined; a hit anywhere means the parameter conveys sensitive data.
TRAVERSED_CONTAINERS = {
    'Expected',
    'FixedVector',
    'HashCountedSet',
    'HashMap',
    'HashSet',
    'KeyValuePair',
    'Markable',
    'MemoryCompactLookupOnlyRobinHoodHashSet',
    'MemoryCompactRobinHoodHashMap',
    'OptionalTuple',
    'Ref',
    'RefPtr',
    'UniqueRef',
    'Variant',
    'Vector',
    'std::optional',
    'std::pair',
    'std::tuple',
    'std::unique_ptr',
}

PERMISSION_CHECKED_WRAPPER = 'IPC::PermissionChecked'

# Files permitted to declare a pre-ordained permission check by specializing
# IPC::IsPreordainedPermissionChecker. Confining these keeps the set of ways to mint a
# PermissionChecked<T> small and reviewable. Enforced by
# test_preordained_checkers_are_confined below.
PREORDAINED_CHECKER_HEADERS = {
    'NetworkProcess/CookieRecipientAuthority.h',
    'Platform/IPC/PermissionChecked.h',
}

VALID_ATTRIBUTES = {
    # Predates this mechanism and has not been audited. The burn-down list.
    'LegacyNeedsAudit',
    # An equivalent permission check already happens on this code path.
    'CheckedElsewhere',
    # The value is not sensitive in this context.
    'NotSecuritySensitive',
    # Needs a security review before it can be given a final justification.
    'NeedsReview',
}


def _strip_const_and_whitespace(type_str):
    if not type_str:
        return ""
    type_str = type_str.strip()
    if type_str.startswith("const "):
        type_str = type_str[6:].strip()
    return type_str


def _split_template_parameters(parameter_list):
    """Split template parameters, honouring nested angle brackets.

    Example: "HashMap<String, WebCore::Cookie>, int" -> ["HashMap<String, WebCore::Cookie>", "int"]
    """
    parameters = []
    current = ""
    depth = 0

    for character in parameter_list:
        if character == '<':
            depth += 1
            current += character
        elif character == '>':
            depth -= 1
            current += character
        elif character == ',' and not depth:
            parameter = _strip_const_and_whitespace(current)
            if parameter:
                parameters.append(parameter)
            current = ""
        else:
            current += character

    parameter = _strip_const_and_whitespace(current)
    if parameter:
        parameters.append(parameter)

    return parameters


def _split_container(type_str):
    """Return (container_name, parameters) for a template type, else (None, None)."""
    match = re.match(r'^(?P<name>[A-Za-z_][A-Za-z_0-9:]*)<(?P<parameters>.+)>$', type_str)
    if not match:
        return None, None
    return match.group('name'), _split_template_parameters(match.group('parameters'))


def unwrap_permission_checked(type_str):
    """Return the wrapped type if type_str is IPC::PermissionChecked<T>, else None."""
    container, parameters = _split_container(_strip_const_and_whitespace(type_str))
    if container != PERMISSION_CHECKED_WRAPPER or not parameters or len(parameters) != 1:
        return None
    return parameters[0]


def conveys_sensitive_data(type_str, visited=None):
    """Return the sensitive type conveyed by type_str, or None.

    An IPC::PermissionChecked<T> wrapper is transparent here: what matters is whether
    the parameter conveys sensitive data at all, not whether it is already wrapped.
    """
    if visited is None:
        visited = set()

    if type_str in visited:
        return None
    visited.add(type_str)

    clean_type = _strip_const_and_whitespace(type_str)
    if clean_type in SENSITIVE_TYPES:
        return clean_type

    container, parameters = _split_container(clean_type)
    if not container or not parameters:
        return None
    if container != PERMISSION_CHECKED_WRAPPER and container not in TRAVERSED_CONTAINERS:
        return None

    for parameter in parameters:
        result = conveys_sensitive_data(parameter, visited.copy())
        if result is not None:
            return result

    return None


def category_of(type_name):
    """Return the human-readable category of a sensitive type name."""
    for category, types in CATEGORIES.items():
        if type_name in types:
            return category
    return 'sensitive data'


class PermissionCheckedDataEntry(object):
    """A single unwrapped sensitive parameter, with its justification."""

    def __init__(self, attribute, receiver, message, parameter_name, parameter_type, is_reply, docs=None):
        self.attribute = attribute
        self.receiver = receiver
        self.message = message
        self.parameter_name = parameter_name
        self.parameter_type = parameter_type
        self.is_reply = is_reply
        self.docs = docs


class PermissionCheckedData(object):
    def __init__(self, tracking_file_path=None):
        if tracking_file_path is None:
            tracking_file_path = os.path.join(os.path.dirname(__file__), 'permission_checked_data.tracking.in')

        self.message_params = {}

        group_attribute = None
        group_type = None

        with open(tracking_file_path, 'r') as file:
            for line in file:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue

                if line == '}':
                    if group_attribute is None:
                        raise Exception('permission_checked_data.tracking.in unmatched }')
                    group_attribute = None
                    group_type = None
                    continue

                group_header = re.match(r'^\[(?P<attribute>[^\]]+)\]\s+(?P<type>.+?)\s*\{$', line)
                if group_header:
                    if group_attribute is not None:
                        raise Exception('permission_checked_data.tracking.in nested group: %s' % line)
                    group_attribute = group_header.group('attribute').strip()
                    group_type = group_header.group('type').strip()
                    self._validate_attribute(group_attribute, line)
                    continue

                self._add_entry(self._parse_entry(line, group_attribute, group_type))

        if group_attribute is not None:
            raise Exception('permission_checked_data.tracking.in unterminated group')

    def _validate_attribute(self, attribute, line):
        for part in attribute.split(','):
            part = part.strip()
            if part.startswith('Docs='):
                continue
            if part not in VALID_ATTRIBUTES:
                raise Exception("permission_checked_data.tracking.in unknown attribute '%s' in: %s. Valid attributes are: %s"
                                % (part, line, ', '.join(sorted(VALID_ATTRIBUTES))))

    def _parse_entry(self, line, group_attribute, group_type):
        if group_attribute is not None:
            match = re.match(r'^MessageParam(?P<reply>Reply)?\s+(?P<receiver>\w+)\.(?P<message>\w+)\s+(?P<parameter>\w+)$', line)
            if not match:
                raise Exception('permission_checked_data.tracking.in malformed grouped entry: %s. '
                                'Expected format: MessageParam[Reply] Receiver.Message parameterName' % line)
            return PermissionCheckedDataEntry(group_attribute, match.group('receiver'), match.group('message'),
                                              match.group('parameter'), group_type, match.group('reply') is not None)

        match = re.match(r'^\[(?P<attribute>[^\]]+)\]\s+MessageParam(?P<reply>Reply)?\s+(?P<receiver>\w+)\.(?P<message>\w+)'
                         r'\s+(?P<parameter>\w+)\s+(?P<type>.+)$', line)
        if not match:
            raise Exception('permission_checked_data.tracking.in malformed entry: %s. Expected format: '
                            '[Attribute] MessageParam[Reply] Receiver.Message parameterName TypeString' % line)
        self._validate_attribute(match.group('attribute'), line)
        return PermissionCheckedDataEntry(match.group('attribute').strip(), match.group('receiver'), match.group('message'),
                                          match.group('parameter'), match.group('type').strip(), match.group('reply') is not None)

    def _add_entry(self, entry):
        key = ('%s.%s' % (entry.receiver, entry.message), entry.parameter_name, entry.is_reply)
        self.message_params.setdefault(key, []).append(entry)

    def message_param_tracked(self, receiver, message, parameter_name, type_string, is_reply=False):
        key = ('%s.%s' % (receiver, message), parameter_name, is_reply)
        return any(entry.parameter_type == type_string for entry in self.message_params.get(key, []))


try:
    permission_checked_data = PermissionCheckedData()
except FileNotFoundError as error:
    raise Exception('permission_checked_data.tracking.in file not found: %s' % error)


def sends_to_unprivileged_process(receiver):
    """True if this receiver's message parameters travel into the least privileged process."""
    return (receiver.receiver_dispatched_to == UNPRIVILEGED_PROCESS
            and receiver.receiver_dispatched_from in PRIVILEGED_PROCESSES)


def replies_to_unprivileged_process(receiver):
    """True if this receiver's reply parameters travel into the least privileged process.

    A reply travels the opposite way to the message it answers, so a receiver taking
    messages from web content replies back into web content.
    """
    return (receiver.receiver_dispatched_from == UNPRIVILEGED_PROCESS
            and receiver.receiver_dispatched_to in PRIVILEGED_PROCESSES)


if __name__ == '__main__':
    import unittest

    class TestPermissionCheckedData(unittest.TestCase):

        def test_direct_sensitive_types(self):
            for type_string in SENSITIVE_TYPES:
                self.assertEqual(conveys_sensitive_data(type_string), type_string)

        def test_non_sensitive_types(self):
            for type_string in ['String', 'int', 'bool', 'URL', 'WebCore::PageIdentifier',
                                'Vector<String>', 'std::optional<uint64_t>', 'HashMap<String, int>',
                                'WebCore::CookieStoreGetOptions', 'WebCore::CookieChangeSubscription']:
                self.assertIsNone(conveys_sensitive_data(type_string))

        def test_containers(self):
            self.assertEqual(conveys_sensitive_data('Vector<WebCore::Cookie>'), 'WebCore::Cookie')
            self.assertEqual(conveys_sensitive_data('std::optional<Vector<WebCore::Cookie>>'), 'WebCore::Cookie')
            self.assertEqual(conveys_sensitive_data('HashMap<String, WebCore::Cookie>'), 'WebCore::Cookie')
            self.assertEqual(conveys_sensitive_data('Expected<std::optional<WebKit::WebExtensionCookieParameters>, WebKit::WebExtensionError>'),
                             'WebKit::WebExtensionCookieParameters')
            self.assertEqual(conveys_sensitive_data('std::optional<const WebCore::CookieHeaderString>'),
                             'WebCore::CookieHeaderString')

        def test_unknown_containers_are_not_traversed(self):
            self.assertIsNone(conveys_sensitive_data('SomeUnknownTemplate<WebCore::Cookie>'))

        def test_wrapper_is_transparent_to_detection(self):
            self.assertEqual(conveys_sensitive_data('IPC::PermissionChecked<WebCore::Cookie>'), 'WebCore::Cookie')
            self.assertEqual(conveys_sensitive_data('IPC::PermissionChecked<Vector<WebCore::Cookie>>'), 'WebCore::Cookie')

        def test_unwrap_permission_checked(self):
            self.assertEqual(unwrap_permission_checked('IPC::PermissionChecked<WebCore::Cookie>'), 'WebCore::Cookie')
            self.assertEqual(unwrap_permission_checked('IPC::PermissionChecked<Vector<WebCore::Cookie>>'),
                             'Vector<WebCore::Cookie>')
            self.assertIsNone(unwrap_permission_checked('WebCore::Cookie'))
            self.assertIsNone(unwrap_permission_checked('Vector<WebCore::Cookie>'))
            self.assertIsNone(unwrap_permission_checked(''))

        def test_bad_formatting(self):
            for type_string in ['', 'Vector<>', 'Vector', '<WebCore::Cookie>', 'IPC::PermissionChecked<>']:
                self.assertIsNone(conveys_sensitive_data(type_string))
                self.assertIsNone(unwrap_permission_checked(type_string))

        def test_category_of(self):
            self.assertEqual(category_of('WebCore::Cookie'), 'a cookie')
            self.assertEqual(category_of('NoSuchType'), 'sensitive data')

        def test_split_template_parameters(self):
            self.assertEqual(_split_template_parameters('HashMap<String, WebCore::Cookie>, int'),
                             ['HashMap<String, WebCore::Cookie>', 'int'])
            self.assertEqual(_split_template_parameters('WebCore::Cookie'), ['WebCore::Cookie'])
            self.assertEqual(_split_template_parameters(''), [])

        def test_production_tracking_file_parses(self):
            tracked = PermissionCheckedData()
            self.assertGreater(len(tracked.message_params), 0,
                               'permission_checked_data.tracking.in seems to have no entries')

        def test_preordained_checkers_are_confined(self):
            source_root = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', '..'))
            found = set()
            for directory, _, filenames in os.walk(source_root):
                for filename in filenames:
                    if not filename.endswith(('.h', '.cpp', '.mm')):
                        continue
                    path = os.path.join(directory, filename)
                    with open(path, 'r', errors='replace') as source_file:
                        if 'struct IsPreordainedPermissionChecker' in source_file.read():
                            found.add(os.path.relpath(path, source_root))
            self.assertEqual(found, PREORDAINED_CHECKER_HEADERS,
                             'IPC::IsPreordainedPermissionChecker may only be specialized in the headers listed in '
                             'PREORDAINED_CHECKER_HEADERS. Adding a permission check needs a security review.')

        def test_tracking_file_lookup(self):
            test_file = os.path.join(os.path.dirname(__file__), 'tests', 'test_permission_checked_data.tracking.in')
            tracked = PermissionCheckedData(test_file)
            self.assertTrue(tracked.message_param_tracked('TestWithoutAttributes', 'TestLegacyCookie',
                                                          'legacyCookies', 'Vector<WebCore::Cookie>'))
            self.assertFalse(tracked.message_param_tracked('TestWithoutAttributes', 'TestLegacyCookie',
                                                           'legacyCookies', 'WebCore::Cookie'))
            self.assertTrue(tracked.message_param_tracked('TestWithoutAttributes', 'TestLegacyCookieReply',
                                                          'legacyCookies', 'Vector<WebCore::Cookie>', is_reply=True))
            self.assertFalse(tracked.message_param_tracked('TestWithoutAttributes', 'TestLegacyCookieReply',
                                                           'legacyCookies', 'Vector<WebCore::Cookie>'))
            self.assertFalse(tracked.message_param_tracked('NoSuchReceiver', 'NoSuchMessage', 'noSuchParameter',
                                                           'WebCore::Cookie'))

    unittest.main()
