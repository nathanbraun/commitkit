# Ad-hoc (One-off) Timer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user click "Focus Now" on the home dashboard, pick a duration / stake / project / distraction lists, and start a staked timer that cannot be cancelled mid-flight and gets charged if abandoned.

**Architecture:** Syntactic sugar over the existing `scheduled_commitments` + `cron:commitment-failures` pipeline. A new `allow_cancel` boolean flows through `timer_templates`, `timer_sessions`, and the `contract_snapshot` on server assignments. The existing `POST /api/timer-assignments` already accepts a snapshot without `id` — ad-hoc timers are assignments with `template_id = null` and a client-derived `complete_by_time`. Cancellation enforcement is two-layer: UI hides the Cancel button when `allow_cancel = false`, and the server's existing daily failures cron charges the stake if `due_at` passes without a completion report.

**Tech Stack:** Rust (Tauri, sqlx, SQLite), TypeScript (Next.js 16, React 19, plain Tailwind 4), Node (Express, Drizzle ORM, PostgreSQL), Vitest.

**Spec:** `docs/superpowers/specs/2026-04-21-ad-hoc-timer-design.md`

---

## Pre-flight

Working directory: `/Users/nathanbraun/code/github.com/nathanbraun/commitkit`

Three subprojects are touched:
- `commitkit-server` — Drizzle migration + registry update + one new test
- `commitkit-desktop/src-tauri` — Rust backend (SQLite migration, models, one new command)
- `commitkit-desktop` — TypeScript types, one new helper + tests, UI rewiring

The project has no Rust test harness, so Rust changes are verified with `cargo check` and manual smoke testing. TypeScript code on both server and desktop uses Vitest — TDD where practical.

Key fact discovered during design: the existing server route `POST /api/timer-assignments` ALREADY supports ad-hoc — it extracts `templateId = typeof snap.id === 'string' ? snap.id : null`. No endpoint change needed. But `splitTemplate` drops fields not declared in the registry, so `allow_cancel` MUST be added to `commitment-types.ts` registry or it will be silently stripped from `contract_snapshot`.

---

# Part A — Server changes

Strictly additive. Safe to ship independently — existing clients continue to work.

## Task 1: Add `allow_cancel` to the commitment-types registry

**Why first:** `splitTemplate` drops unknown fields. If we don't declare `allow_cancel` here, no payload sent to the server will preserve the flag — tests in later tasks would silently fail.

**Files:**
- Modify: `commitkit-server/src/domain/commitment-types.ts:45-62` (the `timer` entry in `registry`)
- Test: `commitkit-server/__tests__/commitment-types.test.ts`

- [ ] **Step 1: Write a failing test for `allow_cancel` preservation**

Append this block to `commitkit-server/__tests__/commitment-types.test.ts` inside the existing `describe('splitTemplate', ...)` block:

```typescript
it('preserves allow_cancel on timer templates (used by ad-hoc timers to lock cancellation)', () => {
  const { contract } = splitTemplate('timer', {
    name: 'Locked 30m',
    duration_minutes: 30,
    penalty_amount: 5,
    allow_cancel: false,
  });
  expect(contract.allow_cancel).toBe(false);
});
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
cd commitkit-server && pnpm test commitment-types
```

Expected: fails with `expected undefined to be false` — `allow_cancel` is dropped because it's not in the registry.

- [ ] **Step 3: Add `allow_cancel` to the timer registry**

Modify `commitkit-server/src/domain/commitment-types.ts`. Locate the `timer` entry (around line 45) and add `allow_cancel` to `contractFields`:

```typescript
  timer: {
    identityFields: ['name', 'color'],
    contractFields: {
      duration_minutes:                  { direction: 'scalar_up' },
      timer_count:                       { direction: 'scalar_up' },
      penalty_amount:                    { direction: 'scalar_up' },
      complete_by_time:                  { direction: 'scalar_down' },
      must_complete_before_distractions: { direction: 'bool_true_strict' },
      allow_deadline_extend:             { direction: 'bool_false_strict' },
      allow_unnamed_timers:              { direction: 'bool_false_strict' },
      // false (cannot cancel) is the stricter direction — matches
      // allow_deadline_extend's semantics.
      allow_cancel:                      { direction: 'bool_false_strict' },
      project_requirements:              { direction: 'structural' },
      list_ids:                          { direction: 'set_add_strict' },
    },
  },
```

- [ ] **Step 4: Run the test to confirm it passes**

```bash
cd commitkit-server && pnpm test commitment-types
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C commitkit-server add src/domain/commitment-types.ts __tests__/commitment-types.test.ts
git -C commitkit-server commit -m "Add allow_cancel to timer commitment-types registry"
```

---

## Task 2: Drizzle migration for `allow_cancel` on `timer_templates`

**Files:**
- Create: `commitkit-server/drizzle/0025_add_allow_cancel.sql`
- Create: `commitkit-server/drizzle/meta/0025_snapshot.json` (generated by `pnpm db:generate`)
- Modify: `commitkit-server/drizzle/meta/_journal.json` (auto-updated by the generate step)

- [ ] **Step 1: Update the schema definition**

Modify `commitkit-server/src/db/schema.ts` — locate the `timerTemplates` table definition (around line 130) and add the new column just before `created_at`:

```typescript
export const timerTemplates = pgTable('timer_templates', {
  id: uuid('id').primaryKey().defaultRandom(),
  user_id: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  client_id: varchar('client_id', { length: 255 }).notNull(),
  device_type: varchar('device_type', { length: 50 }).notNull().default('desktop'),
  name: varchar('name', { length: 255 }).notNull(),
  color: varchar('color', { length: 50 }),
  duration_minutes: integer('duration_minutes').notNull(),
  penalty_amount: decimal('penalty_amount', { precision: 10, scale: 2 }).notNull(),
  list_ids: text('list_ids').array(),
  timer_count: integer('timer_count').notNull().default(1),
  complete_by_time: varchar('complete_by_time', { length: 5 }),
  must_complete_before_distractions: boolean('must_complete_before_distractions').notNull().default(false),
  project_requirements: jsonb('project_requirements'),
  allow_unnamed_timers: boolean('allow_unnamed_timers').notNull().default(false),
  allow_deadline_extend: boolean('allow_deadline_extend').notNull().default(false),
  is_plan_requirement: boolean('is_plan_requirement').notNull().default(false),
  // Default true preserves existing template behavior (timers are cancellable
  // today). Ad-hoc timers set this to false to lock the cancel button and
  // rely on the unified failures cron to charge if abandoned.
  allow_cancel: boolean('allow_cancel').notNull().default(true),
  created_at: timestamp('created_at').notNull().defaultNow(),
  updated_at: timestamp('updated_at').notNull().defaultNow(),
}, (table) => ({
  userClientIdx: uniqueIndex('timer_templates_user_client_idx')
    .on(table.user_id, table.client_id),
}));
```

- [ ] **Step 2: Generate the Drizzle migration**

```bash
cd commitkit-server && pnpm drizzle-kit generate
```

Expected: creates `drizzle/0025_*.sql` and updates `drizzle/meta/*`. The SQL should contain approximately:

```sql
ALTER TABLE "timer_templates" ADD COLUMN "allow_cancel" boolean DEFAULT true NOT NULL;
```

If the file name isn't `0025_add_allow_cancel.sql`, rename it so the prefix matches (Drizzle allows renames — keep the numeric prefix).

- [ ] **Step 3: Apply the migration locally**

If you have a local/dev DB running:

```bash
cd commitkit-server && pnpm db:migrate
```

Expected: migration applied; no errors.

If no local DB is available, skip this step — the migration will run on deploy.

- [ ] **Step 4: Commit**

```bash
git -C commitkit-server add drizzle/ src/db/schema.ts
git -C commitkit-server commit -m "Add allow_cancel column to timer_templates"
```

---

## Task 3: Regression test — ad-hoc assignment POST preserves `allow_cancel`

