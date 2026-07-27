# SOPS cluster extension module
# Adds sops options and generates NixOS modules for secret management.
#
# Secrets are contributed by PROVIDERS (task 10): each cluster module registers
# `sops.providers.<name>.generate` returning { "<secret/key>" = "<bash script
# printing the value to stdout>"; }. `sops gen` collects all providers, runs the
# snippets, and merges the values into the encrypted secrets/<cluster>.yaml.
# age keypair + .sops.yaml + the operator ssh keypair stay core (encryption /
# access infrastructure, not module data-secrets).
{ lib, config, ... }:

let
  cfg = config.sops;
  clusterName = config.name;

  # Derived paths from secretsDir
  secretsFile = "${cfg.secretsDir}/${clusterName}.yaml";
  ageKeyFile = "${cfg.secretsDir}/${clusterName}.age.key";
  agePubFile = "${cfg.secretsDir}/${clusterName}.age.pub";
  sshKeyFile = "${cfg.secretsDir}/${clusterName}_ssh";
  sshPubFile = "${cfg.secretsDir}/${clusterName}_ssh.pub";
  sopsConfigFile = "${cfg.secretsDir}/.sops.yaml";

  # Generate NixOS module for sops-enabled members.
  # NOTE (invariant I3): the age PRIVATE key is delivered to the node at install
  # time via `install --extra-files` (see task 04), never through the nix store.
  mkSopsNixosModule = memberName: member:
    { config, pkgs, ... }: {
      sops = {
        defaultSopsFile = secretsFile;
        age.keyFile = cfg.ageKeyFileOnHost;
        age.generateKey = false;
      };
    };

