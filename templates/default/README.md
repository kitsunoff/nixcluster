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

## CLI

```bash
nix run .#cluster-example -- --help
nix run .#cluster-example -- apply node1
```
