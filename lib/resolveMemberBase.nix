# resolveMemberBase - resolve a member's effective base NixOS configuration.
#
# A member may carry its own `nixosConfiguration` (a Nix value/function that
# cannot be expressed as pure JSON). When a member is injected as pure data
# (e.g. via builtins.fromJSON, as NIO does) it omits `nixosConfiguration`, and
# the cluster-level `defaultNixosConfiguration` is used instead. If neither is
# set, evaluation fails with a clear, member-named error.
#
# Usage: resolveMemberBase cluster memberName member -> base nixosConfiguration
{ lib }:

cluster: memberName: member:

let
  memberBase = member.nixosConfiguration or null;
  clusterDefault = cluster.defaultNixosConfiguration or null;
  base = if memberBase != null then memberBase else clusterDefault;
in
if base == null then
  throw "nixcluster: member '${memberName}' has no nixosConfiguration and cluster '${cluster.name}' has no defaultNixosConfiguration"
else
  base
