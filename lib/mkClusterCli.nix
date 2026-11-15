# mkClusterCli - Build CLI subcommand for a cluster
#
# Two-level router:
#   nixclusterctl <cluster> <command> [args...]            (top-level core command)
#   nixclusterctl <cluster> <group> <action> [args...]     (namespaced module command)
#
# Top-level commands come from `cluster.commands` (core: apply/install/gen-config/
# converge/teardown).
# Module commands come from `cluster.commandGroups.<group>.actions.<action>`.
# Everything after the resolved command/action is passed through verbatim, so a
# `--` passthrough boundary (e.g. `incus exec web -- bash`) reaches the node tool
# untouched by our router.
{ lib }:

{ pkgs, cluster }:

let
  stepPlan = import ./stepPlan.nix { inherit lib; };

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

  # --- the step walker shared by `converge` and `teardown` ---------------------
  # Both commands walk a DAG of steps (cluster.<kind>.steps) in the order
  # stepPlan resolves, skip a step whose dependency did not succeed, and emit one
  # machine-readable result. Only the member action differs (install-or-switch
  # vs. switch back to the base configuration), so each command supplies
  # `member_action` and `MEMBER_SKIP_ACTION` and shares everything else.

  # member -> default install.ip, reusing the install/apply case shape.
  memberIpCases = lib.concatStringsSep "\n              " (lib.mapAttrsToList
    (name: member: ''${name}) echo "${member.install.ip or ""}" ;;'')
    cluster.members);

  # One shell invocation per step, in dependency order. A member step
  # dispatches to the command's member action; every other step runs the
  # package its module contributed.
  mkStepDispatches = steps: order: lib.concatMapStringsSep "\n            "
    (name:
      let
        step = steps.${name};
        deps = lib.concatStringsSep " " (map lib.escapeShellArg step.deps);
      in
      if step.member != null
      then ''run_member_step ${lib.escapeShellArg name} ${lib.escapeShellArg step.phase} ${lib.escapeShellArg step.member} ${deps}''
      else ''run_step ${lib.escapeShellArg name} ${lib.escapeShellArg step.phase} ${lib.escapeShellArg (lib.getExe (step.run { inherit pkgs lib cluster helpers; }))} ${deps}'')
    order;

  # Shell shared by both commands. Expects JSON and DRY_RUN to be set, and
  # `member_action <member>` + MEMBER_SKIP_ACTION to be defined before the walk.
  stepRunner = ''
            # All human output goes to stderr; stdout carries ONLY the result
            # line so `--json` yields a bare object and greppers get one marker.
            log() { echo "$@" >&2; }

            # --- accumulators (built with jq; never hand-concatenated) ---------
            MEMBERS_JSON='[]'
            STEPS_JSON='[]'

            # Outcome of every step by name ("ok" | "planned" | "failed" |
            # "skipped"), so a step whose dependency did not succeed is skipped
            # instead of run. "planned" is a dry-run step: it did not run, but
            # it would have, so the steps after it are planned too.
            declare -A STEP_STATUS=()

            # Echoes the first dependency that did not succeed, if any.
            failed_dep() {
              local dep
              for dep in "$@"; do
                if [[ ! "''${STEP_STATUS[$dep]:-missing}" =~ ^(ok|planned)$ ]]; then
                  echo "$dep"
                  return 0
                fi
              done
              return 1
            }

            add_member() { # name ip action status message durationSeconds
              MEMBERS_JSON=$(jq -c \
                --arg name "$1" --arg ip "$2" --arg action "$3" \
                --arg status "$4" --arg message "$5" --argjson dur "$6" \
                '. += [{name:$name,ip:$ip,action:$action,status:$status,message:$message,durationSeconds:$dur}]' \
                <<<"$MEMBERS_JSON")
            }
            add_step() { # name phase status message
              STEPS_JSON=$(jq -c \
                --arg name "$1" --arg phase "$2" --arg status "$3" --arg message "$4" \
                '. += [{name:$name,phase:$phase,status:$status,message:$message}]' \
                <<<"$STEPS_JSON")
            }

            # No host-key pinning on the converge path: converge reinstalls
            # members (nixos-anywhere), which CHANGES their ssh host key mid-run,
            # so accept-new (which rejects a *changed* key) would fail every
            # post-install step. Matches the operator-injected NIX_SSHOPTS, which
            # also disables host-key checking for exactly this reason.
            SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

            # The operator passes the cluster SSH key via NIX_SSHOPTS ("-i <path>
            # ..."), but plain ssh (the member probe below) and the module steps
            # (incus over ssh) do NOT read NIX_SSHOPTS. Extract that identity and
            # install it as the default key so every direct ssh/scp — and
            # nixos-anywhere/nixos-rebuild — authenticates with the cluster key.
            if [[ -n "''${NIX_SSHOPTS:-}" ]]; then
              # Parse the "-i <path>" identity out of NIX_SSHOPTS with pure bash
              # (no sed/awk — keep runtimeInputs minimal).
              CLUSTER_KEY=""
              if [[ "''${NIX_SSHOPTS}" =~ -i[[:space:]]+([^[:space:]]+) ]]; then
                CLUSTER_KEY="''${BASH_REMATCH[1]}"
              fi
              if [[ -n "''${CLUSTER_KEY:-}" && -r "''${CLUSTER_KEY}" ]]; then
                SSH_HOME="''${HOME:-/root}/.ssh"
                mkdir -p "$SSH_HOME"; chmod 700 "$SSH_HOME"
                install -m 600 "''${CLUSTER_KEY}" "$SSH_HOME/id_ed25519"
                log "[ssh] installed cluster identity from NIX_SSHOPTS at $SSH_HOME/id_ed25519"
              fi
            fi

            member_ip() {
              case "$1" in
              ${memberIpCases}
                *) echo "" ;;
              esac
            }

            # A step may report members it REMOVED, by printing
            #   ::nixcluster:removed:: {"name":…,"action":"removed",…}
            # on stdout. Those entries join the members array, so a consumer sees a
            # departure the same way it sees an install or a switch — membership is
            # reconciled in both directions and the result says so.
            collect_removals() { # step-output-file
              local line payload
              while IFS= read -r line; do
                case "$line" in
                  '::nixcluster:removed:: '*)
                    payload="''${line#'::nixcluster:removed:: '}"
                    if jq -e . >/dev/null 2>&1 <<<"$payload"; then
                      MEMBERS_JSON=$(jq -c --argjson entry "$payload" \
                        '. += [{
                           name: $entry.name,
                           ip: ($entry.ip // ""),
                           action: ($entry.action // "removed"),
                           status: ($entry.status // "Applied"),
                           message: ($entry.message // ""),
                           durationSeconds: ($entry.durationSeconds // 0)
                         }]' <<<"$MEMBERS_JSON")
                    else
                      log "  ignoring malformed ::nixcluster:removed:: payload"
                    fi
                    ;;
                esac
              done < "$1"
            }

            run_step() { # name phase exe [deps...]
              local name="$1" phase="$2" exe="$3"
              shift 3
              local blocker
              if blocker=$(failed_dep "$@"); then
                log "  [step:$phase] $name skipped (dependency '$blocker' did not succeed)"
                add_step "$name" "$phase" skipped "dependency '$blocker' did not succeed"
                STEP_STATUS[$name]=skipped
                return 0
              fi
              if [[ "$DRY_RUN" -eq 1 ]]; then
                log "  [step:$phase] $name (dry-run, not executed)"
                add_step "$name" "$phase" skipped "dry-run"
                STEP_STATUS[$name]=planned
                return 0
              fi
              log "=== step [$phase] $name ==="
              # Capture stdout so removal reports can be folded into the result,
              # while still showing it to a human (on stderr, like everything else).
              local out rc=0
              out="$(mktemp)"
              if "$exe" > "$out" 2>&1; then rc=0; else rc=$?; fi
              cat "$out" >&2
              collect_removals "$out"
              rm -f "$out"

              if [[ "$rc" -eq 0 ]]; then
                add_step "$name" "$phase" ok ""
                STEP_STATUS[$name]=ok
              else
                add_step "$name" "$phase" failed "step exited non-zero"
                STEP_STATUS[$name]=failed
              fi
            }

            # A member step: skip when a dependency failed, otherwise run the
            # command's member action and record the outcome under the STEP name
            # so dependents can gate on it. The step joins the steps array like
            # any other; its status follows the member entry the action wrote.
            run_member_step() { # step-name phase member [deps...]
              local name="$1" phase="$2" member="$3"
              shift 3
              local blocker entry
              if blocker=$(failed_dep "$@"); then
                log "  [member] $member skipped (dependency '$blocker' did not succeed)"
                add_member "$member" "$(member_ip "$member")" "$MEMBER_SKIP_ACTION" Skipped \
                  "dependency '$blocker' did not succeed" 0
                add_step "$name" "$phase" skipped "dependency '$blocker' did not succeed"
                STEP_STATUS[$name]=skipped
                return 0
              fi
              if member_action "$member"; then
                if [[ "$DRY_RUN" -eq 1 ]]; then STEP_STATUS[$name]=planned; else STEP_STATUS[$name]=ok; fi
              else
                STEP_STATUS[$name]=failed
              fi
              entry=$(jq -c --arg m "$member" 'map(select(.name == $m)) | last // {}' <<<"$MEMBERS_JSON")
              case "$(jq -r '.status // ""' <<<"$entry")" in
                Applied) add_step "$name" "$phase" ok "" ;;
                Skipped) add_step "$name" "$phase" skipped "$(jq -r '.message' <<<"$entry")" ;;
                *) add_step "$name" "$phase" failed "$(jq -r '.message // "member action failed"' <<<"$entry")" ;;
              esac
            }

            # Emits the single result line and sets RESULT. The overall result
            # comes from the accumulated members and steps unless one is given.
            # A dry run that planned everything is a success: everything it
            # reports as skipped was skipped on purpose.
            emit_result() { # [result]
              RESULT="''${1:-}"
              if [[ -z "$RESULT" ]]; then
                RESULT=$(jq -rn --argjson m "$MEMBERS_JSON" --argjson s "$STEPS_JSON" --argjson dry "$DRY_RUN" '
                  if ($m | any(.status=="Failed")) or ($s | any(.status=="failed")) then "failed"
                  elif $dry == 1 then "success"
                  elif ($m | any(.status=="Skipped")) or ($s | any(.status=="skipped")) then "partial"
                  else "success" end')
              fi
              local final
              final=$(jq -n -c \
                --arg cluster "${clusterName}" --arg result "$RESULT" \
                --argjson members "$MEMBERS_JSON" --argjson steps "$STEPS_JSON" \
                '{cluster:$cluster,result:$result,members:$members,steps:$steps}')

              log ""
              if [[ "$JSON" -eq 1 ]]; then
                printf '%s\n' "$final"
              else
                printf '::nixcluster:result:: %s\n' "$final"
              fi
            }
  '';

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

    # gen-config (task 03): SSH-discover a node and emit a member module.
    gen-config = {
      description = "Discover a node over SSH and emit a member module";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-gen-config";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -euo pipefail

            IP=""
            NAME=""
            SSH_USER="root"
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --name) NAME="''${2:-}"; shift 2 ;;
                --ssh-user) SSH_USER="''${2:-}"; shift 2 ;;
                --*) echo "Unknown flag: $1" >&2; exit 1 ;;
                *)
                  if [[ -z "$IP" ]]; then IP="$1"; shift;
                  else echo "Unexpected argument: $1" >&2; exit 1; fi
                  ;;
              esac
            done

            if [[ -z "$IP" ]]; then
              echo "Usage: nixclusterctl ${clusterName} gen-config <ip> [--name <node-name>] [--ssh-user <user>]" >&2
              exit 1
            fi

            echo "Discovering node at $IP (user $SSH_USER)..." >&2

            # Bootstrap TOFU: accept-new pins on first contact, never disables checking (B3).
            SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

            REMOTE_HOSTNAME=$(ssh "''${SSH_OPTS[@]}" "$SSH_USER@$IP" 'hostname' | tr -d "\r" | head -n1)

            # Pick the whole disk backing /, else the first disk. Reads the real
            # device from the node (e.g. /dev/vda on Colima), never hardcoded.
            DISK=$(ssh "''${SSH_OPTS[@]}" "$SSH_USER@$IP" 'set -e; root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true); pk=""; if [ -n "$root_src" ]; then pk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1); fi; if [ -n "$pk" ]; then echo "/dev/$pk"; else d=$(lsblk -dn -o NAME,TYPE | grep "disk$" | head -n1 | sed "s/[[:space:]].*//"); echo "/dev/$d"; fi' | tr -d "\r" | head -n1)

            NODE_NAME="''${NAME:-$REMOTE_HOSTNAME}"

            echo "  hostname: $REMOTE_HOSTNAME" >&2
            echo "  disk:     $DISK" >&2
            echo "  member:   $NODE_NAME" >&2

            printf '%s\n' \
              "# Generated by: nixclusterctl ${clusterName} gen-config $IP" \
              "# Save into modules/nodes/$NODE_NAME.nix" \
              "{ ... }:" \
              "{" \
              "  nixcluster.${clusterName}.members.$NODE_NAME = {" \
              "    # nixosConfiguration = ...;  # set your base NixOS config" \
              "    install.ip = \"$IP\";" \
              "    install.disk = \"$DISK\";" \
              "  };" \
              "}"
          '';
        };
    };

    # install (task 04): first-time provisioning via nixos-anywhere.
    install = {
      description = "Install a member via nixos-anywhere";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-install";
          runtimeInputs = with pkgs; [ nixos-anywhere openssh coreutils ];
          text = ''
            set -euo pipefail

            MEMBER=""
            IP=""
            AGE_KEY_FILE=""
            EXTRA_FILES=""
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --age-key-file) AGE_KEY_FILE="''${2:-}"; shift 2 ;;
                --extra-files) EXTRA_FILES="''${2:-}"; shift 2 ;;
                --*) echo "Unknown flag: $1" >&2; exit 1 ;;
                *)
                  if [[ -z "$MEMBER" ]]; then MEMBER="$1";
                  elif [[ -z "$IP" ]]; then IP="$1";
                  else echo "Unexpected argument: $1" >&2; exit 1; fi
                  shift
                  ;;
              esac
            done

            if [[ -z "$MEMBER" ]]; then
              echo "Usage: nixclusterctl ${clusterName} install <member> [ip] [--age-key-file <path>] [--extra-files <dir>]" >&2
              echo "Members: ${lib.concatStringsSep ", " memberNames}" >&2
              exit 1
            fi

            # Default IP from member config.
            case "$MEMBER" in
              ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: member: ''
                ${name}) IP="''${IP:-${member.install.ip or ""}}" ;;
              '') cluster.members)}
            esac

            if [[ -z "$IP" ]]; then
              echo "Error: no IP for $MEMBER (set members.$MEMBER.install.ip or pass as arg)" >&2
              exit 1
            fi

            STAGED=""
            cleanup() { [[ -n "$STAGED" ]] && rm -rf "$STAGED"; }
            trap cleanup EXIT

            EF_ARGS=()
            if [[ -n "$AGE_KEY_FILE" ]]; then
              # I3: deliver the age private key into the node's real filesystem at
              # /etc/age/key.txt (mode 0600), outside the nix store/closure. sops-nix
              # reads it on activation (sops.ageKeyFileOnHost), never via the store.
              STAGED=$(mktemp -d)
              install -m 600 -D "$AGE_KEY_FILE" "$STAGED/etc/age/key.txt"
              EF_ARGS+=(--extra-files "$STAGED")
            elif [[ -n "$EXTRA_FILES" ]]; then
              EF_ARGS+=(--extra-files "$EXTRA_FILES")
            fi

            echo "Installing ${clusterName}-$MEMBER on $IP via nixos-anywhere..." >&2
            nixos-anywhere \
              --flake ".#${clusterName}-$MEMBER" \
              --target-host "root@$IP" \
              "''${EF_ARGS[@]}"

            # B3: pin the node host key for subsequent runtime ssh (no accept-new later).
            KH_DIR="./.nixcluster/known_hosts"
            mkdir -p "$KH_DIR"
            ssh-keyscan -H "$IP" >> "$KH_DIR/${clusterName}" 2>/dev/null || true
            echo "Pinned host key for $IP in $KH_DIR/${clusterName}" >&2
          '';
        };
    };
    # converge (task E): orchestrate a whole cluster in one shot. Every unit of
    # work — a module step or a member's install/switch — is a node in
    # `converge.steps`; stepPlan resolves them into a topological order and the
    # shared step walker runs it, skipping any step whose dependency did not
    # succeed, then emits a single machine-readable result line. Reuses the
    # install/apply member->IP `case` and the `.#<cluster>-<member>` flake attr;
    # step logic is reused from the modules (never reimplemented here).
    converge = {
      description = "Converge the whole cluster (dependency-ordered converge steps)";
      builder = { pkgs, lib, cluster, helpers, ... }:
        let
          stepOrder = stepPlan "converge" cluster;
        in
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-converge";
          runtimeInputs = with pkgs; [ nixos-anywhere nixos-rebuild openssh jq coreutils ];
          text = ''
            set -euo pipefail

            JSON=0
            DRY_RUN=0
            AGE_KEY_FILE=""
            EXTRA_FILES=""
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --json) JSON=1; shift ;;
                --dry-run) DRY_RUN=1; shift ;;
                --age-key-file) AGE_KEY_FILE="''${2:-}"; shift 2 ;;
                --extra-files) EXTRA_FILES="''${2:-}"; shift 2 ;;
                -h|--help)
                  echo "Usage: nixclusterctl ${clusterName} converge [--json] [--dry-run] [--age-key-file <path>] [--extra-files <dir>]" >&2
                  exit 0 ;;
                *) echo "Unknown flag: $1" >&2; exit 1 ;;
              esac
            done

            ${stepRunner}

            # --extra-files staging mirrors `install`: the age private key lands
            # at /etc/age/key.txt (0600) on the node, outside the nix store.
            STAGED=""
            cleanup() { [[ -n "$STAGED" ]] && rm -rf "$STAGED"; return 0; }
            trap cleanup EXIT
            EF_ARGS=()
            if [[ -n "$AGE_KEY_FILE" ]]; then
              STAGED=$(mktemp -d)
              install -m 600 -D "$AGE_KEY_FILE" "$STAGED/etc/age/key.txt"
              EF_ARGS+=(--extra-files "$STAGED")
            elif [[ -n "$EXTRA_FILES" ]]; then
              EF_ARGS+=(--extra-files "$EXTRA_FILES")
            fi

            MEMBER_SKIP_ACTION=noop
            member_action() { converge_member "$1"; }

            # Installs or switches one member. Returns non-zero only when the
            # member genuinely failed to converge; a dry run plans it.
            converge_member() { # member
              local member="$1" ip probe start end
              ip="$(member_ip "$member")"
              if [[ "$DRY_RUN" -eq 1 ]]; then
                log "  [member] $member -> ''${ip:-<no-ip>} (dry-run, not probed)"
                add_member "$member" "$ip" noop Skipped "dry-run" 0
                return 0
              fi
              if [[ -z "$ip" ]]; then
                log "  [member] $member has no install.ip; skipping"
                add_member "$member" "" noop Failed "no install.ip for $member" 0
                return 1
              fi
              start=$(date +%s)
              probe=$(ssh "''${SSH_OPTS[@]}" "root@$ip" \
                'test -e /run/current-system && echo INSTALLED || echo FRESH' 2>/dev/null \
                || echo UNREACHABLE)
              case "$probe" in
                INSTALLED)
                  log "=== switch $member ($ip) [nixos-rebuild] ==="
                  # nixos-rebuild reads its ssh options ONLY from NIX_SSHOPTS, not
                  # from our SSH_OPTS array — pass the same (no-host-key-check)
                  # options there so the switch works non-interactively (the node
                  # was just reinstalled, so its host key changed).
                  if NIX_SSHOPTS="''${SSH_OPTS[*]}" nixos-rebuild switch --flake ".#${clusterName}-$member" --target-host "root@$ip"; then
                    end=$(date +%s); add_member "$member" "$ip" switch Applied "" $((end - start))
                  else
                    end=$(date +%s); add_member "$member" "$ip" switch Failed "nixos-rebuild switch failed" $((end - start))
                  fi
                  ;;
                FRESH)
                  log "=== install $member ($ip) [nixos-anywhere] ==="
                  if nixos-anywhere --flake ".#${clusterName}-$member" --target-host "root@$ip" "''${EF_ARGS[@]}"; then
                    end=$(date +%s); add_member "$member" "$ip" install Applied "" $((end - start))
                  else
                    end=$(date +%s); add_member "$member" "$ip" install Failed "nixos-anywhere failed" $((end - start))
                  fi
                  ;;
                *)
                  end=$(date +%s); add_member "$member" "$ip" noop Failed "unreachable ($probe)" $((end - start))
                  ;;
              esac
            }

            log "Converging cluster '${clusterName}'"
            log "Step order: ${lib.concatStringsSep " " stepOrder}"
            log ""

            # 1) walk the converge DAG in dependency order. Each dispatch skips
            #    itself when one of its dependencies did not succeed.
            ${mkStepDispatches cluster.converge.steps stepOrder}

            # 2) result + emit
            emit_result

            # Reflect a hard convergence failure in the exit code so a consumer
            # driving converge as a Job (NIO's converge NixCronJob) sees the run
            # fail instead of silently succeeding. "partial" (only Skipped, e.g.
            # an unreachable member) is NOT a failure.
            if [[ "$RESULT" == "failed" ]]; then
              exit 1
            fi
          '';
        };
    };

    # teardown: `converge` in reverse, with terraform-destroy semantics. Walks
    # `teardown.steps` — modules take their workloads off, members leave each
    # module's cluster (joiners first, the bootstrap last), every host is cleaned
    # up — and finally switches every member back to its base NixOS
    # configuration (`teardownNixosConfigurations`), so the host stays reachable
    # and the next `converge` rebuilds the same cluster. Disks are not wiped.
    #
    # The plan is printed first; nothing runs unless the operator types `yes`
    # (or passes --auto-approve). --dry-run prints the plan and stops. An
    # unreachable member is reported and skipped, never fatal.
    teardown = {
      description = "Tear the whole cluster down to its base NixOS configuration (reverse of converge)";
      builder = { pkgs, lib, cluster, helpers, ... }:
        let
          steps = cluster.teardown.steps;
          stepOrder = stepPlan "teardown" cluster;

          # The plan, as shell lines: members, then every step in order.
          planMembers = lib.concatMapStringsSep "\n            "
            (member: ''log "    - ${member} ($(member_ip ${lib.escapeShellArg member}))"'')
            memberNames;
          planSteps = lib.concatStringsSep "\n            " (lib.imap1
            (i: name: ''printf '    %3d. %-10s %-30s %s\n' ${toString i} ${lib.escapeShellArg steps.${name}.phase} ${lib.escapeShellArg name} ${lib.escapeShellArg steps.${name}.description} >&2'')
            stepOrder);

          # The dry-run result: every member planned for destruction, every step
          # skipped — without touching a host.
          dryRunRecords = lib.concatMapStringsSep "\n            "
            (name:
              let step = steps.${name}; in
              if step.member != null
              then ''add_member ${lib.escapeShellArg step.member} "$(member_ip ${lib.escapeShellArg step.member})" destroyed Skipped dry-run 0; add_step ${lib.escapeShellArg name} ${lib.escapeShellArg step.phase} skipped dry-run''
              else ''add_step ${lib.escapeShellArg name} ${lib.escapeShellArg step.phase} skipped dry-run'')
            stepOrder;

          # The flake attribute `teardown` switches a member to; the same flake
          # `converge` reads `.#<cluster>-<member>` from.
          baseToplevel = member:
            ''.#clusterConfigurations."${clusterName}".teardownNixosConfigurations."${member}".config.system.build.toplevel'';
        in
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-teardown";
          runtimeInputs = with pkgs; [ nix openssh jq coreutils ];
          text = ''
            set -euo pipefail

            JSON=0
            DRY_RUN=0
            AUTO_APPROVE=0
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --json) JSON=1; shift ;;
                --dry-run) DRY_RUN=1; shift ;;
                --auto-approve) AUTO_APPROVE=1; shift ;;
                -h|--help)
                  echo "Usage: nixclusterctl ${clusterName} teardown [--dry-run] [--json] [--auto-approve]" >&2
                  exit 0 ;;
                *) echo "Unknown flag: $1" >&2; exit 1 ;;
              esac
            done

            ${stepRunner}

            NIX_FLAGS=(--extra-experimental-features "nix-command flakes")

            MEMBER_SKIP_ACTION=destroyed
            member_action() { teardown_member "$1"; }

            # Switches one member back to its base NixOS configuration: build it
            # here, copy it to the member, make it the system profile and switch.
            # The switch runs as a transient unit so it survives the SSH session
            # it was started from. Unreachable is reported, not a failure.
            teardown_member() { # member
              local member="$1" ip start end attr toplevel switch_cmd
              ip="$(member_ip "$member")"
              if [[ -z "$ip" ]]; then
                log "  [member] $member has no install.ip; skipping"
                add_member "$member" "" destroyed Failed "no install.ip for $member" 0
                return 1
              fi
              start=$(date +%s)
              if ! ssh "''${SSH_OPTS[@]}" -o BatchMode=yes "root@$ip" true </dev/null >/dev/null 2>&1; then
                log "  [member] $member ($ip) is unreachable; skipped, its state is left as it is"
                end=$(date +%s)
                add_member "$member" "$ip" destroyed Skipped "unreachable; its state is left as it is" $((end - start))
                return 0
              fi

              log "=== switch $member ($ip) back to its base configuration ==="
              case "$member" in
                ${lib.concatMapStringsSep "\n                " (member:
                  ''${lib.escapeShellArg member}) attr=${lib.escapeShellArg (baseToplevel member)} ;;'') memberNames}
                *) attr="" ;;
              esac
              # The switch command is built here on purpose: the store path is
              # known only on this side (printf %q quotes it for the remote shell).
              # shellcheck disable=SC2029
              if toplevel="$(nix "''${NIX_FLAGS[@]}" build --no-link --print-out-paths "$attr")" &&
                NIX_SSHOPTS="''${SSH_OPTS[*]}" nix "''${NIX_FLAGS[@]}" copy --to "ssh://root@$ip" "$toplevel" &&
                printf -v switch_cmd \
                  'nix-env --profile /nix/var/nix/profiles/system --set %q && systemd-run --collect --no-ask-password --pipe --quiet --service-type=exec --unit=nixcluster-teardown-switch --wait %q switch' \
                  "$toplevel" "$toplevel/bin/switch-to-configuration" &&
                ssh "''${SSH_OPTS[@]}" "root@$ip" "$switch_cmd" </dev/null >&2; then
                end=$(date +%s)
                add_member "$member" "$ip" destroyed Applied "" $((end - start))
              else
                end=$(date +%s)
                add_member "$member" "$ip" destroyed Failed "could not build, copy or switch to the base configuration" $((end - start))
                return 1
              fi
            }

            # 1) the plan
            log "nixcluster will tear down cluster '${clusterName}'."
            log ""
            log "  Members (each ends on its base NixOS configuration; disks are not wiped):"
            ${planMembers}
            log ""
            log "  Steps, in order:"
            ${planSteps}
            log ""
            log "  Plan: ${toString (lib.length memberNames)} member(s) to destroy, ${toString (lib.length stepOrder)} step(s)."
            log ""

            if [[ "$DRY_RUN" -eq 1 ]]; then
              log "Dry run: nothing was touched."
              ${dryRunRecords}
              emit_result
              exit 0
            fi

            # 2) approval, terraform-style: only the literal `yes` proceeds.
            if [[ "$AUTO_APPROVE" -eq 0 ]]; then
              log "Do you really want to destroy cluster '${clusterName}'?"
              log "  nixcluster will remove the cluster state from every member above and"
              log "  switch it back to its base NixOS configuration. \`converge\` rebuilds it."
              log "  Only 'yes' will be accepted to approve."
              log ""
              printf '  Enter a value: ' >&2
              ANSWER=""
              read -r ANSWER || true
              log ""
              if [[ "$ANSWER" != "yes" ]]; then
                log "Teardown cancelled."
                emit_result cancelled
                exit 1
              fi
            fi

            # 3) walk the teardown DAG in dependency order.
            log "Tearing down cluster '${clusterName}'"
            log ""
            ${mkStepDispatches steps stepOrder}

            # 4) result + emit; a failed member or step fails the run.
            emit_result
            if [[ "$RESULT" == "failed" ]]; then
              exit 1
            fi
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
  # Each command's own package, so a test can build one command (e.g. with
  # stubbed tools) without the rest of the CLI.
  passthru.commands = lib.mapAttrs (_: cmd: cmd.package) topCommands;
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
