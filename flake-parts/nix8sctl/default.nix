# nix8sctl - CLI for nix8s cluster management
# Structure: nix8sctl <cluster> <command> [args...]
# Commands are discovered from nix8s.clusters.<cluster>.commands
{ lib, config, ... }:

let
  cfg = config.nix8s;

  # Import command builders for base commands
  mkApply = import ./_lib/apply.nix;
  mkGenSecrets = import ./_lib/gen-secrets.nix;
  mkEditSecrets = import ./_lib/edit-secrets.nix;
  mkShowSecrets = import ./_lib/show-secrets.nix;
in
{
  config = {
    perSystem = { pkgs, ... }:
      let
        clusters = cfg.clusters;
        nodes = cfg.nodes;
        clusterNames = lib.attrNames clusters;

        # Base commands available for all clusters
        baseCommands = cluster: clusterName: {
          apply = {
            description = "Apply config to a member";
            builder = { pkgs, lib, nodes, ... }:
              mkApply { inherit pkgs lib cluster clusterName nodes; };
          };

          gen-secrets = {
            description = "Generate cluster secrets";
            builder = { pkgs, lib, ... }:
              mkGenSecrets { inherit pkgs lib cluster clusterName; };
          };

          edit-secrets = {
            description = "Edit encrypted secrets";
            builder = { pkgs, lib, ... }:
              mkEditSecrets { inherit pkgs lib cluster clusterName; };
          };

          show-secrets = {
            description = "Show decrypted secrets";
            builder = { pkgs, lib, ... }:
              mkShowSecrets { inherit pkgs lib cluster clusterName; };
          };
        };

        # Get all commands for a cluster
        # Merges: base commands + cluster.commands + _extensionCommands
        getClusterCommands = clusterName:
          let
            cluster = clusters.${clusterName};
            # User-defined commands from cluster.commands
            userCommandsList = cluster.commands or [ ];
            userCommands = lib.foldl' (acc: cmds: acc // cmds) { } userCommandsList;
            # Extension commands from _extensionCommands
            extCommandsList = cfg._extensionCommands.${clusterName} or [ ];
            extCommands = lib.foldl' (acc: cmds: acc // cmds) { } extCommandsList;
            # Merge: base commands, then extension commands, then user commands (highest priority)
            allCommands = (baseCommands cluster clusterName) // extCommands // userCommands;
          in
          lib.mapAttrs
            (cmdName: cmdDef: {
              inherit (cmdDef) description;
              package = cmdDef.builder { inherit pkgs lib cluster clusterName nodes; };
            })
            allCommands;

        # Build cluster-specific CLI
        mkClusterCli = clusterName:
          let
            cluster = clusters.${clusterName};
            commands = getClusterCommands clusterName;

            # Help text for this cluster
            helpLines = lib.mapAttrsToList
              (name: cmd: "  ${name} - ${cmd.description}")
              commands;
            helpText = lib.concatStringsSep "\n" helpLines;

            # Member list for help
            memberNames = lib.attrNames cluster.members;
            memberList = lib.concatStringsSep ", " memberNames;

            # Generate case statements
            cases = lib.concatStringsSep "\n" (lib.mapAttrsToList
              (name: cmd: ''
                ${name})
                  shift
                  exec ${lib.getExe cmd.package} "$@"
                  ;;'')
              commands);

            # Determine example commands based on what's available
            exampleApply = lib.optionalString (commands ? apply)
              "  nix8sctl ${clusterName} apply ${lib.head memberNames}\n";
            exampleSecrets = lib.optionalString (commands ? gen-secrets)
              "  nix8sctl ${clusterName} gen-secrets\n";
            exampleBootstrap = lib.optionalString (commands ? bootstrap)
              "  nix8sctl ${clusterName} bootstrap\n";
            exampleKubeconfig = lib.optionalString (commands ? kubeconfig)
              "  nix8sctl ${clusterName} kubeconfig fetch";

          in
          pkgs.writeShellApplication {
            name = "nix8sctl-${clusterName}";
            text = ''
              set -euo pipefail

              show_help() {
                cat << 'HELPEOF'
              nix8sctl ${clusterName} - Manage cluster '${clusterName}'

              Usage: nix8sctl ${clusterName} <command> [args...]

              Commands:
              ${helpText}

              Members: ${memberList}

              Examples:
              ${exampleApply}${exampleSecrets}${exampleBootstrap}${exampleKubeconfig}
              HELPEOF
              }

              COMMAND="''${1:-}"

              case "$COMMAND" in
              ${cases}
                help|--help|-h|"")
                  show_help
                  ;;
                *)
                  echo "Error: Unknown command '$COMMAND' for cluster '${clusterName}'"
                  echo ""
                  show_help
                  exit 1
                  ;;
              esac
            '';
          };

        # Build all cluster CLIs
        clusterClis = lib.genAttrs clusterNames mkClusterCli;

        # Main router - routes to cluster-specific CLI
        clusterCases = lib.concatStringsSep "\n" (lib.mapAttrsToList
          (clusterName: cli: ''
            ${clusterName})
              shift
              exec ${lib.getExe cli} "$@"
              ;;'')
          clusterClis);

        clusterListStr = lib.concatStringsSep "\n" (lib.mapAttrsToList
          (clusterName: cluster:
            let
              commands = getClusterCommands clusterName;
              hasK3s = commands ? bootstrap || commands ? kubeconfig;
              hasPxe = cluster.provisioning.pxe.enable or false;
              hasAnywhere = cluster.provisioning.nixos-anywhere.enable or false;

              features = lib.concatStringsSep ", " (
                (lib.optional hasK3s "k3s")
                ++ (lib.optional hasPxe "pxe")
                ++ (lib.optional hasAnywhere "nixos-anywhere")
              );
              featureStr = if features != "" then " (${features})" else "";
              memberCount = toString (lib.length (lib.attrNames cluster.members));
            in
            "  ${clusterName} - ${memberCount} members${featureStr}"
          )
          clusters);

        nix8sctl = pkgs.writeShellApplication {
          name = "nix8sctl";
          text = ''
            set -euo pipefail

            show_help() {
              cat << 'HELPEOF'
            nix8sctl - CLI for nix8s cluster management

            Usage: nix8sctl <cluster> <command> [args...]

            Clusters:
            ${clusterListStr}

            Use 'nix8sctl <cluster> --help' for cluster-specific commands.

            Examples:
              nix8sctl dev apply lima-node
              nix8sctl dev bootstrap
              nix8sctl prod kubeconfig fetch
            HELPEOF
            }

            CLUSTER="''${1:-}"

            case "$CLUSTER" in
            ${clusterCases}
              help|--help|-h|"")
                show_help
                ;;
              *)
                echo "Error: Unknown cluster '$CLUSTER'"
                echo ""
                show_help
                exit 1
                ;;
            esac
          '';
        };

      in
      {
        apps.nix8sctl = {
          type = "app";
          program = lib.getExe nix8sctl;
        };
      };
  };
}
