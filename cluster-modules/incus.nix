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

  # Members that have Incus activated (via NixOS option incus.enable as a patch).
  incusMembers = lib.filterAttrs
    (name: member: member.incus.enable or false)
    config.members;

  incusMemberNames = lib.attrNames incusMembers;

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
    _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
      [ incusNixosModule { incus.instances = cfg.instances; } ]
    );

    # Expose CLI commands only when at least one node activates Incus (group `incus`).
    commandGroups.incus = lib.mkIf (incusMemberNames != []) {
      description = "Incus virtualization management";
      actions = incusCommands;
    };
  };
}
