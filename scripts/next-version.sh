#!/bin/zsh
# Prints the version for the next release.
#
# Normally that is the latest GitHub release with the last number raised by one (0.1.0 -> 0.1.1).
# Raise CFBundleShortVersionString in Resources/Info.plist above the latest release (e.g. to 0.2.0)
# to choose the next version yourself. Needs the gh CLI, signed in or with GH_TOKEN set.
set -euo pipefail
cd "$(dirname "$0")/.."

planned="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
latest="$(gh release view --json tagName --jq .tagName 2>/dev/null || true)"
latest="${latest#v}"

if [[ -z "$latest" ]]; then
  echo "$planned"
  exit 0
fi
highest="$(printf '%s\n%s\n' "$planned" "$latest" | sort -V | tail -1)"
if [[ "$planned" != "$latest" && "$highest" == "$planned" ]]; then
  echo "$planned"
  exit 0
fi
parts=("${(@s:.:)latest}")
parts[-1]=$(( parts[-1] + 1 ))
echo "${(j:.:)parts}"
