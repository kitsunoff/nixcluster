# teardown-roundtrip.jq — "teardown is converge in reverse", as a checkable
# property. Shared by scripts/check-templates.sh (every template) and
# scripts/check-teardown.sh (a cluster loading every module).
#
# Input:  { converge: { order: [step], deps: { step: [dep] } },
#           teardown: { order: [step], deps: { step: [dep] } } }
# Output: an array of problems, one string each; [] means the property holds.
#
# Step naming contract (see lib/teardown.nix):
#   member-<m>            converge: install/switch m; teardown: switch m to its base
#   <module>.leave-<m>    m leaves that module's cluster
#   <module>.cleanup-<m>  that module's state is removed from m
#   anything else         a cluster-wide step ("workloads off" in teardown)

def members_of($order): $order | map(select(startswith("member-")) | ltrimstr("member-"));
def kind($step):
  if ($step | startswith("member-")) then "member"
  elif ($step | test("\\.leave-")) then "leave"
  elif ($step | test("\\.cleanup-")) then "cleanup"
  else "workloads" end;
def rank: {workloads: 0, leave: 1, cleanup: 2, member: 3}[.];

. as $plan
| members_of($plan.converge.order) as $convergeMembers
| ($plan.teardown.order) as $t

# 1. members are switched back in the reverse of the order they converged in.
| (if members_of($t) == ($convergeMembers | reverse) then []
   else ["members switch back in order \(members_of($t)), want \($convergeMembers | reverse)"] end)

# 2. phases never interleave: workloads off, then leaves, then cleanup, then switch.
+ ([range(1; $t | length)]
   | map(select((kind($t[. - 1]) | rank) > (kind($t[.]) | rank)))
   | map("\($t[.]) (\(kind($t[.]))) runs after \($t[. - 1]) (\(kind($t[. - 1])))"))

# 3. per module, members leave in the reverse of the converge order...
+ ([$t[] | select(test("\\.leave-")) | split(".leave-")[0]] | unique
   | map(. as $module
       | [$t[] | select(startswith($module + ".leave-")) | ltrimstr($module + ".leave-")] as $leaving
       | ($convergeMembers | reverse | map(select(. as $m | $leaving | index($m)))) as $want
       | if $leaving == $want then empty
         else "\($module): members leave in order \($leaving), want \($want)" end))

# 4. ...and every converge edge between two of its members is reversed: if X
#    waited for Y to converge, Y waits for X to leave.
+ ([$plan.converge.deps | to_entries[]
    | select(.key | startswith("member-"))
    | .key as $x | .value[] | select(startswith("member-"))
    | {x: ($x | ltrimstr("member-")), y: ltrimstr("member-")}]
   as $edges
   | [$t[] | select(test("\\.leave-")) | split(".leave-")[0]] | unique
   | map(. as $module
       | $edges[] as $e
       | ($plan.teardown.deps["\($module).leave-\($e.x)"]) as $xDeps
       | ($plan.teardown.deps["\($module).leave-\($e.y)"]) as $yDeps
       | select($xDeps != null and $yDeps != null)
       | select($yDeps | index("\($module).leave-\($e.x)") | not)
       | "\($module).leave-\($e.y) does not wait for \($module).leave-\($e.x) (member-\($e.x) waited for member-\($e.y) in converge)"))