Validates that a client can POST an ad-hoc timer (no `id` in snapshot) and the server persists `allow_cancel: false` into `contract_snapshot`. This is the contract the desktop code in Part C depends on.

**Files:**
- Create: `commitkit-server/__tests__/routes-timer-assignments-ad-hoc.test.ts`

- [ ] **Step 1: Write the failing test**

Create `commitkit-server/__tests__/routes-timer-assignments-ad-hoc.test.ts`:

```typescript
import { describe, it, expect, vi, beforeEach } from 'vitest';
import express from 'express';
import request from 'supertest';

const mocks = vi.hoisted(() => ({
  inserted: [] as any[],
}));

vi.mock('../src/db/index.js', () => ({
  db: {
    insert: () => ({
      values: (v: any) => ({
        returning: () => {
          const row = {
            ...v,
            id: 'new-assignment-id',
            created_at: new Date(),
            updated_at: new Date(),
          };
          mocks.inserted.push(row);
          return Promise.resolve([row]);
        },
      }),
    }),
    select: () => ({
      from: () => ({
        where: () => Promise.resolve([{ timezone: 'America/New_York' }]),
      }),
    }),
  },
}));

vi.mock('../src/middleware/auth.js', () => ({
  authenticateToken: (req: any, _res: any, next: any) => {
    req.userId = 'user-1';
    next();
  },
}));

const { default: router } = await import('../src/routes/timer-assignments.js');

const app = express();
app.use(express.json());
app.use('/api/timer-assignments', router);

beforeEach(() => {
  mocks.inserted = [];
});

describe('POST /api/timer-assignments (ad-hoc)', () => {
  it('accepts a snapshot with no id and stores template_id=null', async () => {
    const res = await request(app).post('/api/timer-assignments').send({
      date: '2026-04-21',
      stake_snapshot: 500,
      device_id: 'dev-1',
      template_snapshot: {
        name: 'Quick 30m timer',
        duration_minutes: 30,
        penalty_amount: 5,
        complete_by_time: '16:19',
        list_ids: ['list-uuid-1'],
        allow_cancel: false,
      },
    });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);

    const inserted = mocks.inserted[0];
    expect(inserted.type).toBe('timer');
    expect(inserted.template_id).toBeNull();
    expect(inserted.stake_cents).toBe(500);
    // allow_cancel must survive splitTemplate into contract_snapshot
    expect(inserted.contract_snapshot.allow_cancel).toBe(false);
    expect(inserted.contract_snapshot.duration_minutes).toBe(30);
    expect(inserted.identity_snapshot.name).toBe('Quick 30m timer');
  });

  it('continues to accept a snapshot with an id (existing template-scheduled flow)', async () => {
    const res = await request(app).post('/api/timer-assignments').send({
      date: '2026-04-21',
      stake_snapshot: 1000,
      device_id: 'dev-1',
      template_snapshot: {
        id: 'existing-template-uuid',
        name: 'Daily Deep Work',
        duration_minutes: 45,
        penalty_amount: 10,
        complete_by_time: '17:00',
      },
    });

    expect(res.status).toBe(200);
    expect(mocks.inserted[0].template_id).toBe('existing-template-uuid');
  });
});
```

- [ ] **Step 2: Run the test to confirm it passes**

Task 1 already added `allow_cancel` to the registry, so this test should pass on the first try. If Task 1 was skipped or reverted, this test will fail on the `contract_snapshot.allow_cancel` assertion.

```bash
cd commitkit-server && pnpm test routes-timer-assignments-ad-hoc
```

Expected: both tests pass.

- [ ] **Step 3: Commit**

```bash
git -C commitkit-server add __tests__/routes-timer-assignments-ad-hoc.test.ts
git -C commitkit-server commit -m "Test ad-hoc timer assignment POST preserves allow_cancel"
```

---

# Part B — Desktop data layer

## Task 4: SQLite migration v24 — add `allow_cancel` to both tables

**Files:**
- Modify: `commitkit-desktop/src-tauri/src/db.rs` (constant `LATEST_VERSION`, migration dispatch, new `migrate_to_v24` function)

- [ ] **Step 1: Bump `LATEST_VERSION` and register the dispatch**

Modify `commitkit-desktop/src-tauri/src/db.rs`:

Find the `LATEST_VERSION` constant (near the top of the file) and change it from 23 to 24:

```rust
const LATEST_VERSION: i64 = 24;
```

Find `run_migrations` (around line 57) and add the new case to the match inside the `for` loop:

```rust
            22 => migrate_to_v22(pool).await?,
            23 => migrate_to_v23(pool).await?,
            24 => migrate_to_v24(pool).await?,
            _ => unreachable!("Unknown migration version {}", v),
```

- [ ] **Step 2: Implement `migrate_to_v24`**

Append this function at the end of `db.rs` (after `migrate_to_v23`):

```rust
/// Version 24: add allow_cancel to timer_templates and timer_sessions.
///
/// Default true preserves today's behavior (all existing timers are
/// cancellable). Ad-hoc timers will insert with allow_cancel = 0 (false)
/// to lock the cancel button and rely on the unified commitment-failures
/// cron to charge the stake if the user abandons the session.
async fn migrate_to_v24(pool: &SqlitePool) -> Result<(), sqlx::Error> {
    // timer_templates
    let has_col: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('timer_templates') WHERE name = 'allow_cancel'"
    )
    .fetch_one(pool)
    .await?;

    if !has_col {
        sqlx::query("ALTER TABLE timer_templates ADD COLUMN allow_cancel INTEGER NOT NULL DEFAULT 1")
            .execute(pool)
            .await?;
    }

    // timer_sessions (denormalized so the running UI can read it without a template lookup —
    // ad-hoc sessions have no local template row at all)
    let has_col: bool = sqlx::query_scalar(
        "SELECT COUNT(*) > 0 FROM pragma_table_info('timer_sessions') WHERE name = 'allow_cancel'"
    )
    .fetch_one(pool)
    .await?;

    if !has_col {
        sqlx::query("ALTER TABLE timer_sessions ADD COLUMN allow_cancel INTEGER NOT NULL DEFAULT 1")
            .execute(pool)
            .await?;
    }

    sqlx::query("INSERT OR REPLACE INTO settings (key, value) VALUES ('schema_version', '24')")
        .execute(pool)
        .await?;

    Ok(())
}
```

- [ ] **Step 3: Verify compilation**

```bash
cd commitkit-desktop/src-tauri && cargo check
```

Expected: compiles cleanly. Warnings about unused symbols are fine at this stage.

- [ ] **Step 4: Apply the migration locally and verify**

```bash
cd commitkit-desktop && pnpm tauri:dev
```

Let the app boot once, then quit. Verify the column exists:

```bash
sqlite3 ~/Library/Application\ Support/CommitKit/commitkit.db \
  "PRAGMA table_info(timer_sessions);" | grep allow_cancel
sqlite3 ~/Library/Application\ Support/CommitKit/commitkit.db \
  "PRAGMA table_info(timer_templates);" | grep allow_cancel
```

Expected: each command outputs a row containing `allow_cancel|INTEGER|1` (not null, default 1).

- [ ] **Step 5: Commit**

```bash
git -C commitkit-desktop add src-tauri/src/db.rs
git -C commitkit-desktop commit -m "Add allow_cancel column to timer_templates and timer_sessions (v24)"
```

---

## Task 5: Rust models — add `allow_cancel` to `TimerTemplate`, `TimerSession`, `StartTimerInput`

**Files:**
- Modify: `commitkit-desktop/src-tauri/src/models.rs` (three structs, around lines 344, 363, 392)

- [ ] **Step 1: Update `TimerSession`**

