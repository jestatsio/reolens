#!/usr/bin/env bash
#
# Deploy or export the CloudKit schema for the Reolens container.
#
# The exported file is the WHOLE container schema, not just one record
# type. As of 0.7.0 it covers:
#   - MotionEvent      — motion-relay notifications
#   - HubStatus        — Hub-offline heartbeat (0.7.0)
#   - CameraCredential — Apple TV credential sync (0.7.0); its `password`
#                        field is ENCRYPTED. See CloudKit/README.md for the
#                        authoritative field/index/encryption spec.
#
# CloudKit has two schemas per container: Development auto-creates
# record types and fields the first time the app writes them;
# Production is locked and must be promoted explicitly. TestFlight,
# App Store, and Developer-ID-signed builds all hit Production, so a
# release that publishes a new field will silently fail on every prod
# device until the schema is promoted.
#
# This script wraps `xcrun cktool` so the deploy is reproducible
# without clicking through the CloudKit Console.
#
# Subcommands:
#   export   — dump the current Development schema to
#              CloudKit/schema.ckdb (committed; becomes the
#              source of truth for diffs)
#   push     — import the committed CloudKit/schema.ckdb into
#              CloudKit Development. Use this when you've added a
#              field locally (e.g. a new optional column on
#              MotionEvent) and need it in Dev so you can then
#              promote to Production. The release DMG hits Prod and
#              ad-hoc-signed dev builds drop iCloud, so the app
#              itself can't seed Dev — this is the codepath that
#              replaces the "build a dev-signed app and publish a
#              record" loop.
#   promote  — print the CloudKit Console steps to deploy Development →
#              Production. cktool CANNOT write the Production schema
#              (import-schema rejects the production environment, and there
#              is no clone/deploy command), so the deploy is Console-only.
#   diff     — export Dev to a temp file and `diff` it against the
#              committed CloudKit/schema.ckdb so you can see
#              what would change if you ran `export` now.
#
# Required environment:
#   CKTOOL_TEAM_ID    — 10-char Apple Developer team identifier
#   CKTOOL_CONTAINER  — typically "iCloud.com.reolens.Reolens"
#
# One-time auth (per machine):
#   xcrun cktool save-token --type management
#   # paste the token from https://icloud.developer.apple.com/dashboard
#
# Exit codes:
#   0 — success
#   1 — usage error
#   2 — missing prerequisites (cktool, env vars, schema file)
#   3 — cktool failure

set -euo pipefail

cd "$(dirname "$0")/.."

readonly SCHEMA_FILE="CloudKit/schema.ckdb"

