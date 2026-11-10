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

"""A member's decode policy in a .serialization.in file: the checks and normalisations of its value, written once in a
small expression language that generate-serializers.py translates into both the C++ decoder and, for a type marked
[Swift], the Swift form's decoder, so that the two decode alike.

    [Check='kernelSize.width > 0 && kernelSize.height > 0'] WebCore::IntSize kernelSize();
    [Normalize='max(0, radiusX)'] float radiusX();

A Check is a condition the decoded value must meet; a Normalize replaces the decoded value with the expression's value.
They apply in the order they are written. Each sees the members decoded so far, by the names their Swift forms have (no
m_ prefix, no parentheses), the member itself included.

The language:
  - literals: integers, decimals, true, false;
  - members and their members: kernelSize.width names IntSize's width(); a member of a described struct or class;
  - enum values: ColorMatrixType::FECOLORMATRIX_TYPE_MATRIX, for an enum described in a .serialization.in file;
  - ! && || ?:, == != < <= > >=, + - * and unary -, with C's precedence, and parentheses;
  - count(v): the number of elements of a Vector;
  - min(a, b) and max(a, b): as std::min and std::max, (b < a ? b : a) and (a < b ? b : a), so their result for NaN and
    signed zeros is the same in both languages;
  - all(v, element, condition): whether the condition holds for each element of a Vector.

Integer arithmetic is done in 64 bits, from operands of at most 32 bits for *, so that it never overflows. Integers of
different types are compared as 64-bit integers. Decimal literals compared with or computed with a float are floats in
both languages."""

import re

from webkit import swift_types


class DecodePolicyError(Exception):
    pass


# (bits, signed, Swift type) of each C++ integer type.
_INTEGER_TYPES = {
    'int8_t': (8, True, 'Int8'),
    'uint8_t': (8, False, 'UInt8'),
    'int16_t': (16, True, 'Int16'),
    'uint16_t': (16, False, 'UInt16'),
    'int': (32, True, 'Int32'),
    'int32_t': (32, True, 'Int32'),
    'unsigned': (32, False, 'UInt32'),
    'unsigned int': (32, False, 'UInt32'),
    'uint32_t': (32, False, 'UInt32'),
    'int64_t': (64, True, 'Int64'),
    'uint64_t': (64, False, 'UInt64'),
}

_FLOAT_TYPES = {
    'float': 'Float',
    'double': 'Double',
}


class PolicyType(object):
    """The type of an expression. kind is 'bool', 'integer', 'float', 'integer_literal', 'decimal_literal', 'enum',
    'struct' or 'vector'."""
    def __init__(self, kind, cpp=None, swift=None, bits=None, signed=None, description=None, element=None, via_pointer=False):
        self.kind = kind
        self.cpp = cpp
        self.swift = swift
        self.bits = bits
        self.signed = signed
        self.description = description
        self.element = element
        # A Ref of a struct, whose members C++ reaches with ->.
        self.via_pointer = via_pointer

    def is_numeric(self):
        return self.kind in ('integer', 'float', 'integer_literal', 'decimal_literal')

    def is_integral(self):
        return self.kind in ('integer', 'integer_literal')

    def name(self):
        return self.cpp or self.kind


_BOOL = PolicyType('bool', 'bool', 'Bool')
_INT64 = PolicyType('integer', 'int64_t', 'Int64', 64, True)
_INTEGER_LITERAL = PolicyType('integer_literal')
_DECIMAL_LITERAL = PolicyType('decimal_literal')