Find `pub struct TimerSession` (around line 344) in `commitkit-desktop/src-tauri/src/models.rs` and add `allow_cancel`:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimerSession {
    pub id: i64,
    pub duration_minutes: i64,
    pub penalty_amount: f64,
    pub apps: Vec<String>,
    pub domains: Vec<String>,
    pub list_ids: Vec<i64>,
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub status: String,
    pub evaluation_passed: Option<bool>,
    pub evaluation_summary: Option<String>,
    pub violation_id: Option<i64>,
    pub project_id: Option<i64>,
    pub assignment_id: Option<String>,
    #[serde(default = "default_allow_cancel")]
    pub allow_cancel: bool,
    pub created_at: i64,
}
```

- [ ] **Step 2: Update `StartTimerInput`**

Find `pub struct StartTimerInput` (around line 363) and add `allow_cancel`:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StartTimerInput {
    pub duration_minutes: i64,
    pub penalty_amount: f64,
    pub apps: Vec<String>,
    pub domains: Vec<String>,
    pub list_ids: Vec<i64>,
    pub project_id: Option<i64>,
    pub assignment_id: Option<String>,
    #[serde(default = "default_allow_cancel")]
    pub allow_cancel: bool,
}
```

- [ ] **Step 3: Update `TimerTemplate`**

