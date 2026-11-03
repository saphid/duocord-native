#!/bin/zsh
# Build a development-signed Duocord Native, install it on a connected device,
# and optionally hand it the Discord login so it signs itself in once.
#
#   scripts/install-device.sh <device-udid>
#   CONFIG=Release PROVISION_LOGIN=1 scripts/install-device.sh <device-udid>
#
# With PROVISION_LOGIN=1 the login is read from 1Password (op-agent) into a
# 0600 temp file, copied into the app's Documents folder, and deleted. The app
# moves it into its Keychain on next launch, deletes its copy, and signs in
# through Discord's own login page once. The file also records that the owner
# has read the account-risk notice (Discord's terms don't allow third-party
# clients using a user token).
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.2.0.app/Contents/Developer}"
DEVICE="${1:?usage: install-device.sh <device-udid>}"
CONFIG="${CONFIG:-Release}"
TEAM_ID="${TEAM_ID:-NJZUMEA4BN}"
ASC_CONFIG="${ASC_CONFIG:-$HOME/.appstoreconnect/frame-control.json}"
DISCORD_ITEM="${DISCORD_ITEM:-op://Apps/is6djixjkwp4l5xahyh4ggopeu}"
BUNDLE_ID=com.saphid.duocord

read -r key_id issuer_id key_path < <(python3 -c "
import json, sys
c = json.load(open(sys.argv[1]))
print(c['key_id'], c['issuer_id'], c['key_path'])" "$ASC_CONFIG")

cd "${0:A:h}/.."
xcodegen generate
xcodebuild build -project DuocordNative.xcodeproj -scheme DuocordNative -configuration "$CONFIG" \
  -destination "platform=iOS,id=$DEVICE" -derivedDataPath build/DeviceDerivedData \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -authenticationKeyPath "$key_path" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer_id"

app="build/DeviceDerivedData/Build/Products/$CONFIG-iphoneos/DuocordNative.app"
xcrun devicectl device install app --device "$DEVICE" "$app"

if [[ "${PROVISION_LOGIN:-0}" == 1 ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  ( umask 077
    DISCORD_EMAIL="$DISCORD_ITEM/username" DISCORD_PASSWORD="$DISCORD_ITEM/password" \
      op-agent run --no-masking -- python3 -c "
import json, os, sys
json.dump({'email': os.environ['DISCORD_EMAIL'], 'password': os.environ['DISCORD_PASSWORD'],
           'acknowledgeRisk': True}, open(sys.argv[1], 'w'))
" "$tmp/duocord-provision.json" ) >/dev/null
  xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --source "$tmp/duocord-provision.json" \
    --destination Documents/duocord-provision.json >/dev/null
  echo "Login handed to the app; it signs in through Discord's login page on next launch."
fi

xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID"
