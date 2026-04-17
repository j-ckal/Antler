#!/bin/zsh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="${APP_NAME:-Antler}"
BUNDLE_ID="${BUNDLE_ID:-com.jack.antler}"
SCRATCH_PATH="${SCRATCH_PATH:-/tmp/antler-build}"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
APP_DIR="${APP_DIR:-$ROOT_DIR/dist/$APP_NAME.app}"
ZIP_PATH="${ZIP_PATH:-$ROOT_DIR/dist/$APP_NAME.zip}"
ICON_SOURCE="${ICON_SOURCE:-$ROOT_DIR/deer.png}"
KEYCHAIN_PATH="${KEYCHAIN_PATH:-}"
DEVELOPER_ID_APP_CERT="${DEVELOPER_ID_APP_CERT:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-antler-notary}"
NOTARIZE="${NOTARIZE:-1}"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/antler-release.XXXXXX")
NOTARY_ZIP="$TEMP_DIR/$APP_NAME-notary.zip"

cleanup() {
  rm -rf "$TEMP_DIR"
}

die() {
  echo "$*" >&2
  exit 1
}

trap cleanup EXIT

find_identity_args=(security find-identity -v -p codesigning)
if [[ -n "$KEYCHAIN_PATH" ]]; then
  find_identity_args+=("$KEYCHAIN_PATH")
fi

available_identities="$("${find_identity_args[@]}")"

if [[ -z "$DEVELOPER_ID_APP_CERT" ]]; then
  developer_id_identities=("${(@f)$(printf '%s\n' "$available_identities" | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p')}")
  if (( ${#developer_id_identities[@]} == 0 )); then
    die "No Developer ID Application certificate found in keychain. Import one into Keychain Access or set DEVELOPER_ID_APP_CERT explicitly."
  fi
  if (( ${#developer_id_identities[@]} > 1 )); then
    printf 'Multiple Developer ID Application certificates found:\n' >&2
    printf '  %s\n' "${developer_id_identities[@]}" >&2
    die "Set DEVELOPER_ID_APP_CERT to the certificate you want to use."
  fi
  DEVELOPER_ID_APP_CERT="${developer_id_identities[1]}"
elif ! printf '%s\n' "$available_identities" | grep -F "\"$DEVELOPER_ID_APP_CERT\"" >/dev/null; then
  die "Developer ID certificate not found in keychain: $DEVELOPER_ID_APP_CERT"
fi

if [[ "$NOTARIZE" != "0" && -z "$NOTARY_PROFILE" ]]; then
  die "NOTARY_PROFILE is required when NOTARIZE is enabled."
fi

mkdir -p "$(dirname "$APP_DIR")" "$(dirname "$ZIP_PATH")"

SIGN_IDENTITY="" \
BUNDLE_ID="$BUNDLE_ID" \
BUILD_CONFIG="$BUILD_CONFIG" \
SCRATCH_PATH="$SCRATCH_PATH" \
APP_DIR="$APP_DIR" \
ICON_SOURCE="$ICON_SOURCE" \
"$ROOT_DIR/Scripts/build-app.sh"

codesign_args=(
  codesign
  --force
  --sign "$DEVELOPER_ID_APP_CERT"
  --identifier "$BUNDLE_ID"
  --options runtime
  --timestamp
)

if [[ -n "$KEYCHAIN_PATH" ]]; then
  codesign_args+=(--keychain "$KEYCHAIN_PATH")
fi

"${codesign_args[@]}" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [[ "$NOTARIZE" != "0" ]]; then
  ditto -c -k --keepParent "$APP_DIR" "$NOTARY_ZIP"

  notarytool_args=(
    xcrun notarytool submit "$NOTARY_ZIP"
    --keychain-profile "$NOTARY_PROFILE"
    --wait
  )

  if [[ -n "$KEYCHAIN_PATH" ]]; then
    notarytool_args+=(--keychain "$KEYCHAIN_PATH")
  fi

  "${notarytool_args[@]}"
  xcrun stapler staple -v "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  spctl --assess --type exec --verbose=4 "$APP_DIR"
fi

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo "Built signed app bundle at $APP_DIR"
echo "Built release archive at $ZIP_PATH"
