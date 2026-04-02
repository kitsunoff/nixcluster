# PXE cluster module
# Provides simple PXE server that boots a minimal NixOS installer
{ lib, config, ... }:

let
  cfg = config.pxe;
  clusterName = config.name;

  # iPXE assets path
  ipxeAssetsPath = ../assets/ipxe;

in
{
  options.pxe = {
    enable = lib.mkEnableOption "PXE boot server";

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
  };

  config = lib.mkIf cfg.enable {
    commands = [{
      pxe-server = {
        description = "Start PXE boot server";
        builder = { pkgs, cluster, ... }:
          let
            # Minimal NixOS installer config
            installerConfig = pkgs.nixos {
              imports = [
                "${pkgs.path}/nixos/modules/installer/netboot/netboot-minimal.nix"
              ];

              # Basic config
              networking.hostName = "nixos-installer";

              # Enable SSH for remote access
              services.openssh = {
                enable = true;
                settings.PermitRootLogin = "yes";
                settings.PermitEmptyPasswords = "yes";
              };

              # Empty root password for easy access
              users.users.root.initialHashedPassword = "";

              # Useful tools
              environment.systemPackages = with pkgs; [
                vim
                htop
                lsblk
                parted
                git
              ];

              system.stateVersion = "24.11";
            };

            kernel = "${installerConfig.config.system.build.kernel}/bzImage";
            initrd = "${installerConfig.config.system.build.netbootRamdisk}/initrd";
            init = installerConfig.config.system.build.toplevel;

            # iPXE binaries
            ipxeUndionly = ipxeAssetsPath + "/undionly.kpxe";
            ipxeEfi = ipxeAssetsPath + "/ipxe.efi";

          in
          pkgs.writeShellApplication {
            name = "nix8sctl-${clusterName}-pxe-server";
            runtimeInputs = with pkgs; [ dnsmasq python3 coreutils ];
            text = ''
              set -euo pipefail

              INTERFACE="''${1:-${cfg.interface}}"
              HTTP_PORT="''${2:-${toString cfg.httpPort}}"

              TFTP_ROOT=$(mktemp -d)
              HTTP_ROOT=$(mktemp -d)

              echo "========================================"
              echo " PXE Boot Server"
              echo " Cluster: ${clusterName}"
              echo "========================================"
              echo ""
              echo "Interface: $INTERFACE"
              echo "HTTP Port: $HTTP_PORT"
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

              # Setup TFTP root
              cp ${ipxeUndionly} "$TFTP_ROOT/undionly.kpxe"
              cp ${ipxeEfi} "$TFTP_ROOT/ipxe.efi"

              # Create iPXE chain script
              cat > "$TFTP_ROOT/boot.ipxe" << EOF
              #!ipxe
              dhcp
              chain http://$SERVER_IP:$HTTP_PORT/menu.ipxe
              EOF

              # Setup HTTP root
              mkdir -p "$HTTP_ROOT/installer"
              ln -s ${kernel} "$HTTP_ROOT/installer/bzImage"
              ln -s ${initrd} "$HTTP_ROOT/installer/initrd"

              # Create boot menu
              cat > "$HTTP_ROOT/menu.ipxe" << EOF
              #!ipxe

              menu NixOS PXE Boot
              item installer   Boot NixOS Installer
              item shell       iPXE Shell
              choose --default installer --timeout 10000 target && goto \''${target} || goto shell

              :installer
              echo Booting NixOS installer...
              kernel http://$SERVER_IP:$HTTP_PORT/installer/bzImage init=${init}/init initrd=initrd loglevel=4
              initrd http://$SERVER_IP:$HTTP_PORT/installer/initrd
              boot

              :shell
              shell
              EOF

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

              # Start HTTP server
              echo "Starting HTTP server on port $HTTP_PORT..."
              cd "$HTTP_ROOT"
              ${pkgs.python3}/bin/python3 -m http.server "$HTTP_PORT" &
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
              echo "Boot modes supported:"
              echo "  - Legacy BIOS"
              echo "  - UEFI x86_64"
              echo ""
              echo "After boot, SSH to the installer:"
              echo "  ssh root@<IP>  (empty password)"
              echo ""
              echo "Press Ctrl+C to stop."

              wait $DNSMASQ_PID
            '';
          };
      };
    }];
  };
}
