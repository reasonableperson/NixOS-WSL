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
  options.wsl.tarball = {
    configPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to system configuration which is copied into the tarball";
    };
  };

  # These options make no sense without the wsl-distro module anyway
  config = mkIf config.wsl.enable {
    system.build.tarball = mkDefault config.system.build.images.wsl;

    image.modules.wsl = { config, ... }: {
      imports = [ (modulesPath + "/image/file-options.nix") ];

      image = {
        baseName = mkDefault "nixos";
        extension = mkDefault "wsl";
        filePath = mkDefault "tarball/${config.image.fileName}";
      };
      system.build.image = config.system.build.tarball;
      system.build.tarball =
        assert lib.assertMsg
          (config.users.users.${config.wsl.defaultUser}.uid != null
            && config.users.groups.${config.users.users.${config.wsl.defaultUser}.group}.gid != null)
          "The sandboxed WSL tarball requires a fixed UID and primary GID for wsl.defaultUser";
        (pkgs.callPackage (modulesPath + "/../lib/make-system-tarball.nix") {
          fileName = config.image.baseName;
          compressionExtension = ".gz";
          compressCommand = "pigz -n";
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
            mkdir -p bin sbin dev proc sys run tmp root etc/nixos nix/var/nix/gcroots
            chmod 1777 tmp
            chmod 0700 root
            touch etc/NIXOS
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

            # WSL resolves users before the shim runs activation. Seed fixed-ID users;
            # activation creates the remaining users and applies passwords and shells.
            cp ${pkgs.writeText "bootstrap-passwd" (concatMapStrings (user:
              optionalString (user.uid != null && config.users.groups.${user.group}.gid != null)
                "${user.name}:x:${toString user.uid}:${toString config.users.groups.${user.group}.gid}:${user.description}:${user.home}:${utils.toShellPath user.shell}\n"
            ) (attrValues config.users.users))} etc/passwd
            cp ${pkgs.writeText "bootstrap-group" (concatMapStrings (group:
              optionalString (group.gid != null)
                "${group.name}:x:${toString group.gid}:${concatStringsSep "," group.members}\n"
            ) (attrValues config.users.groups))} etc/group
            chmod 0644 etc/passwd etc/group

            # The WSL shim bypasses stage 2, which normally loads nix-path-registration.
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
            source ${old.buildCommandPath}
            sourceFile="$out/tarball/"${escapeShellArg "${config.image.baseName}.tar.gz"}
            targetFile="$out/"${escapeShellArg config.image.filePath}
            mkdir -p "$(dirname "$targetFile")"
            if [ "$sourceFile" != "$targetFile" ]; then
              mv "$sourceFile" "$targetFile"
            fi
            echo "file system-tarball $targetFile" > "$out/nix-support/hydra-build-products"
          '';
        });
    };

    system.build.tarballBuilder = pkgs.writeShellApplication {
      name = "nixos-wsl-tarball-builder";

      runtimeInputs = [
        pkgs.coreutils
        pkgs.e2fsprogs
        pkgs.gnutar
        pkgs.nixos-install-tools
        pkgs.pigz
        config.nix.package
      ];

      text = ''
        usage() {
          echo "Usage: $0 [--extra-files PATH] [--chown PATH UID:GID] [output.tar.gz]"
          exit 1
        }

        if ! [ $EUID -eq 0 ]; then
          echo "This script must be run as root!"
          exit 1
        fi

        # Use .wsl extension to support double-click installs on recent versions of Windows
        out="nixos.wsl"
        extra_files=""

        declare -A chowns=()
        positionals=()

        while [ $# -gt 0 ]; do
          case "$1" in
            --extra-files)
              shift
              extra_files="$1"
              ;;
            --chown)
              shift
              path="$1"
              shift
              perms="$1"
              chowns["$path"]="$perms"
              ;;
            -*)
              echo "Unknown option: $1"
              usage
              ;;
            *)
              positionals+=("$1")
              ;;
          esac
          shift
        done

        if [ ''${#positionals[@]} -gt 1 ]; then
          echo "Too many positional arguments: ''${positionals[*]}"
          usage
        fi

        if [ ''${#positionals[@]} -gt 0 ]; then
          out="''${positionals[0]}"
        fi

        root=$(mktemp -p "''${TMPDIR:-/tmp}" -d nixos-wsl-tarball.XXXXXXXXXX)
        # FIXME: fails in CI for some reason, but we don't really care because it's CI
        trap 'chattr -Rf -i "$root" || true && rm -rf "$root" || true' INT TERM EXIT

        if [ -n "$extra_files" ]; then
          if ! [ -d "$extra_files" ]; then
            echo "The path passed to --extra-files must be a directory"
            exit 1
          fi

          echo "[NixOS-WSL] Copying extra files to $root..."
          cp --verbose --archive --no-preserve=ownership --no-target-directory "$extra_files" "$root"
        fi

        chmod o+rx "$root"

        for path in "''${!chowns[@]}"; do
          echo "[NixOS-WSL] Setting ownership for $path to ''${chowns[$path]}"
          chown -R "''${chowns[$path]}" "$root/$path"
        done

        echo "[NixOS-WSL] Installing..."
        nixos-install \
          --root "$root" \
          --no-root-passwd \
          --system ${config.system.build.toplevel} \
          --substituters ""

        ${lib.optionalString config.nix.channel.enable ''
          echo "[NixOS-WSL] Adding channel..."
          nixos-enter --root "$root" --command 'HOME=/root nix-channel --add https://github.com/nix-community/NixOS-WSL/archive/refs/heads/${nixosWslBranch}.tar.gz nixos-wsl'
        ''}

        echo "[NixOS-WSL] Adding wsl-distribution.conf"
        install -Dm644 ${wsl-distribution-conf} "$root/etc/wsl-distribution.conf"
        install -Dm644 ${icon} "$root${iconPath}"

        echo "[NixOS-WSL] Adding default config..."
        ${if cfg.configPath == null then ''
          install -Dm644 ${defaultConfig} "$root/etc/nixos/configuration.nix"
        '' else ''
          mkdir -p "$root/etc/nixos"
          cp -R ${lib.cleanSource cfg.configPath}/. "$root/etc/nixos"
          chmod -R u+w "$root/etc/nixos"
        ''}

        echo "[NixOS-WSL] Compressing..."
        tar -C "$root" \
          -c \
          --sort=name \
          --mtime='@1' \
          --numeric-owner \
          --hard-dereference \
          . \
        | pigz > "$out"
      '';
    };
  };
}
