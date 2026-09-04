# The repo's skills/ tree, republished as a Claude Code plugin, plus the hook
# payloads generated from it.
#
# Two consumers need the identical tree, which is why this is its own file
# rather than an inline runCommand in either of them: nix/home/ai/claude.nix
# registers it with the terminal CLI, and nix/packages/claude-desktop.nix hands it to
# the desktop app, which cannot see ~/.claude/skills on any of its surfaces.
#
# Why a plugin and not the bare `programs.claude-code.skills` directory it
# replaces: a bare tree can only hold SKILL.md files, whereas a plugin is the
# container that can also carry per-skill helper scripts and an .mcp.json. It
# additionally gives the skills a stable `dots-skills:` prefix, which the
# primer quotes so an agent is told the exact name the Skill tool answers to.
#
# The manifest lives at plugins/dots-skills/ and not at skills/.claude-plugin/
# because a plugin's skills must sit one level down in <root>/skills/. A
# manifest next to the skill folders would be at the wrong depth and would
# need a skills/skills/ underneath it.
{
  lib,
  runCommand,
  writers,
}:
let
  # The orchestrating session routes work to five specialized agents, so it
  # needs every writing-good body in force from its first turn rather than
  # left to a trigger line it might not match. A subagent does not: it
  # spawns with its own `skills:` frontmatter already preloading the one
  # body its task needs, so its payload stays down to dodging-cdb, the one
  # skill whose cost of firing late is a push that already happened.
  sessionInline = [
    "dodging-cdb"
    "writing-good-code"
    "writing-good-rs"
    "writing-good-cpp"
    "writing-good-web"
    "writing-good-installer"
  ];
  subagentInline = [ "dodging-cdb" ];

  # The five specialized agents this plugin ships. Named here rather than
  # discovered by globbing, so a typo in an agent's frontmatter name still
  # fails a `test -e` instead of quietly not being checked at all.
  agentNames = [
    "rust-dev"
    "cpp-dev"
    "web-dev"
    "installer-dev"
    "systems-dev"
  ];

  # flake8 gates this the same way it gates searxng-mcp in nix/home/ai/claude.nix.
  # A skill whose frontmatter is missing, unclosed, or disagrees with its own
  # directory name fails the build loudly instead of dropping silently out of
  # the index.
  primerGen = writers.writePython3 "dots-skills-primer" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./dots-skills-primer.py);

  plugin = runCommand "dots-skills-plugin" { } ''
    mkdir -p $out/skills
    cp -r ${../../plugins/dots-skills}/. $out/
    cp -r ${../../skills}/. $out/skills/
    chmod -R u+w $out
    test -e $out/.claude-plugin/plugin.json
    for name in ${lib.concatStringsSep " " (lib.unique (sessionInline ++ subagentInline))}; do
      test -e $out/skills/$name/SKILL.md
    done
    for name in ${lib.concatStringsSep " " agentNames}; do
      test -e $out/agents/$name.md
    done
  '';
in
{
  inherit plugin;

  # The rendered hook payloads, built once here rather than escaped in shell
  # at hook time. Escaping a 7 KB markdown blob into a JSON string literal in
  # bash is the failure mode this avoids: the hook degenerates to a `cat` of a
  # store path that cannot dangle when the checkout moves.
  #
  # Built beside the plugin rather than inside it so what Claude Code scans is
  # exactly a plugin and nothing else.
  primer = runCommand "dots-skills-primer-payloads" { } ''
    ${primerGen} ${plugin} $out ${lib.concatStringsSep "," sessionInline} ${lib.concatStringsSep "," subagentInline}
  '';
}
