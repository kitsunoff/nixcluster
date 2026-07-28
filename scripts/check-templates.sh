#!/usr/bin/env bash
# check-templates.sh — evaluate every registered flake template against this
# worktree.
#
# For each `templates.<name>` in flake.nix: copy the template to a temp dir, lock
# it with `--override-input nixcluster path:<repo root>` so the check exercises
# the code in front of you rather than whatever GitHub currently serves, and then
# assert by EVALUATION:
#
#   1. clusterConfigurations.<cluster>.config.members  = the expected members
#   2. nixosConfigurations                             contains <cluster>-<member>
#   3. apps.aarch64-linux.cluster-<cluster>             exists
#   4. converge steps and their deps                   match the scenario contract
#   5. every member's system.build.toplevel.drvPath     evaluates
#
# (5) is full NixOS module evaluation — it catches option and type errors across
# the whole configuration — but it deliberately does NOT build anything.
#
# Usage:
#   scripts/check-templates.sh              # every template
#   scripts/check-templates.sh k3s-ha       # one or more templates by name
#
# Exit status is non-zero on the first mismatch.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIX=(nix --extra-experimental-features "nix-command flakes")

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0
checks=0

fail() {
  printf '    FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

ok() {
  printf '    ok: %s\n' "$1"
  checks=$((checks + 1))
}

# assert_eq <what> <expected> <actual>
assert_eq() {
  local what="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$what"
  else
    fail "$what
      expected: $expected
      actual:   $actual"
  fi
}

# eval_json <flake-dir> <attr-expr> — evaluate an attribute to compact JSON.
eval_json() {
  local dir="$1" expr="$2"
  "${NIX[@]}" eval --json "$dir#$expr" 2>&1
}

# ---------------------------------------------------------------------------
# Per-scenario expectations. Keep these in sync with the templates: that is the
# point — a template whose converge plan drifts from its documented contract is
# a bug in one of the two, and this script says which.
#
# Format: EXPECT_MEMBERS[<template>]  = space-separated member names (sorted)
#         EXPECT_CLUSTER[<template>]  = the cluster attribute name
#         EXPECT_DEPS[<template>]     = "<step>:<dep>,<dep> <step>:<dep>" pairs,
#                                       deps sorted; "-" means no dependencies
# ---------------------------------------------------------------------------
declare -A EXPECT_CLUSTER=(
  [default]="example"
  [k3s-single]="k3s-single"
  [k3s-ha]="k3s-ha"
  [incus-cluster]="incus-cluster"
)

declare -A EXPECT_MEMBERS=(
  [default]="node1"
  [k3s-single]="server-1"
  [k3s-ha]="agent-1 agent-2 server-1 server-2 server-3"
  [incus-cluster]="node-1 node-2 node-3"
)

declare -A EXPECT_DEPS=(
  [default]="member-node1:- k3s.bootstrap:member-node1 k3s.kubeconfig:member-node1 k3s.prune:k3s.kubeconfig,member-node1"
  [k3s-single]="member-server-1:- k3s.bootstrap:member-server-1 k3s.kubeconfig:member-server-1 k3s.prune:k3s.kubeconfig,member-server-1"
  # The HA contract: servers 2 and 3 wait for server 1 (etcd bootstrap) and not
  # for each other; every agent waits for ALL servers; the kubeconfig needs only
  # the servers.
  [k3s-ha]="member-server-1:- member-server-2:member-server-1 member-server-3:member-server-1 member-agent-1:member-server-1,member-server-2,member-server-3 member-agent-2:member-server-1,member-server-2,member-server-3 k3s.bootstrap:member-server-1,member-server-2,member-server-3 k3s.kubeconfig:member-server-1,member-server-2,member-server-3 k3s.prune:k3s.kubeconfig,member-agent-1,member-agent-2,member-server-1,member-server-2,member-server-3"
  # The Incus contract: joiners wait for the bootstrap and not for each other;
  # the join/reconcile steps wait for every member.
  [incus-cluster]="member-node-1:- member-node-2:member-node-1 member-node-3:member-node-1 incus.cluster-join:member-node-1,member-node-2,member-node-3 incus.reconcile:member-node-1,member-node-2,member-node-3 incus.prune:incus.cluster-join,incus.reconcile,member-node-1,member-node-2,member-node-3"
)

# check_template <name>
check_template() {
  local name="$1"
  local cluster="${EXPECT_CLUSTER[$name]:-}"
  if [[ -z "$cluster" ]]; then
    fail "template '$name' has no expectations in $0 — add them"
    return
  fi

  printf '\n==> %s\n' "$name"
  local dir="$WORK_DIR/$name"
  cp -R "$REPO_ROOT/templates/$name" "$dir"
  chmod -R u+w "$dir"

  # A flake must be a git repo (or all files must be there) for path: inputs to
  # resolve cleanly; a bare directory flake works, but locking needs write access.
  (
    cd "$dir"
    "${NIX[@]}" flake lock --override-input nixcluster "path:$REPO_ROOT" >/dev/null 2>&1 || {
      # Re-run without suppression so the user sees why.
      "${NIX[@]}" flake lock --override-input nixcluster "path:$REPO_ROOT"
    }
  )

  # 1. members — names only: a member may carry its own `nixosConfiguration`,
  # which is a Nix value with no JSON form.
  local members
  members="$("${NIX[@]}" eval --json "$dir#clusterConfigurations.$cluster.config.members" \
    --apply 'builtins.attrNames' 2>/dev/null |
    "${NIX[@]}" run nixpkgs#jq -- --raw-output 'join(" ")' 2>/dev/null ||
    echo "<eval failed>")"
  assert_eq "members" "${EXPECT_MEMBERS[$name]}" "$members"

  # 2. nixosConfigurations.<cluster>-<member> for every member
  local missing=""
  for member in ${EXPECT_MEMBERS[$name]}; do
    if ! "${NIX[@]}" eval "$dir#nixosConfigurations.\"$cluster-$member\".config.system.stateVersion" >/dev/null 2>&1; then
      missing="$missing $cluster-$member"
    fi
  done
  assert_eq "nixosConfigurations" "" "$missing"

  # 3. the per-cluster CLI app. Force the `program` path, not just `type`: the
  # program is what pulls in the converge plan, and a plan with a dependency
  # cycle only fails once something forces it.
  if "${NIX[@]}" eval --raw "$dir#apps.aarch64-linux.cluster-$cluster.program" >/dev/null 2>&1; then
    ok "apps.aarch64-linux.cluster-$cluster builds its program path"
  else
    fail "apps.aarch64-linux.cluster-$cluster does not evaluate
$("${NIX[@]}" eval --raw "$dir#apps.aarch64-linux.cluster-$cluster.program" 2>&1 | tail -n 5)"
  fi

  # 3b. the resolved converge order must exist — this is what runs the
  # topological sort, so an unknown dependency or a cycle fails here by name.
  local order
  order="$("${NIX[@]}" eval --json "$dir#clusterConfigurations.$cluster.convergeOrder" 2>&1)"
  if [[ "$order" == \[* ]]; then
    ok "convergeOrder resolves: $(printf '%s' "$order" | tr -d '[]"' | tr ',' ' ')"
  else
    fail "convergeOrder does not resolve
$(printf '%s' "$order" | tail -n 5)"
  fi

  # 4. converge steps and their deps — the real assertion. Project to deps only:
  # a step's `run` is a function, which has no JSON form.
  local actual_deps
  actual_deps="$("${NIX[@]}" eval --json \
    "$dir#clusterConfigurations.$cluster.config.converge.steps" \
    --apply 'steps: builtins.mapAttrs (_: step: step.deps) steps' 2>/dev/null |
    "${NIX[@]}" run nixpkgs#jq -- --raw-output '
      to_entries
      | map(.key + ":" + (if (.value | length) == 0
                          then "-"
                          else (.value | sort | join(",")) end))
      | sort | join(" ")' 2>/dev/null || echo "<eval failed>")"
  local expected_deps
  expected_deps="$(printf '%s\n' ${EXPECT_DEPS[$name]} | sort | tr '\n' ' ')"
  expected_deps="${expected_deps% }"
  assert_eq "converge steps + deps" "$expected_deps" "$actual_deps"

  # 5. every member's toplevel EVALUATES (full module eval, no build)
  local uneval=""
  for member in ${EXPECT_MEMBERS[$name]}; do
    if ! "${NIX[@]}" eval --raw \
      "$dir#nixosConfigurations.\"$cluster-$member\".config.system.build.toplevel.drvPath" \
      >/dev/null 2>&1; then
      uneval="$uneval $cluster-$member"
    fi
  done
  assert_eq "member toplevels evaluate" "" "$uneval"
}

# ---------------------------------------------------------------------------

if [[ $# -gt 0 ]]; then
  templates=("$@")
else
  # Every registered template, minus the aliases that point at another one
  # (checking the same directory twice proves nothing).
  mapfile -t templates < <("${NIX[@]}" eval --json "$REPO_ROOT#templates" \
    --apply 'ts: builtins.attrNames ts' |
    "${NIX[@]}" run nixpkgs#jq -- --raw-output '.[]' |
    grep --invert-match '^nixcluster$')
fi

printf 'Checking %d template(s) against %s\n' "${#templates[@]}" "$REPO_ROOT"

for name in "${templates[@]}"; do
  check_template "$name"
done

printf '\n%d check(s) passed, %d failed\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
