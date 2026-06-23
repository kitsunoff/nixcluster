# nixcluster library
{ lib, inputs }:

{
  mkCluster = import ./mkCluster.nix { inherit lib inputs; };
  mkClusterCli = import ./mkClusterCli.nix { inherit lib; };
  mkFlakeOutputs = import ./mkFlakeOutputs.nix { inherit lib inputs; };
}
