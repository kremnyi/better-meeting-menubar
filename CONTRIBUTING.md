# Contributing

## Build and test

Use an Apple Silicon Mac with macOS 15 or newer and Xcode 16 or newer. From the
repository root:

```bash
swift test
./scripts/build-app.sh
open "dist/Better Meeting.app"
```

If `swift test` fails with `no such module 'XCTest'`, the Command Line Tools are
selected instead of Xcode. Point the shell at Xcode for the session:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`build-app.sh` already selects Xcode when it is installed.

The build script packages the executable, icons, permission descriptions,
frameworks, and license notices. Use the app bundle for recording;
`swift run BetterMeeting` does not include those resources. The app runs in the
menu bar without a Dock icon.

Tests cover recording recovery, transcription and cache reuse, saved settings,
screen extraction, exports, and updates. UI checks cover stable layouts, audio
warnings, and notification routing. GitHub Actions runs the tests and app-bundle
build, keeping macOS crash reports if a check fails. Live model checks are opt-in;
see below.

Use `dist/Better Meeting.app` to check recording permissions. Local builds and CI
default to ad-hoc signing. On the release Mac, reuse the persistent identity:

```bash
BETTER_MEETING_SIGNING_IDENTITY="Better Meeting Release Signing" \
    ./scripts/build-app.sh
```

Other contributors can use their own persistent code-signing identity for local builds.

## Optional checks

The model check downloads into `.build/model-check`, then checks that a separate
process can load the cache with HTTP requests blocked:

```bash
BETTER_MEETING_MODEL_CHECK=prepare swift test --filter testModelPreparationAcrossColdLaunches
BETTER_MEETING_MODEL_CHECK=offline swift test --filter testModelPreparationAcrossColdLaunches
```

To check all three languages with actual audio, use a disposable recording that
contains Ukrainian, Russian, and English speech. The check saves pass caches next
to the audio and uses the model under `.build/model-check`:

```bash
BETTER_MEETING_TRANSCRIPTION_CHECK=/path/to/mixed.wav swift test --filter testRealMultilingualRecording
```

To check model switching through Small, Turbo, Large v3, and back to Small, use
disposable English audio containing the word "pricing". This downloads any missing
models into `.build/model-check` and writes pass caches beside the audio:

```bash
BETTER_MEETING_MODEL_SWITCH_CHECK=/path/to/pricing.wav swift test --filter testActualModelSwitching
```

With the same environment variable, `--filter testTurboSilenceLimitation` records
the turbo model's known silence hallucination as an expected failure. Keep the
default confidence thresholds; do not tune them just to pass a silent fixture.

To check actual speaker detection, use disposable speech audio. This downloads
the SpeakerKit models into `.build/speaker-check` and processes the audio locally:

```bash
BETTER_MEETING_SPEAKER_CHECK=/path/to/speech.wav swift test --filter testRealSpeakerDetection
```

To compare the Whisper and Parakeet engines on a representative recording —
Ukrainian/Russian switching, English terms and names, silence, and overlapping
speakers — use disposable audio:

```bash
BETTER_MEETING_ENGINE_CHECK=/path/to/meeting.wav swift test --filter testCompareEnginesOnRealAudio
```

Both engines download their models into `.build/engine-check` on first use. To
reuse models the app already downloaded, copy them there as APFS clones, for example
`cp -Rc ~/Library/Application\ Support/BetterMeeting/models/parakeet-tdt-0.6b-v3 .build/engine-check/models/`.
Narrow a run with `BETTER_MEETING_ENGINE_CHECK_ENGINES` (`whisper-turbo`,
`parakeet-v3`) and `BETTER_MEETING_ENGINE_CHECK_LANGUAGES` (for example `ru`). The
check prints elapsed time and peak memory per engine and writes
`.build/engine-check/whisper-turbo.md` and `.build/engine-check/parakeet-v3.md`
for transcript comparison. Parakeet became the default after this check: on a
30-minute Russian call it kept speech Whisper had dropped and finished in 27 seconds,
and on a Ukrainian sample both engines were accurate.

To update the README screenshot with fictional meetings:

```bash
BETTER_MEETING_PREVIEW_PATH="$PWD/docs/menu-bar.png" swift test --filter testRenderMenuBarPreview
```

To render Options, update states, and recording audio warnings in light and dark
mode without launching the app:

```bash
BETTER_MEETING_PANELS_PREVIEW_PATH="$PWD/.build/previews" swift test --filter 'testOptionsAndUpdateLayouts|testRecordingAudioWarningClearsWithoutResizingOrRepeating'
```

The PNGs use fictional data and do not verify live notification delivery or
recording permissions.

## Before opening a pull request

- Keep recording and transcription local, with one folder per meeting.
- Preserve typed titles, the date fallback, and recovery from saved recordings.
- Keep changes and commits focused; verify the changed behavior for a bug fix.
- For code changes, run the affected tests. Run the full tests and app-bundle build
  for changes spanning multiple subsystems or affecting packaging, resources,
  dependencies, or signing, and before a release. Check permission changes in the
  signed app. Documentation-only changes need a diff and relevant link or command
  review, not an app build. Run any checks explicitly requested by the task.
- Reuse passing results for unchanged code and environment; rerun affected checks
  after a fix. The release checks below remain required.

## Publish a release

This repository is also the `kremnyi/better-meeting` Homebrew tap.
`Casks/better-meeting.rb` points to a versioned GitHub release. Releases use the
**Better Meeting Release Signing** self-signed identity in the maintainer's
login Keychain. `package-release.sh` pins its public
certificate fingerprint and fails if the private key is unavailable; it never
falls back to ad-hoc signing.

