# Building your own system tarball

This requires access to a system that already has Nix installed. Please refer to the [Nix installation guide](https://nixos.org/guides/install-nix.html) if that\'s not the case.

## Sandboxed build (experimental)

With flakes enabled, build a tarball without `sudo`:

```sh
nixos-rebuild build-image --flake .#aarch64 --image-variant wsl -L
```

`-L` streams build logs, including staging, database initialization, and compression progress messages.
Use `default` instead of `aarch64` for x86_64, or your own configuration name.
The image is at `result/tarball/nixos.wsl` by default.
You can also build it directly:

```sh
nix build .#nixosConfigurations.aarch64.config.system.build.images.wsl
```

`system.build.tarball` is an alias for the WSL image.
The `wsl` image variant is registered by the NixOS-WSL module when `wsl.enable = true`.
`--image-variant wsl` selects that registered variant; it does not import NixOS-WSL or convert an unrelated configuration into a WSL system.
To customize its name or output path, extend the image variant in your configuration:

```nix
image.modules.wsl = {
  image.baseName = "my-nixos";
  image.filePath = "images/my-nixos.wsl";
};
```

The build runs in the Nix sandbox; the WSL shim activates the system on first boot.
This path is experimental and should be tested with a fresh WSL import before replacing an existing installation.

The image includes the Nix database, bootstrap users, WSL metadata, and the configuration selected by `wsl.tarball.configPath`.
The default user must have a fixed UID and primary GID (as in the supplied configurations).

Without flakes, build the same tarball with:

```sh
nix-build -A nixosConfigurations.default.config.system.build.tarball
```
