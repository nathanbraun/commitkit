# Claude Verification — Desktop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users manage claude_verification commitments from the commitkit-desktop app: generate an API token + credentials file (so a hand-rolled Claude Code skill can POST verdicts), create/edit verification templates, schedule them on dates, see scheduled instances in the day view, and use a verification as a plan requirement.

**Architecture:** No local SQLite for this type — all state lives on the server. Rust `api_client.rs` gets new methods; `commands.rs` exposes new `#[tauri::command]`s; `lib/tauri.ts` adds TypeScript wrappers; new React components cover the Templates tab, day-view card, and plan-form integration. One small server-side addition: a `GET /api/claude-verification-commitments` endpoint for the desktop to list scheduled instances.

**Tech Stack:** Tauri 2, Next.js 16, TypeScript, React 19, Rust (reqwest, std::fs), shadcn/ui, Tailwind.

**Reference spec:** `docs/superpowers/specs/2026-04-20-claude-code-verification-commitment-design.md` (the Desktop UI section, lines 282–326). Server side is shipped (commits `a8278e5` through `73ac410` in `commitkit-server`).

---

## Working directory and conventions

- Desktop paths below are relative to `commitkit-desktop/` unless noted; server paths to `commitkit-server/`.
- Each task's commit happens in whichever repo it modifies.
- Desktop uses **pnpm**; Rust uses **cargo**. No lint script is configured.
- Test frameworks: Vitest for TS, no Rust tests currently. The plan adds Rust unit tests only where the logic is pure (credentials writer, slug helpers).
- Node imports in TS use the project's `@/` path alias (not `.js` suffixes — that's the server convention).
- Typecheck with `pnpm type-check`. Run tests with `pnpm test`. Run dev app with `pnpm tauri:dev`.
- Tauri commands are registered in `src-tauri/src/lib.rs`'s `.invoke_handler(tauri::generate_handler![...])` macro — EVERY new command must be added there or it won't be callable.
- Commit after every task unless the task note says otherwise. Conventional commit prefixes: `feat:`, `test:`, `refactor:`, `chore:`.

---

## Scope check

This plan delivers three shippable slices in order:

- **Slice 1 (Tasks 2–6): Tokens & Credentials.** Generate an API token, write `~/.commitkit/credentials.json`, revoke. End-state: user can write a hand-rolled Claude Code skill that reads the credentials file and POSTs to the server.
- **Slice 2 (Tasks 7–14): Verification templates & scheduling.** Create/edit templates, schedule instances, see them in the day view. End-state: user can manage verifications in the app instead of via curl.
- **Slice 3 (Tasks 15–17): Plan requirement integration.** Use a verification as a plan requirement. End-state: plan evaluator can fail a plan because a verification wasn't reported passed.

Task 1 is a small server prerequisite. Task 18 is end-to-end smoke.

---

## File structure

### New files (desktop)

| File | Responsibility |
|------|----------------|
| `components/verifications/verification-form-dialog.tsx` | Create/edit template: name, slug, stake, deadline time, color, allow-extend toggle, plan-requirement toggle. |
| `components/verifications/verifications-list.tsx` | Templates tab: list, edit, delete, "schedule for date" action. |
| `components/verifications/schedule-verification-dialog.tsx` | Small modal to pick one or more dates and POST to `/api/claude-verification-commitments`. |
| `components/verifications/claude-verification-requirement-config.tsx` | Plan-form sub-component: picker that lists templates with `is_plan_requirement = true`. |
| `components/settings/credentials-card.tsx` | Settings → Account card: "Generate API token" / "Revoke token" states, reads/writes the credentials file. |
| `__tests__/slug-helpers.test.ts` | Unit tests for the TS slug helper (kebab-case, validate). |

### New files (server)

| File | Responsibility |
|------|----------------|
| `__tests__/routes-claude-verification-commitments-list.test.ts` | Tests for the new GET endpoint. |

### New files (Rust)

None — extend existing files.

### Modified files

| File | Change |
|------|--------|
| `commitkit-server/src/routes/claude-verification-commitments.ts` | Add `GET /` handler listing active scheduled instances for the user, with optional `?date=YYYY-MM-DD` filter. |
| `commitkit-desktop/src-tauri/src/api_client.rs` | Add ~10 methods for template CRUD + scheduling + extend + API-token management. |
| `commitkit-desktop/src-tauri/src/credentials.rs` (**new file**) | Pure helper: write `~/.commitkit/credentials.json` with 0600 perms; read existing; delete. |
| `commitkit-desktop/src-tauri/src/commands.rs` | Add `#[tauri::command]` handlers wrapping the api_client + credentials helpers. |
| `commitkit-desktop/src-tauri/src/lib.rs` | Register new commands in `invoke_handler!`. |
| `commitkit-desktop/lib/tauri.ts` | Add TypeScript wrappers + types for each new command. |
| `commitkit-desktop/components/templates/templates-page.tsx` | Add "verifications" sub-tab (icon + label + conditional render). |
| `commitkit-desktop/components/dashboard/day-view.tsx` | Accept `claudeVerifications` prop; render `ScheduledClaudeVerificationCard` (new inline component) alongside existing plan/timer cards. Filter out mirror rows where `evaluation_state.is_plan_requirement === true`. |
| `commitkit-desktop/components/dashboard/home-view.tsx` (or whichever parent fetches day-view data) | Fetch verifications for the day and pass as prop. |
| `commitkit-desktop/components/plans/plan-creation-view.tsx` | Add `claude_verification_requirement` to the requirement-type picker; wire up the new sub-config component. |
| `commitkit-desktop/components/settings/settings-view.tsx` | Insert `CredentialsCard` in the Account section. |

---

## Open decisions locked in

- **Skill file delivery:** User hand-installs from docs / builds on their own. Desktop does NOT write `~/.claude/skills/...` anywhere. (Only writes `~/.commitkit/credentials.json`.)
- **Scope:** Infrastructure-only. No GTD-specific skill bundled in this plan.
- **Local DB:** None for this type. All state is server-owned. This matches the existing pattern for plan commitments and timer assignments.
- **Per-day refetch:** Day-view parent is responsible for fetching verifications for the visible date(s) and passing them as a prop, mirroring how `planCommitments` and `timerAssignments` are handled today.
- **Mirror rows in the UI:** Verifications scheduled as plan requirements (where `evaluation_state.is_plan_requirement === true`) are filtered out of the day view's standalone verification list. They surface inside the parent plan's submission view via the existing `requirement_snapshots`/`check_statuses` path — no new UI needed for that.

---

## Task 1: Server — GET /api/claude-verification-commitments

**Files:**
- Modify: `commitkit-server/src/routes/claude-verification-commitments.ts` (add GET handler)
- Create: `commitkit-server/__tests__/routes-claude-verification-commitments-list.test.ts`

**Context:** Task 6 of the server plan added POST + DELETE, but no GET. The desktop needs to list scheduled verification instances for the day-view. Pattern: mirror `GET /api/plan-commitments` (see `commitkit-server/src/routes/plan-commitments.ts` for the shape).

The endpoint returns rows from `scheduled_commitments` where `user_id = caller` AND `type = 'claude_verification'`. Optional `?date=YYYY-MM-DD` filter: return only rows whose `due_at` falls within that UTC day (or — simpler and good enough for now — whose `evaluation_state.date === <date>` when the date was set explicitly). We don't have a `date` in evaluation_state for standalone verifications (only for plan commitments), so filter by `due_at` using a UTC day window.

- [ ] **Step 1: Write the failing test**

