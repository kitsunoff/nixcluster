# mkFlakeOutputs - Generate flake outputs from clusterConfigurations
#
# Usage (standalone):
#   inherit (nixcluster.lib.mkFlakeOutputs { inherit self; })
#     nixosConfigurations apps packages;
#
# Usage (with explicit clusterConfigurations):
#   outputs = nixcluster.lib.mkFlakeOutputs { clusterConfigurations = ...; nixpkgs = ...; };
#
# Per-system apps + packages come from the shared mkPerSystemOutputs helper, so
# this standalone path produces the SAME cluster-<name> apps/packages and
# nixclusterctl as the flake-parts module and the root flake.
{ lib, inputs, mkPerSystemOutputs }:

{ self ? null, clusterConfigurations ? null, nixpkgs ? inputs.nixpkgs }:

let
  # Get clusterConfigurations from self or direct argument
  clusters = if clusterConfigurations != null then clusterConfigurations else (self.clusterConfigurations or {});

  # Collect all nixosConfigurations from all clusters
  # Format: <clusterName>-<memberName>
  nixosConfigurations = lib.concatMapAttrs (clusterName: cluster:
    lib.mapAttrs' (memberName: nixosCfg:
      lib.nameValuePair "${clusterName}-${memberName}" nixosCfg
    ) cluster.nixosConfigurations
  ) clusters;

  # Supported systems
  systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

  # Per-system projection (apps + packages), one call per system.
  perSystem = lib.genAttrs systems (system:
    mkPerSystemOutputs {
      pkgs = nixpkgs.legacyPackages.${system};
      clusterConfigurations = clusters;
    });

  apps = lib.mapAttrs (_system: o: o.apps) perSystem;
  packages = lib.mapAttrs (_system: o: o.packages) perSystem;

in
{
  inherit nixosConfigurations apps packages;
}
