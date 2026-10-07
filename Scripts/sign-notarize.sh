#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${APPLE_DEVELOPER_ID:?Developer ID Application kimliği gerekli}"
: "${APPLE_NOTARY_PROFILE:?notarytool keychain profili gerekli}"
APP="${PWD}/dist/refik.app"
DMG="${PWD}/dist/refik.dmg"
[[ -d "$APP" ]] || { print -u2 'Önce zsh Scripts/build-app.sh --dmg çalıştırın'; exit 1; }
codesign --force --deep --options runtime --timestamp --sign "$APPLE_DEVELOPER_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/refik.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname refik -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
xcrun notarytool submit "$DMG" --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
