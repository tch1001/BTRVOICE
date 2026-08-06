#!/bin/bash
# Builds BtrVoice.app from the SwiftPM executable.
#
# SwiftPM can't emit an .app bundle, and macOS won't hand out microphone or
# accessibility permission to a bare executable, so the bundle is assembled here.
#
#   ./build.sh                 release build
#   ./build.sh --debug         debug build
#   ./build.sh --run           build, then relaunch the app
#   ./build.sh --clean         rebuild the bundle from scratch
#   SIGN_ID="Developer ID Application: …" ./build.sh
#
# Signing and permissions: an ad-hoc signature ties the Accessibility grant to the
# binary's hash, so every rebuild looks like a new program and the grant silently
# stops applying. Run tools/make-signing-cert.sh once and this script will use that
# stable identity instead, so you only grant Accessibility a single time.

set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
RUN=0
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="debug" ;;
        --release) CONFIG="release" ;;
        --run) RUN=1 ;;
        --clean) CLEAN=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

APP_NAME="BtrVoice"
BUNDLE_ID="com.btr.voice"
LOCAL_IDENTITY="BtrVoice Local Signing"
DEST="build/${APP_NAME}.app"

# Prefer an explicit SIGN_ID, then the local stable identity, then ad-hoc.
if [[ -z "${SIGN_ID:-}" ]]; then
    hash="$(security find-identity 2>/dev/null | grep -F "$LOCAL_IDENTITY" | head -1 | awk '{print $2}' || true)"
    if [[ -n "$hash" ]]; then
        SIGN_ID="$hash"
        SIGN_LABEL="$LOCAL_IDENTITY"
    else
        SIGN_ID="-"
        SIGN_LABEL="ad-hoc"
    fi
else
    SIGN_LABEL="$SIGN_ID"
fi

echo "==> Compiling (${CONFIG})"
swift build -c "$CONFIG" --disable-sandbox

BIN="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN" ]]; then
    echo "build produced no executable at ${BIN}" >&2
    exit 1
fi

echo "==> Assembling ${DEST}"
# Updated in place rather than deleted and recreated: TCC keys its grants partly on
# the bundle itself, and replacing the directory wholesale orphans them.
[[ "$CLEAN" == "1" ]] && rm -rf "$DEST"
mkdir -p "${DEST}/Contents/MacOS" "${DEST}/Contents/Resources"
rm -rf "${DEST}/Contents/_CodeSignature"
cp "$BIN" "${DEST}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${DEST}/Contents/Info.plist"
printf 'APPL????' > "${DEST}/Contents/PkgInfo"

echo "==> Signing (identity: ${SIGN_LABEL})"
# A running copy holds its bundle open; replacing the signature under it fails.
pkill -x "$APP_NAME" 2>/dev/null || true
codesign --force --sign "$SIGN_ID" \
    --identifier "$BUNDLE_ID" \
    --entitlements Resources/BtrVoice.entitlements \
    --timestamp=none \
    "$DEST" >/dev/null

codesign --verify --verbose=1 "$DEST" 2>&1 | sed 's/^/    /'

if [[ "$SIGN_ID" == "-" ]]; then
    echo
    echo "    Signed ad-hoc, so macOS will forget the Accessibility grant on the next"
    echo "    rebuild. Run tools/make-signing-cert.sh once to stop that happening."
    echo
fi

echo "==> Built $(cd "$(dirname "$DEST")" && pwd)/$(basename "$DEST")"

if [[ "$RUN" == "1" ]]; then
    echo "==> Launching"
    open "$DEST"
fi
