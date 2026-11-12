#!/usr/bin/env python3
#
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

# Generates the Swift accessors through which WebCore's Swift reaches the frameworks that PAL soft-links.
#
# Inputs:
#   - PAL's SOFT_LINK_*_FOR_HEADER declarations (and the matching *_FOR_SOURCE ones), the source of truth for which
#     symbols are soft-linked, from which framework, whether that framework is private, and whether a symbol may fail.
#   - A manifest (WebCore/platform/cocoa/SoftLinkAccessors.in) of the symbols Swift uses: `kind framework symbol`, and
#     of the Objective-C members it reaches through a re-declared selector: `member framework class selector declaration`.
#   - The SDK: a generated header of `typedef __typeof__(&symbol)` names each symbol's type as the SDK declares it
#     (__typeof__ is unevaluated, so the header references no symbol), and swift-synthesize-interface gives the imported
#     declarations' Swift signatures. The framework's Objective-C headers give each member's selector and types.
#
# Outputs, in --output-dir:
#   - PALSoftLinkTypes/{module.modulemap,PALSoftLinkTypes.h}, or in --types-output-dir: a directory that the clients of
#     the Swift module search, since they load the modules it imports
#   - <Framework>SoftLinkAccessors.swift for each --framework: dlopen, dlsym and objc_lookUpClass, and the casts to the
#     SDK's types, and the members' views. These are the only files with soft-link `unsafe`.

import argparse
import os
import re
import subprocess
import sys

FRAMEWORK_HEADERS = {
    'AVFAudio': '#import <AVFAudio/AVFAudio.h>',
    'AVFoundation': '#import <AVFoundation/AVFoundation.h>',
    'AVKit': '#import <AVKit/AVKit.h>',
    'AudioToolbox': '#include <AudioToolbox/AudioToolbox.h>',
    'CoreML': '#import <CoreML/CoreML.h>',
    'CoreMedia': '#include <CoreMedia/CoreMedia.h>',
    'MediaToolbox': '#include <MediaToolbox/MediaToolbox.h>',
    'ScreenCaptureKit': '#import <ScreenCaptureKit/ScreenCaptureKit.h>',
    'Vision': '#import <Vision/Vision.h>',
    'VideoToolbox': '#include <VideoToolbox/VideoToolbox.h>',
}

KINDS = ('function', 'constant', 'class', 'member')
SYMBOL_KINDS = ('function', 'constant')


class GeneratorError(Exception):
    pass


class Declaration:
    def __init__(self, kind, framework, name, may_fail, pal_type=None):
        self.kind = kind
        self.framework = framework
        self.name = name
        self.may_fail = may_fail
        self.pal_type = pal_type

    def __repr__(self):
        return f'Declaration({self.kind}, {self.framework}, {self.name}, may_fail={self.may_fail})'


class PALDeclarations:
    def __init__(self):
        self.symbols = {}
        self.private_frameworks = set()


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def macro_arguments(text, start):
    depth, current, arguments = 0, '', []
    for i in range(start, len(text)):
        ch = text[i]
        if ch == '(':
            depth += 1
            if depth == 1:
                continue
        elif ch == ')':
            depth -= 1
            if depth == 0:
                arguments.append(current.strip())
                return arguments
        if ch == ',' and depth == 1:
            arguments.append(current.strip())
            current = ''
        elif depth >= 1:
            current += ch
    raise GeneratorError(f'unterminated macro call at offset {start}')


def parse_pal_header(text, source_text, declarations):
    text = strip_comments(text)
    source_text = strip_comments(source_text or '')

    for m in re.finditer(r'\bSOFT_LINK_(FUNCTION|CONSTANT)(_MAY_FAIL)?_FOR_HEADER\s*(?=\()', text):
        arguments = macro_arguments(text, m.end())
        if arguments[0] != 'PAL':
            continue
        kind = m.group(1).lower()
        pal_type = arguments[3] if kind == 'constant' and len(arguments) > 3 else None
        declarations.symbols[arguments[2]] = Declaration(kind, arguments[1], arguments[2], bool(m.group(2)), pal_type)

    header_classes = set()
    for m in re.finditer(r'\bSOFT_LINK_CLASS_FOR_HEADER(?:_WITH_AVAILABILITY)?\s*(?=\()', text):
        arguments = macro_arguments(text, m.end())
        if arguments[0] == 'PAL':
            header_classes.add(arguments[1])
    for m in re.finditer(r'\bSOFT_LINK_CLASS_FOR_SOURCE(_OPTIONAL)?(?:_WITH_EXPORT)?(?:_AND_IS_OPTIONAL)?\s*(?=\()', source_text):
        arguments = macro_arguments(source_text, m.end())
        if arguments[0] != 'PAL' or arguments[2] not in header_classes:
            continue
        optional = bool(m.group(1)) or (len(arguments) > 4 and arguments[4] == 'SOFT_LINK_IS_OPTIONAL')
        declarations.symbols[arguments[2]] = Declaration('class', arguments[1], arguments[2], optional)

    for m in re.finditer(r'\bSOFT_LINK_PRIVATE_FRAMEWORK_FOR_SOURCE(?:_WITH_EXPORT)?\s*(?=\()', source_text):
        arguments = macro_arguments(source_text, m.end())
        if arguments[0] == 'PAL':
            declarations.private_frameworks.add(arguments[1])


def parse_pal(paths):
    declarations = PALDeclarations()
    for path in paths:
        with open(path) as f:
            text = f.read()
        source_text = None
        stem = os.path.splitext(path)[0]
        for extension in ('.cpp', '.mm'):
            if os.path.exists(stem + extension):
                with open(stem + extension) as f:
                    source_text = f.read()
                break
        parse_pal_header(text, source_text, declarations)
    return declarations