class TypeIndex(object):
    """The described types, enums and aliases that member types are resolved against."""
    def __init__(self, serialized_types, serialized_enums, using_statements):
        self.types = {}
        for type in serialized_types:
            if not type.templates:
                self.types.setdefault(type.namespace_and_name().removeprefix('::'), type)
        self.enums = {}
        for enum in serialized_enums:
            self.enums.setdefault(enum.namespace_and_name().removeprefix('::'), enum)
        self.aliases = {}
        for using_statement in using_statements:
            if len(using_statement.alias_lines) == 1:
                self.aliases.setdefault(using_statement.name.removeprefix('::'), using_statement.alias_lines[0].strip().rstrip(';'))

    def enum_named(self, name):
        name = name.removeprefix('::')
        if name in self.enums:
            return self.enums[name]
        matches = [enum for qualified_name, enum in self.enums.items() if qualified_name.rsplit('::', 1)[-1] == name or qualified_name.endswith('::' + name)]
        if len(matches) == 1:
            return matches[0]
        if matches:
            raise DecodePolicyError(f'{name} names more than one described enum; qualify it.')
        return None

    def resolve(self, cpp_type, depth=0):
        cpp_type = swift_types.strip_cpp_type_decorations(cpp_type).removeprefix('::')
        if depth > 8:
            raise DecodePolicyError(f'{cpp_type} is an alias of itself.')
        if cpp_type == 'bool':
            return _BOOL
        if cpp_type in _INTEGER_TYPES:
            bits, signed, swift = _INTEGER_TYPES[cpp_type]
            return PolicyType('integer', cpp_type, swift, bits, signed)
        if cpp_type in _FLOAT_TYPES:
            return PolicyType('float', cpp_type, _FLOAT_TYPES[cpp_type], 32 if cpp_type == 'float' else 64)
        match = re.fullmatch(r'(?:WTF::)?Vector<(.+)>', cpp_type)
        if match:
            arguments = swift_types.split_template_arguments(match.group(1))
            return PolicyType('vector', cpp_type, element=self.resolve(arguments[0], depth + 1))
        match = re.fullmatch(r'(?:WTF::)?Ref<(.+)>', cpp_type)
        if match:
            pointee = self.resolve(match.group(1), depth + 1)
            if pointee.kind != 'struct':
                raise DecodePolicyError(f'{cpp_type}: only a Ref of a described struct or class can be used in a decode policy.')
            return PolicyType('struct', pointee.cpp, description=pointee.description, via_pointer=True)
        if cpp_type in self.aliases:
            return self.resolve(self.aliases[cpp_type], depth + 1)
        if cpp_type in self.enums:
            return PolicyType('enum', cpp_type, description=self.enums[cpp_type])
        if cpp_type in self.types:
            return PolicyType('struct', cpp_type, description=self.types[cpp_type])
        raise DecodePolicyError(f'{cpp_type} is not a type a decode policy can use: a bool, an integer, a float, a Vector, or a struct, class or enum described in a .serialization.in file.')


# Tokens: decimals and integers, names, :: . , ( ) ? : and the operators.
_TOKEN = re.compile(r'\s*(?:(\d+\.\d+|\d+)|([A-Za-z_][A-Za-z_0-9]*)|(::|==|!=|<=|>=|&&|\|\||[-+*<>!?:.,()]))')


def tokenize(source):
    tokens = []
    position = 0
    source = source.rstrip()
    while position < len(source):
        match = _TOKEN.match(source, position)
        if not match:
            raise DecodePolicyError(f"'{source}': unexpected '{source[position:].strip()[:1]}'.")
        number, name, symbol = match.groups()
        if number is not None:
            tokens.append(('decimal' if '.' in number else 'integer', number))
        elif name is not None:
            tokens.append(('name', name))
        else:
            tokens.append(('symbol', symbol))
        position = match.end()
    tokens.append(('end', None))
    return tokens


class Node(object):
    def __init__(self, kind, *children, value=None):
        self.kind = kind
        self.children = list(children)
        self.value = value


_COMPARISONS = ('==', '!=', '<', '<=', '>', '>=')


