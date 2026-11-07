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

"""The Swift form of IPC types, for Swift receivers of messages that take Swift types.

A C++ type in a .messages.in or .serialization.in file maps to two Swift spellings: the
type a Swift handler sees, and the IPCCoder (SwiftCoding.swift) that decodes and encodes
it in the same wire format as the C++ ArgumentCoder. Types described by .serialization.in
and marked [Swift] are generated into the IPCTypes namespace, and are their own coders.
IPCTypes.CxxName gives each of them a second name made from its qualified C++ name, which
generated message receivers spell coders with, so that a message naming a C++ type that has
no Swift form does not compile, even if another C++ type with the same unqualified name has one.
"""

import re

SWIFT_TYPES_NAMESPACE = 'IPCTypes'
SWIFT_CXX_NAMES = 'CxxName'

_PRIMITIVE_TYPES = {
    'bool': 'Bool',
    'uint8_t': 'UInt8',
    'uint16_t': 'UInt16',
    'uint32_t': 'UInt32',
    'uint64_t': 'UInt64',
    # unsigned is 32 bits on every platform WebKit supports, and is encoded as uint32_t.
    'unsigned': 'UInt32',
    'int8_t': 'Int8',
    'int16_t': 'Int16',
    'int32_t': 'Int32',
    'int64_t': 'Int64',
    'float': 'Float',
    'double': 'Double',
}

# Wire-compatible C++ templates of one type argument: (Swift value type format, coder format).
_SINGLE_ARGUMENT_TEMPLATES = {
    'Vector': ('[%s]', 'IPCCoding.Vector<%s>'),
    'std::optional': ('%s?', 'IPCCoding.StdOptional<%s>'),
    'Markable': ('%s?', 'IPCCoding.Markable<%s>'),
    # A RefPtr is encoded as a std::optional of its pointee.
    'RefPtr': ('%s?', 'IPCCoding.StdOptional<%s>'),
}

# Ref<T> is encoded as T, and OptionSet<E> is the Swift OptionSet generated for E.
_TRANSPARENT_TEMPLATES = ('Ref', 'OptionSet')

# A std::pair is its two members, in order.
_TWO_ARGUMENT_TEMPLATES = {
    'std::pair': ('(%s, %s)', 'IPCCoding.Pair<%s, %s>'),
}

# Types marked [Swift] in a .serialization.in file whose C++ name has no namespace.
_GLOBAL_NAMESPACE_SWIFT_TYPES = frozenset(['WTFLogLevel'])

# C++-decoded values: types whose Swift form is the C++ object itself. Their C++ ArgumentCoder decodes and encodes
# them, through the helpers each coder in IPCCoding.CxxDecoded calls, so Swift accepts exactly what C++ does and
# copies nothing. Ref<T> and RefPtr<T> of them map to T and T?.
_CXX_DECODED_TYPES = {
    'WebCore::SharedBuffer': ('WebCore.SharedBuffer', 'IPCCoding.CxxDecoded.SharedBuffer'),
}


# A [Lent] std::span<const uint8_t> message argument: its bytes are lent to the Swift handler during dispatch, as
# IPC::LentBytes (SwiftCoding.h), rather than copied into a [UInt8]. Generated Swift decodes past them, then lends them
# with the arguments after them decoded.
LENT_BYTES_TYPES = ('std::span<const uint8_t>',)
LENT_BYTES_SWIFT_TYPE = 'IPC.LentBytes'


class UnmappableSwiftType(Exception):
    pass


class UnmappableSwiftCondition(Exception):
    pass


def strip_cpp_type_decorations(cpp_type):
    return re.sub(r'^(?:const\s+|struct\s+|class\s+|enum\s+)+', '', cpp_type.strip()).rstrip('&').strip()


def is_lent_bytes(cpp_type):
    return strip_cpp_type_decorations(cpp_type) in LENT_BYTES_TYPES


def split_template_arguments(arguments):
    result = []
    depth = 0
    current = ''
    for character in arguments:
        if character == '<':
            depth += 1
        elif character == '>':
            depth -= 1
        if character == ',' and not depth:
            result.append(current.strip())
            current = ''
            continue
        current += character
    result.append(current.strip())
    return result


def swift_cxx_name(cpp_name):
    """The name in IPCTypes.CxxName of the Swift form of a qualified C++ type, like WebCore_FrameIdentifier."""
    return cpp_name.removeprefix('::').replace('::', '_')


