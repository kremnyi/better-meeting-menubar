#!/bin/zsh
# Publishes a beta or stable release: bump the version, test, package, commit, tag,
# publish on GitHub, push main, and verify. See "Publish a release" in CONTRIBUTING.md.

set -euo pipefail

cd "${0:A:h:h}"

usage() {
    print -u2 "Usage: scripts/release.sh beta|stable <version> --notes <file> [--dry-run] [--yes]"
    print -u2 "  beta 0.4.0b2   pre-release for Include beta releases; the cask stays on stable"
    print -u2 "  stable 0.4.0   release for everyone; also updates Casks/better-meeting.rb"
    exit 2
}

(( $# >= 2 )) || usage
channel=$1
version=$2
[[ $channel == beta || $channel == stable ]] || usage
shift 2
notes=""
dry_run=false
assume_yes=false
while (( $# )); do
    case $1 in
        --notes) (( $# >= 2 )) || usage; notes=$2; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        --yes) assume_yes=true; shift ;;
        *) usage ;;
    esac
done

repo=kremnyi/better-meeting-menubar
plist=App/Info.plist
cask=Casks/better-meeting.rb
tag="v$version"
archive="Better-Meeting-$version-arm64.zip"
step="checking prerequisites"
changed=false
committed=false
published=false

fail() {
    print -u2 "release.sh: $*"
    exit 1
}

on_exit() {
    local code=$?
    (( code == 0 )) && return
    print -u2 "\nrelease.sh stopped while $step."
    if $published; then
        print -u2 "$tag is already public. Finish the remaining steps from CONTRIBUTING.md by hand."
        print -u2 "Never replace a published archive; publish a new version instead."
    elif $committed; then
        print -u2 "Nothing was pushed. Undo the local release with: git tag -d $tag 2>/dev/null; git reset --hard HEAD~1"
    elif $changed; then
        print -u2 "Nothing was committed. Discard the version bump with: git checkout -- $plist appcast.xml $cask"
    fi
}
trap on_exit EXIT

if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Collect every blocker first, so one run lists everything to fix.
problems=()
problem() { problems+=("$1"); }

if [[ $channel == beta ]]; then
    [[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+b[0-9]+$' ]] || problem "Beta versions look like 0.4.0b2."
else
    [[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || problem "Stable versions look like 0.4.0."
fi
[[ $(uname -m) == arm64 ]] || problem "Releases are packaged on an Apple silicon Mac."
if [[ -z $notes || ! -s $notes ]]; then
    problem "Pass non-empty release notes with --notes <file>."
elif ! grep -qi "self-signed" "$notes"; then
    problem "Release notes must explain self-signing and first-launch approval (see the Installing section of earlier releases)."
fi
if ! command -v gh >/dev/null; then
    problem "Install the GitHub CLI (gh)."
elif ! gh auth status >/dev/null 2>&1; then
    problem "Sign in to GitHub with gh auth login."
fi
[[ $(git branch --show-current) == main ]] || problem "Release from the main branch."
git diff --quiet && git diff --cached --quiet || problem "Commit or stash tracked changes first."
if git fetch --quiet origin main --tags; then
    [[ $(git rev-list --count HEAD..origin/main) == 0 ]] || problem "main is behind origin/main; pull first."
else
    problem "Could not fetch origin."
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || [[ -n $(git ls-remote --tags origin "refs/tags/$tag") ]]; then
    problem "Tag $tag already exists. Published versions are never replaced; choose a new version."
fi
current_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $plist)
current_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $plist)
[[ $current_version != $version ]] || problem "$plist is already at $version."
build=$(( current_build + 1 ))
if [[ $channel == beta ]]; then
    stable_archives=(dist/Better-Meeting-*-arm64.zip(N) .build/sparkle-release/*/Better-Meeting-*-arm64.zip(N))
    stable_archives=(${stable_archives:#*/Better-Meeting-*b[0-9]*-arm64.zip})
    (( ${#stable_archives} )) || problem "Put the current stable ZIP in dist/; the beta feed keeps it for stable users."
else
    command -v ruby >/dev/null || problem "Install Ruby to check the cask syntax."
fi

if (( ${#problems} )); then
    print -u2 "release.sh: can't release $tag yet:"
    printf '  - %s\n' "${problems[@]}" >&2
    exit 1
fi

print "Release plan for $tag ($channel), build $current_build → $build:"
print "  1. Set $plist to $version ($build), run swift test, and package with scripts/package-release.sh $channel"
print "  2. Check the archive checksum and appcast.xml$([[ $channel == stable ]] && print ', then update and check the cask')"
print "  3. Commit, then ask before publishing"
if [[ $channel == stable ]]; then
    print "  4. Push $tag and wait for CI, publish the GitHub release, push main"
    print "  5. Verify the download, the public feed, brew fetch, and CI on main"
else
    print "  4. Push $tag, publish the GitHub pre-release, push main"
    print "  5. Verify the download, the public feed, and CI on the tag and main"
fi
if $dry_run; then
    print "Dry run: all checks passed; nothing was changed."
    exit 0
fi

wait_for_ci() {
    local ref=$1 sha ids conclusions
    sha=$(git rev-parse HEAD)
    ids=()
    for attempt in {1..30}; do
        ids=(${(f)"$(gh run list --repo $repo --commit $sha --json databaseId,headBranch --jq ".[] | select(.headBranch == \"$ref\") | .databaseId")"})
        (( ${#ids} )) && break
        sleep 10
    done
    (( ${#ids} )) || fail "no CI run started for $ref."
    print "Waiting for CI on $ref…"
    for id in $ids; do
        gh run watch $id --repo $repo >/dev/null 2>&1 || true
    done
    # A push can start duplicate runs and cancel one; any successful run counts.
    conclusions=$(for id in $ids; do gh run view $id --repo $repo --json conclusion --jq .conclusion; done)
    [[ $conclusions == *success* ]] || fail "CI did not pass for $ref: $(gh run list --repo $repo --commit $sha --json url --jq '.[0].url')"
    print "CI passed for $ref."
}

step="setting $plist to $version ($build)"
print "\n==> Setting $plist to $version ($build)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $build" $plist
changed=true

step="running swift test"
print "\n==> Running swift test"
swift test

step="packaging"
print "\n==> Packaging"
./scripts/package-release.sh $channel

step="checking the archive and feed"
print "\n==> Checking the archive and feed"
(cd dist && shasum -a 256 -c "$archive.sha256")
grep -q "<sparkle:shortVersionString>$version</sparkle:shortVersionString>" appcast.xml || fail "appcast.xml has no $version item."
grep -q "releases/download/$tag/$archive" appcast.xml || fail "appcast.xml doesn't point at the $tag download."
# Beta items must be on the beta channel, and stable users must still have a stable item.
RELEASE_VERSION=$version RELEASE_CHANNEL=$channel python3 - <<'PY' || fail "appcast.xml doesn't match the $channel release."
import os, sys
import xml.etree.ElementTree as ET

ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse("appcast.xml").findall("channel/item")
channels = {item.findtext(f"{ns}shortVersionString"): item.findtext(f"{ns}channel") for item in items}
version, channel = os.environ["RELEASE_VERSION"], os.environ["RELEASE_CHANNEL"]
expected = "beta" if channel == "beta" else None
if version not in channels or channels[version] != expected:
    sys.exit(f"{version} is on channel {channels.get(version)!r}, expected {expected!r}")
if None not in channels.values():
    sys.exit("the feed has no stable item")
PY

files=($plist appcast.xml)
message="Release $version on the beta channel"
if [[ $channel == stable ]]; then
    step="updating the cask"
    print "\n==> Updating the cask"
    checksum=$(cut -d ' ' -f 1 "dist/$archive.sha256")
    sed -i '' -E "s/^  version \".*\"$/  version \"$version\"/; s/^  sha256 \".*\"$/  sha256 \"$checksum\"/" $cask
    grep -q "version \"$version\"" $cask && grep -q "sha256 \"$checksum\"" $cask || fail "couldn't update $cask."
    ruby -c $cask >/dev/null
    files+=($cask)
    message="Release $version on the stable channel"
fi

step="committing"
git add $files
git commit -q -m "$message"
committed=true
print "\n==> Committed: $message"

if ! $assume_yes; then
    if ! read -q "reply?Publish $tag to GitHub and push main? [y/N] "; then
        print
        fail "not published."
    fi
    print
fi

step="pushing $tag"
print "\n==> Pushing $tag"
git tag $tag
git push -q origin $tag
published=true

if [[ $channel == stable ]]; then
    # The download must exist before the cask and feed on main point at it.
    step="waiting for CI on $tag"
    wait_for_ci $tag
fi

step="publishing the GitHub release"
print "\n==> Publishing the GitHub release"
release_args=(--repo $repo --title "$version" --notes-file "$notes")
[[ $channel == beta ]] && release_args=(--repo $repo --title "$version (beta)" --prerelease --notes-file "$notes")
gh release create $tag "dist/$archive" "dist/$archive.sha256" $release_args

step="checking the download"
download="https://github.com/$repo/releases/download/$tag/$archive"
curl -sfIL -o /dev/null "$download" || fail "$download isn't reachable."

step="pushing main"
print "\n==> Pushing main"
git push -q origin main

step="checking the public feed"
feed_ok=false
for attempt in {1..18}; do
    if curl -sf "https://raw.githubusercontent.com/$repo/main/appcast.xml?$(date +%s)" | grep -q "<sparkle:shortVersionString>$version<"; then
        feed_ok=true
        break
    fi
    sleep 10
done
$feed_ok && print "The public feed lists $version." || print -u2 "warning: the public feed doesn't list $version yet; GitHub's cache can lag a few minutes."

if [[ $channel == stable ]]; then
    step="checking the cask download"
    if command -v brew >/dev/null; then
        brew update --quiet
        brew fetch --cask kremnyi/better-meeting/better-meeting
    else
        print -u2 "warning: Homebrew isn't installed; skipped brew fetch."
    fi
else
    step="waiting for CI on $tag"
    wait_for_ci $tag
fi

step="waiting for CI on main"
wait_for_ci main

print "\nPublished $tag: https://github.com/$repo/releases/tag/$tag"
