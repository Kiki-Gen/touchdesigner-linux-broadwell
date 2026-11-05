{
  description = "TouchDesigner on Linux under Wine/Bottles: notes, fix scripts and the tools they need";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # Wine/TD here is x86_64 only.
      systems = [ "x86_64-linux" ];

      # corefonts is marked unfree: Microsoft's licence allows use but not
      # redistribution of the extracted .ttf files. The allowance is narrowed to
      # that one package so importing this flake does not quietly turn unfree
      # packages on for everything else. If you would rather not take it from
      # Nix at all, drop it and point install-fonts.sh --from at your distro's
      # mscorefonts package, or at files you extracted yourself with cabextract.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "corefonts";
      };

      forEach = f: nixpkgs.lib.genAttrs systems (system: f (pkgsFor system));
    in
    {
      devShells = forEach (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.bottles          # provides both the GUI and bottles-cli
            pkgs.vulkan-tools     # vulkaninfo, which is how the scripts pick a driver
            pkgs.fontconfig       # fc-match, which is how they find font files
            pkgs.cabextract       # to unpack the MS core fonts installer by hand
            pkgs.corefonts        # the fonts themselves, exposed as $CORE_FONTS_DIR
            pkgs.liberation_ttf   # mono face that Lucida Console gets mapped to
          ];

          # The core fonts are handed over as a directory rather than left to
          # fontconfig: a Nix profile's fonts are only visible to fc-match if
          # fontconfig was configured to look there, which holds on NixOS and
          # not much else. install-fonts.sh --from takes this directly.
          CORE_FONTS_DIR = "${pkgs.corefonts}/share/fonts/truetype";

          shellHook = ''
            printf 'TouchDesigner-on-Wine shell\n'
            printf '  ./scripts/doctor.sh                                   state of this machine\n'
            printf '  ./scripts/configure-bottle.sh                         pin the Vulkan driver\n'
            printf '  ./scripts/install-fonts.sh --from "$CORE_FONTS_DIR"   fix the blank UI text\n'
            printf '  ./scripts/patch-ui-tox.sh                             fix the clipped timecode\n'
            printf '\ncore fonts: %s\n' "$CORE_FONTS_DIR"
          '';
        };
      });

      formatter = forEach (pkgs: pkgs.nixpkgs-fmt);
    };
}
