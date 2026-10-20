#!/bin/zsh
# Builds build/Talk2Me.app from the Swift package and signs it.
#
# Signing: macOS ties the Accessibility and Microphone permissions to the signing certificate,
# so every build is signed with the same "Talk2Me Signing" certificate and permissions survive
# rebuilds and updates. Locally it lives in its own keychain, unlocked here with its own
# password so codesign never shows a keychain dialog; the release workflow loads it from
# GitHub secrets and sets SIGN_IDENTITY. Without either, the app is ad-hoc signed and macOS
# asks for the permissions again after every rebuild.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/Talk2Me.app"
SIGNING="$HOME/Library/Application Support/Talk2Me Signing"
SIGN_ARGS=()
if [[ -z "${SIGN_IDENTITY:-}" && -f "$SIGNING/signing.keychain-db" ]]; then
  security unlock-keychain -p "$(<"$SIGNING/keychain-password")" "$SIGNING/signing.keychain-db"
  # By hash: the self-signed certificate is not trusted, and codesign only takes an untrusted
  # identity by hash. The keychain must be on the search list (security list-keychains).
  SIGN_IDENTITY="$(security find-certificate -c "Talk2Me Signing" -Z "$SIGNING/signing.keychain-db" | awk '/SHA-1/ {print $3}')"
  SIGN_ARGS=(--keychain "$SIGNING/signing.keychain-db")
fi

swift build -c "$CONFIG" --product Talk2Me
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Talk2Me"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Talk2Me"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Release builds stamp their version here; the update check compares against it.
if [[ -n "${VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime \
  --entitlements Resources/Talk2Me.entitlements \
  --sign "${SIGN_IDENTITY:--}" "${SIGN_ARGS[@]}" \
  "$APP"

codesign --verify --strict "$APP"
echo "Built $APP"
