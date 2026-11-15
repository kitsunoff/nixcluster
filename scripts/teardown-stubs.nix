# Test harness for scripts/check-teardown.sh: the REAL `teardown` command of a
# cluster that loads every module with a teardown contribution (k3s, incus,
# keepalived, nebula, sops), built with `ssh`/`scp`, `kubectl` and `nix` replaced
# by stubs. Nothing it runs can reach a host.
#
# The stubs are substituted for `pkgs.openssh` / `pkgs.kubectl` / `pkgs.nix`
# rather than prepended to PATH, because writeShellApplication puts its own
# runtimeInputs first — a PATH prefix would be shadowed by the real binaries.
#
# They read their answers from, and record their calls into, files named by
# environment variables, so one build serves every scenario:
#
#   STUB_CALLS        every invocation is appended here, and so is every script
#                     a step pipes to a host (the assertion surface)
#   STUB_UNREACHABLE  addresses that do not answer ssh/scp/nix copy (one per line)
#   STUB_NIX_FAIL     member names whose system build fails (one per line)
#
# Attributes:
#   teardown  the built `teardown` command (bin/nixclusterctl-lab-teardown)
#   plan      { converge = { order; deps; }; teardown = { order; deps; }; } as data
{ repoRoot }:

let
  flake = builtins.getFlake "path:${repoRoot}";
  pkgs = (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem};
  inherit (pkgs) lib;

  grep = "${pkgs.gnugrep}/bin/grep";
  sed = "${pkgs.gnused}/bin/sed";

  # Answers 255 (ssh's "could not connect") for an address listed as unreachable.
  unreachableCheck = ''
    is_unreachable() {
      [ -n "''${STUB_UNREACHABLE:-}" ] && [ -f "$STUB_UNREACHABLE" ] &&
        ${grep} --quiet --fixed-strings --line-regexp "$1" "$STUB_UNREACHABLE"
    }
    target_ip() { # the address of the first root@<ip> / ssh://root@<ip> argument
      local arg
      for arg in "$@"; do
        case "$arg" in
          ssh://root@*) echo "''${arg#ssh://root@}"; return ;;
          root@*) arg="''${arg#root@}"; echo "''${arg%%:*}"; return ;;
        esac
      done
    }
  '';

  stubSsh = pkgs.writeShellScriptBin "ssh" ''
    ${unreachableCheck}
    printf '%s\n' "ssh $*" >> "$STUB_CALLS"
    if is_unreachable "$(target_ip "$@")"; then exit 255; fi
    # A step pipes its host script on stdin (`bash -s`): record it too.
    case "$*" in
      *'bash -s'*) ${sed} 's/^/  | /' >> "$STUB_CALLS" ;;
    esac
    exit 0
  '';

  stubScp = pkgs.writeShellScriptBin "scp" ''
    ${unreachableCheck}
    printf '%s\n' "scp $*" >> "$STUB_CALLS"
    if is_unreachable "$(target_ip "$@")"; then exit 1; fi
    for last in "$@"; do :; done
    printf 'apiVersion: v1\nclusters: []\n' > "$last"
  '';

  stubOpenssh = pkgs.symlinkJoin { name = "openssh-stub"; paths = [ stubSsh stubScp ]; };

  stubKubectl = pkgs.writeShellScriptBin "kubectl" ''
    printf '%s\n' "kubectl $*" >> "$STUB_CALLS"
    exit 0
  '';

  stubNix = pkgs.writeShellScriptBin "nix" ''
    ${unreachableCheck}
    printf '%s\n' "nix $*" >> "$STUB_CALLS"
    case "$*" in
      *' build '*)
        member=""
        for arg in "$@"; do
          case "$arg" in
            *teardownNixosConfigurations*)
              member="''${arg#*teardownNixosConfigurations.\"}"
              member="''${member%%\"*}"
              ;;
          esac
        done
        if [ -n "''${STUB_NIX_FAIL:-}" ] && [ -f "$STUB_NIX_FAIL" ] &&
          ${grep} --quiet --fixed-strings --line-regexp "$member" "$STUB_NIX_FAIL"; then
          echo "error: stubbed build failure for $member" >&2
          exit 1
        fi
        echo "/nix/store/00000000000000000000000000000000-nixos-system-$member"
        ;;
      *' copy '*)
        if is_unreachable "$(target_ip "$@")"; then exit 1; fi
        ;;
    esac
    exit 0
  '';

  stubbedPkgs = pkgs // {
    openssh = stubOpenssh;
    kubectl = stubKubectl;
    nix = stubNix;
  };

  # Four members: three k3s servers and one agent, all of them Incus cluster
  # members and nebula hosts; two of them share a keepalived VIP. node-1 is the
  # bootstrap of both k3s and Incus.
  member = ip: extra: {
    install.ip = ip;
    nebula.enable = true;
    nebula.overlayIp = "192.168.100.${lib.last (lib.splitString "." ip)}/24";
  } // extra;

  cluster = flake.lib.mkCluster {
    imports = with flake.clusterModules; [ k3s incus keepalived nebula sops ];
    name = "lab";

    k3s.enable = true;
    incus.enable = true;
    incus.cluster.enable = true;
    sops.enable = true;
    nebula.enable = true;
    keepalived.enable = true;
    keepalived.instances.api = {
      vip = "10.0.0.100";
      nodes = [ "node-1" "node-2" ];
      virtualRouterId = 51;
    };

    members.node-1 = member "10.0.0.1" { k3s.role = "server"; };
    members.node-2 = member "10.0.0.2" { k3s.role = "server"; };
    members.node-3 = member "10.0.0.3" { k3s.role = "server"; };
    members.node-4 = member "10.0.0.4" { k3s.role = "agent"; };
  };

  depsOf = steps: lib.mapAttrs (_: step: step.deps) steps;
in
{
  teardown = (cluster.cli stubbedPkgs).passthru.commands.teardown;

  plan = {
    converge = { order = cluster.convergeOrder; deps = depsOf cluster.config.converge.steps; };
    teardown = { order = cluster.teardownOrder; deps = depsOf cluster.config.teardown.steps; };
  };
}
