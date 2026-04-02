# Core options for nix8s configuration
# Defines: nodes (NixOS configs), clusters (grouping + IP mapping), provisioning
{ lib, ... }:

let
  # Freeform submodule — allows any attribute, but can define specific options.
  freeformSubmodule = options: lib.types.submodule {
    freeformType = lib.types.attrsOf lib.types.anything;
    inherit options;
  };

  # CLI command type
  commandType = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = "Short description of the command";
      };

      builder = lib.mkOption {
        type = lib.types.functionTo lib.types.package;
        description = "Function that builds the command package. Receives { pkgs, lib, cluster, clusterName, nodes }";
      };
    };
  };

  # Member submodule — just IP mapping for apply
  memberSubmodule = lib.types.submodule {
    freeformType = lib.types.attrsOf lib.types.anything;

    options = {
      ip = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "IP address for nix8sctl apply (optional, can be passed as argument)";
      };
    };
  };

  # Node submodule — full NixOS configuration
  nodeSubmodule = freeformSubmodule {
    install = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Disk installation config (install.disk, install.swapSize)";
    };

    disko = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Raw disko configuration (mutually exclusive with install.disk)";
    };

    nixosModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [ ];
      description = "Custom NixOS modules to include";
    };
  };

  # Provisioning submodule (cluster-level)
  provisioningSubmodule = lib.types.submodule {
    freeformType = lib.types.attrsOf lib.types.anything;

    options = {
      nixos-anywhere = lib.mkOption {
        type = lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.anything;
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable nixos-anywhere provisioning for this cluster";
            };
          };
        };
        default = { };
        description = "nixos-anywhere provisioning config";
      };

      pxe = lib.mkOption {
        type = lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.anything;
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable PXE provisioning for this cluster";
            };
            interface = lib.mkOption {
              type = lib.types.str;
              default = "eth0";
              description = "Network interface for PXE server";
            };
            httpPort = lib.mkOption {
              type = lib.types.int;
              default = 8080;
              description = "HTTP port for PXE server";
            };
          };
        };
        default = { };
        description = "PXE provisioning config";
      };
    };
  };

  # Cluster submodule — grouping nodes + shared config
  clusterSubmodule = freeformSubmodule {
    members = lib.mkOption {
      type = lib.types.attrsOf memberSubmodule;
      default = { };
      description = "Cluster members — node names with optional IP for apply";
    };

    secrets = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Cluster secrets (sshPubKey, etc.)";
    };

    sops = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "SOPS secrets configuration (enable, secretsFile, ageKeyFile)";
    };

    provisioning = lib.mkOption {
      type = provisioningSubmodule;
      default = { };
      description = "Cluster provisioning configuration (pxe, nixos-anywhere)";
    };

    # CLI commands for this cluster
    # Using listOf allows multiple modules to contribute commands
    commands = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf commandType);
      default = [ ];
      description = "CLI commands for this cluster. List of attrsets to be merged.";
    };

    # Extensions add their own options here via freeform
  };

in
{
  options.nix8s = {
    nodes = lib.mkOption {
      type = lib.types.attrsOf nodeSubmodule;
      default = { };
      description = "NixOS node configurations";
    };

    clusters = lib.mkOption {
      type = lib.types.attrsOf clusterSubmodule;
      default = { };
      description = "Cluster definitions (grouping nodes + shared config)";
    };

    # Internal: modules contributed by extensions
    nixosModulesFor = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.deferredModule);
      default = { };
      description = "NixOS modules contributed by extensions (internal)";
    };

    # Internal: additional CLI commands contributed by extensions
    # Key is cluster name, value is list of command attrsets
    # These are merged with cluster.commands in nix8sctl
    _extensionCommands = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf (lib.types.attrsOf commandType));
      default = { };
      internal = true;
      description = "CLI commands contributed by extensions (internal). Merged with cluster.commands.";
    };
  };
}
