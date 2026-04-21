# Ad-hoc (One-off) Timers — Design

**Date:** 2026-04-21
**Status:** Design approved; pending implementation plan

## Summary

Add a "start a staked timer right now" flow to commitkit-desktop. The user picks a duration, stake, project, and distraction lists, hits Start, and either completes the timer or gets charged. The feature is syntactic sugar around the existing `scheduled_commitments` + `cron:commitment-failures` pipeline — no new charging path. The only genuinely new data-model concept is an `allow_cancel` boolean that lets us lock a running timer against escape-by-clicking-cancel (for ad-hoc, this is forced to `false`; existing templates keep the current "always cancellable" behavior).

## Context

Today, staked timers only exist via: create `timer_templates` row → schedule it to a specific date → server creates a `scheduled_commitments` row of `type='timer'` with a `due_at` → user runs a session → completion pings back, or the unified daily cron charges the stake on the due date.

Two gaps relative to the user's "just start a timer right now" intent:

1. **Mandatory template round-trip.** The user has to go to the Templates tab, create a timer template, then schedule it. There's no low-friction path.
2. **Cancellation is always free.** `cancel_timer_session` marks the session `cancelled` with no charge. A sophisticated user can dodge enforcement by hitting Cancel — the stake only "bites" if you let the timer run out while visiting distractions, not if you back out before that.

A dormant `components/timer/timer-view.tsx` already implements ~90% of the setup UI (duration/penalty presets, project + list selection, running + result views) but is unwired, calls an older `tauri.startTimer` path that bypasses server-side assignments, and has no enforcement teeth against cancel.

This design makes ad-hoc timers a first-class entry point that reuses the existing enforcement pipeline end-to-end, adds the one missing data-model primitive (`allow_cancel`), and resurrects `timer-view.tsx` as the UI.

## Goals

- One-click "start a staked timer now" from the home dashboard
- Full server-side enforcement: if the user force-quits or walks away, the daily cron charges the stake
- No templates-list clutter — ad-hoc timers never persist as `timer_templates` rows
- Reuse `scheduled_commitments`, `cron:commitment-failures`, and `createChargeIfPossible()`. No parallel infrastructure.
- The `allow_cancel` flag is general: template authors can opt existing templates into the same lock behavior

## Non-goals

- **Multi-timer ad-hoc sessions** (e.g. "4×30min by 2pm"). Explicitly deferred — the benefit over scheduling a template is minor.
- **Saving an ad-hoc config as a template** ("keep this as a template"). Deferred.
- Mobile support. Desktop-only.
- Changing the semantics of `cancel` for today's (cancellable) timers. If `allow_cancel = true`, cancel still means "no charge."

## Architecture

```
┌───────────────────┐   "Focus Now" button
│  Home dashboard   │─────────────────┐
└───────────────────┘                 ▼
                           ┌─────────────────────┐
                           │ AdHocTimerModal     │
                           │ (timer-view.tsx,    │
                           │  rewired + simpler) │
                           └──────────┬──────────┘
                                      │ Start
                                      ▼
                           ┌─────────────────────┐     POST /api/timer-assignments
                           │ tauri.              │    (template_id: null,
                           │ startAdHocTimer()   │──▶  template_snapshot: {...,
                           └──────────┬──────────┘      allow_cancel: false},
                                      │                 due_at: now + dur + grace)
                                      ▼                          │
                  ┌────────────────────────────────┐              ▼
                  │ local: INSERT timer_sessions   │   ┌──────────────────────┐
                  │ (assignment_id, allow_cancel=  │   │ scheduled_commitments│
                  │  false, status='running')      │   │ row (type='timer')   │
                  └────────────────────────────────┘   └──────────┬───────────┘
                                                                  │
                   ┌──────────────────────────────────────────────┤
                   ▼                                              ▼
         user completes in time                     user abandons / force-quits
                   │                                              │
                   ▼                                              ▼
         complete_timer_session →                  due_at passes → daily cron
         evaluate_and_finalize →                   → evaluator marks failed
         assignment 'completed'                    → finalize → Stripe charge
         no charge                                 → assignment 'charged'
```

