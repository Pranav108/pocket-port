#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: bash scripts/package-macos.sh <version> [--unsigned]" >&2
    exit 2
}

version=${1:-}
mode=${2:-}
[[ $# -le 2 && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
[[ -z "$mode" || "$mode" == --unsigned ]] || usage

suffix=
if [[ "$mode" == --unsigned ]]; then
    suffix=-unsigned
else
    : "${POCKETPORT_APPLICATION_IDENTITY:?Set the Developer ID Application signing identity}"
    : "${POCKETPORT_INSTALLER_IDENTITY:?Set the Developer ID Installer signing identity}"
    : "${POCKETPORT_NOTARY_PROFILE:?Set the notarytool Keychain profile}"
fi

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pocket-port-package.XXXXXXXX")
trap 'rm -rf "$work"' EXIT

for arch in arm64 x86_64; do
    build_args=(--package-path "$project_root" --scratch-path "$work/build-$arch"
                --configuration release --product pocket-port --triple "$arch-apple-macosx14.0")
    swift build "${build_args[@]}"
    bin_path=$(swift build "${build_args[@]}" --show-bin-path)
    cp "$bin_path/pocket-port" "$work/pocket-port-$arch"
done

payload="$work/payload"
mkdir -p "$payload"
binary="$payload/pocket-port"
lipo -create "$work/pocket-port-arm64" "$work/pocket-port-x86_64" -output "$binary"
architectures=" $(lipo -archs "$binary") "
if [[ "$architectures" != *" arm64 "* || "$architectures" != *" x86_64 "* ]]; then
    echo "The installer must contain both arm64 and x86_64." >&2
    exit 1
fi
chmod 755 "$binary"

name="pocket-port-$version-macos-universal$suffix.pkg"
package="$work/$name"
package_args=(--root "$payload" --ownership recommended --install-location /usr/local/bin
              --identifier dev.pocketport.cli --version "$version")
if [[ "$mode" != --unsigned ]]; then
    codesign --sign "$POCKETPORT_APPLICATION_IDENTITY" --options runtime --timestamp "$binary"
    codesign --verify --strict "$binary"
    package_args+=(--sign "$POCKETPORT_INSTALLER_IDENTITY" --timestamp)
fi
pkgbuild "${package_args[@]}" "$package"

if [[ "$mode" != --unsigned ]]; then
    result="$work/notary-result.json"
    xcrun notarytool submit "$package" --keychain-profile "$POCKETPORT_NOTARY_PROFILE" \
        --wait --output-format json > "$result"
    if [[ "$(plutil -extract status raw "$result")" != Accepted ]]; then
        cat "$result" >&2
        exit 1
    fi
    xcrun stapler staple "$package"
    xcrun stapler validate "$package"
    spctl --assess --type install "$package"
fi

destination="$project_root/.build/distribution"
mkdir -p "$destination"
mv "$package" "$destination/$name"
printf 'Installer: %s\n' "$destination/$name"
