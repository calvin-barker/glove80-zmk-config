# Agent Status Keys for the Glove80

Date: 2026-07-16
Status: Approved design, pending implementation plan

## Context

Calvin runs 2-10 Claude Code agents in tmux sessions inside iTerm2, often detaching to let them run in the background. Sessions frequently sit blocked (waiting on a permission prompt) or idle (turn finished) without anyone noticing, wasting wall-clock time. Inspired by the OpenAI Codex Micro (Work Louder) macropad, this project turns the Glove80's F-row into live agent status lights with a jump-to-session action.

Design principle: **dark by default**. A light means a human is needed. No light means the slot is empty or the agent is working.

## User experience

- Slots 1-10 map to F1-F10 (F1-F5 left half, F6-F10 right half). Phase 1 ships slots 1-5 only.
- LED semantics, drawn from the Codex Micro palette but inverted to dark-by-default:
  - **Off**: empty slot, or agent actively working
  - **Amber**: needs input (permission prompt or question)
  - **Green**: turn finished, idle, output waiting
  - **Red**: session died (process gone, crash)
  - **Violet**: Agents layer armed (local firmware effect). Phase 1 renders it on the unlit F-row slot LEDs, which doubles as a map of live jump targets; phase 2 moves it to the H key itself (see Amendments)
- Jump gesture: hold H (a TailorKey-style layer-tap, like the existing home-row mods) to arm the Agents layer, then tap a lit F-key. Tap always jumps; there is no kill gesture on the keyboard.
- Jumping to a red (dead) slot acknowledges and clears it instead of jumping.
- Slot assignment: a new Claude Code session claims the lowest free slot and keeps it until it ends or dies. Dead slots are reused last so a red light is never silently repurposed. Sessions beyond the slot cap queue for the next free slot in registration order.
- Keyboard is used wired over USB. Bluetooth transport is out of scope.

## Architecture

Three subsystems, one owner each. If the daemon is not running, the keyboard behaves exactly like a stock Glove80.

1. **Firmware**: fork of `moergo-sc/zmk` (branch `agent-status`) adds a raw HID endpoint, an LED overlay for the F-row, and a jump behavior.
2. **This repo** (`glove80-zmk-config`): keymap changes only, plus pointing the build at the fork.
3. **`glove-agentd`** (new repo): a Go daemon on the Mac that tracks Claude Code sessions via hooks and drives the LEDs, plus a hook client and launchd plist.

Data flow: Claude Code hooks -> Unix socket -> daemon state machine -> raw HID LED frames -> keyboard. Jump: keyboard raw HID message -> daemon -> tmux/iTerm2 scripting.

## Firmware (fork of moergo-sc/zmk)

- **Raw HID endpoint**: vendor-defined usage page 0xFF60, usage 0x61 (zmk-raw-hid / QMK convention), 32-byte reports, coexisting with the normal keyboard interfaces. USB only.
- **LED overlay**: paints received colors onto the ten F-row LED positions. Black means no overlay; the LED falls back to normal underglow behavior. All other LEDs are untouched. If no host message arrives for 120 seconds, the overlay clears itself so a crashed daemon cannot leave stale lights.
- **Jump behavior**: `&agent_jump N` sends a JUMP message upstream instead of a keycode.
- **Layer indicator**: while the Agents layer is active, slot LEDs that are currently unlit render dim violet (firmware-local, no host round trip). Violet on the H key itself is deferred to phase 2; see Amendments.
- **Split relay (phase 2)**: a custom split-transport command forwards the five right-half slot colors from the central (left) half to the peripheral (right) half. Until then the daemon caps usable slots at 5.

### Protocol v1

Byte 0 is protocol version (0x01), byte 1 is the command.

| Direction    | Command        | Payload                                    |
| ------------ | -------------- | ------------------------------------------ |
| host -> kbd  | 0x02 HELLO     | none; firmware replies with version and slot capability (5 or 10) |
| host -> kbd  | 0x01 SET_LEDS  | 10 slots x RGB, 30 bytes, always a full frame (idempotent) |
| kbd -> host  | 0x10 JUMP      | byte 2 = slot number 1-10                  |

The daemon re-sends SET_LEDS every 30 seconds as a heartbeat and immediately on any state change or keyboard reconnect.

## Keymap changes (this repo)

- New `LAYER_Agents` layer node: F1-F10 positions bind `&agent_jump 1..10`; every other position is `&none` so a stray press while armed types nothing.
- H on the base (HRM_macOS) layer changes from `&kp H` to a hold-tap: tap types h, hold is `&mo LAYER_Agents`. Tuning mirrors the existing TailorKey home-row mods (balanced flavor, require-prior-idle) so fast sequences like "th" never misfire.
- Known quirk: the Typing layer inherits H via `&trans` so hold-H works there; the Autoshift layer redefines H, so the agents hold is unavailable while Autoshift is toggled on. Accepted.
- `config/glove80.conf` gains the Kconfig options the fork requires (raw HID, agent status feature flag).
- `build.sh`, `build.bat`, and CI are parameterized to build against the fork instead of `moergo-sc/zmk` main.

## Daemon (glove-agentd, new repo)

Go, single static binary, launchd-managed. Components:

