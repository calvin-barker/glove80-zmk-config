# Agent Status Firmware and Keymap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Glove80's F-row underglow LEDs into host-controlled agent status lights with a raw HID protocol and an `&agent_jump` key behavior, so a Mac daemon can light F1-F5 and receive "jump to slot N" messages.

**Architecture:** A fork of `moergo-sc/zmk` (branch `agent-status`) gains a vendor raw HID endpoint (second USB HID interface), an agent LED overlay painted over the existing underglow pipeline, a protocol handler, and a jump behavior. This config repo (`glove80-zmk-config`) gains an Agents layer, a hold-tap on H that arms it, the Kconfig flags, and build pointers to the fork. A Python script proves the pipe end to end before any daemon exists.

**Tech Stack:** ZMK v0.3.0 (MoErgo fork), Zephyr v3.5.0 (legacy USB_DEVICE_STACK), C, devicetree, Kconfig, Nix build, Docker, Python 3 + hidapi for the test script.

This plan is milestone 1 of the spec at `docs/superpowers/specs/2026-07-16-agent-status-keys-design.md`. Phase 2 (right-half LEDs F6-F10, violet on the H key itself, split relay) is OUT of scope.

## Validation model (read first)

The firmware has no test suite. For every firmware task, the TDD cycle is replaced by: make the change, run the Nix build for both halves, expect success. Runtime behavior is verified once at the end against real hardware (Task 9 checklist). Keymap tasks validate by building the firmware with the new keymap. Never claim a task done unless its build command succeeded.

Firmware build commands (run from the fork checkout at `~/development/zmk`):

```bash
nix-build -A glove80_left  ./default.nix   # expect: ./result symlink containing a .uf2
nix-build -A glove80_right ./default.nix
```

If Nix is not installed on the Mac, use the throwaway container fallback (slower, no cache):

```bash
docker run --rm -v "$PWD:/src" -w /src nixpkgs/nix:nixos-23.11 nix-build -A glove80_left ./default.nix
```

Config-repo build command (run from `~/development/glove80-zmk-config`, requires the fork branch pushed to GitHub):

```bash
ZMK_REPO=calvin-barker/zmk ./build.sh agent-status   # expect: ./glove80.uf2 appears
```

## Global Constraints

- Protocol v1, fixed for both this plan and the daemon plan: 32-byte HID reports; byte0 = 0x01 (version); byte1 = command; commands: 0x01 SET_LEDS (bytes 2..31 = 10 slots x RGB, full frame), 0x02 HELLO (firmware replies [0x01, 0x02, 0x05]), 0x10 JUMP (byte2 = slot 1-10, keyboard to host).
- Vendor HID usage page 0xFF60, usage 0x61, report size 32. Host writes carry a leading 0x00 report ID byte (33 bytes on the wire from the host side).
- Phase 1 usable slots: 5. Slot-to-LED map on the left half strip: F1=34, F2=28, F3=22, F4=16, F5=10. SET_LEDS bytes for slots 6-10 are accepted and ignored.
- Dark by default: LED color black (0,0,0) means "no overlay for that LED". Agents-layer indicator violet is RGB (40, 20, 80).
- Overlay self-clears 120 seconds after the last valid host message.
- USB only. No BLE raw HID. All new firmware code is central-half only (the left half, which owns USB).
- With CONFIG_ZMK_AGENT_STATUS disabled or no host talking, the keyboard must behave exactly like stock.
- Layer number: LAYER_Agents = 20 (the 21st layer in `config/glove80.keymap`).
- Commit messages: imperative mood, no Claude/Anthropic attribution trailers. Commit after every task, in whichever repo the task touched.
- Repos: firmware fork at `~/development/zmk` (github.com/calvin-barker/zmk, branch `agent-status`); config repo at `~/development/glove80-zmk-config` (branch `agent-status-keys`).

---

### Task 1: Create the firmware fork

**Files:**
- Create: GitHub fork `calvin-barker/zmk`, local clone `~/development/zmk`, branch `agent-status`

**Interfaces:**
- Produces: a pushable fork all later firmware tasks commit to.

- [ ] **Step 1: Fork and clone**

```bash
gh repo fork moergo-sc/zmk --clone=false --fork-name zmk
git clone https://github.com/calvin-barker/zmk ~/development/zmk
cd ~/development/zmk
git checkout -b agent-status origin/main
```

Expected: clone succeeds; `git branch --show-current` prints `agent-status`.

- [ ] **Step 2: Baseline build (proves toolchain before any change)**

```bash
cd ~/development/zmk
nix-build -A glove80_left ./default.nix
```

Expected: exits 0 and `ls result/` shows a `.uf2` file. First run downloads the toolchain; expect several minutes. If this fails, stop and fix the environment before proceeding.

- [ ] **Step 3: Push the branch**

```bash
git push -u origin agent-status
```

---

### Task 2: Vendor the raw HID transport in-tree

Adds a second USB HID interface ("HID_1") with a vendor report descriptor. Host-to-keyboard data arrives via SET_REPORT control transfers and is re-raised as the ZMK event `raw_hid_received_event`; keyboard-to-host data is sent by raising `raw_hid_sent_event`, whose listener calls `hid_int_ep_write`. Code is copied from the zmk-raw-hid module (github.com/zzeneg/zmk-raw-hid, MIT) rather than consumed as a Zephyr module, because the fork's Nix build vendors modules from a frozen manifest (`nix/manifest.json`) and ignores `west.yml`.

**Files:**
- Create: `app/include/raw_hid/raw_hid.h`
- Create: `app/include/raw_hid/events.h`
- Create: `app/src/raw_hid_events.c`
- Create: `app/src/raw_hid_usb.c`
- Modify: `app/Kconfig` (insert before the line `# This loads ZMK's internal board and shield Kconfigs`)
- Modify: `app/CMakeLists.txt` (inside the `if ((NOT CONFIG_ZMK_SPLIT) OR CONFIG_ZMK_SPLIT_ROLE_CENTRAL)` block)
- Modify: `app/boards/arm/glove80/glove80_lh_defconfig`

**Interfaces:**
- Produces: `struct raw_hid_received_event { uint8_t *data; uint8_t length; }` and `struct raw_hid_sent_event { uint8_t *data; uint8_t length; }` with `raise_raw_hid_sent_event(...)` / `as_raw_hid_received_event(eh)`; Kconfig symbols `CONFIG_RAW_HID`, `CONFIG_RAW_HID_USAGE_PAGE=0xFF60`, `CONFIG_RAW_HID_USAGE=0x61`, `CONFIG_RAW_HID_REPORT_SIZE=32`, `CONFIG_RAW_HID_DEVICE="HID_1"`.
- Consumes: Task 1's fork checkout.