Create `commitkit-server/__tests__/routes-claude-verification-commitments-list.test.ts` using the mock pattern from `routes-claude-verification-commitments.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest';
import express from 'express';
import request from 'supertest';

const mocks = vi.hoisted(() => ({
  rows: [] as any[],
  whereArgs: null as any,
}));

vi.mock('../src/db/index.js', () => ({
  db: {
    select: () => ({
      from: () => ({
        where: (w: any) => {
          mocks.whereArgs = w;
          return Promise.resolve(mocks.rows);
        },
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

const { default: router } = await import('../src/routes/claude-verification-commitments.js');

const app = express();
app.use(express.json());
app.use('/api/claude-verification-commitments', router);

beforeEach(() => {
  mocks.rows = [];
  mocks.whereArgs = null;
});

describe('GET /api/claude-verification-commitments', () => {
  it('returns the active rows for the caller', async () => {
    mocks.rows = [
      { id: 'sc-1', user_id: 'user-1', type: 'claude_verification', status: 'active', due_at: new Date('2026-04-20T23:00:00Z'), identity_snapshot: { name: 'GTD', slug: 'gtd' }, contract_snapshot: {}, evaluation_state: {} },
      { id: 'sc-2', user_id: 'user-1', type: 'claude_verification', status: 'completed', due_at: new Date('2026-04-19T23:00:00Z'), identity_snapshot: {}, contract_snapshot: {}, evaluation_state: {} },
    ];
    const res = await request(app).get('/api/claude-verification-commitments');
    expect(res.status).toBe(200);
    expect(res.body.claude_verification_commitments).toHaveLength(2);
    expect(res.body.claude_verification_commitments[0].id).toBe('sc-1');
  });

  it('filters by date when ?date=YYYY-MM-DD is provided', async () => {
    // Mock returns already-filtered rows; verify the query uses a date window.
    // Simplest assertion: endpoint returns 200 and passes through the rows.
    mocks.rows = [
      { id: 'sc-1', user_id: 'user-1', type: 'claude_verification', status: 'active', due_at: new Date('2026-04-20T23:00:00Z'), identity_snapshot: {}, contract_snapshot: {}, evaluation_state: {} },
    ];
    const res = await request(app).get('/api/claude-verification-commitments?date=2026-04-20');
    expect(res.status).toBe(200);
    expect(res.body.claude_verification_commitments).toHaveLength(1);
  });

  it('rejects an invalid date', async () => {
    const res = await request(app).get('/api/claude-verification-commitments?date=not-a-date');
    expect(res.status).toBe(400);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd commitkit-server
pnpm vitest run __tests__/routes-claude-verification-commitments-list.test.ts
```
Expected: FAIL (no GET handler).

- [ ] **Step 3: Add the GET handler**

In `commitkit-server/src/routes/claude-verification-commitments.ts`, add BEFORE the existing POST handler:

```ts
router.get('/', authenticateToken, async (req: AuthRequest, res) => {
  try {
    const userId = req.userId!;
    const date = typeof req.query.date === 'string' ? req.query.date : undefined;

    if (date !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      return res.status(400).json({ error: 'invalid date' });
    }

    const conditions = [
      eq(scheduledCommitments.user_id, userId),
      eq(scheduledCommitments.type, 'claude_verification'),
    ];

    if (date) {
      const dayStart = new Date(`${date}T00:00:00Z`);
      const dayEnd = new Date(dayStart.getTime() + 24 * 3_600_000);
      conditions.push(
        gte(scheduledCommitments.due_at, dayStart),
        lt(scheduledCommitments.due_at, dayEnd),
      );
    }

    const rows = await db.select()
      .from(scheduledCommitments)
      .where(and(...conditions));

    res.json({ claude_verification_commitments: rows });
  } catch (error) {
    console.error('List claude verification commitments error:', error);
    res.status(500).json({ error: 'Failed to list' });
  }
});
```

Add `gte, lt` to the existing `drizzle-orm` import if not already present.

- [ ] **Step 4: Run tests**

```bash
pnpm vitest run __tests__/routes-claude-verification-commitments-list.test.ts
```
Expected: all 3 pass.

Then the full suite:
```bash
pnpm test
```
Expected: 177 → 180 passing (1 pre-existing time flake unchanged).

- [ ] **Step 5: Type-check and commit**

```bash
pnpm type-check
git add src/routes/claude-verification-commitments.ts __tests__/routes-claude-verification-commitments-list.test.ts
git commit -m "feat: GET /api/claude-verification-commitments (list endpoint)"
```

Then deploy to prod before starting Slice 1 on the desktop side, OR run the desktop dev server against a local server. User's choice.

---

## Task 2: Rust — credentials file helper

**Files:**
- Create: `commitkit-desktop/src-tauri/src/credentials.rs`
- Modify: `commitkit-desktop/src-tauri/src/lib.rs` (add `mod credentials;`)

**Context:** Pure helper that reads/writes `~/.commitkit/credentials.json` with 0600 perms. No Tauri state, no HTTP — just `std::fs`. This is the one piece of this plan that's cleanly unit-testable in Rust, so we TDD it.

Credential file shape:
```json
{
  "api_token": "ckv_...",
  "server_url": "https://api.screentime.commitkit.com",
  "created_at": "2026-04-20T10:00:00Z",
  "label": "desktop — nathan's macbook"
}
```

- [ ] **Step 1: Write the failing test**

Create `src-tauri/src/credentials.rs` with this scaffolding AND the test:

```rust
use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CredentialsFile {
    pub api_token: String,
    pub server_url: String,
    pub created_at: String,
    pub label: Option<String>,
}

pub fn credentials_path() -> io::Result<PathBuf> {
    let home = dirs::home_dir()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "home dir not found"))?;
    Ok(home.join(".commitkit").join("credentials.json"))
}

pub fn write_credentials(creds: &CredentialsFile, path: &Path) -> io::Result<()> {
    // TODO
    unimplemented!()
}

pub fn read_credentials(path: &Path) -> io::Result<Option<CredentialsFile>> {
    // TODO
    unimplemented!()
}

pub fn delete_credentials(path: &Path) -> io::Result<()> {
    // TODO
    unimplemented!()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn write_and_read_roundtrip() {
        let dir = tempdir().unwrap();
        let path = dir.path().join(".commitkit").join("credentials.json");
        let creds = CredentialsFile {
            api_token: "ckv_abc".into(),
            server_url: "https://api.example.com".into(),
            created_at: "2026-04-20T10:00:00Z".into(),
            label: Some("test".into()),
        };

        write_credentials(&creds, &path).unwrap();
        let read = read_credentials(&path).unwrap();
        assert_eq!(read, Some(creds));
    }

    #[test]
    fn write_sets_0600_permissions() {
        let dir = tempdir().unwrap();
        let path = dir.path().join(".commitkit").join("credentials.json");
        let creds = CredentialsFile {
            api_token: "ckv_abc".into(),
            server_url: "https://api.example.com".into(),
            created_at: "2026-04-20T10:00:00Z".into(),
            label: None,
        };
        write_credentials(&creds, &path).unwrap();
        let meta = fs::metadata(&path).unwrap();
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn read_returns_none_when_missing() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nope.json");
        let read = read_credentials(&path).unwrap();
        assert_eq!(read, None);
    }

    #[test]
    fn delete_removes_the_file() {
        let dir = tempdir().unwrap();
        let path = dir.path().join(".commitkit").join("credentials.json");
        let creds = CredentialsFile {
            api_token: "ckv_abc".into(),
            server_url: "https://api.example.com".into(),
            created_at: "2026-04-20T10:00:00Z".into(),
            label: None,
        };
        write_credentials(&creds, &path).unwrap();
        delete_credentials(&path).unwrap();
        assert!(!path.exists());
    }
}
```

Add `tempfile = "3"` to `src-tauri/Cargo.toml`'s `[dev-dependencies]`:
```bash
cd src-tauri
cargo add --dev tempfile
```

Add `mod credentials;` to `src-tauri/src/lib.rs` (near the other `mod` lines).

- [ ] **Step 2: Run the test and see it fail**

```bash
cd src-tauri
cargo test credentials:: --lib
```
Expected: FAIL (unimplemented).

- [ ] **Step 3: Implement the helpers**

Replace the three `unimplemented!()` bodies:

