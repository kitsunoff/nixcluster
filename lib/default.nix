# nixcluster library
{ lib, inputs }:

rec {
  mkCluster = import ./mkCluster.nix { inherit lib inputs; };
  mkClusterCli = import ./mkClusterCli.nix { inherit lib; };
  mkClusterOutputs = import ./clusterOutputs.nix { inherit lib; };
  mkFlakeOutputs = import ./mkFlakeOutputs.nix { inherit lib inputs; };

  # Core cluster module path.
  coreModule = ../cluster-modules/core.nix;

  # Built-in cluster modules. Exposed as the top-level `clusterModules` output
  # and offered to cluster definitions; applied only via explicit `imports`.
  builtinClusterModules = {
    core = ../cluster-modules/core.nix;
    disko = ../cluster-modules/disko.nix;
    k3s = ../cluster-modules/k3s.nix;
    sops = ../cluster-modules/sops.nix;
    cozystack = ../cluster-modules/cozystack.nix;
    pxe = ../cluster-modules/pxe.nix;
    incus = ../cluster-modules/incus.nix;
    nebula = ../cluster-modules/nebula.nix;
    keepalived = ../cluster-modules/keepalived.nix;
  };

  # flake-parts module providing the declarative `nixcluster` option.
  flakeModule = import ./flakeModule.nix {
    inherit lib mkClusterOutputs coreModule builtinClusterModules;
  };
}
