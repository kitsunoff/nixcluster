# A node (member) definition. Discovered nodes (via `nixclusterctl <cluster>
# gen-config <ip>`) drop files like this into ./modules/nodes/.
{ inputs, ... }:
{
  nixcluster.example.members.node1 = {
    nixosConfiguration = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        inputs.disko.nixosModules.disko
        {
          system.stateVersion = "24.11";
          fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
          boot.loader.grub.device = "/dev/sda";
        }
      ];
    };

    install.ip = "10.0.0.10";
    install.disk = "/dev/sda";
    k3s.role = "server";
  };
}
