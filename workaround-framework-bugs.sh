#!/bin/sh

# Workaround for rdar://152833427 and rdar://152832286
# Give three arguments:
# 1) Name of the framework in the second bug
# 2) Name of the header in the second bug
# 3) Name of the JSON parsing framework in the first bug (lowercase name)

set -e

if [ $# -eq 0 ]; then
  echo "You must supply the correct framework name - lowercase - and header name"
  exit -1
fi

FRAMEWORK_NAME="$1"
HEADER_NAME="$2"
JSON_FRAMEWORK_NAME="$3"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
XCODE_PATH="$(xcode-select -p)"
FRAMEWORK_HEADERS="$XCODE_PATH/Platforms/MacOSX.platform/Developer/SDKs/MacOSX16.0.Internal.sdk/System/Library/PrivateFrameworks/$FRAMEWORK_NAME.framework/PrivateHeaders"
OVERLAY_PATH="/tmp/${FRAMEWORK_NAME}_Headers"
rm -Rf "$OVERLAY_PATH" || true
cp -r "$FRAMEWORK_HEADERS" "$OVERLAY_PATH"

echo "#include <cstddef>" | cat - "$OVERLAY_PATH/$HEADER_NAME" > /tmp/temp.h && cp /tmp/temp.h "$OVERLAY_PATH/$HEADER_NAME"

JSON_FRAMEWORK_HEADERS="$XCODE_PATH/Platforms/MacOSX.platform/Developer/SDKs/MacOSX16.0.Internal.sdk/usr/local/include/$JSON_FRAMEWORK_NAME"
JSON_OVERLAY_PATH="/tmp/${JSON_FRAMEWORK_NAME}_Headers"
rm -Rf "$JSON_OVERLAY_PATH" || true
cp -r "$JSON_FRAMEWORK_HEADERS" "$JSON_OVERLAY_PATH"
echo "#include <streambuf>" | cat - "$JSON_OVERLAY_PATH/v3.8/detail/input/input_adapters.hpp" > /tmp/temp.h && cp /tmp/temp.h "$JSON_OVERLAY_PATH/v3.8/detail/input/input_adapters.hpp"

cat > "$SCRIPT_DIR/Source/WebKit/framework-overlay.yaml"  <<ENDDOC
# Created by workaround-framework-bugs.sh
{
  'version': 0,
  'roots': [
    {
      'name': '$FRAMEWORK_HEADERS',
      'type': 'directory-remap',
      'external-contents': '$OVERLAY_PATH'
    },
    {
      'name': '$JSON_FRAMEWORK_HEADERS',
      'type': 'directory-remap',
      'external-contents': '$JSON_OVERLAY_PATH'
    }
  ]
}
ENDDOC
