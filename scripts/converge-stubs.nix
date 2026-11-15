# Test harness for scripts/check-converge.sh: the REAL `converge` command of a
# small k3s + Incus cluster, built with `ssh`/`scp`, `nixos-anywhere`,
# `nixos-rebuild`, `nix` and `kubectl` replaced by stubs. Nothing it runs can
# reach a host.
#
# The stubs are substituted for the packages rather than prepended to PATH,
# because writeShellApplication puts its own runtimeInputs first.
#
# Every member is a directory under $STUB_ROOT/<ip> standing in for its root
# file system. A remote command that reads /etc, /run or /nix runs locally with
# those paths moved into that directory (and moved back in its output), so the
# member probe converge really sends is what decides the outcome:
#
#   fresh      empty directory — no NixOS yet
#   installer  /etc/os-release of the NixOS installer (what nixos-anywhere's
#              kexec image runs) and a /run/current-system of its own
#   installed  /etc/os-release of NixOS and /run/current-system pointing at
#              the member's system
#
# Files named by environment variables steer the stubs, one entry per line:
#
#   STUB_CALLS          every invocation is appended here (the assertion surface)
#   STUB_ROOT           the directory holding one fake root per member address
#   STUB_UNREACHABLE    addresses that never answer ssh
#   STUB_ANYWHERE_FAIL  addresses nixos-anywhere fails on
#   STUB_ANYWHERE_HANG  addresses nixos-anywhere never returns for
#   STUB_REBOOT_SECONDS seconds an installed member stays down after nixos-anywhere
#                       (a number, not a file; 0 when unset)
#
# Attributes:
#   converge  the built `converge` command (bin/nixclusterctl-lab-converge)
#   systemOf  member -> the system path the stubbed `nix build` reports for it
{ repoRoot }:

let
  flake = builtins.getFlake "path:${repoRoot}";
  pkgs = (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem};
  inherit (pkgs) lib;

  grep = "${pkgs.gnugrep}/bin/grep";
  sed = "${pkgs.gnused}/bin/sed";

  systemOf = member: "/nix/store/00000000000000000000000000000000-nixos-system-lab-${member}";

  common = ''
    listed() { # file value: the value is a line of the file
      [ -n "$1" ] && [ -f "$1" ] && ${grep} --quiet --fixed-strings --line-regexp "$2" "$1"
    }
    is_down() { # ip: unreachable, or still rebooting after an install
      local until
      listed "''${STUB_UNREACHABLE:-}" "$1" && return 0
      until="$(cat "$STUB_ROOT/$1/.down-until" 2>/dev/null || echo 0)"
      [ "$(date +%s)" -lt "$until" ]
    }
  '';

  # ssh <options...> <user@host> [command...]
  stubSsh = pkgs.writeShellScriptBin "ssh" ''
    ${common}
    printf '%s\n' "ssh $*" >> "$STUB_CALLS"
    host=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o|-F|-i|-p|-l|-J) shift 2 ;;
        -*) shift ;;
        *) host="$1"; shift; break ;;
      esac
    done
    ip="''${host#*@}"
    if is_down "$ip"; then
      echo "ssh: connect to host $ip port 22: Connection refused" >&2
      exit 255
    fi
    cmd="$*"
    case "$cmd" in
      *'bash -s'*|*'sh -s'*)
        ${sed} 's/^/  | /' >> "$STUB_CALLS"
        exit 0
        ;;
      *'incus cluster add'*)
        echo "STUB-JOIN-TOKEN"
        exit 0
        ;;
      */etc/*|*/run/*|*/nix/*)
        root="$STUB_ROOT/$ip"
        moved="$(printf '%s' "$cmd" | ${sed} "s#\(^\|[^A-Za-z0-9_.-]\)/\(etc\|run\|nix\)/#\1$root/\2/#g")"
        bash -c "$moved" | ${sed} "s#$root##g"
        exit "''${PIPESTATUS[0]}"
        ;;
    esac
    exit 0
  '';

  stubScp = pkgs.writeShellScriptBin "scp" ''
    ${common}
    printf '%s\n' "scp $*" >> "$STUB_CALLS"
    for last in "$@"; do :; done
    printf 'apiVersion: v1\nclusters: []\n' > "$last"
  '';

  stubOpenssh = pkgs.symlinkJoin { name = "openssh-stub"; paths = [ stubSsh stubScp ]; };

  stubAnywhere = pkgs.writeShellScriptBin "nixos-anywhere" ''
    ${common}
    printf '%s\n' "nixos-anywhere $*" >> "$STUB_CALLS"
    flake="" target=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --flake) flake="$2"; shift 2 ;;
        --target-host) target="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    ip="''${target#*@}"
    member="''${flake#.#lab-}"
    if listed "''${STUB_ANYWHERE_HANG:-}" "$ip"; then exec sleep 300; fi
    if listed "''${STUB_ANYWHERE_FAIL:-}" "$ip"; then echo "stub: install failed" >&2; exit 1; fi
    root="$STUB_ROOT/$ip"
    system="$root/nix/store/00000000000000000000000000000000-nixos-system-lab-$member"
    rm -rf "$root"
    mkdir -p "$root/etc" "$root/run" "$system"
    printf 'ID=nixos\nVARIANT_ID=""\n' > "$root/etc/os-release"
    ln -s "$system" "$root/run/current-system"
    echo $(( $(date +%s) + ''${STUB_REBOOT_SECONDS:-0} )) > "$root/.down-until"
  '';

  stubRebuild = pkgs.writeShellScriptBin "nixos-rebuild" ''
    printf '%s\n' "nixos-rebuild $* NIX_SSHOPTS=''${NIX_SSHOPTS:-}" >> "$STUB_CALLS"
  '';

  stubNix = pkgs.writeShellScriptBin "nix" ''
    printf '%s\n' "nix $*" >> "$STUB_CALLS"
    case "$*" in
      *' build '*)
        for arg in "$@"; do
          case "$arg" in
            *nixosConfigurations*)
              config="''${arg#*nixosConfigurations.\"}"
              echo "/nix/store/00000000000000000000000000000000-nixos-system-''${config%%\"*}"
              ;;
          esac
        done
        ;;
    esac
  '';

  stubKubectl = pkgs.writeShellScriptBin "kubectl" ''
    printf '%s\n' "kubectl $*" >> "$STUB_CALLS"
  '';

  stubbedPkgs = pkgs // {
    openssh = stubOpenssh;
    nixos-anywhere = stubAnywhere;
    nixos-rebuild = stubRebuild;
    nix = stubNix;
    kubectl = stubKubectl;
  };

  # Two k3s servers that are also an Incus cluster; node-1 bootstraps both.
  cluster = flake.lib.mkCluster {
    imports = with flake.clusterModules; [ k3s incus ];
    name = "lab";

    k3s.enable = true;
    incus.enable = true;
    incus.cluster.enable = true;

    members.node-1 = { install.ip = "10.0.0.1"; k3s.role = "server"; };
    members.node-2 = { install.ip = "10.0.0.2"; k3s.role = "server"; };
  };
in
{
  converge = (cluster.cli stubbedPkgs).passthru.commands.converge;
  inherit systemOf;
  order = cluster.convergeOrder;
}
