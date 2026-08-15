# Vibe Island Clone — Complete Technical Handoff

> Purpose of this file: a self-contained briefing for another AI (or developer)
> so it can answer questions about, debug, or extend this project without any
> other context. Everything below reflects the actual shipped state as of
> 2026-07-17. The original product spec is in `vibe-island-spec.md`; the short
> user-facing readme is `README.md`.

---

## 1. What this is

A native macOS "Dynamic Island" notch app, written from scratch in Swift, that
monitors AI coding agent sessions (Claude Code first-class; the protocol is
agent-agnostic). It is a clone of the commercial app vibeisland.app, built from
a reverse-engineered spec plus screenshots of the real product's UI.

The app shows a black island that merges with the MacBook's physical notch:

- **Hidden** when no agents are active — only Apple's native notch remains.
- **Collapsed pill** while agents run: the black shape covers the notch with
  small side "wings" — a status dot on the left, session count on the right.
- **Expanded panel** on hover/click or when an agent needs the user: a wide
  bell-shaped panel (concave top corners sweeping into the screen edge) with a
  usage strip and compact session rows.
- **Interactive takeovers**: tool-permission approval (diff + Deny/Allow),
  multiple-choice questions (⌘1–⌘9), and plan review — answered right in the
  notch, with the response relayed back to the blocked agent process.
- **Toast**: after answering, a small "✓ <choice>" pill flashes for ~2.6 s.

Fully local: no network calls, no accounts, no telemetry. One-way data flow is
agent hooks → local TCP → UI; the only writes back are hook JSON responses.

**Environment it runs on:** user's MacBook Air (M-series), macOS 26.x, notch
display 1470×956 pt @2x (notch = 179 pt wide, 32 pt tall, spans pixels
1292–1650, center x = 1471 px in 2940-px screenshots), plus an external
1920×1080 monitor. Only the notch display hosts the island.

---

## 2. Repository layout

```
Vibe-Island-Clone/
├── vibe-island-spec.md        # original reverse-engineered product spec
├── README.md                  # short user-facing readme
├── HANDOFF.md                 # this file
├── Package.swift              # SwiftPM manifest (tools 5.10, macOS 14+, one executable target)
├── Assets/VibeIsland.icns     # generated app icon (224 KB)
├── dist/                      # build output: VibeIsland.app + icon.iconset/
├── scripts/
│   ├── make-app.sh            # release build → dist/VibeIsland.app → installs to /Applications
│   ├── make-icon.swift        # regenerates the icon (run: swift scripts/make-icon.swift)
│   ├── demo.sh                # sends fake agent events to a running app
│   └── test-hold.sh           # exercises hold + heartbeat-abandon plumbing
└── Sources/VibeIsland/
    ├── main.swift             # entry; also --install-hooks / --uninstall-hooks CLI modes
    ├── AppDelegate.swift      # status-bar menu, first-launch hook prompt, wiring
    ├── Models.swift           # Session, AgentKind, statuses, wire protocol, JSONValue
    ├── SessionStore.swift     # @MainActor source of truth + persistence + held connections
    ├── EventServer.swift      # TCP 127.0.0.1:43917, hold/heartbeat logic, duplicate-instance guard
    ├── EventHandler.swift     # hook event → Session mutations; decides what to hold
    ├── HookInstaller.swift    # writes hook script + merges ~/.claude/settings.json
    ├── UsageMonitor.swift     # local Claude quota approximation from transcript JSONL
    ├── TerminalJump.swift     # precise tab/pane jump (AppleScript / wezterm cli) + fallbacks
    ├── SoundEngine.swift      # 8-bit synthesized event tones (DEFAULT OFF per user)
    ├── NotchPanel.swift       # NSPanel subclass + controller (position, visibility)
    └── Views/
        ├── NotchRootView.swift    # state machine pill↔panel↔toast, NotchShape, animations
        ├── SessionCardView.swift  # SessionRowView (compact rows)
        ├── RequestView.swift      # permission / question / plan takeovers, DiffPreview, buttons
        └── PixelBotView.swift     # animated pixel-art robot mascot
```

Not a git repository. Built with plain `swift build` — no Xcode project.
Installed app: `/Applications/VibeIsland.app` (LSUIElement=true → no Dock icon;
findable via Spotlight "Vibe Island"; menu-bar sparkle icon while running).

---

## 3. Architecture and data flow

```
Claude Code (any terminal)                    VibeIsland.app
┌──────────────────────────┐                 ┌─────────────────────────────┐
│ hook events (8 types)    │  one JSON line  │ EventServer (NWListener,    │
│ → ~/.vibeisland/         │ ──────────────► │  127.0.0.1:43917, TCP)      │
│   vibe-hook.sh           │                 │   │ decode WireEvent        │
│   (bash + nc)            │ ◄────────────── │   ▼                         │
│ waits for JSON reply     │  hook response  │ EventHandler (@MainActor)   │
└──────────────────────────┘                 │   │ mutates                 │
                                             │   ▼                         │
                                             │ SessionStore (@Published)   │
                                             │   │ observed by             │
                                             │   ▼                         │
                                             │ SwiftUI in a non-activating │
                                             │ NSPanel over the notch      │
                                             └─────────────────────────────┘
```

