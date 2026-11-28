#!/bin/sh
# Generates JarvisPhone.xcodeproj for your own Apple account.
#   JARVIS_TEAM_ID    your team id (Xcode → Settings → Accounts, or developer.apple.com → Membership)
#   JARVIS_BUNDLE_ID  optional, defaults to dev.<your user name>.jarvis
set -eu
cd "$(dirname "$0")"
: "${JARVIS_TEAM_ID:?Set JARVIS_TEAM_ID to your Apple team id, e.g. JARVIS_TEAM_ID=ABCDE12345 ./generate.sh}"
JARVIS_BUNDLE_ID="${JARVIS_BUNDLE_ID:-dev.$(id -un | tr -cd 'a-zA-Z0-9-').jarvis}"
export JARVIS_TEAM_ID JARVIS_BUNDLE_ID
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
xcodegen
echo "Bundle id: $JARVIS_BUNDLE_ID. Open JarvisPhone.xcodeproj, pick your iPhone and press ⌘R."
