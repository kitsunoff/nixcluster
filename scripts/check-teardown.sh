#!/usr/bin/env bash
# check-teardown.sh — verify the whole-cluster `teardown` command without a cluster.
#
# Teardown removes everything a cluster definition created, so what it does, in
# what order, and when it refuses to do anything must be verifiable cheaply and
# often. Two layers:
#
#   Part A — the plan of a cluster loading every module with a teardown step
#            (k3s, incus, keepalived, nebula, sops): its exact order, and the
#            round-trip property "teardown is converge in reverse"
#            (scripts/teardown-roundtrip.jq). Every template gets the same
#            round-trip check in scripts/check-templates.sh. Then what a member
#            is switched back to: its disk layout kept, the cluster dropped.
#
#   Part B — the REAL teardown command of that cluster, run with stub `ssh`,
#            `scp`, `kubectl` and `nix` (scripts/teardown-stubs.nix): the prompt
#            and its refusal, --dry-run, --auto-approve, an unreachable member, a
#            failed member, and the result JSON.
#
# Usage: scripts/check-teardown.sh
# Exit status is non-zero if any expectation failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIX=(nix --extra-experimental-features "nix-command flakes")
# Resolve jq once; `nix run` per call would re-evaluate nixpkgs every time.
JQ=("$("${NIX[@]}" build --no-link --print-out-paths nixpkgs#jq.bin)/bin/jq")

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

checks=0
failures=0

