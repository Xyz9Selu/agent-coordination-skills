#!/usr/bin/env bash
#
# Claim GitHub Issues for this session, executable as-is.
#
# Project instructions describe the claim as "assignee + In progress + a claim:
# comment carrying branch, worktree, host, sid, pid, sock", which leaves every
# caller to assemble six coordinates by hand. A claim reassembled from prose
# every time is a claim written differently every time — and the whole point of
# the fixed fields is that a *peer* can act on them mechanically. On the board
# this script was written for, hand-assembled claims already disagreed: one named
# a worktree that did not exist, another named a branch that did not exist.
# Coordinates a peer cannot resolve are worth nothing.
#
# It also does the preflight and the verify that are easy to skip:
#   - preflight: is the Issue already held by a session that is still ALIVE?
#   - verify:    re-read after writing, because the assignee write cannot fail.
#
# Usage (installed user-level, the script lives at
# ~/.agents/skills/github-backlog/scripts/claim-issue.sh; run it from inside the repo):
#   claim-issue.sh 101 102              # claim the whole set, one call
#   claim-issue.sh --check 101          # read-only: who holds it, alive?,
#                                       #   plus the stale-reclaim grounds
#   claim-issue.sh --dry-run 101        # print the comment, write nothing
#   claim-issue.sh --force 101          # claim despite a live holder
#   claim-issue.sh --self-test          # run the liveness table as code
#
# Why a script: --self-test, --check, uniform output, and no quoting traps
# around the `·` separator. NOT because a snippet is impossible -- the skill
# carries a one-line fallback that emits all six fields and runs fine inside a
# worktree-isolated session. Five successive attributions of that wall were
# wrong on 2026-08-25 (`git` in a substitution / substitution plus compound flow
# / substitution refused wholesale / an argument that is entirely a substitution
# / $CLAUDE_* being unreachable). Only two survive measurement: a bare `$(...)`
# argument is refused while the same substitution inside literal text passes,
# and $CLAUDE_* *expansion* is refused -- which `$(printenv VAR)` sidesteps.
# The lesson worth keeping: before writing "cannot" into a doc other agents
# copy from, try one equivalent form.
#
# This is NOT a lock. Every session authenticates as the same GitHub account,
# so `gh issue edit --add-assignee @me` exits 0 whether or not somebody holds
# the Issue; nothing here can make that write fail. What this buys is that a
# collision becomes *visible* — at preflight if the holder is alive, at verify
# if two sessions raced. Read the output.
#
# Environment (defaults match the github-backlog skill):
#   DEFAULT_REMOTE=origin  DEFAULT_BRANCH=main  IN_PROGRESS_LABEL="In progress"
set -uo pipefail

DEFAULT_REMOTE="${DEFAULT_REMOTE:-origin}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
IN_PROGRESS_LABEL="${IN_PROGRESS_LABEL:-In progress}"

dry_run=0
force=0
self_test=0
check_only=0
issues=()

for arg in "$@"; do
  case "$arg" in
    --dry-run)   dry_run=1 ;;
    --check)     check_only=1 ;;
    --force)     force=1 ;;
    --self-test) self_test=1 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)        echo "unknown flag: $arg" >&2; exit 2 ;;
    *)         issues+=("$arg") ;;
  esac
done

if [ "${#issues[@]}" -eq 0 ] && [ "$self_test" -eq 0 ]; then
  echo "usage: $0 [--check|--dry-run] [--force] <issue-number> [<issue-number> ...]" >&2
  echo "       $0 --self-test" >&2
  exit 2
fi

# ---- this session's coordinates -------------------------------------------
branch="$(git branch --show-current 2>/dev/null || echo "")"
if [ "$self_test" -eq 0 ] && [ -z "$branch" ]; then
  echo "refusing to claim from a detached HEAD" >&2
  exit 1
fi

