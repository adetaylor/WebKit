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
#   - A manifest (WebCore/platform/cocoa/SoftLinkAccessors.in) of the symbols Swift uses: `kind framework symbol`.
#   - The SDK: a generated header of `typedef __typeof__(&symbol)` names each symbol's type as the SDK declares it
#     (__typeof__ is unevaluated, so the header references no symbol), and swift-synthesize-interface gives the imported
#     declarations' Swift signatures.
#
# Outputs, in --output-dir:
#   - PALSoftLinkTypes/{module.modulemap,PALSoftLinkTypes.h}, or in --types-output-dir: a directory that the clients of
#     the Swift module search, since they load the modules it imports
#   - <Framework>SoftLinkAccessors.swift for each --framework: dlopen, dlsym and objc_lookUpClass, and the casts to the
#     SDK's types. These are the only files with soft-link `unsafe`.

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
    'CoreMedia': '#include <CoreMedia/CoreMedia.h>',
    'MediaToolbox': '#include <MediaToolbox/MediaToolbox.h>',
    'VideoToolbox': '#include <VideoToolbox/VideoToolbox.h>',
}

KINDS = ('function', 'constant', 'class')


class GeneratorError(Exception):
    pass


class Declaration:
    def __init__(self, kind, framework, name, may_fail):
        self.kind = kind
        self.framework = framework
        self.name = name
        self.may_fail = may_fail

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
        declarations.symbols[arguments[2]] = Declaration(kind, arguments[1], arguments[2], bool(m.group(2)))

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


def parse_manifest(lines):
    entries = []
    for number, line in enumerate(lines, 1):
        line = line.split('#')[0].strip()
        if not line:
            continue
        words = line.split()
        if len(words) == 5 and words[0] == 'constant' and words[3] == 'as':
            entries.append(tuple(words[:3]) + (words[4],))
            continue
        if len(words) != 3 or words[0] not in KINDS:
            raise GeneratorError(f'manifest line {number}: expected "<{"|".join(KINDS)}> <framework> <symbol>", or "constant <framework> <symbol> as <type>"')
        entries.append(tuple(words) + (None,))
    return entries


def validate(entries, declarations, frameworks):
    errors = []
    seen = set()
    for kind, framework, name, _ in entries:
        if name in seen:
            errors.append(f'{name}: listed twice')
        seen.add(name)
        declaration = declarations.symbols.get(name)
        if not declaration:
            errors.append(f'{name}: not soft-linked by PAL (add a SOFT_LINK_* declaration first)')
        elif declaration.kind != kind or declaration.framework != framework:
            errors.append(f'{name}: the manifest says {kind} in {framework}, PAL says {declaration.kind} in {declaration.framework}')
        if framework not in frameworks:
            errors.append(f'{name}: {framework} is not one of the frameworks to generate ({", ".join(frameworks)})')
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


def function_accessor(declaration, typedef, imported):
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
            load = f'{swift_type}(rawValue: {load})'
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


def class_accessor(declaration, module):
    name = declaration.name
    qualified = f'{module}.{name}'
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


def framework_path(framework, private_frameworks):
    directory = 'PrivateFrameworks' if framework in private_frameworks else 'Frameworks'
    return f'/System/Library/{directory}/{framework}.framework/{framework}'


def accessors_file(framework, entries, declarations, typedefs, interfaces_for):
    path = framework_path(framework, declarations.private_frameworks)
    framework_entries = [(kind, name, swift_type) for kind, f, name, swift_type in entries if f == framework]
    kinds = {kind for kind, _, _ in framework_entries}
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
    if 'class' in kinds:
        w.append('import Foundation')
    w.append(f'import {framework}')
    w.append('import ObjectiveC')
    w.append('import PALSoftLinkTypes')
    w.append('')
    if 'constant' in kinds:
        w.append(f'enum {framework}SoftLink {{ }}')
    if 'class' in kinds:
        w.append(f'enum {framework}Class {{ }}')
    if 'constant' in kinds or 'class' in kinds:
        w.append('')
    w.append('nonisolated(unsafe) private let frameworkHandle: UnsafeMutableRawPointer = {')
    w.append(f'    guard let handle = unsafe dlopen("{path}", RTLD_NOW) else {{')
    w.append(f'        preconditionFailure("{framework} failed to load")')
    w.append('    }')
    w.append('    return unsafe handle')
    w.append('}()')
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
            w += function_accessor(declaration, typedef, imported)
        elif kind == 'constant':
            pointee = find_constant_typedef(typedefs, f'PALSoftLink_{name}_t')
            if not pointee:
                raise GeneratorError(f'{name}: no typedef found')
            w += constant_accessor(declaration, pointee, swift_type)
        else:
            w += class_accessor(declaration, framework)
        w.append('')
    return '\n'.join(w).rstrip('\n') + '\n'


def types_header(entries):
    frameworks = sorted({f for kind, f, _, _ in entries if kind != 'class'})
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
    for kind, _, name, _ in entries:
        if kind != 'class':
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


def generate(arguments):
    with open(arguments.manifest) as f:
        entries = parse_manifest(f.readlines())
    declarations = parse_pal(arguments.pal_header)
    validate(entries, declarations, arguments.framework)

    types_dir = os.path.join(arguments.types_output_dir or arguments.output_dir, 'PALSoftLinkTypes')
    os.makedirs(types_dir, exist_ok=True)
    write_if_changed(os.path.join(types_dir, 'module.modulemap'), MODULE_MAP)
    write_if_changed(os.path.join(types_dir, 'PALSoftLinkTypes.h'), types_header(entries))

    tool = [arguments.synthesize_interface] if arguments.synthesize_interface else ['xcrun', 'swift-synthesize-interface']
    synthesize = Synthesizer(tool, arguments.sdk, arguments.target, arguments.synthesize_argument)
    typedefs = synthesize('PALSoftLinkTypes', [types_dir]) if any(kind != 'class' for kind, _, _, _ in entries) else ''
    for framework in arguments.framework:
        content = accessors_file(framework, entries, declarations, typedefs, synthesize.framework)
        write_if_changed(os.path.join(arguments.output_dir, f'{framework}SoftLinkAccessors.swift'), content)


def main(argv):
    parser = argparse.ArgumentParser(description='Generates the Swift accessors for symbols that PAL soft-links.')
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--pal-header', action='append', required=True)
    parser.add_argument('--framework', action='append', required=True, help='a framework to write accessors for')
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--types-output-dir', help='where to write PALSoftLinkTypes/ (default: --output-dir)')
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--target', required=True)
    parser.add_argument('--synthesize-interface', help='the swift-synthesize-interface executable (default: xcrun\'s)')
    parser.add_argument('--synthesize-argument', action='append', default=[], help='an extra swift-synthesize-interface argument')
    arguments = parser.parse_args(argv)
    try:
        generate(arguments)
    except GeneratorError as error:
        sys.exit(f'generate-soft-link-accessors.py: error: {error}')


if __name__ == '__main__':
    main(sys.argv[1:])
