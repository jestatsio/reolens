#!/bin/sh
# Build the universal (arm64 + x86_64) `reolens-cli` release tarball.
#
# Output: dist/reolens-cli-<version>-macos-universal.tar.gz
#
# The binary is linker-signed (ad-hoc) only — it is NOT Developer ID
# signed or notarized yet, so a downloaded copy needs
# `xattr -d com.apple.quarantine reolens-cli` on first run (documented
# in docs/cli-mcp.md). Notarized distribution needs a Developer ID
# Application certificate in CI secrets; tracked as a follow-up.
set -eu
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" App/Info.plist)
echo "==> Building reolens-cli ${VERSION} (universal)"
swift build -c release --product reolens-cli --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --product reolens-cli --arch arm64 --arch x86_64 --show-bin-path)
BIN="${BIN_DIR}/reolens-cli"
test -x "${BIN}"
file "${BIN}"
"${BIN}" version

mkdir -p dist
TARBALL="dist/reolens-cli-${VERSION}-macos-universal.tar.gz"
tar -czf "${TARBALL}" -C "${BIN_DIR}" reolens-cli
echo "==> Wrote ${TARBALL}"
