#!/usr/bin/env bash
#
# lib.sh — helpers that both tooling tests share.
#
# A test sources this file after it sets ROOT and FAILURES. It runs no test of
# its own. Both tests count failures the same way, so the rules live here once.

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

