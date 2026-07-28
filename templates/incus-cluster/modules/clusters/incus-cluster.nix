# Cluster-level definition for a 3-member Incus cluster.
#
# Clustering is a CLUSTER-level toggle, deliberately not a per-member one: every
# member receives the Incus + clustering configuration off `incus.cluster.enable`.
# That is what lets members supplied as pure data (an operator that only knows a
# node's address — see `nodes/node-3.nix`) still become real cluster members.
{ ... }:
{
  nixcluster.incus-cluster =
    { clusterModules, self, ... }:
    {
      imports = [ clusterModules.incus ];

      incus.enable = true;
      incus.cluster = {
        enable = true;
        # "dir" needs no spare block device; use "zfs"/"btrfs"/"lvm" in production.
        storageBackend = "dir";
        # Unset: the first member by name bootstraps. Set it explicitly to pin
        # which node holds the initial database.
        # bootstrapMember = "node-1";
      };

      defaultNixosConfiguration = self.nixosConfigurations.base;
    };
}