ok() { printf '    ok: %s\n' "$1"; checks=$((checks + 1)); }
fail() { printf '    FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

indent() { sed 's/^/        /' "$1"; }

# expect_contains <what> <haystack-file> <needle>
expect_contains() {
  if grep --quiet --fixed-strings --regexp="$3" -- "$2"; then
    ok "$1"
  else
    fail "$1
      expected to find: $3
      in:
$(indent "$2")"
  fi
}

# expect_absent <what> <haystack-file> <needle>
expect_absent() {
  if grep --quiet --fixed-strings --regexp="$3" -- "$2"; then
    fail "$1
      did NOT expect to find: $3
      in:
$(indent "$2")"
  else
    ok "$1"
  fi
}

# expect_eq <what> <expected> <actual>
expect_eq() {
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    fail "$1
      expected: $2
      actual:   $3"
  fi
}

# expect_before <what> <file> <first-needle> <second-needle>: the first line
# containing <first-needle> comes before the first containing <second-needle>.
expect_before() {
  local a b
  a="$(grep --line-number --fixed-strings --regexp="$3" -- "$2" | head -n 1 || true)"
  b="$(grep --line-number --fixed-strings --regexp="$4" -- "$2" | head -n 1 || true)"
  a="${a%%:*}"
  b="${b%%:*}"
  if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then
    ok "$1"
  else
    fail "$1: '$3' (line ${a:-none}) is not before '$4' (line ${b:-none})"
  fi
}

# expect_all_before <what> <file> <first-needle> <second-needle>: the LAST line
# containing <first-needle> comes before the first containing <second-needle>.
expect_all_before() {
  local a b
  a="$(grep --line-number --fixed-strings --regexp="$3" -- "$2" | tail -n 1 || true)"
  b="$(grep --line-number --fixed-strings --regexp="$4" -- "$2" | head -n 1 || true)"
  a="${a%%:*}"
  b="${b%%:*}"
  if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then
    ok "$1"
  else
    fail "$1: the last '$3' (line ${a:-none}) is not before '$4' (line ${b:-none})"
  fi
}

# expect_no_calls <what>: no stub was invoked at all — nothing touched a host.
expect_no_calls() {
  if [[ ! -s "$STUB_CALLS" ]]; then
    ok "$1"
  else
    fail "$1; recorded calls:
$(indent "$STUB_CALLS")"
  fi
}

# result_json: the payload of the single ::nixcluster:result:: line on stdout.
result_json() {
  local line
  while IFS= read -r line; do
    if [[ "$line" == '::nixcluster:result:: '* ]]; then
      printf '%s\n' "${line#'::nixcluster:result:: '}"
    fi
  done < "$OUT"
}

# jq_result <filter>: apply a jq filter to the result payload.
jq_result() {
  result_json | "${JQ[@]}" --compact-output --raw-output "$1"
}

# ---------------------------------------------------------------------------
# Part A — the plan, evaluated.
# ---------------------------------------------------------------------------
printf '==> Part A: the teardown plan of a cluster with every module\n'

PLAN="$WORK_DIR/plan.json"
"${NIX[@]}" eval --impure --json \
  --file "$REPO_ROOT/scripts/teardown-stubs.nix" --argstr repoRoot "$REPO_ROOT" \
  plan > "$PLAN" 2> "$WORK_DIR/plan.err" || true

if ! "${JQ[@]}" --exit-status '.teardown.order' "$PLAN" >/dev/null 2>&1; then
  fail "the teardown plan does not evaluate
$(tail -n 15 "$WORK_DIR/plan.err" | sed 's/^/        /')"
else
  ok "the teardown plan evaluates"

  # node-1 bootstraps both k3s and Incus; node-4 is the k3s agent. Converge runs
  # node-1, node-2, node-3, node-4 — so teardown undoes node-4 first and node-1
  # last, one phase at a time.
  EXPECTED_ORDER="k3s.drain incus.instances-off
k3s.leave-node-4 incus.leave-node-4 k3s.leave-node-3 incus.leave-node-3
k3s.leave-node-2 incus.leave-node-2 k3s.leave-node-1 incus.leave-node-1
k3s.cleanup-node-4 incus.cleanup-node-4 nebula.cleanup-node-4 sops.cleanup-node-4
k3s.cleanup-node-3 incus.cleanup-node-3 nebula.cleanup-node-3 sops.cleanup-node-3
k3s.cleanup-node-2 incus.cleanup-node-2 keepalived.cleanup-node-2 nebula.cleanup-node-2 sops.cleanup-node-2
k3s.cleanup-node-1 incus.cleanup-node-1 keepalived.cleanup-node-1 nebula.cleanup-node-1 sops.cleanup-node-1
member-node-4 member-node-3 member-node-2 member-node-1"
  expect_eq "teardown order" \
    "$(printf '%s' "$EXPECTED_ORDER" | tr '\n' ' ')" \
    "$("${JQ[@]}" --raw-output '.teardown.order | join(" ")' "$PLAN")"

  expect_eq "converge order is the one teardown reverses" \
    "member-node-1 member-node-2 member-node-3 member-node-4" \
    "$("${JQ[@]}" --raw-output '[.converge.order[] | select(startswith("member-"))] | join(" ")' "$PLAN")"

  ROUNDTRIP="$("${JQ[@]}" --raw-output --from-file "$REPO_ROOT/scripts/teardown-roundtrip.jq" "$PLAN" 2>&1)"
  expect_eq "teardown is converge in reverse (round trip)" "[]" "$(printf '%s' "$ROUNDTRIP" | tr -d ' \n')"

  # The bootstrap leaves last because it waits for every member that joined it.
  expect_eq "the k3s bootstrap waits for every other k3s member to leave" \
    "k3s.drain k3s.leave-node-2 k3s.leave-node-3 k3s.leave-node-4" \
    "$("${JQ[@]}" --raw-output '.teardown.deps["k3s.leave-node-1"] | sort | join(" ")' "$PLAN")"
  expect_eq "a member switches only after its own cleanup" \
    "incus.cleanup-node-2 k3s.cleanup-node-2 keepalived.cleanup-node-2 nebula.cleanup-node-2 sops.cleanup-node-2" \
    "$("${JQ[@]}" --raw-output '.teardown.deps["member-node-2"] | sort | join(" ")' "$PLAN")"
fi

printf '\n==> Part A: what a member is switched back to\n'

# The flake's own `dev` cluster loads disko and k3s on a base that includes the
# disko NixOS module. Its base configuration must keep the disk layout (the
# host has to boot from the same disk afterwards) and drop the cluster.
base_eval() {
  "${NIX[@]}" eval --json "path:$REPO_ROOT#clusterConfigurations.dev.$1" ${2:+--apply "$2"} 2>&1 ||
    echo "<eval failed>"
}
DISKS='d: builtins.mapAttrs (_: v: v.device) d'
expect_eq "the disk layout survives teardown" \
  "$(base_eval 'nixosConfigurations.node1.config.disko.devices.disk' "$DISKS")" \
  "$(base_eval 'teardownNixosConfigurations.node1.config.disko.devices.disk' "$DISKS")"
expect_eq "the base still has a disk to boot from" '{"main":"/dev/sda"}' \
  "$(base_eval 'teardownNixosConfigurations.node1.config.disko.devices.disk' "$DISKS")"
expect_eq "the cluster is gone from the base" "false" \
  "$(base_eval 'teardownNixosConfigurations.node1.config.services.k3s.enable')"

# A member's own patches describe the machine (host name, network): dropping
# them can leave the host without an address, so the next converge cannot reach
# it. They stay; a patch for a cluster-module option (k3s.role) must still
# evaluate even though the module itself is gone.
expect_eq "the member's own patches stay in the base" '"node1"' \
  "$(base_eval 'teardownNixosConfigurations.node1.config.networking.hostName')"
expect_eq "a patch for a cluster-module option still evaluates" '"server"' \
  "$(base_eval 'teardownNixosConfigurations.node1.config.k3s.role')"
expect_eq "and the module behind it stays off" '[]' \
  "$(base_eval 'teardownNixosConfigurations.node1.config.systemd.services' \
    's: builtins.filter (n: n == "k3s" || n == "incus") (builtins.attrNames s)')"
# Teardown removes the decrypted secrets; the base must not decrypt them again
# on the switch back, even when the user's own configuration declares some.
expect_eq "the base decrypts no secrets" '[]' \
  "$(base_eval 'teardownNixosConfigurations.node1' \
    'c: builtins.attrNames (c.extendModules { modules = [ { sops.secrets."demo/token" = { }; } ]; }).config.sops.secrets')"

# ---------------------------------------------------------------------------
# Part B — the real command against stubs.
# ---------------------------------------------------------------------------
printf '\n==> Part B: the teardown command with stubbed ssh/scp/kubectl/nix\n'

TEARDOWN="$("${NIX[@]}" build --impure --no-link --print-out-paths \
  --file "$REPO_ROOT/scripts/teardown-stubs.nix" --argstr repoRoot "$REPO_ROOT" \
  teardown 2> "$WORK_DIR/build.err" | tail -n 1)/bin/nixclusterctl-lab-teardown"
if [[ ! -x "$TEARDOWN" ]]; then
  fail "could not build the teardown command
$(tail -n 15 "$WORK_DIR/build.err" | sed 's/^/        /')"
  printf '\n%d check(s) passed, %d failed\n' "$checks" "$failures"
  exit 1
fi

export STUB_CALLS="$WORK_DIR/calls"
export STUB_UNREACHABLE="$WORK_DIR/unreachable"
export STUB_NIX_FAIL="$WORK_DIR/nix-fail"
OUT="$WORK_DIR/stdout"
ERR="$WORK_DIR/stderr"

# run_teardown <stdin> [args...]: fresh stub state, run in a scratch dir (the k3s
# steps write kubeconfig/<cluster>.yaml there), capture stdout/stderr/exit code.
run_teardown() {
  local input="$1"
  shift
  : > "$STUB_CALLS"
  rm -rf "$WORK_DIR/run"
  mkdir -p "$WORK_DIR/run"
  set +e
  (cd "$WORK_DIR/run" && printf '%s' "$input" | "$TEARDOWN" "$@") > "$OUT" 2> "$ERR"
  RC=$?
  set -e
}

: > "$STUB_UNREACHABLE"
: > "$STUB_NIX_FAIL"

printf '\n  the plan is shown, then anything but "yes" refuses\n'
for answer in "no" "" "YES" "yes please" "y"; do
  run_teardown "$answer"$'\n'
  expect_eq "answer '$answer': exits 1" 1 "$RC"
  expect_no_calls "answer '$answer': runs no command against any host"
  expect_eq "answer '$answer': reports the cancellation" "cancelled" "$(jq_result '.result')"
done
expect_contains "asks terraform-style" "$ERR" "Enter a value:"
expect_contains "says only yes is accepted" "$ERR" "Only 'yes' will be accepted"
expect_contains "says it was cancelled" "$ERR" "Teardown cancelled"
expect_contains "the plan lists the members" "$ERR" "node-4 (10.0.0.4)"
expect_before "the plan lists steps in order: workloads before leaves" "$ERR" "k3s.drain" "k3s.leave-node-4"
expect_before "the plan lists steps in order: joiners before the bootstrap" "$ERR" "k3s.leave-node-4" "k3s.leave-node-1"
expect_before "the plan lists steps in order: cleanup before switching" "$ERR" "sops.cleanup-node-1" "member-node-4"
expect_before "the plan comes before the prompt" "$ERR" "member-node-1" "Enter a value:"

printf '\n  no answer at all (stdin closed) refuses\n'
run_teardown ""
expect_eq "exits 1" 1 "$RC"
expect_no_calls "runs no command against any host"

printf '\n  --dry-run prints the plan and touches nothing\n'
run_teardown "" --dry-run
expect_eq "exits 0" 0 "$RC"
expect_no_calls "runs no command against any host"
expect_absent "does not prompt" "$ERR" "Enter a value:"
expect_contains "prints the plan" "$ERR" "incus.leave-node-1"
expect_eq "every member is planned for destruction, not destroyed" \
  "node-1:destroyed:Skipped:dry-run node-2:destroyed:Skipped:dry-run node-3:destroyed:Skipped:dry-run node-4:destroyed:Skipped:dry-run" \
  "$(jq_result '[.members[] | "\(.name):\(.action):\(.status):\(.message)"] | sort | join(" ")')"
expect_eq "every step is skipped as dry-run" "true" \
  "$(jq_result '(.steps | length) > 0 and (.steps | all(.status == "skipped" and .message == "dry-run"))')"
expect_eq "a plan is a success, not a partial run" "success" "$(jq_result '.result')"
expect_eq "the plan reports the member steps too" "member-node-1 member-node-2 member-node-3 member-node-4" \
  "$(jq_result '[.steps[] | select(.phase == "member") | .name] | sort | join(" ")')"

printf '\n  "yes" proceeds\n'
run_teardown $'yes\n'
expect_eq "exits 0" 0 "$RC"
expect_eq "result is success" "success" "$(jq_result '.result')"
expect_contains "runs commands against the hosts" "$STUB_CALLS" "ssh "

printf '\n  --auto-approve proceeds without asking\n'
run_teardown "" --auto-approve
expect_eq "exits 0" 0 "$RC"
expect_absent "does not prompt" "$ERR" "Enter a value:"
expect_eq "result is success" "success" "$(jq_result '.result')"
expect_eq "every member is destroyed" \
  "node-1:destroyed:Applied node-2:destroyed:Applied node-3:destroyed:Applied node-4:destroyed:Applied" \
  "$(jq_result '[.members[] | "\(.name):\(.action):\(.status)"] | sort | join(" ")')"
expect_eq "every step succeeded" "true" "$(jq_result '.steps | all(.status == "ok")')"

# What actually ran, in what order.
expect_contains "workloads off: k3s nodes are drained" "$STUB_CALLS" "kubectl --request-timeout=20s drain node-4"
expect_contains "workloads off: Incus instances are deleted" "$STUB_CALLS" "incus delete --force"
expect_contains "a k3s joiner server leaves etcd" "$STUB_CALLS" "etcd.k3s.cattle.io/remove=true"
expect_contains "an Incus joiner is removed through the bootstrap" "$STUB_CALLS" "incus cluster remove"
expect_contains "k3s is stopped" "$STUB_CALLS" "stop_unit k3s.service"
expect_contains "k3s data is removed" "$STUB_CALLS" "remove_paths /etc/rancher /var/lib/rancher"
expect_contains "Incus state is removed" "$STUB_CALLS" "remove_paths /var/lib/incus"
expect_contains "keepalived is stopped" "$STUB_CALLS" "stop_unit keepalived.service"
expect_contains "nebula is stopped" "$STUB_CALLS" "stop_unit nebula@"
expect_contains "sops secrets are removed from /run" "$STUB_CALLS" "remove_paths /run/secrets"
expect_absent "the age key is kept, so a later converge can decrypt again" "$STUB_CALLS" "/etc/age"
expect_contains "the base configuration is built" "$STUB_CALLS" 'teardownNixosConfigurations."node-1"'
expect_contains "and copied to the member" "$STUB_CALLS" "copy --to ssh://root@10.0.0.1"
expect_contains "and switched to" "$STUB_CALLS" "bin/switch-to-configuration switch"
expect_before "the agent leaves before the bootstrap" "$STUB_CALLS" "drain node-4" "copy --to ssh://root@10.0.0.4"
expect_all_before "every Incus joiner is removed before any cleanup" "$STUB_CALLS" "incus cluster remove" "remove_paths /etc/rancher"
expect_before "members are switched back last-converged first" "$STUB_CALLS" "copy --to ssh://root@10.0.0.4" "copy --to ssh://root@10.0.0.1"

printf '\n  the result contract\n'
expect_eq "exactly one line on stdout" 1 "$(wc -l < "$OUT" | tr -d ' ')"
expect_eq "it is the result marker" 1 "$(grep --count '^::nixcluster:result:: {' "$OUT")"
expect_eq "result keys" '["cluster","members","result","steps"]' "$(jq_result 'keys')"
expect_eq "cluster name" "lab" "$(jq_result '.cluster')"
expect_eq "member keys" '["action","durationSeconds","ip","message","name","status"]' \
  "$(jq_result '[.members[] | keys] | unique | .[0]')"
expect_eq "step keys" '["message","name","phase","status"]' "$(jq_result '[.steps[] | keys] | unique | .[0]')"
expect_eq "steps are reported in plan order, member steps included" \
  "$(printf '%s' "${EXPECTED_ORDER:-}" | tr '\n' ' ')" \
  "$(jq_result '.steps | map(.name) | join(" ")')"
expect_eq "a member step carries the member phase" "member:ok" \
  "$(jq_result '.steps[] | select(.name == "member-node-1") | "\(.phase):\(.status)"')"
run_teardown "" --auto-approve --json
expect_eq "--json: stdout is the bare object" "lab" "$(head -n 1 "$OUT" | "${JQ[@]}" --raw-output '.cluster')"
expect_eq "--json: and only that" 1 "$(wc -l < "$OUT" | tr -d ' ')"
expect_eq "--json: the marker line still reaches the log (stderr) for greppers" \
  "$(head -n 1 "$OUT")" \
  "$(sed -n 's/^::nixcluster:result:: //p' "$ERR")"

printf '\n  an unreachable member is reported, not fatal\n'
printf '10.0.0.3\n' > "$STUB_UNREACHABLE"
run_teardown "" --auto-approve
expect_eq "exits 0" 0 "$RC"
expect_eq "result is partial" "partial" "$(jq_result '.result')"
expect_eq "the unreachable member is skipped and says why" "destroyed:Skipped:true" \
  "$(jq_result '.members[] | select(.name == "node-3") | "\(.action):\(.status):\(.message | test("unreachable"))"')"
expect_eq "its member step says it was skipped" "skipped" \
  "$(jq_result '.steps[] | select(.name == "member-node-3") | .status')"
expect_eq "the others are destroyed" "node-1:Applied node-2:Applied node-4:Applied" \
  "$(jq_result '[.members[] | select(.name != "node-3") | "\(.name):\(.status)"] | sort | join(" ")')"
expect_contains "the log names it" "$ERR" "unreachable"
expect_absent "nothing is copied to it" "$STUB_CALLS" "copy --to ssh://root@10.0.0.3"
: > "$STUB_UNREACHABLE"

printf '\n  a member that fails to switch fails the run\n'
printf 'node-2\n' > "$STUB_NIX_FAIL"
run_teardown "" --auto-approve
expect_eq "exits 1" 1 "$RC"
expect_eq "result is failed" "failed" "$(jq_result '.result')"
expect_eq "the member is reported as failed" "destroyed:Failed" \
  "$(jq_result '.members[] | select(.name == "node-2") | "\(.action):\(.status)"')"
expect_eq "and so is its member step" "failed" \
  "$(jq_result '.steps[] | select(.name == "member-node-2") | .status')"
expect_eq "the others are still destroyed" "node-1:Applied node-3:Applied node-4:Applied" \
  "$(jq_result '[.members[] | select(.name != "node-2") | "\(.name):\(.status)"] | sort | join(" ")')"
: > "$STUB_NIX_FAIL"

printf '\n  usage\n'
run_teardown "" --bogus
expect_eq "an unknown flag exits 1" 1 "$RC"
expect_no_calls "and touches nothing"
run_teardown "" --help
expect_eq "--help exits 0" 0 "$RC"
expect_contains "--help names every flag" "$ERR" "[--dry-run] [--json] [--auto-approve]"

printf '\n%d check(s) passed, %d failed\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
