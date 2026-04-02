# nixos-anywhere provisioning module
# Generates apps for deploying nodes via nixos-anywhere
{ lib, config, inputs, ... }:

let
  cfg = config.nix8s;

  # Check if nixos-anywhere is enabled for a cluster
  anywhereEnabled = cluster: cluster.provisioning.nixos-anywhere.enable or false;

in
{
  perSystem = { pkgs, system, ... }:
    let
      # Generate deploy script for a single node
      mkDeployScript = clusterName: cluster: memberName: member:
        let
          configName = "${clusterName}-${memberName}";
          targetIp = member.ip or (throw "nix8s: member ${memberName} in cluster ${clusterName} has no IP");

          # SSH config from cluster provisioning
          provCfg = cluster.provisioning.nixos-anywhere;
          sshUser = provCfg.ssh.user or "root";
          sshKeyFile = provCfg.ssh.keyFile or null;
          sshPort = provCfg.ssh.port or 22;

          # Secrets directory
          secretsDir = "nix8s/secrets";
          clusterSshKey = "${secretsDir}/${clusterName}_ssh";

          # Build SSH key args (empty if using ssh-agent)
          sshKeyArgs =
            if sshKeyFile != null then
              [ "-i" sshKeyFile ]
            else
              [ ];

        in
        pkgs.writeShellApplication {
          name = "${configName}-deploy";
          runtimeInputs = with pkgs; [ openssh ];
          text = ''
            set -euo pipefail

            TARGET_IP="${targetIp}"
            TARGET_USER="${sshUser}"
            SSH_PORT="${toString sshPort}"
            FLAKE_REF="''${1:-.}"
            SSH_KEY_ARGS=()

            # Use explicit key file if configured, otherwise try cluster key, otherwise ssh-agent
            ${if sshKeyFile != null then ''
            SSH_KEY_ARGS=("${lib.concatStringsSep "\" \"" sshKeyArgs}")
            '' else ''
            if [[ -f "${clusterSshKey}" ]]; then
              SSH_KEY_ARGS=(-i "${clusterSshKey}")
            fi
            # If no key found, ssh-agent will be used automatically
            ''}

            echo "========================================"
            echo " nixos-anywhere Deploy"
            echo " Config: ${configName}"
            echo " Target: $TARGET_USER@$TARGET_IP:$SSH_PORT"
            echo " Flake: $FLAKE_REF#${configName}"
            ${if sshKeyFile == null then ''echo " SSH: ''${SSH_KEY_ARGS[*]:-ssh-agent}"'' else ''echo " SSH: ${sshKeyFile}"''}
            echo "========================================"
            echo ""

            # Build nixos-anywhere command
            NIXOS_ANYWHERE_ARGS=(
              --flake "$FLAKE_REF#${configName}"
              --ssh-port "$SSH_PORT"
            )

            # Add SSH key args if present
            if [[ ''${#SSH_KEY_ARGS[@]} -gt 0 ]]; then
              NIXOS_ANYWHERE_ARGS+=("''${SSH_KEY_ARGS[@]}")
            fi

            NIXOS_ANYWHERE_ARGS+=("$TARGET_USER@$TARGET_IP")

            # Check if nixos-anywhere is available
            if ! command -v nixos-anywhere &>/dev/null; then
              echo "Running via nix run..."
              nix run github:nix-community/nixos-anywhere -- "''${NIXOS_ANYWHERE_ARGS[@]}"
            else
              nixos-anywhere "''${NIXOS_ANYWHERE_ARGS[@]}"
            fi

            echo ""
            echo "========================================"
            echo " Deploy complete!"
            echo "========================================"
            echo ""
            echo "Connect with:"
            echo "  ssh ''${SSH_KEY_ARGS[*]} $TARGET_USER@$TARGET_IP"
          '';
        };

      # Generate deploy-all script for entire cluster
      mkDeployAllScript = clusterName: cluster:
        let
          memberNames = lib.attrNames cluster.members;

          # Use k3s extension roles for ordering if available
          k3sServers = cluster.k3s.servers or [ ];
          k3sAgents = cluster.k3s.agents or [ ];
          otherMembers = lib.filter
            (name: !(lib.elem name k3sServers) && !(lib.elem name k3sAgents))
            memberNames;

          # Sort servers, first server first
          sortedServerNames = lib.sort (a: b: a < b) k3sServers;
          firstServerName =
            if sortedServerNames != [ ]
            then cluster.k3s.firstServer or (lib.head sortedServerNames)
            else if memberNames != [ ] then lib.head (lib.sort (a: b: a < b) memberNames)
            else null;
          otherServerNames = lib.filter (n: n != firstServerName) sortedServerNames;

          # Order: first server, other servers, agents, others
          orderedNames =
            (if firstServerName != null then [ firstServerName ] else [ ])
            ++ otherServerNames
            ++ k3sAgents
            ++ otherMembers;

          provCfg = cluster.provisioning.nixos-anywhere;
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
            SSH_KEY_ARGS=()

            # Use explicit key file if configured, otherwise try cluster key, otherwise ssh-agent
            ${if sshKeyFile != null then ''
            SSH_KEY_ARGS=(-i "${sshKeyFile}")
            '' else ''
            if [[ -f "${clusterSshKey}" ]]; then
              SSH_KEY_ARGS=(-i "${clusterSshKey}")
            fi
            # If no key found, ssh-agent will be used automatically
            ''}

            echo "========================================"
            echo " nixos-anywhere Cluster Deploy"
            echo " Cluster: ${clusterName}"
            echo " Members: ${toString (lib.length orderedNames)}"
            echo "========================================"
            echo ""
            echo "Deploy order:"
            ${lib.concatMapStringsSep "\n" (name:
              let
                member = cluster.members.${name};
                ipStr = member.ip or "no-ip";
              in ''echo "  - ${clusterName}-${name} (${ipStr})"''
            ) orderedNames}
            echo ""

            ${if firstServerName != null then ''
            # Deploy first member first
            echo "Deploying first: ${clusterName}-${firstServerName}..."
            nix run "$FLAKE_REF#${clusterName}-${firstServerName}-deploy" -- "$FLAKE_REF"
            echo ""

            # Wait for first member to be reachable
            echo "Waiting for ${firstServerName} to be reachable..."
            FIRST_IP="${cluster.members.${firstServerName}.ip or ""}"
            if [[ -n "$FIRST_IP" ]]; then
              for i in $(seq 1 30); do
                if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
                     "''${SSH_KEY_ARGS[@]}" \
                     ${sshUser}@"$FIRST_IP" \
                     "echo ok" &>/dev/null; then
                  echo "${firstServerName} is ready!"
                  break
                fi
                echo "Waiting... ($i/30)"
                sleep 5
              done
            fi
            echo ""
            '' else ""}

            # Deploy remaining members
            ${lib.concatMapStringsSep "\n" (name: ''
              echo "Deploying ${clusterName}-${name}..."
              nix run "$FLAKE_REF#${clusterName}-${name}-deploy" -- "$FLAKE_REF"
              echo ""
            '') (lib.filter (n: n != firstServerName) orderedNames)}

            echo "========================================"
            echo " Cluster deploy complete!"
            echo "========================================"
          '';
        };

      # Generate apps for all clusters
      nixosAnywhereApps = lib.concatMapAttrs
        (clusterName: cluster:
          lib.optionalAttrs (anywhereEnabled cluster) (
            # Per-member deploy apps
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
