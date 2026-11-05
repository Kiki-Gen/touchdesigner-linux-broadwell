#!/usr/bin/env bash
#
# Pin the Vulkan driver a bottle hands to TouchDesigner.
#
# Left unpinned, the Vulkan loader can give TD a device it cannot use. On
# Broadwell that meant startup crashes and ~5 fps; pinned to the driver that
# actually enumerates the GPU, the same build runs at 60. The right driver is
# not guessable from the hardware name -- Gen8 is served by Mesa's hasvk while
# anv finds no GPU at all -- so by default this probes every installed ICD and
# picks one that reports a real GPU.
#
# Writes bottle.yml directly and reads it back to confirm. bottles-cli's
# `edit --params` silently drops some values.
#
# Usage: ./configure-bottle.sh [options] [bottle-name]
#   --icd <path|auto>   driver to pin (default: auto)
#   --dxvk-overrides    also route d3d9/d3d10core/d3d11/dxgi to DXVK
#   --dry-run           print what would change, write nothing
#   -h, --help
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=scripts/lib.sh
. ./lib.sh

ICD=auto
DXVK_OVERRIDES=0
DRY_RUN=0
BOTTLE=''

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --icd) ICD="${2:-}"; shift 2 ;;
    --dxvk-overrides) DXVK_OVERRIDES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage 0 ;;
    -*) die "unknown option $1 (--help for usage)" ;;
    *) BOTTLE="$1"; shift ;;
  esac
done
BOTTLE="${BOTTLE:-TouchDesigner}"

YML="$(bottle_yml "$BOTTLE")"
[ -f "$YML" ] || die "bottle '$BOTTLE' not found ($YML)"

# --- choose the driver -------------------------------------------------------

if [ "$ICD" = auto ]; then
  command -v vulkaninfo >/dev/null 2>&1 ||
    die 'auto needs vulkaninfo (nix develop, or install vulkan-tools). Or pass --icd <path>.'
  dir="$(icd_dir)" || die 'no Vulkan ICD directory found'

  ICD=''
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    result="$(probe_icd "$f")" || continue
    [ -n "$result" ] || continue
    if icd_is_hardware "${result%%|*}"; then
      printf 'found %s -> %s\n' "$(basename "$f")" "${result#*|}"
      [ -n "$ICD" ] || ICD="$f"
    fi
  done
  [ -n "$ICD" ] || die 'no installed Vulkan driver enumerates a hardware GPU'
else
  [ -f "$ICD" ] || die "no such ICD file: $ICD"
fi

printf 'pinning %s\n' "$ICD"

# --- edit ---------------------------------------------------------------------

# Replace a key inside the Environment_Variables block, or add it to the block,
# or create the block. The block is a flat four-space mapping ending at the
# next unindented key.
set_env_var() {
  local file="$1" key="$2" value="$3"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    /^Environment_Variables:[[:space:]]*$/ && !seen { seen = 1; print; next }
    seen && !done && /^[^[:space:]]/ {
      # End of the block without having seen the key: add it here.
      printf "    %s: %s\n", key, value
      done = 1
      print
      next
    }
    seen && !done && /^    [A-Za-z_][A-Za-z0-9_]*:/ {
      k = $1; sub(/:$/, "", k)
      if (k == key) {
        printf "    %s: %s\n", key, value
        done = 1
        next
      }
    }
    { print }
    END {
      if (!seen) printf "Environment_Variables:\n    %s: %s\n", key, value
      else if (!done) printf "    %s: %s\n", key, value
    }
  ' "$file"
}

apply() {
  local key="$1" value="$2" current
  current="$(bottle_env_get "$BOTTLE" "$key" || true)"
  if [ "$current" = "$value" ]; then
    ok "$key already set"
    return
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "would set $key"
    info "  from: ${current:-<unset>}"
    info "    to: $value"
    return
  fi
  local tmp
  tmp="$(mktemp)"
  set_env_var "$YML" "$key" "$value" >"$tmp"
  # Never leave a truncated bottle.yml behind if awk goes wrong.
  [ -s "$tmp" ] || { rm -f "$tmp"; die "refusing to write an empty bottle.yml"; }
  cat "$tmp" >"$YML"
  rm -f "$tmp"

  # bottles-cli has been known to accept a value and not persist it, so the
  # only trustworthy confirmation is reading it back.
  if [ "$(bottle_env_get "$BOTTLE" "$key" || true)" = "$value" ]; then
    ok "$key set"
  else
    bad "$key did not persist -- edit $YML by hand"
  fi
}

if pgrep -x bottles >/dev/null 2>&1 || pgrep -f 'bottles.*main' >/dev/null 2>&1; then
  warn 'Bottles appears to be running; close it or it may overwrite these edits'
fi

BACKUP="$(backup_dir)"
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$BACKUP"
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp "$YML" "$BACKUP/bottle.yml.$stamp"
  info "backed up bottle.yml to $BACKUP/bottle.yml.$stamp"
fi

apply VK_DRIVER_FILES "$ICD"

if [ "$DXVK_OVERRIDES" -eq 1 ]; then
  apply WINEDLLOVERRIDES 'd3d9,d3d10core,d3d11,dxgi=n'
fi

printf '\n'
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'dry run -- nothing written\n'
else
  printf 'done. restart TouchDesigner, then ./doctor.sh %s to confirm.\n' "$BOTTLE"
fi
