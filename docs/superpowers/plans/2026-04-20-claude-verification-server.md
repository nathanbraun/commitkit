# Claude Code Verification Commitment — Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add server-side support for a new commitment type `claude_verification` — users commit to running a Claude Code skill that returns `passed:true` by a deadline, or pay the stake. Supports both standalone instances and plan-requirement mirrors (with zero stake; plan owns the charge).

**Architecture:** New template table + API-token table. All per-instance tracking reuses the existing unified `scheduled_commitments` table with a new `type='claude_verification'` discriminator. Existing cron (`commitment-failures`) and finalizer (`createChargeIfPossible`) are extended, not replaced. A new bearer-token auth middleware lets an external Claude Code skill POST a verdict without a JWT. Plan-requirement integration mirrors the existing timer-as-requirement pattern, with server-enforced `stake_cents=0` on mirror rows.

**Tech Stack:** TypeScript, Express, Drizzle ORM, PostgreSQL, Stripe, Vitest. All code lives under `commitkit-server/`.

**Reference spec:** `docs/superpowers/specs/2026-04-20-claude-code-verification-commitment-design.md`

---

## Working directory and conventions

- All paths below are relative to `commitkit-server/` unless noted.
- All commands assume you are in `commitkit-server/` (use `cd commitkit-server/` first).
- Node imports use `.js` suffixes (ESM transpile convention used throughout this repo — e.g. `import { db } from '../db/index.js';`).
- Run tests with `pnpm test` (full suite) or `pnpm vitest run <file>` (single file).
- Type-check with `pnpm type-check`.
- Database migrations are generated via `pnpm db:generate`.
- Commit after every task unless the task note says otherwise. Conventional commit prefixes: `feat:`, `test:`, `refactor:`, `chore:`.

---

## File Structure

### New files

| File | Responsibility |
|------|----------------|
| `src/lib/tokens.ts` | Pure token utilities: generate a raw token, sha256 hash for storage, constant-time compare. |
| `src/middleware/api-token-auth.ts` | Express middleware that validates `Authorization: Bearer ckv_...` against `api_tokens` table and attaches `req.userId`. |
| `src/routes/api-tokens.ts` | CRUD for API tokens (list, create, revoke). JWT-authed. |
| `src/routes/claude-verifications.ts` | Template CRUD + report + extend endpoints. Report is the only api-token-authed route; the rest are JWT-authed. |
| `src/routes/claude-verification-commitments.ts` | Scheduling CRUD for claude_verification scheduled instances. JWT-authed. |
| `__tests__/tokens.test.ts` | Unit tests for `src/lib/tokens.ts`. |
| `__tests__/api-token-auth.test.ts` | Middleware tests (mocked db). |
| `__tests__/routes-api-tokens.test.ts` | API token routes (supertest). |
| `__tests__/routes-claude-verifications.test.ts` | Template CRUD + extend (supertest). |
| `__tests__/routes-claude-verifications-report.test.ts` | Report endpoint with fan-out + error cases (supertest). |
| `__tests__/routes-claude-verification-commitments.test.ts` | Scheduling routes (supertest). |
| `__tests__/evaluators-claude-verification.test.ts` | `evaluateClaudeVerification` unit tests. |
| `__tests__/finalize-claude-verification.test.ts` | `finalizeClaudeVerification` unit tests. |
| `__tests__/plan-claude-verification-integration.test.ts` | End-to-end plan-with-verification-requirement test. |

### Modified files

| File | Change |
|------|--------|
| `src/db/schema.ts` | Add `claudeVerifications` and `apiTokens` table definitions. |
| `src/db/migrations/*` | Drizzle-generated migration from schema change. |
| `src/index.ts` | Mount `/api/api-tokens`, `/api/claude-verifications`, `/api/claude-verification-commitments` routers. |
| `src/domain/evaluators.ts` | Add `evaluateClaudeVerification`; register in the dispatch; extend `evaluatePlan` for `claude_verification_requirement`. |
| `src/domain/finalize.ts` | Add `finalizeClaudeVerification`; register in dispatch. |
| `src/domain/commitment-types.ts` | Register `claude_verification` contract fields for the strictness-direction analysis. |
| `src/routes/cron.ts` | Extend `commitment-failures` dispatch to include `claude_verification` type. |
| `src/routes/requirements.ts` | Add `'claude_verification_requirement'` to `validTypes` (line 34). |
| `src/routes/plan-commitments.ts` | Mirror claude_verification requirements into `scheduled_commitments` rows with `stake_cents=0` and linking `evaluation_state`. |

---

## Task sequence

Tasks are ordered so each is runnable and committable on its own. Type-check passes after every task. Tests added in a task pass at the end of that task.

---

### Task 1: Schema — add `claude_verifications` and `api_tokens` tables

**Files:**
- Modify: `src/db/schema.ts`
- Create (generated): `src/db/migrations/XXXX_*.sql`

**Context:** We're adding two new tables. Follow the existing style in `schema.ts` (look at `timerTemplates` for the template-table style, and note the repo uses snake_case column names with camelCase JS keys via Drizzle's first-arg/second-arg pattern).

- [ ] **Step 1: Add table definitions to `src/db/schema.ts`**

Add after the existing `timerTemplates` definition (roughly around line 155):

```ts
export const claudeVerifications = pgTable('claude_verifications', {
  id: uuid('id').primaryKey().defaultRandom(),
  user_id: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  name: text('name').notNull(),
  slug: text('slug').notNull(),
  stake_cents: integer('stake_cents').notNull(),
  deadline_time: text('deadline_time').notNull(), // "HH:MM" in user tz
  color: text('color').notNull().default('#8b5cf6'),
  allow_deadline_extend: boolean('allow_deadline_extend').notNull().default(false),
  is_plan_requirement: boolean('is_plan_requirement').notNull().default(false),
  active: boolean('active').notNull().default(true),
  created_at: timestamp('created_at').notNull().defaultNow(),
  updated_at: timestamp('updated_at').notNull().defaultNow(),
}, (t) => ({
  uniqUserSlug: uniqueIndex('claude_verifications_user_slug_idx').on(t.user_id, t.slug),
}));

export const apiTokens = pgTable('api_tokens', {
  id: uuid('id').primaryKey().defaultRandom(),
  user_id: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  token_hash: text('token_hash').notNull().unique(),
  label: text('label'),
  created_at: timestamp('created_at').notNull().defaultNow(),
  last_used_at: timestamp('last_used_at'),
  revoked_at: timestamp('revoked_at'),
});
```

If `uniqueIndex` is not already imported from `drizzle-orm/pg-core`, add it to the imports at the top of the file.

- [ ] **Step 2: Generate migration**

Run: `pnpm db:generate`
Expected: a new file created under `src/db/migrations/` (e.g. `0XXX_<name>.sql`) containing `CREATE TABLE "claude_verifications" ...` and `CREATE TABLE "api_tokens" ...` and the unique index.

- [ ] **Step 3: Type-check**

Run: `pnpm type-check`
Expected: no errors.

- [ ] **Step 4: Apply migration locally (optional, skip if you work against a shared dev DB)**

Run: `pnpm db:migrate`
Expected: migration applies successfully.

- [ ] **Step 5: Commit**

```bash
git add src/db/schema.ts src/db/migrations/
git commit -m "feat: add claude_verifications and api_tokens tables"
```

---

### Task 2: Token hashing utility (`src/lib/tokens.ts`)

**Files:**
- Create: `src/lib/tokens.ts`
- Create: `__tests__/tokens.test.ts`

**Context:** Pure utility module. Tokens look like `ckv_<43 base64url chars>`. Storage format is sha256 hex digest. Timing-safe compare is used when verifying.

- [ ] **Step 1: Write the failing test**

