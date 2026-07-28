# One node (member). `nixclusterctl <cluster> gen-config <ip>` emits files in
# exactly this shape, so discovered nodes can be dropped straight in here.
#
# CHANGE: install.ip (and install.disk if this node's disk differs from the base).
{ ... }:
{
  nixcluster.k3s-single.members.server-1 = {
    install.ip = "10.0.0.11";
    install.disk = "/dev/vda";

    k3s.role = "server";
  };
}
