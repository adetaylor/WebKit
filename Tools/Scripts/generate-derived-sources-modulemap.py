#!/usr/bin/env python3
# Copyright (C) 2026 Apple Inc. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.

import argparse
import os
import sys


def main():
    parser = argparse.ArgumentParser(description='Generate module.private.modulemap for WebKit derived sources')
    parser.add_argument('xcfilelist', help='Path to DerivedSources-output.xcfilelist')
    parser.add_argument('output', help='Path to output module.private.modulemap')
    args = parser.parse_args()

    # Read the xcfilelist and extract header files
    headers = []
    try:
        with open(args.xcfilelist, 'r') as f:
            for line in f:
                line = line.strip()
                # Skip comments and empty lines
                if not line or line.startswith('#'):
                    continue
                # Only include .h files from DerivedSources/WebKit
                if line.endswith('.h') and '/DerivedSources/WebKit/' in line:
                    # Extract just the filename
                    filename = os.path.basename(line)
                    headers.append(filename)
    except IOError as e:
        print(f'Error reading {args.xcfilelist}: {e}', file=sys.stderr)
        return 1

    # Sort headers for consistent output
    headers.sort()

    # Generate the modulemap
    try:
        os.makedirs(os.path.dirname(args.output), exist_ok=True)
        with open(args.output, 'w') as f:
            f.write('module WebKit_DerivedSources {\n')
            f.write('   requires cplusplus\n')
            f.write('   export *\n')
            for header in headers:
                f.write(f'   header "{header}"\n')
            f.write('}\n')
    except IOError as e:
        print(f'Error writing {args.output}: {e}', file=sys.stderr)
        return 1

    return 0


if __name__ == '__main__':
    sys.exit(main())
