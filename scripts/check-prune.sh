#!/usr/bin/env bash
# check-prune.sh — verify the converge prune logic without a cluster.
#
# Pruning is the one part of converge that DELETES things, so its safety rules
# have to be verifiable cheaply and often. Two layers:
#
#   Part A — the shared engine (lib/prune.nix) with the registry and the removal
#            command injected, so every branch is reachable deterministically:
#            no-op, one stale entry, unreachable host -> force, empty desired set
#            -> loud refusal, quorum-breaking removal -> refused.
#
#   Part B — the REAL k3s prune step, built from the cluster definition, run with
#            stub `kubectl` and `ssh` binaries on PATH. This is what checks that
#            the module's own commands are wired to the engine correctly.
#
# Usage: scripts/check-prune.sh
# Exit status is non-zero on the first failed expectation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIX=(nix --extra-experimental-features "nix-command flakes")

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

checks=0
failures=0

ok() { printf '    ok: %s\n' "$1"; checks=$((checks + 1)); }
fail() { printf '    FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# expect_contains <what> <haystack-file> <needle>
expect_contains() {
  if grep --quiet --fixed-strings --regexp="$3" -- "$2"; then
    ok "$1"
  else
    fail "$1
      expected to find: $3
      in:
$(sed 's/^/        /' "$2")"
  fi
}

# expect_absent <what> <haystack-file> <needle>
expect_absent() {
  if grep --quiet --fixed-strings --regexp="$3" -- "$2"; then
    fail "$1
      did NOT expect to find: $3
      in:
$(sed 's/^/        /' "$2")"
  else
    ok "$1"
  fi
}

# expect_exit <what> <expected> <actual>
expect_exit() {
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    fail "$1: exit $3, want $2"
  fi
}

# ---------------------------------------------------------------------------
# Part A — the engine, with the registry and removals injected.
#
# The engine reads $PRUNE_REGISTRY (one name per line) as the registry, appends
# every removal to $PRUNE_REMOVALS, and treats a name listed in $PRUNE_REACHABLE
# as a host that answers.
# ---------------------------------------------------------------------------
build_engine() { # desired-nix-list quorum -> prints the built script path
  "${NIX[@]}" build --impure --no-link --print-out-paths --expr "
    let
      pkgs = (builtins.getFlake \"nixpkgs\").legacyPackages.\${builtins.currentSystem};
      mkPruneStep = import $REPO_ROOT/lib/prune.nix { inherit (pkgs) lib; };
    in
    mkPruneStep {
      inherit pkgs;
      subject = \"fake\";
      desired = $1;
      quorumMinimum = $2;
      listRegistry = ''cat \"\$PRUNE_REGISTRY\"'';
      probeHost = ''grep --quiet --line-regexp \"\$1\" \"\$PRUNE_REACHABLE\"'';
      removeEntry = ''echo \"\$1 \$2\" >> \"\$PRUNE_REMOVALS\"'';
    }
  " 2>/dev/null
}

run_engine() { # script-dir registry-lines reachable-lines -> sets ENGINE_OUT/ENGINE_RC
  local exe="$1" registry="$2" reachable="${3:-}"
  export PRUNE_REGISTRY="$WORK_DIR/registry"
  export PRUNE_REACHABLE="$WORK_DIR/reachable"
  export PRUNE_REMOVALS="$WORK_DIR/removals"
  printf '%s\n' "$registry" > "$PRUNE_REGISTRY"
  printf '%s\n' "$reachable" > "$PRUNE_REACHABLE"
  : > "$PRUNE_REMOVALS"
  ENGINE_OUT="$WORK_DIR/out"
  set +e
  "$exe" > "$ENGINE_OUT" 2>&1
  ENGINE_RC=$?
  set -e
}

printf '==> Part A: the shared prune engine\n'

ENGINE="$(build_engine '[ "keep-1" "keep-2" "keep-3" ]' 2)/bin/nixcluster-prune-fake"
[[ -x "$ENGINE" ]] || { echo "could not build the engine harness" >&2; exit 1; }

printf '\n  registry == desired (no-op)\n'
run_engine "$ENGINE" "keep-1
keep-2
keep-3"
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "says it has nothing to prune" "$ENGINE_OUT" "nothing to prune"
expect_absent "reports no removals" "$ENGINE_OUT" "::nixcluster:removed::"
if [[ ! -s "$PRUNE_REMOVALS" ]]; then
  ok "runs no removal command"
else
  fail "a no-op ran removals: $(cat "$PRUNE_REMOVALS")"
fi

printf '\n  one stale entry, host unreachable (force path)\n'
run_engine "$ENGINE" "keep-1
keep-2
keep-3
gone-1"
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "takes the force path" "$ENGINE_OUT" "force path"
expect_contains "reports the removal" "$ENGINE_OUT" '"name":"gone-1"'
expect_contains "reports it as an action" "$ENGINE_OUT" '"action":"removed"'
expect_contains "removes exactly the stale entry" "$PRUNE_REMOVALS" "gone-1 unreachable"

printf '\n  one stale entry, host reachable (graceful path)\n'
run_engine "$ENGINE" "keep-1
keep-2
keep-3
gone-1" "gone-1"
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "drains first" "$ENGINE_OUT" "host reachable"
expect_contains "removes gracefully" "$PRUNE_REMOVALS" "gone-1 reachable"

printf '\n  quorum-breaking removal is refused\n'
# 3 registered, 2 of them stale -> 1 survivor, below the quorum minimum of 2.
run_engine "$ENGINE" "keep-1
gone-1
gone-2"
expect_exit "does not fail the run" 0 "$ENGINE_RC"
expect_contains "refuses loudly" "$ENGINE_OUT" "REFUSING to prune"
expect_contains "explains why" "$ENGINE_OUT" "below the 2 needed for quorum"
expect_contains "reports the refusal per member" "$ENGINE_OUT" '"status":"Failed"'
if [[ ! -s "$PRUNE_REMOVALS" ]]; then
  ok "removes nothing"
else
  fail "a refused prune still ran removals: $(cat "$PRUNE_REMOVALS")"
fi

printf '\n  an empty desired set fails loudly and prunes nothing\n'
EMPTY_ENGINE="$(build_engine '[ ]' 2)/bin/nixcluster-prune-fake"
run_engine "$EMPTY_ENGINE" "keep-1
keep-2"
expect_exit "fails the step" 1 "$ENGINE_RC"
expect_contains "refuses loudly" "$ENGINE_OUT" "the desired member set is empty"
expect_contains "names the likely cause" "$ENGINE_OUT" "broken or truncated"
if [[ ! -s "$PRUNE_REMOVALS" ]]; then
  ok "removes nothing"
else
  fail "an empty desired set still ran removals: $(cat "$PRUNE_REMOVALS")"
fi

printf '\n  an unreadable registry is not a licence to prune\n'
run_engine "$ENGINE" "keep-1"
rm -f "$PRUNE_REGISTRY" # listRegistry now fails
set +e
"$ENGINE" > "$ENGINE_OUT" 2>&1
ENGINE_RC=$?
set -e
expect_exit "gives up quietly" 0 "$ENGINE_RC"
expect_contains "says it skipped" "$ENGINE_OUT" "could not read the registry"
if [[ ! -s "$PRUNE_REMOVALS" ]]; then
  ok "removes nothing"
else
  fail "an unreadable registry still ran removals: $(cat "$PRUNE_REMOVALS")"
fi

# ---------------------------------------------------------------------------
# Part B — the real k3s prune step with stubbed kubectl and ssh.
# ---------------------------------------------------------------------------
printf '\n==> Part B: the k3s prune step with stubbed kubectl/ssh\n'

# The step is built from the cluster definition, so this exercises the module's
# OWN commands against stubbed binaries — see scripts/prune-stubs.nix.
K3S_PRUNE="$("${NIX[@]}" build --impure --no-link --print-out-paths \
  --file "$REPO_ROOT/scripts/prune-stubs.nix" --argstr repoRoot "$REPO_ROOT" \
  2>&1 | tail -n 1)/bin/nixcluster-prune-k3s"
[[ -x "$K3S_PRUNE" ]] || { echo "could not build the k3s prune step: $K3S_PRUNE" >&2; exit 1; }

run_k3s_prune() { # registry-nodes servers reachable
  export STUB_CALLS="$WORK_DIR/calls"
  export STUB_NODES="$WORK_DIR/nodes"
  export STUB_SERVERS="$WORK_DIR/servers"
  export STUB_REACHABLE="$WORK_DIR/k3s-reachable"
  printf '%s\n' "$1" > "$STUB_NODES"
  printf '%s\n' "$2" > "$STUB_SERVERS"
  printf '%s\n' "$3" > "$STUB_REACHABLE"
  : > "$STUB_CALLS"
  # The step needs the kubeconfig converge would have fetched.
  mkdir -p "$WORK_DIR/run/kubeconfig"
  : > "$WORK_DIR/run/kubeconfig/dev.yaml"
  ENGINE_OUT="$WORK_DIR/k3s-out"
  set +e
  (cd "$WORK_DIR/run" && "$K3S_PRUNE") > "$ENGINE_OUT" 2>&1
  ENGINE_RC=$?
  set -e
}

# The `dev` cluster's members are node1, node2 (servers) and worker1 (agent).
printf '\n  registry matches the cluster definition\n'
run_k3s_prune "node1
node2
worker1" "node1
node2" ""
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "nothing to prune" "$ENGINE_OUT" "nothing to prune"
expect_absent "does not delete a node" "$STUB_CALLS" "delete node"

printf '\n  a departed agent is removed\n'
run_k3s_prune "node1
node2
worker1
old-worker" "node1
node2" ""
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "deletes the Node object" "$STUB_CALLS" "delete node old-worker"
expect_absent "does not touch etcd for an agent" "$STUB_CALLS" "etcd.k3s.cattle.io/remove"
expect_contains "reports the removal" "$ENGINE_OUT" '"name":"old-worker"'

printf '\n  a departed SERVER also has its etcd member removed\n'
run_k3s_prune "node1
node2
worker1
old-server" "node1
node2
old-server" ""
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "removes the etcd member" "$STUB_CALLS" "etcd.k3s.cattle.io/remove=true"
expect_contains "deletes the Node object" "$STUB_CALLS" "delete node old-server"

printf '\n  a reachable departing node is drained and its k3s unit stopped\n'
run_k3s_prune "node1
node2
worker1
old-worker" "node1
node2" "10.0.0.9"
expect_exit "succeeds" 0 "$ENGINE_RC"
expect_contains "cordons first" "$STUB_CALLS" "cordon old-worker"
expect_contains "drains with a bounded timeout" "$STUB_CALLS" "--timeout=120s"
expect_contains "stops the k3s unit on the host" "$STUB_CALLS" "systemctl stop k3s"

printf '\n%d check(s) passed, %d failed\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
