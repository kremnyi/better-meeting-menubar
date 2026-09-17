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
GivenFLY/better-meeting Python CLI; its Whisper engine keeps that project's
transcription semantics (per-language passes, confidence merge, silence filter).

## Operating Context

macOS menu bar app (`MenuBarExtra`); meetings are saved by default to
`~/Documents/Better Meetings`, one folder each with video, audio, transcript,
and Whisper's cached language passes. Speech models live under
`~/Library/Application Support/BetterMeeting`. Under Options → Meetings, an
optional calendar integration reads EventKit events, and an opt-in detector
suggests recording once another app has used the microphone for half a minute.
Updates ship through Sparkle with a beta channel. Distribution is self-signed
GitHub Releases installed through a Homebrew cask; the landing page in `site/`
deploys to GitHub Pages and points to the cask. Development
is Xcode and SwiftPM; verification is `swift test`, with opt-in model checks
for real audio.

## Capabilities and Constraints

- Captures one whole display; window-only and audio-only modes do not exist.
- Two local engines: Parakeet v3 (FluidAudio, the default; one pass without a
  cache, 25 European languages) and Whisper (WhisperKit; one pass per language,
  merged by confidence). Meetings transcribed with Whisper keep it when retried
  or re-transcribed.
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
the original project and its authors stays visible. The About page and the
website credit the maintainer, Bohdan Kremnyi, alongside the original project.

## Evidence on Hand

README.md documents user-facing behavior; CONTRIBUTING.md covers build, test,
release, and the website; `site/` is the public landing page;
`docs/calendar-data.md` the calendar data model; `appcast.xml` and
`dist/` hold live release artifacts; `ThirdPartyNotices.md` and `NOTICE` carry
licenses. The test suite includes opt-in checks against real audio and models.
There are no testimonials, customers, benchmarks, or press — future work must
not fabricate them.

## Product Principles

1. Local by default: a meeting never leaves the Mac unless the user moves it.
2. Plain files, no lock-in: every meeting is a folder of open formats.
3. One-click reliability first: capture must start fast and never lose a
   recording, even when processing or downloads fail.
4. Keep the original's transcription semantics in the Whisper engine. Other
   engines may be the default, but must not change how meetings already
   transcribed with Whisper are retried or re-transcribed.
5. Optimize for the maintainer's daily use before public adoption; polish is
   the current focus.

## Accessibility & Inclusion

Interactive controls carry accessibility labels, and Reduce Motion is honored
where the interface animates. No formal accessibility target or audit has been
set.
