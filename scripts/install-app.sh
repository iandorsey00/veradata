#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
source_app="$PWD/dist/VeraData.app"
applications="${1:-/Applications}"
if [[ $# -gt 1 || ! -d "$applications" ]]; then
    printf 'Usage: %s [existing Applications directory]\n' "$0" >&2
    exit 1
fi
applications="$(cd -- "$applications" && pwd -P)"
destination="$applications/VeraData.app"

if [[ ! -d "$source_app" ]]; then
    printf 'Build VeraData first with ./scripts/build-app.sh.\n' >&2
    exit 1
fi
if pgrep -x VeraData >/dev/null 2>&1; then
    printf 'Quit VeraData before installing the new build.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$source_app"

install_command() {
    if [[ -w "$applications" ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

staging="$(install_command mktemp -d "$applications/.VeraData-install.XXXXXX")"
incoming="$staging/Incoming/VeraData.app"
previous="$staging/VeraData.app"
installed=false

finish() {
    local result=$?
    if [[ "$installed" == false ]]; then
        if [[ -e "$previous" || -L "$previous" ]]; then
            install_command mv -n "$previous" "$applications/" || true
        fi
        if [[ -d "$incoming" ]]; then
            install_command mv -n "$incoming" "$(dirname "$source_app")/" || true
        fi
    fi
    if [[ -e "$previous" || -L "$previous" ]]; then
        printf 'Previous build saved at %s\n' "$previous"
    fi
    if [[ -d "$incoming" ]]; then
        printf 'New build saved at %s\n' "$incoming" >&2
    fi
    install_command rmdir "$staging/Incoming" "$staging" 2>/dev/null || true
    return "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

install_command chmod 755 "$staging"
install_command mkdir "$staging/Incoming"
install_command mv "$source_app" "$incoming"
if [[ -e "$destination" || -L "$destination" ]]; then
    install_command mv "$destination" "$previous"
fi
install_command mv -n "$incoming" "$applications/"
if [[ -d "$incoming" ]]; then
    printf 'Another copy appeared at %s during installation.\n' "$destination" >&2
    exit 1
fi
installed=true
printf 'Installed %s\n' "$destination"
