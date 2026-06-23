# NixOS module for Incus configuration
# Receives cluster context via nixcluster module args.
#
# Enables the Incus daemon and performs a declarative, idempotent
# initialization (network bridge + storage pool + default profile) via the
# upstream `virtualisation.incus.preseed` option, which runs
# `incus admin init --preseed` on activation.
{ config, lib, pkgs, ... }:

let
  cfg = config.incus;
in
{
  options.incus = {
    enable = lib.mkEnableOption "Incus on this node";

    bridgeName = lib.mkOption {
      type = lib.types.str;
      default = "incusbr0";
      description = "Name of the managed Incus network bridge";
    };

    bridgeAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.1/24";
      description = "IPv4 address/CIDR for the managed bridge (NAT to the host network)";
    };

    storagePool = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "Name of the default Incus storage pool";
    };

    storageBackend = lib.mkOption {
      type = lib.types.enum [ "dir" "btrfs" "lvm" "zfs" ];
      default = "dir";
      description = "Storage driver for the default pool";
    };

    storageSource = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional source (block device / dataset) for the storage pool. Null = let Incus manage it (loop/dir).";
    };

    uiEnable = lib.mkEnableOption "the Incus web UI";

    preseed = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Extra preseed merged over the generated default (networks/storage_pools/profiles).";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.incus = {
      enable = true;
      ui.enable = cfg.uiEnable;

      # Declarative, idempotent init. `incus admin init --preseed` is applied
      # on activation and reconciles the existing state to this spec.
      preseed = lib.recursiveUpdate {
        networks = [{
          name = cfg.bridgeName;
          type = "bridge";
          config = {
            "ipv4.address" = cfg.bridgeAddress;
            "ipv4.nat" = "true";
            "ipv6.address" = "none";
          };
        }];

        storage_pools = [({
          name = cfg.storagePool;
          driver = cfg.storageBackend;
        } // lib.optionalAttrs (cfg.storageSource != null) {
          config.source = cfg.storageSource;
        })];

        profiles = [{
          name = "default";
          devices = {
            eth0 = {
              name = "eth0";
              network = cfg.bridgeName;
              type = "nic";
            };
            root = {
              path = "/";
              pool = cfg.storagePool;
              type = "disk";
            };
          };
        }];
      } cfg.preseed;
    };

    # Incus client/tooling on the node and kernel bits for containers.
    environment.systemPackages = with pkgs; [ incus ];

    # Required for container/VM networking and nesting.
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = lib.mkDefault 1;
      "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
    };

    networking.firewall.trustedInterfaces = [ cfg.bridgeName ];
  };
}
