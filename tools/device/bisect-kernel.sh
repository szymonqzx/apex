#!/usr/bin/env bash
# bisect-kernel.sh — kernel feature bisection driver (boot-failure isolation).
#
# Drives the "plain kernel → add features one at a time" loop that isolates
# which kernel feature hangs a device at boot. Every trial is safe: the
# candidate boots on the INACTIVE slot; the known-good slot stays untouched;
# on failure the tool rolls the active slot back.
#
# Stage file format (one stage per line):
#   stage-name | CONFIG_FEATURE=y | CONFIG_FEATURE2=y
# A stage enables all listed CONFIG options on top of the previous stage's
# config. Use the special value "KEEP" to inherit the previous stage's
# features without adding any.
#
# Usage: bisect-kernel.sh <stages-file> \
#            [--base-defconfig <path>] [--expect <kver>] [--expect-apex]
#            [--boot-ref <reference-boot.img>] [--no-restore] [--json]
#
# The defconfig is restored at the end unless --no-restore. Boot images are
# produced by boot-image.sh; flashes go through flash-boot.sh.
#
# Exit: 0 all stages pass, 1 a stage failed (bisect point found).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APEX="$(cd "$HERE/../.." && pwd)"
STAGES_FILE="${1:?usage: bisect-kernel.sh <stages-file> [options]}"
shift

BASE_DEFCONFIG="$APEX/defconfig/apex_defconfig"
EXPECT="5.15.211"
EXPECT_APEX=0
BOOT_REF=""
NO_RESTORE=0
JSON=0
WORK="$APEX/out/bisect"

while [ $# -gt 0 ]; do
  case "$1" in
    --base-defconfig) BASE_DEFCONFIG="$2"; shift 2 ;;
    --expect) EXPECT="$2"; shift 2 ;;
    --expect-apex) EXPECT_APEX=1 ;;
    --boot-ref) BOOT_REF="$2"; shift 2 ;;
    --no-restore) NO_RESTORE=1 ;;
    --json) JSON=1 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

[ -f "$STAGES_FILE" ] || { echo "ERROR: stages file not found: $STAGES_FILE" >&2; exit 1; }
[ -f "$BASE_DEFCONFIG" ] || { echo "ERROR: base defconfig not found: $BASE_DEFCONFIG" >&2; exit 1; }
[ -n "$BOOT_REF" ] && [ -f "$BOOT_REF" ] || { echo "ERROR: --boot-ref must point to a reference boot image" >&2; exit 1; }

mkdir -p "$WORK"
DEFCONFIG_BACKUP="$WORK/defconfig.bak"
cp "$BASE_DEFCONFIG" "$DEFCONFIG_BACKUP"

# Build the current kernel with a given defconfig; print the Image path.
build_variant() {  # <defconfig> <label>
  local def="$1" label="$2"
  echo "== [bisect] building '$label'"
  cp "$def" "$APEX/defconfig/apex_defconfig"
  if ! bash "$APEX/tools/build-kernel.sh" > "$WORK/$label-build.log" 2>&1; then
    echo "ERROR: build failed for '$label' — see $WORK/$label-build.log" >&2
    return 1
  fi
  echo "$APEX/out/arch/arm64/boot/Image"
}

report() {  # report <json-fragment>
  if [ "$JSON" -eq 1 ]; then echo "{\"bisect\":$1}"; fi
}

CURRENT_FEATURES=""
PASSED=()
FAILED=()

while IFS='|' read -r name features; do
  [ -n "${name:-}" ] || continue
  name=$(echo "$name" | xargs)
  features=$(echo "${features:-}" | xargs)
  echo "===== STAGE: $name ====="
  [ -n "$features" ] && [ "$features" != "KEEP" ] && CURRENT_FEATURES="$CURRENT_FEATURES $features"

  # Assemble the variant defconfig: start from the base, disable APEX feature
  # defaults, then enable the stage's features.
  VAR_DEF="$WORK/${name}.defconfig"
  cp "$BASE_DEFCONFIG" "$VAR_DEF"
  sed -i -E 's/^CONFIG_(KSU|KSU_SUSFS|BBG|APEX_THERMAL)(_|=).*/# CONFIG_\1 is not set/' "$VAR_DEF"
  for f in $CURRENT_FEATURES; do
    # f is a Kconfig option name, e.g. CONFIG_KSU
    sed -i -E "s|^# CONFIG_${f#CONFIG_} is not set$|${f}=y|; s|^${f}=n$|${f}=y|" "$VAR_DEF"
    grep -q "^${f}=y" "$VAR_DEF" || echo "${f}=y" >> "$VAR_DEF"
  done

  IMG=$(build_variant "$VAR_DEF" "$name") || { FAILED+=("$name:build"); break; }

  BOOT_IMG="$WORK/${name}.img"
  if [ -n "$BOOT_REF" ]; then
    if ! FEATURE_STRINGS="${features//CONFIG_/}" bash "$HERE/boot-image.sh" "$BOOT_REF" "$IMG" "$BOOT_IMG"; then
      FAILED+=("$name:boot-image"); break
    fi
  else
    cp "$IMG" "$BOOT_IMG"
  fi

  # Trial: flash inactive slot, activate, reboot, boot-test.
  if ! bash "$HERE/flash-boot.sh" "$BOOT_IMG" --activate; then
    FAILED+=("$name:flash"); break
  fi
  TEST_ARGS=(--expect "$EXPECT" --timeout 240)
  [ "$EXPECT_APEX" -eq 1 ] && TEST_ARGS+=(--expect-apex)
  if bash "$HERE/boot-test.sh" "${TEST_ARGS[@]}"; then
    echo "== [bisect] '$name' BOOTS ✓"
    PASSED+=("$name")
    report "{\"stage\":\"$name\",\"result\":\"pass\",\"features\":\"$CURRENT_FEATURES\"}"
  else
    echo "== [bisect] '$name' FAILED to boot — bisect point found"
    FAILED+=("$name:boot")
    report "{\"stage\":\"$name\",\"result\":\"fail\",\"features\":\"$CURRENT_FEATURES\"}"
    # Roll back to the previous (known-good) slot.
    bash "$HERE/slot.sh" set "$(bash "$HERE/slot.sh" other)" 2>/dev/null || true
    break
  fi
done < "$STAGES_FILE"

# Restore the canonical defconfig unless told not to.
if [ "$NO_RESTORE" -eq 0 ]; then
  cp "$DEFCONFIG_BACKUP" "$BASE_DEFCONFIG"
  echo "== [bisect] defconfig restored"
fi

echo "== [bisect] summary: passed=[${PASSED[*]}] failed=[${FAILED[*]:-none}]"
if [ "$JSON" -eq 1 ]; then
  echo "{\"passed\":[\"${PASSED[*]// /,}\"],\"failed\":[\"${FAILED[*]// /,}\"]}"
fi
[ ${#FAILED[@]} -eq 0 ]
