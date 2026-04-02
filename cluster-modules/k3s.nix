# k3s cluster extension module
# Adds k3s options to members and generates NixOS modules
{ lib, config, ... }:

let
  cfg = config;

  # Get all members with k3s role
  k3sMembers = lib.filterAttrs
    (name: member: member.k3s.role or null != null)
    cfg.members;

  servers = lib.attrNames (lib.filterAttrs (n: m: m.k3s.role == "server") k3sMembers);
  agents = lib.attrNames (lib.filterAttrs (n: m: m.k3s.role == "agent") k3sMembers);

  # First server for cluster-init
  sortedServers = lib.sort (a: b: a < b) servers;
  firstServer = if sortedServers != [] then lib.head sortedServers else null;

  # Get first server IP
  firstServerIp =
    if firstServer != null
    then cfg.members.${firstServer}.install.ip or null
    else null;

  # Generate NixOS module for a k3s member
  mkK3sNixosModule = memberName: member:
    let
      role = member.k3s.role;
      isFirst = memberName == firstServer;
      memberIp = member.install.ip or "127.0.0.1";
    in
    { config, pkgs, ... }: {
      services.k3s = {
        enable = true;
        inherit role;

        serverAddr = lib.mkIf (!isFirst && firstServerIp != null)
          "https://${firstServerIp}:6443";

        extraFlags = lib.concatStringsSep " " (
          [ "--node-ip=${memberIp}" ]
          ++ (lib.optionals isFirst [ "--cluster-init" ])
          ++ (member.k3s.extraFlags or [])
        );
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

  # CLI commands
  k3sCommands = {
    bootstrap = {
      description = "Bootstrap k3s cluster";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nix8sctl-${cluster.name}-bootstrap";
          text = ''
            echo "Bootstrapping k3s cluster '${cluster.name}'"
            echo "Servers: ${lib.concatStringsSep " " servers}"
            echo "Agents: ${lib.concatStringsSep " " agents}"
            echo ""
            echo "First server: ${toString firstServer}"
            echo ""
            echo "Deploy order:"
            echo "  1. nix8sctl ${cluster.name} apply ${toString firstServer}"
            ${lib.concatMapStringsSep "\n" (s: ''echo "  2. nix8sctl ${cluster.name} apply ${s}"'') (lib.filter (s: s != firstServer) servers)}
            ${lib.concatMapStringsSep "\n" (a: ''echo "  3. nix8sctl ${cluster.name} apply ${a}"'') agents}
          '';
        };
    };

    kubeconfig = {
      description = "Fetch kubeconfig";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nix8sctl-${cluster.name}-kubeconfig";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            ACTION="''${1:-fetch}"
            KUBECONFIG_FILE="nix8s/kubeconfig/${cluster.name}.yaml"

            case "$ACTION" in
              fetch)
                mkdir -p "$(dirname "$KUBECONFIG_FILE")"
                echo "Fetching kubeconfig from ${toString firstServerIp}..."
                scp -o StrictHostKeyChecking=no "root@${toString firstServerIp}:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG_FILE.tmp"
                sed "s/127.0.0.1/${toString firstServerIp}/g" "$KUBECONFIG_FILE.tmp" > "$KUBECONFIG_FILE"
                rm "$KUBECONFIG_FILE.tmp"
                chmod 600 "$KUBECONFIG_FILE"
                echo "Saved: $KUBECONFIG_FILE"
                ;;
              path)
                echo "$KUBECONFIG_FILE"
                ;;
              *)
                cat "$KUBECONFIG_FILE"
                ;;
            esac
          '';
        };
    };
  };

in
{
  # Add k3s options to member submodule
  options.members = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options.k3s = {
        role = lib.mkOption {
          type = lib.types.nullOr (lib.types.enum [ "server" "agent" ]);
          default = null;
          description = "k3s role for this member";
        };

        extraFlags = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Extra flags for k3s";
        };
      };
    });
  };

  config = lib.mkIf (k3sMembers != {}) {
    # Generate NixOS modules for k3s members
    _generatedNixosModules = lib.mapAttrs
      (name: member: [ (mkK3sNixosModule name member) ])
      k3sMembers;

    # Add CLI commands
    commands = [ k3sCommands ];
  };
}
