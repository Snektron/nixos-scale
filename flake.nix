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
        version = "1.5.0";
        src = fetchurl {
          url = "https://pkgs.scale-lang.com/tar/scale-${version}-amd64.tar.xz";
          hash = "sha256-kExMD6m5li1zpKDjlZrqSHqhS3wuZABhEU4qoqnG/lw=";
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

          # wrapCC detects if a compiler is c++ by whether it has ++ in the name,
          # so create an extra symlink.
          ln -s $out/targets/gfxany/bin/nvcc $out/targets/gfxany/bin/nvcc++

          # Actually, scale checks whether its running in nvcc mode by whether
          # argv[0] is nvcc, so use makeWrapper to write ensure that argv[0]
          # is correct.
          rm $out/targets/gfxany/bin/nvcc
          makeWrapper "$out/llvm/bin/clang++" "$out/targets/gfxany/bin/nvcc" \
            --argv0 "$out/targets/gfxany/bin/nvcc"
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
              };
            }
            ''
              ln -s $scale/targets/gfxany $out
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

              # Make sure that the scale includes have the highest priority. This is
              # normally the case, but nix reorders them.
              echo "-isystem ${scale}/include/redscale_impl/wrappers/" >> $out/nix-support/cc-cflags-before
              echo "-isystem ${gfxany-unwrapped}/include" >> $out/nix-support/cc-cflags-before
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
