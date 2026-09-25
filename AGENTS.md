# Better Meeting

## Task context

Read only the documentation relevant to the requested work:
- `README.md` for user-facing behavior and setup.
- `CONTRIBUTING.md` for build, test, packaging, release, or website (`site/`) work; use only the relevant sections.
- `docs/calendar-data.md` for calendar integration, event metadata, and reminders.
- `.impeccable/critique/` contains historical review findings, not standing instructions or a current backlog. Consult these only when relevant and verify findings against current code.

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
