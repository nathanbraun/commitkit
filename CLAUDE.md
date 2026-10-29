# CLAUDE.md
This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Is This

CommitKit is a commitment accountability ecosystem — users set goals (productivity timers, screen time limits, habits), and the system enforces them through financial stakes via Stripe. This directory contains 7 independent projects (each with its own git repo) that work together.

Historical note: earlier there were separate `commitkit-timer` (standalone Tauri timer) and `commitkit-web` (Next.js web app for plans + AI evaluation) projects. Both were folded into `commitkit-desktop`, which now owns timer, screen-time, plans, and project features in a single Tauri app. If you see references to those old project names in commit history or stale docs, map them to `commitkit-desktop`.

## Projects

| Directory | What It Is | Stack |
|-----------|-----------|-------|
| `commitkit-desktop` | Desktop app — Goals (with AI evaluation), Limits (Goals of usage checks), productivity timers, projects. Subsumes the former `commitkit-web` and `commitkit-timer`. | Tauri 2, Next.js 16, Rust, SQLite |
| `commitkit-mobile` | Mobile app — screen time limit enforcement | React Native 0.81, Expo 54, SQLite, Stripe |
| `commitkit-server` | Backend API for mobile + desktop; owns enforcement ledger and Stripe charges | Express, Drizzle ORM, PostgreSQL, Stripe |
| `commitkit-eval` | Activity evaluation library (pure logic used by desktop + CLI) | Rust 2024 |
| `commitkit-monitor` | macOS activity monitoring daemon + app warning system | Rust 2024 |
| `commitkit-rules` | Shared builder + HTTP helpers for the monitor's `/api/domain-rules` contract. Used by desktop and CLI so both produce an identical wire format. | Rust 2024 |
| `commitkit-data` | Shared SQLite operations on the desktop's `commitkit.db` — project/list resolution, list UUID↔id translation. Used by desktop and CLI so the union of template + project lists is computed identically. | Rust 2024 |
| `commitkit-distractions` | Android app — the phone's side of Goals: phone lists, the before-distractions gate (accessibility-service warning; Continue charges), and verdicts for usage checks on phone lists. Goals are created on the desktop. | React Native 0.81, Expo 54, Kotlin |
| `commitkit-cli` | Terminal focus timer (`commit` binary) — project-scoped; runs sessions that report completions counted toward Goal timer checks; pushes rules to the monitor; evaluates via commitkit-eval. (No longer stakes individual timers — Phase 2.) | Rust 2024 |

Six projects have their own `CLAUDE.md` with detailed architecture: `commitkit-desktop`, `commitkit-mobile`, `commitkit-distractions`, `commitkit-monitor`, `commitkit-rules`, `commitkit-cli`. Read those when working in a specific project. `commitkit-server`, `commitkit-eval`, and `commitkit-data` have no sub-CLAUDE.md yet.

## Common Commands

**JS/TS projects** use **pnpm** (not npm/yarn). Rust projects use **cargo**.

### commitkit-desktop (Tauri)
```bash
pnpm tauri:dev          # Full app (frontend + Rust backend)
pnpm dev                # Next.js frontend only
pnpm build              # Next.js static export
pnpm tauri:build        # Production binary
pnpm type-check         # tsc --noEmit
pnpm test               # Vitest
pnpm test:watch         # Vitest watch mode
pnpm clear-db           # Delete local SQLite DB
```
No lint script is configured.

### commitkit-mobile (React Native/Expo)
```bash
pnpm dev                # Expo dev server (clears cache)
pnpm run android        # Android emulator
pnpm run ios            # iOS simulator
pnpm run web            # Browser (uses mock usage data)
pnpm run type-check     # tsc --noEmit
pnpm test               # Jest
pnpm test:watch         # Jest watch mode
pnpm run clear-db       # Reset SQLite
```

### commitkit-server (Express API)
```bash
pnpm dev                        # Dev server
pnpm build                      # TypeScript build
pnpm test                       # Vitest
pnpm test:watch                 # Vitest watch mode
pnpm db:studio                  # Drizzle Studio
pnpm cron:commitment-failures   # Unified: charges for missed check-ins, timer deadlines, and plan deadlines
pnpm cron:givedirectly-payout   # Batch penalty payouts to GiveDirectly via Mercury
```
The three old cron scripts (`cron:timer-failures`, `cron:plan-failures`, `cron:missed-checkins`) were merged into `cron:commitment-failures` — a single unified job that POSTs to `/api/cron/commitment-failures`.

