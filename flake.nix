{
  description = "Scale development flake";

  inputs = {
    nixpkgs = {
      url = "github:nixos/nixpkgs/nixos-25.05";
    };
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
    scaleTargets = [
      "gfx1010"
      "gfx1030"
      "gfx1100"
      "gfx1101"
      "gfx1102"
      "gfx900"
    ];
  in {
    packages.${system} = {
      scale = pkgs.callPackage ({
        stdenv,
        fetchurl,
        autoPatchelfHook,
        zlib,
        zstd,
        numactl,
        libdrm,
        elfutils,
        # TODO: This should be removed all together,
        # its currently only needed for hiprtc which should really be part
        # of the scale distribution.
        rocmPackages_6,
        lib,
        callPackage,
        # Should we get gcc from the stdenv?
        gcc
      }: stdenv.mkDerivation (finalAttrs: rec {
        pname = "scale-unstable";
        version = "2025.03.24";
        src = fetchurl {
          url = "https://unstable-pkgs.scale-lang.com/tar/scale-free-unstable-${version}-amd64.tar.xz";
          hash = "sha256-YJ4KgB7cvFqVP8UCWF6Zq+WtoeLkgx2hopWC/Tc/jmg=";
        };
        dontConfigure = true;
        dontBuild = true;
        nativeBuildInputs = [ autoPatchelfHook ];
        buildInputs = [
          stdenv.cc.cc.lib
          zlib
          zstd
          numactl
          libdrm
          elfutils
          rocmPackages_6.clr
        ];

        installPhase = ''
          mkdir -p $out
          cp -r bin cccl include lib LICENSE.txt llvm NOTICES.txt $out/

          # Only copy the gfxany target. Its the only one we need
          mkdir -p $out/targets
          cp -r targets/gfxany $out/targets

          # Fix up dead gcc and g++ links
          rm $out/targets/gfxany/bin/gcc
          ln -s ${gcc}/bin/gcc $out/targets/gfxany/bin/gcc

          rm $out/targets/gfxany/bin/g++
          ln -s ${gcc}/bin/g++ $out/targets/gfxany/bin/g++
        '';

        # Split out the target/ directories into separate packages
        passthru =
        let
          gfxany-unwrapped = callPackage ({
            runCommand,
            makeWrapper,
            scale,
          }: runCommand "${pname}-${version}-gfxany"
            {
              pname = "${pname}-${version}-gfxany";
              nativeBuildInputs = [ makeWrapper ];
              inherit version scale;
              passthru = {
                isClang = true;
              };
            }
            ''
              targetdir="$scale/targets/gfxany/bin"
              mkdir -p $out/bin
              for exe in clang clang++ device-linker-gnu ld.lld nvcc; do
                # Use makeWrapper as scale uses argv[0] to determine the builtin libs/includes
                makeWrapper "$targetdir/$exe" "$out/bin/$exe"
              done
              # Required because wrapCC treats *++ as c++
              ln -s $out/bin/nvcc $out/bin/nvcc++
            ''
          ) {
            scale = finalAttrs.finalPackage;
          };

          gfxany = callPackage ({
            wrapCCWith,
            writeText,
            scale,
            gfxany-unwrapped,
            # This is supposed to be in the following format:
            # ccmap = {
            #   "86" = "gfx1030";
            #   default = "gfx1100";
            # };
            #
            # See https://docs.scale-lang.com/stable/manual/compute-capabilities/
            ccmap ? null
          }:
          let
            ccmap-lines = (lib.attrsets.mapAttrsToList
              (cc: arch: if cc == "default" then "${arch}" else "${cc} ${arch}")
              ccmap);

            ccmap-conf = writeText "ccmap.conf"
              (lib.strings.concatLines ccmap-lines);
          in wrapCCWith rec {
            cc = gfxany-unwrapped;
            extraBuildCommands = ''
              wrap nvcc $wrapper $ccPath/nvcc++

              ln -s ${cc}/bin/device-linker-gnu $out/bin/device-linker-gnu

              # Make sure that the wrappers have the highest priority
              echo "-isystem=${scale}/include/redscale/redscale_impl/wrappers/" >> $out/nix-support/cc-cflags
            '' + lib.strings.optionalString (ccmap != null) ''
              # Manually set the target to compile for.
              echo "--cuda-ccmap=${ccmap-conf}" >> $out/nix-support/cc-cflags
            '';
          }) {
            scale = finalAttrs.finalPackage;
            inherit gfxany-unwrapped;
          };

          wrapped-compilers = lib.attrsets.genAttrs
            scaleTargets
            (arch: gfxany.override {
              ccmap = { default = arch; };
            });
        in { inherit gfxany-unwrapped gfxany; } // wrapped-compilers;
      })) {};
    };

    devShells.${system} = pkgs.lib.genAttrs
      scaleTargets
      (arch: let
         LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
          self.packages.${system}.scale
        ];
      in pkgs.mkShell {
        packages = [
          self.packages.${system}.scale
          self.packages.${system}.scale.${arch}
        ];

        # just using `inherit LD_LIBRARY_PATH` here doesn't seem to compose very
        # well, so just set the library path via an environment variable...
        shellHook = ''
          export "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:$LD_LIBRARY_PATH"
        '';
      });
  };
}