Keep an encrypted backup of this identity using Keychain Access, outside the
repository. Recreating the certificate changes the app's identity and requires
users to grant permissions again. Do not commit or upload the private key.

Sparkle uses a separate Ed25519 key under the Keychain account
`com.kremnyi.bettermeeting`. `SUPublicEDKey` in `App/Info.plist` contains its public
key. Keep the existing private key backed up securely; never commit or upload it.
The app-signing certificate and Sparkle key serve different purposes and both are
required to publish. Run Sparkle's `generate_keys --account com.kremnyi.bettermeeting`
to inspect the public key; do not replace the existing key when setting up releases.

### Release script

`scripts/release.sh` runs the whole release, for stable and beta versions alike:

```bash
scripts/release.sh stable 0.4.0 --notes path/to/notes.md
```

```bash
scripts/release.sh beta 0.4.1b1 --notes path/to/notes.md
```

Before it changes anything, the script checks that:

- the version has the right form: `0.4.0` for stable, `0.4.1b1` for beta;
- you are on an up-to-date `main` with no uncommitted tracked changes;
- neither the tag nor the release already exists;
- `gh` is signed in, and you are on an Apple silicon Mac;
- the notes file mentions self-signing;
- for a beta, the current stable ZIP is in `dist/`.

It lists every problem at once. Add `--dry-run` to run only these checks and print the plan.

Then it follows the steps below:

1. Sets the version and the next `CFBundleVersion` in `App/Info.plist`.
2. Runs `swift test` and `package-release.sh`.
3. Checks the archive checksum and the feed items. For a stable release, it also updates and checks the cask.
4. Commits, then asks `Publish v<version> to GitHub and push main? [y/N]`. Pass `--yes` to skip the question.
5. Pushes the tag. For a stable release, it waits for CI on the tag first.
6. Publishes the GitHub release, marked as a pre-release for betas, and checks the download.
7. Pushes `main` and checks that the public feed lists the new version.
8. For a stable release, runs `brew fetch` for the cask.
9. Waits for CI to pass on `main`, and for a beta, on the tag.

If a step fails, the script names the step and what state it left:

- **Before the commit:** it prints the command that discards the version bump.
- **After the commit but before publishing:** it prints the command that undoes the local commit.
- **After the tag is pushed:** the release is public. Finish the remaining steps below by hand, and never replace a published archive.

Write the release notes to a file first. Keep the Installing section about self-signing and first-launch approval from earlier releases.

### Manual steps

The script performs these steps; use them to finish a release it could not complete.

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `App/Info.plist`.
2. Run `swift test`, then `./scripts/package-release.sh`. This creates a
   self-signed ZIP and `.sha256` file in `dist/`, then signs the archive for
   Sparkle and generates `appcast.xml`. The feed contains the latest full update;
   no delta archives or separate hosting are needed.
3. Set the cask's `version` and `sha256` to match that archive. Run
   `ruby -c Casks/better-meeting.rb` and commit the version, cask, and feed together.
4. Tag that commit as `v<version>` and push the tag. Wait for GitHub Actions
   to pass the tests and app-bundle build.
5. Publish the matching GitHub release with the ZIP and checksum from step 2,
   then push the commit to `main`. The download must be available before the
   updated cask and Sparkle feed reach users.
6. Run `brew update`, then
   `brew fetch --cask kremnyi/better-meeting/better-meeting` to verify the public
   download and its checksum. Check that the public `appcast.xml` points to the
   same archive. When changing the updater or signing, also test installation
   between two signed bundles and rejection of a modified archive.

Keep the old repository name `kremnyi/better-meeting` unused. Older app versions
use its update-feed URL, which redirects to this repository.

Keep the exact archive used for the checksum and Sparkle signature; rebuilding
can change it. Never replace a published version's archive. Publish a new version
instead. `auto_updates true` in the cask identifies the built-in updater.

Release notes must explain self-signing and first-launch approval. Keep checksum
verification and platform requirements in the cask. Install hooks must not disable
security checks or remove meetings.

## Publish a beta

Beta builds share the archive, signing identity, and feed with stable releases.
The feed item carries `sparkle:channel beta`, which hides it from everyone who has
not enabled **Options → App & updates → Include beta releases**. The same feed
keeps the current stable item, so stable users only ever see stable releases.

Stable 0.3.42 and later carry the toggle, so opted-in users receive beta cuts
through Sparkle like any other update. Installations older than that can only
reach a beta by installing its ZIP manually.

Publish betas with `scripts/release.sh beta <version> --notes <file>` (see
[Release script](#release-script)). It performs these steps:

1. Set `CFBundleShortVersionString` to the upcoming version with a `b<number>`
   suffix (for example `0.3.42b1`) and increment `CFBundleVersion` past the
   published stable build. The stable release that ends the series needs a higher
   `CFBundleVersion` than every beta in it, so beta users move on to it.
2. Run `swift test`, then `./scripts/package-release.sh beta`. The script signs the
   archive as usual and writes a feed that pairs the beta with the current stable
   archive found in `dist/` or `.build/sparkle-release/`. It stops with an error
   when that ZIP is missing.
3. Commit `App/Info.plist` and `appcast.xml`, tag the commit `v<version>`, and publish
   the GitHub release with the ZIP and checksum from `dist/`. Leave
   `Casks/better-meeting.rb` on the stable release.