### Rust Projects (commitkit-eval, commitkit-monitor, commitkit-rules, commitkit-cli)
```bash
cargo build             # Debug build
cargo build --release   # Release build
cargo test              # Run tests (commitkit-rules, commitkit-cli have them; commitkit-eval/monitor do not)
cargo run               # Run (commitkit-monitor daemon; commitkit-cli binary is `commit`)
```

`commitkit-cli` installs its binary as `commit` via `cargo install --path commitkit-cli`.

### Testing
```bash
# commitkit-desktop (Vitest)
cd commitkit-desktop && pnpm test        # Run tests
cd commitkit-desktop && pnpm test:watch  # Watch mode

# commitkit-mobile (Jest + jest-expo)
cd commitkit-mobile && pnpm test         # Run tests
cd commitkit-mobile && pnpm test:watch   # Watch mode

# commitkit-server (Vitest)
cd commitkit-server && pnpm test         # Run tests
cd commitkit-server && pnpm test:watch   # Watch mode
```
Tests live in `__tests__/` in each JS project. Rust tests live inline (`#[cfg(test)]` modules). `commitkit-rules` and `commitkit-cli` have `cargo test` suites; `commitkit-eval` and `commitkit-monitor` do not yet.

## Railway (Production Infrastructure)

commitkit-server and its cron jobs run on Railway in the **CommitKit** project. The CLI is installed and authenticated.

```bash
# Link to the project (run from this directory)
railway link --project CommitKit --environment production

# Common operations
railway status --json                                    # Current context
railway service status --all --json                      # All services
railway logs --service commitkit-screentime-server --lines 100  # Server logs
railway logs --service missed-checkins-cron --lines 50   # Cron logs
railway variable list --service <svc> --json             # Service variables
```

### Services

| Service | What It Does |
|---------|-------------|
| `commitkit-screentime-server` | Main Express API (api.screentime.commitkit.com) |
| `ck-st-prod` | PostgreSQL database (prod); `ck-st-dev` also exists for dev |
| `missed-checkins-cron` | Hourly at :05 — runs the unified `cron:commitment-failures` script (charges for missed screen-time check-ins, timer deadlines, and plan deadlines). Name is legacy — it now does all three. The :05 offset avoids racing client-side real-time reports for timers/plans that end on round times. |
| `givedirectly-payout-cron` | Batches GiveDirectly penalty payouts via Mercury. The cron service only POSTs to the server — the Mercury transfer code runs on `commitkit-screentime-server`, so all three `MERCURY_*` vars (`API_KEY`, `ACCOUNT_ID`, `RECIPIENT_ID`) must live **on the server service** (fixed 2026-07-14; they were misplaced on the cron service). Mercury expires API tokens after long disuse — payout volume is often below the $10 batch threshold, so expect to recreate the token occasionally (needs Read and Write — it POSTs transfers). The server has Railway Static Outbound IPs enabled (Settings → Networking; Pro plan), so the token's allowlist is `162.220.234.241`, `152.55.180.242`, `152.55.180.243` — not `0.0.0.0/0`. The IPs are shared with other Railway customers, and they change if the service moves region (update the allowlist first). Since 2026-10-26 the crons carry only `CRON_SECRET` (a `${{shared.CRON_SECRET}}` reference); keep `MERCURY_*` off them and out of shared variables. |

### Direct Database Access

`psql` is **not** installed on this machine. Use Node with the `pg` client that's already in `commitkit-server/node_modules` — no install needed:

```bash
DB_URL=$(railway variable list --service ck-st-prod --json | python3 -c "import sys,json; print(json.load(sys.stdin)['DATABASE_PUBLIC_URL'])")
cd commitkit-server && DATABASE_URL="$DB_URL" node -e "
const {Client} = require('pg');
(async () => {
  const c = new Client({connectionString: process.env.DATABASE_URL, ssl: {rejectUnauthorized: false}});
  await c.connect();
  const r = await c.query('SELECT id, email FROM users LIMIT 5');
  console.log(JSON.stringify(r.rows, null, 2));
  await c.end();
})();
"
```

