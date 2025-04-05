# NixOS SCALE development flake

This flake contains packages and dev shells for the [SCALE](https://scale-lang.com) programming language. Packages and shells are split out into separate packages for each supported SCALE AMD target.

## Packages

The following packages are available in this flake:
- `scale`: This is the "base" scale package, containing all the basic compilers, libraries, headers, etc. This package should be added to the library path to provide `libredscale.so`, the SCALE run-time library. The `targets/` directory is mostly stripped out of here, read on for how to use SCALE with this flake instead.
- `scale.gfxany-unwrapped`: This is a package thar extracts the `targets/gfxany/bin` files into a separate package, mostly to make it compatible with NixOS's "standard" compiler package layout.
- `scale.gfxany`: This is a wrapped version of `gfxany-unwrapped`, where all of the compiler flags are patched up by NixOS scripts. By default, this package is not very useful, as SCALE will not know which AMD GPU to target. In order to do that, the package should be customized with a [ccmap](https://docs.scale-lang.com/stable/manual/compute-capabilities). The ccmap can be configured as follows:
    ```nix
    nixos-scale.packages.${system}.scale.gfxany.override {
      ccmap = {
        # The library will report compute capability 6.1 for gfx900 devices.
        # The compiler will use gfx900 for `sm_61` or `compute_61`.
        "61" = "gfx900";

        # The library will report compute capability 8.6 for gfx1030 devices.
        # The compiler will use gfx1030 for any of `sm_80`, `compute_80`,
        # `sm_86`, or `compute_86`.
        "86" = "gfx1030";
        "80" = "gfx1030";

        # The compiler will use gfx1100 for any compute capability other than 6.1, 8.0, or 8.6.
        default = "gfx1100";
      };
    };
    ```
    The simplest option is to only configure the fallback option. For these systems, the flake already includes a convenience alias.
- `scale.gfx1100`, `scale.gfx1101`, etc: Convenience aliases for `scale.gfxany`, configured for the corresponding AMD architecture where all architectures are mapped to the one. These are usually the ones you want.

## Shells

The flake also contains some development shells which automatically pull in the right package and configure the `LD_LIBRARY_PATH` to include `libredscale`. Each `gfxXXX` architecture has a dedicated shell. It can be used using the `inputsFrom` attribute in your development flake:
    ```nix
    {
      inputs = {
        nixpkgs = ...;

        nixos-scale = {
          url = "github:Snektron/nixos-scale";
          inputs.nixpkgs.follow = "nixpkgs";
        };
      };

      outputs = { self, nixpkgs, nixos-scale }: let
        system = "x86_64-linux";
        pkgs = import nixpkgs { inherit system; };
      in {
        devShells.${system}.default = pkgs.mkShell {
          inputsFrom = [
            nixos-scale.devShells.${system}.gfx1100 # or any other architecture of your liking
          ];
        };
      };
    }
    ```
Of course, you can also just use `nix develop .#<shell>` to get a configured environment.

Note that either of these options modify your `LD_LIBRARY_PATH`, which may or may not cause problems with other software in your shell, and especially with ROCm.