```rust
pub fn write_credentials(creds: &CredentialsFile, path: &Path) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(creds)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    fs::write(path, json)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

pub fn read_credentials(path: &Path) -> io::Result<Option<CredentialsFile>> {
    match fs::read_to_string(path) {
        Ok(body) => {
            let parsed: CredentialsFile = serde_json::from_str(&body)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            Ok(Some(parsed))
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

pub fn delete_credentials(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}
```

- [ ] **Step 4: Run the test and see it pass**

```bash
cargo test credentials:: --lib
```
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
cd ..
git add src-tauri/src/credentials.rs src-tauri/src/lib.rs src-tauri/Cargo.toml src-tauri/Cargo.lock
git commit -m "feat: credentials file helper with 0600 perms"
```

---

## Task 3: Rust — api_client methods for API tokens

**Files:**
- Modify: `commitkit-desktop/src-tauri/src/api_client.rs`

**Context:** Add three methods to hit the server's `/api/api-tokens` routes. Pattern: follow the existing methods like `create_timer_assignment` (around line 758). Return types use `serde_json::Value` unless a concrete struct is already defined — matching the codebase's existing casual approach to API response types.

- [ ] **Step 1: Add the three methods to `impl ApiClient`**

Near the bottom of `src-tauri/src/api_client.rs`, add:

```rust
pub async fn list_api_tokens(&self) -> Result<serde_json::Value, String> {
    self.request(reqwest::Method::GET, "/api/api-tokens", None).await
}

pub async fn create_api_token(&self, label: Option<String>) -> Result<serde_json::Value, String> {
    let body = serde_json::json!({ "label": label });
    self.request(reqwest::Method::POST, "/api/api-tokens", Some(body)).await
}

pub async fn revoke_api_token(&self, id: &str) -> Result<serde_json::Value, String> {
    let endpoint = format!("/api/api-tokens/{}/revoke", id);
    self.request(reqwest::Method::POST, &endpoint, None).await
}
```

- [ ] **Step 2: Check it compiles**

```bash
cd src-tauri
cargo check
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
cd ..
git add src-tauri/src/api_client.rs
git commit -m "feat: api_client methods for api tokens"
```

No test for this task — the methods are thin wrappers over `self.request()`, which is exercised by every other api_client call. Integration testing is via the dev-server smoke run in Task 18.

---

## Task 4: Rust — Tauri commands for tokens + credentials file

**Files:**
- Modify: `commitkit-desktop/src-tauri/src/commands.rs`
- Modify: `commitkit-desktop/src-tauri/src/lib.rs` (register commands)

**Context:** Four commands:
1. `list_api_tokens` — proxies to `api_client.list_api_tokens()`.
2. `create_api_token` — calls `api_client.create_api_token(label)`, reads the raw token out of the response, and writes the credentials file.
3. `revoke_api_token` — calls `api_client.revoke_api_token(id)`, AND deletes the credentials file (since revoking the currently-installed token invalidates it).
4. `read_credentials_status` — returns `{ exists: bool, label: Option<String>, created_at: Option<String> }` for the Settings card to render state. Does NOT return the raw token.

The server URL — where do we get it? Check `api_client.rs` for a `base_url` field or similar. If there's a compile-time constant, use that; otherwise accept it as a parameter or read from app state.

- [ ] **Step 1: Identify the server base URL source**

Grep:
```bash
grep -n 'base_url\|BASE_URL\|api.screentime' src-tauri/src/api_client.rs | head -10
```

Expected: a field like `base_url: String` on `ApiClient`. Note how it's populated — constructor arg, constant, env var — and reuse the same source when writing the credentials file.

- [ ] **Step 2: Add the commands to `commands.rs`**

At the end of `src-tauri/src/commands.rs`, add:

```rust
#[tauri::command]
pub async fn list_api_tokens(api: State<'_, Arc<ApiClient>>) -> Result<serde_json::Value, String> {
    api.list_api_tokens().await
}

#[tauri::command]
pub async fn create_api_token(
    label: Option<String>,
    api: State<'_, Arc<ApiClient>>,
) -> Result<serde_json::Value, String> {
    let resp = api.create_api_token(label.clone()).await?;

    // Server returns { token: "ckv_...", api_token: {...metadata} }.
    // Write the raw token to the credentials file, then return the metadata
    // (WITHOUT the raw token) to the frontend.
    let raw_token = resp.get("token").and_then(|v| v.as_str()).ok_or("no token in response")?;
    let metadata = resp.get("api_token").cloned().unwrap_or(serde_json::json!({}));

    let path = crate::credentials::credentials_path().map_err(|e| e.to_string())?;
    let creds = crate::credentials::CredentialsFile {
        api_token: raw_token.to_string(),
        server_url: api.base_url().to_string(), // adjust if the method is named differently
        created_at: chrono::Utc::now().to_rfc3339(),
        label,
    };
    crate::credentials::write_credentials(&creds, &path).map_err(|e| e.to_string())?;

    Ok(metadata)
}

#[tauri::command]
pub async fn revoke_api_token(id: String, api: State<'_, Arc<ApiClient>>) -> Result<(), String> {
    api.revoke_api_token(&id).await?;
    let path = crate::credentials::credentials_path().map_err(|e| e.to_string())?;
    crate::credentials::delete_credentials(&path).map_err(|e| e.to_string())?;
    Ok(())
}

#[derive(serde::Serialize)]
pub struct CredentialsStatus {
    pub exists: bool,
    pub label: Option<String>,
    pub created_at: Option<String>,
}

#[tauri::command]
pub async fn read_credentials_status() -> Result<CredentialsStatus, String> {
    let path = crate::credentials::credentials_path().map_err(|e| e.to_string())?;
    let creds = crate::credentials::read_credentials(&path).map_err(|e| e.to_string())?;
    Ok(match creds {
        Some(c) => CredentialsStatus { exists: true, label: c.label, created_at: Some(c.created_at) },
        None => CredentialsStatus { exists: false, label: None, created_at: None },
    })
}
```

If `ApiClient` doesn't expose a `base_url()` getter, add one:
```rust
// in api_client.rs
pub fn base_url(&self) -> &str {
    &self.base_url
}
```

- [ ] **Step 3: Register the commands in `lib.rs`**

In `src-tauri/src/lib.rs`, find the `.invoke_handler(tauri::generate_handler![...])` block and add the four new commands to the list:

```rust
commands::list_api_tokens,
commands::create_api_token,
commands::revoke_api_token,
commands::read_credentials_status,
```

- [ ] **Step 4: Check it compiles**

```bash
cd src-tauri
cargo check
```
Expected: clean.

- [ ] **Step 5: Commit**

```bash
cd ..
git add src-tauri/src/commands.rs src-tauri/src/lib.rs src-tauri/src/api_client.rs
git commit -m "feat: tauri commands for api tokens + credentials file"
```

---

## Task 5: TypeScript wrappers for token commands

**Files:**
- Modify: `commitkit-desktop/lib/tauri.ts`

**Context:** Add TS wrappers + types for the four commands from Task 4. Follow the pattern of other `tauri.ts` exports (search for `createTimerAssignment` as a model).

- [ ] **Step 1: Add the types and wrappers**

Append to `lib/tauri.ts`:

```ts
export interface ApiTokenMetadata {
  id: string;
  label: string | null;
  created_at: string;
  last_used_at: string | null;
  revoked_at: string | null;
}

export interface CredentialsStatus {
  exists: boolean;
  label: string | null;
  created_at: string | null;
}

export async function listApiTokens(): Promise<{ api_tokens: ApiTokenMetadata[] }> {
  return invoke('list_api_tokens');
}

export async function createApiToken(label: string | null): Promise<ApiTokenMetadata> {
  return invoke('create_api_token', { label });
}

export async function revokeApiToken(id: string): Promise<void> {
  return invoke('revoke_api_token', { id });
}

