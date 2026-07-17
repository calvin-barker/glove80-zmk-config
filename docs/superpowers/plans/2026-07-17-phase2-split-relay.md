# Phase 2: right-half LEDs and violet-on-H via split relay

Branch `phase2-split-relay` in both `calvin-barker/zmk` and `glove-agentd`.

## Goal

Light F6-F10 on the right half with agent colors, and light the H key violet
while the Agents layer is armed. Both require the central (left, USB) half to
relay data across the split link to the peripheral (right) half, which has no
host connection of its own.

Confirmed design decisions (2026-07-17):
- Armed indicator: violet on H **and** dim violet on every unlit F-key on both
  halves (targets map).
- Transports: BLE **and** wired (BLE is what the Glove80 uses; wired is nearly
  free and fixes a pre-existing dropped-command bug).

## Key finding from exploration

BLE does not pass the split command struct through generically; each central to
peripheral command type is its own GATT characteristic. Adding a relay message
means a **new GATT characteristic end to end**. The `SET_PHYSICAL_LAYOUT`
characteristic is the correct template because it also does connect-time sync
(unlike `SET_HID_INDICATORS`, which only pushes on change and would leave a
late-joining right half stale).

Payload fits easily: 5 x RGB (15 bytes) + 1 armed bool = 16 bytes, under the
existing 30-byte `invoke_behavior` union member and a single GATT write.

## Right-half LED indices

Unverified in-repo (no annotation in glove80_rh.dts). Mirror inference:
F-row set {10,16,22,28,34}, H = 8. **Task 1 verifies this on hardware before
anything is built on top of it.**

## Tasks

1. **Verify RH LED indices (hardware).** Throwaway probe lights candidate
   indices in distinct colors; user reports which physical keys glow. Establishes
   the F6-F10 order and H index. (Probe: `app/src/agent_led_probe.c`, reverted
   after.)

2. **Transport type + central sender.**
   - `app/include/zmk/split/transport/types.h`: add
     `ZMK_SPLIT_TRANSPORT_CENTRAL_CMD_TYPE_SET_AGENT_LEDS` and a
     `set_agent_leds { uint8_t rgb[5][3]; uint8_t armed; }` union member.
   - `app/include/zmk/split/central.h`: declare
     `zmk_split_central_set_agent_leds(...)`.
   - `app/src/split/central.c`: broadcast sender (loop all source ids), modeled
     on `zmk_split_central_update_hid_indicator`.

3. **Wired path.**
   - `app/src/split/wired/central.c`: add the `SET_AGENT_LEDS` case to
     `get_payload_data_size`.
   - `app/src/split/peripheral.c`: add a `SET_AGENT_LEDS` case to the generic
     handler that calls the peripheral render function; fix the missing `break`
     on `INVOKE_BEHAVIOR`.

4. **BLE path.**
   - `app/include/zmk/split/bluetooth/uuid.h`: new characteristic UUID (next
     free `0x00000007`).
   - `app/src/split/bluetooth/service.c`: characteristic + write handler that
     calls the peripheral render function.
   - `app/src/split/bluetooth/central.c`: slot handle field, reset, discovery
     case, subscribed gate, plus cases in both `split_central_bt_send_command`
     and `split_central_split_run_callback`.

5. **Peripheral render function.** Shared by both transport handlers: map the 5
   colors to RH F-row indices (from Task 1), paint via
   `zmk_rgb_underglow_set_agent_pixel` + `_agent_commit`; when armed, light H
   violet and unlit slots dim violet. Lives in a peripheral-compiled file
   (rgb_underglow.c is built for both halves).

6. **Connect-time sync.** Cache last agent state at the split layer; re-push on
   the new characteristic's discovery and in `split_central_security_changed`,
   mirroring the physical-layout pattern.

7. **Central producer + both-halves armed indicator.** `app/src/agent_status.c`:
   call `zmk_split_central_set_agent_leds(...)` from `agent_repaint()` alongside
   the existing left-half paint; keep dim violet on left unlit slots when armed.

8. **Ten usable slots.** `agent_status.c` HELLO reply returns 10 (was 5);
   `AGENT_USABLE_SLOTS` and the render loop cover 1-10 split across halves.
   glove-agentd: raise the default `slot_cap` to 10.

9. **Hardware acceptance.** Flash both halves: F6-F10 show colors, H violet when
   armed, dim violet on unlit slots both halves, colors survive a right-half
   reconnect (connect-time sync).

## Backlog (not phase-2 blocking)

- **Jumps freeze after jumping to a detached session (HIGH).** Repro: detach the
  keyboard tmux session, hold H + F1 (opens a new window via `tmux attach`), then
  H + F-keys to other sessions no longer navigate; detaching the session again
  restores it. Hypothesis: the inbound JUMP consumer in cmd/glove-agentd/main.go
  runs `exec.Jump()` synchronously, and focusByTTY's stability loop retries up to
  ~2.5s. The new `tmux attach` window keeps focus from settling, so every jump
  burns the full loop; once the inbound buffer (8) fills, the HID readLoop blocks
  on send and stops reading, freezing all jumps. Detaching closes the window and
  the pipeline drains. Fixes: (a) dispatch jumps to a worker goroutine so a slow
  jump never blocks the reader; (b) cap osascript with a timeout / shorten the
  stability loop; (c) reconsider openTabAndAttach leaving an interfering window.
  Confirm with the daemon log during a live repro before fixing.
- **Idle sessions drift to amber (HIGH: undercuts the core signal).** Claude
  Code's `Notification` hook fires both on permission prompts AND after ~60s of
  idle-waiting, and the daemon maps every `Notification` to needs-input (amber).
  So a session left idle goes green, then amber after a minute, making amber cry
  wolf. Fix options: (a) inspect the `Notification` payload's `message` and only
  set amber for permission/action notifications, treating the idle-waiting
  message as idle/green (fragile string match, version-dependent); (b) use a
  dedicated `PermissionRequest` hook for amber if it fires reliably as a user
  hook, and stop mapping `Notification` to amber. Verify the payload/hook
  availability first. Needs a state.go + hook change, rebuild, reinstall.

- **Green while a backgrounded command runs.** The daemon maps `Stop` (turn
  ended) to idle/green. When Claude backgrounds a long command and ends its turn
  to await it, the session reads green even though it will self-resume, which can
  falsely invite the user over. `Stop` looks identical whether Claude awaits the
  user or a background task, and there is no hook for "a backgrounded command is
  still running," so this is not a quick fix. Possible approximations: debounce
  `Stop` (stay working if a new `PostToolUse` arrives within N ms), or have the
  hook client detect pending background jobs. Revisit after phase 2.

## Testing note

Firmware validation is a successful Nix build per task plus a single hardware
acceptance pass at the end, because the relay only exercises over the live
wireless link.
