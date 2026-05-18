#!/usr/bin/env python3
"""Generate a swiftc @-response file containing the platform-derived flags.

Mirrors the behaviour of Source/WTF/Scripts/generate-platform-args (Xcode build
phase) but adapted for cmake. Produces two kinds of flag:

  -DNAME              for every truthy HAVE_/USE_/ENABLE_/WTF_PLATFORM_/ASSERT_
                      macro that wtf/Platform.h derives, used for Swift's #if
                      conditional compilation.

  -Xcc -DNAME=VALUE   for every entry in cmakeconfig.h, so the clang importer's
                      view of the cmake config matches what a regular C++ TU
                      sees via #include "config.h" -> #include "cmakeconfig.h".

Each token is written on its own line. swiftc reads response files one
argument per line.
"""

import argparse
import re
import subprocess
import sys


CMAKECONFIG_DEFINE = re.compile(r'^#define (\w+) (.+)$')
PREPROCESS_DEFINE = re.compile(r'^#define (\w+) ([01])$')
PLATFORM_PREFIX = re.compile(r'^(HAVE_|USE_|ENABLE_|WTF_PLATFORM|ASSERT_)')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--output', required=True,
                    help='Path to write the response file.')
    ap.add_argument('--cmakeconfig', required=True,
                    help='Path to cmakeconfig.h to seed the clang importer.')
    ap.add_argument('command', nargs=argparse.REMAINDER,
                    help='Clang preprocess command (preceded by --).')
    args = ap.parse_args()

    cmd = args.command
    if cmd and cmd[0] == '--':
        cmd = cmd[1:]
    if not cmd:
        ap.error('clang command is required after --')

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        sys.exit(result.returncode)

    swift_defines = []
    seen = set()
    for line in result.stdout.splitlines():
        m = PREPROCESS_DEFINE.match(line)
        if m and m.group(2) == '1' and PLATFORM_PREFIX.match(m.group(1)):
            name = m.group(1)
            if name not in seen:
                seen.add(name)
                swift_defines.append(name)

    cmake_seeds = []
    with open(args.cmakeconfig) as f:
        for line in f:
            m = CMAKECONFIG_DEFINE.match(line.strip())
            if m:
                cmake_seeds.append((m.group(1), m.group(2)))

    out_lines = []
    for name in swift_defines:
        out_lines.append('-D' + name)
    for name, value in cmake_seeds:
        out_lines.append('-Xcc')
        out_lines.append('-D' + name + '=' + value)

    with open(args.output, 'w') as f:
        f.write('\n'.join(out_lines))
        f.write('\n')


if __name__ == '__main__':
    main()
