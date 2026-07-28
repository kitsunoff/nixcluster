# k3s agent 1 of 2 — a worker. It joins once every server is up, which the
# k3s module expresses as a dependency on all three server steps.
#
# CHANGE: install.ip (and install.disk if this node's disk differs from the base).
{ ... }:
{
  nixcluster.k3s-ha.members.agent-1 = {
    install.ip = "10.0.0.21";
    install.disk = "/dev/vda";

    k3s.role = "agent";
  };
}
