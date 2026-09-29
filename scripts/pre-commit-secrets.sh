#!/bin/bash
# Pre-commit secret check (SEC-01). Install once per clone:
#
#   git config core.hooksPath scripts/git-hooks
#
# Runs gitleaks on the staged changes with .gitleaks.toml when gitleaks is installed
# (brew install gitleaks). Without it, a pattern check for the key shapes this repo has leaked or is
# most likely to: PostHog personal keys (phx_), Anthropic and OpenAI keys, GitHub and Slack tokens,
# AWS access keys, private keys. Test fixtures under Tests/, guest/test/ and *_test.go are exempt.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
if command -v gitleaks >/dev/null 2>&1; then
  exec gitleaks git --pre-commit --staged --config "$root/.gitleaks.toml" --redact --no-banner "$root"
fi
pattern='phx_[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|gh[pousr]_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
scan_staged() {
  git diff --cached --name-only --diff-filter=ACM -z | while IFS= read -r -d '' f; do
    case "$f" in
      (Tests/*|guest/test/*|*_test.go) continue ;;
    esac
    git show ":$f" 2>/dev/null | grep -EIn "$pattern" | sed "s|^|$f:|" | cut -c1-80 || true
  done
}
hits="$(scan_staged)"
if [ -n "$hits" ]; then
  echo "pre-commit: this commit adds what looks like a secret (install gitleaks for a full check):" >&2
  echo "$hits" >&2
  exit 1
fi