Create `__tests__/tokens.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { generateApiToken, hashToken, tokensEqual } from '../src/lib/tokens.js';

describe('tokens', () => {
  it('generateApiToken produces ckv_-prefixed tokens', () => {
    const t = generateApiToken();
    expect(t.startsWith('ckv_')).toBe(true);
    expect(t.length).toBeGreaterThan(40);
  });

  it('generateApiToken produces unique values', () => {
    const set = new Set<string>();
    for (let i = 0; i < 100; i++) set.add(generateApiToken());
    expect(set.size).toBe(100);
  });

  it('hashToken produces a 64-char hex sha256', () => {
    const h = hashToken('ckv_whatever');
    expect(h).toMatch(/^[0-9a-f]{64}$/);
  });

  it('hashToken is deterministic', () => {
    expect(hashToken('ckv_x')).toBe(hashToken('ckv_x'));
  });

  it('tokensEqual is true for equal strings, false otherwise', () => {
    expect(tokensEqual('aaa', 'aaa')).toBe(true);
    expect(tokensEqual('aaa', 'aab')).toBe(false);
    expect(tokensEqual('', '')).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run __tests__/tokens.test.ts`
Expected: FAIL (module not found).

- [ ] **Step 3: Implement `src/lib/tokens.ts`**

```ts
import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';

/**
 * Generate an opaque API token: `ckv_` + 32 bytes base64url-encoded (43 chars, no padding).
 * The raw value is returned once to the caller; only the hash is persisted.
 */
export function generateApiToken(): string {
  return 'ckv_' + randomBytes(32).toString('base64url');
}

/** SHA-256 hex digest of a raw token, used for storage + lookup. */
export function hashToken(raw: string): string {
  return createHash('sha256').update(raw, 'utf8').digest('hex');
}

/** Timing-safe string compare. */
export function tokensEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a, 'utf8');
  const bb = Buffer.from(b, 'utf8');
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}
```

- [ ] **Step 4: Run tests**

Run: `pnpm vitest run __tests__/tokens.test.ts`
Expected: PASS (5/5).

- [ ] **Step 5: Commit**

```bash
git add src/lib/tokens.ts __tests__/tokens.test.ts
git commit -m "feat: token hashing utility"
```

---

### Task 3: API token auth middleware

**Files:**
- Create: `src/middleware/api-token-auth.ts`
- Create: `__tests__/api-token-auth.test.ts`

**Context:** Middleware for the `/api/claude-verifications/report` endpoint. Extracts `Authorization: Bearer ckv_...`, hashes, looks up non-revoked token in `api_tokens`, updates `last_used_at`, attaches `req.userId`. 401 on any failure.

- [ ] **Step 1: Write the failing test**

Create `__tests__/api-token-auth.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest';

const mocks = vi.hoisted(() => ({
  selectRows: [] as unknown[],
  updateCalls: [] as unknown[],
}));

vi.mock('../src/db/index.js', () => ({
  db: {
    select: () => ({
      from: () => ({
        where: () => ({
          limit: () => Promise.resolve(mocks.selectRows),
        }),
      }),
    }),
    update: () => ({
      set: (values: unknown) => ({
        where: (where: unknown) => {
          mocks.updateCalls.push({ values, where });
          return Promise.resolve();
        },
      }),
    }),
  },
}));

const { authenticateApiToken } = await import('../src/middleware/api-token-auth.js');

function makeReqRes(header?: string) {
  const req: any = { headers: header ? { authorization: header } : {} };
  const res: any = { status: vi.fn().mockReturnThis(), json: vi.fn() };
  const next = vi.fn();
  return { req, res, next };
}

beforeEach(() => {
  mocks.selectRows = [];
  mocks.updateCalls = [];
});

describe('authenticateApiToken', () => {
  it('401 when no Authorization header', async () => {
    const { req, res, next } = makeReqRes();
    await authenticateApiToken(req, res, next);
    expect(res.status).toHaveBeenCalledWith(401);
    expect(next).not.toHaveBeenCalled();
  });

  it('401 when header is not a bearer token', async () => {
    const { req, res, next } = makeReqRes('Basic abc');
    await authenticateApiToken(req, res, next);
    expect(res.status).toHaveBeenCalledWith(401);
  });

  it('401 when token has no matching row', async () => {
    mocks.selectRows = [];
    const { req, res, next } = makeReqRes('Bearer ckv_nope');
    await authenticateApiToken(req, res, next);
    expect(res.status).toHaveBeenCalledWith(401);
  });

  it('401 when token is revoked', async () => {
    mocks.selectRows = [{ id: 't1', user_id: 'u1', revoked_at: new Date() }];
    const { req, res, next } = makeReqRes('Bearer ckv_revoked');
    await authenticateApiToken(req, res, next);
    expect(res.status).toHaveBeenCalledWith(401);
  });

  it('attaches req.userId and calls next on valid token', async () => {
    mocks.selectRows = [{ id: 't1', user_id: 'user-1', revoked_at: null }];
    const { req, res, next } = makeReqRes('Bearer ckv_good');
    await authenticateApiToken(req, res, next);
    expect(next).toHaveBeenCalled();
    expect(req.userId).toBe('user-1');
  });

  it('updates last_used_at on valid token', async () => {
    mocks.selectRows = [{ id: 't1', user_id: 'user-1', revoked_at: null }];
    const { req, res, next } = makeReqRes('Bearer ckv_good');
    await authenticateApiToken(req, res, next);
    expect(mocks.updateCalls.length).toBe(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run __tests__/api-token-auth.test.ts`
Expected: FAIL (module not found).

- [ ] **Step 3: Implement `src/middleware/api-token-auth.ts`**

```ts
import express from 'express';
import { db } from '../db/index.js';
import { apiTokens } from '../db/schema.js';
import { eq } from 'drizzle-orm';
import { hashToken } from '../lib/tokens.js';

export interface ApiTokenRequest extends express.Request {
  userId?: string;
  apiTokenId?: string;
}

export const authenticateApiToken = async (
  req: ApiTokenRequest,
  res: express.Response,
  next: express.NextFunction,
) => {
  const authHeader = req.headers['authorization'];
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'API token required' });
  }
  const raw = authHeader.slice('Bearer '.length).trim();
  if (!raw.startsWith('ckv_')) {
    return res.status(401).json({ error: 'Invalid API token' });
  }

  const hash = hashToken(raw);
  const rows = await db.select()
    .from(apiTokens)
    .where(eq(apiTokens.token_hash, hash))
    .limit(1);

  const row = rows[0] as { id: string; user_id: string; revoked_at: Date | null } | undefined;
  if (!row || row.revoked_at) {
    return res.status(401).json({ error: 'Invalid or revoked API token' });
  }

  // Fire-and-forget last_used_at update.
  await db.update(apiTokens)
    .set({ last_used_at: new Date() })
    .where(eq(apiTokens.id, row.id));

  req.userId = row.user_id;
  req.apiTokenId = row.id;
  next();
};
```

- [ ] **Step 4: Run tests**

Run: `pnpm vitest run __tests__/api-token-auth.test.ts`
Expected: PASS (6/6).

- [ ] **Step 5: Type-check**

Run: `pnpm type-check`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add src/middleware/api-token-auth.ts __tests__/api-token-auth.test.ts
git commit -m "feat: api token auth middleware"
```

---

### Task 4: API token management routes

**Files:**
- Create: `src/routes/api-tokens.ts`
- Create: `__tests__/routes-api-tokens.test.ts`
- Modify: `src/index.ts` (mount the router)

**Context:** Three endpoints:

- `GET /api/api-tokens` — list tokens (never returns raw).
- `POST /api/api-tokens` — create; response includes the **raw** token once.
- `POST /api/api-tokens/:id/revoke` — soft revoke.

All JWT-authed via the existing `authenticateToken` middleware.

- [ ] **Step 1: Write the failing test**

Create `__tests__/routes-api-tokens.test.ts`. Model after existing route test style. Minimal stub:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest';
import express from 'express';
import request from 'supertest';

// Mock DB before importing the router.
const mocks = vi.hoisted(() => ({
  rows: [] as any[],
  inserted: [] as any[],
  updated: [] as any[],
}));

vi.mock('../src/db/index.js', () => ({
  db: {
    select: () => ({ from: () => ({ where: () => Promise.resolve(mocks.rows) }) }),
    insert: () => ({
      values: (v: any) => ({
        returning: () => {
          mocks.inserted.push(v);
          return Promise.resolve([{ ...v, id: 'new-id', created_at: new Date() }]);
        },
      }),
    }),
    update: () => ({
      set: (s: any) => ({
        where: (w: any) => {
          mocks.updated.push({ s, w });
          return Promise.resolve();
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

const { default: router } = await import('../src/routes/api-tokens.js');

const app = express();
app.use(express.json());
app.use('/api/api-tokens', router);

beforeEach(() => {
  mocks.rows = [];
  mocks.inserted = [];
  mocks.updated = [];
});

describe('api-tokens routes', () => {
  it('POST creates a token and returns the raw value once', async () => {
    const res = await request(app).post('/api/api-tokens').send({ label: 'my-mac' });
    expect(res.status).toBe(200);
    expect(res.body.token).toMatch(/^ckv_/);
    expect(res.body.label).toBe('my-mac');
    // Hash persisted, not raw.
    expect(mocks.inserted[0].token_hash).toBeDefined();
    expect(mocks.inserted[0].token_hash).not.toEqual(res.body.token);
  });

  it('GET lists tokens without raw values', async () => {
    mocks.rows = [
      { id: 't1', user_id: 'user-1', label: 'mac', token_hash: 'hash', created_at: new Date(), last_used_at: null, revoked_at: null },
    ];
    const res = await request(app).get('/api/api-tokens');
    expect(res.status).toBe(200);
    expect(res.body.tokens[0].token).toBeUndefined();
    expect(res.body.tokens[0].token_hash).toBeUndefined();
    expect(res.body.tokens[0].label).toBe('mac');
  });

  it('POST /:id/revoke sets revoked_at', async () => {
    const res = await request(app).post('/api/api-tokens/t1/revoke');
    expect(res.status).toBe(200);
    expect(mocks.updated[0].s.revoked_at).toBeInstanceOf(Date);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run __tests__/routes-api-tokens.test.ts`
