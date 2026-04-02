# Cozystack cluster extension module
# Configures NixOS for cozystack deployment on k3s
# Reference: https://cozystack.io/docs/v1/install/kubernetes/generic/
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

  # Single NixOS module for cozystack requirements
  cozystackNixosModule = { config, pkgs, lib, nix8s, ... }:
    let
      memberName = nix8s.memberName;
      member = nix8s.member;
      cluster = nix8s.cluster;
      cozyCfg = cluster.cozystack;

      # Get role from member config
      role = member.k3s.role or null;
      isServer = role == "server";
      isAgent = role == "agent";
      isK3sMember = role != null;

      cozystackFlags = if isServer then cozystackServerFlags else cozystackAgentFlags;
    in
    lib.mkIf (cozyCfg.enable && isK3sMember) {
      # Add cozystack flags to k3s extraFlags
      k3s.extraServerFlags = lib.mkIf isServer cozystackServerFlags;
      k3s.extraAgentFlags = lib.mkIf isAgent cozystackAgentFlags;

      # Required packages
      environment.systemPackages = with pkgs; [
        nfs-utils
        openiscsi
        multipath-tools
      ];

      # Required services
      services.openiscsi = {
        enable = true;
        name = "iqn.2024-01.io.cozystack:${memberName}";
      };

      services.multipath.enable = true;

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
      ];

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
    }];
  };
}
