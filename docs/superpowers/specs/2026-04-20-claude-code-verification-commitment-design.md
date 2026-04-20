# Claude Code Verification Commitment — Design

**Date:** 2026-04-20
**Status:** Design approved; pending implementation plan

## Summary

Add a fourth commitment type to CommitKit — **claude_verification** — that represents a user commitment to "run a Claude Code skill that returns `passed: true` by a deadline, or pay the stake." Plan/timer/screen-time remain unchanged; this new type piggybacks on the existing unified `scheduled_commitments` table, the unified `cron:commitment-failures` job, and `createChargeIfPossible()` for Stripe charging. A verification can be standalone or attached to a plan as a requirement, mirroring how timers already work.

## Context

Today CommitKit supports three commitment types: **plans** (multi-requirement evaluations, AI-evaluated on server), **timers** (proof-of-work sessions, locally evaluated), and **screen-time limits** (usage thresholds, monitor-daemon tracked). All three share a single per-instance table `scheduled_commitments` with a `type` discriminator, and all charge via the same unified cron.

The user wants a fourth lever: tasks verified by a Claude Code skill running in the user's terminal. The immediate motivating use case is a daily GTD review audit where a skill walks the user's projects and next-actions files and returns pass/fail JSON. The skill itself is out of scope for this spec — this spec defines only the CommitKit infrastructure that consumes a verdict.

## Goals

- Reuse `scheduled_commitments`, the cron, the Stripe charging helper, and the evaluator/finalizer dispatch pattern. No parallel infrastructure.
- Support both **standalone** verification commitments and **plan-requirement** verification commitments, with the same reporting flow.
- Allow iterative re-reporting before the deadline (users fix issues and re-run the skill).
- Desktop is the management UI but is not required to be running at report time — the server is the broker.

## Non-goals

- Not executing the skill for the user. CommitKit does not spawn `claude` as a subprocess or run prompts. It only receives verdicts.
- Not validating or interpreting the `details` payload shape. The server branches on `passed: bool`; everything else is opaque stored JSON.
- Not shipping the actual GTD skill. The skill lives in the user's `~/.claude/skills/` and evolves independently.
- No mobile app support in v1. This is a desktop + CLI feature.

## Architecture

```
┌─────────────────┐   user runs skill
│  Claude Code    │─────────────────┐
│  (user's term)  │                 │
└─────────────────┘                 ▼
         │              POST /api/claude-verifications/report
         │ reads        Authorization: Bearer ckv_...
         │ credentials  { slug, date?, passed, summary?, details? }
         ▼                          │
~/.commitkit/credentials.json       ▼
         ▲                ┌──────────────────────┐
         │ writes         │  commitkit-server    │
         │                │                      │
┌─────────────────┐       │  updates scheduled_  │
│ commitkit-      │──────▶│  commitments row     │
│ desktop         │ CRUD  │  (type=claude_       │
│ (Tauri)         │       │  verification)       │
└─────────────────┘       │                      │
                          │  unified cron at     │
                          │  deadline → evaluate │
                          │  → Stripe charge     │
                          └──────────────────────┘
```

Server is the source of truth. Desktop manages templates, schedules instances, and displays results. The user's Claude Code skill, running in any terminal, POSTs a verdict using a persistent API token it reads from `~/.commitkit/credentials.json` (written by the desktop on first setup). Desktop does not need to be running when the skill reports.

Matches the plan/timer pattern of server-owned commitments (no local-SQLite mirror), not the screen-time pattern.

## Data model

### New table: `claude_verifications` (templates)

Located in `commitkit-server/src/db/schema.ts`:

```ts
export const claudeVerifications = pgTable("claude_verifications", {
  id:                  uuid("id").primaryKey().defaultRandom(),
  userId:              uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  name:                text("name").notNull(),
  slug:                text("slug").notNull(),
  stakeCents:          integer("stake_cents").notNull(),
  deadlineTime:        text("deadline_time").notNull(),                 // "HH:MM" in user tz
  color:               text("color").notNull().default("#8b5cf6"),
  allowDeadlineExtend: boolean("allow_deadline_extend").notNull().default(false),
  isPlanRequirement:   boolean("is_plan_requirement").notNull().default(false),
  active:              boolean("active").notNull().default(true),
  createdAt:           timestamp("created_at").notNull().defaultNow(),
  updatedAt:           timestamp("updated_at").notNull().defaultNow(),
}, (t) => ({
  uniqUserSlug: uniqueIndex("claude_verifications_user_slug_idx").on(t.userId, t.slug),
}));
```

