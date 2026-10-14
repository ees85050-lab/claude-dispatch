#!/usr/bin/env bash
# ledger-done — has a run written its ending to its ledger?
#
#   source lib/ledger-done.sh
#   ledger_done <ledger>      # 0 = one of the last 3 lines is a DONE or STOPPED line; 1 = no, or no such file
#   ledger_stopped <ledger>   # 0 = the ending among the last 3 lines is STOPPED, not DONE
#
# An ending line may start with list markers and a time: "DONE", "- DONE", "- 14:05 DONE: all green",
# "* 9:30 STOPPED: the API is down". The word must start the line (after those), so a line that merely
# mentions DONE or STOPPED doesn't count.
# Why it exists: `claude -p` can push its work into the background, end its turn, and exit 0. Going by the
# exit code alone, that run looks finished; the ledger says whether it actually got to the end.
LEDGER_DONE_RE='^[-* ]*([0-9]{1,2}:[0-9]{2} *)?DONE\b'
LEDGER_STOP_RE='^[-* ]*([0-9]{1,2}:[0-9]{2} *)?STOPPED:'
ledger_done() {
  [ -f "${1:-}" ] && tail -n 3 "$1" | grep -qE "$LEDGER_DONE_RE|$LEDGER_STOP_RE"
}
ledger_stopped() {
  [ -f "${1:-}" ] && tail -n 3 "$1" | grep -qE "$LEDGER_STOP_RE" && ! tail -n 3 "$1" | grep -qE "$LEDGER_DONE_RE"
}