export async function readCredentialsStatus(): Promise<CredentialsStatus> {
  return invoke('read_credentials_status');
}
```

- [ ] **Step 2: Type-check**

```bash
pnpm type-check
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/tauri.ts
git commit -m "feat: lib/tauri.ts wrappers for api tokens + credentials"
```

---

## Task 6: Settings → Credentials card

**Files:**
- Create: `commitkit-desktop/components/settings/credentials-card.tsx`
- Modify: `commitkit-desktop/components/settings/settings-view.tsx`

**Context:** Card with two states:
- **No token installed** (per `readCredentialsStatus()`): "Generate API token" button. On click: optionally prompts for a label (can be as simple as an `input`) → calls `createApiToken(label)` → shows success + path (`~/.commitkit/credentials.json`).
- **Token installed**: shows label + created date + a "Revoke" button with `AlertDialog` confirmation (destructive).

If the server ALSO has tokens in `/api/api-tokens` that aren't represented in the local credentials file (e.g., old tokens from other devices), optionally show them in a sub-list with individual revoke buttons. For v1 you can skip this and only manage the currently-installed token. **Skip it for v1** — the user's the only user; if it matters later, add then.

- [ ] **Step 1: Write `credentials-card.tsx`**

```tsx
'use client';

import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog';
import {
  createApiToken,
  readCredentialsStatus,
  revokeApiToken,
  listApiTokens,
  type CredentialsStatus,
  type ApiTokenMetadata,
} from '@/lib/tauri';

