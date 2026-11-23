#!/usr/bin/env bash
# Builds a signed TVControl.apk with apktool and the JDK, so no Android SDK is needed.
set -euo pipefail
cd "$(dirname "$0")"

for tool in apktool keytool jarsigner node sips; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found." >&2; exit 1; }
done

node android/test_proto.js

ICON=android/res/drawable-xxxhdpi/ic_launcher.png
if [ ! -f "$ICON" ]; then
  mkdir -p "$(dirname "$ICON")"
  sips -z 192 192 TVControl/Assets.xcassets/AppIcon.appiconset/icon.png --out "$ICON" >/dev/null
fi

# Kept outside the repo. Android refuses updates signed with a different key.
KEYSTORE="$HOME/.android/tvcontrol.keystore"
if [ ! -f "$KEYSTORE" ]; then
  keytool -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android -alias tvcontrol \
    -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=TV Control" 2>/dev/null
fi

mkdir -p dist
rm -f dist/TVControl.apk
apktool b android -o dist/TVControl.apk
rm -rf android/build
jarsigner -keystore "$KEYSTORE" -storepass android -sigalg SHA256withRSA -digestalg SHA-256 dist/TVControl.apk tvcontrol >/dev/null
jarsigner -verify dist/TVControl.apk | head -1
echo "Built $(pwd)/dist/TVControl.apk"
