# Bump dependencies and fix what breaks

Ledger: `notes/ledgers/bump-deps.md`

Read the ledger first. If it already has entries, an earlier run was cut off (killed, paused for quota,
or it quit early): continue from its last step instead of starting over.

## Task

1. Create the ledger's folder if it doesn't exist.
2. Run `npm outdated`; update every dependency within its current major version.
3. Run the test suite and fix what the update broke. Don't edit test expectations to make them pass.
4. Commit on a new branch `deps/bump`; don't push.

## Ledger

After each step, append one line: `- HH:MM <what you did, what you found>`.

## Ending

- All done: append `- HH:MM DONE`.
- A step needs a human decision (a major-version bump, a test that looks wrong):
  append `- HH:MM STOPPED: <what needs deciding>` and stop there.
