---
description: Review uncommitted changes, group them into clean logical commits (verified), and push once to origin/main.
argument-hint: "[optional grouping hints, type/scope, or an explicit commit message]"
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git log:*), Bash(git restore:*), Bash(bundle exec rubocop:*), Bash(bundle exec ruby -Itest:*), Read, Edit
---

# /ship — clean commits + push to main

Run a predictable, low-noise commit workflow for this Ruby CLI project, then push once
to `origin/main`. This command **intentionally commits directly to `main`** —
that is its purpose; do not branch.

Optional user guidance (grouping hints, a `type(scope)`, or an explicit commit
message): `$ARGUMENTS`

## What "clean commits" means here

- **Atomic:** each commit is one isolated logical change.
- **Descriptive:** subject is `type(scope): summary` in imperative voice
  (`feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `style`, `perf`, `ci`,
  `build`, `revert`). Appropriate scopes for this project: `converter`, `logger`,
  `cli`, `tests`, `config`, `docs`.
- **No noise:** no WIP, no debug leftovers, no generated artifacts, no unrelated
  edits mixed in.
- **Logically grouped:** related files together; unrelated concerns split apart.

## Procedure

1. **Confirm branch.** Run `git branch --show-current`. If it is not `main`,
   STOP and tell the user (this command targets `main` by design).
2. **Survey.** `git status --short` and review diffs of every changed file.
3. **Propose a commit plan** — an ordered list of groups, each with the files
   it contains and a draft `type(scope): summary`. Rules:
   - If any `test/` files changed, they form the **first** group.
   - Never stage everything blindly. Exclude unrelated/local files (e.g. `.env`,
     log files, generated output, work that the user did not ask to ship).
   - If you detect unexpected cross-cutting or unrelated changes, **ask** before
     including them.
   - Honor any grouping hints / type / scope / message in `$ARGUMENTS`.
4. **For each group, in order:**
   a. Stage only that group's files (`git add <files>`).
   b. **Verify (gate, not a suggestion).** Run the smallest relevant check:
      - Ruby: `bundle exec rubocop <files>` and, when behaviour changed,
        `bundle exec ruby -Itest test/test_flac_to_mp3.rb`.
      - If `$ARGUMENTS` specifies a verification command, run that instead.
      - **If verification fails, fix it and re-run until green before
        committing.** Do not commit on a red check.
   c. **Commit** with the `type(scope): summary` subject (a body only if it adds
      real context). End the message with the required co-author trailer:
      `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`.
5. **Push once**, after all groups committed cleanly: `git push origin main`.

## Safety rules

- Never `--amend`, rebase, or reset to rewrite history unless explicitly asked.
- Never stage or commit secrets / `.env*` / credential keys.
- Keep commits scoped to what the user asked to ship.
- One push at the end — not per commit.

## Report back

- The ordered group plan.
- Per group: commit hash, message, files committed, verification command + result.
- The final `git push` result (the `origin/main` range, e.g. `abc123..def456`).
