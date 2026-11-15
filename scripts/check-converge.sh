#!/usr/bin/env bash
# check-converge.sh — run the REAL `converge` command against stubbed hosts.
#
# converge decides per member whether to install (nixos-anywhere, which wipes
# the disk) or to switch, waits for what it installed, and gates every later
# step on the ones before it. Those decisions are only visible at runtime, so
# this script builds the converge command of a small k3s + Incus cluster with
# `ssh`, `scp`, `nixos-anywhere`, `nixos-rebuild`, `nix` and `kubectl` replaced
# by stubs (scripts/converge-stubs.nix) and drives it through each case.
#
# Usage: scripts/check-converge.sh
# Exit status is non-zero if any expectation failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIX=(nix --extra-experimental-features "nix-command flakes")
# Resolve jq once; `nix run` per call would re-evaluate nixpkgs every time.
JQ=("$("${NIX[@]}" build --no-link --print-out-paths nixpkgs#jq.bin)/bin/jq")

# Resolved: on macOS the temp dir sits behind the /var symlink, and a fake host
# root must read back the same path `readlink -f` reports inside it.
WORK_DIR="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK_DIR"' EXIT

checks=0
failures=0

ok() { printf '    ok: %s\n' "$1"; checks=$((checks + 1)); }
fail() { printf '    FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

indent() { sed 's/^/        /' "$1"; }

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

# expect_no_calls <what>: no stub was invoked at all — nothing touched a host.
expect_no_calls() {
  if [[ ! -s "$STUB_CALLS" ]]; then
    ok "$1"
  else
    fail "$1; recorded calls:
$(indent "$STUB_CALLS")"
  fi
}

# expect_every_ssh_call <what>: every recorded ssh/scp invocation (and every
# NIX_SSHOPTS handed to nix or nixos-rebuild) uses nixcluster's shared ssh
# options: no host-key prompt or banner, no known_hosts entry, and the
# system-wide ssh_config skipped (its options can be unsupported by this ssh).
expect_every_ssh_call() {
  local bad
  bad="$(grep --extended-regexp '^(ssh|scp) |NIX_SSHOPTS=' "$STUB_CALLS" | grep --invert-match --extended-regexp \
    -e '-F /nix/store/[a-z0-9]+-nixcluster-ssh-config .*StrictHostKeyChecking=no .*UserKnownHostsFile=/dev/null .*LogLevel=ERROR' || true)"
  if [[ -z "$bad" ]] && grep --quiet --extended-regexp '^(ssh|scp) ' "$STUB_CALLS"; then
    ok "$1"
  else
    fail "$1; calls without the shared options:
$(printf '%s\n' "$bad" | sed 's/^/        /')"
  fi
}

# result_json: the payload of the ::nixcluster:result:: line on stdout.
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

printf '==> building the converge command with stubbed hosts\n'
CONVERGE="$("${NIX[@]}" build --impure --no-link --print-out-paths \
  --file "$REPO_ROOT/scripts/converge-stubs.nix" --argstr repoRoot "$REPO_ROOT" \
  converge 2> "$WORK_DIR/build.err" | tail -n 1 || true)/bin/nixclusterctl-lab-converge"
if [[ ! -x "$CONVERGE" ]]; then
  fail "could not build the converge command
$(tail -n 15 "$WORK_DIR/build.err" | sed 's/^/        /')"
  printf '\n%d check(s) passed, %d failed\n' "$checks" "$failures"
  exit 1
fi

export STUB_CALLS="$WORK_DIR/calls"
export STUB_ROOT="$WORK_DIR/hosts"
export STUB_UNREACHABLE="$WORK_DIR/unreachable"
export STUB_ANYWHERE_FAIL="$WORK_DIR/anywhere-fail"
export STUB_ANYWHERE_HANG="$WORK_DIR/anywhere-hang"
export STUB_WRONG_SYSTEM="$WORK_DIR/wrong-system"
OUT="$WORK_DIR/stdout"
ERR="$WORK_DIR/stderr"

SYSTEM_PREFIX="/nix/store/00000000000000000000000000000000-nixos-system-lab-"

# host_state <ip> fresh|installer|installed: what the member looks like.
host_state() {
  local root="$STUB_ROOT/$1"
  rm -rf "$root"
  mkdir -p "$root"
  case "$2" in
    fresh) ;;
    installer)
      mkdir -p "$root/etc" "$root/run" "$root/nix/store/installer-system"
      printf 'ID=nixos\nVARIANT_ID=installer\n' > "$root/etc/os-release"
      ln -s "$root/nix/store/installer-system" "$root/run/current-system"
      ;;
    installed)
      local member="node-${1##*.}"
      mkdir -p "$root/etc" "$root/run" "$root$SYSTEM_PREFIX$member"
      printf 'ID=nixos\n' > "$root/etc/os-release"
      ln -s "$root$SYSTEM_PREFIX$member" "$root/run/current-system"
      ;;
  esac
}

