# claude-dispatch

Run Claude Code tasks (`claude -p`) unattended on a Linux machine. Each run is detached from your terminal, restarted if it gets killed, held back when your 5-hour usage window is nearly full, and ends with one line that says how it went.

```sh
claude-dispatch bump-deps specs/bump-deps.md
# dispatched: dispatch-bump-deps · log ~/.local/state/claude-dispatch/logs/2026-10-14-bump-deps.log · status: systemctl --user status dispatch-bump-deps

claude-dispatch --last bump-deps
# [dispatch:end] bump-deps done rc=0 2026-10-14 03:12:40
```

It's one bash script (about 340 lines) around `systemd-run --user`, with a few helpers and a test suite.

## Why

`claude -p "…" &` in a terminal works until one of these happens, and every one of them did:

- **The terminal goes away.** Closing the editor, an SSH drop or a restart of a web IDE kills the run.
- **It gets killed early.** The OOM killer took a run in its first minute, and nothing retried it.
- **It quits early and still exits 0.** `claude -p` exits when its turn ends, and any background jobs die with it. A run that starts its real work in a background shell, ends its turn and exits looks exactly like a run that finished.
- **It eats the usage window.** A single unattended run used up the whole 5-hour window on a subscription plan, and the interactive session was locked out until the reset.
- **It hits the usage limit at night.** The run stops with "you've hit your limit · resets 3am" and nobody restarts it at 3am.
- **Nobody knows how it ended.** "Is it still running? Did it finish? Was it killed?" meant reading a long log.

## What it does

- **Detached runs.** Each run is a transient systemd user unit, `dispatch-<name>`. It survives closed terminals and SSH drops. With lingering enabled it also survives logging out.
- **Restarts after a kill.** If claude dies from a signal, systemd restarts it 2 minutes later, up to 3 starts in 3 hours. Before starting, the run waits up to 30 minutes for enough free memory.
- **A ledger contract.** The spec names a ledger file, and the run has to end it with `DONE` or `STOPPED: <reason>`. A run that exits 0 without writing one is resumed in place (twice at most), with a note that tells claude what happened.
- **Quota gates, for subscription plans.**
  - A run doesn't start while the 5-hour window is at or above 70%. It schedules its own start for after the reset.
  - A running job is stopped at 80% and resumed after the reset.
  - A run that hits the usage limit anyway is retried after the reset time that claude printed.
- **One end marker per run**: `[dispatch:end] <name> <outcome> rc=<rc> <time>`. `--after` uses it to chain runs, and your own scripts can grep it.
- **A cost line per claude start**: tokens and list-price cost per model. Subagent transcripts are included.
- **Hooks**: a command that gets each run's outcome, and a wrap-up step that runs after a successful run.

## Requirements

- Linux with a systemd user manager (`systemctl --user status` works). Developed on Ubuntu 24.04 with systemd 255.
- bash 4.4 or newer, python3, coreutils, and `free` (procps).
- Claude Code, logged in: `claude -p hello` works in your shell.
- Runs should survive logging out? Then run `loginctl enable-linger "$USER"`. The launcher warns you when lingering is off.

## Install

```sh
git clone https://github.com/ees85050-lab/claude-dispatch.git ~/claude-dispatch
ln -s ~/claude-dispatch/bin/claude-dispatch ~/.local/bin/
```

The script finds `lib/` and `run-cost` from its own real path, so a symlink works.

## Usage

```
claude-dispatch <name> <spec.md>                         dispatch now
claude-dispatch --after <a>[,<b>...] <name> <spec.md>    dispatch now; the run waits until a, b... are done or stopped
claude-dispatch --dry-run [--after ...] <name> <spec.md> print the systemd-run command, start nothing
claude-dispatch --list                                   dispatch units running or scheduled
claude-dispatch --last <name>                            latest end marker of <name> (exit 1 if none)
```

