{ lib, pkgs, config, ... }:

with builtins; with lib;
{
  options.wsl.interop = with types; {
    register = mkOption {
      type = bool;
      default = false; # Use the existing registration by default
      description = "Explicitly register the binfmt_misc handler for Windows executables";
    };

    includePath = mkOption {
      type = bool;
      default = true;
      description = "Include Windows PATH in WSL PATH";
    };
  };

  config =
    let
      cfg = config.wsl.interop;
      appendInteropPath = pkgs.writeShellScript "append-interop-path" ''
        interopPath=$(printf '%s' "$2" \
          | ${pkgs.coreutils}/bin/tr ':' '\n' \
          | ${pkgs.gnugrep}/bin/grep -E ${escapeShellArg "^${escapeRegex config.wsl.wslConf.automount.root}/"} \
          | ${pkgs.coreutils}/bin/paste -sd: -)
        printf '%s' "$1''${interopPath:+:$interopPath}"
      '';
    in
    mkIf config.wsl.enable {

      boot.binfmt.registrations = mkIf cfg.register {
        WSLInterop = {
          magicOrExtension = "MZ";
          fixBinary = true;
          wrapInterpreterInShell = false;
          interpreter = "/init";
          preserveArgvZero = true;
        };
      };

      environment = mkIf cfg.includePath {
        # Capture PATH before NixOS replaces it. Keep shell code out of variables,
        # which are also consumed by non-POSIX shells such as fish.
        variables.INTEROP_PATH = "$PATH";

        # Append only paths under the automount root, not WSL's Linux defaults.
        extraInit = ''
          export PATH="$(${appendInteropPath} "$PATH" "$INTEROP_PATH")"
          unset INTEROP_PATH
        '';
      };

      warnings =
        let
          registrations = config.boot.binfmt.registrations;
        in
        optional (!(registrations ? WSLInterop) && (length (attrNames config.boot.binfmt.registrations)) != 0) "Having any binfmt registrations without re-registering WSLInterop (wsl.interop.register) will break running .exe files from WSL2";
    };


}
