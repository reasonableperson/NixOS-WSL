{ config
, lib
, ...
}:

let
  cfg = config.wsl.ssh-agent;
in
{
  imports = [
    (lib.mkRemovedOptionModule [ "wsl" "ssh-agent" "package" ]
      "The bridge now uses systemd socket activation and Windows PowerShell, without an external agent package.")
  ];
  options.wsl.ssh-agent = {
    enable = lib.mkEnableOption "ssh-agent passthrough to Windows";

    powershellPath = lib.mkOption {
      type = lib.types.str;
      default = "${config.wsl.wslConf.automount.root}/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe";
      defaultText = lib.literalExpression ''"''${config.wsl.wslConf.automount.root}/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"'';
      description = "Path to Windows PowerShell, used to connect to the Windows SSH agent named pipe.";
    };

    users = lib.mkOption {
      type = lib.types.either
        (lib.types.enum [
          "!@system"
          "@system"
        ])
        (lib.types.listOf lib.types.str);
      default = "!@system";
      description = ''
        Users to activate the service for. Defaults to all non-system users.
      '';
    };
  };

  config = lib.mkIf (config.wsl.enable && cfg.enable) {
    services.wsl2-ssh-agent = {
      enable = true;
      inherit (cfg) users powershellPath;
    };
  };
}
