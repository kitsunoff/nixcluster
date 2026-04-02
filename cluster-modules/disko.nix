# Disko cluster module
# Adds disko NixOS module to all members for declarative disk partitioning
#
# Usage:
#   disko.enable = true;
#
#   members.node1 = {
#     nixosConfiguration = ...;
#     install.disk = "/dev/sda";
#     disko.devices = { ... };  # custom disko config (optional)
#   };
#
# If disko.devices is not set, a default config is generated from install.disk
#
# NOTE: Base nixosConfiguration must include disko NixOS module:
#   inputs.disko.nixosModules.disko
{ lib, config, ... }:

let
  cfg = config.disko;
  clusterName = config.name;

  # Default disko config for a disk (simple GPT with ESP + root)
  mkDefaultDiskoConfig = disk: {
    disk.main = {
      type = "disk";
      device = disk;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };

  # NixOS module that configures disko
  diskoNixosModule = { config, lib, pkgs, nix8s, ... }:
    let
      memberName = nix8s.memberName;
      member = nix8s.member;
      cluster = nix8s.cluster;

      # Get disk from install config
      installDisk = member.install.disk or null;

      # Get disko config from member or generate default
      diskoDevices = member.disko.devices or (
        if installDisk != null
        then mkDefaultDiskoConfig installDisk
        else {}
      );

      hasDisko = diskoDevices != {};
    in
    lib.mkIf hasDisko {
      disko.devices = diskoDevices;
    };

in
{
  options.disko = {
    enable = lib.mkEnableOption "Disko declarative disk partitioning";
  };

  config = lib.mkIf cfg.enable {
    # Add disko NixOS module to all members
    _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
      [ diskoNixosModule ]
    );
  };
}
