# prune - the shared "list the registry, diff it against the desired members, act
# on what is gone" engine.
#
# Converge only ever added. A member that leaves `config.members` — a machine
# de-selected by an operator, a node repurposed, a host wiped — stayed in the
# cluster's own registry forever, so you were left with an entry nothing would
# ever reconcile.
#
# Every module's prune step differs only in HOW it lists the registry and HOW it
# removes an entry. The diff, the safety rules and the reporting are the same, and
# live here so all four modules cannot drift apart on the dangerous part.
#
# Guarantees this engine enforces, in order:
#
#   1. An EMPTY desired set is a hard failure and prunes nothing. A truncated or
#      mis-generated node file must never be able to dissolve a cluster.
#   2. A removal that would drop the registry below quorum is refused, loudly,
#      and the run continues with whatever is still safe.
#   3. With registry == desired the step is a pure no-op: no removal command runs
#      and it says so.
#   4. Every removal is reported on stdout as a `::nixcluster:removed::` line so
#      converge folds it into its result JSON.
#
# Graceful with a force fallback: a departing host that answers is drained and
# deregistered cleanly; one that does not (the common case — it is already wiped)
# has its registry entry force-removed.
{ lib }:

{
  # A short name for the step, used in log lines: "k3s", "incus", ...
  subject,
  # Package set and the packages the commands below need on PATH.
  pkgs,
  runtimeInputs ? [ ],
  # The registry names we WANT to exist, i.e. the desired members.
  desired,
  # Shell that prints the registry's current names, one per line, on stdout.
  # Non-zero exit means "registry unavailable" and the step gives up without
  # pruning anything.
  listRegistry,
  # Shell that removes one entry. Receives:
  #   $1 = registry name, $2 = "reachable" | "unreachable"
  # It should drain/deregister gracefully when reachable and force-remove
  # otherwise. Non-zero exit is reported as a failed removal.
  removeEntry,
  # Shell that probes whether the departing host is reachable. Receives $1 =
  # registry name; exit 0 means reachable. Defaults to "never reachable", which
  # makes every removal take the force path.
  probeHost ? ''return 1'',
  # Smallest number of entries the registry must keep for the cluster to stay
  # quorate. 0 disables the check (a registry with no quorum semantics).
  quorumMinimum ? 0,
  # Extra shell run before anything else (resolving an endpoint, exporting a
  # kubeconfig, ...).
  prelude ? "",
}:

let
  desiredList = lib.unique desired;
in
pkgs.writeShellApplication {
  name = "nixcluster-prune-${subject}";
  runtimeInputs = runtimeInputs ++ [ pkgs.coreutils pkgs.jq ];
  text = ''
    set -euo pipefail

    # Human-readable output goes to stderr; stdout carries only the
    # ::nixcluster:removed:: report lines converge parses.
    log() { echo "[${subject}.prune] $*" >&2; }

    report() { # name status message
      jq -nc --arg name "$1" --arg status "$2" --arg message "$3" \
        '{name:$name,action:"removed",status:$status,message:$message}' |
        while IFS= read -r line; do printf '::nixcluster:removed:: %s\n' "$line"; done
    }

    ${prelude}

    # --- the desired set -----------------------------------------------------
    DESIRED=(${lib.concatStringsSep " " (map lib.escapeShellArg desiredList)})

    # Guard 1: an empty desired set is never a licence to empty the cluster. A
    # broken or truncated generated node file would otherwise dissolve it.
    if [[ "''${#DESIRED[@]}" -eq 0 ]]; then
      log "REFUSING to prune: the desired member set is empty."
      log "  That is almost certainly a broken or truncated cluster definition,"
      log "  not an instruction to dissolve the cluster. Nothing was removed."
      exit 1
    fi

    is_desired() {
      local candidate="$1" want
      for want in "''${DESIRED[@]}"; do
        [[ "$want" == "$candidate" ]] && return 0
      done
      return 1
    }

    probe_host() { # registry-name
      ${probeHost}
    }

    remove_entry() { # registry-name reachable|unreachable
      ${removeEntry}
    }

    # --- the registry --------------------------------------------------------
    REGISTRY_RAW=""
    if ! REGISTRY_RAW="$(${listRegistry})"; then
      log "could not read the registry; skipping the prune (nothing removed)"
      exit 0
    fi

    REGISTRY=()
    while IFS= read -r entry; do
      [[ -n "$entry" ]] && REGISTRY+=("$entry")
    done <<< "$REGISTRY_RAW"

    STALE=()
    for entry in ''${REGISTRY[@]+"''${REGISTRY[@]}"}; do
      is_desired "$entry" || STALE+=("$entry")
    done

    # Guarantee 3: a converged cluster is a no-op that says so.
    if [[ "''${#STALE[@]}" -eq 0 ]]; then
      log "registry matches the desired members (''${#REGISTRY[@]} entries), nothing to prune"
      exit 0
    fi

    log "stale registry entries: ''${STALE[*]}"

    # Guard 2: never prune the cluster below quorum.
    QUORUM_MINIMUM=${toString quorumMinimum}
    SURVIVORS=$(( ''${#REGISTRY[@]} - ''${#STALE[@]} ))
    if [[ "$QUORUM_MINIMUM" -gt 0 && "$SURVIVORS" -lt "$QUORUM_MINIMUM" ]]; then
      log "REFUSING to prune ''${STALE[*]}: it would leave $SURVIVORS of ''${#REGISTRY[@]}"
      log "  entries, below the $QUORUM_MINIMUM needed for quorum. Remove members one"
      log "  at a time, letting the cluster re-establish quorum in between."
      for entry in "''${STALE[@]}"; do
        report "$entry" Failed "refused: removing it would break quorum ($SURVIVORS < $QUORUM_MINIMUM)"
      done
      # Loud, but not fatal: the rest of the converge run is still valid.
      exit 0
    fi

    # --- remove --------------------------------------------------------------
    FAILED=0
    for entry in "''${STALE[@]}"; do
      if probe_host "$entry"; then
        log "removing $entry (host reachable: draining first)"
        reachable=reachable
      else
        log "removing $entry (host unreachable: force path)"
        reachable=unreachable
      fi

      if remove_entry "$entry" "$reachable"; then
        log "removed $entry"
        report "$entry" Applied "removed from the ${subject} registry ($reachable)"
      else
        log "FAILED to remove $entry"
        report "$entry" Failed "could not be removed from the ${subject} registry"
        FAILED=1
      fi
    done

    exit "$FAILED"
  '';
}
