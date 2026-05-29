#!/usr/bin/env bash
# Build, archive, and (optionally) upload the native macOS Reolens app to
# the Mac App Store (TestFlight). Mirror of Scripts/build-ios.sh for the
# ReolensMac scheme — it ships under the SAME App Store Connect record as
# the iOS app (shared bundle id com.reolens.Reolens), so iOS + macOS are
# one multiplatform app.
#
# Usage:
#   Scripts/build-mac.sh archive   # archive only, no upload
#   Scripts/build-mac.sh upload    # archive + export .pkg + upload to ASC
#
# Required env when uploading (or archiving with manual signing):
#   AC_API_KEY_ID       — ASC API key id (10-char)
#   AC_API_ISSUER_ID    — issuer UUID
#   AC_API_KEY_P8_PATH  — path to .p8 private key
#                         OR AC_API_KEY_P8_BASE64 with its base64 (or PEM)
#   TEAM_ID             — 10-char Apple Developer team id (defaults below)
#
# macOS App Store uploads need TWO signing identities in the keychain:
#   • "Apple Distribution"                — signs the .app (the same
#                                           unified cert iOS uses)
#   • "3rd Party Mac Developer Installer" — signs the .pkg installer
#   Override the installer identity via MAC_INSTALLER_IDENTITY if your cert
#   is named differently.
#
# Bundle id defaults to project.yml; override via MAC_APP_BUNDLE_ID.

set -euo pipefail

MODE="${1:-archive}"
SCHEME="ReolensMac"
PROJECT_DIR="AppiOS"
PROJECT="${PROJECT_DIR}/ReolensiOS.xcodeproj"
BUILD_DIR="${BUILD_DIR:-build-mac}"
ARCHIVE_PATH="${BUILD_DIR}/ReolensMac.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TEAM_ID="${TEAM_ID:-5M9UT7VQ8Q}"
MAC_APP_BUNDLE_ID="${MAC_APP_BUNDLE_ID:-com.reolens.Reolens}"
MAC_INSTALLER_IDENTITY="${MAC_INSTALLER_IDENTITY:-3rd Party Mac Developer Installer}"
export MAC_APP_BUNDLE_ID

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required (brew install xcodegen)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the ASC API key once so both `archive` and `upload` modes can pass
# it to xcodebuild for cert / profile fetch, and so the upload step can stage
# it where `altool` expects. Mirrors Scripts/build-ios.sh.
AC_AUTH_FLAGS=()
AC_KEY_TMPDIR=""
if [[ -z "${AC_API_KEY_P8_PATH:-}" && -n "${AC_API_KEY_P8_BASE64:-}" && -n "${AC_API_KEY_ID:-}" ]]; then
    AC_KEY_TMPDIR=$(mktemp -d)
    export AC_API_KEY_P8_PATH="${AC_KEY_TMPDIR}/AuthKey_${AC_API_KEY_ID}.p8"
    # Accept either raw PEM (begins with -----BEGIN) or base64; auto-detect.
    if printf '%s' "${AC_API_KEY_P8_BASE64}" | head -n 1 | grep -q '^-----BEGIN'; then
        printf '%s\n' "${AC_API_KEY_P8_BASE64}" > "${AC_API_KEY_P8_PATH}"
    else
        printf '%s' "${AC_API_KEY_P8_BASE64}" | base64 -D > "${AC_API_KEY_P8_PATH}"
    fi
    trap 'rm -rf "${AC_KEY_TMPDIR}"' EXIT
fi
[[ -n "${AC_API_KEY_ID:-}" ]] && export AC_API_KEY_ID
[[ -n "${AC_API_ISSUER_ID:-}" ]] && export AC_API_ISSUER_ID
[[ -n "${AC_API_KEY_P8_PATH:-}" ]] && export AC_API_KEY_P8_PATH
if [[ -n "${AC_API_KEY_ID:-}" && -n "${AC_API_ISSUER_ID:-}" && -n "${AC_API_KEY_P8_PATH:-}" ]]; then
    AC_AUTH_FLAGS=(
        "-authenticationKeyID" "${AC_API_KEY_ID}"
        "-authenticationKeyIssuerID" "${AC_API_ISSUER_ID}"
        "-authenticationKeyPath" "${AC_API_KEY_P8_PATH}"
    )
    echo "==> Using ASC API key ${AC_API_KEY_ID} for signing"

    # Pre-flight: hit a cheap ASC API endpoint to confirm the key is
    # valid AND has enough role to manage provisioning, before spending
    # ~45 min on archive. Mirrors Scripts/build-ios.sh — xcodebuild's
    # generic "Authentication failed: bearer token..." uses the same
    # wording for "wrong API (Developer vs ASC)" and "role too low".
    if command -v python3 >/dev/null 2>&1; then
        PREFLIGHT_SCRIPT=$(mktemp -t asc-preflight.py.XXXXXX)
        cat > "${PREFLIGHT_SCRIPT}" <<'PY'
