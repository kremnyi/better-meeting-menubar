# Better Meeting

## Task context

Read only the documentation relevant to the requested work:
- `README.md` for user-facing behavior and setup.
- `CONTRIBUTING.md` for build, test, packaging, release, or website (`site/`) work; use only the relevant sections.
- `docs/calendar-data.md` for calendar integration, event metadata, and reminders.
- `.impeccable/critique/` contains historical review findings, not standing instructions or a current backlog. Consult these only when relevant and verify findings against current code.
- `PRODUCT.md` holds product positioning for Impeccable; its `Platform: ios` value is that skill's Apple bucket, and the app is macOS-only.

## Code map

All app code is in `Sources/BetterMeetingApp/`; tests in `Tests/` are named after the area they cover.
- `AppModel.swift`: central state — recording lifecycle, transcription queue, retries and recovery, saved settings, model loading and idle release. `AppState.swift` holds its phases and errors.
- `BetterMeetingApp.swift`: app entry, `MenuBarExtra`, app delegate, notification routing.
- Capture: `MeetingRecorder.swift` (ScreenCaptureKit, video quality), `AudioMeters.swift`, `AudioExtractor.swift` (audio from the recording), `MeetingAudio.swift` (decoded samples shared by passes).
- Transcription: `LocalTranscriber.swift` (engines, model storage and migration), `MeetingWhisperKit.swift`, `TranscriptionPasses.swift` (Whisper per-language passes and merge), `ParakeetLanguage.swift`, `SpeakerLabels.swift`, `SpeechSettings.swift`, `MeetingTitle.swift`.
- Meeting files: `MeetingArtifacts.swift` (folder layout, writes, rename, transcript replacement), `MeetingLibrary.swift` (history scan and search), `MeetingBundle.swift` and `ScreenExtractor.swift` (export bundle).
- Calendar and detection: `CalendarIntegration.swift`, `CalendarEvent.swift`, `CalendarReminders.swift`, `MeetingCalendar.swift` (sidecar search), `CalendarViews.swift`, `MeetingDetector.swift`.
- Notifications and updates: `MeetingNotifications.swift`, `AppUpdater.swift` (Sparkle).
- Menu UI: `MenuBarControlView.swift`, `MeetingHistorySection.swift`, `BrandViews.swift` (menu-bar icon and label), `TranscriptionOptionsView.swift` (Options pages and Re-transcribe), `ModelStorageView.swift`, `UpdateOptionsView.swift`, `AboutView.swift`, `ErrorPanel.swift`.
- Packaging: `App/Info.plist`, `scripts/` (build, package, release), `Casks/`, `appcast.xml`; website in `site/`.

## Skills

Use Impeccable only when the user explicitly names Impeccable or invokes one of its commands. An ordinary UI edit or review does not authorize its design workflow. Plugin installation alone does not make a skill explicit-only.

## Tests

Before adding or changing a test, name the behavior it protects, the regression that would make it fail, and why existing tests miss it. Prefer extending the test that already owns the behavior over adding a near-duplicate.

Do not add tests that:
- assert nothing, or only restate constants, declared flags, or copied lists;
- take expected values from the code under test;
- rely on a fixture or injected closure to produce the result being asserted, such as a closure that stops the queue itself;
- break under behavior-preserving refactoring.

Injection hooks such as `prepareSpeechModel(_:)` or a `trash:` parameter stay only while production calls the same path through a default. A regression test must fail on the pre-fix code for the intended reason.

Keep tests that guard saved files and migrations, settings, permissions and privacy, notifications, updates, and menu layout, even when they are slow or look implementation-shaped. Run the owning test with `swift test --filter <name>`, then `swift test`.

## Completion

Complete the requested implementation, applicable verification, and any explicitly requested delivery steps before handing back. A diagnosis-only or recommendations-first request ends with findings; do not implement it without authorization.

For authorized fixes, repair failures caused by the change and rerun affected checks. Reuse successful results while the tested code and environment remain unchanged. Report blocked or failed checks accurately; do not treat an environmental failure as a pass.

Keep recording and transcription local. Preserve existing permission, signing, private-key, and release protections in the project documentation. This file does not grant additional system permissions or authorize publication.
