{
  description = "Scale development flake";

  inputs = {
    nixpkgs = {
      url = "github:nixos/nixpkgs/nixos-25.11";
    };
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
    scaleTargets = [
      "gfx900"
      "gfx906"
      "gfx908"
      "gfx90a"
      "gfx942"
      "gfx950"
      "gfx1010"
      "gfx1030"
      "gfx1032"
      "gfx1100"
      "gfx1101"
      "gfx1102"
      "gfx1151"
      "gfx1200"
      "gfx1201"
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
        lib,
        callPackage,
        makeWrapper,
      }: stdenv.mkDerivation (finalAttrs: rec {
        pname = "scale";
        version = "1.5.1";
        src = fetchurl {
          url = "https://pkgs.scale-lang.com/tar/scale-${version}-amd64.tar.xz";
          hash = "sha256-dzG6H0VQ+ZZO+lH4vPbB/6nG9bdVyWDyrYpXbQI6/Kg=";
        };
        dontConfigure = true;
        dontBuild = true;
        nativeBuildInputs = [ autoPatchelfHook makeWrapper ];
        buildInputs = [
          stdenv.cc.cc.lib
          zlib
          zstd
          numactl
          libdrm
          elfutils
        ];

        installPhase = ''
          mkdir -p $out
          cp -r bin cccl include lib LICENSE.txt llvm NOTICES.txt $out/

          # We only really need one of these directires since the contents are all basically
          # the same, and we're gonna rely on a unified way of configuring the compiler later.
          mkdir $out/targets
          cp -r targets/gfx1100 $out/targets/gfxany

          # Merge the architecture-specific files. These are the only differences between the
          # different targets as of writing.
          for target in $(ls targets); do
            for f in $(ls targets/$target/lib/*$target*); do
              cp -P $f $out/targets/gfxany/lib/
            done
          done

          # These are not needed, the users should get gcc elsewhere.
          rm $out/targets/gfxany/bin/gcc
          rm $out/targets/gfxany/bin/g++
        '';

        # Split out the target/ directories into separate packages
        passthru =
        let
          # Prepare a package that looks like its a normal compiler, so that
          # wrapCC can process most of the contents automatically.
          gfxany-unwrapped = callPackage ({
            runCommand,
            makeWrapper,
            scale,
          }: runCommand "${pname}-${version}-gfxany"
            {
              pname = "${pname}-${version}-gfxany";
              inherit version scale;

              passthru = {
                isClang = true;
                hardeningUnsupportedFlags = [ "zerocallusedregs" ];
              };
            }
            ''
              ln -s $scale/targets/gfxany $out
            ''
          ) {
            scale = finalAttrs.finalPackage;
          };

          gfxany = (callPackage ({
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
              # There are multiple workarounds going on here:
              # - Scale checks whether its running in nvcc mode by whether
              #   argv[0] is nvcc, so use makeWrapper to write ensure that argv[0]
              #   is correct. Note that makeWrapper has to be passed to here using
              #   nativeBuildInputs via overrideAttrs because its normally not available,
              #   and wrapCC does not have an option to add extra native build inputs.
              # - Scale detects its installation location from the current executable. We
              #   need this because nvcc -v prints PATH=/nix/store/.../targets/gfxany/bin,
              #   from which CMake gets the linker path. If this path is the one of the
              #   scale package, it tries to use the unwrapped clang++ as linker. So, we
              #   have to create the wrapper here so that scale is launched from the
              #   path with wrappers, so that it reports the wrapped clang++
              # - For the previous to work, the remaining directories in targets/gfxany
              #   need to be wired up, otherwise scale doesn't detect itself as running
              #   in nvcc mode properly.
              # - wrapCC detects whether the executable is c++ by whether it has "++" in
              #   the name, so we have to create a symlink to cheese it into setting the
              #   correct configuration.

              mkdir -p $out/targets/gfxany/bin/

              # Create an nvcc wrapper, with the correct argv[0]. But put it in a support
              # directory, since its not actually correct yet (this is an unwrapped compiler).
              makeWrapper "${scale}/llvm/bin/clang++" "$out/nix-support/nvcc" \
                --argv0 "$out/targets/gfxany/bin/nvcc"

              # Create an nvcc++ wrapper for wrapCC
              ln -s $out/nix-support/nvcc $out/nix-support/nvcc++

              # Create the actual wrapped executable. Note: outputs in $out/bin by default.
              wrap nvcc $wrapper $out/nix-support/nvcc++

              # Wire up the remaining targets/gfxany/ directories
              for f in include lib lib64 nvvm share; do
                ln -s ${scale}/targets/gfxany/$f $out/targets/gfxany/$f
                ln -s ${scale}/targets/gfxany/$f $out/$f
              done

              # For completeness, rebuild the targets/gfxany/bin directory too.
              # This is also required for CMake
              ln -s $out/bin/nvcc $out/targets/gfxany/bin/nvcc
              for f in amdgpu-arch device-linker-gnu ld.lld lld; do
                ln -s ${scale}/targets/gfxany/bin/$f $out/targets/gfxany/bin/$f
              done
              # Make sure to link these to the wrapped compilers
              for f in clang clang++; do
                ln -s $out/bin/$f $out/targets/gfxany/bin/$f
              done

              # Finally, add in the remaining scale executables in bin/
              for f in ${scale}/bin/*; do
                ln -s $f $out/bin/$(basename $f)
              done

              # Make sure that the scale includes have the highest priority. This is
              # normally the case, but nix reorders them.
              echo "-isystem ${scale}/include/redscale_impl/wrappers/" >> $out/nix-support/cc-cflags-before
              echo "-isystem ${gfxany-unwrapped}/include" >> $out/nix-support/cc-cflags-before
              # Also make sure that scale libraries are marked as more important than everything else
              # This fixes link issues when NVIDIA CUDA libraries are also available.
              echo "-L${scale}/targets/gfxany/lib" >> $out/nix-support/cc-cflags-before
            '' + lib.strings.optionalString (ccmap != null) ''
              # Manually set the target to compile for.
              echo "--cuda-ccmap=${ccmap-conf}" >> $out/nix-support/cc-cflags
            '';
          }) {
            scale = finalAttrs.finalPackage;
            inherit gfxany-unwrapped;
          }).overrideAttrs (old: {
            # Need to add makeWrapper via this cheeky way
            nativeBuildInputs = [ pkgs.makeWrapper ];
          });

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
          self.packages.${system}.scale.${arch}
        ];
      in pkgs.mkShell {
        packages = [
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