- **Where it runs.** The run uses the directory you dispatched from, or `DISPATCH_WORKDIR` if you set it.
- **Names** are letters, digits and dashes. A name that is still running, or that has a retry, resume or start scheduled, can't be dispatched again.
- **Logs.** Each name gets one log per day in `~/.local/state/claude-dispatch/logs/`. It holds claude's output and the dispatcher's own lines.
- **Watching a run.** Use `tail -f` on the log or `systemctl --user status dispatch-<name>`. To stop a run, use `systemctl --user stop dispatch-<name>`. Scheduled retries, resumes and starts are timers named `dispatch-<name>-retry…`, `-pause…` and `-hold…`; `--list` shows them.
- **Chaining.** `--after build-1,build-2` starts the unit now, and the unit waits for both runs to end. It goes ahead only if both ended `done` or `stopped`. If either ended any other way, or is still running after `DISPATCH_AFTER_MAX_H` hours (default 24), it gives up with `prereq-failed`.

## The spec and the ledger

A spec is a markdown file. Its whole text becomes the prompt, after a short preamble of rules. One line in the spec is special:

```
Ledger: `notes/ledgers/bump-deps.md`
```

A relative path is resolved against the working directory, and `~/` works. When a spec names a ledger:

- **The preamble** tells claude to finish only after the last line of the ledger is `- HH:MM DONE` or `- HH:MM STOPPED: <reason>`.
- **When claude exits with 0**, the dispatcher reads the last 3 lines of the ledger. If neither ending is there, the run quit early. It's started again in place with a note to read the ledger and carry on. `DISPATCH_MAX_RESUMES` sets how many times (default 2); after that the outcome is `incomplete`.
- **The dispatcher's own entries.** It adds lines starting `- HH:MM [dispatch]` while it waits, for example on `--after`.

Without a ledger, exit 0 counts as `done`.

A ledger does more than mark the end. It makes restarts cheap, because a run that was killed, paused or resumed reads how far the last one got. Ask for one line per step. [examples/spec-example.md](examples/spec-example.md) shows a complete spec.

The preamble also asks claude to wait in the foreground, with each wait at most 4 minutes. There are two reasons:

- Background jobs die when the turn ends.
- The prompt cache typically expires after 5 minutes of inactivity. A model call after a longer wait writes the whole context to the cache again.

## Outcomes

| Outcome | Meaning | What happens next |
|---|---|---|
| `done` | claude exited 0, and the ledger ends with DONE (or the spec has no ledger) | nothing |
| `stopped` | claude exited 0, and the ledger ends with `STOPPED: <reason>` | read the reason |
| `incomplete` | claude exited 0 every time, but the ledger never got an ending | read the ledger |
| `failed` | claude exited non-zero, and it wasn't a signal or a usage limit | read the log |
| `killed` | claude died from a signal, or the run was stopped | systemd restarts it after 2 min, 3 starts in 3 h at most (not after `systemctl stop`) |
| `paused` | the 5-hour window reached the pause line during the run | a resume is scheduled for 3 minutes after the reset |
| `rate-limited` | claude hit the usage limit | a retry is scheduled for 3 minutes after the reset claude printed (3 tries in all) |
| `held` | the 5-hour window was over the start line | a start is scheduled after the reset (4 holds, then it starts anyway) |
| `low-memory` | available memory stayed under `DISPATCH_MEM_MIN_MB` for 30 minutes | nothing; exit 75, which systemd doesn't restart |
| `prereq-failed` | an `--after` prerequisite didn't end done or stopped | nothing |

Every way out of a run writes exactly one marker. One case can't: if the kernel kills the dispatcher itself (not claude), no marker is written. Then `--last` still shows the previous run's line, and `systemctl --user status dispatch-<name>` tells you what happened.

If scheduling a retry, resume or start fails, the outcome stays the same. The log line just above the marker then has the command to run by hand. It changes to the working directory first; set the same `DISPATCH_*` variables before you run it.

## Quota gates

