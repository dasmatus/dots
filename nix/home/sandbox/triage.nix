# Nix-side wiring for `dots-sandbox triage`'s optional assist layer — see
# .superpowers/sdd/structured-fluttering-chipmunk/triage-contract.md. This
# file is the ONLY place `settings.triageAssist*` (nix/system/defaults.nix) is
# read; it exports them as DOTS_TRIAGE_ASSIST_* environment variables for the
# `triage` subcommand to pick up with the same hand-rolled `env::var` style
# `rust/dots-sandbox/src/{main,launch}.rs` already use for DOTS_SANDBOX_*.
#
# ---------------------------------------------------------------------------
# Why this buys the "ollama is a triage-only dependency" separation
# structurally, not just by convention
# ---------------------------------------------------------------------------
# `dots-sandbox run` — the launcher `nix/home/sandbox/wrap.nix`'s shim and
# every flake app invoke on every single app start — is wired in
# nix/home/sandbox/machined.nix and wrap.nix, neither of which this file
# touches, imports, or is imported by. Those two files declare no
# DOTS_TRIAGE_* variable and reference no ollama unit; this file declares no
# DOTS_SANDBOX_* variable and starts nothing. The two are separate
# home-manager modules with disjoint env-var namespaces and no shared
# activation script, so there is no code path by which enabling this module
# makes the launcher touch, link to, or block on ollama — the only way that
# coupling could reappear is a future edit physically adding a DOTS_TRIAGE_*
# read (or an ollama wait) inside launch.rs/main.rs's `run` handling itself,
# which is exactly what grepping those two files for "ollama"/"DOTS_TRIAGE"
# is meant to catch in review.
#
# The variables are exported unconditionally (not only when
# triageAssistEnable is true): `dots-sandbox triage` itself is the thing
# that must decide, at call time, whether to use them — per the contract,
# it must degrade to heuristics-only, without hanging, when the service
# turns out to be unreachable regardless of what static config says. Baking
# an on/off branch into whether the variable even exists here would just
# move that runtime liveness check into eval time, where it cannot actually
# observe whether ollama answers.
{ settings, ... }:
{
  home.sessionVariables = {
    DOTS_TRIAGE_ASSIST_ENABLE = if settings.triageAssistEnable then "1" else "0";
    DOTS_TRIAGE_ASSIST_MODEL = settings.triageAssistModel;
    # Reuses the existing aiOllamaEndpoint default (nix/system/defaults.nix) —
    # the same endpoint nix/system/hosts.nix's services.ollama binds to —
    # rather than declaring a second, independent ollama address that could
    # silently drift from it.
    DOTS_TRIAGE_OLLAMA_ENDPOINT = settings.aiOllamaEndpoint;
    DOTS_TRIAGE_SEARXNG_ENDPOINT = settings.triageAssistSearxngEndpoint;
  };
}
