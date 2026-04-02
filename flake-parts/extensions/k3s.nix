# k3s extension for nix8s
# Adds Kubernetes cluster capability to nodes
{ lib, config, ... }:

let
  cfg = config.nix8s;

  # Import CLI command builders
  mkBootstrap = import ../nix8sctl/_lib/bootstrap.nix;
  mkKubeconfig = import ../nix8sctl/_lib/kubeconfig.nix;

  # Helper to check if k3s is enabled for a cluster
  k3sEnabled = cluster: (cluster.k3s.enable or false);

  # Get server/agent lists from k3s config
  getServers = cluster: cluster.k3s.servers or [ ];
  getAgents = cluster: cluster.k3s.agents or [ ];

  # Determine role for a member in a cluster
  getMemberRole = cluster: memberName:
    if lib.elem memberName (getServers cluster) then "server"
    else if lib.elem memberName (getAgents cluster) then "agent"
    else null;

  # Check if this is the first server
  isFirstServer = cluster: memberName:
    let
      servers = getServers cluster;
      sortedServers = lib.sort (a: b: a < b) servers;
      firstServer = cluster.k3s.firstServer or (lib.head sortedServers);
    in
    memberName == firstServer;

  # Get first server IP for a cluster
  getFirstServerIp = cluster:
    let
      servers = getServers cluster;
      sortedServers = lib.sort (a: b: a < b) servers;
      firstServerName = cluster.k3s.firstServer or (lib.head sortedServers);
      member = cluster.members.${firstServerName} or { };
    in
    member.ip or null;

  # Build k3s NixOS module for a cluster member
  mkK3sModule = { cluster, clusterName, memberName, member }:
    let
      role = getMemberRole cluster memberName;
      isFirst = isFirstServer cluster memberName;
      firstServerIp = getFirstServerIp cluster;

      k3sConfig = cluster.k3s or { };
      secrets = cluster.secrets or { };
      sopsCfg = cluster.sops or { };
      sopsEnabled = sopsCfg.enable or false;
    in
    lib.mkIf (role != null) ({ config, pkgs, ... }: {
      services.k3s = {
        enable = true;
        package = k3sConfig.package or pkgs.k3s;
        role = role;

        # Token for cluster membership
        tokenFile = lib.mkIf sopsEnabled config.sops.secrets."k3s-token".path;
        token = lib.mkIf (!sopsEnabled && secrets.token or null != null) secrets.token;

        # Server URL (not needed for first server)
        serverAddr = lib.mkIf (!isFirst && firstServerIp != null)
          "https://${firstServerIp}:6443";

        # Extra flags
        extraFlags = lib.concatStringsSep " " (
          [ "--node-ip=${member.ip}" ]
          ++ (lib.optionals isFirst [ "--cluster-init" ])
          ++ (k3sConfig.extraArgs.${role} or [ ])
        );
      };

      # Firewall rules for k3s
      networking.firewall = {
        allowedTCPPorts = [
          6443  # Kubernetes API
          2379  # etcd client
          2380  # etcd peer
          10250 # kubelet metrics
        ];
        trustedInterfaces = [ "cni0" "flannel.1" ];
      };

      # Kubernetes requirements
      swapDevices = lib.mkForce [ ];

      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
        "net.bridge.bridge-nf-call-iptables" = 1;
        "net.bridge.bridge-nf-call-ip6tables" = 1;
      };

      boot.kernelModules = [ "br_netfilter" "overlay" ];

      # sops secrets for k3s token
      sops.secrets = lib.mkIf sopsEnabled {
        "k3s-token" = {
          key = "k3s/token";
          owner = "root";
          group = "root";
          mode = "0400";
        };
      };
    });

  # Generate nixosModulesFor entries for all k3s-enabled clusters
  k3sModules = lib.concatMapAttrs
    (clusterName: cluster:
      if k3sEnabled cluster then
        lib.mapAttrs'
          (memberName: member:
            lib.nameValuePair
              "${clusterName}-${memberName}"
              [ (mkK3sModule { inherit cluster clusterName memberName member; }) ]
          )
          cluster.members
      else { }
    )
    cfg.clusters;

  # k3s commands attrset
  k3sCommandsFor = clusterName: cluster: {
    bootstrap = {
      description = "Bootstrap k3s cluster";
      builder = { pkgs, lib, ... }:
        mkBootstrap { inherit pkgs lib cluster clusterName; };
    };

    kubeconfig = {
      description = "Manage kubeconfig";
      builder = { pkgs, lib, ... }:
        mkKubeconfig { inherit pkgs lib cluster clusterName; };
    };
  };

  # Generate extension commands for k3s-enabled clusters
  k3sExtCommands = lib.mapAttrs
    (clusterName: cluster:
      lib.optional (k3sEnabled cluster) (k3sCommandsFor clusterName cluster)
    )
    cfg.clusters;

in
{
  config.nix8s = {
    # Merge k3s modules into nixosModulesFor
    nixosModulesFor = k3sModules;

    # Register k3s CLI commands via internal extension commands
    _extensionCommands = k3sExtCommands;
  };
}
