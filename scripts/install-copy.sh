#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
framework="$repo_dir/build/DerivedData/Build/Products/Debug-iphoneos/PlayTools.framework"
plugin="$repo_dir/build/MinecraftNativeInput.dylib"
source_app="${1:-}"
target_app="${2:-$HOME/Applications/Minecraft Direct.app}"

if [[ -z "$source_app" || ! -f "$source_app/minecraftpe" ]]; then
    echo "Usage: $0 /path/to/com.mojang.minecraftpe.app [output.app]" >&2
    exit 1
fi
if [[ ! -f "$framework/PlayTools" || ! -f "$plugin" ]]; then
    echo "Run scripts/build.sh first." >&2
    exit 1
fi
if [[ -e "$target_app" ]]; then
    echo "Output already exists: $target_app" >&2
    exit 1
fi

bundle_id="$(plutil -extract CFBundleIdentifier raw "$source_app/Info.plist")"
if [[ "$bundle_id" != "com.mojang.minecraftpe" ]]; then
    echo "Expected Minecraft Bedrock (com.mojang.minecraftpe), got $bundle_id" >&2
    exit 1
fi

old_playtools="$(otool -L "$source_app/minecraftpe" | awk '$1 ~ /PlayTools[.]framework\/PlayTools$/ { print $1 }')"
if [[ -z "$old_playtools" || "$old_playtools" == *$'\n'* ]]; then
    echo "Expected exactly one PlayTools load path in the source app." >&2
    exit 1
fi

settings="$HOME/Library/Containers/io.playcover.PlayCover/App Settings/$bundle_id.plist"
if [[ ! -f "$settings" ]]; then
    echo "Settings plist not found: $settings" >&2
    echo "Create settings for this app in PlayCover before installing the copy." >&2
    exit 1
fi

entitlements="$(mktemp "${TMPDIR:-/tmp}/minecraft-entitlements.XXXXXX")"
trap 'rm -f "$entitlements"' EXIT
codesign -d --entitlements :- "$source_app" > "$entitlements" 2>/dev/null
plutil -lint "$entitlements" >/dev/null

mkdir -p "$(dirname "$target_app")"
ditto "$source_app" "$target_app"
mkdir -p "$target_app/Frameworks/UserPlugins"
ditto "$framework" "$target_app/Frameworks/PlayTools.framework"
cp "$plugin" "$target_app/Frameworks/UserPlugins/MinecraftNativeInput.dylib"

plutil -replace CFBundleSupportedPlatforms -json '["MacOSX"]' "$target_app/Info.plist"
plutil -remove LSRequiresIPhoneOS "$target_app/Info.plist" 2>/dev/null || true
plutil -replace LSMinimumSystemVersion -string '12.0' "$target_app/Info.plist"
install_name_tool -change "$old_playtools" \
    '@executable_path/Frameworks/PlayTools.framework/PlayTools' \
    "$target_app/minecraftpe"

# Preserve the source app's sandbox permissions while signing the copied app.
codesign --force --deep --sign - --entitlements "$entitlements" "$target_app"
codesign --verify --deep --strict "$target_app"

backup="$settings.backup.$(date +%Y%m%d-%H%M%S)"
cp -p "$settings" "$backup"
plutil -replace keymapping -bool NO "$settings"
plutil -replace noKMOnInput -bool NO "$settings"
plutil -replace playChain -bool YES "$settings"
plutil -replace disableBuiltinMouse -bool NO "$settings"
plutil -replace resolution -integer 6 "$settings"
plutil -replace notch -bool NO "$settings"
plutil -replace customScaler -float 2 "$settings"

echo "Installed: $target_app"
echo "Settings backup: $backup"
