# nix8sctl <cluster> edit-secrets
# Opens encrypted secrets file in $EDITOR for editing
{ pkgs, lib, cluster, clusterName }:

pkgs.writeShellApplication {
  name = "nix8sctl-${clusterName}-edit-secrets";
  runtimeInputs = with pkgs; [ sops age ];
  text = ''
    set -euo pipefail

    SECRETS_DIR="nix8s/secrets"
    SECRETS_FILE="$SECRETS_DIR/${clusterName}.yaml"
    AGE_KEY_FILE="$SECRETS_DIR/${clusterName}.age.key"
    SOPS_CONFIG="$SECRETS_DIR/.sops.yaml"

    if [[ ! -f "$AGE_KEY_FILE" ]]; then
      echo "Error: Age key not found at $AGE_KEY_FILE"
      echo "Run: nix8sctl ${clusterName} gen-secrets"
      exit 1
    fi

    if [[ ! -f "$SECRETS_FILE" ]]; then
      echo "Error: Secrets file not found at $SECRETS_FILE"
      echo "Run: nix8sctl ${clusterName} gen-secrets"
      exit 1
    fi

    export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"
    sops --config "$SOPS_CONFIG" "$SECRETS_FILE"
  '';
}
