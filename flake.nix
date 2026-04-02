{
  description = "nix8s - Declarative NixOS cluster management";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    sops-nix.url = "github:Mic92/sops-nix";
    flake-parts.url = "github:hercules-ci/flake-parts";

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
        k3s = ./cluster-modules/k3s.nix;
        sops = ./cluster-modules/sops.nix;
      };

      # Export flake-parts module
      flakeModules.default = ./lib/flakeModule.nix;

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
        modules = [{
          boot.loader.grub.device = "/dev/sda";
          fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
          system.stateVersion = "24.11";
        }];
      };

      # Test cluster
      clusterConfigurations = {
        dev = nix8sLib.mkCluster {
          imports = [
            self.clusterModules.k3s
            self.clusterModules.sops
          ];
          name = "dev";

          sops.enable = true;

          members.node1 = {
            nixosConfiguration = self.nixosConfigurations.base;
            install.ip = "192.168.1.10";
            k3s.role = "server";
          };

          members.node2 = {
            nixosConfiguration = self.nixosConfigurations.base;
            install.ip = "192.168.1.11";
            k3s.role = "server";
          };

          members.worker1 = {
            nixosConfiguration = self.nixosConfigurations.base;
            install.ip = "192.168.1.20";
            k3s.role = "agent";
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
