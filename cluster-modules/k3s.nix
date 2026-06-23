# k3s cluster extension module
# Adds k3s NixOS module to all members and provides CLI commands
{ lib, config, ... }:

let
  cfg = config.k3s;
  clusterName = config.name;

  # Import NixOS module path
  k3sNixosModule = ../modules/nixos/nixcluster-k3s.nix;

  # Get k3s members from members config (via k3s.role NixOS option)
  k3sMembers = lib.filterAttrs
    (name: member: member.k3s.role or null != null)
    config.members;

  servers = lib.attrNames (lib.filterAttrs (n: m: m.k3s.role == "server") k3sMembers);
  agents = lib.attrNames (lib.filterAttrs (n: m: m.k3s.role == "agent") k3sMembers);
  allK3sMembers = servers ++ agents;

  # First server
  sortedServers = lib.sort (a: b: a < b) servers;
  firstServer = if sortedServers != [] then lib.head sortedServers else null;
  firstServerIp = if firstServer != null
    then config.members.${firstServer}.install.ip or null
    else null;

  # CLI commands
  k3sCommands = {
    bootstrap = {
      description = "Bootstrap k3s cluster";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-bootstrap";
          text = ''
            echo "Bootstrapping k3s cluster '${clusterName}'"
            echo ""
            echo "Servers: ${lib.concatStringsSep " " servers}"
            echo "Agents: ${lib.concatStringsSep " " agents}"
            echo "First server: ${toString firstServer}"
            echo ""
            echo "Deploy order:"
            echo "  1. nixclusterctl ${clusterName} apply ${toString firstServer}"
            ${lib.concatMapStringsSep "\n" (s: ''echo "  2. nixclusterctl ${clusterName} apply ${s}"'') (lib.filter (s: s != firstServer) servers)}
            ${lib.concatMapStringsSep "\n" (a: ''echo "  3. nixclusterctl ${clusterName} apply ${a}"'') agents}
          '';
        };
    };

    kubeconfig = {
      description = "Fetch kubeconfig";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-kubeconfig";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            ACTION="''${1:-fetch}"
            KUBECONFIG_FILE="kubeconfig/${clusterName}.yaml"

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
  options.k3s = {
    enable = lib.mkEnableOption "k3s cluster";
  };

  config = lib.mkIf cfg.enable {
    # Add k3s NixOS module to ALL members
    _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
      [ k3sNixosModule ]
    );

    # Add CLI commands only if we have k3s members
    commands = lib.mkIf (allK3sMembers != []) [ k3sCommands ];
  };
}
