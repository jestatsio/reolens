#!/usr/bin/env bash
#
# 0.5.0 CI gate (AGENTS.md §13): require that every shipping bundle
# declares the same MARKETING_VERSION before tagging. Catches the class
# of regression where someone bumps `App/Info.plist` but forgets
# `AppiOS/project.yml` (or vice-versa) and the released DMG + TestFlight
# build diverge.
#
# 0.7.0: the xcodegen spec now declares MARKETING_VERSION on FOUR targets
# (iOS app, Widgets, Notification Service, and the new tvOS app). The
# previous check read only the *first* `MARKETING_VERSION` and exited, so
# a mismatched tvOS (or extension) version would silently pass. This now
# compares the macOS plist against EVERY MARKETING_VERSION in the spec.
#
# Invoked from:
#   - `.github/workflows/ci.yml` on every PR + push (fail on drift).
#   - `.github/workflows/release.yml` as the first step before signing.
#
# Exit codes:
#   0 — all versions match
#   1 — drift detected (prints which)
#   2 — could not read a version source

set -euo pipefail

cd "$(dirname "$0")/.."

mac_plist="App/Info.plist"
ios_yml="AppiOS/project.yml"

if [[ ! -f "$mac_plist" ]]; then
    echo "ERROR: $mac_plist not found" >&2
    exit 2
fi
if [[ ! -f "$ios_yml" ]]; then
    echo "ERROR: $ios_yml not found" >&2
    exit 2
fi

mac_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$mac_plist" 2>/dev/null || true)
if [[ -z "$mac_version" ]]; then
    echo "ERROR: could not read CFBundleShortVersionString from $mac_plist" >&2
    exit 2
fi

# Every MARKETING_VERSION declared in the xcodegen spec. Splitting on the
# double-quote yields the quoted value as field 2. Portable on bash 3.2
# (the macOS system bash) — no mapfile / associative arrays.
ios_versions=$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/ {print $2}' "$ios_yml")
if [[ -z "$ios_versions" ]]; then
    echo "ERROR: no MARKETING_VERSION found in $ios_yml" >&2
    exit 2
fi

echo "macOS CFBundleShortVersionString: $mac_version"
mismatch=0
while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    if [[ "$v" == "$mac_version" ]]; then
        echo "  project.yml MARKETING_VERSION: $v  [OK]"
    else
        echo "  project.yml MARKETING_VERSION: $v  [MISMATCH]"
        mismatch=1
    fi
done <<< "$ios_versions"

if [[ "$mismatch" -ne 0 ]]; then
    cat >&2 <<EOF

ERROR: a MARKETING_VERSION in $ios_yml diverges from the macOS version.
  macOS ($mac_plist CFBundleShortVersionString): $mac_version

Bump every target's MARKETING_VERSION (iOS app, Widgets, Notification
Service, tvOS app) AND App/Info.plist together before tagging.
AGENTS.md §13: all platform versions must align on every release.
EOF
    exit 1
fi

echo "OK: all versions match ($mac_version)"
