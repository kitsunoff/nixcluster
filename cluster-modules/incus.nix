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
#     # optional per-node tuning:
#     incus.storageBackend = "zfs";
#     incus.storageSource = "/dev/sdb";
#   };
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

  # CLI commands
  incusCommands = {
    incus-status = {
      description = "Show Incus status on cluster nodes";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-incus-status";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            echo "=== Incus status for cluster '${clusterName}' ==="
            echo "Incus nodes: ${lib.concatStringsSep " " incusMemberNames}"
            echo ""
            ${lib.concatMapStringsSep "\n" (name:
              let ip = config.members.${name}.install.ip or null; in
              if ip == null then ''echo "--- ${name}: no install.ip configured ---"''
              else ''
                echo "--- ${name} (${ip}) ---"
                ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@${ip}" \
                  'incus version 2>/dev/null && echo "-- instances --" && incus list 2>/dev/null && echo "-- storage --" && incus storage list 2>/dev/null' \
                  || echo "  (unreachable or Incus not ready)"
                echo ""
              ''
            ) incusMemberNames}
          '';
        };
    };

    incus-init = {
      description = "Re-apply Incus preseed (idempotent) on cluster nodes";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-incus-init";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            echo "Re-running Incus preseed (idempotent) on: ${lib.concatStringsSep " " incusMemberNames}"
            echo ""
            ${lib.concatMapStringsSep "\n" (name:
              let ip = config.members.${name}.install.ip or null; in
              if ip == null then ''echo "--- ${name}: no install.ip configured, skipping ---"''
              else ''
                echo "--- ${name} (${ip}) ---"
                # The NixOS activation already applies the preseed; this restarts
                # the preseed unit so a changed spec is re-reconciled without a rebuild.
                ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@${ip}" \
                  'systemctl restart incus-preseed.service 2>/dev/null && echo "  preseed re-applied" || echo "  could not restart incus-preseed.service"' \
                  || echo "  (unreachable)"
              ''
            ) incusMemberNames}
          '';
        };
    };
  };

in
{
  options.incus = {
    enable = lib.mkEnableOption "Incus virtualization support";
  };

  config = lib.mkIf cfg.enable {
    # Add the Incus NixOS module to ALL members; per-node activation is gated
    # by the NixOS option `incus.enable` (set as a member patch).
    _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
      [ incusNixosModule ]
    );

    # Expose CLI commands only when at least one node activates Incus.
    commands = lib.mkIf (incusMemberNames != []) [ incusCommands ];
  };
}
