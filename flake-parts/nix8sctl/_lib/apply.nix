# nix8sctl <cluster> apply <member> [ip] [options]
# Applies NixOS configuration to a cluster member
{ pkgs, lib, cluster, clusterName, nodes }:

let
  members = cluster.members;
  memberNames = lib.attrNames members;

  # Generate member list with IPs
  memberListStr = lib.concatMapStringsSep "\n" (memberName:
    let
      member = members.${memberName};
      ipStr = if member.ip or null != null then " (ip: ${member.ip})" else "";
    in
    ''echo "  ${memberName}${ipStr}"''
  ) memberNames;

  memberCase = lib.concatMapStringsSep "|" (n: ''"${n}"'') memberNames;

  # Generate IP lookup
  ipLookup = lib.concatMapStringsSep "\n" (memberName:
    let member = members.${memberName};
    in lib.optionalString (member.ip or null != null)
      ''      "${memberName}") CONFIG_IP="${member.ip}" ;;''
  ) memberNames;

in
pkgs.writeShellApplication {
  name = "nix8sctl-${clusterName}-apply";
  runtimeInputs = with pkgs; [
    openssh
    nixos-rebuild
    nix
    coreutils
  ];
  text = ''
    set -euo pipefail

    MEMBER_NAME="''${1:-}"
    TARGET_IP=""
    BUILD_ON_REMOTE=""
    FULL_INSTALL=""
    CONFIG_IP=""

    # Shift first argument (member name)
    shift 2>/dev/null || true

    # Parse remaining arguments
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --build-on-remote)
          BUILD_ON_REMOTE="1"
          shift
          ;;
        --full-install)
          FULL_INSTALL="1"
          shift
          ;;
        -*)
          echo "Unknown option: $1"
          exit 1
          ;;
        *)
          # First non-option argument is IP
          if [[ -z "$TARGET_IP" ]]; then
            TARGET_IP="$1"
          else
            echo "Unknown argument: $1"
            exit 1
          fi
          shift
          ;;
      esac
    done

    if [[ -z "$MEMBER_NAME" ]]; then
      echo "Usage: nix8sctl ${clusterName} apply <member> [ip] [options]"
      echo ""
      echo "Applies NixOS configuration to a cluster member."
      echo "Delivers age key for sops-nix secrets decryption."
      echo ""
      echo "Arguments:"
      echo "  member     Member name"
      echo "  ip         Target IP address (optional if configured)"
      echo ""
      echo "Options:"
      echo "  --build-on-remote    Build on target machine instead of locally"
      echo "  --full-install       Full reinstall via nixos-anywhere (kexec + disk wipe)"
      echo ""
      echo "Members:"
      ${memberListStr}
      exit 1
    fi

    # Validate member name
    case "$MEMBER_NAME" in
      ${memberCase})
        ;;
      *)
        echo "Error: Unknown member '$MEMBER_NAME' in cluster '${clusterName}'"
        echo ""
        echo "Available members:"
        ${memberListStr}
        exit 1
        ;;
    esac

    # Look up IP from config
    case "$MEMBER_NAME" in