class Parser(object):
    def __init__(self, source):
        self.source = source
        self.tokens = tokenize(source)
        self.position = 0

    def peek(self, value=None):
        kind, token = self.tokens[self.position]
        if value is None:
            return token
        return kind == 'symbol' and token == value

    def take(self, value=None):
        kind, token = self.tokens[self.position]
        if value is not None and not (kind == 'symbol' and token == value):
            raise DecodePolicyError(f"'{self.source}': expected '{value}'" + (f", not '{token}'." if token is not None else ' at the end.'))
        self.position += 1
        return kind, token

    def parse(self):
        node = self.ternary()
        if self.tokens[self.position][0] != 'end':
            raise DecodePolicyError(f"'{self.source}': unexpected '{self.peek()}'.")
        return node

    def ternary(self):
        condition = self.disjunction()
        if self.peek('?'):
            self.take('?')
            if_true = self.ternary()
            self.take(':')
            if_false = self.ternary()
            return Node('?:', condition, if_true, if_false)
        return condition

    def disjunction(self):
        node = self.conjunction()
        while self.peek('||'):
            self.take()
            node = Node('||', node, self.conjunction())
        return node

    def conjunction(self):
        node = self.comparison()
        while self.peek('&&'):
            self.take()
            node = Node('&&', node, self.comparison())
        return node

    def comparison(self):
        node = self.sum()
        if self.tokens[self.position][0] == 'symbol' and self.peek() in _COMPARISONS:
            _, operator = self.take()
            node = Node(operator, node, self.sum())
            if self.tokens[self.position][0] == 'symbol' and self.peek() in _COMPARISONS:
                raise DecodePolicyError(f"'{self.source}': comparisons can't be chained; use &&.")
        return node

    def sum(self):
        node = self.product()
        while self.peek('+') or self.peek('-'):
            _, operator = self.take()
            node = Node(operator, node, self.product())
        return node

    def product(self):
        node = self.unary()
        while self.peek('*'):
            self.take()
            node = Node('*', node, self.unary())
        return node

    def unary(self):
        if self.peek('!'):
            self.take()
            return Node('!', self.unary())
        if self.peek('-'):
            self.take()
            return Node('negate', self.unary())
        return self.postfix()

    def postfix(self):
        node = self.primary()
        while self.peek('.'):
            self.take()
            kind, name = self.take()
            if kind != 'name':
                raise DecodePolicyError(f"'{self.source}': expected a member name after '.'.")
            node = Node('member', node, value=name)
        return node

    def primary(self):
        kind, token = self.take()
        if kind in ('integer', 'decimal'):
            return Node(kind, value=token)
        if kind == 'symbol' and token == '(':
            node = self.ternary()
            self.take(')')
            return Node('()', node)
        if kind != 'name':
            raise DecodePolicyError(f"'{self.source}': unexpected '{token}'." if token is not None else f"'{self.source}': unexpected end.")
        if token in ('true', 'false'):
            return Node('bool', value=token)
        if self.peek('('):
            self.take('(')
            arguments = []
            if not self.peek(')'):
                arguments.append(self.ternary())
                while self.peek(','):
                    self.take()
                    arguments.append(self.ternary())
            self.take(')')
            return Node('call', *arguments, value=token)
        if self.peek('::'):
            names = [token]
            while self.peek('::'):
                self.take()
                kind, name = self.take()
                if kind != 'name':
                    raise DecodePolicyError(f"'{self.source}': expected a name after '::'.")
                names.append(name)
            return Node('enum_value', value='::'.join(names))
        return Node('name', value=token)


class Scope(object):
    """The names an expression can use: the members decoded so far, and the elements all() binds."""
    def __init__(self, index, members):
        """members: (name, C++ variable, C++ type) of each decoded member."""
        self.index = index
        # name -> (C++ type or PolicyType, the C++ variable of a decoded member, which C++ holds in a std::optional, or
        # None). Only the members an expression names need types it can use.
        self.names = {name: (cpp_type, variable) for name, variable, cpp_type in members}

    def lookup(self, name):
        """(PolicyType, C++ variable or None) of a name, or None."""
        if name not in self.names:
            return None
        policy_type, variable = self.names[name]
        if not isinstance(policy_type, PolicyType):
            policy_type = self.index.resolve(policy_type)
        return policy_type, variable

    def bind(self, name, policy_type):
        scope = Scope.__new__(Scope)
        scope.index = self.index
        scope.names = dict(self.names)
        scope.names[name] = (policy_type, None)
        return scope