**Slug rules:** lowercase ASCII letters, digits, hyphens. Unique per user. Defaulted from slugified name at creation; user-editable. The skill references commitments by slug — it is the stable user-facing identifier.

### New table: `api_tokens`

A new primitive. Plans/timers never authenticated from outside the app. Screen-time monitor traffic uses JWTs. For a CLI-invoked skill, we need long-lived bearer tokens.

```ts
export const apiTokens = pgTable("api_tokens", {
  id:         uuid("id").primaryKey().defaultRandom(),
  userId:     uuid("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  tokenHash:  text("token_hash").notNull().unique(),      // sha256 of the opaque token
  label:      text("label"),                              // e.g. "desktop — nathan's macbook"
  createdAt:  timestamp("created_at").notNull().defaultNow(),
  lastUsedAt: timestamp("last_used_at"),
  revokedAt:  timestamp("revoked_at"),
});
```

**Token format:** `ckv_` prefix + 32 bytes base64url-encoded randomness. Shown once to the user at creation; server stores only sha256 hash. Used as HTTP `Authorization: Bearer <token>`.

### Extend `scheduled_commitments`

No column changes. Add `'claude_verification'` to the valid values of the `type` discriminator. Per-instance shape:

- `type`: `'claude_verification'`
- `template_id` → `claude_verifications.id`
- `due_at`: `active_date + deadline_time` in user tz
- `stake_cents`: copied from template at scheduling
- `status`: `'active' | 'completed' | 'failed'`
- `contract_snapshot`: `{ stake_cents, deadline_time, allow_deadline_extend }`
- `identity_snapshot`: `{ name, slug, color }`
- `evaluation_state`: filled by report endpoint:
  ```json
  {
    "passed": true,
    "summary": "All 34 active projects have next actions.",
    "details": { ... skill's raw JSON, stored as-is ... },
    "reported_at": "2026-04-20T22:47:13Z",
    "report_count": 3,
    "plan_commitment_id": "<uuid|null>",
    "requirement_id":     "<uuid|null>",
    "is_plan_requirement": true
  }
  ```
- `charge_attempted`, `charge_processed`, `stripe_payment_intent_id`: same as existing types.

The `plan_commitment_id` + `requirement_id` + `is_plan_requirement` fields are only populated on rows mirrored from plan scheduling. They let `evaluatePlan` find the linked row at plan-evaluation time, matching the existing timer pattern.

### Extend `requirements.type`

Add `'claude_verification_requirement'` to the validTypes list in `commitkit-server/src/routes/requirements.ts:34`.

`requirements.config` JSON for this type: `{ claude_verification_id: uuid }` pointing to the template.

## API

All endpoints live in `commitkit-server/src/routes/`. JWT auth unless noted.

### Template CRUD — `claude-verifications.ts`

Mirrors `/api/plans`:

- `GET /api/claude-verifications` — list user's templates.
- `POST /api/claude-verifications` — body: `{ name, slug, stakeCents, deadlineTime, color?, allowDeadlineExtend?, isPlanRequirement? }`. Returns the created template. Validates slug format and uniqueness.
- `PATCH /api/claude-verifications/:id` — partial updates. Slug is editable but must remain unique. Updating slug does NOT retroactively rewrite existing `identity_snapshot` values on prior scheduled instances — snapshots are frozen per existing conventions.
- `DELETE /api/claude-verifications/:id` — soft delete (sets `active=false`). Existing scheduled instances continue to be enforceable via their snapshots.

### Scheduling — `claude-verification-commitments.ts`

Mirrors `/api/plan-commitments`:

