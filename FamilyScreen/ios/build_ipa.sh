#!/usr/bin/env bash
# Builds an unsigned FamilyScreen.ipa for sideloading (Sideloadly / AltStore re-sign it). Runs in CI.
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate
rm -rf build dist
xcodebuild \
  -project FamilyScreen.xcodeproj \
  -scheme FamilyScreen \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="build/Build/Products/Release-iphoneos/FamilyScreen.app"
[ -d "$APP" ] || { echo "error: $APP was not produced" >&2; exit 1; }
mkdir -p dist/Payload
cp -R "$APP" dist/Payload/
(cd dist && zip -qry FamilyScreen-unsigned.ipa Payload && rm -rf Payload)
echo "Built $(pwd)/dist/FamilyScreen-unsigned.ipa"
