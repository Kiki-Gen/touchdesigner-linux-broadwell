#!/usr/bin/env bash
#
# Report the state of a TouchDesigner bottle: graphics, bottle settings, the
# TD install, font registration and the ui.tox patch. Read-only -- it changes
# nothing and does not need TD or Wine to be running.
#
# Run it before you start (to see what your machine can do) and after each
# step (to see whether the step took).
#
# Usage: ./doctor.sh [bottle-name]        (default: TouchDesigner)
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=scripts/lib.sh
. ./lib.sh

BOTTLE="${1:-TouchDesigner}"
PREFIX="$(bottle_prefix "$BOTTLE")"

printf 'TouchDesigner-on-Wine checkup -- bottle %s\n' "$BOTTLE"
info "$PREFIX"

# --- host tools --------------------------------------------------------------

head2 'host tools'

if have_bottles_cli; then
  ok 'bottles-cli available'
else
  bad 'bottles-cli not found'
  info 'install Bottles, or set BOTTLES_CLI. nix develop in this repo provides it.'
fi

if command -v fc-match >/dev/null 2>&1; then
  ok 'fontconfig (fc-match) available'
else
  bad 'fc-match not found -- install-fonts.sh needs it to locate font files'
fi

if command -v vulkaninfo >/dev/null 2>&1; then
  ok 'vulkaninfo available'
else
  warn 'vulkaninfo not found -- cannot test which Vulkan driver works'
  info 'nix develop, or install vulkan-tools, then re-run for the ICD probe'
fi

# --- graphics ----------------------------------------------------------------

head2 'graphics'

gpus="$(gpu_summary || true)"
if [ -n "$gpus" ]; then
  while IFS= read -r g; do ok "GPU $g"; done <<<"$gpus"
else
  warn 'no GPU found under /sys/class/drm'
fi

