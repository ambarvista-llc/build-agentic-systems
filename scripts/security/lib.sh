# Shared helpers for the baseline scripts. Sourced, not run.
#
# Every script audits first (GET requests only) and prints what differs from the
# baseline. Nothing is written unless --apply is passed AND you answer y at the
# prompt. After writing, the script audits again and fails if anything still differs.

command -v jq >/dev/null || { echo "needs jq (brew install jq)" >&2; exit 2; }

DRIFT=0
DRIFTED=" "
FAILED=0

parse_args() {  # sets TARGET and MODE; the caller sets USAGE
  TARGET=""
  MODE=audit
  for a in "$@"; do
    case "$a" in
      --apply) MODE=apply ;;
      -*) echo "$USAGE" >&2; exit 2 ;;
      *) [[ -z $TARGET ]] || { echo "$USAGE" >&2; exit 2; }; TARGET="$a" ;;
    esac
  done
  [[ -n $TARGET ]] || { echo "$USAGE" >&2; exit 2; }
}

drifted() { [[ "$DRIFTED" == *" $1 "* ]]; }

mark_drift() {  # group, message
  echo "   DRIFT  $2"
  DRIFT=$((DRIFT + 1))
  DRIFTED+="$1 "
}

# check <group> <api path> <jq expr> <expected> <label>
check() {
  local got
  got=$(gh api "$2" --jq "$3" 2>/dev/null) || got="(unreadable)"
  if [[ "$got" == "$4" ]]; then
    echo "   ok     $5"
  else
    mark_drift "$1" "$5: want $4, got $got"
  fi
}

# check_ok <group> <api path> <label>: passes when the GET succeeds (204 means enabled)
check_ok() {
  if gh api "$2" >/dev/null 2>&1; then echo "   ok     $3"; else mark_drift "$1" "$3: not enabled"; fi
}

note() { echo "   note   $*"; }
manual() { echo "   MANUAL $* (no API; check by hand)"; }

# try <command...>: run a write, record a failure, keep going so the re-audit shows the full picture
try() {
  "$@" >/dev/null || { echo "   FAILED: $*" >&2; FAILED=1; }
}

# try_org_managed <gh api args...>: like try, but a 409 saying the org already
# sets this is fine. Any other error is a real failure.
try_org_managed() {
  local out
  if ! out=$(gh api "$@" 2>&1); then
    if grep -q "already set at the organization" <<<"$out"; then
      echo "   set by the org, skipping"
    else
      echo "   FAILED: gh api $*: $out" >&2
      FAILED=1
    fi
  fi
}

# run_baseline: needs audit() and apply() defined by the caller
run_baseline() {
  local ans
  echo "== Audit ($MODE mode)"
  audit
  if (( DRIFT == 0 )); then echo "No drift."; return 0; fi
  echo "$DRIFT setting(s) differ from the baseline:$DRIFTED"
  if [[ $MODE != apply ]]; then
    echo "Nothing changed. Re-run with --apply to fix what the API allows."
    return 1
  fi
  read -r -p "Apply changes for the groups above? [y/N] " ans </dev/tty 2>/dev/null || ans=n
  [[ $ans == [yY] ]] || { echo "Cancelled, nothing changed."; return 1; }
  echo "== Apply"
  apply
  DRIFT=0
  DRIFTED=" "
  echo "== Re-audit"
  audit
  if (( DRIFT == 0 && FAILED == 0 )); then echo "Baseline matches."; return 0; fi
  echo "Still differs or failed ($DRIFT drift, failed=$FAILED); see above." >&2
  return 1
}