import os, sys, time, urllib.request, urllib.error

key_id = os.environ["AC_API_KEY_ID"]
issuer_id = os.environ["AC_API_ISSUER_ID"]
p8_path = os.environ["AC_API_KEY_P8_PATH"]

try:
    import jwt
except ImportError:
    sys.stderr.write("    (skipping pre-flight: pip3 install pyjwt cryptography)\n")
    sys.exit(0)

with open(p8_path, "rb") as f:
    key = f.read()

token = jwt.encode(
    {"iss": issuer_id, "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
    key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"},
)

def hit(path):
    req = urllib.request.Request(
        "https://api.appstoreconnect.apple.com/v1/" + path + "?limit=1",
        headers={"Authorization": "Bearer " + token},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "ignore")[:200]

apps_status, apps_err = hit("apps")
if apps_status != 200:
    sys.stderr.write("    pre-flight: /v1/apps returned %s\n" % apps_status)
    if apps_err:
        sys.stderr.write("    " + apps_err + "\n")
    sys.exit(2)

profiles_status, profiles_err = hit("profiles")
if profiles_status != 200:
    sys.stderr.write("    pre-flight: /v1/apps OK, /v1/profiles returned %s\n" % profiles_status)
    sys.stderr.write("    Key is valid but under-privileged (Admin role required).\n")
    if profiles_err:
        sys.stderr.write("    " + profiles_err + "\n")
    sys.exit(3)

print("    pre-flight: /v1/apps + /v1/profiles both OK")
PY
        set +e
        python3 "${PREFLIGHT_SCRIPT}"
        PREFLIGHT_RC=$?
        set -e
        rm -f "${PREFLIGHT_SCRIPT}"
        if [[ ${PREFLIGHT_RC} -ne 0 ]]; then
            echo "" >&2
            echo "    Likely fixes:" >&2
            echo "      - Key isn't an ASC API key. Create one at" >&2
            echo "        https://appstoreconnect.apple.com/access/api" >&2
            echo "        (NOT developer.apple.com → Keys). Role: Admin." >&2
            echo "      - Key role is below Admin. xcodebuild needs Admin" >&2
            echo "        to create/fetch provisioning profiles." >&2
            echo "      - .p8 contents are mangled. Re-download / regenerate." >&2
            exit ${PREFLIGHT_RC}
        fi
    fi
else
    echo "==> No ASC API key in env — falling back to Xcode's signed-in Apple ID"
fi

# ---------------------------------------------------------------------------
echo "==> Regenerating Xcode project from spec"
( cd "${PROJECT_DIR}" && xcodegen generate )

mkdir -p "${BUILD_DIR}"

# Pin App Store profiles to the local Apple Distribution cert's serial so a
# stale ASC profile attached to an old/revoked cert doesn't get picked.
if command -v security >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
    CERT_PEM="$(mktemp -t reolens-mac-dist-cert.XXXXXX)"
    if security find-certificate -c "Apple Distribution" -p > "${CERT_PEM}" 2>/dev/null; then
        CERT_SERIAL="$(
            openssl x509 -in "${CERT_PEM}" -noout -serial 2>/dev/null \
                | sed 's/^serial=//' \
                | tr '[:lower:]' '[:upper:]' \
                | tr -d ':'
        )"
        if [[ -n "${CERT_SERIAL}" ]]; then
            export ASC_CERT_SERIAL_NUMBER="${CERT_SERIAL}"
            echo "==> Pinning App Store profiles to Apple Distribution cert serial ${ASC_CERT_SERIAL_NUMBER}"
        fi
    fi
    rm -f "${CERT_PEM}"
fi

# ---------------------------------------------------------------------------
# Pre-create the Mac App Store profile for the main app. The macOS target has
# no embedded extensions (widgets deferred), so unlike build-ios.sh this is a
# single profile. Idempotent — safe to run on every build.
APP_PROFILE_NAME=""
APP_PROFILE_UUID=""
if [[ -n "${AC_API_KEY_ID:-}" && -n "${AC_API_KEY_P8_PATH:-}" ]]; then
    echo "==> Ensuring Mac App Store provisioning profile via ASC API"
    export PLATFORM=MAC_APP_STORE
    export PROFILE_NAME="${MAC_APP_PROFILE_NAME:-Reolens Mac App Store}"
    HELPER_OUT="$(python3 "${REPO_ROOT}/Scripts/asc_ensure_profile.py")"
    APP_PROFILE_NAME="$(printf '%s\n' "${HELPER_OUT}" | sed -n '1p')"
    APP_PROFILE_UUID="$(printf '%s\n' "${HELPER_OUT}" | sed -n '3p')"
    echo "    using mac-app profile: ${APP_PROFILE_NAME} (${APP_PROFILE_UUID})"