Expected: FAIL (module not found).

- [ ] **Step 3: Implement `src/routes/api-tokens.ts`**

```ts
import { Router } from 'express';
import { db } from '../db/index.js';
import { apiTokens } from '../db/schema.js';
import { and, eq } from 'drizzle-orm';
import { authenticateToken, AuthRequest } from '../middleware/auth.js';
import { generateApiToken, hashToken } from '../lib/tokens.js';

const router = Router();

router.get('/', authenticateToken, async (req: AuthRequest, res) => {
  const userId = req.userId!;
  const rows = await db.select().from(apiTokens).where(eq(apiTokens.user_id, userId));
  const sanitized = rows.map((r: any) => ({
    id: r.id,
    label: r.label,
    created_at: r.created_at,
    last_used_at: r.last_used_at,
    revoked_at: r.revoked_at,
  }));
  res.json({ tokens: sanitized });
});

router.post('/', authenticateToken, async (req: AuthRequest, res) => {
  const userId = req.userId!;
  const { label } = req.body as { label?: string };
  const raw = generateApiToken();
  const token_hash = hashToken(raw);
  const [row] = await db.insert(apiTokens)
    .values({ user_id: userId, token_hash, label: label ?? null })
    .returning();
  res.json({
    id: row.id,
    label: row.label,
    created_at: row.created_at,
    token: raw,
  });
});

router.post('/:id/revoke', authenticateToken, async (req: AuthRequest, res) => {
  const userId = req.userId!;
  const id = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  await db.update(apiTokens)
    .set({ revoked_at: new Date() })
    .where(and(eq(apiTokens.id, id), eq(apiTokens.user_id, userId)));
  res.json({ success: true });
});

export default router;
```

- [ ] **Step 4: Mount in `src/index.ts`**

Add import near the other route imports and mount after the other `app.use('/api/...')` lines:

```ts
import apiTokensRouter from './routes/api-tokens.js';
// ...
app.use('/api/api-tokens', apiTokensRouter);
```

- [ ] **Step 5: Run tests**

Run: `pnpm vitest run __tests__/routes-api-tokens.test.ts`
Expected: PASS (3/3).

- [ ] **Step 6: Type-check**

Run: `pnpm type-check`
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add src/routes/api-tokens.ts __tests__/routes-api-tokens.test.ts src/index.ts
git commit -m "feat: api token management routes"
```

---

### Task 5: Claude verification template CRUD

**Files:**
- Create: `src/routes/claude-verifications.ts` (CRUD portion only — report/extend added in later tasks)
- Create: `__tests__/routes-claude-verifications.test.ts`
- Modify: `src/index.ts`

**Context:** Mirror the `/api/plans` route style (see `src/routes/plans.ts`). Endpoints:

- `GET /api/claude-verifications` — list user's templates (excludes soft-deleted).
- `POST /api/claude-verifications` — create. Validates slug format `^[a-z0-9-]+$` and uniqueness per user.
- `PATCH /api/claude-verifications/:id` — partial update.
- `DELETE /api/claude-verifications/:id` — soft delete (sets `active=false`).

- [ ] **Step 1: Write the failing test**

Create `__tests__/routes-claude-verifications.test.ts` covering:
- POST happy path; response matches input.
- POST rejects invalid slug (`"Bad Slug"` with spaces → 400).
- POST rejects duplicate slug (mock the DB insert to throw the unique constraint error → 409).
- GET returns only `active=true` rows for the caller.
- PATCH updates allowed fields and returns the updated row.
- DELETE sets `active=false`, returns success.

Use the same mocking pattern as `routes-api-tokens.test.ts`. Key mocked DB behaviors:

```ts
// For unique constraint test:
vi.mocked(db.insert).mockImplementationOnce(() => ({
  values: () => ({ returning: () => Promise.reject({ code: '23505' }) }),
}));
```

(If the existing mock helpers in the repo handle this differently, follow their lead — check `__tests__/setup.ts` and any route test if one appears later.)

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run __tests__/routes-claude-verifications.test.ts`
Expected: FAIL (module not found).

- [ ] **Step 3: Implement `src/routes/claude-verifications.ts`**

```ts
import { Router } from 'express';
import { db } from '../db/index.js';
import { claudeVerifications } from '../db/schema.js';
import { and, eq } from 'drizzle-orm';
import { authenticateToken, AuthRequest } from '../middleware/auth.js';

const router = Router();

const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;

router.get('/', authenticateToken, async (req: AuthRequest, res) => {
  const userId = req.userId!;
  const rows = await db.select()
    .from(claudeVerifications)
    .where(and(eq(claudeVerifications.user_id, userId), eq(claudeVerifications.active, true)));
  res.json({ claude_verifications: rows });
});

router.post('/', authenticateToken, async (req: AuthRequest, res) => {
  const userId = req.userId!;
  const { name, slug, stakeCents, deadlineTime, color, allowDeadlineExtend, isPlanRequirement } = req.body;

  if (typeof name !== 'string' || !name.trim()) return res.status(400).json({ error: 'name is required' });
  if (typeof slug !== 'string' || !SLUG_RE.test(slug)) return res.status(400).json({ error: 'slug must match ^[a-z0-9][a-z0-9-]{0,63}$' });
  if (!Number.isInteger(stakeCents) || stakeCents < 0) return res.status(400).json({ error: 'stakeCents must be a non-negative integer' });
  if (typeof deadlineTime !== 'string' || !/^\d{2}:\d{2}$/.test(deadlineTime)) return res.status(400).json({ error: 'deadlineTime must be HH:MM' });

  try {
    const [row] = await db.insert(claudeVerifications).values({
      user_id: userId,
      name: name.trim(),
      slug,
      stake_cents: stakeCents,
      deadline_time: deadlineTime,
      color: color || '#8b5cf6',
      allow_deadline_extend: !!allowDeadlineExtend,
      is_plan_requirement: !!isPlanRequirement,
    }).returning();
    res.json({ claude_verification: row });
  } catch (err: any) {
    if (err?.code === '23505') return res.status(409).json({ error: 'slug already exists' });
    console.error('Create claude_verification error:', err);
    res.status(500).json({ error: 'Failed to create claude verification' });
  }
});

router.patch('/:id', authenticateToken, async (req: AuthRequest, res) => {
  const userId = req.userId!;
  const id = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  const { name, slug, stakeCents, deadlineTime, color, allowDeadlineExtend, isPlanRequirement, active } = req.body;

  const updates: Record<string, unknown> = { updated_at: new Date() };
  if (name !== undefined) updates.name = String(name).trim();
  if (slug !== undefined) {
    if (!SLUG_RE.test(slug)) return res.status(400).json({ error: 'invalid slug' });
    updates.slug = slug;
  }
  if (stakeCents !== undefined) {
    if (!Number.isInteger(stakeCents) || stakeCents < 0) return res.status(400).json({ error: 'invalid stakeCents' });
    updates.stake_cents = stakeCents;
  }
  if (deadlineTime !== undefined) {
    if (!/^\d{2}:\d{2}$/.test(deadlineTime)) return res.status(400).json({ error: 'invalid deadlineTime' });
    updates.deadline_time = deadlineTime;
  }
  if (color !== undefined) updates.color = color;
  if (allowDeadlineExtend !== undefined) updates.allow_deadline_extend = !!allowDeadlineExtend;
  if (isPlanRequirement !== undefined) updates.is_plan_requirement = !!isPlanRequirement;
  if (active !== undefined) updates.active = !!active;

  try {
    const [row] = await db.update(claudeVerifications)
      .set(updates)
      .where(and(eq(claudeVerifications.id, id), eq(claudeVerifications.user_id, userId)))
      .returning();
    if (!row) return res.status(404).json({ error: 'not found' });
    res.json({ claude_verification: row });
  } catch (err: any) {
    if (err?.code === '23505') return res.status(409).json({ error: 'slug already exists' });
    console.error('Update claude_verification error:', err);
    res.status(500).json({ error: 'Failed to update' });
  }
});

router.delete('/:id', authenticateToken, async (req: AuthRequest, res) => {
  const userId = req.userId!;
  const id = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;
  await db.update(claudeVerifications)
    .set({ active: false, updated_at: new Date() })
    .where(and(eq(claudeVerifications.id, id), eq(claudeVerifications.user_id, userId)));
  res.json({ success: true });
});

export default router;
```

