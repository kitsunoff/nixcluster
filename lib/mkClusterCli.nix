# mkClusterCli - Build CLI subcommand for a cluster
#
# Returns a package that handles: nix8sctl <cluster> <command> [args...]
{ lib }:

{ pkgs, cluster }:

let
  clusterName = cluster.name;
  memberNames = lib.attrNames cluster.members;

  # Base commands (always available)
  baseCommands = {
    apply = {
      description = "Apply config to member";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nix8sctl-${clusterName}-apply";
          runtimeInputs = with pkgs; [ nixos-rebuild openssh ];
          text = ''
            MEMBER="''${1:-}"
            IP="''${2:-}"

            if [[ -z "$MEMBER" ]]; then
              echo "Usage: nix8sctl ${clusterName} apply <member> [ip]"
              echo "Members: ${lib.concatStringsSep ", " memberNames}"
              exit 1
            fi

            # Get IP from config or argument
            case "$MEMBER" in
              ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: member: ''
                ${name}) IP="''${IP:-${member.install.ip or ""}}" ;;
              '') cluster.members)}
            esac

            if [[ -z "$IP" ]]; then
              echo "Error: No IP for $MEMBER. Specify as argument."
              exit 1
            fi

            echo "Deploying ${clusterName}-$MEMBER to $IP..."
            nixos-rebuild switch \
              --flake ".#${clusterName}-$MEMBER" \
              --target-host "root@$IP"
          '';
        };
    };
  };

  # Extension commands from cluster.commands (list of attrsets)
  extCommands = lib.foldl' (acc: cmds: acc // cmds) {} (cluster.commands or []);

  # All commands
  allCommands = baseCommands // extCommands;

  # Build command packages
  commands = lib.mapAttrs (cmdName: cmdDef: {
    inherit (cmdDef) description;
    package = cmdDef.builder { inherit pkgs lib cluster; };
  }) allCommands;

  # Generate help text
  helpText = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (n: c: "  ${n} - ${c.description}") commands);

  # Generate case statements
  cases = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: cmd: ''
    ${name})
      shift
      exec ${lib.getExe cmd.package} "$@"
      ;;
  '') commands);

in
pkgs.writeShellApplication {
  name = "nix8sctl-${clusterName}";
  text = ''
    show_help() {
      cat << 'EOF'
    nix8sctl ${clusterName}

    Commands:
    ${helpText}

    Members: ${lib.concatStringsSep ", " memberNames}
    EOF
    }

    CMD="''${1:-}"
    case "$CMD" in
    ${cases}
      help|--help|-h|"") show_help ;;
      *) echo "Unknown: $CMD"; show_help; exit 1 ;;
    esac
  '';
}