${ipLookup}
      *) ;;
    esac

    # Determine final IP
    if [[ -z "$TARGET_IP" ]]; then
      if [[ -n "$CONFIG_IP" ]]; then
        TARGET_IP="$CONFIG_IP"
      else
        echo "Error: No IP address specified and none found in config"
        echo ""
        echo "Usage: nix8sctl ${clusterName} apply $MEMBER_NAME <ip> [options]"
        exit 1
      fi
    fi

    CONFIG_NAME="${clusterName}-$MEMBER_NAME"
    SECRETS_DIR="nix8s/secrets"

    # Determine SSH options
    SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    SSH_KEY_FILE="$SECRETS_DIR/${clusterName}_ssh"
    if [[ -f "$SSH_KEY_FILE" ]]; then
      SSH_OPTS+=(-i "$SSH_KEY_FILE")
    fi

    # Full install mode: use nixos-anywhere with kexec
    if [[ -n "$FULL_INSTALL" ]]; then
      echo "=========================================="
      echo "Full install: $CONFIG_NAME"
      echo "=========================================="
      echo ""
      echo "Target:  root@$TARGET_IP"
      echo "Cluster: ${clusterName}"
      echo "Member:  $MEMBER_NAME"
      echo ""
      echo "WARNING: This will WIPE the disk and reinstall!"
      echo ""

      # Build nixos-anywhere arguments
      ANYWHERE_ARGS=(
        --flake ".#$CONFIG_NAME"
      )

      # Add SSH key if available
      if [[ -f "$SSH_KEY_FILE" ]]; then
        ANYWHERE_ARGS+=(-i "$SSH_KEY_FILE")
      fi

      # Add extra files for age key delivery
      AGE_KEY_FILE="$SECRETS_DIR/${clusterName}.age.key"
      if [[ -f "$AGE_KEY_FILE" ]]; then
        EXTRA_FILES_DIR=$(mktemp -d)
        trap 'rm -rf "$EXTRA_FILES_DIR"' EXIT

        mkdir -p "$EXTRA_FILES_DIR/etc/age"
        cp "$AGE_KEY_FILE" "$EXTRA_FILES_DIR/etc/age/key.txt"
        chmod 600 "$EXTRA_FILES_DIR/etc/age/key.txt"

        ANYWHERE_ARGS+=(--extra-files "$EXTRA_FILES_DIR")
        echo "[*] Age key will be deployed to /etc/age/key.txt"
      fi

      # Build on remote if requested
      if [[ -n "$BUILD_ON_REMOTE" ]]; then
        ANYWHERE_ARGS+=(--build-on-remote)
      fi

      ANYWHERE_ARGS+=("root@$TARGET_IP")

      echo "[*] Running nixos-anywhere..."
      echo "    Command: nixos-anywhere ''${ANYWHERE_ARGS[*]}"
      echo ""

      if command -v nixos-anywhere &>/dev/null; then
        nixos-anywhere "''${ANYWHERE_ARGS[@]}"
      else
        nix run github:nix-community/nixos-anywhere -- "''${ANYWHERE_ARGS[@]}"
      fi

      echo ""
      echo "=========================================="
      echo "Full install complete!"
      echo "=========================================="
      echo ""
      echo "Connect with:"
      echo "  ssh ''${SSH_OPTS[*]} root@$TARGET_IP"
      exit 0
    fi

    # Regular apply mode
    echo "=========================================="
    echo "Applying: $CONFIG_NAME"
    echo "=========================================="
    echo ""
    echo "Target:  root@$TARGET_IP"
    echo "Cluster: ${clusterName}"
    echo "Member:  $MEMBER_NAME"
    echo ""

    # Step 1: Deploy age key
    AGE_KEY_FILE="$SECRETS_DIR/${clusterName}.age.key"
    if [[ -f "$AGE_KEY_FILE" ]]; then
      echo "[1/3] Deploying age key..."
      ssh "''${SSH_OPTS[@]}" "root@$TARGET_IP" "mkdir -p /etc/age && chmod 700 /etc/age"
      scp "''${SSH_OPTS[@]}" "$AGE_KEY_FILE" "root@$TARGET_IP:/etc/age/key.txt"
      ssh "''${SSH_OPTS[@]}" "root@$TARGET_IP" "chmod 600 /etc/age/key.txt"
      echo "       Age key deployed to /etc/age/key.txt"
    else
      echo "[1/3] No age key found at $AGE_KEY_FILE - skipping"
      echo "       (Run 'nix8sctl ${clusterName} gen-secrets' if using sops)"
    fi

    # Step 2: Build and deploy NixOS configuration
    echo "[2/3] Building and deploying NixOS configuration..."
    NIX_SSHOPTS_STR="''${SSH_OPTS[*]}"
    if [[ -n "$BUILD_ON_REMOTE" ]]; then
      echo "       Building on remote machine..."
      NIX_SSHOPTS="$NIX_SSHOPTS_STR" nixos-rebuild switch \
        --flake ".#$CONFIG_NAME" \
        --target-host "root@$TARGET_IP" \
        --build-host "root@$TARGET_IP"
    else
      echo "       Building locally, deploying to remote..."
      NIX_SSHOPTS="$NIX_SSHOPTS_STR" nixos-rebuild switch \
        --flake ".#$CONFIG_NAME" \
        --target-host "root@$TARGET_IP"
    fi

    # Step 3: Verify
    echo "[3/3] Verifying deployment..."
    if ssh "''${SSH_OPTS[@]}" "root@$TARGET_IP" "test -d /run/secrets"; then
      echo "       Secrets directory exists!"
    else
      echo "       Note: /run/secrets not found"
      echo "       This is normal if sops is not configured"
    fi

    echo ""
    echo "=========================================="
    echo "Configuration applied successfully!"
    echo "=========================================="
    echo ""
    echo "Next steps:"
    echo "  - Check node status:"
    echo "    ssh ''${SSH_OPTS[*]} root@$TARGET_IP systemctl status"
  '';
}