(The Drizzle schema may not match what's in prod — column names like `frequency` or `device_type` from older snapshots may not exist. Inspect `information_schema.columns` first when in doubt.)

### Migrations

The server's Railway pre-deploy command is `pnpm run db:push` (drizzle-kit push against `schema.ts`). It applies **additive** changes (new tables/columns) automatically before the new code boots. Anything that would lose data (drops) it only prompts for, and the non-interactive default aborts — the deploy continues and nothing is dropped. So:
- **Additive:** edit `schema.ts`, write the `drizzle/NNNN_*.sql` file for the record, push. No manual step.
- **Drops and backfills:** hand-written `drizzle/NNNN_*.sql`, applied with `sh scripts/apply-migration.sh drizzle/NNNN_*.sql [...]` from `commitkit-server/` (each file in its own transaction). Drops go **after** the deploy that stops using the column; backfills go before the deploy that relies on them.
- A "THIS ACTION WILL CAUSE DATA LOSS" prompt in the deploy log means a drop migration hasn't been applied yet (2026-10-28: 0036, 0037, 0039 had piled up). Don't run drizzle-kit generate — the journal is abandoned past 0018.

For interactive sessions: `railway connect ck-st-prod` opens a psql shell using Railway's bundled binary (no local install needed).

### Deploying

The service is connected to its GitHub repo in the Railway console. **Deploying is `git push origin main`** — that's the whole procedure. Auto-deploy builds from the pushed commit.

**Do not use `railway up`.** It uploads your *working tree* as a one-off deployment that GitHub knows nothing about, so production ends up running code that exists in no commit, and the next push silently replaces it with whatever is on main. It also happily deploys uncommitted changes. (Learned 2026-07-15: a `railway up` shipped a prompt fix that only existed locally.)

Two ways a `railway up` goes wrong quietly, if you ever reach for it anyway:
- Run from the repo root instead of `commitkit-server/`, it ships only `docs/`, `.gitignore`, and this file, and dies at the Railpack stage. That's a *build* failure — Railway keeps the previous deployment serving, so `/health` still returns 200 and nothing looks broken.
- It returns as soon as the upload starts, so its output never reports the outcome.

Either way, never conclude a deploy landed from the command's output or from a "Server running on port 8080" line in `railway logs` (that's a stale boot from the *previous* deployment). Check the deployment's actual status:
```bash
railway service list --json | python3 -c "import sys,json; [print(s['name'], s.get('deploymentId'), s.get('status')) for s in json.load(sys.stdin)]"
```
(`railway service status --all` is deprecated.) To read logs for a *failed* build, pass its deployment id — the bare `--build` flag shows the last **successful** build, which looks fine and isn't yours:
```bash
railway logs <deployment-id> --service commitkit-screentime-server --build --lines 40
```

### Rotating secrets

Full rotation done 2026-10-26 after a Railway env-var exposure. Where each secret lives:
- **Server only**: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `ANTHROPIC_API_KEY` (key in its own `commitkit` Console workspace with a $25/mo spend limit), `JWT_SECRET` (rotating it logs every desktop/mobile user out once; `ckv_` tokens are unaffected), `MERCURY_*`.
- **Shared**: `CRON_SECRET` (server + both crons reference it), `GOOGLE_DESKTOP_CLIENT_ID` (public, not a secret).
- **`DATABASE_URL`**: the server's is `${{ck-st-prod.DATABASE_URL}}`; on ck-st-prod every URL and `PGPASSWORD` derives from the literal `POSTGRES_PASSWORD`.

Stage all changes, then deploy once between :10 and :50 so the :05 cron doesn't hit a half-rotated state. Stripe: use **Roll** with a ~1h expiry on the old key/secret, so the overlap covers the deploy.

**Postgres password**: editing `POSTGRES_PASSWORD` does *not* change the real password (the image reads it only on first init — Railway warns about this). Order:
1. `railway connect ck-st-prod`, then `\password` at the psql prompt (keeps the value out of shell history). Use a hex password (`openssl rand -hex 32`); symbols break the URL.
2. Set `POSTGRES_PASSWORD` on ck-st-prod to the same value and deploy.
3. **Push to main to redeploy the server** (`git commit --allow-empty`). Changing the referenced variable did not redeploy it; it kept running the old `DATABASE_URL`, and new connections fail until it restarts. Confirm the deployment id changed and the boot log reaches "Changes applied" (the startup schema pull proves the DB connection).

