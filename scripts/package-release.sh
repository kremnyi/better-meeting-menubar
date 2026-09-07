#!/bin/zsh

set -euo pipefail

cd "${0:A:h:h}"
if [[ $(uname -m) != arm64 ]]; then
    echo "Release packaging requires an Apple Silicon Mac." >&2
    exit 1
fi

signing_identity=B7DD515B85782011633AF2ACC25BFBDA42576F6E
BETTER_MEETING_SIGNING_IDENTITY="$signing_identity" ./scripts/build-app.sh
app_dir="dist/Better Meeting.app"
codesign --verify --deep --strict \
    -R "=identifier \"com.kremnyi.bettermeeting\" and certificate leaf = H\"$signing_identity\"" \
    "$app_dir"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
archive="Better-Meeting-${version}-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "dist/$archive"
cd dist
shasum -a 256 "$archive" > "$archive.sha256"
cat "$archive.sha256"
cd ..
feed_dir="$PWD/.build/sparkle-release/$version"
mkdir -p "$feed_dir"
ln -f "dist/$archive" "$feed_dir/$archive"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --account com.kremnyi.bettermeeting --maximum-deltas 0 --maximum-versions 1 \
    --download-url-prefix "https://github.com/kremnyi/better-meeting-menubar/releases/download/v$version/" \
    --link "https://github.com/kremnyi/better-meeting-menubar/releases/tag/v$version" \
    -o appcast.xml "$feed_dir"
