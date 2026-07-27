{
  description = "nixcluster test: multi-node Incus clustering (bootstrap + joiner)";

  inputs = {
    # The nixcluster flake under test (this worktree).
    nixcluster.url = "path:../..";

    # Reuse nixcluster's locked inputs for a single consistent set.
    nixpkgs.follows = "nixcluster/nixpkgs";
    flake-parts.follows = "nixcluster/flake-parts";
    import-tree.follows = "nixcluster/import-tree";
    disko.follows = "nixcluster/disko";
    sops-nix.follows = "nixcluster/sops-nix";
  };

  outputs =
    inputs@{ flake-parts, nixcluster, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-linux" ];

      imports = [ nixcluster.flakeModules.default ];

      # Minimal bootable aarch64 base shared by all members (data-only members
      # inherit it via defaultNixosConfiguration). Kept intentionally tiny: this
      # test proves the clustered bootstrap/joiner configs EVALUATE and BUILD;
      # full 2-node runtime formation is validated on real VMs (M5).
      flake.nixosConfigurations.base = nixpkgs.lib.nixosSystem {
        modules = [
          {
            nixpkgs.hostPlatform = "aarch64-linux";
            boot.loader.grub.device = "/dev/vda";
            fileSystems."/" = {
              device = "/dev/vda1";
              fsType = "ext4";
            };
            system.stateVersion = "24.11";
          }
        ];
      };

      # Clustered Incus: ALL members participate off the cluster-level toggle.
      # node-a is the bootstrap (first sorted); node-b is a DATA-ONLY member
      # (only install.ip, no `incus.enable` patch) — it must still receive Incus
      # + clustering config (followup C), joined at runtime by converge.
      # `nixcluster.<name>` is a TOP-LEVEL flake-parts option from flakeModule.
      nixcluster.incus-cluster =
        { self, ... }:
        {
          imports = [ nixcluster.clusterModules.incus ];
          name = "incus-cluster";

          incus.enable = true;
          incus.cluster = {
            enable = true;
            storageBackend = "dir";
          };

          defaultNixosConfiguration = self.nixosConfigurations.base;

          members.node-a = {
            install.ip = "192.168.105.11";
            incus.enable = true;
          };

          # Data-only joiner: no `incus.enable` — proves clustering applies to
          # NIO-injected members that never set the per-member patch.
          members.node-b = {
            install.ip = "192.168.105.12";
          };
        };
    };
}
