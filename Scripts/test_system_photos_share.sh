#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 SIMULATOR_UDID [OUTPUT_DIRECTORY]" >&2
    exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
simulator_id="$1"
output_directory="${2:-$(mktemp -d "${TMPDIR:-/tmp}/tesserae-photos-share.XXXXXX")}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"

# Use a dedicated booted simulator with Photos' first-run setup completed.
# Seeding adds only synthetic media; it never erases the existing library.
xcrun simctl addmedia "$simulator_id" \
    "$repo_root/Scripts/Fixtures/LivePhoto/Sample.jpg" \
    "$repo_root/Scripts/Fixtures/LivePhoto/Sample.mov"

cd "$repo_root"
echo "Photos Share test results: $output_directory/PhotosShare.xcresult"
xcodebuild \
    -project TesseraeCompanion.xcodeproj \
    -scheme TesseraeCompanion \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$output_directory/build" \
    -resultBundlePath "$output_directory/PhotosShare.xcresult" \
    -parallel-testing-enabled NO \
    -only-testing:TesseraeCompanionUITests/MediaFrameUITests/testSystemPhotosLivePhotoAutomaticallyShowsTimeline \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG TESSERAE_SYSTEM_PHOTOS_TESTS' \
    CODE_SIGNING_ALLOWED=NO \
    test
