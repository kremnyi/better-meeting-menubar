# Calendar event and recording links

Schema version: `1`. Calendar events exist independently of recordings. Scheduled times never replace the recording's `metadata.json.recordedAt` or measured duration.

## Files

- `<meeting>/calendar.json`: an event-occurrence snapshot, invitee details, and the recording link. It moves with the recording folder and survives retranscription because transcript writers do not touch it.

The file contains personal data and remains local. Do not commit real calendars, email addresses, or calendar exports to the source repository. No OAuth, calendar subscription, or remote write is involved.

## Stable identity

| Field | Meaning |
| --- | --- |
| `calendarKey` | Persistent local calendar namespace, `eventkit:` plus SHA-256 of the EventKit source and calendar identifiers. |
| `eventId` | SHA-256 of calendarKey, a newline, and the external identifier, falling back to the local calendar item identifier. Stable across title and time edits. |
| `occurrenceId` | For a recurring instance, SHA-256 of eventId, a newline, and the original recurrence time; otherwise eventId. |
| `recurrenceId` | Original scheduled occurrence time, null for nonrecurring events and master definitions. |

`providerCalendarId` and `providerEventId` are EventKit identifiers, not Google API IDs. `externalIdentifier` is preserved separately. EventKit local identifiers can change after a full account sync, so the sidecar is a historical snapshot and search never depends on those identifiers remaining resolvable.

## Recording attachment

`calendar.json` contains `schemaVersion`, `event`, and `link`. `event` is a full occurrence snapshot, so email search does not depend on a central catalog. `link` records `method` (`started_from_calendar_event`), `linkedAt`, and `recordedAtAtLink`.

## Search and future integration

The search box matches attendee and organizer names and emails, including partial addresses and domains, plus the calendar-event title. Search includes unfinished recordings without making them appear transcribed. A missing, unknown-version, or malformed sidecar must not break ordinary title/transcript search.

## EventKit MVP

Options → Calendars enables the integration and explicitly selects calendars already synced with macOS. It defaults off with an empty selection. Calendar permission is requested only from the Allow calendar access button. macOS requires full event access to read calendars; the app has no EventKit save/delete operations. No Google credentials or backend are involved.

The selected calendars are read for ongoing events and events starting in the next 24 hours. The view refreshes on appearance; while enabled, the integration also refreshes every minute, when EventKit announces changes, on app activation, and after wake. All-day, ended, cancelled, and current-user-declined events are excluded. Sync freshness depends on macOS Calendar; the app does not force a Google server sync. No events are automatically selected for recording.

The upcoming section lists today's remaining meetings. The first is shown in full — relative timing and a compact record-circle button beside its title, with the tooltip “Record this meeting.” That button records the displayed occurrence with its title and invitee details. Up to two more meetings appear under a muted “Later today” label below a divider, as one-line time and title rows, followed by a muted “N more today” line that opens Calendar. Once today is done, the section reads “No more meetings today.” with a muted line naming the first meeting of tomorrow. The 24-hour read still feeds reminders and the menu-bar preview. The large Start recording button remains a standalone manual action. There is no secondary full-size recording button or “Record another” menu.

Start recording on an event rechecks that exact occurrence after capture permissions, then saves a private, exclusively created `calendar.json` before starting capture. The file uses schemaVersion 1, an `event` snapshot and a `link` with method `started_from_calendar_event`, linkedAt and recordedAtAtLink. It contains title, scheduled times, calendar name, timezone, organizer and invitees (names/emails/response statuses), and sourceUpdatedAt. Search reads this format. Calendar details are not descriptions, verified attendance, or speaker identities.

EventKit identity is namespaced separately: calendarKey hashes the EventKit source/calendar identifiers; eventId hashes that namespace and the external identifier (falling back to the local calendar item identifier). occurrenceId additionally uses the original recurrence date for recurring instances, including rescheduled exceptions. providerCalendarId/providerEventId are **EventKit identifiers, not Google API IDs**; externalIdentifier is preserved separately, not asserted to be an ICS UID. EventKit local identifiers can change after a full account sync. The sidecar is a historical snapshot and does not depend on those identifiers remaining resolvable.

There is deliberately no historical matching, manual linking, automatic recording, or calendar edit. Existing sidecars are never updated. Manual recording does not access EventKit. Turning the integration off clears in-memory events and stops reads, retaining selections and saved recording attachments; it does not revoke the OS permission. Permission revocation clears visible event data and prevents event-based recording, while manual recording remains available.

## Meeting-start notifications

Options → Calendars → Notify me when meetings start is separately opt-in and defaults off. Enabling it requests macOS alert/sound permission; denied or disabled alerts show a settings link and retry action. Focus, notification settings, and sleep can silence or delay delivery.

Calendar options group the control under Meeting reminders and omit routine explanatory hints. The summary shows the number of future alerts confirmed in the notification center and the next event. Failed scheduling never counts as success; partial failures retain the confirmed count with an error and retry action. Empty, loading, and permission states remain explicit. Relative timing updates every minute while visible.

When enabled, the app refreshes selected calendars on launch, every minute even with the menu closed, on wake, on activation, and on EventKit changes. It schedules one nonrepeating native notification per upcoming occurrence within the existing 24-hour window, using its absolute start time. Refreshes preserve unchanged requests rather than moving their delivery time. Rescheduling, cancellation, deselection, and revoked permission remove obsolete calendar alerts; turning reminders off removes queued and delivered calendar alerts without touching transcription or audio-warning notifications. Scheduling operations are serialized so a late add cannot survive a subsequent disable.

Notification contents include the event title and occurrence/start identifiers, not invitee emails or transcripts. The banner opens the menu without recording. Only the explicit Start recording action starts capture, after checking the selected occurrence and its scheduled start again. Stale alerts cannot select a different event, and the action never interrupts an active recording or transcription. The application delegate receives its model at launch, independently of opening the menu.

Already scheduled alerts can be delivered by macOS after the app quits, but new events and changes cannot be reconciled while the app is closed. Reopen it to refresh the schedule. Past meeting starts are not replayed when enabling reminders or reopening the app. No server push, calendar edits, automatic capture, or background Google credentials are involved.
