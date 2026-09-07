# Better Meeting

Record a display, system audio, and microphone from the macOS menu bar. After
recording stops, Whisper transcribes the audio locally. Each meeting gets a
folder with the video, audio, and transcript, accessible from a Finder button.

Requires Apple Silicon and macOS 15+. Downloads approximately 1.6 GB of speech
model files during initial setup. Transcription runs locally and works offline
afterward.

<img src="docs/menu-bar.png" alt="Better Meeting menu with About in the top-right corner, Options at the bottom left, and Finder buttons for recent meetings" width="304">

The app's menu, shown with fictional meetings.

## Install with Homebrew

```bash
brew tap --custom-remote kremnyi/better-meeting https://github.com/kremnyi/better-meeting-menubar
brew install --cask kremnyi/better-meeting/better-meeting
open -a "Better Meeting"
```

The tap keeps the name `kremnyi/better-meeting`. If you installed before the
repository was renamed, run the tap command above to update its URL.

The cask downloads the app from [GitHub Releases](https://github.com/kremnyi/better-meeting-menubar/releases)
and verifies its SHA-256 checksum. You can also download the ZIP there, extract
it, and move the app to `/Applications`. Xcode is not required.

Releases use a self-signed certificate, without an Apple Developer ID or notarization. If
macOS blocks the first launch, try opening the app, then use **System Settings
→ Privacy & Security → Open Anyway**. See [Apple's instructions](https://support.apple.com/102445).
Managed Macs may not allow this exception.

Click the **ⓘ** button in the top-right corner to open **About**, with the installed
version, release notes, and **Check for Updates**. Checks and downloads appear in
this menu without separate update dialogs. Sparkle verifies updates with a separate
signing key before extraction.

Enable **Download updates automatically** to check GitHub and prepare updates in
the background. This is off by default. Once ready, click **Restart to Update**
in the main menu to install and reopen the app. A prepared update can also install
when you quit. Recording or
processing must finish before restarting. If macOS requires authorization, click
**Install Update** to continue. Failed updates show an inline retry action.

Homebrew remains available for installation and updates.

To update with Homebrew, finish any active recording, quit the app, and run:

```bash
brew update
brew upgrade --cask kremnyi/better-meeting/better-meeting
```

Releases reuse the same signing certificate so macOS can recognize the app across
updates. Uninstalling the app keeps saved meetings.

## Record a meeting

1. Open the app. If needed, it downloads and prepares the selected speech model
   (Large v3 Turbo by default) in the background. The menu shows progress; you can
   start recording during setup. Transcription waits until the model is ready. If setup
   fails, use **Retry setup**.
2. Enter a meeting name or leave it empty for automatic naming.
3. Open **Options** in the bottom-left corner to choose a display, microphone, and save folder.
   The app remembers these choices. Defaults are the main display, system
   microphone, and `~/Documents/Better Meetings`.
4. Start recording and grant **Screen & System Audio Recording** and
   **Microphone** access. Restart the app if prompted after granting screen access.
5. Stop recording and wait for transcription. Click the folder button beside the
   finished meeting to open its files in Finder.

While recording, separate microphone and system-audio meters show incoming sound.
An empty meter can mean silence; check the selected input if it stays empty while
you expect sound.

The menu-bar icon spins during processing, or stays still with Reduce Motion enabled.
A warning icon appears if recording or transcription fails and stays until you retry
or dismiss the error. Search, Finder, and **Copy Transcript** remain available during
transcription and export; renaming and starting another job wait until processing finishes.

Options groups settings under **Recording**, **Transcription**, and **Files**.
Expand **Video settings** to change **Resolution** and **Frame rate**. The collapsed
row shows the current values, which default to
1440 px and 10 fps. Resolution limits the video's longest edge to 1280, 1440,
1920, or 2560 pixels. It uses Retina pixels, preserves the display's proportions,
and never upscales smaller displays. Frame rate sets a maximum of 5, 10, or
30 fps. Higher settings can increase file size and processing load; macOS manages
compression bitrate. These settings do not affect audio or transcription.

**Advanced transcription → Model** offers multilingual Small, Large v3 Turbo (default), and Large v3.
Small uses less memory; Large v3 takes longer and uses more memory. Each model
is downloaded once and then works offline. Changing models releases the previous
model before loading the next one. The picker waits for active setup to finish.

**Advanced transcription** opens model, vocabulary, and decoding settings in the same panel. Decoding includes temperature,
fallback attempts and temperature increase, no-speech and log-probability thresholds,
and the repetition threshold. Use the back button to return to Options.
**Reset decoding defaults** resets decoding without changing the selected model, vocabulary, or speaker-label option. Model
and decoding settings are saved with each transcript; retries reuse them and changed settings invalidate
cached passes.

**Language** defaults to **Automatic**, with Ukrainian, Russian, and English as candidates.
Automatic transcribes the whole recording
in each candidate language separately, then merges segments by confidence and filters likely silence
hallucinations. Choose one language for a single pass. The app remembers your choice.
Three languages require three passes; progress shows the current language and pass.
Change **Languages** to match the languages you expect. Each selected language
adds one pass; at least one is required. Single-language mode supports any language
listed by WhisperKit.

Use **Advanced transcription → Vocabulary** for names, companies, and technical terms separated
by commas. These optional hints use Whisper's existing prompt support and stay on
your Mac. The app remembers them; changing hints reruns the affected language passes.

**Label speakers** in **Options → Transcription** is off by default. When enabled,
SpeakerKit identifies voices locally after transcription and adds **Speaker 1**,
**Speaker 2**, and so on to the transcript and exported timeline. The first use
downloads about 11 MB of models; later runs use the saved models offline.
This adds processing time. Labels describe voices within this meeting, not real
names or identities across meetings. Each transcript segment gets the speaker
with the most overlapping speech; ties and unmatched segments stay unlabeled.
Fast turn-taking within a segment and overlapping voices can be mislabeled.

The setting is saved with each meeting and is also available in **Re-transcribe…**.
Changing it reuses matching transcription passes. Speaker turns are cached in
`speaker_turns.json`; changing the audio or a damaged cache reruns detection.
If speaker detection fails, the transcript is saved without labels and the menu
shows the error. Cancellation keeps completed passes for a later retry.

The menu shows the 10 most recent completed meetings. Search finds matching titles
and saved transcript text across all completed meetings in the selected folder,
including older meetings and manual Markdown edits. Search runs locally.
If transcription fails,
use **Retry transcription** or **Finish saved recording** to resume from saved
audio or video, including after a restart. When quitting during work, choose
**Finish and quit** or **Wait and quit** to let saving finish. Force Quit or power
loss can leave an unfinished video that cannot be recovered.

**Cancel transcription** stops processing and keeps the recording and completed
language passes. Use **Finish saved recording** to resume later, even after a restart.

Each completed language pass is saved as `pass_uk.json`, `pass_ru.json`, or
`pass_en.json` in the meeting folder. Retry reuses matching passes and reruns any
missing or damaged ones. Changing the audio, model, or decoding options invalidates
the affected cache. Finished transcripts are not regenerated automatically.

Right-click a completed meeting to **Copy Transcript** or **Rename…**. Copy uses
the saved Markdown, including any edits. Rename updates the folder, title, and
metadata while keeping the transcript body and media files.

**Re-transcribe…** lets you choose languages and vocabulary for a saved meeting.
It reuses matching passes and keeps the current transcript available until the
replacement is ready. A successful run replaces the transcript, including manual
edits, while preserving the meeting name. Cancellation or failure keeps the old files.

Before your first recording or retry, the app asks permission to send completion
notifications. Allow them to see when transcription finishes or needs attention;
clicking a notification opens that meeting's folder. You can change this in
macOS **System Settings → Notifications → Better Meeting**.

## Meeting files and titles

```text
2026-09-04 14.30.00 — Product sync/
├── recording.mp4
├── audio.m4a
├── transcript.md
├── transcript.json
├── pass_uk.json
├── pass_ru.json
├── pass_en.json
└── metadata.json
```

`transcript.md` has timestamps and a link to the video. `transcript.json` stores
segment times, text, language tags, and optional speaker IDs. `metadata.json` stores the title,
recording date, duration, file names, and transcription status.

For unnamed meetings, Apple's `NaturalLanguage` framework looks for a person,
company, or product and a repeated topic. A discussion with Anna about a pricing
review might become `Anna — Pricing Review`. The folder, Markdown heading, and
metadata use the same title. Existing folders are never overwritten.

Naming needs no additional model or API. Product names use a heuristic based on
repeated capitalized nouns; recognition varies with the transcript and language
support on the Mac. If no usable name and topic are found, the date-based name
remains. Typed titles and titles from older folders are preserved.

## Screenshots and export bundles

Right-click a finished meeting and choose **Export bundle…**. The app reads the
saved video, extracts screenshots and screen text, and opens `artifacts/` in Finder.
Enable **Options → Files → Include screenshots and screen text** to run this
after each transcript is saved. Automatic export is off by default.

Screen extraction samples every two seconds, keeps screen changes and a frame
at least every 90 seconds, and recognizes text with Apple's Vision framework.
Repeated lines are removed. It exports up to 30 screenshots spread across the
recording, preferring frames with more new text. If no text is recognized, it
still selects screenshots. OCR uses supported languages from the transcript;
small text, rapid changes, and unsupported languages can be missed.

```text
artifacts/
├── transcript.md
├── transcript.json
├── timeline.md
├── screen.json
├── screens/
├── screens_index.md
├── languages.json
├── PROMPT.md
└── HOW-TO.md
```

The timeline combines speech, newly recognized screen text, screenshot links,
and gaps of at least eight seconds between speech segments. `HOW-TO.md` reports
language shares based on transcribed speech duration; `languages.json` stores
the same durations and shares. Percentages exclude gaps and describe language
labels, not recognition accuracy.

The exported Markdown includes manual transcript edits. The timeline and language
shares use the timed JSON segments, which manual Markdown edits do not change.
Audio and video stay in the meeting folder. `PROMPT.md` is a short instruction
for using the bundle with an external assistant; the app does not send it anywhere.

Export runs locally with progress and cancellation. Regenerating replaces the
previous bundle only when the new one is ready. Failure or cancellation preserves
the transcript and any previous bundle. Automatic export failures appear in the
menu without marking the saved transcript as failed.

## Privacy and model storage

Recording, transcription, screenshots, OCR, and automatic naming run on your Mac. The app does not
upload meetings. Update checks contact GitHub. The first speech-model setup downloads files from Hugging Face;
after successful setup, transcription works offline. Removing or damaging those
files can require another download.

Model files live under `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`.
Tokenizer files may also be stored under
`~/Documents/huggingface/models/openai/` for each selected model. WhisperKit calls the
turbo model `openai_whisper-large-v3-v20240930`; its model files total about 1.6 GB.
Selecting a model requires its download once. Downloaded model files are kept when switching.
The first load can take longer while Core ML prepares the model.

Speaker models are downloaded only when processing with **Label speakers** enabled,
under `~/Documents/huggingface/models/argmaxinc/speakerkit-coreml/`.
Speaker detection runs locally and releases its models after each run. Its memory
use also includes the decoded recording, so longer meetings need more memory.

## Build from source

Source builds require Xcode 16 or newer. See [CONTRIBUTING.md](CONTRIBUTING.md)
for building, testing, signing, and publishing releases.

## Limits

- Captures one whole display; window-only and audio-only modes are not available.
- One recording, transcription, or export runs at a time.
- Speaker labels are optional and may need correction; automatic speaker naming is not available.
- Whisper can produce text during silence; the no-speech filter does not catch every case.
- File import, live captions, and meeting summaries are not included.
- The selected display and microphone must be connected when recording starts.

## Project origin and license

This macOS app is based on [GivenFLY/better-meeting](https://github.com/GivenFLY/better-meeting),
which processes existing recordings. The original implementation remains in
that repository and this fork's Git history.

Licensed under [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution
and [ThirdPartyNotices.md](ThirdPartyNotices.md) for dependency licenses.