### 3.1 Wire protocol (agent-agnostic)

One JSON object per TCP connection, newline-terminated. Reply is one JSON line
(Claude Code hook-response format); `{}` means "no opinion". Example:

```json
{"v":1,"source":"claude-code","term_program":"iTerm.app","term_session":"…","tty":"ttys004",
 "payload":{"session_id":"…","hook_event_name":"PreToolUse","tool_name":"Bash",
            "tool_input":{"command":"npm test"},"cwd":"/path"}}
```

- `source` maps to a brand tag/color: claude-code, codex, gemini, cursor,
  opencode, copilot, droid, amp (see `AgentKind` in Models.swift).
- `payload` is the raw Claude Code hook stdin JSON; other agents can mimic it.
- Decoded into `WireEvent`/`HookPayload`; arbitrary `tool_input` handled by a
  custom `JSONValue` enum (Codable free-form JSON with subscript helpers).

### 3.2 Event semantics (EventHandler.swift)

| hook_event_name    | Effect |
|--------------------|--------|
| SessionStart       | create/revive session, status working |
| UserPromptSubmit   | title = first line truncated to 34 chars, full prompt stored separately, status working, clears recap/pending |
| PreToolUse         | append activity entry (max 30 kept); may HOLD (see 3.3) |
| PostToolUse        | fills the last matching activity entry's result detail |
| Notification       | status waiting, recap = message |
| Stop / SubagentStop| status done |
| SessionEnd         | status ended (removed from display) |
| VibeShow           | **debug-only**: expands the panel programmatically (used by tests) |

Also debug: a PreToolUse whose `tool_input` contains key `vibe_force_hold`
is held for GUI approval regardless of settings (testing escape hatch).

### 3.3 Interactive holds (the clever part)

For `AskUserQuestion` and `ExitPlanMode` (always), and for Bash/Edit/Write/
NotebookEdit when a session's per-row "Approve from notch" toggle is on, the
server does NOT reply immediately. It keeps the TCP connection open
("held"), shows a takeover card, and replies only when the user acts:

- **Allow** → `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",...}}`
- **Deny** → same with `"deny"` and a reason.
- **Question answer** → there is no hook mechanism to inject an answer, so the
  app denies the AskUserQuestion tool call with reason
  `User answered via Vibe Island: "<option>". Proceed with this choice; do not re-ask.`
  — the agent reads the denial reason as the user's answer. This works well.
- **Plan approve** → allow on ExitPlanMode (plan accepted); **Revise** → deny
  with the user's typed feedback as the reason.

Hold bookkeeping lives in `SessionStore.pendingReplies`
(`[sessionID: (token: UUID, reply: closure)]`). The token guards against a
stale dead connection clearing a newer request (`abandonPending` is a no-op
unless the token matches the current holder).

**Disconnect detection subtlety:** the hook script pipes into `nc`, and macOS
`nc` half-closes the socket after stdin EOF — so receiving EOF (`isComplete`)
must NOT be treated as client death (the reply path is still open!). Instead
the server sends a heartbeat (a bare newline) every 15 s on held connections;
a failed send means the hook process died (timeout/Ctrl-C) → abandon the card.
The hook script filters blank lines and takes the last non-empty line as the
response. All of this is in `EventServer.dispatch`'s `onHold` closure.

### 3.4 The hook script and installer (HookInstaller.swift)

- Script path: `~/.vibeisland/vibe-hook.sh`. **CRITICAL: the path must contain
  no spaces.** Claude Code executes hook commands via `/bin/sh` unquoted; the
  original location under `~/Library/Application Support/` silently broke
  every hook (`/bin/sh: /Users/…/Library/Application: No such file or
  directory`). This was the single worst bug in the project's history.
- The script: reads stdin; probes `nc -z -G 1 127.0.0.1 43917` and exits
  instantly if the app is down (hooks add ~1 ms when app not running); wraps
  the payload with `source`/`term_program`/`term_session`/`tty` (tty via
  `ps -o tty= -p $PPID`); pipes to `nc -w 3600`; prints the last non-empty
  response line.
- Installer merges entries into `~/.claude/settings.json` for 8 events
  (PreToolUse/PostToolUse with matcher `*`, timeout 3600 for PreToolUse).
  Idempotent: removes any entry whose command contains `vibe-hook.sh`
  (including stale old-path ones) before adding the current one. One-time
  backup at `~/.claude/settings.json.vibeisland-backup`. Full uninstall via
  menu or `--uninstall-hooks`.
