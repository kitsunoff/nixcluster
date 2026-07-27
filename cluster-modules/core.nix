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

  # A converge DAG step. This is the unified execution model: every converge
  # step — module steps AND the per-member install/switch — is a node in
  # `converge.steps`, ordered by its `deps`. `preSteps`/`postSteps` are sugar
  # that desugars into this attrset (see the `config` section below), so a
  # module can keep contributing phase steps without knowing about the DAG.
  #
  # Exactly one of `run` / `member` must be set:
  #   run    - a builder `{ pkgs, lib, cluster, helpers } -> package` whose
  #            executable is invoked (same shape as a command builder).
  #   member - the name of a cluster member; the step is the built-in
  #            install-or-switch for that member (converge decides which by an
  #            SSH probe). Core generates one such step per member.
  dagStepType = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Short description of what this converge step does";
      };

      run = lib.mkOption {
        type = lib.types.nullOr (lib.types.functionTo lib.types.package);
        default = null;
        description = ''
          Builder function `{ pkgs, lib, cluster, helpers } -> package` whose
          executable is invoked (no required arguments) when this step runs.
          Reuse a module's existing action builder here instead of duplicating.
          Mutually exclusive with `member`.
        '';
      };

      member = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          When set, this step is the built-in install-or-switch of the named
          cluster member instead of a `run` package. Mutually exclusive with
          `run`.
        '';
      };

      deps = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Names of steps that must succeed before this one runs. An unknown name
          or a dependency cycle is an evaluation error. At runtime a step whose
          dependency did not succeed is skipped rather than run.
        '';
      };

      phase = lib.mkOption {
        type = lib.types.str;
        default = "step";
        description = ''
          Reporting label carried into the `::nixcluster:result::` JSON
          (`pre`/`post` for desugared phase steps, `member` for member steps).
          It has no effect on ordering — `deps` alone decides that.
        '';
      };

      priority = lib.mkOption {
        type = lib.types.int;
        default = 100;
        description = "Tie-break among steps that are ready at the same time; lower runs first, ties broken by step name.";
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

  # --- converge DAG generation ------------------------------------------------
  # Core turns the declared members and the phase-step sugar into `converge.steps`
  # nodes. Everything here is `mkDefault`, so a module refining a generated step
  # (typically its `deps`) simply overrides the default.
  memberStepName = memberName: "member-${memberName}";

  # Deterministic member order: bootstrapMember (if set) leads, the rest follow
  # the explicit `order` (if set) or sorted-by-name — the historical converge order.
  sortedMemberNames = lib.sort (a: b: a < b) (lib.attrNames config.members);
  baseMemberOrder =
    if config.converge.order != [] then config.converge.order else sortedMemberNames;
  memberOrder =
    if config.converge.bootstrapMember != null
    then [ config.converge.bootstrapMember ]
      ++ lib.filter (m: m != config.converge.bootstrapMember) baseMemberOrder
    else baseMemberOrder;

  preStepNames = lib.attrNames config.converge.preSteps;
  memberStepNames = map memberStepName memberOrder;

  # Default member dependencies reproduce the historical behaviour exactly: the
  # first member waits for every preStep, and each later member waits for the
  # previous one (a strict chain). Modules that know the real contract override
  # this — the k3s module, for instance, makes agents wait for all servers
  # instead of for the member that happens to precede them.
  memberSteps = lib.listToAttrs (lib.imap0
    (i: memberName: lib.nameValuePair (memberStepName memberName) {
      member = memberName;
      description = lib.mkDefault "Install or switch member ${memberName}";
      phase = lib.mkDefault "member";
      priority = lib.mkDefault (200 + i);
      deps = lib.mkDefault (
        if i == 0
        then preStepNames
        else [ (memberStepName (lib.elemAt memberOrder (i - 1))) ]
      );
    })
    memberOrder);

  # preSteps/postSteps sugar -> DAG nodes. preSteps have no dependencies;
  # postSteps depend on every member step, which is what "after the member loop"
  # meant before the DAG existed.
  desugarSteps = phase: defaultDeps: steps: lib.mapAttrs (_name: s: {
    description = lib.mkDefault s.description;
    run = lib.mkDefault s.run;
    priority = lib.mkDefault s.priority;
    phase = lib.mkDefault phase;
    deps = lib.mkDefault defaultDeps;
  }) steps;

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
            description = "Steps run once BEFORE the per-member loop (e.g. sops.gen, nebula.gen-certs), ordered by priority then name. Sugar for `steps` entries with no dependencies.";
          };

          postSteps = lib.mkOption {
            type = lib.types.attrsOf stepType;
            default = {};
            description = "Steps run once AFTER the per-member loop (e.g. k3s.bootstrap, cozystack.bootstrap), ordered by priority then name. Sugar for `steps` entries depending on every member step.";
          };

          steps = lib.mkOption {
            type = lib.types.attrsOf dagStepType;
            default = {};
            description = ''
              The converge execution DAG. Core populates it with one
              `member-<name>` step per cluster member plus the desugared
              `preSteps`/`postSteps`; modules add their own steps and may refine
              the dependencies of generated ones (e.g. the k3s module makes
              agents depend on every server). Ordering comes from `deps` only.
            '';
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

  # Populate the converge DAG: one step per member, plus the phase-step sugar.
  config.converge.steps = lib.mkMerge [
    memberSteps
    (desugarSteps "pre" [] config.converge.preSteps)
    (desugarSteps "post" memberStepNames config.converge.postSteps)
  ];
}
