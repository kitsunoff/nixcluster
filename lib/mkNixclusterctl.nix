# mkNixclusterctl - flake-parts-independent cluster dispatcher.
#
# A pure function of `pkgs` + `clusterConfigurations` that returns a
# writeShellApplication dispatching directly into each cluster's CLI by store
# path. Cluster discovery is STATIC (baked at build time from the attr names),
# so it depends ONLY on pkgs and clusterConfigurations — no flake-parts, no
# apps/packages, no runtime `nix eval` / `nix run`.
#
# Trade-off: adding a cluster requires rebuilding nixclusterctl (same as the
# per-cluster apps already behave). Runtime discovery is intentionally dropped.
#
# Usage: nixclusterctl <cluster> [args...]
{ lib }:

{ pkgs, clusterConfigurations }:

let
  clusterNames = lib.attrNames clusterConfigurations;

  # Static case list: one branch per cluster, exec its CLI by store path.
  clusterCases = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: c: ''
    ${name})
      shift
      exec ${lib.getExe (c.cli pkgs)} "$@"
      ;;
  '') clusterConfigurations);

  clusterList =
    if clusterNames == [] then
      "  (none)"
    else
      lib.concatMapStringsSep "\n" (name: "  ${name}") clusterNames;
in
pkgs.writeShellApplication {
  name = "nixclusterctl";
  text = ''
    show_help() {
      cat << 'EOF'
    nixclusterctl - Cluster management CLI

    Usage: nixclusterctl <cluster> [args...]

    Clusters:
    ${clusterList}

    Use 'nixclusterctl <cluster> --help' for cluster commands.
    EOF
    }

    CLUSTER="''${1:-}"
    case "$CLUSTER" in
    ${clusterCases}
      help|--help|-h|"")
        show_help
        ;;
      *)
        echo "Unknown cluster: $CLUSTER" >&2
        show_help
        exit 1
        ;;
    esac
  '';
}
