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
