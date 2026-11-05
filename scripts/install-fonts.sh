#!/usr/bin/env bash
#
# Fix TouchDesigner's blank UI text under Wine.
#
# TD's UI operators request the font 'Verdana' and resolve it through the Wine
# prefix's font REGISTRY. Two things break that on a fresh bottle:
#
#   1. Bottles writes a replacement entry mapping Verdana -> Times New Roman,
#      so the request is redirected before any installed Verdana is consulted.
#   2. Dropping .ttf files into drive_c/windows/Fonts does NOT register them.
#      Installing fonts host-side (fontconfig) makes them appear in TD's font
#      MENU but does not satisfy TD's by-filename lookup, so the UI still
#      renders nothing. TD reports this as:
#        Error Loading Default Font. Failed to load font file. Failed to load .
#      The empty filename is the tell -- it wants a file, not a family.
#
# This copies the core fonts in under the conventional Windows filenames the
# registry entries reference, registers them in HKLM, drops the Verdana
# redirect, and maps Lucida Console (TD's mono UI font, not part of corefonts)
# to a mono face that is actually installed.
#
# Font files are located with fontconfig, so this works wherever the core fonts
# came from -- nixpkgs corefonts, ttf-mscorefonts-installer, a manual
# cabextract -- as long as the host can see them. --from takes a directory
# instead, for files that are not registered with fontconfig.
#
# Usage: ./install-fonts.sh [options] [bottle-name]
#   --from <dir>   take .ttf files from this directory instead of fontconfig
#   --dry-run      report what would be installed, change nothing
#   -h, --help
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=scripts/lib.sh
. ./lib.sh

FROM=''
DRY_RUN=0
BOTTLE=''

usage() { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage 0 ;;
    -*) die "unknown option $1 (--help for usage)" ;;
    *) BOTTLE="$1"; shift ;;
  esac
done
BOTTLE="${BOTTLE:-TouchDesigner}"

PREFIX="$(bottle_prefix "$BOTTLE")"
FONTS="$PREFIX/drive_c/windows/Fonts"
USERDIR="$PREFIX/drive_c/users/$USER"

[ -d "$PREFIX" ] || die "bottle '$BOTTLE' not found ($PREFIX)"
[ -z "$FROM" ] || [ -d "$FROM" ] || die "no such directory: $FROM"

# Windows filename, family, style. The filenames are what corefonts.reg
# registers, and what TD ends up asking the prefix for.
FACES='
verdana.ttf|Verdana|Regular
verdanab.ttf|Verdana|Bold
verdanai.ttf|Verdana|Italic
verdanaz.ttf|Verdana|Bold Italic
times.ttf|Times New Roman|Regular
timesbd.ttf|Times New Roman|Bold
timesi.ttf|Times New Roman|Italic
timesbi.ttf|Times New Roman|Bold Italic
arial.ttf|Arial|Regular
arialbd.ttf|Arial|Bold
ariali.ttf|Arial|Italic
arialbi.ttf|Arial|Bold Italic
cour.ttf|Courier New|Regular
courbd.ttf|Courier New|Bold
georgia.ttf|Georgia|Regular
trebuc.ttf|Trebuchet MS|Regular
comic.ttf|Comic Sans MS|Regular
impact.ttf|Impact|Regular
andalemo.ttf|Andale Mono|Regular
webdings.ttf|Webdings|Regular
'

# Ask fontconfig for a family, but only accept the answer if it really is that
# family: fc-match always returns something, so an uninstalled face comes back
# as a silent substitute. Copying that in under a corefonts filename is worse
# than leaving the file out -- TD would render the wrong metrics and the real
# problem would stay hidden.
resolve_fontconfig() {
  local family="$1" style="$2" pattern result got file
  pattern="$family"
  [ "$style" = Regular ] || pattern="$family:style=$style"
  result="$(fc-match -f '%{family[0]}|%{file}' "$pattern" 2>/dev/null)" || return 1
  got="${result%%|*}"
  file="${result#*|}"
  [ "${got,,}" = "${family,,}" ] || return 1
  [ -f "$file" ] || return 1
  printf '%s\n' "$file"
}

