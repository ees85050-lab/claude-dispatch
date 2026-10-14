#!/usr/bin/env bash
# Tests for bin/claude-dispatch. Plain bash, no framework.
#   bash tests/test_claude_dispatch.sh
#   DISPATCH_SRC=/path/to/a/modified/copy bash tests/test_claude_dispatch.sh   # does a broken copy turn them red?
# free, sleep, claude, systemd-run, systemctl, loginctl and run-cost are fakes on PATH; logs, state, the quota
# cache and the readings file all live in a temp dir. Nothing real is started or scheduled.
set -u
HERE="$(dirname "$(readlink -f "$0")")"
SRC="${DISPATCH_SRC:-$HERE/../bin/claude-dispatch}"
LIBDIR="$(readlink -f "$HERE/../lib")"
ORIG_PATH="$PATH"; REAL_SLEEP="$(type -P sleep)"; export REAL_SLEEP
PASS=0; FAIL=0; TMPS=()
trap 'rm -rf "${TMPS[@]}"' EXIT
ok()    { PASS=$((PASS+1)); echo "ok   $1"; }
bad()   { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

setup() {
  local v
  for v in $(compgen -e | grep -E '^(DISPATCH_|QUOTA_|RUN_COST_)'); do unset "$v"; done
  unset RESTART_COUNT
  T=$(mktemp -d); TMPS+=("$T"); mkdir -p "$T/bin" "$T/log" "$T/state" "$T/work" "$T/alive"
  echo "Task" > "$T/spec.md"
  # free: one reading per line in $T/avail, one line used up per call (the last one stays)
  cat > "$T/bin/free" <<'X'
#!/usr/bin/env bash
f="$FAKE/avail"; v=$(head -1 "$f"); [ "$(wc -l < "$f")" -gt 1 ] && sed -i 1d "$f"
echo "              total        used        free      shared  buff/cache   available"
echo "Mem:           3900        2000         500          10        1400        $v"
X
  printf '#!/usr/bin/env bash\necho "$@" >> "$FAKE/sleeps"\n' > "$T/bin/sleep"
  cat > "$T/bin/claude" <<'X'
#!/usr/bin/env bash
touch "$FAKE/claude-ran"; printf '%s\n' "$@" > "$FAKE/claude.argv"; pwd > "$FAKE/claude.cwd"
echo "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS-unset}" > "$FAKE/claude.bgwait"
[ -n "${FAKE_LEDGER_LINE:-}" ] && echo "$FAKE_LEDGER_LINE" >> "${FAKE_LEDGER:-$FAKE/ledger.md}"
[ -n "${FAKE_CLAUDE_QUOTA:-}" ] && "$FAKE/mkcache" "$FAKE_CLAUDE_QUOTA" 0
[ -n "${FAKE_CLAUDE_SLEEP:-}" ] && "$REAL_SLEEP" "$FAKE_CLAUDE_SLEEP"
[ -n "${FAKE_CLAUDE_OUT:-}" ] && echo "$FAKE_CLAUDE_OUT"
echo done
exit "${FAKE_CLAUDE_RC:-0}"
X
  printf '#!/usr/bin/env bash\necho "[cost] sid=$1 fake"\n' > "$T/bin/run-cost"
  printf '#!/usr/bin/env bash\necho "$1" >> "$FAKE/notified"\n' > "$T/bin/notify-fake"
  printf '#!/usr/bin/env bash\necho "${FAKE_LINGER:-yes}"\n' > "$T/bin/loginctl"
  # mkcache <5-hour window %> <reading age in seconds>: writes the fake quota cache (fake claude rewrites it mid-run)
  cat > "$T/mkcache" <<'X'
#!/usr/bin/env bash
python3 -c "import json,time,sys; json.dump({'cachedUsageUtilization':{'fetchedAtMs':int(time.time()*1000)-int(sys.argv[3])*1000,'utilization':{'five_hour':{'utilization':int(sys.argv[2]),'resets_at':'2099-01-01T00:00:00+00:00'}}}},open(sys.argv[1],'w'))" "$FAKE/cache.json" "$1" "$2"
X
  chmod +x "$T/mkcache"; FAKE="$T" "$T/mkcache" "${FAKE_CACHE_PCT:-10}" "${FAKE_CACHE_AGE_S:-0}"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$FAKE/systemd-run.argv"\n' > "$T/bin/systemd-run"
  # systemctl: $T/alive/<unit> holds how many more times that unit counts as running; no file = not running
  cat > "$T/bin/systemctl" <<'X'
#!/usr/bin/env bash
for a in "$@"; do f="$FAKE/alive/$a"; [ -f "$f" ] || continue
  n=$(cat "$f"); [ "$n" -gt 0 ] && { echo "$a loaded active running x"; echo $((n-1)) > "$f"; }
done; exit 0
X
  chmod +x "$T/bin/"*
  export FAKE="$T" PATH="$T/bin:$ORIG_PATH" XDG_STATE_HOME="$T/xdg" \
    DISPATCH_LIB="$LIBDIR" DISPATCH_LOGDIR="$T/log" DISPATCH_STATE="$T/state" DISPATCH_POLL_SEC=7 \
    DISPATCH_RUN_COST="$T/bin/run-cost" DISPATCH_WORKDIR="$T/work" \
    QUOTA_CACHE_FILE="$T/cache.json" QUOTA_REFRESH_CMD=true QUOTA_READINGS_FILE="$T/readings.jsonl"
}
logtext() { cat "$T/log/"*.log 2>/dev/null; }
ends() { grep -h '^\[dispatch:end\]' "$T/log/"*.log 2>/dev/null; }
end_is() {   # $1 = name, $2 = outcome, $3 = rc: exactly one marker for that name, and it's this one
  [ "$(ends | grep -c "^\[dispatch:end\] $1 ")" -eq 1 ] && ends | grep -qE "^\[dispatch:end\] $1 $2 rc=$3 [0-9-]{10} [0-9:]{8}$"
}
A() { cat "$T/systemd-run.argv" 2>/dev/null; }

# —— memory ——
setup; echo 3000 > "$T/avail"
bash "$SRC" --run t1 "$T/spec.md" 1 >/dev/null 2>&1; rc=$?
check "enough memory: starts at once"                 '[ $rc -eq 0 ] && [ -e "$T/claude-ran" ] && ! grep -qx 300 "$T/sleeps" 2>/dev/null'
check "a normal end removes the start mark"           '[ ! -e "$T/state/t1.starts" ]'

setup; printf '400\n600\n2500\n' > "$T/avail"
bash "$SRC" --run t2 "$T/spec.md" 1 >/dev/null 2>&1; rc=$?
check "low memory: waits, then starts"                '[ $rc -eq 0 ] && [ -e "$T/claude-ran" ] && [ "$(grep -cx 300 "$T/sleeps")" -eq 2 ]'
check "the waiting is logged"                         'logtext | grep -q "low on memory"'

setup; echo 300 > "$T/avail"
bash "$SRC" --run t3 "$T/spec.md" 1 >/dev/null 2>&1; rc=$?
check "never enough: 6 waits, no start, rc=75"        '[ $rc -eq 75 ] && [ ! -e "$T/claude-ran" ] && [ "$(grep -cx 300 "$T/sleeps")" -eq 6 ]'
check "giving up is logged"                           'logtext | grep -q "giving up rc=75"'
check "...with a by-hand command that goes back to the workdir" 'logtext | grep -qF "By hand: cd $T/work && "'

# —— killed, then restarted by systemd ——
setup; echo 3000 > "$T/avail"; FAKE_CLAUDE_RC=137 bash "$SRC" --run t4 "$T/spec.md" 1 >/dev/null 2>&1; rc=$?
check "claude killed by a signal: non-zero exit so systemd restarts" '[ $rc -eq 137 ] && [ -e "$T/state/t4.starts" ]'
bash "$SRC" --run t4 "$T/spec.md" 1 >/dev/null 2>&1
check "the restart logs that the previous start was killed" 'logtext | grep -q "start 2 (previous start was killed)"'

setup; echo 3000 > "$T/avail"; RESTART_COUNT=2 bash "$SRC" --run t5 "$T/spec.md" 1 >/dev/null 2>&1
check "\$RESTART_COUNT wins when systemd sets it"      'logtext | grep -q "start 3 (previous start was killed)"'

setup; echo 3000 > "$T/avail"; bash "$SRC" --run t6 "$T/spec.md" 1 >/dev/null 2>&1
check "a first start doesn't claim a previous kill"   '! logtext | grep -q "previous start was killed"'

setup; echo 3000 > "$T/avail"; echo 2 > "$T/state/t11.starts"
FAKE_CLAUDE_RC=137 bash "$SRC" --run t11 "$T/spec.md" 1 >/dev/null 2>&1
check "third kill: logs that systemd won't restart it" 'logtext | grep -q "won.t restart"'

# —— the launcher ——
setup; bash "$SRC" t7 "$T/spec.md" >/dev/null 2>&1
check "unit restarts on failure"                      'A | grep -qx "Restart=on-failure"'
check "unit restarts after 2 minutes"                 'A | grep -qx "RestartSec=120"'
check "unit restarts at most 3 starts..."             'A | grep -qx "StartLimitBurst=3"'
check "...within 3 hours"                             'A | grep -qx "StartLimitIntervalSec=3h"'
check "low-memory exit 75 is never restarted"         'A | grep -qx "RestartPreventExitStatus=75"'
check "unit runs in DISPATCH_WORKDIR"                 'A | grep -qx "WorkingDirectory=$T/work"'
check "unit gets this PATH"                           'A | grep -qxF -- "--setenv=PATH=$PATH"'
check "unit gets the resolved claude"                 'A | grep -qxF -- "--setenv=DISPATCH_CLAUDE=$T/bin/claude"'
check "unit gets absolute log and state dirs"         'A | grep -qxF -- "--setenv=DISPATCH_LOGDIR=$T/log" && A | grep -qxF -- "--setenv=DISPATCH_STATE=$T/state"'

setup; mkdir "$T/elsewhere"; (cd "$T/elsewhere" && unset DISPATCH_WORKDIR && bash "$SRC" t7b "$T/spec.md" >/dev/null 2>&1)
check "without DISPATCH_WORKDIR the unit runs where you dispatched from" 'A | grep -qx "WorkingDirectory=$T/elsewhere"'

setup; DISPATCH_MODEL=claude-sonnet-5 SECRET_TOKEN=s3cret ANTHROPIC_API_KEY=sk-test CLAUDE_CODE_OAUTH_TOKEN=oat-test \
  bash "$SRC" t8 "$T/spec.md" >/dev/null 2>&1
check "DISPATCH_* settings are forwarded"             'A | grep -qx -- "--setenv=DISPATCH_MODEL=claude-sonnet-5"'
check "nothing else from the environment is"          '! A | grep -qE "s3cret|sk-test|oat-test"'

setup; echo "ANTHROPIC_API_KEY=sk-test" > "$T/env"; DISPATCH_ENV_FILE="$T/env" bash "$SRC" t9 "$T/spec.md" >/dev/null 2>&1
check "DISPATCH_ENV_FILE becomes EnvironmentFile=, contents stay out" 'A | grep -qx "EnvironmentFile=$T/env" && ! A | grep -q sk-test'
setup; DISPATCH_ENV_FILE="$T/nope" bash "$SRC" t9b "$T/spec.md" >/dev/null 2>&1; rc=$?
check "a missing DISPATCH_ENV_FILE refuses to dispatch" '[ $rc -eq 2 ] && [ ! -e "$T/systemd-run.argv" ]'

setup; bash "$SRC" --dry-run t10 "$T/spec.md" > "$T/dry.out" 2>&1
check "--dry-run prints the command and starts nothing" '[ ! -e "$T/systemd-run.argv" ] && grep -q "systemd-run --user --quiet --unit=dispatch-t10" "$T/dry.out" && grep -q "Restart=on-failure" "$T/dry.out"'

setup; FAKE_LINGER=no bash "$SRC" t12 "$T/spec.md" 2> "$T/err" >/dev/null
check "lingering off: the launcher says so"           'grep -q "lingering is off" "$T/err"'

setup; echo 1 > "$T/alive/dispatch-t13.service"; bash "$SRC" t13 "$T/spec.md" >/dev/null 2>&1; rc=$?
check "a name that is still running can't be dispatched again" '[ $rc -eq 1 ] && [ ! -e "$T/systemd-run.argv" ]'
setup; bash "$SRC" "bad name" "$T/spec.md" >/dev/null 2>&1; rc=$?
check "names: letters, digits, dashes"                '[ $rc -eq 2 ] && [ ! -e "$T/systemd-run.argv" ]'
setup; echo 2 > "$T/state/t14.starts"; bash "$SRC" t14 "$T/spec.md" >/dev/null 2>&1
check "a new dispatch starts counting from 1 again"   '[ ! -e "$T/state/t14.starts" ]'

# —— what claude is started with ——
setup; echo 3000 > "$T/avail"; bash "$SRC" --run s1 "$T/spec.md" 1 >/dev/null 2>&1
SID=$(grep -A1 -x -- --session-id "$T/claude.argv" | tail -1)
check "claude gets a fresh --session-id"              '[[ "$SID" =~ ^[0-9a-f-]{36}$ ]]'
check "the log has the sid"                           'logtext | grep -q "sid=$SID"'
check "the cost line for that sid lands in the log"   'logtext | grep -qF "[cost] sid=$SID fake"'
check "claude runs in DISPATCH_WORKDIR"               '[ "$(cat "$T/claude.cwd")" = "$T/work" ]'
check "background-wait ceiling is off"                '[ "$(cat "$T/claude.bgwait")" = 0 ]'
check "no DISPATCH_MODEL: no --model"                 '! grep -qx -- --model "$T/claude.argv"'
check "default permission flag"                       'grep -qx -- --dangerously-skip-permissions "$T/claude.argv"'
check "rules without a ledger: foreground waits ≤ 4 minutes" 'grep -q "each wait ≤ 4 minutes" "$T/claude.argv"'
check "rules without a ledger: no DONE/STOPPED demand"        '! grep -qE "DONE|STOPPED" "$T/claude.argv"'

setup; echo 3000 > "$T/avail"
DISPATCH_MODEL=claude-sonnet-5 DISPATCH_PERMISSION_FLAGS="--permission-mode acceptEdits" bash "$SRC" --run s2 "$T/spec.md" 1 >/dev/null 2>&1
check "DISPATCH_MODEL becomes --model"                'grep -A1 -x -- --model "$T/claude.argv" | tail -1 | grep -qx claude-sonnet-5'
check "DISPATCH_PERMISSION_FLAGS replaces the default" 'grep -qx -- --permission-mode "$T/claude.argv" && grep -qx acceptEdits "$T/claude.argv" && ! grep -q dangerously "$T/claude.argv"'
setup; echo 3000 > "$T/avail"; DISPATCH_PERMISSION_FLAGS="" bash "$SRC" --run s3 "$T/spec.md" 1 >/dev/null 2>&1
check "DISPATCH_PERMISSION_FLAGS set but empty: no flags" '[ -e "$T/claude-ran" ] && ! grep -q -- "--dangerously\|--permission" "$T/claude.argv"'

# —— the ledger ——
setup; echo 3000 > "$T/avail"; printf 'Ledger: `%s`\n' "$T/ledger.md" > "$T/spec.md"
FAKE_LEDGER_LINE="- 17:09 DONE" bash "$SRC" --run l1 "$T/spec.md" 1 >/dev/null 2>&1
check "DONE with a time counts as the end, no resume"  'logtext | grep -q "finished rc=0" && ! logtext | grep -q "resuming in place" && end_is l1 done 0'
check "rules with a ledger: name it and ask for \`date +%H:%M\`" 'grep -qF "$T/ledger.md" "$T/claude.argv" && grep -qF "\`date +%H:%M\`" "$T/claude.argv"'

setup; echo 3000 > "$T/avail"; printf 'Ledger: `ledger.md`\n' > "$T/spec.md"
FAKE_LEDGER="$T/work/ledger.md" FAKE_LEDGER_LINE="- 17:09 DONE" bash "$SRC" --run l2 "$T/spec.md" 1 >/dev/null 2>&1
check "a relative ledger path is relative to DISPATCH_WORKDIR" 'end_is l2 done 0 && grep -qF "$T/work/ledger.md" "$T/claude.argv"'

setup; echo 3000 > "$T/avail"; mkdir "$T/home"; printf 'Ledger: `~/ledger.md`\n' > "$T/spec.md"
HOME="$T/home" FAKE_LEDGER="$T/home/ledger.md" FAKE_LEDGER_LINE="- DONE" bash "$SRC" --run l3 "$T/spec.md" 1 >/dev/null 2>&1
check "~/ in the ledger path is \$HOME"                'end_is l3 done 0'

setup; echo 3000 > "$T/avail"; printf 'Ledger: `%s`\n' "$T/ledger.md" > "$T/spec.md"
FAKE_LEDGER_LINE="- 17:09 not DONE yet" DISPATCH_MAX_RESUMES=1 bash "$SRC" --run l4 "$T/spec.md" 1 >/dev/null 2>&1
check "a line that merely mentions DONE isn't an ending" 'logtext | grep -q "resuming in place" && end_is l4 incomplete 0'
check "the resume tells claude what happened"         'grep -q "previous run exited before writing its ending" "$T/claude.argv"'

# —— the quota gates ——
setup; FAKE_CACHE_AGE_S=3600 setup; echo 3000 > "$T/avail"
FAKE_CLAUDE_SLEEP=3 DISPATCH_NOTIFY="$T/bin/notify-fake" bash "$SRC" --run q1 "$T/spec.md" 1 >/dev/null 2>&1; rc=$?
check "in-run gate can't read the quota 3 times: notifies once, keeps going" \
  '[ $rc -eq 0 ] && [ "$(grep -c "can.t read usage" "$T/notified")" -eq 1 ] && logtext | grep -q "finished rc=0"'
check "start gate can't read the quota: logs it, starts anyway" 'logtext | grep -q "start gate can.t read the quota"'
check "every reading lands in the readings file"     '[ "$(wc -l < "$T/readings.jsonl")" -ge 4 ]'

FAKE_CACHE_PCT=75 setup; echo 3000 > "$T/avail"; echo "90 $(( $(date +%s) + 600 ))" > "$T/state/gate.override"
bash "$SRC" --run q2 "$T/spec.md" 1 >/dev/null 2>&1
check "gate.override raises the start line until it expires" '[ -e "$T/claude-ran" ] && end_is q2 done 0'
FAKE_CACHE_PCT=75 setup; echo 3000 > "$T/avail"; echo "90 $(( $(date +%s) - 1 ))" > "$T/state/gate.override"
bash "$SRC" --run q3 "$T/spec.md" 1 >/dev/null 2>&1
check "an expired gate.override is ignored"          '[ ! -e "$T/claude-ran" ] && end_is q3 held 0'

FAKE_CACHE_PCT=75 setup; echo 3000 > "$T/avail"; DISPATCH_QUOTA=off bash "$SRC" --run q4 "$T/spec.md" 1 >/dev/null 2>&1
check "DISPATCH_QUOTA=off: no gate, no readings"      '[ -e "$T/claude-ran" ] && end_is q4 done 0 && [ ! -e "$T/readings.jsonl" ]'

# —— one end marker per run, for every way out ——
setup; echo 3000 > "$T/avail"; bash "$SRC" --run e1 "$T/spec.md" 1 >/dev/null 2>&1
check "outcome: done"                                 'end_is e1 done 0'
setup; echo 3000 > "$T/avail"; printf 'Ledger: `%s`\n' "$T/ledger.md" > "$T/spec.md"
FAKE_LEDGER_LINE="- 00:50 STOPPED: the premise is false" bash "$SRC" --run e2 "$T/spec.md" 1 >/dev/null 2>&1
check "outcome: stopped (with a time, no resume)"     'end_is e2 stopped 0 && ! logtext | grep -q "resuming in place"'
setup; echo 3000 > "$T/avail"; printf 'Ledger: `%s`\n' "$T/ledger.md" > "$T/spec.md"
DISPATCH_MAX_RESUMES=1 bash "$SRC" --run e3 "$T/spec.md" 1 >/dev/null 2>&1
check "outcome: incomplete (resumes used up)"         'end_is e3 incomplete 0'
setup; echo 3000 > "$T/avail"; FAKE_CLAUDE_RC=1 bash "$SRC" --run e4 "$T/spec.md" 1 >/dev/null 2>&1
check "outcome: failed"                               'end_is e4 failed 1'
setup; echo 3000 > "$T/avail"; FAKE_CLAUDE_RC=137 bash "$SRC" --run e5 "$T/spec.md" 1 >/dev/null 2>&1
check "outcome: killed (claude got a signal)"         'end_is e5 killed 137'
setup; echo 3000 > "$T/avail"; FAKE_CLAUDE_SLEEP=5 bash "$SRC" --run e6 "$T/spec.md" 1 >/dev/null 2>&1 & BP=$!
for _ in $(seq 40); do [ -e "$T/claude-ran" ] && break; "$REAL_SLEEP" 0.1; done; "$REAL_SLEEP" 0.3; kill -TERM $BP; wait $BP; rc=$?
check "outcome: killed (the runner got TERM, as from systemctl stop)" '[ $rc -eq 143 ] && end_is e6 killed 143'
setup; echo 3000 > "$T/avail"; FAKE_CLAUDE_QUOTA=90 FAKE_CLAUDE_SLEEP=12 bash "$SRC" --run e7 "$T/spec.md" 1 >/dev/null 2>&1
check "outcome: paused (in-run gate), resume scheduled" 'end_is e7 paused 0 && logtext | grep -q "paused mid-run" && A | grep -q "^--unit=dispatch-e7-pause"'
setup; echo 3000 > "$T/avail"
FAKE_CLAUDE_RC=1 FAKE_CLAUDE_OUT="You've hit your limit · resets 3am (UTC)" bash "$SRC" --run e8 "$T/spec.md" 1 >/dev/null 2>&1
check "outcome: rate-limited, try 2 scheduled"        'end_is e8 rate-limited 0 && logtext | grep -q "hit the usage limit" && A | grep -qx -- "--unit=dispatch-e8-retry1" && [ "$(A | tail -1)" = 2 ]'
FAKE_CACHE_PCT=75 setup; echo 3000 > "$T/avail"; bash "$SRC" --run e9 "$T/spec.md" 1 >/dev/null 2>&1
check "outcome: held (start gate), start scheduled"   'end_is e9 held 0 && [ ! -e "$T/claude-ran" ] && A | grep -qx -- "--unit=dispatch-e9-hold1"'
setup; echo 300 > "$T/avail"; bash "$SRC" --run e10 "$T/spec.md" 1 >/dev/null 2>&1
check "outcome: low-memory"                           'end_is e10 low-memory 75'

# —— --after ——
setup; bash "$SRC" --after a,b-2 t20 "$T/spec.md" >/dev/null 2>&1
check "--after hands the list to the unit"            'A | grep -qx -- "--setenv=DISPATCH_AFTER=a,b-2"'
setup; bash "$SRC" --after "a;rm" t21 "$T/spec.md" >/dev/null 2>&1; rc=$?
check "--after with a bad list dispatches nothing"    '[ $rc -eq 2 ] && [ ! -e "$T/systemd-run.argv" ]'
setup; DISPATCH_AFTER=zz bash "$SRC" t21b "$T/spec.md" >/dev/null 2>&1
check "an inherited DISPATCH_AFTER isn't passed on"   '! A | grep -q DISPATCH_AFTER'
setup; echo 3000 > "$T/avail"; printf 'Ledger: `%s`\n' "$T/ledger.md" > "$T/spec.md"
echo "[dispatch:end] pa done rc=0 2026-10-01 23:00:00" > "$T/log/2026-10-01-pa.log"   # marker in the previous day's file
echo "[dispatch:end] pb done rc=0 2026-10-02 00:10:00" > "$T/log/2026-10-02-pb.log"
echo 2 > "$T/alive/dispatch-pb.service"
FAKE_LEDGER_LINE="- 01:00 DONE" DISPATCH_AFTER=pa,pb DISPATCH_AFTER_POLL=61 bash "$SRC" --run t22 "$T/spec.md" 1 >/dev/null 2>&1
check "--after: waits while a prerequisite runs, then starts" '[ -e "$T/claude-ran" ] && [ "$(grep -cx 61 "$T/sleeps")" -eq 2 ] && end_is t22 done 0'
check "--after: the ledger notes the wait and the start" 'grep -q "waiting for pa,pb to finish" "$T/ledger.md" && grep -q "all finished, starting" "$T/ledger.md"'
setup; echo 3000 > "$T/avail"
printf '[dispatch:end] pc done rc=0 2026-10-02 00:00:00\n[dispatch:end] pc failed rc=1 2026-10-02 01:00:00\n' > "$T/log/2026-10-02-pc.log"
DISPATCH_AFTER=pc bash "$SRC" --run t23 "$T/spec.md" 1 >/dev/null 2>&1; rc=$?
check "--after: prerequisite's last run failed: no start" '[ $rc -eq 0 ] && [ ! -e "$T/claude-ran" ] && end_is t23 prereq-failed 0'
setup; echo 3000 > "$T/avail"; DISPATCH_AFTER=pd bash "$SRC" --run t24 "$T/spec.md" 1 >/dev/null 2>&1
check "--after: prerequisite never ran (no marker): no start" '[ ! -e "$T/claude-ran" ] && logtext | grep -q "pd (no end marker)"'
setup; echo 3000 > "$T/avail"; echo 99 > "$T/alive/dispatch-pe.service"
DISPATCH_AFTER=pe DISPATCH_AFTER_MAX_H=0 bash "$SRC" --run t25 "$T/spec.md" 1 >/dev/null 2>&1
check "--after: gives up after DISPATCH_AFTER_MAX_H"  '[ ! -e "$T/claude-ran" ] && logtext | grep -q "still running after 0 h"'
setup; echo 3000 > "$T/avail"; echo "[dispatch:end] pf done rc=0 2026-10-02 00:00:00" > "$T/log/2026-10-02-pf.log"
DISPATCH_AFTER=pf FAKE_CLAUDE_RC=1 FAKE_CLAUDE_OUT="You've hit your limit · resets 3am (UTC)" bash "$SRC" --run t26 "$T/spec.md" 1 >/dev/null 2>&1
check "--after: a retry scheduled after the wait doesn't wait again" 'A | grep -qx -- "--unit=dispatch-t26-retry1" && ! A | grep -q DISPATCH_AFTER'

# —— --last ——
setup; printf '[dispatch:end] px done rc=0 2026-10-02 00:00:00\n[dispatch:end] px failed rc=1 2026-10-02 01:00:00\n' > "$T/log/2026-10-02-px.log"
out=$(bash "$SRC" --last px); rc=$?
check "--last prints the latest marker"               '[ $rc -eq 0 ] && [ "$out" = "[dispatch:end] px failed rc=1 2026-10-02 01:00:00" ]'
out=$(bash "$SRC" --last nobody); rc=$?
check "--last with no marker: exit 1, no output"      '[ $rc -eq 1 ] && [ -z "$out" ]'

# —— hooks ——
setup; echo 3000 > "$T/avail"; printf 'Ledger: `%s`\n' "$T/ledger.md" > "$T/spec.md"
FAKE_LEDGER_LINE="- 01:00 DONE" DISPATCH_WRAPUP='echo "$DISPATCH_NAME $DISPATCH_OUTCOME $DISPATCH_LEDGER" > "$FAKE/wrapup.out"; echo hello' \
  bash "$SRC" --run h1 "$T/spec.md" 1 >/dev/null 2>&1
check "wrapup runs after done, with name/outcome/ledger" '[ "$(cat "$T/wrapup.out")" = "h1 done $T/ledger.md" ] && logtext | grep -q "wrapup rc=0: hello"'
check "wrapup runs before the end marker"             'logtext | awk "/wrapup rc=/{w=NR} /^\\[dispatch:end\\]/{e=NR} END{exit !(w && e && w<e)}"'
setup; echo 3000 > "$T/avail"; FAKE_CLAUDE_RC=1 DISPATCH_WRAPUP='touch "$FAKE/wrapup.out"' bash "$SRC" --run h2 "$T/spec.md" 1 >/dev/null 2>&1
check "wrapup doesn't run after a failure"            '[ ! -e "$T/wrapup.out" ] && end_is h2 failed 1'
setup; echo 3000 > "$T/avail"; DISPATCH_WRAPUP='echo oops; exit 3' bash "$SRC" --run h3 "$T/spec.md" 1 >/dev/null 2>&1
check "a failing wrapup is logged and changes nothing" 'logtext | grep -q "wrapup rc=3: oops" && end_is h3 done 0'
setup; echo 3000 > "$T/avail"; DISPATCH_NOTIFY="$T/bin/notify-fake" bash "$SRC" --run h4 "$T/spec.md" 1 >/dev/null 2>&1
check "notify gets the outcome at the end"            'grep -q "^dispatch h4: done (rc=0)" "$T/notified"'
setup; echo 3000 > "$T/avail"; DISPATCH_NOTIFY=false bash "$SRC" --run h5 "$T/spec.md" 1 >/dev/null 2>&1
check "a failing notify is logged"                    'logtext | grep -q "notify failed" && end_is h5 done 0'

echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
