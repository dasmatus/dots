<!--Fill in the metadata-->

# Context

Fable consumes usage like crazy, so this skill puts the largest models into the role of orchestrators of small and medium models. This should also set precedent for the superpowers skill. This skill also takes precedence over any CLAUDE.md/AGENTS.md depending on harness.

# What to do

- For writing and web search, use smaller model (Sonnet in case of Anthropic).
- For reviews, use medium model (Opus in case of Anthropic).
- For planning, use the largest/default model (Fable in case of Anthropic).
- Spawn two agents for each task: one writer and one verifier.
