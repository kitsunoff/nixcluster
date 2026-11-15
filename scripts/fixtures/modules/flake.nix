# Fixture for scripts/check-modules.sh: a downstream flake (flake-parts + the
# nixcluster flake module, exactly how users consume it) whose clusters combine
# the built-in modules the way a real deployment does. Only evaluated, never
# built.
#
#   lab     k3s + Incus cluster + sops + keepalived on two members: the
#           combination of the live demo
#   plain   keepalived alone, so the host keeps the iptables firewall
#
# `nixcluster` is overridden to the checkout under test by the check script.
{
  description = "nixcluster module combination fixture";

  inputs = {
    nixcluster.url = "github:kitsunoff/nixcluster";
    nixpkgs.follows = "nixcluster/nixpkgs";
    flake-parts.follows = "nixcluster/flake-parts";
    disko.follows = "nixcluster/disko";
    sops-nix.follows = "nixcluster/sops-nix";
  };

  outputs =
    inputs@{ flake-parts, nixcluster, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      imports = [ nixcluster.flakeModules.default ];

      flake.nixosConfigurations.base = inputs.nixpkgs.lib.nixosSystem {
        modules = [
          inputs.disko.nixosModules.disko
          inputs.sops-nix.nixosModules.sops
          {
            nixpkgs.hostPlatform = "x86_64-linux";
            boot.loader.grub.device = "/dev/vda";
            fileSystems."/" = { device = "/dev/vda1"; fsType = "ext4"; };
            system.stateVersion = "25.11";
          }
        ];
      };

      nixcluster.lab =
        { clusterModules, self, config, lib, ... }:
        {
          imports = with clusterModules; [ k3s incus sops keepalived ];

          k3s.enable = true;
          incus.enable = true;
          incus.cluster.enable = true;
          sops.enable = true;
          keepalived.enable = true;
          keepalived.instances.api = {
            vip = "10.0.0.100";
            nodes = lib.attrNames config.members;
            virtualRouterId = 51;
          };

          defaultNixosConfiguration = self.nixosConfigurations.base;
          members.node-1 = { install.ip = "10.0.0.1"; k3s.role = "server"; };
          members.node-2 = { install.ip = "10.0.0.2"; k3s.role = "server"; };
        };

      nixcluster.plain =
        { clusterModules, self, ... }:
        {
          imports = with clusterModules; [ keepalived ];

          keepalived.enable = true;
          keepalived.instances.api = {
            vip = "10.0.1.100";
            nodes = [ "node-1" ];
            virtualRouterId = 52;
          };

          defaultNixosConfiguration = self.nixosConfigurations.base;
          members.node-1.install.ip = "10.0.1.1";
        };
    };
}