On a subscription plan, everything on the account shares one 5-hour usage window: your interactive sessions and every dispatched run. The gates keep unattended work from using all of it.

| Setting | Default | |
|---|---|---|
| `DISPATCH_START_MAX` | 70 | don't start at or above this % of the 5-hour window |
| `DISPATCH_PAUSE_AT` | 80 | stop a running job at this %, and resume after the reset |
| `DISPATCH_POLL_SEC` | 300 | how often a running job checks |

**How the window is read.** Claude Code keeps what its `/usage` screen shows in `~/.claude.json`, under `cachedUsageUtilization`. That cache is **undocumented** and may change in any release. The gates refresh it by running `claude -p /usage`, a local command that makes no model call. The start gate refreshes it when it's older than `QUOTA_REFRESH_MIN` minutes (default 20); a running job's gate refreshes it before every check.

**When the cache can't be read.** If it's missing, unreadable or stale, the gates **fail open**: the run starts or carries on. After 3 misses in a row during a run, the notify hook gets a message. Every reading is appended to `~/.local/state/claude-dispatch/quota-readings.jsonl`, so you can check the gates against what really happened.

- **Using an API key instead of a subscription?** There's no 5-hour window, so set `DISPATCH_QUOTA=off`.
- **Need more room for a while?** Raise both lines until a given time:
  ```sh
  echo "95 $(date -d '+2 hours' +%s)" > ~/.local/state/claude-dispatch/state/gate.override
  ```
- **Hitting the usage limit anyway.** claude prints something like `resets 3am (Europe/Berlin)`. The retry is scheduled for that time plus 3 minutes. The time is read in the machine's local time zone; the zone name in brackets isn't parsed. If the time can't be parsed at all, the retry is in 5 hours.

## Configuration

