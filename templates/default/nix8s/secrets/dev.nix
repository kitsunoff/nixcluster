# DEPRECATED: This file format is no longer used.
#
# nix8s now uses sops-nix for encrypted secrets.
# Generate secrets with: nix run .#gen-secrets -- dev
#
# This creates:
#   - dev.yaml (encrypted secrets - safe to commit)
#   - dev.age.key (private key - NEVER commit)
#   - dev_ssh (SSH private key - NEVER commit)
#   - dev_ssh.pub (SSH public key - safe to commit)
#
# See cluster config in clusters/dev.nix for sops configuration.
throw "Use sops-nix instead. Run: nix run .#gen-secrets -- dev"
