{
  pkgs ? import <nixpkgs> {
    config.allowUnfree = true;
    config.allowBroken = true;
  },
  ci ? false,
}:

let
  videreNix = import ./nix/videre.nix {
    inherit ci pkgs;
  };
in
pkgs.mkShell {
  buildInputs = videreNix.packages ++ (with pkgs; [ flutter git ]);

  shellHook = (videreNix.prepareShell {}) + ''
  echo "Setting up submodules"
  git submodule init
  git submodule update

  echo "Setting up pre-commit hook"
  dart run tools/setup_git_hooks.dart

  export PATH="./submodules/flutter/bin:$PATH"

  echo "creating useful aliases..."
  alias build-runner="dart run build_runner build --delete-conflicting-outputs"
  alias build-runner-watch="dart run build_runner watch --delete-conflicting-outputs"
  flutter config --jdk-dir ${pkgs.jdk21}/lib/openjdk
  echo -e "\nAll done 🎉 \nAvailable aliases:"
  echo "build-runner: Run code generation once"
  echo "build-runner-watch: Watch for changes and run code generation"
  '';

  # Required for locale support in `nix-shell --pure` on NixOS.
  LOCALE_ARCHIVE = if pkgs.stdenv.isLinux then "${pkgs.glibcLocales}/lib/locale/locale-archive" else "";
}
