# Cluster-level definition. `nixcluster.<name>` is a cluster module: it imports
# the cluster modules it wants and sets their options. Rename `k3s-single` to
# your own cluster name — the CLI app becomes `cluster-<name>` and the per-member
# NixOS configurations become `<name>-<member>`.
{ ... }:
{
  nixcluster.k3s-single =
    { clusterModules, self, ... }:
    {
      imports = [ clusterModules.k3s ];

      k3s.enable = true;

      # Members that do not carry their own `nixosConfiguration` inherit this.
      defaultNixosConfiguration = self.nixosConfigurations.base;
    };
}
