# CLAUDE.md
This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Is This

CommitKit is a commitment accountability ecosystem — users set goals (productivity timers, screen time limits, habits), and the system enforces them through financial stakes via Stripe. This directory contains 7 independent projects (each with its own git repo) that work together.

## Projects

| Directory | What It Is | Stack |
|-----------|-----------|-------|
| `commitkit-web` | Web app — plans, AI evaluation, Stripe stakes | Next.js 16, Prisma, PostgreSQL, NextAuth, Claude API |
| `commitkit-timer` | Desktop productivity timer | Tauri 2, Next.js 16, Rust, SQLite |
| `commitkit-mobile` | Mobile app (screen time enforcer, expanding to general commitments) | React Native 0.81, Expo 54, SQLite, Stripe |
| `commitkit-desktop` | Desktop app — screen time limits, productivity timers, plans, projects | Tauri 2, Next.js 16, Rust, SQLite |
| `commitkit-server` | Backend API for mobile + desktop apps | Express, Drizzle ORM, PostgreSQL, Stripe |
| `commitkit-eval` | Activity evaluation library | Rust 2024 |
| `commitkit-monitor` | macOS activity monitoring daemon + app warning system | Rust 2024 |

Four projects have their own `CLAUDE.md` with detailed architecture: `commitkit-timer`, `commitkit-mobile`, `commitkit-desktop`, `commitkit-web`. Read those when working in a specific project.

## Common Commands

**JS/TS projects** use **pnpm** (not npm/yarn). Rust projects use **cargo**.

### Tauri Desktop Apps (commitkit-timer, commitkit-desktop)
```bash
pnpm tauri:dev          # Full app (frontend + Rust backend)
pnpm dev                # Next.js frontend only
pnpm build              # Next.js static export
pnpm tauri:build        # Production binary
pnpm type-check         # tsc --noEmit
pnpm lint               # ESLint (commitkit-timer only)
```

### commitkit-web (Next.js web)
```bash
pnpm dev                # Dev server
pnpm build              # Prisma generate + Next.js build
pnpm type-check         # tsc --noEmit
pnpm lint               # ESLint
pnpm seed               # Seed PostgreSQL via Prisma
pnpm migrate            # prisma migrate deploy
```

### commitkit-mobile (React Native/Expo)
```bash
pnpm dev                # Expo dev server (clears cache)
pnpm run android        # Android emulator
pnpm run ios            # iOS simulator
pnpm run type-check     # tsc --noEmit
```

### commitkit-server (Express API)
```bash
pnpm dev                # Dev server
pnpm build              # TypeScript build
pnpm db:migrate         # Drizzle migrations
pnpm db:studio          # Drizzle Studio
pnpm cron:timer-failures    # Charge missed timer deadlines
pnpm cron:plan-failures     # Charge missed plan deadlines
pnpm cron:missed-checkins   # Charge missed screen time check-ins
```

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
```
Tests live in `__tests__/` in each project. Other projects do not have automated tests.

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
| `ck-st-prod` | PostgreSQL database |
| `missed-checkins-cron` | Daily: charges for unsynced screen time check-ins |
| `timer-failures-cron` | Daily: charges for missed timer deadlines |
| `plan-failures-cron` | Daily: charges for missed plan deadlines |
| `givedirectly-payout-cron` | Batches GiveDirectly penalty payouts via Mercury |

### Direct Database Access

The production PostgreSQL database is accessible via the public proxy:
```bash
# Get the public DATABASE_URL
railway variable list --service ck-st-prod --json | python3 -c "import sys,json; print(json.load(sys.stdin)['DATABASE_PUBLIC_URL'])"

# Then use psql directly
psql "<DATABASE_PUBLIC_URL>"
```

### Deploying

The server auto-deploys from its GitHub repo. To deploy manually:
```bash
railway up --service commitkit-screentime-server --detach
```

## Cross-Project Dependencies

```
commitkit-timer ──depends on──> commitkit-eval (local Cargo path: ../../commitkit-eval)

commitkit-desktop ──depends on──> commitkit-eval (local Cargo path: ../../commitkit-eval)
commitkit-desktop ──bundles──> commitkit-monitor (built in build.rs, bundled as Tauri resource)
commitkit-desktop ──reads from──> commitkit-monitor's SQLite DB (~/.proof-of-work-monitor/activity.db)

commitkit-mobile ──syncs with──> commitkit-server
commitkit-desktop ──syncs with──> commitkit-server (api.screentime.commitkit.com)
```

## Shared Patterns

- **Path alias**: All JS/TS projects use `@/*` mapping to the project root
- **UI**: Desktop/web apps use shadcn/ui (new-york style) + Tailwind CSS + Radix primitives
- **Tauri IPC**: Frontend calls `invoke("command", { args })` → Rust `#[tauri::command]` returns `Result<T, String>`
- **Local-first data**: Tauri and Expo apps use SQLite as source of truth, syncing to server opportunistically
- **Static export**: Both Tauri apps use Next.js `output: 'export'` (no SSR)
- **Auth**: Mobile app uses Google Sign-In (native SDK → server verifies ID token → issues JWT). Server auth via `google-auth-library` + `jsonwebtoken`.

## Data Storage Locations (macOS)

- `~/.ck-timer/timer.db` — commitkit-timer SQLite
- `~/Library/Application Support/CommitKit/commitkit.db` — commitkit-desktop SQLite
- `~/.proof-of-work-monitor/activity.db` — commitkit-monitor SQLite (read by commitkit-desktop)
- `~/.commitkit/bin/commitkit-monitor` — installed monitor daemon binary
- `~/Library/LaunchAgents/com.commitkit.monitor.plist` — monitor launchd service
