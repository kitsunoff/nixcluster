# keepalived cluster extension module.
# Declarative VRRP (virtual IPs) across cluster nodes, with the auth password
# delivered via sops and rendered into keepalived.conf at RUNTIME (never the
# nix store — invariant I4). See modules/nixos/nixcluster-keepalived.nix.
#
# Usage:
#   imports = [ nixcluster.clusterModules.keepalived nixcluster.clusterModules.sops ];
#   keepalived.enable = true;
#   keepalived.instances.web = {
#     vip = "192.168.1.100";
#     interface = "eth0";
#     nodes = [ "node1" "node2" ];   # first node is MASTER, rest BACKUP
#     virtualRouterId = 51;          # unique per instance
#   };
{ lib, config, options, ... }:

let
  cfg = config.keepalived;
  clusterName = config.name;

  keepalivedNixosModule = ../modules/nixos/nixcluster-keepalived.nix;

  instances = cfg.instances;

  instanceType = lib.types.submodule {
    options = {
      vip = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Primary virtual IP to hold (convenience for a single VIP).";
      };
      vips = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional virtual IPs for this instance.";
      };
      interface = lib.mkOption {
        type = lib.types.str;
        default = "eth0";
        description = "Network interface VRRP runs on.";
      };
      nodes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Member nodes participating; the first is MASTER, the rest BACKUP.";
      };
      virtualRouterId = lib.mkOption {
        type = lib.types.ints.between 1 255;
        description = "VRRP virtual_router_id, unique per instance on the segment.";
      };
      advertInt = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "VRRP advertisement interval (seconds).";
      };
    };
  };

  # Members participating in at least one instance.
  participatingMembers = lib.unique
    (lib.concatMap (i: i.nodes) (lib.attrValues instances));

  # Shell prelude (pinned known_hosts, B3 runtime) — matches incus/nebula.
  nodeIpCases = lib.concatStringsSep "\n        " (lib.mapAttrsToList
    (name: member: ''${name}) echo "${member.install.ip or ""}" ;;'')
    config.members);

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

  # "instance node vip" rows known at eval, for the status matrix.
  statusRows = lib.concatStringsSep "\n" (lib.concatLists (lib.mapAttrsToList
    (name: i:
      let vips = (lib.optional (i.vip != null) i.vip) ++ i.vips; in
      lib.concatMap (node:
        map (vip: ''check_row "${name}" "${node}" "${vip}"'') vips) i.nodes)
    instances));

  keepalivedCommands = {
    status = {
      description = "Show VRRP VIP ownership across nodes (table)";
      builder = { pkgs, cluster, helpers, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-keepalived-status";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            TABLEFMT="${lib.getExe helpers.tablefmt}"

            check_row() {
              local inst="$1" node="$2" vip="$3"
              local holds active bareip
              bareip="''${vip%%/*}"
              if ssh_node "$node" "ip -o addr show | grep -qw $bareip" 2>/dev/null; then holds=yes; else holds=no; fi
              if ssh_node "$node" "systemctl is-active keepalived" >/dev/null 2>&1; then active=active; else active=inactive; fi
              printf '%s\t%s\t%s\t%s\t%s\n' "$inst" "$node" "$vip" "$holds" "$active"
            }

            {
              printf 'INSTANCE\tNODE\tVIP\tHOLDS\tKEEPALIVED\n'
              ${statusRows}
            } | "$TABLEFMT"
          '';
        };
    };
  };

in
{
  options.keepalived = {
    enable = lib.mkEnableOption "keepalived VRRP (virtual IPs)";

    instances = lib.mkOption {
      type = lib.types.attrsOf instanceType;
      default = {};
      description = "VRRP instances; each holds a VIP across a set of nodes.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # Add the keepalived NixOS module to all members; it self-activates only on
      # members that participate in an instance.
      _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
        [ keepalivedNixosModule ]
      );

      commandGroups.keepalived = lib.mkIf (participatingMembers != []) {
        description = "keepalived VRRP management";
        actions = keepalivedCommands;
      };

      # No converge step: keepalived needs no runtime orchestration. Its VRRP
      # auth password is delivered via the sops provider (below) and applied by
      # sops.gen (a converge preStep), and its VIPs are brought up by the
      # keepalived service at NixOS switch. Nothing to run between members.
    }

    # Register the keepalived secret provider (VRRP auth_pass per instance) when
    # sops is in use. Guarded by option presence so keepalived works without sops.
    (lib.optionalAttrs (options ? sops) {
      sops.providers.keepalived.generate = { ... }:
        lib.mapAttrs'
          (name: _: lib.nameValuePair "keepalived/${name}/authPass"
            # VRRP auth_pass is truncated to 8 bytes by keepalived; keep it short.
            "head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 8")
          instances;
    })
  ]);
}
