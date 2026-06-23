# NixOS module for Incus configuration
# Receives cluster context via nixcluster module args.
#
# Enables the Incus daemon and performs a declarative, idempotent
# initialization (network bridge + storage pool + default profile) via the
# upstream `virtualisation.incus.preseed` option, which runs
# `incus admin init --preseed` on activation.
#
# Instance reconciliation (Part A of task 05): preseed is ADDITIVE and never
# touches instances, so a per-node oneshot unit reconciles the declared
# `incus.instances` whose `node` == this member. Delivery model: the declarative
# spec rides the normal nixos-rebuild closure (no secrets in it — I2); the image
# is pulled on the node by `incus launch`. Instances carrying their own NixOS
# config delivered via `nix copy` are a future extension (B5).
{ config, lib, pkgs, nixcluster ? null, ... }:

let
  cfg = config.incus;

  thisMember = if nixcluster != null then nixcluster.memberName else null;
  clusterName = if nixcluster != null then nixcluster.clusterName else "nixcluster";

  # Instances bound to THIS node.
  thisInstances = lib.filterAttrs (_: i: i.node == thisMember) cfg.instances;

  # Declarative spec for this node (store path, no secrets — I2).
  specList = lib.mapAttrsToList
    (name: i: {
      inherit name;
      inherit (i) type image autoStart profiles config devices;
    })
    thisInstances;
  specFile = pkgs.writeText "incus-instances-${clusterName}.json"
    (builtins.toJSON specList);

  instanceType = lib.types.submodule {
    options = {
      node = lib.mkOption {
        type = lib.types.str;
        description = "Cluster member (node) that hosts this instance.";
      };
      type = lib.mkOption {
        type = lib.types.enum [ "container" "virtual-machine" ];
        default = "container";
        description = "Incus instance type.";
      };
      image = lib.mkOption {
        type = lib.types.str;
        example = "images:debian/12";
        description = "Incus image reference (pulled on the node).";
      };
      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Start the instance on boot (boot.autostart).";
      };
      profiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "default" ];
        description = "Incus profiles applied to the instance.";
      };
      config = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Incus instance config keys (NO secrets inline — I2; use sops/run-secrets).";
      };
      devices = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
        default = {};
        description = "Incus devices: <device> = { type = \"...\"; <prop> = \"...\"; }.";
      };
    };
  };
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

    instances = lib.mkOption {
      type = lib.types.attrsOf instanceType;
      default = {};
      description = ''
        Declarative Incus instances. Each instance is reconciled on the node
        named by its `node` field (preseed cannot manage instances). Example:
          incus.instances.web = {
            node = "node-04"; type = "container"; image = "images:debian/12";
            autoStart = true; profiles = [ "default" ];
          };
      '';
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

    # Reconcile declarative instances bound to this node (Part A). Only runs
    # when this node actually hosts at least one declared instance.
    systemd.services.incus-instances-reconcile = lib.mkIf (thisInstances != {}) {
      description = "Reconcile declarative Incus instances for this node";
      after = [ "incus.service" "incus-preseed.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "incus.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ incus jq coreutils gnugrep ];
      script = ''
        set -euo pipefail
        SPEC="${specFile}"
        CLUSTER="${clusterName}"

        # Wait for the daemon to be ready.
        for _ in $(seq 1 30); do incus info >/dev/null 2>&1 && break; sleep 2; done

        declared="$(jq -r '.[].name' "$SPEC")"

        jq -c '.[]' "$SPEC" | while read -r inst; do
          name="$(jq -r '.name' <<<"$inst")"
          image="$(jq -r '.image' <<<"$inst")"
          itype="$(jq -r '.type' <<<"$inst")"
          autostart="$(jq -r '.autoStart' <<<"$inst")"

          if ! incus info "$name" >/dev/null 2>&1; then
            echo "incus-reconcile: launching $name ($image, $itype)"
            profile_args=()
            while read -r p; do [ -n "$p" ] && profile_args+=(--profile "$p"); done \
              < <(jq -r '.profiles[]?' <<<"$inst")
            vm_flag=()
            [ "$itype" = "virtual-machine" ] && vm_flag=(--vm)
            incus launch "$image" "$name" "''${vm_flag[@]}" "''${profile_args[@]}"
          else
            echo "incus-reconcile: $name exists, updating"
          fi

          # Tag as managed so deletion is bounded to our instances.
          incus config set "$name" user.nixcluster "$CLUSTER"

          # Apply instance config keys.
          while read -r kv; do
            k="$(jq -r '.key' <<<"$kv")"; v="$(jq -r '.value' <<<"$kv")"
            incus config set "$name" "$k" "$v"
          done < <(jq -c '.config | to_entries[]?' <<<"$inst")

          # Apply devices (remove + re-add to converge).
          while read -r dev; do
            dname="$(jq -r '.key' <<<"$dev")"
            dtype="$(jq -r '.value.type' <<<"$dev")"
            incus config device remove "$name" "$dname" >/dev/null 2>&1 || true
            props=()
            while read -r p; do props+=("$p"); done \
              < <(jq -r '.value | to_entries[] | select(.key!="type") | "\(.key)=\(.value)"' <<<"$dev")
            incus config device add "$name" "$dname" "$dtype" "''${props[@]}"
          done < <(jq -c '.devices | to_entries[]?' <<<"$inst")

          incus config set "$name" boot.autostart "$autostart"
        done

        # Delete instances we manage (tagged) that are no longer declared.
        while read -r m; do
          [ -z "$m" ] && continue
          tag="$(incus config get "$m" user.nixcluster 2>/dev/null || true)"
          [ "$tag" = "$CLUSTER" ] || continue
          if ! grep -qxF "$m" <<<"$declared"; then
            echo "incus-reconcile: deleting undeclared $m"
            incus delete --force "$m"
          fi
        done < <(incus list --format csv -c n 2>/dev/null || true)
      '';
    };
  };
}
