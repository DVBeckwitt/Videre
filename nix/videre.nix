{ pkgs, ci ? false }:

let
  helpers = {
    postgres = {
      setup = builtins.readFile ./helpers/postgres/init_db.sh;
      clean = builtins.readFile ./helpers/postgres/clean.sh;
      packages = pkgs: [ pkgs.postgresql ];
    };

    invidious = {
      setup = builtins.readFile ./helpers/invidious/setup.sh;
      clean = ''
        if [ -n "$INVIDIOUS_PID" ]; then
          kill "$INVIDIOUS_PID" 2>/dev/null || true
        fi
      '';
      packages = pkgs: [ pkgs.invidious ];
    };
  };
in
{
  inherit helpers;

  packages = helpers.postgres.packages pkgs ++ helpers.invidious.packages pkgs;

  prepareShell = { setupScripts ? [], cleanupScripts ? [] }: ''
    export NIX_SHELL_DIR="$PWD/.nix-shell"
    rm -rf "$NIX_SHELL_DIR"
    '' + helpers.postgres.setup + helpers.invidious.setup
      + builtins.concatStringsSep "\n" setupScripts + ''

    _videre_cleanup() {
    '' + helpers.postgres.clean
      + helpers.invidious.clean
      + builtins.concatStringsSep "\n" cleanupScripts
      + ''
      rm -rf "$NIX_SHELL_DIR"
    }
    trap _videre_cleanup EXIT
    '';
}
