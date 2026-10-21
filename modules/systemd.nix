{ config, lib, utils, pkgs, modulesPath, ... }:

with lib;

let
  cfg = config.wsl;

  bashWrapper = pkgs.writeShellScriptBin "sh" ''
    export PATH="$PATH:${lib.makeBinPath [ pkgs.systemd pkgs.gnugrep ]}"
    exec ${pkgs.bashInteractive}/bin/sh "$@"
  '';

  wrapShell = shellPath:
    pkgs.stdenvNoCC.mkDerivation {
      name = "wrapped-${last (splitString "/" (shellPath))}";
      buildCommand = ''
        mkdir -p $out
        cp ${config.system.build.nativeUtils}/bin/shell-wrapper $out/wrapper
        ln -s ${shellPath} $out/shell
      '';
    };

  users-groups-module = import "${modulesPath}/config/users-groups.nix" {
    inherit lib utils pkgs;
    config = recursiveUpdate config {
      users.users = mapAttrs
        (n: v: v // {
          shell = (wrapShell (utils.toShellPath v.shell)).outPath + "/wrapper";
        })
        config.users.users;
    };
  };
in
{
  imports = [
    (lib.mkRemovedOptionModule [ "wsl" "nativeSystemd" ] "Native systemd is now always enabled as support for syschdemd has been removed")
  ];

  options.wsl.wrapBinSh = mkOption {
    type = types.bool;
    default = true;
    description = ''
      Wrap /bin/sh with a script that sets the correct environment variables (like the user shells). Only takes effect when using native systemd
    '';
  };

  config = mkIf cfg.enable {
    # useful for usbip but adds a dependency on various firmwares which are combined over 300 MB big
    services.udev.enable = lib.mkDefault false;

    systemd = {
      # systemd-oomd requires cgroup pressure info (PSI). Older WSL2 kernels
      # lacked CONFIG_PSI, but modern kernels (6.1+) support it.
      oomd.enable = lib.mkDefault false;
      # Disable systemd units that don't make sense on WSL
      services.firewall.enable = false;

      # Don't allow emergency mode, because we don't have a console.
      enableEmergencyMode = false;
    };

    system.build.nativeUtils = pkgs.callPackage ../utils { };

    wsl = {
      binShPkg = bashWrapper;
      binShExe = mkIf config.wsl.wrapBinSh ((wrapShell "${config.wsl.binShPkg}/bin/sh").outPath + "/wrapper");
      wslConf = {
        user.default = config.users.users.${cfg.defaultUser}.name;
        boot.systemd = true;
      };
      extraBin = [
        { src = "${pkgs.shadow}/bin/login"; }
      ];
    };

    system.activationScripts = {
      users = users-groups-module.config.system.activationScripts.users;
      createBootedSystemSymlink = stringAfter [ "specialfs" "users" "groups" ] ''
        echo "setting up /run/booted-system..."
        [[ -e /run/booted-system ]] || ln -sfn "$(readlink -f "$systemConfig")" /run/booted-system
      '';
      createSbin = stringAfter (optional cfg.populateBin "populateBin") (
        if cfg.populateBin
        then ''
          echo "setting up /sbin..."
          if [ ! -L /sbin ]; then
            rm -rf /sbin
            ln -s /bin /sbin
          fi
        ''
        else ''
          echo "setting up /sbin..."
          if [ ! -d /sbin ] || [ -L /sbin ]; then
            rm -rf /sbin
            mkdir -p /sbin
          fi
        ''
      );
      shimSystemd = stringAfter [ "createSbin" ] ''
        echo "setting up /sbin/init shim..."
        ln -sf ${config.system.build.nativeUtils}/bin/systemd-shim /sbin/init
      '';
    };

    environment = {
      # preserve $PATH from parent
      variables.PATH = [ "$PATH" ];
      extraInit = ''
        eval $(${config.system.build.nativeUtils}/bin/split-path --automount-root="${cfg.wslConf.automount.root}" ${lib.optionalString cfg.interop.includePath "--include-interop"})
      '';
    };
  };
}
