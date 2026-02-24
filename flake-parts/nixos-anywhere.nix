# nixos-anywhere provisioning module
# Generates apps for deploying nodes via nixos-anywhere
{ lib, config, inputs, ... }:

let
  cfg = config.nix8s;

  memberAttrs = [ "node" "role" "ip" ];

  resolveNode = clusterName: memberName: nodeRef:
    if builtins.isAttrs nodeRef
    then nodeRef
    else cfg.nodes.${nodeRef} or { };

  buildNodeConfig = clusterName: memberName: member:
    lib.recursiveUpdate
      (resolveNode clusterName memberName member.node)
      (removeAttrs member memberAttrs);

in
{
  perSystem = { pkgs, system, ... }:
    let
      # Generate deploy script for a single node
      mkDeployScript = clusterName: cluster: memberName: member:
        let
          nodeConfig = buildNodeConfig clusterName memberName member;
          nodeName = "${clusterName}-${memberName}";
          targetIp = member.ip;

          # SSH config from provisioning or defaults
          provCfg = cluster.provisioning.nixos-anywhere or cfg.provisioning.nixos-anywhere or { };
          sshUser = provCfg.ssh.user or "root";
          sshKeyFile = provCfg.ssh.keyFile or null;
          sshPort = provCfg.ssh.port or 22;

          # Secrets directory
          secretsDir = "nix8s/secrets";
          clusterSshKey = "${secretsDir}/${clusterName}_ssh";

          # Determine which SSH key to use
          sshKeyArg =
            if sshKeyFile != null then
              "-i ${sshKeyFile}"
            else
              "-i $SSH_KEY";

        in
        pkgs.writeShellApplication {
          name = "${nodeName}-deploy";
          runtimeInputs = with pkgs; [ openssh ];
          text = ''
            set -euo pipefail

            TARGET_IP="${targetIp}"
            TARGET_USER="${sshUser}"
            SSH_PORT="${toString sshPort}"
            FLAKE_REF="''${1:-.}"
            SSH_KEY=""

            # Find SSH key
            if [[ -f "${clusterSshKey}" ]]; then
              SSH_KEY="${clusterSshKey}"
            elif [[ -f "$HOME/.ssh/id_ed25519" ]]; then
              SSH_KEY="$HOME/.ssh/id_ed25519"
            elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
              SSH_KEY="$HOME/.ssh/id_rsa"
            fi

            echo "========================================"
            echo " nixos-anywhere Deploy"
            echo " Node: ${nodeName}"
            echo " Target: $TARGET_USER@$TARGET_IP:$SSH_PORT"
            echo " Flake: $FLAKE_REF#${nodeName}"
            echo "========================================"
            echo ""

            # Check if nixos-anywhere is available
            if ! command -v nixos-anywhere &>/dev/null; then
              echo "Installing nixos-anywhere..."
              nix run github:nix-community/nixos-anywhere -- \
                --flake "$FLAKE_REF#${nodeName}" \
                --ssh-port "$SSH_PORT" \
                ${sshKeyArg} \
                "$TARGET_USER@$TARGET_IP"
            else
              nixos-anywhere \
                --flake "$FLAKE_REF#${nodeName}" \
                --ssh-port "$SSH_PORT" \
                ${sshKeyArg} \
                "$TARGET_USER@$TARGET_IP"
            fi

            echo ""
            echo "========================================"
            echo " Deploy complete!"
            echo "========================================"
            echo ""
            echo "Connect with:"
            echo "  ssh ${sshKeyArg} $TARGET_USER@$TARGET_IP"
          '';
        };

      # Generate deploy-all script for entire cluster
      mkDeployAllScript = clusterName: cluster:
        let
          memberNames = lib.attrNames cluster.members;

          # Get server members first, then agents
          serverNames = lib.filter
            (name: cluster.members.${name}.role == "server")
            memberNames;
          agentNames = lib.filter
            (name: cluster.members.${name}.role == "agent")
            memberNames;

          # Sort servers, first server first
          sortedServerNames = lib.sort (a: b: a < b) serverNames;
          firstServerName = cluster.firstServer or (lib.head sortedServerNames);
          otherServerNames = lib.filter (n: n != firstServerName) sortedServerNames;

          # Order: first server, other servers, agents
          orderedNames = [ firstServerName ] ++ otherServerNames ++ agentNames;

          provCfg = cluster.provisioning.nixos-anywhere or cfg.provisioning.nixos-anywhere or { };
          sshUser = provCfg.ssh.user or "root";
          sshKeyFile = provCfg.ssh.keyFile or null;

          secretsDir = "nix8s/secrets";
          clusterSshKey = "${secretsDir}/${clusterName}_ssh";

        in
        pkgs.writeShellApplication {
          name = "${clusterName}-deploy";
          runtimeInputs = with pkgs; [ openssh ];
          text = ''
            set -euo pipefail

            FLAKE_REF="''${1:-.}"
            SSH_KEY=""
            PARALLEL="''${PARALLEL:-false}"

            # Find SSH key
            if [[ -f "${clusterSshKey}" ]]; then
              SSH_KEY="${clusterSshKey}"
            elif [[ -f "$HOME/.ssh/id_ed25519" ]]; then
              SSH_KEY="$HOME/.ssh/id_ed25519"
            fi

            echo "========================================"
            echo " nixos-anywhere Cluster Deploy"
            echo " Cluster: ${clusterName}"
            echo " Nodes: ${toString (lib.length orderedNames)}"
            echo "========================================"
            echo ""
            echo "Deploy order:"
            ${lib.concatMapStringsSep "\n" (name:
              let member = cluster.members.${name};
              in ''echo "  ${toString (lib.elemAt orderedNames (lib.lists.findFirstIndex (n: n == name) 0 orderedNames) + 1)}. ${clusterName}-${name} (${member.role}) - ${member.ip}"''
            ) orderedNames}
            echo ""

            # Deploy first server first (for cluster init)
            echo "Deploying first server: ${clusterName}-${firstServerName}..."
            nix run "$FLAKE_REF#${clusterName}-${firstServerName}-deploy" -- "$FLAKE_REF"
            echo ""

            # Wait for first server to be ready
            echo "Waiting for first server API..."
            FIRST_SERVER_IP="${cluster.members.${firstServerName}.ip}"
            for i in $(seq 1 60); do
              if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
                   ''${SSH_KEY:+-i "$SSH_KEY"} \
                   ${sshUser}@"$FIRST_SERVER_IP" \
                   "kubectl get nodes" &>/dev/null; then
                echo "First server is ready!"
                break
              fi
              echo "Waiting... ($i/60)"
              sleep 10
            done
            echo ""

            # Deploy remaining nodes
            ${lib.concatMapStringsSep "\n" (name: ''
              echo "Deploying ${clusterName}-${name}..."
              nix run "$FLAKE_REF#${clusterName}-${name}-deploy" -- "$FLAKE_REF"
              echo ""
            '') (otherServerNames ++ agentNames)}

            echo "========================================"
            echo " Cluster deploy complete!"
            echo "========================================"
            echo ""
            echo "Fetch kubeconfig:"
            echo "  nix run $FLAKE_REF#fetch-kubeconfig -- ${clusterName}"
          '';
        };

      # Generate apps for all clusters
      nixosAnywhereApps = lib.concatMapAttrs
        (clusterName: cluster:
          let
            enabled = cluster.provisioning.nixos-anywhere.enable
              or cfg.provisioning.nixos-anywhere.enable
              or false;
          in
          lib.optionalAttrs enabled (
            # Per-node deploy apps
            (lib.mapAttrs'
              (memberName: member:
                lib.nameValuePair
                  "${clusterName}-${memberName}-deploy"
                  (mkDeployScript clusterName cluster memberName member)
              )
              cluster.members)
            // {
              # Cluster-wide deploy app
              "${clusterName}-deploy" = mkDeployAllScript clusterName cluster;
            }
          )
        )
        cfg.clusters;

    in
    {
      packages = nixosAnywhereApps;
    };
}