## Cross-Project Dependencies

```
commitkit-desktop ──depends on──> commitkit-eval   (local Cargo path: ../../commitkit-eval)
commitkit-desktop ──depends on──> commitkit-rules  (local Cargo path: ../../commitkit-rules)
commitkit-desktop ──depends on──> commitkit-data   (local Cargo path: ../../commitkit-data)
commitkit-desktop ──bundles──> commitkit-monitor   (built in build.rs, bundled as Tauri resource)
commitkit-desktop ──reads from──> commitkit-monitor's SQLite DB (~/.proof-of-work-monitor/activity.db)

commitkit-cli ──depends on──> commitkit-eval   (local Cargo path: ../commitkit-eval)
commitkit-cli ──depends on──> commitkit-rules  (local Cargo path: ../commitkit-rules)
commitkit-cli ──depends on──> commitkit-data   (local Cargo path: ../commitkit-data)
commitkit-cli ──reads/writes──> commitkit-desktop's SQLite DB (~/Library/Application Support/CommitKit/commitkit.db)
commitkit-cli ──talks to──> commitkit-monitor's HTTP API (127.0.0.1:8787)

commitkit-mobile ──syncs with──> commitkit-server
commitkit-desktop ──syncs with──> commitkit-server (api.screentime.commitkit.com)
commitkit-cli ──syncs with──> commitkit-server (via ckv_ API token + combined auth middleware)
```

## Data Ownership: Local vs Server

**Principle: local autonomy, server authority.** Local SQLite owns configuration and real-time detection. Server PostgreSQL owns enforcement and money. Once money is at stake, the server takes over.

| Data | Owner | Why |
|------|-------|-----|
| Lists | Local creates, server stores **and decides removals** (2026-10-29) | Desktop lists are shared across Macs (`device_type desktop`); phone lists are `device_type android`, edited online only. Goals reference lists by UUID (`client_id`). `/api/lists/sync` diffs against the stored row: a dropped item waits 48h in `pending_removals` (client-sent ones are ignored); `GET` returns `effective_apps/domains` |
| Screen-time templates, commitments (**mobile only**) | Local creates, server stores | Device-scoped scheduling; server must know so the unified commitment-failures cron can charge. The desktop dropped these 2026-10-29: its Limits are Goals |
| Timer sessions | Local | Real-time state; result reported to `/api/timer-completions`, which Goal timer checks count. |
| Activity data (monitor DB) | **Local only** | Too granular/sensitive for server; only compliance verdicts cross the boundary |
| Violations | **Server is ledger** | Server processes Stripe charges; mobile keeps a UI cache, the desktop none (local table dropped in schema v35) |
| Plans, requirements, evaluations | **Server only** | Web-managed, AI-evaluated, no local copy needed |
| Claude verification templates/commitments | **Server only** | AI-reported via API token (`/api/claude-verifications/report`); desktop is thin UI. Credentials file at `~/.commitkit/credentials.json` (0600). Full reporting contract: `commitkit-server/docs/claude-verification-contract.md`. |
| Projects | **Local creates, server owns the rules** (2026-10-29) | Desktop/CLI keep a local copy (lists attach locally); the server owns `rules` (eval rules + working directories) so edits follow akrasia. `client_id` = local `projects.uuid` = completions' `project_uuid` |
| Stripe charges, payouts | **Server only** | Financial records |

