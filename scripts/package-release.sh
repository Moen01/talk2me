#!/bin/zsh
# Builds Talk2Me.app and packages it for download as a zip and a disk image in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
./scripts/build-app.sh

rm -rf dist
mkdir -p dist

# Zip: keeps the bundle's signature, extended attributes and permissions intact.
ditto -c -k --sequesterRsrc --keepParent build/Talk2Me.app "dist/Talk2Me-$VERSION.zip"

# Disk image with the usual drag-to-Applications layout.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R build/Talk2Me.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Talk2Me $VERSION" -srcfolder "$STAGING" -ov -format UDZO "dist/Talk2Me-$VERSION.dmg"

( cd dist && shasum -a 256 * > SHA256SUMS )
ls -lh dist
cat dist/SHA256SUMS
