# PXE cluster module
# Provides PXE server with MAC-based auto-provisioning
#
# Features:
# - Discovery mode: unknown MAC → boots minimal installer for hardware discovery
# - Provisioning mode: known MAC → boots auto-installer with target nixosConfiguration
#
# Usage:
#   pxe.enable = true;
#   members.node1 = {
#     nixosConfiguration = ...;
#     install.ip = "192.168.1.10";
#     install.mac = "aa:bb:cc:dd:ee:ff";  # enables auto-provisioning
#     install.disk = "/dev/sda";
#   };
{ lib, config, ... }:

let
  cfg = config.pxe;
  clusterName = config.name;

  # iPXE assets path
  ipxeAssetsPath = ../assets/ipxe;

  # Path to modules
  installerModule = ../modules/nixos/installer.nix;
  discoveryModule = ../modules/nixos/discovery.nix;

  # Path to pxe server script
  pxeServerScript = ../scripts/pxe_server.py;

  # Get members with MAC addresses (for provisioning)
  membersWithMac = lib.filterAttrs
    (name: member: member.install.mac or null != null)
    config.members;

  # Generate installer NixOS config for a member
  mkInstallerConfig = memberName: member: { pkgs, inputs, ... }:
    let
      # Target config is the member's nixosConfiguration with cluster patches
      # This will be built and installed by the installer
      targetConfig = member.nixosConfiguration.extendModules {
        modules = config._generatedNixosModules.${memberName} or [];
      };

      targetDisk = member.install.disk or "/dev/sda";
    in
    pkgs.nixos {
      imports = [
        "${pkgs.path}/nixos/modules/installer/netboot/netboot-minimal.nix"
        inputs.disko.nixosModules.disko
      ];

      # Hostname for installer
      networking.hostName = "${clusterName}-${memberName}-installer";

      # Enable SSH for debugging
      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = "yes";
          PermitEmptyPasswords = "yes";
        };
      };

      # Empty root password for emergency access
      users.users.root.initialHashedPassword = "";

      # Auto-start installation
      systemd.services.nix8s-installer = {
        description = "nix8s Auto-Installer";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        path = with pkgs; [
          nixos-install-tools
          nix
          parted
          dosfstools
          e2fsprogs
          util-linux
          coreutils
        ];

        serviceConfig = {
          Type = "oneshot";
          StandardOutput = "journal+console";
          StandardError = "journal+console";
        };

        script = ''
          set -euo pipefail

          echo ""
          echo "=========================================="
          echo " nix8s Auto-Installer"
          echo " Target: ${clusterName}-${memberName}"
          echo " Disk: ${targetDisk}"
          echo "=========================================="
          echo ""

          # Wait for network
          echo "Waiting for network..."
          for i in $(seq 1 30); do
            if ping -c 1 cache.nixos.org > /dev/null 2>&1; then
              echo "Network is up."
              break
            fi
            sleep 1
          done

          # Format disk with disko
          echo ""
          echo "Formatting disk with disko..."
          ${targetConfig.config.system.build.diskoScript}

          # Mount filesystems
          echo ""
          echo "Mounting filesystems..."
          ${targetConfig.config.system.build.mountScript}

          # Install NixOS
          echo ""
          echo "Installing NixOS configuration..."
          nixos-install --no-root-passwd --system ${targetConfig.config.system.build.toplevel}

          echo ""
          echo "=========================================="
          echo " Installation complete!"
          echo " Rebooting in 5 seconds..."
          echo "=========================================="
          sleep 5

          reboot
        '';
      };

      # Required packages
      environment.systemPackages = with pkgs; [
        nixos-install-tools
        vim
        htop
        parted
        dosfstools
        e2fsprogs
      ];

      boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];
      documentation.enable = false;
      documentation.nixos.enable = false;
      system.stateVersion = "24.11";
    };

  # Generate discovery NixOS config (for unknown MACs)
  mkDiscoveryConfig = { pkgs, ... }:
    pkgs.nixos {
      imports = [
        "${pkgs.path}/nixos/modules/installer/netboot/netboot-minimal.nix"
      ];

      networking.hostName = lib.mkForce "discovery";

      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = lib.mkForce "yes";
          PermitEmptyPasswords = lib.mkForce "yes";
        };
      };

      users.users.root.initialHashedPassword = lib.mkForce "";

      # Set hostname based on MAC
      systemd.services.set-hostname-from-mac = {
        description = "Set hostname based on MAC address";
        wantedBy = [ "multi-user.target" ];
        before = [ "network-online.target" "nix8s-discovery.service" ];
        after = [ "systemd-udevd.service" ];
        path = with pkgs; [ iproute2 gnugrep coreutils gawk hostname ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          PRIMARY_IFACE=$(ip -o link show | grep -v "lo:" | head -1 | awk -F': ' '{print $2}')
          if [[ -n "$PRIMARY_IFACE" ]] && [[ -f "/sys/class/net/$PRIMARY_IFACE/address" ]]; then
            MAC=$(cat /sys/class/net/"$PRIMARY_IFACE"/address)
            MAC_CLEAN=$(echo "$MAC" | tr -d ':' | tr '[:upper:]' '[:lower:]')
            NEW_HOSTNAME="discovery-$MAC_CLEAN"
            hostname "$NEW_HOSTNAME"
            echo "Hostname set to: $NEW_HOSTNAME"
          fi
        '';
      };

      # Hardware discovery service
      systemd.services.nix8s-discovery = {
        description = "nix8s Hardware Discovery";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "set-hostname-from-mac.service" ];
        wants = [ "network-online.target" ];
        path = with pkgs; [ iproute2 gnugrep coreutils gawk findutils hostname util-linux jq curl ];

        serviceConfig = {
          Type = "oneshot";
          StandardOutput = "journal+console";
          StandardError = "journal+console";
          RemainAfterExit = true;
        };

        script = ''
          set -euo pipefail

          echo ""
          echo "=========================================="
          echo " nix8s Hardware Discovery"
          echo " Cluster: ${clusterName}"
          echo "=========================================="
          echo ""

          # Wait for network
          echo "Waiting for network..."
          for i in $(seq 1 30); do
            if ip route | grep -q default; then
              echo "Network is up."
              break
            fi
            sleep 1
          done

          # Collect hardware info
          echo "Collecting hardware information..."

          PRIMARY_IFACE=$(ip -o link show | grep -v "lo:" | head -1 | awk -F': ' '{print $2}')
          MAC=$(cat /sys/class/net/"$PRIMARY_IFACE"/address)
          IP_ADDR=$(ip -4 addr show "$PRIMARY_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

          INTERFACES=$(ip -j link show | jq -c '[.[] | select(.ifname != "lo") | {name: .ifname, mac: .address}]')
          DISKS=$(lsblk -J -o NAME,SIZE,TYPE,MODEL,SERIAL | jq -c '.blockdevices | [.[] | select(.type == "disk")]')

          MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
          MEMORY_GB=$((MEMORY_KB / 1024 / 1024))

          CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
          CPU_CORES=$(grep -c "^processor" /proc/cpuinfo)

          VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "unknown")
          PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
          SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "unknown")

          PAYLOAD=$(jq -n \
            --arg mac "$MAC" \
            --arg ip "$IP_ADDR" \
            --arg hostname "$(hostname)" \
            --argjson interfaces "$INTERFACES" \
            --argjson disks "$DISKS" \
            --arg memory_gb "$MEMORY_GB" \
            --arg cpu_model "$CPU_MODEL" \
            --arg cpu_cores "$CPU_CORES" \
            --arg vendor "$VENDOR" \
            --arg product "$PRODUCT" \
            --arg serial "$SERIAL" \
            --arg cluster "${clusterName}" \
            --arg discovered_at "$(date -Iseconds)" \
            '{
              mac: $mac,
              ip: $ip,
              hostname: $hostname,
              interfaces: $interfaces,
              disks: $disks,
              memory_gb: ($memory_gb | tonumber),
              cpu: { model: $cpu_model, cores: ($cpu_cores | tonumber) },
              system: { vendor: $vendor, product: $product, serial: $serial },
              cluster: $cluster,
              discovered_at: $discovered_at
            }')

          echo ""
          echo "Hardware info:"
          echo "$PAYLOAD" | jq .

          # Report to PXE server
          SERVER_IP=$(grep -oP 'pxe_server=\K[^\s]+' /proc/cmdline || ip route | grep default | awk '{print $3}')
          SERVER_PORT=$(grep -oP 'pxe_port=\K[^\s]+' /proc/cmdline || echo "8080")

          echo ""
          echo "Reporting to PXE server..."
          if curl -s -X POST -H "Content-Type: application/json" -d "$PAYLOAD" \
              "http://''${SERVER_IP}:''${SERVER_PORT}/api/discover" > /tmp/response.json 2>&1; then
            echo "Reported successfully"
          else
            echo "Failed to report (server may not be running)"
            echo "$PAYLOAD" > /tmp/discovery.json
          fi

          echo ""
          echo "=========================================="
          echo " Discovery complete!"
          echo " MAC: $MAC"
          echo " IP: $IP_ADDR"
          echo ""
          echo " Add to cluster config:"
          echo "   members.<name>.install.mac = \"$MAC\";"
          echo "=========================================="
          echo ""
          echo "SSH: ssh root@$IP_ADDR (empty password)"
        '';
      };

      environment.systemPackages = with pkgs; [
        vim htop jq curl iproute2 gawk gnugrep coreutils
        findutils hostname util-linux pciutils usbutils dmidecode lshw
      ];

      boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];
      documentation.enable = false;
      documentation.nixos.enable = false;
      system.stateVersion = "24.11";
    };