- CLI: `/Applications/VibeIsland.app/Contents/MacOS/VibeIsland --install-hooks`
  (or `--uninstall-hooks`) runs headless and exits — no UI.
- First launch shows a plain-language consent dialog (skippable with env
  `VIBE_NO_SETUP=1`, used by automated tests).
- Hooks are snapshotted by Claude Code at session start — sessions already
  running when hooks are installed will never report.
- **Verified fact:** sessions inside the T3 Code harness (the user's main AI
  coding app, which drives `claude` in stream-json mode) DO fire these hooks.
  An earlier theory that SDK mode skips user settings was wrong — the
  space-in-path bug was masking everything.

### 3.5 Session model (Models.swift)

`Session`: id (agent session id), agent (AgentKind), title (short), prompt
(full user prompt), cwd, termProgram/termSession/tty, status
(working/waiting/done/ended), startedAt, lastEventAt, activity
([ActivityEntry] — toolName, summary like `Read(schema.prisma)`, detail like
`1.2 KB` / `Updated`), pendingRequest (PendingRequest: kind
permission/question/plan, title, body, options), recap, approveFromNotch.

Persistence: JSON at `~/Library/Application Support/VibeIsland/sessions.json`
(async save on every mutation; ISO8601 dates). On app launch, restored
sessions get pendingRequest stripped and working/waiting demoted to **ended**
(their hook connections are gone). A session with the same id revives via any
new event (`ensureSession` upserts).

`activeSessions` (what the UI shows): excludes ended, excludes done sessions
whose lastEventAt is older than **5 minutes**; sorted waiting > working >
done, then most-recent-first. A 30 s `tick` timer republishes so elapsed
labels and the 5-minute expiry re-evaluate without events.

---

## 4. The window and UI

### 4.1 Panel mechanics (NotchPanel.swift)

- `NotchPanel: NSPanel` — styleMask `[.borderless, .nonactivatingPanel]`,
  level `.statusBar`, clear background, `canBecomeKey=true` (so ⌘Y/⌘N/⌘1–9
  shortcuts work without activating the app), collectionBehavior
  canJoinAllSpaces + fullScreenAuxiliary + stationary.
- **Gotcha #1:** must override `constrainFrameRect(_:to:)` to return the rect
  unchanged — AppKit otherwise pushes windows below the menu bar and the
  island floats visibly under the notch.
- **Gotcha #2:** `NSHostingView` LEFT-ALIGNS an undersized SwiftUI root. The
  root view needs `.frame(maxWidth:.infinity, maxHeight:.infinity,
  alignment:.top)` or the island renders ~120 pt left of the notch. This was
  found only by pixel-measuring screenshots; it looked "roughly centered" to
  the eye.
