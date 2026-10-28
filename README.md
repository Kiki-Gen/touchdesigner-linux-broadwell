# TouchDesigner on Linux — Broadwell / Bottles notes

Getting **TouchDesigner 2022.35320** running properly under Wine (Bottles) on a
2015 MacBook Pro with an **Intel HD Graphics 6000 (Broadwell / Gen8)** iGPU,
on NixOS + KDE Plasma 6.

Everything here was worked out by measurement on that machine. The two fixes
that matter — font **registration** and the `ui.tox` patch — apply to any Wine
install of TD, not just this hardware.

## Summary

| Symptom | Cause | Fix |
| --- | --- | --- |
| Crashes at startup / unusable lag | Vulkan loader hands TD a device it can't use | Pin the ICD to Mesa **hasvk** |
| **No text anywhere in the UI** | TD requests `Verdana`; Wine redirects it to Times New Roman, and fonts copied into the prefix were never *registered* | `scripts/install-fonts.sh` |
| Timecode / time fields show a few rows of pixels | TD ships 23 UI text ops with `dispmethod='bitmap'`, which Wine can't render | `scripts/patch-ui-tox.sh` |
| Blank Palette / operator panels | same font problem as above | `scripts/install-fonts.sh` |

## Version choice

- **2022.35320 works.** This is the build to use on pre-Skylake Intel.
- **2023+ / 2025 cannot work.** DXVK and TD both require the Vulkan
  `descriptorIndexing` feature, which Broadwell's driver does not expose:
  `Skipping: Device does not support required feature 'descriptorIndexing'`.
- **2021 does not work** — deterministic segfault inside `libTD.dll` during
  startup, unaffected by runner, fonts, DXVK or Windows version.

## Graphics

Runner: **soda-9.0-1**. Wine 10+ reportedly has a DWrite regression with TD.

Pin the Vulkan driver in `bottle.yml`:

```yaml
Environment_Variables:
    VK_DRIVER_FILES: /run/opengl-driver/share/vulkan/icd.d/intel_hasvk_icd.x86_64.json
```

Broadwell is served by Mesa's **hasvk**, *not* `anv` — `intel_icd.json` finds no
GPU at all on Gen8. Without pinning, the loader may hand TD an unusable device:
that caused both the startup crashes and ~5 fps. With it pinned, TD runs at 60 fps.
`lvp_icd` (llvmpipe) also works but is software-only and far too slow.

DXVK 1.10.3 is optional. 3.x will not initialise (needs `descriptorIndexing`);
1.10.3 does, giving D3D11 at feature level 10_0. It was not required for any fix
here, but it works and avoids the wined3d → OpenGL path.

## The font problem (the hard one)

TD's UI text operators have `font = 'Verdana'` and `fontfile = ''`. The telltale
log line is:

```
Error Loading Default Font. Failed to load font file. Failed to load . Substituted with Tahoma.
```

The **empty filename** means TD wants a font *file*, resolved via the prefix's
font registry. Two independent things break that:

1. Bottles writes `"Verdana"="Times New Roman"` into
   `HKCU\Software\Wine\Fonts\Replacements` when the prefix is created, so every
   Verdana request is redirected regardless of what is installed.
2. Copying `.ttf` files into `drive_c/windows/Fonts` **does not register them**.
   Installing corefonts host-side via fontconfig only populates TD's font *menu*
   (those land in `HKCU\Software\Wine\Fonts\External Fonts`); it does not satisfy
   the by-filename lookup. This is the step `winetricks corefonts` performs and
   that hand-copying skips.

Fix: conventional filenames (`verdana.ttf`, `verdanab.ttf`, …) plus entries in
`HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts`, drop the Verdana
redirect, and map `Lucida Console` (TD's mono font, absent from corefonts) to an
available mono face. Run `scripts/install-fonts.sh`.

## The clipped timecode (separate bug)

TD ships 23 UI text operators with `dispmethod='bitmap'` inside
`Config/System/ui.tox`. Wine renders that mode as a few rows of pixels. The
community fix is `wine_ui_fixes.tox`, an Execute DAT that rewrites them at
runtime — but `/ui` is rebuilt on every project load, so it must be re-added to
every project.

`scripts/patch-ui-tox.sh` instead unpacks `ui.tox` with TD's own `toeexpand.exe`,
sets the 23 operators to `automatic`/`scalable`, and repacks with
`toecollapse.exe`. The fix then lives in TD's installed UI and is permanent.
A TD update will overwrite `ui.tox`, so keep the backup it makes.

## Things that look like the cause but are not

Ruled out by direct measurement — don't spend time here:

- **`dispmethod` globally.** A pixel read-back (`TOP.numpyArray()`) shows
  `automatic`, `bitmap` and `scalable` all rasterise glyphs at full brightness.
  Only `polygon` and `stroke` fail (they need geometry rendering). Sweeping every
  UI operator to `scalable` does not fix the Palette.
- **Repointing operators to an installed font** (e.g. Tahoma) appears to work but
  only masks it: `scalable` ignores point metrics, so it fixes the timeline and
  nothing else.
- **DPI.** `LogPixels` is already `0x60` (96).
- **GLSL / shaders.** No compile errors; `op('/ui').errors(recurse=True)` is empty.
  The Palette's rows are plain Text TOPs, no shaders involved.
- **Panel compositing or missing data.** The Palette's own text operators read
  back rendered pixels, its data table holds 301 rows, and the container is
  `display=True`, while the stub `already_open` panel is `display=False`.
- **The graphics backend.** The same blank text occurs under llvmpipe, hasvk,
  wined3d→GL and DXVK→Vulkan. It was never a GPU problem.

## Gotchas

- Pass Windows paths to TD's CLI tools with **forward slashes**
  (`C:/users/you/x.tox`). `bottles-cli` puts arguments through a shell that eats
  backslashes, and `toeexpand` then writes to a literally-named file.
- `bottles-cli edit --params` silently fails to persist some values. Edit
  `bottle.yml` directly and verify.
- Bottles' component repo (`repo.usebottles.com`) is gone. Seed runners and
  components into `~/.local/share/bottles/` by hand from GitHub. `bottles-cli`
  always prints "Forcing offline mode" — that is by design, not an error.
- Don't delete the `dxvk`/`vkd3d`/`nvapi`/`latencyflex` component directories;
  Bottles' essential-components check needs them to create or manage bottles.

## Licence

Public domain / CC0 — notes and glue scripts, use freely.
