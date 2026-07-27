# Core cluster module - defines base options for all clusters
{ lib, config, ... }:

let
  # CLI command type. A command builder receives { pkgs, lib, cluster, helpers }
  # and returns a package. `helpers` exposes shared utilities (e.g. table renderer).
  commandType = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = "Short description of the command";
      };

      builder = lib.mkOption {
        type = lib.types.functionTo lib.types.package;
        description = "Function that builds the command. Receives { pkgs, lib, cluster, helpers }";
      };
    };
  };

  # A converge step. Modules contribute steps into the cluster-level
  # `converge.preSteps` / `converge.postSteps` attrsets; the `converge` command
  # runs them around the per-member install/switch loop (see mkClusterCli).
  #
  # A step's `run` is the SAME shape as a command `builder`
  # (`{ pkgs, lib, cluster, helpers } -> package`), so a module reuses its
  # existing action builder verbatim as a step (no duplicated logic). Steps are
  # ordered deterministically by `priority` (ascending) then step name.
  stepType = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = "Short description of what this converge step does";
      };

      run = lib.mkOption {
        type = lib.types.functionTo lib.types.package;
        description = ''
          Builder function `{ pkgs, lib, cluster, helpers } -> package` whose
          executable is invoked (no required arguments) when this step runs.
          Reuse a module's existing action builder here instead of duplicating.
        '';
      };

      priority = lib.mkOption {
        type = lib.types.int;
        default = 100;
        description = "Ordering key within its phase; lower runs first, ties broken by step name.";
      };
    };
  };

  # A namespaced group of commands contributed by a module, e.g. the `incus`
  # group with actions `status`/`list`/`exec`. Groups are merged by the module
  # system across modules, so action collisions surface as evaluation errors
  # instead of being silently overwritten (the old flat foldl' model).
  groupType = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Short description of the command group";
      };

      actions = lib.mkOption {
        type = lib.types.attrsOf commandType;
        default = {};
        description = "Actions within this command group";
      };
    };
  };

  # Member submodule - nixosConfiguration + patches + install options
  memberModule = lib.types.submodule ({ name, config, ... }: {
    # Freeform allows any NixOS options as patches
    freeformType = lib.types.attrsOf lib.types.anything;

    options = {
      nixosConfiguration = lib.mkOption {
        type = lib.types.raw;
        default = null;
        description = ''
          Base NixOS configuration to extend. Optional: when unset (e.g. for
          members injected as pure JSON data), the cluster-level
          defaultNixosConfiguration is used instead.
        '';
      };

      install = lib.mkOption {
        type = lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.anything;
          options = {
            ip = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "IP address for deployment";
            };
          };
        };
        default = {};
        description = "Installation/deployment options";
      };
    };
  });

in
{
  options = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Cluster name";
    };

    members = lib.mkOption {
      type = lib.types.attrsOf memberModule;
      default = {};
      description = "Cluster members";
    };

    # Cluster-wide default base NixOS configuration. Members that do not set
    # their own `nixosConfiguration` inherit this. Enables members supplied as
    # pure JSON data (which cannot carry a Nix value/function) to still resolve
    # to a working nixosConfiguration.
    defaultNixosConfiguration = lib.mkOption {
      type = lib.types.raw;
      default = null;
      description = "Cluster-wide default base NixOS configuration; members inherit this when they do not set their own nixosConfiguration.";
    };

    # Top-level (core) CLI commands: nixclusterctl <cluster> <command> [args].
    # Reserved for non-module commands (apply/install/gen-config). Merged by name.
    commands = lib.mkOption {
      type = lib.types.attrsOf commandType;
      default = {};
      description = "Top-level CLI commands for nixclusterctl";
    };

    # Namespaced module command groups: nixclusterctl <cluster> <group> <action>.
    # Modules contribute via commandGroups.<group>.actions.<action>.
    commandGroups = lib.mkOption {
      type = lib.types.attrsOf groupType;
      default = {};
      description = "Namespaced CLI command groups for nixclusterctl";
    };

    # Convergence orchestration (the `converge` top-level command). Cluster
    # modules contribute pre/post steps; the command runs preSteps once, then
    # installs/switches every member (bootstrap first), then runs postSteps once.
    converge = lib.mkOption {
      type = lib.types.submodule {
        options = {
          bootstrapMember = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Member converged first (e.g. the k3s/incus bootstrap node). When
              set it leads the order; the remaining members follow in `order`
              (if set) or sorted-by-name.
            '';
          };

          order = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = ''
              Explicit member convergence order. Empty means sorted-by-name.
              `bootstrapMember`, when set, is always moved to the front.
            '';
          };

          preSteps = lib.mkOption {
            type = lib.types.attrsOf stepType;
            default = {};
            description = "Steps run once BEFORE the per-member loop (e.g. sops.gen, nebula.gen-certs), ordered by priority then name.";
          };

          postSteps = lib.mkOption {
            type = lib.types.attrsOf stepType;
            default = {};
            description = "Steps run once AFTER the per-member loop (e.g. k3s.bootstrap, cozystack.bootstrap), ordered by priority then name.";
          };
        };
      };
      default = {};
      description = "Convergence orchestration for the `converge` command.";
    };

    # Internal: flake inputs, threaded in by mkCluster so cluster modules can
    # reference inputs.<name> (e.g. pxe installer needs inputs.disko).
    _inputs = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      internal = true;
      description = "Flake inputs, provided by mkCluster";
    };

    # Internal: NixOS modules generated by extensions (per member)
    _generatedNixosModules = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.deferredModule);
      default = {};
      internal = true;
      description = "NixOS modules generated by extensions";
    };
  };
}
