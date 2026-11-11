# Vibe Island review — September 10, 2026

## Codex fix delivered

The running app had exhausted its 64 utility workers with `CodexWatcher.run`
readers blocked in `Process.waitUntilExit`. Timed-out polls leaked workers; after
long uptime, discovery stopped updating. Subprocess capture now uses a private
temporary output file, a termination callback, and bounded terminate/kill cleanup.

The old watcher also treated 30 seconds without transcript writes as completion,
read only the final 128 KB, and understood only older user-message events. The
new incremental adapter preserves the complete prompt and model, follows explicit
turn start/completion/interruption events, handles partial JSON and Unicode, and
keeps live owned rollouts visible during long turns. A resumed turn resets its
elapsed time and completion acknowledgement. Metadata identifies T3 Code as the
click destination for the locally observed `t3code_desktop` sessions.

Codex's optional artwork was absent from this checkout. The installed build now
contains the blue Codex robot sprite sheets. Builds without those files use a
separate animated teal robot, rather than a recolored Claude crab. Brand rendering
is shared across the notch, rows, and popup. Hover selection follows the actual
agent's mascot when Claude and Codex are both present. The unsupported Codex
"Approve from notch" control is hidden, and empty-state copy mentions Codex.
Session saves now run in order, preventing an older snapshot from overwriting a
newly discovered session.

## Three focused follow-ups

| Improvement | Why it helps | Small implementation |
|---|---|---|
| Label the usage strip accurately. | The expanded panel showed Claude-derived `5h` and `7d` percentages above Codex-only rows. These are relative to a historical peak, not subscription limits. | In `UsageStripView`, use a visible `Claude activity · estimated` label and suppress the strip when only Codex sessions are present. Keep the existing explanatory tooltip. |
| Scope automatic completion acknowledgement. | Activating any recognized terminal currently acknowledges every finished session, including work in other apps. A completion can disappear before it is seen. | Pass the activated bundle identifier into `SessionStore.acknowledgeFinished`, match session host metadata, and leave unknown-host sessions unacknowledged until explicitly opened. |
| Show shortcut failures where the shortcut is advertised. | `HotKeyCenter` logs registration failures, but the menu and footer continue promising the shortcut. Users get no explanation when another app owns it. | Expose registration success from `HotKeyCenter`; omit the unavailable shortcut hint and show a disabled `Shortcut unavailable` menu item. Keep click-to-open available. |

## One small addition — implemented

Keep the agent's mascot when a turn finishes and add a five-point green completion
dot. Previously, every finished brand became the same green blob. This preserves
identity at a glance, adds no label or new control, and keeps the existing
acknowledgement and five-minute expiry behavior. Implemented in
`MascotBarView.slotView` using the shared mascot plus a bottom-trailing dot.

## Verification and limits

- Release build succeeds; the existing three actor-isolation warnings in the
  panel timers remain.
- `./scripts/test-codex.sh` passes six regression scenarios: desktop metadata and
  long output, completion/resume/interruption, split Unicode/partial writes,
  file truncation/nested subagents, legacy timeout/assistant recap, and 80 process
  launches followed by timeout recovery.
- The installed app discovered the live Vibe-Island-Clone Codex session with its
  model and T3 Code destination. Its expanded rows and collapsed blue robot were
  inspected visually. A temporary Claude session verified both mascots together
  and the completion dot; that test session was then ended. A post-restart
  process sample showed no accumulated
  `waitUntilExit` workers.
- Codex remains observe-only: permissions are answered in its host. Rollout
  fields are a compatibility adapter based on observed local files, not a stable
  external API contract. The [official configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
  documents notification commands; this fix requires no notification or hook
  configuration changes.

## September 25 — disappearing Claude and stranded questions

Confirmed a real parent AskUserQuestion followed by child completion events.
`SubagentStop` shared the parent session ID and was handled like `Stop`, clearing
the request while leaving its reply connection held. The done session then faded
out, making both the mascot and the answer controls inaccessible.

Subagent completion now leaves parent state alone; concurrent tool/notification/stop
events cannot overwrite a held request. SessionEnd releases its connection. The
popup keeps its SwiftUI root stable between changes, supports keyboard focus and
actual option shortcuts, and offers Answer in app to release the hook without
choosing an answer. Multiple-question/multiselect requests use Claude's native UI.
The hook forwarder also identifies T3 Code through process ancestry when the SDK
host omits TERM_PROGRAM.

Release build/install succeeded. `python3 scripts/test-claude-question.py` verified
that SubagentStop, PostToolUse, Notification, and Stop preserve a held question;
the Test answer response reached its waiting socket. The temporary test session
was ended. The real Claude session resumed in T3 Code, and both Claude and Codex
mascots were visually confirmed beside the notch.
