# k3s cluster extension module
# Adds k3s NixOS module to all members and provides CLI commands
{ lib, config, options, ... }:

let
  cfg = config.k3s;
  clusterName = config.name;

  # Import NixOS module path
  k3sNixosModule = ../modules/nixos/nixcluster-k3s.nix;

  # Shared registry-diff engine (see lib/prune.nix): every module that reconciles
  # membership downward uses it, so the dangerous part exists exactly once.
  mkPruneStep = import ../lib/prune.nix { inherit lib; };

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

  # Registry names (Kubernetes node names) of the desired k3s members, via core's
  # canonical mapping — never re-derived here.
  desiredNodeNames = map (member: config.memberRegistryNames.${member}) allK3sMembers;

  # Smallest number of nodes the registry must keep. Embedded etcd needs a
  # majority of its members to elect a leader, so with N registered nodes we may
  # only prune down to floor(N/2)+1. That bound is computed against the LIVE
  # registry inside the step (we cannot know here how many nodes are actually
  # registered), so what we pass is the majority of the DESIRED server count —
  # the floor below which the control plane certainly cannot function.
  serverQuorumMinimum =
    if servers == [] then 0 else (builtins.length servers) / 2 + 1;

  # Removing a k3s node, in the order the k3s maintainers require:
  #
  #   1. cordon + drain, bounded, so workloads move off before the node goes;
  #   2. stop the k3s unit ON the node — a server whose service keeps running
  #      rejoins the etcd cluster after being deleted (k3s-io/k3s#4023). NixOS has
  #      no `k3s-uninstall.sh`, so stopping the unit is the whole host-side story
  #      and it is best-effort;
  #   3. for a SERVER, remove the embedded etcd member. `kubectl delete node` does
  #      NOT do this (k3s-io/k3s#4865): the supported way is the
  #      `etcd.k3s.cattle.io/remove=true` annotation, which shuts etcd down on
  #      that node — so it must come after draining, never before;
  #   4. delete the Node object.
  #
  # An unreachable node (already wiped, the common case) skips 1 and 2 and has its
  # Node object and etcd member removed from a surviving server.
  pruneRemoveEntry = ''
    local node="$1" reachable="$2"

    if [[ "$reachable" == "reachable" ]]; then
      kubectl cordon "$node" || true
      # Bounded: a stuck pod must not hold the whole converge run.
      kubectl drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --timeout=${toString cfg.prune.drainTimeoutSeconds}s || \
        log "drain of $node did not finish cleanly; continuing"

      # Best-effort: NixOS has no k3s-uninstall.sh. Without this a server rejoins.
      ssh_stop_k3s "$node" || log "could not stop the k3s unit on $node; continuing"
    fi

    if is_server "$node"; then
      # Ask k3s to remove the etcd member. Deleting the Node alone leaves it
      # behind and the survivors keep dialling a machine that is gone.
      kubectl annotate node "$node" etcd.k3s.cattle.io/remove=true --overwrite || \
        log "could not annotate $node for etcd removal; the member may need etcdctl"
    fi

    kubectl delete node "$node" --ignore-not-found --wait=false
  '';

  # Everything the prune step needs before it starts: the kubeconfig converge
  # fetched, and helpers that answer questions about a node that is no longer in
  # the cluster definition — so its role and address come from the REGISTRY, the
  # only place that still knows them.
  prunePrelude = ''
    export KUBECONFIG="kubeconfig/${clusterName}.yaml"
    if [[ ! -f "$KUBECONFIG" ]]; then
      log "no kubeconfig at $KUBECONFIG; run the k3s.kubeconfig step first"
      exit 0
    fi

    SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes)

    # A departing node's address is not in the cluster definition any more; the
    # Node object still has it.
    node_ip() {
      kubectl get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true
    }

    # Purpose-specific rather than a generic "run this string over there": the
    # remote command is a literal, so there is no question about which side
    # expands what.
    ssh_reachable() { # node
      local ip
      ip="$(node_ip "$1")"
      [[ -n "$ip" ]] || return 1
      ssh "''${SSH_OPTS[@]}" "root@$ip" 'true'
    }

    ssh_stop_k3s() { # node
      local ip
      ip="$(node_ip "$1")"
      [[ -n "$ip" ]] || return 1
      ssh "''${SSH_OPTS[@]}" "root@$ip" 'systemctl stop k3s k3s-agent 2>/dev/null || true'
    }

    # Role from the registry's own labels, not from our config: the node we are
    # removing is by definition absent from the config.
    is_server() {
      kubectl get node "$1" \
        -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null |
        grep --quiet true
    }
  '';

  pruneProbeHost = ''
    ssh_reachable "$1" >/dev/null 2>&1
  '';

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

    prune.drainTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = ''
        How long to wait for a departing node to drain before removing it anyway.
        Bounded on purpose: a pod that will not evict must not hold the whole
        converge run open.
      '';
    };
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

          # Membership is reconciled in BOTH directions: this removes nodes that
          # are registered but no longer in the cluster definition. It waits for
          # every member step and for the kubeconfig, so the desired members have
          # converged before anything is taken away.
          "k3s.prune" = {
            description = "Remove departed members from the Kubernetes registry";
            phase = "post";
            priority = 40;
            deps = (map memberStepName allK3sMembers) ++ [ "k3s.kubeconfig" ];
            run = { pkgs, ... }: mkPruneStep {
              inherit pkgs;
              subject = "k3s";
              runtimeInputs = with pkgs; [ kubectl openssh gnugrep ];
              desired = desiredNodeNames;
              quorumMinimum = serverQuorumMinimum;
              prelude = prunePrelude;
              probeHost = pruneProbeHost;
              listRegistry = ''kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' '';
              removeEntry = pruneRemoveEntry;
            };
          };
        }
        # The first server leads: it depends on the preparation steps only. This
        # MUST be stated. Core's default makes each member wait for the previous
        # one in name order, which for a cluster whose agents sort before its
        # servers would make the bootstrap wait for an agent that is itself
        # waiting for the bootstrap — a cycle.
        // {
          ${memberStepName firstServer}.deps = lib.attrNames config.converge.preSteps;
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