def _member_of(description, name):
    """The member of a described struct or class whose Swift form is named name: (C++ spelling of its access, type)."""
    type = description
    while type is not None:
        for member in type.members:
            if 'NotSerialized' in [attribute.split('=')[0] for attribute in member.attributes if attribute]:
                continue
            match = re.fullmatch(r'(m_)?([A-Za-z_][A-Za-z0-9_]*)(\(\))?', member.name)
            if match and match.group(2) == name:
                if match.group(1) and not match.group(3):
                    raise DecodePolicyError(f'{description.namespace_and_name()}::{member.name} is a private member, which C++ decoders can\'t read.')
                return (f'{match.group(2)}()' if match.group(3) else match.group(2)), member.type
        type = type.parent_class
    raise DecodePolicyError(f'{description.namespace_and_name()} has no serialized member {name}.')


def _swift_identifier(name, keywords):
    return f'`{name}`' if name in keywords else name


class Emitted(object):
    def __init__(self, cpp, swift, type):
        self.cpp = cpp
        self.swift = swift
        self.type = type


class Translator(object):
    """Translates a parsed expression into C++ and Swift, checking its types. Swift spellings are made only when
    `swift` is set, since only types marked [Swift] have Swift forms."""
    def __init__(self, source, swift):
        self.source = source
        # The generator's Swift naming: keywords, and the Swift spelling of an enum value.
        self.swift = swift
        self.swift_keywords = swift.keywords if swift else frozenset()

    def error(self, message):
        return DecodePolicyError(f"'{self.source}': {message}")

    def translate(self, node, scope):
        method = getattr(self, 'translate_' + {'?:': 'ternary', '||': 'logical', '&&': 'logical', '!': 'not', 'negate': 'negate',
                                               '()': 'parenthesized', '+': 'arithmetic', '-': 'arithmetic', '*': 'arithmetic'}.get(node.kind, node.kind if node.kind not in _COMPARISONS else 'comparison'))
        return method(node, scope)

    def translate_integer(self, node, scope):
        return Emitted(node.value, node.value, _INTEGER_LITERAL)

    def translate_decimal(self, node, scope):
        return Emitted(node.value, node.value, _DECIMAL_LITERAL)

    def translate_bool(self, node, scope):
        return Emitted(node.value, node.value, _BOOL)

    def translate_parenthesized(self, node, scope):
        inner = self.translate(node.children[0], scope)
        return Emitted(f'({inner.cpp})', f'({inner.swift})', inner.type)

    def translate_name(self, node, scope):
        found = scope.lookup(node.value)
        if found is None:
            raise self.error(f'{node.value} is not a member decoded before this one, or an element all() names.')
        policy_type, variable = found
        swift = _swift_identifier(node.value, self.swift_keywords)
        if variable is not None:
            return Emitted(f'*{variable}', swift, policy_type)
        return Emitted(node.value, swift, policy_type)

    def translate_member(self, node, scope):
        base_node = node.children[0]
        base = self.translate(base_node, scope)
        if base.type.kind != 'struct':
            raise self.error(f'{node.value}: only described structs and classes have members, not {base.type.name()}.')
        access, cpp_type = _member_of(base.type.description, node.value)
        member_type = scope.index.resolve(cpp_type)
        variable = scope.lookup(base_node.value)[1] if base_node.kind == 'name' else None
        if variable is not None:
            # A decoded member, which C++ holds in a std::optional.
            cpp = f'(*{variable})->{access}' if base.type.via_pointer else f'{variable}->{access}'
        else:
            cpp = f'{base.cpp}->{access}' if base.type.via_pointer else f'{base.cpp}.{access}'
        if self.swift and not base.type.description.swift:
            raise self.error(f'{base.type.cpp} has no Swift form, so a type marked [Swift] can\'t check its members.')
        return Emitted(cpp, f'{base.swift}.{_swift_identifier(node.value, self.swift_keywords)}', member_type)

    def translate_enum_value(self, node, scope):
        enum_name, _, value = node.value.rpartition('::')
        enum = scope.index.enum_named(enum_name)
        if enum is None:
            raise self.error(f'{enum_name} is not an enum described in a .serialization.in file.')
        if enum.is_option_set():
            raise self.error(f'{enum_name} is an OptionSet, whose values a decode policy can\'t use.')
        if value not in [enum_value.name for enum_value in enum.valid_values]:
            raise self.error(f'{enum_name} has no value {value} in its description.')
        cpp_name = enum.namespace_and_name().removeprefix('::')
        swift = self.swift.enum_value(enum, value) if self.swift else None
        return Emitted(f'{cpp_name}::{value}', swift, PolicyType('enum', cpp_name, description=enum))

    def translate_not(self, node, scope):
        operand = self.expect_bool(node.children[0], scope)
        return Emitted(f'!{operand.cpp}', f'!{operand.swift}', _BOOL)

    def translate_negate(self, node, scope):
        operand = self.translate(node.children[0], scope)
        if operand.type.kind not in ('integer_literal', 'decimal_literal', 'float'):
            raise self.error('only literals and floats can be negated; integers would need 64 bits first.')
        return Emitted(f'-{operand.cpp}', f'-{operand.swift}', operand.type)

    def expect_bool(self, node, scope):
        emitted = self.translate(node, scope)
        if emitted.type.kind != 'bool':
            raise self.error(f'expected a condition, not a {emitted.type.name()}.')
        return emitted

    def translate_logical(self, node, scope):
        operands = []
        for child in node.children:
            operand = self.expect_bool(child, scope)
            # C++ compilers warn about && within || without parentheses.
            if node.kind == '||' and child.kind == '&&':
                operand = Emitted(f'({operand.cpp})', f'({operand.swift})', _BOOL)
            operands.append(operand)
        left, right = operands
        return Emitted(f'{left.cpp} {node.kind} {right.cpp}', f'{left.swift} {node.kind} {right.swift}', _BOOL)

    def translate_ternary(self, node, scope):
        condition = self.expect_bool(node.children[0], scope)
        if_true = self.translate(node.children[1], scope)
        if_false = self.translate(node.children[2], scope)
        if_true, if_false, result_type = self.unify(if_true, if_false, 'the branches of ?:')
        return Emitted(f'{condition.cpp} ? {if_true.cpp} : {if_false.cpp}', f'{condition.swift} ? {if_true.swift} : {if_false.swift}', result_type)

    def unify(self, left, right, what):
        """The two operands converted to one type, and that type."""
        lt, rt = left.type, right.type
        if lt.kind == 'bool' and rt.kind == 'bool':
            return left, right, _BOOL
        if lt.kind == 'enum' or rt.kind == 'enum':
            if lt.kind != 'enum' or rt.kind != 'enum' or lt.cpp != rt.cpp:
                raise self.error(f'{what} have different types: {lt.name()} and {rt.name()}.')
            return left, right, lt
        if not lt.is_numeric() or not rt.is_numeric():
            raise self.error(f'{what} have types that can\'t be compared or combined: {lt.name()} and {rt.name()}.')
        if lt.kind == 'float' or rt.kind == 'float' or lt.kind == 'decimal_literal' or rt.kind == 'decimal_literal':
            float_types = [t for t in (lt, rt) if t.kind == 'float']
            if any(t.kind == 'integer' for t in (lt, rt)):
                raise self.error(f'{what} mix an integer and a floating-point value: {lt.name()} and {rt.name()}.')
            if len(float_types) == 2 and float_types[0].cpp != float_types[1].cpp:
                raise self.error(f'{what} mix float and double.')
            if not float_types:
                raise self.error(f'{what} are both literals; one must be a member.')
            float_type = float_types[0]
            return self.as_float(left, float_type), self.as_float(right, float_type), float_type
        # Integers.
        if lt.kind == 'integer_literal' and rt.kind == 'integer_literal':
            return left, right, _INTEGER_LITERAL
        if lt.kind == 'integer_literal' or rt.kind == 'integer_literal':
            typed, literal = (rt, left) if lt.kind == 'integer_literal' else (lt, right)
            if not typed.signed and literal.cpp.startswith('-'):
                raise self.error(f'{what} compare an unsigned integer with a negative literal.')
            return left, right, typed
        if lt.bits == rt.bits and lt.signed == rt.signed:
            return left, right, lt
        return self.as_int64(left), self.as_int64(right), _INT64

    def as_float(self, emitted, float_type):
        if emitted.type.kind in ('integer_literal', 'decimal_literal') and float_type.cpp == 'float':
            literal = emitted.cpp
            negative = literal.startswith('-')
            digits = literal.lstrip('-')
            cpp = ('-' if negative else '') + (f'{digits}f' if '.' in digits else f'{digits}.0f')
            return Emitted(cpp, emitted.swift, float_type)
        return emitted

    def as_int64(self, emitted):
        if emitted.type.kind == 'integer_literal' or (emitted.type.kind == 'integer' and emitted.type.bits == 64 and emitted.type.signed):
            return emitted
        if emitted.type.kind == 'integer' and emitted.type.bits == 64:
            raise self.error(f'{emitted.type.name()} doesn\'t fit in a 64-bit signed integer, so can\'t be compared with other integer types.')
        return Emitted(f'static_cast<int64_t>({emitted.cpp})', f'Int64({emitted.swift})', _INT64)

    def translate_comparison(self, node, scope):
        left = self.translate(node.children[0], scope)
        right = self.translate(node.children[1], scope)
        left, right, operand_type = self.unify(left, right, f'the operands of {node.kind}')
        if operand_type.kind in ('bool', 'enum') and node.kind not in ('==', '!='):
            raise self.error(f'{operand_type.name()} values can only be compared with == and !=.')
        return Emitted(f'{left.cpp} {node.kind} {right.cpp}', f'{left.swift} {node.kind} {right.swift}', _BOOL)

    def translate_arithmetic(self, node, scope):
        left = self.translate(node.children[0], scope)
        right = self.translate(node.children[1], scope)
        if left.type.is_integral() and right.type.is_integral():
            if node.kind == '*':
                for operand in (left, right):
                    if operand.type.kind == 'integer' and operand.type.bits > 32:
                        raise self.error('* takes integers of at most 32 bits, so that the 64-bit product never overflows.')
            if left.type.kind == 'integer_literal' and right.type.kind == 'integer_literal':
                raise self.error('arithmetic on two literals; write the result.')
            left, right = self.as_int64(left), self.as_int64(right)
            return Emitted(f'({left.cpp} {node.kind} {right.cpp})', f'({left.swift} {node.kind} {right.swift})', _INT64)
        left, right, result_type = self.unify(left, right, f'the operands of {node.kind}')
        if result_type.kind != 'float':
            raise self.error(f'{node.kind} takes numbers.')
        return Emitted(f'({left.cpp} {node.kind} {right.cpp})', f'({left.swift} {node.kind} {right.swift})', result_type)

    def translate_call(self, node, scope):
        name = node.value
        arguments = node.children
        if name == 'count':
            self.expect_arguments(name, arguments, 1)
            vector = self.translate(arguments[0], scope)
            if vector.type.kind != 'vector':
                raise self.error(f'count() takes a Vector, not a {vector.type.name()}.')
            cpp = vector.cpp[1:] + '->size()' if vector.cpp.startswith('*') else f'{vector.cpp}.size()'
            return Emitted(f'static_cast<int64_t>({cpp})', f'Int64({vector.swift}.count)', _INT64)
        if name in ('min', 'max'):
            self.expect_arguments(name, arguments, 2)
            a, b = self.translate(arguments[0], scope), self.translate(arguments[1], scope)
            a, b, result_type = self.unify(a, b, f'the arguments of {name}()')
            if result_type.kind in ('bool', 'enum') or result_type.kind.endswith('literal'):
                raise self.error(f'{name}() takes a member and a number.')
            if name == 'max':
                return Emitted(f'({a.cpp} < {b.cpp} ? {b.cpp} : {a.cpp})', f'({a.swift} < {b.swift} ? {b.swift} : {a.swift})', result_type)
            return Emitted(f'({b.cpp} < {a.cpp} ? {b.cpp} : {a.cpp})', f'({b.swift} < {a.swift} ? {b.swift} : {a.swift})', result_type)
        if name == 'all':
            self.expect_arguments(name, arguments, 3)
            vector = self.translate(arguments[0], scope)
            if vector.type.kind != 'vector':
                raise self.error(f'all() takes a Vector, not a {vector.type.name()}.')
            if arguments[1].kind != 'name':
                raise self.error('the second argument of all() names the element.')
            element = arguments[1].value
            if element in scope.names:
                raise self.error(f'all() can\'t name its element {element}, which is already a name.')
            condition = self.expect_bool(arguments[2], scope.bind(element, vector.type.element))
            return Emitted(f'std::ranges::all_of({vector.cpp}, [&](auto& {element}) {{ return {condition.cpp}; }})',
                           f'{vector.swift}.allSatisfy({{ {element} in {condition.swift} }})', _BOOL)
        raise self.error(f'{name}() is not a function of the decode policy language: count, min, max and all are.')

    def expect_arguments(self, name, arguments, count):
        if len(arguments) != count:
            raise self.error(f'{name}() takes {count} argument' + ('s.' if count > 1 else '.'))


