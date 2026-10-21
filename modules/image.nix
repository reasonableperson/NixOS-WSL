{ config, pkgs, lib, utils, modulesPath, ... }:
with builtins; with lib;
let
  cfg = config.wsl.tarball;

  icon = ../assets/NixOS-WSL.ico;
  iconPath = "/etc/nixos.ico";

  wsl-distribution-conf = pkgs.writeText "wsl-distribution.conf" (
    generators.toINI { } {
      oobe.defaultName = "NixOS";
      shortcut.icon = iconPath;
    }
  );

  nixosWslBranch =
    let
      # Use the nix parser conveniently built into nix
      flake = import ../flake.nix;
      url = flake.inputs.nixpkgs.url;
      version = lib.removePrefix "github:NixOS/nixpkgs/nixos-" url;
    in
    if version == "unstable"
    then "main"
    else "release-" + version;

  defaultConfig = pkgs.writeText "default-configuration.nix" ''
    # Edit this configuration file to define what should be installed on
    # your system. Help is available in the configuration.nix(5) man page, on
    # https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

    # NixOS-WSL specific options are documented on the NixOS-WSL repository:
    # https://github.com/nix-community/NixOS-WSL

    { config, lib, pkgs, ... }:

    {
      imports = [
        # include NixOS-WSL modules
        <nixos-wsl/modules>
      ];

      wsl.enable = true;
      wsl.defaultUser = "${config.wsl.defaultUser}";

      # This value determines the NixOS release from which the default
      # settings for stateful data, like file locations and database versions
      # on your system were taken. It's perfectly fine and recommended to leave
      # this value at the release version of the first install of this system.
      # Before changing this value read the documentation for this option
      # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
      system.stateVersion = "${config.system.nixos.release}"; # Did you read the comment?
    }
  '';
in
{
  imports = [ (modulesPath + "/image/file-options.nix") ];

  wsl.enable = true;

  image.fileName = mkDefault "nixos.${pkgs.stdenv.hostPlatform.parsed.cpu.name}.wsl";
  system.build.image =
    (pkgs.callPackage (modulesPath + "/../lib/make-system-tarball.nix") {
      compressionExtension = ".gz";
      compressCommand = pkgs.writeShellScript "compress-wsl-tarball" ''
        echo "[NixOS-WSL] Compressing filesystem archive..." >&2
        exec pigz -n
      '';
      extraInputs = [ pkgs.pigz ];

      storeContents = [{
        object = config.system.build.toplevel;
        symlink = "/nix/var/nix/profiles/system-1-link";
      }];

      contents = [
        { source = wsl-distribution-conf; target = "/etc/wsl-distribution.conf"; }
        { source = icon; target = iconPath; }
        { source = config.environment.etc."wsl.conf".source; target = "/etc/wsl.conf"; }
        { source = config.system.build.toplevel + "/etc/os-release"; target = "/etc/os-release"; }
      ];

      extraCommands = pkgs.writeShellScript "prepare-wsl-tarball" ''
        set -e
        echo "[NixOS-WSL] Preparing bootstrap files and users..."
        mkdir -p bin sbin dev proc sys run tmp root etc/nixos nix/var/nix/gcroots
        chmod 1777 tmp
        chmod 0700 root
        ln -s ${config.system.build.nativeUtils}/bin/systemd-shim sbin/init
        ln -s ${config.wsl.binShExe} bin/sh
        ${concatMapStrings (entry:
          optionalString (config.wsl.populateBin && entry.name != "sh") (
            if entry.copy
            then "cp ${escapeShellArg entry.src} ${escapeShellArg "bin/${entry.name}"}\n"
            else "ln -s ${escapeShellArg entry.src} ${escapeShellArg "bin/${entry.name}"}\n"
          )
        ) config.wsl.extraBin}
        ln -s system-1-link nix/var/nix/profiles/system
        ln -s /nix/var/nix/profiles/system nix/var/nix/gcroots/system

        # WSL resolves users before the shim runs activation. Allocate IDs now;
        # activation preserves them and applies passwords and wrapped shells.
        bootstrapUsers="$(mktemp -d)"
        ${pkgs.buildPackages.userborn}/bin/userborn ${pkgs.writeText "bootstrap-users.json" (toJSON {
          users = mapAttrsToList (_: user: {
            inherit (user) name uid group description home;
            isNormal = user.isNormalUser;
            shell = utils.toShellPath user.shell;
          }) (filterAttrs (_: user: user.enable) config.users.users);
          groups = mapAttrsToList (_: group: {
            inherit (group) name gid members;
          }) config.users.groups;
        })} "$bootstrapUsers"
        mv "$bootstrapUsers/passwd" etc/passwd
        mv "$bootstrapUsers/group" etc/group
        rm -r "$bootstrapUsers"
        chmod 0644 etc/passwd etc/group

        # The WSL shim bypasses stage 2, which normally loads nix-path-registration.
        echo "[NixOS-WSL] Initializing the Nix database..."
        NIX_STATE_DIR="$PWD/nix/var/nix" ${config.nix.package}/bin/nix-store --load-db < nix-path-registration
        rm nix-path-registration

        ${optionalString config.nix.channel.enable ''
          mkdir -p root/.nix-defexpr
          ln -s /nix/var/nix/profiles/per-user/root/channels root/.nix-defexpr/channels
          printf '%s\n' \
            '${config.system.defaultChannel} nixos' \
            'https://github.com/nix-community/NixOS-WSL/archive/refs/heads/${nixosWslBranch}.tar.gz nixos-wsl' \
            > root/.nix-channels
        ''}

        ${if cfg.configPath == null then ''
          cp ${defaultConfig} etc/nixos/configuration.nix
        '' else ''
          cp -R ${lib.cleanSource cfg.configPath}/. etc/nixos
        ''}
        chmod -R u+w etc/nixos
      '';
    }).overrideAttrs (old: {
      buildCommandPath = pkgs.writeText "build-wsl-image.sh" ''
        echo "[NixOS-WSL] Staging filesystem and system closure ($(wc -l < "$closureInfo/store-paths") store paths)..."
        source ${old.buildCommandPath}
        targetFile="$out/"${escapeShellArg config.image.fileName}
        mv "$out/tarball/"${escapeShellArg "${old.fileName}.tar.gz"} "$targetFile"
        echo "file system-tarball $targetFile" > "$out/nix-support/hydra-build-products"
        echo "[NixOS-WSL] Image ready: $(du -h "$targetFile")"
      '';
    });
}
