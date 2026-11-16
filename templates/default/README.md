# nixcluster downstream flake

Generated from `nix flake init --template github:kitsunoff/nixcluster`.

## Layout

```text
flake.nix                      flake-parts + import-tree + nixcluster module
modules/
  nodes/                       one file per node -> nixcluster.<cluster>.members.<node>
  clusters/                    cluster-level options -> nixcluster.<cluster>
  clusterModules/              custom cluster modules -> flake.clusterModules.<name>
```

`import-tree` auto-imports every `.nix` file under `modules/`. Drop a node file
into `modules/nodes/`, a cluster file into `modules/clusters/`, and the
`nixcluster.<cluster>` option is merged across them, then transformed into
`clusterConfigurations.<cluster>` (with `nixosConfigurations.<cluster>-<member>`
and a per-cluster CLI app `cluster-<cluster>`).

## Cluster modules

Built-in modules (k3s, sops, incus, keepalived, nebula, disko, cozystack, pxe)
and any custom ones under `modules/clusterModules/` are offered via the
`clusterModules` argument and applied only with explicit `imports`:

```nix
nixcluster.example = { clusterModules, ... }: {
  imports = [ clusterModules.k3s clusterModules.sops ];
  k3s.enable = true;
};
```

> [!IMPORTANT]
> The installer needs **at least 3 GiB of RAM** on the target. nixos-anywhere
> boots a kexec image that unpacks into memory; with 2 GiB it fails with
> `kexec_file_load failed: Out of memory`. A smaller host can be installed by
> giving it more memory for the install only.

## CLI

```bash
nix run .#cluster-example -- --help
nix run .#cluster-example -- apply node1
```