export function CredentialsCard() {
  const [status, setStatus] = useState<CredentialsStatus | null>(null);
  const [installedToken, setInstalledToken] = useState<ApiTokenMetadata | null>(null);
  const [label, setLabel] = useState('desktop');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = async () => {
    try {
      const s = await readCredentialsStatus();
      setStatus(s);
      if (s.exists) {
        // Look up matching server-side token metadata for display.
        const tokens = await listApiTokens();
        const match = tokens.api_tokens.find((t) => t.label === s.label);
        setInstalledToken(match ?? null);
      } else {
        setInstalledToken(null);
      }
    } catch (e: any) {
      setError(e.toString());
    }
  };

  useEffect(() => { refresh(); }, []);

  const handleGenerate = async () => {
    setLoading(true);
    setError(null);
    try {
      await createApiToken(label || null);
      await refresh();
    } catch (e: any) {
      setError(e.toString());
    } finally {
      setLoading(false);
    }
  };

  const handleRevoke = async () => {
    if (!installedToken) return;
    setLoading(true);
    setError(null);
    try {
      await revokeApiToken(installedToken.id);
      await refresh();
    } catch (e: any) {
      setError(e.toString());
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="rounded-lg border bg-card p-4">
      <div className="mb-2 flex items-center justify-between">
        <h3 className="font-medium">Claude Code verification token</h3>
      </div>
      <p className="mb-4 text-sm text-muted-foreground">
        API token used by a Claude Code skill to report verification verdicts.
        Stored in <code>~/.commitkit/credentials.json</code> with 0600 perms.
      </p>

      {status?.exists && installedToken ? (
        <div>
          <div className="mb-3 text-sm">
            <div><span className="text-muted-foreground">Label:</span> {installedToken.label ?? '(none)'}</div>
            <div><span className="text-muted-foreground">Created:</span> {new Date(installedToken.created_at).toLocaleString()}</div>
            {installedToken.last_used_at && (
              <div><span className="text-muted-foreground">Last used:</span> {new Date(installedToken.last_used_at).toLocaleString()}</div>
            )}
          </div>
          <AlertDialog>
            <AlertDialogTrigger asChild>
              <Button variant="destructive" disabled={loading}>Revoke token</Button>
            </AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>Revoke API token?</AlertDialogTitle>
                <AlertDialogDescription>
                  This deletes the credentials file and invalidates the token on the server. Your Claude Code skill will stop working until you generate a new one.
                </AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>Cancel</AlertDialogCancel>
                <AlertDialogAction onClick={handleRevoke}>Revoke</AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        </div>
      ) : (
        <div className="flex gap-2">
          <Input
            placeholder="Label (e.g. 'nathan's macbook')"
            value={label}
            onChange={(e) => setLabel(e.target.value)}
            className="max-w-xs"
          />
          <Button onClick={handleGenerate} disabled={loading}>
            {loading ? 'Generating…' : 'Generate API token'}
          </Button>
        </div>
      )}

      {error && <p className="mt-2 text-sm text-destructive">{error}</p>}
    </div>
  );
}
```

- [ ] **Step 2: Insert the card into `settings-view.tsx`**

Import it and render it inside the Account section (after the existing email + logout rows, around line 156 per the codebase tour):

```tsx
import { CredentialsCard } from './credentials-card';

// ... inside the Account section, after the existing card's children:
<CredentialsCard />
```

- [ ] **Step 3: Smoke-test in the dev app**

```bash
pnpm tauri:dev
```
- Sign in, navigate to Settings → Account.
- Click "Generate API token" with a label → verify card flips to the installed-token state.
- Check the file: `ls -la ~/.commitkit/credentials.json` → should be `-rw-------`.
- `cat ~/.commitkit/credentials.json` → should show the token.
- Click "Revoke token" → confirm → file should be gone, card flips back.

- [ ] **Step 4: Commit**

```bash
git add components/settings/credentials-card.tsx components/settings/settings-view.tsx
git commit -m "feat: settings → credentials card for api tokens"
```

**End of Slice 1.** At this point the user can write a hand-rolled Claude Code skill that reads `~/.commitkit/credentials.json` and POSTs to the server. Template CRUD is still server-side-only (use curl); the desktop gets UI in Slice 2.

---

## Task 7: Rust — api_client methods for verification templates + scheduling

**Files:**
- Modify: `commitkit-desktop/src-tauri/src/api_client.rs`

**Context:** Add methods for template CRUD (`/api/claude-verifications`), scheduling (`/api/claude-verification-commitments`), extend (`/api/claude-verifications/extend/:id`), and list-scheduled (the GET endpoint added in Task 1). Pattern: mirror Task 3 — thin wrappers, `serde_json::Value` return types.

- [ ] **Step 1: Add the methods**

Append to `impl ApiClient`:

```rust
// Template CRUD
pub async fn list_claude_verifications(&self) -> Result<serde_json::Value, String> {
    self.request(reqwest::Method::GET, "/api/claude-verifications", None).await
}

pub async fn create_claude_verification(&self, body: serde_json::Value) -> Result<serde_json::Value, String> {
    self.request(reqwest::Method::POST, "/api/claude-verifications", Some(body)).await
}

pub async fn update_claude_verification(&self, id: &str, body: serde_json::Value) -> Result<serde_json::Value, String> {
    let endpoint = format!("/api/claude-verifications/{}", id);
    self.request(reqwest::Method::PATCH, &endpoint, Some(body)).await
}

pub async fn delete_claude_verification(&self, id: &str) -> Result<serde_json::Value, String> {
    let endpoint = format!("/api/claude-verifications/{}", id);
    self.request(reqwest::Method::DELETE, &endpoint, None).await
}

// Scheduling
pub async fn list_claude_verification_commitments(&self, date: Option<&str>) -> Result<serde_json::Value, String> {
    let endpoint = match date {
        Some(d) => format!("/api/claude-verification-commitments?date={}", d),
        None => "/api/claude-verification-commitments".to_string(),
    };
    self.request(reqwest::Method::GET, &endpoint, None).await
}

pub async fn create_claude_verification_commitments(&self, body: serde_json::Value) -> Result<serde_json::Value, String> {
    self.request(reqwest::Method::POST, "/api/claude-verification-commitments", Some(body)).await
}

pub async fn delete_claude_verification_commitment(&self, id: &str) -> Result<serde_json::Value, String> {
    let endpoint = format!("/api/claude-verification-commitments/{}", id);
    self.request(reqwest::Method::DELETE, &endpoint, None).await
}

pub async fn extend_claude_verification_deadline(&self, scheduled_commitment_id: &str) -> Result<serde_json::Value, String> {
    let endpoint = format!("/api/claude-verifications/extend/{}", scheduled_commitment_id);
    self.request(reqwest::Method::POST, &endpoint, None).await
}
```

- [ ] **Step 2: Check it compiles**

```bash
cd src-tauri
cargo check
```
Expected: clean.

- [ ] **Step 3: Commit**

```bash
cd ..
git add src-tauri/src/api_client.rs
git commit -m "feat: api_client methods for claude_verification templates + scheduling"
```

---

## Task 8: Rust — Tauri commands for verification templates + scheduling

**Files:**
- Modify: `commitkit-desktop/src-tauri/src/commands.rs`
- Modify: `commitkit-desktop/src-tauri/src/lib.rs` (register)

**Context:** Eight thin `#[tauri::command]` wrappers around the api_client methods from Task 7. Pattern: same shape as Task 4's token commands.

- [ ] **Step 1: Add the commands**

Append to `commands.rs`:

```rust
#[tauri::command]
pub async fn list_claude_verifications(api: State<'_, Arc<ApiClient>>) -> Result<serde_json::Value, String> {
    api.list_claude_verifications().await
}

#[tauri::command]
pub async fn create_claude_verification(
    body: serde_json::Value,
    api: State<'_, Arc<ApiClient>>,
) -> Result<serde_json::Value, String> {
    api.create_claude_verification(body).await
}

#[tauri::command]
pub async fn update_claude_verification(
    id: String,
    body: serde_json::Value,
    api: State<'_, Arc<ApiClient>>,
) -> Result<serde_json::Value, String> {
    api.update_claude_verification(&id, body).await
}

#[tauri::command]
pub async fn delete_claude_verification(
    id: String,
    api: State<'_, Arc<ApiClient>>,
) -> Result<serde_json::Value, String> {
    api.delete_claude_verification(&id).await
}

#[tauri::command]
pub async fn list_claude_verification_commitments(
    date: Option<String>,
    api: State<'_, Arc<ApiClient>>,
) -> Result<serde_json::Value, String> {
    api.list_claude_verification_commitments(date.as_deref()).await
}

#[tauri::command]
pub async fn create_claude_verification_commitments(
    body: serde_json::Value,
    api: State<'_, Arc<ApiClient>>,
) -> Result<serde_json::Value, String> {
    api.create_claude_verification_commitments(body).await
}

#[tauri::command]
pub async fn delete_claude_verification_commitment(
    id: String,
    api: State<'_, Arc<ApiClient>>,
) -> Result<serde_json::Value, String> {
    api.delete_claude_verification_commitment(&id).await
}

#[tauri::command]
pub async fn extend_claude_verification_deadline(
    scheduled_commitment_id: String,
    api: State<'_, Arc<ApiClient>>,
) -> Result<serde_json::Value, String> {
    api.extend_claude_verification_deadline(&scheduled_commitment_id).await
}
```

- [ ] **Step 2: Register in `lib.rs`**

Append to the `invoke_handler![...]` list:
```rust
commands::list_claude_verifications,
commands::create_claude_verification,
commands::update_claude_verification,
commands::delete_claude_verification,
commands::list_claude_verification_commitments,
commands::create_claude_verification_commitments,
commands::delete_claude_verification_commitment,
commands::extend_claude_verification_deadline,
```

- [ ] **Step 3: Check it compiles**

```bash
cd src-tauri
cargo check
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
cd ..
git add src-tauri/src/commands.rs src-tauri/src/lib.rs
git commit -m "feat: tauri commands for claude_verification templates + scheduling"
```

---

## Task 9: TypeScript wrappers for verification commands

**Files:**
- Modify: `commitkit-desktop/lib/tauri.ts`

**Context:** TS wrappers + types for the eight commands from Task 8.

- [ ] **Step 1: Add the types**

Append to `lib/tauri.ts`:

```ts
export interface ClaudeVerificationTemplate {
  id: string;
  user_id: string;
  name: string;
  slug: string;
  stake_cents: number;
  deadline_time: string;
  color: string;
  allow_deadline_extend: boolean;
  is_plan_requirement: boolean;
  active: boolean;
  created_at: string;
  updated_at: string;
}

export interface ClaudeVerificationCommitment {
  id: string;
  user_id: string;
  type: 'claude_verification';
  template_id: string | null;
  status: 'active' | 'completed' | 'failed' | 'expired';
  due_at: string;
  stake_cents: number;
  contract_snapshot: Record<string, unknown>;
  identity_snapshot: Record<string, unknown>;
  evaluation_state: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

export interface CreateClaudeVerificationBody {
  name: string;
  slug: string;
  stakeCents: number;
  deadlineTime: string;
  color?: string;
  allowDeadlineExtend?: boolean;
  isPlanRequirement?: boolean;
}
```

- [ ] **Step 2: Add the wrappers**

```ts
export async function listClaudeVerifications(): Promise<{ claude_verifications: ClaudeVerificationTemplate[] }> {
  return invoke('list_claude_verifications');
}

export async function createClaudeVerification(body: CreateClaudeVerificationBody): Promise<{ claude_verification: ClaudeVerificationTemplate }> {
  return invoke('create_claude_verification', { body });
}

export async function updateClaudeVerification(id: string, body: Partial<CreateClaudeVerificationBody>): Promise<{ claude_verification: ClaudeVerificationTemplate }> {
  return invoke('update_claude_verification', { id, body });
}

export async function deleteClaudeVerification(id: string): Promise<void> {
  await invoke('delete_claude_verification', { id });
}

export async function listClaudeVerificationCommitments(date?: string): Promise<{ claude_verification_commitments: ClaudeVerificationCommitment[] }> {
  return invoke('list_claude_verification_commitments', { date: date ?? null });
}

export async function scheduleClaudeVerification(templateId: string, dates: string[]): Promise<{ created: ClaudeVerificationCommitment[] }> {
  return invoke('create_claude_verification_commitments', { body: { templateId, dates } });
}

export async function unscheduleClaudeVerification(id: string): Promise<void> {
  await invoke('delete_claude_verification_commitment', { id });
}

export async function extendClaudeVerificationDeadline(scheduledCommitmentId: string): Promise<{ claude_verification_commitment: ClaudeVerificationCommitment }> {
  return invoke('extend_claude_verification_deadline', { scheduledCommitmentId });
}
```

- [ ] **Step 3: Type-check**

```bash
pnpm type-check
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add lib/tauri.ts
git commit -m "feat: lib/tauri.ts wrappers for claude_verification templates + scheduling"
```

---

## Task 10: Slug helper (TS)

**Files:**
- Create: `commitkit-desktop/lib/slug.ts`
- Create: `commitkit-desktop/__tests__/slug-helpers.test.ts`

**Context:** Template form needs slug auto-gen from name + validation. Slug rule (matches server): `^[a-z0-9][a-z0-9-]{0,63}$`. This is pure logic — unit test it.

- [ ] **Step 1: Write the failing test**

Create `__tests__/slug-helpers.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { toSlug, isValidSlug } from '@/lib/slug';

describe('toSlug', () => {
  it('lowercases and hyphenates', () => {
    expect(toSlug('Daily GTD Review')).toBe('daily-gtd-review');
  });
  it('strips non-ascii', () => {
    expect(toSlug("Nathan's Review — 2026")).toBe('nathans-review-2026');
  });
  it('collapses runs of hyphens', () => {
    expect(toSlug('hello    world')).toBe('hello-world');
  });
  it('trims leading/trailing hyphens', () => {
    expect(toSlug('  -hello-  ')).toBe('hello');
  });
  it('truncates to 64 chars', () => {
    expect(toSlug('a'.repeat(100))).toHaveLength(64);
  });
});

describe('isValidSlug', () => {
  it('accepts valid slugs', () => {
    expect(isValidSlug('daily-gtd')).toBe(true);
    expect(isValidSlug('a')).toBe(true);
    expect(isValidSlug('a1-b2')).toBe(true);
  });
  it('rejects empty', () => {
    expect(isValidSlug('')).toBe(false);
  });
  it('rejects leading hyphen', () => {
    expect(isValidSlug('-hello')).toBe(false);
  });
  it('rejects uppercase', () => {
    expect(isValidSlug('Hello')).toBe(false);
  });
  it('rejects >64 chars', () => {
    expect(isValidSlug('a'.repeat(65))).toBe(false);
  });
});
```

- [ ] **Step 2: Run test and see it fail**

```bash
pnpm vitest run __tests__/slug-helpers.test.ts
```
Expected: FAIL (module not found).

- [ ] **Step 3: Implement**

Create `lib/slug.ts`:

```ts
const SLUG_PATTERN = /^[a-z0-9][a-z0-9-]{0,63}$/;

export function toSlug(input: string): string {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 64);
}

export function isValidSlug(slug: string): boolean {
  return SLUG_PATTERN.test(slug);
}
```

- [ ] **Step 4: Run test and see it pass**

```bash
pnpm vitest run __tests__/slug-helpers.test.ts
```
Expected: 10 passed.

- [ ] **Step 5: Commit**

```bash
git add lib/slug.ts __tests__/slug-helpers.test.ts
git commit -m "feat: slug helpers (toSlug, isValidSlug)"
```

---

## Task 11: Verification form dialog component

**Files:**
- Create: `commitkit-desktop/components/verifications/verification-form-dialog.tsx`

**Context:** Modal form for create + edit. Follow `plan-form-dialog.tsx` as a structural model. Fields: name, slug (auto-populated, editable, validated), stake (dollar input → cents), deadline time (HH:MM), color (`COLOR_OPTIONS`), `allow_deadline_extend` toggle, `is_plan_requirement` toggle.

- [ ] **Step 1: Locate `COLOR_OPTIONS`**

```bash
grep -rn 'COLOR_OPTIONS' components/ | head -5
```
Reuse whichever module exports it.

- [ ] **Step 2: Write the component**

Skeleton:

```tsx
'use client';

import { useEffect, useState } from 'react';
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter, DialogDescription,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Switch } from '@/components/ui/switch';
import { toSlug, isValidSlug } from '@/lib/slug';
import {
  createClaudeVerification,
  updateClaudeVerification,
  type ClaudeVerificationTemplate,
  type CreateClaudeVerificationBody,
} from '@/lib/tauri';
// Import COLOR_OPTIONS from wherever it lives (discovered in Step 1).

interface Props {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
  editing?: ClaudeVerificationTemplate | null;
}

export function VerificationFormDialog({ open, onOpenChange, onSaved, editing }: Props) {
  const [name, setName] = useState('');
  const [slug, setSlug] = useState('');
  const [slugTouched, setSlugTouched] = useState(false);
  const [stakeDollars, setStakeDollars] = useState('5');
  const [deadlineTime, setDeadlineTime] = useState('23:00');
  const [color, setColor] = useState('#8b5cf6');
  const [allowExtend, setAllowExtend] = useState(false);
  const [isPlanReq, setIsPlanReq] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Reset when dialog opens.
  useEffect(() => {
    if (!open) return;
    if (editing) {
      setName(editing.name);
      setSlug(editing.slug);
      setSlugTouched(true);
      setStakeDollars((editing.stake_cents / 100).toString());
      setDeadlineTime(editing.deadline_time);
      setColor(editing.color);
      setAllowExtend(editing.allow_deadline_extend);
      setIsPlanReq(editing.is_plan_requirement);
    } else {
      setName('');
      setSlug('');
      setSlugTouched(false);
      setStakeDollars('5');
      setDeadlineTime('23:00');
      setColor('#8b5cf6');
      setAllowExtend(false);
      setIsPlanReq(false);
    }
    setError(null);
  }, [open, editing]);

  // Auto-populate slug from name until user edits it manually.
  useEffect(() => {
    if (!slugTouched) setSlug(toSlug(name));
  }, [name, slugTouched]);

  const canSave =
    name.trim().length > 0 &&
    isValidSlug(slug) &&
    /^\d{2}:\d{2}$/.test(deadlineTime) &&
    !isNaN(parseFloat(stakeDollars));

  const handleSave = async () => {
    setSaving(true);
    setError(null);
    try {
      const stakeCents = Math.round(parseFloat(stakeDollars) * 100);
      const body: CreateClaudeVerificationBody = {
        name: name.trim(),
        slug,
        stakeCents,
        deadlineTime,
        color,
        allowDeadlineExtend: allowExtend,
        isPlanRequirement: isPlanReq,
      };
      if (editing) {
        await updateClaudeVerification(editing.id, body);
      } else {
        await createClaudeVerification(body);
      }
      onSaved();
      onOpenChange(false);
    } catch (e: any) {
      setError(e.toString());
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{editing ? 'Edit verification' : 'New verification'}</DialogTitle>
          <DialogDescription>
            A Claude Code skill reports pass/fail; if no pass arrives by the deadline, you're charged.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <div>
            <Label>Name</Label>
            <Input value={name} onChange={(e) => setName(e.target.value)} />
          </div>
          <div>
            <Label>Slug</Label>
            <Input
              value={slug}
              onChange={(e) => { setSlug(e.target.value); setSlugTouched(true); }}
              className={isValidSlug(slug) ? '' : 'border-destructive'}
            />
            {!isValidSlug(slug) && slug.length > 0 && (
              <p className="text-xs text-destructive">lowercase letters, digits, hyphens; max 64 chars</p>
            )}
          </div>
          <div className="flex gap-2">
            <div className="flex-1">
              <Label>Stake ($)</Label>
              <Input type="number" value={stakeDollars} onChange={(e) => setStakeDollars(e.target.value)} />
            </div>
            <div className="flex-1">
              <Label>Deadline</Label>
              <Input type="time" value={deadlineTime} onChange={(e) => setDeadlineTime(e.target.value)} />
            </div>
          </div>
          <div>
            <Label>Color</Label>
            {/* Render a row of color swatches from COLOR_OPTIONS; selected color = color state. */}
          </div>
          <div className="flex items-center justify-between">
            <Label>Allow 2-minute extend</Label>
            <Switch checked={allowExtend} onCheckedChange={setAllowExtend} />
          </div>
          <div className="flex items-center justify-between">
            <Label>Use as plan requirement</Label>
            <Switch checked={isPlanReq} onCheckedChange={setIsPlanReq} />
          </div>
          {error && <p className="text-sm text-destructive">{error}</p>}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button onClick={handleSave} disabled={!canSave || saving}>
            {saving ? 'Saving…' : editing ? 'Save' : 'Create'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
```

- [ ] **Step 3: Type-check**

```bash
pnpm type-check
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add components/verifications/verification-form-dialog.tsx
git commit -m "feat: verification-form-dialog component"
```

Smoke test deferred to Task 12 (when the list component wires it up).

---

## Task 12: Verifications list component

**Files:**
- Create: `commitkit-desktop/components/verifications/verifications-list.tsx`

**Context:** Renders the user's templates in a card list. Each card: name, slug, stake, deadline, edit button, delete button, "schedule for date" action (opens Task 13's dialog). Top-right "New verification" button.