# run_converge [args...]: fresh stub log, run in a scratch dir (the k3s steps
# write kubeconfig/<cluster>.yaml there), capture stdout/stderr/exit code.
run_converge() {
  : > "$STUB_CALLS"
  rm -rf "$WORK_DIR/run"
  mkdir -p "$WORK_DIR/run"
  set +e
  (cd "$WORK_DIR/run" && "$CONVERGE" "$@" </dev/null) > "$OUT" 2> "$ERR"
  RC=$?
  set -e
}

reset_hosts() { # state for both members
  : > "$STUB_UNREACHABLE"
  : > "$STUB_ANYWHERE_FAIL"
  : > "$STUB_ANYWHERE_HANG"
  : > "$STUB_WRONG_SYSTEM"
  unset STUB_REBOOT_SECONDS
  host_state 10.0.0.1 "$1"
  host_state 10.0.0.2 "$1"
}

printf '\n  installed members are switched, every step runs\n'
reset_hosts installed
run_converge
expect_eq "exits 0" 0 "$RC"
expect_eq "result is success" "success" "$(jq_result '.result')"
expect_eq "both members are switched" "node-1:switch:Applied node-2:switch:Applied" \
  "$(jq_result '[.members[] | "\(.name):\(.action):\(.status)"] | sort | join(" ")')"
expect_absent "nothing is installed" "$STUB_CALLS" "nixos-anywhere"
expect_eq "every step is reported in plan order, member steps included" \
  "$("${NIX[@]}" eval --impure --raw --file "$REPO_ROOT/scripts/converge-stubs.nix" --argstr repoRoot "$REPO_ROOT" order --apply 'builtins.concatStringsSep " "')" \
  "$(jq_result '.steps | map(.name) | join(" ")')"
expect_every_ssh_call "every ssh, scp and nixos-rebuild call uses the shared ssh options"
expect_contains "the kubeconfig is fetched with them too" "$STUB_CALLS" "scp -F "
expect_eq "member steps carry the member phase and succeeded" "member:ok member:ok" \
  "$(jq_result '[.steps[] | select(.name | startswith("member-")) | "\(.phase):\(.status)"] | join(" ")')"

printf '\n  fresh members are installed\n'
reset_hosts fresh
run_converge
expect_eq "exits 0" 0 "$RC"
expect_eq "both members are installed" "node-1:install:Applied node-2:install:Applied" \
  "$(jq_result '[.members[] | "\(.name):\(.action):\(.status)"] | sort | join(" ")')"
expect_contains "with nixos-anywhere" "$STUB_CALLS" "nixos-anywhere --flake .#lab-node-1"
expect_absent "and nothing is switched" "$STUB_CALLS" "nixos-rebuild"

