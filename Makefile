# Firmware build and bench helpers for the agent status keys project.
# The build runs inside a persistent Docker container because this machine
# has no native nix; see .superpowers/sdd/progress.md for the decisions.

ZMK_DIR ?= $(HOME)/development/zmk
CONTAINER := zmk-nix
# Cap compile parallelism inside the container. Nix defaults to all cores,
# and 18 emulated compilers outrun Docker Desktop's default memory allowance
# (the kernel OOM-kills the build: exit 137). Raise if your VM has 12GB+.
NIX_CORES ?= 2

.PHONY: help container firmware flash test-leds listen bench

help: ## show available targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

container: ## create or start the persistent zmk-nix build container
	@docker start $(CONTAINER) 2>/dev/null || \
	  docker run -d --name $(CONTAINER) --platform linux/amd64 -v "$(ZMK_DIR):/src" -w /src nixpkgs/nix:nixos-23.11 sleep infinity
	@# Repair configuration in place every run: a container created any other
	@# way (or an interrupted setup) would otherwise fail with
	@# "unable to load seccomp BPF program" under Docker emulation.
	@# Pure-sh checks: the container's exec shell has no grep on PATH.
	@docker exec $(CONTAINER) sh -c 'case "$$(cat /etc/nix/nix.conf 2>/dev/null)" in *"filter-syscalls = false"*) : ;; *) mkdir -p /etc/nix && printf "sandbox = false\nfilter-syscalls = false\n" >> /etc/nix/nix.conf ;; esac'
	@docker exec $(CONTAINER) sh -c 'export PATH=/root/.nix-profile/bin:$$PATH; case "$$(cat /root/.config/nix/nix.conf /etc/nix/nix.conf 2>/dev/null)" in *moergo-glove80-zmk-dev*) : ;; *) command -v cachix >/dev/null || nix-env -iA cachix -f https://cachix.org/api/v1/install; cachix use moergo-glove80-zmk-dev ;; esac'

firmware: container ## build combined glove80.uf2 against the fork, copy to repo root
	docker exec $(CONTAINER) sh -c 'rm -rf /cfg && mkdir -p /cfg'
	docker cp config $(CONTAINER):/cfg/config
	docker exec $(CONTAINER) sh -c 'nix-build /cfg/config --arg firmware "import /src/default.nix {}" -j1 --cores $(NIX_CORES) -o /tmp/combined'
	docker cp $(CONTAINER):/tmp/combined/glove80.uf2 ./glove80.uf2
	@ls -la glove80.uf2

flash: ## flash both halves (put each in bootloader mode when prompted)
	@test -f glove80.uf2 || { echo "no glove80.uf2 here; run 'make firmware' first"; exit 1; }
	@echo "Put the LEFT half in bootloader mode. Waiting for GLV80LHBOOT to mount..."
	@until [ -d /Volumes/GLV80LHBOOT ]; do sleep 1; done
	@cp glove80.uf2 /Volumes/GLV80LHBOOT/ || echo "(an I/O error here is normal: the half reboots mid-copy)"
	@echo "Left half flashed."
	@echo "Put the RIGHT half in bootloader mode. Waiting for GLV80RHBOOT to mount..."
	@until [ -d /Volumes/GLV80RHBOOT ]; do sleep 1; done
	@cp glove80.uf2 /Volumes/GLV80RHBOOT/ || echo "(an I/O error here is normal: the half reboots mid-copy)"
	@echo "Right half flashed. Reconnect USB to the LEFT half."

test-leds: ## HELLO handshake, paint slots 1-3, clear (needs: pip install hidapi)
	python3 tools/agent_leds_test.py

listen: ## paint, then listen for JUMP messages (hold H + tap F-keys)
	python3 tools/agent_leds_test.py --listen

bench: ## print the Task 9 hardware bench checklist
	@sed -n '/^### Task 9/,/^---/p' docs/superpowers/plans/2026-07-16-agent-status-firmware-and-keymap.md