# An Objective-C member that Swift calls through a re-declared selector, because the SDK's own declaration names a class
# of the soft-linked framework (a typed collection), which would link it: `member <framework> <class> <selector>
# <declaration>`, where the declaration is the Swift one with NSArray and NSDictionary for the SDK's typed collections, as
# `func name(labels: Types) [throws] [-> Type]` or `var name: Type { get }`. `[T] counted by property` stands for a
# `const T *` the object owns, which the generated adapter copies, so the pointer never leaves the generated file. A
# selector that starts with `+` is a class method, which Swift calls on the class object that a `class` entry soft-links.
class Member:
    def __init__(self, cls, selector, declaration):
        self.cls = cls
        self.is_class_member = selector.startswith('+')
        self.selector = selector[1:] if self.is_class_member else selector
        self.declaration = declaration
        m = re.fullmatch(r'var (\w+): (.+?) \{ get \}', declaration)
        if m and self.is_class_member:
            raise GeneratorError(f'{cls} {selector}: a class method is declared as a func')
        if m:
            self.name, self.is_property, self.parameters, self.throws, self.result, self.counted_by = m.group(1), True, [], False, m.group(2), None
            return
        m = re.fullmatch(r'func (\w+)\((.*?)\)( throws)?(?: -> (.+?))?(?: counted by (\w+))?', declaration)
        if not m:
            raise GeneratorError(f'{cls} {selector}: expected "func name(labels: Types) [throws] [-> Type] [counted by property]" or "var name: Type {{ get }}", not "{declaration}"')
        self.name, self.is_property, self.throws, self.result, self.counted_by = m.group(1), False, bool(m.group(3)), m.group(4) or 'Void', m.group(5)
        self.parameters = []
        for parameter in split_parameters(m.group(2)):
            head, parameter_type = parameter.rsplit(':', 1)
            words = head.split()
            self.parameters.append((words[0], words[-1], parameter_type.strip()))
        if self.counted_by and not re.fullmatch(r'\[\w+\]', self.result):
            raise GeneratorError(f'{cls} {selector}: "counted by" needs an array result, not {self.result}')
        if self.counted_by and self.is_class_member:
            raise GeneratorError(f'{cls} {selector}: a class method can\'t be "counted by" a property')

    @property
    def key(self):
        return f'{self.cls} {"+" if self.is_class_member else ""}{self.selector}'

    @property
    def protocol(self):
        return f'Member_{self.cls}_{self.name}'

    def __eq__(self, other):
        return isinstance(other, Member) and (self.cls, self.selector, self.declaration) == (other.cls, other.selector, other.declaration)

    def __repr__(self):
        return f'Member({self.cls}, {self.selector}, {self.declaration})'


def parse_manifest(lines):
    entries = []
    for number, line in enumerate(lines, 1):
        line = line.split('#')[0].strip()
        if not line:
            continue
        words = line.split()
        if len(words) >= 6 and words[0] == 'member':
            member = Member(words[2], words[3], ' '.join(words[4:]))
            entries.append(('member', words[1], member.key, member))
            continue
        if len(words) == 5 and words[0] in ('constant', 'class') and words[3] == 'as':
            entries.append(tuple(words[:3]) + (words[4],))
            continue
        if len(words) == 5 and words[0] == 'function' and words[3:] == ['with', 'pointer']:
            entries.append(tuple(words[:3]) + ('pointer',))
            continue
        if len(words) != 3 or words[0] not in KINDS:
            raise GeneratorError(f'manifest line {number}: expected "<{"|".join(KINDS[:3])}> <framework> <symbol>", "<constant|class> <framework> <symbol> as <type>", "member <framework> <class> <selector> <declaration>", or "function <framework> <symbol> with pointer"')
        entries.append(tuple(words) + (None,))
    return entries


def validate(entries, declarations, frameworks):
    errors = []
    seen = set()
    for kind, framework, name, _ in entries:
        if name in seen:
            errors.append(f'{name}: listed twice')
        seen.add(name)
        if framework not in frameworks:
            errors.append(f'{name}: {framework} is not one of the frameworks to generate ({", ".join(frameworks)})')
        if kind == 'member':
            # A member's class is only a static type, which needs no symbol, so PAL needn't soft-link it.
            continue
        declaration = declarations.symbols.get(name)
        if not declaration:
            errors.append(f'{name}: not soft-linked by PAL (add a SOFT_LINK_* declaration first)')
        elif declaration.kind != kind or declaration.framework != framework:
            errors.append(f'{name}: the manifest says {kind} in {framework}, PAL says {declaration.kind} in {declaration.framework}')
        if framework not in FRAMEWORK_HEADERS and kind != 'class':
            errors.append(f'{name}: no SDK header known for {framework}')
    if errors:
        raise GeneratorError('\n'.join(errors))


# The Core Foundation Create rule, as clang applies it (CocoaConventions.cpp, coreFoundation::followsCreateRule) and as
# Swift's importer uses it for an audited declaration's result: a function whose name contains the word "Create" or
# "Copy" returns +1, any other returns +0. This is the one place the accessors decide ownership.
def follows_create_rule(name):
    i = 0
    while i < len(name):
        ch = name[i]
        if ch not in 'Cc' or (ch == 'c' and i > 0 and name[i - 1].isalpha()):
            i += 1
            continue
        for suffix in ('reate', 'opy'):
            if name.startswith(suffix, i + 1):
                end = i + 1 + len(suffix)
                if end == len(name) or not name[end].islower():
                    return True
        i += 1
    return False


def split_parameters(text):
    depth, current, parts = 0, '', []
    for ch in text:
        if ch in '(<[':
            depth += 1
        elif ch in ')>]':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(current.strip())
            current = ''
        else:
            current += ch
    if current.strip():
        parts.append(current.strip())
    return parts


