#!/usr/bin/env bash
#
# After a PR merges: prove it landed, then move its Issue to Done.
# This is the "Merged PR = accepted" rule in SKILL.md (Source And State) as one command.
#
# Usage (run from inside the repository or any of its worktrees):
#   close-merged.sh <pr> <issue>...      # verify, then In review -> Done on each Issue
#   close-merged.sh --check <pr>         # read-only: verify only, change nothing
#
# Environment:
#   DEFAULT_REMOTE=origin DEFAULT_BRANCH=main   the branch the merge commit must be on
#   REVIEW_LABEL="In review" DONE_LABEL=Done    the labels removed / added
#
# Output: one line per step; the LAST line is always `branch=<the PR's head branch>` on
# success, so a caller (the chief-of-staff skill's closeout.sh) can pick up the branch to clean up.
# Exit: 0 = landed (and labels changed, unless --check); 1 = not merged / not on the base
# branch (nothing written); 2 = usage. A failed label write is reported, not fatal: the
# merge is a fact either way, and the caller still has cleanup to do.
#
# "Landed" means both: `gh pr view` says MERGED, and the merge commit is an ancestor of
# <remote>/<branch> after a fetch. The second half is there because a merged PR whose
# merge commit is not on the base branch (merged into another PR's branch, say) did not
# ship anything.
#
# When to set Done belongs to this skill, so the command does too (see HISTORY #11).

set -u
check=0
[ "${1:-}" = --check ] && { check=1; shift; }
pr=${1:-}; [ -n "$pr" ] || { echo "usage: close-merged.sh [--check] <pr> <issue>..."; exit 2; }; shift
[ $check = 1 ] || [ $# -gt 0 ] || { echo "usage: close-merged.sh <pr> <issue>...  (or --check <pr>)"; exit 2; }
REMOTE=${DEFAULT_REMOTE:-origin}; BASE=$REMOTE/${DEFAULT_BRANCH:-main}
REVIEW_LABEL=${REVIEW_LABEL:-In review}; DONE_LABEL=${DONE_LABEL:-Done}

git fetch -q "$REMOTE" || echo "⚠ git fetch failed — checking against the cached $BASE"
mc=$(gh pr view "$pr" --json mergeCommit,state --jq 'select(.state=="MERGED")|.mergeCommit.oid') || exit 1
[ -n "$mc" ] || { echo "#$pr NOT MERGED"; exit 1; }
git merge-base --is-ancestor "$mc" "$BASE" || { echo "#$pr NOT ON $BASE"; exit 1; }
echo "#$pr LANDED ${mc:0:8}"
br=$(gh pr view "$pr" --json headRefName --jq .headRefName) || exit 1

if [ $check = 0 ]; then
  for issue in "$@"; do
    if gh issue edit "$issue" --remove-label "$REVIEW_LABEL" --add-label "$DONE_LABEL" >/dev/null; then
      st=$(gh issue view "$issue" --json state --jq .state)
      echo "#$issue -> $DONE_LABEL ($st)"
      [ "$st" = OPEN ] && echo "ℹ #$issue is still OPEN — the PR body had no \`Closes #$issue\`; close it if the PR finished it"
    else
      echo "⚠ #$issue label change failed"
    fi
  done
fi
echo "branch=$br"
