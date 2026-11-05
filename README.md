# TouchDesigner on Linux — Broadwell / Bottles notes

Getting **TouchDesigner 2022.35320** running properly under Wine (Bottles) on a
2015 MacBook Pro with an **Intel HD Graphics 6000 (Broadwell / Gen8)** iGPU,
on NixOS + KDE Plasma 6.

Everything here was worked out by measurement on that machine. The two fixes
that matter — font **registration** and the `ui.tox` patch — apply to any Wine
install of TD, not just this hardware.

## Start here

```sh
nix develop                # or install bottles-cli, vulkan-tools, fontconfig yourself
./scripts/doctor.sh        # what state is this machine in?
```

`doctor.sh` is read-only and safe to run before anything exists. It probes your
graphics stack, then reports on the bottle, the TD install, font registration
and the `ui.tox` patch — each line with the script that fixes it.

**[SETUP.md](SETUP.md) is the full path from an empty machine to a working
install.** The rest of this file is why those steps are what they are.

## Summary

| Symptom | Cause | Fix |
| --- | --- | --- |
| Crashes at startup / unusable lag | Vulkan loader hands TD a device it can't use | `scripts/configure-bottle.sh` |
| **No text anywhere in the UI** | TD requests `Verdana`; Wine redirects it to Times New Roman, and fonts copied into the prefix were never *registered* | `scripts/install-fonts.sh` |
| Timecode / time fields show a few rows of pixels | TD ships 23 UI text ops with `dispmethod='bitmap'`, which Wine can't render | `scripts/patch-ui-tox.sh` |
| Blank Palette / operator panels | same font problem as above | `scripts/install-fonts.sh` |

## What's in here

| | |
| --- | --- |
| `scripts/doctor.sh` | Read-only check of graphics, bottle, TD, fonts and the patch. |
| `scripts/configure-bottle.sh` | Probes the installed Vulkan drivers and pins one that works. |
| `scripts/install-fonts.sh` | Installs **and registers** the core fonts in the prefix. |
| `scripts/patch-ui-tox.sh` | Patches `ui.tox` so the timecode renders. `--status`, `--revert`. |
| `scripts/lib.sh` | Shared bottle/registry/Vulkan introspection. |
| `fonts/*.reg` | The registry entries the font fix imports. |
| `flake.nix` | `nix develop` shell with every tool the scripts need. |

All four scripts take a bottle name (default `TouchDesigner`), support
`--dry-run`, and work with a Flatpak Bottles via `$BOTTLES_CLI` / `$BOTTLES_HOME`.

## Version choice

- **2022.35320 works.** This is the build to use on pre-Skylake Intel.
- **2023+ / 2025 cannot work.** DXVK and TD both require the Vulkan
  `descriptorIndexing` feature, which Broadwell's driver does not expose:
  `Skipping: Device does not support required feature 'descriptorIndexing'`.
- **2021 does not work** — deterministic segfault inside `libTD.dll` during
  startup, unaffected by runner, fonts, DXVK or Windows version.

Check your own GPU with `vulkaninfo | grep -i descriptorIndexing`. If it is
`true`, you are not limited to an old build and can skip the version advice —
the font and `ui.tox` fixes still apply.

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

Which driver that is on *your* machine is not guessable from the hardware name,
so `configure-bottle.sh` asks each installed ICD what it enumerates and pins one
that reports a real GPU:

```
intel_hasvk_icd.x86_64.json -> Intel(R) HD Graphics 6000 (BDW GT3) [INTEGRATED_GPU]  <- usable
lvp_icd.x86_64.json -> llvmpipe (LLVM 21.1.8, 256 bits) [CPU]  (software, far too slow for TD)
```

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

It locates the font files with fontconfig, so it does not care where they came
from — but it only accepts an answer whose family really is the one asked for.
`fc-match` always returns *something*: ask it for Lucida Console on a machine
without it and it will hand back Noto Sans, and installing that as `lucon.ttf`
would bury the problem rather than fix it.

## The clipped timecode (separate bug)

TD ships 23 UI text operators with `dispmethod='bitmap'` inside
`Config/System/ui.tox`. Wine renders that mode as a few rows of pixels. The
community fix is `wine_ui_fixes.tox`, an Execute DAT that rewrites them at
runtime — but `/ui` is rebuilt on every project load, so it must be re-added to
every project.

`scripts/patch-ui-tox.sh` instead unpacks `ui.tox` with TD's own `toeexpand.exe`,
sets the 23 operators to `automatic`/`scalable`, and repacks with
`toecollapse.exe`. The fix then lives in TD's installed UI and is permanent.
A TD update will overwrite `ui.tox`, so keep the backup it makes
(`--revert` restores it).

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
  `bottle.yml` directly and verify — `configure-bottle.sh` reads back every
  value it writes for this reason.
- Bottles' component repo (`repo.usebottles.com`) is gone. Seed runners and
  components into `~/.local/share/bottles/` by hand from GitHub. `bottles-cli`
  always prints "Forcing offline mode" — that is by design, not an error.
- Don't delete the `dxvk`/`vkd3d`/`nvapi`/`latencyflex` component directories;
  Bottles' essential-components check needs them to create or manage bottles.
- Registry state can be read without running Wine: `system.reg` and `user.reg`
  in the prefix are plain text. That is how `doctor.sh` checks registration.

## Licence

The notes and glue scripts are public domain / CC0 — see [LICENSE](LICENSE), use
freely.

Nothing proprietary is redistributed here. **TouchDesigner** is Derivative's and
you download it yourself; the **Microsoft core fonts** are licensed for use but
not for redistribution, so this repo carries only the registry entries that
reference them by filename, never the `.ttf` files.