def find_declaration(interfaces, name):
    for text in interfaces:
        m = re.search(r'^\s*(?:@\w+(?:\([^)]*\))? )*public func ' + re.escape(name) + r'\((.*)\)( -> (.*))?$', text, re.M)
        if m:
            return split_parameters(m.group(1)), (m.group(3) or 'Void').strip()
    return None


def find_function_typedef(text, name):
    m = re.search(r'^(@unsafe )?public typealias ' + re.escape(name) + r' = @convention\(c(?:, cType: "[^"]*")?\) \((.*)\) -> (.*)$', text, re.M)
    if not m:
        return None
    return split_parameters(m.group(2)), m.group(3).strip(), bool(m.group(1))


def find_constant_typedef(text, name):
    m = re.search(r'^(?:@unsafe )?public typealias ' + re.escape(name) + r' = Unsafe(?:Mutable)?Pointer<(.*)>$', text, re.M)
    return m.group(1).strip() if m else None


def strip_optional(type_name):
    return type_name[:-1] if type_name.endswith('?') else type_name


def adapt_argument(expression, declared_type, pointer_type):
    if declared_type == pointer_type:
        return expression, False
    if declared_type == 'Bool' and pointer_type == 'DarwinBoolean':
        return f'DarwinBoolean({expression})', False
    declared = re.fullmatch(r'Unsafe(Mutable)?Pointer<(\w+)\?>', declared_type)
    pointer = re.fullmatch(r'Unsafe(Mutable)?Pointer<Unmanaged<(\w+)>\?>', pointer_type)
    if declared and pointer and declared.group(1) == pointer.group(1) and declared.group(2) == pointer.group(2):
        # A CF out-parameter. Optional<T> and Optional<Unmanaged<T>> have the same layout, and the callee stores a +1
        # reference that the caller's Optional<T> then owns, as with the imported declaration.
        mutable = declared.group(1) or ''
        return f'Unsafe{mutable}RawPointer({expression}).assumingMemoryBound(to: Unmanaged<{pointer.group(2)}>?.self)', True
    return None, False


def audited_name(name, section):
    characters = ', '.join(str(ord(c)) for c in name) + ', 0'
    tuple_type = '(' + ', '.join(['CChar'] * (len(name) + 1)) + ')'
    return f'@section("{section}") @used private let auditedName_{name}: {tuple_type} = ({characters})'


def function_accessor(declaration, typedef, imported, with_pointer=False):
    name = declaration.name
    pointer_parameters, pointer_result, typedef_is_unsafe = typedef
    declared_parameters, declared_result = imported
    if len(pointer_parameters) != len(declared_parameters):
        raise GeneratorError(f'{name}: {len(declared_parameters)} parameters imported, {len(pointer_parameters)} in the pointer type')
    pointer_type = f'PALSoftLink_{name}_t'
    lines = []
    if declaration.may_fail:
        lines.append(f'private let softLink_{name}: {pointer_type}? = unsafe softLinkSymbol(auditedName_{name}).map {{ unsafe unsafeBitCast($0, to: {pointer_type}.self) }}')
    else:
        lines.append(f'private let softLink_{name}: {pointer_type} = unsafe unsafeBitCast(softLinkRequiredSymbol(auditedName_{name}), to: {pointer_type}.self)')

    arguments, signature, needs_unsafe = [], [], typedef_is_unsafe
    for i, (parameter, pointer_parameter) in enumerate(zip(declared_parameters, pointer_parameters)):
        head, parameter_type = parameter.rsplit(':', 1)
        parameter_type = parameter_type.strip()
        words = head.split()
        local = words[-1]
        if local == '_':
            local = f'arg{i}'
            head = f'_ {local}'
        signature.append(f'{head}: {parameter_type}')
        expression, adapted_unsafely = adapt_argument(local, parameter_type, pointer_parameter)
        if expression is None:
            raise GeneratorError(f'{name}: parameter {i} is {parameter_type}, {pointer_parameter} in the pointer type: no adaptation rule')
        needs_unsafe = needs_unsafe or adapted_unsafely
        arguments.append(expression)

    callee = f'softLink_{name}' + ('!' if declaration.may_fail else '')
    call = f'{callee}({", ".join(arguments)})'
    if declared_result == pointer_result:
        body = call
    elif pointer_result in (f'Unmanaged<{strip_optional(declared_result)}>?', f'Unmanaged<{declared_result}>'):
        take = 'takeRetainedValue' if follows_create_rule(name) else 'takeUnretainedValue'
        body = f'{call}{"?" if pointer_result.endswith("?") else ""}.{take}()'
        needs_unsafe = True
    elif declared_result == 'Bool' and pointer_result == 'DarwinBoolean':
        body = f'{call}.boolValue'
    else:
        raise GeneratorError(f'{name}: result {declared_result}, {pointer_result} in the pointer type: no adaptation rule')

    if declaration.may_fail:
        lines.append(f'var canLoad_{declaration.framework}_{name}: Bool {{ unsafe softLink_{name} != nil }}')
    if with_pointer:
        if declaration.may_fail:
            raise GeneratorError(f'{name}: "with pointer" needs a function that can\'t fail')
        # For real-time code, which copies the pointer on the main thread so that its own thread never initializes it.
        lines.append(f'var softLinkPointer_{name}: {pointer_type} {{ unsafe softLink_{name} }}')
    result = '' if declared_result == 'Void' else f' -> {declared_result}'
    lines.append(f'func {name}({", ".join(signature)}){result} {{ {"unsafe " if needs_unsafe else ""}{body} }}')
    return lines


