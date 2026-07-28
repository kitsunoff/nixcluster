# The base NixOS configuration every member inherits (via the cluster's
# `defaultNixosConfiguration`). Intentionally minimal but genuinely bootable:
# a disk, a bootloader, SSH for converge to reach the node, and flakes enabled
# so `nixos-rebuild` works on the target.
#
# CHANGE THESE for your hardware:
#   - the disk device (`/dev/vda` here — `/dev/sda` or `/dev/nvme0n1` elsewhere)
#   - the SSH public key authorized for root
#   - `nixpkgs.hostPlatform` if your nodes are not aarch64
{ inputs, ... }:
{
  flake.nixosConfigurations.base = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      inputs.disko.nixosModules.disko
      inputs.sops-nix.nixosModules.sops
      {
        nixpkgs.hostPlatform = "aarch64-linux";

        boot.loader.grub.device = "/dev/vda";
        fileSystems."/" = {
          device = "/dev/vda1";
          fsType = "ext4";
        };

        # converge reaches every member over SSH as root, using the cluster key.
        services.openssh = {
          enable = true;
          settings.PermitRootLogin = "prohibit-password";
        };
        users.users.root.openssh.authorizedKeys.keys = [
          # REPLACE with your own public key.
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREPLACEMEWITHYOUROWNPUBLICKEY000000000"
        ];

        # nixos-rebuild on the target needs flakes.
        nix.settings.experimental-features = [ "nix-command" "flakes" ];

        system.stateVersion = "24.11";
      }
    ];
  };
}
