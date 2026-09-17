# Better Meeting

Record a display, system audio, and microphone from the macOS menu bar. After
recording stops, Whisper transcribes the audio locally. Each meeting gets a
folder with the video, audio, and transcript; clicking the finished meeting in
the menu opens its transcript.

Requires Apple Silicon and macOS 15+. Downloads approximately 1.6 GB of speech
model files during initial setup. Transcription runs locally and works offline
afterward.

Project website: [kremnyi.github.io/better-meeting-menubar](https://kremnyi.github.io/better-meeting-menubar/)

<img src="docs/menu-bar.png" alt="Better Meeting menu with a search field and meeting rows grouped by day, each with an action button" width="304">

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

## Update the app

Open **Options → App & updates** to see the installed version, release notes, and
**Check for Updates** below the automatic-download setting. Update progress and
errors stay on that page, without separate update dialogs. Sparkle verifies updates
with a separate signing key before extraction.

Enable **Download updates automatically** there to check GitHub on each launch and
periodically while the app is open, preparing updates in the background. This is off
by default. When an update is ready, **Restart to Update** appears beside **Options**
in the menu footer; click it to install and reopen the app; a prepared update also
installs when you quit. Recording or processing must finish before restarting. If macOS
requires authorization, click **Install Update** to continue. Failed updates show
an inline retry action.

**Include beta releases** on the same page opts into pre-release builds tagged as beta.
They install the same way as stable releases, which still arrive either way. Turn
the toggle off to stop receiving betas. The installed beta stays until a newer
stable release arrives. Beta cuts are published as GitHub pre-releases, so the
repository's latest release always stays on stable.

To update with Homebrew, finish any active recording, quit the app, and run:

```bash
brew update
brew upgrade --cask kremnyi/better-meeting/better-meeting
```

Releases reuse the same signing certificate so macOS can recognize the app across
updates. Uninstalling the app keeps saved meetings and downloaded models; see
[Privacy and model storage](#privacy-and-model-storage) for how to remove the models.

## Record a meeting

1. Open the app.
2. Enter a meeting name or leave it empty for automatic naming. Press Return to
   start recording right away.
3. Open **Options** in the bottom-left corner to choose a display, microphone, and save folder.
   The app remembers these choices. Defaults are the main display, system
   microphone, and `~/Documents/Better Meetings`.
4. Start recording and grant **Screen & System Audio Recording** and
   **Microphone** access. If access is blocked, click **Open System Settings** to enable it,
   then use **Restart Better Meeting** for screen access or **Try again** for microphone access.
5. Stop recording and wait for transcription. Click the finished meeting to
   open its transcript.

The app downloads and prepares the selected speech model in the background when
needed. The menu shows progress; you can record during setup, but transcription
waits until the model is ready. If setup fails, use **Retry setup**.
If Core ML cannot load the model files, the app clears that model's cache so retrying
downloads a fresh copy. Other downloaded models and saved meetings are kept.
Five minutes after the last transcription, the app releases the model from memory;
the next transcription loads it again, which takes a few seconds.

While recording, separate microphone and system-audio meters show incoming sound.
An empty meter can mean silence; check the selected input if it stays empty while
you expect sound.

The meeting name stays editable while recording; a name typed or changed then is
used when recording stops. The menu bar shows the elapsed time beside the icon;
turn off **Show recording time in the menu bar** in **Options → App & updates** to
hide it.

If neither source has detected audio after 30 seconds, an amber warning replaces
the recording status. With the menu closed, the app also sends one notification;
click it to open the recording controls. Recording continues. The warning clears
when either source detects audio, and later pauses do not trigger another warning.

The menu-bar icon spins during processing, or stays still with Reduce Motion enabled.
A warning icon appears if recording or transcription fails and stays until you retry
or dismiss the error. Search, Finder, and **Copy Transcript** remain available during
transcription and export; renaming and starting another job wait until processing finishes.

Before your first recording or retry, the app asks permission to send notifications
for missing audio and transcription results. Click an audio warning to open the
recording controls. Click **Transcript ready** to open the transcript, or use its
**Copy Transcript** and **Show in Finder** actions; a notification about a failed
transcription opens the meeting's folder.
You can change notification access in macOS **System Settings → Notifications
→ Better Meeting**.

To open the app automatically when you sign in, enable **Launch at login** in
**Options → App & updates**.
If macOS requires approval, use **Open Login Items…** below the checkbox and allow
Better Meeting to open at login.

## Calendar integration

The menu can show your meetings from the macOS Calendar app. Enable
**Use calendar** in **Options → Meetings** and choose which calendars to read. The menu lists
today's remaining meetings, with a **Record this meeting** button on the first
one that starts a recording named after the event. It becomes a labeled
**Record** button once the meeting is under way or starts within five minutes.
Once today is done the menu names the first meeting of tomorrow. With **When a calendar meeting starts** enabled
under **Suggest recording**, the app also sends a notification when the event starts.

The integration is off by default, reads events only, and never edits them.
macOS requires full calendar access for reading; the app offers to request it
when you first enable the feature. Event details stay on your Mac. Links
between recordings and calendar events are stored in the meeting folder; see
[docs/calendar-data.md](docs/calendar-data.md) for the data model.

## Calls that are not on the calendar

Enable **Detect meetings automatically** under **Suggest recording** in **Options → Meetings**
for meetings nobody scheduled. It works with the calendar turned off. When another app has been using the microphone for
half a minute, the app sends a notification with **Start recording**; nothing is
recorded until you click it. macOS reports only that some app is recording, never
what it records, so this needs no extra permission and reads nothing from the other
app. Dictation, Voice Memos, and other short microphone use can still trigger it.
The option is off by default.

## Recording settings

Options groups settings under **Recording**, **Transcription**, and **Files**.
Rows below them open the **Calendars**, **Advanced transcription**, and **App &
updates** pages; the arrow beside each page title returns to Options. Settings stay
available after an error. Display, microphone, and video quality lock only while
recording. Transcription settings, including **Advanced transcription**, lock only
while a transcription runs; changes made during a recording apply when it stops.
The save folder and automatic export lock during either. Calendars and App &
updates never lock, so a prepared update can install as soon as the meeting finishes.
The **Video** menu under Recording sets **Resolution** and **Frame rate**, which default
to 1440 px and 10 fps. Resolution
limits the video's longest edge to 1280, 1440, 1920, or 2560 pixels. It uses
Retina pixels, preserves the display's proportions,
and never upscales smaller displays. Frame rate sets a maximum of 5, 10, or
30 fps. Higher settings can increase file size and processing load; macOS manages
compression bitrate. These settings do not affect audio or transcription.

## Transcription settings

### Engine

**Advanced transcription → Engine** chooses the transcription engine. **Parakeet v3** is
the default: it runs one fast pass with automatic language detection and punctuation
for 25 European languages, including Ukrainian, Russian, and English; its model is
about 470 MB and downloads once. **Whisper** supports every language WhisperKit lists
and runs one pass per selected language; choose it for other languages. Settings
saved before Parakeet became the default switch to it unless their languages include
one Parakeet doesn't support, and meetings already transcribed with Whisper keep
Whisper when you retry or re-transcribe them. The
language, model, vocabulary, and decoding rows apply to Whisper only. Changing
engines only downloads the model if it is missing; it loads on the next
transcription. Parakeet segments get a script-based uk/ru/en tag for the
transcript and bundles — treat it as a hint, not model output. **Advanced transcription →
Models** lists every model with its size, where each one can be deleted or
downloaded ahead of time.

### Languages

When Whisper is selected, choose the expected **Languages** in one menu.
Ukrainian, Russian, and English are selected by default. Choose one for a
single pass or several for multilingual
meetings; at least one is required. The app remembers your selection.

Each selected language adds one pass over the whole recording. The app merges
segments by confidence and filters likely silence hallucinations. Fewer languages
finish faster. Progress shows the current language and pass. All languages listed
by WhisperKit are available.

### Model

**Advanced transcription → Model** offers multilingual Small, Large v3 Turbo
(default), and Large v3.
Small uses less memory; Large v3 takes longer and uses more memory. Changing
models downloads it if it is missing; it loads on the next transcription. The
picker waits for an active download to finish.

### Vocabulary

Use **Advanced transcription → Vocabulary** for names, companies, and technical terms separated
by commas. These optional hints use Whisper's existing prompt support and stay on
your Mac. The app remembers them; changing hints reruns the affected language passes.

### Decoding

**Advanced transcription** shows engine, model, and vocabulary settings with
**Decoding** right below them. It expands temperature, fallback attempts and
temperature increase, no-speech and log-probability thresholds, and the repetition
threshold. Downloaded models are listed last on the page.

**Reset decoding defaults** resets decoding without changing the selected model,
vocabulary, or speaker-label option. Model and decoding settings are saved with
each transcript; retries reuse them and changed settings invalidate cached passes.

### Speaker labels

**Options → Transcription → Add speaker labels** is off by default. When enabled,
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

## Saved meetings

The menu lists all completed meetings under day headings, most recent first, with
each meeting's start time and length; scroll to see older ones. The folder button
beside **Recorded meetings** opens the meetings folder. Search finds matching titles
and saved transcript text across all completed meetings in the selected folder,
including older meetings and manual Markdown edits. Search runs locally. While the
menu is open, ⌘F searches, ⌘, opens Options, and ⌘Q quits.

Click a meeting to open its transcript; recordings that are not transcribed open
their folder instead. Use the **•••** button on a meeting row, or right-click the
row, for **Open Transcript**, **Show in Finder**, **Copy Transcript**, **Rename…**,
**Re-transcribe…**, **Export bundle…**, and **Move to Trash**.
Copy uses the saved Markdown, including any edits. Rename updates the folder,
title, and metadata while keeping the transcript body and media files. Move to
Trash moves the whole meeting folder to the macOS Trash, so you can still restore it
from there.

After a transcript is saved, the menu offers **Open Transcript**, **Copy Transcript**,
and **Show in Finder** below the confirmation.

### Re-transcribe a meeting

**Re-transcribe…** lets you choose languages and vocabulary for a saved meeting.
It reuses matching passes and keeps the current transcript available until the
replacement is ready. A successful run replaces the transcript, including manual
edits, while preserving the meeting name. Cancellation or failure keeps the old files.

### Transcribe all unfinished recordings

When recordings failed, were cancelled, or are waiting for transcription, the
menu shows their count with **Transcribe**, or **Transcribe all** for several; the
arrow beside it picks a single recording. Choosing it transcribes them in
order; progress shows **Transcribing 2 of 3** plus the current meeting and the
number still waiting, and the list marks the current meeting with its progress and
the rest as **Queued**. Cancel stops the queue and reports how many finished;
every recording keeps its completed language passes. If you quit while the
queue runs, the app asks whether to wait until it finishes.

### Retry or cancel transcription

If transcription fails, use **Retry transcription** or **Finish saved recording**
to resume from saved audio or video, including after a restart. When quitting during work, choose
**Finish and quit** or **Wait and quit** to let saving finish. Force Quit or power
loss can leave an unfinished video that cannot be recovered.

**Cancel** next to the progress bar stops processing and keeps the recording and completed
language passes. Use **Finish saved recording** to resume later, even after a restart.

Each completed language pass is saved as `pass_uk.json`, `pass_ru.json`, or
`pass_en.json` in the meeting folder. Retry reuses matching passes and reruns any
missing or damaged ones. Changing the audio, model, or decoding options invalidates
the affected cache. Finished transcripts are not regenerated automatically.

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
`pass_<language>.json` files are per-language transcription caches reused when the same
recording is transcribed again; they are safe to delete. Re-transcription keeps the
earlier transcript files in a hidden staging folder until the replacement is saved; if
restoring them fails, the error message names the folder that still holds them. A failed
rename restores the earlier files in place.

For unnamed meetings, Apple's `NaturalLanguage` framework looks for a person,
company, or product and a repeated topic. A discussion with Anna about a pricing
review might become `Anna — Pricing Review`. The folder, Markdown heading, and
metadata use the same title. Existing folders are never overwritten.
Long folder names are shortened to fit filesystem limits; the title inside the meeting stays intact.

Naming needs no additional model or API. Product names use a heuristic based on
repeated capitalized nouns; recognition varies with the transcript and language
support on the Mac. If no usable name and topic are found, the date-based name
remains. Typed titles and titles from older folders are preserved.

## Screenshots and export bundles

Choose **Export bundle…** from a finished meeting's **•••** menu or right-click.
The app reads the
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

Recording, transcription, screenshots, OCR, and automatic naming run on your Mac.
The app does not upload meetings. Update checks contact GitHub. Speech models
download from Hugging Face once per selected model and work offline after setup.
Removing or damaging those files can require another download.

Model files live under `~/Library/Application Support/BetterMeeting/`. Whisper
models are in `models/argmaxinc/whisperkit-coreml/`; tokenizer files are stored
under `models/openai/`. WhisperKit calls the turbo model
`openai_whisper-large-v3-v20240930`; its model files total about 1.6 GB.
Downloaded model files are kept when switching. The first load can take longer
while Core ML prepares the model.

Parakeet models live under `models/parakeet-tdt-0.6b-v3/` (about 470 MB) and are
downloaded while Parakeet is the selected engine, which it is by default. The FluidAudio runtime is
Apache-2.0; the model weights are CC-BY-4.0, © NVIDIA Corporation. See
[ThirdPartyNotices.md](ThirdPartyNotices.md).

Speaker models are downloaded only when processing with **Add speaker labels** enabled,
under `models/argmaxinc/speakerkit-coreml/`. Speaker detection runs locally
and releases its models after each run. Its memory
use also includes the decoded recording, so longer meetings need more memory.

**Advanced transcription → Models** lists every model. Downloaded ones show
their size with a **Delete** button; models that are missing show their
approximate download size with a **Download** button, so they can be fetched
ahead of time. Progress appears on the row during a download, **Show models
folder** opens the whole folder, and a deleted model downloads again the next
time it is needed. Deleting one that is in memory releases it first.

Updating from an earlier version moves models stored under
`~/Documents/huggingface/` to the new location on first launch, so they are not
downloaded again. Removing the app does not delete saved meetings or downloaded
models. To free the model files, delete them under **Advanced transcription → Models**, or run
`brew uninstall --zap --cask kremnyi/better-meeting/better-meeting` if you
installed with Homebrew. Saved meetings are always kept.

## Build from source

Source builds require Xcode 16 or newer. See [CONTRIBUTING.md](CONTRIBUTING.md)
for building, testing, signing, and publishing releases.

## Limits

- Captures one whole display; window-only and audio-only modes are not available.
- Transcription and export run one at a time; a recording can start while transcription finishes in the background.
- Speaker labels are optional and may need correction; automatic speaker naming is not available.
- Whisper can produce text during silence; the no-speech filter does not catch every case.
- Parakeet v3 covers 25 European languages; choose Whisper for other languages.
- File import, live captions, and meeting summaries are not included.
- The selected display and microphone must be connected when recording starts.

## Project origin and license

This macOS app is based on [GivenFLY/better-meeting](https://github.com/GivenFLY/better-meeting),
which processes existing recordings. The original implementation remains in
that repository and this fork's Git history.

Licensed under [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution
and [ThirdPartyNotices.md](ThirdPartyNotices.md) for dependency licenses.
