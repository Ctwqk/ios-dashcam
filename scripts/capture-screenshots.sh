#!/usr/bin/env bash
# Boots a simulator, installs the Debug build of DashCam, launches it and saves screenshots.
#
# usage: scripts/capture-screenshots.sh <DerivedData dir used for the build> <output dir>
#
# The simulator has no camera, so the screenshots show the app's "camera unavailable"
# empty state, plus the Settings sheet (opened with the -showSettings launch argument).
set -euo pipefail

DERIVED_DATA="${1:?DerivedData dir}"
OUT_DIR="${2:?output dir}"
BUNDLE_ID="com.constructure.dashcam"
APP="${DERIVED_DATA}/Build/Products/Debug-iphonesimulator/DashCam.app"

UDID="$("$(dirname "$0")/sim-udid.sh")"
mkdir -p "${OUT_DIR}"

xcrun simctl boot "${UDID}" || true
xcrun simctl bootstatus "${UDID}" -b
xcrun simctl install "${UDID}" "${APP}"

# Pre-grant what the simulator allows so no system alert covers the UI.
xcrun simctl privacy "${UDID}" grant photos-add "${BUNDLE_ID}" || true
xcrun simctl privacy "${UDID}" grant location "${BUNDLE_ID}" || true

xcrun simctl launch "${UDID}" "${BUNDLE_ID}"
sleep 6
xcrun simctl io "${UDID}" screenshot "${OUT_DIR}/main.png"

xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" || true
xcrun simctl launch "${UDID}" "${BUNDLE_ID}" -showSettings
sleep 6
xcrun simctl io "${UDID}" screenshot "${OUT_DIR}/settings.png"

xcrun simctl shutdown "${UDID}" || true
ls -l "${OUT_DIR}"
