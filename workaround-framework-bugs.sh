#!/bin/sh

# Workaround for rdar://136551157
# Pass the name of the framework (a single lower case word) as the first argument to this script

set -e

if [ $# -eq 0 ]; then
  echo "You must supply the correct framework name - lowercase"
  exit -1
fi

FRAMEWORK_NAME="$1"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
XCODE_PATH="$(xcode-select -p)"
FRAMEWORK_HEADERS="$XCODE_PATH/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.6.Internal.sdk/System/Library/PrivateFrameworks/$FRAMEWORK_NAME.framework/Headers"
OVERLAY_PATH="/tmp/${FRAMEWORK_NAME}_Headers"
rm -Rf "$OVERLAY_PATH" || true
cp -r "$FRAMEWORK_HEADERS" "$OVERLAY_PATH"

echo "#include <atomic>" | cat - "$OVERLAY_PATH/allocator/bitmap_allocator.h" > /tmp/temp.h && cp /tmp/temp.h "$OVERLAY_PATH/allocator/bitmap_allocator.h"
echo "#include <typeinfo>" | cat - "$OVERLAY_PATH/concurrent/task.h" > /tmp/temp.h && cp /tmp/temp.h "$OVERLAY_PATH/concurrent/task.h"
echo "#include <type_traits>" | cat - "$OVERLAY_PATH/utility/string_utilities.h" > /tmp/temp.h && cp /tmp/temp.h "$OVERLAY_PATH/utility/string_utilities.h"

cat > "$SCRIPT_DIR/Source/WebKit/framework-overlay.yaml"  <<ENDDOC
# Created by workaround-framework-bugs.sh
{
  'version': 0,
  'roots': [
    {
      'name': '$FRAMEWORK_HEADERS',
      'type': 'directory-remap',
      'external-contents': '$OVERLAY_PATH'
    }
  ]
}
ENDDOC