class CompiledPolicy(object):
    """A Check or Normalize of a member: its source, and its C++ and Swift spellings (Swift only for [Swift] types)."""
    def __init__(self, kind, source, cpp, swift):
        self.kind = kind
        self.source = source
        self.cpp = cpp
        self.swift = swift


POLICY_ATTRIBUTES = ('Check', 'Normalize')


def policy_attributes(member):
    """(kind, source) of each Check and Normalize of a member, in the order they are written."""
    result = []
    for attribute in member.attributes:
        match = re.fullmatch(r"(Check|Normalize)='(.*)'", attribute)
        if match:
            result.append((match.group(1), match.group(2)))
        elif attribute.split('=')[0] in POLICY_ATTRIBUTES:
            raise DecodePolicyError(f"{attribute}: write {attribute.split('=')[0]}='<expression>'.")
    return result


class SwiftNaming(object):
    """How the generator names Swift forms: its keywords, and enum_value(enum, value), the Swift spelling of an enum value,
    which raises DecodePolicyError for an enum without a Swift form."""
    def __init__(self, keywords, enum_value):
        self.keywords = keywords
        self.enum_value = enum_value


def compile_member_policy(kind, source, index, members_so_far, member, swift=None):
    """Compiles one Check or Normalize of a member. members_so_far: (name, C++ variable, C++ type) of the members decoded
    before it; member: its own. swift: a SwiftNaming, for a type marked [Swift], whose Swift form decodes with the policy
    too."""
    member_name, _, member_cpp_type = member
    scope = Scope(index, list(members_so_far) + [member])
    translator = Translator(source, swift)
    emitted = translator.translate(Parser(source).parse(), scope)
    if kind == 'Check':
        if emitted.type.kind != 'bool':
            raise DecodePolicyError(f"'{source}': a Check is a condition, not a {emitted.type.name()}.")
        return CompiledPolicy(kind, source, emitted.cpp, emitted.swift)
    member_type = index.resolve(member_cpp_type)
    if member_type.kind not in ('integer', 'float'):
        raise DecodePolicyError(f"'{source}': only integer and floating-point members can be normalized.")
    if emitted.type.kind.endswith('literal'):
        emitted = translator.as_float(emitted, member_type) if member_type.kind == 'float' else emitted
    elif emitted.type.cpp != member_type.cpp:
        raise DecodePolicyError(f"'{source}': normalizes {member_name}, a {member_type.cpp}, to a {emitted.type.name()}.")
    return CompiledPolicy(kind, source, emitted.cpp, emitted.swift)
