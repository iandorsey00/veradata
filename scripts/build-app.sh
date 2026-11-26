#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release --product VeraData "$@"
products="$(swift build -c release --show-bin-path "$@")"
mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.assemble.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

app="$staging/VeraData.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/VeraData" "$app/Contents/MacOS/"
cp Sources/VeraDataApp/Resources/demo.json "$app/Contents/Resources/"
cp scripts/Info.plist "$app/Contents/Info.plist"
cp -R Sources/VeraDataCore/Resources/*.lproj "$app/Contents/Resources/"

cp Assets/VeraData.icns "$app/Contents/Resources/"

codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

if [[ -e dist/VeraData.app ]]; then
    mv dist/VeraData.app "$staging/previous.app"
fi
if ! mv "$app" dist/VeraData.app; then
    if [[ -e "$staging/previous.app" ]]; then
        mv "$staging/previous.app" dist/VeraData.app
    fi
    exit 1
fi
printf '%s\n' "$PWD/dist/VeraData.app"
