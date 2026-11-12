#!/bin/bash
# Build Typeset.app (release) from the Swift package and launch it.
#   ./build.sh [--no-open] [--public]
# Anything in Resources/Private (gitignored: your fonts, paper.json, nameplate, a seed issue and its pictures) is
# bundled into the app as its defaults. --public leaves it out, to see the app as someone cloning the repo gets it.
set -euo pipefail
OPEN=1; PRIVATE=1
for a in "$@"; do case "$a" in --no-open) OPEN=0;; --public) PRIVATE=0;; *) echo "unknown option $a" >&2; exit 2;; esac; done
cd "$(dirname "$0")"
if ! out=$(swift build -c release 2>&1); then
  echo "$out" | grep -E "error" ; exit 1
fi
echo "$out" | grep -E "warning: unre|Build complete" || true
test -x .build/release/Typeset
APP=build/Typeset.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Typeset "$APP/Contents/MacOS/Typeset"
cp -R Resources/IDML Resources/AppIcon.icns "$APP/Contents/Resources/"
if [ "$PRIVATE" = 1 ] && [ -d Resources/Private ] && [ -n "$(ls -A Resources/Private)" ]; then
  cp -R Resources/Private/. "$APP/Contents/Resources/"
  echo "bundled Resources/Private: $(ls Resources/Private | tr '\n' ' ')"
fi
[ -d Resources/Components ] && cp -R Resources/Components "$APP/Contents/Resources/"   # the shipped Header and Folio
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Typeset</string>
  <key>CFBundleDisplayName</key><string>Typeset</string>
  <key>CFBundleIdentifier</key><string>edu.rpi.poly.galley</string>
  <key>CFBundleExecutable</key><string>Typeset</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>edu.rpi.poly.galley.issue</string>
    <key>UTTypeDescription</key><string>Typeset Issue</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeIconFile</key><string>AppIcon</string>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>typeset</string></array></dict>
  </dict><dict>
    <key>UTTypeIdentifier</key><string>edu.rpi.poly.galley.template</string>
    <key>UTTypeDescription</key><string>Typeset Template</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeIconFile</key><string>AppIcon</string>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>typesettemplate</string></array></dict>
  </dict><dict>
    <key>UTTypeIdentifier</key><string>edu.rpi.poly.galley.component</string>
    <key>UTTypeDescription</key><string>Typeset Component</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeIconFile</key><string>AppIcon</string>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>typesetcomponent</string></array></dict>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Typeset Issue</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>edu.rpi.poly.galley.issue</string></array>
  </dict><dict>
    <key>CFBundleTypeName</key><string>Typeset Template</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>edu.rpi.poly.galley.template</string></array>
  </dict><dict>
    <key>CFBundleTypeName</key><string>Typeset Component</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>edu.rpi.poly.galley.component</string></array>
  </dict></array>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "built $APP"
if [ "$OPEN" = 1 ]; then open "$APP"; fi
