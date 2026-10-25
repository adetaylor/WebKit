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

"""Checks the Swift sources of the WGSL compiler for what the Swift type system cannot express.

The wgsl/L-* rules apply to Source/WebGPU/WGSL/**/*.swift: the WGSL module, and the wgslc and wgslfuzz tools
where a rule names them. A line opts out of a rule with `// lint-exempt(RULE): reason`, or with
`// lint-exempt-next-line(RULE): reason` on the line above; an exemption without a reason does not count, and
L-STUB-1 cannot be exempted. Most rules read the other Swift files of Source/WebGPU/WGSL from the checkout.

Headers under Source/WebGPU/WebGPU must not test HAVE(WGSL_COMPILER) (wgsl/have_wgsl_compiler).
"""

import bisect
import os
import re

from webkitpy.style.checkers.cpp import CppChecker
from webkitpy.style.checkers.swift import SwiftChecker

MODULE_DIR = 'Source/WebGPU/WGSL/'
TOOL_DIRS = ('Source/WebGPU/WGSL/wgslc/', 'Source/WebGPU/WGSL/wgslfuzz/')
FUZZ_ENTRY = 'Source/WebGPU/WGSL/wgslfuzz/wgslfuzz.swift'
WEBGPU_HEADER_DIR = 'Source/WebGPU/WebGPU/'


# ---------------------------------------------------------------------------------------------------------------
# Swift scanner: masks comments and string literal contents, keeps interpolated code visible.

class Literal:
    __slots__ = ('line', 'text', 'interps', 'offsets', 'multiline')

    def __init__(self, line, multiline):
        self.line = line
        self.text = []
        self.interps = []
        self.offsets = []  # the offset in the file text of each interpolation's code
        self.multiline = multiline


def scan_swift(text):
    """Returns (code lines, comment text per line, literals).

    Code lines have the same length as the source lines: comments become spaces, literal contents NUL,
    the quotes and the code of interpolations stay. A literal's text has \\x01 where an interpolation was."""
    out = list(text)
    comments = [[] for _ in range(text.count('\n') + 1)]
    literals = []
    n = len(text)
    i = 0
    line = 0
    stack = [['code', None]]
    while i < n:
        c = text[i]
        top = stack[-1]
        kind = top[0]
        if c == '\n':
            if kind == 'str' and not top[2]:
                stack.pop()
            line += 1
            i += 1
            continue
        if kind == 'block':
            if text.startswith('/*', i):
                top[1] += 1
                comments[line].append('/*')
                out[i] = out[i + 1] = ' '
                i += 2
                continue
            if text.startswith('*/', i):
                top[1] -= 1
                comments[line].append('*/')
                out[i] = out[i + 1] = ' '
                i += 2
                if top[1] == 0:
                    stack.pop()
                continue
            comments[line].append(c)
            out[i] = ' '
            i += 1
            continue
        if kind == 'str':
            hashes, multi, lit = top[1], top[2], top[3]
            close = ('"""' if multi else '"') + '#' * hashes
            if text.startswith(close, i):
                i += len(close)
                stack.pop()
                continue
            esc = '\\' + '#' * hashes
            if text.startswith(esc, i):
                k = i + len(esc)
                if k < n and text[k] == '(':
                    for j in range(i, k):
                        out[j] = '\x00'
                    lit.text.append('\x01')
                    stack.append(['code', [0, lit, k + 1]])
                    i = k + 1
                    continue
                for j in range(i, min(k + 1, n)):
                    if out[j] != '\n':
                        out[j] = '\x00'
                lit.text.append(text[i:k + 1])
                i = k + 1
                continue
            lit.text.append(c)
            out[i] = '\x00'
            i += 1
            continue
        interp = top[1]
        if interp is not None:
            if c == '(':
                interp[0] += 1
            elif c == ')':
                if interp[0] == 0:
                    interp[1].interps.append(text[interp[2]:i])
                    interp[1].offsets.append(interp[2])
                    stack.pop()
                    i += 1
                    continue
                interp[0] -= 1
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            j = text.find('\n', i)
            j = n if j < 0 else j
            comments[line].append(text[i:j])
            for k in range(i, j):
                out[k] = ' '
            i = j
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            stack.append(['block', 1])
            comments[line].append('/*')
            out[i] = out[i + 1] = ' '
            i += 2
            continue
        if c == '"' or c == '#':
            j = i
            while j < n and text[j] == '#':
                j += 1
            if j < n and text[j] == '"':
                multi = text.startswith('"""', j)
                lit = Literal(line, multi)
                literals.append(lit)
                stack.append(['str', j - i, multi, lit])
                i = j + (3 if multi else 1)
                continue
        i += 1
    for lit in literals:
        lit.text = ''.join(lit.text)
    return ''.join(out).split('\n'), [''.join(c) for c in comments], literals


# ---------------------------------------------------------------------------------------------------------------
# Structure: logical statements and brace scopes.

ATTR_RE = re.compile(r'@[\w.]+(?:\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))?\s*')
MOD_RE = re.compile(r'(?:public|private|fileprivate|internal|package|open|static|final|override|mutating|nonmutating|'
                    r'consuming|borrowing|indirect|lazy|weak|unowned|convenience|required|dynamic|nonisolated|'
                    r'isolated|prefix|postfix|infix|optional|distributed|__consuming)(?:\(\s*\w+\s*\))?\s+')
CLASS_MOD_RE = re.compile(r'class\s+(?=(?:func|var|let|subscript|override|final|static|public|private|internal)\b)')
TYPE_DECL_RE = re.compile(r'(struct|class|enum|protocol|actor|extension)\s+([\w.]+)')
ACCESSOR_RE = re.compile(r'(?:get|set|willSet|didSet|_modify|modify|_read|read|unsafeAddress|unsafeMutableAddress)\b')


class Decl:
    __slots__ = ('attrs', 'mods', 'kw', 'name', 'rest', 'params', 'generics', 'inherits', 'offset')

    def __init__(self):
        self.attrs = []
        self.mods = set()
        self.kw = None
        self.name = None
        self.rest = ''
        self.params = None
        self.generics = []
        self.inherits = []
        self.offset = 0


def matching(s, i, open_ch, close_ch):
    """Index of the bracket closing s[i] (== open_ch), or len(s)."""
    depth = 0
    for j in range(i, len(s)):
        if s[j] == open_ch:
            depth += 1
        elif s[j] == close_ch:
            depth -= 1
            if depth == 0:
                return j
    return len(s)


