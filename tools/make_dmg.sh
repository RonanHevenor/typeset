#!/bin/bash
# Package build/Typeset.app as a disk image with an Applications shortcut to drag it onto.
#   tools/make_dmg.sh [out.dmg]        (default build/Typeset.dmg; run ./build.sh first)
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Typeset.app
OUT=${1:-build/Typeset.dmg}
test -d "$APP" || { echo "no $APP: run ./build.sh --no-open first" >&2; exit 1; }
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -quiet -volname Typeset -srcfolder "$STAGE" -ov -format UDZO "$OUT"
hdiutil verify -quiet "$OUT"
echo "wrote $OUT"
