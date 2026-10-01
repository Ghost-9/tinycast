#!/bin/bash
# Imports Scripts/cloudkit/schema.ckdb into one channel's container. See docs/features/icloud-sync.md.
#
# Usage: deploy-schema.sh <bundle-id> [development|production]
# Needs TINYCAST_TEAM_ID, and a management token saved once with `xcrun cktool save-token`.
set -euo pipefail

BUNDLE_ID="${1:?usage: deploy-schema.sh <bundle-id> [development|production]}"
ENVIRONMENT="${2:-development}"
case "$ENVIRONMENT" in
    development | production) ;;
    *) echo "✗ the environment is development or production" >&2; exit 1 ;;
esac
TEAM_ID="${TINYCAST_TEAM_ID:?set TINYCAST_TEAM_ID to the Apple Developer team}"
CONTAINER_ID="iCloud.$BUNDLE_ID"
SCHEMA="$(cd "$(dirname "$0")" && pwd)/schema.ckdb"

ARGS=(--team-id "$TEAM_ID" --container-id "$CONTAINER_ID" --environment "$ENVIRONMENT")
xcrun cktool validate-schema "${ARGS[@]}" --file "$SCHEMA"
xcrun cktool import-schema "${ARGS[@]}" --file "$SCHEMA"
echo "✓ $CONTAINER_ID ($ENVIRONMENT) has the sync schema"
