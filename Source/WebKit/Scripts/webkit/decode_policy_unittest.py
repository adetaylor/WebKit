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

# Tests the decode policy language (decode_policy.py): the C++ and Swift that generate-serializers.py makes of a member's
# Check and Normalize.
#
# python3 Source/WebKit/Scripts/webkit/decode_policy_unittest.py

import importlib.util
import os
import sys
import unittest

module_directory = os.path.dirname(os.path.abspath(__file__))
scripts_directory = os.path.abspath(os.path.join(module_directory, os.path.pardir))
sys.path.append(scripts_directory)

_specification = importlib.util.spec_from_file_location('generate_serializers', os.path.join(scripts_directory, 'generate-serializers.py'))
generate_serializers = importlib.util.module_from_spec(_specification)
_specification.loader.exec_module(generate_serializers)

_geometry = '''
[Swift] class WebCore::IntSize {
    int width();
    int height();
}
[Swift] class WebCore::FloatPoint {
    float x();
    float y();
}
[Swift] enum class WebKit::Kind : uint8_t {
    First,
    HTTPSOnly,
    Default,
}
[OptionSet] enum class WebKit::Flags : uint8_t {
    A,
}
enum class WebKit::CxxOnly : uint8_t {
    A,
}
struct WebKit::Term {
    unsigned index;
}
[Swift] struct WebKit::SwiftTerm {
    unsigned index;
}
[Swift] class WebKit::Private {
    int m_secret;
}
'''


def parse(source):
    serialized_types, serialized_enums, _, using_statements, _, _ = generate_serializers.parse_serialized_types((_geometry + source).splitlines())
    serialized_types = generate_serializers.resolve_inheritance(serialized_types)
    return serialized_types, serialized_enums, using_statements


def generate(source):
    """The C++ decoder of the last type in source, and the Swift forms."""
    serialized_types, serialized_enums, using_statements = parse(source)
    generate_serializers.compile_decode_policies(serialized_types, serialized_enums, using_statements)
    cpp = '\n'.join(generate_serializers.decode_type(serialized_types[-1], serialized_types)) + '\n'
    swift = generate_serializers.generate_swift(serialized_types, serialized_enums, using_statements)
    return cpp, swift


def policies(source):
    """(C++, Swift) of each policy of the last member of the last type in source."""
    serialized_types, serialized_enums, using_statements = parse(source)
    generate_serializers.compile_decode_policies(serialized_types, serialized_enums, using_statements)
    member = serialized_types[-1].members[-1]
    return [(policy.cpp, policy.swift) for policy in member.decode_policies]


def check(members, swift=True):
    """(C++, Swift) of the Check of the last of members, in a struct."""
    marker = '[Swift] ' if swift else ''
    return policies(f'{marker}struct WebKit::S {{\n{members}\n}}\n')[0]


