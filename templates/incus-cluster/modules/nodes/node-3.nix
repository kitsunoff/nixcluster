# A DATA-ONLY member: nothing but an address. No `incus.enable` patch, no base
# configuration of its own — it inherits `defaultNixosConfiguration` and receives
# Incus + clustering from the cluster-level toggle.
#
# This is exactly the shape an operator generates when all it knows about a node
# is where to reach it, and it is what proves clustering does not depend on a
# per-member patch somebody has to remember to write.
#
# CHANGE: install.ip.
{ ... }:
{
  nixcluster.incus-cluster.members.node-3 = {
    install.ip = "10.0.0.13";
  };
}
