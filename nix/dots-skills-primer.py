"""Render the skill primer that SessionStart and SubagentStart hooks emit.

Reads a built dots-skills plugin tree and writes three files: the primer as
markdown, and one JSON hook payload per event. A subagent is constructed with
a fresh message array rather than a copy of its parent's transcript, so it
never sees SessionStart output and fires SubagentStart instead; both events
therefore need the same text, and only the JSON form reaches a subagent's
model input at all.

Argv: <plugin root> <output dir> <name of the skill to inline whole>
"""

import json
import pathlib
import sys

# Only the escaping matters enough to justify a program over a sed line: a
# description is free prose carrying colons, commas and apostrophes, and it
# has to survive being pasted into a JSON string literal.
EVENTS = {"SessionStart": "session-start.json", "SubagentStart": "subagent-start.json"}


def split(path):
    """Return (frontmatter fields, body) for one SKILL.md, or die loudly."""
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
    if fields["name"] != path.parent.name:
        raise SystemExit(
            f"{path}: frontmatter name {fields['name']!r} does not match its directory"
        )
    return fields, body.strip()


def render(prefix, parsed, always, bodies):
    """Return the primer markdown: one trigger line per skill, then one body."""
    index = "\n".join(
        f"- `{prefix}:{f['name']}`: {f['description']}" for f, _ in parsed
    )
    return f"""# Personal skills ({prefix})

Each line below is a trigger, not a topic. When the work in front of you
matches one, call the Skill tool with that exact name before starting the
work, then say which one you used. This binds a subagent exactly as it binds
a top-level session: a subagent starts with no memory of the session that
spawned it, so nothing else will remind it, and no other instruction excuses
skipping a match.

{index}

# {always}, in force for the whole session

{bodies[always]}
"""


def main():
    root = pathlib.Path(sys.argv[1])
    out = pathlib.Path(sys.argv[2])
    always = sys.argv[3]

    # The prefix is read back out of the shipped manifest rather than spelled
    # here, so the names the index advertises cannot drift from the names the
    # Skill tool actually answers to.
    manifest = json.loads((root / ".claude-plugin" / "plugin.json").read_text())
    prefix = manifest["name"]

    paths = sorted((root / "skills").glob("*/SKILL.md"))
    if not paths:
        raise SystemExit(f"{root}/skills: no SKILL.md found")
    parsed = [split(p) for p in paths]

    bodies = {f["name"]: b for f, b in parsed}
    if always not in bodies:
        raise SystemExit(f"{root}/skills: no skill named {always!r} to inline")

    primer = render(prefix, parsed, always, bodies)

    out.mkdir(parents=True, exist_ok=True)
    (out / "primer.md").write_text(primer)
    for event, name in EVENTS.items():
        payload = {
            "hookSpecificOutput": {
                "hookEventName": event,
                "additionalContext": primer,
            }
        }
        (out / name).write_text(json.dumps(payload) + "\n")


main()