class DecodePolicyLanguageTest(unittest.TestCase):
    def test_members_and_their_members(self):
        self.assertEqual(check("    [Check='size.width > 0 && size.height > 0'] WebCore::IntSize size;"),
                         ('size->width() > 0 && size->height() > 0', 'size.width > 0 && size.height > 0'))
        self.assertEqual(check("    WebCore::IntSize size;\n    [Check='point.x < 1.5 || size.width == 2'] WebCore::FloatPoint point;"),
                         ('point->x() < 1.5f || size->width() == 2', 'point.x < 1.5 || size.width == 2'))

    def test_private_member_names_drop_m_(self):
        self.assertEqual(check("    int32_t m_count;\n    [Check='count >= 0'] int32_t m_other;"),
                         ('*m_count >= 0', 'count >= 0'))

    def test_integers_of_different_types_compare_in_64_bits(self):
        self.assertEqual(check("    uint32_t a;\n    [Check='a < b'] int32_t b;"),
                         ('static_cast<int64_t>(*a) < static_cast<int64_t>(*b)', 'Int64(a) < Int64(b)'))
        self.assertEqual(check("    uint8_t a;\n    [Check='a == b'] uint8_t b;"), ('*a == *b', 'a == b'))

    def test_integer_arithmetic_is_64_bit(self):
        self.assertEqual(check("    WebCore::IntSize size;\n    [Check='size.width * size.height == count(values)'] Vector<float> values;"),
                         ('(static_cast<int64_t>(size->width()) * static_cast<int64_t>(size->height())) == static_cast<int64_t>(values->size())',
                          '(Int64(size.width) * Int64(size.height)) == Int64(values.count)'))
        self.assertEqual(check("    int32_t a;\n    [Check='a + 1 > 0'] int32_t b;"),
                         ('(static_cast<int64_t>(*a) + 1) > 0', '(Int64(a) + 1) > 0'))

    def test_float_literals_are_floats_in_cpp(self):
        self.assertEqual(check("    [Check='value >= 0 && value <= 0.1 && value != -2'] float value;"),
                         ('*value >= 0.0f && *value <= 0.1f && *value != -2.0f', 'value >= 0 && value <= 0.1 && value != -2'))
        self.assertEqual(check("    [Check='value <= 0.1'] double value;"), ('*value <= 0.1', 'value <= 0.1'))

    def test_min_and_max_are_std_min_and_std_max(self):
        self.assertEqual(policies("[Swift] struct WebKit::S {\n    [Normalize='max(0, value)'] float value;\n}\n"),
                         [('(0.0f < *value ? *value : 0.0f)', '(0 < value ? value : 0)')])
        self.assertEqual(policies("[Swift] struct WebKit::S {\n    [Normalize='max(value, 0)'] float value;\n}\n"),
                         [('(*value < 0.0f ? 0.0f : *value)', '(value < 0 ? 0 : value)')])
        self.assertEqual(policies("[Swift] struct WebKit::S {\n    [Normalize='min(value, 1)'] float value;\n}\n"),
                         [('(1.0f < *value ? 1.0f : *value)', '(1 < value ? 1 : value)')])

    def test_normalize_applies_before_check(self):
        self.assertEqual(policies("[Swift] struct WebKit::S {\n    [Check='value > 0', Normalize='value >= 128 ? 128 : value'] float value;\n}\n"),
                         [('*value >= 128.0f ? 128.0f : *value', 'value >= 128 ? 128 : value'), ('*value > 0.0f', 'value > 0')])

    def test_enum_values(self):
        self.assertEqual(check("    [Check='kind == Kind::HTTPSOnly || kind != WebKit::Kind::Default'] WebKit::Kind kind;"),
                         ('*kind == WebKit::Kind::HTTPSOnly || *kind != WebKit::Kind::Default',
                          'kind == IPCTypes.Kind.httpsOnly || kind != IPCTypes.Kind.`default`'))
        self.assertEqual(check("    [Check='kind == CxxOnly::A'] WebKit::CxxOnly kind;", swift=False)[0], '*kind == WebKit::CxxOnly::A')

    def test_conditional(self):
        self.assertEqual(check("    WebKit::Kind kind;\n    [Check='kind == Kind::First ? count(values) == 20 : kind == Kind::Default'] Vector<float> values;"),
                         ('*kind == WebKit::Kind::First ? static_cast<int64_t>(values->size()) == 20 : *kind == WebKit::Kind::Default',
                          'kind == IPCTypes.Kind.first ? Int64(values.count) == 20 : kind == IPCTypes.Kind.`default`'))

    def test_and_within_or_is_parenthesized(self):
        self.assertEqual(check("    [Check='a && !a || a'] bool a;"), ('(*a && !*a) || *a', '(a && !a) || a'))

    def test_all(self):
        self.assertEqual(check("    Vector<float> values;\n    [Check='all(terms, term, term.index < count(values))'] Vector<WebKit::SwiftTerm> terms;"),
                         ('std::ranges::all_of(*terms, [&](auto& term) { return static_cast<int64_t>(term.index) < static_cast<int64_t>(values->size()); })',
                          'terms.allSatisfy({ term in Int64(term.index) < Int64(values.count) })'))

    def test_aliases(self):
        self.assertEqual(policies("using WebKit::Terms = Vector<WebKit::Term>;\nstruct WebKit::S {\n    [Check='count(terms) > 0'] WebKit::Terms terms;\n}\n")[0][0],
                         'static_cast<int64_t>(terms->size()) > 0')

    def test_errors(self):
        for members, message in [
            ("    [Check='other > 0'] int32_t value;", r'other is not a member decoded before this one'),
            ("    [Check='value > 0.5'] int32_t value;", r'mix an integer and a floating-point value'),
            ("    [Check='value > 1 > 0'] int32_t value;", r'comparisons can\'t be chained'),
            ("    [Check='value'] int32_t value;", r'a Check is a condition, not a int32_t'),
            ("    [Check='value * value > 0'] int64_t value;", r'\* takes integers of at most 32 bits'),
            ("    int32_t a;\n    [Check='a < value'] uint64_t value;", r'uint64_t doesn\'t fit in a 64-bit signed integer'),
            ("    [Check='abs(value) > 0'] int32_t value;", r'abs\(\) is not a function of the decode policy language'),
            ("    [Check='count(value) > 0'] int32_t value;", r'count\(\) takes a Vector'),
            ("    [Check='value.width > 0'] int32_t value;", r'only described structs and classes have members'),
            ("    [Check='size.depth > 0'] WebCore::IntSize size;", r'WebCore::IntSize has no serialized member depth'),
            ("    [Check='kind == Kind::Last'] WebKit::Kind kind;", r'Kind has no value Last'),
            ("    [Check='kind == Flags::A'] WebKit::Kind kind;", r'is an OptionSet'),
            ("    [Check='kind == CxxOnly::A'] WebKit::CxxOnly kind;", r'WebKit::CxxOnly has no Swift form'),
            ("    [Check='value != 0'] uint32_t value;\n    [Check='value == -1'] uint32_t other;", r'other is not|negative literal'),
            ("    [Check='other.secret > 0'] WebKit::Private other;", r'is a private member'),
            ("    [Normalize='value > 0'] float value;", r'normalizes value, a float, to a bool'),
            ("    [Normalize='0'] String value;", r'String is not a type a decode policy can use|only integer and floating-point members'),
            ("    [Check='all(terms, terms, true)'] Vector<WebKit::Term> terms;", r'can\'t name its element terms'),
            ("    [Check='value > 0 &'] int32_t value;", r'unexpected'),
        ]:
            with self.subTest(members=members):
                with self.assertRaisesRegex(Exception, message):
                    check(members)


