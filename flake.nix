{
  description = "nixcluster - Declarative NixOS cluster management";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    sops-nix.url = "github:Mic92/sops-nix";
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    disko.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, ... }@inputs:
    let
      lib = nixpkgs.lib;

      # nixcluster library
      nixclusterLib = import ./lib { inherit lib inputs; };

      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      forAllSystems = f: lib.genAttrs systems (system: f {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit system;
      });

      # Single-source per-system projection (apps + packages) shared with the
      # flake-parts module and standalone mkFlakeOutputs.
      perSystemOutputs = forAllSystems ({ pkgs, ... }:
        nixclusterLib.mkPerSystemOutputs {
          inherit pkgs;
          clusterConfigurations = self.clusterConfigurations;
        });

    in
    {
      # Export library functions
      lib = nixclusterLib;

      # Export built-in cluster modules (applied only via explicit imports).
      clusterModules = nixclusterLib.builtinClusterModules;

      # flake-parts module for the declarative `nixcluster` option (task 01).
      flakeModules.nixcluster = nixclusterLib.flakeModule;
      flakeModules.default = nixclusterLib.flakeModule;

      # Downstream flake template (task 02): flake-parts + import-tree + ./modules.
      templates.default = {
        path = ./template;
        description = "nixcluster downstream flake (flake-parts + import-tree)";
      };
      templates.nixcluster = self.templates.default;

      # Packages - per-cluster buildable CLIs + nixclusterctl dispatcher.
      packages = lib.mapAttrs (_system: o: o.packages) perSystemOutputs;

      # Apps - runnable per-cluster CLIs.
      apps = lib.mapAttrs (_system: o: o.apps) perSystemOutputs;

      # DevShell
      devShells = forAllSystems ({ pkgs, system }: {
        default = pkgs.mkShell {
          packages = [
            self.packages.${system}.nixclusterctl
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
        dev = nixclusterLib.mkCluster {
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
      # To use nixcluster in your flake:
      #
      # clusterConfigurations = {
      #   prod = nixclusterLib.mkCluster {
      #     imports = [ nixcluster.clusterModules.k3s ];
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
      # inherit (nixclusterLib.mkFlakeOutputs { inherit self; }) nixosConfigurations apps;
    };
}
