{ runCommand
, python3
, powershell
, ...
}:

runCommand "wsl-ssh-agent-test"
{
  nativeBuildInputs = [ python3 powershell ];
  RELAY = ../modules/ssh-agent.ps1;
} ''
  python3 ${../tests/ssh-agent.py}
  touch $out
''
