# nix8sctl - Cluster management CLI
#
# Simple router that discovers clusters via nix eval
# and routes to cluster subcommands via nix run
{ pkgs }:

pkgs.writeShellApplication {
  name = "nix8sctl";
  runtimeInputs = with pkgs; [ nix jq ];
  text = ''
    show_help() {
      CLUSTERS=$(nix eval .#clusterConfigurations --apply 'builtins.attrNames' --json 2>/dev/null | jq -r '.[]' || echo "")
      cat << EOF
    nix8sctl - Cluster management CLI

    Usage:
      nix8sctl cluster <command>     System commands
      nix8sctl <cluster> <command>   Cluster commands

    Clusters:
    EOF
      if [[ -n "$CLUSTERS" ]]; then
        echo "$CLUSTERS" | while read -r name; do
          echo "    $name"
        done
      else
        echo "    (none found)"
      fi
      echo ""
      echo "Use 'nix8sctl <cluster> --help' for cluster commands."
    }

    CMD="''${1:-}"
    case "$CMD" in
      cluster)
        shift
        echo "System commands not implemented yet"
        exit 1
        ;;
      help|--help|-h|"")
        show_help
        ;;
      *)
        # Check if cluster exists and run its CLI
        if nix eval ".#clusterConfigurations.$CMD" --apply 'x: x != null' &>/dev/null; then
          shift
          exec nix run ".#cluster-$CMD" -- "$@"
        else
          echo "Unknown cluster: $CMD"
          show_help
          exit 1
        fi
        ;;
    esac
  '';
}