- [ ] **Step 1: Create `app/include/raw_hid/raw_hid.h`** (report descriptor; verbatim from zmk-raw-hid)

```c
#pragma once

#include <zmk/hid.h>
#include <zephyr/usb/class/hid.h>
#include <zephyr/usb/class/usb_hid.h>

#define HID_USAGE_PAGE16(page, page2)                                                              \
    HID_ITEM(HID_ITEM_TAG_USAGE_PAGE, HID_ITEM_TYPE_GLOBAL, 2), page, page2

#define HID_USAGE_PAGE16_SINGLE(a) HID_USAGE_PAGE16((a & 0xFF), ((a >> 8) & 0xFF))

static const uint8_t raw_hid_report_desc[] = {
    HID_USAGE_PAGE16_SINGLE(CONFIG_RAW_HID_USAGE_PAGE),
    HID_USAGE(CONFIG_RAW_HID_USAGE),

    HID_COLLECTION(0x01),

    HID_LOGICAL_MIN8(0x00),
    HID_LOGICAL_MAX16(0xFF, 0x00),
    HID_REPORT_SIZE(0x08),
    HID_REPORT_COUNT(CONFIG_RAW_HID_REPORT_SIZE),

    HID_USAGE(0x01),
    HID_INPUT(ZMK_HID_MAIN_VAL_DATA | ZMK_HID_MAIN_VAL_VAR | ZMK_HID_MAIN_VAL_ABS),

    HID_USAGE(0x02),
    HID_OUTPUT(ZMK_HID_MAIN_VAL_DATA | ZMK_HID_MAIN_VAL_VAR | ZMK_HID_MAIN_VAL_ABS |
               ZMK_HID_MAIN_VAL_NON_VOL),

    HID_END_COLLECTION,
};
```

- [ ] **Step 2: Create `app/include/raw_hid/events.h`** (verbatim from zmk-raw-hid)

```c
#pragma once

#include <zmk/event_manager.h>

struct raw_hid_received_event {
    uint8_t *data;
    uint8_t length;
};

ZMK_EVENT_DECLARE(raw_hid_received_event);

struct raw_hid_sent_event {
    uint8_t *data;
    uint8_t length;
};

ZMK_EVENT_DECLARE(raw_hid_sent_event);
```

- [ ] **Step 3: Create `app/src/raw_hid_events.c`**

```c
#include <raw_hid/events.h>

#include <zephyr/logging/log.h>
LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

ZMK_EVENT_IMPL(raw_hid_received_event);
ZMK_EVENT_IMPL(raw_hid_sent_event);
```