in
{
  options.pxe = {
    enable = lib.mkEnableOption "PXE boot server with auto-provisioning";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
      description = "Network interface to listen on";
    };

    httpPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "HTTP port for serving boot files";
    };

    discoveryTimeout = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Timeout in seconds for discovery menu (0 = no auto-boot)";
    };
  };

  config = lib.mkIf cfg.enable {
    commands = [{
      pxe-server = {
        description = "Start PXE boot server with auto-provisioning";
        builder = { pkgs, cluster, ... }:
          let
            # Build installer configs for each member with MAC
            installerConfigs = lib.mapAttrs (name: member:
              mkInstallerConfig name member { inherit pkgs; inputs = cluster._inputs or {}; }
            ) membersWithMac;

            # Build discovery config
            discoveryConfig = mkDiscoveryConfig { inherit pkgs; };

            # iPXE binaries
            ipxeUndionly = ipxeAssetsPath + "/undionly.kpxe";
            ipxeEfi = ipxeAssetsPath + "/ipxe.efi";

            # Generate iPXE menu with MAC routing
            menuContent = ''
              #!ipxe

              # MAC-based auto-routing
              ${lib.concatMapStringsSep "\n" (name:
                let
                  member = config.members.${name};
                  mac = lib.toLower (member.install.mac);
                in
                "iseq \''${net0/mac} ${mac} && goto install-${name} ||"
              ) (lib.attrNames membersWithMac)}

              # No MAC match - show menu
              goto menu

              :menu
              menu nix8s PXE Boot - ${clusterName}
              item discovery   [Discovery] Scan hardware (unknown nodes)
              item --gap --
              ${lib.concatMapStringsSep "\n" (name:
                let
                  member = config.members.${name};
                  mac = member.install.mac;
                  ip = member.install.ip or "no-ip";
                in
                "item install-${name} Install ${name} (${mac}, ${ip})"
              ) (lib.attrNames membersWithMac)}
              item --gap --
              item shell       iPXE shell
              choose --default discovery --timeout ${toString (cfg.discoveryTimeout * 1000)} target && goto \''${target} || goto shell

              :discovery
              echo Booting discovery image...
              kernel http://__SERVER__:__PORT__/discovery/bzImage init=${discoveryConfig.config.system.build.toplevel}/init initrd=initrd loglevel=4 pxe_server=__SERVER__ pxe_port=__PORT__
              initrd http://__SERVER__:__PORT__/discovery/initrd
              boot

              ${lib.concatMapStringsSep "\n\n" (name:
                let
                  installerConfig = installerConfigs.${name};
                  kernel = "${installerConfig.config.system.build.kernel}/bzImage";
                  initrd = "${installerConfig.config.system.build.netbootRamdisk}/initrd";
                  toplevel = installerConfig.config.system.build.toplevel;
                in
                ''
                  :install-${name}
                  echo Installing ${name}...
                  kernel http://__SERVER__:__PORT__/installer-${name}/bzImage init=${toplevel}/init initrd=initrd loglevel=4
                  initrd http://__SERVER__:__PORT__/installer-${name}/initrd
                  boot
                ''
              ) (lib.attrNames membersWithMac)}

              :shell
              shell
            '';

          in
          pkgs.writeShellApplication {
            name = "nix8sctl-${clusterName}-pxe-server";
            runtimeInputs = with pkgs; [ dnsmasq python3 coreutils jq ];
            text = ''
              set -euo pipefail

              INTERFACE="''${1:-${cfg.interface}}"
              HTTP_PORT="''${2:-${toString cfg.httpPort}}"

              TFTP_ROOT=$(mktemp -d)
              HTTP_ROOT=$(mktemp -d)
              NODES_DIR="$PWD/discovered-nodes"

              echo "========================================"
              echo " PXE Boot Server - ${clusterName}"
              echo "========================================"
              echo ""
              echo "Interface: $INTERFACE"
              echo "HTTP Port: $HTTP_PORT"
              echo ""
              echo "Configured members:"
              ${lib.concatMapStringsSep "\n" (name:
                let
                  member = config.members.${name};
                  mac = member.install.mac;
                  ip = member.install.ip or "no-ip";
                in
                ''echo "  - ${name}: MAC=${mac}, IP=${ip}"''
              ) (lib.attrNames membersWithMac)}
              ${if membersWithMac == {} then ''echo "  (none - all boots will go to discovery)"'' else ""}
              echo ""

              # Get server IP
              if command -v ip &> /dev/null; then
                SERVER_IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
              else
                SERVER_IP=$(ifconfig "$INTERFACE" | grep 'inet ' | awk '{print $2}')
              fi

              if [[ -z "$SERVER_IP" ]]; then
                echo "ERROR: Could not determine IP for interface $INTERFACE"
                exit 1
              fi

              echo "Server IP: $SERVER_IP"
              echo ""

              # Setup TFTP
              cp ${ipxeUndionly} "$TFTP_ROOT/undionly.kpxe"
              cp ${ipxeEfi} "$TFTP_ROOT/ipxe.efi"

              cat > "$TFTP_ROOT/boot.ipxe" << EOF
              #!ipxe
              dhcp
              chain http://$SERVER_IP:$HTTP_PORT/menu.ipxe
              EOF

              # Setup HTTP root
              mkdir -p "$HTTP_ROOT/discovery"
              ln -s ${discoveryConfig.config.system.build.kernel}/bzImage "$HTTP_ROOT/discovery/bzImage"
              ln -s ${discoveryConfig.config.system.build.netbootRamdisk}/initrd "$HTTP_ROOT/discovery/initrd"

              ${lib.concatMapStringsSep "\n" (name:
                let
                  installerConfig = installerConfigs.${name};
                  kernel = "${installerConfig.config.system.build.kernel}/bzImage";
                  initrd = "${installerConfig.config.system.build.netbootRamdisk}/initrd";
                in
                ''
                  mkdir -p "$HTTP_ROOT/installer-${name}"
                  ln -s ${kernel} "$HTTP_ROOT/installer-${name}/bzImage"
                  ln -s ${initrd} "$HTTP_ROOT/installer-${name}/initrd"
                ''
              ) (lib.attrNames membersWithMac)}

              # Generate menu with actual IP
              cat > "$HTTP_ROOT/menu.ipxe" << 'MENU_EOF'
              ${menuContent}
              MENU_EOF
              sed -i "s/__SERVER__/$SERVER_IP/g; s/__PORT__/$HTTP_PORT/g" "$HTTP_ROOT/menu.ipxe"

              echo "Boot menu:"
              cat "$HTTP_ROOT/menu.ipxe"
              echo ""

              # Cleanup
              cleanup() {
                echo ""
                echo "Stopping servers..."
                kill $HTTP_PID 2>/dev/null || true
                [[ -n "''${DNSMASQ_PID:-}" ]] && kill $DNSMASQ_PID 2>/dev/null || sudo kill $DNSMASQ_PID 2>/dev/null || true
                rm -rf "$TFTP_ROOT" "$HTTP_ROOT"
              }
              trap cleanup EXIT INT TERM

              # Start HTTP server with discovery API
              mkdir -p "$NODES_DIR"
              export ASSETS_DIR="$HTTP_ROOT"
              export NODES_DIR="$NODES_DIR"

              echo "Starting HTTP server on port $HTTP_PORT..."
              ${pkgs.python3}/bin/python3 ${pxeServerScript} "$HTTP_PORT" &
              HTTP_PID=$!

              sleep 1

              # Start dnsmasq
              echo "Starting dnsmasq (TFTP + ProxyDHCP)..."
              echo ""

              if [[ $EUID -ne 0 ]]; then
                echo "Note: DHCP requires root. Using sudo for dnsmasq..."
                SUDO="sudo"
              else
                SUDO=""
              fi

              $SUDO dnsmasq \
                --no-daemon \
                --port=0 \
                --interface="$INTERFACE" \
                --bind-interfaces \
                --leasefile-ro \
                --dhcp-range="$SERVER_IP,proxy" \
                --dhcp-match=set:ipxe,175 \
                --dhcp-match=set:bios,option:client-arch,0 \
                --dhcp-match=set:efi64,option:client-arch,7 \
                --dhcp-match=set:efi64,option:client-arch,9 \
                --dhcp-boot=tag:ipxe,boot.ipxe \
                --dhcp-boot=tag:!ipxe,tag:bios,undionly.kpxe \
                --dhcp-boot=tag:!ipxe,tag:efi64,ipxe.efi \
                --pxe-service=tag:!ipxe,tag:bios,x86PC,"PXE chainload to iPXE",undionly.kpxe \
                --pxe-service=tag:!ipxe,tag:efi64,x86-64_EFI,"PXE chainload to iPXE",ipxe.efi \
                --enable-tftp \
                --tftp-root="$TFTP_ROOT" \
                --log-dhcp &
              DNSMASQ_PID=$!

              echo ""
              echo "========================================"
              echo " PXE server is running!"
              echo "========================================"
              echo ""
              echo "Boot modes: Legacy BIOS, UEFI x86_64"
              echo ""
              echo "API endpoints:"
              echo "  http://$SERVER_IP:$HTTP_PORT/api/nodes    - List discovered nodes"
              echo "  http://$SERVER_IP:$HTTP_PORT/api/discover - Discovery callback"
              echo ""
              echo "Discovered nodes: $NODES_DIR/"
              echo ""
              echo "Press Ctrl+C to stop."

              wait $DNSMASQ_PID
            '';
          };
      };
    }];
  };
}
