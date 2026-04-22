#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
IOS_DIR="$ROOT_DIR/ios"
ARCHIVE_PATH="${1:-$ROOT_DIR/build/Nod-TestFlight.xcarchive}"
EXPORT_PATH="${2:-$ROOT_DIR/build/TestFlightUpload}"

mkdir -p "$(dirname "$ARCHIVE_PATH")"

cd "$IOS_DIR"
xcodegen generate

cd "$ROOT_DIR"
xcodebuild \
  -project ios/Nod.xcodeproj \
  -scheme Nod \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  -skipMacroValidation \
  archive

echo "Archive created at: $ARCHIVE_PATH"
echo "Open Xcode Organizer to upload it, or run:"
echo "xcodebuild -exportArchive -archivePath $ARCHIVE_PATH -exportPath $EXPORT_PATH -exportOptionsPlist $IOS_DIR/TestFlightExportOptions.plist -allowProvisioningUpdates"
