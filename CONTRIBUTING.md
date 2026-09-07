# Contributing

## Build and test

Use an Apple Silicon Mac with macOS 15 or newer and Xcode 16 or newer. From the
repository root:

```bash
swift test
./scripts/build-app.sh
open "dist/Better Meeting.app"
```

The build script packages the executable, icons, permission descriptions,
frameworks, and license notices. Use the app bundle for recording;
`swift run BetterMeeting` does not include those resources. The app runs in the
menu bar without a Dock icon.

Tests cover meeting recovery, audio exports, saved preferences, capture presets,
automatic titles, multilingual merging, and per-language cache recovery.
They also cover cancellation, vocabulary and language settings, safe transcript
replacement, stereo audio meters, model-cache repair, and stable history search layout.
History refresh checks cover background scanning and discarding results from an old folder.
Model and decoding checks cover saved settings and cache invalidation. Screen tests
create a two-slide video and run native frame extraction and Vision OCR. Bundle
checks cover language shares, manual edits, replacement, and cancellation recovery.
Updater checks cover inline states, waiting for a restart click, and deferring
installation while a meeting is active.
GitHub Actions runs the same checks and keeps any macOS
crash reports when a check fails.

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

To update the README screenshot with fictional meetings:

```bash
BETTER_MEETING_PREVIEW_PATH="$PWD/docs/menu-bar.png" swift test --filter testRenderMenuBarPreview
```

## Before opening a pull request

- Keep recording and transcription local, with one folder per meeting.
- Preserve typed titles, the date fallback, and recovery from saved recordings.
- Keep changes and commits focused; include a regression check for a bug fix.
- Run the tests and app-bundle build above. Check permission changes in the signed app.

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