- [ ] **Step 4: Mount in `src/index.ts`**

```ts
import claudeVerificationsRouter from './routes/claude-verifications.js';
// ...
app.use('/api/claude-verifications', claudeVerificationsRouter);
```

- [ ] **Step 5: Run tests**

Run: `pnpm vitest run __tests__/routes-claude-verifications.test.ts`
Expected: PASS.

- [ ] **Step 6: Type-check**

Run: `pnpm type-check`
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add src/routes/claude-verifications.ts __tests__/routes-claude-verifications.test.ts src/index.ts
git commit -m "feat: claude verification template CRUD"
```

---

### Task 6: Scheduling endpoint (standalone instances)

**Files:**
- Create: `src/routes/claude-verification-commitments.ts`
- Create: `__tests__/routes-claude-verification-commitments.test.ts`
- Modify: `src/index.ts`

**Context:** Parallels `src/routes/plan-commitments.ts`. Endpoints:

- `POST /api/claude-verification-commitments` — body: `{ templateId, dates: string[] }`. Inserts one `scheduled_commitments` row per date.
- `DELETE /api/claude-verification-commitments/:scheduledCommitmentId` — unschedule (only if status=active and outside the 10-min lock).

Reuse `splitTemplate` from `src/domain/commitment-types.ts` once we've registered the new type in Task 10 — for now, construct `contract_snapshot` / `identity_snapshot` inline and we'll refactor in a later task.

Use existing `computeDueAt(date, timeStr, tz)` and `userTimezone(userId)` helpers (check where they're exported from in `plan-commitments.ts` and reuse the same import).

- [ ] **Step 1: Write the failing test**

Create `__tests__/routes-claude-verification-commitments.test.ts` covering:
- POST creates one row per date; each row has correct `template_id`, `type='claude_verification'`, `stake_cents=<template.stake_cents>`, `contract_snapshot` with deadline_time + allow_deadline_extend + stake_cents, `identity_snapshot` with name/slug/color.
- POST rejects invalid `dates` (non-array, wrong format).
- POST 404 when template not found or belongs to another user.
- DELETE happy path (row with status='active', created < 10 min ago).
- DELETE 409 when row is locked (created > 10 min ago).
- DELETE 409 when status != 'active'.

Mock `computeDueAt` + `userTimezone` as needed.

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run __tests__/routes-claude-verification-commitments.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement `src/routes/claude-verification-commitments.ts`**

```ts
import { Router } from 'express';
import { db } from '../db/index.js';
import { claudeVerifications, scheduledCommitments } from '../db/schema.js';
import { and, eq, inArray } from 'drizzle-orm';
import { authenticateToken, AuthRequest } from '../middleware/auth.js';
import { computeDueAt, userTimezone } from './plan-commitments.js'; // adjust import to wherever these live

const router = Router();

const LOCK_WINDOW_MS = 10 * 60 * 1000;

router.post('/', authenticateToken, async (req: AuthRequest, res) => {
  const userId = req.userId!;
  const { templateId, dates } = req.body as { templateId?: string; dates?: string[] };

  if (!templateId) return res.status(400).json({ error: 'templateId is required' });
  if (!Array.isArray(dates) || dates.length === 0) return res.status(400).json({ error: 'dates must be a non-empty array' });
  for (const d of dates) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(d)) return res.status(400).json({ error: `invalid date: ${d}` });
  }

  const [tmpl] = await db.select()
    .from(claudeVerifications)
    .where(and(eq(claudeVerifications.id, templateId), eq(claudeVerifications.user_id, userId), eq(claudeVerifications.active, true)))
    .limit(1);
  if (!tmpl) return res.status(404).json({ error: 'template not found' });

  const tz = await userTimezone(userId);

  const valuesToInsert = dates.map((date) => ({
    user_id: userId,
    type: 'claude_verification' as const,
    template_id: tmpl.id,
    due_at: computeDueAt(date, tmpl.deadline_time, tz),
    stake_cents: tmpl.stake_cents,
    status: 'active' as const,
    contract_snapshot: {
      stake_cents: tmpl.stake_cents,
      deadline_time: tmpl.deadline_time,
      allow_deadline_extend: tmpl.allow_deadline_extend,
    },
    identity_snapshot: {
      name: tmpl.name,
      slug: tmpl.slug,
      color: tmpl.color,
    },
    evaluation_state: { date },
  }));

  const rows = await db.insert(scheduledCommitments).values(valuesToInsert).returning();
  res.json({ claude_verification_commitments: rows });
});

router.delete('/:id', authenticateToken, async (req: AuthRequest, res) => {
  const userId = req.userId!;
  const id = Array.isArray(req.params.id) ? req.params.id[0] : req.params.id;

  const [row] = await db.select()
    .from(scheduledCommitments)
    .where(and(
      eq(scheduledCommitments.id, id),
      eq(scheduledCommitments.user_id, userId),
      eq(scheduledCommitments.type, 'claude_verification'),
    ))
    .limit(1);

  if (!row) return res.status(404).json({ error: 'not found' });
  if (row.status !== 'active') return res.status(409).json({ error: `cannot unschedule: status=${row.status}` });
  if (Date.now() - new Date(row.created_at).getTime() > LOCK_WINDOW_MS) {
    return res.status(409).json({ error: 'commitment is locked (created more than 10 minutes ago)' });
  }

  await db.delete(scheduledCommitments).where(eq(scheduledCommitments.id, id));
  res.json({ success: true });
});

export default router;
```

If `computeDueAt` / `userTimezone` are not exported from `plan-commitments.ts`, lift them into `src/lib/datetime.ts` as part of this task and import from there (updating `plan-commitments.ts` to import from the new location). Keep behavior identical.

- [ ] **Step 4: Mount in `src/index.ts`**

```ts
import claudeVerificationCommitmentsRouter from './routes/claude-verification-commitments.js';
// ...
app.use('/api/claude-verification-commitments', claudeVerificationCommitmentsRouter);
```

- [ ] **Step 5: Run tests**

Run: `pnpm vitest run __tests__/routes-claude-verification-commitments.test.ts`
Expected: PASS.

- [ ] **Step 6: Type-check**

Run: `pnpm type-check`
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add src/routes/claude-verification-commitments.ts __tests__/routes-claude-verification-commitments.test.ts src/index.ts
# If you moved helpers:
git add src/lib/datetime.ts src/routes/plan-commitments.ts
git commit -m "feat: schedule claude verification commitments"
```

---

### Task 7: Extend-deadline endpoint

**Files:**
- Modify: `src/routes/claude-verifications.ts` (add extend route)
- Create: `__tests__/routes-claude-verifications-extend.test.ts`

**Context:** Mirror existing `extendPlanDeadline` behavior. Endpoint:

