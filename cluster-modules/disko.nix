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
# Integration with cozystack.storage.systemPartition:
#   When cozystack.storage.systemPartition.enable = true, disko automatically
#   creates an additional partition for LINSTOR storage on the system disk.
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

  # Disko config with LINSTOR storage partition
  # Layout: ESP (512M) + root (remaining - storageSize) + linstor (storageSize)
  mkDiskoConfigWithStorage = disk: storageSize: {
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
            # Takes remaining space after ESP and linstor
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
          linstor = {
            # Storage partition for LINSTOR - placed at end of disk
            size = storageSize;
            # No content - LINSTOR will format it as ZFS/LVM
          };
        };
      };
    };
  };

  # NixOS module that configures disko
  diskoNixosModule = { config, lib, pkgs, nixcluster, ... }:
    let
      member = nixcluster.member;

      # Get disk from install config (cluster member option)
      installDisk = member.install.disk or null;

      # Check for cozystack storage config (NixOS option if cozystack module loaded)
      # Use lib.attrByPath to safely access nested options that may not exist
      useSystemPartition = lib.attrByPath [ "cozystack" "storage" "systemPartition" "enable" ] false config;
      storageSize = lib.attrByPath [ "cozystack" "storage" "systemPartition" "size" ] "400G" config;

      # Generate disko config based on storage mode
      diskoDevices =
        if installDisk != null && useSystemPartition then
          mkDiskoConfigWithStorage installDisk storageSize
        else if installDisk != null then
          mkDefaultDiskoConfig installDisk
        else
          null;
    in
    lib.mkIf (diskoDevices != null) {
      disko.devices = lib.mkDefault diskoDevices;
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