top="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
main_root="$(git worktree list --porcelain 2>/dev/null | head -1 | cut -d' ' -f2 || echo "")"
if [ -n "$top" ] && [ "$top" = "$main_root" ]; then
  worktree="none (main checkout)"
elif [ -n "$top" ] && [ -n "$main_root" ]; then
  worktree="${top#"$main_root"/}"
else
  worktree="none"
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
host="$(hostname)"
sid="${CLAUDE_CODE_SESSION_ID:-}"
sid="${sid:0:8}"
[ -n "$sid" ] || sid="unknown"
pid="${CLAUDE_PID:-$$}"
sock="${CLAUDE_CODE_MESSAGING_SOCKET:-none}"

# A socket path that resolves to nothing reads as a dead session and invites a
# reclaim of live work. If the harness handed us one, it had better be there.
if [ "$sock" != "none" ] && [ ! -S "$sock" ]; then
  echo "warning: \$CLAUDE_CODE_MESSAGING_SOCKET=$sock is not a live socket; recording 'none'" >&2
  sock="none"
fi

claim_body() {
  printf 'claim: %s · %s\n  worktree: %s\n  host: %s  sid: %s  pid: %s\n  sock: %s\n' \
    "$branch" "$ts" "$worktree" "$host" "$sid" "$pid" "$sock"
}

# The claims still open on an Issue, as a jq filter over `gh issue view --json
# comments`: every `claim:` posted after the last `release:` or `reclaim:`.
# Both end the claims before them — a release by its holder, a reclaim by
# superseding them (the skill's step 5 posts the reclaim *before* the new
# claim). More than one open claim after our own write is a race.
#
# Replaced (2026-09-30): "0 if the last marker is a release, else every claim
# and reclaim ever posted". It never looked for the *last* boundary, so any
# claim → release → claim read as a race, and a documented reclaim counted the
# reclaim marker itself as a claim. What would overturn this: the skill's
# reclaim protocol stops posting `reclaim:` before `claim:` — then a reclaim is
# no longer a boundary and this filter must change with it.
OPEN_CLAIMS_JQ='
  [.comments[] | select(.body|test("^(claim|reclaim|release):"))]
  | ([.[] | .body | test("^(release|reclaim):")] | indices(true) | last) as $b
  | .[(if $b == null then 0 else $b + 1 end):]
  | [.[] | select(.body|test("^claim:"))]'

field() {  # field <name> <text>
  printf '%s\n' "$2" | sed -n "s/.*[[:space:]]$1:[[:space:]]*\([^[:space:]]*\).*/\1/p" | head -1
}

# The liveness table from the github-backlog skill, step 3, as code. The check
# is deliberately asymmetric: it proves life reliably and proves death only on
# the same host. Never invert "socket exists ⇒ alive" into a death test.
verdict_for() {  # verdict_for <claim-comment-text>
  local last="$1" h_host h_sock h_sid
  h_host="$(field host "$last")"; [ -n "$h_host" ] || h_host="unrecorded"
  h_sock="$(field sock "$last")"; [ -n "$h_sock" ] || h_sock="unrecorded"
  h_sid="$(field sid  "$last")"; [ -n "$h_sid" ]  || h_sid="unrecorded"

  if [ "$h_sid" = "$sid" ] && [ "$sid" != "unknown" ]; then
    echo "ours already (sid $h_sid)"
  elif [ "$h_sock" = "none" ] || [ "$h_sock" = "unrecorded" ]; then
    echo "UNKNOWN — holder reported no socket; only the 2-day commit-age rule can decide"
  elif [ "$h_host" != "$host" ]; then
    echo "UNKNOWN — holder is on '$h_host', this is '$host'; its socket path means nothing here"
  elif [ -S "$h_sock" ]; then
    echo "HOLDER ALIVE (sid $h_sid, $h_sock)"
  else
    echo "probably dead (sid $h_sid, same host, socket gone) — see 'Reclaim stale holds'"
  fi
}