def swift_type_and_coder(cpp_type, cxx_name_coders=True):
    """Returns (Swift value type, Swift IPCCoder type) for a C++ IPC type, or raises UnmappableSwiftType.

    With cxx_name_coders, the coder of a type in IPCTypes is spelled by its C++ name, as IPCTypes.CxxName.NS_T."""
    cpp_type = strip_cpp_type_decorations(cpp_type)

    if cpp_type in _PRIMITIVE_TYPES:
        swift_type = _PRIMITIVE_TYPES[cpp_type]
        return (swift_type, swift_type)

    # An AtomString is encoded as its String.
    if cpp_type in ('String', 'WTF::String', 'AtomString', 'WTF::AtomString'):
        return ('String?', 'IPCCoding.WTFString')

    # A Seconds is encoded as its value, a double, which Swift takes as the seconds it is.
    if cpp_type in ('Seconds', 'WTF::Seconds'):
        return ('Double', 'Double')

    # A UTF8CString is encoded as the span of its bytes, which Swift takes a copy of, as of a Vector of them.
    if cpp_type in ('UTF8CString', 'WTF::UTF8CString'):
        return ('[UInt8]', 'IPCCoding.Vector<UInt8>')

    if cpp_type.removeprefix('::') in _CXX_DECODED_TYPES:
        return _CXX_DECODED_TYPES[cpp_type.removeprefix('::')]

    match = re.match(r'^([A-Za-z_][A-Za-z_0-9:]*)<(.+)>$', cpp_type)
    if match:
        template, arguments = match.group(1), split_template_arguments(match.group(2))
        template = re.sub(r'^WTF::', '', template)
        if template in _TWO_ARGUMENT_TEMPLATES and len(arguments) == 2:
            value_format, coder_format = _TWO_ARGUMENT_TEMPLATES[template]
            first_type, first_coder = swift_type_and_coder(arguments[0], cxx_name_coders)
            second_type, second_coder = swift_type_and_coder(arguments[1], cxx_name_coders)
            return (value_format % (first_type, second_type), coder_format % (first_coder, second_coder))
        if template in _SINGLE_ARGUMENT_TEMPLATES and (len(arguments) == 1 or template == 'Markable'):
            value_format, coder_format = _SINGLE_ARGUMENT_TEMPLATES[template]
            inner_type, inner_coder = swift_type_and_coder(arguments[0], cxx_name_coders)
            return (value_format % inner_type, coder_format % inner_coder)
        if template in _TRANSPARENT_TEMPLATES and len(arguments) == 1:
            return swift_type_and_coder(arguments[0], cxx_name_coders)
        # A span of const primitives is encoded as a Vector of them is, so Swift takes a copy of its elements.
        if template == 'std::span' and len(arguments) == 1 and arguments[0].startswith('const ') and arguments[0].removeprefix('const ').strip() in _PRIMITIVE_TYPES:
            element = _PRIMITIVE_TYPES[arguments[0].removeprefix('const ').strip()]
            return ('[%s]' % element, 'IPCCoding.Vector<%s>' % element)
        raise UnmappableSwiftType("'%s' has no Swift form: %s<> is not supported in messages that take Swift types." % (cpp_type, template))

    if cpp_type.removeprefix('::') in _GLOBAL_NAMESPACE_SWIFT_TYPES:
        swift_type = '%s.%s' % (SWIFT_TYPES_NAMESPACE, cpp_type.removeprefix('::'))
        if not cxx_name_coders:
            return (swift_type, swift_type)
        return (swift_type, '%s.%s.%s' % (SWIFT_TYPES_NAMESPACE, SWIFT_CXX_NAMES, swift_cxx_name(cpp_type)))

    # A leading :: qualifies a name from the global namespace, as .messages.in and .serialization.in files write the
    # types of namespaces that WebKit also has, like ::WebGPU.
    qualified_type = cpp_type.removeprefix('::')
    match = re.match(r'^(?:[A-Za-z_][A-Za-z_0-9]*::)+([A-Za-z_][A-Za-z_0-9]*)$', qualified_type)
    if match and not qualified_type.startswith('WTF::') and not qualified_type.startswith('std::'):
        swift_type = '%s.%s' % (SWIFT_TYPES_NAMESPACE, match.group(1))
        if not cxx_name_coders:
            return (swift_type, swift_type)
        return (swift_type, '%s.%s.%s' % (SWIFT_TYPES_NAMESPACE, SWIFT_CXX_NAMES, swift_cxx_name(cpp_type)))

    raise UnmappableSwiftType("'%s' has no Swift form. Messages that take Swift types support integers, bool, float, "
                              "double, Seconds, String, AtomString, Vector, std::span of const primitives, std::optional, std::pair, Markable, Ref, RefPtr, OptionSet, "
                              "types marked [Swift] in a .serialization.in file, and the C++-decoded types %s." % (cpp_type, ', '.join(sorted(_CXX_DECODED_TYPES))))


def swift_coder(cpp_type):
    return swift_type_and_coder(cpp_type)[1]


_SWIFT_CONDITION_MACROS = {
    'ENABLE': 'ENABLE_%s',
    'HAVE': 'HAVE_%s',
    'USE': 'USE_%s',
    'PLATFORM': 'WTF_PLATFORM_%s',
}

_SWIFT_CONDITION_MACRO_PREFIXES = ('ENABLE_', 'HAVE_', 'USE_', 'WTF_PLATFORM_', 'ASSERT_')


def swift_condition(cpp_condition):
    """Translates a preprocessor condition to a Swift #if condition, or raises UnmappableSwiftCondition.

    Swift sees only some of the HAVE_/USE_/ENABLE_/WTF_PLATFORM_/ASSERT_ macros that are true for C++
    (generate-platform-args), and nothing else, so a condition can differ between Swift and C++. Use it only where
    that difference fails to build, never to choose what is decoded."""
    def replace(match):
        macro, argument = match.group(1), match.group(2)
        if macro not in _SWIFT_CONDITION_MACROS:
            raise UnmappableSwiftCondition("'%s' cannot be evaluated in Swift: %s() is not available there." % (cpp_condition, macro))
        return _SWIFT_CONDITION_MACROS[macro] % argument

    result = re.sub(r'\b([A-Za-z_][A-Za-z_0-9]*)\(\s*([A-Za-z_0-9]+)\s*\)', replace, cpp_condition)
    if re.search(r'[A-Za-z_0-9]\s*\(', result):
        raise UnmappableSwiftCondition("'%s' cannot be evaluated in Swift." % cpp_condition)
    for token in re.findall(r'[A-Za-z_0-9]+|&&|\|\||[^\s]', result):
        if re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', token):
            if not token.startswith(_SWIFT_CONDITION_MACRO_PREFIXES):
                raise UnmappableSwiftCondition("'%s' cannot be evaluated in Swift: %s is not available there." % (cpp_condition, token))
        elif token not in ('!', '&&', '||', '(', ')'):
            raise UnmappableSwiftCondition("'%s' cannot be evaluated in Swift." % cpp_condition)
    return result
