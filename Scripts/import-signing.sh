#!/bin/bash
# CI only: imports the Developer ID identity and a provisioning profile, then hands the job
# TEAM_ID and PROFILE_UUID. Reads P12_BASE64, P12_PASSWORD and PROFILE_BASE64; see docs/signing.md.
set -euo pipefail

for NAME in P12_BASE64 P12_PASSWORD PROFILE_BASE64; do
    if [ -z "${!NAME:-}" ]; then
        echo "::error::$NAME is empty — set the release secrets per docs/signing.md"
        exit 1
    fi
done

KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"
P12="$RUNNER_TEMP/cert.p12"
PROFILE="$RUNNER_TEMP/tinycast.provisionprofile"
trap 'rm -f "$P12" "$PROFILE"' EXIT

echo "$P12_BASE64" | base64 --decode > "$P12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -A -T /usr/bin/codesign
# Lets codesign use the key without an interactive prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# Prepended, so xcodebuild's codesign finds the identity here first.
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | sed 's/"//g')

echo "$PROFILE_BASE64" | base64 --decode > "$PROFILE"
DECODED="$(security cms -D -i "$PROFILE")"
UUID="$(plutil -extract UUID raw -o - - <<< "$DECODED")"
TEAM="$(plutil -extract TeamIdentifier.0 raw -o - - <<< "$DECODED")"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$PROFILES"
cp "$PROFILE" "$PROFILES/$UUID.provisionprofile"

{
    echo "TEAM_ID=$TEAM"
    echo "PROFILE_UUID=$UUID"
} >> "$GITHUB_ENV"
echo "✓ Developer ID for team $TEAM, profile $UUID"