- Panel frame: fixed 680×460, top-aligned flush with the screen top, centered
  on the notch's true center (`frame.minX + auxiliaryTopLeftArea.width +
  notchWidth/2` — not `frame.midX`, which can differ by 0.5 pt). SwiftUI
  content morphs inside this fixed window.
- `PanelMetrics` (ObservableObject) publishes notchWidth/notchHeight computed
  from `NSScreen.safeAreaInsets.top` + `auxiliaryTopLeft/RightArea`. On
  non-notch screens both are 0 and the UI falls back to floating-pill styling
  below the menu bar.
- **Visibility rule (user requirement):** when there are no active sessions,
  no toast, nothing waiting, and the panel isn't manually expanded, the window
  is `orderOut` — completely gone, leaving Apple's native notch. It reappears
  (orderFrontRegardless) the moment anything becomes active. Driven by a
  Combine subscription to `SessionStore.objectWillChange` →
  `updateVisibility()`.

### 4.2 The island shape (NotchShape in NotchRootView.swift)

Custom `Shape` with animatable `(bottomRadius, topRadius)`:

- Top edge spans the full width; **top corners are concave "wings"** — quad
  curves with control points that make the outline leave the top edge
  horizontally and merge into the vertical body sides (the "upside-down bell"
  / swoop the user asked for, matching the real Dynamic Island).
- Bottom corners are normal convex rounds.
- With topRadius 0 it degenerates to a flat-topped rounded rect.
- Content gets `.padding(.horizontal, topRadius)` so it stays inside the body
  between the wings.

Radii per state: idle cover (10 bottom, 0 top — blends with the physical
notch's own curve), active pill (16, 8), toast (16, 10), expanded (32, 26).
Expanded panel body width: `max(560, notchWidth + 340)`.

### 4.3 UI states (NotchRootView.swift)

State machine, in priority order: toast → expanded → collapsed.

- **Idle collapsed (notch Mac):** `Color.clear` sized exactly notchWidth ×
  notchHeight — but note the whole WINDOW is hidden when idle (4.1), so this
  is only visible transiently.
- **Active collapsed:** 30 pt wings — left: one 7 pt dot in the
  highest-priority status color (waiting orange > working blue > done green);
  right: session count, rounded 12 pt semibold. No text, no icons.
- **Expanded:** usage strip on top, then either the session rows OR a full
  takeover (if any active session has a pendingRequest, `RequestView` replaces
  the whole list). Empty state text: "No agents working".
- **Toast:** icon + text pill (green/red/orange), auto-dismisses ~2.6 s,
  generation-counted so rapid toasts don't cancel each other wrongly.
- Animation: `.spring(response: 0.45, dampingFraction: 0.72)` on state
  changes; content swaps use a custom transition = blur morph (BlurModifier
  radius 8→0) + opacity + scale(0.96, anchor: .top) — the Apple-style blur
  morph. Shadow: none idle, deeper when expanded. Hairline white stroke
  (0.14) only when expanded.
- **Hover/collapse rules (user-specified):** hover expands. A 1 s repeating
  timer collapses when: expanded ∧ not hovering ∧ nothing waiting ∧ >1 s since
  last hover change ∧ >4 s since expansion (the 4 s grace prevents a panel
  opened via menu/attention from self-closing before the mouse ever enters —
  was a real bug). Clicking inside never collapses (hover stays true).

### 4.4 Session rows (SessionCardView.swift → SessionRowView)

Matches the real product's screenshots:

- Prominent (first) row: animated `PixelBotView` (pixel-art robot, tinted by
  status color, blinks ~every 2.4 s while working), bold title, "You: <full
  prompt>" line (only if it adds info beyond the title), and a status line —
  working: blue "Writing middleware.ts" (verb-ized from the latest activity:
  Edit→Writing, Read→Reading, Bash→Running, Grep→Searching); done: green
  "Done — click to jump"; waiting: orange recap or "Needs your input".
- Other rows: 6 pt status dot + title only.
- Right side of every row: chip tags (agent brand, terminal display name) +
  elapsed time. Chips: 9 pt text on white-0.07 fill with 0.10 hairline.
- Click: `TerminalJump.jump(to:)`, collapses the panel, and if the session was
  done, removes it (click = acknowledge). Right-click context menu: "Approve
  from notch" toggle (enables GUI approval holds for that session) + Remove.

### 4.5 Takeover views (RequestView.swift)

- **Permission:** "• Permission Request" header → "⚠ Edit middleware.ts"
  (tool in orange, target from title) → `DiffPreview` → "+N -M" stats →
  buttons: dark "Deny ⌘N" / WHITE "Allow ⌘Y" (LightButtonStyle, black text —
  matches the real product). DiffPreview colors lines by
  `DiffPreview.kind(of:)` which strips a leading number gutter before
  checking +/-.
- **Diff line numbers:** for Edit tools, `EventHandler.permissionBody` READS
  THE TARGET FILE, locates `old_string`, and emits real line numbers plus one
  context line above/below (`%4d - old` / `%4d + new`); falls back to bare
  +/- lines if the file/string isn't found.
- **Question:** teal accent (0.28, 0.87, 0.74) — "💬 Claude asks" header,
  question text, option rows with ⌘n keycap chips, teal borders, hover
  highlight, `.keyboardShortcut` ⌘1–⌘9.
- **Plan:** "<agent> has a plan" header, scrollable markdown-ish body
  (AttributedString inline markdown), feedback TextField, Revise/Approve.
- Every resolution plays a (default-muted) sound, collapses, and shows a toast
  ("✓ <option>", "Allowed", "Denied", "Plan approved", "Sent back for
  revision").

### 4.6 Usage strip (UsageMonitor.swift + UsageStripView)

"✦ 5h 61% 59m │ 7d 70% 2d22h" — a LOCAL approximation of Claude subscription
quota (no network): scans `~/.claude/projects/**/*.jsonl` (files modified
<15 days, <50 MB, streamed line-by-line), sums weighted tokens
(input + output + cache_creation; cache_read ignored) from
`type=="assistant"` lines. 5 h "blocks" ccusage-style (block start = first
event floored to the hour; new block after 5 h or a 5 h gap); percent =
current block ÷ max block over 14 days (so it's "utilization vs your recent
peak", NOT an official quota); 7 d = trailing sum vs peak trailing sum.
Rescans every 5 min. Orange % when ≥80. Shows "usage —" when no data.

### 4.7 Pixel bot (PixelBotView.swift)

11×8 int grids (0 empty, 1 body, 2 = transparent eye/mouth holes), 1.8 pt
pixels, two frames (open / blink), `TimelineView(.periodic 0.4s)` swaps to the
blink frame every 6th beat while `animating` (status == working). Tinted by
status color. This is the "little pixelated movements" feature.

### 4.8 Terminal jump (TerminalJump.swift)

- Precise (find the exact tab/pane by tty): iTerm2 + Terminal.app via
  NSAppleScript, WezTerm via `wezterm cli list --format json` +
  `activate-pane`. **Gotcha:** the AppleScripts must `return "found"` /
  `return "no"` and the caller must check the string — a script that runs
  fine but matches nothing must count as failure, else the activation
  fallback is skipped and clicks appear dead (was a real bug).
- tty normalization: nil/empty/`"??"` → no precise attempt.
- Fallback: activate the session's terminal app if running, launch it if not;
  if the terminal is unknown, activate the first RUNNING app from a preference
  order (iTerm, Terminal, Ghostty, Warp, WezTerm, kitty, Alacritty, VS Code,
  Cursor, Zed). Bundle-ID map covers ~12 terminals.
- First precise jump triggers the macOS Automation consent prompt
  ("VibeIsland wants to control iTerm2") — expected, one-time.
  `NSAppleEventsUsageDescription` is in Info.plist.

### 4.9 Sounds (SoundEngine.swift)

AVAudioEngine + square-wave PCM buffers rendered in code (8-bit style
melodies per event: done arpeggio, attention two-tone, question triad,
resolve blip). **enabled = false by default — the user explicitly asked for
sounds off.** Toggle in the menu bar. Auto-muted when the screen is locked
(CGSessionCopyCurrentDictionary check).

---

## 5. Build, install, run, test

```sh
swift build                              # debug build (~2 s incremental)
VIBE_NO_SETUP=1 .build/debug/VibeIsland  # run debug without the setup dialog

