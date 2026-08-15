#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
APP_NAME="x3utils"
ARCH="x86_64"

BUNDLE_DIR="$ROOT_DIR/build/linux/x64/release/bundle"
APPDIR="$ROOT_DIR/build/appimage/${APP_NAME}.AppDir"
DIST_DIR="$ROOT_DIR/dist"
OUTPUT="$DIST_DIR/${APP_NAME}-${VERSION}-${ARCH}.AppImage"

find_appimagetool() {
  if [[ -n "${APPIMAGETOOL:-}" ]]; then
    printf '%s\n' "$APPIMAGETOOL"
    return
  fi

  if command -v appimagetool >/dev/null 2>&1; then
    command -v appimagetool
    return
  fi

  if [[ -x /tmp/appimagetool-x86_64.AppImage ]]; then
    printf '%s\n' /tmp/appimagetool-x86_64.AppImage
    return
  fi

  return 1
}

echo "== Building Linux release bundle =="
(cd "$ROOT_DIR" && flutter build linux --release)

if [[ ! -x "$BUNDLE_DIR/$APP_NAME" ]]; then
  echo "Release bundle executable not found: $BUNDLE_DIR/$APP_NAME" >&2
  exit 1
fi

echo "== Assembling AppDir =="
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" \
  "$APPDIR/native/linux" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/256x256/apps" \
  "$DIST_DIR"

cp -a "$BUNDLE_DIR/." "$APPDIR/usr/bin/"
cp -a "$ROOT_DIR/native/linux/oocd" "$APPDIR/native/linux/"
cp -a "$ROOT_DIR/native/linux/special" "$APPDIR/native/linux/"
cp "$ROOT_DIR/icon.png" "$APPDIR/${APP_NAME}.png"
cp "$ROOT_DIR/icon.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/${APP_NAME}.png"

cat > "$APPDIR/${APP_NAME}.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=x3utils
Comment=ST-LINK utilities for X3 scooters
Exec=x3utils
Icon=x3utils
Categories=Utility;
Terminal=false
DESKTOP
cp "$APPDIR/${APP_NAME}.desktop" "$APPDIR/usr/share/applications/${APP_NAME}.desktop"

cat > "$APPDIR/AppRun" <<'APPRUN'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib:${LD_LIBRARY_PATH:-}"
cd "$HERE"
exec "$HERE/usr/bin/x3utils" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

chmod +x "$APPDIR/usr/bin/$APP_NAME"
chmod +x "$APPDIR/native/linux/oocd/bin/openocd"
find "$APPDIR/native/linux/special" -type f -name '*.sh' -exec chmod +x {} +

APPIMAGETOOL_BIN="$(find_appimagetool || true)"
if [[ -z "$APPIMAGETOOL_BIN" ]]; then
  cat >&2 <<'MSG'
appimagetool was not found.

Install it in PATH, or run with:
  APPIMAGETOOL=/path/to/appimagetool-x86_64.AppImage tool/build_appimage.sh

For this workstation, /tmp/appimagetool-x86_64.AppImage is also accepted.
MSG
  exit 2
fi

echo "== Creating AppImage =="
rm -f "$OUTPUT"
ARCH="$ARCH" APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGETOOL_BIN" "$APPDIR" "$OUTPUT"

echo "== Done =="
echo "$OUTPUT"
