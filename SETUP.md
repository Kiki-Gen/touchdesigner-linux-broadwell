# Setting this up from scratch

Start to finish, on a machine that has none of it. Every command here was run on
the machine described in the [README](README.md); where something is specific to
that hardware it says so.

The short version: find out what your GPU can actually do, pick a TD version it
can run, create the bottle, then apply the three fixes.

## What you need

- An x86_64 Linux machine.
- [Bottles](https://usebottles.com/), native or Flatpak.
- A **TouchDesigner installer for Windows** that you supply yourself. It is not
  redistributable, so it is not in this repo -- download it from Derivative
  (an account is free; their download page keeps older builds).
- The **Microsoft core fonts**. Also not redistributable, also not in this repo.
- Roughly 5 GB of disk for the prefix and the install.

With Nix, the tools come from this repo:

```sh
nix develop github:Kiki-Gen/touchdesigner-linux-broadwell   # or: git clone && nix develop
```

That gives you `bottles-cli`, `vulkaninfo`, `fc-match`, `cabextract`, the core
fonts as `$CORE_FONTS_DIR`, and Liberation Mono. Without Nix, install those from
your distro: Bottles, `vulkan-tools`, `fontconfig`, `cabextract`, and whichever
package carries the MS core fonts (Debian/Ubuntu `ttf-mscorefonts-installer`,
Arch `ttf-ms-fonts` from the AUR, Fedora `curl`+`cabextract` by hand).

If Bottles is a Flatpak, the scripts find it on their own. To be explicit:

```sh
export BOTTLES_CLI='flatpak run --command=bottles-cli com.usebottles.bottles'
export BOTTLES_HOME="$HOME/.var/app/com.usebottles.bottles/data/bottles"
```

## 1. Find out what your GPU can do

```sh
./scripts/doctor.sh
```

Before any bottle exists this mostly reports on your graphics stack, which is
the part that decides everything else. The interesting section probes every
installed Vulkan driver and says what each one actually enumerates:

```
intel_hasvk_icd.x86_64.json -> Intel(R) HD Graphics 6000 (BDW GT3) [INTEGRATED_GPU]  <- usable
lvp_icd.x86_64.json -> llvmpipe (LLVM 21.1.8, 256 bits) [CPU]  (software, far too slow for TD)
```

Three outcomes:

- **A driver reports INTEGRATED_GPU or DISCRETE_GPU.** Good. That is the one to
  pin in step 5, and `configure-bottle.sh` will pick it for you.
- **Only llvmpipe answers.** TD will start and be unusably slow. Fix your Mesa
  or vendor driver install first.
- **Nothing answers.** Vulkan is not working on this machine at all; TD cannot
  run. This is a host problem, not a TD one.

Note that the driver that works is not predictable from the hardware name. On
Broadwell, Mesa's `hasvk` serves the GPU and `anv` (`intel_icd.json`) finds no
device whatsoever -- it is installed, it loads, and it enumerates nothing. The
probe is the only reliable answer.

## 2. Pick a TouchDesigner version

One Vulkan feature decides this:

```sh
vulkaninfo | grep -i descriptorIndexing
```

- **`descriptorIndexing = true`** -- anything Skylake-or-newer, and all recent
  AMD/NVIDIA. You are not limited to an old build; use a current TD. The font
  and `ui.tox` fixes below still apply, since they are Wine problems rather than
  GPU ones.
- **`descriptorIndexing = false`** (what this hardware reports) -- TD 2023+ and
  DXVK 2.x/3.x will refuse to initialise:
  `Skipping: Device does not support required feature 'descriptorIndexing'`.
  Use **2022.35320**. TD 2021 is not an alternative: it segfaults inside
  `libTD.dll` during startup regardless of runner, fonts, DXVK or Windows
  version.

## 3. Seed a runner

Bottles' component repository (`repo.usebottles.com`) is gone, so the runner
has to be placed by hand. `bottles-cli` printing "Forcing offline mode" is by
design and not an error.

```sh
mkdir -p ~/.local/share/bottles/runners
curl -L https://github.com/bottlesdevs/wine/releases/download/soda-9.0-1/soda-9.0-1-x86_64.tar.xz \
  | tar -xJ -C ~/.local/share/bottles/runners
ls ~/.local/share/bottles/runners      # expect: soda-9.0-1-x86_64
```

**soda-9.0-1** is what this was proven on. Wine 10+ reportedly regressed DWrite
in a way that affects TD, so newer is not automatically better here.

Bottles also checks for its "essential components" before it will manage a
bottle, and expects non-empty `dxvk/`, `vkd3d/`, `nvapi/` and `latencyflex/`
directories next to `runners/`. If it complains, seed those the same way from
[bottlesdevs/components](https://github.com/bottlesdevs/components/releases),
one subdirectory per component:

```
~/.local/share/bottles/dxvk/dxvk-1.10.3/
~/.local/share/bottles/vkd3d/vkd3d-proton-3.0.1/
~/.local/share/bottles/nvapi/dxvk-nvapi-v0.9.2/
~/.local/share/bottles/latencyflex/latencyflex-v0.1.1/
```

Do not delete them afterwards -- the check runs every time.

## 4. Create the bottle and install TD

```sh
bottles-cli new --bottle-name TouchDesigner --environment application \
  --arch win64 --runner soda-9.0-1-x86_64

bottles-cli run -b TouchDesigner -e ~/Downloads/TouchDesigner.2022.35320.exe
```

The installer's own GUI appears. Accept the default location so TD lands in
`C:\Program Files\Derivative\TouchDesigner`, which is where the scripts look.

DXVK is optional. On this hardware 1.10.3 initialises and gives D3D11 at feature
level 10_0; 2.x and 3.x will not start (see step 2). It fixed nothing on its own
but does avoid the wined3d-to-OpenGL path. If you use it, add the DLL overrides
in the next step.

## 5. Pin the Vulkan driver

```sh
./scripts/configure-bottle.sh                   # probes, then pins what works
./scripts/configure-bottle.sh --dxvk-overrides  # also route d3d9/10/11/dxgi to DXVK
./scripts/configure-bottle.sh --dry-run         # show the change, write nothing
```

This is not a tuning step. Unpinned, the loader can hand TD a device it cannot
use: on this machine that produced startup crashes and about 5 fps, and pinning
the driver that the probe found took the same build to 60.

It writes `bottle.yml` directly and reads the value back, because
`bottles-cli edit --params` accepts some values without persisting them. Close
the Bottles GUI first, or it may write its own copy over the edit.

## 6. Fix the blank UI text

```sh
./scripts/install-fonts.sh                            # finds fonts via fontconfig
./scripts/install-fonts.sh --from "$CORE_FONTS_DIR"   # or take them from a directory
./scripts/install-fonts.sh --dry-run                  # show what it would do
```

Use `--from` when the fonts are not registered with fontconfig -- a Nix profile
on a non-NixOS host, or files you extracted yourself:

```sh
curl -LO https://downloads.sourceforge.net/corefonts/IELPKTH.CAB   # and friends
cabextract -L IELPKTH.CAB
./scripts/install-fonts.sh --from .
```

The script refuses to pass off a substitute as Verdana. If it reports Verdana
missing, install the core fonts before going further -- that one font is what
TD's UI asks for.

`winetricks corefonts` does the same job inside the prefix, if you would rather
use it. What does **not** work is copying `.ttf` files into
`drive_c/windows/Fonts`, or installing them host-side: see the README for why.

## 7. Fix the clipped timecode

```sh
./scripts/patch-ui-tox.sh            # unpack ui.tox, fix 23 operators, repack
./scripts/patch-ui-tox.sh --status   # is it patched?
./scripts/patch-ui-tox.sh --revert   # put the original back
```

The original is copied to `~/.local/share/bottles/td-config-backup/ui.tox.orig`
before anything is written. A TD update replaces `ui.tox`, so re-run this after
upgrading.

## 8. Launch it

```sh
bottles-cli run -b TouchDesigner -p TouchDesigner
./scripts/doctor.sh                  # expect: all checks passed
```

What a working install looks like:

- UI text is readable everywhere, including the Palette's operator list.
- The timecode and the time-attribute fields show full-height digits, not a
  few rows of pixels.
- No `Error Loading Default Font` in the output.
- 60 fps on an idle project.

## If it still is not right

| What you see | Check |
| --- | --- |
| No text anywhere in the UI | `doctor.sh` -- is `verdana.ttf` registered, and is the Verdana redirect gone? Both come from step 6. |
| `Error Loading Default Font. Failed to load .` | Same. The empty filename means the registry lookup failed, not that a file is missing. |
| Crashes at startup, or a few fps | Step 5. `doctor.sh` tells you whether the pinned driver enumerates a hardware GPU. |
| `Skipping: Device does not support required feature 'descriptorIndexing'` | The TD or DXVK version is too new for this GPU -- step 2. |
| Timecode is a sliver of pixels | Step 7. |
| Bottles refuses to create or manage the bottle | Essential components -- step 3. |
| `toeexpand` writes a file with a literal `\` in the name | Pass Windows paths with forward slashes. The scripts already do. |

## Replicating on other hardware

Two things here are specific to pre-Skylake Intel: the **version ceiling**
(step 2) and the fact that **hasvk** is the driver that works (step 5, which the
probe decides for you anyway).

The rest is not hardware-specific. Font **registration** and the `ui.tox`
`dispmethod` patch are Wine-level problems and apply to any Wine install of
TouchDesigner, on any GPU.
