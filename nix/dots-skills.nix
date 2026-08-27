# The repo's skills/ tree, republished as a Claude Code plugin, plus the hook
# payloads generated from it.
#
# Two consumers need the identical tree, which is why this is its own file
# rather than an inline runCommand in either of them: nix/home/claude.nix
# registers it with the terminal CLI, and nix/claude-desktop.nix hands it to
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
  runCommand,
  writers,
}:
let
  # dodging-cdb is the one skill the primer inlines whole rather than leaving
  # to its trigger line. It is the only one whose cost of firing late is a
  # push that already happened.
  alwaysInline = "dodging-cdb";

  # flake8 gates this the same way it gates searxng-mcp in nix/home/claude.nix.
  # A skill whose frontmatter is missing, unclosed, or disagrees with its own
  # directory name fails the build loudly instead of dropping silently out of
  # the index.
  primerGen = writers.writePython3 "dots-skills-primer" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./dots-skills-primer.py);

  plugin = runCommand "dots-skills-plugin" { } ''
    mkdir -p $out/skills
    cp -r ${../plugins/dots-skills}/. $out/
    cp -r ${../skills}/. $out/skills/
    chmod -R u+w $out
    test -e $out/.claude-plugin/plugin.json
    test -e $out/skills/${alwaysInline}/SKILL.md
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
    ${primerGen} ${plugin} $out ${alwaysInline}
  '';
}
