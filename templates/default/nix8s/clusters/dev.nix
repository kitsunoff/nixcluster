# Dev cluster configuration
{ ... }:

{
  nix8s.clusters.dev = {
    # k3s configuration
    k3s = {
      enable = true;
      servers = [ "server" ];
      agents = [ "agent" ];
      # Optional: override k3s package
      # package = pkgs.k3s_1_30;
    };

    # SOPS-encrypted secrets
    # Generate with: nix run .#gen-secrets -- dev
    sops = {
      enable = true;
      secretsFile = ../secrets/dev.yaml;
      # Age key must be deployed to /etc/age/key.txt on nodes
      # Use nixos-anywhere --extra-files or manual deployment
    };

    # SSH public key for node access (read from encrypted secrets at build time)
    # This is safe because it's a public key
    secrets.sshPubKey = builtins.readFile ../secrets/dev_ssh.pub;

    # Helm packages (optional)
    # helmPackages = {
    #   autoDeployOnBootstrap = true;  # Auto-deploy after k3s starts
    #   repos = {
    #     cilium = "https://helm.cilium.io/";
    #   };
    #   charts = {
    #     cilium = {
    #       chart = "cilium/cilium";
    #       version = "1.15.0";
    #       namespace = "kube-system";
    #       values = {
    #         operator.replicas = 1;
    #       };
    #     };
    #   };
    # };

    members = {
      server = {
        node = "standard";
        role = "server";
        ip = "192.168.1.10";
      };
      agent = {
        node = "standard";
        role = "agent";
        ip = "192.168.1.20";
      };
    };
  };
}
