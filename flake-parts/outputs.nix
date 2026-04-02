# Generates nixosConfigurations from nix8s nodes and clusters
{ lib, config, inputs, ... }:

let
  cfg = config.nix8s;
  nix8sModulesPath = ../modules/nixos;

  # Build standalone NixOS config for a node
  mkStandaloneConfig = nodeName: nodeConfig:
    lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit inputs;
        nix8s = {
          inherit nodeName nodeConfig;
          # No cluster context
          cluster = null;
          clusterName = null;
          memberName = null;
        };
      };
      modules = [
        inputs.disko.nixosModules.disko
        inputs.sops-nix.nixosModules.sops
        (nix8sModulesPath + "/base.nix")
      ] ++ (nodeConfig.nixosModules or [ ])
      ++ (cfg.nixosModulesFor.${nodeName} or [ ]);
    };

  # Build NixOS config for a node in cluster context
  mkClusterConfig = { clusterName, cluster, memberName }:
    let
      nodeName = memberName;
      nodeConfig = cfg.nodes.${memberName} or
        (throw "nix8s: clusters.${clusterName}.members.${memberName} references node '${memberName}' which doesn't exist in nix8s.nodes. Available nodes: ${builtins.toString (builtins.attrNames cfg.nodes)}");

      member = cluster.members.${memberName};
      configName = "${clusterName}-${memberName}";
    in
    lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit inputs;
        nix8s = {
          inherit nodeName nodeConfig;
          inherit cluster clusterName memberName member;
          configName = configName;
        };
      };
      modules = [
        inputs.disko.nixosModules.disko
        inputs.sops-nix.nixosModules.sops
        (nix8sModulesPath + "/base.nix")
        (nix8sModulesPath + "/sops.nix")
      ] ++ (nodeConfig.nixosModules or [ ])
      ++ (cfg.nixosModulesFor.${configName} or [ ]);
    };

  # Generate standalone configs for all nodes
  standaloneConfigs = lib.mapAttrs mkStandaloneConfig cfg.nodes;

  # Generate cluster configs for all cluster members
  clusterConfigs = lib.concatMapAttrs
    (clusterName: cluster:
      lib.mapAttrs'
        (memberName: _member:
          lib.nameValuePair
            "${clusterName}-${memberName}"
            (mkClusterConfig { inherit clusterName cluster memberName; })
        )
        cluster.members
    )
    cfg.clusters;

  # Merge: cluster configs override standalone if same name
  allConfigs = standaloneConfigs // clusterConfigs;

in
{
  config.flake.nixosConfigurations = allConfigs;
}
