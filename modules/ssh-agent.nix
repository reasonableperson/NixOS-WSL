{ config
, lib
, pkgs
, ...
}:

let
  cfg = config.wsl.ssh-agent;
  encodedRelay = pkgs.runCommand "wsl-ssh-agent-encoded"
    {
      nativeBuildInputs = [ pkgs.coreutils pkgs.glibc.bin ];
    } ''
    iconv -f UTF-8 -t UTF-16LE ${./ssh-agent.ps1} | base64 -w0 > $out
  '';
  relay = pkgs.writeShellScript "wsl-ssh-agent" ''
    exec ${lib.escapeShellArg cfg.powershellPath} -NoLogo -NoProfile -NonInteractive \
      -EncodedCommand "$( ${pkgs.coreutils}/bin/cat ${encodedRelay} )"
  '';
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
    assertions = [
      {
        assertion = builtins.isList cfg.users -> lib.all (u: lib.hasAttr u config.users.users) cfg.users;
        message = ''
          wsl.ssh-agent.users contains users that do not exist in users.users:
          ${lib.concatStringsSep ", " (lib.filter (u: !lib.hasAttr u config.users.users) cfg.users)}
        '';
      }
    ];

    systemd.user.sockets.wsl2-ssh-agent = {
      description = "Windows SSH agent socket";
      wantedBy = [ "sockets.target" ];
      unitConfig.ConditionUser = lib.join "|" (lib.toList cfg.users);
      socketConfig = {
        ListenStream = "%t/wsl2-ssh-agent.sock";
        SocketMode = "0600";
        Accept = true;
        RemoveOnStop = true;
      };
    };

    systemd.user.services."wsl2-ssh-agent@" = {
      description = "Windows SSH agent connection";
      serviceConfig = {
        ExecStart = relay;
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
      };
    };

    environment.variables.SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/wsl2-ssh-agent.sock";
  };
}