def split_top(s, sep=','):
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch in '([<{':
            depth += 1
        elif ch in ')]>}':
            depth -= 1
        if ch == sep and depth == 0:
            parts.append(''.join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append(''.join(cur))
    return parts


def top_level_has(s, ch):
    depth = 0
    for c in s:
        if c in '([<{':
            depth += 1
        elif c in ')]>}':
            depth -= 1
        elif c == ch and depth == 0:
            return True
    return False


def has_top_level_assign(s):
    depth = 0
    for j, ch in enumerate(s):
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        elif ch == '=' and depth == 0:
            prev = s[j - 1] if j > 0 else ''
            nxt = s[j + 1] if j + 1 < len(s) else ''
            if prev not in '=!<>-+*/%&|^~' and nxt not in '=>':
                return True
    return False


def parse_decl(text):
    d = Decl()
    s = text
    pos = 0
    while True:
        while pos < len(s) and s[pos] in ' \t\n':
            pos += 1
        m = ATTR_RE.match(s, pos)
        if m and m.end() > pos:
            d.attrs.append(m.group(0).strip())
            pos = m.end()
            continue
        m = MOD_RE.match(s, pos) or CLASS_MOD_RE.match(s, pos)
        if m:
            d.mods.add(re.match(r'\w+', m.group(0)).group(0))
            pos = m.end()
            continue
        break
    d.offset = pos
    rest = s[pos:]
    m = TYPE_DECL_RE.match(rest)
    if m:
        d.kw, d.name = m.group(1), m.group(2)
        after = rest[m.end():]
        k = 0
        while k < len(after) and after[k] in ' \t\n':
            k += 1
        if k < len(after) and after[k] == '<':
            e = matching(after, k, '<', '>')
            d.generics = [g.split(':')[0].strip() for g in split_top(after[k + 1:e]) if g.strip()]
            after = after[e + 1:]
        else:
            after = after[k:]
        after = re.split(r'\bwhere\b', after)[0]
        after = after.strip()
        if after.startswith(':'):
            d.inherits = [re.sub(r'<.*', '', x).replace('~', '').replace('@unchecked', '').strip()
                          for x in split_top(after[1:]) if x.strip()]
        d.rest = rest
        return d
    m = re.match(r'(func)\s+([^\s(<]+)', rest) or re.match(r'(init)[?!]?(?=\s*[(<])', rest) or \
        re.match(r'(subscript)(?=\s*[(<])', rest)
    if m:
        d.kw = m.group(1)
        d.name = m.group(2) if d.kw == 'func' else d.kw
        k = m.end()
        while k < len(rest) and rest[k] in ' \t\n':
            k += 1
        if k < len(rest) and rest[k] == '<':
            e = matching(rest, k, '<', '>')
            d.generics = [g.split(':')[0].strip() for g in split_top(rest[k + 1:e]) if g.strip()]
            k = e + 1
        p = rest.find('(', k)
        if p >= 0:
            e = matching(rest, p, '(', ')')
            d.params = rest[p + 1:e]
        d.rest = rest
        return d
    m = re.match(r'deinit\b', rest)
    if m:
        d.kw = d.name = 'deinit'
        d.rest = rest
        return d
    m = re.match(r'(var|let|case)\s+(\w+)', rest)
    if m:
        d.kw, d.name = m.group(1), m.group(2)
        d.rest = rest
        return d
    m = re.match(r'(typealias|associatedtype|import)\b', rest)
    if m:
        d.kw = m.group(1)
    d.rest = rest
    return d


class Scope:
    __slots__ = ('kind', 'name', 'decl', 'parent', 'line', 'end_line')

    def __init__(self, kind, name, decl, parent, line):
        self.kind = kind
        self.name = name
        self.decl = decl
        self.parent = parent
        self.line = line
        self.end_line = None

    def chain(self):
        s = self
        while s is not None:
            yield s
            s = s.parent


class Stmt:
    __slots__ = ('line', 'col', 'text', 'scope', 'opens', 'ended_by')

    def __init__(self, line, text, scope, col=0):
        self.line = line
        self.col = col
        self.text = text
        self.scope = scope
        self.opens = None
        self.ended_by = None

    def line_of(self, offset):
        return self.line + self.text.count('\n', 0, offset)

    def pos_of(self, offset):
        """(line, column) in the file of an offset into text (continuation lines keep their indentation)."""
        nl = self.text.rfind('\n', 0, offset)
        if nl < 0:
            return self.line, self.col + offset
        return self.line_of(offset), offset - nl - 1


def classify(header, parent, line):
    d = parse_decl(header)
    if d.kw in ('struct', 'class', 'enum', 'actor'):
        return Scope('type', d.name.split('.')[-1], d, parent, line)
    if d.kw == 'protocol':
        return Scope('protocol', d.name, d, parent, line)
    if d.kw == 'extension':
        return Scope('extension', d.name.split('.')[-1], d, parent, line)
    if d.kw in ('func', 'init', 'subscript', 'deinit'):
        return Scope('func', d.name, d, parent, line)
    if d.kw == 'var' and not has_top_level_assign(header):
        return Scope('accessor', d.name, d, parent, line)
    if d.kw is None and ACCESSOR_RE.match(d.rest.strip()) and parent is not None and parent.kind == 'accessor':
        return Scope('accessor', d.rest.strip().split()[0], d, parent, line)
    word = re.match(r'\w*', d.rest.strip()).group(0)
    return Scope('block', word, d, parent, line)


DIRECTIVE_RE = re.compile(r'\s*#(if|elseif|else|endif)\b(.*)')
LINE_END_CONT = ('(', '[', ',', '=', '->', '&&', '||', '.', '+', '-', '*', '/', '&', '|', '%', '^')
NEXT_START_CONT = re.compile(r'(?:\.|->|where\b|throws\b|rethrows\b|async\b|&&|\|\||\?|:(?!:)|[-+*/%&|^=<>](?!/))')
ATTR_ONLY_RE = re.compile(r'^(?:' + ATTR_RE.pattern + r')+$')


def structure(code):
    root = Scope('file', '', None, None, 0)
    scope = root
    transitions = []
    stmts = []
    state = {'text': [], 'start': None, 'col': 0, 'depth': 0}
    pending = [None]
    ifstack = []
    ifconds = []
    next_nonblank = [None] * len(code)
    nxt = None
    for ln in range(len(code) - 1, -1, -1):
        next_nonblank[ln] = nxt
        if code[ln].strip():
            nxt = ln

    def finish(ended_by):
        text = ''.join(state['text'])
        st = None
        if text.strip():
            st = Stmt(state['start'], text, scope, state['col'])
            st.ended_by = ended_by
            stmts.append(st)
        state['text'] = []
        state['start'] = None
        state['depth'] = 0
        return st

    for ln, line in enumerate(code):
        transitions.append([(0, scope)])
        ifconds.append(tuple(ifstack))
        m = DIRECTIVE_RE.match(line)
        if m:
            st = finish('directive')
            pending[0] = None
            kw, cond = m.group(1), m.group(2).strip()
            if kw == 'if':
                ifstack.append((cond, True))
            elif kw in ('elseif', 'else'):
                if ifstack:
                    prev = ifstack.pop()
                    ifstack.append((prev[0], False) if kw == 'else' else (cond, True))
            elif kw == 'endif' and ifstack:
                ifstack.pop()
            continue
        for col, ch in enumerate(line):
            if ch == '{':
                text = ''.join(state['text'])
                if not text.strip() and pending[0] is not None and pending[0].ended_by == 'newline' and \
                        pending[0].opens is None:
                    st = pending[0]
                    header = st.text
                    hdr_line = st.line
                else:
                    st = finish('brace')
                    header = st.text if st else ''
                    hdr_line = st.line if st else ln
                new = classify(header, scope, hdr_line)
                if st is not None:
                    st.opens = new
                scope = new
                transitions[ln].append((col + 1, scope))
                pending[0] = None
                continue
            if ch == '}':
                finish('close')
                scope.end_line = ln
                scope = scope.parent or root
                transitions[ln].append((col + 1, scope))
                pending[0] = None
                continue
            if ch == ';' and state['depth'] == 0:
                pending[0] = finish('semicolon')
                continue
            if ch in '([':
                state['depth'] += 1
            elif ch in ')]':
                state['depth'] = max(0, state['depth'] - 1)
            if state['start'] is None:
                if ch in ' \t':
                    continue
                state['start'] = ln
                state['col'] = col
            state['text'].append(ch)
        if state['start'] is None:
            continue
        cont = state['depth'] > 0
        if not cont:
            cur = ''.join(state['text']).rstrip()
            if cur.endswith(LINE_END_CONT) or ATTR_ONLY_RE.match(cur.strip()):
                cont = True
            else:
                nn = next_nonblank[ln]
                if nn is not None and not DIRECTIVE_RE.match(code[nn]) and NEXT_START_CONT.match(code[nn].lstrip()):
                    cont = True
        if cont:
            state['text'].append('\n')
        else:
            pending[0] = finish('newline')
    finish('eof')
    return root, stmts, transitions, ifconds


# ---------------------------------------------------------------------------------------------------------------
# Files

EXEMPT_RE = re.compile(r'lint-exempt(-next-line)?\(\s*([A-Z0-9, -]+?)\s*\)\s*(?::\s*(\S.*))?')


class SwiftFile:
    def __init__(self, rel, text):
        self.rel = rel
        self.text = text
        self.raw = text.split('\n')
        self.code, self.comments, self.literals = scan_swift(text)
        self.root, self.stmts, self.transitions, self.ifconds = structure(self.code)
        self.exempt = {}
        for ln, comment in enumerate(self.comments):
            for m in EXEMPT_RE.finditer(comment):
                target = ln + 1 if m.group(1) else ln
                for rule in m.group(2).split(','):
                    rule = rule.strip()
                    if rule:
                        self.exempt.setdefault(target, {})[rule] = m.group(3)
        self.lits_by_line = {}
        for lit in self.literals:
            self.lits_by_line.setdefault(lit.line, []).append(lit)
        self._line_starts = None

    def pos_at(self, offset):
        """(line, column) of an offset into the file text."""
        if self._line_starts is None:
            self._line_starts = [0]
            for line in self.raw:
                self._line_starts.append(self._line_starts[-1] + len(line) + 1)
        ln = bisect.bisect_right(self._line_starts, offset) - 1
        return ln, offset - self._line_starts[ln]

    def code_at(self, offset, length):
        """The masked code (f.code) of the file text's [offset, offset + length)."""
        ln, col = self.pos_at(offset)
        n = self.text.count('\n', offset, offset + length)
        return '\n'.join(self.code[ln:ln + n + 1])[col:col + length]

    @property
    def base(self):
        return self.rel.rsplit('/', 1)[-1]

    @property
    def mrel(self):
        """The path relative to Source/WebGPU/WGSL/ ('' outside it)."""
        return self.rel[len(MODULE_DIR):] if self.rel.startswith(MODULE_DIR) else ''

    @property
    def is_module(self):
        return self.rel.startswith(MODULE_DIR) and not self.rel.startswith(TOOL_DIRS)

    @property
    def is_tool(self):
        return self.rel.startswith(TOOL_DIRS)

    def scope_at(self, ln, col):
        tr = self.transitions[ln]
        k = bisect.bisect_right([c for c, _ in tr], col) - 1
        return tr[max(k, 0)][1]


def match_mrel(f, *patterns):
    """Whether f's module-relative path matches one of the patterns ('dir/' is a prefix; '*' stays within a component)."""
    for p in patterns:
        if p.endswith('/'):
            if f.mrel.startswith(p):
                return True
        elif re.fullmatch(re.escape(p).replace(r'\*', '[^/]*'), f.mrel):
            return True
    return False


# ---------------------------------------------------------------------------------------------------------------
# Rules

class Rule:
    def __init__(self, rid, bans, use, scope, check):
        self.id = rid
        self.bans = bans
        self.use = use
        self.scope = scope
        self.check = check


RULES = []


def rule(rid, bans, use, scope):
    def wrap(fn):
        RULES.append(Rule(rid, bans, use, scope, fn))
        return fn
    return wrap


def call_args(f, ln, p):
    """The text between the parenthesis at f.code[ln][p] and its match, looking at most 8 lines ahead."""
    text = '\n'.join(f.code[ln:ln + 8])
    e = matching(text, p, '(', ')')
    return text[p + 1:e]


def regex_lines(f, rx, lines=None):
    for ln in (range(len(f.code)) if lines is None else lines):
        for m in rx.finditer(f.code[ln]):
            yield ln, m


SAFE_RE = re.compile(r'(?<![\w@])(?:@?unsafe\w*|Unsafe\w*|withUnsafe\w*|withUTF8Buffer|utf8Start|Unmanaged|'
                     r'unsafelyUnwrapped|OpaquePointer|AutoreleasingUnsafe\w*)\b|@unsafe\b|@unchecked\b')


@rule('L-SAFE-1', '`unsafe`, `@unsafe`, `Unsafe*Pointer`, `withUnsafe*`, `unsafeBitCast`, `withUTF8Buffer`, `utf8Start`, '
      '`Unmanaged`, `@unchecked`', 'safe APIs', 'module, wgslc, wgslfuzz (the wgslfuzz entry is exempt)')
def check_safe(ctx, f):
    if not (f.is_module or f.is_tool) or f.rel == FUZZ_ENTRY:
        return
    for ln, m in regex_lines(f, SAFE_RE):
        yield ln, m.group(0)


IMPORT_RE = re.compile(r'^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:(public|internal|private|fileprivate|package)\s+)?import\s+'
                       r'(?:(?:class|struct|enum|func|protocol|typealias|var|let)\s+)?([\w.]+)')


@rule('L-IMPORT-1', '`import Foundation`, any import other than `internal import Darwin` in `Support/LibM.swift`', 'stdlib',
      'module')
def check_import(ctx, f):
    if not f.is_module:
        return
    for ln, m in regex_lines(f, IMPORT_RE):
        if f.mrel == 'Support/LibM.swift' and m.group(1) == 'internal' and m.group(2) == 'Darwin' and \
                re.fullmatch(r'\s*internal\s+import\s+Darwin\s*', f.code[ln]):
            continue
        yield ln, 'import ' + m.group(2)


BD_RE = re.compile(r'\bFloat16\b|\bInlineArray\b|\[\s*\d+\s+of\s+\w|\b(?:Mutable)?(?:Raw)?Span\b|\bOutput(?:Raw)?Span\b|'
                   r'\bUTF8Span\b|\.(?:mutableSpan|mutableBytes|utf8Span)\b|'
                   r'\.span\b(?=\s*(?:\[|\.(?:count|isEmpty|indices|extracting|withUnsafe\w*|bytes|isIdentical)\b))|'
                   r'\bTask\s*\.\s*immediate\b|\bisTriviallyIdentical\b')


@rule('L-BD-1', '`Float16`, `InlineArray`, `.span`, `.mutableSpan`, `utf8Span`, `RawSpan`, `MutableSpan`, `Span<` and other '
      'macOS 26+ APIs', '`Half`, arrays', 'module')
def check_bd(ctx, f):
    if not f.is_module:
        return
    for ln, m in regex_lines(f, BD_RE):
        yield ln, m.group(0).strip()


@rule('L-GLOBAL-1', '`static var`, global `var`, `nonisolated(unsafe)` (computed properties are not state)',
      'immutable `let` or instance state', 'module')
def check_global(ctx, f):
    if not f.is_module:
        return
    for ln, m in regex_lines(f, re.compile(r'\bnonisolated\s*\(\s*unsafe\s*\)')):
        yield ln, m.group(0)
    for st in f.stmts:
        d = parse_decl(st.text)
        if d.kw != 'var':
            continue
        static = 'static' in d.mods or 'class' in d.mods
        if not static and st.scope.kind != 'file':
            continue
        computed = st.opens is not None and st.opens.kind == 'accessor'
        if not computed:
            yield st.line_of(d.offset), ('static var ' if static else 'global var ') + d.name


def dictionary_names(f):
    """Names declared anywhere in f with a Dictionary or Set type (annotation or initialiser)."""
    names = set()
    joined = '\n'.join(f.code)
    for m in re.finditer(r'\b(\w+)\s*:\s*(?:inout\s+|borrowing\s+|consuming\s+)?(\[|Dictionary\s*<|Set\s*<)', joined):
        if m.group(2) == '[':
            e = matching(joined, m.end() - 1, '[', ']')
            if not top_level_has(joined[m.end():e], ':'):
                continue
        names.add(m.group(1))
    for m in re.finditer(r'\b(?:let|var)\s+(\w+)\s*=\s*(?:Dictionary\s*[<(]|Set\s*[<(]|\[\s*:\s*\]|\[[^\[\]=]*:[^\[\]=]*\]\s*\()',
                         joined):
        names.add(m.group(1))
    names.discard('_')
    return names


class TypedNames:
    """Declarations of names in a file, so a use can be resolved to the textually nearest preceding declaration."""

    def __init__(self, f, type_re):
        self.decls = {}
        rx_typed = re.compile(r'(?<![\w.])(\w+)\s*:\s*(?:inout\s+|borrowing\s+|consuming\s+)?(?:' + type_re + r')(?!\s*[.(<\w])')
        rx_init = re.compile(r'\b(?:let|var)\s+(\w+)\s*=\s*(?:' + type_re + r')\s*\(')
        rx_any = re.compile(r'\b(?:let|var)\s+(\w+)\b|(?<![\w.])(\w+)\s*:(?!:)')
        for ln, line in enumerate(f.code):
            typed = {}
            for m in rx_typed.finditer(line):
                typed[m.start(1)] = True
            for m in rx_init.finditer(line):
                typed[m.start(1)] = True
            for m in rx_any.finditer(line):
                g = 1 if m.group(1) else 2
                self.decls.setdefault(m.group(g), []).append(((ln, m.start(g)), typed.get(m.start(g), False)))

    def names(self):
        return {n for n, ds in self.decls.items() if any(t for _, t in ds) and n != '_'}

    def is_typed(self, name, ln, col):
        best = None
        for pos, typed in self.decls.get(name, ()):
            if pos < (ln, col):
                best = typed
        return bool(best)


def split_top_spans(s, sep=','):
    """split_top, with each part's start offset in s."""
    out, depth, start = [], 0, 0
    for j, ch in enumerate(s):
        if ch in '([<{':
            depth += 1
        elif ch in ')]>}':
            depth -= 1
        elif ch == sep and depth == 0:
            out.append((s[start:j], start))
            start = j + 1
    out.append((s[start:], start))
    return out


def top_level_index(s, chars):
    """Index of the first character of s in chars outside brackets (an `=` of `==`/`!=`/`<=`/`>=`/`->` does not
    count), or -1."""
    depth = 0
    for j, ch in enumerate(s):
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        elif ch in chars and depth == 0:
            if ch == '=' and ((j > 0 and s[j - 1] in '=!<>') or s[j + 1:j + 2] in ('=', '>')):
                continue
            return j
    return -1


DECL_NAME_RE = re.compile(r'[A-Za-z_]\w*')
CONTROL_HEADS = ('if', 'while', 'for', 'catch', 'else', 'repeat', 'do')
CLOSURE_PARAMS_RE = re.compile(r'\s*(?:\[[^\]\n]*\]\s*)?(?:\(((?:[^()]|\([^()]*\))*)\)|((?:[A-Za-z_]\w*\s*,\s*)*[A-Za-z_]\w*))\s*'
                               r'(?:async\s+)?(?:throws(?:\s*\([^()]*\))?\s+)?(?:->\s*[^{}]+?\s+)?in\b')
NOT_CLOSURE_HEADS = {'for', 'case', 'if', 'while', 'guard', 'switch', 'return', 'let', 'var', 'try', 'await', 'throw',
                     'else', 'repeat', 'do', 'catch', 'defer', 'func', 'init', 'subscript', 'import', 'typealias'}


class Decl2:
    __slots__ = ('name', 'owner', 'pos', 'type', 'init', 'src')

    def __init__(self, name, owner, pos, type_text, init_text, src=None):
        self.name = name
        self.owner = owner
        self.pos = pos
        self.type = type_text
        self.init = init_text
        # Where an unannotated binding's value comes from: ('elem', sequence, tuple index or None, (line, col)) for a
        # for-in binding, ('payload', case name, index, qualifier, `if case` subject) for an enum case pattern,
        # ('closure', index) for a closure parameter.
        self.src = src


def bracket_depths(s):
    """The ([{ nesting depth before each character of s."""
    out, depth = [], 0
    for ch in s:
        if ch in ')]}':
            depth = max(0, depth - 1)
        out.append(depth)
        if ch in '([{':
            depth += 1
    return out


def split_clauses(s):
    """split_top_spans on commas nested only in ([{ (a `<` of a comparison does not open anything)."""
    out, start = [], 0
    for j, d in enumerate(bracket_depths(s)):
        if s[j] == ',' and d == 0:
            out.append((s[start:j], start))
            start = j + 1
    out.append((s[start:], start))
    return out


def top_level_word(s, word):
    """Offset of the first top-level whole word in s, or -1."""
    depths = None
    for m in re.finditer(r'\b%s\b' % word, s):
        if depths is None:
            depths = bracket_depths(s)
        if depths[m.start()] == 0:
            return m.start()
    return -1


class DeclIndex:
    """The declarations of a file with the scope each belongs to, so that a use resolves roughly the way Swift's lookup
    does: the innermost enclosing local scope that declares the name before the use, else a member of an enclosing type,
    of an extension of a type with the same name or of a base type or protocol named in the file, else a file-level
    declaration. Parameters belong to their function, `if`/`while`/`for`/`catch` bindings to their block, `guard` and
    `case` bindings to the enclosing scope, closure parameters to the closure. Also records what the type inference
    of L-MSL-2 needs: function return types, enum cases, typealiases, generic constraints and closure headers."""

    def __init__(self, f):
        self.by_name = {}
        self.headers = {}      # id(scope) -> the statement that opened it
        self.inherits = {}     # type name -> inherited type names
        self.generics = {}     # generic parameter name -> constraint text
        self.funcs = []        # (name, owner type name or None, return type text)
        self.enum_cases = []   # (case name, enum name, [payload type texts])
        self.aliases = {}      # typealias name -> type text
        seen_scopes = set()
        for st in f.stmts:
            if st.opens is not None:
                self.headers[id(st.opens)] = st
                if st.opens.kind in ('type', 'extension', 'protocol') and st.opens.decl is not None:
                    self.inherits.setdefault(st.opens.name, []).extend(st.opens.decl.inherits)
            first_in_scope = id(st.scope) not in seen_scopes
            seen_scopes.add(id(st.scope))
            self._collect(st, first_in_scope)

    def _add(self, st, name, owner, offset, type_text, init_text, src=None):
        if name == '_' or owner is None:
            return
        self.by_name.setdefault(name, []).append(Decl2(name, owner, st.pos_of(offset), type_text, init_text, src))

    def _binding(self, st, owner, part, base, shorthand=False):
        """`name[: Type][= init]` at offset base of st.text (`if let name` stands for `if let name = name`)."""
        m = re.match(r'\s*([A-Za-z_]\w*)', part)
        if not m:
            return
        rest = part[m.end():]
        type_text = init_text = None
        k = rest.lstrip()
        if k.startswith(':') and not k.startswith('::'):
            body = k[1:]
            e = top_level_index(body, '={')
            type_text = (body if e < 0 else body[:e]).strip()
            if e >= 0 and body[e] == '=':
                init_text = body[e + 1:].strip()
        elif k.startswith('=') and not k.startswith('=='):
            init_text = k[1:].strip()
        elif shorthand:
            init_text = m.group(1)
        self._add(st, m.group(1), owner, base + m.start(1), type_text, init_text)

    def _pattern_names(self, st, owner, text, base):
        for m in DECL_NAME_RE.finditer(text):
            if m.group(0) not in ('let', 'var', '_', 'in', 'case') and not text[:m.start()].rstrip().endswith('.'):
                self._add(st, m.group(0), owner, base + m.start(), None, None)

    def _generic_constraints(self, text):
        k = text.find('<')
        if k >= 0 and re.match(r'(?:func\s+[^\s(<]+|init[?!]?|subscript|(?:struct|class|enum|actor|extension)\s+[\w.]+)\s*$',
                               text[:k]):
            e = matching(text, k, '<', '>')
            for g in split_top(text[k + 1:e]):
                if ':' in g:
                    self.generics[g.split(':')[0].strip()] = g.split(':', 1)[1].strip()
        w = top_level_word(text, 'where')
        if w >= 0:
            for g in split_top(text[w + 5:]):
                if ':' in g and '==' not in g:
                    self.generics.setdefault(g.split(':')[0].strip(), g.split(':', 1)[1].strip())

    def _pattern_regions(self, rest, head):
        """(start, end, subject) of the patterns of a `case`/`if case`/`guard case`/`while case`/`for case`/`catch`
        statement: offsets in rest (not optional bindings, initialisers or `where` clauses), and the matched expression
        of an `if case … = subject` clause."""
        regions = []
        if head == 'case':
            body = rest[4:]
            e = top_level_index(body, ':')
            w = top_level_word(body, 'where')
            ends = [x for x in (e, w) if x >= 0]
            regions.append((4, 4 + (min(ends) if ends else len(body)), None))
        elif head in ('if', 'guard', 'while'):
            for clause, off in split_clauses(rest[len(head):]):
                m = re.match(r'\s*case\b', clause)
                if m:
                    eq = top_level_index(clause, '=')
                    regions.append((len(head) + off + m.end(), len(head) + off + (eq if eq >= 0 else len(clause)),
                                    clause[eq + 1:].strip() if eq >= 0 else None))
        elif head == 'for':
            m = re.match(r'for\s+case\b', rest)
            if m:
                i = top_level_word(rest, 'in')
                regions.append((m.end(), i if i >= 0 else len(rest), None))
        elif head == 'catch':
            w = top_level_word(rest, 'where')
            regions.append((5, w if w >= 0 else len(rest), None))
        return regions

    def _pattern_bindings(self, st, owner, rest, a, b, subject, base):
        """The bindings of the pattern rest[a:b]: enum case payloads (`.name(let x)`, `let .name(x)`) remember the case
        and position, `let x as T` its type, the others are unannotated."""
        seg = rest[a:b]
        taken = []
        for pm in re.finditer(r'(?:\b(?!(?:let|var)\b)([A-Za-z_]\w*)\s*)?\.\s*([A-Za-z_]\w*)\s*\(', seg):
            p = pm.end() - 1
            e = matching(seg, p, '(', ')')
            outer = bool(re.search(r'\b(?:let|var)\s*$', seg[:pm.start()]))
            for idx, (part, off) in enumerate(split_top_spans(seg[p + 1:e])):
                q = re.match(r'\s*(?:[A-Za-z_]\w*\s*:(?!:)\s*)?(?:(let|var)\s+)?([A-Za-z_]\w*)\s*$', part)
                if not q or q.group(2) in ('_', 'let', 'var', 'nil', 'true', 'false') or not (q.group(1) or outer):
                    continue
                self._add(st, q.group(2), owner, base + a + p + 1 + off + q.start(2), None, None,
                          ('payload', pm.group(2), idx, pm.group(1), subject))
            taken.append((p, e))
        for m in re.finditer(r'\b(?:let|var)\s+', seg):
            k = m.end()
            if any(x <= m.start() <= y for x, y in taken):
                continue
            if seg[k:k + 1] == '(':
                e = matching(seg, k, '(', ')')
                self._pattern_names(st, owner, seg[k + 1:e], base + a + k + 1)
                continue
            n = DECL_NAME_RE.match(seg, k)
            if not n:
                continue
            t = re.match(r'\s*as\s+(.+?)\s*$', seg[n.end():].split(',')[0])
            self._add(st, n.group(0), owner, base + a + n.start(), t.group(1) if t else None, None)

    def _collect(self, st, first_in_scope):
        t = st.text
        d = parse_decl(t)
        rest = t[d.offset:]
        head = re.match(r'\w*', rest).group(0)
        if d.kw in ('func', 'init', 'subscript'):
            self._generic_constraints(rest)
            owner = st.opens if st.opens is not None and st.opens.kind == 'func' else None
            m = re.match(r'(?:func\s+[^\s(<]+|init[?!]?|subscript)\s*', rest)
            k = m.end() if m else 0
            if k < len(rest) and rest[k] == '<':
                k = matching(rest, k, '<', '>') + 1
            p = rest.find('(', k)
            if p >= 0:
                e = matching(rest, p, '(', ')')
                if d.kw in ('func', 'subscript'):
                    r = re.match(r'\s*(?:async\s+)?(?:(?:re)?throws(?:\s*\([^()]*\))?\s+)?(?:async\s+)?->\s*(.+?)\s*$',
                                 re.split(r'\bwhere\b', rest[e + 1:])[0], re.S)
                    tn = st.scope.name if st.scope.kind in ('type', 'extension', 'protocol') else None
                    self.funcs.append((d.name, tn, r.group(1) if r else 'Void'))
                if owner is not None:
                    for part, off in split_top_spans(rest[p + 1:e]):
                        c = top_level_index(part, ':')
                        if c < 0:
                            continue
                        names = list(DECL_NAME_RE.finditer(part[:c]))
                        if not names:
                            continue
                        n = names[-1]
                        body = part[c + 1:]
                        eq = top_level_index(body, '=')
                        type_text = (body if eq < 0 else body[:eq]).strip()
                        self._add(st, n.group(0), owner, d.offset + p + 1 + off + n.start(), type_text, None)
            return
        if d.kw in ('struct', 'class', 'enum', 'actor', 'extension'):
            self._generic_constraints(rest)
            return
        if d.kw == 'typealias':
            m = re.match(r'typealias\s+([A-Za-z_]\w*)\s*(?:<[^=]*>)?\s*=\s*(.+?)\s*$', rest, re.S)
            if m:
                self.aliases[m.group(1)] = m.group(2)
            return
        if head == 'case' and st.scope.kind == 'type' and st.scope.decl is not None and st.scope.decl.kw == 'enum':
            for part, _ in split_top_spans(rest[4:]):
                m = re.match(r'\s*`?([A-Za-z_]\w*)`?', part)
                if not m:
                    continue
                after = part[m.end():].lstrip()
                payload = []
                if after.startswith('('):
                    e = matching(after, 0, '(', ')')
                    for el in split_top(after[1:e]):
                        c = top_level_index(el, ':')
                        ty = el[c + 1:] if c >= 0 else el
                        eq = top_level_index(ty, '=')
                        payload.append((ty if eq < 0 else ty[:eq]).strip())
                self.enum_cases.append((m.group(1), st.scope.name, payload))
            return
        if d.kw in ('let', 'var') and head in ('let', 'var'):
            body = rest[len(head):]
            base = d.offset + len(head)
            if body.lstrip().startswith('('):
                q = body.index('(')
                e = matching(body, q, '(', ')')
                self._pattern_names(st, st.scope, body[q + 1:e], base + q + 1)
                return
            for part, off in split_top_spans(body):
                self._binding(st, st.scope, part, base + off)
            return
        if head in CONTROL_HEADS or head in ('guard', 'case'):
            owner = st.scope if head in ('guard', 'case') else (st.opens or st.scope)
            regions = []
            if head == 'for':
                m = re.match(r'for\s+(?:case\s+)?(?:(?:let|var)\s+)?(\([^()]*\)|[A-Za-z_]\w*)\s+in\b', rest)
                if m:
                    seq = rest[m.end():]
                    w = top_level_word(seq, 'where')
                    seq = (seq if w < 0 else seq[:w]).strip()
                    at = st.pos_of(d.offset + m.end() + len(rest[m.end():]) - len(rest[m.end():].lstrip()))
                    pat = m.group(1)
                    if pat.startswith('('):
                        for idx, (part, off) in enumerate(split_top_spans(pat[1:-1])):
                            n = re.match(r'\s*(?:(?:let|var)\s+)?([A-Za-z_]\w*)', part)
                            if n:
                                self._add(st, n.group(1), owner, d.offset + m.start(1) + 1 + off + n.start(1), None, None,
                                          ('elem', seq, idx, at))
                    else:
                        self._add(st, pat, owner, d.offset + m.start(1), None, None, ('elem', seq, None, at))
                    return
            regions = self._pattern_regions(rest, head)
            for a, b, subject in regions:
                self._pattern_bindings(st, owner, rest, a, b, subject, d.offset)
            depths = None
            for m in re.finditer(r'\b(?:let|var)\s+(?=[A-Za-z_(])', rest):
                if any(a <= m.start() < b for a, b, _ in regions):
                    continue
                if depths is None:
                    depths = bracket_depths(rest)
                k = m.end()
                if rest[k] == '(':
                    e = matching(rest, k, '(', ')')
                    self._pattern_names(st, owner, rest[k + 1:e], d.offset + k + 1)
                    continue
                n = DECL_NAME_RE.match(rest, k)
                if depths[m.start()] > 0:
                    self._add(st, n.group(0), owner, d.offset + n.start(), None, None)  # a pattern inside parentheses
                    continue
                after = rest[n.end():]
                e = top_level_index(after, ',{')
                self._binding(st, owner, rest[k:n.end()] + (after if e < 0 else after[:e]), d.offset + k, shorthand=True)
            return
        if first_in_scope and st.scope.kind == 'block' and head not in NOT_CLOSURE_HEADS:
            m = CLOSURE_PARAMS_RE.match(t)
            if m:
                if m.group(1) is not None:
                    for idx, (part, off) in enumerate(split_top_spans(m.group(1))):
                        c = top_level_index(part, ':')
                        names = list(DECL_NAME_RE.finditer(part if c < 0 else part[:c]))
                        if names:
                            n = names[-1]
                            self._add(st, n.group(0), st.scope, m.start(1) + off + n.start(),
                                      part[c + 1:].strip() if c >= 0 else None, None, ('closure', idx))
                else:
                    for idx, (part, off) in enumerate(split_top_spans(m.group(2))):
                        n = DECL_NAME_RE.search(part)
                        if n:
                            self._add(st, n.group(0), st.scope, m.start(2) + off + n.start(), None, None, ('closure', idx))

    def type_and_bases(self, name):
        """name, then the types and protocols it inherits from or conforms to in this file, breadth first."""
        out = [name]
        k = 0
        while k < len(out) and len(out) < 16:
            for b in self.inherits.get(out[k], ()):
                if b not in out:
                    out.append(b)
            k += 1
        return out

    def resolve(self, f, name, ln, col, members_only=False):
        """The declaration a use of name at (ln, col) refers to, or None when no visible declaration is in this file."""
        decls = self.by_name.get(name)
        if not decls:
            return None
        for sc in f.scope_at(ln, col).chain():
            if sc.kind in ('type', 'extension'):
                for tn in self.type_and_bases(sc.name):
                    for dcl in decls:
                        if dcl.owner.kind in ('type', 'extension', 'protocol') and dcl.owner.name == tn:
                            return dcl
            elif members_only:
                continue
            elif sc.kind == 'file':
                for dcl in decls:
                    if dcl.owner is sc:
                        return dcl
            else:
                best = None
                for dcl in decls:
                    if dcl.owner is sc and dcl.pos < (ln, col):
                        best = dcl
                if best is not None:
                    return best
        return None

    def names_with(self, f, predicate):
        """The names with at least one declaration for which has_type holds."""
        return {n for n, ds in self.by_name.items() if any(self.has_type(f, d, predicate) for d in ds)}

    def has_type(self, f, dcl, predicate, depth=0):
        """Whether predicate holds for dcl, or for the declaration of the plain name it is initialised from
        (`let x = y`, `if let x = y`, `if let y`), followed at most 3 times."""
        if dcl is None:
            return False
        if predicate(dcl):
            return True
        if dcl.type or not dcl.init or depth >= 3:
            return False
        m = re.fullmatch(r'(self\s*\.\s*)?([A-Za-z_]\w*)', dcl.init)
        if not m:
            return False
        return self.has_type(f, self.resolve(f, m.group(2), dcl.pos[0], dcl.pos[1], members_only=bool(m.group(1))),
                             predicate, depth + 1)


def type_is_dictionary(dcl):
    """Whether a declaration has a Dictionary or Set type (annotation or initialiser)."""
    t = dcl.type
    if t:
        t = re.sub(r'^(?:inout|borrowing|consuming|sending|__owned|__shared)\s+', '', t).strip()
        if re.match(r'(?:Swift\s*\.\s*)?(?:Dictionary|Set)\s*<', t):
            return True
        if t.startswith('['):
            e = matching(t, 0, '[', ']')
            return top_level_has(t[1:e], ':')
        return False
    i = dcl.init
    if i:
        if re.match(r'(?:Swift\s*\.\s*)?(?:Dictionary|Set)\s*[<(]|\[\s*:\s*\]', i):
            return True
        if i.startswith('['):
            e = matching(i, 0, '[', ']')
            return top_level_has(i[1:e], ':')
    return False


ITER_METHODS = (r'forEach|map|compactMap|flatMap|reduce|sorted|first|enumerated|lazy|makeIterator|randomElement|popFirst|'
                r'joined|prefix|suffix|dropFirst|dropLast|elementsEqual|reversed|shuffled|indices|description|'
                r'debugDescription|withContiguousStorageIfAvailable|min\(by|max\(by')


def decl_index(ctx, f):
    return ctx.cached(('decls', f.rel), lambda: DeclIndex(f))


@rule('L-DET-1', 'iterating a Swift `Dictionary`/`Set` (`for … in dict`, iterating `.keys`/`.values`, `.map`/`forEach`/… on '
      'them; heuristic: a name whose visible declaration in the same file has a Dictionary/Set type)',
      '`LookupMap` (no iteration), `OrderedSet`, WTF emulation', 'module')
def check_det1(ctx, f):
    if not f.is_module:
        return
    kv = re.compile(r'(?:^|[{;])\s*for\s+[^{]*?\s+in\s+[\w.()\[\]]*\.(?:keys|values)\b(?!\s*[\[(])|'
                    r'\.(?:keys|values)\s*\.\s*(?:' + ITER_METHODS + r')\b|'
                    r'\b(?:Array|ContiguousArray|Set)\s*\(\s*[\w.]*\.(?:keys|values)\s*\)|'
                    r'contentsOf\s*:\s*[\w.]*\.(?:keys|values)\b')
    for ln, m in regex_lines(f, kv):
        yield ln, m.group(0).strip()
    for ln, m in regex_lines(f, re.compile(r'(?:^|[{;])\s*for\s+[^{]*?\s+in\s+(?:Set|Dictionary)\s*[<(]')):
        yield ln, 'for-in over a Set/Dictionary'
    index = decl_index(ctx, f)
    names = dictionary_names(f) | index.names_with(f, type_is_dictionary)
    if not names:
        return
    alt = '|'.join(sorted(map(re.escape, names)))
    rx = re.compile(r'(?:(?:^|[{;])\s*for\s+[^{]*?\s+in\s+(?P<s1>self\.)?(?P<n1>' + alt + r')\b(?!\s*[.\[(])|'
                    r'(?<![\w.])(?P<s2>self\.)?(?P<n2>' + alt + r')\s*\.\s*(?:' + ITER_METHODS + r')\b|'
                    r'\bArray\s*\(\s*(?P<s3>self\.)?(?P<n3>' + alt + r')\s*\))')
    for ln, m in regex_lines(f, rx):
        k = next(i for i in (1, 2, 3) if m.group('n%d' % i))
        dcl = index.resolve(f, m.group('n%d' % k), ln, m.start('n%d' % k), members_only=bool(m.group('s%d' % k)))
        if index.has_type(f, dcl, type_is_dictionary):
            yield ln, m.group(0).strip()


@rule('L-DET-2', '`String` used for identifier equality/hashing/keys; `Character`; `.count` on `String`',
      '`Symbol`, `Name`, code units', 'module')
def check_det2(ctx, f):
    if not f.is_module:
        return
    rx = re.compile(r'\bCharacter\b|\[\s*(?:Swift\.)?String\s*:|'
                    r'\b(?:Dictionary|LookupMap|OrderedDictionary)\s*<\s*(?:Swift\.)?String\s*,|'
                    r'\b(?:Set|LookupSet|OrderedSet)\s*<\s*(?:Swift\.)?String\s*>|'
                    r'(?:==|!=)\s*#*"|"#*\s*(?:==|!=)|^\s*case\s+#*"|"#*\s*\.\s*count\b')
    for ln, m in regex_lines(f, rx):
        yield ln, m.group(0).strip()
    tn = TypedNames(f, r'(?:Swift\.)?String')
    names = tn.names()
    if names:
        alt = '|'.join(sorted(map(re.escape, names)))
        rx2 = re.compile(r'(?<![\w.])(?:self\.)?(' + alt + r')\s*\.\s*count\b')
        for ln, m in regex_lines(f, rx2):
            if tn.is_typed(m.group(1), ln, m.start(1)):
                yield ln, m.group(0).strip()


MSL1_ALLOWED = ('Metal/MTLWorkarounds.swift', 'Metal/MSLWriter.swift')


@rule('L-MSL-1', '`[` inside `MSLText` literals outside `BoundsCheck.swift`, `Metal/MTLWorkarounds.swift`, '
      '`Metal/MSLWriter.swift` (literals of `wgslFatal`/`assert` lines are not MSL)',
      '`emitSubscript`, `MSLAttribute`, `appendArrayExtent`, `MSLHelperText`', '`Metal/`')
def check_msl1(ctx, f):
    if not f.is_module or not f.mrel.startswith('Metal/') or f.mrel in MSL1_ALLOWED:
        return
    for lit in f.literals:
        if '[' not in lit.text:
            continue
        if re.search(r'\b(?:wgslFatal|assert|assertionFailure)\s*\(', f.code[lit.line]):
            continue
        yield lit.line, '"' + lit.text.replace('\x01', '\\(…)')[:60] + '"'


INT_TYPE_NAMES = r'(?:U?Int(?:8|16|32|64|128)?)'
FLOAT_TYPE_NAMES = r'(?:Float(?:16|32|64|80)?|Double|Half|CGFloat)'
INT_TYPE_RE = re.compile(INT_TYPE_NAMES + r'|BinaryInteger|FixedWidthInteger|SignedInteger|UnsignedInteger')
FLOAT_TYPE_RE = re.compile(FLOAT_TYPE_NAMES + r'|BinaryFloatingPoint|FloatingPoint')
NUM_PROTOCOL_RE = re.compile(r'Numeric|SignedNumeric|AdditiveArithmetic|Strideable')
NUMERIC_LITERAL_RE = re.compile(r'-?(?:0[xob][0-9a-fA-F_.pP+-]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][-+]?\d+)?)')
FLOAT_LITERAL_RE = re.compile(r'(?<![\w.])\d[\d_]*(?:\.\d[\d_]*(?:[eE][-+]?\d+)?|[eE][-+]?\d+)\b|\b0x[0-9a-fA-F_]*(?:\.[0-9a-fA-F_]*)?[pP]')
# Properties of the standard library's numeric types and collections that are themselves numbers.
NUMERIC_MEMBERS = ('count', 'magnitude', 'bitPattern', 'bitWidth', 'nonzeroBitCount', 'leadingZeroBitCount',
                   'trailingZeroBitCount', 'exponent', 'significand', 'ulp', 'byteSwapped', 'littleEndian', 'bigEndian',
                   'exponentBitPattern', 'significandBitPattern', 'significandWidth', 'startIndex', 'endIndex',
                   'utf8CodeUnitCount', 'underestimatedCount', 'capacity')
FLOAT_SAME_MEMBERS = ('magnitude', 'significand', 'ulp', 'nextUp', 'nextDown', 'squareRoot', 'rounded')
FLOATISH_WORDS = ('float', 'floating', 'double', 'half')
TYPE_PREFIX_RE = re.compile(r'(?:(?:inout|borrowing|consuming|sending|__owned|__shared|some|any|isolated)\s+|'
                            r'@\w+(?:\([^()]*\))?\s+|Swift\s*\.\s*)')
STRING_TYPES = ('String', 'Substring', 'StaticString')
CODE_UNIT_VIEWS = {'utf8': 'String.UTF8View', 'utf16': 'String.UTF16View', 'unicodeScalars': 'String.UnicodeScalarView'}
VIEW_ELEMENTS = {'String.UTF8View': 'UInt8', 'String.UTF16View': 'UInt16', 'String.UnicodeScalarView': 'Unicode.Scalar',
                 'String': 'Character', 'Substring': 'Character'}
ELEMENT_METHODS = ('map', 'compactMap', 'flatMap', 'forEach', 'filter', 'first', 'last', 'contains', 'allSatisfy',
                   'firstIndex', 'lastIndex', 'drop', 'prefix', 'removeAll', 'sorted', 'sort', 'min', 'max', 'partition',
                   'count', 'lazy')
CONTROL_BLOCK_HEADS = ('if', 'else', 'for', 'while', 'guard', 'switch', 'do', 'repeat', 'catch', 'defer', 'case')


def identifier_words(ident):
    """The lower-cased camelCase / snake_case components of an identifier."""
    return [w.lower() for w in re.findall(r'[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+', ident)]


def floatish_name(text):
    """Whether an identifier in text has a float/floating/double/half component (`halfWidth`, `floatValue`,
    `Float(`, `value.doubleValue`), or text has a floating-point literal."""
    if FLOAT_LITERAL_RE.search(text):
        return True
    return any(w in FLOATISH_WORDS for ident in re.findall(r'[A-Za-z_]\w*', text) for w in identifier_words(ident))


def normalize_type(t):
    """A type without ownership modifiers, `some`/`any`, attributes, `Swift.`, enclosing parentheses, trailing `?`/`!`
    or `Optional<…>`."""
    if t is None:
        return None
    t = t.strip()
    for _ in range(8):
        prev = t
        m = TYPE_PREFIX_RE.match(t)
        if m:
            t = t[m.end():].strip()
        t = t.rstrip('?!').strip()
        m = re.fullmatch(r'Optional\s*<(.*)>', t, re.S)
        if m:
            t = m.group(1).strip()
        if t.startswith('(') and matching(t, 0, '(', ')') == len(t) - 1 and not top_level_has(t[1:-1], ','):
            t = t[1:-1].strip()
        if t == prev:
            break
    return t


def generic_args(t):
    """(base name, [argument texts]) of `Name<A, B>`, or (t, [])."""
    m = re.fullmatch(r'([\w.]+)\s*<(.*)>', t, re.S)
    if not m:
        return t, []
    return m.group(1), [a.strip() for a in split_top(m.group(2))]


def elem_type(t, key_value=None):
    """The element type of a sequence type ([T], Name<T>, the code-unit views); for a dictionary, its key (0) or value (1)
    when key_value says which, else None."""
    t = normalize_type(t)
    if not t:
        return None
    if t in VIEW_ELEMENTS:
        return VIEW_ELEMENTS[t]
    if t.startswith('[') and matching(t, 0, '[', ']') == len(t) - 1:
        inner = t[1:-1]
        if top_level_has(inner, ':'):
            if key_value is None:
                return None
            c = top_level_index(inner, ':')
            return (inner[:c] if key_value == 0 else inner[c + 1:]).strip()
        return inner.strip()
    base, args = generic_args(t)
    if len(args) == 1:
        return args[0]
    if len(args) == 2 and base.split('.')[-1] in ('Dictionary', 'LookupMap', 'OrderedDictionary', 'HashMap') and \
            key_value is not None:
        return args[key_value]
    return None


def subscript_type(t):
    """The type of t[…]: a dictionary's value, else the element."""
    v = elem_type(t, 1)
    return v if v is not None and (normalize_type(t) or '').split('<')[0].strip() not in ('Set',) else elem_type(t)


def matching_back(s, i):
    """Index of the bracket opening s[i] (one of `)]}`), or -1."""
    close = s[i]
    open_ch = {')': '(', ']': '[', '}': '{'}[close]
    depth = 0
    for j in range(i, -1, -1):
        if s[j] == close:
            depth += 1
        elif s[j] == open_ch:
            depth -= 1
            if depth == 0:
                return j
    return -1


VALUE_END = re.compile(r'[\w$)\]"#?!]')


def trailing_expr(s, end):
    """Start offset of the postfix expression (a primary with `.member`s, calls, subscripts and `?`/`!`, across line
    breaks) that ends at s[end], or end when there is none."""
    j = end
    while True:
        k = j
        while k > 0 and s[k - 1] in ' \t\n':
            k -= 1
        while k > 0 and s[k - 1] in '?!' and k > 1 and VALUE_END.match(s[k - 2]):
            k -= 1
        if k == 0:
            return k
        c = s[k - 1]
        if c in ')]':
            o = matching_back(s, k - 1)
            if o < 0:
                return k
            p = o
            while p > 0 and s[p - 1] in ' \t':
                p -= 1
            if p > 0 and VALUE_END.match(s[p - 1]) and not re.search(r'\b(?:return|in|throw|try|await|case|let|var)$', s[:p]):
                j = p
                continue
            return o
        if c == '"' or (c == '#' and '"' in s[:k]):
            q = s.rfind('"', 0, k - 1 if c == '"' else s.rfind('"', 0, k))
            while q > 0 and s[q - 1] in '"#':
                q -= 1
            return max(q, 0)
        m = re.search(r'(?:\$\d+|(?<![\w$])[A-Za-z_]\w*|(?<![\w$])\d[\d_]*)$', s[:k])
        if not m:
            return end if k == end else k
        q = m.start()
        r = q
        while r > 0 and s[r - 1] in ' \t\n':
            r -= 1
        if r > 0 and s[r - 1] == '.' and not (r > 1 and s[r - 2] == '.'):
            b = r - 1
            while b > 0 and s[b - 1] in ' \t\n':
                b -= 1
            if b > 0 and VALUE_END.match(s[b - 1]) and not re.search(r'\b(?:return|in|throw|try|await|case)$', s[:b]):
                j = b
                continue
            return r - 1
        return q


class ModuleIndex:
    """The module-wide part of the L-MSL-2 type inference: functions, members, file-level declarations, enum cases,
    typealiases and inheritance of every module file."""

    def __init__(self, ctx):
        self.funcs = {}
        self.members = {}
        self.globals = {}
        self.cases = {}
        self.aliases = {}
        self.inherits = {}
        for f in ctx.module_files():
            idx = decl_index(ctx, f)
            for name, owner, ret in idx.funcs:
                self.funcs.setdefault(name, []).append((owner, ret, f))
            for name, ds in idx.by_name.items():
                for dcl in ds:
                    if dcl.owner.kind in ('type', 'extension', 'protocol'):
                        self.members.setdefault(name, []).append((f, dcl))
                    elif dcl.owner.kind == 'file':
                        self.globals.setdefault(name, []).append((f, dcl))
            for name, enum, payload in idx.enum_cases:
                self.cases.setdefault(name, []).append((enum, payload, f))
            self.aliases.update(idx.aliases)
            for tn, bases in idx.inherits.items():
                self.inherits.setdefault(tn, []).extend(bases)

    def type_and_bases(self, name):
        out = [name]
        k = 0
        while k < len(out) and len(out) < 16:
            for b in self.inherits.get(out[k], ()):
                if b not in out:
                    out.append(b)
            k += 1
        return out


class Typer:
    """A best-effort inference of the type of an expression, for L-MSL-2: from annotations, initialisers, for-in
    sequences, enum case payloads, closure receivers, function return types and members declared in the module.
    None means unknown."""

    def __init__(self, ctx):
        self.ctx = ctx
        self.module = ctx.cached('module-index', lambda: ModuleIndex(ctx))
        self.memo = {}

    def type_class(self, f, t, depth=0):
        """'float', 'int', 'num' (numeric, maybe floating), 'other', or None (unknown)."""
        t = normalize_type(t)
        if not t or depth > 4:
            return None
        if FLOAT_TYPE_RE.fullmatch(t):
            return 'float'
        if INT_TYPE_RE.fullmatch(t):
            return 'int'
        if NUM_PROTOCOL_RE.fullmatch(t):
            return 'num'
        if f is not None:
            g = decl_index(self.ctx, f).generics
            if t in g:
                classes = {self.type_class(None, c, depth + 1) for c in re.split(r'[&,]', g[t])}
                return next((c for c in ('float', 'int', 'num') if c in classes), None)
        if t in self.module.aliases:
            return self.type_class(f, self.module.aliases[t], depth + 1)
        if re.fullmatch(r'[A-Z]', t) or t in ('Element', 'T', 'Value', 'Key'):
            return None
        return 'other'

    def is_numeric(self, f, t):
        return self.type_class(f, t) in ('float', 'int', 'num')

    def consistent(self, f, candidates):
        """One type standing for the (file, type) candidates of a name: those declared in f when there are any, then a
        numeric one when any is numeric, else the first when all are known."""
        local = [t for g, t in candidates if g is f]
        types = local or [t for _, t in candidates]
        if not types:
            return None
        classes = [self.type_class(f, t) for t in types]
        for c in ('float', 'num', 'int'):
            if c in classes:
                return types[classes.index(c)]
        if None in classes:
            return None
        return types[0]

    def switch_subject_enum(self, f, scope, depth):
        """The type of the subject of the `switch` whose body is scope, or None."""
        header = decl_index(self.ctx, f).headers.get(id(scope)) if scope is not None else None
        if header is None:
            return None
        m = re.match(r'\s*switch\b', header.text)
        if not m:
            return None
        ln, col = header.pos_of(m.end())
        return self.expr_type(f, header.text[m.end():], ln, col, depth + 1)

    def decl_type(self, f, dcl, depth=0):
        key = id(dcl)
        if key in self.memo:
            return self.memo[key]
        self.memo[key] = None
        t = self._decl_type(f, dcl, depth) if depth <= 8 else None
        self.memo[key] = t
        return t

    def _decl_type(self, f, dcl, depth):
        if dcl.type:
            return dcl.type
        src = dcl.src
        if src is not None:
            if src[0] == 'elem':
                _, seq, idx, (ln, col) = src
                if idx is None:
                    return elem_type(self.expr_type(f, seq, ln, col, depth + 1))
                m = re.fullmatch(r'(.*?)\s*\.\s*enumerated\s*\(\s*\)', seq, re.S)
                if m:
                    return 'Int' if idx == 0 else elem_type(self.expr_type(f, m.group(1), ln, col, depth + 1))
                if idx in (0, 1):
                    return elem_type(self.expr_type(f, seq, ln, col, depth + 1), idx)
                return None
            if src[0] == 'payload':
                _, name, idx, qual, subject = src
                cases = [(enum, p, g) for enum, p, g in self.module.cases.get(name, ()) if idx < len(p)]
                if qual is None or not qual[0].isupper():
                    if subject is not None:
                        qual = self.expr_type(f, subject, dcl.pos[0], dcl.pos[1], depth + 1)
                    else:
                        qual = self.switch_subject_enum(f, dcl.owner, depth)
                    qual = generic_args(normalize_type(qual))[0].split('.')[-1] if qual else None
                if qual and any(enum == qual for enum, _, _ in cases):
                    cases = [c for c in cases if c[0] == qual]
                return self.consistent(f, [(g, p[idx]) for _, p, g in cases])
            if src[0] == 'closure':
                return self.closure_param(f, dcl.owner, src[1], depth + 1)
        if dcl.init:
            return self.expr_type(f, dcl.init, dcl.pos[0], dcl.pos[1], depth + 1)
        return None

    def closure_param(self, f, scope, idx, depth):
        """The type of parameter idx of the closure that is scope, when the closure is the argument of an
        element-passing method (`xs.map {`, `xs.first(where: {`) of a sequence of known type."""
        if depth > 8 or scope is None or scope.kind != 'block':
            return None
        header = decl_index(self.ctx, f).headers.get(id(scope))
        if header is None:
            return None
        text = header.text.rstrip()
        m = re.search(r'\.\s*(' + '|'.join(ELEMENT_METHODS) + r')\s*(?:\(\s*(?:(?:where|by|while)\s*:\s*)?)?$', text)
        if not m or (idx > 0 and m.group(1) not in ('sorted', 'sort', 'min', 'max')):
            return None
        start = trailing_expr(text, m.start())
        if start >= m.start():
            return None
        ln, col = header.pos_of(start)
        base = text[start:m.start()].rstrip()
        t = self.expr_type(f, base, ln, col, depth + 1)
        if m.group(1) in ('map', 'flatMap') and (base.endswith('?') or (t or '').rstrip().endswith('?') or
                                                 re.match(r'\s*Optional\s*<', t or '')):
            return normalize_type(t)  # Optional.map passes the wrapped value
        return elem_type(t)

    def enclosing_closure_param(self, f, n, ln, col, depth):
        for sc in f.scope_at(ln, col).chain():
            if sc.kind != 'block':
                return None
            header = decl_index(self.ctx, f).headers.get(id(sc))
            word = re.match(r'\s*(\w*)', parse_decl(header.text).rest if header else '').group(1)
            if word in CONTROL_BLOCK_HEADS:
                continue
            return self.closure_param(f, sc, n, depth)
        return None

    def enclosing_type(self, f, ln, col):
        for sc in f.scope_at(ln, col).chain():
            if sc.kind in ('type', 'extension', 'protocol'):
                return sc.name
        return None

    def member_type(self, f, base, name, depth):
        """The type of base.name, base being a type (or None when unknown)."""
        if depth > 8:
            return None
        cls = self.type_class(f, base) if base else None
        nb = normalize_type(base) if base else None
        if cls in ('float', 'int', 'num'):
            if name.startswith('is'):
                return 'Bool'
            if name in ('description', 'debugDescription'):
                return 'String'
            if name in NUMERIC_MEMBERS and name not in FLOAT_SAME_MEMBERS:
                return 'Int'
            return base
        if name in NUMERIC_MEMBERS:
            return 'Int'
        if nb in STRING_TYPES or nb in VIEW_ELEMENTS:
            if name in CODE_UNIT_VIEWS:
                return CODE_UNIT_VIEWS[name]
            if name in ('description', 'debugDescription'):
                return 'String'
        if nb and name in ('first', 'last') and elem_type(nb) is not None:
            return elem_type(nb)
        owner = generic_args(nb)[0].split('.')[-1] if nb else None
        decls = self.module.members.get(name, ())
        cases = self.module.cases.get(name, ())
        if owner:
            for tn in self.module.type_and_bases(owner):
                found = [(g, self.decl_type(g, d, depth + 1)) for g, d in decls if d.owner.name == tn]
                if found:
                    return self.consistent(f, found)
                if any(enum == tn for enum, _, _ in cases):
                    return tn
        found = [(g, self.decl_type(g, d, depth + 1)) for g, d in decls]
        found += [(g, enum) for enum, _, g in cases]
        return self.consistent(f, found)

    def call_type(self, f, callee, args, ln, col, depth):
        callee = callee.rstrip()
        if callee.endswith('>'):
            o = callee.rfind('<')
            if o > 0:
                callee = callee[:o].rstrip()
        m = re.search(r'([A-Za-z_]\w*)$', callee)
        if not m:
            return None
        name = m.group(1)
        before = callee[:m.start()].rstrip()
        is_member = before.endswith('.') and not before.endswith('..')
        base = before[:-1].rstrip() if is_member else ''
        if name == 'init' and base:
            return self.expr_type(f, base, ln, col, depth + 1)
        if name[0].isupper():
            return name
        if not is_member and name in ('min', 'max', 'abs'):
            first = split_top(args)[0] if args.strip() else ''
            return self.expr_type(f, first, ln, col, depth + 1) if first else None
        bt = self.expr_type(f, base, ln, col, depth + 1) if base else None
        if bt is not None:
            cls = self.type_class(f, bt)
            if cls in ('float', 'int', 'num') and \
                    name in FLOAT_SAME_MEMBERS + ('advanced', 'negate', 'addingProduct', 'remainder', 'truncatingRemainder'):
                return bt
            if name.startswith(('is', 'contains', 'starts', 'ends', 'elementsEqual')):
                return 'Bool'
            if normalize_type(bt) in STRING_TYPES and name in ('lowercased', 'uppercased'):
                return 'String'
        entries = self.module.funcs.get(name, ())
        if is_member and not base:
            cases = self.module.cases.get(name, ())
            if cases:
                return self.consistent(f, [(g, enum) for enum, _, g in cases])
        if bt is not None:
            owner = generic_args(normalize_type(bt))[0].split('.')[-1]
            cases = [(g, enum) for enum, _, g in self.module.cases.get(name, ()) if enum == owner]
            if cases:
                return owner
            for tn in self.module.type_and_bases(owner):
                own = [(g, r) for o, r, g in entries if o == tn]
                if own:
                    return self.consistent(f, own)
        elif not is_member:
            free = [(g, r) for o, r, g in entries if o is None]
            enclosing = self.enclosing_type(f, ln, col)
            own = [(g, r) for o, r, g in entries if enclosing and o == enclosing]
            if own or free:
                return self.consistent(f, own or free)
        return self.consistent(f, [(g, r) for _, r, g in entries])

    def expr_type(self, f, s, ln, col, depth=0):
        """The type of the expression text s (masked code) used at (ln, col), or None."""
        if depth > 10 or s is None:
            return None
        s = s.strip()
        while True:
            m = re.match(r'(?:try[?!]?|await|consume|copy|&)\s*', s)
            if not m or not m.group(0):
                break
            s = s[m.end():]
        if not s:
            return None
        depths = bracket_depths(s)

        def top(rx):
            for mm in re.finditer(rx, s):
                if depths[mm.start()] == 0:
                    return mm
            return None

        m = top(r'\s+as[?!]?\s+')
        if m:
            return s[m.end():].strip()
        m = top(r'\s\?\s')
        if m:
            c = top(r'\s:\s')
            return self.expr_type(f, s[m.end():c.start()] if c else s[m.end():], ln, col, depth + 1)
        m = top(r'\s\?\?\s')
        if m:
            return self.expr_type(f, s[:m.start()], ln, col, depth + 1) or \
                self.expr_type(f, s[m.end():], ln, col, depth + 1)
        if top(r'\s(?:==|!=|<=|>=|<|>|&&|\|\||===|!==)\s'):
            return 'Bool'
        m = top(r'\.\.[.<]')
        if m:
            lo = s[:m.start()].strip()
            lt = self.expr_type(f, lo, ln, col, depth + 1) if lo else \
                self.expr_type(f, s[m.end():], ln, col, depth + 1)
            return 'Range<%s>' % lt if lt else None
        m = top(r'\s(?:&?[-+*/%]|<<|>>|&|\||\^)\s')
        if m:
            parts = [s[:m.start()], s[m.end():]]
            types = [self.expr_type(f, p, ln, col, depth + 1) for p in parts]
            return next((t for t in types if self.type_class(f, t) == 'float'), None) or \
                next((t for t in types if t is not None), None)
        if s[0] == '!' and len(s) > 1 and s[1] not in ' =':
            return 'Bool'
        if s[0] in '-+~' and len(s) > 1 and s[1] not in ' =':
            return self.expr_type(f, s[1:], ln, col, depth + 1)
        if NUMERIC_LITERAL_RE.fullmatch(s):
            return 'Double' if re.fullmatch(r'-?' + FLOAT_LITERAL_RE.pattern, s) else 'Int'
        s = s.rstrip()
        while s and s[-1] in '?!' and len(s) > 1 and VALUE_END.match(s[-2]):
            s = s[:-1].rstrip()
        if not s:
            return None
        c = s[-1]
        if c == '"' or (c == '#' and '"' in s):
            return 'String'
        if c in ')]':
            o = matching_back(s, len(s) - 1)
            if o < 0:
                return None
            head = s[:o].rstrip()
            inner = s[o + 1:-1]
            if not head or not VALUE_END.match(head[-1]):
                if c == ']':
                    return None
                return None if top_level_has(inner, ',') else self.expr_type(f, inner, ln, col, depth + 1)
            if c == ']':
                bt = self.expr_type(f, head, ln, col, depth + 1)
                st = subscript_type(bt) if bt else None
                if st is None and bt:
                    st = self.consistent(f, [(g, r) for o2, r, g in self.module.funcs.get('subscript', ())
                                             if o2 == generic_args(normalize_type(bt))[0].split('.')[-1]])
                return st
            return self.call_type(f, head, inner, ln, col, depth)
        m = re.search(r'(\$\d+|(?<![\w$])[A-Za-z_]\w*|(?<![\w$])\d+)$', s)
        if not m:
            return None
        word = m.group(1)
        before = s[:m.start()].rstrip()
        if before.endswith('.') and not before.endswith('..'):
            base = before[:-1].rstrip()
            if word.isdigit():
                return None
            if not base or not VALUE_END.match(base[-1]):
                cases = self.module.cases.get(word, ())
                return self.consistent(f, [(g, enum) for enum, _, g in cases])
            if base == 'self':
                bt = self.enclosing_type(f, ln, col)
            elif base == 'Self':
                bt = self.enclosing_type(f, ln, col)
            else:
                bt = self.expr_type(f, base, ln, col, depth + 1)
            return self.member_type(f, bt, word, depth + 1)
        if word[0] == '$':
            return self.enclosing_closure_param(f, int(word[1:]), ln, col, depth + 1)
        if word.isdigit():
            return 'Int'
        if word in ('self', 'Self'):
            return self.enclosing_type(f, ln, col)
        if word in ('true', 'false'):
            return 'Bool'
        if word == 'nil':
            return None
        index = decl_index(self.ctx, f)
        dcl = index.resolve(f, word, ln, col)
        if dcl is not None:
            return self.decl_type(f, dcl, depth + 1)
        found = [(g, self.decl_type(g, d, depth + 1)) for g, d in self.module.globals.get(word, ())]
        if found:
            return self.consistent(f, found)
        if word[0].isupper():
            return word  # a type, as the base of a static member or an initialiser
        return None


def typer(ctx):
    return ctx.cached('typer', lambda: Typer(ctx))


MSL2_DESCRIPTION_ALLOWED = ('Support/MessageText.swift', 'Support/ByteSink.swift', 'Metal/MSLWriter.swift')
DESCRIPTION_RE = re.compile(r'\.\s*(?:description|debugDescription)\b(?!\s*\()')


@rule('L-MSL-2', '`String(describing:)`/`(reflecting:)`, `.description`/`.debugDescription` on a receiver not known to be '
      'non-numeric, `"\\(x)"` for floating values, `print`, `debugPrint`, `dump` (heuristic)',
      'the WTF formatters (`MessageText` `\\(number:)`, `MSLNumber`)', 'module')
def check_msl2(ctx, f):
    if not f.is_module:
        return
    rx = re.compile(r'\bString\s*\(\s*(?:describing|reflecting)\s*:|(?<![\w.])(?:print|debugPrint|dump)\s*\(')
    for ln, m in regex_lines(f, rx):
        if re.search(r'\bfunc\s+$', f.code[ln][:m.start()]):
            continue
        yield ln, m.group(0)
    ty = typer(ctx)
    if f.mrel not in MSL2_DESCRIPTION_ALLOWED:
        for st in f.stmts:
            for m in DESCRIPTION_RE.finditer(st.text):
                text = st.text
                dot = m.start()
                word = m.group(0).lstrip('. \t\n')
                ln = st.line_of(dot)
                if text[:dot].rstrip().endswith('\\'):
                    k = re.search(r'\.\s*(?:' + '|'.join(ELEMENT_METHODS) + r')\s*\(\s*\\\s*$', text[:dot])
                    start = trailing_expr(text, k.start()) if k else dot
                    t = elem_type(ty.expr_type(f, text[start:k.start()], *st.pos_of(start))) if k and start < k.start() \
                        else None
                    recv = '\\'
                else:
                    start = trailing_expr(text, dot)
                    recv = text[start:dot].strip()
                    if not recv:
                        continue  # an implicit member `.description` or a declaration
                    t = ty.expr_type(f, recv, *st.pos_of(start))
                cls = ty.type_class(f, t)
                units = re.match(r'\s*\.\s*(?:utf8|utf16|unicodeScalars|utf8CString)\b', text[m.end():])
                if cls in ('float', 'int', 'num') or (cls is None and not units):
                    label = ' '.join(recv.replace('\x00', '').split())
                    yield ln, '%s.%s (%s)' % (label[-40:], word, 'a %s receiver' % normalize_type(t) if cls else
                                              'a receiver of unknown type')
    if f.mrel == 'WGSLFatal.swift':
        return
    for lit in f.literals:
        for expr, off in zip(lit.interps, lit.offsets):
            if re.match(r'\s*number\s*:', expr):
                continue
            e = expr.strip()
            lead = len(expr) - len(expr.lstrip())
            ln, col = f.pos_at(off + lead)
            flag = floatish_name(e)
            if not flag and not re.match(r'\s*[A-Za-z_]\w*\s*:(?!:)', expr):
                code = f.code_at(off + lead, len(e))
                if not top_level_has(code, ','):
                    flag = ty.type_class(f, ty.expr_type(f, code, ln, col)) == 'float'
            if flag:
                yield ln, '\\(' + ' '.join(e.split()) + ')'


def reserved_spellings(ctx):
    """The `__…` identifiers spelled inside `enum ReservedName` and its extensions, or None before it exists.

    A word an interpolation completes (`"__\\(name)_ArrayLength"`, `"__i\\(depth)"`) is a parameterised case's prefix, not
    a spelling: it does not let `"__\\(text)"` through elsewhere."""
    found = None
    for f in ctx.module_files():
        for sc in iter_scopes(f):
            if sc.kind in ('type', 'extension') and sc.name == 'ReservedName' and sc.end_line is not None:
                if found is None:
                    found = set()
                for lit in f.literals:
                    if sc.line <= lit.line <= sc.end_line:
                        m = re.match(r'__\w*', lit.text)
                        if m and not lit.text.startswith('\x01', m.end()):
                            found.add(m.group(0))
    return found


@rule('L-MSL-3', 'a `"__…"` spelling not in `ReservedName` (inert until `enum ReservedName` exists)',
      'add a `ReservedName` case (IR-maintenance); SymbolTableTests checks the cases', 'module')
def check_msl3(ctx, f):
    if not f.is_module:
        return
    spellings = ctx.cached('reserved', lambda: reserved_spellings(ctx))
    if spellings is None:
        return
    ranges = [(sc.line, sc.end_line) for sc in iter_scopes(f)
              if sc.kind in ('type', 'extension') and sc.name == 'ReservedName' and sc.end_line is not None]
    for lit in f.literals:
        m = re.match(r'__\w*', lit.text)
        if not m or any(a <= lit.line <= b for a, b in ranges):
            continue
        if m.group(0) not in spellings:
            yield lit.line, '"' + m.group(0) + '"'


# The literal-only text types (`ByteLiteral`, `MSLText`) are String-literal-backed, so an explicit literal
# initialiser or an unapplied `.init` reference would let runtime text reach a sink; `ByteSink.sinkBytes` is the sink's
# storage, written only by Support/ByteSink.swift.
MSL4_RE = re.compile(r'(?:\b[A-Z]\w*\s*(?:\.\s*init\s*)?|\.\s*init\s*)\('
                     r'\s*(?:stringLiteral|extendedGraphemeClusterLiteral|unicodeScalarLiteral)\s*:'
                     r'|\b(?:ByteLiteral|MSLText)\s*\.\s*init\b(?!\s*\()')
MSL4_SINK_FILE = 'Support/ByteSink.swift'


@rule('L-MSL-4', 'an explicit `init(stringLiteral:)` (or `extendedGraphemeClusterLiteral:`/`unicodeScalarLiteral:`) '
      'call on any type, an unapplied `ByteLiteral.init`/`MSLText.init`, `sinkBytes` outside `%s`' % MSL4_SINK_FILE,
      'a literal; the `ByteSink` appends', 'module')
def check_msl4(ctx, f):
    if not f.is_module:
        return
    for ln, m in regex_lines(f, MSL4_RE):
        yield ln, m.group(0)
    if f.mrel != MSL4_SINK_FILE:
        for ln, m in regex_lines(f, re.compile(r'\bsinkBytes\b')):
            yield ln, m.group(0)


CE1_FILES = ('ConstantFunctions*.swift', 'Support/ConstEvalArithmetic.swift', 'Support/ByteSize.swift', 'Types.swift',
             'AttributeValidator.swift', 'Evaluate.swift')


@rule('L-CE-1', '`Swift.min`/`Swift.max`, two-argument `min(`/`max(`, `.minimum`/`.maximum`, `.clamped(to:)`',
      '`cxxMin`/`cxxMax`/`cxxClamp`/`constClamp`', ', '.join('`%s`' % p for p in CE1_FILES))
def check_ce1(ctx, f):
    if not f.is_module or not match_mrel(f, *CE1_FILES):
        return
    rx = re.compile(r'\bSwift\s*\.\s*(?:min|max)\s*\(|(?<![\w.])(min|max)\s*\(|\.\s*(?:minimum|maximum)\s*\(|'
                    r'\.\s*clamped\s*\(\s*to\s*:')
    for ln, m in regex_lines(f, rx):
        line = f.code[ln]
        if m.group(1):
            if re.search(r'\bfunc\s+$', line[:m.start()]):
                continue
            p = line.index('(', m.start())
            if len(split_top(call_args(f, ln, p))) < 2:
                continue
        yield ln, m.group(0)


@rule('L-CE-2', 'trapping `Int32(someFloat)`-style conversions', '`arm64ConvertTo*`, `Int32(exactly:)`, `truncatingIfNeeded`',
      'module')
def check_ce2(ctx, f):
    if not f.is_module:
        return
    tn = TypedNames(f, r'Float|Double|Half|Float80|CGFloat')
    rx = re.compile(r'(?<![\w.])(?:U?Int(?:8|16|32|64)?)\s*(?:\.\s*init\s*)?\(')
    for ln, m in regex_lines(f, rx):
        line = f.code[ln]
        p = m.end() - 1
        raw = call_args(f, ln, p)
        arg = raw.strip()
        if re.match(r'\w+\s*:', arg):
            continue
        floaty = re.search(r'\b(?:Float|Double|Half|Float80)\b|\.\s*(?:rounded|squareRoot|magnitude)\b|\d\.\d|\d[eE][-+]?\d', arg)
        if not floaty:
            n = re.fullmatch(r'(?:self\.)?(\w+)', arg)
            floaty = n and tn.is_typed(n.group(1), ln, p + 1 + raw.index(n.group(1)))
        if floaty:
            yield ln, m.group(0) + ' '.join(arg.split()) + ')'


@rule('L-CE-3', '`.remainder(dividingBy:)`', '`cxxFmod`', 'module')
def check_ce3(ctx, f):
    if f.is_module:
        for ln, m in regex_lines(f, re.compile(r'\.\s*(?:formRemainder|remainder)\s*\(\s*dividingBy\s*:')):
            yield ln, m.group(0)


@rule('L-CE-4', 'bare `.rounded()` / `.round()`', 'an explicit rounding rule', 'module')
def check_ce4(ctx, f):
    if f.is_module:
        for ln, m in regex_lines(f, re.compile(r'\.\s*(?:rounded|round)\s*\(\s*\)')):
            yield ln, m.group(0)


@rule('L-CE-5', '`abs(`', '`ConstInt.abs`, `.magnitude`', 'module')
def check_ce5(ctx, f):
    if not f.is_module:
        return
    for ln, m in regex_lines(f, re.compile(r'(?:\bSwift\s*\.\s*|(?<![\w.]))abs\s*\(')):
        if re.search(r'\bfunc\s+$', f.code[ln][:m.start()]):
            continue
        yield ln, m.group(0)


NUM_TYPES = r'(?:Float|Double|Float80|Half|CGFloat|U?Int(?:8|16|32|64|128)?|Decimal)'
TEXTISH = r'\w*(?:[tT]ext|[sS]tring|[sS]tr|[sS]ubstring|[sS]pelling|[tT]oken|[dD]igits|[lL]iteral|[sS]ource|[cC]haracters)'


@rule('L-CE-6', '`Float("…")`, `Double(text)`, `Int(text)`, `radix:` parsing and every other text→number initialiser '
      '(they call the OS\'s Swift runtime), C `strto*`/`ato*`', '`NumberParsing` (pure Swift, no stdlib text parsing even '
      'inside it)', 'module')
def check_ce6(ctx, f):
    if not f.is_module:
        return
    rx = re.compile(r'(?<![\w.])' + NUM_TYPES + r'\s*(?:\.\s*init\s*)?\(\s*(?:#*"|(?:String|Substring)\s*\(|'
                    r'(?:self\.)?' + TEXTISH + r'\s*[)!?,]|[^()]*\bradix\s*:)|'
                    r'(?<![\w.])(?:strto\w+|ato[fil]l?|sscanf|Scanner|NumberFormatter|LosslessStringConvertible)\b|'
                    r'\b' + NUM_TYPES + r'\s*\(\s*(?:self\.)?\w+\s*\.\s*(?:description|text)\s*\)')
    for ln, m in regex_lines(f, rx):
        yield ln, m.group(0).strip()
    tn = TypedNames(f, r'(?:Swift\.)?(?:String|Substring)')
    names = tn.names()
    if names:
        rx2 = re.compile(r'(?<![\w.])' + NUM_TYPES + r'\s*(?:\.\s*init\s*)?\(\s*(?:self\.)?(' +
                         '|'.join(sorted(map(re.escape, names))) + r')\s*[),]')
        for ln, m in regex_lines(f, rx2):
            if tn.is_typed(m.group(1), ln, m.start(1)):
                yield ln, m.group(0).strip()


CE7_FILES = ('ConstantFunctions*.swift', 'Evaluate.swift', 'Support/ConstEvalArithmetic.swift')
WRAP_FILES = ('GlobalVariableRewriter*.swift', 'EntryPointRewriter.swift', 'AttributeValidator.swift', 'TypeCheck*.swift',
              'BoundsCheck.swift', 'Metal/')
ARITH_SKIP_RE = re.compile(r'\b(?:Float|Double|Half|Float80)\b|&|\d\.\d|\b\d[\d_]*[eE][-+]?\d|0x[0-9a-fA-F_]*[pP]|'
                           r'\.(?:infinity|nan|signalingNaN|greatestFiniteMagnitude|leastNormalMagnitude|leastNonzeroMagnitude|'
                           r'pi|ulpOfOne)\b')
NEG_LITERAL_PREV = set('([{,:=?!<>+-*/%&|^~')
NEG_LITERAL_WORDS = ('return', 'case', 'in', 'throw', 'yield', 'else', 'where', 'is', 'as', 'try', 'await', 'then')


def integer_arith(line):
    """The first trapping integer `+ - *` (or compound assignment, or unary minus on a non-literal) on a masked
    code line that has no Float/Double/Half/`&`/float literal, or None."""
    if ARITH_SKIP_RE.search(line):
        return None
    s = line.replace('\x00', ' ')
    s = re.sub(r'->', '  ', s)
    s = re.sub(r'\b(?:infix|prefix|postfix)\s+operator\b.*', '', s)
    s = re.sub(r'\bfunc\s*[-+*]+', lambda m: ' ' * len(m.group(0)), s)
    s = re.sub(r'(?:\(\s*\*\s*\)|\*\s*(?=[,)])|(?<=[(,])\s*\*)', lambda m: ' ' * len(m.group(0)), s)
    for m in re.finditer(r'[-+*]=?', s):
        op = m.group(0)
        j = m.start()
        if op[0] == '-' and j + 1 < len(s) and s[j + 1] == '-':
            continue
        prev = s[:j].rstrip()
        nxt = s[m.end():]
        if op == '-' and nxt[:1].isdigit():
            word = re.search(r'(\w+)$', prev)
            if not prev or prev[-1] in NEG_LITERAL_PREV or (word and word.group(1) in NEG_LITERAL_WORDS):
                continue
        if op in ('+', '*') and not prev:
            continue
        return op
    return None


@rule('L-CE-7', 'a binary `+`, `-`, `*` (or `+=`, `-=`, `*=`) or unary `-` between integer operands in const-eval code '
      '(heuristic: a line without `Float`/`Double`/`Half`/`&`/float literal)', '`ConstInt`/`AbstractInt` helpers or '
      '`&+ &- &*` (C++ `-fwrapv`)', ', '.join('`%s`' % p for p in CE7_FILES))
def check_ce7(ctx, f):
    if not f.is_module or not match_mrel(f, *CE7_FILES):
        return
    for ln, line in enumerate(f.code):
        op = integer_arith(line)
        if op:
            yield ln, op


@rule('L-WRAP-1', 'the L-CE-7 line rule (integer `+`, `-`, `*`, including `+ 1` / `- 1`) outside const-eval',
      '`&+ &- &*`, or `// lint-exempt(L-WRAP-1): bounded by <container/count>`', ', '.join('`%s`' % p for p in WRAP_FILES))
def check_wrap(ctx, f):
    if not f.is_module or not match_mrel(f, *WRAP_FILES):
        return
    for ln, line in enumerate(f.code):
        op = integer_arith(line)
        if op:
            yield ln, op


@rule('L-LAY-1', 'raw `+ - *` (wrapping or not) on `.bytes` values outside `Support/ByteSize.swift`', '`ByteSize`, '
      '`CheckedUInt32`', 'module')
def check_lay(ctx, f):
    if not f.is_module or f.mrel == 'Support/ByteSize.swift':
        return
    rx = re.compile(r'\.bytes\s*&?[-+*](?!>)|(?<![-&>])&?[-+*]=?\s*(?:\w+\s*\.\s*)*\w+\s*\.\s*bytes\b')
    for ln, m in regex_lines(f, rx):
        yield ln, m.group(0).strip()


CATCHALL_ELEM = r'(?:_|(?:let|var)\s+[A-Za-z_]\w*)'
CATCHALL_BOUND_ELEM = r'(?:_|[A-Za-z_]\w*)'
CATCHALL_RE = re.compile(r'(?<![\w.])case\s+(?:_|(?:let|var)\s+[A-Za-z_]\w*|'
                         r'\(\s*' + CATCHALL_ELEM + r'(?:\s*,\s*' + CATCHALL_ELEM + r')+\s*\)|'
                         r'(?:let|var)\s*\(\s*' + CATCHALL_BOUND_ELEM + r'(?:\s*,\s*' + CATCHALL_BOUND_ELEM + r')+\s*\))'
                         r'\s*:(?!:)')
DEFAULT_RE = re.compile(r'(?<![\w.`])(?:@unknown\s+)?default\s*:(?!:)')


@rule('L-ENUM-1', '`default:` and `@unknown default:` (anywhere on a line), catch-all cases (`case _:`, `case let x:`, '
      '`case var x:`, all-wildcard or all-binding tuples such as `case (_, _):` and `case let (a, b):`)',
      'exhaustive cases; over integers/characters `// lint-exempt(L-ENUM-1): …`', 'module')
def check_enum(ctx, f):
    if not f.is_module:
        return
    joined = None
    starts = None
    for ln, m in regex_lines(f, DEFAULT_RE):
        if joined is None:
            joined = '\n'.join(f.code)
            starts = [0]
            for line in f.code:
                starts.append(starts[-1] + len(line) + 1)
        k = starts[ln] + m.start()
        prev = joined[:k].rstrip(' \t\n\x00')[-1:]
        if prev in ('(', ',', '['):
            continue  # an argument label (`dict[key, default: 0]`, `f(\n    default: x)`)
        yield ln, m.group(0).strip()
    if not re.search(r'(?<![\w.])case\b', f.text):
        return
    joined = '\n'.join(f.code)
    for m in CATCHALL_RE.finditer(joined):
        yield f.pos_at(m.start())[0], ' '.join(m.group(0).split())  # the pattern may start on the next line


@rule('L-FATAL-1', '`fatalError(`, `precondition(`, `preconditionFailure(` (`WGSLFatal.swift` implements wgslFatal)',
      '`wgslFatal(_:cppSite:)`', 'module')
def check_fatal(ctx, f):
    if not f.is_module or f.mrel == 'WGSLFatal.swift':
        return
    for ln, m in regex_lines(f, re.compile(r'(?<![\w.])(?:Swift\s*\.\s*)?(?:fatalError|precondition|preconditionFailure)\s*\(')):
        yield ln, m.group(0)


@rule('L-FORCE-1', '`!` force unwrap, `try!`, `as!`, implicitly unwrapped optionals', '`guard … else { wgslFatal }`',
      'module (also swift-format)')
def check_force(ctx, f):
    if f.is_module:
        for ln, m in regex_lines(f, re.compile(r'(?<=[\w)\]>"])!(?!=)')):
            yield ln, f.code[ln][max(0, m.start() - 12):m.end()].strip()


STUB_RE = re.compile(r'\bwgslFatal\s*\(\s*"')


@rule('L-STUB-1', '`wgslFatal("unported"` (no `lint-exempt(L-STUB-1)` is accepted)', 'the implementation', 'module')
def check_stub(ctx, f):
    if not f.is_module:
        return
    stub_lines = [lit.line for lit in f.literals if lit.text == 'unported' and STUB_RE.search(f.code[lit.line])]
    for ln in sorted(f.exempt):
        if 'L-STUB-1' in f.exempt[ln] and ln not in stub_lines:
            yield ln, 'lint-exempt(L-STUB-1) is not accepted'
    for ln in stub_lines:
        yield ln, 'unported stub'


PERF_FILES = ('AST/', 'Metal/', 'Lexer.swift', 'Parser*.swift', 'TypeCheck*.swift', 'UniformityAnalysis*.swift',
              'GlobalVariableRewriter*.swift')
HOOK_NAME_RE = re.compile(r'(?:visit|visitChildren|scopedVisit|visitShaderModule\w*)$')
FOR_IN_RE = re.compile(r'(?:^|[{;:])\s*(for)\s+(?:case\s+|try\s+|await\s+)*[^\s:][^{]*?\s+in\s|\.\s*(forEach)\b')


@rule('L-PERF-1', '`for … in` and `.forEach` (a coroutine frame per iteration at -Onone)', '`ListCursor`, '
      '`forEachElement(_:_:)`, index `while` loops', ', '.join('`%s`' % p for p in PERF_FILES) + ', visitor hooks of every pass')
def check_perf(ctx, f):
    if not f.is_module:
        return
    whole = match_mrel(f, *PERF_FILES)
    for ln, m in regex_lines(f, FOR_IN_RE):
        col = m.start(1) if m.group(1) else m.start(2)
        if not whole:
            sc = f.scope_at(ln, col)
            if not any(s.kind == 'func' and HOOK_NAME_RE.match(s.name or '') for s in sc.chain()):
                continue
        yield ln, (m.group(1) or '.' + m.group(2))


VISIT2_NAMES_RE = re.compile(r'checkErrorAndVisit\w*|maybeCheckErrorAndVisit|setError|result')


@rule('L-PERF-2', 'a non-mutating instance method or computed property of a visitor conformer (pass struct) or in an `ASTVisitor`/'
      '`ASTScopedVisitor` extension: called from the specialised traversal, it gets a copy of the whole pass at -O unless inlined',
      '`mutating` (also for helpers that only read), a `static` helper taking the parts it reads, or '
      '`// lint-exempt(L-PERF-2): <why it is off the per-node path>`', 'module')
def check_perf2(ctx, f):
    if not f.is_module:
        return
    conformers = ctx.cached('conformers', lambda: visitor_conformers(ctx))
    for st in f.stmts:
        sc = st.scope
        if sc.kind not in ('type', 'extension'):
            continue
        if not (sc.name in conformers or (sc.kind == 'extension' and sc.name in ('ASTVisitor', 'ASTScopedVisitor'))):
            continue
        d = parse_decl(st.text)
        if d.mods & {'static', 'class', 'mutating', 'consuming'}:
            continue
        if sc.name in conformers and VISIT2_NAMES_RE.fullmatch(d.name or ''):
            continue
        if d.kw == 'func':
            yield st.line_of(d.offset), 'func ' + d.name
        elif d.kw == 'var' and st.opens is not None and st.opens.kind == 'accessor':
            yield st.line_of(d.offset), 'var ' + d.name


def iter_scopes(f):
    seen = set()
    for st in f.stmts:
        if st.opens is not None and id(st.opens) not in seen:
            seen.add(id(st.opens))
            yield st.opens


def visitor_conformers(ctx):
    names = set()
    for f in ctx.module_files():
        for sc in iter_scopes(f):
            if sc.kind in ('type', 'extension') and sc.decl and \
                    any(x in ('ASTVisitor', 'ASTScopedVisitor') for x in sc.decl.inherits):
                names.add(sc.name)
    return names


PASS_SUFFIX_RE = re.compile(r'(?:Rewriter|Validator|Analysis|Analyzer|Checker|Sorter|Sorting|Mangler|Pass|Writer|Generator)$')


@rule('L-IR-1', 'stored properties of existential (`Any`, `any P`, `AnyObject`), `weak`/`unowned` or generic-parameter type in '
      '`ShaderModule`, pass structs (visitor conformers, `*Rewriter`, `*Validator`, `*Analysis`, `*Writer`, …), `ModuleState`, '
      '`PreparedState` (except under `#if WGSL_UNOPTIMIZED`)', 'concrete types', 'module')
def check_ir(ctx, f):
    if not f.is_module:
        return
    conformers = ctx.cached('conformers', lambda: visitor_conformers(ctx))
    for st in f.stmts:
        sc = st.scope
        if sc.kind != 'type':
            continue
        if not (sc.name in ('ShaderModule', 'ModuleState', 'PreparedState') or sc.name in conformers or
                PASS_SUFFIX_RE.search(sc.name)):
            continue
        d = parse_decl(st.text)
        if d.kw not in ('var', 'let') or (st.opens is not None and st.opens.kind == 'accessor') or 'static' in d.mods:
            continue
        if any(c == 'WGSL_UNOPTIMIZED' and pos for c, pos in f.ifconds[st.line]):
            continue
        m = re.match(r'(?:var|let)\s+\w+\s*:\s*(.*)', d.rest, re.S)
        typ = m.group(1) if m else ''
        typ = re.split(r'=', typ, 1)[0].strip()
        bad = None
        if 'weak' in d.mods or 'unowned' in d.mods:
            bad = 'weak/unowned'
        elif re.search(r'\bAny\b|\bany\s+\w|\bAnyObject\b|\bAnyHashable\b|\bsome\s+\w', typ):
            bad = 'existential ' + typ
        elif sc.decl and typ.rstrip('?!').strip() in sc.decl.generics:
            bad = 'generic parameter ' + typ
        if bad:
            yield st.line_of(d.offset), d.name + ': ' + bad


@rule('L-STICKY-1', '`constantValue(of:)`', 'the named sticky reader of the constant table',
      '`BoundsCheck.swift`, `GlobalVariableRewriter*.swift`, `EntryPointRewriter.swift`, `Metal/*.swift`, `Evaluate.swift`, '
      '`Types.swift`')
def check_sticky(ctx, f):
    if not f.is_module or not match_mrel(f, 'BoundsCheck.swift', 'GlobalVariableRewriter*.swift', 'EntryPointRewriter.swift',
                                         'Metal/', 'Evaluate.swift', 'Types.swift'):
        return
    for ln, m in regex_lines(f, re.compile(r'\bconstantValue\s*\(\s*of\s*:')):
        yield ln, m.group(0)


def normalize_params(params):
    sig = []
    for p in split_top(params or ''):
        p = p.strip()
        if not p:
            continue
        p = re.sub(r'\s*=.*$', '', p, flags=re.S)
        p = re.sub(r'^(?:@\w+\s+)*', '', p)
        if ':' not in p:
            sig.append(('?', re.sub(r'\s+', '', p)))
            continue
        names, typ = p.split(':', 1)
        names = names.split()
        label = names[0] if names else '_'
        typ = re.sub(r'\b(?:borrowing|consuming|__owned|__shared|sending|isolated)\s+', '', typ)
        sig.append((label, re.sub(r'\s+', '', typ)))
    return tuple(sig)


VISITOR_FILES = ('Source/WebGPU/WGSL/AST/ASTVisitor.swift', 'Source/WebGPU/WGSL/AST/ASTScopedVisitor.swift')


def visitor_signatures(ctx):
    """{name: set(param signatures)} of the hook requirements and extension methods, or None before ASTVisitor.swift."""
    files = [ctx.files[r] for r in VISITOR_FILES if r in ctx.files]
    if not any(f.rel == VISITOR_FILES[0] for f in files):
        return None
    sigs = {}
    for f in files:
        for st in f.stmts:
            sc = st.scope
            if sc.kind not in ('protocol', 'extension') or sc.name not in ('ASTVisitor', 'ASTScopedVisitor'):
                continue
            d = parse_decl(st.text)
            if d.kw == 'func' and HOOK_NAME_RE.match(d.name):
                sigs.setdefault(d.name, set()).add(normalize_params(d.params))
    return sigs


def conformer_members(ctx, f, conformers):
    for st in f.stmts:
        sc = st.scope
        if sc.kind in ('type', 'extension') and sc.name in conformers and f.rel not in VISITOR_FILES:
            yield st, parse_decl(st.text)


@rule('L-VISIT-1', 'a `visit`/`visitChildren`/`scopedVisit`/`visitShaderModule*` method in an `ASTVisitor`/`ASTScopedVisitor` '
      'conformer whose signature matches no requirement or extension method (inert until AST/ASTVisitor.swift exists)',
      'fix the signature', 'module')
def check_visit1(ctx, f):
    if not f.is_module:
        return
    sigs = ctx.cached('visitor-sigs', lambda: visitor_signatures(ctx))
    if sigs is None:
        return
    conformers = ctx.cached('conformers', lambda: visitor_conformers(ctx))
    for st, d in conformer_members(ctx, f, conformers):
        if d.kw == 'func' and HOOK_NAME_RE.match(d.name):
            sig = normalize_params(d.params)
            if sig not in sigs.get(d.name, ()):
                yield st.line_of(d.offset), '%s(%s)' % (d.name, ', '.join('%s: %s' % p for p in sig))


@rule('L-VISIT-2', 'a conformer declaring `checkErrorAndVisit*`, `maybeCheckErrorAndVisit`, `setError`, `result`',
      'the extension methods', 'module')
def check_visit2(ctx, f):
    if not f.is_module:
        return
    conformers = ctx.cached('conformers', lambda: visitor_conformers(ctx))
    for st, d in conformer_members(ctx, f, conformers):
        if d.kw == 'func' and re.fullmatch(r'checkErrorAndVisit\w*|maybeCheckErrorAndVisit|setError|result', d.name or ''):
            yield st.line_of(d.offset), d.name
        elif d.kw in ('var', 'let') and d.name == 'result':
            yield st.line_of(d.offset), d.name


WB_ALLOWED_FILE = 'MinBindingSizeWriteBack.swift'


@rule('L-WB-1', 'constructing `PrepareOutcome`/`PreparedModule` outside `WGSL.swift`\'s prepare and '
      '`MinBindingSizeWriteBack.swift`', '`Compiler.prepare`', 'module')
def check_wb(ctx, f):
    if not f.is_module or f.mrel == WB_ALLOWED_FILE:
        return
    rx = re.compile(r'\bPreparedModule\s*(?:\.\s*init\s*)?\(|\bPrepareOutcome\s*(?:\.\s*\w+\s*)?\(|(?<![\w.])\.\s*prepared\s*\(')
    for ln, m in regex_lines(f, rx):
        if re.search(r'\bcase\b', f.code[ln][:m.start()]):
            continue
        if f.mrel == 'WGSL.swift':
            sc = f.scope_at(ln, m.start())
            if any(s.kind == 'func' and s.name == 'prepare' for s in sc.chain()):
                continue
        yield ln, m.group(0)


SCOPE_FILES = ('ModuleState.swift', 'WGSLShaderModule.swift', 'TypeStore.swift')
SCOPE_RE = re.compile(r'\bwithTestScope\s*\(|\bModuleState\s*\.\s*staticCheck\s*\(|\.\s*types\s*\.\s*(?:openScope|rollback)\s*\(|'
                      r'\.\s*(?:types|symbols)\s*=(?!=)')


@rule('L-SCOPE-1', '`ModuleState.withTestScope`, `ModuleState.staticCheck` (outside `WGSL.swift`), `types.openScope`/'
      '`types.rollback`, assigning a whole `types`/`symbols`', 'the ModuleState typestate; `modify`',
      'module, outside ModuleState.swift, WGSLShaderModule.swift and TypeStore.swift')
def check_scope(ctx, f):
    if not f.is_module or f.mrel in SCOPE_FILES:
        return
    for ln, m in regex_lines(f, SCOPE_RE):
        if f.mrel == 'WGSL.swift' and 'staticCheck' in m.group(0):
            continue
        yield ln, m.group(0)


# ---------------------------------------------------------------------------------------------------------------
# Context and driver

class Context:
    """The Swift files of Source/WebGPU/WGSL."""

    def __init__(self, files):
        self.files = files
        self.cache = {}

    def with_file(self, f):
        """The same context with f in place of the file at its path."""
        files = dict(self.files)
        files[f.rel] = f
        return Context(files)

    def cached(self, key, fn):
        if key not in self.cache:
            self.cache[key] = fn()
        return self.cache[key]

    def module_files(self):
        return [f for f in self.files.values() if f.is_module]


UNEXEMPTABLE = ('L-STUB-1',)
RULES_BY_ID = {r.id: r for r in RULES}


def lint(ctx, f):
    """The findings in f as sorted (line, rule id, note), with 1-based lines; line 0 stands for the whole file."""
    findings = {}
    for r in RULES:
        for ln, note in r.check(ctx, f) or ():
            ex = f.exempt.get(ln, {})
            if r.id in ex:
                if r.id in UNEXEMPTABLE:
                    if 'not accepted' not in note:
                        note += ' (lint-exempt(%s) is not accepted)' % r.id
                elif ex[r.id]:
                    continue
                else:
                    note += ' (exemption ignored: it has no reason)'
            findings.setdefault((ln + 1 if ln >= 0 else 0, r.id), note)
    return sorted((line, rid, note) for (line, rid), note in findings.items())


def message(rule_id, note):
    r = RULES_BY_ID[rule_id]
    text = '%s: %s bans %s; instead: %s.' % (note, rule_id, r.bans, r.use)
    if rule_id not in UNEXEMPTABLE:
        text += ' A justified exception takes `// lint-exempt(%s): <reason>`.' % rule_id
    return text


def _read(path):
    with open(path, encoding='utf-8', errors='surrogateescape') as fh:
        return fh.read()


def _files_under(root, directory, suffixes=('.swift',)):
    """{path relative to root: absolute path} of the files under root/directory with one of the suffixes."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, directory)):
        dirnames.sort()
        for name in sorted(filenames):
            if name.endswith(suffixes):
                path = os.path.join(dirpath, name)
                out[os.path.relpath(path, root).replace(os.sep, '/')] = path
    return out


def _stamp(paths):
    out = []
    for rel, path in sorted(paths.items()):
        try:
            st = os.stat(path)
        except OSError:
            continue
        out.append((rel, st.st_mtime_ns, st.st_size))
    return tuple(out)


_CONTEXTS = {}


def context_for(root, rel, text):
    """The context of the checkout at root, with text as the contents of rel.

    The parsed files of a checkout are kept between calls, so a check-webkit-style run parses each file once."""
    module = _files_under(root, MODULE_DIR)
    key = _stamp(module)
    entry = _CONTEXTS.get(root)
    if entry is None or entry[0] != key:
        ctx = Context({r: SwiftFile(r, _read(p)) for r, p in module.items()})
        entry = (key, ctx)
        _CONTEXTS[root] = entry
    ctx = entry[1]
    if rel in ctx.files and ctx.files[rel].text == text:
        return ctx
    return ctx.with_file(SwiftFile(rel, text))


def split_path(file_path):
    """(checkout root, path relative to it) of a path under Source/WebGPU/, or None."""
    path = os.path.normpath(os.path.abspath(file_path)).replace(os.sep, '/')
    i = path.rfind('/Source/WebGPU/')
    if i < 0:
        return None
    return path[:i] or '/', path[i + 1:]


def _relative_path(file_path):
    split = split_path(file_path)
    return split[1] if split else None


def is_wgsl_swift_path(file_path):
    rel = _relative_path(file_path)
    return bool(rel) and rel.startswith(MODULE_DIR) and rel.endswith('.swift')


def is_webgpu_header_path(file_path):
    rel = _relative_path(file_path)
    return bool(rel) and rel.startswith(WEBGPU_HEADER_DIR) and rel.endswith('.h')


class WGSLSwiftChecker(SwiftChecker):
    """The Swift checks, plus the WGSL rules for the Swift sources of Source/WebGPU/WGSL."""

    categories = SwiftChecker.categories.union('wgsl/' + r.id for r in RULES)

    def _check_unsafe(self, lines):
        # The libFuzzer entry point has to copy out the buffer libFuzzer hands over; L-SAFE-1 makes the same exception.
        if _relative_path(self.file_path) == FUZZ_ENTRY:
            return
        super(WGSLSwiftChecker, self)._check_unsafe(lines)

    def check(self, lines, line_numbers=None):
        super(WGSLSwiftChecker, self).check(lines, line_numbers)
        root, rel = split_path(self.file_path)
        ctx = context_for(root, rel, '\n'.join(lines))
        for line, rule_id, note in lint(ctx, ctx.files[rel]):
            self.handle_style_error(line, 'wgsl/' + rule_id, 5, message(rule_id, note))


# ---------------------------------------------------------------------------------------------------------------
# HAVE(WGSL_COMPILER) in Source/WebGPU/WebGPU headers

HAVE_WGSL_COMPILER_CATEGORY = 'wgsl/have_wgsl_compiler'
HAVE_WGSL_COMPILER_RE = re.compile(r'\bHAVE\s*\(\s*WGSL_COMPILER\s*\)|\bHAVE_WGSL_COMPILER\b')


def cxx_code_lines(lines):
    """The lines with C/C++ comments and the contents of string and character literals blanked out."""
    out = []
    in_block = False
    for line in lines:
        code = []
        i = 0
        n = len(line)
        while i < n:
            if in_block:
                end = line.find('*/', i)
                if end < 0:
                    i = n
                    continue
                in_block = False
                i = end + 2
                code.append(' ')
                continue
            c = line[i]
            if line.startswith('//', i):
                break
            if line.startswith('/*', i):
                in_block = True
                i += 2
                code.append(' ')
                continue
            if c in '"\'':
                j = i + 1
                while j < n and line[j] != c:
                    j += 2 if line[j] == '\\' else 1
                code.append(c + c)
                i = j + 1
                continue
            code.append(c)
            i += 1
        out.append(''.join(code))
    return out


class WebGPUHeaderChecker(CppChecker):
    """The C++ checks, plus the HAVE(WGSL_COMPILER) ban, for the headers of Source/WebGPU/WebGPU.

    The build systems define HAVE_WGSL_COMPILER for WebGPU's Objective-C++ only: CMake does not pass per-target
    definitions to the Swift clang importer, so a header that tests it would give Swift and Objective-C++ different
    layouts."""

    categories = CppChecker.categories.union([HAVE_WGSL_COMPILER_CATEGORY])

    def check(self, lines, line_numbers=None):
        super(WebGPUHeaderChecker, self).check(lines, line_numbers)
        for index, code in enumerate(cxx_code_lines(lines)):
            if HAVE_WGSL_COMPILER_RE.search(code):
                self.handle_style_error(index + 1, HAVE_WGSL_COMPILER_CATEGORY, 5,
                                        'Do not test HAVE(WGSL_COMPILER) in a header: Swift imports the WebGPU headers '
                                        'without the definition, so Swift and Objective-C++ would disagree on layouts. '
                                        'Test it in the .mm file instead.')