class GeneratedDecodersTest(unittest.TestCase):
    def test_cpp_decoder(self):
        cpp, _ = generate("struct WebKit::S {\n    [Normalize='max(0, value)', Check='value < 10'] float value;\n}\n")
        self.assertIn('    auto value = decoder.decode<float>();\n'
                      '    if (!decoder.isValid()) [[unlikely]]\n'
                      '        return std::nullopt;\n'
                      '    *value = (0.0f < *value ? *value : 0.0f);\n'
                      '    if (!(*value < 10.0f)) {\n'
                      '#if ENABLE(IPC_TESTING_API)\n'
                      '        decoder.setErrorString("Validation failed: value < 10"_s);\n'
                      '#endif\n'
                      '        return std::nullopt;\n'
                      '    }\n', cpp)

    def test_swift_decoder_decodes_into_locals(self):
        _, swift = generate("[Swift] struct WebKit::S {\n    int32_t count;\n    [Normalize='max(0, value)', Check='value < 10'] float value;\n}\n")
        self.assertIn('    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {\n'
                      '        let count = try Int32.decode(from: &decoder)\n'
                      '        var value = try Float.decode(from: &decoder)\n'
                      '        value = (0 < value ? value : 0)\n'
                      '        guard value < 10 else {\n'
                      '            throw IPCDecodingError()\n'
                      '        }\n'
                      '        self.count = count\n'
                      '        self.value = value\n'
                      '    }\n', swift)

    def test_parent_class_members_are_in_scope(self):
        cpp, swift = generate('''
[Swift] class WebKit::Base {
    int32_t limit;
}
[Swift] class WebKit::Derived : WebKit::Base {
    [Check='value <= limit'] int32_t value;
}
''')
        self.assertIn('if (!(*value <= *limit))', cpp)
        self.assertIn('        guard value <= limit else {\n', swift)

    def test_cxx_enum_types(self):
        cpp, swift = generate('''
enum class WebCore::StyleAppearance : uint8_t {
    Button,
    Checkbox,
}
[Swift] struct WebKit::S {
    [Check='type == StyleAppearance::Button'] WebCore::StyleAppearance type;
}
''')
        self.assertIn('if (!(*type == WebCore::StyleAppearance::Button))', cpp)
        self.assertIn('        guard type == WebCore.StyleAppearance.Button else {\n', swift)

    def test_without_policies_the_decoders_are_unchanged(self):
        _, swift = generate("[Swift] struct WebKit::S {\n    int32_t count;\n}\n")
        self.assertIn('        self.count = try Int32.decode(from: &decoder)\n', swift)


if __name__ == '__main__':
    unittest.main()
