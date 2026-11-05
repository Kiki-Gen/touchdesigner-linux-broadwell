# shellcheck shell=bash
# Shared helpers for the scripts in this directory. Sourced, never executed.
#
# Nothing here needs Wine to be running, or python/yq to be installed: bottle
# settings are read out of bottle.yml, and Windows registry state out of the
# prefix's system.reg / user.reg, both of which are plain text.

# --- output ------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'
  C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_BAD=''; C_DIM=''; C_OFF=''
fi

# Each check prints one line, and bumps a counter the caller can report on.
CHECK_WARN=0
CHECK_FAIL=0

ok()   { printf '%s  ok  %s %s\n'   "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '%s warn %s %s\n'   "$C_WARN" "$C_OFF" "$*"; CHECK_WARN=$((CHECK_WARN + 1)); }
bad()  { printf '%s fail %s %s\n'   "$C_BAD"  "$C_OFF" "$*"; CHECK_FAIL=$((CHECK_FAIL + 1)); }
info() { printf '      %s%s%s\n'    "$C_DIM"  "$*"     "$C_OFF"; }
head2() { printf '\n%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- locations ---------------------------------------------------------------

# Bottles stores its data in one of two places depending on how it was
# installed. $BOTTLES_HOME overrides the guess.
bottles_home() {
  if [ -n "${BOTTLES_HOME:-}" ]; then
    printf '%s\n' "$BOTTLES_HOME"
  elif [ -d "$HOME/.local/share/bottles/bottles" ]; then
    printf '%s\n' "$HOME/.local/share/bottles"
  elif [ -d "$HOME/.var/app/com.usebottles.bottles/data/bottles/bottles" ]; then
    printf '%s\n' "$HOME/.var/app/com.usebottles.bottles/data/bottles"
  else
    printf '%s\n' "$HOME/.local/share/bottles"
  fi
}

bottle_prefix() { printf '%s/bottles/%s\n' "$(bottles_home)" "$1"; }
bottle_yml()    { printf '%s/bottle.yml\n' "$(bottle_prefix "$1")"; }

# Run bottles-cli however it is installed here. $BOTTLES_CLI overrides.
bottles_cli() {
  if [ -n "${BOTTLES_CLI:-}" ]; then
    # Deliberately unquoted: the override may carry its own arguments.
    # shellcheck disable=SC2086
    $BOTTLES_CLI "$@"
  elif command -v bottles-cli >/dev/null 2>&1; then
    command bottles-cli "$@"
  elif command -v flatpak >/dev/null 2>&1 &&
    flatpak info com.usebottles.bottles >/dev/null 2>&1; then
    flatpak run --command=bottles-cli com.usebottles.bottles "$@"
  else
    printf 'bottles-cli not found (set BOTTLES_CLI to override)\n' >&2
    return 127
  fi
}

have_bottles_cli() {
  [ -n "${BOTTLES_CLI:-}" ] ||
    command -v bottles-cli >/dev/null 2>&1 ||
    { command -v flatpak >/dev/null 2>&1 &&
      flatpak info com.usebottles.bottles >/dev/null 2>&1; }
}

# --- bottle.yml --------------------------------------------------------------

# Top-level scalar: Runner, Windows, DXVK, Arch, ...
bottle_get() {
  local yml
  yml="$(bottle_yml "$1")"
  [ -f "$yml" ] || return 1
  sed -n "s/^$2:[[:space:]]*//p" "$yml" | head -1 | tr -d "'\"" | tr -d '\r'
}

# One key from the Environment_Variables block, which is a flat mapping
# indented by four spaces and terminated by the next unindented key.
bottle_env_get() {
  local yml
  yml="$(bottle_yml "$1")"
  [ -f "$yml" ] || return 1
  awk -v want="$2" '
    /^Environment_Variables:[[:space:]]*$/ { inblock = 1; next }
    inblock && /^[^[:space:]]/            { inblock = 0 }
    inblock && /^    [A-Za-z_][A-Za-z0-9_]*:/ {
      key = $1; sub(/:$/, "", key)
      if (key == want) {
        sub(/^    [A-Za-z_][A-Za-z0-9_]*:[[:space:]]*/, "")
        print; exit
      }
    }
  ' "$yml"
}

# Where the bottle's runner lives, honouring an explicit RunnerPath.
bottle_runner_dir() {
  local rp runner
  rp="$(bottle_get "$1" RunnerPath 2>/dev/null || true)"
  if [ -n "$rp" ] && [ -d "$rp" ]; then
    printf '%s\n' "$rp"
    return
  fi
  runner="$(bottle_get "$1" Runner 2>/dev/null || true)"
  [ -n "$runner" ] || return 1
  printf '%s/runners/%s\n' "$(bottles_home)" "$runner"
}

# regedit.exe from the runner the bottle actually uses -- not whichever runner
# happens to sort first, which is what picking blindly gets you once more than
# one is installed.
bottle_regedit() {
  local dir rel
  dir="$(bottle_runner_dir "$1")" || return 1
  for rel in \
    lib/wine/x86_64-windows/regedit.exe \
    lib64/wine/x86_64-windows/regedit.exe \
    files/lib/wine/x86_64-windows/regedit.exe \
    lib32/wine/i386-windows/regedit.exe \
    files/lib/wine/i386-windows/regedit.exe; do
    if [ -f "$dir/$rel" ]; then
      printf '%s/%s\n' "$dir" "$rel"
      return
    fi
  done
  return 1
}

td_dir()     { printf '%s/drive_c/Program Files/Derivative/TouchDesigner\n' "$(bottle_prefix "$1")"; }
td_ui_tox()  { printf '%s/Config/System/ui.tox\n' "$(td_dir "$1")"; }
backup_dir() { printf '%s/td-config-backup\n' "$(bottles_home)"; }

# Version as recorded by the installer, e.g. 2022.35320.
td_version() {
  local reg
  reg="$(bottle_prefix "$1")/system.reg"
  [ -f "$reg" ] || return 1
  grep -o 'TouchDesigner\.[0-9][0-9.]*' "$reg" 2>/dev/null |
    sed 's/^TouchDesigner\.//' | sort -u | head -1
}

# --- registry (read-only, straight out of the prefix) ------------------------

# Is a font file registered under HKLM...\Windows NT\CurrentVersion\Fonts?
# Registration is what TD's by-filename lookup consults; a .ttf sitting in
# drive_c/windows/Fonts without an entry here is invisible to it.
font_registered() {
  local reg
  reg="$(bottle_prefix "$1")/system.reg"
  [ -f "$reg" ] || return 1
  grep -qi "\"$2\"" "$reg"
}

# A HKCU\Software\Wine\Fonts\Replacements entry, if any. Prints the target.
font_replacement() {
  local reg
  reg="$(bottle_prefix "$1")/user.reg"
  [ -f "$reg" ] || return 1
  awk -v want="\"$2\"" '
    /^\[Software\\\\Wine\\\\Fonts\\\\Replacements\]/ { inblock = 1; next }
    inblock && /^\[/                                 { inblock = 0 }
    inblock && index($0, want) == 1 {
      sub(/^[^=]*=/, ""); gsub(/"/, ""); print; exit
    }
  ' "$reg"
}

# --- vulkan ------------------------------------------------------------------

icd_dir() {
  local d
  for d in /run/opengl-driver/share/vulkan/icd.d \
    /usr/share/vulkan/icd.d \
    /usr/local/share/vulkan/icd.d; do
    if [ -d "$d" ]; then
      printf '%s\n' "$d"
      return
    fi
  done
  return 1
}

# Ask the loader what a single ICD actually enumerates, which is the only
# reliable way to tell a usable driver from one that finds no GPU at all.
# Prints "<device type>|<device name>", or nothing.
probe_icd() {
  command -v vulkaninfo >/dev/null 2>&1 || return 1
  VK_DRIVER_FILES="$1" VK_ICD_FILENAMES="$1" vulkaninfo --summary 2>/dev/null |
    awk '
      /deviceName[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); name = $0 }
      /deviceType[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); type = $0 }
      END {
        if (name == "") exit 1
        sub(/^PHYSICAL_DEVICE_TYPE_/, "", type)
        printf "%s|%s\n", type, name
      }
    '
}

# Integrated or discrete GPU, as opposed to llvmpipe's CPU device.
icd_is_hardware() { case "$1" in INTEGRATED_GPU | DISCRETE_GPU) return 0 ;; *) return 1 ;; esac; }

# The GPU as the kernel sees it: vendor:device and the bound driver. Works
# without lspci, which is not installed everywhere.
gpu_summary() {
  local dev vendor device driver
  for dev in /sys/class/drm/card*/device; do
    [ -e "$dev/vendor" ] || continue
    vendor="$(tr -d '\n' <"$dev/vendor")"
    device="$(tr -d '\n' <"$dev/device")"
    driver='?'
    if [ -e "$dev/driver" ]; then driver="$(basename "$(readlink -f "$dev/driver")")"; fi
    printf '%s:%s (%s)\n' "${vendor#0x}" "${device#0x}" "$driver"
  done
}