def constant_accessor(declaration, pointee, swift_type=None):
    name = declaration.name
    pointer_type = f'PALSoftLink_{name}_t'
    value_type = strip_optional(pointee)
    load = f'unsafe address.load(as: {pointer_type}.Pointee.self)'
    if pointee.endswith('?'):
        load = f'({load})!'
    if value_type == 'NSString':
        value_type = 'String'
        load = f'{load} as String'
        if swift_type:
            value_type = swift_type
            load = f'stringConstant({load}) as {swift_type}'
    elif swift_type:
        raise GeneratorError(f'{name}: "as {swift_type}" applies only to NSString constants')
    lines = [f'extension {declaration.framework}SoftLink {{']
    if declaration.may_fail:
        lines += [
            f'    static let {name}: {value_type}? = {{',
            f'        guard let address = unsafe softLinkSymbol(auditedName_{name}) else {{',
            '            return nil',
            '        }',
            f'        return {load}',
            '    }()',
        ]
    else:
        lines += [
            f'    static let {name}: {value_type} = {{',
            f'        let address = unsafe softLinkRequiredSymbol(auditedName_{name})',
            f'        return {load}',
            '    }()',
        ]
    lines.append('}')
    return lines


# swift_name is the class's Swift name when the SDK renames it (`class AVFoundation AVCaptureDeviceFormat as
# AVCaptureDevice.Format`).
def class_accessor(declaration, module, swift_name=None):
    name = declaration.name
    qualified = f'{module}.{swift_name or name}'
    lines = [f'extension {declaration.framework}Class {{']
    if declaration.may_fail:
        lines += [
            f'    static let {name}: {qualified}.Type? = {{',
            f'        guard let classObject = softLinkClass(auditedName_{name}) else {{',
            '            return nil',
            '        }',
            f'        return unsafe unsafeBitCast(classObject, to: {qualified}.Type.self)',
            '    }()',
            '',
            f'    static func cast(_ object: AnyObject?, to _: {qualified}.Type?) -> {qualified}? {{',
            f'        guard let classObject = {name}, let object = object as? NSObject, object.isKind(of: classObject) else {{',
        ]
    else:
        lines += [
            f'    static let {name}: {qualified}.Type = {{',
            f'        guard let classObject = softLinkClass(auditedName_{name}) else {{',
            f'            preconditionFailure("{name} is missing")',
            '        }',
            f'        return unsafe unsafeBitCast(classObject, to: {qualified}.Type.self)',
            '    }()',
            '',
            f'    static func cast(_ object: AnyObject?, to _: {qualified}.Type) -> {qualified}? {{',
            f'        guard let object = object as? NSObject, object.isKind(of: {name}) else {{',
        ]
    lines += [
        '            return nil',
        '        }',
        f'        return unsafe unsafeBitCast(object as AnyObject, to: {qualified}.self)',
        '    }',
        '}',
    ]
    return lines


