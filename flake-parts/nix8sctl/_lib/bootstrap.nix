# nix8sctl <cluster> bootstrap [timeout-seconds]
# Bootstraps the cluster: waits for k3s, fetches kubeconfig
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
  name = "nix8sctl-${clusterName}-bootstrap";
  runtimeInputs = with pkgs; [ openssh coreutils kubectl ];
  text = ''
    set -euo pipefail

    TIMEOUT="''${1:-300}"
    FIRST_SERVER_IP="${firstServerIp}"

    if [[ "$FIRST_SERVER_IP" == "UNKNOWN" ]]; then
      echo "Error: Could not determine first server IP"
      echo "Check that k3s.servers is configured and members have IP addresses"
      exit 1
    fi

    SECRETS_DIR="nix8s/secrets"
    SSH_KEY_FILE="$SECRETS_DIR/${clusterName}_ssh"
    KUBECONFIG_DIR="nix8s/kubeconfig"
    KUBECONFIG_FILE="$KUBECONFIG_DIR/${clusterName}.yaml"

    SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    if [[ -f "$SSH_KEY_FILE" ]]; then
      SSH_OPTS+=(-i "$SSH_KEY_FILE")
    fi

    echo "=========================================="
    echo "Bootstrapping cluster: ${clusterName}"
    echo "=========================================="
    echo ""
    echo "First server: ${firstServerName} ($FIRST_SERVER_IP)"
    echo "Timeout: ''${TIMEOUT}s"
    echo ""

    # Step 1: Wait for k3s to be ready
    echo "[1/3] Waiting for k3s to be ready..."
    START_TIME=$(date +%s)
    while true; do
      CURRENT_TIME=$(date +%s)
      ELAPSED=$((CURRENT_TIME - START_TIME))

      if [[ $ELAPSED -gt $TIMEOUT ]]; then
        echo "Error: Timeout waiting for k3s"
        exit 1
      fi

      if ssh "''${SSH_OPTS[@]}" "root@$FIRST_SERVER_IP" \
          "test -f /etc/rancher/k3s/k3s.yaml && systemctl is-active k3s >/dev/null 2>&1" 2>/dev/null; then
        echo "       k3s is ready! (''${ELAPSED}s)"
        break
      fi

      echo "       Waiting... (''${ELAPSED}s)"
      sleep 5
    done

    # Step 2: Fetch kubeconfig
    echo "[2/3] Fetching kubeconfig..."
    mkdir -p "$KUBECONFIG_DIR"
    scp "''${SSH_OPTS[@]}" "root@$FIRST_SERVER_IP:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG_FILE.tmp"

    # Replace localhost with actual IP
    sed "s/127.0.0.1/$FIRST_SERVER_IP/g" "$KUBECONFIG_FILE.tmp" > "$KUBECONFIG_FILE"
    rm "$KUBECONFIG_FILE.tmp"
    chmod 600 "$KUBECONFIG_FILE"
    echo "       Saved to $KUBECONFIG_FILE"

    # Step 3: Verify cluster
    echo "[3/3] Verifying cluster..."
    export KUBECONFIG="$KUBECONFIG_FILE"
    if kubectl get nodes; then
      echo ""
      echo "=========================================="
      echo "Cluster bootstrapped successfully!"
      echo "=========================================="
      echo ""
      echo "Use kubeconfig:"
      echo "  export KUBECONFIG=$KUBECONFIG_FILE"
      echo "  kubectl get nodes"
    else
      echo "Warning: Could not verify cluster"
      exit 1
    fi
  '';
}
