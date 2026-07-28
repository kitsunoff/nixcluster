# Cluster-level definition: imports cluster modules and sets cluster options.
# The value of `nixcluster.<cluster>` is a cluster module; written as a function
# it receives `clusterModules` (built-in + custom), `self`, and `inputs`.
{ ... }:
{
  nixcluster.example = { clusterModules, ... }: {
    imports = [
      clusterModules.k3s
      # clusterModules.sops
      # clusterModules.incus
      # ./modules/clusterModules/my-custom.nix is imported explicitly here too
    ];

    k3s.enable = true;
  };
}
