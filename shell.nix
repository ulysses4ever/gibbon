let
  pkgs = import (builtins.fetchGit {
                   url = "https://github.com/nixos/nixpkgs/";
                   ref = "refs/tags/24.05";
                 }) {};
  stdenv = pkgs.overrideCC pkgs.stdenv pkgs.gcc7;
  # stuck with GCC 7 because Cilk was kicked out in GCC 8,
  # need OpenCilk packaged in nixpkgs, see
  # https://github.com/NixOS/nixpkgs/issues/144256

  ghc = pkgs.haskell.compiler.ghc910;
  clang = pkgs.clang_16;
  llvm = pkgs.llvm_16;
  gibbon_dir = builtins.toString ./.;
in
  with pkgs;
  stdenv.mkDerivation {
    name = "basicGibbonEnv";
    buildInputs = [ # Haskell
                    ghc cabal-install stack
                    # C/C++
                    clang llvm gcc7 boehmgc uthash
                    # Rust
                    rustc cargo
                    # Racket
                    racket
                    # Other utilities
                    stdenv ncurses unzip which rr rustfmt clippy ghcid gdb valgrind
                  ];
    shellHook = ''
      export GIBBONDIR=${gibbon_dir}
    '';
  }