./scripts/make-app.sh   # release → dist/VibeIsland.app → installs /Applications
open /Applications/VibeIsland.app

swift scripts/make-icon.swift            # regenerate dist/icon.iconset (then iconutil → Assets/VibeIsland.icns)

scripts/demo.sh                # fake session lifecycle (working → done)
scripts/demo.sh question       # live multiple-choice; prints the JSON your click produced
scripts/demo.sh approval       # plan-review takeover
scripts/test-hold.sh           # hold + heartbeat-abandon plumbing check
```

- Duplicate launches: the second instance detects EADDRINUSE on port 43917
  and terminates itself.
- Deps: none. Frameworks: AppKit, SwiftUI, Network, AVFoundation, Combine,
  CoreGraphics. Swift 5.10 language mode (tools-version 5.10) on a Swift 6.2
  toolchain — chosen to avoid strict-concurrency friction.

### 5.1 Verification workflow (important house style)

The user demands "experience it, then report" — never claim UI work done from
code alone. The established loop:

1. Rebuild + reinstall + relaunch (`pkill -x VibeIsland` first).
2. Seed state by piping wire-protocol JSON into `nc 127.0.0.1 43917`
   (see demo.sh for the exact shape; a bash `send()` one-liner works).
3. `screencapture -x -m /tmp/x.png` (main display only), crop with `sips -c H W
   --cropOffset Y X`, and READ the image.
4. For placement claims, don't eyeball: scan pixels (there's a scan.swift
   pattern in /tmp from past sessions — loads the PNG via NSBitmapImageRep and
   prints the dark-pixel span per row; the island must be centered at px 1471
   on this machine).
5. Expand the panel with the debug `VibeShow` event — do NOT try to drive the
   user's mouse with synthetic CGEvents; the user is often actively using the
   machine and clicks race their cursor (this corrupted several test runs;
   one stray click even toggled a session's approve-from-notch).
6. Interactive round-trips can be verified headlessly: hold a question via
   `nc -w 60 … > /tmp/answer.json &`, resolve it (or kill nc and watch the
   heartbeat abandon within ~30 s), inspect the JSON.

### 5.2 Shell gotchas that bit us (macOS bash 3.2)

- Nested `"$( … "${x}" … )"` command substitution mis-parses and brace-expands
  JSON payloads — build JSON in a variable first, then pass it quoted.
- `tty` outside a terminal prints "not a tty" on stdout (breaks JSON) — check
  for `/dev/*` prefix.
- No `timeout` command on macOS by default.

---

## 6. History of major bugs (fixed) — useful for "why is it like this?"

1. **Hook path with spaces** (worst): hooks under `~/Library/Application
   Support/` never ran — `/bin/sh` word-split the unquoted path. Moved to
   `~/.vibeisland/`. Installer now purges any stale entry containing
   `vibe-hook.sh` from settings.json before adding the current path.
2. **Island off-center by 121 pt**: NSHostingView left-aligning an undersized
   root. Fixed with maxWidth-infinity frame; verified by pixel scan.
3. **Panel pushed below menu bar**: default `constrainFrameRect`. Overridden.
4. **AppleScript false success**: jump scripts "succeeded" without matching
   any tab, suppressing the fallback → dead clicks. Now return "found"/"no".
5. **nc half-close mistaken for disconnect**: held approvals were instantly
   abandoned. Now only hard errors or heartbeat-send failures abandon.
6. **Watchdog closing menu-opened panels**: collapse timer fired ~1 s after
   programmatic expansion because no hover had registered. Added 4 s grace.
7. **bash 3.2 brace-expanding JSON** in demo scripts (see 5.2).

### 4.9b VISUAL OVERHAUL (2026-07-21): agent-notch mode — supersedes the
### collapsed-pill descriptions in 4.2/4.3

Per user request the visuals now follow agent-notch (vendored at
vendor/agent-notch/, MIT). Collapsed state: NO black cover — the native notch
stays visible and `MascotBarView` (Views/NotchRootView.swift) renders on a
transparent bar beside the notch's right edge: per-agent slots — the Claude
banner crab (block-character pixel art, `CrabView` in Views/MascotViews.swift,
orange; tinted waiting-orange when something needs the user) walks while any
Claude session works; the official Codex pet (`PetSpriteView`, spritesheets in
Sources/VibeIsland/Resources/pets/, all 8 bundled, selectable via
~/.config/agent-notch/pet — same config file as agent-notch) walks while a GPT
session works; a dithered green blob (`GreenBlobView`) marks done-but-
unacknowledged; activating any known terminal acknowledges
(`SessionStore.acknowledgeFinished()`, observer in AppDelegate,
`Session.acknowledged`). Rows: prompt-led titles, mini walking mascots, green
pixel checkmark (`PixelCheckView`) on done rows, mono model tag + relative
time on the right, `DitherSeparatorView` dividers; acknowledged-done rows dim.
The black bell shape now exists ONLY while expanded or showing a toast
(`showsBlackShape`); positioning inside the container must be LAYOUT-based
(spacer), not `.offset` — offset content escapes the clipShape and turns
invisible (bug hit during the port). The idle → fully-hidden window rule and
5-minute done expiry are unchanged. Debug `VibeShow` no longer creates
sessions.

### 4.9c Usability layer (2026-07-29)

- **Global hotkey** ⌥⌘I (`HotKeyCenter.swift`, Carbon `RegisterEventHotKey` —
  no Accessibility permission needed) toggles the panel from any app. Needed
  because the island is invisible when idle AND macOS hides the status item on
  crowded menu bars.
- **Island right-click menu** (`Views/IslandMenu.swift`, attached to the
  mascot bar and expanded panel): live status summary, pet picker, hook
  install/uninstall, clear finished, quit — the escape hatch for a hidden
  status item.
- **Menu bar badge** (`AppDelegate.refreshBadge`, 2 s timer): grey working
  count → orange waiting count → green ✓ for unacknowledged done, with
  tooltips. Menu also gained a live status header (`menuWillOpen`) reporting
  hook state, listen port, and counts, plus a Codex Pet submenu writing
  `~/.config/agent-notch/pet`.
- **Row activity disclosure**: rows with >1 activity entry show “N steps”;
  expanding lists the last 6 tool calls with their result details.
- **⌘1–⌘9** jump to the Nth session (hidden zero-size buttons in the list's
  `.background`; no conflict with question shortcuts because RequestView
  replaces the list entirely). Tooltips added to rows and the usage strip.
- **Store pruning**: `SessionStore.prune()` caps history at 150 (it had grown
  to 594 in a week, bloating every save/parse).
- **Top-edge gap — DEFENCE IN DEPTH + evidence (2026-08-15).** The gap was
  reproduced live on a long-running instance (rows 0–8 bright ⇒ ~4.5 pt) while
  a freshly launched instance measured perfectly flush — i.e. it **degrades
  over time**, which is why every "fixed it" verification passed. Three
  additions: (1) `Diagnostics.swift` appends to `~/.vibeisland/diagnostics.log`
  (NSLog is invisible in the unified log for this LSUIElement app) — geometry
  is sampled every 60 s plus on every expand and every correction, so the next
  recurrence has numbers attached; (2) `enforceTopFlush()` re-clears
  `hostingView.safeAreaRegions` every heartbeat and publishes any residual
  inset as `PanelMetrics.contentInsetTop`, which `NotchRootView` cancels with
  `.padding(.top, -inset)`; (3) an AppKit `topGuard` CAShapeLayer traces the
  island's own outline (full-width top edge + concave wings, `tr = 26` must
  match `NotchRootView.topRadius`) and is pinned to the window's top edge
  whenever the panel is open — a SwiftUI-independent guarantee. Sized from
  `PanelMetrics.islandFrame`, which the SwiftUI side reports via
  `GeometryReader`; a plain rectangle here visibly squares off the wings.
- **Top-edge gap — POSITIONING cause (2026-08-06).** Separate from the drawing
  bug below, and the reason it kept "coming back at startup or after a while":
  `PanelMetrics.update` decided "notched or not" from
  `screen.auxiliaryTopLeftArea` / `safeAreaInsets`, which macOS returns as
  nil/zero during display wake, space + fullscreen transitions and early
  launch. One blink → `hasNotch == false` → `layout()` used
  `visibleFrame.maxY` → the whole panel sat BELOW the menu bar (a gap of menu
  bar height) and stayed there. Fixes: (1) `layout()` now anchors to
  `screen.frame.maxY` **unconditionally** — an overlay's top edge is the
  screen's top edge; (2) notch dimensions are cached per `CGDirectDisplayID`
  and a degraded reading falls back to the cached value (logged), never to
  zero; (3) `targetScreen` prefers a display *known* to be notched, then the
  built-in; (4) the 2 s heartbeat compares `panel.frame.maxY` against
  `screen.frame.maxY` and logs + corrects drift. Debug event `VibeNudge`
  displaces the panel 40 pt to exercise this — verified: log shows
  `correcting drifted panel top (was 916.0, screen top 956.0)` within 2 s.
- **Top-edge sliver — DRAWING cause (2026-08-05).** Root cause was
  layering, not geometry: `.clipShape` was applied AFTER `.background`, and a
  SwiftUI clip mask is bounded by the view's frame, so it silently erased the
  shape's `topOverdraw` — the very thing meant to cover macOS's ~4.5 pt inset.
  Correct order is now: content → `.clipShape` (content only, no overdraw) →
  `.background(NotchShape(topOverdraw: 40))` unclipped behind it. Second trap:
  the overdraw must be a straight **skirt** above `rect.minY` (extra path
  segments), NOT `rect.minY - overdraw` for the whole rect — shifting the rect
  moves the concave wings off-screen and leaves the top corners transparent
  (measured: bright rows 0–64 at the panel's left edge). Third trap: the gap
  only reproduced in the **request-takeover** state (a held AskUserQuestion /
  plan), never in the session-list state, because that path runs
  `showForAttention()` → `panel.makeKey()`. Always reproduce with a held
  request, e.g. `PreToolUse` + `AskUserQuestion` piped to `nc -w 25`, and
  profile bright bands across rows 0–119 at several x positions (see
  `/tmp/profile.swift` pattern) rather than sampling a few rows.
- **Earlier partial fixes (kept, all still needed)**: (1) `hosting.safeAreaRegions
  = []` stops macOS insetting hosted content from the screen edge; (2)
  `NotchShape.topOverdraw` draws 10 pt above the view's top so a re-applied
  inset still can't expose desktop; (3) **the black is toggled by PRESENCE,
  never by fill colour** — `fill(showsBlackShape ? .black : .clear)`
  interpolates through *translucent* black on every expand, and the bright
  menu bar bleeding through the top edge is exactly what users report as "a
  gap at the top when I hover". The shape now lives behind
  `if showsBlackShape { … }` with `.transition(.identity)` (which also
  suppresses SwiftUI's default fade-in) while its geometry still animates.
  Verified by burst-capturing screenshots during the expand animation and
  scanning the top 8 pixel rows: 0.69 → 0.08 → 0.00 brightness across the
  three iterations. Debug event `VibeHover` reproduces the hover path exactly
  (expand with no re-layout/makeKey); `NotchPanelController.logGeometry` dumps
  window/screen/safe-area numbers.
- **Self-healing visibility**: `updateVisibility()` now always re-asserts
  frame + `orderFrontRegardless` when it should show (never trusting
  `isVisible`), plus a 2 s heartbeat — protection against status-level windows
  being dropped after sleep/display reconfiguration.
- **Hover zone**: the collapsed hover target is notch-width + mascots only
  (was: the full-width invisible positioning spacer, which made the empty
  top-right corner open the panel).
- ⚠️ Testing note: synthetic input injection (CGEvent/System Events) is
  blocked in this environment, so hotkey / click / hover paths are
  code-verified only — verify them by hand.

### 4.9e Hover-to-open (2026-08-15)

Hovering either the walking mascot **or** the physical notch opens the panel.
`MascotBarView` renders an invisible notch-sized `Color.clear` hover target
even when idle, and the active-state zone spans notch + 10 pt gap + mascots
(and nothing beyond). Because `updateVisibility()` orders the main panel out
when idle, an always-present notch-sized `HoverCatcherView` panel (NotchPanel
.swift, level `statusBar - 1`, NSTrackingArea `.activeAlways`) provides the
idle hover target. It is deliberately confined to the notch cutout, which
contains no menu-bar items, so it cannot swallow menu clicks — do NOT
"simplify" this by keeping the full 680×460 panel visible at all times.

### 4.9d UX pass (2026-08-06)

- **Requests no longer pin the panel open.** `isExpanded` was
  `store.expanded || attentionCount > 0`, and the collapse watchdog refused to
  run while anything waited — an unanswered question sat across the top of the
  screen with no way to dismiss it. Now a request opens the panel (EventHandler
  still sets `expanded`) but it tucks back to a **pulsing orange mascot**
  (`AttentionPulse` in MascotViews.swift) after a 12 s grace (4 s for
  non-request opens), or 1.5 s after the pointer leaves. Hover re-opens with
  the request intact; nothing is lost, nothing is answered implicitly.
- **Watchdog timer bug (also fixed):** `Timer.publish` was an *instance*
  property of `NotchRootView`, so every SwiftUI rebuild replaced the publisher
  and restarted its 1 s countdown — under a stream of events it effectively
  never fired. It is now `private static let`. Any future in-view timer must
  be static for the same reason.
- **Queued requests are visible**: when several agents ask at once, the header
  shows an orange `+N more` chip (answer one, the next takes over).
- **Request context line**: `project · terminal · waiting 2m`, so an
  interruption identifies itself when many agents are running.
- **Diagnostic empty state**: if `HookInstaller.isInstalled` is false the panel
  says "Claude Code isn't connected" with a one-click *Set up now*, instead of
  the misleading "No agents working".
- **Esc** collapses the panel; rows show the project name and carry the full
  (untruncated) prompt in their tooltip.

### 4.10 Codex/GPT discovery (CodexWatcher.swift) — added 2026-07-21

Adapted from agent-notch (MIT, github.com/realfishsam/agent-notch). A 3 s
poll on a utility queue: `ps -Axo pid,tty,command` finds claude/codex
processes (deliberately INCLUDING tty `??` — T3 Code spawns agents headless
and they must still count); one batched `lsof -a -p <pids> -Fn` maps codex
pids to their open rollout transcript + cwd. `~/.codex/sessions/**/*.jsonl`
files modified <30 min are parsed (head line → payload.id/cwd/
parent_thread_id; tail 128 KB → model regex, last user_message, last text
snippet; subagent rollouts with parent_thread_id are skipped). Mapping into
the store: written-<30 s = working; working→quiet = done (then the normal
5-min expiry); rollout vanished or process long gone = ended. Codex sessions
are observe-only (no pendingRequests). `TranscriptInfo` in the same file is
shared with Claude model extraction (EventHandler reads the hook's
transcript_path at Stop to fill `Session.model`). The same apply() pass reaps
stuck Claude hook sessions: working + (no claude processes at all ∧ quiet
>2 min) or quiet >30 min → ended. Session rows show a model chip; the
prominent row for codex sessions renders `CodexPetView` — the official Codex
pet spritesheet (Sources/VibeIsland/Resources/pet-codex.webp, bundled via
SwiftPM resources → `VibeIsland_VibeIsland.bundle`, which make-app.sh copies
into Contents/Resources; Bundle.module finds it there). Sheet: 1536×1872,
8×9 frames of 192×208; row 1 from the top = run cycle, ~120 ms/frame.
Revived sessions (ended → new event) reset startedAt so elapsed labels don't
read "93h". Note: replacing the app binary re-triggers macOS folder-access
TCC prompts (ad-hoc signature changes CDHash).

## 7. Known limitations / not implemented (from the spec)

- Only Claude Code has an automatic hook installer (Codex needs none — the
  watcher above covers it read-only). Gemini/etc. would need their own
  adapters; the TCP protocol already accepts any `source`.
- Subagent nesting (spec 4.1), SSH remote (4.10), custom sound packs and
  silence rules (4.8), session switcher hotkeys (4.11), licensing/trial (5),
  landing page (7) — all unbuilt.
- Usage percentages are relative to the user's own 14-day peak, not real plan
  limits (real limits aren't available locally).
- Precise tab jump implemented for iTerm2/Terminal/WezTerm only; everything
  else gets app activation.
- The permission takeover only fires for sessions where the user opted in via
  "Approve from notch" (or the AskUserQuestion/ExitPlanMode interceptions,
  which are always on) — deliberate, so the normal terminal permission flow
  is untouched by default.
- `VibeShow` and `vibe_force_hold` are undocumented debug hooks; harmless
  (localhost only) but could be stripped for a public release.

## 8. User preferences that shape the design (do not regress these)

- Sounds OFF by default.
- Idle = the island fully disappears (window orderOut), native notch only.
  Reappears only when agents are active; done sessions expire after 5 min.
- Hovering while agents are active may expand; collapse ~1 s after mouse
  leaves. When something needs the user it stays open.
- Minimal, Apple-like: no labels/icons in the collapsed pill beyond dot +
  count; bell-swoop top corners; wide expanded panel; blur+spring morphs.
- Clicking a done row acknowledges (removes) it.
- The user judges by screenshots and pixel placement — verify visually before
  reporting, and never call something centered without measuring.