- `POST /api/claude-verification-commitments` — body: `{ templateId, dates: string[] }`. For each date, inserts one `scheduled_commitments` row with `type='claude_verification'`, `due_at = date + template.deadline_time` in user tz, contract + identity snapshots frozen from current template values, `stake_cents = template.stakeCents`.
- `DELETE /api/claude-verification-commitments/:scheduledCommitmentId` — unschedule. Only permitted if `status='active'` and the row has not crossed the 10-minute lock window (matching existing lock rule from CLAUDE.md).

### Report — `claude-verifications.ts` (or separate file)

New endpoint with **API token auth**, not JWT:

```
POST /api/claude-verifications/report
Authorization: Bearer ckv_...
Content-Type: application/json

Body:
{
  "slug":    "gtd-daily-audit",
  "date":    "2026-04-20",      // optional, defaults to "today" in user tz
  "passed":  true,
  "summary": "All 34 projects have next actions",  // optional, ≤500 chars
  "details": { ... }            // optional arbitrary JSON blob, ≤64 KB serialized
}

Response 200:
{
  "updated": [
    {
      "scheduledCommitmentId": "uuid",
      "status":   "active",
      "dueAt":    "2026-04-20T23:00:00-05:00",
      "reportCount": 3,
      "isPlanRequirement": false
    }
  ]
}
```

The `updated` array typically contains one entry. Two entries can occur when the user has both a standalone instance and a plan-requirement mirror scheduled on the same date for the same template — one report fans out to both.

**Resolution logic (server):**

1. Validate `Authorization` header → sha256 the token → lookup in `api_tokens` (non-revoked). Set `lastUsedAt`. Resolve `userId`. On miss: **401**.
2. Lookup `claude_verifications` by `(userId, slug)` where `active=true`. On miss: **404** with message `"no active verification with slug '<slug>'"`.
3. Lookup **all** `scheduled_commitments` rows where `template_id = that.id`, `type = 'claude_verification'`, and the date-component of `due_at` (in user tz) = resolved date. On empty result: **404** with message `"no verification scheduled for <date>"`.
4. Partition the rows into (a) updatable (status=`'active'` AND `due_at > now()`) and (b) rejected (past deadline or non-active).
5. If (a) is empty, return **409** with a message describing the first rejection reason found (e.g., `"deadline has passed"` or `"verification already <status>"`). All-or-nothing: the endpoint does not partial-update when some rows would reject.
6. Atomic transaction: for each row in (a), set `evaluation_state.passed`, `evaluation_state.summary`, `evaluation_state.details`, `evaluation_state.reported_at = now()`, increment `evaluation_state.report_count` by 1. Return 200 with the `updated` array.

**Body validation:** `summary` trimmed/truncated to 500 chars. Serialized `details` rejected with **413** if > 64 KB. Missing `passed` → **400**.

### Extend — `claude-verifications.ts`

Matches existing `extendPlanDeadline` / `extendTimerDeadline` endpoints (JWT auth):

- `POST /api/claude-verifications/extend/:scheduledCommitmentId` — bump `due_at` by 2 minutes.
  - Reject 403 if `contract_snapshot.allow_deadline_extend != true`.
  - Reject 409 if outside the last-2-minutes-before-`due_at` window.
  - Reject 409 if `status != 'active'`.
  - On success, update `due_at` (and the `deadline_time` in `contract_snapshot` for display consistency), return updated snapshot.

### Token management — `api-tokens.ts` (new)

JWT auth:

- `GET /api/api-tokens` — list user's tokens (label, createdAt, lastUsedAt, revokedAt). Never returns raw tokens.
- `POST /api/api-tokens` — body: `{ label? }`. Generates token, inserts hashed row, returns raw token **once** in response. Client is responsible for persisting.
- `POST /api/api-tokens/:id/revoke` — sets `revokedAt = now()`.

## Evaluation and finalization

### Standalone evaluation

New function `evaluateClaudeVerification(row)` in `commitkit-server/src/domain/evaluators.ts`:

