# Provisioning configuration
{ ... }:

{
  nix8s.provisioning = {
    nixos-anywhere = {
      enable = true;
      ssh.user = "root";
      # ssh.keyFile = "~/.ssh/id_ed25519";  # Optional, uses ssh-agent by default
    };
    pxe.enable = true;
  };
}
