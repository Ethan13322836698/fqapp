#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arch="${1:-universal}"
case "$arch" in x64) slices='x86_64';; arm64) slices='arm64';; universal) slices='x86_64 arm64';; *) echo 'Usage: build_macos.sh [x64|arm64|universal]' >&2; exit 2;; esac
if [[ "$(uname -s)" != Darwin ]]; then echo 'Build on macOS with Xcode and CocoaPods.' >&2; exit 1; fi
cd "$ROOT"
flutter pub get --enforce-lockfile
flutter build macos --release
source_app="$ROOT/build/macos/Build/Products/Release/fqapp.app"
[[ -d "$source_app" ]] || { echo 'Flutter app bundle missing' >&2; exit 1; }
mkdir -p dist
app="$ROOT/dist/fqapp-macos-$arch.app"
[[ ! -e "$app" ]] || { echo "Remove the previous output first: $app" >&2; exit 1; }
ditto "$source_app" "$app"
# Each artifact must contain only the requested slices, including native plugins.
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    lipo -verify_arch $slices "$binary"
    if [[ "$arch" != universal && "$(lipo -archs "$binary")" == *' '* ]]; then
      lipo "$binary" -thin "$slices" -output "$binary.thin"
      chmod "$(stat -f %Lp "$binary")" "$binary.thin"
      mv "$binary.thin" "$binary"
    fi
  fi
done < <(find "$app/Contents" -type f -print0)
[[ -f "$app/Contents/Frameworks/libfqapi_core.dylib" ]] || { echo 'Rust core missing' >&2; exit 1; }
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
cp MACOS.md "$app/Contents/Resources/MACOS.md"
# Architecture thinning changes signatures; produce a coherent ad-hoc signed bundle.
codesign --force --deep --sign - --timestamp=none --entitlements macos/Runner/Release.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"
python3 scripts/verify_macos_bundle.py "$app" "$arch"
archive="$ROOT/dist/fqapp-macos-$arch.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
echo "Built $archive"