# TD and DXVK need a Vulkan driver that actually enumerates the GPU. On this
# class of hardware the wrong driver is present and silently useless, so the
# only trustworthy answer comes from asking each one in turn.
if icds="$(icd_dir)"; then
  ok "Vulkan ICDs in $icds"
  recommended=''
  if command -v vulkaninfo >/dev/null 2>&1; then
    for f in "$icds"/*.json; do
      [ -f "$f" ] || continue
      name="$(basename "$f")"
      if result="$(probe_icd "$f")" && [ -n "$result" ]; then
        type="${result%%|*}"
        device="${result#*|}"
        if icd_is_hardware "$type"; then
          info "$name -> $device [$type]  <- usable"
          [ -n "$recommended" ] || recommended="$f"
        else
          info "$name -> $device [$type]  (software, far too slow for TD)"
        fi
      fi
    done
    if [ -n "$recommended" ]; then
      ok "pin this one: $recommended"
    else
      bad 'no Vulkan driver enumerates a hardware GPU'
      info 'TD will not run usably. Check your Mesa/driver install first.'
    fi
  fi
else
  bad 'no Vulkan ICD directory found'
fi

# --- bottle ------------------------------------------------------------------

head2 'bottle'

if [ ! -d "$PREFIX" ]; then
  bad "bottle '$BOTTLE' does not exist"
  info 'see SETUP.md -- create it first, then re-run this'
  printf '\n%s warnings, %s failures\n' "$CHECK_WARN" "$CHECK_FAIL"
  exit 1
fi
ok 'prefix exists'

runner="$(bottle_get "$BOTTLE" Runner || true)"
if [ -n "$runner" ]; then
  if runner_dir="$(bottle_runner_dir "$BOTTLE")" && [ -d "$runner_dir" ]; then
    ok "runner $runner"
  else
    bad "runner $runner is named in bottle.yml but not installed"
    info 'seed it into the runners/ directory -- see SETUP.md'
  fi
else
  warn 'no runner recorded in bottle.yml'
fi

if bottle_regedit "$BOTTLE" >/dev/null 2>&1; then
  ok 'regedit.exe located in that runner'
else
  bad 'regedit.exe not found in the runner -- install-fonts.sh cannot import .reg files'
fi

winver="$(bottle_get "$BOTTLE" Windows || true)"
if [ -n "$winver" ]; then info "windows version: $winver"; fi

dxvk="$(bottle_get "$BOTTLE" DXVK || true)"
if [ -n "$dxvk" ]; then
  case "$dxvk" in
    *-1.*) info "dxvk: $dxvk (1.x -- the series that works on pre-Skylake)" ;;
    *) warn "dxvk: $dxvk -- 2.x/3.x need descriptorIndexing, absent on Gen8" ;;
  esac
fi

# --- the Vulkan pin ----------------------------------------------------------

head2 'vulkan pin'

pinned="$(bottle_env_get "$BOTTLE" VK_DRIVER_FILES || true)"
if [ -z "$pinned" ]; then
  warn 'VK_DRIVER_FILES is not set in bottle.yml'
  info 'unpinned, the loader may hand TD a device it cannot use: crashes or ~5 fps'
  info './configure-bottle.sh '"$BOTTLE"
elif [ ! -f "$pinned" ]; then
  bad "VK_DRIVER_FILES points at a missing file: $pinned"
elif command -v vulkaninfo >/dev/null 2>&1; then
  if result="$(probe_icd "$pinned")" && icd_is_hardware "${result%%|*}"; then
    ok "pinned to ${result#*|}"
  else
    bad "pinned driver enumerates no hardware GPU: $(basename "$pinned")"
    info './configure-bottle.sh '"$BOTTLE"' picks the one that does'
  fi
else
  ok "pinned to $(basename "$pinned")"
  info 'install vulkaninfo to confirm it actually enumerates the GPU'
fi

overrides="$(bottle_env_get "$BOTTLE" WINEDLLOVERRIDES || true)"
if [ -n "$overrides" ]; then info "dll overrides: $overrides"; fi

# --- TouchDesigner -----------------------------------------------------------

head2 'touchdesigner'

TD="$(td_dir "$BOTTLE")"
if [ -d "$TD" ]; then
  version="$(td_version "$BOTTLE" || true)"
  ok "installed${version:+ -- $version}"
  case "$version" in
    2022.*) : ;;
    '') warn 'could not read the version out of the registry' ;;
    2021.*) warn "$version segfaults in libTD.dll on this hardware; use 2022.35320" ;;
    *) warn "$version needs Vulkan descriptorIndexing; use 2022.35320 on pre-Skylake" ;;
  esac
  for exe in TouchDesigner.exe toeexpand.exe toecollapse.exe; do
    [ -f "$TD/bin/$exe" ] || warn "missing $exe in the install's bin/"
  done
else
  bad 'TouchDesigner is not installed in this bottle'
  info "expected at $TD"
fi

# --- fonts -------------------------------------------------------------------

head2 'fonts'

FONTS="$PREFIX/drive_c/windows/Fonts"
missing_files=''
for f in verdana.ttf verdanab.ttf times.ttf arial.ttf cour.ttf; do
  [ -f "$FONTS/$f" ] || missing_files="$missing_files $f"
done
if [ -z "$missing_files" ]; then
  ok 'core font files present under conventional names'
else
  bad "missing from drive_c/windows/Fonts:$missing_files"
  info './install-fonts.sh '"$BOTTLE"
fi

# Present but unregistered is the failure that looks like success: the files
# are right there, and TD still cannot resolve them.
if font_registered "$BOTTLE" verdana.ttf; then
  ok 'verdana.ttf registered in HKLM'
else
  bad 'verdana.ttf is not registered -- TD cannot resolve it by filename'
  info './install-fonts.sh '"$BOTTLE"
fi

replacement="$(font_replacement "$BOTTLE" Verdana || true)"
if [ -z "$replacement" ]; then
  ok 'no Verdana replacement entry'
else
  bad "Verdana is redirected to $replacement -- every request is substituted"
  info './install-fonts.sh '"$BOTTLE"' removes it'
fi

mono="$(font_replacement "$BOTTLE" 'Lucida Console' || true)"
if [ -n "$mono" ]; then
  ok "Lucida Console mapped to $mono"
else
  warn 'Lucida Console is unmapped -- TD mono UI text may be missing'
fi

# --- ui.tox ------------------------------------------------------------------

head2 'ui.tox patch'

UI="$(td_ui_tox "$BOTTLE")"
BK="$(backup_dir)"
if [ ! -f "$UI" ]; then
  warn 'ui.tox not found (TD not installed?)'
elif [ -f "$BK/ui.tox.patched" ] && cmp -s "$UI" "$BK/ui.tox.patched"; then
  ok 'patched'
elif [ -f "$BK/ui.tox.orig" ] && cmp -s "$UI" "$BK/ui.tox.orig"; then
  warn 'unpatched -- timecode and time fields will show clipped text'
  info './patch-ui-tox.sh '"$BOTTLE"
else
  warn 'unknown state -- matches neither backup (a TD update replaces ui.tox)'
  info './patch-ui-tox.sh '"$BOTTLE"' is safe to re-run; it backs up first'
fi

# --- verdict -----------------------------------------------------------------

printf '\n'
if [ "$CHECK_FAIL" -gt 0 ]; then
  printf '%d failure(s), %d warning(s)\n' "$CHECK_FAIL" "$CHECK_WARN"
  exit 1
elif [ "$CHECK_WARN" -gt 0 ]; then
  printf '%d warning(s), no failures\n' "$CHECK_WARN"
else
  printf 'all checks passed\n'
fi
