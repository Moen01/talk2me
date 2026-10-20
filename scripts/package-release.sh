#!/bin/zsh
# Builds Talk2Me.app and packages it for download as a zip and a disk image in dist/.
#
# The files keep the same names in every release, so
# https://github.com/Moen01/talk2me/releases/latest/download/Talk2Me.zip always gets the newest one.
# VERSION overrides CFBundleShortVersionString from Resources/Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

export VERSION="${VERSION:-$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)}"
./scripts/build-app.sh

rm -rf dist
mkdir -p dist

# Zip: keeps the bundle's signature, extended attributes and permissions intact.
ditto -c -k --sequesterRsrc --keepParent build/Talk2Me.app dist/Talk2Me.zip

# Disk image with the usual drag-to-Applications layout.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R build/Talk2Me.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Talk2Me $VERSION" -srcfolder "$STAGING" -ov -format UDZO dist/Talk2Me.dmg

( cd dist && shasum -a 256 * > SHA256SUMS )
ls -lh dist
cat dist/SHA256SUMS