- `POST /api/claude-verifications/extend/:scheduledCommitmentId` — bump `due_at` by 2 minutes.
  - Requires `contract_snapshot.allow_deadline_extend === true`.
  - Must be within the last 2 minutes before current `due_at`.
  - Row must be `status='active'`.

Uses JWT auth (not the report API-token auth).

- [ ] **Step 1: Write the failing test**

Create `__tests__/routes-claude-verifications-extend.test.ts` covering:
- Happy path: due_at is 1 min away, `allow_deadline_extend=true` → `due_at` is bumped by 120 seconds, response includes new `due_at`.
- 403 when `allow_deadline_extend=false`.
- 409 when more than 2 min until `due_at`.
- 409 when `due_at` is already past.
- 409 when `status != 'active'`.
- 404 when row does not belong to the user.

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run __tests__/routes-claude-verifications-extend.test.ts`
Expected: FAIL (route not implemented).

- [ ] **Step 3: Add the extend route to `src/routes/claude-verifications.ts`**

```ts
// ... existing imports ...
import { scheduledCommitments } from '../db/schema.js';

const EXTEND_WINDOW_MS = 2 * 60 * 1000;
const EXTEND_BUMP_MS = 2 * 60 * 1000;

router.post('/extend/:scheduledCommitmentId', authenticateToken, async (req: AuthRequest, res) => {
  const userId = req.userId!;
  const id = Array.isArray(req.params.scheduledCommitmentId) ? req.params.scheduledCommitmentId[0] : req.params.scheduledCommitmentId;

  const [row] = await db.select()
    .from(scheduledCommitments)
    .where(and(
      eq(scheduledCommitments.id, id),
      eq(scheduledCommitments.user_id, userId),
      eq(scheduledCommitments.type, 'claude_verification'),
    ))
    .limit(1);

  if (!row) return res.status(404).json({ error: 'not found' });
  if (row.status !== 'active') return res.status(409).json({ error: `status=${row.status}` });

  const contract = (row.contract_snapshot ?? {}) as Record<string, unknown>;
  if (contract.allow_deadline_extend !== true) return res.status(403).json({ error: 'extend disallowed' });

  const now = Date.now();
  const dueAt = new Date(row.due_at).getTime();
  if (dueAt <= now) return res.status(409).json({ error: 'already past deadline' });
  if (dueAt - now > EXTEND_WINDOW_MS) return res.status(409).json({ error: 'not within extend window' });

  const newDueAt = new Date(dueAt + EXTEND_BUMP_MS);
  const [updated] = await db.update(scheduledCommitments)
    .set({ due_at: newDueAt, updated_at: new Date() })
    .where(eq(scheduledCommitments.id, id))
    .returning();

  res.json({ claude_verification_commitment: updated });
});
```

- [ ] **Step 4: Run tests**

Run: `pnpm vitest run __tests__/routes-claude-verifications-extend.test.ts`
Expected: PASS.

- [ ] **Step 5: Type-check and commit**

```bash
pnpm type-check
git add src/routes/claude-verifications.ts __tests__/routes-claude-verifications-extend.test.ts
git commit -m "feat: extend claude verification deadline"
```

---

### Task 8: Report endpoint (fan-out)

**Files:**
- Modify: `src/routes/claude-verifications.ts` (add report route)
- Create: `__tests__/routes-claude-verifications-report.test.ts`

**Context:** API-token-authed. Partition matching rows by updatability; update all or none. Detailed resolution logic from the spec:

1. Lookup `claude_verifications` by `(userId, slug)` where `active=true`. 404 if none.
2. Lookup all `scheduled_commitments` rows where `template_id = that.id`, `type = 'claude_verification'`, date-component of `due_at` (in user tz) = resolved date. 404 if empty.
3. Partition into updatable (`status='active' AND due_at > now()`) vs rejected.
4. If updatable is empty → 409.
5. Else update all updatable atomically.

`date` in the request body defaults to "today" in user tz.

- [ ] **Step 1: Write the failing test**

Create `__tests__/routes-claude-verifications-report.test.ts` covering:
- Happy path single row, default date.
- Happy path single row, explicit date.
- 401 (middleware handles this — verify it returns 401 when no auth header).
- 404 unknown slug.
- 404 no scheduled row for date.
- 409 all rows past deadline.
- 409 all rows already completed.
- Fan-out: two rows (one standalone + one mirror) both updated atomically.
- 400 missing `passed`.
- 413 oversized `details`.
- Verify `evaluation_state` on the updated row(s) contains `passed`, `summary`, `details`, `reported_at`, incremented `report_count`.

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run __tests__/routes-claude-verifications-report.test.ts`
Expected: FAIL.

- [ ] **Step 3: Add the report route to `src/routes/claude-verifications.ts`**

```ts
// Top of file:
import { authenticateApiToken, ApiTokenRequest } from '../middleware/api-token-auth.js';
import { sql } from 'drizzle-orm';

const MAX_DETAILS_BYTES = 64 * 1024;

// Helper: find today's date in a user's tz. Reuse userTimezone() lookup.
async function todayInUserTz(userId: string): Promise<string> {
  const tz = await userTimezone(userId); // import from shared helpers
  const fmt = new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' });
  return fmt.format(new Date()); // yields YYYY-MM-DD
}

router.post('/report', authenticateApiToken, async (req: ApiTokenRequest, res) => {
  const userId = req.userId!;
  const { slug, date: dateInput, passed, summary, details } = req.body as {
    slug?: string; date?: string; passed?: boolean; summary?: string; details?: unknown;
  };

  if (typeof slug !== 'string') return res.status(400).json({ error: 'slug is required' });
  if (typeof passed !== 'boolean') return res.status(400).json({ error: 'passed (boolean) is required' });

  const date = dateInput ?? await todayInUserTz(userId);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return res.status(400).json({ error: 'invalid date' });

  let summaryClean: string | undefined = undefined;
  if (summary !== undefined) {
    if (typeof summary !== 'string') return res.status(400).json({ error: 'summary must be string' });
    summaryClean = summary.slice(0, 500);
  }

  if (details !== undefined) {
    const sz = Buffer.byteLength(JSON.stringify(details), 'utf8');
    if (sz > MAX_DETAILS_BYTES) return res.status(413).json({ error: 'details payload too large' });
  }

  // Resolve template.
  const [tmpl] = await db.select()
    .from(claudeVerifications)
    .where(and(
      eq(claudeVerifications.user_id, userId),
      eq(claudeVerifications.slug, slug),
      eq(claudeVerifications.active, true),
    ))
    .limit(1);
  if (!tmpl) return res.status(404).json({ error: `no active verification with slug '${slug}'` });

  // Find all scheduled rows for this template on this date (in user tz).
  // Date filter: convert date -> a 24h window in user tz.
  const tz = await userTimezone(userId);
  const dayStart = zonedDateToUtc(date, '00:00', tz);
  const dayEnd = zonedDateToUtc(date, '00:00', tz, { addDays: 1 });

  const candidateRows = await db.select()
    .from(scheduledCommitments)
    .where(and(
      eq(scheduledCommitments.user_id, userId),
      eq(scheduledCommitments.type, 'claude_verification'),
      eq(scheduledCommitments.template_id, tmpl.id),
      sql`${scheduledCommitments.due_at} >= ${dayStart}`,
      sql`${scheduledCommitments.due_at} < ${dayEnd}`,
    ));

  if (candidateRows.length === 0) {
    return res.status(404).json({ error: `no verification scheduled for ${date}` });
  }

  const now = Date.now();
  const updatable: any[] = [];
  const rejected: Array<{ row: any; reason: string }> = [];
  for (const row of candidateRows) {
    if (row.status !== 'active') {
      rejected.push({ row, reason: `verification already ${row.status}` });
    } else if (new Date(row.due_at).getTime() <= now) {
      rejected.push({ row, reason: 'deadline has passed' });
    } else {
      updatable.push(row);
    }
  }

  if (updatable.length === 0) {
    const first = rejected[0]!.reason;
    return res.status(409).json({ error: first });
  }

  // Atomic update of all updatable rows.
  const reportedAt = new Date();
  const updatedRows: any[] = [];
  for (const row of updatable) {
    const prev = (row.evaluation_state ?? {}) as Record<string, unknown>;
    const nextState: Record<string, unknown> = {
      ...prev,
      passed,
      summary: summaryClean,
      details,
      reported_at: reportedAt.toISOString(),
      report_count: ((prev.report_count as number | undefined) ?? 0) + 1,
    };
    const [u] = await db.update(scheduledCommitments)
      .set({ evaluation_state: nextState, updated_at: reportedAt })
      .where(eq(scheduledCommitments.id, row.id))
      .returning();
    updatedRows.push(u);
  }

  res.json({
    updated: updatedRows.map((r) => ({
      scheduledCommitmentId: r.id,
      status: r.status,
      dueAt: r.due_at,
      reportCount: (r.evaluation_state as any).report_count,
      isPlanRequirement: (r.evaluation_state as any).is_plan_requirement === true,
    })),
  });
});
```

