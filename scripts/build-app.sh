#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
package_dir=${script_dir:h}
build_dir="$package_dir/.build"
app_dir="$package_dir/dist/Better Meeting.app"
iconset_dir="$build_dir/BetterMeeting.iconset"
signing_identity=${BETTER_MEETING_SIGNING_IDENTITY:--}

if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

export CLANG_MODULE_CACHE_PATH="$build_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/module-cache"

swift build \
    --package-path "$package_dir" \
    --scratch-path "$build_dir" \
    --cache-path "$build_dir/cache" \
    --config-path "$build_dir/config" \
    --security-path "$build_dir/security" \
    -c release \
    --product BetterMeeting

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$package_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
cp "$build_dir/release/BetterMeeting" "$app_dir/Contents/MacOS/BetterMeeting"

sparkle_dir="$build_dir/artifacts/sparkle/Sparkle"
sparkle_framework="$app_dir/Contents/Frameworks/Sparkle.framework"
ditto "$sparkle_dir/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$sparkle_framework"
# ponytail: this app is not sandboxed; restore Sparkle's XPC services if sandboxing is added.
rm -rf "$sparkle_framework/Versions/B/XPCServices" "$sparkle_framework/XPCServices"
for component in "$sparkle_framework/Versions/B/Autoupdate" "$sparkle_framework/Versions/B/Updater.app" "$sparkle_framework"; do
    codesign --force --options 0 --sign "$signing_identity" "$component"
done
cp "$sparkle_dir/LICENSE" "$app_dir/Contents/Resources/Sparkle-LICENSE.txt"

cp "$build_dir/checkouts/FluidAudio/LICENSE" "$app_dir/Contents/Resources/FluidAudio-LICENSE.txt"
for license in "$build_dir"/checkouts/FluidAudio/ThirdPartyLicenses/*.md; do
    cp "$license" "$app_dir/Contents/Resources/"
done

rm -rf "$iconset_dir"
mkdir -p "$iconset_dir"
for icon_size in 16 32 128 256 512; do
    sips -z "$icon_size" "$icon_size" "$package_dir/Assets/AppIconMaster.png" --out "$iconset_dir/icon_${icon_size}x${icon_size}.png" >/dev/null
    retina_size=$((icon_size * 2))
    sips -z "$retina_size" "$retina_size" "$package_dir/Assets/AppIconMaster.png" --out "$iconset_dir/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/BetterMeeting.icns"

sips -z 18 18 "$package_dir/Assets/MenuBarIconTemplate.png" \
    --out "$app_dir/Contents/Resources/MenuBarIconTemplate.png" >/dev/null
sips -z 36 36 "$package_dir/Assets/MenuBarIconTemplate.png" \
    --out "$app_dir/Contents/Resources/MenuBarIconTemplate@2x.png" >/dev/null
cp "$package_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE.txt"
cp "$package_dir/NOTICE" "$app_dir/Contents/Resources/NOTICE.txt"
cp "$package_dir/ThirdPartyNotices.md" "$app_dir/Contents/Resources/ThirdPartyNotices.md"
cp "$build_dir/checkouts/argmax-oss-swift/LICENSE" "$app_dir/Contents/Resources/Argmax-LICENSE.txt"
cp "$build_dir/checkouts/argmax-oss-swift/NOTICES" "$app_dir/Contents/Resources/Argmax-NOTICES.txt"

codesign --force --sign "$signing_identity" "$app_dir"

if [[ "$signing_identity" == "-" ]]; then
    echo "Warning: ad-hoc signing changes the app identity after every rebuild; Screen Recording access must then be granted again." >&2
fi

echo "$app_dir"