- [ ] **Step 4: Create `app/src/raw_hid_usb.c`** (verbatim from zmk-raw-hid's `src/usb_hid.c`)

```c
#include <raw_hid/raw_hid.h>
#include <raw_hid/events.h>

#include <zmk/usb.h>

#include <zephyr/logging/log.h>
LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

static const struct device *raw_hid_dev;

static K_SEM_DEFINE(hid_sem, 1, 1);

static void in_ready_cb(const struct device *dev) { k_sem_give(&hid_sem); }

#define HID_GET_REPORT_TYPE_MASK 0xff00
#define HID_GET_REPORT_ID_MASK 0x00ff

#define HID_REPORT_TYPE_INPUT 0x100
#define HID_REPORT_TYPE_OUTPUT 0x200
#define HID_REPORT_TYPE_FEATURE 0x300

static int get_report_cb(const struct device *dev, struct usb_setup_packet *setup, int32_t *len,
                         uint8_t **data) {
    return 0;
}

static int set_report_cb(const struct device *dev, struct usb_setup_packet *setup, int32_t *len,
                         uint8_t **data) {
    if ((setup->wValue & HID_GET_REPORT_TYPE_MASK) != HID_REPORT_TYPE_OUTPUT &&
        (setup->wValue & HID_GET_REPORT_TYPE_MASK) != HID_REPORT_TYPE_FEATURE) {
        LOG_ERR("[# raw-hid #] Set: Unsupported report type %d requested",
                (setup->wValue & HID_GET_REPORT_TYPE_MASK) >> 8);
        return -ENOTSUP;
    }

    LOG_INF("USB - Received Raw HID report of length %i", *len);
    LOG_HEXDUMP_DBG(*data, *len, "USB - Received Raw HID report");
    raise_raw_hid_received_event((struct raw_hid_received_event){.data = *data, .length = *len});

    return 0;
}

static const struct hid_ops ops = {
    .int_in_ready = in_ready_cb,
    .get_report = get_report_cb,
    .set_report = set_report_cb,
};

static void send_report(const uint8_t *data, uint8_t len) {
    k_sem_take(&hid_sem, K_MSEC(30));

    LOG_INF("USB - Sending Raw HID report of length %i", len);
    uint8_t report[CONFIG_RAW_HID_REPORT_SIZE] = {0};
    memcpy(report, data, len);
    LOG_HEXDUMP_DBG(report, CONFIG_RAW_HID_REPORT_SIZE, "USB - Sending Raw HID report");

    int err = hid_int_ep_write(raw_hid_dev, report, CONFIG_RAW_HID_REPORT_SIZE, NULL);
    if (err) {
        LOG_ERR("Failed to send report: %i", err);
        k_sem_give(&hid_sem);
    }
}

static int raw_hid_sent_event_listener(const zmk_event_t *eh) {
    struct raw_hid_sent_event *event = as_raw_hid_sent_event(eh);
    if (event) {
        send_report(event->data, event->length);
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(usb_process_raw_hid_sent_event, raw_hid_sent_event_listener);
ZMK_SUBSCRIPTION(usb_process_raw_hid_sent_event, raw_hid_sent_event);

static int raw_hid_init(void) {
    raw_hid_dev = device_get_binding(CONFIG_RAW_HID_DEVICE);
    if (raw_hid_dev == NULL) {
        LOG_ERR("Unable to locate HID device");
        return -EINVAL;
    }

    usb_hid_register_device(raw_hid_dev, raw_hid_report_desc, sizeof(raw_hid_report_desc), &ops);

    usb_hid_init(raw_hid_dev);

    return 0;
}

SYS_INIT(raw_hid_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
```

Key facts: `device_get_binding("HID_1")` only succeeds when `CONFIG_USB_HID_DEVICE_COUNT=2` (Zephyr defaults to 1); host-to-device arrives through `set_report_cb` (SET_REPORT control transfer, not an interrupt-OUT endpoint) and is re-raised as `raw_hid_received_event`; device-to-host goes through the `raw_hid_sent_event` listener into `hid_int_ep_write`.

- [ ] **Step 5: Add Kconfig options to `app/Kconfig`**

Find this anchor near the end of `app/Kconfig`:

```
# This loads ZMK's internal board and shield Kconfigs
```

Insert immediately BEFORE that line:

```
menu "Raw HID and agent status"

config RAW_HID
    bool "Enable Raw HID"
    depends on !ZMK_SPLIT || ZMK_SPLIT_ROLE_CENTRAL
    imply USB_DEVICE_HID

config RAW_HID_USAGE_PAGE
    hex "Raw HID Usage Page"
    default 0xFF60

config RAW_HID_USAGE
    hex "Raw HID Usage"
    default 0x61

config RAW_HID_REPORT_SIZE
    int "Raw HID Report Size"
    default 32

config RAW_HID_DEVICE
    string "Raw HID Device"
    default HID_1

config ZMK_AGENT_STATUS
    bool "Agent status LED overlay and jump behavior"
    depends on RAW_HID && ZMK_RGB_UNDERGLOW

config ZMK_AGENT_STATUS_LAYER
    int "Keymap layer number that arms the agent jump keys"
    depends on ZMK_AGENT_STATUS
    default -1

endmenu

```

(`ZMK_AGENT_STATUS` and `ZMK_AGENT_STATUS_LAYER` are consumed by Tasks 4 and 5; defining them now keeps this file touched once.)

- [ ] **Step 6: Register sources in `app/CMakeLists.txt`**

Find this line inside the `if ((NOT CONFIG_ZMK_SPLIT) OR CONFIG_ZMK_SPLIT_ROLE_CENTRAL)` block:

```cmake
  target_sources(app PRIVATE src/behaviors/behavior_to_layer.c)
```

Insert immediately AFTER it:

```cmake
  target_sources_ifdef(CONFIG_RAW_HID app PRIVATE src/raw_hid_events.c)
  target_sources_ifdef(CONFIG_RAW_HID app PRIVATE src/raw_hid_usb.c)
```

- [ ] **Step 7: Enable the feature on the central half**

Append to `app/boards/arm/glove80/glove80_lh_defconfig`:

```
CONFIG_USB_HID_DEVICE_COUNT=2
CONFIG_RAW_HID=y
CONFIG_ZMK_AGENT_STATUS=y
```

The right half (`glove80_rh_defconfig`) is untouched: it has no USB and `CONFIG_RAW_HID` depends on the central role. Putting these in the left defconfig means every fork build compiles the new code, so build validation is real.

- [ ] **Step 8: Build both halves**

```bash
cd ~/development/zmk
nix-build -A glove80_left  ./default.nix
nix-build -A glove80_right ./default.nix
```

Expected: both exit 0. Note: `CONFIG_ZMK_AGENT_STATUS=y` is set but no code consumes it yet; that is fine.

- [ ] **Step 9: Commit**

```bash
git add app/include/raw_hid app/src/raw_hid_events.c app/src/raw_hid_usb.c app/Kconfig app/CMakeLists.txt app/boards/arm/glove80/glove80_lh_defconfig
git commit -m "Add vendor raw HID transport from zmk-raw-hid

Vendored in-tree from github.com/zzeneg/zmk-raw-hid (MIT) because the
Nix build vendors Zephyr modules from a frozen manifest. USB only."
git push
```

---

### Task 3: Agent LED overlay API in the underglow driver

The driver (`app/src/rgb_underglow.c`) keeps `pixels[]` (animation) and `status_pixels[]` (battery/BT status) and composes them in `zmk_led_write_pixels()` before `led_strip_update_rgb(led_strip, ..., STRIP_NUM_PIXELS)` (STRIP_NUM_PIXELS = 40 per half). This task adds a third buffer, `agent_pixels[]`, painted last so non-black agent pixels always win, plus the external-power handling needed because this user's underglow is normally OFF (LED rail unpowered).

**Files:**
- Modify: `app/src/rgb_underglow.c`
- Modify: `app/include/zmk/rgb_underglow.h`

**Interfaces:**
- Produces (consumed by Task 4):

```c
int zmk_rgb_underglow_set_agent_pixel(uint8_t index, uint8_t r, uint8_t g, uint8_t b); // buffer only
int zmk_rgb_underglow_clear_agent_pixels(void);                                        // buffer only
int zmk_rgb_underglow_agent_commit(void);   // recompute power state and render the strip
```

- [ ] **Step 1: Add the buffer and flag**

In `app/src/rgb_underglow.c`, find:

```c
static struct led_rgb pixels[STRIP_NUM_PIXELS];
static struct led_rgb status_pixels[STRIP_NUM_PIXELS];
```

Replace with:

```c
static struct led_rgb pixels[STRIP_NUM_PIXELS];
static struct led_rgb status_pixels[STRIP_NUM_PIXELS];
static struct led_rgb agent_pixels[STRIP_NUM_PIXELS];
static bool agent_overlay_active;
```

- [ ] **Step 2: Route the fast path around the overlay**

In `zmk_led_write_pixels()`, find:

```c
    // fast path: no status indicators, battery level OK
    if (blend == 0 && bat0 >= 20) {
        led_strip_update_rgb(led_strip, pixels, STRIP_NUM_PIXELS);
        return;
    }
```

Replace with:

```c
    // fast path: no status indicators, no agent overlay, battery level OK
    if (blend == 0 && bat0 >= 20 && !agent_overlay_active) {
        led_strip_update_rgb(led_strip, pixels, STRIP_NUM_PIXELS);
        return;
    }
```

- [ ] **Step 3: Paint the overlay last**

Still in `zmk_led_write_pixels()`, find:

```c
    // battery below 20%, reduce LED brightness
    if (bat0 < 20) {
        for (int i = 0; i < STRIP_NUM_PIXELS; i++) {
            led_buffer[i].r = led_buffer[i].r >> 1;
            led_buffer[i].g = led_buffer[i].g >> 1;
            led_buffer[i].b = led_buffer[i].b >> 1;
        }
    }

    int err = led_strip_update_rgb(led_strip, led_buffer, STRIP_NUM_PIXELS);
```

Insert between the dimming block and the `led_strip_update_rgb` call:

```c
    // agent status overlay: non-black agent pixels override everything,
    // including battery dimming, so status colors stay recognizable
    if (agent_overlay_active) {
        for (int i = 0; i < STRIP_NUM_PIXELS; i++) {
            if (agent_pixels[i].r || agent_pixels[i].g || agent_pixels[i].b) {
                led_buffer[i] = agent_pixels[i];
            }
        }
    }
```

- [ ] **Step 4: Keep the LED power rail on while the overlay is lit**

The rail control is `zmk_rgb_set_ext_power()`. Find:

```c
    int desired_state = state.on || state.status_active;
```

Replace with:

```c
    int desired_state = state.on || state.status_active || agent_overlay_active;
```

This mirrors how the status display powers the rail: when the user's underglow is off, `state.on` is false and without this line the WS2812 strip would be unpowered and every agent pixel invisible.

- [ ] **Step 5: Add the public API**

In `app/src/rgb_underglow.c`, find the function `zmk_rgb_underglow_status(void)` (near the bottom, after `K_WORK_DEFINE(underglow_write_work, zmk_led_write_pixels_work);`). Insert BEFORE `int zmk_rgb_underglow_status(void) {`:

```c
static void agent_recompute_active(void) {
    agent_overlay_active = false;
    for (int i = 0; i < STRIP_NUM_PIXELS; i++) {
        if (agent_pixels[i].r || agent_pixels[i].g || agent_pixels[i].b) {
            agent_overlay_active = true;
            return;
        }
    }
}

int zmk_rgb_underglow_set_agent_pixel(uint8_t index, uint8_t r, uint8_t g, uint8_t b) {
    if (!led_strip)
        return -ENODEV;
    if (index >= STRIP_NUM_PIXELS)
        return -EINVAL;
    agent_pixels[index] = (struct led_rgb){.r = r, .g = g, .b = b};
    return 0;
}

int zmk_rgb_underglow_clear_agent_pixels(void) {
    if (!led_strip)
        return -ENODEV;
    memset(agent_pixels, 0, sizeof(agent_pixels));
    return 0;
}

int zmk_rgb_underglow_agent_commit(void) {
    if (!led_strip)
        return -ENODEV;
    agent_recompute_active();
    zmk_rgb_set_ext_power();
    if (!k_work_is_pending(&underglow_write_work)) {
        k_work_submit(&underglow_write_work);
    }
    return 0;
}
```

`agent_commit` reuses the driver's existing `underglow_write_work` work item so strip writes happen on the system work queue, the same context the status display uses. When the overlay clears and underglow is off, the write renders all-black `pixels[]` and `zmk_rgb_set_ext_power()` drops the rail.

- [ ] **Step 6: Declare the API in `app/include/zmk/rgb_underglow.h`**

Append before the end of the file:

```c
int zmk_rgb_underglow_set_agent_pixel(uint8_t index, uint8_t r, uint8_t g, uint8_t b);
int zmk_rgb_underglow_clear_agent_pixels(void);
int zmk_rgb_underglow_agent_commit(void);
```

- [ ] **Step 7: Build both halves**

```bash
cd ~/development/zmk
nix-build -A glove80_left  ./default.nix
nix-build -A glove80_right ./default.nix
```

Expected: both exit 0 (the right half compiles the same file; the new code is inert there).

- [ ] **Step 8: Commit**

```bash
git add app/src/rgb_underglow.c app/include/zmk/rgb_underglow.h
git commit -m "Add agent pixel overlay API to RGB underglow driver

Third pixel buffer painted after status blending and battery dimming.
Holds the ext power rail on while any agent pixel is lit so the
overlay renders even when underglow is off."
git push
```

---

### Task 4: Agent status protocol handler

New central-half file that parses host messages from `raw_hid_received_event`, owns the 10-slot color table, maps slots 1-5 onto LED indices {34, 28, 22, 16, 10}, answers HELLO, self-clears after 120 seconds of host silence, and renders the dim-violet Agents-layer indicator on unlit slots.

**Files:**
- Create: `app/include/zmk/agent_status.h`
- Create: `app/src/agent_status.c`
- Modify: `app/CMakeLists.txt`

**Interfaces:**
- Consumes: Task 2's events and Kconfig symbols; Task 3's `zmk_rgb_underglow_set_agent_pixel` / `zmk_rgb_underglow_agent_commit`.
- Produces (consumed by Task 5): protocol constants in `<zmk/agent_status.h>`: `AGENT_PROTO_VERSION 0x01`, `AGENT_CMD_SET_LEDS 0x01`, `AGENT_CMD_HELLO 0x02`, `AGENT_CMD_JUMP 0x10`.

- [ ] **Step 1: Create `app/include/zmk/agent_status.h`**

```c
#pragma once

#define AGENT_PROTO_VERSION 0x01

#define AGENT_CMD_SET_LEDS 0x01
#define AGENT_CMD_HELLO 0x02
#define AGENT_CMD_JUMP 0x10

#define AGENT_SLOT_COUNT 10
#define AGENT_USABLE_SLOTS 5
```

- [ ] **Step 2: Create `app/src/agent_status.c`**

```c
#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <raw_hid/events.h>
#include <zmk/agent_status.h>
#include <zmk/event_manager.h>
#include <zmk/events/layer_state_changed.h>
#include <zmk/rgb_underglow.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#define AGENT_TIMEOUT_SECONDS 120

// Underglow LED indices beneath F1-F5 on the left half strip
static const uint8_t slot_led_index[AGENT_USABLE_SLOTS] = {34, 28, 22, 16, 10};

static uint8_t slot_colors[AGENT_SLOT_COUNT][3];
static bool agents_layer_active;

static void agent_repaint(void) {
    for (int i = 0; i < AGENT_USABLE_SLOTS; i++) {
        uint8_t r = slot_colors[i][0];
        uint8_t g = slot_colors[i][1];
        uint8_t b = slot_colors[i][2];
        if (r == 0 && g == 0 && b == 0 && agents_layer_active) {
            // dim violet: this slot key is an armed jump target
            r = 40;
            g = 20;
            b = 80;
        }
        zmk_rgb_underglow_set_agent_pixel(slot_led_index[i], r, g, b);
    }
    zmk_rgb_underglow_agent_commit();
}

static void agent_timeout_handler(struct k_work *work) {
    LOG_INF("Agent status: host silent for %ds, clearing overlay", AGENT_TIMEOUT_SECONDS);
    memset(slot_colors, 0, sizeof(slot_colors));
    agent_repaint();
}

static K_WORK_DELAYABLE_DEFINE(agent_timeout_work, agent_timeout_handler);

static void agent_send_hello_reply(void) {
    static uint8_t reply[3] = {AGENT_PROTO_VERSION, AGENT_CMD_HELLO, AGENT_USABLE_SLOTS};
    raise_raw_hid_sent_event((struct raw_hid_sent_event){.data = reply, .length = sizeof(reply)});
}

static int agent_status_hid_listener(const zmk_event_t *eh) {
    struct raw_hid_received_event *ev = as_raw_hid_received_event(eh);
    if (ev == NULL || ev->length < 2 || ev->data[0] != AGENT_PROTO_VERSION) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    switch (ev->data[1]) {
    case AGENT_CMD_SET_LEDS:
        if (ev->length < 2 + AGENT_SLOT_COUNT * 3) {
            return ZMK_EV_EVENT_BUBBLE;
        }
        for (int s = 0; s < AGENT_SLOT_COUNT; s++) {
            slot_colors[s][0] = ev->data[2 + s * 3];
            slot_colors[s][1] = ev->data[3 + s * 3];
            slot_colors[s][2] = ev->data[4 + s * 3];
        }
        agent_repaint();
        break;
    case AGENT_CMD_HELLO:
        agent_send_hello_reply();
        break;
    default:
        return ZMK_EV_EVENT_BUBBLE;
    }

    k_work_reschedule(&agent_timeout_work, K_SECONDS(AGENT_TIMEOUT_SECONDS));
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(agent_status_hid, agent_status_hid_listener);
ZMK_SUBSCRIPTION(agent_status_hid, raw_hid_received_event);

#if CONFIG_ZMK_AGENT_STATUS_LAYER >= 0

static int agent_status_layer_listener(const zmk_event_t *eh) {
    const struct zmk_layer_state_changed *ev = as_zmk_layer_state_changed(eh);
    if (ev == NULL) {
        return ZMK_EV_EVENT_BUBBLE;
    }
    if (ev->layer == CONFIG_ZMK_AGENT_STATUS_LAYER) {
        agents_layer_active = ev->state;
        agent_repaint();
    }
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(agent_status_layer, agent_status_layer_listener);
ZMK_SUBSCRIPTION(agent_status_layer, zmk_layer_state_changed);

#endif /* CONFIG_ZMK_AGENT_STATUS_LAYER >= 0 */
```

Notes for the implementer: copying the payload inside the listener is required because `ev->data` points into the USB stack's transfer buffer, only valid during the synchronous event dispatch. The listener/subscription macro pattern matches `app/src/conditional_layer.c`. SET_LEDS parses all 10 slots but only 5 are rendered; slots 6-10 wait for phase 2.

- [ ] **Step 3: Register in `app/CMakeLists.txt`**

Immediately after the two `raw_hid` lines added in Task 2 Step 6, insert:

```cmake
  target_sources_ifdef(CONFIG_ZMK_AGENT_STATUS app PRIVATE src/agent_status.c)
```

- [ ] **Step 4: Build both halves**

```bash
cd ~/development/zmk
nix-build -A glove80_left  ./default.nix
nix-build -A glove80_right ./default.nix
```

Expected: both exit 0. The left build now compiles `agent_status.c` (defconfig set `CONFIG_ZMK_AGENT_STATUS=y` in Task 2); `CONFIG_ZMK_AGENT_STATUS_LAYER` defaults to -1 so the layer listener block is compiled out until the keymap config sets it.

- [ ] **Step 5: Commit**

```bash
git add app/include/zmk/agent_status.h app/src/agent_status.c app/CMakeLists.txt
git commit -m "Add agent status protocol handler

Parses SET_LEDS and HELLO from raw HID, maps slots 1-5 to the F-row
LEDs, self-clears after 120s of host silence, and paints unlit slots
dim violet while the configured Agents layer is active."
git push
```

---

### Task 5: The `&agent_jump` behavior

A one-parameter behavior that sends `[0x01, 0x10, N]` to the host instead of a keycode. Modeled on `app/src/behaviors/behavior_to_layer.c`. Behaviors execute on the central half even when the pressed key is physically on the right half, so F6-F10 jump bindings already work in phase 1 despite their LEDs staying dark.

**Files:**
- Create: `app/src/behaviors/behavior_agent_jump.c`
- Create: `app/dts/bindings/behaviors/zmk,behavior-agent-jump.yaml`
- Create: `app/dts/behaviors/agent_jump.dtsi`
- Modify: `app/dts/behaviors.dtsi`
- Modify: `app/CMakeLists.txt`

**Interfaces:**
- Consumes: `raise_raw_hid_sent_event` (Task 2), `<zmk/agent_status.h>` constants (Task 4).
- Produces: devicetree behavior `&agent_jump N` (N = 1-10), used by the keymap in Task 6.

- [ ] **Step 1: Create `app/src/behaviors/behavior_agent_jump.c`**

```c
#define DT_DRV_COMPAT zmk_behavior_agent_jump

#include <zephyr/device.h>
#include <drivers/behavior.h>
#include <zephyr/logging/log.h>

#include <raw_hid/events.h>
#include <zmk/agent_status.h>
#include <zmk/behavior.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#if DT_HAS_COMPAT_STATUS_OKAY(DT_DRV_COMPAT)

static int agent_jump_binding_pressed(struct zmk_behavior_binding *binding,
                                      struct zmk_behavior_binding_event event) {
    static uint8_t msg[3];
    msg[0] = AGENT_PROTO_VERSION;
    msg[1] = AGENT_CMD_JUMP;
    msg[2] = (uint8_t)binding->param1;
    LOG_DBG("agent jump slot %d", binding->param1);
    raise_raw_hid_sent_event((struct raw_hid_sent_event){.data = msg, .length = sizeof(msg)});
    return ZMK_BEHAVIOR_OPAQUE;
}

static int agent_jump_binding_released(struct zmk_behavior_binding *binding,
                                       struct zmk_behavior_binding_event event) {
    return ZMK_BEHAVIOR_OPAQUE;
}

static const struct behavior_driver_api behavior_agent_jump_driver_api = {
    .binding_pressed = agent_jump_binding_pressed,
    .binding_released = agent_jump_binding_released,
};

BEHAVIOR_DT_INST_DEFINE(0, NULL, NULL, NULL, NULL, POST_KERNEL, CONFIG_KERNEL_INIT_PRIORITY_DEFAULT,
                        &behavior_agent_jump_driver_api);

#endif /* DT_HAS_COMPAT_STATUS_OKAY(DT_DRV_COMPAT) */
```

- [ ] **Step 2: Create `app/dts/bindings/behaviors/zmk,behavior-agent-jump.yaml`**

```yaml
description: Agent jump, sends a raw HID JUMP message for the slot in param1

compatible: "zmk,behavior-agent-jump"

include: one_param.yaml
```

- [ ] **Step 3: Create `app/dts/behaviors/agent_jump.dtsi`**

```dts
/ {
    behaviors {
        agent_jump: agent_jump {
            compatible = "zmk,behavior-agent-jump";
            #binding-cells = <1>;
            display-name = "Agent Jump";
        };
    };
};
```

- [ ] **Step 4: Include it from `app/dts/behaviors.dtsi`**

Find the line:

```dts
#include <behaviors/to_layer.dtsi>
```

Insert after it:

```dts
#include <behaviors/agent_jump.dtsi>
```

- [ ] **Step 5: Register in `app/CMakeLists.txt`**

Immediately after the `agent_status.c` line from Task 4 Step 3, insert:

```cmake
  target_sources_ifdef(CONFIG_ZMK_AGENT_STATUS app PRIVATE src/behaviors/behavior_agent_jump.c)
```

- [ ] **Step 6: Build both halves**

```bash
cd ~/development/zmk
nix-build -A glove80_left  ./default.nix
nix-build -A glove80_right ./default.nix
```

Expected: both exit 0.

- [ ] **Step 7: Commit and push**

```bash
git add app/src/behaviors/behavior_agent_jump.c app/dts/bindings/behaviors/zmk,behavior-agent-jump.yaml app/dts/behaviors/agent_jump.dtsi app/dts/behaviors.dtsi app/CMakeLists.txt
git commit -m "Add agent_jump behavior sending raw HID JUMP messages"
git push
```

---

### Task 6: Keymap changes in glove80-zmk-config

Adds the Agents layer (layer 20), converts H into a TailorKey-style hold-tap that arms it, and sets the layer number Kconfig. Work happens in `~/development/glove80-zmk-config` on branch `agent-status-keys`.

**Files:**
- Modify: `config/glove80.keymap`
- Modify: `config/glove80.conf`

**Interfaces:**
- Consumes: `&agent_jump` (Task 5), `CONFIG_ZMK_AGENT_STATUS_LAYER` (Task 2).
- Produces: `LAYER_Agents` = 20; hold-H gesture.

- [ ] **Step 1: Add the layer define**

In `config/glove80.keymap`, find:

```c
#define LAYER_Lower 18
#define LAYER_Magic 19
```

Replace with:

```c
#define LAYER_Lower 18
#define LAYER_Magic 19
#define LAYER_Agents 20
```

(These live inside the `KB_TYPE == KB_TYPE_GLOVE_80` branch; do not touch the `#else` branch.)

- [ ] **Step 2: Add the `agents_H` hold-tap behavior**

Find the TailorKey thumb behavior block:

```c
        // thumb_layer_access - TailorKey
        thumb_v2_TKZ: thumb_v2_TKZ {
            compatible = "zmk,behavior-hold-tap";
            #binding-cells = <2>;
            tapping-term-ms = <200>;
            bindings = <&mo>, <&kp>;
            flavor = "balanced";
            quick-tap-ms = <300>;
            require-prior-idle-ms = <0>;
        };
    };
};
```

Replace with:

```c
        // thumb_layer_access - TailorKey
        thumb_v2_TKZ: thumb_v2_TKZ {
            compatible = "zmk,behavior-hold-tap";
            #binding-cells = <2>;
            tapping-term-ms = <200>;
            bindings = <&mo>, <&kp>;
            flavor = "balanced";
            quick-tap-ms = <300>;
            require-prior-idle-ms = <0>;
        };

        // agents_layer_access: hold H to arm the Agents layer.
        // Hold only triggers when the other key pressed is an F-row key,
        // so fast letter sequences can never misfire.
        agents_H: agents_H {
            compatible = "zmk,behavior-hold-tap";
            #binding-cells = <2>;
            tapping-term-ms = <200>;
            bindings = <&mo>, <&kp>;
            flavor = "balanced";
            quick-tap-ms = <300>;
            require-prior-idle-ms = <100>;
            hold-trigger-key-positions = <POS_LH_C6R1 POS_LH_C5R1 POS_LH_C4R1 POS_LH_C3R1 POS_LH_C2R1 POS_RH_C2R1 POS_RH_C3R1 POS_RH_C4R1 POS_RH_C5R1 POS_RH_C6R1>;
            hold-trigger-on-release;
        };
    };
};
```

- [ ] **Step 3: Rebind H on the base layer**

In the `layer_HRM_macOS` bindings, find the fragment (row 5, right half):

```
   &kp K                             &kp H                        &kp COMMA
```

Replace with:

```
   &kp K       &agents_H LAYER_Agents H                        &kp COMMA
```

(Only whitespace alignment differs; the row's column count must stay identical. Do NOT touch `&kp HOME` on the row below, which also matches the substring `&kp H`.)

- [ ] **Step 4: Add the Agents layer node**

Find the end of the keymap node:

```
        layer_Magic {
```

and after that entire node's closing `};` (immediately before the final `    };` and `};` that close `keymap` and the root node at the end of the file), insert:

```
        layer_Agents {
            bindings = <
 &agent_jump 1  &agent_jump 2  &agent_jump 3  &agent_jump 4  &agent_jump 5                                                          &agent_jump 6  &agent_jump 7  &agent_jump 8  &agent_jump 9  &agent_jump 10
         &none          &none          &none          &none          &none  &none                                          &none          &none          &none          &none          &none           &none
         &none          &none          &none          &none          &none  &none                                          &none          &none          &none          &none          &none           &none
         &none          &none          &none          &none          &none  &none                                          &none          &none          &none          &none          &none           &none
         &none          &none          &none          &none          &none  &none  &none  &none  &none  &none  &none  &none  &none        &none          &none          &none          &none           &none
         &none          &none          &none          &none          &none         &none  &none  &none  &none  &none  &none               &none          &none          &none          &none           &none
            >;
        };
```

Layer node order in the keymap must match the define numbering: this node comes 21st, right after `layer_Magic`. Row shape check: 10 + 12 + 12 + 12 + 18 + 16 = 80 bindings.

- [ ] **Step 5: Set the Kconfig flag**

Append to `config/glove80.conf`:

```
# Agent status keys: the firmware fork needs to know which layer arms
# the jump keys (LAYER_Agents in glove80.keymap)
CONFIG_ZMK_AGENT_STATUS_LAYER=20
```

(`CONFIG_RAW_HID`, `CONFIG_ZMK_AGENT_STATUS`, and `CONFIG_USB_HID_DEVICE_COUNT` are already set in the fork's left-half defconfig from Task 2.)

- [ ] **Step 6: Build against the fork**

```bash
cd ~/development/glove80-zmk-config
ZMK_REPO=calvin-barker/zmk ./build.sh agent-status
```

Expected: exits 0 and `./glove80.uf2` exists. This requires Task 7's `ZMK_REPO` plumbing; if running tasks strictly in order, do Task 7 Steps 1-3 first or temporarily edit the Dockerfile clone URL by hand. Alternative without Docker: check the fork out at `src/` and run `nix-build config -o combined` from the repo root, matching CI.

- [ ] **Step 7: Commit**

```bash
git add config/glove80.keymap config/glove80.conf
git commit -m "Add Agents layer with hold-H access and agent_jump keys

F1-F10 on the new layer send raw HID JUMP messages to the host.
H becomes a hold-tap tuned like the TailorKey home row mods, with
hold restricted to F-row companion presses."
```

---

### Task 7: Point the builds at the fork

**Files:**
- Modify: `.github/workflows/build.yml`
- Modify: `Dockerfile`
- Modify: `build.sh`
- Modify: `build.bat`
- Modify: `CLAUDE.md`

**Interfaces:**
- Produces: `ZMK_REPO` env var for `build.sh`/`build.bat`; CI pinned to `calvin-barker/zmk@agent-status`.

- [ ] **Step 1: CI workflow**

In `.github/workflows/build.yml`, find:

```yaml
      - uses: actions/checkout@v4
        with:
          repository: moergo-sc/zmk
          ref: main
          path: src
```

Replace with:

```yaml
      - uses: actions/checkout@v4
        with:
          repository: calvin-barker/zmk
          ref: agent-status
          path: src
```

- [ ] **Step 2: Dockerfile repo argument**

Find:

```dockerfile
FROM nixpkgs/nix:nixos-23.11

ENV PATH=/root/.nix-profile/bin:/usr/bin:/bin
```

Replace with:

```dockerfile
FROM nixpkgs/nix:nixos-23.11

ARG ZMK_REPO=moergo-sc/zmk

ENV PATH=/root/.nix-profile/bin:/usr/bin:/bin
```

Then find:

```dockerfile
    git clone --mirror https://github.com/moergo-sc/zmk /zmk
```

Replace with:

```dockerfile
    git clone --mirror "https://github.com/${ZMK_REPO}" /zmk
```

And in the embedded entrypoint script, find:

```
    echo "Checking out \$BRANCH from moergo-sc/zmk" >&2
```

Replace with:

```
    echo "Checking out \$BRANCH" >&2
```

- [ ] **Step 3: build.sh**

Replace the entire file content of `build.sh` with:

```bash
#!/bin/bash

set -euo pipefail

IMAGE=glove80-zmk-config-docker
BRANCH="${1:-main}"
ZMK_REPO="${ZMK_REPO:-moergo-sc/zmk}"

docker build --build-arg ZMK_REPO="$ZMK_REPO" -t "$IMAGE" .
docker run --rm -v "$PWD:/config" -e UID="$(id -u)" -e GID="$(id -g)" -e BRANCH="$BRANCH" "$IMAGE"
```

Usage for this project: `ZMK_REPO=calvin-barker/zmk ./build.sh agent-status`. Defaults unchanged, so `./build.sh` still builds stock moergo-sc/zmk main (note: with the Agents keymap in place, a stock-main build fails on `&agent_jump`; the fork is now the working default for this repo and CLAUDE.md documents it).

- [ ] **Step 4: build.bat**

In `build.bat`, find:

```bat
set IMAGE=glove80-zmk-config-docker
```

Replace with:

```bat
set IMAGE=glove80-zmk-config-docker

if "%ZMK_REPO%"=="" set ZMK_REPO=moergo-sc/zmk
```

Then find:

```bat
docker build -t "%IMAGE%" .
```

Replace with:

```bat
docker build --build-arg ZMK_REPO=%ZMK_REPO% -t "%IMAGE%" .
```

- [ ] **Step 5: CLAUDE.md**

In `CLAUDE.md`, find the line:

```
- **Local Docker build** (self-contained, clones the firmware source for you):
```

Insert before it:

```
- **This repo builds against the `calvin-barker/zmk` fork, branch `agent-status`** (agent status keys feature). CI is pinned to it. For local Docker builds pass the repo explicitly: `ZMK_REPO=calvin-barker/zmk ./build.sh agent-status`. A stock `./build.sh` against moergo-sc/zmk main no longer builds this keymap because it references `&agent_jump`.
```

- [ ] **Step 6: Rebuild to verify plumbing**

```bash
cd ~/development/glove80-zmk-config
ZMK_REPO=calvin-barker/zmk ./build.sh agent-status
```

Expected: exits 0, `./glove80.uf2` refreshed.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/build.yml Dockerfile build.sh build.bat CLAUDE.md
git commit -m "Parameterize firmware repo and point builds at the agent-status fork"
```

---

### Task 8: Prove-the-pipe script

A host-side Python script that exercises the whole firmware feature with no daemon: HELLO handshake, paint colors, then listen for JUMP messages.

**Files:**
- Create: `tools/agent_leds_test.py`

**Interfaces:**
- Consumes: the protocol constants (Global Constraints) and a flashed keyboard.
- Produces: the hardware validation tool for Task 9.

- [ ] **Step 1: Create `tools/agent_leds_test.py`**

```python
#!/usr/bin/env python3
"""Prove-the-pipe test for the Glove80 agent status firmware.

Usage:
  pip install hidapi
  python3 tools/agent_leds_test.py           # HELLO, paint 3 slots, clear
  python3 tools/agent_leds_test.py --listen  # also wait for JUMP messages
"""

import sys
import time

import hid

USAGE_PAGE = 0xFF60
USAGE = 0x61
REPORT_SIZE = 32

PROTO_VERSION = 0x01
CMD_SET_LEDS = 0x01
CMD_HELLO = 0x02
CMD_JUMP = 0x10

AMBER = (0xFF, 0xB0, 0x00)
GREEN = (0x00, 0xC8, 0x53)
RED = (0xFF, 0x17, 0x44)
OFF = (0x00, 0x00, 0x00)


def find_device():
    for info in hid.enumerate():
        if info["usage_page"] == USAGE_PAGE and info["usage"] == USAGE:
            return info["path"]
    return None


def write_report(dev, payload):
    # Leading 0x00 is the report ID byte hidapi requires; 33 bytes total.
    report = bytes([0x00]) + bytes(payload) + bytes(REPORT_SIZE - len(payload))
    n = dev.write(report)
    if n <= 0:
        raise IOError(f"HID write failed: {n}")


def set_leds(dev, slots):
    """slots: dict of slot number (1-10) to (r, g, b). Always a full frame."""
    frame = [PROTO_VERSION, CMD_SET_LEDS]
    for slot in range(1, 11):
        frame.extend(slots.get(slot, OFF))
    write_report(dev, frame)


def main():
    listen = "--listen" in sys.argv

    path = find_device()
    if path is None:
        print("No raw HID interface found (usage page 0xFF60, usage 0x61).")
        print("Is the Glove80 plugged in and flashed with the agent-status firmware?")
        sys.exit(1)

    dev = hid.device()
    dev.open_path(path)
    try:
        print(f"Opened {path.decode() if isinstance(path, bytes) else path}")

        write_report(dev, [PROTO_VERSION, CMD_HELLO])
        reply = dev.read(REPORT_SIZE, 1000)
        if reply and reply[0] == PROTO_VERSION and reply[1] == CMD_HELLO:
            print(f"HELLO ok: firmware supports {reply[2]} slots")
        else:
            print(f"HELLO reply missing or malformed: {reply}")
            sys.exit(1)

        print("Painting slot 1 amber, slot 2 green, slot 3 red for 5 seconds...")
        set_leds(dev, {1: AMBER, 2: GREEN, 3: RED})
        time.sleep(5)

        print("Clearing all slots...")
        set_leds(dev, {})

        if listen:
            print("Listening for JUMP messages; hold H and tap F1-F10 (Ctrl-C to stop)")
            while True:
                data = dev.read(REPORT_SIZE, 200)
                if data and data[0] == PROTO_VERSION and data[1] == CMD_JUMP:
                    print(f"JUMP slot {data[2]}")
    except KeyboardInterrupt:
        pass
    finally:
        dev.close()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Syntax check (no keyboard needed)**

```bash
cd ~/development/glove80-zmk-config
python3 -m py_compile tools/agent_leds_test.py && echo OK
```

Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add tools/agent_leds_test.py
git commit -m "Add raw HID prove-the-pipe script for agent status LEDs"
```

---

### Task 9: Hardware bench checklist (manual)

Flash and verify on the physical keyboard. Flashing: put a half into bootloader mode (Magic + the `&bootloader` key on its half, or the recessed reset sequence per MoErgo docs); it mounts as a USB drive (GLV80LHBOOT / GLV80RHBOOT); copy `glove80.uf2` onto it; it reboots. Flash BOTH halves from the same combined uf2. Keyboard must be connected by USB cable to the LEFT half.

- [ ] Build and flash `glove80.uf2` from Task 7 Step 6 onto both halves. Keyboard types normally (Colemak-DH base layer, home row mods work).
- [ ] `pip install hidapi`, then `python3 tools/agent_leds_test.py`: HELLO prints "firmware supports 5 slots"; amber renders under F1, green under F2, red under F3 for 5 seconds; then all clear. Colors must render with RGB underglow toggled OFF (the normal state).
- [ ] Known possible quirk on the very first paint after the keyboard has been idle: the LED power rail powers up in the same call that writes the strip, so the first frame can fail to latch and show nothing until the next write. If you see a dark first frame followed by correct behavior, report it as this quirk (a known candidate fix is delaying the first write 50-100ms after rail power-on), not as a protocol failure.
- [ ] While slots are painted, type continuously: lights stay stable, no flicker back to underglow, no stuck keys.
- [ ] Run the script, then kill it right after painting. After ~120 seconds the lights clear on their own (heartbeat timeout).
- [ ] `python3 tools/agent_leds_test.py --listen`: hold H; unlit F-row slot LEDs (F4, F5) turn dim violet while held; painted ones keep their color. Tap F1 while holding H: the script prints `JUMP slot 1`. Tap F6-F10: JUMP 6-10 print (their LEDs stay dark; expected in phase 1). Release H: violet disappears.
- [ ] Hold H for more than 200ms (past the tapping term), then tap a letter key: nothing types (Agents layer is `&none` off the F-row). A letter pressed within the first 200ms correctly resolves the hold-tap as a tap and types normally; that is expected, not a failure.
- [ ] Type "the" and "hhh" quickly many times: no misfires into the Agents layer (require-prior-idle plus F-row-only hold trigger).
- [ ] With the test script not running, the keyboard behaves fully stock: typing, layers, Magic functions, RGB toggles.
- [ ] Mark this plan's milestone done; the daemon plan (2026-07-16-glove-agentd-daemon.md) takes over from here.

---

## Self-review notes

- Spec coverage: raw HID endpoint (Task 2), LED overlay with 120s self-clear and off-underglow rendering (Tasks 3-4), HELLO/SET_LEDS/JUMP protocol (Tasks 4-5, 8), Agents layer + hold-H + `&none` filler (Task 6), violet armed indicator on unlit slots (Task 4), build pointers (Task 7), prove-the-pipe (Task 8), stock-behavior guarantee (Task 9). Phase 2 items intentionally absent.
- Protocol constants match the daemon plan: version 0x01; SET_LEDS 0x01; HELLO 0x02 reply [0x01, 0x02, 0x05]; JUMP 0x10; 32-byte reports; host writes prepend 0x00.
- Type consistency: `zmk_rgb_underglow_set_agent_pixel` / `zmk_rgb_underglow_clear_agent_pixels` / `zmk_rgb_underglow_agent_commit` are declared in Task 3 and consumed with identical signatures in Task 4.