# The members that the framework's Objective-C headers declare, by class: the selector, then the return type and the
# parameters' types, with nullability and __kindof dropped. Categories and class extensions add to their class.
class ObjCHeaders:
    def __init__(self, texts):
        self.superclasses = {}
        self.members = {}
        self.class_members = {}
        self.nullable_results = {}
        self.string_typedefs = set()
        for text in texts:
            self.parse(strip_comments(text))

    # Whether a declaration may give nil: annotated nullable or null_unspecified, or not annotated outside
    # NS_ASSUME_NONNULL_BEGIN/END.
    @staticmethod
    def may_be_nil(annotations, assumes_nonnull):
        if re.search(r'\b(nullable|null_unspecified|_Nullable|_Null_unspecified|__nullable)\b', annotations):
            return True
        if re.search(r'\b(nonnull|_Nonnull|__nonnull)\b', annotations):
            return False
        return not assumes_nonnull

    @staticmethod
    def normalize_type(text):
        text = re.sub(r'\b(nullable|nonnull|null_unspecified|_Nullable|_Nonnull|_Null_unspecified|__nullable|__nonnull|__kindof|__strong|__unsafe_unretained)\b', ' ', text)
        text = re.sub(r'\s*\*\s*', '*', text)
        text = re.sub(r'\s*([<>,])\s*', r'\1', text)
        return ' '.join(text.split())

    @staticmethod
    def strip_trailing_macros(text):
        while True:
            m = re.search(r'\s+(?:[A-Z_][A-Z0-9_]*|__attribute__)\s*(?:\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))?\s*$', text)
            if not m:
                return text.strip()
            text = text[:m.start()]

    @staticmethod
    def balanced(text, start):
        depth = 0
        for i in range(start, len(text)):
            if text[i] == '(':
                depth += 1
            elif text[i] == ')':
                depth -= 1
                if not depth:
                    return text[start + 1:i], i + 1
        raise GeneratorError(f'unbalanced parentheses in "{text}"')

    def parse(self, text):
        for m in re.finditer(r'typedef\s+NSString\s*\*\s*(\w+)', text):
            self.string_typedefs.add(m.group(1))
        nonnull_regions = []
        for m in re.finditer(r'\bNS_ASSUME_NONNULL_(BEGIN|END)\b', text):
            if m.group(1) == 'BEGIN':
                nonnull_regions.append([m.end(), len(text)])
            elif nonnull_regions:
                nonnull_regions[-1][1] = m.start()
        for m in re.finditer(r'@interface\s+(\w+)\s*(?::\s*(\w+))?[^\n]*?\n(.*?)@end', text, re.S):
            name, superclass, body = m.group(1), m.group(2), m.group(3)
            assumes_nonnull = any(start <= m.start(3) < end for start, end in nonnull_regions)
            if superclass:
                self.superclasses[name] = superclass
            instance_members = self.members.setdefault(name, {})
            class_members = self.class_members.setdefault(name, {})
            body = re.sub(r'\{[^{}]*\}', ';', body, count=1) if body.lstrip().startswith('{') else body
            body = re.sub(r'^\s*#.*$', '', body, flags=re.M)
            for statement in body.split(';'):
                statement = ' '.join(statement.split())
                if statement.startswith('@property'):
                    attributes = re.match(r'^@property\s*(\(([^)]*)\))?', statement).group(2) or ''
                    declaration = self.strip_trailing_macros(re.sub(r'^@property\s*(\([^)]*\))?', '', statement))
                    p = re.fullmatch(r'(.*?)\s*\b(\w+)', declaration)
                    if not p:
                        continue
                    is_class = bool(re.search(r'\bclass\b', attributes))
                    members = class_members if is_class else instance_members
                    property_type = self.normalize_type(p.group(1))
                    getter = re.search(r'\bgetter\s*=\s*(\w+)', attributes)
                    getter = getter.group(1) if getter else p.group(2)
                    members[getter] = (property_type, [])
                    self.nullable_results[(name, is_class, getter)] = self.may_be_nil(attributes + ' ' + p.group(1), assumes_nonnull)
                    if not re.search(r'\breadonly\b', attributes):
                        setter = re.search(r'\bsetter\s*=\s*(\w+:)', attributes)
                        setter = setter.group(1) if setter else f'set{p.group(2)[0].upper()}{p.group(2)[1:]}:'
                        members[setter] = ('void', [property_type])
                elif statement[:1] in '-+' and '(' in statement:
                    return_type, end = self.balanced(statement, statement.index('('))
                    rest = self.strip_trailing_macros(statement[end:])
                    pieces, parameters = [], []
                    while True:
                        k = re.match(r'\s*(\w+)\s*:\s*', rest)
                        if not k:
                            break
                        parameter_type, end = self.balanced(rest, k.end())
                        pieces.append(k.group(1))
                        parameters.append(self.normalize_type(parameter_type))
                        rest = re.sub(r'^\s*\w+', '', rest[end:], count=1)
                    selector = ''.join(f'{piece}:' for piece in pieces) if pieces else rest.strip()
                    if selector:
                        is_class = statement[0] == '+'
                        (class_members if is_class else instance_members)[selector] = (self.normalize_type(return_type), parameters)
                        self.nullable_results[(name, is_class, selector)] = self.may_be_nil(return_type, assumes_nonnull)

    def find(self, cls, selector, is_class_member=False):
        while cls:
            member = (self.class_members if is_class_member else self.members).get(cls, {}).get(selector)
            if member:
                return member
            cls = self.superclasses.get(cls)
        return None

    def result_may_be_nil(self, cls, selector, is_class_member=False):
        while cls:
            if (self.class_members if is_class_member else self.members).get(cls, {}).get(selector):
                return self.nullable_results.get((cls, is_class_member, selector), True)
            cls = self.superclasses.get(cls)
        return True

    # The Swift type that may stand for an Objective-C type in a member's re-declaration: the plain type, with NSArray and
    # NSDictionary for typed collections and AnyObject for protocol-typed objects, which would otherwise name the
    # framework's classes and protocols.
    def erased_types(self, objc_type):
        objc_type = objc_type.strip()
        if re.fullmatch(r'NSArray(<.*>)?\*', objc_type):
            return {'NSArray'}
        if re.fullmatch(r'NSDictionary(<.*>)?\*', objc_type):
            return {'NSDictionary'}
        if re.fullmatch(r'id(<.*>)?', objc_type):
            return {'AnyObject'}
        if objc_type == 'NSString*' or objc_type in self.string_typedefs:
            return {'String', 'NSString'}
        plain = {'BOOL': 'Bool', 'NSUInteger': 'Int', 'NSInteger': 'Int', 'void': 'Void', 'CGSize': 'CGSize', 'CGPoint': 'CGPoint', 'CGRect': 'CGRect', 'CGFloat': 'CGFloat', 'float': 'Float', 'double': 'Double'}
        if objc_type in plain:
            return {plain[objc_type]}
        m = re.fullmatch(r'const (\w+)\*', objc_type)
        if m and m.group(1) in plain:
            return {f'[{plain[m.group(1)]}] counted'}
        m = re.fullmatch(r'(\w+)\*', objc_type)
        if m:
            return {m.group(1), 'AnyObject'}
        return set()

    def check(self, member):
        found = self.find(member.cls, member.selector, member.is_class_member)
        if not found:
            raise GeneratorError(f'{member.key}: the SDK\'s headers declare no such {"class " if member.is_class_member else ""}member of {member.cls} or its superclasses')
        return_type, parameters = found
        swift_parameters = [parameter_type for _, _, parameter_type in member.parameters]
        throws = bool(parameters) and parameters[-1] == 'NSError**'
        if throws:
            parameters = parameters[:-1]
        if throws != member.throws:
            raise GeneratorError(f'{member.key}: {"throws" if throws else "does not throw"} in the SDK (an NSError ** last parameter)')
        if len(parameters) != len(swift_parameters):
            raise GeneratorError(f'{member.key}: {len(parameters)} parameters in the SDK, {len(swift_parameters)} in "{member.declaration}"')

        def strip(swift_type):
            return swift_type[:-1] if swift_type.endswith('?') else swift_type

        for objc_type, swift_type in zip(parameters, swift_parameters):
            if strip(swift_type) not in self.erased_types(objc_type):
                raise GeneratorError(f'{member.key}: a parameter is {objc_type} in the SDK, which {swift_type} cannot stand for')
        # A parameter that stands for a typed collection or a class lets Swift pass objects of other classes, so calling
        # the re-declaration is unsafe.
        member.erases_parameters = any(strip(swift_type) in ('NSArray', 'NSDictionary', 'AnyObject') and objc_type not in ('NSArray*', 'NSDictionary*', 'id')
            for objc_type, swift_type in zip(parameters, swift_parameters))
        if not throws and not member.counted_by and not member.result.endswith('?') and self.erased_types(return_type) & {'NSArray', 'NSDictionary', 'AnyObject', 'NSString'} and self.result_may_be_nil(member.cls, member.selector, member.is_class_member):
            raise GeneratorError(f'{member.key}: the SDK\'s result may be nil, so "{member.result}" needs to be optional')
        result = strip(member.result)
        if member.counted_by:
            result += ' counted'
        if throws and return_type == 'BOOL':
            expected = {'Void'}
        else:
            expected = self.erased_types(return_type)
        if result not in expected:
            raise GeneratorError(f'{member.key}: the result is {return_type} in the SDK, which {member.result} cannot stand for')


