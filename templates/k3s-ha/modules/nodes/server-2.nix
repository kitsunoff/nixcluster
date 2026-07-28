# k3s server 2 of 3 — the three servers form the embedded-etcd control plane.
#
# The first server by name bootstraps the cluster; the other two join it. That
# ordering is derived by the k3s module, not written here.
#
# CHANGE: install.ip (and install.disk if this node's disk differs from the base).
{ ... }:
{
  nixcluster.k3s-ha.members.server-2 = {
    install.ip = "10.0.0.12";
    install.disk = "/dev/vda";

    k3s.role = "server";
  };
}
