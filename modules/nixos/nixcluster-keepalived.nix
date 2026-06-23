# NixOS module for keepalived VRRP.
# Receives cluster context via the `nixcluster` module arg.
#
# Invariant I4: services.keepalived renders keepalived.conf into the world-
# readable nix store, so the VRRP auth_pass would leak. This module therefore
# does NOT use services.keepalived. Instead it runs keepalived from a config
# rendered at RUNTIME into /run/keepalived (tmpfs, 0600), reading auth_pass from
# the sops secret path /run/secrets/* (I2). The store contains only the secret
# PATH, never the password.
{ config, lib, pkgs, nixcluster, ... }:

let
  cluster = nixcluster.cluster;
  memberName = nixcluster.memberName;

  sopsEnabled = cluster.sops.enable or false;
  members = cluster.members or {};
  instances = cluster.keepalived.instances or {};

  # Instances this node participates in.
  myInstances = lib.filterAttrs (_: i: lib.elem memberName i.nodes) instances;

  cfgEnable = (cluster.keepalived.enable or false) && (myInstances != {});

  # Per-instance derived data for this node.
  instData = name: i:
    let
      nodes = i.nodes;
      isMaster = (lib.head nodes) == memberName;
      vips = (lib.optional (i.vip != null) i.vip) ++ i.vips;
      peerIps = lib.filter (ip: ip != null && ip != "")
        (map (n: members.${n}.install.ip or null) (lib.filter (n: n != memberName) nodes));
      secretKey = "keepalived/${name}/authPass";
    in
    {
      inherit name vips peerIps secretKey;
      interface = i.interface;
      virtualRouterId = i.virtualRouterId;
      state = if isMaster then "MASTER" else "BACKUP";
      priority = if isMaster then 150 else 100;
      advertInt = i.advertInt;
      secretPath =
        if sopsEnabled then config.sops.secrets.${secretKey}.path else null;
    };

  myInstData = lib.mapAttrsToList instData myInstances;

  # Runtime render script (in the store: contains only secret PATHS, no values).
  renderScript = pkgs.writeShellScript "keepalived-render-${cluster.name}" (''
    set -euo pipefail
    umask 077
    CONF=/run/keepalived/keepalived.conf
    : > "$CONF"
    chmod 600 "$CONF"
    {
      echo "global_defs {"
      echo "  enable_script_security"
      echo "}"
  '' + (lib.concatMapStringsSep "\n" (d: ''
      ${lib.optionalString (d.secretPath != null) ''
      if [ ! -r "${d.secretPath}" ]; then
        echo "keepalived: secret ${d.secretPath} not readable" >&2; exit 1
      fi
      AUTH_${toString d.virtualRouterId}="$(cat "${d.secretPath}")"
      ''}
      {
        echo "vrrp_instance ${d.name} {"
        echo "  state ${d.state}"
        echo "  interface ${d.interface}"
        echo "  virtual_router_id ${toString d.virtualRouterId}"
        echo "  priority ${toString d.priority}"
        echo "  advert_int ${toString d.advertInt}"
        ${lib.optionalString (d.peerIps != []) ''
        echo "  unicast_peer {"
        ${lib.concatMapStringsSep "\n" (ip: ''echo "    ${ip}"'') d.peerIps}
        echo "  }"
        ''}
        ${lib.optionalString (d.secretPath != null) ''
        echo "  authentication {"
        echo "    auth_type PASS"
        echo "    auth_pass $AUTH_${toString d.virtualRouterId}"
        echo "  }"
        ''}
        echo "  virtual_ipaddress {"
        ${lib.concatMapStringsSep "\n" (vip: ''echo "    ${vip}"'') d.vips}
        echo "  }"
        echo "}"
      } >> "$CONF"
  '') myInstData) + ''
    } >> "$CONF"
  '');
in
{
  config = lib.mkIf cfgEnable {
    # Auth passwords consumed from runtime sops paths (I2). Declared per instance
    # this node participates in.
    sops.secrets = lib.mkIf sopsEnabled (lib.listToAttrs
      (map (d: lib.nameValuePair d.secretKey { }) myInstData));

    systemd.services.keepalived = {
      description = "Keepalived VRRP (nixcluster, runtime-rendered config)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        RuntimeDirectory = "keepalived";
        RuntimeDirectoryMode = "0700";
        ExecStartPre = "${renderScript}";
        ExecStart = "${pkgs.keepalived}/bin/keepalived -n -f /run/keepalived/keepalived.conf";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    environment.systemPackages = [ pkgs.keepalived ];

    # Allow the VRRP protocol (IP proto 112) through the firewall. extraCommands
    # targets the default iptables firewall; document nftables setups separately.
    networking.firewall.extraCommands = lib.mkAfter ''
      iptables -I INPUT -p vrrp -j ACCEPT 2>/dev/null || true
    '';
  };
}
