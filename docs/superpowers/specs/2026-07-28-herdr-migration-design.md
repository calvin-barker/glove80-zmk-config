# Herdr migration for agent status keys

Date: 2026-07-28
Status: Approved by Calvin (roster/LED mapping, jump, colors/rollout sections each approved in session)
Predecessor spec: `2026-07-16-agent-status-keys-design.md`

## Why

Calvin's workflow moved from tmux-in-iTerm2 to herdr (https://herdr.dev, installed via Homebrew, v0.7.5), a terminal workspace manager for AI coding agents. The existing glove-agentd pipeline breaks in two places under herdr: sessions register with empty tmux/iTerm identifiers, so `&agent_jump` F-key presses cannot focus anything, and the daemon's session roster no longer matches what Calvin actually sees, which is herdr's sidebar. herdr already tracks every agent and its status in its UI, so the keyboard should mirror herdr instead of maintaining a parallel state model.

Decisions made during brainstorming:

1. herdr becomes the single source of truth for agent status. The Claude Code hook pipeline is removed.
2. Color matching direction: herdr adopts the keyboard's palette via `[theme.custom]` overrides.
3. Integration mechanism: native Unix-socket subscriber, not CLI polling.

## What herdr provides (verified on this machine, herdr 0.7.5, protocol 17)

- Server socket: `~/.config/herdr/herdr.sock` (client socket `herdr-client.sock` alongside it).
- `herdr agent list` returns JSON: per agent `agent` (e.g. "claude"), `agent_status`, `cwd`, `pane_id` (e.g. "w3:p1"), `workspace_id`, `tab_id`, `terminal_id`, `terminal_title`, `focused`, `revision`, `state_change_seq`. List order is workspace order, which matches the sidebar under the default `agent_panel_sort = "spaces"`.
- Agent statuses: `idle`, `working`, `blocked`, `done`, `unknown` (enum `AgentStatus` in the API schema).
- Socket API schema via `herdr api schema --json`: request/response/event/subscription_event schemas. Relevant: `EventsSubscribeParams` (subscribe), a `focus` request, `PaneAgentStatusChangedEvent { pane_id, workspace_id, agent_status, agent, title, state_labels }`, and a `snapshot` request (`herdr api snapshot` prints it).
- `herdr agent focus <target>` focuses an agent's pane inside herdr.
- Status detection is manifest-driven per agent (Claude manifest at `~/.local/state/herdr/agent-detection/remote/claude.toml`, auto-updated). `blocked` fires on Claude's permission/select forms ("enter to select", "esc to cancel"), which is exactly the old needs_input/amber signal. `working` fires on the braille spinner in the OSC title. `unknown` is rare and mostly transitional.
- Theming: `~/.config/herdr/config.toml` (does not exist yet on this machine; herdr runs stock catppuccin). `[theme.custom]` overrides individual palette tokens with hex. Token names `green`, `yellow`, `red`, `accent` validate via `herdr config check`; there are no per-state tokens (`state_idle` etc. are rejected). State icons draw from the palette tokens, so overrides retint every UI element using those tokens, which Calvin accepted.
- `herdr server reload-config` applies config changes to the running server.

## Architecture

All changes live in `~/development/glove-agentd`. The keymap, ZMK firmware fork, and this config repo need no changes; hold-H still arms `LAYER_Agents`, F-keys still send jump HID reports for slots 1..10, and the daemon still drives LEDs over raw HID.

