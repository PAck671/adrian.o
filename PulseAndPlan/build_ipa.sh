#!/usr/bin/env bash
# Builds an unsigned PulseAndPlan.ipa for sideloading (Sideloadly / AltStore / LiveContainer re-sign it).
set -euo pipefail
cd "$(dirname "$0")"

for tool in xcodegen xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: '$tool' not found. Install Xcode and 'brew install xcodegen'." >&2
    exit 1
  fi
done

xcodegen generate

rm -rf build dist
xcodebuild \
  -project PulseAndPlan.xcodeproj \
  -scheme PulseAndPlan \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="build/Build/Products/Release-iphoneos/PulseAndPlan.app"
[ -d "$APP" ] || { echo "error: $APP was not produced" >&2; exit 1; }

mkdir -p dist/Payload
cp -R "$APP" dist/Payload/
(cd dist && zip -qry RedThread-unsigned.ipa Payload && rm -rf Payload)
echo "Built $(pwd)/dist/RedThread-unsigned.ipa"
