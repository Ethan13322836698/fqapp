#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then echo 'macOS with Xcode is required.' >&2; exit 1; fi
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
export CARGO_PROFILE_RELEASE_STRIP=debuginfo
architectures="${ARCHS:-arm64 x86_64}"
libraries=()
for arch in $architectures; do
  case "$arch" in
    arm64) target=aarch64-apple-darwin ;;
    x86_64) target=x86_64-apple-darwin ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 2 ;;
  esac
  rustup target add "$target"
  cargo build --manifest-path "$ROOT/rust/Cargo.toml" --target-dir "$ROOT/rust/target" --locked --release --target "$target"
  libraries+=("$ROOT/rust/target/$target/release/libfqapi_core.dylib")
done
mkdir -p "$ROOT/macos/Frameworks"
output="$ROOT/macos/Frameworks/libfqapi_core.dylib"
if [[ ${#libraries[@]} -eq 1 ]]; then cp "${libraries[0]}" "$output"; else lipo -create "${libraries[@]}" -output "$output"; fi
install_name_tool -id '@rpath/libfqapi_core.dylib' "$output"
lipo "$output" -verify_arch $architectures
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${FRAMEWORKS_FOLDER_PATH:-}" ]]; then
  destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
  mkdir -p "$destination"
  cp "$output" "$destination/libfqapi_core.dylib"
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$destination/libfqapi_core.dylib"
fi
