# convergePlan - resolve `cluster.converge.steps` into a deterministic execution
# order, or fail evaluation with a precise message.
#
# The converge DAG is declared by core (one `member-<name>` step per member, plus
# the desugared `preSteps`/`postSteps`) and refined by cluster modules, which set
# `deps` to express real ordering contracts (k3s agents wait for every server,
# a prune step waits for every member, ...).
#
# Ordering is a topological sort: repeatedly take the ready step (all deps
# already emitted) with the lowest `priority`, ties broken by name. That keeps
# the order stable and, for a dependency-free set of phase steps, identical to
# the priority ordering the pre-DAG converge used.
{ lib }:

cluster:

let
  steps = cluster.converge.steps or {};
  names = lib.attrNames steps;
  isKnown = name: steps ? ${name};

  # Every way a declared DAG can be wrong, collected so one evaluation reports
  # all of them instead of failing on the first.
  problems = lib.concatMap
    (name:
      let
        step = steps.${name};
        bothSet = step.member != null && step.run != null;
        neitherSet = step.member == null && step.run == null;
        unknownMember = step.member != null && !(cluster.members ? ${step.member});
        unknownDeps = lib.filter (dep: !isKnown dep) step.deps;
        selfDep = lib.elem name step.deps;
      in
      lib.optional neitherSet
        "step '${name}' sets neither `run` nor `member`"
      ++ lib.optional bothSet
        "step '${name}' sets both `run` and `member` (they are mutually exclusive)"
      ++ lib.optional unknownMember
        "step '${name}' references unknown member '${step.member}'"
      ++ lib.optional selfDep
        "step '${name}' depends on itself"
      ++ map (dep: "step '${name}' depends on unknown step '${dep}'") unknownDeps
    )
    names;

  # Lowest priority first, then name — a total order, so the plan is reproducible.
  before = a: b:
    if steps.${a}.priority != steps.${b}.priority
    then steps.${a}.priority < steps.${b}.priority
    else a < b;

  topoSort = done: remaining:
    if remaining == [] then done
    else
      let
        ready = lib.filter
          (name: lib.all (dep: lib.elem dep done) steps.${name}.deps)
          remaining;
      in
      if ready == []
      then throw ''
        nixcluster: cycle in converge step dependencies for cluster '${cluster.name}'.
        Steps that can never become ready: ${lib.concatStringsSep ", " remaining}
      ''
      else
        let next = lib.head (lib.sort before ready);
        in topoSort (done ++ [ next ]) (lib.filter (name: name != next) remaining);
in

if problems != []
then throw ''
  nixcluster: invalid converge plan for cluster '${cluster.name}':
    - ${lib.concatStringsSep "\n    - " problems}
''
else topoSort [] (lib.sort before names)
