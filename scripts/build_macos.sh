#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arch="${1:-universal}"
case "$arch" in x64) slices='x86_64';; arm64) slices='arm64';; universal) slices='x86_64 arm64';; *) echo 'Usage: build_macos.sh [x64|arm64|universal]' >&2; exit 2;; esac
if [[ "$(uname -s)" != Darwin ]]; then echo 'Build on macOS with Xcode and CocoaPods.' >&2; exit 1; fi
cd "$ROOT"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "${sdk_version%%.*}" -lt 26 ]]; then
  echo 'connectivity_plus requires macOS SDK 26 or newer. Select Xcode 26+ with DEVELOPER_DIR or xcode-select.' >&2
  exit 1
fi
xcodebuild -version
echo "macOS SDK: $sdk_version"
flutter pub get --enforce-lockfile
flutter build macos --release --no-pub
source_app="$ROOT/build/macos/Build/Products/Release/fqapp.app"
[[ -d "$source_app" ]] || { echo 'Flutter app bundle missing' >&2; exit 1; }
mkdir -p dist
app="$ROOT/dist/fqapp-macos-$arch.app"
[[ ! -e "$app" ]] || { echo "Remove the previous output first: $app" >&2; exit 1; }
ditto "$source_app" "$app"
# Each artifact must contain only the requested slices, including native plugins.
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    lipo "$binary" -verify_arch $slices
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
# Thinning invalidates existing signatures. Sign code inside each bundle
# first, then sign the enclosing bundles. App entitlements belong to Runner.
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    codesign --force --sign - --timestamp=none "$binary"
  fi
done < <(find "$app/Contents/Frameworks" -type f -print0)
while IFS= read -r -d '' bundle; do
  codesign --force --sign - --timestamp=none "$bundle"
done < <(find "$app/Contents/Frameworks" -depth -type d \
  \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.bundle' \) -print0)
codesign --force --sign - --timestamp=none --entitlements macos/Runner/Release.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"
python3 scripts/verify_macos_bundle.py "$app" "$arch"
archive="$ROOT/dist/fqapp-macos-$arch.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
echo "Built $archive"