**About `zonedDateToUtc`:** this helper converts a date + HH:MM in a named IANA tz to a UTC `Date`. It should exist in the same module as `computeDueAt` (or be added there). If not present, add a small helper:

```ts
// In src/lib/datetime.ts (or wherever computeDueAt lives):
export function zonedDateToUtc(
  dateYmd: string,
  hhmm: string,
  tz: string,
  opts?: { addDays?: number },
): Date {
  const [y, m, d] = dateYmd.split('-').map(Number);
  const [hh, mm] = hhmm.split(':').map(Number);
  const addDays = opts?.addDays ?? 0;
  // Build a UTC candidate, then adjust by the tz offset at that moment.
  const candidate = new Date(Date.UTC(y, m - 1, d + addDays, hh, mm));
  const offsetMin = getTzOffsetMinutes(tz, candidate);
  return new Date(candidate.getTime() - offsetMin * 60_000);
}
```

Reuse whatever tz-offset helper `computeDueAt` already uses.

- [ ] **Step 4: Run tests**

Run: `pnpm vitest run __tests__/routes-claude-verifications-report.test.ts`
Expected: PASS.

- [ ] **Step 5: Type-check and commit**

```bash
pnpm type-check
git add src/routes/claude-verifications.ts __tests__/routes-claude-verifications-report.test.ts src/lib/datetime.ts
git commit -m "feat: claude verification report endpoint with fan-out"
```

---

### Task 9: Evaluator for claude_verification

**Files:**
- Modify: `src/domain/evaluators.ts`
- Create: `__tests__/evaluators-claude-verification.test.ts`

**Context:** Add `evaluateClaudeVerification(row)` and register it in the dispatch (follow the dispatch pattern in the existing file — likely a `switch(type)` or a map). Rules:

- `status !== 'active'` → `already_processed`.
- `evaluation_state.passed === true` → `passed`.
- Anything else (`passed === false`, missing, or no report) → `failed`.

- [ ] **Step 1: Write the failing test**

Create `__tests__/evaluators-claude-verification.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { evaluate } from '../src/domain/evaluators.js';

function row(overrides: any = {}) {
  return {
    id: 'sc-1',
    user_id: 'u-1',
    type: 'claude_verification',
    status: 'active',
    due_at: new Date('2026-04-20T23:00:00Z'),
    stake_cents: 500,
    contract_snapshot: {},
    identity_snapshot: { name: 'GTD audit', slug: 'gtd', color: '#8b5cf6' },
    evaluation_state: {},
    ...overrides,
  };
}

describe('evaluateClaudeVerification', () => {
  it('passed when evaluation_state.passed === true', async () => {
    const r = await evaluate(row({ evaluation_state: { passed: true, report_count: 2 } }));
    expect(r.outcome).toBe('passed');
  });

  it('failed when evaluation_state.passed === false', async () => {
    const r = await evaluate(row({ evaluation_state: { passed: false } }));
    expect(r.outcome).toBe('failed');
  });

  it('failed when no report arrived (empty evaluation_state)', async () => {
    const r = await evaluate(row({ evaluation_state: {} }));
    expect(r.outcome).toBe('failed');
  });

  it('already_processed when status is not active', async () => {
    const r = await evaluate(row({ status: 'completed', evaluation_state: { passed: true } }));
    expect(r.outcome).toBe('already_processed');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run __tests__/evaluators-claude-verification.test.ts`
Expected: FAIL (dispatch does not handle 'claude_verification').

- [ ] **Step 3: Add evaluator to `src/domain/evaluators.ts`**

Add near the existing evaluators:

```ts
async function evaluateClaudeVerification(row: SchedRow): Promise<EvaluationResult> {
  if (row.status !== 'active') {
    return {
      outcome: 'already_processed',
      description: `status=${row.status}`,
      metadata: { status: row.status },
    };
  }
  const ev = (row.evaluation_state ?? {}) as Record<string, unknown>;
  if (ev.passed === true) {
    return {
      outcome: 'passed',
      description: 'verification reported passed',
      metadata: { reported_at: ev.reported_at, report_count: ev.report_count ?? 1 },
    };
  }
  return {
    outcome: 'failed',
    description: ev.passed === false ? 'verification reported failed' : 'no verification reported',
    metadata: { report_count: ev.report_count ?? 0, summary: ev.summary },
  };
}
```

Register in the dispatch — find the existing type switch in the top-level `evaluate()` function and add:

```ts
case 'claude_verification':
  return evaluateClaudeVerification(row);
```

- [ ] **Step 4: Run tests**

Run: `pnpm vitest run __tests__/evaluators-claude-verification.test.ts`
Expected: PASS (4/4).

- [ ] **Step 5: Type-check and commit**

```bash
pnpm type-check
git add src/domain/evaluators.ts __tests__/evaluators-claude-verification.test.ts
git commit -m "feat: evaluateClaudeVerification"
```

---

### Task 10: Finalizer + commitment-types registration + cron dispatch

**Files:**
- Modify: `src/domain/finalize.ts`
- Modify: `src/domain/commitment-types.ts`
- Modify: `src/routes/cron.ts`
- Create: `__tests__/finalize-claude-verification.test.ts`

**Context:** Add `finalizeClaudeVerification(row, outcome)`; register in the finalize dispatch. Register claude_verification contract fields (for strictness-direction analysis). Extend the cron's commitment-failures handler to include the new type. The finalizer must NOT call Stripe when `stake_cents = 0` (mirror rows); `createChargeIfPossible` already returns `{kind: 'no_stake'}` in that case, which the finalizer must handle gracefully.

- [ ] **Step 1: Write the failing test**

