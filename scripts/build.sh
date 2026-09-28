#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$repo_dir/build"
playtools_dir="$build_dir/PlayTools"
playtools_commit="f2bfbd76ff55f4737c959fa2eac07f9ada2e6d7e"
playtools_source="${1:-https://github.com/PlayCover/PlayTools.git}"

if [[ -e "$playtools_dir" ]]; then
    echo "Build checkout already exists: $playtools_dir" >&2
    echo "Move it aside to rebuild from a clean checkout." >&2
    exit 1
fi

mkdir -p "$build_dir"
git clone --no-checkout "$playtools_source" "$playtools_dir"
git -C "$playtools_dir" checkout --detach "$playtools_commit"
git -C "$playtools_dir" apply --check "$repo_dir/patches/playtools-minecraft.patch"
git -C "$playtools_dir" apply "$repo_dir/patches/playtools-minecraft.patch"

# Upstream's lint build phase skips SwiftLint when FASTLANE is set.
FASTLANE=1 xcodebuild \
    -project "$playtools_dir/PlayTools.xcodeproj" \
    -scheme PlayTools \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$build_dir/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    build

framework="$build_dir/DerivedData/Build/Products/Debug-iphoneos/PlayTools.framework"
framework_binary="$framework/PlayTools"
[[ -f "$framework_binary" ]] || { echo "PlayTools build product not found" >&2; exit 1; }

# The app runs on Apple Silicon macOS via the Mac Catalyst compatibility path.
vtool -set-build-version maccatalyst 11.0 14.0 -replace \
    -output "$framework_binary.rewritten" "$framework_binary"
mv -f "$framework_binary.rewritten" "$framework_binary"
chmod +x "$framework_binary"
codesign --force --deep --sign - "$framework"

plugin="$build_dir/MinecraftNativeInput.dylib"
mkdir -p "$build_dir/ModuleCache"
CLANG_MODULE_CACHE_PATH="$build_dir/ModuleCache" xcrun clang \
    -target arm64-apple-ios15.0 \
    -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -fobjc-arc -fblocks -dynamiclib \
    -framework Foundation -framework GameController -framework CoreGraphics \
    -Wl,-install_name,@rpath/MinecraftNativeInput.dylib \
    -o "$plugin" "$repo_dir/NativeInput/MinecraftNativeInput.m"
vtool -set-build-version maccatalyst 11.0 14.0 -replace \
    -output "$plugin.rewritten" "$plugin"
mv -f "$plugin.rewritten" "$plugin"
chmod +x "$plugin"
codesign --force --sign - "$plugin"

echo "Built $framework and $plugin"
