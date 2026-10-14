#!/usr/bin/env bash
# quota-reset-when — when to try again after `claude -p` hit a usage limit.
#
#   lib/quota-reset-when.sh <file with claude's output>    # prints "%F %T": the reset time + 3 minutes
#
# Finds the first "resets …" phrase in the output. Understands:
#   resets 5:40pm (UTC) · resets 11:30pm · resets Sep 17, 7pm · resets Sep 17, 7:30pm
# The time is read in this machine's local time zone (whatever the bracketed zone says). A time with no date
# that has already passed today means tomorrow; a dated time in the past means the window already reset, so now.
# Nothing parseable → now + 5 hours.
OUT=${1:?usage: quota-reset-when.sh <output file>}
R=$(grep -oiE "resets ([A-Za-z]{3,9}\.? [0-9]{1,2},? )?[0-9]{1,2}(:[0-9]{2})? ?(am|pm)" "$OUT" | head -1 | sed -E 's/^resets //I; s/,//; s/\.//')
T=""
if [ -n "$R" ]; then
  if echo "$R" | grep -qiE '^[A-Za-z]'; then
    T=$(date -d "$R" +%s 2>/dev/null || true)                    # with a date: Sep 17 7pm
    [ -n "$T" ] && [ "$T" -le "$(date +%s)" ] && T=$(date +%s)
  else
    T=$(date -d "today $R" +%s 2>/dev/null || true)              # time only: today, or tomorrow if already past
    [ -n "$T" ] && [ "$T" -le "$(date +%s)" ] && T=$(date -d "tomorrow $R" +%s)
  fi
fi
if [ -n "$T" ]; then date -d "@$((T+180))" '+%F %T'; else date -d "+5 hours" '+%F %T'; fi