Create `__tests__/finalize-claude-verification.test.ts`. Model after `__tests__/finalize.test.ts` (use the same mocking setup). Cases:
- passed outcome → row updated to `status='completed'`, `charge_attempted=false`, no Stripe call.
- failed outcome, standalone row (stake=500) → Stripe called with 500, `charge_attempted=true`, `charge_processed=true` on success, `stripe_payment_intent_id` recorded.
- failed outcome, mirror row (stake=0) → Stripe NOT called; row updated to `status='failed'`, `charge_attempted=true`, `charge_processed=false` (or `true` with kind=no_stake, match whatever `createChargeIfPossible` returns — follow the existing timer finalizer's handling).
- failed outcome, no payment method → Stripe NOT called; `charge_attempted=true`, `charge_processed=false`, `charge_error` set.

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run __tests__/finalize-claude-verification.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement `finalizeClaudeVerification` in `src/domain/finalize.ts`**

Add this function next to `finalizeTimer` (lines 77-124). It has the same shape as `finalizeTimer`: pass → mark completed; already_processed → skip; failed → attempt charge via `createChargeIfPossible` (which itself returns `{kind:'no_stake'}` when `amountCents === 0`, so mirror rows with `stake_cents=0` safely flow through without a Stripe call).

```ts
async function finalizeClaudeVerification(
  row: SchedRow,
  result: EvaluationResult,
  userInfo: UserStripeInfo,
): Promise<FinalizeResult> {
  if (result.outcome === 'passed') {
    await db.update(scheduledCommitments)
      .set({ status: 'completed', updated_at: new Date() })
      .where(eq(scheduledCommitments.id, row.id));
    return { outcome: 'passed' };
  }

  if (result.outcome === 'already_processed') {
    return { outcome: 'skipped' };
  }

  if (result.outcome !== 'failed') return { outcome: 'skipped' };

  const meta = result.metadata as Record<string, unknown>;
  const charge = await createChargeIfPossible({
    amountCents: row.stake_cents,
    userInfo,
    description: result.description,
    metadata: {
      scheduled_commitment_id: row.id,
      commitment_type: 'claude_verification',
    },
  });

  const charge_attempted = true;
  const charge_processed = charge.kind === 'charged';
  const stripe_payment_intent_id = charge.kind === 'charged' ? charge.paymentIntent.id : null;
  const charge_error =
    charge.kind === 'charge_failed' ? charge.error :
    charge.kind === 'no_payment_method' ? 'No payment method on file' :
    charge.kind === 'no_stake' ? 'No stake amount' : null;

  await db.update(scheduledCommitments)
    .set({
      status: 'failed',
      charge_attempted,
      charge_processed,
      charge_error,
      stripe_payment_intent_id,
      updated_at: new Date(),
    })
    .where(eq(scheduledCommitments.id, row.id));

  if (charge.kind === 'charged') return { outcome: 'charged', stripe_payment_intent_id: charge.paymentIntent.id };
  if (charge.kind === 'charge_failed') return { outcome: 'charge_failed', charge_error: charge.error };
  return { outcome: 'no_charge', charge_error: charge_error ?? undefined };
}
```

Register in the dispatch map near line 302 (where `timer: finalizeTimer` appears):

```ts
const FINALIZERS = {
  plan: finalizePlan,
  timer: finalizeTimer,
  claude_verification: finalizeClaudeVerification,
  screen_time: finalizeScreenTime, // existing
} as const;
```

(Match whatever shape the existing dispatch uses — a switch, a map, etc. The signature above matches `finalizeTimer`'s exactly.)

- [ ] **Step 4: Register in `src/domain/commitment-types.ts`**

Add to the type definitions (follow the `timer` block at lines 50-60):

```ts
claude_verification: {
  stake_cents:           { direction: 'scalar_up' },
  deadline_time:         { direction: 'scalar_down' },
  allow_deadline_extend: { direction: 'bool_false_strict' },
},
```

If `splitTemplate('claude_verification', ...)` is used downstream (in the scheduling routes refactor), also make sure the identity/contract split is defined here. The contract fields above are the stricter-direction ones; identity is `{ name, slug, color }`. Follow whatever structure this file uses for the existing types.

- [ ] **Step 5: Extend cron dispatch in `src/routes/cron.ts`**

Find the part of the commitment-failures handler that filters by `type`. Add `claude_verification` to the allowed types (or remove the filter if it's already a whitelist that hits each type). Verify with a unit test if one exists; otherwise inline-check by reading `cron-commitment-failures.test.ts` and mirroring its test style in a new block:

```ts
it('finalizes a failed claude_verification with stake > 0 by charging', async () => {
  // ... setup a scheduled_commitments row with type=claude_verification, status=active, due_at in the past, stake_cents=500, no report
  // ... invoke the cron handler
  // ... assert Stripe called with 500, row status='failed'
});
```

Add the test to `__tests__/cron-commitment-failures.test.ts`.

- [ ] **Step 6: Run all tests**

Run: `pnpm test`
Expected: all pass, including existing tests.

- [ ] **Step 7: Type-check and commit**

```bash
pnpm type-check
git add src/domain/finalize.ts src/domain/commitment-types.ts src/routes/cron.ts __tests__/finalize-claude-verification.test.ts __tests__/cron-commitment-failures.test.ts
git commit -m "feat: finalize + cron for claude_verification"
```

---

### Task 11: Allow `claude_verification_requirement` as a requirement type

**Files:**
- Modify: `src/routes/requirements.ts` (line 34)

**Context:** A one-line change but test it to prevent regression.

- [ ] **Step 1: Read current line 34**

```bash
grep -n 'validTypes' src/routes/requirements.ts
```
Expected: see a line like `const validTypes = ['text', 'image_verification', 'schedule_plans', 'timer_requirement'];`

- [ ] **Step 2: Write failing test**

Add to an existing requirements test file, or create `__tests__/routes-requirements-claude-verification.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
// ... existing mock setup for requirements routes ...

describe('requirements — claude_verification_requirement', () => {
  it('accepts type=claude_verification_requirement', async () => {
    const res = await request(app).post('/api/requirements').send({
      name: 'GTD audit',
      description: '',
      template: '',
      type: 'claude_verification_requirement',
      config: { claude_verification_id: '<uuid>' },
    });
    expect(res.status).toBe(200);
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pnpm vitest run __tests__/routes-requirements-claude-verification.test.ts`
Expected: FAIL (type rejected).

- [ ] **Step 4: Update `src/routes/requirements.ts:34`**

```ts
const validTypes = ['text', 'image_verification', 'schedule_plans', 'timer_requirement', 'claude_verification_requirement'];
```

- [ ] **Step 5: Run tests**

Run: `pnpm vitest run __tests__/routes-requirements-claude-verification.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/routes/requirements.ts __tests__/routes-requirements-claude-verification.test.ts
git commit -m "feat: allow claude_verification_requirement type"
```

---

### Task 12: Mirror claude_verification requirements on plan scheduling

**Files:**
- Modify: `src/routes/plan-commitments.ts` (extend the POST handler)

**Context:** In the existing `POST /api/plan-commitments` handler (around lines 93-175), after the plan's own `scheduled_commitments` row is inserted, also insert mirror rows for any `claude_verification_requirement` entries. Mirror row rules per spec:

- `type = 'claude_verification'`
- `template_id = requirement.config.claude_verification_id`
- `due_at = <plan's due_at>`
- **`stake_cents = 0`** (server-enforced)
- `contract_snapshot = { stake_cents: 0, deadline_time: plan.time_due, allow_deadline_extend: plan.allow_deadline_extend }`
- `identity_snapshot = { name, slug, color }` from the claude_verification template
- `evaluation_state = { plan_commitment_id: <plan row.id>, requirement_id: <req.id>, is_plan_requirement: true }`

- [ ] **Step 1: Write integration test**

Create `__tests__/plan-claude-verification-integration.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest';
// ... mocks for db, auth ...

describe('plan scheduling mirrors claude_verification_requirement', () => {
  it('inserts a mirror row with stake_cents=0 and correct evaluation_state', async () => {
    // Set up mocks:
    // - plan with a requirement of type='claude_verification_requirement', config.claude_verification_id='cv-1'
    // - claude_verifications row 'cv-1' with name='GTD', slug='gtd', color='#8b5cf6', deadline_time='23:00'
    // - POST /api/plan-commitments with { plan_id, date: '2026-04-20' }
    // Assert:
    // - two insert calls on scheduled_commitments
    // - the mirror insert has: type='claude_verification', template_id='cv-1', stake_cents=0
    //   contract_snapshot.stake_cents=0
    //   evaluation_state.plan_commitment_id=<plan row id>
    //   evaluation_state.requirement_id=<req id>
    //   evaluation_state.is_plan_requirement=true
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run __tests__/plan-claude-verification-integration.test.ts`
Expected: FAIL (mirror insert not happening).

- [ ] **Step 3: Extend `src/routes/plan-commitments.ts`**

In the POST handler, after the plan row is inserted (around line 173 where `returning()` populates `row`), add:

```ts
// Mirror claude_verification_requirement entries.
const claudeReqs = requirementSnapshots.filter((r) => r.type === 'claude_verification_requirement');
if (claudeReqs.length > 0) {
  const templateIds = claudeReqs
    .map((r) => (r.config as any)?.claude_verification_id)
    .filter((v): v is string => typeof v === 'string');

  if (templateIds.length > 0) {
    const templates = await db.select()
      .from(claudeVerifications)
      .where(and(
        eq(claudeVerifications.user_id, userId),
        inArray(claudeVerifications.id, templateIds),
      ));

    const mirrorValues = claudeReqs.flatMap((req) => {
      const cvId = (req.config as any)?.claude_verification_id as string | undefined;
      const tmpl = templates.find((t: any) => t.id === cvId);
      if (!tmpl) return [];
      return [{
        user_id: userId,
        type: 'claude_verification' as const,
        template_id: tmpl.id,
        due_at: dueAt, // plan's due_at
        stake_cents: 0, // server-enforced
        status: 'active' as const,
        contract_snapshot: {
          stake_cents: 0,
          deadline_time: plan.time_due,
          allow_deadline_extend: plan.allow_deadline_extend,
        },
        identity_snapshot: {
          name: tmpl.name,
          slug: tmpl.slug,
          color: tmpl.color,
        },
        evaluation_state: {
          plan_commitment_id: row.id,
          requirement_id: req.id,
          is_plan_requirement: true,
        },
      }];
    });

    if (mirrorValues.length > 0) {
      await db.insert(scheduledCommitments).values(mirrorValues);
    }
  }
}
```

Imports to add at top of file:

```ts
import { claudeVerifications } from '../db/schema.js';
import { inArray } from 'drizzle-orm';
```

- [ ] **Step 4: Run tests**

Run: `pnpm vitest run __tests__/plan-claude-verification-integration.test.ts`
Expected: PASS.

- [ ] **Step 5: Type-check and commit**

```bash
pnpm type-check
git add src/routes/plan-commitments.ts __tests__/plan-claude-verification-integration.test.ts
git commit -m "feat: mirror claude_verification_requirement on plan scheduling"
```

---

### Task 13: Extend `evaluatePlan` for `claude_verification_requirement`

**Files:**
- Modify: `src/domain/evaluators.ts` (`evaluatePlan` function, around lines 68-91)

**Context:** Parallel to the existing timer branch, but reads `evaluation_state.passed === true` on the mirror row (not `status === 'completed'`), because the claude_verification cron and plan cron can race.

- [ ] **Step 1: Write a failing test**

Add to `__tests__/plan-claude-verification-integration.test.ts`:

```ts
it('plan evaluator marks requirement passed when mirror row has passed=true', async () => {
  // Setup: a plan scheduled_commitment with a claude_verification_requirement in evaluation_state.requirement_snapshots
  // Plus a mirror scheduled_commitments row (type=claude_verification) with
  //   evaluation_state: { plan_commitment_id: <plan id>, requirement_id: <req id>, passed: true }
  //   status: 'active'
  // Call evaluate(planRow)
  // Assert outcome is 'passed' with check_statuses[reqId]='passed'
});

it('plan evaluator marks requirement failed when mirror row has passed!=true', async () => {
  // Same setup but mirror's evaluation_state.passed is false or absent
  // Assert outcome is 'failed' with check_statuses[reqId]='failed'
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm vitest run __tests__/plan-claude-verification-integration.test.ts`
Expected: FAIL (plan evaluator ignores the new req type).

- [ ] **Step 3: Extend `evaluatePlan` in `src/domain/evaluators.ts`**

Find the existing for-loop at lines 70-91 that handles `timer_requirement`. Add a sibling branch AFTER that loop (to avoid collision with the timer query):

```ts
// Auto-evaluate claude_verification_requirement entries by looking up the mirrored
// scheduled_commitments row on the same plan instance + requirement. We read
// evaluation_state.passed directly (not status), because the claude_verification
// cron and the plan cron can race — the mirror row may still be status='active'
// at plan-evaluation time even though a passing report has been received.
for (const req of reqSnapshots) {
  if (req.type !== 'claude_verification_requirement') continue;
  const reqId = req.id as string;
  if (updated[reqId] === 'passed') continue;

  const mirrorRows = await db.select().from(scheduledCommitments)
    .where(and(
      eq(scheduledCommitments.user_id, row.user_id),
      eq(scheduledCommitments.type, 'claude_verification'),
    ));

  const match = mirrorRows.find((t: any) => {
    const s = (t.evaluation_state ?? {}) as Record<string, unknown>;
    return s.plan_commitment_id === row.id && s.requirement_id === reqId;
  });
  const passed = match && (match.evaluation_state as any)?.passed === true;
  updated[reqId] = passed ? 'passed' : 'failed';
}
```

- [ ] **Step 4: Run tests**

Run: `pnpm vitest run __tests__/plan-claude-verification-integration.test.ts`
Expected: PASS.

- [ ] **Step 5: Type-check and commit**

```bash
pnpm type-check
git add src/domain/evaluators.ts __tests__/plan-claude-verification-integration.test.ts
git commit -m "feat: evaluatePlan handles claude_verification_requirement"
```

---

### Task 14: End-to-end integration test

**Files:**
- Modify: `__tests__/plan-claude-verification-integration.test.ts` (add end-to-end flow)

**Context:** Single test that exercises the full lifecycle through mocked DB + Stripe:

1. Create a claude_verification template (`slug='gtd-audit'`, `stake=500`, `deadline=23:00`).
2. Create a requirement of type `claude_verification_requirement` pointing to it.
3. Create a plan with that requirement (stake=1000).
4. Generate an API token.
5. Schedule the plan on a date → verify mirror row created with `stake_cents=0`.
6. POST `/report` with the token → verify mirror row's `evaluation_state.passed=true` and `report_count=1`.
7. Run cron (call the commitment-failures handler directly) with the plan's row past due → verify plan is marked `status='completed'` and no Stripe call occurs.

Then a failure-path test:

1. Same setup minus the POST /report step.
2. Run cron → verify plan is marked `status='failed'` and Stripe called with 1000 cents (plan's stake, not the verification's 500).

- [ ] **Step 1: Write both failing tests**

Add to `__tests__/plan-claude-verification-integration.test.ts`. Use the existing mock pattern (`vi.mock` on `db` and `stripe`).

- [ ] **Step 2: Run and iterate**

Run: `pnpm vitest run __tests__/plan-claude-verification-integration.test.ts`
Expected: PASS both tests. If any fail, debug against the implementation from earlier tasks before moving on.

- [ ] **Step 3: Run the full suite**

Run: `pnpm test`
Expected: all tests pass (existing + new).

- [ ] **Step 4: Commit**

```bash
git add __tests__/plan-claude-verification-integration.test.ts
git commit -m "test: end-to-end claude verification + plan integration"
```

---

### Task 15: Smoke test against a real dev DB (optional but recommended)

**Context:** Mocked tests cover logic, but they don't catch schema drift, migration issues, or SQL-vs-ORM mismatches. Run a manual smoke test before merging.

- [ ] **Step 1: Apply migrations to dev DB**

```bash
pnpm db:migrate
```

- [ ] **Step 2: Start the server locally**

```bash
pnpm dev
```

- [ ] **Step 3: Exercise the endpoints via curl**

Get a JWT for a test user (use your existing auth flow or an existing test user), then:

```bash
JWT="<paste your JWT>"

# Create template
curl -X POST localhost:3000/api/claude-verifications \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"name":"Smoke GTD","slug":"smoke-gtd","stakeCents":100,"deadlineTime":"23:59"}'

# List
curl -H "Authorization: Bearer $JWT" localhost:3000/api/claude-verifications

# Generate API token
curl -X POST -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"label":"smoke"}' \
  localhost:3000/api/api-tokens
# Capture the returned raw token:
CKV="ckv_..."

# Schedule
curl -X POST -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"templateId":"<uuid from create>","dates":["2026-04-20"]}' \
  localhost:3000/api/claude-verification-commitments

# Report
curl -X POST -H "Authorization: Bearer $CKV" \
  -H "Content-Type: application/json" \
  -d '{"slug":"smoke-gtd","passed":true,"summary":"all good"}' \
  localhost:3000/api/claude-verifications/report
```

Expected: each command returns a 200 with the appropriate body. Check the DB to confirm `scheduled_commitments` has the expected rows and `evaluation_state.passed=true` after the report.

- [ ] **Step 4: Cleanup test data**

Either `pnpm db:reset` (if you have a dedicated dev DB) or delete test rows manually.

- [ ] **Step 5: No commit** — this task is verification only.

---

## Done criteria

- All 15 tasks complete, each with a passing commit.
- `pnpm test` exits clean.
- `pnpm type-check` exits clean.
- Dev smoke test succeeded.
- The server can receive a `POST /api/claude-verifications/report` and update a standalone scheduled row.
- The server can receive the same report and fan-out-update a standalone + mirror row.
- The cron correctly charges standalone failures (stake > 0) and skips mirror failures (stake = 0).
- The plan evaluator correctly reads mirror `evaluation_state.passed` to pass/fail a plan requirement.

After this plan lands and is deployed, the desktop plan (`2026-04-20-claude-verification-desktop.md`) can be written and executed against the live API.
