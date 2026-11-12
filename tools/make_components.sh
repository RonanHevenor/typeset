#!/bin/bash
# Remakes the shipped Header and Folio components (Resources/Components/*.typesetcomponent) from the house style,
# with the built app (./build.sh --no-open first). They're committed; run this after changing HouseStyle.Front or
# HouseStyle.Folio, then build again so the bundle carries the new files.
set -e
cd "$(dirname "$0")/.."
build/Typeset.app/Contents/MacOS/Typeset --make-components Resources/Components