- [ ] **Step 1: Write the component**

```tsx
'use client';

import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Pencil, Trash2, Calendar } from 'lucide-react';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle, AlertDialogTrigger,
} from '@/components/ui/alert-dialog';
import {
  listClaudeVerifications,
  deleteClaudeVerification,
  type ClaudeVerificationTemplate,
} from '@/lib/tauri';
import { VerificationFormDialog } from './verification-form-dialog';
import { ScheduleVerificationDialog } from './schedule-verification-dialog';

export function VerificationsList() {
  const [templates, setTemplates] = useState<ClaudeVerificationTemplate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<ClaudeVerificationTemplate | null>(null);
  const [scheduling, setScheduling] = useState<ClaudeVerificationTemplate | null>(null);

  const refresh = async () => {
    setLoading(true);
    setError(null);
    try {
      const r = await listClaudeVerifications();
      setTemplates(r.claude_verifications);
    } catch (e: any) {
      setError(e.toString());
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { refresh(); }, []);

  const handleDelete = async (id: string) => {
    try {
      await deleteClaudeVerification(id);
      await refresh();
    } catch (e: any) {
      setError(e.toString());
    }
  };

  if (loading) return <p>Loading…</p>;
  if (error) return <p className="text-destructive">{error}</p>;

  return (
    <div>
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-lg font-medium">Verifications</h2>
        <Button onClick={() => { setEditing(null); setFormOpen(true); }}>New verification</Button>
      </div>

      {templates.length === 0 ? (
        <p className="text-muted-foreground">No verifications yet.</p>
      ) : (
        <div className="space-y-2">
          {templates.map((t) => (
            <div key={t.id} className="flex items-center justify-between rounded-lg border bg-card p-3">
              <div className="flex items-center gap-3">
                <span className="inline-block h-3 w-3 rounded-full" style={{ backgroundColor: t.color }} />
                <div>
                  <div className="font-medium">{t.name}</div>
                  <div className="text-xs text-muted-foreground">
                    <code>{t.slug}</code> · ${(t.stake_cents / 100).toFixed(2)} · by {t.deadline_time}
                    {t.is_plan_requirement && ' · plan req'}
                  </div>
                </div>
              </div>
              <div className="flex gap-1">
                <Button variant="ghost" size="icon" onClick={() => setScheduling(t)}>
                  <Calendar className="h-4 w-4" />
                </Button>
                <Button variant="ghost" size="icon" onClick={() => { setEditing(t); setFormOpen(true); }}>
                  <Pencil className="h-4 w-4" />
                </Button>
                <AlertDialog>
                  <AlertDialogTrigger asChild>
                    <Button variant="ghost" size="icon"><Trash2 className="h-4 w-4" /></Button>
                  </AlertDialogTrigger>
                  <AlertDialogContent>
                    <AlertDialogHeader>
                      <AlertDialogTitle>Delete "{t.name}"?</AlertDialogTitle>
                      <AlertDialogDescription>
                        This marks the template inactive. Scheduled instances that are still pending are not affected.
                      </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                      <AlertDialogCancel>Cancel</AlertDialogCancel>
                      <AlertDialogAction onClick={() => handleDelete(t.id)}>Delete</AlertDialogAction>
                    </AlertDialogFooter>
                  </AlertDialogContent>
                </AlertDialog>
              </div>
            </div>
          ))}
        </div>
      )}

      <VerificationFormDialog
        open={formOpen}
        onOpenChange={setFormOpen}
        onSaved={refresh}
        editing={editing}
      />
      {scheduling && (
        <ScheduleVerificationDialog
          template={scheduling}
          open={!!scheduling}
          onOpenChange={(o) => { if (!o) setScheduling(null); }}
          onScheduled={() => { setScheduling(null); }}
        />
      )}
    </div>
  );
}
```