def member_accessor(framework, member, swift_names=None):
    protocol = f'{framework}{member.protocol}'
    qualified = f'{framework}.{(swift_names or {}).get(member.cls, member.cls)}'
    lines = [f'// {"+" if member.is_class_member else "-"}[{member.cls} {member.selector}], with NSArray and NSDictionary for the SDK\'s typed collections.']
    lines.append(f'@objc protocol {protocol} {{')
    unsafe = '@unsafe ' if getattr(member, 'erases_parameters', False) else ''
    if member.is_property:
        lines.append(f'    @objc({member.selector}) var {member.name}: {member.result} {{ get }}')
    else:
        parameters = ', '.join(f'{label} {local}: {parameter_type}' if label != local else f'{label}: {parameter_type}' for label, local, parameter_type in member.parameters)
        if member.counted_by:
            element = member.result[1:-1]
            result = f' -> UnsafePointer<{element}>?'
        else:
            result = '' if member.result == 'Void' else f' -> {member.result}'
        lines.append(f'    {unsafe}@objc({member.selector}) func {member.name}({parameters}){" throws" if member.throws else ""}{result}')
    lines.append('}')
    lines.append('')
    lines.append(f'extension {framework}Member {{')
    if member.is_class_member:
        lines += [
            '    // The class object, seen through the re-declaration, or nil if it doesn\'t answer the selector.',
            f'    static func {member.name}(of classObject: {qualified}.Type) -> (any {protocol})? {{',
            '        let object: AnyObject = classObject',
            f'        guard object.responds(to: NSSelectorFromString("{member.selector}")) else {{',
            '            return nil',
            '        }',
            f'        return unsafe unsafeBitCast(object, to: (any {protocol}).self)',
            '    }',
        ]
    elif member.counted_by:
        signature = ''.join(f', {label} {local}: {parameter_type}' if label != local else f', {label}: {parameter_type}' for label, local, parameter_type in member.parameters)
        arguments = ', '.join(local if label == '_' else f'{label}: {local}' for label, local, _ in member.parameters)
        lines += [
            f'    // A copy of the object\'s {member.counted_by} elements, or nil if the object doesn\'t answer the selector.',
            f'    static func {member.name}(of object: {qualified}{signature}) -> {member.result}? {{',
            f'        guard object.responds(to: NSSelectorFromString("{member.selector}")) else {{',
            '            return nil',
            '        }',
            f'        let view = unsafe unsafeBitCast(object, to: (any {protocol}).self)',
            f'        guard let elements = unsafe view.{member.name}({arguments}) else {{',
            '            return []',
            '        }',
            f'        return unsafe Array(UnsafeBufferPointer(start: elements, count: object.{member.counted_by}))',
            '    }',
        ]
    else:
        lines += [
            '    // The object, seen through the re-declaration, or nil if it doesn\'t answer the selector.',
            f'    static func {member.name}(of object: {qualified}) -> (any {protocol})? {{',
            f'        guard object.responds(to: NSSelectorFromString("{member.selector}")) else {{',
            '            return nil',
            '        }',
            f'        return unsafe unsafeBitCast(object, to: (any {protocol}).self)',
            '    }',
        ]
    lines.append('}')
    return lines


def framework_path(framework, private_frameworks):
    directory = 'PrivateFrameworks' if framework in private_frameworks else 'Frameworks'
    return f'/System/Library/{directory}/{framework}.framework/{framework}'


