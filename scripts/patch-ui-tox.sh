#!/usr/bin/env bash
#
# Permanently fix TouchDesigner's clipped timeline/transport text under Wine.
#
# TD ships 23 UI text operators with dispmethod='bitmap' in Config/System/ui.tox.
# Wine cannot render that mode, so the timecode, the time-attribute fields and
# the OP-create search box show only a few rows of pixels. The usual community
# fix is an Execute DAT that rewrites them at runtime, which has to be re-added
# to every project because /ui is rebuilt on each load. This patches ui.tox
# itself, so the fix lives in the install and applies everywhere.
#
# Uses TD's own toeexpand.exe / toecollapse.exe to unpack and repack, so it
# needs TD installed in the bottle. The original is backed up before anything
# is written, and --revert puts it back.
#
# A TD update replaces ui.tox; re-run this afterwards.
#
# Usage: ./patch-ui-tox.sh [options] [bottle-name]
#   --status    report whether ui.tox is patched, change nothing
#   --revert    restore the backed-up original
#   --dry-run   list the operators that would change
#   -h, --help
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=scripts/lib.sh
. ./lib.sh

MODE='patch'
BOTTLE=''

usage() { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --status) MODE=status; shift ;;
    --revert) MODE=revert; shift ;;
    --dry-run) MODE=dry-run; shift ;;
    -h | --help) usage 0 ;;
    -*) die "unknown option $1 (--help for usage)" ;;
    *) BOTTLE="$1"; shift ;;
  esac
done
BOTTLE="${BOTTLE:-TouchDesigner}"

PREFIX="$(bottle_prefix "$BOTTLE")"
TD="$(td_dir "$BOTTLE")"
SYS="$TD/Config/System"
UI="$(td_ui_tox "$BOTTLE")"
BACKUP="$(backup_dir)"
WORK="$PREFIX/drive_c/users/$USER/uiwork"

# The operators to change, and what to change them to. The transport readouts
# render correctly on 'automatic'; the rest need 'scalable'.
AUTOMATIC='
dialogs/timeline/transport/timecode/bg
dialogs/timeline/transport/musiccode/bg
dialogs/timeline/transport/frame/bg
'
SCALABLE='
dialogs/timeline/timeattributes/rate/label/bg
dialogs/timeline/timeattributes/rate/textfield/bg
dialogs/timeline/timeattributes/clip_s/label/bg
dialogs/timeline/timeattributes/clip_s/textfield/bg
dialogs/timeline/timeattributes/clip_e/label/bg
dialogs/timeline/timeattributes/clip_e/textfield/bg
dialogs/timeline/timeattributes/range_s/label/bg
dialogs/timeline/timeattributes/range_s/textfield/bg
dialogs/timeline/timeattributes/range_e/label/bg
dialogs/timeline/timeattributes/range_e/textfield/bg
dialogs/timeline/timeattributes/signature0/label/bg
dialogs/timeline/timeattributes/signature0/textfield/bg
dialogs/timeline/timeattributes/signature1/label/bg
dialogs/timeline/timeattributes/signature1/textfield/bg
dialogs/timeline/timeattributes/tempo/label/bg
dialogs/timeline/timeattributes/tempo/textfield/bg
dialogs/timeline/timeattributes/resetf/label/bg
dialogs/timeline/timeattributes/resetf/textfield/bg
dialogs/menu_op/search/textfield/bg
dialogs/menu_op/search/textfield/bg1
'

# --- status / revert ---------------------------------------------------------

if [ "$MODE" = status ]; then
  if [ ! -f "$UI" ]; then
    bad "ui.tox not found at $SYS"
    exit 1
  fi
  if [ -f "$BACKUP/ui.tox.patched" ] && cmp -s "$UI" "$BACKUP/ui.tox.patched"; then
    ok 'patched'
  elif [ -f "$BACKUP/ui.tox.orig" ] && cmp -s "$UI" "$BACKUP/ui.tox.orig"; then
    warn 'unpatched'
  else
    warn 'unknown -- matches neither backup (never patched here, or TD was updated)'
  fi
  info "$UI"
  exit 0
fi

if [ "$MODE" = revert ]; then
  [ -f "$BACKUP/ui.tox.orig" ] || die "no backup to restore ($BACKUP/ui.tox.orig)"
  cp "$BACKUP/ui.tox.orig" "$UI"
  ok 'original ui.tox restored'
  exit 0
fi

if [ "$MODE" = dry-run ]; then
  printf 'would set dispmethod on these operators in %s:\n\n' "$UI"
  while IFS= read -r p; do [ -n "$p" ] && info "automatic  $p"; done <<<"$AUTOMATIC"
  while IFS= read -r p; do [ -n "$p" ] && info "scalable   $p"; done <<<"$SCALABLE"
  printf '\ndry run -- nothing written\n'
  exit 0
fi

# --- patch -------------------------------------------------------------------

[ -f "$UI" ] || die "ui.tox not found at $SYS"
have_bottles_cli || die 'bottles-cli not found (set BOTTLES_CLI to override)'
for exe in toeexpand.exe toecollapse.exe; do
  [ -f "$TD/bin/$exe" ] || die "$exe missing from $TD/bin -- is TD fully installed?"
done

mkdir -p "$BACKUP"
# -n: never overwrite the pristine copy with an already-patched one.
cp -n "$UI" "$BACKUP/ui.tox.orig"
info "original backed up to $BACKUP/ui.tox.orig"

rm -rf "$WORK"
mkdir -p "$WORK"
cp "$UI" "$WORK/ui.tox"

# NOTE: pass Windows paths with FORWARD slashes. bottles-cli puts arguments
# through a shell that eats backslashes, and toeexpand then writes to a
# literally-named file instead of the directory you asked for.
bottles_cli run -b "$BOTTLE" -e "$TD/bin/toeexpand.exe" "C:/users/$USER/uiwork/ui.tox"
sleep 2
[ -d "$WORK/ui.tox.dir" ] || die 'toeexpand produced no ui.tox.dir'

W="$WORK/ui.tox.dir/ui"
changed=0
set_disp() {
  local f="$W/$1.parm" want="$2"
  if [ ! -f "$f" ]; then
    warn "missing $1.parm"
    return
  fi
  if grep -q '^dispmethod ' "$f"; then
    sed -i "s/^dispmethod .*/dispmethod 0 $want/" "$f"
  else
    printf 'dispmethod 0 %s\n' "$want" >>"$f"
  fi
  changed=$((changed + 1))
}

while IFS= read -r p; do
  [ -n "$p" ] || continue
  set_disp "$p" automatic
done <<<"$AUTOMATIC"

while IFS= read -r p; do
  [ -n "$p" ] || continue
  set_disp "$p" scalable
done <<<"$SCALABLE"

ok "$changed operator(s) set"

rm -f "$WORK/ui.tox"
bottles_cli run -b "$BOTTLE" -e "$TD/bin/toecollapse.exe" "C:/users/$USER/uiwork/ui.tox.dir"
sleep 2
[ -f "$WORK/ui.tox" ] || die 'toecollapse produced nothing; the installed ui.tox is untouched'
[ -s "$WORK/ui.tox" ] || die 'toecollapse produced an empty file; the installed ui.tox is untouched'

cp "$WORK/ui.tox" "$UI"
cp "$WORK/ui.tox" "$BACKUP/ui.tox.patched"
rm -rf "$WORK"

ok 'patched ui.tox installed'
printf '\nrestart TouchDesigner. to revert: ./patch-ui-tox.sh --revert %s\n' "$BOTTLE"
