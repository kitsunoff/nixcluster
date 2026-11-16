# convergePlan - resolve `cluster.converge.steps` into a deterministic execution
# order, or fail evaluation with a precise message. See lib/stepPlan.nix, which
# resolves the converge and the teardown DAG alike.
{ lib }:

import ./stepPlan.nix { inherit lib; } "converge"