Server remains the enforcement authority. The only new server behavior is accepting `template_id: null` on assignment creation (with a full `template_snapshot`). Everything downstream — evaluators, finalizer, cron, charging — is unchanged.

## Data model

### New column: `allow_cancel` (three places)

**Local: `timer_templates`** — new column via migration v19 in `src-tauri/src/db.rs`:

```sql
ALTER TABLE timer_templates ADD COLUMN allow_cancel INTEGER NOT NULL DEFAULT 1;
```

Default `1` (true) preserves behavior for all existing templates.

**Local: `timer_sessions`** — denormalized at session creation so the running UI can read it without a template lookup (ad-hoc sessions have no local template row at all):

```sql
ALTER TABLE timer_sessions ADD COLUMN allow_cancel INTEGER NOT NULL DEFAULT 1;
```

**Server: `timer_templates`** — new Drizzle column, migrates existing rows to `true`:

```ts
allowCancel: boolean("allow_cancel").notNull().default(true),
```

**Server: `scheduled_commitments.template_snapshot`** — the JSON snapshot already stores the template payload at scheduling time; include `allow_cancel` in it. No schema change.

### Nullable `template_id` on `scheduled_commitments`

Verify the `templateId` column on `scheduled_commitments` is already nullable (or make it nullable via migration). Ad-hoc assignments set it to `null` and rely entirely on `template_snapshot`.

### Rust / TypeScript types

- `src-tauri/src/models.rs`: add `allow_cancel: bool` to `TimerTemplate`, `TimerSession`, and `CreateTimerSessionInput`
- `lib/types.ts`: same — add `allow_cancel: boolean` to `TimerTemplate`, `TimerSession`, and the ad-hoc start input

## Ad-hoc start flow

### Desktop → server

New Tauri command `start_ad_hoc_timer` in `commands.rs`, backed by a new API client method:

```rust
// api_client.rs — new method
pub async fn create_ad_hoc_timer_assignment(
    &self,
    payload: AdHocTimerAssignmentPayload,
) -> Result<TimerAssignment, String>
```

`AdHocTimerAssignmentPayload` carries: `duration_minutes`, `penalty_amount`, `list_ids` (resolved to UUIDs for server), `project_id` (optional but required at UI layer), `apps`/`domains` (empty for ad-hoc — lists do the work), `allow_cancel: false`, and a display name (derived — e.g. "Quick 30m timer").

### Server endpoint

Extend the existing `POST /api/timer-assignments` to accept:

- `template_id: null` (already nullable, or made nullable as part of this work — verify during implementation)
- Full `template_snapshot` built from the payload, including `allow_cancel: false` and a derived display name (e.g. "Quick 30m timer")
- `stake_cents` from the payload
- `due_at = now + duration_minutes + 2 minutes` (grace buffer for network / evaluation latency)
- `date = today (user tz)` — needed for day-view grouping

One endpoint, one code path. The existing template-scheduled flow continues to pass a `template_id`; ad-hoc passes `null`.

No changes to evaluators, finalizer, or the cron. They already read from `template_snapshot`.

### Desktop-side local session

After the server assignment is created, desktop inserts a local `timer_sessions` row with:

- `assignment_id` = returned assignment ID
- `allow_cancel = false`
- `duration_minutes`, `penalty_amount`, `list_ids`, `project_id` from the form
- `started_at = now`, `status = 'running'`

## Cancellation enforcement

Two layers:

1. **UI**: `SessionRunner` and (rewired) `TimerView` running-state render check `session.allow_cancel`. If `false`, the Cancel button is not rendered. The close/ESC affordance on the modal is also disabled while a locked timer runs.
2. **Server**: `due_at` was set at assignment creation. If the user force-quits, kills the process, or just walks away, the next daily run of `cron:commitment-failures` picks up the assignment (active, due_at passed, no completion reported), marks it failed, and calls `createChargeIfPossible()`.

This is Option C: the UI removes the easy escape hatch, and the server catches the rest. No new cron, no new charging code.

