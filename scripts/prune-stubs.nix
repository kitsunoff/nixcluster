# Test harness for scripts/check-prune.sh, Part B: the REAL k3s prune step, built
# from the cluster definition, with `kubectl` and `ssh` replaced by stubs.
#
# The stubs are substituted for `pkgs.kubectl` / `pkgs.openssh` rather than merely
# prepended to PATH, because writeShellApplication puts its own runtimeInputs
# first — a PATH prefix would be shadowed by the real binaries.
#
# The stubs read their answers from, and record their calls into, files named by
# environment variables, so one build serves every scenario:
#
#   STUB_CALLS      every invocation is appended here (the assertion surface)
#   STUB_NODES      the node names `kubectl get nodes` reports
#   STUB_SERVERS    which of those are control-plane nodes
#   STUB_REACHABLE  contains the address if ssh should succeed
{
  repoRoot,
  cluster ? "dev",
  step ? "k3s.prune",
}:

let
  flake = builtins.getFlake "path:${repoRoot}";
  pkgs = (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem};

  grep = "${pkgs.gnugrep}/bin/grep";

  stubKubectl = pkgs.writeShellScriptBin "kubectl" ''
    printf '%s\n' "kubectl $*" >> "$STUB_CALLS"
    case "$*" in
      *'get nodes'*)
        cat "$STUB_NODES"
        ;;
      *'jsonpath={.status.addresses'*)
        echo '10.0.0.9'
        ;;
      *control-plane*)
        # `kubectl get node <name> -o jsonpath=...` -> the name is $3.
        ${grep} --quiet --line-regexp "$3" "$STUB_SERVERS" && echo true || true
        ;;
    esac
    exit 0
  '';

  stubSsh = pkgs.writeShellScriptBin "ssh" ''
    printf '%s\n' "ssh $*" >> "$STUB_CALLS"
    ${grep} --quiet 10.0.0.9 "$STUB_REACHABLE" || exit 255
    exit 0
  '';

  stubbedPkgs = pkgs // {
    kubectl = stubKubectl;
    openssh = stubSsh;
  };

  clusterConfig = flake.clusterConfigurations.${cluster}.config;
in
clusterConfig.converge.steps.${step}.run {
  pkgs = stubbedPkgs;
  inherit (pkgs) lib;
  cluster = clusterConfig;
  helpers = { };
}
