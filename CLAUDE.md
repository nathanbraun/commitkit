# CLAUDE.md
This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Is This

CommitKit is a commitment accountability ecosystem — users set goals (productivity timers, screen time limits, habits), and the system enforces them through financial stakes via Stripe. This directory contains 7 independent projects (each with its own git repo) that work together.

Historical note: earlier there were separate `commitkit-timer` (standalone Tauri timer) and `commitkit-web` (Next.js web app for plans + AI evaluation) projects. Both were folded into `commitkit-desktop`, which now owns timer, screen-time, plans, and project features in a single Tauri app. If you see references to those old project names in commit history or stale docs, map them to `commitkit-desktop`.

## Projects

| Directory | What It Is | Stack |
|-----------|-----------|-------|
| `commitkit-desktop` | Desktop app — screen time limits, productivity timers, plans (with AI evaluation), projects. Subsumes the former `commitkit-web` and `commitkit-timer`. | Tauri 2, Next.js 16, Rust, SQLite |
| `commitkit-mobile` | Mobile app — screen time limit enforcement | React Native 0.81, Expo 54, SQLite, Stripe |
| `commitkit-server` | Backend API for mobile + desktop; owns enforcement ledger and Stripe charges | Express, Drizzle ORM, PostgreSQL, Stripe |
| `commitkit-eval` | Activity evaluation library (pure logic used by desktop + CLI) | Rust 2024 |
| `commitkit-monitor` | macOS activity monitoring daemon + app warning system | Rust 2024 |
| `commitkit-rules` | Shared builder + HTTP helpers for the monitor's `/api/domain-rules` contract. Used by desktop and CLI so both produce an identical wire format. | Rust 2024 |
| `commitkit-data` | Shared SQLite operations on the desktop's `commitkit.db` — project/list resolution, list UUID↔id translation. Used by desktop and CLI so the union of template + project lists is computed identically. | Rust 2024 |
| `commitkit-cli` | Terminal focus timer (`commit` binary) — project-scoped; runs sessions that report completions counted toward Goal timer checks; pushes rules to the monitor; evaluates via commitkit-eval. (No longer stakes individual timers — Phase 2.) | Rust 2024 |

Five projects have their own `CLAUDE.md` with detailed architecture: `commitkit-desktop`, `commitkit-mobile`, `commitkit-monitor`, `commitkit-rules`, `commitkit-cli`. Read those when working in a specific project. `commitkit-server`, `commitkit-eval`, and `commitkit-data` have no sub-CLAUDE.md yet.

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
pnpm db:migrate                 # Drizzle migrations
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
| `givedirectly-payout-cron` | Batches GiveDirectly penalty payouts via Mercury |

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

For interactive sessions: `railway connect ck-st-prod` opens a psql shell using Railway's bundled binary (no local install needed).

### Deploying

The server auto-deploys from its GitHub repo. To deploy manually:
```bash
railway up --service commitkit-screentime-server --detach
```

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
| Templates, lists, timer templates | Local creates, server stores | Config is local-first; server needs a copy for cross-device sync and enforcement backstop |
| Commitments | Local creates, server stores | Device-scoped scheduling; server must know so the unified commitment-failures cron can charge |
| Timer assignments (`type='timer'`) | **Dormant (Phase 2)** | No longer created or charged. Was: a standalone staked timer. Now a timer is a check inside a Goal; the Goal charges. The `/api/timer-assignments` GET + the `timer` commitment-type are retained only because `rule_pusher`/`check_commitment_progress` still read them, over an empty set. |
| Timer sessions | Local | Real-time state; result synced to server via assignment status (see above). |
| Activity data (monitor DB) | **Local only** | Too granular/sensitive for server; only compliance verdicts cross the boundary |
| Violations | **Server is ledger**; local is UI cache | Server processes Stripe charges; local stores enough for toasts/acknowledgment |
| Plans, requirements, evaluations | **Server only** | Web-managed, AI-evaluated, no local copy needed |
| Claude verification templates/commitments | **Server only** | AI-reported via API token (`/api/claude-verifications/report`); desktop is thin UI. Credentials file at `~/.commitkit/credentials.json` (0600). Full reporting contract: `commitkit-server/docs/claude-verification-contract.md`. |
| Projects | **Local only** (sync metadata planned) | Working directories are machine-specific; name/color/eval rules may sync later |
| Stripe charges, payouts | **Server only** | Financial records |

**Key rules:**
- Commitments lock after 10 minutes — no softening rules after that
- `violation_tracking_starts_at` = grace period for mid-day rule creation (forward-looking, not retroactive)
- **Timers are never individually staked (Phase 2, 2026-06-18).** A timer is only a *timer check inside a Goal* (internally a `plan`, UI-branded "Goal") plus a *session* that reports a completion to `/api/timer-completions`. The server counts passing completions toward a Goal's timer check; the **Goal** owns the only stake. There is no standalone staked-timer commitment anymore — the cron excludes `type='timer'` and `evaluateTimer`/`finalizeTimer` are deleted. The `type='timer'` row + `/api/timer-assignments` read-path survive only as **dormant infra** (read by `rule_pusher`/`check_commitment_progress`); nothing creates timer rows. See memory `project_plan_to_goal_rename`.
- Raw activity data never leaves the device — only `was_compliant` + `actual_usage` vs `limit_value`
- **Local integer IDs stay local.** SQLite `INTEGER PRIMARY KEY` autoincrement values are the efficient intra-local identifier and fine for joins / FKs / in-process references. **They must never leak into anything that outlives the local-ID space** — not into snapshots (`contract_snapshot` / `identity_snapshot`), not into API payloads, not into logs, not into anything sent across devices. When a value crosses that boundary, translate to the row's UUID at the write edge and back to a local integer at the read edge. Leaks produce silent "no distractions configured"–style bugs when local IDs drift (reinstall, list delete+recreate, cross-device). See `docs/list-ids-uuid-migration.md` — the `list_ids` case is now fixed; the doc records the incident and the shape of the migration for reference.

