# optionsOnly - a NixOS module reduced to the options it declares.
#
# Teardown switches a member back to a configuration without the cluster, but
# the member's own patches may still set options that a cluster module declares
# (`k3s.role = "server"`). Loading the module options-only keeps those
# definitions valid while none of the module's config takes effect.
#
# Accepts every module form the module system accepts: a path, a function
# (its argument names are kept, so it still receives `nixcluster` etc.) or an
# attribute set. Imports are reduced the same way. A module without an
# `options` attribute is all config, so nothing of it remains.
{ lib }:

let
  strip = result:
    if result ? _type then { } # mkIf / mkMerge / ...: config only
    else {
      options = result.options or { };
      imports = map optionsOnly (result.imports or [ ]);
    };

  optionsOnly = module:
    if builtins.isPath module || builtins.isString module then
      { _file = toString module; imports = [ (optionsOnly (import module)) ]; }
    else if lib.isFunction module then
      lib.setFunctionArgs (args: strip (module args)) (lib.functionArgs module)
    else
      strip module;
in
optionsOnly
