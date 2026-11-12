#!/bin/bash
# Render the seed issue (the Header filled with stories 3–5 by hand, as the generator teased them before
# phase 4) and compare each page with phase 0's reference pages (repro/reference).
# Usage: repro/compare.sh [data-dir]   Prints per-page differing-pixel counts; 0 everywhere = identical.
set -e
cd "$(dirname "$0")/.."
# Usage: repro/compare.sh --migrated   Opens the seed issue with phase 0's own layout, saved as a file from before
#   components was (teasers and a teaser inset, no format key), and renders it as is: the migration must give the
#   same pages.
OUT=repro/out; rm -rf $OUT; mkdir -p $OUT
if [ "${1:-}" = "--migrated" ]; then
  shift
  python3 -I -c "
import json
d = json.load(open('Resources/Private/seed-issue.json')); d['layout'] = json.load(open('repro/reference/seed1-layout.json'))
json.dump(d, open('$OUT/old-format.json', 'w'))"
  RENDER="--render --issue $OUT/old-format.json --as-is"
else
  RENDER="--render --seed 1 --fill-header"
fi
DATA="${1:-$(mktemp -d)}"
GALLEY_DATA_DIR="$DATA" build/Typeset.app/Contents/MacOS/Typeset $RENDER --out $OUT/seed1.pdf --json $OUT/seed1-layout.json >/dev/null 2>&1
pdftoppm -r 100 -png $OUT/seed1.pdf $OUT/page 2>/dev/null
status=0
for ref in repro/reference/page-*.png; do
  p=$(basename $ref)
  if [ ! -f $OUT/$p ]; then echo "$p MISSING"; status=1; continue; fi
  [ -x repro/.pngdiff ] || swiftc -O repro/pngdiff.swift -o repro/.pngdiff
  n=$(repro/.pngdiff $ref $OUT/$p $OUT/diff-$p || true)
  echo "$p differing pixels: $n"; [ "${n%% *}" != "0" ] && status=1
done
for p in $OUT/page-*.png; do [ -f repro/reference/$(basename $p) ] || { echo "$(basename $p) EXTRA"; status=1; }; done
exit $status
