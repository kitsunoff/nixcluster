# flakeOutputs - single-source per-system projection of clusterConfigurations.
#
# One helper used by all three flake entry paths (root flake.nix, the
# flake-parts module, and standalone mkFlakeOutputs) so their per-system
# outputs never drift. From the SAME `clusterConfigurations` it produces:
#
#   apps.cluster-<name>     -> runnable  ({ type = "app"; program = getExe cli; })
#   packages.cluster-<name> -> buildable (the SAME derivation getExe points at)
#   packages.nixclusterctl  -> the static dispatcher (mkNixclusterctl)
#
# Exposing each cluster CLI as BOTH an app and a package is what lets
# `nix build .#cluster-<name>` work (nix build resolves only packages), which
# NIO relies on for its per-cluster prebuild.
{ lib, mkNixclusterctl }:

{ pkgs, clusterConfigurations }:

let
  # The single source of truth: each cluster's `cli pkgs` derivation.
  clusterClis = lib.mapAttrs (_name: c: c.cli pkgs) clusterConfigurations;
in
{
  # Runnable: `nix run .#cluster-<name>`.
  apps = lib.mapAttrs'
    (name: cli: lib.nameValuePair "cluster-${name}" {
      type = "app";
      program = lib.getExe cli;
    })
    clusterClis;

  # Buildable: `nix build .#cluster-<name>` (same derivation as the app's exe),
  # plus the aggregate nixclusterctl dispatcher.
  packages =
    (lib.mapAttrs'
      (name: cli: lib.nameValuePair "cluster-${name}" cli)
      clusterClis)
    // {
      nixclusterctl = mkNixclusterctl { inherit pkgs clusterConfigurations; };
    };
}
