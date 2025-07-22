#!/bin/sh

set -e

FRAMEWORK_NAME="LanguageModeling"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
XCODE_PATH="$(xcode-select -p)"
FRAMEWORK_HEADERS="$XCODE_PATH/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.0.Internal.sdk/System/Library/PrivateFrameworks/$FRAMEWORK_NAME.framework/PrivateHeaders"
OVERLAY_PATH="/tmp/${FRAMEWORK_NAME}_Headers"
rm -Rf "$OVERLAY_PATH" || true
cp -r "$FRAMEWORK_HEADERS" "$OVERLAY_PATH"

echo "#include <memory>" | cat - "$OVERLAY_PATH/CompletionStem.hpp" > /tmp/temp.h && cp /tmp/temp.h "$OVERLAY_PATH/CompletionStem.hpp"

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