```ts
async function evaluateClaudeVerification(row: SchedRow): Promise<EvaluationResult> {
  if (row.status !== 'active') {
    return { outcome: 'already_processed', description: `status=${row.status}`, metadata: { status: row.status } };
  }
  const eval_ = (row.evaluation_state ?? {}) as Record<string, unknown>;
  if (eval_.passed === true) {
    return { outcome: 'passed', description: 'verification reported passed', metadata: { reported_at: eval_.reported_at } };
  }
  return {
    outcome: 'failed',
    description: eval_.passed === false ? 'verification reported failed' : 'no verification reported',
    metadata: { report_count: eval_.report_count ?? 0, summary: eval_.summary },
  };
}
```

Register in the evaluator dispatch alongside `evaluatePlan`, `evaluateTimer`, `evaluateScreenTime`.

### Finalization

New function `finalizeClaudeVerification(row, outcome)` in `commitkit-server/src/domain/finalize.ts`, structurally identical to `finalizeTimer`:

- On `outcome='passed'`: update row `status='completed'`, no Stripe call, no violations row.
- On `outcome='failed'`: update row `status='failed'`, `charge_attempted=true`; call `createChargeIfPossible({ stake_cents: row.stake_cents, customerId, paymentMethodId, description, metadata })`; persist `charge_processed`, `stripe_payment_intent_id`, `charge_error` per the result kind.

No entries in the `violations` table (matching plan/timer behavior; only screen-time writes to `violations`).

### Cron wiring

Extend the dispatch in `commitkit-server/src/cron.ts`:

- Add `claude_verification` to the `type` filter in the `scheduled_commitments` scan.
- Route matching rows through `evaluateClaudeVerification` → `finalizeClaudeVerification`.
- No new Railway service. The existing `missed-checkins-cron` already invokes the unified `cron:commitment-failures` script. The dispatch extension is sufficient.

### Plan-requirement mirroring

When `POST /api/plan-commitments` schedules a plan on date D and the plan has a `claude_verification_requirement`:

1. Existing code inserts the plan's `scheduled_commitments` row (`type='plan'`).
2. New mirror step inserts a parallel `scheduled_commitments` row:
   - `type = 'claude_verification'`
   - `template_id` = `requirement.config.claude_verification_id`
   - `due_at` = plan's `due_at` (requirement inherits plan's deadline — no separate per-requirement deadline in v1).
   - `stake_cents` = **0**. Plan-requirement mirrors carry no independent stake — failure cascades to the plan, which has its own stake. The claude_verification template's `stake_cents` is used only for standalone instances. (This is a product-level rule: a requirement should fail the plan, not charge separately. The same rule applies conceptually to plan-required timers, and the server enforces it here rather than trusting the client.)
   - `contract_snapshot` = `{ stake_cents: 0, deadline_time: plan.time_due, allow_deadline_extend: plan.allow_deadline_extend }`
   - `identity_snapshot` = cloned from the claude_verification template.
   - `evaluation_state` = `{ plan_commitment_id: <plan row id>, requirement_id: <requirement row id>, is_plan_requirement: true }`.

Extend `evaluatePlan()` in `evaluators.ts:68-91` with a new branch for `req.type === 'claude_verification_requirement'`, paralleling the existing `timer_requirement` branch: find the mirrored `scheduled_commitments` row where `evaluation_state.plan_commitment_id = plan.id` and `evaluation_state.requirement_id = req.id`, then mark the requirement `'passed'` iff `evaluation_state.passed === true` on the mirrored row. Note this differs from the timer branch which keys off `status === 'completed'` — claude_verification mirrored rows may still be `status='active'` at plan-evaluation time (the claude_verification cron and the plan cron can race), so we read `passed` directly from the latest report rather than waiting for cron to finalize.

**Fan-out on resolution.** The user's skill POSTs `{slug, date, passed}`; the server resolves slug+date to **all** matching `scheduled_commitments` rows (typically one, but two in the rare case where the user has both a standalone instance and a plan-requirement mirror scheduled on the same date). The report updates every matching row atomically in a single transaction. Standalone vs plan-requirement is transparent to the skill — it reports once regardless of how many rows the verdict applies to.

## Desktop UI

