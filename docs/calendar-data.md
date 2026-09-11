# Calendar event and recording links

Schema version: `1`. Calendar events exist independently of recordings. Scheduled times never replace the recording's `metadata.json.recordedAt` or measured duration.

## Files

- `<meeting>/calendar.json`: an event-occurrence snapshot, invitee details, and auditable matching evidence. It moves with the recording folder and survives retranscription because transcript writers do not touch it.
- `<library>/.calendar/catalog.json`: source calendars, original event definitions, and materialized occurrences. Hidden from the app's meeting-folder scanner.
- `<library>/.calendar/import-report.json`: a decision for every recording, including unmatched records and ambiguous candidates. Uncertain suggestions are not attached to meeting folders.

All files contain personal data and remain local. Do not commit real catalogs, email addresses, calendar exports, or matching reports to the source repository. The import uses only the supplied ICS files; there is no OAuth, calendar subscription, reminder, or remote write.

## Stable identity

| Field | Meaning |
| --- | --- |
| `calendarKey` | Persistent local calendar namespace, initially `ics:` plus SHA-256 of the exported calendar name. Preserve it after import even if the calendar is renamed. |
| `eventId` | SHA-256 of calendarKey, newline, and original iCalendar UID. Stable across title/time edits within the calendar. |
| `iCalendarUID` | Unmodified ICS UID. It is **not** a Google Calendar API event ID. |
| `occurrenceId` | For a recurring instance, SHA-256 of eventId, newline, and original recurrence time; otherwise eventId. |
| `recurrenceId` | Original scheduled occurrence time in UTC, even when an exception moves the actual start. Null for nonrecurring events and master definitions. |
| `meetingId` | Stable local recording-link ID, initially hashed from the recording folder path. Retain its stored value if the folder moves or is renamed. |

One occurrence may link to multiple recording folders (for example, a split recording). A recording has at most one confident event link in version 1. Deduplicate recurring instances by occurrenceId, not title or current start time.

`providerCalendarId` and `providerEventId` are null until a live provider supplies them. A later integration must reconcile its calendar namespace and iCalendar UID/recurrence identity with these imports before assigning provider IDs. Never equate ICS UID with a provider event ID or create a new local calendar namespace merely because the calendar name changed.

## Catalog

`sources[]` stores calendarKey, display name, provider, providerCalendarId, timeZone, original file name, SHA-256, and event-entry count. `importedAt` records when this snapshot was generated, not when the provider last changed an event.

`eventDefinitions[]` preserves standalone events, recurring masters, exceptions, RRULEs, and EXDATE values. `occurrences[]` resolves rules, exclusions, and rescheduled exceptions only inside `expansionWindow` (inclusive start, exclusive end). The current import expands from the day before the earliest recording through January 1, 2027. Future integration should expand a rolling window from the retained definitions; the materialized list is not an infinite calendar.

Each event/occurrence contains:

- Identity fields above, `isRecurring`, title, sourceUpdatedAt, sequence, and source status.
- `scheduledStart` / `scheduledEnd`: ISO-8601 UTC instants for timed events. `timeZone` preserves the source TZID/calendar timezone; UTC values remain authoritative.
- `allDay`, `startDate`, and exclusive `endDate` for all-day events; timed fields are null. All-day events are excluded from automatic recording matching.
- `organizer` and `attendees[]`: email as supplied, normalizedEmail for comparisons, optional name, responseStatus, role, and kind. These represent **invitees, not verified attendance**. Do not fabricate emails or treat ACCEPTED as proof of attendance.
- `conferenceURLs`: Google Meet URLs found in the supplied description/location. No remote URLs are fetched; descriptions and unrelated private text are not copied.
- `cancellationHint`: a title begins with "Canceled:" or "Cancelled:" even if the ICS STATUS still says CONFIRMED. Such events are retained but excluded from automatic matching and must not trigger future reminders without provider confirmation.

## Recording attachment

`calendar.json` contains schemaVersion, meetingId, event, attendeeSemantics, and match. `event` is a full occurrence snapshot, so email search does not depend on opening the central catalog.

`match` records the occurrenceId, matched title and its source, scheduledStart, start-time difference, scoring evidence, method, confidence, linkedAt, and recordedAtAtMatch. Sources may be the current recording title, a preserved original title, or the saved Fireflies response title.

Automatic matches require corroborating title tokens/exact titles or an exact conference code, a bounded time difference/overlap, and a clear score margin over competing events. A score is a ranking heuristic, not a statistical probability. Timing alone is never enough. The importer refuses to replace an existing different sidecar and never rewrites recordings, transcripts, or metadata.

## Search and future integration