claim_branch() {  # claim_branch <claim-comment-text>
  printf '%s\n' "$1" | head -1 | sed -n 's/^\(claim\|reclaim\):[[:space:]]*\([^[:space:]]*\).*/\2/p'
}

# Decide what to do when preflight found a live holder. Split out of the main
# loop so --self-test can drive check_only/force combinations directly,
# without a real `gh issue view` round trip. Returns 1 to mean "refuse and
# skip this Issue"; the "--force given" narration is force's alone — --check
# only ever reads, so it must never earn a line that claims a write happened.
handle_live_holder() {  # handle_live_holder <check_only> <force>
  local co="$1" fo="$2"
  if [ "$co" -eq 0 ] && [ "$fo" -eq 0 ]; then
    echo "  REFUSING to claim. Message that session instead, or pass --force if you know better." >&2
    return 1
  fi
  [ "$fo" -eq 1 ] && echo "  --force given: claiming over a live holder anyway" >&2
  return 0
}

# The step-5 grounds, and the check step 5 tells you not to skip: a dead session
# may have left finished work behind. Read-only.
stale_grounds() {  # stale_grounds <claim-comment-text>
  local last="$1" br ref n_ahead
  br="$(claim_branch "$last")"
  if [ -z "$br" ]; then echo "  (no claimed branch recorded)"; return 0; fi
  echo "  claimed branch: $br"

  ref=""
  if git rev-parse --verify --quiet "refs/heads/$br" >/dev/null; then
    ref="refs/heads/$br"
  elif git rev-parse --verify --quiet "refs/remotes/${DEFAULT_REMOTE}/$br" >/dev/null; then
    ref="refs/remotes/${DEFAULT_REMOTE}/$br"
  fi

  if [ -z "$ref" ]; then
    echo "  ground 2: BRANCH GONE — no local or ${DEFAULT_REMOTE} ref (fetch first if unsure)"
    return 0
  fi

  if git log -1 --since='2 days ago' --oneline "$ref" 2>/dev/null | grep -q .; then
    echo "  ground 2: branch active within 2 days — NOT stale"
  else
    echo "  ground 2: BRANCH QUIET — no commit in 2 days"
  fi

  n_ahead="$(git rev-list --count "${DEFAULT_REMOTE}/${DEFAULT_BRANCH}..$ref" 2>/dev/null || echo 0)"
  if [ "${n_ahead:-0}" -gt 0 ]; then
    echo "  ⚠ $n_ahead unmerged commit(s) on that branch — this is NOT free work:"
    git log --oneline "${DEFAULT_REMOTE}/${DEFAULT_BRANCH}..$ref" 2>/dev/null | sed 's/^/      /'
  else
    echo "  no unmerged commits vs ${DEFAULT_REMOTE}/${DEFAULT_BRANCH}"
  fi
  gh pr list --state all --head "$br" --json number,state,mergedAt \
    --jq '.[] | "  PR #\(.number) \(.state) merged=\(.mergedAt // "no")"' 2>/dev/null
}

