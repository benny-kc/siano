#!/usr/bin/env bash
#
# latest-branch.sh — find which branch has the most recent changes.
#
# It inspects every branch's tip commit (local, and optionally remote) and
# reports the one committed most recently, then prints its name. Handy for
# answering "where did the newest work land?" after switching machines or
# picking up someone else's push.
#
# Usage:
#   scripts/latest-branch.sh            # look at local branches
#   scripts/latest-branch.sh --remote   # include remote-tracking branches too
#   scripts/latest-branch.sh --all      # local + remote
#   scripts/latest-branch.sh --name     # print ONLY the winning branch name
#
set -euo pipefail

# --- parse flags -------------------------------------------------------------
scope="local"     # local | remote | all
name_only=false

for arg in "$@"; do
  case "$arg" in
    --remote) scope="remote" ;;
    --all)    scope="all" ;;
    --name)   name_only=true ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

# --- must be inside a git repo ----------------------------------------------
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not a git repository." >&2
  exit 1
fi

# --- pick which refs to scan -------------------------------------------------
case "$scope" in
  local)  refs="refs/heads" ;;
  remote) refs="refs/remotes" ;;
  all)    refs="refs/heads refs/remotes" ;;
esac

# Sort branches by their tip commit date, newest first.
# %(committerdate:iso8601) → sortable timestamp; %(refname:short) → branch name.
# shellcheck disable=SC2086
sorted=$(git for-each-ref \
  --sort=-committerdate \
  --format='%(committerdate:iso8601)|%(refname:short)|%(subject)' \
  $refs | grep -v '/HEAD$' || true)

if [ -z "$sorted" ]; then
  echo "No branches found." >&2
  exit 1
fi

# The winner is simply the first line (newest committerdate).
winner_line=$(printf '%s\n' "$sorted" | head -n1)
winner_branch=$(printf '%s' "$winner_line" | cut -d'|' -f2)

# --name → just the branch name, nothing else (for scripting).
if [ "$name_only" = true ]; then
  echo "$winner_branch"
  exit 0
fi

# --- human-readable report ---------------------------------------------------
current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

echo "Branches by most recent change (newest first):"
echo
printf '%s\n' "$sorted" | while IFS='|' read -r date branch subject; do
  marker="  "
  [ "$branch" = "$current" ] && marker="* "
  printf '%s%-20s  %s  %s\n' "$marker" "$branch" "$date" "$subject"
done

echo
echo "Most recent changes are on branch: $winner_branch"
echo "  (last commit: $(printf '%s' "$winner_line" | cut -d'|' -f1))"
[ "$winner_branch" = "$current" ] && echo "  You are already on it."