Removed:
- `cmd/glove-agent-hook` and its install into `/usr/local/bin`.
- `internal/ingest` (hook payload parsing).
- `internal/liveness` (PID liveness checks; herdr's roster is the liveness signal).
- `state.json` persistence and the sticky-slot registry semantics in `internal/state`.
- All tmux code in `internal/jump` (`tmux list-clients`, open-tab-and-attach, per-agent iTerm window hunting).
- Hook entries in `~/.claude/settings.json` (uninstall step at deploy time).

Added: `internal/herdr`, a socket client that:
1. Dials `~/.config/herdr/herdr.sock`.
2. Verifies protocol compatibility (protocol 17 at time of writing); logs loudly and retries on mismatch rather than crashing.
3. Fetches a full snapshot, then subscribes to agent-status events.
4. On any disconnect or decode error: drop the connection, clear the roster (all LEDs off), reconnect with backoff, resync from a fresh snapshot.

Kept: `internal/hidio` (LED writes, jump report reads, sleep/wake stuck-handle self-heal), `internal/jump`'s dispatcher worker and iTerm focus-by-tty AppleScript, `internal/config`.

## Roster and LED mapping

Slots are positional, not sticky: slot N is the Nth agent in herdr's agent list. When an agent exits, lower agents shift up, exactly like the sidebar. More than 10 agents: slots 1..10 light, the rest stay dark, and the daemon logs the overflow.

| herdr status | LED color (config key) |
|---|---|
| `working` | working dim (`working`, currently 303030) |
| `blocked` | amber (`amber`, FFB000) |
| `idle` | green (`green`, currently 00E000) |
| `done` | green |
| `unknown` | working dim |
| agent absent | off |
| herdr unreachable | all off; daemon retries with backoff |

Red retires. "Dead session" is no longer a reportable state: a vanished agent goes dark. The `red` config key stays parsed for compatibility but nothing maps to it.

Daemon `config.json` (`~/.config/glove-agentd/config.json`) is unchanged: `green` 00E000, `red` FF0000, `working` 303030, default `amber` FFB000. `ignore_cwd_substrings` becomes unused (herdr only lists real agent panes) and is removed from config parsing.

## Jump

An F-key press arrives as a HID report and goes through the existing single-worker dispatcher. The handler:

1. Resolves the slot to the current roster entry's `pane_id`.
2. Sends a `focus` request for that pane over the herdr socket (equivalent to `herdr agent focus w3:p1`).
3. Raises the iTerm2 session hosting the herdr client, located by the client process's tty (today `ttys009`), reusing the existing focus-by-tty AppleScript. One fixed target replaces the per-agent window hunt that failed on the two-monitor split-pane layout.

The herdr client tty is discovered at runtime (find the `herdr` client process, read its tty) with an optional `config.json` override. Window raise is best-effort: if AppleScript fails, the in-herdr focus still happened and the failure is logged. Empty slot or stale pane: no-op, logged.

## Colors

Create `~/.config/herdr/config.toml`:

```toml
[theme.custom]
green = "#00E000"
yellow = "#FFB000"
red = "#FF0000"
```

Then `herdr server reload-config`. Implementation must verify visually which token colors the `working` spinner icon (likely `accent`); if Calvin wants that aligned with the dim 303030 LED, set it then. This is the only herdr-side change.

## Error handling

- Socket gone (herdr not running): LEDs all off, reconnect loop with capped exponential backoff. No crash, no launchd churn.
- Protocol mismatch after a herdr upgrade: loud log line naming both versions; keep retrying so a compatible herdr restart heals it.
- Event stream gap or decode error: treat as disconnect, resync via snapshot. Never patch state from a possibly-missed stream.
- Jump focus errors: logged, non-fatal, next press retries.
- HID sleep/wake self-heal behavior is untouched.

## Testing

Red/green TDD throughout. Unit tests spin up a fake herdr server on a temp Unix socket serving canned snapshot and event payloads (captured from the real schema) and cover: roster ordering and shifting, status-to-LED mapping including overflow and unknown, reconnect-resync behavior, protocol mismatch handling, and jump focus request emission (fake runner asserts the AppleScript step). The existing `test/integration_test.go` references tmux and must be rewritten against the fake herdr server. `hidio` tests are untouched.

## Rollout

Preconditions in `~/development/glove-agentd` (verified 2026-07-28): the repo sits on `fix/hid-sleep-wake-self-heal` with six modified, uncommitted files, and `main` (69f0c02) is behind the deployed binary (built from 938c232). Step zero: triage the uncommitted changes, land the branch, and fast-forward `main` before starting this work on a fresh feature branch.

Deploy is the established sequence: `make sign`, Calvin copies the binary with sudo from a real terminal, `launchctl kickstart -k gui/$(id -u)/com.calvin-barker.glove-agentd`. macOS grants persist because the code signature is stable. Remove the Claude Code hook entries from `~/.claude/settings.json` at deploy time; `glove-agent-hook` in `/usr/local/bin` can be deleted.

Acceptance: with herdr running four agents, F1..F4 mirror the sidebar top to bottom; blocking one agent turns its LED amber within a beat; hold-H plus that F-key lands focus on that agent in herdr; quitting herdr turns all LEDs off and restarting it brings them back without touching the daemon.

## Out of scope

- Left number row or right-half LED expansion (Plan 3 was rolled back on 2026-07-24; unchanged).
- A distinct LED color for `done` (maps to green for now).
- Multiple herdr clients or named sessions (single local client assumed; tty override exists as the escape hatch).
- Reporting keyboard-side state back into herdr (the API's pane-report endpoints support it, but there is no need).
