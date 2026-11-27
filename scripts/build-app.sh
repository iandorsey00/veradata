#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

sdk_version=27.2
sdk_name="macosx$sdk_version"
if ! sdk_path="$(xcrun --sdk "$sdk_name" --show-sdk-path 2>/dev/null)" ||
   [[ "$(xcrun --sdk "$sdk_name" --show-sdk-version 2>/dev/null)" != "$sdk_version" ]]; then
    printf 'VeraData requires the macOS %s SDK. Select Xcode 27.2 or Command Line Tools that include that SDK.\n' "$sdk_version" >&2
    exit 1
fi

minimum_os="$(sed -nE 's/.*\.macOS\(\.v([0-9]+(_[0-9]+)*)\).*/\1/p' Package.swift | tr '_' '.')"
if [[ "$minimum_os" =~ ^[0-9]+$ ]]; then
    minimum_os="$minimum_os.0"
fi
if [[ ! "$minimum_os" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    printf 'Could not read the macOS deployment target from Package.swift.\n' >&2
    exit 1
fi

export SDKROOT="$sdk_path"
sdk_flags=(
    -Xswiftc -sdk -Xswiftc "$sdk_path"
    -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_os" -Xlinker "$sdk_version"
)
swift build -c release --product VeraData "$@" "${sdk_flags[@]}"
swift build -c release --product veradata-cli "$@" "${sdk_flags[@]}"
products="$(swift build -c release --show-bin-path "$@" "${sdk_flags[@]}")"

for binary in VeraData veradata-cli; do
    if ! xcrun vtool -show-build "$products/$binary" | awk -v sdk="$sdk_version" -v minos="$minimum_os" '
        $1 == "sdk" { sdks++; if ($2 != sdk) mismatch = 1 }
        $1 == "minos" { versions++; if ($2 != minos) mismatch = 1 }
        END { exit (mismatch || !sdks || sdks != versions) }
    '; then
        printf '%s must report SDK %s and minimum macOS %s. The app bundle was left in place.\n' \
            "$binary" "$sdk_version" "$minimum_os" >&2
        exit 1
    fi
done

mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.assemble.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

app="$staging/VeraData.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp "$products/VeraData" "$app/Contents/MacOS/"
cp "$products/veradata-cli" "$app/Contents/Helpers/veradata"
cp Sources/VeraDataApp/Resources/demo.json "$app/Contents/Resources/"
cp scripts/Info.plist "$app/Contents/Info.plist"
cp -R Sources/VeraDataCore/Resources/*.lproj "$app/Contents/Resources/"
cp scripts/zh-Hans.lproj/InfoPlist.strings "$app/Contents/Resources/zh-Hans.lproj/"

cp Assets/VeraData.icns "$app/Contents/Resources/"

codesign --force --sign - "$app/Contents/Helpers/veradata"
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