# In a directory, accept either the conventional Windows name or the
# underscored style nixpkgs uses (Verdana_Bold_Italic.ttf).
resolve_dir() {
  local target="$1" family="$2" style="$3" cand candidates
  if [ -n "$style" ]; then
    # Never fall back to the regular face for a styled one: quietly installing
    # Arial.ttf as arialbd.ttf would leave TD asking for bold and getting
    # regular, with nothing in the output to show that it happened.
    candidates="$target
${family// /_}_${style// /_}.ttf"
  else
    candidates="$target
${family// /_}.ttf
${family}.ttf"
  fi
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if [ -f "$FROM/$cand" ]; then
      printf '%s\n' "$FROM/$cand"
      return
    fi
  done <<<"$candidates"
  return 1
}

head2 'font files'

installed=0
missing=''
while IFS='|' read -r target family style; do
  [ -n "$target" ] || continue
  src=''
  if [ -n "$FROM" ]; then
    style_part="$style"
    if [ "$style_part" = Regular ]; then style_part=''; fi
    src="$(resolve_dir "$target" "$family" "$style_part" || true)"
  else
    src="$(resolve_fontconfig "$family" "$style" || true)"
  fi

  if [ -z "$src" ]; then
    missing="$missing $target"
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "$target <- $src"
  else
    mkdir -p "$FONTS"
    cp -f "$src" "$FONTS/$target"
    info "$target"
  fi
  installed=$((installed + 1))
done <<<"$FACES"

if [ "$installed" -gt 0 ]; then
  ok "$installed face(s) $([ "$DRY_RUN" -eq 1 ] && echo 'would be installed' || echo installed)"
fi

# Verdana is the only one TD's UI actually needs; the rest are what a real
# corefonts install provides and are cheap to carry along.
case "$missing" in
  *verdana.ttf*)
    bad 'Verdana is not available on this host -- that is the font TD needs'
    info 'install the MS core fonts first (see SETUP.md), then re-run'
    ;;
  '') ok 'all faces found' ;;
  *) warn "not found on this host:$missing" ;;
esac

# --- registry ----------------------------------------------------------------

head2 'registry'

REGEDIT="$(bottle_regedit "$BOTTLE" || true)"
[ -n "$REGEDIT" ] || die "regedit.exe not found in the bottle's runner ($(bottle_get "$BOTTLE" Runner || echo 'no runner set'))"
info "regedit from $(bottle_get "$BOTTLE" Runner)"

# TD asks for 'Lucida Console' for mono UI text. It is not part of corefonts,
# so point it at a mono face that exists. Liberation Mono is the known-good
# choice; otherwise take whatever fontconfig calls monospace.
mono='Liberation Mono'
if command -v fc-match >/dev/null 2>&1; then
  if ! resolve_fontconfig 'Liberation Mono' Regular >/dev/null 2>&1; then
    detected="$(fc-match -f '%{family[0]}' monospace 2>/dev/null || true)"
    [ -z "$detected" ] || mono="$detected"
  fi
fi
info "Lucida Console -> $mono"

if [ "$DRY_RUN" -eq 1 ]; then
  warn 'dry run -- no .reg files imported'
  printf '\nwould import: corefonts.reg, remove-verdana-replacement.reg, mono_font.reg\n'
  [ "$CHECK_FAIL" -eq 0 ] || exit 1
  exit 0
fi

mkdir -p "$USERDIR"
cp ../fonts/corefonts.reg ../fonts/remove-verdana-replacement.reg "$USERDIR/"

# Generated rather than copied, so the mapping names a font that is installed
# here instead of a hardcoded one.
cat >"$USERDIR/mono_font.reg" <<EOF
REGEDIT4

; TD asks for "Lucida Console" as its monospace UI font. It is not part of
; corefonts and is not installed, so map it to an available mono face. This is
; the same replacement mechanism that was breaking Verdana -- used correctly.
[HKEY_CURRENT_USER\\Software\\Wine\\Fonts\\Replacements]
"Lucida Console"="$mono"
EOF

for r in corefonts.reg remove-verdana-replacement.reg mono_font.reg; do
  printf '  importing %s\n' "$r"
  # Forward slashes: bottles-cli puts arguments through a shell that eats
  # backslashes, and regedit then looks for a literally-named file.
  bottles_cli run -b "$BOTTLE" -e "$REGEDIT" -- /S "C:/users/$USER/$r" >/dev/null 2>&1 || true
  sleep 2
done

# --- confirm -----------------------------------------------------------------

head2 'result'

if font_registered "$BOTTLE" verdana.ttf; then
  ok 'verdana.ttf registered in HKLM'
else
  bad 'verdana.ttf still not registered -- the .reg import did not take'
  info "import by hand: bottles-cli run -b $BOTTLE -e '$REGEDIT' -- /S 'C:/users/$USER/corefonts.reg'"
fi

replacement="$(font_replacement "$BOTTLE" Verdana || true)"
if [ -z "$replacement" ]; then
  ok 'Verdana redirect is gone'
else
  bad "Verdana is still redirected to $replacement"
fi

mapped="$(font_replacement "$BOTTLE" 'Lucida Console' || true)"
if [ -n "$mapped" ]; then ok "Lucida Console -> $mapped"; fi

printf '\n'
if [ "$CHECK_FAIL" -gt 0 ]; then
  printf 'something did not take -- see above\n'
  exit 1
fi
printf "done. restart TouchDesigner; 'Error Loading Default Font' should be gone.\n"
