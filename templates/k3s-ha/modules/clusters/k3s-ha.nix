# Cluster-level definition for the HA scenario: three k3s servers forming an
# embedded-etcd control plane, plus two agents.
#
# Nothing here says "three servers" — the roles live in the node files, and the
# k3s module derives the ordering contract from them. Add or remove a node file
# and the converge plan follows.
{ ... }:
{
  nixcluster.k3s-ha =
    { clusterModules, self, ... }:
    {
      imports = [ clusterModules.k3s ];

      k3s.enable = true;

      defaultNixosConfiguration = self.nixosConfigurations.base;
    };
}