- **Hook client** (`glove-agent-hook`): configured in user-level `~/.claude/settings.json` for SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd. Forwards the hook's stdin JSON plus identity from its environment (tmux session name and pane via `$TMUX_PANE`, `$ITERM_SESSION_ID`, Claude process PID) to the daemon's Unix socket. Fire-and-forget, 100ms timeout, silent failure so Claude Code is never slowed.
- **Session registry**: keyed by Claude session ID; records slot, state, tmux identity, iTerm session ID, PID, cwd, last event time. Persisted to disk so a daemon restart re-verifies liveness and restores lights.
- **State machine** per session:

  | Event               | State       | LED   |
  | ------------------- | ----------- | ----- |
  | SessionStart        | working     | off   |
  | UserPromptSubmit    | working     | off   |
  | Notification        | needs input | amber |
  | Stop                | idle        | green |
  | SessionEnd          | slot freed  | off   |
  | liveness poll fails | dead        | red   |
  | jump on dead slot   | slot freed  | off   |

- **Liveness**: every 5 seconds, `kill -0` on each recorded PID. Works identically for tmux and bare-pane sessions.
- **LED writer**: opens the vendor HID interface via hidapi, reconnect loop on unplug, full frame on every change, reconnect, and heartbeat tick.
- **Jump executor**, resolution order:
  1. Dead slot: acknowledge and clear.
  2. tmux session with an attached client: find the iTerm session hosting that client by matching the tmux client tty against iTerm session ttys via AppleScript (`osascript`), focus it, and activate iTerm2. Fall back to the recorded iTerm session ID if no tty match is found.
  3. tmux session detached: new iTerm tab running `tmux attach -t <name>`.
  4. Bare pane (no tmux): focus the recorded iTerm session directly.
- **Operability**: `glove-agentd status` prints the slot table (slot, session, state, location). Config file (colors, slot cap, poll interval, socket path). Structured log file.
- macOS permissions: one-time Automation approval for controlling iTerm2. No Accessibility or Input Monitoring needed.

## Error handling

- Keyboard unplugged: daemon retries, pushes a full frame on reconnect.
- Daemon crash or stop: firmware clears the overlay after 120 seconds.
- Daemon restart: registry reloaded from disk, PIDs re-verified, frame re-sent.
- Claude crash without SessionEnd: caught by the liveness poll, slot goes red.
- Hook fires with daemon down: dropped silently; the next event repaints state.
- More sessions than slots: queued in registration order; logged.

## Testing

- **Daemon**: red/green TDD in Go. State machine transitions, slot assignment rules (lowest free, dead reused last, queueing), protocol encode/decode, and registry persistence are all unit-tested against fakes (fake HID device, fake clock, fake process prober).
- **Firmware**: no automated test harness exists for the MoErgo fork. Validation is a successful Nix/Docker build plus a hardware bench checklist: frame renders correctly, heartbeat timeout clears the overlay, JUMP arrives at the host, violet-on-hold works, keyboard is stock-normal with the daemon off.
- **Integration**: a scripted harness fires fake hook events at the socket and asserts on the frames written to a fake HID device; on hardware, an acceptance walkthrough covers each state color and each jump case (attached, detached, bare pane, dead).

## Build order

1. **Firmware pipe**: raw HID endpoint + LED overlay (left half) in the fork; Agents layer + hold-H in this repo; a throwaway script pushes colors to prove the pipe.
2. **Daemon core**: socket, state machine, slot registry, LED writer, hook configuration. Hooks light LEDs end to end.
3. **Jump path**: JUMP handling, tmux/iTerm resolution, new-tab attach.
4. **Split relay**: central-to-peripheral forwarding in the fork; slot cap raised to 10.

Each step lands independently and leaves the keyboard usable.

## Out of scope

- Bluetooth transport for the raw HID protocol
- A kill gesture on the keyboard (tap always jumps)
- Terminals other than iTerm2; operating systems other than macOS
- Suppressing lights for the currently focused pane (possible future refinement)
- Per-project or per-model color schemes

## Amendments (2026-07-16, post source exploration)

Two facts surfaced while grounding the implementation plans in the `moergo-sc/zmk` sources:

1. **Violet-on-H requires the phase-2 split relay.** The H key's LED sits on the right half, which is the wireless peripheral, and the MoErgo fork has no central-to-peripheral command for driving an LED. Phase 1 therefore renders the armed indicator as dim violet on unlit F-row slot LEDs on the left half instead, and the H-key variant ships with phase 2 alongside the F6-F10 colors.
2. **Host-to-keyboard messages travel as SET_REPORT control transfers**, not an interrupt OUT endpoint (a property of the vendored raw HID design). No behavioral impact: hidapi's write path uses SetReport on macOS, so the daemon code is unchanged.

## Decisions log

| Question              | Decision                                        |
| --------------------- | ----------------------------------------------- |
| Connection            | Wired USB                                       |
| Slot count            | 10 (F1-F10), phase 1 ships 5                    |
| Lit states            | needs input, idle/done, dead; working stays dark |
| Key press action      | Tap always jumps                                |
| Agent key placement   | Function row F1-F10                             |
| Jump trigger          | Hold H (layer-tap into Agents layer)            |
| tmux mapping          | One session per agent, bare panes tolerated     |
| Slot assignment       | First free slot                                 |
| Detached jump target  | New iTerm tab                                   |
| Architecture          | Two-way raw HID, one Go daemon                  |
