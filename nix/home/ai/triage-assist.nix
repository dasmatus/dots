# Nix-side wiring for `dots-secreport triage`'s optional LLM-assist layer —
# see .superpowers/sdd/structured-fluttering-chipmunk/triage-contract.md.
# This file is the ONLY place `settings.triageAssist*`
# (nix/system/defaults.nix) is read; it exports them as DOTS_TRIAGE_ASSIST_*
# environment variables for the `triage` subcommand to pick up.
#
# Moved here from the deleted nix/home/sandbox/ (Phase E retired the bespoke
# per-app sandbox for Flatpak + AppArmor — see git history) because this
# module was never sandbox-launcher wiring: it sets environment variables and
# starts nothing, and the crate it feeds, `dots-secreport`, is the salvaged
# report/triage half of the old `dots-sandbox`, not its launcher. Living
# beside the other AI-harness modules (claude.nix, codex.nix) fits its actual
# shape better than the directory it used to share with `wrap.nix`.
#
# The variables are exported unconditionally (not only when
# triageAssistEnable is true): `dots-secreport triage` itself is the thing
# that must decide, at call time, whether to use them — per the contract, it
# must degrade to heuristics-only, without hanging, when the service turns
# out to be unreachable regardless of what static config says. Baking an
# on/off branch into whether the variable even exists here would just move
# that runtime liveness check into eval time, where it cannot actually
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
