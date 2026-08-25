#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$SCRIPT_DIR"

PROJECT_PATH="NoXcodeApp/NoXcode.xcodeproj"
SCHEME="NoXcode"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.build}"
APP_NAME="NoXcode.app"
SOURCE_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
TARGET_APP_PATH="$HOME/Applications/$APP_NAME"

echo "Building $APP_NAME ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

if [[ ! -d "$SOURCE_APP_PATH" ]]; then
  echo "Build succeeded, but app bundle was not found at:"
  echo "  $SOURCE_APP_PATH"
  exit 1
fi

echo "Installing to $TARGET_APP_PATH..."
mkdir -p "$HOME/Applications"
rm -rf "$TARGET_APP_PATH"
ditto "$SOURCE_APP_PATH" "$TARGET_APP_PATH"

# Safe to ignore if no quarantine attribute exists.
xattr -dr com.apple.quarantine "$TARGET_APP_PATH" 2>/dev/null || true

if pgrep -x "NoXcode" >/dev/null 2>&1; then
  echo "Stopping running NoXcode..."
  osascript -e 'tell application "NoXcode" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! pgrep -x "NoXcode" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  if pgrep -x "NoXcode" >/dev/null 2>&1; then
    echo "Force killing NoXcode..."
    pkill -x "NoXcode" >/dev/null 2>&1 || true
  fi
fi

echo "Opening app..."
open "$TARGET_APP_PATH"

echo "Done."