## Runbook: Manually passing a timer that false-failed

When a timer was *legitimately completed* but failed because of a bug or unfair verdict (e.g. the diff-eval false-negative on no-diff app/web work), correct it by flipping **both** databases — the server `timer_completions` row is what the cron counts; the local `timer_sessions` row is only the UI/source-of-truth cache. Flipping just one leaves them inconsistent.

1. **Find the session.** Local:
   ```sh
   sqlite3 "$HOME/Library/Application Support/CommitKit/commitkit.db" \
     "SELECT id, status, evaluation_passed, datetime(started_at,'unixepoch','localtime') AS started, server_completion_id, assignment_id, project_id FROM timer_sessions ORDER BY id DESC LIMIT 6;"
   ```
   Note `server_completion_id` (= server `timer_completions.id`) and `assignment_id` (**empty = free timer**; non-empty = individually staked).

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

4. **Assess the *actual* charge risk — flipping may not be enough.** What charges depends on the timer type:
   - **Free timer (no `assignment_id`)**: charges nothing on its own, but feeds **batch** commitments. The cron evaluator (`commitkit-server/src/domain/evaluators.ts`) counts passing `timer_completions` with `duration_minutes >= min_duration_minutes` and `ended_at` between the commitment's date-midnight (in the user's tz) and `due_at`, optionally project-filtered (`project_filter_uuid` / `project_requirements[].project_name` in `contract_snapshot`; **no filter = any project counts**). **Completions are shared across commitments** — one morning timer counts toward both an AM kickstart and a noon batch. So: query `scheduled_commitments` (`type='timer'`, `status='active'`, `due_at` ahead) for the user, and confirm the flip pushes the count to `>= required_count`. If it's still short, the shortfall is **real** (the user simply did fewer timers than required) — flipping won't prevent that charge; only more passing timers before `due_at` will. Don't move `due_at` to dodge a charge: that violates the user's "commitments lock, no softening" rule.
   - **Staked timer (`assignment_id` set)**: the assignment row itself is the enforcement deadline. Transition it to `status='completed'` (and ensure no `/api/violations/timer` charge already fired).

5. **Timezone quirk (do not "fix" it).** Server timer timestamps are stored **+5h from true UTC**, but *consistently* — `timer_completions.ended_at` and `scheduled_commitments.due_at` are both shifted, so the cron's in-frame comparisons are correct. When reading back, remember `::text`/`to_char` renders roughly true-UTC; a `due_at` of `17:00` in the stored frame is the user's local **noon**.

6. **Timing.** The cron is Railway `missed-checkins-cron`, hourly at **:05**. The :05 run *after* a commitment's `due_at` is the one that charges, so there's until then to land additional passing timers.

## Shared Patterns

- **Path alias**: All JS/TS projects use `@/*` mapping to the project root
- **UI**: `commitkit-desktop` uses plain Tailwind CSS 4 with shadcn-style design tokens but no shadcn primitives (hand-rolled buttons/inputs/modals — see `commitkit-desktop/CLAUDE.md`); `commitkit-mobile` uses NativeWind + React Native Reusables
- **Tauri IPC**: Frontend calls `invoke("command", { args })` → Rust `#[tauri::command]` returns `Result<T, String>`
- **Local-first data**: Tauri and Expo apps use SQLite as source of truth, syncing to server opportunistically
- **Static export**: `commitkit-desktop` uses Next.js `output: 'export'` (no SSR)
- **Auth**: Mobile app uses Google Sign-In (native SDK → server verifies ID token → issues JWT). Server auth via `google-auth-library` + `jsonwebtoken`. Routes that need to serve both the desktop (JWT) and external clients like commitkit-cli (`ckv_` tokens) use `authenticateJwtOrApiToken` from `src/middleware/combined-auth.ts` — currently the `/api/timer-assignments` routes.

## Data Storage Locations (macOS)

- `~/Library/Application Support/CommitKit/commitkit.db` — commitkit-desktop SQLite
- `~/.proof-of-work-monitor/activity.db` — commitkit-monitor SQLite (read by commitkit-desktop)
- `~/.commitkit/bin/commitkit-monitor` — installed monitor daemon binary
- `~/Library/LaunchAgents/com.commitkit.monitor.plist` — monitor launchd service
- `~/.commitkit/timer.lock` — cross-process flock; only one CommitKit timer (CLI or desktop) runs at a time on a given machine. Auto-released on process exit. See `commitkit-data/src/lock.rs`.
