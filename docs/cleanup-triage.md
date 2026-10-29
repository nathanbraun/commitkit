# cleanup triage

started 2026-10-27 from three read-only sweeps (desktop frontend, desktop rust,
server) + the oct 26 goal investigation. QUICK = mechanical. STRUCTURAL =
needs a call. build estimates are claude code wall-clock.

## done 2026-10-27

- settlement: fixed 24h grace replaced client-liveness deferral; misses show
  as failed on read (record-verdicts) and in the cron; schedule checks frozen
  at deadline; stale schedule "passed" fixed both sides
- removed: /api/user/reset + debug tab, templates tab (projects → settings),
  timer-assignment subsystem, /api/violations/timer, /api/requirements, timer
  templates (desktop schema v34, cli in lockstep)
- server quick batch: dead routes, tz bug in /checkin/status, shared
  completion count, asyncHandler, timing-safe cron auth, risky db scripts gone
- desktop quick batch: launch-at-login status, replace_local_data template
  id, dead commands/components/deps, shared formatters, authed_api

## deploy checklist for the above (order matters)

- rebuild + reinstall desktop (re-grant screen recording), then
  `cargo install --path commitkit-cli` right after — v34 schema; an old cli
  against a v34 db fails its insert
- then push commitkit-server — old desktops 404 on /api/timer-templates and
  their startup pull fails
- after the server deploys: apply drizzle 0036 (liveness) + 0037
  (timer_templates) by hand

## done 2026-10-29

- per-check `timerListIds` removed: a session blocks its project's lists only
  (desktop = cli). closes the local-int leak in prod goal configs; the stale
  key stays in old configs, unread
- desktop limits are goals: `usage_limit` check type + `/usage-report` route
  (immediate charge via shared `domain/breach.ts`); desktop limit stack gone
  (templates/commitments/violations tables, violation_checker, the limit form,
  check-in + violation sync, violations tab). schema v35, cli unchanged

- projects on the server: rule edits follow akrasia (directories: add now,
  remove waits), goal timer checks by project uuid + per-project counts
  (`timerCountsPerProject`), list ids kept stable across sign-in so project
  list attachments survive. desktop v36, cli 36. backfill 0043 by hand after
  the desktop uploads its projects

## bugs still open

- flaky tests seen once each: routes-evaluate-session (neutral-domains),
  routes-plan-distraction-breach (socket hang up)

## STRUCTURAL — agreed, next

- server decides every edit (10-min window / 48h akrasia / stricter-anytime);
  clients display only. removes the two client copies of akrasia logic and
  client-computed pending_removals. folds in:
  - two pull-from-server paths (`replace_local_data` vs
    `upsert_*_from_server`), already diverged once
  - commitments sync by local int `client_id` → `commitments.uuid`

## STRUCTURAL — recommend, not yet agreed

- desktop/cli duplication — session eval, eval-rules builder, worktree
  baseline, neutral-domain normalization, completion report + 7-day resync.
  the "two sites must agree" surfaces. shared builder in commitkit-eval or a
  small crate. a session; gate: e2e both apps
- third copy of the goal timer-count rule lives in desktop goal-detail.tsx
  (server copies now shared)

## your call / later
- usage_limit check edits classify as weaken whole-check (a tightening waits
  48h too) — per-field directions in `apply-edit.ts` when it matters
- move mobile + distractions onto usage_limit checks, then delete the
  server's screen-time stack (commitments/templates/check_ins/mirror)

- stake bounds for goals + verifications (only >= 0 today) — left as is
- schema renames (`commitments`, `legacy_instance_id`, stake units) — leave
  until something touches them
- schedule-check slot deleted *after* the deadline still fails the goal (only
  creation is frozen)
- shared `<Modal>` shell (24 hand-rolled, none handles esc)
- split commands.rs / db_operations.rs / commitment-form-dialog after the
  deletions shrank them
- monitor reports screen-time usage directly (desktop fully optional)
- test gaps: webhooks, payment, auth, lists, plan-periods
- dollar formatters not consolidated (mixed toFixed(0)/(2) output)
- confirm railway builder (toml pins nixpacks; docs say railpack)
- archive/delete `commitkit-web/` (last commit feb)
