# Cozystack cluster extension module
# Configures NixOS for cozystack deployment on k3s
# Reference: https://cozystack.io/docs/v1/install/kubernetes/generic/
#
# Storage configuration:
#   members.node1.cozystack.storage = {
#     disks = [ "/dev/sdb" ];           # dedicated disks for LINSTOR
#     # OR
#     systemPartition.enable = true;    # use partition on system disk
#     systemPartition.size = "400G";
#   };
{ lib, config, ... }:

let
  cfg = config.cozystack;
  clusterName = config.name;

  # Get k3s members from members config (via k3s.role)
  k3sMembers = lib.filterAttrs
    (name: member: member.k3s.role or null != null)
    config.members;

  servers = lib.attrNames (lib.filterAttrs (n: m: m.k3s.role == "server") k3sMembers);
  agents = lib.attrNames (lib.filterAttrs (n: m: m.k3s.role == "agent") k3sMembers);

  # First server
  sortedServers = lib.sort (a: b: a < b) servers;
  firstServer = if sortedServers != [] then lib.head sortedServers else null;
  firstServerIp = if firstServer != null
    then config.members.${firstServer}.install.ip or null
    else null;

  # k3s server flags for cozystack
  cozystackServerFlags = [
    "--disable=traefik"
    "--disable=servicelb"
    "--disable=local-storage"
    "--disable=metrics-server"
    "--disable-network-policy"
    "--disable-kube-proxy"
    "--flannel-backend=none"
    "--cluster-domain=${cfg.clusterDomain}"
    "--kubelet-arg=max-pods=${toString cfg.maxPods}"
  ];

  # k3s agent flags for cozystack
  cozystackAgentFlags = [
    "--kubelet-arg=max-pods=${toString cfg.maxPods}"
  ];

  # Get members with storage config
  membersWithStorage = lib.filterAttrs
    (name: member:
      let storage = member.cozystack.storage or {};
      in (storage.disks or []) != [] || (storage.systemPartition.enable or false)
    )
    config.members;

  # Single NixOS module for cozystack requirements
  cozystackNixosModule = { config, pkgs, lib, nix8s, ... }:
    let
      memberName = nix8s.memberName;
      member = nix8s.member;
      cluster = nix8s.cluster;
      cozyCfg = cluster.cozystack;

      # Get role from member config (k3s is also NixOS option now)
      role = config.k3s.role or null;
      isServer = role == "server";
      isAgent = role == "agent";
      isK3sMember = role != null;

      # Storage config from NixOS options
      storageConfig = config.cozystack.storage;
      storageDisks = storageConfig.disks;
      useSystemPartition = storageConfig.systemPartition.enable;
      systemPartitionSize = storageConfig.systemPartition.size;
      poolName = storageConfig.poolName;
      poolType = storageConfig.poolType;

      hasStorage = storageDisks != [] || useSystemPartition;

      cozystackFlags = if isServer then cozystackServerFlags else cozystackAgentFlags;
    in
    {
    # Define NixOS options for cozystack storage
    options.cozystack.storage = {
      disks = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Dedicated disks for LINSTOR storage pool";
        example = [ "/dev/sdb" "/dev/nvme0n1" ];
      };

      systemPartition = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Use a partition on the system disk for LINSTOR storage";
        };

        size = lib.mkOption {
          type = lib.types.str;
          default = "400G";
          description = "Size of the LINSTOR storage partition";
        };
      };

      poolName = lib.mkOption {
        type = lib.types.str;
        default = "data";
        description = "LINSTOR storage pool name";
      };

      poolType = lib.mkOption {
        type = lib.types.enum [ "zfs" "lvm" "lvmthin" ];
        default = "zfs";
        description = "Storage pool type for LINSTOR";
      };
    };

    config = lib.mkIf (cozyCfg.enable && isK3sMember) {
      # Add cozystack flags to k3s extraFlags
      k3s.extraServerFlags = lib.mkIf isServer cozystackServerFlags;
      k3s.extraAgentFlags = lib.mkIf isAgent cozystackAgentFlags;

      # Required packages
      environment.systemPackages = with pkgs; [
        nfs-utils
        openiscsi
        multipath-tools
        zfs  # for LINSTOR ZFS pools
        lvm2  # for LINSTOR LVM pools
      ];

      # Required services
      services.openiscsi = {
        enable = true;
        name = "iqn.2024-01.io.cozystack:${memberName}";
      };

      services.multipath.enable = true;

      # ZFS support for LINSTOR
      boot.supportedFilesystems = lib.mkIf (poolType == "zfs") [ "zfs" ];
      boot.zfs.forceImportRoot = lib.mkIf (poolType == "zfs") false;

      # Sysctl configuration
      boot.kernel.sysctl = {
        "fs.inotify.max_user_watches" = 524288;
        "fs.inotify.max_user_instances" = 8192;
        "fs.inotify.max_queued_events" = 65536;
        "fs.file-max" = 2097152;
        "fs.aio-max-nr" = 1048576;
        "vm.swappiness" = 1;
      };

      # Kernel modules
      boot.kernelModules = [
        "iscsi_tcp"
        "dm_multipath"
      ] ++ lib.optionals (poolType == "zfs") [ "zfs" ];

      # Firewall
      networking.firewall = {
        allowedTCPPorts = [
          3366 3367  # LINSTOR
          4240 4244  # Cilium
          6641 6642  # KubeOVN
        ];
        allowedUDPPorts = [
          8472  # VXLAN
          6081  # Geneve
        ];
      };
    };
    };  # close NixOS module

  # Platform package YAML
  platformPackageYaml = ''