printf '\n  a member still in the kexec installer is installed, not switched\n'
# An interrupted install leaves the host in nixos-anywhere's kexec installer,
# which has a /run/current-system of its own. Switching it would put the
# cluster's system on a RAM disk that is gone after the next reboot.
reset_hosts installed
host_state 10.0.0.2 installer
run_converge
expect_eq "exits 0" 0 "$RC"
expect_eq "the installer member is installed" "install:Applied" \
  "$(jq_result '.members[] | select(.name == "node-2") | "\(.action):\(.status)"')"
expect_contains "with nixos-anywhere" "$STUB_CALLS" "nixos-anywhere --flake .#lab-node-2"
expect_absent "and is not switched" "$STUB_CALLS" "nixos-rebuild switch --flake .#lab-node-2"
expect_eq "the installed member is still switched" "switch:Applied" \
  "$(jq_result '.members[] | select(.name == "node-1") | "\(.action):\(.status)"')"

printf '\n  a failed install fails the member and skips what depends on it\n'
reset_hosts fresh
printf '10.0.0.1\n' > "$STUB_ANYWHERE_FAIL"
run_converge
expect_eq "exits 1" 1 "$RC"
expect_eq "the member failed" "install:Failed" \
  "$(jq_result '.members[] | select(.name == "node-1") | "\(.action):\(.status)"')"
expect_eq "the member that joins it is skipped" "Skipped" \
  "$(jq_result '.members[] | select(.name == "node-2") | .status')"
expect_eq "so is every step after it" "true" \
  "$(jq_result '[.steps[] | select(.name != "member-node-1") | .status] | all(. == "skipped")')"

printf '\n  a hanging nixos-anywhere is stopped by the install timeout\n'
reset_hosts fresh
printf '10.0.0.1\n' > "$STUB_ANYWHERE_HANG"
started=$(date +%s)
run_converge
elapsed=$(( $(date +%s) - started ))
expect_eq "exits 1" 1 "$RC"
expect_eq "within the timeout, not after the hang (3s timeout, ${elapsed}s)" "true" \
  "$([[ "$elapsed" -lt 30 ]] && echo true || echo false)"
expect_eq "the member failed and says it timed out" "install:Failed:true" \
  "$(jq_result '.members[] | select(.name == "node-1") | "\(.action):\(.status):\(.message | test("timed out"))"')"
expect_eq "what depends on it is skipped" "Skipped" \
  "$(jq_result '.members[] | select(.name == "node-2") | .status')"

printf '\n  after an install converge waits for the member to come back\n'
# nixos-anywhere returns while the host reboots into its new system. The steps
# after it (kubeconfig, Incus join) need the host up and on that system.
reset_hosts fresh
export STUB_REBOOT_SECONDS=2
run_converge
expect_eq "exits 0" 0 "$RC"
expect_eq "both members are installed" "node-1:install:Applied node-2:install:Applied" \
  "$(jq_result '[.members[] | "\(.name):\(.action):\(.status)"] | sort | join(" ")')"
expect_eq "every step after them succeeded on the first run" "true" \
  "$(jq_result '.steps | all(.status == "ok")')"
expect_contains "the log says it waited" "$ERR" "is back on ${SYSTEM_PREFIX}node-1"

printf '\n  a member that does not come back fails\n'
reset_hosts fresh
export STUB_REBOOT_SECONDS=600
run_converge
expect_eq "exits 1" 1 "$RC"
expect_eq "the member failed and says why" "install:Failed:true" \
  "$(jq_result '.members[] | select(.name == "node-1") | "\(.action):\(.status):\(.message | test("did not come back"))"')"
expect_eq "what depends on it is skipped" "Skipped" \
  "$(jq_result '.members[] | select(.name == "node-2") | .status')"

printf '\n  a member that comes back on another system fails\n'
reset_hosts fresh
printf '10.0.0.1\n' > "$STUB_WRONG_SYSTEM"
run_converge
expect_eq "exits 1" 1 "$RC"
expect_eq "the member failed and names the system it runs" "install:Failed:true" \
  "$(jq_result '.members[] | select(.name == "node-1") | "\(.action):\(.status):\(.message | test("nixos-system-other"))"')"

