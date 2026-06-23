# Nebula cluster extension module.
# Brings the Nebula NixOS module to members and provides CLI tooling to
# generate certificates, bring the mesh up, and check all-to-all connectivity.
#
# Usage:
#   imports = [ nixcluster.clusterModules.nebula nixcluster.clusterModules.sops ];
#   nebula.enable = true;
#   nebula.network = "nixcluster";          # network name
#   members.node1 = {
#     nebula.enable = true;
#     nebula.overlayIp = "192.168.100.1/24";
#     nebula.isLighthouse = true;
#   };
#   members.node2 = { nebula.enable = true; nebula.overlayIp = "192.168.100.2/24"; };
#
# Certs are produced by `nebula gen-certs`: the CA PRIVATE key is admin-only and
# gitignored (never on nodes / never in the nix store — B4); ca.crt + per-host
# cert/key are stored sops-encrypted and consumed on nodes via /run/secrets (I2).
{ lib, config, ... }:

let
  cfg = config.nebula;
  clusterName = config.name;

  nebulaNixosModule = ../modules/nixos/nixcluster-nebula.nix;

  bareIp = ipCidr: lib.head (lib.splitString "/" ipCidr);

  nebulaMembers = lib.filterAttrs
    (n: m: (m.nebula.enable or false) && (m.nebula.overlayIp or null) != null)
    config.members;
  nebulaMemberNames = lib.attrNames nebulaMembers;

  secretsDir = config.sops.secretsDir or "secrets";
  caKeyFile = "${secretsDir}/${clusterName}.nebula-ca.key";
  caCrtFile = "${secretsDir}/${clusterName}.nebula-ca.crt";
  secretsFile = "${secretsDir}/${clusterName}.yaml";
  ageKeyFile = "${secretsDir}/${clusterName}.age.key";
  sopsConfigFile = "${secretsDir}/.sops.yaml";

  # Shell prelude: resolve member -> install.ip and ssh with a pinned
  # known_hosts (B3 runtime phase; matches the incus module).
  nodeIpCases = lib.concatStringsSep "\n        " (lib.mapAttrsToList
    (name: member: ''${name}) echo "${member.install.ip or ""}" ;;'')
    nebulaMembers);

  sshPrelude = ''
    KNOWN_HOSTS=".nixcluster/known_hosts/${clusterName}"
    mkdir -p "$(dirname "$KNOWN_HOSTS")"
    touch "$KNOWN_HOSTS"
    node_ip() {
      case "$1" in
        ${nodeIpCases}
        *) echo "" ;;
      esac
    }
    ssh_node() {
      local node="$1"; shift
      local ip; ip="$(node_ip "$node")"
      if [ -z "$ip" ]; then echo "no install.ip for node '$node'" >&2; return 1; fi
      ssh -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=5 "root@$ip" "$@"
    }
  '';

  netName = cfg.network;
  memberList = lib.concatStringsSep " " nebulaMemberNames;
  # "name=bareip" pairs for shell-side matrix building.
  memberIpPairs = lib.concatStringsSep " "
    (lib.mapAttrsToList (n: m: "${n}=${bareIp m.nebula.overlayIp}") nebulaMembers);

  # Per-member signing snippets (member names/IPs known at eval).
  signSnippets = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: m: ''
    sign_member "${name}" "${m.nebula.overlayIp}"
  '') nebulaMembers);

  nebulaCommands = {
    gen-certs = {
      description = "Generate Nebula CA + per-host certs into sops (--force to re-issue)";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-nebula-gen-certs";
          runtimeInputs = with pkgs; [ nebula sops yq-go coreutils ];
          text = ''
            set -euo pipefail
            FORCE="''${1:-}"

            CA_KEY="${caKeyFile}"
            CA_CRT="${caCrtFile}"
            SECRETS_FILE="${secretsFile}"
            AGE_KEY_FILE="${ageKeyFile}"
            SOPS_CONFIG="${sopsConfigFile}"

            if [[ ! -f "$AGE_KEY_FILE" || ! -f "$SOPS_CONFIG" ]]; then
              echo "Run 'nixclusterctl ${clusterName} sops gen' first (need age key + .sops.yaml)." >&2
              exit 1
            fi
            export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

            # CA: reuse unless missing or --force (re-issuing the CA invalidates
            # every host cert). CA private key stays here (gitignored), B4.
            if [[ ! -f "$CA_KEY" || "$FORCE" == "--force" ]]; then
              echo "[ca] generating Nebula CA"
              rm -f "$CA_KEY" "$CA_CRT"
              nebula-cert ca -name "${clusterName}" -out-crt "$CA_CRT" -out-key "$CA_KEY"
              chmod 600 "$CA_KEY"
            else
              echo "[ca] keeping existing CA"
            fi

            WORK=$(mktemp -d)
            # shellcheck disable=SC2064
            trap "rm -rf '$WORK'" EXIT

            if [[ -f "$SECRETS_FILE" ]]; then
              sops --config "$SOPS_CONFIG" --decrypt "$SECRETS_FILE" > "$WORK/s.yaml"
            else
              echo "{}" > "$WORK/s.yaml"
            fi

            VAL="$(cat "$CA_CRT")" yq -i '.nebula.ca.crt = strenv(VAL)' "$WORK/s.yaml"

            # sign_member <name> <ip/cidr>: issue cert/key, store both in sops.
            sign_member() {
              local name="$1" ip="$2"
              echo "[sign] $name ($ip)"
              nebula-cert sign -ca-crt "$CA_CRT" -ca-key "$CA_KEY" \
                -name "$name" -ip "$ip" \
                -out-crt "$WORK/$name.crt" -out-key "$WORK/$name.key"
              VAL="$(cat "$WORK/$name.crt")" yq -i ".nebula.[\"$name\"].crt = strenv(VAL)" "$WORK/s.yaml"
              VAL="$(cat "$WORK/$name.key")" yq -i ".nebula.[\"$name\"].key = strenv(VAL)" "$WORK/s.yaml"
            }

            ${signSnippets}

            sops --config "$SOPS_CONFIG" --filename-override "$SECRETS_FILE" \
              --encrypt "$WORK/s.yaml" > "$SECRETS_FILE.tmp"
            mv "$SECRETS_FILE.tmp" "$SECRETS_FILE"

            echo "Nebula certs written to $SECRETS_FILE (encrypted)."
            echo "CA private key: $CA_KEY (NEVER commit; gitignored, admin-only)."
          '';
        };
    };

    up = {
      description = "(Re)start Nebula on mesh nodes";
      builder = { pkgs, cluster, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-nebula-up";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            echo "Restarting Nebula (network ${netName}) on: ${memberList}"
            for node in ${memberList}; do
              echo "--- $node ---"
              ssh_node "$node" 'systemctl restart nebula@${netName}.service && echo "  up" || echo "  failed"' \
                || echo "  (unreachable)"
            done
          '';
        };
    };

    check = {
      description = "All-to-all overlay connectivity matrix";
      builder = { pkgs, cluster, helpers, ... }:
        pkgs.writeShellApplication {
          name = "nixclusterctl-${clusterName}-nebula-check";
          runtimeInputs = with pkgs; [ openssh coreutils ];
          text = ''
            set -uo pipefail
            ${sshPrelude}
            TABLEFMT="${lib.getExe helpers.tablefmt}"

            PAIRS="${memberIpPairs}"
            NAMES="${memberList}"

            ip_of() { for p in $PAIRS; do case "$p" in "$1="*) echo "''${p#*=}";; esac; done; }

            {
              # header row
              printf 'from\\to'
              for to in $NAMES; do printf '\t%s' "$to"; done
              printf '\n'
              for from in $NAMES; do
                printf '%s' "$from"
                for to in $NAMES; do
                  tip="$(ip_of "$to")"
                  if ssh_node "$from" "ping -c1 -W1 $tip >/dev/null 2>&1"; then
                    printf '\tok'
                  else
                    printf '\tfail'
                  fi
                done
                printf '\n'
              done
            } | "$TABLEFMT"
          '';
        };
    };
  };

in
{
  options.nebula = {
    enable = lib.mkEnableOption "Nebula mesh VPN";

    network = lib.mkOption {
      type = lib.types.str;
      default = "nixcluster";
      description = "Nebula network name (services.nebula.networks.<name>).";
    };

    subnet = lib.mkOption {
      type = lib.types.str;
      default = "192.168.100.0/24";
      description = "Overlay subnet CIDR (documentation/reference for overlay IPs).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Add the Nebula NixOS module to all members; per-node activation via the
    # NixOS option nebula.enable (set as a member patch).
    _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
      [ nebulaNixosModule ]
    );

    commandGroups.nebula = lib.mkIf (nebulaMemberNames != []) {
      description = "Nebula mesh VPN management";
      actions = nebulaCommands;
    };
  };
}
