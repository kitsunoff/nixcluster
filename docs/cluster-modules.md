# Cluster Modules Guide

Cluster modules extend nixcluster clusters with additional functionality. They can:
- Define cluster-level options
- Generate NixOS modules for cluster members
- Add CLI commands to nixclusterctl

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Cluster Configuration                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ k3s.enable  │  │ sops.enable │  │ cozystack.enable    │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│                                                              │
│  members.node1 = {                                           │
│    nixosConfiguration = base;                                │
│    install.ip = "192.168.1.10";                             │
│    k3s.role = "server";        ← NixOS option (patch)       │
│  };                                                          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     Cluster Modules                          │
│  ┌──────────────────┐  ┌──────────────────────────────────┐ │
│  │ cluster-modules/ │  │ Responsibilities:                │ │
│  │   k3s.nix        │  │ • Define cluster-level options   │ │
│  │   sops.nix       │  │ • Add NixOS modules to members   │ │
│  │   cozystack.nix  │  │ • Provide CLI commands           │ │
│  └──────────────────┘  └──────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      NixOS Modules                           │
│  ┌──────────────────┐                                       │
│  │ modules/nixos/   │  Receive nixcluster context:               │
│  │   nixcluster-k3s.nix  │  • nixcluster.cluster   - full cluster    │
│  │                  │  • nixcluster.member    - current member  │
│  │                  │  • nixcluster.memberName                   │
│  └──────────────────┘                                       │
└─────────────────────────────────────────────────────────────┘
```

## Creating a Cluster Module

### Basic Structure

```nix
# cluster-modules/mymodule.nix
{ lib, config, ... }:

let
  cfg = config.mymodule;
  clusterName = config.name;

  # Path to NixOS module
  myNixosModule = ../modules/nixos/mymodule.nix;

in
{
  # 1. Define cluster-level options
  options.mymodule = {
    enable = lib.mkEnableOption "My module";

    someSetting = lib.mkOption {
      type = lib.types.str;
      default = "value";
    };
  };

  # 2. Configure when enabled
  config = lib.mkIf cfg.enable {
    # Add NixOS module to ALL members
    _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
      [ myNixosModule ]
    );

    # Add CLI commands
    commands = [{
      my-command = {
        description = "Do something";
        builder = { pkgs, cluster, ... }:
          pkgs.writeShellApplication {
            name = "nixclusterctl-${clusterName}-my-command";
            text = ''echo "Hello from ${clusterName}"'';
          };
      };
    }];
  };
}
```

### NixOS Module with Cluster Context

```nix
# modules/nixos/mymodule.nix
{ config, lib, pkgs, nixcluster, ... }:

let
  # Access cluster context
  cluster = nixcluster.cluster;
  member = nixcluster.member;
  memberName = nixcluster.memberName;

  # Read member-specific options (these are NixOS patches from cluster config)
  myRole = member.mymodule.role or null;

  # Read cluster-level settings
  mySetting = cluster.mymodule.someSetting;

  # Access other members
  allMembers = cluster.members;

in
{
  # Define NixOS options that members can set
  options.mymodule = {
    role = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "primary" "secondary" ]);
      default = null;
      description = "Role for this node";
    };
  };

  # Configure based on role
  config = lib.mkIf (myRole != null) {
    # Your NixOS configuration here
    environment.etc."mymodule/role".text = myRole;
  };
}
```

## Key Concepts

### 1. Member Options vs Cluster Options

**Cluster-level options** (defined in cluster module):
```nix
# In cluster config:
mymodule.enable = true;
mymodule.someSetting = "value";
```

**Member-level options** (defined in NixOS module, set as patches):
```nix
# In cluster config:
members.node1 = {
  nixosConfiguration = base;
  mymodule.role = "primary";  # This becomes a NixOS option
};
```

### 2. The `nixcluster` Module Argument

Every NixOS module added via `_generatedNixosModules` receives:

| Argument | Description |
|----------|-------------|
| `nixcluster.cluster` | Full evaluated cluster config |
| `nixcluster.member` | Current member's config (from `cluster.members.<name>`) |
| `nixcluster.memberName` | Name of current member (e.g., "node1") |
| `nixcluster.clusterName` | Cluster name |

### 3. Discovering Other Members

```nix
# In NixOS module:
let
  cluster = nixcluster.cluster;

  # Find all servers
  servers = lib.filterAttrs
    (n: m: m.k3s.role or null == "server")
    cluster.members;

  # Get first server IP
  serverNames = lib.attrNames servers;
  firstServer = lib.head (lib.sort (a: b: a < b) serverNames);
  firstServerIp = cluster.members.${firstServer}.install.ip;