in
{
  options.sops = {
    enable = lib.mkEnableOption "SOPS secrets management";

    secretsDir = lib.mkOption {
      type = lib.types.str;
      default = "secrets";
      description = "Directory for SOPS secrets files (relative to project root)";
    };

    ageKeyFileOnHost = lib.mkOption {
      type = lib.types.str;
      default = "/etc/age/key.txt";
      description = "Path to the age private key on target systems";
    };

    # Provider registry (task 10). Cluster modules register secret generators
    # here; they are merged by the module system across all active modules.
    providers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.generate = lib.mkOption {
          type = lib.types.functionTo (lib.types.attrsOf lib.types.str);
          default = _: {};
          description = ''
            Function { pkgs, cluster, ... } -> { "<secret/key>" = "<bash script
            that PRINTS the secret value to stdout>"; }. Keys use `/` for YAML
            nesting (e.g. "k3s/token" -> k3s.token). Multi-line values (keys,
            certs) are printed in full and stored as YAML block scalars.
          '';
        };
      });
      default = {};
      description = "Secret providers contributed by cluster modules.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Generate NixOS modules for all members
    _generatedNixosModules = lib.mapAttrs
      (name: member: [ (mkSopsNixosModule name member) ])
      config.members;

    # converge preStep: materialize secrets before any member is installed.
    # Reuses the exact `sops gen` action builder (no duplicated logic).
    converge.preSteps."sops.gen" = {
      description = "Generate/merge cluster secrets from providers";
      priority = 10;
      run = config.commandGroups.sops.actions.gen.builder;
    };

    # CLI commands for sops management (group `sops`)
    commandGroups.sops = {
      description = "Secret management (sops)";
      actions = {
      gen = {
        description = "Generate/merge cluster secrets from providers";
        builder = { pkgs, cluster, ... }:
          let
            # Collect provider-contributed secrets: { "<secret/key>" = script; }
            providerSecrets = lib.foldl'
              (acc: provider: acc // (provider.generate { inherit pkgs cluster; }))
              {}
              (lib.attrValues (cluster.sops.providers or {}));

            # Emit a shell function per secret + an ensure_secret call.
            secretShell = lib.concatStringsSep "\n" (lib.mapAttrsToList (key: script:
              let
                fn = "gen_" + (lib.replaceStrings [ "/" "-" "." ] [ "_" "_" "_" ] key);
                dotPath = "." + (lib.replaceStrings [ "/" ] [ "." ] key);
              in ''
                ${fn}() {
                  ${script}
                }
                ensure_secret "${dotPath}" ${fn}
              '') providerSecrets);
          in
          pkgs.writeShellApplication {
            name = "nixclusterctl-${clusterName}-gen-secrets";
            runtimeInputs = with pkgs; [ coreutils openssh age sops yq-go ];
            text = ''
              set -euo pipefail

              FORCE="''${1:-}"

              SECRETS_DIR="${cfg.secretsDir}"
              AGE_KEY_FILE="${ageKeyFile}"
              AGE_PUB_FILE="${agePubFile}"
              SSH_KEY_FILE="${sshKeyFile}"
              SSH_PUB_FILE="${sshPubFile}"
              SECRETS_FILE="${secretsFile}"
              SOPS_CONFIG="${sopsConfigFile}"

              mkdir -p "$SECRETS_DIR"
              export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

              # --- age keypair (encryption infra, regenerate only if missing/--force) ---
              if [[ ! -f "$AGE_KEY_FILE" || "$FORCE" == "--force" ]]; then
                echo "[age] generating keypair"
                rm -f "$AGE_KEY_FILE" "$AGE_PUB_FILE"
                age-keygen 2>&1 | tee "$AGE_KEY_FILE.tmp" >/dev/null
                grep "AGE-SECRET-KEY-" "$AGE_KEY_FILE.tmp" > "$AGE_KEY_FILE"
                grep "public key:" "$AGE_KEY_FILE.tmp" | cut -d: -f2 | tr -d ' ' > "$AGE_PUB_FILE"
                rm "$AGE_KEY_FILE.tmp"
                chmod 600 "$AGE_KEY_FILE"
                AGE_PUB_KEY=$(cat "$AGE_PUB_FILE")
                cat > "$SOPS_CONFIG" << EOF
              # SOPS configuration for nixcluster secrets
              # Auto-generated by: nixclusterctl ${clusterName} sops gen
              keys:
                - &${clusterName} $AGE_PUB_KEY
              creation_rules:
                - path_regex: ${clusterName}\\.yaml$
                  key_groups:
                    - age:
                        - *${clusterName}
              EOF
              else
                echo "[age] keeping existing keypair"
              fi
              AGE_PUB_KEY=$(cat "$AGE_PUB_FILE")
              echo "[age] public key: $AGE_PUB_KEY"

              # --- operator ssh keypair (access infra, regenerate only if missing/--force) ---
              if [[ ! -f "$SSH_KEY_FILE" || "$FORCE" == "--force" ]]; then
                echo "[ssh] generating keypair"
                rm -f "$SSH_KEY_FILE" "$SSH_PUB_FILE"
                ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "nixcluster-${clusterName}" -q
                chmod 600 "$SSH_KEY_FILE"
              else
                echo "[ssh] keeping existing keypair"
              fi
              SSH_PUB_KEY=$(cat "$SSH_PUB_FILE")

              # --- working plaintext (decrypt existing for merge, unless --force) ---
              WORK=$(mktemp)
              # shellcheck disable=SC2064
              trap "rm -f '$WORK'" EXIT
              if [[ -f "$SECRETS_FILE" && "$FORCE" != "--force" ]]; then
                echo "[merge] decrypting existing secrets to add only missing keys"
                sops --config "$SOPS_CONFIG" --decrypt "$SECRETS_FILE" > "$WORK"
              else
                echo "{}" > "$WORK"
              fi

              # ssh public key (core data secret)
              VAL="$SSH_PUB_KEY" yq -i '.ssh.publicKey = strenv(VAL)' "$WORK"

              # ensure_secret <dotpath> <generator-fn>: set only if missing (or --force)
              ensure_secret() {
                local dotpath="$1" fn="$2" cur val
                if [[ "$FORCE" != "--force" ]]; then
                  cur=$(yq "$dotpath" "$WORK" 2>/dev/null || echo "null")
                  if [[ -n "$cur" && "$cur" != "null" ]]; then
                    echo "  keep   $dotpath"
                    return 0
                  fi
                fi
                val=$("$fn")
                VAL="$val" yq -i "$dotpath = strenv(VAL)" "$WORK"
                echo "  set    $dotpath"
              }

              echo "[providers] collecting secrets"
              ${secretShell}

              # --- encrypt ---
              echo "[encrypt] writing $SECRETS_FILE"
              ENCRYPTED_FILE=$(mktemp)
              sops --config "$SOPS_CONFIG" --filename-override "$SECRETS_FILE" --encrypt "$WORK" > "$ENCRYPTED_FILE"
              mv "$ENCRYPTED_FILE" "$SECRETS_FILE"

              echo ""
              echo "Secrets ready: $SECRETS_FILE (encrypted, safe to commit)"
              echo "Private keys (NEVER commit, gitignored): $AGE_KEY_FILE, $SSH_KEY_FILE"
              echo "Commit: git add $AGE_PUB_FILE $SSH_PUB_FILE $SECRETS_FILE $SOPS_CONFIG"
            '';
          };
      };

      edit = {
        description = "Edit cluster secrets";
        builder = { pkgs, cluster, ... }:
          pkgs.writeShellApplication {
            name = "nixclusterctl-${clusterName}-edit-secrets";
            runtimeInputs = with pkgs; [ sops ];
            text = ''
              SECRETS_FILE="${secretsFile}"
              AGE_KEY_FILE="${ageKeyFile}"
              SOPS_CONFIG="${sopsConfigFile}"

              if [[ ! -f "$SECRETS_FILE" ]]; then
                echo "Secrets file not found: $SECRETS_FILE"
                echo "Use 'sops gen' to create."
                exit 1
              fi

              export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"
              exec sops --config "$SOPS_CONFIG" "$SECRETS_FILE"
            '';
          };
      };

      show = {
        description = "Show decrypted secrets";
        builder = { pkgs, cluster, ... }:
          pkgs.writeShellApplication {
            name = "nixclusterctl-${clusterName}-show-secrets";
            runtimeInputs = with pkgs; [ sops ];
            text = ''
              SECRETS_FILE="${secretsFile}"
              AGE_KEY_FILE="${ageKeyFile}"
              SOPS_CONFIG="${sopsConfigFile}"

              if [[ ! -f "$SECRETS_FILE" ]]; then
                echo "Secrets file not found: $SECRETS_FILE"
                exit 1
              fi

              export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"
              sops --config "$SOPS_CONFIG" --decrypt "$SECRETS_FILE"
            '';
          };
      };
      };
    };
  };
}
