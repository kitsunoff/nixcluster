# Export all nix8s flake modules
{ ... }:

{
  flake.flakeModules = {
    # All-in-one module
    default = {
      imports = [
        ./core.nix
        ./outputs.nix
        ./devshell.nix
        ./nix8sctl
        ./nixos-anywhere.nix
        # Extensions
        ./extensions/k3s.nix
      ];
    };

    # Individual modules
    core = ./core.nix;
    outputs = ./outputs.nix;
    devshell = ./devshell.nix;
    nix8sctl = ./nix8sctl;
    nixos-anywhere = ./nixos-anywhere.nix;

    # Extensions
    k3s = ./extensions/k3s.nix;
  };
}