On force-quit during a locked timer, the local session row stays in `running` state. On next app launch, the existing active-timer rehydration logic re-opens the running view. If `due_at` has passed and the cron has already marked the server assignment failed, the next sync pulls that state down and the local session is resolved to `failed`.

## UI

### Entry point

A "Focus Now" (working title) button on the home dashboard — specifically on the page rendered by `components/dashboard/day-view.tsx` or its parent. Placed prominently but not disruptively (top of the page alongside the date, or in an empty-state CTA when the day has no other commitments). Exact placement is a small UX call, not an architectural one.

### Modal

Resurrect `components/timer/timer-view.tsx` and mount it as a modal (following the plan-form-dialog pattern from `components/plans/plan-form-dialog.tsx`). Changes to the existing component:

- **Drop the Blocks control** — single-timer only in v1
- **Require a project** — remove the "No project" option; disable Start until a project is selected (matches the memory convention that sessions should require a project)
- **Require ≥1 distraction list** — already enforced
- **Rewire `handleStart`** — call new `startAdHocTimer` path instead of `tauri.startTimer`; receive the created assignment ID and pass it to the session
- **Hide Cancel in running view when `allow_cancel === false`** — for ad-hoc, this is always the case
- **Show a "locked" affordance** where Cancel used to be — e.g. a small note like "Stake locked — complete or be charged"
- **Strip multi-block result logic** — simplify to a single pass/fail result view

The setup-view preset UI (duration 15/25/45/60, penalty $5/$10/$25) stays as-is.

### Day-view integration

Ad-hoc assignments show up in the day view just like any other timer assignment (they ARE `scheduled_commitments` rows of type `timer`). No special casing needed, though we may want to display a "locked" badge visually distinct from regular scheduled timers — low priority, can wait.

## Template-form edit (follow-up)

After v1 is stable, add an "Allow cancel" checkbox to the timer template edit form (`components/timer/timer-template-form-dialog.tsx`). Default checked (matches the DB default). This exposes the same `allow_cancel` flag to template authors who want a locked scheduled template. No schema or backend changes — the column already exists from this spec.

## Files touched

### commitkit-desktop

- `src-tauri/src/db.rs` — migration v19: add `allow_cancel` to `timer_templates` and `timer_sessions`
- `src-tauri/src/models.rs` — add `allow_cancel` to structs; new `AdHocTimerAssignmentPayload`
- `src-tauri/src/commands.rs` — new `start_ad_hoc_timer` handler
- `src-tauri/src/api_client.rs` — `create_ad_hoc_timer_assignment`
- `src-tauri/src/db_operations.rs` — `create_timer_session` accepts and stores `allow_cancel`
- `src-tauri/src/lib.rs` — register new command in `invoke_handler`
- `lib/types.ts` — add `allow_cancel`; new `StartAdHocTimerInput`
- `lib/tauri.ts` — wrapper for the new command
- `components/timer/timer-view.tsx` — simplify (drop blocks), rewire start path, conditional cancel
- `components/timer/session-runner.tsx` — conditional cancel based on `session.allow_cancel`
- `components/dashboard/*` — "Focus Now" trigger button + modal mount
- (Follow-up) `components/timer/timer-template-form-dialog.tsx` — add Allow-cancel checkbox

### commitkit-server

- `drizzle/` — new migration adding `allow_cancel` to `timer_templates`
- `src/db/schema.ts` — `allowCancel` column on `timerTemplates`
- `src/routes/timer-assignments.ts` (or equivalent) — accept `template_id: null` + full snapshot; build `scheduled_commitments` row with `due_at = now + duration + 2min`

## Open questions

None blocking. The grace window (2 min) is a judgment call — can be tuned during implementation based on how evaluation latency behaves in practice.

## Testing

- **Unit (desktop, Vitest)**: `allow_cancel` flows through session creation; UI conditionally renders Cancel
- **Unit (server, Vitest)**: ad-hoc assignment creation with `template_id: null` produces a valid `scheduled_commitments` row the evaluator can consume
- **Manual**: happy path (start → complete → no charge), force-quit path (start → kill app → wait for cron → charge), abandon path (start → let timer expire while on distraction → charge)
- No new Rust tests needed — logic changes are thin passthroughs
