{ system, inputs, lib, pkgs, runCommand, ... }:

let
  mkEnvironment = includePath: root: (inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      ../modules/interop.nix
      ({ lib, ... }: {
        options.wsl = {
          enable = lib.mkOption { default = true; };
          wslConf.automount.root = lib.mkOption { default = root; };
        };
        config.wsl.interop.includePath = includePath;
      })
    ];
  }).config.system.build.setEnvironment;

  check = name: includePath: root: incoming: suffix:
    let
      environment = mkEnvironment includePath root;
      fishEnvironment = runCommand "${name}-environment.fish"
        {
          nativeBuildInputs = [ pkgs.babelfish ];
        } ''
        babelfish < ${environment} > $out
      '';
      script = pkgs.writeText "${name}-check" ''
        source ${environment}
        ${pkgs.coreutils}/bin/printenv PATH
        if ${pkgs.coreutils}/bin/printenv INTEROP_PATH; then exit 1; fi
      '';
      fishScript = pkgs.writeText "${name}-check.fish" ''
        source ${fishEnvironment}
        ${pkgs.coreutils}/bin/printenv PATH
        if set -q INTEROP_PATH
          exit 1
        end
      '';
    in
    ''
      baseline=$(env -i HOME="$TMPDIR" USER="$USER" PATH=${lib.escapeShellArg incoming} \
        ${pkgs.bash}/bin/bash --noprofile --norc -c \
        'source ${mkEnvironment false root}; ${pkgs.coreutils}/bin/printenv PATH')
      expected="$baseline"${lib.escapeShellArg suffix}
      for shell in ${pkgs.bash}/bin/bash ${pkgs.zsh}/bin/zsh; do
        actual=$(env -i HOME="$TMPDIR" USER="$USER" PATH=${lib.escapeShellArg incoming} "$shell" ${script})
        test "$actual" = "$expected"
      done
      actual=$(env -i HOME="$TMPDIR" USER="$USER" PATH=${lib.escapeShellArg incoming} \
        ${pkgs.fish}/bin/fish --no-config ${fishScript})
      test "$actual" = "$expected"
    '';
in
runCommand "interop-shells" { } ''
  export USER=$(id -un)
  ${check "windows-paths" true "/mnt" "/usr/bin:/mnt/c/Windows:/mnt/c/Program Files/bin:/bin:/mnt/d/tools" ":/mnt/c/Windows:/mnt/c/Program Files/bin:/mnt/d/tools"}
  ${check "no-windows-paths" true "/mnt" "/usr/bin:/bin" ""}
  ${check "disabled" false "/mnt" "/usr/bin:/mnt/c/Windows" ""}
  ${check "custom-root" true "/windows.+" "/windowsX+/c/no:/windows.+/c/yes:/other/windows.+/c/no" ":/windows.+/c/yes"}
  touch $out
''
