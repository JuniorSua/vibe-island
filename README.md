# Vibe Island

A native macOS app that turns the MacBook notch into a live control surface for
your AI coding agents. Mascots walk beside the notch while agents work; hover to
see every session; approve tool calls, answer questions and review plans without
leaving the window you're in.

Written in Swift + SwiftUI, no Electron, no dependencies. **Fully local** — no
network calls, no accounts, no telemetry.

```
swift build && ./scripts/make-app.sh    # → /Applications/VibeIsland.app
```

./scripts/install-autostart.sh   # start at login + restart if it ever dies

Requires macOS 14+. Plain SwiftPM, no Xcode project.

---

## What it does

**Watches your agents.** Claude Code sessions report in through hooks; Codex
(GPT) sessions are discovered with zero configuration by matching running
processes to their transcripts. Each session shows its prompt, live activity,
model, project and elapsed time.

**Answers for you.** When an agent needs input, a small popup appears under
its mascot — the island never expands on its own:

| Request | What you get |
|---|---|
| Tool permission | Real diff with file line numbers, `+N -M` stats, **Deny ⌘N** / **Allow ⌘Y** |
| Question | The question with clickable options on **⌘1–⌘9** |
| Plan review | Rendered plan, a feedback field, approve or send back |

The agent is genuinely blocked while you decide — the app holds its hook
connection open and replies with your answer.

**Gets out of the way.** Idle, the window is removed entirely: only Apple's
native notch remains. Finished sessions fade out after five minutes. An
unanswered request tucks itself into a pulsing mascot rather than camping on
your screen.

**Takes you back.** Click a session to jump to the exact terminal tab or pane
that's running it (iTerm2, Terminal.app and WezTerm by tty; app activation for
Ghostty, Warp, kitty, Alacritty, VS Code, Cursor, Zed and others).

## Controls

| | |
|---|---|
| Peek a task | **Hover the walking mascot** → a popup with the task + live status |
| Answer a question | Click an option in the popup, or **⌘1–⌘9** |
| Open the full session list | Click the mascot · **⌥⌘I** from anywhere · **Esc** to dismiss |
| Jump to a session | Click its row · **⌘1–⌘9** |
| See recent tool calls | Click **“N steps”** on a row |
| Settings | Right-click the island (or the menu bar icon) |

## How it works

```
agent hook ──▶ ~/.vibeisland/vibe-hook.sh ──▶ TCP 127.0.0.1:43917 ──▶ event engine
                                                    │                      │
                                     holds the connection open       Session model
                                     until you answer                      │
                                                                   SwiftUI in a
                                                            non-activating NSPanel
```

- **Hook layer** — a one-time merge into `~/.claude/settings.json` (backed up,
  fully reversible from the menu). The forwarder exits in ~1 ms when the app
  isn't running.
- **Event engine** — normalises hook events into a common `Session` model.
  Interactive tools (`AskUserQuestion`, `ExitPlanMode`, and Bash/Edit/Write when
  you opt in per session) are *held*: the TCP connection stays open, with 15 s
  heartbeats to detect a dead client, and the reply carries your decision.
- **Codex/GPT discovery** — `ps` + a batched `lsof` map running `codex`
  processes to their `~/.codex/sessions` transcripts; recent writes mean busy.
  No hooks, no config.
- **Usage** — the 5-hour and 7-day quota strip is computed locally from your own
  transcripts (utilisation against your busiest window in the last 14 days).
- **UI** — a non-activating `NSPanel` pinned to the notch, with a custom
  `NotchShape` (full-width top edge, concave "bell" flares) and spring/blur
  morphs between states.

## Adding another agent

The protocol is agent-agnostic. One JSON line in, one JSON line back:

```json
{"v":1,"source":"my-agent","term_program":"iTerm.app","tty":"ttys004",
 "payload":{"session_id":"…","hook_event_name":"PreToolUse","tool_name":"Bash",
            "tool_input":{"command":"npm test"},"cwd":"/path"}}
```

Reply `{}` for "no opinion", or a Claude Code hook response to allow/deny.

## Repo layout

```
Sources/VibeIsland/
  EventServer.swift     TCP listener, held connections, heartbeats
  EventHandler.swift    hook events → session state; decides what to hold
  SessionStore.swift    source of truth, persistence, pending replies
  CodexWatcher.swift    hookless GPT/Codex discovery
  UsageMonitor.swift    local quota approximation
  TerminalJump.swift    per-terminal jump adapters
  NotchPanel.swift      window geometry, visibility, top-edge guarantees
  Views/                island shape, mascots, session rows, request cards
scripts/                build/install, icon generation, demo & test harnesses
```

`HANDOFF.md` is a deep technical companion — architecture plus a log of the
non-obvious bugs this app ran into (AppKit safe-area insets at the screen edge,
SwiftUI clip masks eating overdraw, `nc` half-close semantics, unreliable
`NSScreen` notch reporting) and how each was diagnosed.

## Try it without an agent

```sh
scripts/demo.sh            # a fake session: prompt → tool activity → done
scripts/demo.sh question   # a live question — answer it in the notch
scripts/demo.sh approval   # a plan review
```

## Credits

- Mascot presentation and the hookless process-discovery approach are adapted
  from [agent-notch](https://github.com/realfishsam/agent-notch) (MIT).
- Codex pets are OpenAI's official sprite sheets, fetched by
  `scripts/fetch-pets.sh` rather than redistributed here.
- The concept — a notch UI for AI agents — is inspired by the commercial app
  [Vibe Island](https://vibeisland.app). This is an independent personal
  reimplementation, not affiliated with it.

## License

MIT — see [LICENSE](LICENSE).
