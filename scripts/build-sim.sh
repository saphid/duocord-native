#!/bin/zsh
# Build the Debug app for the project's Duo simulator into build/DerivedData.
#   scripts/build-sim.sh            # build
#   scripts/build-sim.sh install    # build + install on build/duo-sim-udid
set -uo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.2.0.app/Contents/Developer}"
cd "${0:A:h}/.."
udid=$(cat build/duo-sim-udid)
config="${CONFIG:-Debug}"
xcodegen generate >/dev/null || exit 1
xcodebuild build -project DuocordNative.xcodeproj -scheme DuocordNative -configuration "$config" \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath build/DerivedData > build/build.log 2>&1
rc=$?
grep -E "error:" build/build.log | sort -u | head -n 40
if [[ $rc -ne 0 ]]; then echo "BUILD FAILED ($rc)"; exit $rc; fi
echo "BUILD OK ($(grep -c 'warning:' build/build.log) warning lines)"
if [[ "${1:-}" == install ]]; then
  xcrun simctl install "$udid" "build/DerivedData/Build/Products/$config-iphonesimulator/DuocordNative.app"
  rc=$?
  if [[ $rc -ne 0 ]]; then echo "INSTALL FAILED ($rc)"; exit $rc; fi
  echo "installed on $udid"
fi
if [[ "${1:-}" == install ]]; then
  xcrun simctl get_app_container "$udid" com.saphid.duocord data > build/app-data-path 2>/dev/null || true
fi
