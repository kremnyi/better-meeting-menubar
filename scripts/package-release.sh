#!/bin/zsh

set -euo pipefail

cd "${0:A:h:h}"
if [[ $(uname -m) != arm64 ]]; then
    echo "Release packaging requires an Apple Silicon Mac." >&2
    exit 1
fi

channel="stable"
if [[ $# -gt 0 ]]; then
    channel="$1"
fi
if [[ "$channel" != stable && "$channel" != beta ]]; then
    echo "Usage: package-release.sh [stable|beta]" >&2
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
channel_args=()
if [[ "$channel" == beta ]]; then
    # Sparkle prunes per channel, so the feed keeps one stable item next to the new beta.
    channel_args=(--channel beta)
    stable_archives=(
        "$PWD"/.build/sparkle-release/*/Better-Meeting-*-arm64.zip(N)
        "$PWD"/dist/Better-Meeting-*-arm64.zip(N)
    )
    stable_archives=(${stable_archives:#*Better-Meeting-*b[0-9]*-arm64.zip})
    stable_archives=(${stable_archives:#*Better-Meeting-*beta*-arm64.zip})
    if (( ${#stable_archives} == 0 )); then
        echo "No published stable archive found to keep in the beta feed." >&2
        echo "Put the current stable ZIP back in dist/ and retry." >&2
        exit 1
    fi
    for stable_archive in "${stable_archives[@]}"; do
        ln -f "$stable_archive" "$feed_dir/${stable_archive:t}"
    done
fi
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --account com.kremnyi.bettermeeting --maximum-deltas 0 --maximum-versions 1 \
    "${channel_args[@]}" \
    --download-url-prefix "https://github.com/kremnyi/better-meeting-menubar/releases/download/v$version/" \
    --link "https://github.com/kremnyi/better-meeting-menubar/releases/tag/v$version" \
    -o appcast.xml "$feed_dir"
# generate_appcast applies one URL prefix to every archive, including retained stable builds.
python3 - <<'PY'
import xml.etree.ElementTree as ET

namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", namespace)
feed = ET.parse("appcast.xml")
for item in feed.findall("channel/item"):
    version = item.findtext(f"{{{namespace}}}shortVersionString")
    item.find("enclosure").set("url", f"https://github.com/kremnyi/better-meeting-menubar/releases/download/v{version}/Better-Meeting-{version}-arm64.zip")
feed.write("appcast.xml", encoding="utf-8", xml_declaration=True)
PY
