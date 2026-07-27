# k3s cluster extension module
# Adds k3s NixOS module to all members and provides CLI commands
{ lib, config, options, ... }:

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

  # Converge-step names (must match core's `member-<name>` generation).
  memberStepName = memberName: "member-${memberName}";
  serverSteps = map memberStepName sortedServers;
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

    nodes = {
      description = "List cluster nodes (table; --json for raw)";
      builder = { pkgs, lib, cluster, helpers, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-k3s-nodes";
          runtimeInputs = with pkgs; [ kubectl jq coreutils ];
          text = ''
            set -euo pipefail
            export KUBECONFIG="kubeconfig/${clusterName}.yaml"
            if [[ ! -f "$KUBECONFIG" ]]; then
              echo "No kubeconfig. Run: nixclusterctl ${clusterName} k3s kubeconfig fetch" >&2
              exit 1
            fi
            if [[ "''${1:-}" == "--json" ]]; then
              exec kubectl get nodes -o json
            fi
            {
              printf 'NAME\tSTATUS\tROLES\tVERSION\tINTERNAL-IP\n'
              kubectl get nodes -o json | jq -r '
                .items[] | [
                  .metadata.name,
                  ([.status.conditions[] | select(.type=="Ready") | .status] | join("")),
                  ([.metadata.labels | to_entries[] | select(.key|test("node-role.kubernetes.io/")) | (.key|sub("node-role.kubernetes.io/";""))] | join(",")),
                  .status.nodeInfo.kubeletVersion,
                  ([.status.addresses[] | select(.type=="InternalIP") | .address] | join(""))
                ] | @tsv'
            } | ${lib.getExe helpers.tablefmt}
          '';
        };
    };

    manifest = {
      description = "Manage deployed manifests (list | apply <file> | delete <file>)";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-k3s-manifest";
          runtimeInputs = with pkgs; [ kubectl ];
          text = ''
            set -euo pipefail
            export KUBECONFIG="kubeconfig/${clusterName}.yaml"
            if [[ ! -f "$KUBECONFIG" ]]; then
              echo "No kubeconfig. Run: nixclusterctl ${clusterName} k3s kubeconfig fetch" >&2
              exit 1
            fi
            SUB="''${1:-list}"
            shift || true
            case "$SUB" in
              list)   kubectl get all --all-namespaces ;;
              apply)  [[ -n "''${1:-}" ]] || { echo "usage: k3s manifest apply <file>" >&2; exit 1; }; kubectl apply --filename "$1" ;;
              delete) [[ -n "''${1:-}" ]] || { echo "usage: k3s manifest delete <file>" >&2; exit 1; }; kubectl delete --filename "$1" ;;
              *)      echo "manifest subcommands: list | apply <file> | delete <file>" >&2; exit 1 ;;
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

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # Add k3s NixOS module to ALL members
      _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
        [ k3sNixosModule ]
      );

      # Add CLI commands only if we have k3s members (group `k3s`)
      commandGroups.k3s = lib.mkIf (allK3sMembers != []) {
        description = "k3s cluster management";
        actions = k3sCommands;
      };

      # converge DAG: the k3s ordering contract, expressed as dependencies.
      #
      #   - the first server bootstraps the cluster (etcd), so every other server
      #     waits for it;
      #   - an agent has nothing to join until the control plane exists, so it
      #     waits for ALL servers — not merely for whichever member core happened
      #     to order before it;
      #   - the kubeconfig can only be fetched from a running server.
      #
      # Refining the generated `member-*` steps is enough; core supplies the rest
      # of each step (the member it converges, its description).
      converge.steps = lib.mkIf (allK3sMembers != []) (
        {
          "k3s.bootstrap" = {
            description = "Report k3s bootstrap/deploy order";
            phase = "post";
            priority = 30;
            deps = serverSteps;
            run = k3sCommands.bootstrap.builder;
          };
          "k3s.kubeconfig" = {
            description = "Fetch cluster kubeconfig";
            phase = "post";
            priority = 35;
            deps = serverSteps;
            run = k3sCommands.kubeconfig.builder;
          };
        }
        // lib.listToAttrs (map
          (server: lib.nameValuePair (memberStepName server) {
            deps = [ (memberStepName firstServer) ];
          })
          (lib.filter (server: server != firstServer) servers))
        // lib.listToAttrs (map
          (agent: lib.nameValuePair (memberStepName agent) { deps = serverSteps; })
          agents)
      );
    }

    # Register the k3s secret provider when sops is in use (task 10). Guarded by
    # option presence so k3s works without the sops module imported.
    (lib.optionalAttrs (options ? sops) {
      sops.providers.k3s.generate = { ... }: {
        "k3s/token" = "head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 48";
        "k3s/agentToken" = "head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 48";
      };
    })
  ]);
}