All UI lives in `commitkit-desktop/`. No local SQLite for this type — all CRUD calls hit the server directly via new Tauri commands that proxy to the existing `sync_service`.

**Templates page:** new "Verifications" tab alongside Plans / Timers / Limits in the Templates area.

**Form dialog:** `components/verifications/verification-form-dialog.tsx`, structured like `plan-form-dialog.tsx`:

- Name (text).
- Slug (auto-populated from name; user-editable; validates lowercase-ascii-hyphen).
- Stake (dollar input, converts to cents).
- Deadline time (HH:MM picker).
- Color picker (reuses `COLOR_OPTIONS`).
- "Allow 2-minute extend" toggle → `allow_deadline_extend`.
- "Use as plan requirement" toggle → `is_plan_requirement`.

**Day-view cards:** scheduled verification instances render alongside plan/timer cards in the day view. Mirror rows (`evaluation_state.is_plan_requirement = true`) are filtered out of the standalone day view — they surface inside the parent plan's submission view instead, matching how plan-required timers are handled today. Card contents for standalone verification instances:

- Name + color dot + deadline time.
- Status badge: `active` / `completed` / `failed`.
- If the row has a report: "Last reported: passed at HH:MM — <summary>" + an expandable "View details" revealing the `details` JSON blob.
- "Extend 2 min" button within the last-2-min window if `allow_deadline_extend`, wired to `useDeadlineProximity` + new `tauri.extendClaudeVerificationDeadline` command.
- **No "run verification" button.** The user runs the skill in their terminal, not in the app.

**Credentials setup:** a new card in Settings → Account:

- If no token exists: "Generate API token" button. Clicking calls new Tauri command `create_api_token()` → server POST → desktop receives raw token once → writes `~/.commitkit/credentials.json` with `{ api_token, server_url }` → shows confirmation + copy-to-clipboard affordance.
- If a token exists: show label, created date, last-used date, "Revoke token" button. Revoking deletes the credentials file and posts revoke to server.

**Plan-form integration:** in `plan-form-dialog.tsx`, add `claude_verification_requirement` as a new option in the requirement-type selector. Selecting it surfaces a picker showing the user's verifications where `is_plan_requirement = true`.

## Credentials file format

`~/.commitkit/credentials.json`:

```json
{
  "api_token": "ckv_<base64url>",
  "server_url": "https://api.screentime.commitkit.com",
  "created_at": "2026-04-20T10:00:00Z",
  "label": "desktop — nathan's macbook"
}
```

File permissions: 0600. Desktop creates parent directory if missing. On revoke or token rotation, desktop overwrites or deletes the file.

## Edge cases

- **Skill reports before any scheduling exists.** 404. Skill surfaces "No active verification scheduled for today."
- **Skill reports with typo'd slug.** 404 with active slug list omitted from error (to avoid leaking template names in logs). Error text: `"no active verification with slug '<slug>'"`.
- **Multiple reports at near-same timestamp.** Serialized in a single UPDATE transaction; last write wins on `passed`/`summary`/`details`; `report_count` increments once per request.
- **`details` payload exceeds 64 KB.** Rejected 413. User iterates to reduce payload or drops `details`.
- **User revokes token while skill is mid-run.** Next POST returns 401. Skill surfaces error; user regenerates token and re-runs.
- **Clock skew at deadline.** Server's clock is authoritative. If `due_at <= server_now()` when the report arrives, it is rejected — even if the user's clock says there's 5 seconds left.
- **Plan requirement reported, but plan has other unmet requirements.** Verification mirror row has its `evaluation_state.passed` set to true; plan row stays `active` until all requirements pass. Plan evaluator at cron time reads the mirror row's `evaluation_state.passed` directly (not `status`, which may still be `active` if claude_verification cron hasn't run yet). Plan's own stake is what charges if the plan ultimately fails — the mirror row's `stake_cents` is 0 and contributes nothing to charges.
- **User deletes a template with scheduled instances.** Soft delete only — `active=false` on template. Existing scheduled rows continue to be enforceable using their frozen snapshots. Report endpoint rejects 404 (looks up `active=true` templates only), so after soft delete, no more reports can arrive — the instance will fail at cron time and charge.
- **Desktop never run on a scheduling date.** Zero impact at report time. Desktop will reflect status when next opened.

