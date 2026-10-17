#!/bin/zsh
# Builds build/Talk2Me.app from the Swift package and signs it.
#
# Signing: set SIGN_IDENTITY to a code-signing certificate name for a stable signature.
# Without one the app is ad-hoc signed, and macOS asks for Accessibility access again
# after every rebuild because the signature changes.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/Talk2Me.app"

swift build -c "$CONFIG" --product Talk2Me
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Talk2Me"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Talk2Me"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime \
  --entitlements Resources/Talk2Me.entitlements \
  --sign "${SIGN_IDENTITY:--}" \
  "$APP"

codesign --verify --strict "$APP"
echo "Built $APP"
