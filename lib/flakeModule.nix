# flakeModule - flake-parts module exposing the declarative `nixcluster` option.
#
# A downstream flake imports this (inputs.nixcluster.flakeModules.default) and
# then declares clusters as flake-parts options:
#
#   nixcluster.prod = { clusterModules, self, ... }: {
#     imports = [ clusterModules.k3s clusterModules.incus ];
#     members.node1 = {
#       nixosConfiguration = self.nixosConfigurations.base;
#       install.ip = "10.0.0.1";
#       k3s.role = "server";
#     };
#   };
#
# Pipeline (see [[01-flake-parts-nixcluster-module]]):
#   nixcluster.<cluster>  (INPUT, merged across ./modules files)
#     -> evaluated as a cluster module (core + explicitly imported clusterModules)
#     -> clusterConfigurations.<cluster>  (OUTPUT: config + nixosConfigurations + cli)
#
# Built-in cluster modules and any downstream custom ones (written to the
# top-level `clusterModules` output, e.g. by import-tree over ./modules) are
# both offered to cluster definitions via the `clusterModules` module argument;
# nothing is auto-applied — the user imports explicitly (A3/A5).
{ lib, mkClusterOutputs, mkPerSystemOutputs, coreModule, builtinClusterModules }:

# flake-parts top-level module. `self`/`inputs` here are the DOWNSTREAM flake's.
{ config, self, inputs, ... }:

let
  # clusterModules offered to cluster definitions = built-in + downstream custom.
  clusterModules = builtinClusterModules // (config.flake.clusterModules or {});

  # INPUT -> evaluated -> OUTPUT, per cluster.
  built = lib.mapAttrs
    (name: cfg: { config = cfg; } // (mkClusterOutputs cfg))
    config.nixcluster;
in
{
  options.nixcluster = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.submoduleWith {
      modules = [
        coreModule
        # Thread downstream flake inputs (consumed by e.g. pxe -> inputs.disko).
        { _inputs = inputs; }
        # Default the cluster name to its attribute key (nixcluster.<name>).
        ({ name, ... }: { name = lib.mkDefault name; })
      ];
      specialArgs = { inherit clusterModules self inputs; };
    });
    default = {};
    description = ''
      Declarative cluster definitions. Each `nixcluster.<name>` is a cluster
      module (core options + explicitly imported clusterModules) and becomes
      `clusterConfigurations.<name>` in the flake outputs.
    '';
  };

  config.flake = {
    # OUTPUT end of the pipeline: evaluated config + derived outputs.
    clusterConfigurations = built;

    # Flatten members into top-level nixosConfigurations.<cluster>-<member>.
    nixosConfigurations = lib.concatMapAttrs
      (clusterName: c:
        lib.mapAttrs'
          (memberName: nixosCfg:
            lib.nameValuePair "${clusterName}-${memberName}" nixosCfg)
          c.nixosConfigurations)
      built;
  };

  # Per-system outputs (apps + packages) from the single-source projection:
  #   apps.cluster-<name>     (nix run .#cluster-<name>)
  #   packages.cluster-<name> (nix build .#cluster-<name>)
  #   packages.nixclusterctl  (static dispatcher)
  config.perSystem = { pkgs, ... }:
    mkPerSystemOutputs { inherit pkgs; clusterConfigurations = built; };
}
