{ system
, inputs
, runCommand
, python3
, closureInfo
, ...
}:
let
  configuration = inputs.self.nixosConfigurations.${system};
  image = (configuration.extendModules {
    modules = [{
      image.modules.wsl = { config, lib, ... }: {
        image.fileName = "test-wsl.wsl";
        users.users.${config.wsl.defaultUser} = {
          uid = lib.mkForce null;
          group = "bootstrap";
        };
        users.groups.bootstrap = { };
        users.users.reserved = {
          isNormalUser = true;
          uid = 1000;
          group = "reserved";
        };
        users.groups.reserved.gid = 400;
        users.users.bootstrap-system = {
          isSystemUser = true;
          group = "bootstrap";
        };
        users.users.disabled = {
          enable = false;
          isSystemUser = true;
          group = "bootstrap";
        };
      };
    }];
  }).config.system.build.images.wsl;
  inherit (image.passthru) config;
  closure = closureInfo { rootPaths = [ config.system.build.toplevel ]; };
in
assert image.passthru.filePath == "test-wsl.wsl";
runCommand "check-wsl-tarball" { nativeBuildInputs = [ python3 ]; } ''
  python3 <<'PY'
  import pathlib
  import sqlite3
  import tarfile

  required = {
      "etc/passwd", "etc/group", "etc/NIXOS", "etc/wsl.conf",
      "etc/wsl-distribution.conf", "etc/nixos.ico", "etc/os-release",
      "etc/nixos/configuration.nix", "root/.nix-channels",
      "root/.nix-defexpr/channels", "sbin/init", "bin/sh",
      "nix/var/nix/profiles/system", "nix/var/nix/profiles/system-1-link",
      "nix/var/nix/gcroots/system", "nix/var/nix/db/db.sqlite",
  }
  files = {}
  links = {}
  names = set()
  with tarfile.open("${image}/${image.passthru.filePath}", "r|gz") as archive:
      for member in archive:
          assert member.uid == 0 and member.gid == 0, member.name
          names.add(member.name)
          if member.name in required:
              if member.isfile():
                  files[member.name] = archive.extractfile(member).read()
              elif member.issym():
                  links[member.name] = member.linkname
          if member.name == "tmp":
              assert member.mode == 0o1777
          if member.name == "root":
              assert member.mode == 0o700

  assert required <= names, required - names
  assert "nix-path-registration" not in names
  assert links["nix/var/nix/profiles/system"] == "system-1-link"
  assert links["nix/var/nix/profiles/system-1-link"] == "${config.system.build.toplevel}"
  for name in ("sbin/init", "bin/sh"):
      assert links[name].lstrip("/") in names, links[name]
  assert b"systemd=true" in files["etc/wsl.conf"]
  assert b"shortcut" in files["etc/wsl-distribution.conf"]
  assert b"<nixos-wsl/modules>" in files["etc/nixos/configuration.nix"]
  assert b"nixos-wsl" in files["root/.nix-channels"]
  users = {line.split(":")[0]: line.split(":") for line in files["etc/passwd"].decode().splitlines()}
  assert users["root"][2:4] == ["0", "0"]
  groups = {line.split(":")[0]: line.split(":") for line in files["etc/group"].decode().splitlines()}
  default_user = users["${config.users.users.${config.wsl.defaultUser}.name}"]
  assert 1000 < int(default_user[2]) < 30000
  assert default_user[3] == groups["bootstrap"][2]
  assert 400 < int(groups["bootstrap"][2]) < 1000
  assert users["reserved"][2:4] == ["1000", "400"]
  assert 400 <= int(users["bootstrap-system"][2]) < 1000
  assert users["bootstrap-system"][3] == groups["bootstrap"][2]
  assert "disabled" not in users
  assert len({user[2] for user in users.values()}) == len(users)
  assert len({group[2] for group in groups.values()}) == len(groups)

  pathlib.Path("db.sqlite").write_bytes(files["nix/var/nix/db/db.sqlite"])
  with sqlite3.connect("db.sqlite") as db:
      registered = {row[0] for row in db.execute("SELECT path FROM ValidPaths")}
  expected = set(pathlib.Path("${closure}/store-paths").read_text().splitlines())
  assert registered == expected, (registered - expected, expected - registered)
  for path in registered:
      assert path.lstrip("/") in names, path
  PY
  touch $out
''
