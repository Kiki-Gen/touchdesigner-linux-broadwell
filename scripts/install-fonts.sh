#!/usr/bin/env bash
#
# Fix TouchDesigner's blank UI text under Wine.
#
# TD's UI operators request the font 'Verdana' and resolve it through the Wine
# prefix's font REGISTRY. Two things break this on a fresh bottle:
#
#   1. Bottles/Proton prefixes ship a replacement entry mapping
#      Verdana -> Times New Roman, so the request is redirected before any
#      installed Verdana is consulted.
#   2. Dropping .ttf files into drive_c/windows/Fonts does NOT register them.
#      Installing fonts host-side (fontconfig) makes them appear in TD's font
#      MENU but does not satisfy TD's by-filename lookup, so the UI still
#      renders nothing. TD reports this as:
#        Error Loading Default Font. Failed to load font file. Failed to load .
#      The empty filename is the tell.
#
# This copies corefonts in under conventional Windows filenames, registers them
# in HKLM, drops the Verdana redirect, and maps Lucida Console (TD's mono font,
# not part of corefonts) to an available mono face.
#
# Usage: ./install-fonts.sh <bottle-name> <path-to-corefonts-ttf-dir>
#   e.g. ./install-fonts.sh TouchDesigner ~/.nix-profile/share/fonts/truetype
set -euo pipefail

BOTTLE="${1:-TouchDesigner}"
SRC="${2:-}"
PREFIX="$HOME/.local/share/bottles/bottles/$BOTTLE"
FONTS="$PREFIX/drive_c/windows/Fonts"
USERDIR="$PREFIX/drive_c/users/$USER"
RUNNER=$(ls -d "$HOME/.local/share/bottles/runners/"*/ | head -1)
REGEDIT="${RUNNER}lib/wine/x86_64-windows/regedit.exe"

[ -d "$PREFIX" ] || { echo "bottle $BOTTLE not found" >&2; exit 1; }
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "give the corefonts .ttf directory" >&2; exit 1; }

mkdir -p "$FONTS" "$USERDIR"

# Conventional Windows filenames, which is what the registry entries reference.
declare -A MAP=(
  [Verdana.ttf]=verdana.ttf              [Verdana_Bold.ttf]=verdanab.ttf
  [Verdana_Italic.ttf]=verdanai.ttf      [Verdana_Bold_Italic.ttf]=verdanaz.ttf
  [Times_New_Roman.ttf]=times.ttf        [Times_New_Roman_Bold.ttf]=timesbd.ttf
  [Arial.ttf]=arial.ttf                  [Arial_Bold.ttf]=arialbd.ttf
  [Courier_New.ttf]=cour.ttf             [Georgia.ttf]=georgia.ttf
  [Trebuchet_MS.ttf]=trebuc.ttf          [Impact.ttf]=impact.ttf
)
for from in "${!MAP[@]}"; do
  if [ -f "$SRC/$from" ]; then
    cp -f "$SRC/$from" "$FONTS/${MAP[$from]}"
    echo "  ${MAP[$from]}"
  fi
done

cp "$(dirname "$0")/../fonts/"*.reg "$USERDIR/"
for r in corefonts.reg remove-verdana-replacement.reg mono_font.reg; do
  [ -f "$USERDIR/$r" ] || continue
  echo "importing $r"
  bottles-cli run -b "$BOTTLE" -e "$REGEDIT" -- /S "C:/users/$USER/$r" >/dev/null 2>&1 || true
  sleep 2
done

echo
echo "done. restart TouchDesigner; 'Error Loading Default Font' should be gone."
