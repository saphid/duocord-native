#!/bin/zsh
# Archive Duocord Native as an update to the existing Duocord TestFlight app.
#
#   scripts/testflight.sh                     # archive + upload
#   DESTINATION=export scripts/testflight.sh  # archive + local .ipa only
#
# Needs the app record in App Store Connect and the API key described by
# ASC_CONFIG (default ~/.appstoreconnect/frame-control.json: key_id,
# issuer_id, key_path). Build numbers are UTC timestamps, so they always
# increase. DEVELOPER_DIR defaults to Xcode 27.2 (iOS 27.2 SDK).
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.2.0.app/Contents/Developer}"
TEAM_ID="${TEAM_ID:-NJZUMEA4BN}"
DESTINATION="${DESTINATION:-upload}"
ASC_CONFIG="${ASC_CONFIG:-$HOME/.appstoreconnect/frame-control.json}"
[[ "$DESTINATION" == upload || "$DESTINATION" == export ]] \
  || { echo "DESTINATION must be upload or export" >&2; exit 64; }

read -r key_id issuer_id key_path < <(python3 -c "
import json, sys
c = json.load(open(sys.argv[1]))
print(c['key_id'], c['issuer_id'], c['key_path'])" "$ASC_CONFIG")
[[ -f "$key_path" ]] || { echo "no API key at $key_path" >&2; exit 1; }
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key_path"
      -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer_id")

cd "${0:A:h}/.."
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
out="build/testflight/$BUILD_NUMBER"
archive="$out/DuocordNative.xcarchive"
mkdir -p "$out"
out="${out:A}"
archive="$out/DuocordNative.xcarchive"
build_wrapper="$HOME/.codex/skills/xcode-simulator/scripts/run-xcodebuild-clean.sh"
[[ -x "$build_wrapper" ]] || { echo "Xcode build wrapper is unavailable" >&2; exit 1; }

xcodegen generate
"$build_wrapper" --lane non-t3 -- archive -project DuocordNative.xcodeproj -scheme DuocordNative \
  -configuration Release -destination generic/platform=iOS \
  -archivePath "$archive" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${auth[@]}"

# Check what was archived, not just the arguments passed.
plist="$archive/Products/Applications/DuocordNative.app/Info.plist"
archived=$(plutil -extract CFBundleVersion raw "$plist")
[[ "$archived" == "$BUILD_NUMBER" ]] || { echo "archived build $archived, expected $BUILD_NUMBER" >&2; exit 1; }
[[ "$(plutil -extract CFBundleIdentifier raw "$plist")" == com.saphid.duocord ]] \
  || { echo "unexpected bundle identifier" >&2; exit 1; }
[[ "$(plutil -extract CFBundleDisplayName raw "$plist")" == "Duocord Native" ]] \
  || { echo "unexpected launcher name" >&2; exit 1; }
extension="$archive/Products/Applications/DuocordNative.app/PlugIns/DuocordNativeLiveActivity.appex/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw "$extension")" == com.saphid.duocord.LiveActivity ]] \
  || { echo "unexpected extension identifier" >&2; exit 1; }
[[ "$(plutil -extract CFBundleVersion raw "$extension")" == "$BUILD_NUMBER" ]] \
  || { echo "unexpected extension build number" >&2; exit 1; }
echo "Archived Duocord $(plutil -extract CFBundleShortVersionString raw "$plist") ($archived)"

cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
  <key>testFlightInternalTestingOnly</key><true/>
</dict></plist>
EOF

xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist "$out/ExportOptions.plist" -exportPath "$out/export" "${auth[@]}"

if [[ "$DESTINATION" == export ]]; then
  echo "Exported $out/export/DuocordNative.ipa (build $BUILD_NUMBER). Nothing was uploaded."
else
  echo "Uploaded build $BUILD_NUMBER. It shows in TestFlight once App Store Connect finishes processing."
fi
