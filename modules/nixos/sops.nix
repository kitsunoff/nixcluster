# SOPS secrets configuration for cluster nodes
{ config, lib, nix8s, ... }:

let
  cluster = nix8s.cluster;
  clusterName = nix8s.clusterName;

  # SOPS configuration from cluster
  sopsCfg = cluster.sops or { };
  sopsEnabled = sopsCfg.enable or false;
  sopsFile = sopsCfg.secretsFile or null;

  # Age key path on the target system
  ageKeyPath = sopsCfg.ageKeyFile or "/etc/age/key.txt";

in
lib.mkIf sopsEnabled {
  # Configure sops-nix
  sops = {
    # Default sops file for this cluster
    defaultSopsFile = lib.mkIf (sopsFile != null) sopsFile;

    # Age key location on the target system
    age.keyFile = ageKeyPath;

    # Don't generate age key — we deploy it manually
    age.generateKey = false;

    # Secrets definitions
    secrets = {
      # k3s cluster token
      "k3s-token" = {
        key = "k3s/token";
        owner = "root";
        group = "root";
        mode = "0400";
      };

      # k3s agent token (optional, for separate agent authentication)
      "k3s-agent-token" = {
        key = "k3s/agentToken";
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };
  };
}