def accessors_file(framework, entries, declarations, typedefs, interfaces_for, headers_for=None, path=None):
    path = path or framework_path(framework, declarations.private_frameworks)
    members = [member for kind, f, _, member in entries if f == framework and kind == 'member']
    framework_entries = [(kind, name, swift_type) for kind, f, name, swift_type in entries if f == framework and kind != 'member']
    kinds = {kind for kind, _, _ in framework_entries}
    if members:
        headers = headers_for(framework)
        for member in members:
            headers.check(member)
    w = []
    w.append('// Generated by WebCore/Scripts/generate-soft-link-accessors.py from PAL\'s SOFT_LINK declarations,')
    w.append('// WebCore/platform/cocoa/SoftLinkAccessors.in and the SDK. Do not edit.')
    w.append('//')
    w.append(f'// WebCore soft-links {framework}: its Swift reaches the symbols below only through this file, which loads the')
    w.append('// framework with dlopen and finds each symbol with dlsym or objc_lookUpClass, at first use. Each symbol is cast to')
    w.append('// the type that PALSoftLinkTypes.h takes from the SDK\'s own declaration. A missing framework or symbol traps, as')
    w.append('// PAL\'s RELEASE_ASSERT does, unless PAL declares the symbol MAY_FAIL or the class OPTIONAL.')
    w.append('')
    w.append('import Darwin')
    if 'class' in kinds or members:
        w.append('import Foundation')
    w.append(f'import {framework}')
    w.append('import ObjectiveC')
    w.append('import PALSoftLinkTypes')
    w.append('')
    if 'constant' in kinds:
        w.append(f'enum {framework}SoftLink {{ }}')
    if 'class' in kinds:
        w.append(f'enum {framework}Class {{ }}')
    if members:
        w.append(f'enum {framework}Member {{ }}')
    if 'constant' in kinds or 'class' in kinds or members:
        w.append('')
    w.append(f'nonisolated(unsafe) private let frameworkHandleIfLoaded: UnsafeMutableRawPointer? = unsafe dlopen("{path}", RTLD_NOW)')
    w.append('')
    w.append('nonisolated(unsafe) private let frameworkHandle: UnsafeMutableRawPointer = {')
    w.append('    guard let handle = unsafe frameworkHandleIfLoaded else {')
    w.append(f'        preconditionFailure("{framework} failed to load")')
    w.append('    }')
    w.append('    return unsafe handle')
    w.append('}()')
    w.append('')
    w.append(f'// Whether {framework} loads, as PAL\'s is{framework}FrameworkAvailable() answers, without trapping.')
    w.append(f'var {framework}FrameworkIsAvailable: Bool {{ unsafe frameworkHandleIfLoaded != nil }}')
    w.append('')
    if 'function' in kinds or 'constant' in kinds:
        w.append('private func softLinkSymbol<Name>(_ name: Name) -> UnsafeMutableRawPointer? {')
        w.append('    withUnsafePointer(to: name) { unsafe dlsym(frameworkHandle, UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }')
        w.append('}')
        w.append('')
        if any(not declarations.symbols[name].may_fail for kind, name, _ in framework_entries if kind != 'class'):
            w.append('private func softLinkRequiredSymbol<Name>(_ name: Name) -> UnsafeMutableRawPointer {')
            w.append('    guard let symbol = unsafe softLinkSymbol(name) else {')
            w.append(f'        preconditionFailure("a symbol of {framework} is missing")')
            w.append('    }')
            w.append('    return unsafe symbol')
            w.append('}')
            w.append('')
    if any(kind == 'constant' and swift_type for kind, _, swift_type in framework_entries):
        w.append('// Through RawRepresentable, not the type\'s own init(rawValue:): PAL re-declares some of these types (AVMediaType),')
        w.append('// and the re-declaration\'s initializer is visible only where pal is imported.')
        w.append('private func stringConstant<Constant: RawRepresentable>(_ value: String) -> Constant where Constant.RawValue == String {')
        w.append('    guard let constant = Constant(rawValue: value) else {')
        w.append(f'        preconditionFailure("a constant of {framework} has no value")')
        w.append('    }')
        w.append('    return constant')
        w.append('}')
        w.append('')
    if 'class' in kinds:
        w.append('private func softLinkClass<Name>(_ name: Name) -> AnyClass? {')
        w.append('    _ = unsafe frameworkHandle')
        w.append('    return withUnsafePointer(to: name) { unsafe objc_lookUpClass(UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }')
        w.append('}')
        w.append('')
    for kind, name, _ in framework_entries:
        w.append(audited_name(name, '__TEXT,__getClass_cstr' if kind == 'class' else '__TEXT,__dlsym_cstr'))
    w.append('')
    for kind, name, swift_type in framework_entries:
        declaration = declarations.symbols[name]
        if kind == 'function':
            typedef = find_function_typedef(typedefs, f'PALSoftLink_{name}_t')
            imported = find_declaration(interfaces_for(framework), name)
            if not typedef or not imported:
                raise GeneratorError(f'{name}: no typedef or imported declaration found')
            w += function_accessor(declaration, typedef, imported, swift_type == 'pointer')
        elif kind == 'constant':
            pointee = find_constant_typedef(typedefs, f'PALSoftLink_{name}_t')
            if not pointee:
                raise GeneratorError(f'{name}: no typedef found')
            w += constant_accessor(declaration, pointee, swift_type)
        else:
            w += class_accessor(declaration, framework, swift_type)
        w.append('')
    swift_names = {name: swift_type for kind, name, swift_type in framework_entries if kind == 'class' and swift_type}
    for member in members:
        w += member_accessor(framework, member, swift_names)
        w.append('')
    return '\n'.join(w).rstrip('\n') + '\n'


# The file for a framework that the target's SDK doesn't have (Vision on watchOS), so that the build's list of generated
# files stays the same: nothing in it, and nothing may use it.
def stub_file(framework):
    return ('// Generated by WebCore/Scripts/generate-soft-link-accessors.py. Do not edit.\n'
            f'// The target\'s SDK has no {framework}, so WebCore\'s Swift has no accessors for it.\n')


# A constant that may fail is typed as PAL declares it, not with __typeof__: such a constant may be unavailable on some
# of the SDK's platforms (an iOS-only device type on macOS), where the SDK's declaration can't be named, though PAL
# still looks it up at runtime.
def typed_by_pal(declaration):
    return declaration is not None and declaration.kind == 'constant' and declaration.may_fail and declaration.pal_type


def types_header(entries, declarations=None):
    frameworks = sorted({f for kind, f, _, _ in entries if kind in SYMBOL_KINDS})
    w = ['// Generated by WebCore/Scripts/generate-soft-link-accessors.py. Do not edit.',
         '// Each typedef names the type of a soft-linked symbol as the SDK declares it. __typeof__ is unevaluated, so this',
         '// header references no symbol.',
         '',
         '#pragma once',
         '']
    for framework in frameworks:
        w.append(FRAMEWORK_HEADERS[framework])
    w.append('')
    w.append('#pragma clang diagnostic push')
    w.append('#pragma clang diagnostic ignored "-Wunguarded-availability-new"')
    w.append('#pragma clang diagnostic ignored "-Wdeprecated-declarations"')
    for kind, _, name, _ in entries:
        if kind not in SYMBOL_KINDS:
            continue
        declaration = declarations.symbols.get(name) if declarations else None
        if typed_by_pal(declaration):
            w.append(f'typedef {declaration.pal_type} const * PALSoftLink_{name}_t;')
        else:
            w.append(f'typedef __typeof__(&{name}) PALSoftLink_{name}_t;')
    w.append('#pragma clang diagnostic pop')
    return '\n'.join(w) + '\n'


