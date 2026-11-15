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

WORK_DIR="$(mktemp -d)"
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
  converge 2> "$WORK_DIR/build.err" | tail -n 1)/bin/nixclusterctl-lab-converge"
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
expect_eq "member steps carry the member phase and succeeded" "member:ok member:ok" \
  "$(jq_result '[.steps[] | select(.name | startswith("member-")) | "\(.phase):\(.status)"] | join(" ")')"

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

printf '\n%d check(s) passed, %d failed\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
