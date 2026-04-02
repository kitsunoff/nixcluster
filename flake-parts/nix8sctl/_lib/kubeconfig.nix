# nix8sctl <cluster> kubeconfig [fetch|show|path]
# Fetches or displays kubeconfig for a cluster
{ pkgs, lib, cluster, clusterName }:

let
  # Get first server IP from k3s extension
  k3sServers = cluster.k3s.servers or [ ];
  sortedServers = lib.sort (a: b: a < b) k3sServers;
  firstServerName = cluster.k3s.firstServer or (
    if sortedServers != [ ] then lib.head sortedServers else null
  );
  firstServerIp =
    if firstServerName != null && cluster.members ? ${firstServerName}
    then cluster.members.${firstServerName}.ip or "UNKNOWN"
    else "UNKNOWN";
in
pkgs.writeShellApplication {
  name = "nix8sctl-${clusterName}-kubeconfig";
  runtimeInputs = with pkgs; [ openssh coreutils ];
  text = ''
    set -euo pipefail

    ACTION="''${1:-show}"
    FIRST_SERVER_IP="${firstServerIp}"

    SECRETS_DIR="nix8s/secrets"
    SSH_KEY_FILE="$SECRETS_DIR/${clusterName}_ssh"
    KUBECONFIG_DIR="nix8s/kubeconfig"
    KUBECONFIG_FILE="$KUBECONFIG_DIR/${clusterName}.yaml"

    SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    if [[ -f "$SSH_KEY_FILE" ]]; then
      SSH_OPTS+=(-i "$SSH_KEY_FILE")
    fi

    case "$ACTION" in
      fetch)
        if [[ "$FIRST_SERVER_IP" == "UNKNOWN" ]]; then
          echo "Error: Could not determine first server IP"
          exit 1
        fi
        echo "Fetching kubeconfig from $FIRST_SERVER_IP..."
        mkdir -p "$KUBECONFIG_DIR"
        scp "''${SSH_OPTS[@]}" "root@$FIRST_SERVER_IP:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG_FILE.tmp"
        sed "s/127.0.0.1/$FIRST_SERVER_IP/g" "$KUBECONFIG_FILE.tmp" > "$KUBECONFIG_FILE"
        rm "$KUBECONFIG_FILE.tmp"
        chmod 600 "$KUBECONFIG_FILE"
        echo "Saved to $KUBECONFIG_FILE"
        echo ""
        echo "Use:"
        echo "  export KUBECONFIG=$KUBECONFIG_FILE"
        ;;
      show)
        if [[ ! -f "$KUBECONFIG_FILE" ]]; then
          echo "Error: Kubeconfig not found at $KUBECONFIG_FILE"
          echo "Run: nix8sctl ${clusterName} kubeconfig fetch"
          exit 1
        fi
        cat "$KUBECONFIG_FILE"
        ;;
      path)
        if [[ ! -f "$KUBECONFIG_FILE" ]]; then
          echo "Error: Kubeconfig not found at $KUBECONFIG_FILE"
          exit 1
        fi
        echo "$KUBECONFIG_FILE"
        ;;
      --help|-h|help)
        echo "Usage: nix8sctl ${clusterName} kubeconfig [fetch|show|path]"
        echo ""
        echo "Actions:"
        echo "  fetch   - Fetch kubeconfig from cluster (overwrites local)"
        echo "  show    - Display local kubeconfig (default)"
        echo "  path    - Print path to kubeconfig file"
        ;;
      *)
        echo "Error: Unknown action '$ACTION'"
        echo "Use: fetch, show, or path"
        exit 1
        ;;
    esac
  '';
}
