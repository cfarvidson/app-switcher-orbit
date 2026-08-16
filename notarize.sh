#!/bin/bash
set -euo pipefail

# Notarize the Release app already copied to ./Orbit.app by ./build.sh.
# Credentials: one-time
#   xcrun notarytool store-credentials orbit-notary --apple-id <id> --team-id D3LY7SL2HW
# (uses an app-specific password from appleid.apple.com)

APP="Orbit.app"
PROFILE="${NOTARY_PROFILE:-orbit-notary}"
ZIP="Orbit-notarize.zip"

if [ ! -d "$APP" ]; then
    echo "Missing $APP. Run ./build.sh first."
    exit 1
fi

echo "Zipping $APP..."
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple notary service (profile: $PROFILE)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling ticket..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "Gatekeeper check..."
spctl -a -vv "$APP"

rm -f "$ZIP"
echo "Notarized. Zip a fresh Orbit-X.Y.Z.zip from this Orbit.app for the GitHub release."
