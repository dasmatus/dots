"""Render the skill primers that SessionStart and SubagentStart hooks emit.

Reads a built dots-skills plugin tree and writes three files: primer.md,
which holds the session-level primer text, plus one JSON hook payload per
event. A subagent is constructed with a fresh message array rather than a
copy of its parent's transcript, so it never sees SessionStart output and
fires SubagentStart instead, and the two events no longer share one body of
text: the top-level session inlines every writing-good skill so it can route
work to the right specialized agent, while a subagent inlines only
dodging-cdb, because a specialized agent now preloads the rest of what it
needs through its own `skills:` frontmatter. Both payloads still carry the
same skills index and a "Delegate to" table naming the agents an
orchestrating session can hand work to.

Argv: <plugin root> <output dir> <session inline csv> <subagent inline csv>
"""

import json
import pathlib
import sys

# Only the escaping matters enough to justify a program over a sed line: a
# description is free prose carrying colons, commas and apostrophes, and it
# has to survive being pasted into a JSON string literal.
EVENTS = {"SessionStart": "session-start.json", "SubagentStart": "subagent-start.json"}


def split(path, expected_name):
    """Return (frontmatter fields, body) for one SKILL.md or agent file, or die loudly."""
    text = path.read_text()
    if not text.startswith("---\n"):
        raise SystemExit(f"{path}: no frontmatter block")
    head, sep, body = text[4:].partition("\n---\n")
    if not sep:
        raise SystemExit(f"{path}: frontmatter block is never closed")
    fields = {}
    for line in head.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, sep, value = line.partition(":")
        if not sep:
            raise SystemExit(f"{path}: unparsable frontmatter line {line!r}")
        value = value.strip()
        if len(value) > 1 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        fields[key.strip()] = value
    for key in ("name", "description"):
        if key not in fields:
            raise SystemExit(f"{path}: frontmatter has no {key}")
    if fields["name"] != expected_name:
        raise SystemExit(
            f"{path}: frontmatter name {fields['name']!r} does not match {expected_name!r}"
        )
    return fields, body.strip()


def parse_agents(root, prefix, bodies):
    """Return one frontmatter-fields dict per agents/*.md, after validating its `skills` entry.

    An agent's whole reason to exist is the skill(s) it preloads, so a
    missing `skills` key or an entry that resolves to no known skill fails
    the build instead of shipping an agent that silently forgot its rules.
    The body half of split()'s return is discarded; render() never quotes an
    agent's body, only its name and description.

    Claude Code resolves a `skills:` entry by trying it as written, then by
    joining the spawning agent's own plugin prefix to it. Our agents all
    live in this plugin, so only the bare skill name or `<prefix>:<name>`
    can ever resolve to one of our skills; any other prefix looks valid
    here and silently resolves to nothing at runtime.
    """
    paths = sorted((root / "agents").glob("*.md"))
    if not paths:
        raise SystemExit(f"{root}/agents: no agent files found")
    allowed = set(bodies) | {f"{prefix}:{name}" for name in bodies}
    agents = []
    for path in paths:
        fields, _ = split(path, path.stem)
        raw = fields.get("skills")
        if raw is None:
            raise SystemExit(f"{path}: agent frontmatter has no skills entry")
        raw = raw.strip()
        if not (raw.startswith("[") and raw.endswith("]")):
            raise SystemExit(f"{path}: skills value {raw!r} is not a flow sequence")
        inner = raw[1:-1].strip()
        if not inner:
            raise SystemExit(f"{path}: skills value has no entries")
        entries = []
        for piece in inner.split(","):
            entry = piece.strip()
            if len(entry) > 1 and entry[0] == entry[-1] and entry[0] in "\"'":
                entry = entry[1:-1]
            if not entry:
                raise SystemExit(f"{path}: skills value has an empty entry")
            if '"' in entry or "'" in entry:
                raise SystemExit(f"{path}: skills entry {entry!r} still carries a quote")
            entries.append(entry)
        for entry in entries:
            if entry not in allowed:
                raise SystemExit(
                    f"{path}: skills entry {entry!r} does not resolve to a known skill"
                )
        agents.append(fields)
    return agents


def render(prefix, parsed, names, bodies, agents):
    """Return primer markdown: the skills index, one inlined body per name, then the delegate table."""
    index = "\n".join(
        f"- `{prefix}:{f['name']}`: {f['description']}" for f, _ in parsed
    )
    sections = "\n\n".join(
        f"# {name}, in force for the whole session\n\n{bodies[name]}" for name in names
    )

    def escape_row(text):
        return text.replace("|", "\\|")

    delegate = "\n".join(
        f"| `{prefix}:{f['name']}` | {escape_row(f['description'])} |" for f in agents
    )
    return f"""# Personal skills ({prefix})

Each line below is a trigger, not a topic. When the work in front of you
matches one, call the Skill tool with that exact name before starting the
work, then say which one you used. This binds a subagent exactly as it binds
a top-level session: a subagent starts with no memory of the session that
spawned it, so nothing else will remind it, and no other instruction excuses
skipping a match.

{index}

{sections}

# Delegate to

These agents spawn with their matching skill already loaded through their own `skills:` frontmatter.

| Agent | Description |
| --- | --- |
{delegate}
"""


def main():
    root = pathlib.Path(sys.argv[1])
    out = pathlib.Path(sys.argv[2])
    session_names = sys.argv[3].split(",")
    subagent_names = sys.argv[4].split(",")

    # The prefix is read back out of the shipped manifest rather than spelled
    # here, so the names the index advertises cannot drift from the names the
    # Skill tool actually answers to.
    manifest = json.loads((root / ".claude-plugin" / "plugin.json").read_text())
    prefix = manifest["name"]

    paths = sorted((root / "skills").glob("*/SKILL.md"))
    if not paths:
        raise SystemExit(f"{root}/skills: no SKILL.md found")
    parsed = [split(p, p.parent.name) for p in paths]
    bodies = {f["name"]: b for f, b in parsed}

    for name in session_names + subagent_names:
        if name not in bodies:
            raise SystemExit(f"{root}/skills: no skill named {name!r} to inline")

    agents = parse_agents(root, prefix, bodies)

    session_primer = render(prefix, parsed, session_names, bodies, agents)
    subagent_primer = render(prefix, parsed, subagent_names, bodies, agents)
    texts = {"SessionStart": session_primer, "SubagentStart": subagent_primer}

    out.mkdir(parents=True, exist_ok=True)
    # primer.md is the session text; the leaner subagent text only ever
    # reaches a subagent through subagent-start.json below.
    (out / "primer.md").write_text(session_primer)
    for event, name in EVENTS.items():
        payload = {
            "hookSpecificOutput": {
                "hookEventName": event,
                "additionalContext": texts[event],
            }
        }
        (out / name).write_text(json.dumps(payload) + "\n")


main()
