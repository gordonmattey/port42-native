#!/bin/bash
# What is built and not in main (docs/release-checklist: run before every release).
#
# The release is built from main plus the batch the squad hands over. A ticket marked FIXED that is not in
# that batch is invisible from main, and 1.0.5 left five out (#128, #136, #137, #221, #222). This lists them:
# every ticket on a recent branch whose change is not in main, by patch identity (a squashed or cherry-picked
# ticket does not count as missing) and by ticket number in main's history.
#
#   scripts/unshipped.sh            # branches touched in the last 7 days
#   scripts/unshipped.sh 30         # the last 30 days
#
# Reconcile every line before a release: in this release, deferred (say why on the card), or dropped.
cd "$(dirname "$0")/.." || exit 1
days=${1:-7}
since=$(date -v-"${days}"d +%s)
found=0
git for-each-ref --sort=-committerdate --format='%(refname:short)|%(committerdate:relative)|%(committerdate:unix)' refs/heads |
while IFS='|' read -r b when ts; do
  [ "$ts" -lt "$since" ] && continue
  case $b in main|lead/for-*|squad/for-*|candidate-*|worktree-agent-*|spike/*|watch|rc/*) continue;; esac
  plus=$(git cherry main "$b" 2>/dev/null | grep -c '^+')
  [ "$plus" -gt 0 ] || continue
  subject=$(git log --no-merges --format=%s "main..$b" | head -1)
  # A ticket id is #123, or a squad audit id such as APP-06, NAU-05, BLD-11, SEC-01, GST-02.
  ticket=$(echo "$subject" | grep -oE '#[0-9]+|\b[A-Z]{2,4}-[0-9]+' | head -1)
  # A ticket whose number is in main's history shipped, whatever branch shape it took (squashed, merged).
  if [ -n "$ticket" ] && git log main --oneline -i --grep="$ticket\b" | grep -q .; then continue; fi
  printf '%-34s %-16s %s\n' "$b" "$when" "$(echo "$subject" | cut -c1-80)"
  found=1
done
echo "---"
echo "Every line above is built and not in main. Release it, defer it on its card with a reason, or drop it."