MODULE_MAP = 'module PALSoftLinkTypes {\n    header "PALSoftLinkTypes.h"\n    export *\n}\n'


def write_if_changed(path, content):
    if os.path.exists(path):
        with open(path) as f:
            if f.read() == content:
                return
    with open(path, 'w') as f:
        f.write(content)


class Synthesizer:
    def __init__(self, tool, sdk, target, extra_arguments):
        self.tool = tool
        self.sdk = sdk
        self.target = target
        self.extra_arguments = extra_arguments
        self.cache = {}

    def __call__(self, module, include_dirs=()):
        command = self.tool + ['-sdk', self.sdk, '-target', self.target, '-module-name', module] + self.extra_arguments
        for directory in include_dirs:
            command += ['-I', directory]
        result = subprocess.run(command + ['-o', '/dev/stdout'], capture_output=True, text=True)
        if result.returncode:
            raise GeneratorError(f'swift-synthesize-interface {module} failed:\n{result.stderr}')
        return result.stdout

    def module_and_submodules(self, module):
        if module not in self.cache:
            listing = self(module)
            submodules = sorted(set(re.findall(r'^(?:@_exported )?import (' + re.escape(module) + r'(?:\.\w+)+)$', listing, re.M)))
            self.cache[module] = [listing] + [self(s) for s in submodules]
        return self.cache[module]

    # The framework's module and its submodules, then the modules it re-exports whose names extend its own (the internal
    # SDK's AudioToolbox declares its functions in AudioToolboxCore), public ones first.
    def framework(self, module):
        yield from self.module_and_submodules(module)
        listing = self.module_and_submodules(module)[0]
        related = set(re.findall(r'^(?:@_exported )?import (' + re.escape(module) + r'\w+)$', listing, re.M))
        related |= {name[:-len('_Private')] for name in related if name.endswith('_Private')}
        for name in sorted(related, key=lambda name: (name.endswith('_Private'), name)):
            yield from self.module_and_submodules(name)


def framework_headers(sdk, framework):
    directory = os.path.join(sdk, 'System', 'Library', 'Frameworks', f'{framework}.framework', 'Headers')
    if not os.path.isdir(directory):
        raise GeneratorError(f'{framework}: no headers in {directory}')
    texts = []
    for name in sorted(os.listdir(directory)):
        if name.endswith('.h'):
            with open(os.path.join(directory, name), errors='replace') as f:
                texts.append(f.read())
    return ObjCHeaders(texts)


def generate(arguments):
    with open(arguments.manifest) as f:
        entries = parse_manifest(f.readlines())
    stubs = set(arguments.stub_framework)
    entries = [entry for entry in entries if entry[1] not in stubs]
    declarations = parse_pal(arguments.pal_header)
    validate(entries, declarations, arguments.framework)

    types_dir = os.path.join(arguments.types_output_dir or arguments.output_dir, 'PALSoftLinkTypes')
    os.makedirs(types_dir, exist_ok=True)
    write_if_changed(os.path.join(types_dir, 'module.modulemap'), MODULE_MAP)
    write_if_changed(os.path.join(types_dir, 'PALSoftLinkTypes.h'), types_header(entries, declarations))

    tool = [arguments.synthesize_interface] if arguments.synthesize_interface else ['xcrun', 'swift-synthesize-interface']
    synthesize = Synthesizer(tool, arguments.sdk, arguments.target, arguments.synthesize_argument)
    typedefs = synthesize('PALSoftLinkTypes', [types_dir]) if any(kind in SYMBOL_KINDS for kind, _, _, _ in entries) else ''
    paths = dict(override.split('=', 1) for override in getattr(arguments, 'framework_path', []))
    for framework in arguments.framework:
        content = accessors_file(framework, entries, declarations, typedefs, synthesize.framework, lambda framework: framework_headers(arguments.sdk, framework), paths.get(framework))
        write_if_changed(os.path.join(arguments.output_dir, f'{framework}SoftLinkAccessors.swift'), content)
    for framework in stubs:
        write_if_changed(os.path.join(arguments.output_dir, f'{framework}SoftLinkAccessors.swift'), stub_file(framework))


def main(argv):
    parser = argparse.ArgumentParser(description='Generates the Swift accessors for symbols that PAL soft-links.')
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--pal-header', action='append', required=True)
    parser.add_argument('--framework', action='append', required=True, help='a framework to write accessors for')
    parser.add_argument('--stub-framework', action='append', default=[], help='a framework the SDK lacks: write an empty file for it')
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--types-output-dir', help='where to write PALSoftLinkTypes/ (default: --output-dir)')
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--target', required=True)
    parser.add_argument('--synthesize-interface', help='the swift-synthesize-interface executable (default: xcrun\'s)')
    parser.add_argument('--synthesize-argument', action='append', default=[], help='an extra swift-synthesize-interface argument')
    parser.add_argument('--framework-path', action='append', default=[], metavar='FRAMEWORK=PATH', help='load FRAMEWORK from PATH instead of /System/Library (for tests that substitute a fake framework)')
    arguments = parser.parse_args(argv)
    try:
        generate(arguments)
    except GeneratorError as error:
        sys.exit(f'generate-soft-link-accessors.py: error: {error}')


if __name__ == '__main__':
    main(sys.argv[1:])
