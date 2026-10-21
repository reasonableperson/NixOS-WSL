# Building your own system tarball

This requires access to a system that already has Nix installed. Please refer to the [Nix installation guide](https://nixos.org/guides/install-nix.html) if that\'s not the case.

## Sandboxed build (experimental)

With flakes enabled, build a tarball without `sudo`:

```sh
nixos-rebuild build-image --flake .#aarch64-linux --image-variant wsl -L
```

`-L` streams build logs, including staging, database initialization, and compression progress messages.
Use `x86_64-linux` instead of `aarch64-linux` for x86_64, or your own configuration name.
The image is at `result/nixos.aarch64.wsl` (or `result/nixos.x86_64.wsl` for x86_64) by default.
You can also build it directly:

```sh
nix build .#nixosConfigurations.aarch64-linux.config.system.build.images.wsl
```

Importing the flake's exported NixOS-WSL module registers the `wsl` image variant.
Selecting it enables WSL in the image configuration, without enabling it in the original system configuration.
`--image-variant wsl` does not import NixOS-WSL automatically; the target configuration must already import the module.
To customize its filename, extend the image variant in your configuration:

```nix
image.modules.wsl.image.fileName = "my-nixos.wsl";
```

This produces `result/my-nixos.wsl`.

The build runs in the Nix sandbox; the WSL shim activates the system on first boot.
This path is experimental and should be tested with a fresh WSL import before replacing an existing installation.

The image includes the Nix database, bootstrap users, WSL metadata, and the configuration selected by `wsl.tarball.configPath`.
The default user must have a fixed UID and primary GID (as in the supplied configurations).

Without flakes, build the same tarball with:

```sh
nix-build -A nixosConfigurations.x86_64-linux.config.system.build.images.wsl
```