**Key rules:**
- Commitments lock after 10 minutes — no softening rules after that. The server enforces this for screen-time deletes too (`DELETE /api/commitments/by-client-id` → 409 inside the akrasia window; `src/domain/commitment-guards.ts`), and the delete is a **soft delete** (`commitments.deleted_at`, drizzle `0033`) so violation/charge records outlive the commitment. Screen-time stakes are any whole-cent amount $1–$1000, no ladder (`PENALTY_MAX_DOLLARS`); Goals and verifications only require a non-negative whole-cent stake.
- `users.penalty_destination` is akrasia-locked (2026-07-14): switching to `givedirectly` is immediate; switching back to `platform` is scheduled 48h out (`pending_penalty_destination` + `penalty_destination_applies_at`, applied lazily on preferences GET/PUT and by the hourly cron before charging). A DB trigger rejects direct SQL flips unless a due pending switch authorizes them (`drizzle/0029`).
- **Before-distractions Goals (2026-10-12)**: a Goal with `must_complete_before_distractions` warns on every distraction-list app/tab focused while it's pending (from the instance's `gate_opens_at` until its deadline; the server also refuses a breach from before `gate_opens_at`). Go Back is free; **Continue is the breach** — monitor queues it → desktop reports `POST /api/plan-commitments/:id/distraction-breach` → server fails + charges the Goal immediately (same `finalizePlan` path and idempotency key as the cron; the evaluator also fails any active Goal carrying `evaluation_state.distraction_breach`). Passive activity never charges. Completion paths never flip a `failed` Goal back to `completed`. The gate does **not** need the desktop running (2026-10-27): the desktop pushes a 14-day schedule of gate windows that the monitor keeps enforcing from `domain-rules.json`, completion reports return `completed_gate_goal_ids` that the reporter forwards to the monitor to lift the warning, and the desktop launches at login. Root cause of the 2026-10-26 miss: app closed for ~2 days, so the monitor's watchlist was a stale "open right now" snapshot. List edits follow akrasia per Goal-day: once a Goal's deadline is inside the akrasia window its apps/domains are locked (`gate_target_locks`, union with current lists — additions apply, removals don't), and Goals further out pick up removals immediately.
- **One akrasia length**: 48h — server `AKRASIA_MS` (`src/domain/apply-edit.ts`), Rust `commitkit_data::AKRASIA_WINDOW_SECS`, desktop frontend `lib/akrasia.ts`, and the phone's display-only `AKRASIA_S` (`commitkit-distractions/src/screens/Lists.tsx`). Keep them in sync. Every list removal serves it (`pending_removals`), regardless of what uses the list.
- **Settlement (2026-10-27)**: every past-due commitment settles at `due_at + 24h` (`SETTLEMENT_GRACE_HOURS`, `commitkit-server/src/domain/settlement.ts`). Work done before the deadline that syncs inside that window still counts; going offline can't dodge the charge because it lands at +24h regardless. The first cron run after the deadline that evaluates a row as failed stamps `evaluation_state.missed_at` (row stays `active`); APIs then report it as failed with `charges_at`, and a late pass retracts it. Distraction breaches charge immediately. Replaced the client-liveness deferral (per-user/per-device last-seen + 72h bound), which never settled for an always-online desktop.
- **Goal windows (2026-10-29)**: every plan instance carries absolute timestamps on its `scheduled_commitments` row — `opens_at` (submissions accepted, timer checks count) and `gate_opens_at` (before-distractions gate), both ending at `due_at`; a CHECK makes `opens_at` required for plan rows. The Goal template only holds the rules that produce them (`plans.submission_opens` / `plans.gate_opens`: `{days_before, at: "HH:MM"}` or `{when_scheduled: true}`), resolved in the user's timezone at scheduling (`src/domain/goal-window.ts`; period day-slots always open on their own day). Readers use the stamped columns only — submissions 409 before `opens_at`, cron and live re-eval share `timerCountFrom`, the desktop watchlist pushes `gate_opens_at..due_at` to the monitor. Edits follow akrasia and re-stamp: a later submission opening / earlier gate applies now, the reverse waits 48h on locked instances. Replaced `span_days` (2026-10-28) and the desktop's global `pre_distraction_reset_hour` setting; migrations 0040 before deploy, 0041 drop after.
- `violation_tracking_starts_at` = grace period for mid-day rule creation (forward-looking, not retroactive)
- **Desktop Limits are Goals (2026-10-29).** A Limit is a Goal whose checks are all `usage_limit` (`{usageListIds, usageMode, usageMetric, usageMax, usageWindows}`, server `src/domain/usage-limit.ts`). The desktop measures usage from the monitor and reports only the verdict to `POST /api/plan-commitments/:id/usage-report`: over the limit fails + charges the Goal at once (a `usage_breach`; claim + settle shared with the gate breach in `src/domain/breach.ts`), under passes the check once its last window closes, and an unreported check fails at the deadline like any other. Stake, schedule, lock, akrasia, days off and settlement are the Goal machinery. **A usage check belongs to one device type** (2026-10-29): all its lists are desktop or all phone (`plans.ts` 400s a mix), and only that kind of device measures and reports it — the desktop skips checks with any non-local list, `commitkit-distractions` takes checks whose lists are all phone lists (block mode only). The old `commitkit-mobile` still uses the screen-time stack (`commitments`/`templates`/`/api/checkin`), which stays until it's retired.
- **Gate on every device (2026-10-29)**: a Goal's `distraction_list_ids` can mix Mac and phone lists; each device warns for its own (a second Mac works off the same server Goals), and a Continue anywhere charges once. The phone's gate is `commitkit-distractions/modules/commitkit-gate` (see its CLAUDE.md).
- **Project rules follow akrasia (2026-10-29)**: `PUT /api/projects/:clientId` runs rule edits through the `project` entry of `commitment-types.ts` (`src/domain/project-rules.ts`): turning a `require_*` on, adding a file pattern or a working directory applies now; turning one off, adding a neutral domain, removing/moving a directory, or changing the eval context waits 48h as `pending_rules` + `rules_apply_at`. A project's first 10 minutes are free. The desktop needs the server for a rule edit, mirrors `pending_rules` locally, and both it and the CLI read rules through `commitkit_data::project_rules::effective_project_rules` (a due loosening applies without a round trip); the 5-minute pull rewrites local rules, so editing the SQLite row directly reverts. Goal timer checks name projects by `project_uuid` (name only as a label/legacy fallback); with `timerCountsPerProject` each listed project needs its own `count` (`timerCheckSatisfied`, `evaluators.ts`).
- **Timers are never individually staked (Phase 2, 2026-06-18).** A timer is only a *timer check inside a Goal* (internally a `plan`, UI-branded "Goal") plus a *session* that reports a completion to `/api/timer-completions`. The server counts passing completions toward a Goal's timer check; the **Goal** owns the only stake. There is no standalone staked-timer commitment anymore: the timer-assignment and timer-template subsystems (server routes, `/api/violations/timer`, desktop commands, local tables) were deleted 2026-10-27, and `timer_templates` is dropped by `drizzle/0037`. Historical `type='timer'` `scheduled_commitments` rows remain as settled history; the evaluator has no `timer` entry, so one could never charge. See memory `project_plan_to_goal_rename`.
- Raw activity data never leaves the device — only `was_compliant` + `actual_usage` vs `limit_value`
- **Local integer IDs stay local.** SQLite `INTEGER PRIMARY KEY` autoincrement values are the efficient intra-local identifier and fine for joins / FKs / in-process references. **They must never leak into anything that outlives the local-ID space** — not into snapshots (`contract_snapshot` / `identity_snapshot`), not into API payloads, not into logs, not into anything sent across devices. When a value crosses that boundary, translate to the row's UUID at the write edge and back to a local integer at the read edge. Leaks produce silent "no distractions configured"–style bugs when local IDs drift (reinstall, list delete+recreate, cross-device). See `docs/list-ids-uuid-migration.md` — the `list_ids` case is now fixed; the doc records the incident and the shape of the migration for reference.

## Runbook: Manually passing a timer that false-failed

When a timer was *legitimately completed* but failed because of a bug or unfair verdict (e.g. the diff-eval false-negative on no-diff app/web work), correct it by flipping **both** databases — the server `timer_completions` row is what the cron counts; the local `timer_sessions` row is only the UI/source-of-truth cache. Flipping just one leaves them inconsistent.

1. **Find the session.** Local:
   ```sh
   sqlite3 "$HOME/Library/Application Support/CommitKit/commitkit.db" \
     "SELECT id, status, evaluation_passed, datetime(started_at,'unixepoch','localtime') AS started, server_completion_id, project_id FROM timer_sessions ORDER BY id DESC LIMIT 6;"
   ```
   Note `server_completion_id` (= server `timer_completions.id`).

2. **Flip the server completion** (what the cron counts). `psql` isn't installed — use the node-pg pattern in *Direct Database Access* above, DB URL from `railway variable list --service ck-st-prod`:
   ```sql
   UPDATE timer_completions SET evaluation_passed = true,
     evaluation_summary = 'Manually passed <date>: <reason>'
   WHERE id = '<server_completion_id>';
   ```

3. **Flip the local session** for consistency:
   ```sql
   UPDATE timer_sessions SET status='completed', evaluation_passed=1,
     evaluation_summary='Manually passed <date>: <reason>' WHERE id = <local_id>;
   ```

4. **Assess the *actual* charge risk — flipping may not be enough.** A timer charges nothing on its own; it feeds the **timer checks of Goals**. The cron evaluator (`commitkit-server/src/domain/evaluators.ts`, `timerCheckSatisfied`) counts passing `timer_completions` with `duration_minutes >= timerDurationMinutes` and `ended_at` between the instance's `opens_at` and `due_at`, optionally project-filtered (`timerProjectRequirements[]` by `project_uuid`, else `project_name`; **no filter = any project counts**; with `timerCountsPerProject` each listed project also needs its own `count`). **Completions are shared across checks** — one morning timer counts toward every Goal whose check it matches. So: query the user's `scheduled_commitments` (`type='plan'`, `status='active'`, `due_at` ahead) with `timer_requirement` checks, and confirm the flip pushes the count to `>= timerCount`. If it's still short, the shortfall is **real** (the user simply did fewer timers than required) — flipping won't prevent that charge; only more passing timers before `due_at` will. Don't move `due_at` to dodge a charge: that violates the user's "commitments lock, no softening" rule.

5. **Timezone quirk (do not "fix" it).** Server timer timestamps are stored **+5h from true UTC**, but *consistently* — `timer_completions.ended_at` and `scheduled_commitments.due_at` are both shifted, so the cron's in-frame comparisons are correct. When reading back, remember `::text`/`to_char` renders roughly true-UTC; a `due_at` of `17:00` in the stored frame is the user's local **noon**.

6. **Timing.** The cron is Railway `missed-checkins-cron`, hourly at **:05**. The :05 run *after* a commitment's `due_at` is the one that charges, so there's until then to land additional passing timers.

## Shared Patterns

- **Path alias**: All JS/TS projects use `@/*` mapping to the project root
- **UI**: `commitkit-desktop` uses plain Tailwind CSS 4 with shadcn-style design tokens but no shadcn primitives (hand-rolled buttons/inputs/modals — see `commitkit-desktop/CLAUDE.md`); `commitkit-mobile` uses NativeWind + React Native Reusables
- **Tauri IPC**: Frontend calls `invoke("command", { args })` → Rust `#[tauri::command]` returns `Result<T, String>`
- **Local-first data**: Tauri and Expo apps use SQLite as source of truth, syncing to server opportunistically
- **Cross-device sync**: Desktop templates and lists are shared across all desktop devices for the same user (keyed by `device_type` not `device_id`). Commitments remain device-specific. Mobile and desktop do not sync with each other.
- **Static export**: `commitkit-desktop` uses Next.js `output: 'export'` (no SSR)
- **Auth**: Mobile app uses Google Sign-In (native SDK → server verifies ID token → issues JWT). Server auth via `google-auth-library` + `jsonwebtoken`. Routes that need to serve both the desktop (JWT) and external clients like commitkit-cli (`ckv_` tokens) use `authenticateJwtOrApiToken` from `src/middleware/combined-auth.ts` — the `/api/timer-completions` and `/api/evaluate-session` routes (`/api/claude-verifications/report` is `ckv_`-only via `authenticateApiToken`).

## Data Storage Locations (macOS)

- `~/Library/Application Support/CommitKit/commitkit.db` — commitkit-desktop SQLite
- `~/.proof-of-work-monitor/activity.db` — commitkit-monitor SQLite (read by commitkit-desktop)
- `~/.commitkit/bin/commitkit-monitor` — installed monitor daemon binary
- `~/Library/LaunchAgents/com.commitkit.monitor.plist` — monitor launchd service
- `~/.commitkit/timer.lock` — cross-process flock; only one CommitKit timer (CLI or desktop) runs at a time on a given machine. Auto-released on process exit. See `commitkit-data/src/lock.rs`.