in
...
```

### 4. Composing with Other Modules

Modules can read options from other modules:

```nix
# cozystack module reading k3s member roles:
cozystackNixosModule = { config, lib, nixcluster, ... }:
  let
    member = nixcluster.member;
    role = member.k3s.role or null;  # Read k3s role
    isServer = role == "server";
  in
  lib.mkIf (isServer) {
    # Add cozystack-specific flags to k3s
    k3s.extraServerFlags = [ "--disable=traefik" ];
  };
```

### 5. Priority and Merging

Use standard NixOS priority functions:

```nix
# Default value (can be overridden)
services.k3s.extraFlags = lib.mkDefault "...";

# Force value (overrides others)
services.k3s.extraFlags = lib.mkForce "...";

# Append to existing value
k3s.extraServerFlags = lib.mkAfter [ "--my-flag" ];
```

## Example: Complete k3s Module

```nix
# cluster-modules/k3s.nix
{ lib, config, ... }:

let
  cfg = config.k3s;
  k3sNixosModule = ../modules/nixos/nixcluster-k3s.nix;

  # Discover members with k3s.role set
  k3sMembers = lib.filterAttrs
    (name: member: member.k3s.role or null != null)
    config.members;

  servers = lib.attrNames (lib.filterAttrs (n: m: m.k3s.role == "server") k3sMembers);

in
{
  options.k3s.enable = lib.mkEnableOption "k3s cluster";

  config = lib.mkIf cfg.enable {
    # Add k3s NixOS module to all members
    _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
      [ k3sNixosModule ]
    );

    # CLI commands
    commands = lib.mkIf (servers != []) [{
      bootstrap = {
        description = "Bootstrap k3s cluster";
        builder = { pkgs, ... }: pkgs.writeShellApplication {
          name = "nixclusterctl-${config.name}-bootstrap";
          text = ''echo "Servers: ${toString servers}"'';
        };
      };
    }];
  };
}
```

```nix
# modules/nixos/nixcluster-k3s.nix
{ config, lib, nixcluster, ... }:

let
  cluster = nixcluster.cluster;
  member = nixcluster.member;
  memberName = nixcluster.memberName;

  role = config.k3s.role;
  memberIp = member.install.ip or "127.0.0.1";

  # Find first server for cluster-init
  servers = lib.filterAttrs (n: m: m.k3s.role or null == "server") cluster.members;
  firstServer = lib.head (lib.sort (a: b: a < b) (lib.attrNames servers));
  isFirst = memberName == firstServer;

in
{
  options.k3s = {
    role = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "server" "agent" ]);
      default = null;
    };
    extraServerFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };
  };

  config = lib.mkIf (role != null) {
    services.k3s = {
      enable = true;
      inherit role;
      extraFlags = lib.concatStringsSep " " (
        [ "--node-ip=${memberIp}" ]
        ++ lib.optionals (isFirst && role == "server") [ "--cluster-init" ]
        ++ config.k3s.extraServerFlags
      );
    };
  };
}
```

## Usage in Cluster Config

```nix
clusterConfigurations.prod = mkCluster {
  imports = [
    clusterModules.k3s
    clusterModules.cozystack
  ];

  name = "prod";

  # Cluster-level options
  k3s.enable = true;
  cozystack.enable = true;

  # Member configs with NixOS patches
  members.node1 = {
    nixosConfiguration = base;
    install.ip = "10.0.0.1";
    k3s.role = "server";      # NixOS option
  };

  members.node2 = {
    nixosConfiguration = base;
    install.ip = "10.0.0.2";
    k3s.role = "agent";
  };
};
```
