#!/bin/zsh

set -euo pipefail

cd "${0:A:h:h}"

usage() {
    print -u2 "Usage: scripts/release.sh beta|stable <version> --notes <file> [--dry-run] [--yes]"
    print -u2 "  beta 0.4.0b2   pre-release for Include beta releases; updates Casks/better-meeting@beta.rb"
    print -u2 "  stable 0.4.0   release for everyone; updates both casks"
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
beta_cask=Casks/better-meeting@beta.rb
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
        print -u2 "Nothing was committed. Discard the version bump with: git checkout -- $plist appcast.xml $cask $beta_cask"
    fi
}
trap on_exit EXIT

if [[ -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

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
fi
command -v ruby >/dev/null || problem "Install Ruby to check the cask syntax."

if (( ${#problems} )); then
    print -u2 "release.sh: can't release $tag yet:"
    printf '  - %s\n' "${problems[@]}" >&2
    exit 1
fi

print "Release plan for $tag ($channel), build $current_build → $build:"
print "  1. Set $plist to $version ($build), run swift test, and package with scripts/package-release.sh $channel"
print "  2. Check the archive checksum and appcast.xml, then update and check $([[ $channel == stable ]] && print 'both casks' || print 'the beta cask')"
print "  3. Commit, then ask before publishing"
if [[ $channel == stable ]]; then
    print "  4. Push $tag and wait for CI, publish the GitHub release, push main"
    print "  5. Verify the download, the public feed, brew fetch, and CI on main"
else
    print "  4. Push $tag, publish the GitHub pre-release, push main"
    print "  5. Verify the download, the public feed, brew fetch, and CI on the tag and main"
fi
if $dry_run; then
    print "Dry run: all checks passed; nothing was changed."
    exit 0
fi

# The tag is already public when this runs, so a GitHub API error alone must not stop the release: each gh call is tried again.
# The release commit passes when each build job passed on it, in any attempt of any run of the commit (for the tag, main, or another ref).
# GitHub cancels a job that no runner takes in 15 minutes. If such a job of the tag run passed in no run,
# the failed jobs of the tag run are run again, up to ci_reruns times in one wait.
# A run for another ref is not run again: build.yml cancels a run in progress on the same ref, which can be the run of a newer commit.
# A job that failed in the last attempt of a run stops the release, also when it passed in another run.
ci_reruns=8
wait_for_ci() {
    local ref=$1 sha run id branch job name last now state attempt url tries=0
    local -a runs mine jobs f failed again rerun missing
    local -aU names passed idle
    local -A stuck started
    sha=$(git rev-parse HEAD)
    runs=()
    for attempt in {1..30}; do
        runs=(${(f)"$(gh run list --repo $repo --workflow build.yml --commit $sha --json databaseId,headBranch --jq '.[] | "\(.databaseId) \(.headBranch)"' || true)"})
        mine=(${(M)runs:#* $ref})
        (( ${#mine} )) && break
        sleep 10
    done
    (( ${#mine} )) || fail "GitHub listed no CI run for $ref after 30 tries."
    url="https://github.com/$repo/actions/runs/${mine[1]%% *}"
    print "Waiting for CI on $ref…"
    while true; do
        names=() passed=() failed=() idle=() stuck=()
        for run in $runs; do
            id=${run%% *} branch=${run#* }
            # gh run watch returns early on a network error, so ask until GitHub reports the run as completed.
            # After a rerun, an answer about the attempt before it does not count.
            state=""
            for attempt in {1..60}; do
                gh run watch $id --repo $repo --interval 10 >/dev/null 2>&1 || true
                state=$(gh run view $id --repo $repo --json status,attempt --jq '"\(.status) \(.attempt)"' 2>/dev/null || true)
                if [[ $state == completed\ <-> ]] && (( ${state#* } >= ${started[$id]:-0} )); then break; fi
                state=""
                (( attempt > 1 )) || print -u2 "GitHub did not report run $id as completed yet; asking again every 30 seconds."
                sleep 30
            done
            [[ -n $state ]] || fail "GitHub did not report run $id as completed. See https://github.com/$repo/actions/runs/$id"
            # One line for each job of each attempt: attempt, conclusion, number of steps, name.
            last=0
            for attempt in {1..60}; do
                jobs=(${(f)"$(gh api --paginate "repos/$repo/actions/runs/$id/jobs?filter=all&per_page=100" --jq '.jobs[] | "\(.run_attempt) \(.conclusion // "unfinished") \(.steps // [] | length) \(.name)"' 2>/dev/null || true)"})
                jobs=(${(M)jobs:#<-> *})
                for job in $jobs; do
                    if (( ${job%% *} > last )); then last=${job%% *}; fi
                done
                # A job of the last attempt without a conclusion: the job list is behind the run, so ask again.
                if (( last && last >= ${started[$id]:-0} )) && [[ -z ${(M)jobs:#$last unfinished *} ]]; then break; fi
                last=0
                sleep 30
            done
            (( last )) || fail "GitHub gave no complete job list for run $id. See https://github.com/$repo/actions/runs/$id"
            for job in $jobs; do
                f=(${(s: :)job})
                name="${f[4,-1]}"
                if [[ $f[2] == success ]]; then
                    names+=($name)
                    passed+=($name)
                elif [[ $f[2] != skipped ]]; then
                    names+=($name)
                    if (( f[1] == last )); then
                        if [[ $f[2] != cancelled ]]; then
                            failed+=("$name ($f[2]) for $branch")
                        else
                            if [[ $branch == $ref ]]; then idle+=($name); fi
                            # No step ran: usually no runner took the job. Only such a job of the tag run is run again.
                            if [[ $f[3] == 0 && $branch == $tag ]]; then stuck[$name]="$id $last"; fi
                        fi
                    fi
                fi
            done
        done
        if (( ${#failed} )); then
            fail "CI did not pass for $ref: ${(j:, :)failed}. See $url"
        fi
        if (( ${#names} == 0 )); then
            fail "GitHub gave no CI result for $ref. See $url"
        fi
        missing=(${names:|passed})
        if (( ${#missing} == 0 )); then
            print "CI passed for $ref: ${(j:, :)names} passed on commit ${sha[1,7]}."
            if (( ${#idle} )); then
                print "The run for $ref has a cancelled job (${(j:, :)idle}), so that run stays red on GitHub. Each job passed on this commit in another run or attempt."
            fi
            return 0
        fi
        rerun=() again=()
        for name in $missing; do
            if [[ -n ${stuck[$name]:-} ]]; then
                rerun+=($stuck[$name])
                again+=($name)
            fi
        done
        if (( ${#rerun} == 0 )); then
            fail "CI did not pass for $ref: ${(j:, :)missing} passed in no run. See $url"
        fi
        if (( tries >= ci_reruns )); then
            fail "CI did not pass for $ref: after $tries reruns, GitHub still cancelled ${(j:, :)again} for $tag before a step ran. See $url"
        fi
        (( tries += 1 ))
        print "GitHub cancelled ${(j:, :)again} for $tag before a step ran, usually because no runner took the job. Running the failed jobs again (try $tries of $ci_reruns)…"
        for run in ${(u)rerun}; do
            id=${run%% *}
            now=""
            for attempt in {1..20}; do
                gh run rerun $id --failed --repo $repo >/dev/null 2>&1 || true
                sleep 15
                now=$(gh run view $id --repo $repo --json attempt --jq .attempt 2>/dev/null || true)
                if [[ $now == <-> ]] && (( now > ${run#* } )); then break; fi
                now=""
            done
            [[ -n $now ]] || fail "GitHub did not start the jobs of run $id again. See https://github.com/$repo/actions/runs/$id"
            started[$id]=$now
        done
    done
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
# The beta cask follows every release: betas, and the stable release that ends a series.
casks=($beta_cask)
if [[ $channel == stable ]]; then
    casks+=($cask)
    message="Release $version on the stable channel"
fi
step="updating the casks"
print "\n==> Updating $casks"
checksum=$(cut -d ' ' -f 1 "dist/$archive.sha256")
for c in $casks; do
    sed -i '' -E "s/^  version \".*\"$/  version \"$version\"/; s/^  sha256 \".*\"$/  sha256 \"$checksum\"/" $c
    grep -q "version \"$version\"" $c && grep -q "sha256 \"$checksum\"" $c || fail "couldn't update $c."
    ruby -c $c >/dev/null
done
files+=($casks)

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

step="checking the cask download"
if command -v brew >/dev/null; then
    brew update --quiet
    for c in $casks; do
        brew fetch --cask "kremnyi/better-meeting/${c:t:r}"
    done
else
    print -u2 "warning: Homebrew isn't installed; skipped brew fetch."
fi
if [[ $channel == beta ]]; then
    step="waiting for CI on $tag"
    wait_for_ci $tag
fi

step="waiting for CI on main"
wait_for_ci main

print "\nPublished $tag: https://github.com/$repo/releases/tag/$tag"
