#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
APP_NAME="x3utils"
ICON_NAME="AppIcon"

BUILD_APP="$ROOT_DIR/build/macos/Build/Products/Release/$APP_NAME.app"
PACKAGE_DIR="$ROOT_DIR/dist/$APP_NAME-$VERSION-macos-universal"
PACKAGE_APP="$PACKAGE_DIR/$APP_NAME.app"
OUTPUT_ZIP="$ROOT_DIR/dist/$APP_NAME-$VERSION-macos-universal.zip"
NATIVE_SOURCE="$ROOT_DIR/native/macos"
NATIVE_DEST="$PACKAGE_APP/Contents/MacOS/native/macos"
LIBUSB_SOURCE="$NATIVE_SOURCE/oocd/libexec/libusb-1.0.0.dylib"
LIBUSB_DEST="$NATIVE_DEST/oocd/libexec/libusb-1.0.0.dylib"
LIBUSB_RECORDS_SOURCE="$ROOT_DIR/third_party/libusb"
LIBUSB_RECORDS_DEST="$PACKAGE_APP/Contents/Resources/licenses/libusb"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "Required file not found: $1"
}

require_executable() {
  [[ -x "$1" ]] || fail "Required executable not found: $1"
}

require_universal() {
  local file="$1"
  local archs
  archs="$(lipo -archs "$file" 2>/dev/null || true)"
  [[ " $archs " == *" x86_64 "* ]] || fail "Missing x86_64 slice: $file"
  [[ " $archs " == *" arm64 "* ]] || fail "Missing arm64 slice: $file"
}

command -v flutter >/dev/null 2>&1 || fail "flutter is not in PATH"
command -v codesign >/dev/null 2>&1 || fail "codesign is not available"
command -v ditto >/dev/null 2>&1 || fail "ditto is not available"
command -v lipo >/dev/null 2>&1 || fail "lipo is not available"
command -v rsync >/dev/null 2>&1 || fail "rsync is not available"

require_file "$ROOT_DIR/pubspec.yaml"
require_file "$ROOT_DIR/lib/theme.dart"
require_executable "$NATIVE_SOURCE/oocd/bin/openocd"
require_file "$LIBUSB_SOURCE"
require_file "$LIBUSB_RECORDS_SOURCE/LICENSE-LGPL-2.1.txt"
require_file "$LIBUSB_RECORDS_SOURCE/README.md"
require_file "$NATIVE_SOURCE/oocd/scripts/target/artery/at32f4x_race.cfg"
require_file "$NATIVE_SOURCE/special/rdp/rdp_check.sh"
require_file "$NATIVE_SOURCE/special/rdp/rescue_unlock.sh"

PUBSPEC_VERSION="$(
  awk '/^version:/ { split($2, parts, "+"); print parts[1]; exit }' \
    "$ROOT_DIR/pubspec.yaml"
)"
THEME_VERSION="$(
  sed -n "s/^const kAppVersion = '\\([^']*\\)';/\\1/p" \
    "$ROOT_DIR/lib/theme.dart"
)"

[[ "$PUBSPEC_VERSION" == "$VERSION" ]] ||
  fail "VERSION ($VERSION) does not match pubspec.yaml ($PUBSPEC_VERSION)"
[[ "$THEME_VERSION" == "$VERSION" ]] ||
  fail "VERSION ($VERSION) does not match lib/theme.dart ($THEME_VERSION)"

echo "== Building universal macOS release =="
(cd "$ROOT_DIR" && flutter build macos --release)

require_executable "$BUILD_APP/Contents/MacOS/$APP_NAME"

BUILT_VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$BUILD_APP/Contents/Info.plist"
)"
[[ "$BUILT_VERSION" == "$VERSION" ]] ||
  fail "Built app version ($BUILT_VERSION) does not match VERSION ($VERSION)"

BUILT_ICON_NAME="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' \
    "$BUILD_APP/Contents/Info.plist"
)"
[[ "$BUILT_ICON_NAME" == "$ICON_NAME" ]] ||
  fail "Built app icon ($BUILT_ICON_NAME) does not match $ICON_NAME"

BUILT_ICON_FILE="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
    "$BUILD_APP/Contents/Info.plist"
)"
[[ "$BUILT_ICON_FILE" == "$ICON_NAME" ]] ||
  fail "Built app icon file ($BUILT_ICON_FILE) does not match $ICON_NAME"
require_file "$BUILD_APP/Contents/Resources/$ICON_NAME.icns"

echo "== Assembling package =="
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"
ditto --norsrc "$BUILD_APP" "$PACKAGE_APP"

rm -rf "$PACKAGE_APP/Contents/MacOS/native"
mkdir -p "$NATIVE_DEST"
rsync -a --delete --exclude '.DS_Store' "$NATIVE_SOURCE/" "$NATIVE_DEST/"
mkdir -p "$LIBUSB_RECORDS_DEST"
cp "$LIBUSB_RECORDS_SOURCE/LICENSE-LGPL-2.1.txt" "$LIBUSB_RECORDS_DEST/"
cp "$LIBUSB_RECORDS_SOURCE/README.md" "$LIBUSB_RECORDS_DEST/"
chmod +x "$NATIVE_DEST/oocd/bin/openocd"
find "$NATIVE_DEST/special" -type f -name '*.sh' -exec chmod +x {} +

require_executable "$NATIVE_DEST/oocd/bin/openocd"
require_file "$LIBUSB_DEST"
require_file "$LIBUSB_RECORDS_DEST/LICENSE-LGPL-2.1.txt"
require_file "$LIBUSB_RECORDS_DEST/README.md"
require_file "$NATIVE_DEST/oocd/scripts/target/artery/at32f4x_race.cfg"
require_file "$NATIVE_DEST/special/rdp/rdp_check.sh"
require_file "$NATIVE_DEST/special/rdp/rescue_unlock.sh"

echo "== Verifying universal binaries =="
require_universal "$PACKAGE_APP/Contents/MacOS/$APP_NAME"
require_universal "$PACKAGE_APP/Contents/Frameworks/App.framework/App"
require_universal \
  "$PACKAGE_APP/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS"
require_universal "$NATIVE_DEST/oocd/bin/openocd"
while IFS= read -r dylib; do
  require_universal "$dylib"
done < <(find "$NATIVE_DEST/oocd/libexec" -type f -name '*.dylib' | sort)

echo "== Ad-hoc signing embedded backend and app =="
while IFS= read -r dylib; do
  codesign --force --sign - "$dylib"
done < <(find "$NATIVE_DEST/oocd/libexec" -type f -name '*.dylib' | sort)
codesign --force --sign - "$NATIVE_DEST/oocd/bin/openocd"
codesign --force --deep --sign - "$PACKAGE_APP"
codesign --verify --deep --strict "$PACKAGE_APP"

echo "== Parsing packaged Power-race config =="
"$NATIVE_DEST/oocd/bin/openocd" \
  -d0 \
  -s "$NATIVE_DEST/oocd/scripts" \
  -f target/artery/at32f4x_race.cfg \
  -c shutdown

echo "== Creating ZIP =="
rm -f "$OUTPUT_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_APP" "$OUTPUT_ZIP"

echo "== Package ready =="
echo "$PACKAGE_APP"
echo "$OUTPUT_ZIP"
shasum -a 256 "$OUTPUT_ZIP"
