# Incus cluster extension module
# Adds the Incus NixOS module to all members and provides CLI commands.
#
# Usage:
#   imports = [ nixcluster.clusterModules.incus ];
#   incus.enable = true;
#
#   members.node1 = {
#     nixosConfiguration = ...;
#     install.ip = "192.168.1.10";
#     incus.enable = true;            # activate Incus on this node (NixOS option)
#   };
#
#   # Declarative instances (reconciled on the node named by `node`):
#   incus.instances.web = { node = "node1"; image = "images:debian/12"; };
{ lib, config, ... }:

let
  cfg = config.incus;
  clusterName = config.name;

  # NixOS module that configures the Incus daemon + idempotent preseed.
  incusNixosModule = ../modules/nixos/nixcluster-incus.nix;

  # Multi-node clustering toggle (cluster-level, NOT per-member).
  clusterEnabled = cfg.cluster.enable;

  # Members that have Incus activated. In clustering mode EVERY cluster member
  # participates (followup C: NIO-injected data-only members never set the
  # per-member NixOS patch `member.incus.enable`, so clustering must NOT depend
  # on it). Otherwise only members that opt in via that patch.
  perMemberIncusMembers = lib.filterAttrs
    (name: member: member.incus.enable or false)
    config.members;
  incusMembers = if clusterEnabled then config.members else perMemberIncusMembers;

  incusMemberNames = lib.attrNames incusMembers;

  # Bootstrap resolution: explicit `incus.cluster.bootstrapMember`, else the
  # first member sorted by name (all members run Incus when clustering).
  sortedMemberNames = lib.sort (a: b: a < b) (lib.attrNames config.members);
  resolvedBootstrap =
    if cfg.cluster.bootstrapMember != null then cfg.cluster.bootstrapMember
    else if sortedMemberNames != [] then lib.head sortedMemberNames
    else null;
  bootstrapIp =
    if resolvedBootstrap != null
    then (config.members.${resolvedBootstrap}.install.ip or null)
    else null;
  joinerNames = lib.filter (n: n != resolvedBootstrap) (lib.attrNames config.members);

  # Shell prelude: resolve a member -> install.ip and ssh with a PINNED
  # known_hosts (B3 runtime phase — no StrictHostKeyChecking=no). The host key
  # is pinned by `install` into .nixcluster/known_hosts/<cluster>; accept-new
  # tolerates a not-yet-pinned host without disabling verification entirely.
  nodeIpCases = lib.concatStringsSep "\n        " (lib.mapAttrsToList
    (name: member: ''${name}) echo "${member.install.ip or ""}" ;;'')
    incusMembers);

  sshPrelude = ''
    KNOWN_HOSTS=".nixcluster/known_hosts/${clusterName}"
    mkdir -p "$(dirname "$KNOWN_HOSTS")"
    touch "$KNOWN_HOSTS"
    node_ip() {
      case "$1" in
        ${nodeIpCases}
        *) echo "" ;;
      esac
    }
    ssh_node() {
      local node="$1"; shift
      local ip; ip="$(node_ip "$node")"
      if [ -z "$ip" ]; then echo "no install.ip for node '$node'" >&2; return 1; fi
      ssh -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=5 "root@$ip" "$@"
    }
  '';

  allMembersList = lib.concatStringsSep " " incusMemberNames;

  # CLI commands
  incusCommands = {
    status = {
      description = "Show Incus status on cluster nodes";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-incus-status";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            echo "=== Incus status for cluster '${clusterName}' ==="
            echo "Incus nodes: ${allMembersList}"
            echo ""
            INCUS_NODES="${allMembersList}"
            for node in $INCUS_NODES; do
              ip="$(node_ip "$node")"
              echo "--- $node ($ip) ---"
              ssh_node "$node" \
                'incus version 2>/dev/null && echo "-- instances --" && incus list 2>/dev/null && echo "-- storage --" && incus storage list 2>/dev/null' \
                || echo "  (unreachable or Incus not ready)"
              echo ""
            done
          '';
        };
    };

    init = {
      description = "Re-apply Incus preseed + instance reconcile on cluster nodes";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-incus-init";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            echo "Re-running Incus preseed + reconcile on: ${allMembersList}"
            echo ""
            INCUS_NODES="${allMembersList}"
            for node in $INCUS_NODES; do
              ip="$(node_ip "$node")"
              echo "--- $node ($ip) ---"
              ssh_node "$node" \
                'systemctl restart incus-preseed.service 2>/dev/null && echo "  preseed re-applied" || echo "  no incus-preseed.service"; systemctl restart incus-instances-reconcile.service 2>/dev/null && echo "  instances reconciled" || echo "  no reconcile unit"' \
                || echo "  (unreachable)"
            done
          '';
        };
    };

    cluster-join = {
      description = "Join Incus cluster members to the bootstrap node (idempotent)";
      builder = { pkgs, cluster, ... }:
        let
          joinerArray = lib.concatStringsSep " " (map lib.escapeShellArg joinerNames);
        in
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-incus-cluster-join";
          runtimeInputs = with pkgs; [ openssh coreutils jq gnugrep ];
          text = ''
            set -uo pipefail
            ${sshPrelude}

            BOOTSTRAP="${toString resolvedBootstrap}"
            BOOTSTRAP_IP="${toString bootstrapIp}"
            PORT="${toString cfg.cluster.httpsPort}"
            JOINERS=(${joinerArray})

            if [ -z "$BOOTSTRAP" ]; then
              echo "incus cluster-join: no bootstrap member resolved" >&2
              exit 1
            fi
            if [ -z "$BOOTSTRAP_IP" ]; then
              echo "incus cluster-join: no install.ip for bootstrap '$BOOTSTRAP'" >&2
              exit 1
            fi

            echo "=== Incus cluster-join (bootstrap: $BOOTSTRAP @ $BOOTSTRAP_IP:$PORT) ==="

            # Current membership: first CSV column is the member name. Tolerate a
            # not-yet-clustered / unreachable bootstrap (treated as no members).
            existing="$(ssh_node "$BOOTSTRAP" 'incus cluster list --format csv 2>/dev/null' \
              | cut -d, -f1 || true)"

            rc=0
            for joiner in "''${JOINERS[@]}"; do
              jip="$(node_ip "$joiner")"
              if [ -z "$jip" ]; then
                echo "  $joiner: no install.ip, skipping" >&2
                rc=1
                continue
              fi
              if printf '%s\n' "$existing" | grep -qxF "$joiner"; then
                echo "  $joiner: already a cluster member, skipping"
                continue
              fi

              echo "  $joiner: minting single-use join token on $BOOTSTRAP"
              if ! token="$(ssh_node "$BOOTSTRAP" incus cluster add "$joiner" --quiet)"; then
                echo "  $joiner: FAILED to mint join token" >&2
                rc=1
                continue
              fi
              token="$(printf '%s' "$token" | tr -d '\r\n')"
              if [ -z "$token" ]; then
                echo "  $joiner: empty join token" >&2
                rc=1
                continue
              fi

              # Build the join preseed as JSON (valid YAML) so the token and
              # address are injected as data, never concatenated into hand-written
              # YAML. member_config is empty: a dir storage pool + NAT bridge carry
              # no per-member keys, and cluster-wide entities propagate from the
              # bootstrap on join. (Backends needing a per-member source would add
              # entries here — future work, validated on real VMs.)
              preseed="$(jq -n \
                --arg addr "$jip:$PORT" \
                --arg token "$token" \
                '{cluster:{enabled:true,server_address:$addr,cluster_token:$token,member_config:[]}}')"

              echo "  $joiner: joining via incus admin init --preseed"
              if printf '%s' "$preseed" | ssh_node "$joiner" 'incus admin init --preseed'; then
                echo "  $joiner: joined"
              else
                echo "  $joiner: FAILED to join" >&2
                rc=1
              fi
            done

            if [ "$rc" -ne 0 ]; then
              echo "incus cluster-join: one or more joiners failed" >&2
            fi
            exit "$rc"
          '';
        };
    };

    list = {
      description = "List Incus instances [--node <m>] [--json]";
      builder = { pkgs, cluster, helpers, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-incus-list";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            TABLEFMT="${lib.getExe helpers.tablefmt}"

            NODE=""
            JSON=0
            while [ $# -gt 0 ]; do
              case "$1" in
                --node) NODE="''${2:-}"; shift 2 ;;
                --json) JSON=1; shift ;;
                *) echo "Unknown flag: $1" >&2; exit 1 ;;
              esac
            done

            if [ -n "$NODE" ]; then targets="$NODE"; else targets="${allMembersList}"; fi

            for node in $targets; do
              if [ "$JSON" -eq 1 ]; then
                echo "// $node"
                ssh_node "$node" 'incus list --format json' || echo "[]"
              else
                echo "--- $node ---"
                {
                  printf 'NAME\tSTATE\tIPV4\tTYPE\tSNAPSHOTS\n'
                  ssh_node "$node" 'incus list --format csv --columns ns4tS' 2>/dev/null | tr ',' '\t' || true
                } | "$TABLEFMT"
                echo ""
              fi
            done
          '';
        };
    };

    start = {
      description = "Start an instance: <instance> [--node <m>]";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-incus-start";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            INSTANCE=""; NODE=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --node) NODE="''${2:-}"; shift 2 ;;
                *) if [ -z "$INSTANCE" ]; then INSTANCE="$1"; shift; else echo "unexpected: $1" >&2; exit 1; fi ;;
              esac
            done
            [ -z "$INSTANCE" ] && { echo "Usage: incus start <instance> [--node <m>]" >&2; exit 1; }
            [ -z "$NODE" ] && NODE="${lib.head (incusMemberNames ++ [ "" ])}"
            ssh_node "$NODE" incus start "$INSTANCE"
          '';
        };
    };

    stop = {
      description = "Stop an instance: <instance> [--node <m>]";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-incus-stop";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            INSTANCE=""; NODE=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --node) NODE="''${2:-}"; shift 2 ;;
                *) if [ -z "$INSTANCE" ]; then INSTANCE="$1"; shift; else echo "unexpected: $1" >&2; exit 1; fi ;;
              esac
            done
            [ -z "$INSTANCE" ] && { echo "Usage: incus stop <instance> [--node <m>]" >&2; exit 1; }
            [ -z "$NODE" ] && NODE="${lib.head (incusMemberNames ++ [ "" ])}"
            ssh_node "$NODE" incus stop "$INSTANCE"
          '';
        };
    };

    exec = {
      description = "Exec in an instance: <instance> [--node <m>] -- <cmd...>";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-incus-exec";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            INSTANCE=""; NODE=""
            # Parse our flags up to the `--` passthrough boundary; everything
            # after `--` goes verbatim to `incus exec` on the node (task 11).
            while [ $# -gt 0 ]; do
              case "$1" in
                --) shift; break ;;
                --node) NODE="''${2:-}"; shift 2 ;;
                *) if [ -z "$INSTANCE" ]; then INSTANCE="$1"; shift; else echo "unexpected: $1" >&2; exit 1; fi ;;
              esac
            done
            [ -z "$INSTANCE" ] && { echo "Usage: incus exec <instance> [--node <m>] -- <cmd...>" >&2; exit 1; }
            [ -z "$NODE" ] && NODE="${lib.head (incusMemberNames ++ [ "" ])}"
            [ $# -eq 0 ] && { echo "no command after --" >&2; exit 1; }
            ssh_node "$NODE" incus exec "$INSTANCE" -- "$@"
          '';
        };
    };
  };

