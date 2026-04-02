# flake-parts module wrapper for nix8s
#
# Usage:
#   imports = [ nix8s.flakeModules.default ];
#   nix8s.clusters.prod = { ... };
#
# Automatically generates clusterConfigurations and outputs
{ lib, config, self, inputs, ... }:

let
  cfg = config.nix8s;

  # Import the standalone lib
  nix8sLib = import ./default.nix { inherit lib inputs; };

  # Evaluate each cluster
  evaluatedClusters = lib.mapAttrs (name: clusterCfg:
    nix8sLib.mkCluster (clusterCfg // { name = name; })
  ) cfg.clusters;

  # Generate outputs
  outputs = nix8sLib.mkFlakeOutputs {
    clusterConfigurations = evaluatedClusters;
  };

in
{
  options.nix8s = {
    clusters = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        freeformType = lib.types.attrsOf lib.types.anything;
      });
      default = {};
      description = "Cluster configurations";
    };
  };

  config = lib.mkIf (cfg.clusters != {}) {
    flake = {
      inherit (outputs) nixosConfigurations;
      clusterConfigurations = evaluatedClusters;
    };

    perSystem = { system, ... }: {
      apps = outputs.apps.${system} or {};
    };
  };
}