printf '\n  --json keeps stdout a bare object and the marker in the log\n'
reset_hosts installed
run_converge --json
expect_eq "exits 0" 0 "$RC"
expect_eq "stdout is one line" 1 "$(wc -l < "$OUT" | tr -d ' ')"
expect_eq "and it is the bare result object" "lab" "$("${JQ[@]}" --raw-output '.cluster' "$OUT")"
expect_eq "stderr carries the same result behind the marker" \
  "$(cat "$OUT")" "$(sed -n 's/^::nixcluster:result:: //p' "$ERR")"

printf '\n  --dry-run plans every step and touches nothing\n'
reset_hosts installed
run_converge --dry-run
expect_eq "exits 0" 0 "$RC"
expect_no_calls "runs no command against any host"
expect_absent "no step is skipped for a failed dependency" "$ERR" "did not succeed"
expect_eq "every step is reported as a dry run" "true" \
  "$(jq_result '(.steps | length) > 0 and (.steps | all(.status == "skipped" and .message == "dry-run"))')"
expect_eq "every member is reported as a dry run" "node-1:Skipped:dry-run node-2:Skipped:dry-run" \
  "$(jq_result '[.members[] | "\(.name):\(.status):\(.message)"] | sort | join(" ")')"
expect_eq "the plan covers every step" "incus.cluster-join incus.prune incus.reconcile k3s.bootstrap k3s.kubeconfig k3s.prune member-node-1 member-node-2" \
  "$(jq_result '[.steps[] | .name] | sort | join(" ")')"
expect_eq "a plan is a success, not a partial run" "success" "$(jq_result '.result')"

printf '\n==> sops.gen, the converge pre-step that fills the secrets file\n'
# It runs on every converge. The file is committed, so rewriting it when no key
# is missing turns every converge into a diff.
build_gen() {
  "${NIX[@]}" build --impure --no-link --print-out-paths \
    --file "$REPO_ROOT/scripts/converge-stubs.nix" --argstr repoRoot "$REPO_ROOT" "$1" 2>/dev/null | tail -n 1 || true
}
GEN="$(build_gen sopsGen)/bin/nixclusterctl-vault-gen-secrets"
GEN_MORE="$(build_gen sopsGenMore)/bin/nixclusterctl-vault-gen-secrets"
if [[ ! -x "$GEN" || ! -x "$GEN_MORE" ]]; then
  fail "could not build the sops gen commands"
else
  SOPS_DIR="$WORK_DIR/sops"
  mkdir -p "$SOPS_DIR"
  digest() {
    local sum
    sum="$(shasum --algorithm 256 "$SOPS_DIR/secrets/vault.yaml")"
    printf '%s' "${sum%% *}"
  }
  (cd "$SOPS_DIR" && "$GEN") > "$WORK_DIR/gen1.log" 2>&1
  expect_eq "the first run writes the secrets file" "true" \
    "$([[ -s "$SOPS_DIR/secrets/vault.yaml" ]] && echo true || echo false)"
  first="$(digest)"
  (cd "$SOPS_DIR" && "$GEN") > "$WORK_DIR/gen2.log" 2>&1
  expect_eq "a second run with nothing missing leaves the file byte for byte" "$first" "$(digest)"
  expect_contains "and says so" "$WORK_DIR/gen2.log" "nothing to add"
  (cd "$SOPS_DIR" && "$GEN_MORE") > "$WORK_DIR/gen3.log" 2>&1
  expect_eq "a new provider secret is added" "true" \
    "$([[ "$(digest)" != "$first" ]] && grep --quiet "set    .extra.token" "$WORK_DIR/gen3.log" && echo true || echo false)"
  expect_contains "and the existing one is kept" "$WORK_DIR/gen3.log" "keep   .demo.token"
fi

printf '\n%d check(s) passed, %d failed\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
