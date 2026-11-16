# teardown - the shared shape of every module's teardown steps.
#
# `teardown` is `converge` in reverse, and that has to hold for every module at
# once, so the contract lives here instead of being re-derived per module:
#
#   1. workloads off   cluster-wide steps a module declares itself
#                      (k3s.drain, incus.instances-off), priority band `workloads`
#   2. leave           `<module>.leave-<m>`: m leaves that module's cluster. A
#                      member waits for every member whose CONVERGE step waited
#                      for it — joiners leave before the bootstrap they joined.
#   3. cleanup         `<module>.cleanup-<m>`: that module's state is removed from
#                      m (data, units, runtime secrets). Waits for every leave of
#                      the module: no host is wiped while a peer still needs it.
#   4. switch back     core's `member-<m>`: m is switched to its base NixOS
#                      configuration. Waits for every cleanup of m.
#
# Within a phase, members go in the reverse of the order converge brought them
# up in, and on one member the modules go in a fixed order (`offset`), so the
# plan reads member by member. `scripts/teardown-roundtrip.jq` checks all of
# this against the converge plan.
{ lib }:

let
  stepPlan = import ./stepPlan.nix { inherit lib; };
  sshLib = import ./ssh.nix { inherit lib; };
in
rec {
  # Priority bands. Phases are separated by `deps` where it matters and by these
  # bands everywhere else: the plan is walked one step at a time, lowest
  # priority first among the ready ones. Each band leaves room for 1000 members.
  bands = {
    workloads = 100;
    leave = 10000;
    cleanup = 20000;
    member = 30000;
  };

  # member -> its position in the REVERSE of the converge member order (0 for
  # the member converge brought up last). Bind it once per cluster:
  #   rank = teardownLib.rankOf config;
  rankOf = cluster:
    let
      convergeMembers = map (lib.removePrefix "member-")
        (lib.filter (lib.hasPrefix "member-") (stepPlan "converge" cluster));
      reversed = lib.reverseList convergeMembers;
    in
    member: lib.lists.findFirstIndex (m: m == member) (lib.length reversed) reversed;

  # The members among `candidates` whose converge step waited for `member`.
  # Teardown reverses that edge: they must leave BEFORE `member` does.
  dependentsOf = cluster: candidates: member:
    lib.filter
      (other: other != member
        && lib.elem "member-${member}" (cluster.converge.steps."member-${other}".deps or [ ]))
      candidates;

  # The teardown steps of one module, in the shape described above.
  #
  #   module    step-name prefix, e.g. "k3s"
  #   members   the members the module runs on
  #   offset    the module's position among the modules on one member (0..9)
  #   after     cluster-wide steps every leave waits for (its "workloads off")
  #   leave     null, or member -> { description; run; }
  #   cleanup   member -> { description; run; }
  mkModuleSteps =
    { cluster, module, members, offset, after ? [ ], leave ? null, cleanup }:
    let
      rank = rankOf cluster;
      priority = band: member: band + 10 * (rank member) + offset;
      leaveName = member: "${module}.leave-${member}";
      cleanupName = member: "${module}.cleanup-${member}";

      leaveSteps = lib.optionalAttrs (leave != null) (lib.listToAttrs (map
        (member: lib.nameValuePair (leaveName member) ((leave member) // {
          phase = "leave";
          priority = priority bands.leave member;
          deps = after ++ map leaveName (dependentsOf cluster members member);
        }))
        members));

      cleanupSteps = lib.listToAttrs (map
        (member: lib.nameValuePair (cleanupName member) ((cleanup member) // {
          phase = "cleanup";
          priority = priority bands.cleanup member;
          deps = if leave != null then map leaveName members else after;
        }))
        members);

      # Core owns the switch-back step; a module only makes it wait.
      switchDeps = lib.listToAttrs (map
        (member: lib.nameValuePair "member-${member}" { deps = [ (cleanupName member) ]; })
        members);
    in
    leaveSteps // cleanupSteps // switchDeps;

  # One host-side step: run `script` as root on a member over SSH.
  #
  # An unreachable host is reported and skipped (exit 0), never fatal: teardown
  # must be able to dissolve a cluster whose machines are already gone. A host
  # that answers but fails the script fails the step, and everything that
  # depends on it is skipped.
  #
  # The script runs under bash with two helpers that make it idempotent, so a
  # teardown that stopped halfway can simply be run again:
  #   stop_unit <unit>...      stop each unit that exists; absent ones are fine
  #   remove_paths <path>...   unmount whatever is still mounted below each path
  #                            (deepest first), then delete it without crossing
  #                            into another file system
  mkHostStep = { pkgs, name, member, ip, script }:
    pkgs.writeShellApplication {
      name = "nixcluster-teardown-${name}-${member}";
      runtimeInputs = [ pkgs.openssh ];
      text = ''
        log() { echo "[${name}] ${member}: $*" >&2; }

        IP=${lib.escapeShellArg (if ip == null then "" else ip)}
        SSH_OPTS=(${sshLib.shellArgs} -o BatchMode=yes)

        if [[ -z "$IP" ]]; then
          log "no install.ip; skipped"
          exit 0
        fi
        if ! ssh "''${SSH_OPTS[@]}" "root@$IP" true </dev/null >/dev/null 2>&1; then
          log "unreachable at $IP; skipped, its state is left as it is"
          exit 0
        fi

        ssh "''${SSH_OPTS[@]}" "root@$IP" 'bash -s' <<'REMOTE'
        stop_unit() {
          local unit
          for unit in "$@"; do
            if systemctl cat "$unit" >/dev/null 2>&1; then
              systemctl stop "$unit" || return 1
            fi
          done
        }
        remove_paths() {
          local path mount
          for path in "$@"; do
            findmnt --list --noheadings --output TARGET | sort --reverse | while read -r mount; do
              case "$mount" in
                "$path" | "$path"/*) umount --lazy "$mount" || true ;;
              esac
            done
            rm --recursive --force --one-file-system "$path"
          done
        }
        ${script}
        REMOTE
      '';
    };
}
