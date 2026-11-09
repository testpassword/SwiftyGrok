#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Building the app requires macOS 14+ and Xcode 16+." >&2
    exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo "Build and run tests from a native Apple Silicon shell (arm64)." >&2
    exit 1
fi
if ! xcrun --find xcodebuild >/dev/null 2>&1; then
    echo "Install Xcode 16+ and select Command Line Tools in Xcode > Settings > Locations." >&2
    exit 1
fi

build_dir="build"
app_path="$build_dir/SwiftyGrok.app"
staged_app="$build_dir/package/SwiftyGrok.app"

echo "Running tests..."
swift test --arch arm64 --scratch-path "$build_dir/swiftpm"

echo "Building the Apple Silicon (arm64) Release app..."
# Remove the retired Finder Sync plug-in from an older cached product before
# Xcode embeds and signs the replacement Share Extension.
rm -rf "$build_dir/xcode/Build/Products/Release/SwiftyGrok.app/Contents/PlugIns/SwiftyGrokFinder.appex"
xcodebuild -project SwiftyGrok.xcodeproj -scheme SwiftyGrok -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$build_dir/xcode" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build

# Verify a fresh bundle before replacing the previous app. This also prevents
# resources removed from the project from remaining in the packaged app.
echo "Packaging and verifying the app..."
mkdir -p "$build_dir/package"
rm -rf "$staged_app"
ditto "$build_dir/xcode/Build/Products/Release/SwiftyGrok.app" "$staged_app"
share_extension="$staged_app/Contents/PlugIns/SwiftyGrokShare.appex"
widget_extension="$staged_app/Contents/PlugIns/SwiftyGrokWidgets.appex"
for extension in "$share_extension" "$widget_extension"; do
    if [[ ! -d "$extension" ]]; then
        echo "An extension is missing from the app bundle: ${extension##*/}" >&2
        exit 1
    fi
done
if [[ -e "$staged_app/Contents/PlugIns/SwiftyGrokFinder.appex" ]]; then
    echo "The retired Finder Sync extension is still present." >&2
    exit 1
fi

# Release targets are stripped by Xcode before signing. Require arm64-only
# executables and reject source/object debug records and local build paths.
echo "Checking arm64 architecture and executable privacy..."
for binary in "$staged_app/Contents/MacOS/SwiftyGrok" \
    "$share_extension/Contents/MacOS/SwiftyGrokShare" \
    "$widget_extension/Contents/MacOS/SwiftyGrokWidgets"; do
    architectures=$(xcrun lipo -archs "$binary")
    if [[ "$architectures" != arm64 ]]; then
        echo "Unexpected architectures in ${binary##*/}: $architectures (expected arm64)." >&2
        exit 1
    fi
    symbols=$(xcrun nm -pa -arch all "$binary")
    if printf '%s\n' "$symbols" | awk '
        $5 == "SO" || $5 == "OSO" { found = 1 }
        END { exit !found }
    '; then
        echo "Release executable still contains source/object debug records: ${binary##*/}" >&2
        exit 1
    fi
    if LC_ALL=C grep -aF "$PWD/" "$binary" >/dev/null || \
        LC_ALL=C grep -aE '/Users/|/home/|/private/(tmp|var/folders)/|/var/folders/' "$binary" >/dev/null; then
        echo "Release executable still contains local build paths: ${binary##*/}" >&2
        exit 1
    fi
done
codesign --verify --strict "$share_extension"
codesign --verify --strict "$widget_extension"
codesign --verify --deep --strict "$staged_app"
rm -rf "$app_path"
mv "$staged_app" "$app_path"

echo "Built: $PWD/$app_path"
echo "Run: open $app_path"