- [ ] **Step 2: Type-check (will fail — ScheduleVerificationDialog doesn't exist yet)**

This is expected. Task 13 creates that file. If you want to keep commits atomic, stub out `schedule-verification-dialog.tsx` first with a minimal empty component, commit this task, then fully implement it in Task 13.

Simpler alternative: combine Tasks 12 and 13 into one commit. **Recommended.**

- [ ] **Step 3: Move to Task 13**

Don't commit yet. Task 13 finishes the scheduling dialog, then a single commit lands both.

---

## Task 13: Schedule-verification dialog

**Files:**
- Create: `commitkit-desktop/components/verifications/schedule-verification-dialog.tsx`

**Context:** Small modal: user picks one or more dates (at minimum: a single-date picker for v1), clicks Schedule, calls `scheduleClaudeVerification(templateId, dates)`.

- [ ] **Step 1: Write the component**

```tsx
'use client';

import { useState } from 'react';
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter, DialogDescription,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { scheduleClaudeVerification, type ClaudeVerificationTemplate } from '@/lib/tauri';

interface Props {
  template: ClaudeVerificationTemplate;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onScheduled: () => void;
}

export function ScheduleVerificationDialog({ template, open, onOpenChange, onScheduled }: Props) {
  const today = new Date().toISOString().slice(0, 10);
  const [date, setDate] = useState(today);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSchedule = async () => {
    setSaving(true);
    setError(null);
    try {
      await scheduleClaudeVerification(template.id, [date]);
      onScheduled();
      onOpenChange(false);
    } catch (e: any) {
      setError(e.toString());
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle>Schedule "{template.name}"</DialogTitle>
          <DialogDescription>
            Creates a commitment for the chosen date with a ${(template.stake_cents / 100).toFixed(2)} stake.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <div>
            <Label>Date</Label>
            <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </div>
          {error && <p className="text-sm text-destructive">{error}</p>}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button onClick={handleSchedule} disabled={saving}>
            {saving ? 'Scheduling…' : 'Schedule'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
```

- [ ] **Step 2: Type-check**

```bash
pnpm type-check
```
Expected: clean.

- [ ] **Step 3: Commit Tasks 12 + 13 together**

```bash
git add components/verifications/
git commit -m "feat: verifications list + schedule dialog"
```

---

## Task 14: Wire up "Verifications" sub-tab + day-view cards

**Files:**
- Modify: `commitkit-desktop/components/templates/templates-page.tsx`
- Modify: `commitkit-desktop/components/dashboard/day-view.tsx`
- Modify: `commitkit-desktop/components/dashboard/home-view.tsx` (or the day-view data-fetching parent — confirm during implementation)

**Context:** Wire the new list into the Templates page, wire scheduled-instance cards into the day view.

### Part A: Templates page sub-tab

- [ ] **Step A1: Extend `SUB_TABS`**

In `components/templates/templates-page.tsx`, add `'verifications'` to the `SubTab` union and the `SUB_TABS` array (with an appropriate icon — e.g. `CheckCircle2` from lucide). Follow the existing pattern. Add a conditional render:

```tsx
{activeTab === 'verifications' && <VerificationsList />}
```

And import `VerificationsList` from `@/components/verifications/verifications-list`.

### Part B: Day view cards

- [ ] **Step B1: Add `claudeVerifications` prop to `DayView`**

In `components/dashboard/day-view.tsx`, add `claudeVerifications?: ClaudeVerificationCommitment[]` to the props type. Import the type from `@/lib/tauri`.

- [ ] **Step B2: Render cards inline (pattern of ScheduledPlanCard / ScheduledTimerCard)**

Add a new inline component in the same file:

```tsx
function ScheduledClaudeVerificationCard({ row }: { row: ClaudeVerificationCommitment }) {
  const identity = row.identity_snapshot as { name?: string; color?: string };
  const contract = row.contract_snapshot as { deadline_time?: string };
  const evalState = row.evaluation_state as { passed?: boolean; summary?: string };
  const statusLabel = row.status === 'active' ? 'active' : row.status;
  return (
    <div className="rounded-lg border bg-card p-3">
      <div className="flex items-center gap-2">
        <span className="inline-block h-3 w-3 rounded-full" style={{ backgroundColor: identity.color ?? '#8b5cf6' }} />
        <div className="font-medium">{identity.name ?? 'verification'}</div>
        <span className="ml-auto text-xs text-muted-foreground">by {contract.deadline_time ?? '—'}</span>
      </div>
      <div className="mt-1 text-xs text-muted-foreground">
        {statusLabel}
        {evalState.passed === true && ' · passed'}
        {evalState.summary && ` · ${evalState.summary}`}
      </div>
    </div>
  );
}
```

Render the filtered list (filtering out mirror rows) in the day view section where plan/timer cards render:

```tsx
{claudeVerifications
  ?.filter((v) => !((v.evaluation_state as any)?.is_plan_requirement))
  .map((v) => <ScheduledClaudeVerificationCard key={v.id} row={v} />)}
```

- [ ] **Step B3: Fetch verifications in the day-view parent**

In `components/dashboard/home-view.tsx` (or wherever `planCommitments` and `timerAssignments` are fetched — confirm during implementation), add a parallel fetch via `listClaudeVerificationCommitments(date)` and pass as a prop.

- [ ] **Step 4: Smoke-test**

```bash
pnpm tauri:dev
```
- Templates → Verifications tab → click "New verification" → fill in a template → save. Template appears in list.
- Click the calendar icon → pick today → Schedule. No visible error.
- Navigate to the dashboard/day view → verification card appears for today with status "active".
- Verify via psql/curl that the row exists in `scheduled_commitments` with `type='claude_verification'`.

- [ ] **Step 5: Commit**

```bash
git add components/templates/templates-page.tsx components/dashboard/day-view.tsx components/dashboard/home-view.tsx
git commit -m "feat: verifications sub-tab + day-view cards"
```

**End of Slice 2.** User can now manage templates + scheduling without curl.

---

## Task 15: Plan form — add `claude_verification_requirement` option

**Files:**
- Modify: `commitkit-desktop/components/plans/plan-creation-view.tsx`

**Context:** Add the new requirement type to the type picker. This task is structural only — it enables the option; Task 16 adds the config sub-component.

- [ ] **Step 1: Extend the requirement-type picker**

In `plan-creation-view.tsx`, find where requirement types are enumerated (the tour reports around lines 125–145). Add `'claude_verification_requirement'` to the list and the switch-on-type rendering logic, initially pointing to the new config component (Task 16).

- [ ] **Step 2: Type-check**

```bash
pnpm type-check
```
Expected: clean (the config component is imported but may not yet render meaningful UI — stub if needed).

- [ ] **Step 3: Commit (can combine with Task 16)**

Skip the commit here and land Task 16 together.

---

## Task 16: `claude-verification-requirement-config.tsx`

**Files:**
- Create: `commitkit-desktop/components/plans/claude-verification-requirement-config.tsx`

**Context:** Sub-component (pattern: `timer-requirement-config.tsx`). Renders a picker showing the user's templates with `is_plan_requirement === true`. Stores `{ claude_verification_id: <uuid> }` in `config`.

- [ ] **Step 1: Write the component**

```tsx
'use client';

import { useEffect, useState } from 'react';
import { Label } from '@/components/ui/label';
import { listClaudeVerifications, type ClaudeVerificationTemplate } from '@/lib/tauri';

export interface ClaudeVerificationRequirementConfig {
  claude_verification_id?: string;
}

interface Props {
  config: ClaudeVerificationRequirementConfig;
  onConfigUpdate: (next: ClaudeVerificationRequirementConfig) => void;
}

export function ClaudeVerificationRequirementConfig({ config, onConfigUpdate }: Props) {
  const [templates, setTemplates] = useState<ClaudeVerificationTemplate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const r = await listClaudeVerifications();
        setTemplates(r.claude_verifications.filter((t) => t.is_plan_requirement));
      } catch (e: any) {
        setError(e.toString());
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  if (loading) return <p className="text-sm">Loading verifications…</p>;
  if (error) return <p className="text-sm text-destructive">{error}</p>;
  if (templates.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        No verifications marked "Use as plan requirement" yet. Create one from Templates → Verifications.
      </p>
    );
  }

  return (
    <div>
      <Label>Verification</Label>
      <select
        className="w-full rounded-md border bg-background p-2"
        value={config.claude_verification_id ?? ''}
        onChange={(e) => onConfigUpdate({ claude_verification_id: e.target.value || undefined })}
      >
        <option value="">Select…</option>
        {templates.map((t) => (
          <option key={t.id} value={t.id}>{t.name} ({t.slug})</option>
        ))}
      </select>
    </div>
  );
}
```

- [ ] **Step 2: Wire it into `plan-creation-view.tsx`**

Import and conditionally render when `editingCheck.type === 'claude_verification_requirement'`. Pass `config` and an `onConfigUpdate` that updates the requirement being edited.

- [ ] **Step 3: Type-check**

```bash
pnpm type-check
```
Expected: clean.

- [ ] **Step 4: Smoke-test**

```bash
pnpm tauri:dev
```
- Create a verification template with "Use as plan requirement" ON.
- Create a plan; add a requirement of type "claude_verification_requirement"; pick the template.
- Save the plan.
- Schedule the plan on a date.
- Via psql or curl, verify `scheduled_commitments` now has TWO rows for the plan date: one `type='plan'` and one `type='claude_verification'` with `stake_cents=0` and `evaluation_state.is_plan_requirement=true`.

- [ ] **Step 5: Commit Tasks 15 + 16 together**

```bash
git add components/plans/plan-creation-view.tsx components/plans/claude-verification-requirement-config.tsx
git commit -m "feat: claude_verification_requirement in plan form"
```

**End of Slice 3.**

---

## Task 17: Type-check + full-suite sanity

**Files:** none

- [ ] **Step 1: Run everything**

```bash
pnpm type-check
pnpm test
cd src-tauri && cargo check && cargo test --lib && cd ..
```

Expected: all clean (TS type-check, Vitest suite, Rust compile, Rust credential tests).

If anything fails, fix and commit the fix.

---

## Task 18: End-to-end smoke

**Files:** none

**Context:** Manual verification that the whole thing works against prod (or local server). The user is the only user, so this runs in the dev app but hits the real server.

- [ ] **Step 1: Generate a token via the app**

Start the app, sign in, Settings → Account → Generate API token with a label. Verify `~/.commitkit/credentials.json` exists with 0600 perms and contains a real `ckv_...` token.

- [ ] **Step 2: Create a template via the app**

Templates → Verifications → New. Make one with `is_plan_requirement = false` first (standalone).

- [ ] **Step 3: Schedule it**

From the verifications list, click the calendar icon → today → Schedule.

- [ ] **Step 4: Verify it appears in the day view**

Dashboard → today → verification card visible with status "active".

- [ ] **Step 5: POST a report manually**

```bash
CKV=$(python3 -c "import json; print(json.load(open('/Users/$(whoami)/.commitkit/credentials.json'))['api_token'])")
curl -X POST -H "Authorization: Bearer $CKV" \
  -H "Content-Type: application/json" \
  -d '{"slug":"<your-slug>","passed":true,"summary":"hand-tested","details":{}}' \
  https://api.screentime.commitkit.com/api/claude-verifications/report
```

Expect a 200 with `{ updated: [{ scheduledCommitmentId, reportCount, ... }] }`.

- [ ] **Step 6: Refresh the day view**

Card should update to show the passed status (or at least not be stuck on "active" after you trigger a refresh — depending on how the day view refetches).

- [ ] **Step 7: Create a plan-requirement verification + plan**

Make a second verification with `is_plan_requirement = true`. Create a plan with that as a requirement. Schedule the plan for tomorrow.

- [ ] **Step 8: Inspect the DB**

Use `railway connect ck-st-prod` or the pg node snippet from the top-level CLAUDE.md to query:

```sql
SELECT id, type, template_id, stake_cents, status, evaluation_state
FROM scheduled_commitments
WHERE user_id = '<your uuid>'
ORDER BY created_at DESC
LIMIT 10;
```

Confirm you see one `type='plan'` row (with your plan's stake) AND one `type='claude_verification'` mirror row with `stake_cents=0` and `evaluation_state.is_plan_requirement = true` and `plan_commitment_id` matching the plan row.

- [ ] **Step 9: No commit**

Verification only.

---

## Done criteria

- All 18 tasks complete; Tasks 1–16 each with a passing commit (Tasks 12–13 share one; Tasks 15–16 share one).
- `pnpm type-check` clean on both repos.
- `pnpm test` clean on commitkit-server (180 tests passing + 1 pre-existing time flake) and on commitkit-desktop (existing + slug-helpers).
- `cargo test --lib` clean in commitkit-desktop/src-tauri.
- Smoke test (Task 18) fully exercised.

Once all green, the desktop app is feature-complete for claude_verification. User can:
- Generate/revoke API tokens from Settings.
- Hand-roll a Claude Code skill that reads `~/.commitkit/credentials.json` and POSTs verdicts.
- Create/edit/delete verification templates from Templates → Verifications.
- Schedule a verification on any date from the template list.
- See scheduled verifications in the day view.
- Use a verification as a plan requirement when authoring a plan.
