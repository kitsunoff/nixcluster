# NixOS module for k3s configuration
# Receives cluster context via nix8s module args
{ config, lib, pkgs, nix8s, ... }:

let
  cfg = config.k3s;
  cluster = nix8s.cluster;
  memberName = nix8s.memberName;

  # Get all servers from cluster members
  allMembers = cluster.members;
  servers = lib.filterAttrs (n: m: m.k3s.role or null == "server") allMembers;
  serverNames = lib.attrNames servers;

  # First server for cluster-init
  sortedServers = lib.sort (a: b: a < b) serverNames;
  firstServer = if sortedServers != [] then lib.head sortedServers else null;
  isFirst = memberName == firstServer;

  # Get first server IP for joining
  firstServerIp = if firstServer != null
    then allMembers.${firstServer}.install.ip or "127.0.0.1"
    else "127.0.0.1";

  # Member IP
  memberIp = allMembers.${memberName}.install.ip or "127.0.0.1";

  # Build flags
  baseFlags = [ "--node-ip=${memberIp}" ];

  serverFlags = baseFlags
    ++ (lib.optionals isFirst [ "--cluster-init" ])
    ++ cfg.extraServerFlags;

  agentFlags = baseFlags ++ cfg.extraAgentFlags;

in
{
  options.k3s = {
    role = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "server" "agent" ]);
      default = null;
      description = "k3s role for this node (server or agent)";
    };

    extraServerFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra flags for k3s server";
    };

    extraAgentFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra flags for k3s agent";
    };
  };

  config = lib.mkIf (cfg.role != null) {
    services.k3s = {
      enable = true;
      role = cfg.role;

      serverAddr = lib.mkIf (!isFirst && cfg.role == "agent" || !isFirst && cfg.role == "server")
        "https://${firstServerIp}:6443";

      extraFlags = lib.mkDefault (lib.concatStringsSep " " (
        if cfg.role == "server" then serverFlags else agentFlags
      ));
    };

    networking.firewall = {
      allowedTCPPorts = [ 6443 2379 2380 10250 ];
      trustedInterfaces = [ "cni0" "flannel.1" ];
    };

    swapDevices = lib.mkForce [];

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
    };

    boot.kernelModules = [ "br_netfilter" "overlay" ];
  };
}
