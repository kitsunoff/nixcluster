# Provisioning configuration
{ ... }:

{
  nix8s.provisioning = {
    nixos-anywhere = {
      enable = true;
      ssh = {
        user = "root";
        keyFile = "~/.ssh/id_ed25519";
      };
    };
    pxe.enable = true;
  };
}
