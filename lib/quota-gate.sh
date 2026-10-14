#!/usr/bin/env bash
# quota-gate — how full is the Claude Code 5-hour usage window right now?
#
#   source lib/quota-gate.sh; quota_gate <who>     # sets U AGE RESET, returns the gate state
#   lib/quota-gate.sh <who>                        # prints "U AGE RESET", exit code = gate state
#
# Reads the cache Claude Code keeps for its own /usage screen: cachedUsageUtilization.utilization.five_hour
# in ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json. That cache is undocumented and may change shape in any release;
# every failure to read it ends in rc=2, and claude-dispatch treats rc=2 as "don't know, carry on" (fail open).
#
# Exit code: 0 = below the line; 1 = at or over the line (U ≥ QUOTA_GATE_MAX, default 85);
#            2 = can't tell: no cache, unreadable, or the reading is older than 2 × QUOTA_REFRESH_MIN minutes
#                (at least 20) and refreshing it didn't work.
# A reading whose reset time has already passed belongs to the previous window: the gate treats it as 0%,
# and the readings file records u="unknown" (a string of fake zeros would skew any later calibration).
#
# Before reading, quota_refresh runs `claude -p /usage` if the cache is older than QUOTA_REFRESH_MIN
# (default 20) minutes. /usage is a local command (no model call, a few seconds) and rewrites the cache;
# headless sessions otherwise never refresh it. CLAUDE_CODE_OAUTH_TOKEN is removed for that one command:
# with a long-lived token in the environment, /usage shows the session's cost view and fetches no quota.
#
# Each reading appends one JSON line to QUOTA_READINGS_FILE (who/u/age_h/reset/gate, whether the refresh
# landed, and every limit line Claude Code reports), so you can later see who used what.
# Overrides (tests use all three): QUOTA_CACHE_FILE, QUOTA_READINGS_FILE, QUOTA_REFRESH_CMD.
QUOTA_CACHE_FILE="${QUOTA_CACHE_FILE:-${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json}"
QUOTA_READINGS_FILE="${QUOTA_READINGS_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-dispatch/quota-readings.jsonl}"

_quota_fetched() {
  python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['cachedUsageUtilization']['fetchedAtMs'])" "$QUOTA_CACHE_FILE" 2>/dev/null || echo 0
}

# sets QR_REFRESHED (true / false / skip = the reading is fresh enough, no refresh), QR_RC, QR_HEAD
quota_refresh() {
  local before after age_min out
  QR_REFRESHED=skip; QR_RC=""; QR_HEAD=""
  before=$(_quota_fetched)
  age_min=$(python3 -c "import sys,time; print(int((time.time()*1000-int(sys.argv[1]))/60000))" "$before" 2>/dev/null || echo 99999)
  [ "$age_min" -lt "${QUOTA_REFRESH_MIN:-20}" ] && return 0
  # shellcheck disable=SC2086
  out=$( cd "${TMPDIR:-/tmp}" && timeout 60 ${QUOTA_REFRESH_CMD:-env -u CLAUDE_CODE_OAUTH_TOKEN ${DISPATCH_CLAUDE:-claude} -p /usage} < /dev/null 2>&1 ); QR_RC=$?
  QR_HEAD=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-40)
  after=$(_quota_fetched)
  if [ "$after" != "$before" ] && [ "$after" != 0 ]; then QR_REFRESHED=true; else QR_REFRESHED=false; fi
  return 0
}

quota_gate() {
  local who="${1:-?}" q rc
  quota_refresh
  q=$(QG_WHO="$who" QG_MAX="${QUOTA_GATE_MAX:-85}" QG_STALE_MIN="${QUOTA_REFRESH_MIN:-20}" \
      QG_REFRESHED="$QR_REFRESHED" QG_RC="$QR_RC" QG_HEAD="$QR_HEAD" QG_FILE="$QUOTA_READINGS_FILE" \
      python3 - "$QUOTA_CACHE_FILE" <<'PY'
import json,sys,time,datetime,os
E=os.environ
row={"at":time.strftime("%Y-%m-%dT%H:%M:%S%z"),"who":E["QG_WHO"]}
try:
    j=json.load(open(sys.argv[1]))['cachedUsageUtilization']
    age_h=(time.time()*1000-j['fetchedAtMs'])/3.6e6
    fh=j['utilization']['five_hour']
    if fh is None:
        # right after the window resets, before anything has used the new one, five_hour is null: that's 0%
        fh={'utilization':0,'resets_at':None}
    u=fh['utilization']; r=fh['resets_at']
    # a reset time in the past means the reading is from the previous window: gate on 0%, record "unknown".
    # (Gating on the old number would schedule the next try at a time that has already passed.)
    if r is None:
        passed=False; r='-'
    else:
        rt=datetime.datetime.fromisoformat(r.replace('Z','+00:00'))
        passed = rt <= datetime.datetime.now(datetime.timezone.utc)
    ug = 0 if passed else u
    if passed: r=r+'(passed)'
    stale = age_h*60 > max(2*int(E["QG_STALE_MIN"]), 20) and E["QG_REFRESHED"] != "true"
    if stale or (age_h >= 6 and ug >= int(E["QG_MAX"])):
        rc=2
    elif ug >= int(E["QG_MAX"]):
        rc=1
    else:
        rc=0
    lines=[]
    for l in (j['utilization'].get('limits') or []):
        sc=l.get('scope') or {}
        lines.append({"kind":l.get("kind"),"model":((sc.get("model") or {}).get("display_name")),"pct":l.get("percent"),
                      "resets_at":l.get("resets_at"),"severity":l.get("severity"),"active":l.get("is_active")})
    row.update(u=("unknown" if passed else str(u)), age_h=f"{age_h:.1f}", reset=r, gate=rc, fetched_ms=j['fetchedAtMs'], lines=lines)
    print(f"{ug} {age_h:.1f} {r} {rc}")
except Exception:
    row.update(u="-1", age_h="99", reset="-", gate=2)
    print("-1 99 - 2")
row.update(refreshed=E["QG_REFRESHED"], refresh_rc=E["QG_RC"], refresh_head=E["QG_HEAD"])
try:
    os.makedirs(os.path.dirname(E["QG_FILE"]) or ".", exist_ok=True)
    with open(E["QG_FILE"],"a") as fh: fh.write(json.dumps(row,ensure_ascii=False)+"\n")
except OSError:
    pass
PY
)
  read -r U AGE RESET rc <<<"$q"
  return "${rc:-2}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  quota_gate "${1:-cli}"; rc=$?
  echo "$U $AGE $RESET"
  exit $rc
fi