Find `pub struct TimerTemplate` (around line 392) and add `allow_cancel`:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimerTemplate {
    pub id: i64,
    pub uuid: Option<String>,
    pub name: String,
    pub color: Option<String>,
    pub duration_minutes: i64,
    pub penalty_amount: f64,
    pub list_ids: Vec<i64>,
    pub timer_count: i64,
    pub complete_by_time: Option<String>,
    pub must_complete_before_distractions: bool,
    pub project_requirements: Vec<ProjectRequirement>,
    pub allow_unnamed_timers: bool,
    pub allow_deadline_extend: bool,
    pub is_plan_requirement: bool,
    #[serde(default = "default_allow_cancel")]
    pub allow_cancel: bool,
    pub server_id: Option<String>,
    pub sync_status: String,
    pub created_at: i64,
    pub updated_at: i64,
}
```

- [ ] **Step 4: Add the default helper**

At the top of `models.rs`, after the imports and before the first struct, add:

```rust
// Default for `allow_cancel` when deserializing payloads that predate the
// field (existing clients, older assignment snapshots). True = cancellable,
// which preserves current behavior.
fn default_allow_cancel() -> bool {
    true
}
```

- [ ] **Step 5: Verify compilation**

```bash
cd commitkit-desktop/src-tauri && cargo check
```

Expected: compiles. The compiler will flag downstream errors in `db_operations.rs` and `commands.rs` — those are addressed in Task 6.

- [ ] **Step 6: Commit**

```bash
git -C commitkit-desktop add src-tauri/src/models.rs
git -C commitkit-desktop commit -m "Add allow_cancel to TimerSession, TimerTemplate, StartTimerInput"
```

---

## Task 6: Desktop db_operations — read + write `allow_cancel`

Three reader functions currently fetch the same column set and map it to `TimerSession`; all three need the new column. One writer (`create_timer_session`) stores it. Template reader/writer functions likely also need updating.

**Files:**
- Modify: `commitkit-desktop/src-tauri/src/db_operations.rs` — `create_timer_session`, `get_timer_session`, `get_active_timer_session`, `get_timer_sessions`
- Modify: `commitkit-desktop/src-tauri/src/db_operations.rs` — any `TimerTemplate` reader/writer that selects/inserts all template columns

- [ ] **Step 1: Update `create_timer_session`**

Modify the function around line 1625 in `db_operations.rs`:

```rust
pub async fn create_timer_session(
    pool: &SqlitePool,
    input: &StartTimerInput,
) -> Result<TimerSession, String> {
    let now = Utc::now().timestamp();
    let apps_json = serde_json::to_string(&input.apps).unwrap_or_else(|_| "[]".to_string());
    let domains_json = serde_json::to_string(&input.domains).unwrap_or_else(|_| "[]".to_string());
    let list_ids_json = serde_json::to_string(&input.list_ids).unwrap_or_else(|_| "[]".to_string());

    let id: i64 = sqlx::query_scalar(
        "INSERT INTO timer_sessions (duration_minutes, penalty_amount, apps, domains, list_ids, started_at, status, project_id, assignment_id, allow_cancel, created_at)
         VALUES (?, ?, ?, ?, ?, ?, 'running', ?, ?, ?, ?)
         RETURNING id"
    )
    .bind(input.duration_minutes)
    .bind(input.penalty_amount)
    .bind(&apps_json)
    .bind(&domains_json)
    .bind(&list_ids_json)
    .bind(now)
    .bind(input.project_id)
    .bind(&input.assignment_id)
    .bind(input.allow_cancel as i64)
    .bind(now)
    .fetch_one(pool)
    .await
    .map_err(|e| format!("Failed to create timer session: {}", e))?;

    get_timer_session(pool, id).await
}
```

- [ ] **Step 2: Update all three `TimerSession` reader functions**

Three functions starting around line 1655 (`get_timer_session`, `get_active_timer_session`, `get_timer_sessions`) share the same shape. For each one:

1. Add `allow_cancel` to the SELECT statement (position matters — add at end, after `assignment_id`, before `created_at`)
2. Widen the tuple type to add one more `i64` slot at the matching position
3. Map the new tuple field to `allow_cancel: row.N != 0`

Here is the complete updated `get_timer_session`:

```rust
pub async fn get_timer_session(pool: &SqlitePool, id: i64) -> Result<TimerSession, String> {
    let row = sqlx::query_as::<_, (
        i64, i64, f64, String, String, String, i64, Option<i64>,
        String, Option<bool>, Option<String>, Option<i64>, Option<i64>, Option<String>, i64, i64,
    )>(
        "SELECT id, duration_minutes, penalty_amount, apps, domains, list_ids,
                started_at, ended_at, status, evaluation_passed, evaluation_summary,
                violation_id, project_id, assignment_id, allow_cancel, created_at
         FROM timer_sessions WHERE id = ?"
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .map_err(|e| format!("Timer session not found: {}", e))?;

    Ok(TimerSession {
        id: row.0,
        duration_minutes: row.1,
        penalty_amount: row.2,
        apps: parse_json_vec_string(&row.3),
        domains: parse_json_vec_string(&row.4),
        list_ids: parse_json_vec_i64(&row.5),
        started_at: row.6,
        ended_at: row.7,
        status: row.8,
        evaluation_passed: row.9,
        evaluation_summary: row.10,
        violation_id: row.11,
        project_id: row.12,
        assignment_id: row.13,
        allow_cancel: row.14 != 0,
        created_at: row.15,
    })
}
```

Apply the same shape (SELECT `... allow_cancel, created_at ...`, tuple gets an extra `i64`, `allow_cancel: row.14 != 0`, `created_at: row.15`) to `get_active_timer_session` and `get_timer_sessions`. Only the WHERE/ORDER clauses differ — keep those.

- [ ] **Step 3: Update `TimerTemplate` reader/writer functions**

Grep for the template column reads and updates:

```bash
cd commitkit-desktop && grep -n "duration_minutes, penalty_amount" src-tauri/src/db_operations.rs
```

Expected: several hits. For each function that reads timer_template rows, add `allow_cancel` to the SELECT and map it to the struct (`allow_cancel: row.N != 0`). For each writer that inserts or updates timer_template rows, add `allow_cancel` to the column list, `?` placeholder, and bind call.

If a reader has a shape like `SELECT id, uuid, name, ... FROM timer_templates`, insert `allow_cancel` just before `created_at` (matching the position used in the SQLite migration's `ALTER TABLE`).

If an existing `CreateTimerTemplateInput` or `UpdateTimerTemplateInput` path does not yet include `allow_cancel`, that's fine for this task — the default `1` takes care of it. We are NOT yet exposing template-level editing of this flag (that's Task 17). For now: any writer that the compiler complains about only needs to supply `input.allow_cancel` if the struct is updated, or just leave it — the DB default handles unset cases.

- [ ] **Step 4: Verify compilation**

```bash
cd commitkit-desktop/src-tauri && cargo check
```

Expected: compiles cleanly. If there are errors, they'll be in places that construct `TimerSession` or `TimerTemplate` literals — add `allow_cancel: true` (the preserve-existing-behavior default) at each such site.

- [ ] **Step 5: Commit**

```bash
git -C commitkit-desktop add src-tauri/src/db_operations.rs
git -C commitkit-desktop commit -m "Read and write allow_cancel in timer session / template db ops"
```

---

## Task 7: TypeScript types — mirror the Rust struct changes

**Files:**
- Modify: `commitkit-desktop/lib/types.ts` (lines 339, 413, 431 area)

- [ ] **Step 1: Update `TimerTemplate`, `CreateTimerTemplateInput`, `UpdateTimerTemplateInput`**

Modify `commitkit-desktop/lib/types.ts`. For each of the three interfaces above (around lines 339, 360, 375), add `allow_cancel: boolean` just before the timestamp/metadata fields. Example for `TimerTemplate`:

```typescript
export interface TimerTemplate {
  id: number
  uuid: string | null
  name: string
  color: string | null
  duration_minutes: number
  penalty_amount: number
  list_ids: number[]
  timer_count: number
  complete_by_time: string | null
  must_complete_before_distractions: boolean
  project_requirements: ProjectRequirement[]
  allow_unnamed_timers: boolean
  allow_deadline_extend: boolean
  is_plan_requirement: boolean
  allow_cancel: boolean
  server_id: string | null
  sync_status: string
  created_at: number
  updated_at: number
}
```

For `CreateTimerTemplateInput` and `UpdateTimerTemplateInput`, add `allow_cancel: boolean` in the same relative position (after `is_plan_requirement`, before any trailing fields).

- [ ] **Step 2: Update `TimerSession`**

Around line 413:

```typescript
export interface TimerSession {
  id: number
  duration_minutes: number
  penalty_amount: number
  apps: string[]
  domains: string[]
  list_ids: number[]
  started_at: number
  ended_at: number | null
  status: "running" | "completed" | "failed" | "cancelled"
  evaluation_passed: boolean | null
  evaluation_summary: string | null
  violation_id: number | null
  project_id: number | null
  assignment_id: string | null
  allow_cancel: boolean
  created_at: number
}
```

- [ ] **Step 3: Update `StartTimerInput`**

Around line 431:

```typescript
export interface StartTimerInput {
  duration_minutes: number
  penalty_amount: number
  apps: string[]
  domains: string[]
  list_ids: number[]
  project_id?: number
  assignment_id?: string
  allow_cancel?: boolean
}
```

The `?` is intentional — `StartTimerInput` already has optional fields; existing callers don't need to supply `allow_cancel` unless they want it non-default.

- [ ] **Step 4: Type-check**

```bash
cd commitkit-desktop && pnpm type-check
```

Expected: failures only in places that construct `TimerTemplate` or `TimerSession` literals (test fixtures, mock data). For each such site, add `allow_cancel: true`. No runtime behavior change — we are preserving the existing default.

- [ ] **Step 5: Commit**

```bash
git -C commitkit-desktop add lib/types.ts $(git -C commitkit-desktop diff --name-only | grep -E '\.(ts|tsx)$')
git -C commitkit-desktop commit -m "Mirror allow_cancel field in TypeScript timer types"
```

---

# Part C — Ad-hoc path

## Task 8: TS helper — compute `(date, complete_by_time)` from duration

The server's `computeDueAt(date, completeBy, tz)` expects both a date string and an `HH:MM` time. For an ad-hoc timer, the desktop must derive those from `now + duration + grace` and handle the midnight-crossing case. Pure-function, easy to unit-test.

**Files:**
- Create: `commitkit-desktop/lib/ad-hoc-timer.ts`
- Create: `commitkit-desktop/__tests__/ad-hoc-timer.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `commitkit-desktop/__tests__/ad-hoc-timer.test.ts`:

```typescript
import { describe, it, expect } from 'vitest';
import { computeAdHocDeadline } from '../lib/ad-hoc-timer';

describe('computeAdHocDeadline', () => {
  it('returns today\'s date and the correct HH:MM for a mid-day timer', () => {
    // 14:30 local, 30 min duration, 2 min grace → 15:02 today
    const now = new Date(2026, 3, 21, 14, 30, 0); // April 21 2026, 14:30
    const result = computeAdHocDeadline(30, 2, now);
    expect(result.date).toBe('2026-04-21');
    expect(result.completeByTime).toBe('15:02');
  });

  it('rolls the date forward when the deadline crosses midnight', () => {
    // 23:45, 30 min duration, 2 min grace → 00:17 next day
    const now = new Date(2026, 3, 21, 23, 45, 0);
    const result = computeAdHocDeadline(30, 2, now);
    expect(result.date).toBe('2026-04-22');
    expect(result.completeByTime).toBe('00:17');
  });

  it('handles the month boundary', () => {
    // Apr 30 23:50 + 30m + 2m grace = May 1 00:22
    const now = new Date(2026, 3, 30, 23, 50, 0);
    const result = computeAdHocDeadline(30, 2, now);
    expect(result.date).toBe('2026-05-01');
    expect(result.completeByTime).toBe('00:22');
  });

  it('pads hours and minutes to two digits', () => {
    // 05:00 + 5 min + 2 min grace = 05:07
    const now = new Date(2026, 3, 21, 5, 0, 0);
    const result = computeAdHocDeadline(5, 2, now);
    expect(result.completeByTime).toBe('05:07');
  });

  it('defaults graceMinutes to 2 when omitted', () => {
    const now = new Date(2026, 3, 21, 10, 0, 0);
    const result = computeAdHocDeadline(15, undefined, now);
    // 10:00 + 15 + 2 = 10:17
    expect(result.completeByTime).toBe('10:17');
  });
});
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
cd commitkit-desktop && pnpm test ad-hoc-timer
```

Expected: all fail with "Cannot find module '../lib/ad-hoc-timer'".

- [ ] **Step 3: Implement the helper**

Create `commitkit-desktop/lib/ad-hoc-timer.ts`:

```typescript
// Helpers for ad-hoc timer scheduling. The server's existing
// POST /api/timer-assignments expects a (date, complete_by_time) pair and
// computes due_at from them. Ad-hoc timers derive those from the current
// moment plus duration plus a small grace buffer (so the UI has a chance to
// report completion before the daily failures cron considers the assignment
// overdue). Keep pure — no Date.now() reads — so callers can test.

export interface AdHocDeadline {
  date: string;          // YYYY-MM-DD in the user's local calendar
  completeByTime: string; // HH:MM (24h), matches server's `complete_by_time` format
}

export function computeAdHocDeadline(
  durationMinutes: number,
  graceMinutes: number = 2,
  now: Date = new Date(),
): AdHocDeadline {
  const deadline = new Date(now.getTime() + (durationMinutes + graceMinutes) * 60_000);

  const year = deadline.getFullYear();
  const month = String(deadline.getMonth() + 1).padStart(2, '0');
  const day = String(deadline.getDate()).padStart(2, '0');
  const hours = String(deadline.getHours()).padStart(2, '0');
  const minutes = String(deadline.getMinutes()).padStart(2, '0');

  return {
    date: `${year}-${month}-${day}`,
    completeByTime: `${hours}:${minutes}`,
  };
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
cd commitkit-desktop && pnpm test ad-hoc-timer
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git -C commitkit-desktop add lib/ad-hoc-timer.ts __tests__/ad-hoc-timer.test.ts
git -C commitkit-desktop commit -m "Add ad-hoc timer deadline helper"
```

---

## Task 9: Rust command `start_ad_hoc_timer`

This command orchestrates the full start flow: create server assignment, then create local session with `assignment_id` wired up and `allow_cancel = false`.

**Files:**
- Modify: `commitkit-desktop/src-tauri/src/commands.rs` (append the new command)
- Modify: `commitkit-desktop/src-tauri/src/lib.rs` (register in invoke_handler)

- [ ] **Step 1: Add the command**

Append to `commitkit-desktop/src-tauri/src/commands.rs`. Find a reasonable location near the other timer commands (after `start_timer`, around line 1403):

```rust
#[tauri::command]
pub async fn start_ad_hoc_timer(
    pool: State<'_, SqlitePool>,
    duration_minutes: i64,
    penalty_amount: f64,
    list_ids: Vec<i64>,
    project_id: Option<i64>,
    date: String,
    complete_by_time: String,
) -> Result<TimerSession, String> {
    // Cancel any existing running timer (matches start_timer's behavior).
    if let Some(active) = db_operations::get_active_timer_session(&pool).await? {
        db_operations::cancel_timer_session(&pool, active.id).await?;
    }

    let user = db_operations::get_user(&pool)
        .await?
        .ok_or("Not logged in")?;
    let device_id = db_operations::get_setting(&pool, "device_id")
        .await?
        .unwrap_or_default();

    // Resolve local list IDs to server UUIDs so the snapshot matches what the
    // server expects. build_local_to_list_uuid_map is the same helper used by
    // the template sync path.
    let list_uuid_map = db_operations::build_local_to_list_uuid_map(&pool).await?;
    let list_uuids: Vec<String> = list_ids
        .iter()
        .filter_map(|id| list_uuid_map.get(id).cloned())
        .collect();

    // Build a minimal template_snapshot. No `id` field — server treats that
    // as the ad-hoc signal and sets template_id = null.
    let stake_cents = (penalty_amount * 100.0).round() as i64;
    let display_name = format!("Quick {}m timer", duration_minutes);
    let snapshot = serde_json::json!({
        "name": display_name,
        "duration_minutes": duration_minutes,
        "timer_count": 1,
        "penalty_amount": penalty_amount,
        "complete_by_time": complete_by_time,
        "list_ids": list_uuids,
        "allow_cancel": false,
    });

    // POST to server. Returns the created assignment.
    let api = ApiClient::new(Some(user.auth_token));
    let body = serde_json::json!({
        "date": date,
        "template_snapshot": snapshot,
        "stake_snapshot": stake_cents,
        "device_id": device_id,
    });
    let resp = api.create_timer_assignment(body).await?;
    let assignment_id = resp.timer_assignment.id.clone();

    // Create the local session linked to the assignment.
    let input = StartTimerInput {
        duration_minutes,
        penalty_amount,
        apps: Vec::new(),
        domains: Vec::new(),
        list_ids,
        project_id,
        assignment_id: Some(assignment_id),
        allow_cancel: false,
    };
    let session = db_operations::create_timer_session(&pool, &input).await?;

    // Push rules so the monitor starts enforcing the distraction lists.
    rule_pusher::push_domain_rules_background(pool.inner().clone());

    Ok(session)
}
```

**Note on `build_local_to_list_uuid_map`:** If this helper does not already exist under that exact name, grep for the actual function that maps local list IDs to server UUIDs (`list_uuid_to_local_map` has the inverse name). CLAUDE.md mentions both directions exist. If the name differs, substitute it.

- [ ] **Step 2: Register in `lib.rs`**

Modify `commitkit-desktop/src-tauri/src/lib.rs` around line 254 (where `start_timer` is registered). Add `start_ad_hoc_timer` in the same block:

```rust
            // Timer
            commands::start_timer,
            commands::start_ad_hoc_timer,
            commands::complete_timer,
```

- [ ] **Step 3: Verify compilation**

```bash
cd commitkit-desktop/src-tauri && cargo check
```

Expected: compiles. If `build_local_to_list_uuid_map` is under a different name, `cargo check` will flag it — fix the call site.

- [ ] **Step 4: Commit**

```bash
git -C commitkit-desktop add src-tauri/src/commands.rs src-tauri/src/lib.rs
git -C commitkit-desktop commit -m "Add start_ad_hoc_timer Tauri command"
```

---

## Task 10: TS wrapper for `start_ad_hoc_timer`

**Files:**
- Modify: `commitkit-desktop/lib/tauri.ts` (add after the existing `startTimer` wrapper, around line 463)

- [ ] **Step 1: Add the wrapper**

Modify `commitkit-desktop/lib/tauri.ts`. Locate `export async function startTimer` (around line 463) and add a new export right after it:

```typescript
export interface StartAdHocTimerInput {
  duration_minutes: number
  penalty_amount: number
  list_ids: number[]
  project_id?: number
  date: string
  complete_by_time: string
}

export async function startAdHocTimer(input: StartAdHocTimerInput): Promise<TimerSession> {
  return invoke("start_ad_hoc_timer", {
    durationMinutes: input.duration_minutes,
    penaltyAmount: input.penalty_amount,
    listIds: input.list_ids,
    projectId: input.project_id,
    date: input.date,
    completeByTime: input.complete_by_time,
  })
}
```

Note: Tauri converts Rust `snake_case` parameter names to JavaScript `camelCase` in the `invoke` call, so the keys on the right side of the object literal must be camelCase.

- [ ] **Step 2: Type-check**

```bash
cd commitkit-desktop && pnpm type-check
```

Expected: passes.

- [ ] **Step 3: Commit**

```bash
git -C commitkit-desktop add lib/tauri.ts
git -C commitkit-desktop commit -m "Add startAdHocTimer tauri wrapper"
```

---

# Part D — Desktop UI

## Task 11: Rewrite `timer-view.tsx` as a single-timer ad-hoc dialog

The existing `components/timer/timer-view.tsx` has most of the scaffolding (preset buttons, list/project selection, running view, result view) but is built around multi-block sessions tied to templates. The spec scopes v1 to single ad-hoc timers with server-backed assignments. Cleanest path: replace the contents with a focused implementation.

**Files:**
- Modify: `commitkit-desktop/components/timer/timer-view.tsx` — full rewrite

- [ ] **Step 1: Replace the file contents**

Overwrite `commitkit-desktop/components/timer/timer-view.tsx`:

```tsx
"use client"

import { useEffect, useState, useCallback, useRef } from "react"
import type { TimerSession, AppList, Project, TimerEvaluationResult } from "@/lib/types"
import * as tauri from "@/lib/tauri"
import { toast } from "sonner"
import { Play, Square, CheckCircle, XCircle, Lock } from "lucide-react"
import { computeAdHocDeadline } from "@/lib/ad-hoc-timer"

type ViewState = "setup" | "running" | "result"

const DURATION_PRESETS = [15, 25, 45, 60]
const PENALTY_PRESETS = [5, 10, 25]

interface TimerViewProps {
  onClose?: () => void
}

export function TimerView({ onClose }: TimerViewProps = {}) {
  // Setup state
  const [durationMinutes, setDurationMinutes] = useState(25)
  const [penaltyAmount, setPenaltyAmount] = useState(10)
  const [lists, setLists] = useState<AppList[]>([])
  const [selectedListIds, setSelectedListIds] = useState<number[]>([])
  const [projects, setProjects] = useState<Project[]>([])
  const [selectedProjectId, setSelectedProjectId] = useState<number | undefined>(undefined)

  // Timer state
  const [viewState, setViewState] = useState<ViewState>("setup")
  const [activeSession, setActiveSession] = useState<TimerSession | null>(null)
  const [secondsRemaining, setSecondsRemaining] = useState(0)
  const [evaluating, setEvaluating] = useState(false)
  const [loading, setLoading] = useState(true)
  const [result, setResult] = useState<TimerEvaluationResult | null>(null)
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null)

  const loadData = useCallback(async () => {
    try {
      const [listsData, projectsData, active] = await Promise.all([
        tauri.getLists(),
        tauri.getProjects(),
        tauri.getActiveTimer(),
      ])
      setLists(listsData)
      setProjects(projectsData)
      if (listsData.length > 0 && selectedListIds.length === 0) {
        setSelectedListIds(listsData.map((l) => l.id))
      }
      if (active) {
        setActiveSession(active)
        const elapsed = Math.floor(Date.now() / 1000) - active.started_at
        const totalSeconds = active.duration_minutes * 60
        const remaining = Math.max(0, totalSeconds - elapsed)
        if (remaining <= 0) {
          await handleComplete(active.id)
        } else {
          setSecondsRemaining(remaining)
          setViewState("running")
        }
      }
    } catch (e) {
      console.error("Failed to load timer data:", e)
    } finally {
      setLoading(false)
    }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { loadData() }, [loadData])

  // Countdown ticker
  useEffect(() => {
    if (viewState !== "running") {
      if (intervalRef.current) clearInterval(intervalRef.current)
      return
    }
    intervalRef.current = setInterval(() => {
      setSecondsRemaining((prev) => {
        if (prev <= 1) {
          if (intervalRef.current) clearInterval(intervalRef.current)
          if (activeSession) handleComplete(activeSession.id)
          return 0
        }
        return prev - 1
      })
    }, 1000)
    return () => { if (intervalRef.current) clearInterval(intervalRef.current) }
  }, [viewState, activeSession]) // eslint-disable-line react-hooks/exhaustive-deps

  const canStart = selectedListIds.length > 0 && selectedProjectId !== undefined

  const handleStart = async () => {
    if (!canStart) return
    try {
      const deadline = computeAdHocDeadline(durationMinutes, 2)
      const session = await tauri.startAdHocTimer({
        duration_minutes: durationMinutes,
        penalty_amount: penaltyAmount,
        list_ids: selectedListIds,
        project_id: selectedProjectId,
        date: deadline.date,
        complete_by_time: deadline.completeByTime,
      })
      setActiveSession(session)
      setSecondsRemaining(durationMinutes * 60)
      setViewState("running")
    } catch (e) {
      toast.error("Failed to start timer: " + e)
    }
  }

  const handleComplete = async (sessionId: number) => {
    setEvaluating(true)
    try {
      const evalResult = await tauri.completeTimer(sessionId)
      setResult(evalResult)
      setActiveSession(null)
      setViewState("result")
    } catch (e) {
      toast.error("Evaluation failed: " + e)
      setViewState("setup")
      setActiveSession(null)
    } finally {
      setEvaluating(false)
    }
  }

  const toggleList = (id: number) => {
    setSelectedListIds((prev) =>
      prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]
    )
  }

  const formatTime = (totalSeconds: number) => {
    const m = Math.floor(totalSeconds / 60)
    const s = totalSeconds % 60
    return `${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`
  }

  if (loading) {
    return <div className="py-20 text-center text-muted-foreground">Loading...</div>
  }

  // ─── Setup ─────────────────────────────────────────────────────────────
  if (viewState === "setup") {
    return (
      <div className="mx-auto max-w-lg space-y-6">
        <div className="text-center">
          <h2 className="text-2xl font-bold">Focus Now</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Lock in a staked timer. Once started, it can't be cancelled.
          </p>
        </div>

        <div className="space-y-3">
          <label className="text-sm font-medium">Duration</label>
          <div className="flex gap-2">
            {DURATION_PRESETS.map((d) => (
              <button
                key={d}
                onClick={() => setDurationMinutes(d)}
                className={`flex-1 rounded-md border px-3 py-2 text-sm font-medium transition-colors ${
                  durationMinutes === d
                    ? "border-primary bg-primary text-primary-foreground"
                    : "border-border hover:bg-accent"
                }`}
              >
                {d}m
              </button>
            ))}
          </div>
          <div className="flex items-center gap-2">
            <span className="text-sm text-muted-foreground">Custom:</span>
            <input
              type="number"
              min={1}
              max={180}
              value={durationMinutes}
              onChange={(e) => setDurationMinutes(Math.max(1, parseInt(e.target.value) || 1))}
              className="w-20 rounded-md border border-border bg-background px-2 py-1 text-sm"
            />
            <span className="text-sm text-muted-foreground">minutes</span>
          </div>
        </div>

        <div className="space-y-3">
          <label className="text-sm font-medium">Stake</label>
          <div className="flex gap-2">
            {PENALTY_PRESETS.map((p) => (
              <button
                key={p}
                onClick={() => setPenaltyAmount(p)}
                className={`flex-1 rounded-md border px-3 py-2 text-sm font-medium transition-colors ${
                  penaltyAmount === p
                    ? "border-primary bg-primary text-primary-foreground"
                    : "border-border hover:bg-accent"
                }`}
              >
                ${p}
              </button>
            ))}
          </div>
          <div className="flex items-center gap-2">
            <span className="text-sm text-muted-foreground">Custom: $</span>
            <input
              type="number"
              min={1}
              max={1000}
              value={penaltyAmount}
              onChange={(e) => setPenaltyAmount(Math.max(1, parseInt(e.target.value) || 1))}
              className="w-20 rounded-md border border-border bg-background px-2 py-1 text-sm"
            />
          </div>
        </div>

        <div className="space-y-2">
          <label className="text-sm font-medium">
            Project <span className="text-destructive">*</span>
          </label>
          {projects.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              Create a project first to use ad-hoc timers.
            </p>
          ) : (
            <select
              value={selectedProjectId ?? ""}
              onChange={(e) =>
                setSelectedProjectId(e.target.value ? Number(e.target.value) : undefined)
              }
              className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            >
              <option value="">Select a project...</option>
              {projects.map((p) => (
                <option key={p.id} value={p.id}>{p.name}</option>
              ))}
            </select>
          )}
        </div>

        {lists.length > 0 && (
          <div className="space-y-3">
            <label className="text-sm font-medium">
              Distraction lists <span className="text-destructive">*</span>
            </label>
            <div className="space-y-2">
              {lists.map((list) => (
                <label
                  key={list.id}
                  className="flex cursor-pointer items-center gap-3 rounded-md border border-border p-3 transition-colors hover:bg-accent/50"
                >
                  <input
                    type="checkbox"
                    checked={selectedListIds.includes(list.id)}
                    onChange={() => toggleList(list.id)}
                    className="h-4 w-4 rounded border-border"
                  />
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-medium">{list.name}</p>
                    <p className="truncate text-xs text-muted-foreground">
                      {[...list.apps, ...list.domains].slice(0, 5).join(", ")}
                      {list.apps.length + list.domains.length > 5 && "..."}
                    </p>
                  </div>
                </label>
              ))}
            </div>
          </div>
        )}

        <button
          onClick={handleStart}
          disabled={!canStart}
          className="flex w-full items-center justify-center gap-2 rounded-md bg-primary py-3 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50"
        >
          <Play className="h-4 w-4" />
          Start {durationMinutes}m timer (${penaltyAmount} at stake)
        </button>
      </div>
    )
  }

  // ─── Running ───────────────────────────────────────────────────────────
  if (viewState === "running") {
    const totalSeconds = (activeSession?.duration_minutes ?? durationMinutes) * 60
    const progress = totalSeconds > 0 ? ((totalSeconds - secondsRemaining) / totalSeconds) * 100 : 0

    return (
      <div className="mx-auto flex max-w-lg flex-col items-center justify-center space-y-8 py-16">
        {evaluating ? (
          <>
            <div className="font-mono text-6xl font-bold tracking-wider">00:00</div>
            <p className="animate-pulse text-muted-foreground">Evaluating...</p>
          </>
        ) : (
          <>
            <div className="font-mono text-7xl font-bold tracking-wider">
              {formatTime(secondsRemaining)}
            </div>
            <div className="h-2 w-full rounded-full bg-muted">
              <div
                className="h-full rounded-full bg-primary transition-all duration-1000"
                style={{ width: `${progress}%` }}
              />
            </div>
            <div className="flex items-center gap-4 text-sm text-muted-foreground">
              <span>{activeSession?.duration_minutes}m session</span>
              <span>·</span>
              <span>${activeSession?.penalty_amount} at stake</span>
            </div>
            {/* Cancel button only shown if session is cancellable. Ad-hoc
                timers set allow_cancel=false, so no escape hatch is
                rendered here. */}
            {activeSession?.allow_cancel ? (
              <button
                onClick={async () => {
                  if (!activeSession) return
                  try {
                    await tauri.cancelTimer(activeSession.id)
                    setActiveSession(null)
                    setViewState("setup")
                    setSecondsRemaining(0)
                  } catch (e) {
                    toast.error("Failed to cancel: " + e)
                  }
                }}
                className="flex items-center gap-2 rounded-md border border-border px-4 py-2 text-sm text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
              >
                <Square className="h-4 w-4" />
                Cancel
              </button>
            ) : (
              <p className="flex items-center gap-2 text-xs text-muted-foreground">
                <Lock className="h-3 w-3" />
                Stake locked — complete or be charged
              </p>
            )}
          </>
        )}
      </div>
    )
  }

  // ─── Result ────────────────────────────────────────────────────────────
  return (
    <div className="mx-auto flex max-w-lg flex-col items-center space-y-6 py-16">
      {result?.passed ? (
        <>
          <CheckCircle className="h-16 w-16 text-green-500" />
          <h2 className="text-2xl font-bold">Timer Passed</h2>
        </>
      ) : (
        <>
          <XCircle className="h-16 w-16 text-red-500" />
          <h2 className="text-2xl font-bold">Timer Failed</h2>
          {result?.violation_id && (
            <p className="text-sm text-red-400">
              Violation created — ${penaltyAmount} charge
            </p>
          )}
        </>
      )}
      {result?.summary && (
        <div className="w-full rounded-md border border-border p-4">
          <pre className="whitespace-pre-wrap text-sm text-muted-foreground">{result.summary}</pre>
        </div>
      )}
      <button
        onClick={() => { onClose?.() }}
        className="rounded-md bg-primary px-6 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
      >
        Done
      </button>
    </div>
  )
}
```

**Note on removed props:** The old `initialTemplate` / `onConsumeTemplate` props are gone — no callers use them (the component was unwired). If your search turns up a dead import, remove it.

- [ ] **Step 2: Check that no other files import the old API**

```bash
cd commitkit-desktop && grep -rn "initialTemplate\|onConsumeTemplate" --include='*.tsx' --include='*.ts'
```

Expected: no hits, or only the file we just rewrote (we already removed those props).

- [ ] **Step 3: Type-check**

```bash
cd commitkit-desktop && pnpm type-check
```

Expected: passes.

- [ ] **Step 4: Commit**

```bash
git -C commitkit-desktop add components/timer/timer-view.tsx
git -C commitkit-desktop commit -m "Rewrite TimerView as single-timer ad-hoc modal"
```

---

## Task 12: `session-runner.tsx` — conditionally hide Cancel

Template-scheduled timers also use `SessionRunner`, and now they can theoretically have `allow_cancel = false` (via the template flag added in Task 5, exposed in the form later in Task 17). The cancel button in `SessionRunner` must respect the session's flag.

**Files:**
- Modify: `commitkit-desktop/components/timer/session-runner.tsx` (around line 250 — the cancel button)

- [ ] **Step 1: Locate the cancel button**

```bash
cd commitkit-desktop && grep -n "Cancel" components/timer/session-runner.tsx
```

Pick out the block that renders the Cancel button in the running phase. The exact line may vary.

- [ ] **Step 2: Wrap the button in an `allow_cancel` check**

Change the cancel button block from roughly:

```tsx
<button onClick={handleCancel} ...>
  <Square className="h-4 w-4" />
  Cancel
</button>
```

to:

```tsx
{session?.allow_cancel !== false ? (
  <button onClick={handleCancel} ...>
    <Square className="h-4 w-4" />
    Cancel
  </button>
) : (
  <p className="flex items-center gap-2 text-xs text-muted-foreground">
    <Lock className="h-3 w-3" />
    Stake locked — complete or be charged
  </p>
)}
```

The condition uses `!== false` instead of `=== true` so that legacy sessions lacking the field (or `undefined` from a stale render) default to visible-cancel, matching the DB default.

Add `Lock` to the `lucide-react` import at the top of the file (alongside `Square`, etc).

- [ ] **Step 3: Type-check**

```bash
cd commitkit-desktop && pnpm type-check
```

Expected: passes.

- [ ] **Step 4: Commit**

```bash
git -C commitkit-desktop add components/timer/session-runner.tsx
git -C commitkit-desktop commit -m "Hide cancel button in SessionRunner when allow_cancel is false"
```

---

## Task 13: "Focus Now" button on the dashboard + modal mount

Add the entry-point button and wire up the TimerView as a dialog. Only render the button on today's date — an ad-hoc timer is inherently "right now."

**Files:**
- Modify: `commitkit-desktop/components/dashboard/day-view.tsx`

- [ ] **Step 1: Locate the day-view header block**

Read the component to find the element that renders the date header (the visible "Monday, April 21" line), so the button can sit alongside it.

```bash
cd commitkit-desktop && grep -n "DAY_NAMES_FULL\|selectedDate.getDay\|formatDateKey" components/dashboard/day-view.tsx | head -20
```

The component is long — pick the heading section that renders near the top of the JSX return value.

- [ ] **Step 2: Add state, import, and button**

At the top of `day-view.tsx`, add the import:

```tsx
import { TimerView } from "@/components/timer/timer-view"
import { Zap } from "lucide-react"
import { isToday } from "@/lib/date-utils"
```

(Some of these may already be imported. Reuse existing lines where possible.)

Inside the `DayView` component, add state for the modal:

```tsx
const [showFocusNow, setShowFocusNow] = useState(false)
```

In the JSX, right after the date header, render the button — only for today:

```tsx
{isToday(selectedDate) && (
  <button
    onClick={() => setShowFocusNow(true)}
    className="inline-flex items-center gap-2 rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
  >
    <Zap className="h-4 w-4" />
    Focus Now
  </button>
)}
```

At the end of the component's JSX, before the closing tag, render the modal conditionally. Follow the modal pattern from `components/plans/plan-form-dialog.tsx` — a fixed-overlay wrapper with backdrop and a max-width panel:

```tsx
{showFocusNow && (
  <div
    className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
    onClick={(e) => {
      // Backdrop click closes (only outside the dialog panel).
      if (e.target === e.currentTarget) setShowFocusNow(false)
    }}
  >
    <div className="max-h-[90vh] w-full max-w-xl overflow-y-auto rounded-lg border border-border bg-background p-6 shadow-xl">
      <TimerView onClose={() => {
        setShowFocusNow(false)
        onRefresh?.()
      }} />
    </div>
  </div>
)}
```

The `onRefresh?.()` call ensures the day view pulls the new assignment when the user closes the modal after completing the timer.

- [ ] **Step 3: Type-check**

```bash
cd commitkit-desktop && pnpm type-check
```

Expected: passes.

- [ ] **Step 4: Smoke test the happy path**

```bash
cd commitkit-desktop && pnpm tauri:dev
```

Manually verify:
1. On the home dashboard with today selected, a "Focus Now" button appears near the date header.
2. Clicking it opens the modal.
3. Selecting duration + stake + project + ≥1 list enables the Start button.
4. Clicking Start transitions to the running countdown view.
5. No Cancel button is visible — instead, a "Stake locked" note shows.
6. The `scheduled_commitments` table on the server has a new row with `type='timer'`, `template_id=NULL`, `contract_snapshot.allow_cancel=false`.

Don't commit until you've at least seen the modal open and the Start button reach the countdown view. Completing/charging a real timer is covered in Task 15.

- [ ] **Step 5: Commit**

```bash
git -C commitkit-desktop add components/dashboard/day-view.tsx
git -C commitkit-desktop commit -m "Add Focus Now button and ad-hoc timer modal to day view"
```

---

## Task 14: Run the full test suites

**Files:** none modified — this task is pure verification.

- [ ] **Step 1: Run server tests**

```bash
cd commitkit-server && pnpm test
```

Expected: all tests pass (Task 1 and Task 3 added new coverage; nothing else should regress).

- [ ] **Step 2: Run desktop tests**

```bash
cd commitkit-desktop && pnpm test
```

Expected: all tests pass (Task 8 added new coverage; mirrors in mock/fixture files may need `allow_cancel: true` if the compiler flagged them in Task 7).

- [ ] **Step 3: Run type checks in both projects**

```bash
cd commitkit-desktop && pnpm type-check
cd commitkit-server && pnpm build
```

Expected: both succeed.

- [ ] **Step 4: Run Rust compile check**

```bash
cd commitkit-desktop/src-tauri && cargo check
```

Expected: compiles, no errors.

If anything fails, fix it before proceeding. No commit unless something was actually fixed.

---

## Task 15: Manual end-to-end verification

**Files:** none modified.

This task confirms the feature works in the actual app. It cannot be automated in this codebase.

- [ ] **Step 1: Happy path — complete a timer**

1. Start `pnpm tauri:dev` in `commitkit-desktop`.
2. Open "Focus Now", set duration = 1 minute (for speed), stake = $5, project, and ≥1 distraction list.
3. Click Start. Verify countdown begins. No Cancel button.
4. Let it run out without visiting any distraction. Verify "Timer Passed" result view appears.
5. Check the server: the corresponding `scheduled_commitments` row status should transition to `completed` (via the existing completion sync).

- [ ] **Step 2: Force-quit / abandon path**

1. Start another 1-minute ad-hoc timer with a small stake (e.g. $1).
2. Force-quit the app (`cmd+Q` or kill the process) within 15 seconds of starting.
3. Wait until after `due_at` has passed (roughly 3 min after start, given 1 min duration + 2 min grace).
4. Trigger the commitment-failures cron manually (via Railway or local) — or wait for the next scheduled run.
5. Verify the `scheduled_commitments` row transitions to `failed` and a Stripe charge is attempted for the stake (or queued, depending on test mode).

- [ ] **Step 3: Distraction visited path**

1. Start a 1-minute ad-hoc timer.
2. Within the minute, visit one of the selected distraction lists' apps or domains.
3. When the timer completes (the app is still running), the result view should show "Timer Failed" with a violation and charge.

- [ ] **Step 4: Day view integration**

1. Start a 1-minute ad-hoc timer. Let it complete.
2. Close the modal.
3. Verify the completed ad-hoc timer shows up in the day view's "Earlier" / completed section, alongside any template-scheduled timers.

- [ ] **Step 5: Note any issues**

If something doesn't work, open an issue / TODO and pause execution before Task 16. The core v1 surface is these four paths.

---

# Part E — Template-form follow-up

## Task 16: Add "Allow cancel" checkbox to the template form

Deferred from v1 but low-cost to finish once v1 is stable. The column and the registry field already exist — this task just exposes them in the template-edit UI.

**Files:**
- Modify: `commitkit-desktop/components/timer/timer-template-form-dialog.tsx`
- Modify: `commitkit-desktop/src-tauri/src/commands.rs` (template create/update handlers — if `allow_cancel` isn't already threaded)
- Modify: `commitkit-desktop/src-tauri/src/db_operations.rs` (template insert/update — if not already updated in Task 6)

- [ ] **Step 1: Find the template form's "advanced" section**

```bash
cd commitkit-desktop && grep -n "allow_deadline_extend\|allow_unnamed_timers" components/timer/timer-template-form-dialog.tsx
```

Those flags are already rendered as checkboxes — model the new checkbox on them.

- [ ] **Step 2: Add the form field**

Add a new checkbox for `allow_cancel`. Because semantically it's "allowed to cancel", and the default is true (cancellable), the UI should phrase it as:

```tsx
<label className="flex items-start gap-3 rounded-md border border-border p-3 cursor-pointer hover:bg-accent/50">
  <input
    type="checkbox"
    checked={allowCancel}
    onChange={(e) => setAllowCancel(e.target.checked)}
    className="mt-0.5 h-4 w-4 rounded border-border"
  />
  <div className="min-w-0 flex-1">
    <p className="text-sm font-medium">Allow cancel</p>
    <p className="text-xs text-muted-foreground">
      If unchecked, the timer cannot be cancelled once started — stake is
      charged if you abandon it.
    </p>
  </div>
</label>
```

Add `const [allowCancel, setAllowCancel] = useState(template?.allow_cancel ?? true)` to the form state. Include `allow_cancel: allowCancel` in the create/update payload sent to the Tauri command.

- [ ] **Step 3: Thread `allow_cancel` through the Rust template command inputs**

If `CreateTimerTemplateInput` and `UpdateTimerTemplateInput` in `models.rs` don't already have `allow_cancel: bool`, add it:

```rust
#[serde(default = "default_allow_cancel")]
pub allow_cancel: bool,
```

And update the corresponding DB insert/update SQL in `db_operations.rs` to include `allow_cancel` in the column list and the bound values.

- [ ] **Step 4: Verify**

```bash
cd commitkit-desktop && pnpm type-check && pnpm test
cd commitkit-desktop/src-tauri && cargo check
```

Manually: create a timer template with "Allow cancel" unchecked, schedule it, start the session, confirm the Cancel button is not rendered.

- [ ] **Step 5: Commit**

```bash
git -C commitkit-desktop add components/timer/timer-template-form-dialog.tsx src-tauri/
git -C commitkit-desktop commit -m "Expose allow_cancel in timer template form"
```

---

# Open risks / notes for the executor

- **List ID resolution helper name.** Task 9 calls `build_local_to_list_uuid_map`. If that exact function doesn't exist, grep for similar helpers (CLAUDE.md mentions both directions). Substitute the correct name — don't invent one.
- **Template reader/writer scope in Task 6.** We added the `allow_cancel` column to `timer_templates` but the task only asks you to update template db functions if the compiler flags them. That's fine for v1 because Task 16 (follow-up) is where the field becomes user-editable. Don't over-reach into template code unless `cargo check` forces you to.
- **Midnight-crossing `date` field.** When an ad-hoc timer starts at 23:50 and spans midnight, Task 8's helper correctly returns tomorrow's date, but the day view (which groups by date) will show the assignment on tomorrow's date. Cosmetically odd, functionally correct. Accept for v1.
- **Modal scroll.** The TimerView modal uses `max-h-[90vh] overflow-y-auto`. On short windows (e.g., vertical ultrawide in split view) the running-view countdown may scroll. That's fine for v1.
- **Default `allow_cancel` in existing TimerTemplate fixtures.** Task 7 step 4 asks you to fix type errors by adding `allow_cancel: true` to literals. Prefer `true` everywhere — it's the safe default and matches the DB.

---

# Self-review (performed before committing this plan)

- **Spec coverage:** Every section of the spec (`docs/superpowers/specs/2026-04-21-ad-hoc-timer-design.md`) is covered: data model (Tasks 2, 4, 5, 7), ad-hoc = assignment with null template_id (Task 9 via existing endpoint), cancellation enforcement (Tasks 11, 12), UI (Task 13), force-quit path (server existing cron, validated in Task 15). Template-form follow-up is explicitly Task 16.
- **Placeholder scan:** No TBDs, TODOs, or "implement later" stubs. Every step has concrete code or a concrete command.
- **Type consistency:** `allow_cancel` is consistently `bool` / `boolean` across Rust and TS; `allow_cancel: false` in snapshots; `!= 0` mapping in SQLite reads; `snake_case` in serialized JSON, `camelCase` in Tauri invoke payloads.
- **Ambiguity:** One judgment call flagged in "Open risks" — the exact name of the list-UUID mapping helper function in Task 9. Executor should grep and substitute.
