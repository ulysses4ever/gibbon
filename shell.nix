let
  moz_overlay = import (builtins.fetchGit {
                   name = "nixpkgs-mozilla-2023-07-05";
                   url = "https://github.com/ckoparkar/nixpkgs-mozilla";
                   # Commit hash for nixos as of 2023-07-05
                   ref = "refs/heads/master";
                   rev = "9b05600b23ec227b663a5059e22a744ef6751ced";
                 });
  pkgs = import (builtins.fetchGit {
                   url = "https://github.com/nixos/nixpkgs/";
                   ref = "refs/tags/22.11";
                 }) { overlays = [ moz_overlay ]; };
  stdenv = pkgs.overrideCC pkgs.stdenv pkgs.gcc7;
  ghc = pkgs.haskell.compiler.ghc94;
  rust = (pkgs.rustChannelOf { rustToolchain = ./gibbon-rts/rust-toolchain; }).rust;
  clang = pkgs.clang_14;
  llvm = pkgs.llvm_14;
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
                    rust
                    # Racket
                    racket
                    # Other utilities
                    stdenv ncurses unzip which rr rustfmt clippy ghcid gdb valgrind
                  ];
    shellHook = ''
      export GIBBONDIR=${gibbon_dir}
      export HC=${ghc}/bin/ghc
    '';
  }