All settings are environment variables. They're read when you dispatch and handed to the unit explicitly, because systemd units don't inherit your shell's environment. On top of the systemd user manager's own environment (which has `HOME`, but none of your shell's exports), the unit gets exactly these: `PATH`, every exported `DISPATCH_*`, `QUOTA_*` and `RUN_COST_*` variable, `CLAUDE_CONFIG_DIR` and `XDG_STATE_HOME`. Retries and resumes get the same set.

| Variable | Default | |
|---|---|---|
| `DISPATCH_WORKDIR` | current directory | where claude runs |
| `DISPATCH_MODEL` | Claude Code's default | passed as `--model` |
| `DISPATCH_PERMISSION_FLAGS` | `--dangerously-skip-permissions` | split on spaces; set it empty for no flags. See [Safety](#safety) |
| `DISPATCH_CLAUDE` | `claude` on PATH | path to the claude binary |
| `DISPATCH_ENV_FILE` | none | a file of `KEY=value` lines; systemd loads it into the unit (`EnvironmentFile=`) |
| `DISPATCH_QUOTA` | `on` | `off` turns off both quota gates |
| `DISPATCH_MEM_MIN_MB` | 1000 | minimum available memory to start |
| `DISPATCH_MAX_RESUMES` | 2 | in-place resumes when the ledger has no ending |
| `DISPATCH_AFTER_MAX_H`, `DISPATCH_AFTER_POLL` | 24, 60 | `--after`: give up after this many hours; seconds between checks |
| `DISPATCH_NOTIFY`, `DISPATCH_WRAPUP` | none | see [Hooks](#hooks) |
| `DISPATCH_LOGDIR`, `DISPATCH_STATE` | `~/.local/state/claude-dispatch/{logs,state}` | |
| `QUOTA_REFRESH_MIN` | 20 | refresh the usage cache when it's older than this |
| `QUOTA_CACHE_FILE`, `QUOTA_READINGS_FILE`, `QUOTA_REFRESH_CMD` | | mainly for tests |
| `RUN_COST_PROJECTS`, `RUN_COST_LEDGER`, `RUN_COST_PRICES` | | see [Cost](#cost) |

**Secrets.** Anything passed to the unit as an environment variable shows up in `systemctl --user show`. API keys and tokens therefore don't belong in exported `DISPATCH_*` variables. Put them in a file only you can read (`chmod 600`) and point `DISPATCH_ENV_FILE` at it, so systemd reads the file itself.

## Hooks

**`DISPATCH_NOTIFY`** is a command. The message is added as its last argument. It runs at the end of every run (`dispatch <name>: <outcome> (rc=N) · log <path>`), and also when a running job's quota gate goes blind. It has a 30-second limit, and failures are logged. Two examples:

```sh
export DISPATCH_NOTIFY='notify-send claude-dispatch'
export DISPATCH_NOTIFY='curl -s -o /dev/null ntfy.sh/your-topic -d'
```

**`DISPATCH_WRAPUP`** is a shell snippet that runs after a `done` or `stopped` run, in the working directory, before the end marker is written. It gets `DISPATCH_NAME`, `DISPATCH_LOG`, `DISPATCH_LEDGER` and `DISPATCH_OUTCOME`, and it has a 5-minute limit. Its exit code and the first 500 characters of its output go into the log. It never changes the outcome. Use it for checks you'd otherwise forget, such as `make lint`, `git status --short` or regenerating an index.

## Cost

When each claude start exits, the log gets a line like this:

```
[cost] sid=4f3c… list-price total $3.41 (incl. 2 subagent files): opus-5-5 41 calls in=… out=… cr=… cw=… $2.95; sonnet-5 12 calls … $0.46
```

The same numbers are appended as JSON to `~/.local/state/claude-dispatch/run-cost.jsonl`.

On a subscription plan this is a yardstick: what the run would cost at API list prices, for comparing runs. It's not a bill. The prices live in `bin/run-cost` and date from 2026-10, so check them. A model that isn't in the table is reported as `unpriced` and left out of the total; it is never counted as $0. To add or correct prices, point `RUN_COST_PRICES` at a JSON file in this form:

```json
{"some-new-model": [3, 15, 0.3, 3.75, 6]}
```

The five numbers are USD per million tokens: input, output, cache read, 5-minute cache write and 1-hour cache write.

`run-cost <session-id>` also works on its own, for any Claude Code session.

## Safety

By default, runs use `--dangerously-skip-permissions`, because nobody is there to approve tool calls. That means a run can do anything your user account can do. Some ways to limit that:

- Run it under a dedicated user, in a VM, or in a container.
- Point it at a working directory under version control that you can afford to lose.
- Set `DISPATCH_PERMISSION_FLAGS` to something narrower, such as `--permission-mode acceptEdits`, and put an allow-list in the project's `.claude/settings.json`. In `-p` mode, a tool call that isn't allowed is denied and the run carries on without it.

## Tests

```sh
bash tests/test_claude_dispatch.sh     # 82 checks, about 10 s
python3 tests/test_run_cost.py
```

The tests use fake `systemd-run`, `systemctl`, `claude`, `free` and `sleep` binaries on PATH, so nothing real gets started or scheduled. `DISPATCH_SRC=path/to/copy bash tests/test_claude_dispatch.sh` runs the suite against another copy of the script. Use it to check that removing a feature makes its test fail.

## Limitations

- Linux and systemd only.
- The quota gates depend on an undocumented cache file. A Claude Code update can blind them; they fail open and send a notification.
- The reset time in a rate-limit message is only parsed in the English formats Claude Code prints now.

## License

MIT

---

## 中文简介

在 Linux 上无人值守地跑 Claude Code（`claude -p`）任务：用 `systemd-run --user` 脱离终端；被信号杀掉由 systemd 两分钟后重来；任务说明里指定一份台账，没写 DONE／STOPPED 就退出的会被就地续跑；订阅用户的五小时额度过线时不起跑、跑到一半让路，重置后自己接着跑；每趟结束写一行结局标记，`--after` 靠它串联；每次启动记一行按模型的 token 和挂牌价花费。用法和配置见上文。
