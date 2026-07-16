# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the official ZMK firmware configuration for the MoErgo Glove80, a wireless split contoured keyboard with 80 keys. It is meant to be used as a GitHub template: users fork it, edit the keymap, push, and GitHub Actions builds a flashable `glove80.uf2`.

This repo contains **only** the keymap and build glue. The actual ZMK firmware source lives in the external `moergo-sc/zmk` repo (MoErgo's fork of ZMK) and is fetched at build time into `src/`. Nothing in `src/` is version-controlled here.

## Build

The build compiles the left and right halves separately, then merges them into one combined `glove80.uf2`.

- **CI / native Nix** (what GitHub Actions runs):
  ```
  nix-build config -o combined
  cp combined/glove80.uf2 glove80.uf2
  ```
  This requires the firmware source already checked out at `src/` (CI checks out `moergo-sc/zmk@main` into `src/` first).

- **This repo builds against the `calvin-barker/zmk` fork, branch `agent-status`** (agent status keys feature). CI is pinned to it. For local Docker builds pass the repo explicitly: `ZMK_REPO=calvin-barker/zmk ./build.sh agent-status`. A stock `./build.sh` against moergo-sc/zmk main no longer builds this keymap because it references `&agent_jump`.
- **Local Docker build** (self-contained, clones the firmware source for you):
  ```
  ./build.sh [branch]      # macOS/Linux, defaults to moergo-sc/zmk main
  build.bat [branch]       # Windows
  ```
  The optional argument is the `moergo-sc/zmk` branch/tag to build against. Output lands at `./glove80.uf2` in the repo root.

There is no test suite and no linter. "It builds" is the validation. A keymap change is verified by a successful firmware build.

## Editing the keymap

`config/glove80.keymap` is the **source of truth** for the firmware. It is a ZMK devicetree file (C preprocessor syntax, `linguist-language=C` per `.gitattributes`). This is the file to edit for any keymap change.

Structure of `config/glove80.keymap`:
- **Layers** are defined by `#define` at the top: `DEFAULT` (0), `LOWER` (1), `MAGIC` (2), `FACTORY_TEST` (3). Each has a corresponding `*_layer` node under `keymap`.
- **Bindings** in each layer are laid out as a 6-row grid matching the physical 80-key layout. The `default_layer` has an ASCII-art comment mapping positions to keys; keep it in sync when editing that layer.
- **Custom behaviors** (`behaviors` block):
  - `layer_td`: tap-dance on the LOWER key. First tap/hold = `&mo LOWER` (momentary), second tap = `&to LOWER` (toggle).
  - `magic`: hold-tap for the MAGIC key. Hold = activate a layer, tap = show RGB underglow battery/status.
- **Macros** (`macros` block): `bt_0`..`bt_3` each switch output to BLE and select a Bluetooth profile; `rgb_ug_status_macro` shows RGB status.
- The `MAGIC` layer holds firmware controls: Bluetooth profile selection/clear, RGB underglow adjustment, USB/BLE output toggle, `&bootloader`, `&sys_reset`, and the entry point to `FACTORY_TEST`.

`config/glove80.conf` holds Kconfig firmware options (currently empty). Add ZMK/Kconfig settings here.

## Layout Editor artifacts vs build inputs

Only `config/glove80.keymap` and `config/glove80.conf` are consumed by the build (see `config/default.nix`). These two are **not** build inputs:
- `config/info.json`: physical key-position metadata describing the 80-key layout for tooling.
- `config/keymap.json`: the Glove80 Layout Editor webapp's own representation of a keymap.

Do not assume `keymap.json` and `glove80.keymap` agree. In this repo they are out of sync (`keymap.json` describes only 2 layers named `base`/`fn`, while `glove80.keymap` defines 4). If you edit the keymap by hand, edit `glove80.keymap`; the JSON files will not affect the firmware. The Layout Editor is the alternative, GUI-based path most users are pointed to instead of hand-editing.

## Build internals

`config/default.nix` is the Nix entry point. It calls `firmware.zmk.override` once per half (`board = "glove80_lh"` and `glove80_rh`), passing this repo's `glove80.keymap` and `glove80.conf`, then `firmware.combine_uf2` merges the two into the single `glove80.uf2`. `firmware` defaults to `import ../src {}`, i.e. the external ZMK source. The `Dockerfile` sets up Nix + the `moergo-glove80-zmk-dev` Cachix cache, mirrors `moergo-sc/zmk`, and prebuilds dependencies for `main` and the three most recent tags to speed up local builds.
