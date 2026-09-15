# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

macOS 15+ on Apple silicon. The value above uses the skill's Apple-native bucket;
this app is not iOS.

## Users

Primary: the maintainer, recording their own meetings on a Mac. The job is
capturing a live meeting with no setup ceremony and getting a private,
searchable record with enough context to revisit it later.

Secondary, welcome but not a design driver: Mac users who find the public
release and share the same privacy needs, often for multilingual meetings
(Ukrainian, Russian, and English are the default transcript languages).

## Product Purpose

Record a display, system audio, and microphone from the macOS menu bar, then
extract everything useful locally: transcript, speaker labels, on-screen text,
and key screenshots, each meeting in its own self-contained folder. Success is
a recording that starts without friction and a transcript reliable enough to
use and search afterwards.

## Positioning

Fully local meeting capture and extraction: no account, no upload, no LLM
inside. Output is plain files — Markdown, JSON, screenshots — that a user's own
assistant can consume. It is a native menu bar reimplementation of the original
GivenFLY/better-meeting Python CLI, keeping that project's transcription
semantics (per-language passes, confidence merge, silence filter).

## Operating Context

macOS menu bar app (`MenuBarExtra`); meetings are saved by default to
`~/Documents/Better Meetings`, one folder each with video, audio, transcript,
and cached language passes. Speech models live under
`~/Library/Application Support/BetterMeeting`. Optional calendar integration
reads EventKit events; updates ship through Sparkle with a beta channel.
Distribution is self-signed GitHub Releases plus a Homebrew cask. Development
is Xcode and SwiftPM; verification is `swift test`, with opt-in model checks
for real audio.

## Capabilities and Constraints

- Captures one whole display; window-only and audio-only modes do not exist.
- Two local engines: Whisper (WhisperKit, one pass per language, merged by
  confidence) and Parakeet v3 (FluidAudio, one pass, 25 European languages).
- Optional speaker labels (SpeakerKit) and heuristic automatic meeting titles.
- Screen extraction samples every two seconds, reads text with Vision OCR, and
  exports up to 30 screenshots; bundles are exportable for external assistants.
- One transcription or export runs at a time; recording may continue during
  processing.
- Self-signed and not notarized: first launch needs Gatekeeper's "Open Anyway",
  and managed Macs may refuse it entirely. This distribution is a durable
  choice, not a temporary state.
- Not sandboxed, no cloud services, no built-in LLM. Recording, transcription,
  OCR, and naming stay on the Mac.
- Models total roughly 2 GB across engines; deleted models download again when
  needed.
- Fork of GivenFLY/better-meeting (Apache-2.0); attribution, NOTICE, and
  third-party licenses must be preserved, including CC-BY-4.0 NVIDIA weights.

## Brand Commitments

The name "Better Meeting". A calm, factual, privacy-forward voice: statements
about locality must stay true, and copy avoids marketing hype. Attribution to
the original project and its authors stays visible.

## Evidence on Hand

README.md documents user-facing behavior; CONTRIBUTING.md covers build, test,
and release; `docs/calendar-data.md` the calendar data model; `appcast.xml` and
`dist/` hold live release artifacts; `ThirdPartyNotices.md` and `NOTICE` carry
licenses. The test suite includes opt-in checks against real audio and models.
There are no testimonials, customers, benchmarks, or press — future work must
not fabricate them.

## Product Principles

1. Local by default: a meeting never leaves the Mac unless the user moves it.
2. Plain files, no lock-in: every meeting is a folder of open formats.
3. One-click reliability first: capture must start fast and never lose a
   recording, even when processing or downloads fail.
4. Keep the original's transcription semantics; engine additions stay opt-in
   and behavior-compatible.
5. Optimize for the maintainer's daily use before public adoption; polish is
   the current focus.

## Accessibility & Inclusion

Interactive controls carry accessibility labels, and Reduce Motion is honored
where the interface animates. No formal accessibility target or audit has been
set.