in
{
  options.incus = {
    enable = lib.mkEnableOption "Incus virtualization support";

    # Multi-node clustering (cluster-level, NOT per-member — followup C). When
    # enabled, ALL cluster members participate (including data-only members).
    cluster = {
      enable = lib.mkEnableOption "multi-node Incus clustering across all members";

      bootstrapMember = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Member that bootstraps the Incus cluster (initialized declaratively at
          activation). All other members are joiners, joined at runtime by the
          converge `incus.cluster-join` postStep. Null resolves to the first
          member sorted by name.
        '';
      };

      httpsPort = lib.mkOption {
        type = lib.types.int;
        default = 8443;
        description = "Port for the Incus HTTPS API and cluster member addresses.";
      };

      storagePool = lib.mkOption {
        type = lib.types.str;
        default = "default";
        description = "Name of the cluster-wide default Incus storage pool.";
      };

      storageBackend = lib.mkOption {
        type = lib.types.enum [ "dir" "btrfs" "lvm" "zfs" ];
        default = "dir";
        description = "Storage driver for the cluster-wide default pool.";
      };
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = {};
      description = ''
        Declarative Incus instances for the cluster. Propagated to every node;
        each node reconciles only the instances whose `node` matches it.
        See the incus NixOS module `incus.instances` for the field shape.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Add the Incus NixOS module to ALL members; per-node activation is gated
    # by the NixOS option `incus.enable`. The full instance set is handed to
    # every node so each can reconcile the ones bound to it.
    #
    # In clustering mode, additionally activate Incus on EVERY member (data-only
    # members included) and inject the clustering role so the NixOS module can
    # pick bootstrap vs joiner. This drives membership off the cluster-level
    # `incus.cluster.enable`, never the per-member patch (followup C).
    _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
      [ incusNixosModule { incus.instances = cfg.instances; } ]
      ++ lib.optional clusterEnabled {
        incus.enable = true;
        incus.storagePool = cfg.cluster.storagePool;
        incus.storageBackend = cfg.cluster.storageBackend;
        incus.cluster = {
          enable = true;
          bootstrapMember = resolvedBootstrap;
          httpsPort = cfg.cluster.httpsPort;
        };
      }
    );

    # Expose CLI commands only when at least one node activates Incus (group `incus`).
    commandGroups.incus = lib.mkIf (incusMemberNames != []) {
      description = "Incus virtualization management";
      actions = incusCommands;
    };

    # converge postSteps:
    #  - incus.cluster-join (only when clustering): mint single-use join tokens
    #    on the bootstrap and join each joiner via `incus admin init --preseed`.
    #    Runs BEFORE reconcile (priority 65 < 70) so a joiner is already a cluster
    #    member when its declared instances reconcile; idempotent (skips members
    #    already in `incus cluster list`).
    #  - incus.reconcile (always, when there are incus nodes): re-apply the
    #    preseed + instance reconcile. Reuses the EXISTING `incus init` action.
    converge.postSteps = lib.mkMerge [
      (lib.mkIf clusterEnabled {
        "incus.cluster-join" = {
          description = "Join Incus cluster members to the bootstrap node";
          priority = 65;
          run = incusCommands.cluster-join.builder;
        };
      })
      (lib.mkIf (incusMemberNames != []) {
        "incus.reconcile" = {
          description = "Re-apply Incus preseed + instance reconcile on nodes";
          priority = 70;
          run = incusCommands.init.builder;
        };
      })
    ];
  };
}
