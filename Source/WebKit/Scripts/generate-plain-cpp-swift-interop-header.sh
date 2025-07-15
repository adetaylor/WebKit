#!/bin/bash
set -e

# Swift/C++ interop generates a header file to be included in C++ code that provides
# definitions of types encountered in Swift.
# There's built-in XCode functionality to generate this file.
# But we need to do it twice:
# - once, processing Swift code that pertains to objective-C[++] types to generate
#   a header for inclusion in objective-C++ code
# - once, processing only Swift code that does not involve objective-C[++ types,
#   to generate a header which can be safely included in pure C++ code.
# This shell script does the second thing. We use the built-in XCode action
# for the first.
# Working around rdar://152836730

/usr/bin/swiftc -emit-clang-header-path "${SCRIPT_OUTPUT_FILE_0}" -DEXCLUDE_OBJC_STUFF "${SCRIPT_INPUT_FILE_0}"
