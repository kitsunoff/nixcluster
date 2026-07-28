{
  description = "nixcluster scenario: single-server k3s cluster";

  inputs = {
    nixcluster.url = "github:kitsunoff/nixcluster";

    # Reuse nixcluster's locked inputs for a single consistent set.
    nixpkgs.follows = "nixcluster/nixpkgs";
    flake-parts.follows = "nixcluster/flake-parts";
    import-tree.follows = "nixcluster/import-tree";
    disko.follows = "nixcluster/disko";
    sops-nix.follows = "nixcluster/sops-nix";
  };

  outputs =
    inputs@{ flake-parts, import-tree, nixcluster, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      imports = [
        # Declarative `nixcluster.<cluster>` option -> clusterConfigurations.
        nixcluster.flakeModules.default
        # Auto-import everything under ./modules (base, cluster, nodes).
        (import-tree ./modules)
      ];
    };
}
