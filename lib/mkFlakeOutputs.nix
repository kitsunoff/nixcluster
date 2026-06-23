# mkFlakeOutputs - Generate flake outputs from clusterConfigurations
#
# Usage (standalone):
#   inherit (nixcluster.lib.mkFlakeOutputs { inherit self; }) nixosConfigurations apps;
#
# Usage (with explicit clusterConfigurations):
#   outputs = nixcluster.lib.mkFlakeOutputs { clusterConfigurations = ...; nixpkgs = ...; };
{ lib, inputs }:

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

  # Build nixclusterctl for a system
  mkNixclusterctl = system:
    let
      pkgs = nixpkgs.legacyPackages.${system};

      # Get CLI subcommand from each cluster
      clusterClis = lib.mapAttrs (name: cluster: cluster.cli pkgs) clusters;

      # Main router
      clusterCases = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: cli: ''
        ${name})
          shift
          exec ${lib.getExe cli} "$@"
          ;;
      '') clusterClis);

      clusterList = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: cluster:
        let
          memberCount = toString (lib.length (lib.attrNames cluster.config.members));
          hasK3s = (lib.filterAttrs (n: m: m.k3s.role or null != null) cluster.config.members) != {};
          features = lib.optionalString hasK3s " (k3s)";
        in
        "  ${name} - ${memberCount} members${features}"
      ) clusters);

      nixclusterctl = pkgs.writeShellApplication {
        name = "nixclusterctl";
        text = ''
          show_help() {
            cat << 'EOF'
          nixclusterctl - Cluster management CLI

          Usage: nixclusterctl <cluster> <command> [args...]

          Clusters:
          ${clusterList}

          Use 'nixclusterctl <cluster> --help' for commands.
          EOF
          }

          CLUSTER="''${1:-}"
          case "$CLUSTER" in
          ${clusterCases}
            help|--help|-h|"") show_help ;;
            *) echo "Unknown cluster: $CLUSTER"; show_help; exit 1 ;;
          esac
        '';
      };
    in
    {
      type = "app";
      program = lib.getExe nixclusterctl;
    };

  apps = lib.genAttrs systems (system: {
    nixclusterctl = mkNixclusterctl system;
  });

in
{
  inherit nixosConfigurations apps;
}
