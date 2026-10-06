# Live release validation

Use this checklist before promoting a beta to stable. Unit tests, previews,
archive checksums, and signature verification do not replace these checks.
A stable release is not ready while any applicable row is failed, blocked, or
unverified. Betas may carry outstanding checks only when the release notes name
those limitations explicitly.

## Record the candidate

For each validation run, retain a report outside the source tree with:

- Candidate version, build number, source commit, and any uncommitted app changes.
- macOS version, Mac model, displays, microphone, and recording volume.
- The exact signed app and ZIP tested, including its SHA-256 checksum.
- Date, tester, result for each row, and the evidence or blocker.

Use `passed`, `failed`, `blocked`, or `not applicable` with a reason. Do not use
`passed` for an injected device condition, a screenshot, or a check that was not
run. Redo affected rows if the code, signed candidate, or relevant environment
changes; reuse unaffected results.

Use fictional meeting names and disposable speech. Close private windows before
screen capture. Store media and reports under an ignored directory such as
`.build/live-validation/`, never in the repository. Remove captured media when
finished. Do not change privacy settings, signing identities, trusted keys, or
system security protections just to make a check pass.

## Checks

| Check | Procedure | Required outcome |
| --- | --- | --- |
| Sustained recording under transcription load | In the signed app, start transcription of a disposable saved meeting, then record a ten-minute call in both screen and audio-only modes. Include system playback, microphone speech, silence, and overlap. Stop normally and transcribe both. | Neither capture ends early. Both voices remain audible with correct relative timing; silence does not produce a false source failure when buffers continue. The audio-only original has no video track. |
| Microphone/headphone disconnection | During a disposable recording, unplug the selected external input or disconnect the headset. Check the open menu and then a separate run with the menu closed. Reconnect the same device if supported. | Loss is reported without claiming successful audio capture. Any saved media remains available. Resumed buffers clear the warning; an unrecoverable stop is explicit. |
| Display removal | Record an external display, then unplug it. Also remove a noncaptured display during audio-only capture. | Screen capture stops or reports the unavailable source explicitly, never silently switches to another display. Saved media remains available. Audio-only behavior is recorded separately. |
| Sleep/wake | During each capture mode, put the Mac to sleep and wake it. Do not force sleep on someone else's active work. | The resulting capture state, warning, duration, and any gap agree with the saved media. No stale “recording” state remains if capture ended. Record actual behavior rather than assuming sleep is prevented. |
| macOS screen-sharing-menu stop | Stop a disposable capture using macOS's screen-sharing control rather than the app's Stop button. Exercise each mode exposed by macOS. | Capture stops, finalization completes, and saved media becomes readable and available for transcription. No permanently stuck Stopping state. |
| Low-space notifications | Choose a disposable constrained test volume; never fill the real system or meetings drive. Start above the hard start threshold but below the warning threshold, then separately cross the warning threshold during capture. With notifications allowed and Focus off, close the menu. Free space afterward. | The notification is delivered, opens the current recording controls, and is removed after recovery or stop. The menu shows the warning. A start below 250 MB is rejected without losing prior meetings. |
| Signed update installation | Install an older signed build in a disposable app location, opt into the candidate's channel, and update to the exact candidate through Sparkle. Also prepare an update during recording/transcription. Do not replace a user's running production app. | The correct candidate installs and relaunches; settings and meetings survive; permission identity is retained. An active recording/job is never interrupted by an update restart. |
| Modified archive rejection | Copy the candidate ZIP, alter the copy, and attempt its update using the original signature in an isolated update setup. Never modify or republish a released archive. | Sparkle rejects the modified archive and leaves the existing app intact. Command-line signature rejection is supporting evidence, not proof of installer behavior. |

## Supporting automated checks

Run the owning regression suites and `swift test`, then build with the existing
persistent release identity as documented in [CONTRIBUTING.md](../CONTRIBUTING.md).
Verify the candidate's code signature against that pinned identity. Verify the
original archive's Sparkle signature and reject a modified *copy*. Never export,
print, replace, or commit either private signing key.

Permission-blocked capture, unavailable physical devices, and unavailable UI
automation are blockers, not successful smoke tests. Ask the maintainer to finish
those rows and retain the completed report before publishing stable.
