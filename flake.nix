{
  description = "nix8s - Declarative NixOS cluster management";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    sops-nix.url = "github:Mic92/sops-nix";

    disko.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, ... }@inputs:
    let
      lib = nixpkgs.lib;

      # nix8s library
      nix8sLib = import ./lib { inherit lib inputs; };

      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      forAllSystems = f: lib.genAttrs systems (system: f {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit system;
      });

    in
    {
      # Export library functions
      lib = nix8sLib;

      # Export cluster modules
      clusterModules = {
        core = ./cluster-modules/core.nix;
        disko = ./cluster-modules/disko.nix;
        k3s = ./cluster-modules/k3s.nix;
        sops = ./cluster-modules/sops.nix;
        cozystack = ./cluster-modules/cozystack.nix;
        pxe = ./cluster-modules/pxe.nix;
        incus = ./cluster-modules/incus.nix;
      };

      # Packages
      packages = forAllSystems ({ pkgs, ... }: {
        nix8sctl = import ./packages/nix8sctl.nix { inherit pkgs; };
      });

      # Apps - cluster CLIs
      apps = forAllSystems ({ pkgs, ... }:
        lib.mapAttrs' (name: cluster:
          lib.nameValuePair "cluster-${name}" {
            type = "app";
            program = lib.getExe (cluster.cli pkgs);
          }
        ) self.clusterConfigurations
      );

      # DevShell
      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          packages = [
            (import ./packages/nix8sctl.nix { inherit pkgs; })
          ];
        };
      });

      # Minimal base NixOS configuration for testing
      nixosConfigurations.base = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          inputs.disko.nixosModules.disko
          inputs.sops-nix.nixosModules.sops
          {
            # Disko will manage disk layout, these are fallbacks
            boot.loader.grub.device = lib.mkDefault "/dev/sda";
            fileSystems."/" = lib.mkDefault { device = "/dev/sda1"; fsType = "ext4"; };
            system.stateVersion = "24.11";
          }
        ];
      };

      # Test cluster
      clusterConfigurations = {
        dev = nix8sLib.mkCluster {
          imports = [
            self.clusterModules.disko
            self.clusterModules.k3s
            self.clusterModules.sops
            self.clusterModules.cozystack
            self.clusterModules.pxe
          ];
          name = "dev";

          disko.enable = true;
          sops.enable = true;
          k3s.enable = true;

          cozystack = {
            enable = true;
            publishing.host = "cozy.example.com";
          };

          # PXE server for auto-provisioning
          pxe = {
            enable = true;
            interface = "eth0";
            httpPort = 8080;
          };

          members.node1 = {
            nixosConfiguration = self.nixosConfigurations.base;
            install.ip = "192.168.1.10";
            install.mac = "aa:bb:cc:dd:ee:01";  # auto-provision by MAC
            install.disk = "/dev/sda";
            k3s.role = "server";
            # Storage: dedicated disks for LINSTOR
            cozystack.storage = {
              disks = [ "/dev/sdb" ];
              poolName = "data";
              poolType = "zfs";
            };
          };

          members.node2 = {
            nixosConfiguration = self.nixosConfigurations.base;
            install.ip = "192.168.1.11";
            install.mac = "aa:bb:cc:dd:ee:02";
            install.disk = "/dev/sda";
            k3s.role = "server";
            # Storage: dedicated disks
            cozystack.storage.disks = [ "/dev/sdb" ];
          };

          members.worker1 = {
            nixosConfiguration = self.nixosConfigurations.base;
            install.ip = "192.168.1.20";
            install.mac = "aa:bb:cc:dd:ee:03";
            install.disk = "/dev/sda";
            k3s.role = "agent";
            # Storage: partition on system disk (single-disk mode)
            cozystack.storage.systemPartition = {
              enable = true;
              size = "400G";
            };
          };
        };
      };

      # === Example usage (standalone) ===
      # To use nix8s in your flake:
      #
      # clusterConfigurations = {
      #   prod = nix8sLib.mkCluster {
      #     imports = [ nix8s.clusterModules.k3s ];
      #     name = "prod";
      #
      #     members.node1 = {
      #       nixosConfiguration = self.nixosConfigurations.base;
      #       install.ip = "10.0.0.1";
      #       k3s.role = "server";
      #       # Any other attrs are NixOS patches:
      #       networking.hostName = "prod-node1";
      #     };
      #   };
      # };
      #
      # inherit (nix8sLib.mkFlakeOutputs { inherit self; }) nixosConfigurations apps;
    };
}
