# mkClusterCli - Build CLI subcommand for a cluster
#
# Two-level router:
#   nixclusterctl <cluster> <command> [args...]            (top-level core command)
#   nixclusterctl <cluster> <group> <action> [args...]     (namespaced module command)
#
# Top-level commands come from `cluster.commands` (core: apply/install/gen-config).
# Module commands come from `cluster.commandGroups.<group>.actions.<action>`.
# Everything after the resolved command/action is passed through verbatim, so a
# `--` passthrough boundary (e.g. `incus exec web -- bash`) reaches the node tool
# untouched by our router.
{ lib }:

{ pkgs, cluster }:

let
  clusterName = cluster.name;
  memberNames = lib.attrNames cluster.members;

  # Shared table renderer: reads TSV on stdin, prints aligned columns.
  # Commands emit tab-separated rows and pipe through this for human output;
  # the same data backs `--json` where a command implements it.
  tablefmt = pkgs.writeShellApplication {
    name = "tablefmt";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      exec column -t -s "$(printf '\t')"
    '';
  };

  helpers = { inherit tablefmt; };

  # Base (core) top-level commands, always available.
  baseCommands = {
    apply = {
      description = "Apply config to member";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-apply";
          runtimeInputs = with pkgs; [ nixos-rebuild openssh ];
          text = ''
            MEMBER="''${1:-}"
            IP="''${2:-}"

            if [[ -z "$MEMBER" ]]; then
              echo "Usage: nixclusterctl ${clusterName} apply <member> [ip]"
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

  # Top-level commands = base + any contributed via cluster.commands (attrsOf).
  topCommands = lib.mapAttrs (cmdName: cmdDef: {
    inherit (cmdDef) description;
    package = cmdDef.builder { inherit pkgs lib cluster helpers; };
  }) (baseCommands // (cluster.commands or {}));

  # Namespaced groups, each with built action packages.
  groups = lib.mapAttrs (groupName: groupDef: {
    inherit (groupDef) description;
    actions = lib.mapAttrs (actionName: actionDef: {
      inherit (actionDef) description;
      package = actionDef.builder { inherit pkgs lib cluster helpers; };
    }) groupDef.actions;
  }) (cluster.commandGroups or {});

  # --- help text -------------------------------------------------------------
  topHelp = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (n: c: "  ${n} - ${c.description}") topCommands);

  groupHelp = lib.concatStringsSep "\n" (lib.mapAttrsToList (gName: g:
    let actions = lib.concatStringsSep ", " (lib.attrNames g.actions);
    in "  ${gName} - ${g.description} (${actions})"
  ) groups);

  # --- router cases ----------------------------------------------------------
  topCases = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: cmd: ''
    ${name})
      shift
      exec ${lib.getExe cmd.package} "$@"
      ;;
  '') topCommands);

  groupCases = lib.concatStringsSep "\n" (lib.mapAttrsToList (gName: g:
    let
      actionCases = lib.concatStringsSep "\n" (lib.mapAttrsToList (aName: a: ''
        ${aName})
          shift
          exec ${lib.getExe a.package} "$@"
          ;;
      '') g.actions);
      actionList = lib.concatStringsSep ", " (lib.attrNames g.actions);
    in ''
    ${gName})
      shift
      ACTION="''${1:-}"
      case "$ACTION" in
      ${actionCases}
        help|--help|-h|"")
          echo "${gName} - ${g.description}"
          echo "Actions: ${actionList}"
          ;;
        *) echo "Unknown ${gName} action: $ACTION"; echo "Actions: ${actionList}"; exit 1 ;;
      esac
      ;;
  '') groups);

in
pkgs.writeShellApplication {
  name = "nixclusterctl-${clusterName}";
  text = ''
    show_help() {
      cat << 'EOF'
    nixclusterctl ${clusterName}

    Commands:
    ${topHelp}

    Command groups:
    ${groupHelp}

    Members: ${lib.concatStringsSep ", " memberNames}
    EOF
    }

    CMD="''${1:-}"
    case "$CMD" in
    ${topCases}
    ${groupCases}
      help|--help|-h|"") show_help ;;
      *) echo "Unknown: $CMD"; show_help; exit 1 ;;
    esac
  '';
}
