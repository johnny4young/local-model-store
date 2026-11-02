#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failures=0

report() {
  echo "$1" >&2
  echo "$2" >&2
  failures=1
}

for required in LICENSE README.md AGENTS.md SECURITY.md docs/PROVENANCE.md; do
  if [[ ! -f "$required" ]]; then
    report "Required file is missing:" "$required"
  fi
done

if [[ "$(readlink CLAUDE.md || true)" != "AGENTS.md" ]]; then
  report "CLAUDE.md must be a symlink to AGENTS.md:" "$(ls -l CLAUDE.md 2>&1 || true)"
fi

forbidden_tracked='^(\.agents|\.claude|\.codex|\.planning|\.tickets|plans|tickets|docs/plans|docs/tickets|artifacts|screenshots|test-results)/|^docs/ROADMAP\.md$|^planning_.*\.md$|(^|/)(DerivedData|xcuserdata)/|\.xcodeproj/|\.xcresult/|\.profraw$|\.profdata$|\.xcactivitylog$'
tracked_forbidden="$(git ls-files | grep -E "$forbidden_tracked" || true)"
if [[ -n "$tracked_forbidden" ]]; then
  report "Ephemeral or generated files must not be tracked:" "$tracked_forbidden"
fi

tracked_ignored="$(git ls-files -ci --exclude-standard || true)"
if [[ -n "$tracked_ignored" ]]; then
  report "Tracked files also match .gitignore:" "$tracked_ignored"
fi

conflict_markers="$(git grep --untracked -nEI '^(<{7}|\|{7}|>{7})( |$)' -- . || true)"
if [[ -n "$conflict_markers" ]]; then
  report "Unresolved merge-conflict markers:" "$conflict_markers"
fi

private_ref_pattern='(^|[^[:alnum:]_])(ENG|JIRA|TICKET|TASK|STORY|EPIC|SPIKE|PORTAVOZ|SECRETEO|STORE|PV|APT|APUN)-[0-9]{1,6}([^[:alnum:]_]|$)'
ticket_refs="$(git grep --untracked -nEI "$private_ref_pattern" -- . || true)"
if [[ -n "$ticket_refs" ]]; then
  report "Private ticket references:" "$ticket_refs"
fi

# Bracketed so the patterns do not match this file.
source_app_identifiers='app[.]portavoz|PORTAVOZ[_]|PV[D]esign|"PV[O]Z"|0x5056_?4F5[A]|A[p]untador|Cloud[K]it|PortavozSource[C]ommit|portavozLocal[i]zed|portavoz-ui-test[s]|Application Support/Portavo[z]'
leaked_identifiers="$(
  git grep --untracked -nEI "$source_app_identifiers" -- . \
    ':(exclude)docs/PROVENANCE.md' || true
)"
if [[ -n "$leaked_identifiers" ]]; then
  report "Source-app identifiers belong only in docs/PROVENANCE.md:" "$leaked_identifiers"
fi

private_paths="$(git grep --untracked -nEI '/Users/[a-z0-9]|PortavozFiel[d]' -- . || true)"
if [[ -n "$private_paths" ]]; then
  report "Private local paths:" "$private_paths"
fi

gpl_markers="$(
  git grep --untracked -nEIi 'SPDX-License-Identifier:[[:space:]]*(A|L)?GPL|GNU (Affero |Lesser )?General Public License' -- . || true
)"
if [[ -n "$gpl_markers" ]]; then
  report "GPL license markers:" "$gpl_markers"
fi

if git rev-parse --verify --quiet HEAD >/dev/null; then
  attributed_commits="$(
    git log --format='%h %B' | grep -EIi \
      'co-authored-by:.*(claude|anthropic|copilot|codex|openai|chatgpt|gemini|cursor)|generated (with|by) .*(claude|copilot|codex|chatgpt|gemini|cursor)' || true
  )"
  if [[ -n "$attributed_commits" ]]; then
    report "Commit messages must not carry AI attribution:" "$attributed_commits"
  fi
fi

if compgen -G '.github/workflows/*.yml' >/dev/null; then
  mutable_actions="$(
    grep -nE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+[^[:space:]]+@' .github/workflows/*.yml \
      | grep -Ev '@[0-9a-f]{40}([[:space:]]|#|$)' || true
  )"
  if [[ -n "$mutable_actions" ]]; then
    report "GitHub Actions must use full-length commit SHAs:" "$mutable_actions"
  fi
fi

if [[ -d Tests ]]; then
  oversized_tests="$(
    find Tests -name '*.swift' -exec wc -l {} + \
      | awk '$2 != "total" && $1 > 2400 { print $1 " " $2 }' || true
  )"
  if [[ -n "$oversized_tests" ]]; then
    report "Test files must stay under 2400 lines:" "$oversized_tests"
  fi
fi

ignore_probes=(
  .agents/session.md
  .claude/worktrees/x/file.md
  .codex/plan.md
  .planning/next-slice.md
  .tickets/LOCAL.md
  plans/local-plan.md
  tickets/LOCAL.md
  docs/plans/local-plan.md
  docs/tickets/LOCAL.md
  docs/ROADMAP.md
  planning_voice_20260911.md
  PLAN.md
  TODO.md
  HANDOFF.md
  reports/local-audit.md
  scratch/notes.md
  private-evidence/pack.json
  artifacts/ui/result.txt
  screenshots/local-smoke.png
  test-results/run.json
  local-ui.xcresult/Info.plist
)

for probe in "${ignore_probes[@]}"; do
  if ! git check-ignore --quiet --no-index "$probe"; then
    report "Expected local artifact is not ignored:" "$probe"
  fi
done

if [[ -d Tests/Tooling ]]; then
  python3 -m unittest discover -s Tests/Tooling -p 'test_*.py'
fi

exit "$failures"
