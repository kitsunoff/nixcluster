#!/usr/bin/env bash
# check-modules.sh — evaluate the NixOS side of the built-in cluster modules in
# the combinations a real cluster uses.
#
# The templates load one or two modules each. Bugs live where modules meet: sops
# next to keepalived, keepalived next to Incus (which switches the firewall to
# nftables), the firewall ports k3s and Incus need between members. The fixture
# flake in scripts/fixtures/modules is a downstream flake that combines them;
# this script locks it against the checkout and asserts by EVALUATION only —
# nothing is built and no host is touched.
#
# Usage: scripts/check-modules.sh
# Exit status is non-zero if any expectation failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIX=(nix --extra-experimental-features "nix-command flakes")

# Resolved: on macOS the temp dir sits behind the /var symlink, which a path:
# flake reference refuses.
WORK_DIR="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK_DIR"' EXIT

checks=0
failures=0

ok() { printf '    ok: %s\n' "$1"; checks=$((checks + 1)); }
fail() { printf '    FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

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

FLAKE="$WORK_DIR/fixture"
cp -R "$REPO_ROOT/scripts/fixtures/modules" "$FLAKE"
chmod -R u+w "$FLAKE"
(
  cd "$FLAKE"
  "${NIX[@]}" flake lock --override-input nixcluster "path:$REPO_ROOT" >/dev/null 2>&1 ||
    "${NIX[@]}" flake lock --override-input nixcluster "path:$REPO_ROOT"
)

# member_eval <cluster-member> <option-path> [apply]: a member's option as JSON,
# or the last lines of the evaluation error.
member_eval() {
  local out
  if out="$("${NIX[@]}" eval --json "path:$FLAKE#nixosConfigurations.\"$1\".config.$2" \
    ${3:+--apply "$3"} 2>&1)"; then
    printf '%s' "$out"
  else
    printf '<eval failed: %s>' "$(printf '%s' "$out" | grep --invert-match '^ *… ' | tail -n 3 | tr '\n' ' ')"
  fi
}

printf '==> sops\n'

# sops-nix types defaultSopsFile as a path; a relative string fails every
# cluster that loads sops. The default must be the file inside the flake.
expect_eq "defaultSopsFile is the cluster's file inside the flake" "true" \
  "$(member_eval lab-node-1 sops.defaultSopsFile \
    'f: builtins.match "/nix/store/[^/]+/secrets/lab[.]yaml" (toString f) != null')"
expect_eq "a secret declared by a module resolves to that file" "true" \
  "$(member_eval lab-node-1 sops.secrets \
    's: builtins.match "/nix/store/[^/]+/secrets/lab[.]yaml" (toString s."k3s/token".sopsFile) != null')"

printf '\n%d check(s) passed, %d failed\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
