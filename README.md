# nixcluster

Declarative NixOS-based Kubernetes cluster management with module system.

## Features

- **Cluster Modules** — extensible architecture for k3s, sops, cozystack
- **NixOS Integration** — cluster config generates NixOS configurations
- **CLI Tool** — `nixclusterctl` for managing clusters
- **Secrets Management** — sops-based encrypted secrets with age

## Quick Start

```bash
# Clone and enter
git clone https://github.com/kitsunoff/nixcluster
cd nixcluster

# Generate cluster secrets
nix run .#nixclusterctl -- dev gen-secrets

# Show cluster info
nix run .#nixclusterctl -- dev

# Bootstrap cluster (shows deploy order)
nix run .#nixclusterctl -- dev bootstrap
```

## Cluster Configuration

```nix
clusterConfigurations.prod = mkCluster {
  imports = [
    clusterModules.k3s
    clusterModules.sops
    clusterModules.cozystack
  ];

  name = "prod";

  # Enable modules
  k3s.enable = true;
  sops.enable = true;
  cozystack = {
    enable = true;
    publishing.host = "cozy.example.com";
  };

  # Define members
  members.node1 = {
    nixosConfiguration = self.nixosConfigurations.base;
    install.ip = "192.168.1.10";
    k3s.role = "server";
  };

  members.node2 = {
    nixosConfiguration = self.nixosConfigurations.base;
    install.ip = "192.168.1.11";
    k3s.role = "server";
  };

  members.worker1 = {
    nixosConfiguration = self.nixosConfigurations.base;
    install.ip = "192.168.1.20";
    k3s.role = "agent";
  };
};
```

## CLI Commands

```bash
nix run .#nixclusterctl -- <cluster> <command> [args]

# Available commands:
#   apply              - Apply config to member
#   bootstrap          - Bootstrap k3s cluster
#   gen-secrets        - Generate cluster secrets
#   edit-secrets       - Edit cluster secrets
#   show-secrets       - Show decrypted secrets
#   kubeconfig         - Fetch kubeconfig
#   cozystack-bootstrap - Bootstrap cozystack
#   cozystack-status   - Show cozystack status
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Cluster Configuration                     │
│                                                              │
│  k3s.enable = true;                                         │
│  cozystack.enable = true;                                   │
│                                                              │
│  members.node1 = {                                          │
│    nixosConfiguration = base;                               │
│    install.ip = "192.168.1.10";                            │
│    k3s.role = "server";         ← NixOS option             │
│  };                                                          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     Cluster Modules                          │
│                                                              │
│  cluster-modules/k3s.nix      → modules/nixos/nixcluster-k3s.nix │
│  cluster-modules/sops.nix                                    │
│  cluster-modules/cozystack.nix                               │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   NixOS Configurations                       │
│                                                              │
│  nixosConfigurations.node1    (server, --cluster-init)      │
│  nixosConfigurations.node2    (server)                       │
│  nixosConfigurations.worker1  (agent)                        │
└─────────────────────────────────────────────────────────────┘
```

## Cluster Modules

### k3s

Configures k3s server/agent based on `k3s.role`:

```nix
k3s.enable = true;

members.node1.k3s.role = "server";  # First server gets --cluster-init
members.node2.k3s.role = "server";
members.worker1.k3s.role = "agent";
```

### sops

Manages encrypted secrets with age:

```nix
sops.enable = true;
sops.secretsDir = "secrets";  # default

# Generated files:
# secrets/<cluster>.yaml      - encrypted secrets
# secrets/<cluster>.age.key   - age private key (gitignored)
# secrets/<cluster>.age.pub   - age public key
# secrets/<cluster>_ssh       - SSH private key (gitignored)
# secrets/<cluster>_ssh.pub   - SSH public key
```

### cozystack

Deploys [Cozystack](https://cozystack.io) platform:

```nix
cozystack = {
  enable = true;
  publishing.host = "cozy.example.com";
  variant = "isp-full-generic";  # default
  networking = {
    podCIDR = "10.42.0.0/16";
    serviceCIDR = "10.43.0.0/16";
  };
};
```

Automatically adds required k3s flags, sysctl settings, packages.

## Writing Cluster Modules

See [docs/cluster-modules.md](docs/cluster-modules.md) for guidelines.

Key concepts:

1. **Cluster module** defines cluster-level options and adds NixOS modules
2. **NixOS module** receives `nixcluster` context with cluster/member info
3. **Member options** are NixOS options set as patches in cluster config

```nix
# cluster-modules/mymodule.nix
{ lib, config, ... }:
{
  options.mymodule.enable = lib.mkEnableOption "My module";

  config = lib.mkIf config.mymodule.enable {
    _generatedNixosModules = lib.genAttrs (lib.attrNames config.members) (_:
      [ ../modules/nixos/mymodule.nix ]
    );
  };
}
```

```nix
# modules/nixos/mymodule.nix
{ config, lib, nixcluster, ... }:
let
  cluster = nixcluster.cluster;
  member = nixcluster.member;
  memberName = nixcluster.memberName;
in
{
  # NixOS configuration based on cluster context
}
```

## Secrets Workflow

```bash
# Generate secrets (age keypair, SSH keypair, k3s tokens)
nix run .#nixclusterctl -- prod gen-secrets

# Edit encrypted secrets
nix run .#nixclusterctl -- prod edit-secrets

# Show decrypted secrets
nix run .#nixclusterctl -- prod show-secrets
```

## Deployment Workflow

```bash
# 1. Generate secrets
nix run .#nixclusterctl -- prod gen-secrets

# 2. Deploy nodes (first server first)
nix run .#nixclusterctl -- prod apply node1
nix run .#nixclusterctl -- prod apply node2
nix run .#nixclusterctl -- prod apply worker1

# 3. Fetch kubeconfig
nix run .#nixclusterctl -- prod kubeconfig fetch
export KUBECONFIG=kubeconfig/prod.yaml

# 4. Bootstrap cozystack (if enabled)
nix run .#nixclusterctl -- prod cozystack-bootstrap

# 5. Check status
kubectl get nodes
nix run .#nixclusterctl -- prod cozystack-status
```

## License

MIT
