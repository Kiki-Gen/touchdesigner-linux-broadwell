#!/usr/bin/env bash
#
# Permanently fix TouchDesigner's clipped timeline/transport text under Wine.
#
# TD ships 23 UI text operators with dispmethod='bitmap' in Config/System/ui.tox.
# Wine cannot render that mode, so the timecode, time-attribute fields and the
# OP-create search box show only a few rows of pixels. The usual community fix is
# an Execute DAT that rewrites them at runtime, which must be re-added to every
# project. This patches ui.tox itself, so the fix is permanent and project-wide.
#
# Requires: a working Bottles bottle with TD installed (TD ships toeexpand.exe /
# toecollapse.exe, which do the unpack/repack).
#
# Usage: ./patch-ui-tox.sh <bottle-name>
set -euo pipefail

BOTTLE="${1:-TouchDesigner}"
PREFIX="$HOME/.local/share/bottles/bottles/$BOTTLE"
TD="$PREFIX/drive_c/Program Files/Derivative/TouchDesigner"
SYS="$TD/Config/System"
BACKUP="$HOME/.local/share/bottles/td-config-backup"
WORK="$PREFIX/drive_c/users/$USER/uiwork"

[ -f "$SYS/ui.tox" ] || { echo "ui.tox not found at $SYS" >&2; exit 1; }
command -v bottles-cli >/dev/null || { echo "bottles-cli not found" >&2; exit 1; }

mkdir -p "$BACKUP"
cp -n "$SYS/ui.tox" "$BACKUP/ui.tox.orig"
echo "backed up original to $BACKUP/ui.tox.orig"

rm -rf "$WORK"; mkdir -p "$WORK"
cp "$SYS/ui.tox" "$WORK/ui.tox"

# NOTE: pass Windows paths with FORWARD slashes. bottles-cli puts arguments
# through a shell that eats backslashes, and toeexpand then writes to a
# literally-named file.
bottles-cli run -b "$BOTTLE" -e "$TD/bin/toeexpand.exe" "C:/users/$USER/uiwork/ui.tox"
sleep 2
[ -d "$WORK/ui.tox.dir" ] || { echo "expand failed" >&2; exit 1; }

W="$WORK/ui.tox.dir/ui"
set_disp() {
  local f="$W/$1.parm" want="$2"
  [ -f "$f" ] || { echo "  missing $1.parm"; return; }
  if grep -q "^dispmethod " "$f"; then
    sed -i "s/^dispmethod .*/dispmethod 0 $want/" "$f"
  else
    printf 'dispmethod 0 %s\n' "$want" >> "$f"
  fi
  echo "  $1 -> $want"
}

# Transport readouts render correctly on 'automatic'; the rest need 'scalable'.
for p in timecode musiccode frame; do
  set_disp "dialogs/timeline/transport/$p/bg" automatic
done
for p in rate clip_s clip_e range_s range_e signature0 signature1 tempo resetf; do
  set_disp "dialogs/timeline/timeattributes/$p/label/bg" scalable
  set_disp "dialogs/timeline/timeattributes/$p/textfield/bg" scalable
done
set_disp "dialogs/menu_op/search/textfield/bg" scalable
set_disp "dialogs/menu_op/search/textfield/bg1" scalable

rm -f "$WORK/ui.tox"
bottles-cli run -b "$BOTTLE" -e "$TD/bin/toecollapse.exe" "C:/users/$USER/uiwork/ui.tox.dir"
sleep 2
[ -f "$WORK/ui.tox" ] || { echo "collapse failed; original left in place" >&2; exit 1; }

cp "$WORK/ui.tox" "$SYS/ui.tox"
cp "$WORK/ui.tox" "$BACKUP/ui.tox.patched"
rm -rf "$WORK"
echo
echo "patched ui.tox installed. restart TouchDesigner."
echo "to revert: cp $BACKUP/ui.tox.orig '$SYS/ui.tox'"
