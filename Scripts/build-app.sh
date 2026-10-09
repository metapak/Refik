#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Build-only Microsoft packaging tool; no runtime npm dependency or publishing.
VSCE_CLI="${REFIK_VSCE_CLI:-}"
if [[ -z "$VSCE_CLI" || ! -f "$VSCE_CLI" ]]; then
  print -u2 "Set REFIK_VSCE_CLI to the official @vscode/vsce 4.0.0 CLI file."
  exit 1
fi
if [[ "$(node "$VSCE_CLI" --version)" != "4.0.0" ]]; then
  print -u2 "Refik editor packaging requires @vscode/vsce 4.0.0."
  exit 1
fi
mkdir -p dist
(cd Extensions/refik-editor-focus && node "$VSCE_CLI" package --no-dependencies --allow-missing-repository --skip-license --out "${PWD}/../../dist/RefikEditorFocus.vsix")
shasum -a 256 dist/RefikEditorFocus.vsix > dist/RefikEditorFocus.vsix.sha256

if [[ "${1:-}" == "--universal" ]]; then
  swift build -c release --arch arm64 --arch x86_64
else
  swift build -c release --arch arm64
fi

BIN="$(swift build -c release --show-bin-path)"
APP="${PWD}/dist/refik.app"
mkdir -p dist
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/refik" "$APP/Contents/MacOS/refik"
cp "$BIN/refikHook" "$APP/Contents/MacOS/refikHook"
cp "$BIN/refikCLI" "$APP/Contents/MacOS/refikCLI"
cp -R Resources/Mascots Resources/Sounds "$APP/Contents/Resources/"
cp dist/RefikEditorFocus.vsix "$APP/Contents/Resources/"
cp Resources/refik.icns "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/ThirdPartyLicenses"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/ThirdPartyLicenses/component-license.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>refik</string>
<key>CFBundleDisplayName</key><string>refik</string>
<key>CFBundleIdentifier</key><string>com.refik.app</string>
<key>CFBundleVersion</key><string>5</string>
<key>CFBundleShortVersionString</key><string>0.1.4</string>
<key>CFBundleExecutable</key><string>refik</string>
<key>CFBundleIconFile</key><string>refik.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Remove compiler debug records containing local build paths before signing.
strip -S "$APP/Contents/MacOS/refik" "$APP/Contents/MacOS/refikHook" "$APP/Contents/MacOS/refikCLI"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"

if [[ "${1:-}" == "--dmg" || "${2:-}" == "--dmg" ]]; then
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/refik.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname refik -srcfolder "$STAGE" -ov -format UDZO "${PWD}/dist/refik.dmg" >/dev/null
  rm -rf "$STAGE"
  echo "${PWD}/dist/refik.dmg"
fi