self_test() {
  local fails=0 got
  local orig_sock="${sock}"
  local orig_sid="${sid}"
  local temp_sock_dir=""

  # $sock is this session's own live socket. If not available in this environment,
  # create a temporary unix domain socket for self-testing.
  local live="${sock}"
  if [ "$live" = "none" ] || [ ! -S "$live" ]; then
    temp_sock_dir="$(mktemp -d)"
    live="$temp_sock_dir/test.sock"
    python3 -c "import socket; s = socket.socket(socket.AF_UNIX); s.bind('$live')" 2>/dev/null || true
  fi

  if [ ! -S "$live" ]; then
    echo "SKIP: no live socket in this environment" >&2
    [ -n "$temp_sock_dir" ] && rm -rf "$temp_sock_dir"
    return 0
  fi

  # For "ours already" test, ensure sid is not "unknown"
  if [ "$sid" = "unknown" ]; then
    sid="testsession"
  fi

  check() {  # check <expected-prefix> <label> <claim-text>
    got="$(verdict_for "$3")"
    case "$got" in
      "$1"*) printf 'ok   %s\n' "$2" ;;
      *)     printf 'FAIL %s\n       expected: %s...\n       got:      %s\n' "$2" "$1" "$got"; fails=$((fails+1)) ;;
    esac
  }

  check "HOLDER ALIVE" "live socket on this host ⇒ alive" \
    "claim: b · t
  host: $host  sid: aaaaaaaa  pid: 1
  sock: $live"

  check "UNKNOWN — holder is on" "live socket but foreign host ⇒ unknown, NOT dead" \
    "claim: b · t
  host: some-other-box  sid: aaaaaaaa  pid: 1
  sock: $live"

  check "UNKNOWN — holder is on" "absent socket on foreign host ⇒ unknown, NOT dead" \
    "claim: b · t
  host: some-other-box  sid: aaaaaaaa  pid: 1
  sock: /run/user/1000/cc-socks/999999.sock"

  check "probably dead" "absent socket on THIS host ⇒ may escalate" \
    "claim: b · t
  host: $host  sid: aaaaaaaa  pid: 1
  sock: /run/user/1000/cc-socks/999999.sock"

  check "UNKNOWN — holder reported no socket" "sock: none ⇒ unknown" \
    "claim: b · t
  host: $host  sid: aaaaaaaa  pid: 1
  sock: none"

  check "UNKNOWN — holder reported no socket" "old single-line format ⇒ unknown" \
    "claim: fix/101-notify-submit-failure · 2026-08-25T06:27:37Z · worktree-101"

  # The documented hand-rolled fallback emits all six fields on ONE line.
  # Peers must be able to parse that shape too, or the fallback is a trap.
  check "HOLDER ALIVE" "single-line fallback shape parses" \
    "claim: b · t worktree: . host: $host sid: aaaaaaaa pid: 1 sock: $live"

  check "ours already" "our own sid ⇒ ours" \
    "claim: b · t
  host: $host  sid: $sid  pid: 1
  sock: /run/user/1000/cc-socks/999999.sock"

  # handle_live_holder: --check must never narrate a force it didn't do (an earlier version did).
  check_holder_action() {  # check_holder_action <label> <check_only> <force> <expect-force-line:0|1> <expect-rc>
    local label="$1" co="$2" fo="$3" expect_force="$4" expect_rc="$5" out rc_got ok=1
    out="$(handle_live_holder "$co" "$fo" 2>&1)"; rc_got=$?
    [ "$rc_got" = "$expect_rc" ] || ok=0
    case "$out" in
      *"--force given"*) [ "$expect_force" -eq 1 ] || ok=0 ;;
      *)                  [ "$expect_force" -eq 0 ] || ok=0 ;;
    esac
    if [ "$ok" -eq 1 ]; then
      printf 'ok   %s\n' "$label"
    else
      printf 'FAIL %s\n       check_only=%s force=%s\n       expected: force_line=%s rc=%s\n       got:      output=%s rc=%s\n' \
        "$label" "$co" "$fo" "$expect_force" "$expect_rc" "$out" "$rc_got"
      fails=$((fails+1))
    fi
  }

  check_holder_action "--check alone: no false force narration, read-only rc"  1 0 0 0
  check_holder_action "--force alone: narrates and proceeds"                  0 1 1 0
  check_holder_action "no flags: refuses, no force narration"                 0 0 0 1
  check_holder_action "--check --force: still narrates force"                 1 1 1 0

  sock="$orig_sock"
  sid="$orig_sid"
  [ -n "$temp_sock_dir" ] && rm -rf "$temp_sock_dir"

  # Open-claim counting. Observed 2026-09-30: claim → release → claim read as
  # "2 unreleased claims" and stopped two workers whose claims were sole holds.
  check_open() {  # check_open <expected-count> <label> <comment-kind>...
    local expected="$1" label="$2"; shift 2
    local json
    json="$(python3 -c 'import json,sys; print(json.dumps({"comments":[{"body":k+": x","createdAt":"t%d"%i} for i,k in enumerate(sys.argv[1:])]}))' "$@")"
    got="$(jq "$OPEN_CLAIMS_JQ | length" <<<"$json")"
    if [ "$got" = "$expected" ]; then printf 'ok   %s\n' "$label"
    else printf 'FAIL %s\n       expected: %s open\n       got:      %s\n' "$label" "$expected" "$got"; fails=$((fails+1)); fi
  }
  check_open 1 "sole claim"                                  claim
  check_open 2 "two claims, no release ⇒ race"               claim claim
  check_open 0 "claim then release ⇒ none open"              claim release
  check_open 1 "claim, release, claim ⇒ only the new one"    claim release claim
  check_open 2 "race after a release is still a race"        claim release claim claim
  check_open 1 "documented reclaim ⇒ only the new claim"     claim reclaim claim
  check_open 2 "race after a reclaim is still a race"        claim reclaim claim claim
  check_open 1 "non-protocol comments are ignored"           claim note release note claim

  [ "$fails" -eq 0 ] && echo "all liveness cases pass" || echo "$fails case(s) FAILED"
  return "$fails"
}