usage() {
    cat <<'EOF'
Usage: Scripts/deploy-cloudkit-schema.sh <subcommand>

Subcommands:
  export   Dump CloudKit Development schema to CloudKit/schema.ckdb
  push     Import the committed .ckdb into CloudKit Development
  promote  Print Console steps to deploy Development → Production (cktool can't write Prod)
  diff     Show diff between live Development schema and committed file

Required env vars:
  CKTOOL_TEAM_ID    Apple Developer team ID
  CKTOOL_CONTAINER  CloudKit container, e.g. iCloud.com.reolens.Reolens

One-time auth: run `xcrun cktool save-token --type management` and paste a
token from https://icloud.developer.apple.com/dashboard.
EOF
}

require_cktool() {
    if ! xcrun --find cktool >/dev/null 2>&1; then
        echo "ERROR: xcrun cktool not found. Install Xcode command-line tools." >&2
        exit 2
    fi
}

require_env() {
    local missing=0
    if [[ -z "${CKTOOL_TEAM_ID:-}" ]]; then
        echo "ERROR: CKTOOL_TEAM_ID is not set." >&2
        missing=1
    fi
    if [[ -z "${CKTOOL_CONTAINER:-}" ]]; then
        echo "ERROR: CKTOOL_CONTAINER is not set (expected e.g. iCloud.com.reolens.Reolens)." >&2
        missing=1
    fi
    if [[ $missing -ne 0 ]]; then
        exit 2
    fi
}

cmd_export() {
    require_cktool
    require_env
    mkdir -p "$(dirname "$SCHEMA_FILE")"
    echo "Exporting Development schema for $CKTOOL_CONTAINER → $SCHEMA_FILE"
    xcrun cktool export-schema \
        --team-id "$CKTOOL_TEAM_ID" \
        --container-id "$CKTOOL_CONTAINER" \
        --environment DEVELOPMENT \
        --output-file "$SCHEMA_FILE" \
        || { echo "ERROR: cktool export-schema failed." >&2; exit 3; }
    echo "Wrote $SCHEMA_FILE."
    echo "Review the diff, then commit:"
    echo "  git diff -- $SCHEMA_FILE"
    echo "  git add $SCHEMA_FILE && git commit -m 'chore: snapshot CloudKit schema'"
}

cmd_push() {
    require_cktool
    require_env
    if [[ ! -f "$SCHEMA_FILE" ]]; then
        echo "ERROR: $SCHEMA_FILE not found. Run 'export' first, then edit it to add the new field." >&2
        exit 2
    fi
    echo "About to import schema:"
    echo "  container:    $CKTOOL_CONTAINER"
    echo "  team:         $CKTOOL_TEAM_ID"
    echo "  destination:  DEVELOPMENT"
    echo "  source file:  $SCHEMA_FILE"
    echo
    read -r -p "Proceed? [y/N] " reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
    xcrun cktool import-schema \
        --team-id "$CKTOOL_TEAM_ID" \
        --container-id "$CKTOOL_CONTAINER" \
        --environment DEVELOPMENT \
        --file "$SCHEMA_FILE" \
        || { echo "ERROR: cktool import-schema failed." >&2; exit 3; }
    echo "Development schema updated."
    echo "Next: Scripts/deploy-cloudkit-schema.sh promote   (Dev → Production)"
}

cmd_promote() {
    require_env
    # cktool (Xcode 26) CANNOT write the Production schema. `import-schema
    # --environment PRODUCTION` is rejected with "endpoint not applicable
    # in the environment 'production'", and there is no clone/deploy/promote
    # subcommand. The Development → Production deploy is Console-only — so
    # this command guides that, rather than failing on an impossible write.
    cat <<EOF
cktool cannot deploy this container's schema to Production:
  • import-schema rejects the production environment, and
  • there is no clone/deploy/promote subcommand.

Deploy Development → Production in the CloudKit Console:

  1. https://icloud.developer.apple.com/dashboard
  2. Container: $CKTOOL_CONTAINER  →  Schema
  3. "Deploy Schema Changes…"  →  Development to Production
  4. Review the diff — expect HubStatus + CameraCredential added, with
     CameraCredential.password marked Encrypted and a Queryable recordName
     index on both — then Deploy.

If the diff is empty or missing the new types, Development isn't seeded
yet: create them in the Console (Development env) or run a Debug build
that writes them, then deploy. See CloudKit/README.md.

To snapshot the current Development schema into the repo first:
  Scripts/deploy-cloudkit-schema.sh export
EOF
}

cmd_diff() {
    require_cktool
    require_env
    if [[ ! -f "$SCHEMA_FILE" ]]; then
        echo "ERROR: $SCHEMA_FILE not found. Run 'export' first." >&2
        exit 2
    fi
    local tmp
    tmp="$(mktemp -t reolens-ckschema.XXXXXX)"
    trap 'rm -f "$tmp"' EXIT
    xcrun cktool export-schema \
        --team-id "$CKTOOL_TEAM_ID" \
        --container-id "$CKTOOL_CONTAINER" \
        --environment DEVELOPMENT \
        --output-file "$tmp" \
        || { echo "ERROR: cktool export-schema failed." >&2; exit 3; }
    if diff -u "$SCHEMA_FILE" "$tmp"; then
        echo "No drift: live Development schema matches $SCHEMA_FILE."
    fi
}

if [[ $# -ne 1 ]]; then
    usage
    exit 1
fi

case "$1" in
    export)  cmd_export ;;
    push)    cmd_push ;;
    promote) cmd_promote ;;
    diff)    cmd_diff ;;
    -h|--help|help) usage ;;
    *)
        echo "ERROR: unknown subcommand '$1'." >&2
        usage
        exit 1
        ;;
esac
