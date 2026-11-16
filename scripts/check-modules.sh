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

# eval_json <nix eval args...>: the value as JSON, or the last lines of the
# evaluation error. stderr stays out of the value: nix reports progress there
# ("copying path ... from <substituter>" on a CI runner with a binary cache).
eval_json() {
  local out
  if out="$("${NIX[@]}" eval --json "$@" 2>"$WORK_DIR/eval.err")"; then
    printf '%s' "$out"
  else
    printf '<eval failed: %s>' "$(grep --invert-match '^ *… ' "$WORK_DIR/eval.err" | tail -n 3 | tr '\n' ' ')"
  fi
}

# member_eval <cluster-member> <option-path> [apply]: a member's option as JSON,
# or the last lines of the evaluation error.
member_eval() {
  eval_json "path:$FLAKE#nixosConfigurations.\"$1\".config.$2" ${3:+--apply "$3"}
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

printf '\n==> keepalived and the firewall\n'

# Incus switches the firewall to nftables, where iptables extraCommands are an
# evaluation error. VRRP must be allowed the nftables way there, and the
# iptables way everywhere else.
expect_eq "keepalived + Incus: the member configuration evaluates" "true" \
  "$(member_eval lab-node-1 system.build.toplevel.drvPath 'p: builtins.isString p')"
expect_eq "keepalived + Incus: the firewall is nftables" "true" \
  "$(member_eval lab-node-1 networking.nftables.enable)"
expect_eq "keepalived + Incus: VRRP is allowed by an nftables rule" "true" \
  "$(member_eval lab-node-1 networking.firewall.extraInputRules 's: builtins.match ".*ip protocol vrrp accept.*" s != null')"
expect_eq "keepalived + Incus: no iptables command is left" '""' \
  "$(member_eval lab-node-1 networking.firewall.extraCommands)"
expect_eq "keepalived alone: the iptables rule stays" "true" \
  "$(member_eval plain-node-1 networking.firewall.extraCommands 's: builtins.match ".*iptables -I INPUT -p vrrp -j ACCEPT.*" s != null')"
expect_eq "keepalived alone: the member configuration evaluates" "true" \
  "$(member_eval plain-node-1 system.build.toplevel.drvPath 'p: builtins.isString p')"

printf '\n==> ports between members\n'

# Members talk to each other on these; a closed port shows up only at runtime
# (pods on different nodes cannot reach each other, `incus cluster add` hangs).
has_port() { printf 'p: builtins.elem %s p' "$1"; }
expect_eq "k3s opens flannel VXLAN (UDP 8472)" "true" \
  "$(member_eval lab-node-1 networking.firewall.allowedUDPPorts "$(has_port 8472)")"
expect_eq "k3s opens the API (TCP 6443)" "true" \
  "$(member_eval lab-node-1 networking.firewall.allowedTCPPorts "$(has_port 6443)")"
expect_eq "a clustered Incus opens its cluster API (TCP 8443)" "true" \
  "$(member_eval lab-node-1 networking.firewall.allowedTCPPorts "$(has_port 8443)")"
expect_eq "a host without Incus or k3s opens neither" "false false" \
  "$(member_eval plain-node-1 networking.firewall.allowedTCPPorts "$(has_port 8443)") $(member_eval plain-node-1 networking.firewall.allowedUDPPorts "$(has_port 8472)")"

printf '\n==> Incus without virtual machines\n'

# Where VMs are impossible (no nested KVM) qemu and the UEFI firmware are dead
# weight in every member's closure. The Incus units are what pull them in.
vm_refs() { # cluster-member -> the VM pieces any Incus unit still references
  member_eval "$1" systemd.units 'units: builtins.sort builtins.lessThan (builtins.filter (x: x != null) (map
    (needle: if builtins.any (unit: builtins.match "(.*[^A-Za-z])?${needle}.*" (units.${unit}.text or "") != null)
      [ "incus.service" "incus-user.service" "incus-startup.service" ] then needle else null)
    [ "qemu" "ovmf" "virtiofsd" "swtpm" "seabios" ]))'
}
expect_eq "by default an Incus member can run VMs (its units reference them)" '["ovmf","qemu","swtpm","virtiofsd"]' \
  "$(vm_refs lab-node-1)"
expect_eq "with incus.virtualMachines = false no Incus unit references them" '[]' "$(vm_refs lite-node-1)"
expect_eq "the containers-only member still evaluates" "true" \
  "$(member_eval lite-node-1 system.build.toplevel.drvPath 'p: builtins.isString p')"
expect_eq "and still runs Incus" "true" "$(member_eval lite-node-1 virtualisation.incus.enable)"
expect_eq "a VM instance on a containers-only member is refused" "true" \
  "$(eval_json "path:$FLAKE#nixosConfigurations.\"lite-node-1\"" --apply '
    c: let e = c.extendModules { modules = [ {
      incus.instances.vm = { node = "node-1"; type = "virtual-machine"; image = "images:debian/12"; };
    } ]; };
    in builtins.any (x: !x.assertion && builtins.match ".*virtualMachines.*" x.message != null) e.config.assertions')"

printf '\n%d check(s) passed, %d failed\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
