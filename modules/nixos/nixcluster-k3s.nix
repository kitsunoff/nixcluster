# NixOS module for k3s configuration
# Receives cluster context via nixcluster module args
{ config, options, lib, pkgs, nixcluster, ... }:

let
  cfg = config.k3s;
  cluster = nixcluster.cluster;
  memberName = nixcluster.memberName;

  # Whether the cluster uses sops; if so, the join token is consumed from a
  # runtime path (/run/secrets) rather than being placed in the nix store (I2).
  sopsEnabled = cluster.sops.enable or false;

  # Get all servers from cluster members
  allMembers = cluster.members;
  servers = lib.filterAttrs (n: m: m.k3s.role or null == "server") allMembers;
  serverNames = lib.attrNames servers;

  # First server for cluster-init
  sortedServers = lib.sort (a: b: a < b) serverNames;
  firstServer = if sortedServers != [] then lib.head sortedServers else null;
  isFirst = memberName == firstServer;

  # Get first server IP for joining
  firstServerIp = if firstServer != null
    then allMembers.${firstServer}.install.ip or "127.0.0.1"
    else "127.0.0.1";

  # Member IP
  memberIp = allMembers.${memberName}.install.ip or "127.0.0.1";

  # Build flags
  baseFlags = [ "--node-ip=${memberIp}" ];

  serverFlags = baseFlags
    ++ (lib.optionals isFirst [ "--cluster-init" ])
    ++ cfg.extraServerFlags;

  agentFlags = baseFlags ++ cfg.extraAgentFlags;

  isServer = cfg.role == "server";

  # A k3s server auto-deploys any manifest under
  # /var/lib/rancher/k3s/server/manifests (services.k3s.manifests). Helm
  # releases and kustomizations are rendered into that same channel.

  # Helm release -> HelmChart CRD (helm.cattle.io/v1), handled by the bundled
  # helm-controller. Pin `version` (and image digests inside values) per B6.
  mkHelmManifest = name: hc: {
    enable = true;
    target = "helm-${name}.yaml";
    content = {
      apiVersion = "helm.cattle.io/v1";
      kind = "HelmChart";
      metadata = { inherit name; namespace = "kube-system"; };
      spec = {
        chart = hc.chart;
        targetNamespace = hc.targetNamespace;
      }
      // lib.optionalAttrs (hc.repo != null) { repo = hc.repo; }
      // lib.optionalAttrs (hc.version != null) { version = hc.version; }
      // lib.optionalAttrs (hc.createNamespace) { createNamespace = true; }
      // lib.optionalAttrs (hc.valuesContent != null) { valuesContent = hc.valuesContent; }
      // lib.optionalAttrs (hc.set != {}) { set = hc.set; };
    };
  };

  # Kustomization dir -> rendered manifest at build time (pkgs.kustomize).
  mkKustomizeManifest = name: dir: {
    enable = true;
    target = "kustomize-${name}.yaml";
    source = pkgs.runCommand "kustomize-${name}.yaml"
      { nativeBuildInputs = [ pkgs.kustomize ]; }
      "kustomize build ${dir} > $out";
  };

in
{
  options.k3s = {
    role = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "server" "agent" ]);
      default = null;
      description = "k3s role for this node (server or agent)";
    };

    extraServerFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra flags for k3s server";
    };

    extraAgentFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra flags for k3s agent";
    };

    # Declarative addons (server-scoped). Applied only on members with
    # role = "server"; k3s auto-deploys them via its manifests directory.
    manifests = lib.mkOption {
      default = {};
      description = ''
        Raw Kubernetes manifests auto-deployed on k3s servers. Provide inline
        objects via `content` (a k8s object attrset or a list of them) or a
        file via `source`. Secrets must NOT be inlined here — the manifest is
        rendered into the nix store (invariant I2); reference cluster secrets
        through sops/`/run/secrets` instead.
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to deploy this manifest.";
          };
          content = lib.mkOption {
            type = lib.types.nullOr (lib.types.either lib.types.attrs (lib.types.listOf lib.types.attrs));
            default = null;
            description = "Inline Kubernetes object(s) as Nix attrs.";
          };
          source = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "A YAML manifest file to deploy.";
          };
          target = lib.mkOption {
            type = lib.types.str;
            default = "${name}.yaml";
            description = "Filename written into the k3s manifests directory.";
          };
        };
      }));
    };

    helmCharts = lib.mkOption {
      default = {};
      description = ''
        Helm releases deployed on k3s servers via HelmChart CRDs
        (helm.cattle.io, handled by the bundled helm-controller). Pin `version`
        and image digests in values for a reproducible supply chain (B6).
        Secrets in values come from sops/`/run/secrets`, never inlined (I2).
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          chart = lib.mkOption {
            type = lib.types.str;
            description = "Chart name (in `repo`) or a full chart URL/OCI ref.";
          };
          repo = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Helm repository URL (omit for a full chart URL/OCI ref).";
          };
          version = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Pinned chart version (strongly recommended, B6).";
          };
          targetNamespace = lib.mkOption {
            type = lib.types.str;
            default = "default";
            description = "Namespace to install the release into.";
          };
          createNamespace = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Create targetNamespace if missing.";
          };
          valuesContent = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Inline values.yaml content (no secrets — I2).";
          };
          set = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = "Simple --set style overrides.";
          };
        };
      });
    };

    kustomizations = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      description = ''
        Kustomization directories rendered with kustomize at build time and
        deployed on k3s servers. Keyed by name. Remote bases need network and
        may not build in a sandbox — prefer vendored/local bases.
      '';
    };
  };

  config = lib.mkIf (cfg.role != null) (lib.mkMerge [
   {
    services.k3s = {
      enable = true;
      role = cfg.role;

      serverAddr = lib.mkIf (!isFirst && cfg.role == "agent" || !isFirst && cfg.role == "server")
        "https://${firstServerIp}:6443";

      # Shared cluster join token from sops (runtime path, never a value in the
      # store) so HA servers and agents can join. Fixes the verify-notes finding
      # that the generated k3s token was never consumed.
      tokenFile = lib.mkIf sopsEnabled config.sops.secrets."k3s/token".path;

      extraFlags = lib.mkDefault (lib.concatStringsSep " " (
        if cfg.role == "server" then serverFlags else agentFlags
      ));

      # Declarative addons, server-scoped (k3s auto-deploys these).
      manifests = lib.mkIf isServer (
        (lib.mapAttrs (_: m: { inherit (m) enable content source target; }) cfg.manifests)
        // (lib.mapAttrs mkHelmManifest cfg.helmCharts)
        // (lib.mapAttrs' (n: dir: lib.nameValuePair "kustomize-${n}" (mkKustomizeManifest n dir)) cfg.kustomizations)
      );
    };


    networking.firewall = {
      allowedTCPPorts = [ 6443 2379 2380 10250 ];
      trustedInterfaces = [ "cni0" "flannel.1" ];
    };

    swapDevices = lib.mkForce [];

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
    };

    boot.kernelModules = [ "br_netfilter" "overlay" ];
   }

   # Declare the sops secret consumed above (sops-nix decrypts it to
   # /run/secrets/k3s/token on activation). Guarded by option presence: a cluster
   # that does not use sops must not be forced to import sops-nix just to get k3s,
   # and merely *defining* `sops.secrets` — even under an mkIf that is false —
   # requires the option to exist.
   (lib.optionalAttrs (options ? sops) {
     sops.secrets = lib.mkIf sopsEnabled {
       "k3s/token" = { };
     };
   })
  ]);
}
