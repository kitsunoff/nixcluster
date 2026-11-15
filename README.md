<div align="center">

# nixcluster

**Declarative NixOS clusters, converged by one idempotent command**

Describe a cluster once — members, roles, modules — and `converge` installs what is missing, switches what has drifted, joins what has not joined, and removes what has left.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](LICENSE)
[![Nix flake](https://img.shields.io/badge/Nix-flake%20%2B%20flake--parts-5277C3?style=flat-square&logo=nixos&logoColor=white)](https://nixos.wiki/wiki/Flakes)
[![Checks](https://img.shields.io/github/actions/workflow/status/kitsunoff/nixcluster/checks.yml?branch=master&label=checks&style=flat-square)](../../actions/workflows/checks.yml)
[![Security](https://img.shields.io/github/actions/workflow/status/kitsunoff/nixcluster/security.yml?branch=master&label=security&style=flat-square)](../../actions/workflows/security.yml)
[![Modules](https://img.shields.io/badge/cluster%20modules-k3s%20%C2%B7%20incus%20%C2%B7%20sops%20%C2%B7%20nebula-009688?style=flat-square)](#cluster-modules)

</div>

---

> [!WARNING]
> First-time provisioning runs `nixos-anywhere`, which **wipes the target disk**.
> `converge` decides install-vs-switch by probing `/run/current-system` over SSH, so
> a host you did not mean to include is a host you may destroy. Check every
> `install.ip` and `install.disk` before the first run.

> [!IMPORTANT]
> Removing a member from the cluster definition now **removes it from the
> cluster** — that is the point of two-way reconciliation. The guards are real
> (an empty member set refuses to prune anything, and a removal that would break
> quorum is refused), but a deliberate deletion is carried out.
>
> `converge` never dissolves a whole cluster: emptying the definition is
> refused. Dissolving it is a separate command, [`teardown`](#teardown), which
> shows its plan and acts only on an explicit `yes`.

## Table of contents

- [What you get](#what-you-get)
- [Start from a scenario template](#start-from-a-scenario-template)
- [How converge orders itself](#how-converge-orders-itself)
- [Teardown](#teardown)
- [Cluster modules](#cluster-modules)
- [Writing a cluster by hand](#writing-a-cluster-by-hand)
- [CLI](#cli)
- [Checks](#checks)
- [Architecture](#architecture)
- [Known limitations](#known-limitations)
- [License](#license)

## What you get

| Stage | What nixcluster does |
| --- | --- |
| **Describe** | One `nixcluster.<name>` definition: members, their roles, and which cluster modules to load. Everything that is not a nixcluster key is a NixOS patch for that member. |
| **Derive** | `nixosConfigurations.<cluster>-<member>` per member and a per-cluster CLI app `cluster-<name>`, from that single definition. |
| **Install** | `nixos-anywhere` for a host with no NixOS on it yet, decided by an SSH probe — so the step as a whole is idempotent even though installing is not. |
| **Converge** | A dependency graph, not a fixed pipeline: secrets before members, non-first servers after the bootstrap, agents after **all** servers, post-ops after the members they need. |
| **Join** | Module-specific runtime work that a NixOS switch cannot do: minting Incus join tokens, fetching a kubeconfig. Idempotent — an already-joined member is skipped and says so. |
| **Prune** | Members that left the definition are drained, deregistered and removed from the cluster's own registry. Reported as `action: "removed"` in the result JSON. |
| **Teardown** | The whole cluster is dissolved, converge in reverse: workloads off, members leave, module state is removed, and every member is switched back to its base NixOS configuration. Reported as `action: "destroyed"`. |

## Start from a scenario template

Each template is a complete, evaluating cluster with a README naming exactly which
values to change.

| Template | What you get |
| --- | --- |
| `k3s-single` | one k3s server — the minimal k3s scenario |
| `k3s-ha` | three etcd servers plus two agents, the full ordering contract |
| `incus-cluster` | three Incus members, two of which carry nothing but an address |
| `default` | the bare skeleton: flake-parts + import-tree, no scenario |

```bash
mkdir my-cluster && cd my-cluster
nix flake init --template github:kitsunoff/nixcluster#k3s-ha

# Edit modules/nodes/*.nix (addresses) and modules/base.nix (disk, SSH key):
nix run .#cluster-k3s-ha -- converge --dry-run   # plan only, nothing touched
nix run .#cluster-k3s-ha -- converge
```

## How converge orders itself

Roles in the node files are the only input. Nothing in the cluster definition says
"three servers":

```text
$ nix eval .#clusterConfigurations.k3s-ha.convergeOrder
["member-server-1","member-server-2","member-server-3","k3s.bootstrap","k3s.kubeconfig","member-agent-1","member-agent-2","k3s.prune"]

$ nix eval .#clusterConfigurations.k3s-ha.config.converge.steps \
    --apply 'steps: builtins.mapAttrs (_: s: s.deps) steps'
  k3s.bootstrap          <- member-server-1, member-server-2, member-server-3
  k3s.kubeconfig         <- member-server-1, member-server-2, member-server-3
  k3s.prune              <- member-server-1, member-server-2, member-server-3, member-agent-1, member-agent-2, k3s.kubeconfig
  member-agent-1         <- member-server-1, member-server-2, member-server-3
  member-agent-2         <- member-server-1, member-server-2, member-server-3
  member-server-1        <- (nothing)
  member-server-2        <- member-server-1
  member-server-3        <- member-server-1
```

Read that as: `server-1` bootstraps etcd, so `server-2` and `server-3` wait for it
and **not** for each other; each agent waits for **all three** servers, because
there is no control plane to join until they are up; the kubeconfig needs a server
and does not care about agents; and pruning happens last, once the desired members
have converged.

A step whose dependency did not succeed is **skipped**, not run — a failed
bootstrap does not drag the agents through a pointless join attempt.

`preSteps` / `postSteps` still exist as sugar over the same attrset, carrying the
dependencies their names implied.

## Teardown

`converge` handles the members that left the definition (prune).
`teardown` removes the cluster from every member that is still in the
definition. The machines stay installed, keep their disk layout and still answer
SSH, so a later `converge` can rebuild the cluster on them.

```bash
nix run .#cluster-k3s-ha -- teardown --dry-run       # plan only, nothing touched
nix run .#cluster-k3s-ha -- teardown                 # shows the plan, asks for "yes"
nix run .#cluster-k3s-ha -- teardown --auto-approve  # no prompt (automation)
```

The plan is `converge` in reverse, built from the same dependency graph, and
`scripts/check-templates.sh` checks that property for every template:

1. **Workloads off.** Cluster-wide steps: `k3s.drain` cordons and drains every
   node, and `incus.instances-off` deletes every instance.
2. **Leave.** `<module>.leave-<member>`: each member leaves the module's cluster.
   Members leave in the reverse of the order converge brought them up in, so
   joiners leave before the bootstrap they joined.
3. **Cleanup.** `<module>.cleanup-<member>`: the module's units, data and runtime
   secrets are removed from the host. For a module with a leave phase (`k3s`,
   `incus`), cleanup starts only after every member of that module has left.
4. **Switch back.** `member-<member>`: the member is switched to its base NixOS
   configuration — its own `nixosConfiguration` or the cluster's
   `defaultNixosConfiguration` plus its member patches (host name, network),
   without what the cluster modules generate. Patches may still set
   cluster-module options such as `k3s.role`: those modules are loaded
   options-only. The disk layout from `disko` is kept, and no sops secret is
   decrypted. The base is published as
   `clusterConfigurations.<name>.teardownNixosConfigurations.<member>`.

```text
$ nix eval .#clusterConfigurations.k3s-ha.teardownOrder
["k3s.drain","k3s.leave-agent-2","k3s.leave-agent-1","k3s.leave-server-3","k3s.leave-server-2","k3s.leave-server-1","k3s.cleanup-agent-2","k3s.cleanup-agent-1","k3s.cleanup-server-3","k3s.cleanup-server-2","k3s.cleanup-server-1","member-agent-2","member-agent-1","member-server-3","member-server-2","member-server-1"]
```

What each module removes:

| Module | Leave | Cleanup |
| --- | --- | --- |
| `k3s` | a joining server gives up its etcd member; the Node is deleted; k3s stops | containers, `/etc/rancher`, `/var/lib/rancher`, kubelet and CNI state |
| `incus` | a joiner is removed through the bootstrap; Incus stops | Incus units, `incusbr*` bridges, `/var/lib/incus`, `/var/log/incus`, `/var/cache/incus` |
| `keepalived` | — | keepalived stops (its VIPs are released); `/run/keepalived` |
| `nebula` | — | `nebula@<network>.service` stops |
| `sops` | — | decrypted secrets under `/run`; the age key stays, so a later converge can decrypt again |

Every host step is safe to run again, so a teardown that stopped halfway can be
repeated. A member that does not answer SSH is reported as `Skipped` and its
state is left as it is; the result is then `partial`, not a failure.

## Cluster modules

Nothing is auto-applied: a cluster imports what it wants.

| Module | What it adds |
| --- | --- |
| `k3s` | k3s on every member, roles from `k3s.role`, the ordering contract above, kubeconfig fetch, node/manifest/helm commands, and a prune step |
| `incus` | Incus on every member; with `incus.cluster.enable`, runtime join tokens for members that never set a per-member patch, plus a prune step. `incus.virtualMachines = false` runs containers only and keeps qemu and the UEFI firmware out of the closure (for hosts without nested KVM) |
| `sops` | age-encrypted cluster secrets, generate-if-missing, delivered to hosts outside the Nix store. Members decrypt `secrets/<cluster>.yaml` from the flake (`sops.secretsFile`; commit the file so the flake contains it) |
| `nebula` | a Nebula mesh with a per-cluster CA and per-member certificates |
| `keepalived` | VRRP virtual addresses across members |
| `disko` | declarative partitioning for the install step |
| `cozystack` | Cozystack platform bootstrap on top of k3s |
| `pxe` | a PXE server for provisioning members that cannot be reached over SSH yet |

## Writing a cluster by hand

```nix
nixcluster.prod =
  { clusterModules, self, ... }:
  {
    imports = [ clusterModules.k3s clusterModules.sops ];

    k3s.enable = true;
    sops.enable = true;

    # Members with no nixosConfiguration of their own inherit this — which is what
    # lets a member be supplied as pure data (an address and nothing else).
    defaultNixosConfiguration = self.nixosConfigurations.base;

    members.node-1 = {
      install.ip = "10.0.0.11";
      install.disk = "/dev/vda";
      k3s.role = "server";
      networking.hostName = "prod-node-1";   # any NixOS option is a patch
    };
  };
```

## CLI

```bash
nix run .#cluster-prod -- --help
nix run .#cluster-prod -- converge [--dry-run] [--json] [--age-key-file path]
nix run .#cluster-prod -- teardown [--dry-run] [--json] [--auto-approve]
nix run .#cluster-prod -- apply node-1          # switch one member
nix run .#cluster-prod -- install node-1        # first-time provisioning
nix run .#cluster-prod -- gen-config 10.0.0.12  # SSH-discover a node, emit a member file
nix run .#cluster-prod -- k3s nodes             # module command groups
```

`--dry-run` walks the whole plan without touching a host: every step and member
is reported as `skipped` with the message `dry-run`, and the result is
`success`.

`converge` and `teardown` write human output to stderr and exactly one machine-readable line to
stdout, so a consumer gets a single marker to grep:

```text
::nixcluster:result:: {"cluster":"prod","result":"success","members":[
  {"name":"node-1","ip":"10.0.0.11","action":"switch","status":"Applied","durationSeconds":47},
  {"name":"old-node","ip":"","action":"removed","status":"Applied","message":"removed from the k3s registry (unreachable)"}],
  "steps":[{"name":"sops.gen","phase":"pre","status":"ok"},{"name":"member-node-1","phase":"member","status":"ok"},
  {"name":"k3s.prune","phase":"post","status":"ok"}]}
```

`steps` lists every step in the order it ran, the `member-<name>` steps
included; `members` adds the per-member detail (action, address, duration).

## Checks

All of them run in CI on every push and pull request. None of them builds a NixOS
system or touches a host.

```text
$ scripts/check-templates.sh
32 check(s) passed, 0 failed

$ scripts/check-prune.sh
38 check(s) passed, 0 failed

$ scripts/check-teardown.sh
88 check(s) passed, 0 failed

$ scripts/check-modules.sh
2 check(s) passed, 0 failed

$ scripts/check-converge.sh
11 check(s) passed, 0 failed
```

`check-templates.sh` locks every registered template against the checkout and
asserts the expected members, a NixOS configuration per member, the per-cluster CLI
app, the resolved converge order, and the converge steps **with their
dependencies** — so a template whose plan drifts from its documented contract
fails loudly. It also evaluates every member's `system.build.toplevel`, which
catches option and type errors across the whole configuration, while building
nothing. Finally, it checks each template's teardown order and that the teardown
plan is its converge plan in reverse.

`check-prune.sh` covers the only part of converge that deletes things: the engine's
branches against an injected registry (no-op, one stale member, unreachable host →
force path, empty desired set → loud refusal with nothing removed, quorum-breaking
removal → refused) and the real k3s step against stubbed `kubectl` and `ssh`.

`check-teardown.sh` covers the command that removes a whole cluster: the exact
plan of a cluster that loads every module with teardown steps, the disk layout
surviving the switch back, and the real `teardown` command against stubbed
`ssh`, `kubectl` and `nix` — the `yes` prompt and every refusal, `--dry-run`,
`--auto-approve`, an unreachable member, a member that fails to switch, and the
result JSON.

`check-modules.sh` evaluates the NixOS side of the modules in combination: a
fixture flake (`scripts/fixtures/modules`) loads them the way a real cluster
does, and the script asserts what each member's configuration ends up with.

`check-converge.sh` runs the real `converge` command of a k3s + Incus cluster
against stubbed `ssh`, `nixos-anywhere`, `nixos-rebuild`, `nix` and `kubectl`:
each member is a directory standing in for its root file system, so the probe
converge sends decides install or switch exactly as it would on a host.

## Architecture

```text
nixcluster.<name>                     one definition (merged across ./modules by import-tree)
  │
  ├─ core.nix                         members, converge DAG, CLI plumbing
  ├─ clusterModules.*                 explicitly imported; each contributes
  │                                   NixOS modules, CLI commands, converge steps
  ▼
clusterConfigurations.<name>
  ├─ nixosConfigurations.<name>-<member>     one per member
  ├─ convergeOrder                           resolved topological plan
  ├─ teardownOrder                           the same, for `teardown`
  ├─ teardownNixosConfigurations.<member>    what teardown switches a member to
  └─ cli  →  apps.<system>.cluster-<name>    the per-cluster CLI
```

Every unit of converge work — a module step *and* each member's install-or-switch —
is a node in `converge.steps`, and every unit of teardown work is a node in
`teardown.steps`. `lib/stepPlan.nix` topologically sorts either graph and
fails evaluation on an unknown dependency, a cycle, or a step that is neither a
`run` nor a `member`. `lib/prune.nix` holds the registry-diff engine all pruning
modules share, so the dangerous logic exists exactly once. `lib/teardown.nix`
gives every module the same four teardown phases for the same reason.

## Known limitations

- **Pruning has never run against a live cluster.** The engine and the k3s step are
  covered by stubbed tests; the Incus path is verified only by evaluation.
- **`nebula` and `keepalived` do not prune.** Nebula revocation is only enforced
  through `pki.blocklist`, which is deliberately not distributed by lighthouses, so
  it needs a persisted blocklist wired through the NixOS module.
- **Per-member converge status is coarse.** The result JSON reports one action per
  member, not a step-by-step trace.
- **`converge` builds where it runs.** There is no `--build-host`, so driving it
  from a machine that cannot build the members' system needs a configured remote
  builder. The same applies to `teardown`, which builds each member's base.
- **Teardown has never run against a live cluster.** The plan and the command are
  covered by evaluation and by stubbed tests only.
- **Teardown fully resets only the default `dir` Incus storage pool.** Pools on
  zfs, lvm or btrfs with a block-device source are not wiped.
- **Teardown keeps member patches.** A patch that configures a service
  directly (for example `services.k3s.*` instead of the module's `k3s.*`
  options) stays active after teardown.

## License

MIT. See [LICENSE](LICENSE).