if [ "$self_test" -eq 1 ]; then
  self_test
  exit $?
fi

# ---- per Issue -------------------------------------------------------------
rc=0
for n in "${issues[@]}"; do
  echo "=== #$n ==="

  last="$(gh issue view "$n" --json comments \
    --jq '[.comments[].body | select(test("^(claim|reclaim|release):"))] | last // ""' 2>&1)" || {
      echo "  ERROR: cannot read #$n — $last" >&2; rc=1; continue; }

  # ---- preflight: is it held, and is the holder alive? ----
  case "$last" in
    claim:*|reclaim:*)
      verdict="$(verdict_for "$last")"
      echo "  held: ${last%%$'\n'*}"
      echo "  liveness: $verdict"

      case "$verdict" in
        "HOLDER ALIVE"*)
          if ! handle_live_holder "$check_only" "$force"; then
            rc=1
            continue
          fi
          ;;
      esac
      ;;
    "")        echo "  no prior claim" ;;
    release:*) echo "  last action was a release — free" ;;
  esac

  if [ "$check_only" -eq 1 ]; then
    stale_grounds "$last"
    continue
  fi

  if [ "$dry_run" -eq 1 ]; then
    echo "  --dry-run, would post:"
    claim_body | sed 's/^/    /'
    continue
  fi

  # ---- write ----
  body_file="$(mktemp -t "claim-$n.XXXXXX")"
  claim_body > "$body_file"
  gh issue edit "$n" --add-assignee @me --add-label "$IN_PROGRESS_LABEL" >/dev/null || { rc=1; continue; }
  gh issue comment "$n" --body-file "$body_file" >/dev/null || { rc=1; continue; }
  rm -f "$body_file"
  echo "  claimed"

  # ---- verify: the assignee write cannot fail, so this is the only place a
  # ---- collision surfaces.
  comments_json="$(gh issue view "$n" --json comments)"
  open_claims="$(jq "$OPEN_CLAIMS_JQ | length" <<<"$comments_json")"
  if [ "${open_claims:-0}" -gt 1 ]; then
    echo "  ⚠ $open_claims unreleased claims on #$n — EARLIEST TIMESTAMP WINS."
    jq -r "$OPEN_CLAIMS_JQ"' | .[] | "    \(.createdAt)  \(.body | split("\n")[0])"' <<<"$comments_json"
    echo "  If yours is not the earliest: release it and re-select."
    rc=1
  fi
done

exit "$rc"
