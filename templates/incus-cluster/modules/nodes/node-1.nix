# The bootstrap member: first by name, so it initialises the Incus cluster
# database and mints the join tokens for the others.
#
# `incus.enable = true` here is a per-member NixOS patch. It is redundant while
# `incus.cluster.enable` is on (that already applies Incus to every member) — it
# is spelled out on this one node to show the shape of a per-member patch.
#
# CHANGE: install.ip (and install.disk if this node's disk differs from the base).
{ ... }:
{
  nixcluster.incus-cluster.members.node-1 = {
    install.ip = "10.0.0.11";
    install.disk = "/dev/vda";

    incus.enable = true;
  };
}