apiVersion: cozystack.io/v1alpha1
kind: Package
metadata:
  name: cozystack.cozystack-platform
spec:
  variant: ${cfg.variant}
  components:
    platform:
      values:
        publishing:
          host: "${cfg.publishing.host}"
          apiServerEndpoint: "https://${toString firstServerIp}:6443"
        networking:
          podCIDR: "${cfg.networking.podCIDR}"
          podGateway: "${cfg.networking.podGateway}"
          serviceCIDR: "${cfg.networking.serviceCIDR}"
          joinCIDR: "${cfg.networking.joinCIDR}"
  '';

in
{
  options.cozystack = {
    enable = lib.mkEnableOption "Cozystack platform";

    clusterDomain = lib.mkOption {
      type = lib.types.str;
      default = "cozy.local";
      description = "Kubernetes cluster domain";
    };

    maxPods = lib.mkOption {
      type = lib.types.int;
      default = 220;
      description = "Maximum pods per node";
    };

    variant = lib.mkOption {
      type = lib.types.enum [
        "isp-full-generic"
        "isp-full"
        "managed-k8s"
        "virtual-machines"
        "hybrid"
      ];
      default = "isp-full-generic";
      description = "Cozystack platform variant";
    };

    publishing = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "example.com";
        description = "Base domain for cozystack services";
      };
    };

    networking = {
      podCIDR = lib.mkOption {
        type = lib.types.str;
        default = "10.42.0.0/16";
        description = "Pod network CIDR (must match k3s)";
      };

      podGateway = lib.mkOption {
        type = lib.types.str;
        default = "10.42.0.1";
        description = "Pod network gateway";
      };

      serviceCIDR = lib.mkOption {
        type = lib.types.str;
        default = "10.43.0.0/16";
        description = "Service network CIDR (must match k3s)";
      };

      joinCIDR = lib.mkOption {
        type = lib.types.str;
        default = "100.64.0.0/16";
        description = "Join network CIDR for tenant clusters";
      };
    };

    version = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Cozystack version (latest if null)";
    };

    storage = {
      poolName = lib.mkOption {
        type = lib.types.str;
        default = "data";
        description = "Default LINSTOR storage pool name";
      };

      poolType = lib.mkOption {
        type = lib.types.enum [ "zfs" "lvm" "lvmthin" ];
        default = "zfs";
        description = "Storage pool type for LINSTOR";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Add cozystack NixOS module to ALL members
    _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
      [ cozystackNixosModule ]
    );

    # CLI commands
    commands = [{
      cozystack-bootstrap = {
        description = "Bootstrap cozystack on cluster";
        builder = { pkgs, cluster, ... }:
          pkgs.writeShellApplication {
            name = "nix8sctl-${clusterName}-cozystack-bootstrap";
            runtimeInputs = with pkgs; [ kubectl coreutils curl ];
            text = ''
              set -euo pipefail

              KUBECONFIG="''${KUBECONFIG:-kubeconfig/${clusterName}.yaml}"
              FIRST_SERVER="${toString firstServerIp}"

              echo "========================================"
              echo "Cozystack Bootstrap for '${clusterName}'"
              echo "========================================"
              echo ""
              echo "Cluster: ${clusterName}"
              echo "First server: $FIRST_SERVER"
              echo "Servers: ${lib.concatStringsSep ", " servers}"
              echo "Agents: ${lib.concatStringsSep ", " agents}"
              echo ""

              if [[ ! -f "$KUBECONFIG" ]]; then
                echo "ERROR: Kubeconfig not found: $KUBECONFIG"
                echo "Run: nix8sctl ${clusterName} kubeconfig fetch"
                exit 1
              fi

              export KUBECONFIG

              echo "[1/4] Checking cluster connectivity..."
              if ! kubectl cluster-info &>/dev/null; then
                echo "ERROR: Cannot connect to cluster"
                exit 1
              fi
              kubectl get nodes
              echo ""

              echo "[2/4] Applying Cozystack CRDs..."
              VERSION="${if cfg.version != null then cfg.version else "latest"}"
              if [[ "$VERSION" == "latest" ]]; then
                CRD_URL="https://github.com/cozystack/cozystack/releases/latest/download/cozystack-crds.yaml"
                OPERATOR_URL="https://github.com/cozystack/cozystack/releases/latest/download/cozystack-operator-generic.yaml"
              else
                CRD_URL="https://github.com/cozystack/cozystack/releases/download/$VERSION/cozystack-crds.yaml"
                OPERATOR_URL="https://github.com/cozystack/cozystack/releases/download/$VERSION/cozystack-operator-generic.yaml"
              fi

              kubectl apply -f "$CRD_URL"
              echo ""

              echo "[3/4] Deploying Cozystack operator..."
              curl -fsSL "$OPERATOR_URL" \
                | sed "s/REPLACE_ME/$FIRST_SERVER/" \
                | kubectl apply -f -
              echo ""

              echo "Waiting for operator to be ready..."
              kubectl wait --for=condition=Available deployment/cozystack-operator \
                -n cozy-system --timeout=300s || true
              echo ""

              echo "[4/4] Creating Platform Package..."
              kubectl apply -f - <<'PLATFORM_EOF'
${platformPackageYaml}
PLATFORM_EOF
              echo ""

              echo "========================================"
              echo "Cozystack bootstrap initiated!"
              echo "========================================"
              echo ""
              echo "Monitor progress:"
              echo "  kubectl logs -n cozy-system deploy/cozystack-operator -f"
              echo "  kubectl get hr -A"
              echo "  kubectl get pods -A"
              echo ""
              echo "Dashboard will be available at:"
              echo "  https://${cfg.publishing.host}"
            '';
          };
      };

      cozystack-status = {
        description = "Show cozystack status";
        builder = { pkgs, cluster, ... }:
          pkgs.writeShellApplication {
            name = "nix8sctl-${clusterName}-cozystack-status";
            runtimeInputs = with pkgs; [ kubectl ];
            text = ''
              KUBECONFIG="''${KUBECONFIG:-kubeconfig/${clusterName}.yaml}"
              export KUBECONFIG

              echo "=== Cozystack Status ==="
              echo ""

              echo "--- Nodes ---"
              kubectl get nodes -o wide
              echo ""

              echo "--- Helm Releases ---"
              kubectl get hr -A 2>/dev/null || echo "No HelmReleases found"
              echo ""

              echo "--- Cozy System Pods ---"
              kubectl get pods -n cozy-system 2>/dev/null || echo "cozy-system namespace not found"
              echo ""

              echo "--- Packages ---"
              kubectl get packages -A 2>/dev/null || echo "No packages found"
            '';
          };
      };

      cozystack-init-storage = {
        description = "Initialize LINSTOR storage pools on nodes";
        builder = { pkgs, cluster, ... }:
          let
            # Build storage info for each member
            storageInfo = lib.mapAttrs (name: member:
              let
                storage = member.cozystack.storage or {};
                disks = storage.disks or [];
                systemPartition = storage.systemPartition or {};
                useSystemPartition = systemPartition.enable or false;
                partitionSize = systemPartition.size or "400G";
                poolName = storage.poolName or cfg.storage.poolName;
                poolType = storage.poolType or cfg.storage.poolType;
              in {
                inherit name disks useSystemPartition partitionSize poolName poolType;
                ip = member.install.ip or null;
                systemDisk = member.install.disk or "/dev/sda";
              }
            ) membersWithStorage;

            # Generate initialization script for a member
            mkInitScript = name: info: ''
              echo ""
              echo "=== Initializing storage on ${name} (${info.ip or "no-ip"}) ==="
              ${if info.disks != [] then ''
              echo "Mode: Dedicated disks"
              echo "Disks: ${lib.concatStringsSep " " info.disks}"
              echo "Pool: ${info.poolName} (${info.poolType})"
              echo ""

              # Check if pool already exists
              if linstor storage-pool list --node ${clusterName}-${name} | grep -q "${info.poolName}"; then
                echo "Storage pool '${info.poolName}' already exists on ${name}, skipping..."
              else
                echo "Creating ${info.poolType} storage pool..."
                linstor physical-storage create-device-pool \
                  ${info.poolType} ${clusterName}-${name} \
                  ${lib.concatStringsSep " " info.disks} \
                  --pool-name ${info.poolName} \
                  --storage-pool ${info.poolName}
                echo "Done."
              fi
              '' else if info.useSystemPartition then ''
              echo "Mode: System disk partition"
              echo "System disk: ${info.systemDisk}"
              echo "Partition size: ${info.partitionSize}"
              echo "Pool: ${info.poolName} (${info.poolType})"
              echo ""
              echo "WARNING: System partition mode requires manual setup:"
              echo "  1. SSH to ${name}: ssh root@${info.ip or "IP"}"
              echo "  2. Create partition on ${info.systemDisk} with size ${info.partitionSize}"
              echo "  3. Note the partition device (e.g., ${info.systemDisk}p6 or ${info.systemDisk}6)"
              echo "  4. Wipe the partition: wipefs -a /dev/<partition>"
              echo "  5. Add to LINSTOR:"
              echo "     linstor ps cdp ${info.poolType} ${clusterName}-${name} /dev/<partition> \\"
              echo "       --pool-name ${info.poolName} --storage-pool ${info.poolName}"
              '' else ''
              echo "No storage configuration for ${name}"
              ''}
            '';

          in
          pkgs.writeShellApplication {
            name = "nix8sctl-${clusterName}-cozystack-init-storage";
            runtimeInputs = with pkgs; [ kubectl ];
            text = ''
              set -euo pipefail

              KUBECONFIG="''${KUBECONFIG:-kubeconfig/${clusterName}.yaml}"
              export KUBECONFIG

              echo "========================================"
              echo "LINSTOR Storage Initialization"
              echo "Cluster: ${clusterName}"
              echo "========================================"
              echo ""

              # Check LINSTOR controller is running
              echo "Checking LINSTOR controller..."
              if ! kubectl get pods -n cozy-linstor -l app=linstor-controller 2>/dev/null | grep -q Running; then
                echo "ERROR: LINSTOR controller is not running"
                echo "Make sure cozystack is bootstrapped first:"
                echo "  nix8sctl ${clusterName} cozystack-bootstrap"
                exit 1
              fi

              # Get LINSTOR controller pod
              LINSTOR_POD=$(kubectl get pods -n cozy-linstor -l app=linstor-controller -o jsonpath='{.items[0].metadata.name}')
              echo "LINSTOR controller pod: $LINSTOR_POD"
              echo ""

              # Function to run linstor commands
              linstor() {
                kubectl exec -n cozy-linstor "$LINSTOR_POD" -- linstor "$@"
              }

              echo "Current storage pools:"
              linstor storage-pool list || true
              echo ""

              echo "Available physical storage:"
              linstor physical-storage list || true
              echo ""

              ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkInitScript storageInfo)}

              echo ""
              echo "========================================"
              echo "Storage initialization complete"
              echo "========================================"
              echo ""
              echo "Verify with:"
              echo "  kubectl exec -n cozy-linstor $LINSTOR_POD -- linstor storage-pool list"
            '';
          };
      };
    }];
  };
}
