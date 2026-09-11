# ~/Dokumente skeleton: the directory tree under ./dokumente IS the data.
# haumea loads it into a nested attrset (keep.nix markers = git-trackable
# leaves). Materialized with mkdir -p: idempotent, never clobbers content.
{
  config,
  lib,
  inputs,
  ...
}:
let
  tree = inputs.haumea.lib.load {
    src = ./dokumente;
    loader = inputs.haumea.lib.loaders.verbatim;
  };
  walk =
    prefix: t:
    lib.concatLists (
      lib.mapAttrsToList (
        name: value:
        if lib.isAttrs value then [ "${prefix}${name}" ] ++ walk "${prefix}${name}/" value else [ ]
      ) t
    );
in
{
  home.activation.dokumenteSkeleton = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    lib.concatMapStringsSep "\n" (
      d: "run mkdir -p ${lib.escapeShellArg "${config.home.homeDirectory}/Dokumente/${d}"}"
    ) (walk "" tree)
  );
}
