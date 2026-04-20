# CLAUDE.md
This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Is This

CommitKit is a commitment accountability ecosystem — users set goals (productivity timers, screen time limits, habits), and the system enforces them through financial stakes via Stripe. This directory contains 5 independent projects (each with its own git repo) that work together.

Historical note: earlier there were separate `commitkit-timer` (standalone Tauri timer) and `commitkit-web` (Next.js web app for plans + AI evaluation) projects. Both were folded into `commitkit-desktop`, which now owns timer, screen-time, plans, and project features in a single Tauri app. If you see references to those old project names in commit history or stale docs, map them to `commitkit-desktop`.

## Projects

| Directory | What It Is | Stack |
|-----------|-----------|-------|
| `commitkit-desktop` | Desktop app — screen time limits, productivity timers, plans (with AI evaluation), projects. Subsumes the former `commitkit-web` and `commitkit-timer`. | Tauri 2, Next.js 16, Rust, SQLite |
| `commitkit-mobile` | Mobile app — screen time limit enforcement | React Native 0.81, Expo 54, SQLite, Stripe |
| `commitkit-server` | Backend API for mobile + desktop; owns enforcement ledger and Stripe charges | Express, Drizzle ORM, PostgreSQL, Stripe |
| `commitkit-eval` | Activity evaluation library (pure logic used by desktop) | Rust 2024 |
| `commitkit-monitor` | macOS activity monitoring daemon + app warning system | Rust 2024 |

Three projects have their own `CLAUDE.md` with detailed architecture: `commitkit-desktop`, `commitkit-mobile`, `commitkit-monitor`. Read those when working in a specific project. `commitkit-server` and `commitkit-eval` have no sub-CLAUDE.md yet.

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

### Rust Projects (commitkit-eval, commitkit-monitor)
```bash
cargo build             # Debug build
cargo build --release   # Release build
cargo run               # Run (monitor only)
```

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
Tests live in `__tests__/` in each project. Rust projects (commitkit-eval, commitkit-monitor) do not have automated tests.

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
| `missed-checkins-cron` | Daily: runs the unified `cron:commitment-failures` script (charges for missed screen-time check-ins, timer deadlines, and plan deadlines). Name is legacy — it now does all three. |
| `givedirectly-payout-cron` | Batches GiveDirectly penalty payouts via Mercury |
| `timer-failures-cron`, `plan-failures-cron` | **Stopped/deprecated.** Superseded by the unified job above. Do not re-enable without coordinating with the unified script to avoid double-charging. |

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
commitkit-desktop ──depends on──> commitkit-eval (local Cargo path: ../../commitkit-eval)
commitkit-desktop ──bundles──> commitkit-monitor (built in build.rs, bundled as Tauri resource)
commitkit-desktop ──reads from──> commitkit-monitor's SQLite DB (~/.proof-of-work-monitor/activity.db)

commitkit-mobile ──syncs with──> commitkit-server
commitkit-desktop ──syncs with──> commitkit-server (api.screentime.commitkit.com)
```

## Data Ownership: Local vs Server

**Principle: local autonomy, server authority.** Local SQLite owns configuration and real-time detection. Server PostgreSQL owns enforcement and money. Once money is at stake, the server takes over.

| Data | Owner | Why |
|------|-------|-----|
| Templates, lists, timer templates | Local creates, server stores | Config is local-first; server needs a copy for cross-device sync and enforcement backstop |
| Commitments | Local creates, server stores | Device-scoped scheduling; server must know so the unified commitment-failures cron can charge |
| Timer assignments | **Server** | Server creates deadlines; unified commitment-failures cron charges if no completion reported |
| Timer sessions | Local | Real-time state; result synced to server via assignment status |
| Activity data (monitor DB) | **Local only** | Too granular/sensitive for server; only compliance verdicts cross the boundary |
| Violations | **Server is ledger**; local is UI cache | Server processes Stripe charges; local stores enough for toasts/acknowledgment |
| Plans, requirements, evaluations | **Server only** | Web-managed, AI-evaluated, no local copy needed |
| Claude verification templates/commitments | **Server only** | AI-reported via API token (`/api/claude-verifications/report`); desktop is thin UI. Credentials file at `~/.commitkit/credentials.json` (0600). |
| Projects | **Local only** (sync metadata planned) | Working directories are machine-specific; name/color/eval rules may sync later |
| Stripe charges, payouts | **Server only** | Financial records |

**Key rules:**
- Commitments lock after 10 minutes — no softening rules after that
- `violation_tracking_starts_at` = grace period for mid-day rule creation (forward-looking, not retroactive)
- Every staked timer must have a server-side assignment — no enforcement-free ad-hoc timers
- Raw activity data never leaves the device — only `was_compliant` + `actual_usage` vs `limit_value`

## Shared Patterns

- **Path alias**: All JS/TS projects use `@/*` mapping to the project root
- **UI**: `commitkit-desktop` uses plain Tailwind CSS 4 with shadcn-style design tokens but no shadcn primitives (hand-rolled buttons/inputs/modals — see `commitkit-desktop/CLAUDE.md`); `commitkit-mobile` uses NativeWind + React Native Reusables
- **Tauri IPC**: Frontend calls `invoke("command", { args })` → Rust `#[tauri::command]` returns `Result<T, String>`
- **Local-first data**: Tauri and Expo apps use SQLite as source of truth, syncing to server opportunistically
- **Static export**: `commitkit-desktop` uses Next.js `output: 'export'` (no SSR)
- **Auth**: Mobile app uses Google Sign-In (native SDK → server verifies ID token → issues JWT). Server auth via `google-auth-library` + `jsonwebtoken`.

## Data Storage Locations (macOS)

- `~/Library/Application Support/CommitKit/commitkit.db` — commitkit-desktop SQLite
- `~/.proof-of-work-monitor/activity.db` — commitkit-monitor SQLite (read by commitkit-desktop)
- `~/.commitkit/bin/commitkit-monitor` — installed monitor daemon binary
- `~/Library/LaunchAgents/com.commitkit.monitor.plist` — monitor launchd service
