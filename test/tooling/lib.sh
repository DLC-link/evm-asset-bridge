#!/usr/bin/env bash
#
# lib.sh — helpers that both tooling tests share.
#
# A test sources this file after it sets ROOT and FAILURES. It runs no test of
# its own. Both tests count failures the same way, and both leave compiler
# inputs behind, so the rules live here once.

# check compares one value against the value the test expects.
check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: got '$2', want '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

# contains looks for a substring in a captured output.
contains() { # contains <label> <haystack> <needle>
  case "$2" in
    *"$3"*) echo "  ok   $1" ;;
    *) echo "  FAIL $1: '$3' not found"; FAILURES=$((FAILURES + 1)) ;;
  esac
}

# prune_untracked_solc_inputs removes the compiler inputs a test run created.
# It keeps any input that a record on disk still names, whether the record
# names it directly or through a history entry. A real deploy leaves both the
# record and the input untracked until the operator commits them. Deleting an
# input that a record names would destroy the only copy.
prune_untracked_solc_inputs() {
  local f hash r keep
  for f in deployments/solcInputs/*.json; do
    [ -e "$f" ] || continue
    git ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue
    hash="$(basename "$f" .json)"
    keep=0
    for r in deployments/*.json; do
      [ -e "$r" ] || continue
      if jq -e --arg h "$hash" \
        '[.solcInputHash, ((.history // [])[] | .solcInputHash)] | index($h) != null' \
        "$r" >/dev/null 2>&1; then
        keep=1
        break
      fi
    done
    [ "$keep" -eq 1 ] || rm -f "$f"
  done
  return 0
}
