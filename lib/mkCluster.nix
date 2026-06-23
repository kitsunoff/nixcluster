# mkCluster - Evaluate a cluster configuration (standalone API)
#
# Usage:
#   nixcluster.lib.mkCluster {
#     imports = [ nixcluster.clusterModules.k3s ];
#     name = "prod";
#     members.node1 = {
#       nixosConfiguration = self.nixosConfigurations.base;
#       install.ip = "10.0.0.1";
#       networking.hostName = "prod-node1";  # NixOS patch
#     };
#   }
#
# The flake-parts module (lib/flakeModule.nix) is the declarative front-end for
# the same pipeline; both evaluate the cluster module and then derive outputs via
# lib/clusterOutputs.nix.
{ lib, inputs }:

let
  # Core cluster module
  coreModule = ../cluster-modules/core.nix;

  mkClusterOutputs = import ./clusterOutputs.nix { inherit lib; };
in

clusterConfig:

let
  # Evaluate the cluster using the module system.
  evaluated = lib.evalModules {
    modules = [
      coreModule
      clusterConfig
      # Thread flake inputs into the cluster config (consumed by e.g. pxe).
      { _inputs = inputs; }
    ];
  };

  cfg = evaluated.config;
in
{
  inherit (evaluated) config options;
} // (mkClusterOutputs cfg)
