#!/usr/bin/env bash
# ================================================================
#  tests/lint.sh — Tier 0: static checks, no VM, runs in seconds
#
#    · bash -n syntax check of install.sh + every harness script
#    · shellcheck (if installed) on the same set
#    · YAML well-formedness of .steps.yaml / .konkrit.yaml
#
#  Exits non-zero on the first category that fails; prints a summary.
# ================================================================
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

section "Tier 0 — lint"

fail=0

# ── 1. bash -n syntax ────────────────────────────────────────────
log "bash -n syntax check"
mapfile -t _scripts < <(
  printf '%s\n' "${REPO_ROOT}/install.sh"
  find "${TESTS_DIR}" -name '*.sh' -not -path "${ARTIFACTS}/*" | sort
)
for s in "${_scripts[@]}"; do
  if bash -n "${s}" 2>/tmp/lint.$$; then
    ok "syntax: ${s#"${REPO_ROOT}/"}"
  else
    warn "syntax error in ${s#"${REPO_ROOT}/"}:"
    cat /tmp/lint.$$ >&2
    fail=1
  fi
done
rm -f /tmp/lint.$$

# ── 2. shellcheck (optional) ─────────────────────────────────────
if command -v shellcheck &>/dev/null; then
  log "shellcheck"
  # SC1091: don't follow sourced files. SC2034: "unused" var — endemic false
  # positive here because install.sh assembles a large chroot script inside a
  # heredoc, so vars consumed there look unused to shellcheck.
  if shellcheck -e SC1091 -e SC2034 -S warning "${_scripts[@]}"; then
    ok "shellcheck clean (warning+)"
  else
    warn "shellcheck reported issues"
    fail=1
  fi
else
  warn "shellcheck not installed — skipping (pacman -S shellcheck)"
fi

# ── 3. YAML well-formedness ──────────────────────────────────────
# .steps.yaml / .konkrit.yaml carry custom afosi/konkrit tags (!NoCon, !Input,
# !Choice, …) so a plain safe_load rejects them — use a loader that IGNORES
# unknown tags and only checks that the document is well-formed. Missing PyYAML
# degrades to a skip (a dev-dep gap must not fail the lint).
log "YAML validation"
_HAVE_PYYAML=0
if command -v python3 &>/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  _HAVE_PYYAML=1
fi

_yaml_check() {
  local f="$1"
  [[ -f "${f}" ]] || { warn "missing: ${f}"; return 1; }
  if (( _HAVE_PYYAML )); then
    if python3 - "${f}" 2>/tmp/yaml.$$ <<'PY'
import sys, yaml
class L(yaml.SafeLoader): pass
# Catch-all: any tag (custom !NoCon etc.) resolves to None; we only test syntax.
L.add_multi_constructor('', lambda loader, suffix, node: None)
with open(sys.argv[1]) as fh:
    for _ in yaml.load_all(fh, Loader=L):
        pass
PY
    then
      ok "yaml: ${f#"${REPO_ROOT}/"}"; return 0
    else
      warn "invalid YAML: ${f#"${REPO_ROOT}/"}"; cat /tmp/yaml.$$ >&2; return 1
    fi
  else
    warn "PyYAML not available — skipping YAML check for ${f#"${REPO_ROOT}/"} (pip install pyyaml)"
    return 0
  fi
}
_yaml_check "${REPO_ROOT}/.steps.yaml"   || fail=1
_yaml_check "${REPO_ROOT}/.konkrit.yaml" || fail=1
rm -f /tmp/yaml.$$

# ── Summary ──────────────────────────────────────────────────────
if (( fail )); then
  die "lint FAILED"
fi
ok "lint passed"
