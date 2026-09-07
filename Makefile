# APEX kernel/ROM — developer workflow entrypoint.
# Thin wrapper over tools/* scripts so `make <target>` is the one entry point.
# Every target delegates to a real tool script (see tools/README.md).

SHELL := /usr/bin/env bash
.PHONY: help patch build build-clean modules verify test config package release \
        lint device-state device-boot device-logs dry-run

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-14s %s\n", $$1, $$2}'

## ---- Kernel pipeline ---------------------------------------------------

patch: ## Apply patches/apex-new/ series to kernel/ (idempotent)
	bash tools/apply-patches.sh

build: ## Build kernel incrementally (needs kernel/ + toolchain)
	bash tools/build-kernel.sh

build-clean: ## Full rebuild from clean out/
	bash tools/build-kernel.sh --clean

modules: ## Build out-of-tree modules only
	bash tools/build-kernel.sh --modules

dry-run: ## Structural dry-run of the build pipeline (fast, no side effects)
	bash tools/build-kernel.sh --dry-run

verify: ## Verify the last build (--strict: warnings are failures)
	bash tools/verify.sh --strict

test: ## Certification test suite (pytest)
	python3 -m pytest tests/cert/ -v

config: ## Validate defconfig/apex_defconfig structure
	python3 tools/check-configs.py

## ---- Packaging / release ----------------------------------------------

package: ## Build the AnyKernel3 flashable zip
	bash tools/package-anykernel3.sh

release: ## Cut a release: tests + build + tag v<ver>-zepharo + manifest
	bash tools/release.sh

## ---- Lint / static checks ---------------------------------------------

lint: ## Shell syntax + defconfig + (optional) checkpatch on APEX C sources
	@set -e; \
	fail=0; \
	for f in tools/*.sh hiding/*.sh rom-overlays/update/*.sh \
	         ksu-module/system/bin/*.sh; do \
	  [ -f "$$f" ] || continue; \
	  bash -n "$$f" || { echo "syntax error: $$f"; fail=1; }; \
	done; \
	[ "$$fail" -eq 0 ] && echo "shell syntax OK"; \
	python3 tools/check-configs.py; \
	if [ -f kernel/scripts/checkpatch.pl ]; then \
	  for c in patches/apex-new/*/src/*.c; do \
	    [ -f "$$c" ] || continue; \
	    kernel/scripts/checkpatch.pl --no-tree -f "$$c" >/dev/null 2>&1 \
	      || echo "checkpatch issues: $$c"; \
	  done; \
	fi

## ---- Device ops (hardware attached; all are ask-first) ------------------

device-state: ## One-shot device snapshot (run first, every session)
	bash tools/device/device-state.sh

device-boot: ## Boot verification after a flash (JSON output)
	bash tools/device/boot-test.sh --json

device-logs: ## Collect pstore/ramoops + dmesg + logcat
	bash tools/device/collect-boot-log.sh