The existing search box can search attendee/organizer names and emails, including partial addresses and domains, plus the calendar-event title. Search should include unfinished recordings too, without making them appear transcribed. A missing, unknown-version, or malformed sidecar must not break ordinary title/transcript search.

## EventKit MVP

Options → Calendars enables the integration and explicitly selects calendars already synced with macOS. It defaults off with an empty selection. Calendar permission is requested only from the Allow calendar access button. macOS requires full event access to read calendars; the app has no EventKit save/delete operations. No Google credentials or backend are involved.

While the menu is idle and visible, selected calendars are read for ongoing events and events starting in the next 24 hours. The view refreshes on appearance, every minute while visible, when EventKit announces changes, and when the app becomes active. All-day, ended, cancelled, and current-user-declined events are excluded. Sync freshness depends on macOS Calendar; the app does not force a Google server sync. No events are automatically selected for recording.

The upcoming section lists today's remaining meetings. The first is shown in full — relative timing and a compact record-circle button beside its title, with the tooltip “Record this meeting.” That button records the displayed occurrence with its title and invitee details. Up to two more meetings appear under a muted “Later today” label below a divider, as one-line time and title rows, followed by a muted “N more today” line that opens Calendar. Once today is done, the section reads “No more meetings today.” with a muted line naming the first meeting of tomorrow. The 24-hour read still feeds reminders and the menu-bar preview. The large Start recording button remains a standalone manual action. There is no secondary full-size recording button or “Record another” menu.

Start recording on an event rechecks that exact occurrence after capture permissions, then saves a private, exclusively created `calendar.json` before starting capture. The file uses schemaVersion 1, provider `eventkit`, a recording-local meetingId, an `event` snapshot and a `link` with method `started_from_calendar_event`, linkedAt and recordedAtAtLink. It contains title, scheduled times, calendar name, timezone, organizer and invitees (names/emails/response statuses), and sourceUpdatedAt. Search reads this format and the existing ICS attachments. Calendar details are not descriptions, verified attendance, or speaker identities.

EventKit identity is namespaced separately: calendarKey hashes the EventKit source/calendar identifiers; eventId hashes that namespace and the external identifier (falling back to the local calendar item identifier). occurrenceId additionally uses the original recurrence date for recurring instances, including rescheduled exceptions. providerCalendarId/providerEventId are **EventKit identifiers, not Google API IDs**; externalIdentifier is preserved separately, not asserted to be an ICS UID. EventKit local identifiers can change after a full account sync. The sidecar is a historical snapshot and does not depend on those identifiers remaining resolvable.

There is deliberately no reconciliation with the imported catalog, historical matching, manual linking, automatic recording, or calendar edit. Existing sidecars/catalogs are never updated. Manual recording does not access EventKit. Turning the integration off clears in-memory events and stops reads, retaining selections and saved recording attachments; it does not revoke the OS permission. Permission revocation clears visible event data and prevents event-based recording, while manual recording remains available.

## Meeting-start notifications

Options → Calendars → Notify me when meetings start is separately opt-in and defaults off. Enabling it requests macOS alert/sound permission; denied or disabled alerts show a settings link and retry action. Focus, notification settings, and sleep can silence or delay delivery.

Calendar options group the control under Meeting reminders and omit routine explanatory hints. The summary shows the number of future alerts confirmed in the notification center and the next event. Failed scheduling never counts as success; partial failures retain the confirmed count with an error and retry action. Empty, loading, and permission states remain explicit. Relative timing updates every minute while visible.

When enabled, the app refreshes selected calendars on launch, every minute even with the menu closed, on wake, on activation, and on EventKit changes. It schedules one nonrepeating native notification per upcoming occurrence within the existing 24-hour window, using its absolute start time. Refreshes preserve unchanged requests rather than moving their delivery time. Rescheduling, cancellation, deselection, and revoked permission remove obsolete calendar alerts; turning reminders off removes queued and delivered calendar alerts without touching transcription or audio-warning notifications. Scheduling operations are serialized so a late add cannot survive a subsequent disable.

Notification contents include the event title and occurrence/start identifiers, not invitee emails or transcripts. The banner opens the menu without recording. Only the explicit Start recording action starts capture, after checking the selected occurrence and its scheduled start again. Stale alerts cannot select a different event, and the action never interrupts an active recording or transcription. The application delegate receives its model at launch, independently of opening the menu.

Already scheduled alerts can be delivered by macOS after the app quits, but new events and changes cannot be reconciled while the app is closed. Reopen it to refresh the schedule. Past meeting starts are not replayed when enabling reminders or reopening the app. No server push, calendar edits, automatic capture, or background Google credentials are involved.