## Testing (server)

Using Vitest, consistent with `commitkit-server/__tests__/`:

- Template CRUD: create / list / update / soft delete; slug uniqueness; slug format validation.
- Token management: create returns raw once; hash stored; revoke works; list excludes raw.
- Scheduling: `POST /api/claude-verification-commitments` creates rows with correct `due_at` in user tz and correct snapshots.
- Report endpoint: happy path (new report), happy path (overwrite existing), 401 (bad/revoked token), 404 (unknown slug), 404 (wrong date), 409 (past deadline), 409 (already completed), 400 (missing `passed`), 413 (oversized `details`).
- Extend endpoint: happy path within 2-min window; 403 when `allow_deadline_extend=false`; 409 outside window; 409 when not active.
- Evaluator: passed / failed / never-reported outcomes all route to correct `EvaluationResult`.
- Finalizer: Stripe called with correct amount on failed standalone row; not called on passed; not called on mirror row with `stake_cents=0` regardless of outcome; `charge_attempted`/`charge_processed`/`stripe_payment_intent_id` persisted; no violations row written.
- Plan-requirement mirroring: plan scheduling creates a linked claude_verification row with `stake_cents=0`, `plan_commitment_id`, and `requirement_id` populated; plan evaluator reads the mirror row's `evaluation_state.passed` (not `status`); plan marks failed if mirror row has `passed !== true`; plan marks passed if all requirements pass.
- Fan-out report: creating both a standalone instance and a plan-requirement mirror for the same template+date, then posting one report, updates both rows atomically.
- End-to-end: create template → generate token → schedule → POST report → cron runs → assert `status=completed` and no Stripe call; then same flow with no report → assert `status=failed` and Stripe called.

No desktop tests required (no dedicated frontend Vitest coverage for the parallel plan/timer UIs exists today; desktop verification is manual per existing conventions).

## Implementation scope (high-level)

**commitkit-server:**
- `src/db/schema.ts`: add `claudeVerifications` + `apiTokens` tables.
- Drizzle migration.
- `src/routes/claude-verifications.ts`: template CRUD + report + extend.
- `src/routes/claude-verification-commitments.ts`: schedule + unschedule.
- `src/routes/api-tokens.ts`: token management.
- `src/routes/requirements.ts`: add `claude_verification_requirement` to valid types.
- `src/routes/plan-commitments.ts`: extend scheduling to mirror claude_verification requirements.
- `src/middleware/api-token-auth.ts`: new middleware for bearer-token auth on the report endpoint.
- `src/domain/evaluators.ts`: add `evaluateClaudeVerification`; extend `evaluatePlan` for the new requirement type.
- `src/domain/finalize.ts`: add `finalizeClaudeVerification`.
- `src/domain/commitment-types.ts`: register contract fields for the new type (for the existing strictness-direction analysis).
- `src/cron.ts`: extend dispatch to include `claude_verification`.
- Tests for all of the above.

**commitkit-desktop:**
- New Tauri commands: `listClaudeVerifications`, `createClaudeVerification`, `updateClaudeVerification`, `deleteClaudeVerification`, `scheduleClaudeVerification`, `extendClaudeVerificationDeadline`, `createApiToken`, `listApiTokens`, `revokeApiToken`.
- `lib/tauri.ts` wrappers for all of the above.
- `components/verifications/verification-form-dialog.tsx`.
- `components/verifications/verifications-list.tsx`.
- Templates page tab wiring.
- Day-view card component for verification instances.
- Settings → Account credential card + Tauri command to write `~/.commitkit/credentials.json`.
- `plan-form-dialog.tsx`: integrate `claude_verification_requirement` as a selectable requirement type with a template picker.

**commitkit-mobile, commitkit-eval, commitkit-monitor:** no changes.

## Rollout notes

- Desktop and server both need to ship together for the feature to be usable. Server can ship first (API becomes available but no UI).
- No backfill required — new feature.
- No changes to existing Railway cron services.
- No changes to existing data.