fi

# ---------------------------------------------------------------------------
SIGN_BUILD_SETTINGS=()
if [[ -n "${APP_PROFILE_NAME}" ]]; then
    SIGN_BUILD_SETTINGS=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=Apple Distribution"
        "DEVELOPMENT_TEAM=${TEAM_ID}"
        "REOLENS_MAC_APP_PROFILE_NAME=${APP_PROFILE_NAME}"
        "REOLENS_MAC_APP_PROFILE_UUID=${APP_PROFILE_UUID}"
    )
else
    SIGN_BUILD_SETTINGS=("CODE_SIGN_IDENTITY=Apple Distribution")
fi

XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}"
XCODEBUILD="${XCODE_DEVELOPER_DIR}/usr/bin/xcodebuild"
echo "==> Using xcodebuild at: ${XCODEBUILD}"

echo "==> Archiving for macOS"
"${XCODEBUILD}" \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -sdk macosx \
    -destination 'generic/platform=macOS' \
    -archivePath "${ARCHIVE_PATH}" \
    -allowProvisioningUpdates \
    ${AC_AUTH_FLAGS[@]+"${AC_AUTH_FLAGS[@]}"} \
    "${SIGN_BUILD_SETTINGS[@]}" \
    archive

if [[ "${MODE}" == "archive" ]]; then
    echo "==> Archive ready: ${ARCHIVE_PATH}"
    echo "    Open Xcode → Window → Organizer → Distribute App to upload."
    exit 0
fi

# ---------------------------------------------------------------------------
echo "==> Writing ExportOptions.plist"
EXPORT_APP_PROFILE="${APP_PROFILE_UUID:-${APP_PROFILE_NAME:-Reolens Mac App Store}}"

cat > "${EXPORT_OPTIONS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Apple Distribution</string>
    <key>installerSigningCertificate</key>
    <string>${MAC_INSTALLER_IDENTITY}</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>${MAC_APP_BUNDLE_ID}</key>
        <string>${EXPORT_APP_PROFILE}</string>
    </dict>
    <key>uploadSymbols</key>
    <true/>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Exporting .pkg"
"${XCODEBUILD}" \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    -allowProvisioningUpdates \
    ${AC_AUTH_FLAGS[@]+"${AC_AUTH_FLAGS[@]}"}

PKG=$(find "${EXPORT_DIR}" -maxdepth 1 -name '*.pkg' | head -n 1)
if [[ -z "${PKG}" ]]; then
    echo "error: no .pkg produced under ${EXPORT_DIR}" >&2
    exit 1
fi
echo "==> Exported: ${PKG}"

if [[ -z "${AC_API_KEY_ID:-}" || -z "${AC_API_ISSUER_ID:-}" || -z "${AC_API_KEY_P8_PATH:-}" ]]; then
    echo "error: set AC_API_KEY_ID, AC_API_ISSUER_ID, and AC_API_KEY_P8_BASE64 to upload" >&2
    exit 1
fi

# `xcrun altool` ignores --apiKeyPath; stage the key where it looks.
ALTOOL_KEY_DIR="${HOME}/.appstoreconnect/private_keys"
mkdir -p "${ALTOOL_KEY_DIR}"
ALTOOL_KEY_PATH="${ALTOOL_KEY_DIR}/AuthKey_${AC_API_KEY_ID}.p8"
cp "${AC_API_KEY_P8_PATH}" "${ALTOOL_KEY_PATH}"
chmod 600 "${ALTOOL_KEY_PATH}"
trap 'rm -f "${ALTOOL_KEY_PATH}"; rm -rf "${AC_KEY_TMPDIR}"' EXIT

echo "==> Uploading to App Store Connect (TestFlight)"
set +e
ALTOOL_OUTPUT=$(xcrun altool \
    --upload-app \
    --type macos \
    --file "${PKG}" \
    --apiKey "${AC_API_KEY_ID}" \
    --apiIssuer "${AC_API_ISSUER_ID}" 2>&1)
ALTOOL_RC=$?
set -e
printf '%s\n' "${ALTOOL_OUTPUT}"
if [[ ${ALTOOL_RC} -ne 0 ]] || \
   printf '%s\n' "${ALTOOL_OUTPUT}" | grep -Eq 'UPLOAD FAILED|Validation failed|Failed to upload package|STATE_ERROR'; then
    echo "error: App Store Connect upload failed" >&2
    exit 1
fi

echo "==> Upload complete. TestFlight processing typically takes 10-30 minutes."
echo "    Track progress at: https://appstoreconnect.apple.com/apps"
