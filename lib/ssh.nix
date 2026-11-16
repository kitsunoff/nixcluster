# ssh - the ssh client options every nixcluster command uses to reach a member.
#
# One set, so no step behaves differently from the next:
#
#   -F <config>                  a config that includes only the user's own
#                                ~/.ssh/config. The system-wide ssh_config is
#                                written for the host's ssh, not for the one in
#                                the Nix store: an option it does not support
#                                (GSSAPIAuthentication on most distributions)
#                                prints an error on every single connection.
#   StrictHostKeyChecking=no     converge reinstalls members, which changes their
#   UserKnownHostsFile=/dev/null host key mid-run; a pinned or accept-new key
#                                would reject the host after its install. Nothing
#                                is written to known_hosts either.
#   LogLevel=ERROR               no "Permanently added ... to the list of known
#                                hosts" banner on every call; errors still show.
#   ConnectTimeout=10            an unreachable member fails fast.
#
# Use:
#   SSH_OPTS=(${ssh.shellArgs})            then  ssh "${SSH_OPTS[@]}" root@host
#   NIX_SSHOPTS="${ssh.nixSshOpts}"        for nix copy / nixos-rebuild
{ lib }:

rec {
  configFile = builtins.toFile "nixcluster-ssh-config" ''
    # nixcluster: the user's own ssh configuration, and not the system-wide one.
    Include ~/.ssh/config
  '';

  args = [
    "-F" "${configFile}"
    "-o" "StrictHostKeyChecking=no"
    "-o" "UserKnownHostsFile=/dev/null"
    "-o" "LogLevel=ERROR"
    "-o" "ConnectTimeout=10"
  ];

  # The arguments, quoted for a shell command line or array literal.
  shellArgs = lib.escapeShellArgs args;

  # The same, as the single string nix and nixos-rebuild split into arguments.
  nixSshOpts = lib.concatStringsSep " " args;
}
