#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Command Line Tools keeps the Swift Testing macros in a separate plugin directory.
developer="$(xcode-select -p)"
testing_plugin="$developer/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$testing_plugin" ]]; then
    swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin" "$@"
else
    swift test --disable-xctest "$@"
fi

python3 scripts/check-portability.py
